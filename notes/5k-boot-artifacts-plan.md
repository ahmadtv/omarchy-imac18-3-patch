# Plan: fix the two 5K boot-time display artifacts

Written 2026-09-03. Both artifacts are **patch-level gaps**, root-caused from the
boot timeline — not cosmetic quirks to live with, and not userspace misconfiguration.

## Artifact A — skewed Apple logo on warm reboot (not on cold boot)

**Root cause (confirmed).** The patch writes the panel-latch DPCD
`0x4F1 = 1` to wake the slave tile in four code paths (`slave-predetect`,
`source-dpcd`, `training`, `stream-enable`). There is **no teardown anywhere** —
grep for shutdown/`.remove`/suspend/un-wake returns nothing. The woken tile state
therefore survives a warm reboot, and Apple's EFI firmware — which assumes the
factory single-link state — renders its boot logo into a panel configuration it
does not expect. A cold boot power-cycles the panel, which is why the logo is
correct then. The user's warm-vs-cold observation is the diagnostic that proves it.

**Fix.** Add a teardown that restores the pre-boot panel state on shutdown/reboot:
write `0x4F1 = 0` (and/or drop back to a single-tile stream) from amdgpu's
shutdown path (`.shutdown` / `amdgpu_pci_shutdown`) and the module-unload path.

**Risk: low.** The code only runs while the machine is going down, so a mistake
cannot break a running desktop; worst case the logo stays skewed. Still test on
the USB clone first per RULE 2.

## Artifact B — half-black screen at the LUKS password prompt

**Root cause (confirmed).** Boot timeline from `dmesg`:

| t | event |
|---|---|
| 7.7 s | `mode_valid` — connectors enumerated, 5120 mode advertised |
| 18.9 s | `crtc_mode=5120x2880` **but** `stream_timing=2560x2880`, link[0] only |
| 19.03 s | `root wake 0x4F1 stage=slave-predetect` — slave tile finally woken |
| 19.03 s+ | peer stream added, `sync_enabled=1` — genlock latches |

The stitched 5120×2880 mode is exposed to fbcon/Plymouth **before** the slave tile
is woken and genlocked. Anything drawn in that window spans 5120 px while only the
left 2560 px is physically lit → the LUKS prompt appears with the right half black.
The wake is *lazy* (fired by a late connector detect), not done at driver init.

**Fix — two candidate approaches, try in this order:**

1. **Eager wake (preferred).** Perform the slave wake + link-train during amdgpu
   initialisation, before the connector/mode is published, so both tiles are live
   before anything can draw. Closes the window rather than hiding it.
2. **Gate the mode.** Do not advertise the 5120×2880 mode until both streams
   report `sync_enabled=1`; fall back to a single-tile mode until then. Safer but
   causes a visible mode switch mid-boot.

**Risk: medium.** This touches the bring-up ordering of a delicately balanced
stitch. Clone-first testing is mandatory, and `--restore-5k` must be verified
working before starting.

## Artifact C (deferred) — DP-1 phantom output in Hyprland

`hyprctl` lists DP-1 as a disabled connector. It is **functionally correct** — the
kernel drives the panel over both links (`master_link[1]`) and the stitch depends
on it. Do **not** disable it from the compositor; that risks the fused output.
The clean fix is patch-level: mark the slave connector `non-desktop` so compositors
ignore it without powering it down. Cosmetic only — lowest priority.

## Execution order and protocol

1. Verify `imac-patcher --restore-5k` works end-to-end (safety net first).
2. **Artifact A** — smallest, lowest-risk, clearest win. Build, test on clone,
   then SSD. Validate by warm-rebooting and watching the Apple logo.
3. **Artifact B** — approach 1, fall back to approach 2. Validate by watching the
   LUKS prompt across several warm and cold boots.
4. **Artifact C** — only after A and B are stable.
5. Regenerate `patches/imac5k-amdgpu-7.2.2.patch`, update `patches/README.md`,
   and offer both fixes upstream on drm/amd#4455 (the teardown gap in particular
   affects every dual-boot user of this patch, not just this machine).

Each iteration: edit source in `~/.cache/kernel-5k-build/linux-7.1.9`, rebuild the
module (~33 s), install, reboot, observe. `--restore-5k` returns to stock at any point.

## Coordination note

The native-5K work lives in a parallel session. These two fixes extend that patch
stack; regenerate the combined diff so both efforts stay on one artifact rather
than diverging.
