# iMac 5K patch — how to use, and the rules that keep you safe

`imac5k-amdgpu-7.2.2.patch` is the complete native-5K stack for the iMac18,3's
internal tiled panel, as one diff against **kernel 7.2.2** source:

1. **Second-tile wake** — DPCD `0x4F1` root-latch pulse that powers up the
   hidden right-tile DP link (community work from
   [drm/amd#4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) /
   [mcirsta/linux-imac-5k](https://github.com/mcirsta/linux-imac-5k), rebased
   to 7.2.2 by taprobane99)
2. **Single-display stitch** — presents both 2560×2880 tiles to userspace as
   ONE 5120×2880 output, so Hyprland (or any compositor) works unmodified
   (erik2's commits, hand-ported to 7.2.2)
3. **Genlock fix** — enables the per-frame CRTC reset for the Apple tile pair
   so both halves scan in lockstep (`sync_enabled=1`) and the panel is
   seamless under motion (mr_projects; fills a standing mainline TODO)

Boot parameter once installed: `amdgpu.tiled_stitch=1`

## Installing without a second kernel

```bash
sudo ../scripts/patch-imac5k-amdgpu.sh          # build + swap the amdgpu module
sudo ../scripts/patch-imac5k-amdgpu.sh --restore  # undo everything
```

The script rebuilds **only the amdgpu module** for your *running* kernel and
swaps it in (stock module backed up first). Re-run it after a kernel update.

Since 2026-09-07 the installer builds the **lean pair** (`imac5k-lean-core-7.2.x.patch`
+ `imac5k-stitch-layer-7.x.patch`). The verbose stack (full-stack patch + the
five `5k-*.patch` increments) is still available: `IMAC5K_STACK=verbose sudo
../scripts/patch-imac5k-amdgpu.sh`.

## Lean mainline candidate: `imac5k-lean-core-7.2.x.patch`

A human-edited strip-down of taprobane99's base patch (no stitch layer), now
carrying everything core-side that this machine runs:
**+770 added lines / 13 files** (his base: +1631 / 12, and it lacks the last two items).

- the panel-ID quirk table, tile-peer wiring, `0x4F1` latch pulse, slave AUX
  pre-detect, source-table revision, stream-enable latch, root EDID re-read
  (his mechanism, logging and its plumbing removed, `dc/core/dc.c` no-op
  refactor dropped);
- **deterministic genlock**: both tile streams flagged before the master pick
  (the earlier one-sided form was a coin flip per modeset);
- **clean firmware handoff at reboot**: `amdgpu_pci_shutdown()` runs
  `drm_atomic_helper_shutdown()` for a tiled panel with a going-down flag set
  (wake paths and tiled re-detects become no-ops), the slave's stream-off
  clears `0x4F1` / `0x310` / `0x10A`, and the root eDP panel is powered off
  and held for T12. Without this Apple's firmware draws a skewed boot logo on
  every warm reboot (patch-caused: a stock warm reboot is straight).

Compiles clean; applies with zero rejects to pristine 7.1.9 and 7.2.2. Kernel
exposes two proper tiles; the compositor stitches (Mutter today, KWin in
progress). Posted upstream in drm/amd#4455.

## Stitch layer on top of it: `imac5k-stitch-layer-7.x.patch`

erik2's single-display stitch (`amdgpu.tiled_stitch`, slave tile non-desktop)
as a layer that applies **on top of** the lean core, plus the two
stitch-specific boot fixes: the early modeset before Plymouth (full-width
disk-password prompt) and the settle-and-resync after tiled commits.
**+1315 added lines / 10 files.** Needed only for compositors without tile
support — Hyprland. Upstream will not take this layer.

```bash
patch -p1 < patches/imac5k-lean-core-7.2.x.patch     # core (+ genlock + reboot handoff)
patch -p1 < patches/imac5k-stitch-layer-7.x.patch    # Hyprland stitch (+ early modeset, resync)
```

Applies cleanly on pristine 7.1.9 and 7.2.2 after the core. One fix over
erik2's original: the saved tile-group id buffer is 9 bytes like DRM's
(`drm_tile_group.group_data[9]`); it was 8. erik2's own logging is still in
this layer; leaning it is a later pass.

**Equivalence:** core + layer is the same feature set as the verbose stack
(`imac5k-amdgpu-7.2.2.patch` + the five `5k-*.patch` increments), minus the
core-side logging.

**Status: promoted to the default on 2026-09-07** after two boots from its own
entry (full-width password prompt, seam fine, straight Apple logo on the warm
reboot out of it). The verbose module is kept as the `/Test - 5K-verbose-fallback`
entry and as `amdgpu.ko.zst.prev-promote` beside the installed module; drop
both once the lean default has run for a few days.

## Booting any build from its own entry: `scripts/imac-alt-entry`

```bash
sudo scripts/imac-alt-entry add  5K-lean path/to/amdgpu.ko   # new UKI + Limine entry
sudo scripts/imac-alt-entry list
sudo scripts/imac-alt-entry drop 5K-lean
```

Builds a separate UKI from a private copy of the running kernel's module tree
(`mkinitcpio --moduleroot`), so `/usr/lib/modules`, the default UKI and any
other test entry are untouched. Refuses a module whose vermagic is not the
running kernel, and verifies the module inside the built UKI is the one given.
The entry is hash-pinned like the others.

## The rules

- **RULE 1 — version gate.** The patch is verified against kernel **7.1.x and 7.2.x source** (same diff applies to both).
  The script refuses to run on any other series, because the amdgpu display
  code changes between kernel versions and a mis-applied patch means a broken
  GPU module. When Arch/Omarchy moves to 7.3+, the patch must be **re-ported
  by a human first** — re-running the script is not enough. (Check
  `uname -r` starts with 7.1 or 7.2 before expecting anything.)

- **RULE 2 — test on the USB clone first.** Never run this for the first time
  on your only install. The project keeps a full bootable clone on a USB
  stick for exactly this. If a build ever produces a bad module you get
  software rendering until `--restore` — recoverable, but not fun to discover
  on your daily machine.

- **RULE 3 — the vermagic must match.** The script verifies the built
  kernelrelease equals `uname -r` and refuses otherwise. If it ever refuses,
  that's it working as designed — don't force it.

- **RULE 4 — this is a bridge, not the destination.** The endgame is
  upstreaming (tracked in drm/amd#4455, where the iMac18,3 result and the
  genlock fix have been posted). Once merged into mainline, stock kernels
  will do all of this and these patches retire.

## Known good configuration (verified 2026-09-02, iMac18,3)

- Kernel 7.2.2 + this patch, `amdgpu.tiled_stitch=1`, Omarchy/Hyprland
- Result: genuine 5120×2880, both tiles HBR2×4, 10-bpc, `sync_enabled=1`,
  seamless under motion, zero GPU faults
- Expected quirks: GNOME-keyring popup on a cloned system (benign), YouTube
  4K is CPU-decoded (Polaris has no VP9/AV1 hardware — a silicon limit,
  unrelated to this patch)
