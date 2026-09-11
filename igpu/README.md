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
1. **i915 headless.** `linux-side/README.md` stage B: `i915.disable_display=1`
   plus the no-outputs VBT, packages installed, stop at once if the panel blanks.
2. **Video on Intel.** `vainfo` on the Intel render node, ffmpeg transcodes,
   power (turbostat) against the default boot, then GuC/HuC on a separate boot.
3. **Promotion** only after the above, and only as Ahmad's call.

Known limits: Omarchy's screen recorder (gpu-screen-recorder) encodes on the
GPU it captures from, so screen recording stays on the Radeon unless a
cross-GPU path works; ffmpeg, Strata (via its ffmpeg) and Chromium can be
pointed at the Intel node. Kaby Lake encodes up to 4K.
