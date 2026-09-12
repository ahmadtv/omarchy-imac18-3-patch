# Intel HD 630 on the iMac18,3 -- experimental

The iMac18,3 has an Intel HD 630 (8086:5912) next to the Radeon Pro 575. Apple
firmware hides it unless the loader announces macOS through the Apple `set_os`
EFI protocol; macOS runs it headless (0 framebuffers) and sends Apple's video
framework -- H.264/HEVC encode and decode -- to it. Nobody has published i915 on
an iMac18,x under Linux; the only upstream attempt (an iMac20,1, Jan-Feb 2026,
unmerged) blanked the Radeon-driven panel once i915 probed a display it made up.

Goal: the same split as macOS. The Radeon keeps the display, the compositor
and everything else; the Intel chip does video (VA-API via intel-media-driver)
and nothing else. Nothing here is installed or wired into `imac-patcher`.

| Directory | What |
|---|---|
| `set-os-loader/` | `imac-set-os.efi`, a 4.6 KB EFI app built from source here: calls `set_os` exactly like the kernel's `apple_set_os()`, then chainloads a UKI with the rest of its options. QEMU-tested (9/9), not yet run on the iMac. |
| `linux-side/` | Drafts for when the iGPU exists: headless i915 options, a no-outputs VBT, stable `/dev/dri` names, Hyprland pinned to the Radeon, WirePlumber and hibernation guards, `scripts/igpu-check`. |

## Order of work

Each stage is its own non-default Limine entry; the default is never touched.

0. **Discovery boot.** Loader + today's cmdline without `resume=`, plus
   `module_blacklist=i915 snd_hda_core.gpu_bind=0`. The second option is not
   optional: once the iGPU is visible, snd_hda_intel waits for i915 forever
   (`-EPROBE_DEFER` in `snd_hdac_i915_init`) and the speakers and mics vanish.
   Questions: does `00:02.0 8086:5912` appear, does the 5K desktop stay normal,
   does the OpRegion carry a VBT (`/sys/kernel/debug/dri/*/i915_opregion` needs
   i915, so dump ASLS memory instead). Nothing loads a driver for the iGPU.
   **Result 2026-09-12: it works.** `ImacSetOsStatus` read `set_os v3: vendor ok,
   version 0x800000000000000E` -- set_os_vendor alone was enough; the version call
   returned EFI_NOT_FOUND and did not matter. `00:02.0 [8086:5912]` HD 630, subsystem
   Apple 0180, BARs 16M + 256M, D0. vgaarb first marked it boot VGA, then the Radeon
   overrode it (`boot_vga`: Radeon 1, Intel 0); fb0 and the 5K desktop stayed on
   amdgpu. HD-audio came up normally with `snd_hda_core.gpu_bind=0` (speakers, jack,
   ATI HDMI). No new kernel warnings beyond `Module i915 is blacklisted`.
1. **i915 headless.** `linux-side/README.md` stage B: `i915.disable_display=1`
   plus the no-outputs VBT, packages installed, stop at once if the panel blanks.
   Staged 2026-09-12 as "Test - iGPU i915 headless": stage 0's cmdline without the
   blacklist, plus `i915.disable_display=1 i915.vbt_firmware=imac18-3/headless-vbt.bin`.
   `snd_hda_core.gpu_bind=0` stays (instead of the draft's `probe_mask`): HD-audio then
   never waits for i915, so a failing i915 cannot take the speakers with it.
   **Result 2026-09-12: it works.** i915 bound 00:02.0, DMC 1.4 loaded, zero connectors
   ("Cannot find any crtc or sizes"), 5K desktop on the Radeon, audio unaffected,
   `/dev/dri/intel-render` = renderD129, AMD kept card1/renderD128, Hyprland got
   `AQ_DRM_DEVICES=/dev/dri/amd-card`, the iGPU runtime-suspends to D3hot when idle.
   vainfo (iHD 26.2.4): H.264 encode (normal + low-power), HEVC 8- and 10-bit encode,
   VP8/JPEG/MPEG-2 encode; decode H.264, HEVC 8/10, VP9 8/10, VP8, VC-1, JPEG.

   `scripts/video-bench`, identical lossless sources, same bitrate targets:

   | Test | Intel HD 630 | Radeon Pro 575 | x264/x265 (CPU) |
   |---|---|---|---|
   | H.264 1080p60 8M | **295 fps**, VMAF 96.12 at 5.1 Mb/s | 82 fps, 96.12 at 7.9 Mb/s | 176 fps veryfast |
   | H.264 1440p60 12M | **185 fps**, 96.03 at 7.6 Mb/s | 49 fps, 96.10 at 12.1 Mb/s | 111 fps |
   | H.264 2160p30 20M | **86 fps**, 90.05 | 22 fps, 90.15 | 34 fps |
   | HEVC 1080p60 5M | 133 fps, **VMAF 95.34** at 3.7 Mb/s | 122 fps, 89.89 at 4.9 Mb/s | 50 fps |
   | HEVC 2160p30 12M | 32 fps, 89.81 | **37 fps**, 89.83 | 10 fps |
   | Decode 4K H.264 / HEVC / VP9 | **192 / 223 / 313 fps** | 111 / 82 / none | 208 / 94 / 165 |

   Intel is 3.6-3.8x faster at H.264 and reaches the same quality with 35-37% fewer
   bits at 1080p/1440p; it wins HEVC quality at 1080p by a wide margin; the Radeon is
   slightly faster at 4K HEVC. Only Intel handles 1440p60 and 4K30 H.264 in real time.
   Intel's higher CPU% reflects frame upload at 3-4x the frame rate. Power not
   measured (RAPL is root-only).
2. **Video on Intel.** `vainfo` on the Intel render node, ffmpeg transcodes,
   power (turbostat) against the default boot, then GuC/HuC on a separate boot.
2b. **Intel as the default video GPU (stage 2), result 2026-09-12: it works.** Own UKI
   built from `linux-side/mkinitcpio/zz-imac-igpu.conf` (i915 before amdgpu, VBT in the
   initramfs). i915 registers first: renderD128/card1 = HD 630, renderD129/card2 = Radeon;
   the Radeon still takes fb0 and the 5K desktop. With no device named, ffmpeg's VAAPI
   picks iHD (1080p60 H.264 at 273 fps) and GStreamer's default `vah264enc`/`vah264dec`/
   `vah265enc`/`vavp9dec` are the Intel ones (the Radeon's stay as `varenderD129*`). Every
   graphics client (Hyprland, Xwayland, terminals, quickshell, voxtype, portal) holds only
   amdgpu fds. Differences vs the default boot: `acpi_video0` behaves as on the default boot
   (absent on stages 0-1); i801_smbus logs "BIOS is accessing SMBus registers" and inhibits
   itself (only the DIMM SPD EEPROMs sit behind it). Caveat: `mkinitcpio -c <file>` skips
   `/etc/mkinitcpio.conf.d`; build test images from a merged config and diff them.
2c. **Side effects of macOS mode, 2026-09-12.**
   - **Brightness works.** With set_os the firmware's `acpi_video0` actually dims the panel
     (verified by eye: 79 -> 15 -> 79); on the default boot it accepts writes and does
     nothing. Omarchy's `omarchy-hw-display` already picks `acpi_video0`, so the brightness
     keys/OSD need no change. Supersedes the `acpi_backlight=native` test entry.
   - **SMBus:** in macOS mode the firmware leaves the SMBus controller disabled and drives
     the backlight over it from ACPI; systemd-backlight's restore at boot collided with
     i2c_i801's probe ("BIOS is accessing SMBus registers ... inhibited"). The firmware owns
     that bus here and only the DIMM SPD EEPROMs sit on it, so the set_os entries boot with
     `module_blacklist=i2c_i801`. **But** i801 was also what enabled the controller: blacklisted,
     00:1f.4 stays `COMMAND=0000` and brightness silently stops working (writes land, nothing
     dims; enabling I/O decode by hand made it dim again). So `udev/62-imac-smbus-acpi.rules`
     sets the device's sysfs `enable` (no driver, no competing access), and ships inside the
     initramfs so it runs before systemd-backlight restores the saved level.
   - **Chromium** decodes H.264/HEVC on the Radeon (the GPU drawing its window; UVD 27% busy
     on the Cursor clip) and VP9/AV1 on the CPU (4K VP9 ~1.1 cores). Pointing it at Intel
     (`--hardware-video-device-path`) makes the HD 630 decode, but the Radeon cannot import
     the frames (`eglCreateImage failed`, `Unable to initialize binding from pixmap`), so
     leave Chromium on its default.
   - **Strata** previews landed on the HD 630 with no setting (its sandboxed ffmpeg took
     renderD128).
2d. **Permanent setup (2026-09-12, in progress).** Power first: `scripts/idle-power`, 60 s idle,
   default boot 12.0 W package / pc3 0% vs stage 2 11.7 W / pc3 38% (pc6/pc7 0% on both: the
   Radeon, not the iGPU, caps package C-states; i915 powering the HD 630 off lets the package
   go deeper than the firmware-hidden state). Then:
   - `imac-set-os.efi` with no LoadOptions boots `\EFI\Linux\omarchy_linux.efi` with its
     embedded cmdline, so the menu entry needs no cmdline and kernel updates change nothing.
   - `/etc/mkinitcpio.conf.d/zz-imac-igpu.conf` (i915 first, VBT in the initramfs).
   - The four options go into `KERNEL_CMDLINE[default]` in `/etc/default/limine` -- it is
     loaded last and assigns the whole line, so a `limine-entry-tool.d` drop-in has no effect.
   - `limine-entry-tool --add-efi "Omarchy (macOS mode)" /boot/EFI/imac-set-os/imac-set-os.efi`
     writes a managed entry (no hash pin), and `default_entry:` points at it.
   - `configs/udev/90-imac-gpu-reset.rules` now matches `DRIVERS=="amdgpu"` only.
2e. **Full brightness range + boot brightness (2026-09-12).** macOS drives the backlight
   controller over 0..65535 (AppleMCCSControlCello via `\_SB.PNLF`; AppleBacklightDisplay
   `brightness` 0-65535, max 500 nits; DarwinDumped iMac18,3), while the firmware's ACPI `_BCL`
   stops at level 80 and `BSET` sends 655*level -- Linux's 100% was 80% (~400 nits), the same
   'Boot Camp is dimmer' gap owners report. `linux-side/acpi/make-bcl100` rewrites only `ABCL`
   to levels 4..100 from the machine's own table (acpi_override hook; Apple's table is not in
   this repo). The brightness jump mid-splash is systemd-backlight restoring after the root is
   unlocked; the firmware lights the panel from NVRAM `backlight-level` (u16 LE, same scale,
   currently 0xFFFF), which macOS keeps current. `linux-side/bin/imac-backlight-nvram` +
   `systemd/imac-backlight-nvram.service` write it at shutdown, only when it changed (the
   approach kernel reviewers accepted for Atharva Tiwari's 2026 series; flash wear).
3. **Promotion** only after the above, and only as Ahmad's call.

Known limits: Omarchy's screen recorder (gpu-screen-recorder) encodes on the
GPU it captures from, so screen recording stays on the Radeon unless a
cross-GPU path works; ffmpeg, Strata (via its ffmpeg) and Chromium can be
pointed at the Intel node. Kaby Lake encodes up to 4K.

## Routing video to the Intel chip: what already exists (researched 2026-09-11)

There is no system-wide router on Linux: libva has no device-selection variable
(requests intel/libva#221 from 2018 and #752 from 2023 are open, no code), and
switcheroo / "launch on dedicated GPU" only set `DRI_PRIME`, which does not reach
iHD. On Wayland libva opens the compositor's main device, so every client gets
the Radeon unless the app picks a device itself. Existing building blocks:

| Scope | Mechanism |
|---|---|
| All GStreamer apps | `GST_PLUGIN_FEATURE_RANK=varenderD129h264dec:MAX,...` (va plugin names extra devices after their render node) |
| ffmpeg | `-init_hw_device vaapi=va:,kernel_driver=i915`; `h264_qsv` picks Intel on its own (needs intel-media-sdk) |
| Chromium / Electron | `--hardware-video-device-path=/dev/dri/by-path/pci-0000:00:02.0-render` in `~/.config/chromium-flags.conf` / `electron*-flags.conf` |
| Firefox | `MOZ_DRM_DEVICE=` |
| mpv | `--hwdec=vaapi-copy --vaapi-device=...` (device option only applies to copy mode) |
| OBS, Kdenlive | device setting in the encoder / render preset (Kdenlive's shipped "VAAPI Intel" preset assumes renderD128) |
| Screen recording | OBS with its VAAPI device set to the Intel node (AMD captures and scales, only the output frame crosses); wf-recorder `-d` (CPU copy of full frames, fine at low res/fps); a GStreamer portal pipeline (zero CPU copy, needs a test that LINEAR dma-bufs cross from AMD to Intel) |

Not routable today: gpu-screen-recorder (Omarchy's recorder; its FAQ says capture
and encode must be on the same GPU, and it unsets `DRI_PRIME`), Strata's preview
(tries render nodes in order inside a `--clearenv` sandbox, so AMD first).
Playback caveat: decoding on Intel for an AMD-displayed player needs a frame copy
(Firefox closed cross-GPU decode as WONTFIX). Kaby Lake H.264 tops out near 4096x2304,
so 5K captures must be scaled before encoding on either chip.

If per-app settings are not enough, the smallest thing to build is a VA driver
shim on the nvidia-vaapi-driver model (`NVD_GPU`): selected with
`LIBVA_DRIVER_NAME`, it opens the Intel node and hands off to `iHD_drv_video.so`.
None exists yet.
