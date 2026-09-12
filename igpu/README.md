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
2. **Video on Intel.** `vainfo` on the Intel render node, ffmpeg transcodes,
   power (turbostat) against the default boot, then GuC/HuC on a separate boot.
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
