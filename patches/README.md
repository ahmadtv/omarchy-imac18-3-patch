# iMac 5K patch — how it works, and the rules that keep you safe

The native-5K stack for the iMac18,3's internal tiled panel. Three layers, all
inside the `amdgpu` module:

1. **Second-tile wake** — a DPCD `0x4F1` root-latch pulse that powers up the
   hidden right-tile DP link (community work from
   [drm/amd#4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) /
   [mcirsta/linux-imac-5k](https://github.com/mcirsta/linux-imac-5k), rebased to
   7.2.x by taprobane99).
2. **Single-display stitch** — presents both 2560×2880 tiles to userspace as ONE
   5120×2880 output, so a compositor without tile support (Hyprland) works
   unmodified (erik2's commits, hand-ported).
3. **Genlock** — enables the per-frame CRTC reset for the Apple tile pair so both
   halves scan in lockstep (`sync_enabled=1`) and the panel is seamless under
   motion. This fills a standing mainline TODO and is this project's own
   contribution.

Plus a clean firmware handoff at reboot (atomic shutdown, slave registers
cleared, panel powered off before the handoff) so Apple's firmware doesn't draw
a skewed logo on a warm reboot.

Boot parameter once installed: `amdgpu.tiled_stitch=1`

## Install without a second kernel

```bash
sudo ../scripts/patch-imac5k-amdgpu.sh                  # build + swap the amdgpu module
sudo ../scripts/patch-imac5k-amdgpu.sh --kernel latest  # build for a kernel you have not booted yet
sudo ../scripts/patch-imac5k-amdgpu.sh --restore        # undo everything
```

The script rebuilds **only the amdgpu module** and swaps it in, backing up the
stock module first. It downloads the matching kernel source from kernel.org
itself — you supply nothing.

A kernel update reverts you to stock, so re-run it after one. `--kernel` lets
that happen *before* the reboot: the new kernel's headers and module tree are
already on disk, so the patched module can be built and installed for it while
you are still on the old kernel, and 5K works on its first boot. The old
kernel keeps its own patched module, so it remains a working fallback.

The build is reproducible: run in `--build-only` mode from a pristine tarball in
an empty directory, it produces a module with the same srcversion as a normal
install.

## The patch files

Two forms of the same fix ship here; the installer builds the **lean pair** by
default.

- **`imac5k-lean-core-7.2.x.patch`** — the mainline candidate: taprobane99's
  mechanism reworked down to the panel-ID quirk, tile-peer wiring, `0x4F1` latch
  pulse, slave AUX pre-detect, source-table revision, stream-enable latch, root
  EDID re-read, deterministic genlock, the reboot handoff, and a fix so the
  driver's own latch write is not mistaken for a hotplug (no self-inflicted
  re-detects). Compiles clean and applies with zero rejects to pristine 7.1.9 and
  7.2.2. Posted upstream in drm/amd#4455. With this alone the kernel exposes two
  proper tiles and a tile-aware compositor (Mutter, KWin) stitches them.

- **`imac5k-stitch-layer-7.x.patch`** — erik2's single-display stitch
  (`amdgpu.tiled_stitch`, slave tile marked non-desktop) as a layer **on top of**
  the lean core, plus the two stitch-specific boot fixes (an early modeset before
  Plymouth for a full-width disk-password prompt, and a settle-and-resync after
  tiled commits). Needed only for compositors without tile support, i.e.
  Hyprland. Upstream will not take this layer.

```bash
patch -p1 < patches/imac5k-lean-core-7.2.x.patch     # core (+ genlock + reboot handoff)
patch -p1 < patches/imac5k-stitch-layer-7.x.patch    # Hyprland stitch (+ early modeset, resync)
```

The older monolithic **`imac5k-amdgpu-7.2.2.patch`** plus the five `5k-*.patch`
increments are the same feature set with the core-side debug logging left in.
Select it with `IMAC5K_STACK=verbose sudo ../scripts/patch-imac5k-amdgpu.sh`.

### iMac Pro (iMacPro1,1): Vega 64X, DCE 12

The lean pair on its own leaves the iMac Pro's panel stretched 2x: the second
tile trains but never locks video, and the panel scales the one tile it sees
across the whole display. Four small patches on top of the lean pair fix it,
verified on iMacPro1,1 / Radeon Pro Vega 64X, kernel 7.1.8. Each is conditional
so the iMac18,3 (Polaris, DCE 11.2) build is unaffected:

- **`imacpro-slave-dp-panel-mode.patch`** — the root cause. `dp_get_panel_mode()`
  gives the second tile `DP_PANEL_MODE_EDP`, which sets the alternate scrambler
  reset bit in DPCD `0x10A`. The iMac Pro panel's second tile does not accept it:
  the link trains (training patterns are unscrambled) but SINK_STATUS `0x205`
  stays `00`. Captured from the same panel brought up by Apple's firmware:
  `0x10A = 00`, `0x205 = 01`. Toggling that one bit on a working panel breaks and
  restores 5K reversibly. Keyed on the panel ID (`APP 0xAE1D` / `0xAE1E`); the
  iMac18,3 panel keeps eDP panel mode.
- **`dce120-enable-crtc-reset.patch`** — DCE 12's timing generator never wired
  `.enable_crtc_reset`, so the per-frame CRTC reset that genlocks the tiles could
  not be armed on Vega. Adds it, selecting GSL group 0 as the trigger source.
  DCE 12 only by construction.
- **`dce12-multisync-master-first.patch`** — `enable_timing_multisync()` hands the
  hwseq only the slave pipes, but the DCE hwseq takes its GSL master from entry 0
  and arms entries 1..n. With no master, the armed slave waits for a trigger that
  never comes (`GSL: Timeout on reset trigger!`). Puts the master first, on
  `DCE_VERSION_12_0` only.
- **`dce110-genlock-master-from-pipe0.patch`** — when entry 0 is the master, derive
  `gsl_master` from its TG instance instead of the hardcoded `0` (as
  `dce110_enable_timing_synchronization()` already does), and skip a missing
  `enable_crtc_reset`. With a slaves-only list nothing changes.

Hyprland must enable the panel at 10 bpc (`bitdepth = 10` in `monitors.lua`).
On the iMac18,3 depth is cosmetic. On the iMac Pro the tile pair latches only when
the stream is brought up at the panel's native 10 bpc. The kernel does that by
itself (max bpc defaults to 16, so DC picks 10) but Hyprland starting at its
default 8 bpc then leaves the second tile unlocked and the display stretched.

Only the 5K module has been tried on the iMac Pro; the patcher's hardware gate
still names the iMac18,3, so run the installer directly or pass `--force`.

## Booting a build from its own entry: `scripts/imac-alt-entry`

```bash
sudo scripts/imac-alt-entry add  5K-lean path/to/amdgpu.ko   # new UKI + Limine entry
sudo scripts/imac-alt-entry list
sudo scripts/imac-alt-entry drop 5K-lean
```

Builds a separate UKI from a private copy of the running kernel's module tree, so
`/usr/lib/modules`, the default UKI and any other entry are untouched. Refuses a
module whose vermagic is not the running kernel, and verifies the module inside
the built UKI is the one given. Test a new build here first — the default entry
stays known-good.

## The rules

- **Version gate.** The patch is verified against kernel **7.1.x and 7.2.x
  source** (the same diff applies to both). The script refuses any other series,
  because the amdgpu display code changes between versions and a mis-applied
  patch means a broken GPU module. Moving to 7.3+ needs a human re-port first —
  re-running the script is not enough.

- **Try a new build safely.** A new amdgpu build never has to replace the working
  one to be tested: boot it from its own `imac-alt-entry`, or keep a spare
  bootable install to try it on first. A bad module means software rendering
  until `--restore` — recoverable, but not what you want to discover on your only
  machine.

- **The vermagic must match.** The script verifies the built kernelrelease equals
  the kernel it is building for — the running one, or the `--kernel` target — and
  refuses otherwise. If it refuses, that is it working as designed.

- **This is a bridge, not the destination.** The endgame is upstreaming (tracked
  in drm/amd#4455). Once merged, stock kernels do all of this and these patches
  retire.

## Known-good configuration

- Kernel 7.2.2 + this patch, `amdgpu.tiled_stitch=1`, Omarchy/Hyprland.
- Result: genuine 5120×2880, both tiles HBR2×4, 10-bpc, `sync_enabled=1`, seamless
  under motion, zero GPU faults.
- Silicon limit, unrelated to this patch: YouTube 4K is CPU-decoded (Polaris has
  no VP9/AV1 hardware).
