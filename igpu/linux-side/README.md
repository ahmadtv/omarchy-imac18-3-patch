# Headless Intel HD 630 on Linux: the Linux side

> **Installed by `imac-patcher --apply macos` since 2026-09-12; the notes below are the
> original design.** Prepared 2026-09-11 against
> kernel 7.2.3-arch1-3 (source in `~/.cache/kernel-5k-build/linux-7.2.3`),
> libva 2.24.1, ffmpeg 9.0.1, gpu-screen-recorder 6.1.0, Hyprland 0.56.2 /
> aquamarine 0.15.0, WirePlumber 0.5.17, mkinitcpio 41.1, Omarchy 4.0.3.
> The EFI side (calling Apple `set_os` so firmware stops hiding 00:02.0) is the kernel's
> own stub, with iMac18,3 added by `mkinitcpio/imac-setos` (`../README.md`, stage 2f).

**Goal:** use the HD 630 the way macOS does (`NumFrameBuffer 0`, Quick Sync
encode): render and video only. It never drives a display, and it is never the
compositor's GPU. The Radeon Pro 575 keeps doing everything else.

## Decisions at a glance

| Topic | Decision |
|---|---|
| i915 display | `i915.disable_display=1` **plus** `i915.vbt_firmware=imac18-3/headless-vbt.bin` (a VBT that declares no outputs). Display engine still initialised, so DMC, DC5/DC6 and power-well gating stay available. |
| GuC/HuC | Stage 1: off (the default on gen9). Stage 2, on a separate boot: `i915.enable_guc=2`, only for low-power H.264 with CBR/VBR. |
| initramfs | i915 is never in it: drop the `kms` hook (amdgpu is already in `MODULES=`). Measured: today's image is byte-for-byte the same size and has the same file list. |
| Device names | udev links `/dev/dri/{amd,intel}-{card,render}`, keyed on PCI address and driver. |
| Compositor | `AQ_DRM_DEVICES=/dev/dri/amd-card`, guarded so it applies only on set_os boots and only if the link exists. The SDDM greeter pin is optional. |
| VA-API default | Unchanged. Everything stays on the Radeon (renderD128 stays AMD). Intel is opted into per application. Do **not** set `LIBVA_DRIVER_NAME`. |
| Decode | Stays on the Radeon for playback. Transcode pipelines run entirely on Intel (decode, scale and encode on one device). |
| Audio | `snd_hda_intel.probe_mask=1,1` stops the Intel HDMI codec from being probed. A WirePlumber rule is the fallback. |
| Hibernation | Hibernation is masked today. The test entry has no `resume=`. A guard drop-in is drafted for the day hibernation is unmasked. |
| Test-phase scoping | All kernel options go on the **test entry's command line**. The default entry and its configuration stay untouched. |

---

## 1. i915 on this kernel: what the parameters really do

### Parameters available (7.2.3)
`i915_params.h`: `modeset`, `enable_guc`, `guc_log_level`, `guc/huc/gsc_firmware_path`,
`force_probe`, `reset`, `enable_hangcheck`, `error_capture`, `enable_gvt`, ….
`display/intel_display_params.h`: `dmc_firmware_path`, `vbt_firmware`, `enable_dc`,
`disable_power_well`, `enable_fbc`, `enable_psr`, `disable_display`, ….

- `force_probe`: not needed. The kernel config has `CONFIG_DRM_I915_FORCE_PROBE="*"`, and KBL 8086:5912 is supported natively anyway.
- `modeset=0`: unusable here. `i915_module.c` treats 0 as "don't register the driver" (deprecated alias of `nomodeset`), so there would be no render node either.
- `enable_dc` (default -1) and `disable_power_well` (default -1, sanitised to 1): leave both alone. For display version 9, `get_allowed_dc_mask()` sets `max_dc = 2`, which means up to DC6.

### What `disable_display=1` does, from the code
```c
/* display/intel_display_device.c */
 * Disabling display means taking over the display hardware, putting it to
 * sleep, and preventing connectors from being connected via any means.
bool intel_display_device_enabled(struct intel_display *display)
{   return !display->params.disable_display && !intel_opregion_headless_sku(display); }
```
- It does **not** clear `HAS_DISPLAY()`: `DRIVER_MODESET` stays set, so i915 still creates `cardN` (with no usable outputs). The full display bring-up still runs:
  - `intel_display_driver_probe_noirq()` → `intel_display_power_init_hw()`
  - `intel_dmc_init()` loads `i915/kbl_dmc_ver1_04.bin`, which is installed as `.zst`. `CONFIG_FW_LOADER_COMPRESS_ZSTD=y`.
  - `get_allowed_dc_mask()` returns 0 only `if (!HAS_DISPLAY(display))`, so DC5/DC6 stay allowed.
  - Unused power wells are disabled.
- The only callers of `intel_display_device_enabled()` are connector `detect()`/init paths (`intel_dp.c`, `intel_hdmi.c`, `intel_dp_mst.c`, `intel_crt/dvo/sdvo/tv.c`, `intel_panel.c`) and `intel_hpd_poll_enable()`. Every detect returns `connector_status_disconnected`.
- It does **not** stop connector *creation*. With no VBT, `init_vbt_missing_defaults()` makes every DDI port a connector and sets `DEVICE_TYPE_INTERNAL_CONNECTOR` on port A, which makes port A eDP. `intel_edp_init_connector()` then runs AUX/PPS on DDI A at probe time.
  - This is the upstream iMac20,1 failure. With `i915.disable_display=1` the log still shows `DDI A/PHY A] failed to retrieve link info, disabling eDP`, and "the display just goes blank", meaning the AMD-driven panel. Atharva Tiwari, 2026-01-27: <https://lkml.iu.edu/hypermail/linux/kernel/2601.3/04368.html>
  - Jani Nikula's answer was to ignore the display completely with a DMI `has_no_display()` quirk: <https://lkml.iu.edu/hypermail/linux/kernel/2601.3/05641.html>
  - Ville Syrjälä's objection to that approach is the power concern: *"you won't be able to get deep pkgC states due to the display hardware not going into DC5/6"*: <https://www.mail-archive.com/intel-gfx@lists.freedesktop.org/msg372777.html>
  - The series (v1–v3) is unmerged. 7.2.3's `has_no_display()` still lists only IVB-Q. <https://lore.kernel.org/all/20260203073130.1111-1-atharvatiwarilinuxdev@gmail.com/>
- **The middle path used here:** `i915.vbt_firmware=` takes precedence over OpRegion and ROM (`intel_bios_get_vbt()` tries `firmware_get_vbt()` first).
  - A valid VBT with an empty BDB has no general-definitions block, so it has no child devices.
  - `intel_setup_outputs()` on a DDI platform then runs only `intel_bios_for_each_encoder(display, intel_ddi_init)` over an empty list. The CRT branch is `DISPLAY_VER >= 9 → false`, and `intel_pps_unlock_regs_wa()` returns early for DDI.
  - Result: no connectors, no AUX, no PPS, but the display engine is still initialised, so DC5/DC6 remain possible.
  - `vbt/make-headless-vbt.py` builds that file (70 bytes) and re-checks it against `intel_bios_is_valid_vbt()`. `vbt/headless-vbt.bin` is the output (b2sum starts `2c5c9b56e781…`).
  - If the file cannot be loaded, i915 logs `Requesting VBT firmware … failed` and behaves as with `disable_display` alone.
- The HD-audio component is still registered (`intel_audio_init/register` sit behind `HAS_DISPLAY`, not behind `disable_display`). snd_hda_intel binds to it; see section 4.
- `drm_fb_helper` with no connectors logs `Cannot find any crtc or sizes` and returns `-EAGAIN`, so no `/dev/fbN` is created. Plymouth and fbcon get nothing from i915.

### GuC / HuC on Kaby Lake
- Firmware installed (`linux-firmware-intel 20260810`): `kbl_guc_70.1.1`, `kbl_huc_4.0.0`, `kbl_dmc_ver1_04`. These are exactly what `gt/uc/intel_uc_fw.c` requests for KABYLAKE.
- Default: `uc_expand_default_options()` → `/* Don't enable GuC/HuC on pre-Gen12 */ enable_guc = 0`.
- What HuC is needed for: intel media-driver README: *"HuC firmware is necessary for AVC/HEVC/VP9/AV1 low power encoding bitrate control, including CBR, VBR … APL/KBL: … set `i915.enable_guc=2`"* (<https://github.com/intel/media-driver#known-issues-and-limitations>).
- On KBL (`docs/media_features.md`, "Hardware Encoding, Low Power Encoding (VDEnc/HuC)"), only **AVC** has a VDEnc path, and **HEVC 8-bit is encoded only via PAK+VME shaders (`Es`)**. That path needs no HuC and the Full-Feature driver build. Arch builds Full-Feature by default (`ENABLE_NONFREE_KERNELS` defaults ON, PKGBUILD doesn't override). No 10-bit HEVC encode. Max encode resolution is 4k, so a native 5120×2880 capture cannot be encoded. Omarchy's recorder already caps at 3840×2160.
- So without HuC you still get:
  - H.264 via `EncSlice` (shader + PAK, full CBR/VBR)
  - H.264 low-power with CQP
  - HEVC 8-bit via `EncSlice`

  HuC buys only low-power H.264 with bitrate control.
- `enable_guc=2` implications (7.2.3 source):
  - bit 1 = "HuC load". GuC firmware is loaded only to authenticate HuC. Gen9 keeps execlist submission ("GuC submission is N/A").
  - `i915_param_named_unsafe(enable_guc …)`: setting it **taints the kernel** (`TAINT_USER`, 'U'). That is visible in the amdgpu bug reports Ahmad files.
  - `__uc_init_hw()`: a *present but failing* GuC upload (3 attempts on gen9, `WaEnableGuCBootHashCheckNotSet:skl,bxt,kbl`) returns `-EIO`, which marks the **GT wedged** (no render/encode until reboot). Locked WOPCM registers from an earlier boot are a known way to hit this. It needs its own test boot.

## 2. Device naming, compositor pinning, early boot

### Numbering (prediction, verify on first boot)
- `drm_minor_alloc()` uses `xa_alloc()`, the lowest free index.
- Today's boot log: `simpledrm … on minor 0`, then `amdgpu … on minor 1`. amdgpu allocates its minors in `devm_drm_dev_alloc()` before `aperture_remove_conflicting_pci_devices()` kicks simpledrm, which frees card0.
- i915 loads later from the root fs, so it most likely gets **card0 + renderD129**. AMD stays **card1 + renderD128**, which keeps every "first render node" consumer (ffmpeg default, Strata, the repo's `scripts/vce-*`) on the Radeon.
- That is a side effect, not a contract, hence the udev names.

### udev → `udev/61-imac-dri-names.rules`
- Creates `amd-card`, `amd-render`, `intel-card`, `intel-render`.
- Matches `KERNELS=="0000:01:00.0"` / `"0000:00:02.0"` together with `DRIVERS=="amdgpu"` / `"i915"` on the same parent, and only for `DEVTYPE=drm_minor` (connectors like `card1-DP-1` are skipped).
- Needed because the `by-path` links contain colons. The Hyprland wiki says: *"the colons in the actual card device paths are not usable in the `AQ_DRM_DEVICES` environment variable since colons `:` are used as a separator"* (<https://github.com/hyprwm/hyprland-wiki/blob/main/content/configuring/extra/multi-gpu.md>).

### Hyprland / aquamarine → `hypr/imac-gpu.lua`
- aquamarine 0.15.0 `scanGPUs()` (<https://github.com/hyprwm/aquamarine/blob/v0.15.0/src/backend/drm/DRM.cpp>):
  - `CVarList(explicitGpus, 0, ':', true)` → `std::filesystem::canonical()` on each entry, so symlinks resolve. Only listed devices are used, first = primary. A missing path means *"Explicit device … not found"*, and with no devices Hyprland has no GPU. That is why the snippet is guarded.
  - Unset: boot_vga goes first, but a GPU with more **connected** eDP/LVDS/DSI panels is promoted to primary, and every other KMS device is opened as a secondary GPU.
  - `addDrmCard` is emitted by the session but consumed by nobody, so a late i915 is ignored anyway.
- Omarchy env: Hyprland is Lua-configured. `/usr/share/omarchy/default/hypr/envs.lua` uses `hl.env()`, and the wiki says `hl.env()` sets variables *"before the display server initializes"*. There is no `~/.config/uwsm/env*`. `~/.config/environment.d/50-imac-small-bar.conf` exists, but the session env is simpler to guard in Lua.
- The session chain: SDDM autologin → `omarchy.desktop` → `uwsm start -g -1 -e -D Hyprland hyprland.desktop` → `start-hyprland` → `Hyprland`.
- Don't set `LIBVA_DRIVER_NAME` globally: `va.c` replaces the driver list for **every** display with it (`drivers[0] = strdup(driver)`), which would break radeonsi. libva already maps `i915 → {iHD, i965}` and `amdgpu → radeonsi` (`va/drm/va_drm_utils.c`).

### SDDM greeter → `sddm/` (optional)
- `/etc/sddm.conf.d/10-wayland.conf` (omarchy-settings): `DisplayServer=wayland`, `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`. The greeter is its own Hyprland running as the `sddm` user; there is no X.
- It never reads `~/.config/hypr`. Unpinned, it still takes the boot_vga Radeon as primary (the Intel card has no connected eDP), and only idles the Intel card as a secondary GPU.
- With autologin the greeter appears only after a logout or a GPU-reset recovery. The wrapper plus drop-in pins it anyway, with the same guard.

### Plymouth / early KMS → `mkinitcpio/zz-imac-no-kms-hook.conf`
- Effective HOOKS (Omarchy's `omarchy_hooks.conf` replaces `mkinitcpio.conf`'s): `base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs resume`, with `MODULES=(amdgpu thunderbolt)`.
- The `kms` hook runs `map add_checked_modules '/drivers/char/agp/' '/drivers/gpu/drm/'`, filtered by `autodetect` from `/sys` MODALIAS at **build** time. So any `mkinitcpio`/`limine-mkinitcpio` run on a set_os boot would put i915 into the image the default entry uses too. The fallback image (no autodetect) already contains it.
- Measured with `/usr/bin/mkinitcpio -g` into a scratch dir on today's boot:

  | image | modules | i915.ko | i915 fw files | size |
  |---|---|---|---|---|
  | default HOOKS | 376 | 0 | 0 | 57,797,962 |
  | `-S kms` | identical file list | 0 | 0 | 57,797,962 |
  | `-S autodetect` (fallback-like) | — | 1 | 49 | 226,705,299 |
  | `-S autodetect,kms` | — | 0 | 0 | 98,920,688 |

  amdgpu is present in all four.
- Keeping i915 out also guarantees:
  - amdgpu owns the panel and fbcon first;
  - i915 always finds `vbt_firmware`, which lives on the root fs, not in the initramfs;
  - the boot kernel of a resume never touches the iGPU before the image restore.
- Plymouth's hook adds no GPU drivers itself.

### Existing repo rules
- `configs/udev/90-imac-gpu-reset.rules` fires on `WEDGED=none` for any `card*`. i915 emits only `WEDGED=rebind,bus-reset` (`gt/intel_reset.c`, when wedged), so it won't trigger the AMD recovery. Optional hardening: add `DRIVERS=="amdgpu"`.
- `89-imac-gpu-coredump.rules` is unaffected, because i915 doesn't use devcoredump. Its error state is `/sys/class/drm/card0/error`.
- `scripts/vce-*` hard-code `renderD128`. Switch them to `/dev/dri/amd-render` once the rule is in.

## 3. Choosing the device per application

**libva 2.24.1 has no device-selection variable.** `strings` on `libva.so.2`/`libva-drm.so.2` shows only `LIBVA_DRIVER_NAME`, `LIBVA_DRIVERS_PATH`, `LIBVA_MESSAGING_LEVEL` and `LIBVA_TRACE*`. There is no `LIBVA_DRM_DEVICE`. The application opens the node and hands the fd to `vaGetDisplayDRM()`. `vaGetDisplayWl()` follows the compositor's device, which is AMD.

| App | How it picks | Plan |
|---|---|---|
| ffmpeg 9 | `vaapi_device_create()`: an explicit path, otherwise the **first openable `/dev/dri/renderD128+n`**, optionally filtered by `kernel_driver=` / `vendor_id=` options (<https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/hwcontext_vaapi.c>) | Explicit: `-init_hw_device vaapi=intel:/dev/dri/intel-render` or `vaapi=intel:,kernel_driver=i915`. |
| gpu-screen-recorder 6.1 | No device option (`--help`). The EGL display comes from the monitor's card (`use_monitor_gpu`, KMS capture) or from the Wayland window. Encode uses that EGL device's render node (`src/egl.c`, `gsr_egl_load()`). Omarchy's recorder uses KMS capture (`-w <monitor>`), so it always runs on the Radeon. | **Cannot be moved to Intel as-is.** Experiment only: `OMARCHY_SCREENRECORD_USE_PORTAL=true` path plus `DRI_PRIME=pci-0000_00_02_0` (Mesa renders on Intel; portal dmabufs from AMD must import into i915). Untested. |
| Strata | Spawns `ffmpeg` with `-hwaccel vaapi …`. The binary contains no `/dev/dri`/`renderD` string, so ffmpeg's default is **renderD128 = AMD**. Settings: `video_preview_backend = "vaapi"`. | No knob. Keep it on AMD (VCE fix pending) or software, and ask upstream for a device setting. A PATH `ffmpeg` wrapper is possible but not recommended. |
| Chromium 152 | `VADisplayStateSingleton::PreSandboxInitialization()`: `--hardware-video-device-path=` wins, then `--render-node-override`, else the node matching the active GPU (AMD) (<https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/vaapi/vaapi_wrapper.cc>) | Leave it. Optional test: `--hardware-video-device-path=/dev/dri/intel-render` in `~/.config/chromium-flags.conf`. This moves decode too (cross-GPU frames). |
| Firefox (not installed) | `widget/gtk/DMABufDevice.cpp`: `MOZ_DRM_DEVICE`, else gfx's DRM device | Don't. It moves all DMABuf use, not just video. |

**Decode decision: keep decode on the Radeon for playback. Move a whole
transcode to Intel when the encode is on Intel.**
- Playback frames end up on the Radeon's scanout. Decoding them on the iGPU means system-RAM surfaces crossing PCIe every frame, and Intel tiled modifiers that amdgpu can't import (linear fallbacks).
- For decode→scale→encode jobs (Strata-style previews, ffmpeg transcodes), keeping all three on one device keeps them zero-copy.
- KBL decodes AVC 4k, HEVC 8/10-bit 8k, VP9 8/10-bit 8k, VP8, MPEG-2 and VC-1, with no AV1 (`media_features.md`). So VP9 is the one codec where Intel adds something. Polaris' UVD has no VP9, to be confirmed with `vainfo` on `amd-render`. It is worth a Chromium experiment, not a default.

Examples (after `intel-media-driver` is installed):
```sh
vainfo --display drm --device /dev/dri/intel-render           # expect "Intel iHD driver", H264 EncSlice(+LP), HEVCMain EncSlice
ffmpeg -init_hw_device vaapi=intel:/dev/dri/intel-render -filter_hw_device intel \
  -i in.mp4 -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 8M out.mp4          # sw decode, Intel encode
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/intel-render -hwaccel_output_format vaapi \
  -i in.mp4 -vf 'scale_vaapi=w=1920:h=-2' -c:v hevc_vaapi -qp 24 out.mkv        # all on Intel
ffmpeg ... -c:v h264_vaapi -low_power 1 -rc_mode CQP -qp 23 ...                 # VDEnc; CBR/VBR need HuC (stage 2)
```
`intel_gpu_top` should show the Video engine busy, and `radeontop`/VCE idle.

## 4. Audio

- Today: `card0 = PCH` (00:1f.3, CS8409 at codec 0, patched `snd_hda_codec_cs8409`), `card1 = HDMI` (01:00.1, ATI HDMI at codec 0). `power_save=10`.
- **A new codec on the same PCH link: yes.** On SKL/KBL the iGPU's display-audio codec is a codec on the PCH HD-Audio link, not a separate controller. Once 00:02.0 is visible, `snd_hdac_i915_init()` sees Intel graphics on the same bus (`i915_gfx_present()`/`connectivity_check()`) and binds the i915 audio component. If i915 hasn't bound yet it returns **`-EPROBE_DEFER`, and the whole PCH controller probe is deferred** (`controllers/intel.c`, `azx_probe()`). Consequences:
  - **ALSA indices will likely swap.** The slot is taken with `find_first_zero_bit(probed_devs)` and only marked on success, so the Radeon HDMI controller probes first and becomes card0, and the PCH becomes card1. Nothing local keys on indices: WirePlumber state and rules use `alsa_card.pci-0000_00_1f.3`, `/etc/modprobe.d/imac-headset-mic.conf` uses codec options, and no config uses `hw:0`. Use `hw:PCH` if something ever needs a name.
  - **If i915 fails to bind** (blacklisted, probe failure), the PCH controller never probes, so there are no speakers, headphones or microphone. Never blacklist i915 on a set_os boot. The rollback is the default entry.
  - The CS8409 patch is per-codec (address 0) and unaffected. The Intel HDMI codec would take the `snd-hda-codec-intelhdmi` module (separate from `atihdmi` in 7.x), and while powered it holds i915 display power, which blocks DC states.
- **Guard 1 (primary): `snd_hda_intel.probe_mask=1,1`.** It probes codec slot 0 only, on both controllers, so probe order doesn't matter. Mechanism: `codec_probe_mask` ANDed with `codec_mask` in `common/controller.c`; see also `Documentation/sound/hd-audio/notes.rst`. There are no Intel HDMI routes or sinks and no display-power coupling.
- **Guard 2: `wireplumber/52-imac-no-intel-hdmi.conf`**. `node.disabled` applies to any `alsa_output.pci-0000_00_1f.3.*hdmi*` node. The PCH *device* can't be disabled (that is the speakers). The profile is already pinned by `~/.local/state/wireplumber/default-profile`.

## 5. Packages (not installed; `pacman -Si`, all in **extra**)

| Package | Version | Need |
|---|---|---|
| `intel-media-driver` | 26.2.4 | **Required.** iHD VA driver, "Broadwell+". |
| `libva-utils` | 2.24.0 | **Required** for verification (`vainfo`). |
| `intel-gpu-tools` | 2.5 | Recommended (`intel_gpu_top`). |
| `turbostat` | 7.2.3 | Recommended (package C-states, GFX RC6). |
| `powertop` | 2.16 | Optional. |
| `intel-media-sdk` | 23.2.2 | Optional. "Legacy … (Broadwell to Rocket Lake)", only for ffmpeg `*_qsv` via libvpl (installed). VA-API doesn't need it. |
| `vpl-gpu-rt` | 26.2.4 | **Not for KBL** ("Tiger Lake and newer"). |
| `libva-intel-driver` | 2.4.5 | Skip (legacy i965; libva tries iHD first). |
| `vulkan-intel` | 26.2.2 | Skip for now. Not needed for VA-API encode, and it would add the iGPU to every Vulkan app's device list (ggml/voxtype, browsers). |

Mesa's iris GL driver already ships in `mesa`. `linux-firmware-intel` (GuC/HuC/DMC) is already installed.

## 6. Power measurement

- **Baseline** on the default entry, and again on the test entry, with the same idle desktop, panel on, 5+ minutes settled:
  ```sh
  sudo turbostat --quiet --interval 30 --num_iterations 10 \
       --show PkgWatt,CorWatt,GFXWatt,RAMWatt,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc7,Pkg%pc8,GFX%rc6,GFXMHz
  sudo powertop            # Idle stats: Pkg(HW) C-states; Device stats
  ```
  turbostat finds i915's `/sys/class/drm/cardN/gt/gt0/rc6_residency_ms` on any card (7.2.3 `turbostat.c` loops `card%d`). It loads `msr` itself.
- **iGPU-specific:**
  - `cat /sys/bus/pci/devices/0000:00:02.0/power/runtime_status` should read `suspended` about 10 s after the GPU goes idle. i915 sets autosuspend to 10 000 ms and calls `pm_runtime_allow()` on integrated parts.
  - `sudo cat /sys/kernel/debug/dri/*/i915_dmc_info` (on the i915 one): firmware loaded, and the "DC3 -> DC5" / "DC5 -> DC6" counts must keep climbing at idle.
  - GFX%rc6 should be ≈ 99 % at idle.
  - The kernel log should show `Finished loading DMC firmware i915/kbl_dmc_ver1_04.bin`. If DMC fails, `intel_dmc_init()` keeps a runtime-PM wakeref ("runtime suspend *requires* a working DMC"), so the iGPU never suspends.
- **What to conclude:**
  - The iGPU is fine if GFX%rc6 is high, DC6 is counting, the device runtime-suspends, and PkgWatt/Pkg%pc* are no worse than baseline.
  - Worse package C-states with those three good point elsewhere, for example the Intel HDMI codec holding display power (check that `probe_mask` took).
  - The Radeon on the PEG port (`amdgpu.runpm=0`, lit 5K panel) may already cap the package at PC2/PC3 in the baseline. In that case compare PkgWatt, not C-state names.

## 7. Hibernation

- The current cmdline has `resume=/dev/mapper/root resume_offset=1902559` (swapfile `/swap/swapfile`, via `/etc/limine-entry-tool.d/resume.conf`). However `hibernate.target`, `hybrid-sleep.target`, `suspend-then-hibernate.target` and `suspend.target` are all symlinked to `/dev/null`. **Nothing can hibernate today.**
- Hazard if that changes: an image carries its kernel's view of PCI.
  - **iGPU image, resumed on a default boot (iGPU hidden again):** the restored i915, and the PCH HDA bound to it through the audio component, poke a function that no longer decodes. Expect i915 restore errors or a wedge, and a stuck audio controller.
  - **The reverse:** 00:02.0 is left undriven, which doesn't crash but gives no RC6 until the next boot.
- Guards:
  1. The **test entry gets no `resume=`**, so it never restores a default-boot image.
  2. i915 stays out of the initramfs, so the resuming boot kernel never touches the iGPU.
  3. If hibernation is unmasked while both kinds of boot share one swapfile, install `systemd/imac-igpu-hibernate-guard.conf`. `ExecStartPre` fails `systemd-hibernate.service` whenever 00:02.0 is visible.
  4. Once every boot uses set_os, the topology is the same both ways. Drop the guard and give the entry `resume=` back.

---

## First boot with the iGPU: ordered steps

**A. Prep on the default entry (no reboot, each step is a no-op while the iGPU is hidden)**
1. `sudo pacman -S intel-media-driver libva-utils intel-gpu-tools turbostat` (powertop optional).
2. Install the udev rule: `sudo install -m644 udev/61-imac-dri-names.rules /etc/udev/rules.d/` then `sudo udevadm control --reload && sudo udevadm trigger -s drm`. Check that `ls -l /dev/dri` shows `amd-card → card1` and `amd-render → renderD128`.
3. Install the VBT: `sudo install -Dm644 vbt/headless-vbt.bin /usr/lib/firmware/imac18-3/headless-vbt.bin`.
4. Install the initramfs drop-in: `sudo install -m644 mkinitcpio/zz-imac-no-kms-hook.conf /etc/mkinitcpio.conf.d/`, then `sudo limine-mkinitcpio`. Check that `sudo lsinitcpio -a` on the new image still lists amdgpu and not i915.
5. Install the session pin: copy `hypr/imac-gpu.lua` to `~/.config/hypr/` and add `require("hypr.imac-gpu")` to `hyprland.lua` (inert on this boot). Mirror it in `~/Projects/dotfiles`.
6. Install the WirePlumber guard: copy `wireplumber/52-imac-no-intel-hdmi.conf` to `~/.config/wireplumber/wireplumber.conf.d/` (inert).
7. Record the baseline power numbers (section 6). Run `scripts/igpu-check` for the "before" picture.
8. Create the set_os test entry (`../set-os-loader/`). Keep the known-good entry as the default. Test-entry cmdline = today's default **minus** `resume=… resume_offset=…`, **plus**
   `i915.disable_display=1 i915.vbt_firmware=imac18-3/headless-vbt.bin snd_hda_intel.probe_mask=1,1`.
   If the entry boots a UKI with an embedded `.cmdline`, confirm on the booted system (`cat /proc/cmdline`) that the passed options won.

**B. First boot on the test entry: watch it**
1. Expect the usual splash and the 5K desktop on the Radeon. **If the panel blanks a few seconds after the root fs mounts** (when i915 loads), that is the iMac20,1 failure: hold power, boot the default entry, and note it.
2. Run `scripts/igpu-check` (and `sudo scripts/igpu-check`). It must show:
   - 00:02.0 driver `i915`, AMD `boot_vga=1`
   - `intel-card`/`intel-render` present, with the predicted numbers (card0/renderD129) or not; the links make it irrelevant
   - **no connectors on the Intel card**, which proves the VBT was taken
   - Hyprland's environment contains `AQ_DRM_DEVICES=/dev/dri/amd-card`, and no process other than an explicit encoder holds the Intel nodes
   - the DMC loaded line
   - `snd_hda_intel 0000:00:1f.3: bound 0000:00:02.0 (ops intel_audio_component_bind_ops [i915])`
   - no `Intel Kabylake HDMI` codec in `/proc/asound/card*/codec#*`
   - taint U-bit 0
3. Audio: speakers, headphone jack and mic, plus `wpctl status`. The default sink is still "iMac Audio", and there are no new HDMI sinks on the PCH device.
4. Video: `vainfo` on both nodes, then the ffmpeg examples above while `intel_gpu_top` runs.
5. Power: section 6, compared against the baseline.
6. Recording: `omarchy-capture-screenrecording` still works (on the Radeon). Optionally try the portal + `DRI_PRIME` experiment.
7. Reboot and shut down once each from the test entry. Watch for the known shutdown-splash/VRAM hang and any new Plymouth artefact. i915 creates no fbdev, but Plymouth watches udev for DRM devices.

**C. Stage 2 (a separate boot):** add `i915.enable_guc=2`. Check that the log shows the GuC firmware loaded and HuC authenticated, `vainfo -a` offers CBR/VBR for `VAEntrypointEncSliceLP`, and taint U = 1. If GuC fails (`GuC initialization failed`, GT wedged), drop it again.

**D. Promotion (later, Ahmad's call):** move the options into `modprobe.d/imac-igpu.conf`, make the set_os entry the default, restore `resume=` on it, optionally install the greeter pin, and review section 7.

## Rollback
- Select the default Limine entry. Firmware hides 00:02.0 again, so i915 never binds. The udev lines only match i915/amdgpu, the Lua snippet's guard is false, the VBT file and `probe_mask` are unused (only codec 0 exists on both controllers), and the initramfs drop-in has been shown to build the identical image.
- Full removal: delete `/etc/udev/rules.d/61-imac-dri-names.rules`, `/usr/lib/firmware/imac18-3/`, `/etc/mkinitcpio.conf.d/zz-imac-no-kms-hook.conf` (then `limine-mkinitcpio`), `~/.config/hypr/imac-gpu.lua` plus its `require`, and `~/.config/wireplumber/wireplumber.conf.d/52-imac-no-intel-hdmi.conf`. Optionally `pacman -Rs intel-media-driver libva-utils intel-gpu-tools turbostat`.

## Files here

| File | Target | Status |
|---|---|---|
| `udev/61-imac-dri-names.rules` | `/etc/udev/rules.d/` | draft |
| `hypr/imac-gpu.lua` | `~/.config/hypr/` + `require` | draft |
| `wireplumber/52-imac-no-intel-hdmi.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | draft |
| `modprobe.d/imac-igpu.conf` | `/etc/modprobe.d/` (promotion only; cmdline while testing) | draft |
| `mkinitcpio/zz-imac-no-kms-hook.conf` | `/etc/mkinitcpio.conf.d/` | draft, measured |
| `vbt/make-headless-vbt.py`, `vbt/headless-vbt.bin` | `/usr/lib/firmware/imac18-3/headless-vbt.bin` | draft, source-checked only |
| `systemd/imac-igpu-hibernate-guard.conf` | `systemd-{hibernate,hybrid-sleep,suspend-then-hibernate}.service.d/` | draft, only if hibernation is unmasked |
| `sddm/20-imac-greeter-gpu.conf`, `sddm/imac-greeter-compositor` | `/etc/sddm.conf.d/`, `/usr/local/bin/` | optional draft |
| `scripts/igpu-check` | run in place | read-only |

## Not verified (needs the hardware boot)
- That set_os exposes a sane 00:02.0 on the iMac18,3: stolen memory, no OpRegion VBT expected, and the AMD device stays `boot_vga`.
- That i915 binding cannot disturb the Radeon-driven panel. The empty-VBT path is checked against 7.2.3 source only.
- The card/render numbering prediction.
- That the Intel HDMI codec appears at slot 2, and that `probe_mask` hides it.
- DC5/DC6 residency and the package-C-state outcome.
- GuC/HuC loading on this board.
- Strata's exact ffmpeg arguments (inferred from strings).
- The GSR `DRI_PRIME` portal experiment.
- Chromium's cross-GPU frame handling with `--hardware-video-device-path`.
- No VP9 on Polaris UVD.
- How the UKI treats a passed cmdline.
- `/boot` images were not readable here (root-only); the equivalence was measured on scratch builds from the same config.
