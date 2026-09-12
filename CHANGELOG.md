# Changelog

What changed for someone running the patcher, newest first. Small fixes count. The commit history has the detail.

## 2026-09-12

- **Screen recordings at full speed** (new `record` module). The Radeon encodes 4K at only ~29 fps, so Omarchy's 4K recordings came out sped up, shorter than their audio, and slow to stop (sometimes "force-killed"). The Screenrecord menu now records at 2560×1440, exactly half of 5K, at a real 60 fps.
- **The patcher no longer risks locking your account.** It asks for your sudo password only when run in a terminal. Run from anything else (a widget, a script), each unanswered sudo prompt counted as a failed login, and ten in a row lock the account for ten minutes.
- **macOS mode is now the normal boot entry.** The kernel's own boot code tells the firmware "macOS is starting" (iMac18,3 added to its model list by an initramfs hook), so there is no separate EFI app and no extra menu entry: one "Omarchy > linux" entry, with or without the OpenCore USB.
- **Intel Quick Sync and working brightness** (new `macos` module): the hidden Intel HD 630 appears and becomes the default for video (H.264 about 3.7× faster than the Radeon, plus VP9 and HEVC 10-bit); the brightness slider works over the panel's full range; the panel comes up at your saved brightness from power-on.
- **`wifi` module retired.** Omarchy now ships the same Broadcom handshake fix for every Mac (omacom/omarchy#6652). Its "remove" would have deleted Omarchy's copy.
- The patcher's status shows macOS mode correctly without sudo; applying no longer shows the boot module as "n/a".
- The GPU-reset test script finds the Radeon's debug directory when the Intel GPU is exposed.
- Docs match the current setup; one-off investigation tools moved out of the repo.

## 2026-09-11

- **Screen recording and H.264 export no longer hang the GPU.** Backport of AMD's fix for the VCE encoder hang that every Polaris card has had since kernel 7.1.6 (drm/amd#5595).
- **A GPU hang now recovers** (new `gpureset` module plus two amdgpu fixes, reported as drm/amd#5810): a fresh desktop about five seconds later instead of a frozen machine, with a text message during the handoff.
- **One display in settings panels.** With the stitch on, the second tile reports disconnected, so Omarchy's display panel no longer offers it as a second output.

## 2026-09-10

- Speaker EQ parked (see `TODO.md`); the jack-aware audio panel moved to its own place.
