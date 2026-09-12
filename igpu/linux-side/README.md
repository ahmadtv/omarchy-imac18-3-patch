# Headless Intel HD 630 on Linux: the Linux side

What `imac-patcher --apply macos` installs from this directory, and why each piece is there. The EFI side, getting Apple firmware to show 00:02.0 at all, is the kernel's own `set_os` call with iMac18,3 added by `mkinitcpio/imac-setos` (see `../README.md`, stage 2f).

**Goal:** use the HD 630 the way macOS does (`NumFrameBuffer 0`, Quick Sync): render and video only. It never drives a display and is never the compositor's GPU. The Radeon Pro 575 keeps the panel, the desktop and all 3D.

Written against kernel 7.2.3-arch1-3, libva 2.24.1, ffmpeg 9.0.1, Hyprland 0.56.2 / aquamarine 0.15.0, mkinitcpio 41.1, Omarchy 4.0.3.

## What gets installed

| File | Installed as | Why |
|---|---|---|
| `mkinitcpio/imac-setos` | `/etc/initcpio/post/imac-setos` | Adds iMac18,3 to the kernel stub's `set_os` model list in every UKI mkinitcpio builds |
| `mkinitcpio/zz-imac-igpu.conf` | `/etc/mkinitcpio.conf.d/` | i915 first in the initramfs, with the VBT, the SMBus rule and the ACPI table override |
| `vbt/headless-vbt.bin` (from `vbt/make-headless-vbt.py`) | `/usr/lib/firmware/imac18-3/headless-vbt.bin` | A VBT that declares no outputs (section 1) |
| `udev/61-imac-dri-names.rules` | `/etc/udev/rules.d/` | Stable `/dev/dri/{amd,intel}-{card,render}` names (section 2) |
| `udev/62-imac-smbus-acpi.rules` | `/etc/udev/rules.d/` (and the initramfs) | Re-enables the SMBus controller the firmware's backlight method talks through |
| `acpi/make-bcl100` | builds `/etc/initcpio/acpi_override/imac-bcl100.aml` | The firmware's brightness table, extended from 80% to the full range (from the machine's own SSDT; Apple's table is not in this repo) |
| `bin/imac-backlight-nvram` + `systemd/imac-backlight-nvram.service` | `/usr/local/bin/`, `/etc/systemd/system/` | Saves the brightness to NVRAM at shutdown, so the panel comes up at your level from power-on |
| `hypr/imac-gpu.lua` | `~/.config/hypr/` + a `require` in `hyprland.lua` | Keeps Hyprland on the Radeon (section 2) |

Kernel options, in `KERNEL_CMDLINE[default]` of `/etc/default/limine`: `snd_hda_core.gpu_bind=0 i915.disable_display=1 i915.vbt_firmware=imac18-3/headless-vbt.bin module_blacklist=i2c_i801`. Undo everything with `imac-patcher --remove macos`.

`scripts/igpu-check` is a read-only status report (`sudo` adds i915 parameters, DMC and runtime-PM detail).

## 1. i915 with no outputs: why a VBT, not just `disable_display`

- `i915.disable_display=1` only gates connector `detect()` and hotplug polling (`intel_display_device_enabled()`). It does **not** stop connectors being *created*: `DRIVER_MODESET` stays set, and the full display bring-up still runs (power wells, `intel_dmc_init()` loading `i915/kbl_dmc_ver1_04.bin`, DC5/DC6 allowed).
- This iMac's OpRegion (8 KiB, v2.0) has an empty VBT mailbox. With no VBT, `init_vbt_missing_defaults()` makes every DDI port a connector and marks port A internal, so i915 runs eDP AUX/PPS on DDI A at probe. That is the iMac20,1 failure from the 2026 upstream series: with `disable_display=1` the log still shows `DDI A/PHY A] failed to retrieve link info, disabling eDP`, and the Radeon-driven panel went blank (Atharva Tiwari, <https://lkml.iu.edu/hypermail/linux/kernel/2601.3/04368.html>).
  - Jani Nikula's suggestion was a DMI `has_no_display()` quirk (<https://lkml.iu.edu/hypermail/linux/kernel/2601.3/05641.html>); Ville Syrjälä's objection was power, since the display hardware would never reach DC5/6 (<https://www.mail-archive.com/intel-gfx@lists.freedesktop.org/msg372777.html>). The series is unmerged.
- **The middle path used here:** `i915.vbt_firmware=` takes precedence over the OpRegion (`intel_bios_get_vbt()` tries `firmware_get_vbt()` first). A valid VBT with an empty BDB has no child devices, so on a DDI platform `intel_setup_outputs()` iterates an empty encoder list: no connectors, no AUX, no PPS, while the display engine is still initialised. Measured here: DC3→DC5 transitions at idle, the HD 630 runtime-suspends to D3hot, and package pc3 reaches 38% of idle against 0% when the firmware hides the iGPU (pc6/pc7 stay 0 either way; the Radeon caps them).
  - `vbt/make-headless-vbt.py` builds the 70-byte file and checks it against `intel_bios_is_valid_vbt()`. If the file can't be loaded, i915 logs `Requesting VBT firmware … failed` and falls back to `disable_display` alone.
- With no connectors, `drm_fb_helper` logs `Cannot find any crtc or sizes` and creates no `/dev/fbN`, so Plymouth and fbcon get nothing from i915.
- `vbt_firmware` is an "unsafe" parameter, so the kernel is tainted `U` — expected.
- The upstream question — a quirk so iMacs need no `vbt_firmware` — is drm/i915#17042.

**GuC/HuC** stay off (the gen9 default). HuC would only add low-power H.264 with CBR/VBR (`i915.enable_guc=2`, which also taints and can wedge the GT if the GuC upload fails). Without it Kaby Lake still encodes H.264 (EncSlice, full rate control, plus low-power CQP) and 8-bit HEVC, up to 4K.

## 2. Device names and the compositor

- DRM minors are handed out in probe order. i915 loads first from the initramfs, so it takes **card1 + renderD128** and amdgpu gets **card2 + renderD129**. Apps that open "the first render node" (ffmpeg's default, Strata's previews, GStreamer) therefore get Quick Sync with no setting — the macOS split, by default.
- `udev/61-imac-dri-names.rules` gives both GPUs stable, colon-free names, keyed on PCI address and bound driver. The `by-path` links won't do: `AQ_DRM_DEVICES` uses `:` as its separator.
- Hyprland/aquamarine opens every KMS device unless told otherwise, and a GPU with more connected internal panels can be promoted to primary. `hypr/imac-gpu.lua` sets `AQ_DRM_DEVICES=/dev/dri/amd-card`, guarded: only when 00:02.0 exists and the link is there, because an entry that doesn't exist leaves aquamarine with no GPU at all. Wayland, GL and Vulkan clients follow the compositor, so they stay on the Radeon.
- Never set `LIBVA_DRIVER_NAME` globally: libva applies it to every display (`drivers[0] = driver`) and would break radeonsi. libva already maps i915 → iHD and amdgpu → radeonsi.
- `vulkan-intel` is deliberately not installed: it would put the iGPU in every Vulkan app's device list (ggml/voxtype, browsers).

| App | Device |
|---|---|
| ffmpeg, Strata, GStreamer | Intel by default (first render node); `-init_hw_device vaapi=amd:/dev/dri/amd-render` for the Radeon |
| gpu-screen-recorder (Omarchy's recorder) | Always the Radeon: it encodes on the GPU it captures from |
| OBS, Kdenlive | Pick the VA-API device in their settings |
| Chromium | Its active GPU (Radeon). `--hardware-video-device-path=/dev/dri/intel-render` makes Intel decode, but the Radeon can't import the frames — leave it |

## 3. Audio

On Kaby Lake the iGPU's display-audio codec sits on the PCH HD-Audio link. Once 00:02.0 is visible, `snd_hdac_i915_init()` wants to bind the i915 audio component and returns `-EPROBE_DEFER` until i915 has bound — deferring the whole PCH controller, i.e. the speakers and mics. `snd_hda_core.gpu_bind=0` skips that binding: the PCH controller probes as before (still ALSA card 0, CS8409 at codec 0), and no Intel HDMI codec appears.

## Rejected along the way

Kept out of the repo, recorded here so they aren't re-tried:

- **i915 kept out of the initramfs** (dropping the `kms` hook): i915 then loads late from the root fs and takes the second render node, so nothing uses Quick Sync by default.
- **`snd_hda_intel.probe_mask=1,1`** to hide the Intel HDMI codec: replaced by `gpu_bind=0`, which also removes the probe deferral. A WirePlumber rule disabling Intel HDMI nodes turned out moot, since no such codec appears.
- **Options in `/etc/modprobe.d/`**: the kernel command line keeps them next to the boot entry that needs them.
- **A hibernation guard** for images crossing set_os and non-set_os boots: moot once every boot uses set_os, and hibernation is masked.
- **Pinning the SDDM greeter** to the Radeon: unpinned, it already takes the boot_vga Radeon as primary.
- **`MOZ_DRM_DEVICE` for Firefox**: it moves all DMABuf use, not just video.
