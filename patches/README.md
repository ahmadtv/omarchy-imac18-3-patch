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

The installer applies these in order to pristine kernel source:

- **`imac5k-lean-core-7.2.x.patch`** — the mainline candidate: the panel-ID
  quirk, tile-peer wiring, `0x4F1` latch pulse, slave AUX pre-detect,
  source-table revision, stream-enable latch, root EDID re-read, deterministic
  genlock, the reboot handoff, and a fix so the driver's own latch write is not
  mistaken for a hotplug. Posted upstream in drm/amd#4455. With this alone the
  kernel exposes two proper tiles and a tile-aware compositor (Mutter, KWin)
  stitches them.
- **`imac5k-stitch-layer-7.x.patch`** — erik2's single-display stitch
  (`amdgpu.tiled_stitch`) on top of the core, plus its two boot fixes: an early
  modeset so the disk-password prompt is full width, and a settle-and-resync
  after tiled commits. Needed only for compositors without tile support, i.e.
  Hyprland. Upstream will not take this layer.
- **`imac5k-stitch-hide-slave.patch`** — with the stitch on, the slave tile's
  connector reports disconnected, so compositors and settings panels see one
  display instead of offering the tile as a second output.

```bash
patch -p1 < patches/imac5k-lean-core-7.2.x.patch
patch -p1 < patches/imac5k-stitch-layer-7.x.patch
patch -p1 < patches/imac5k-stitch-hide-slave.patch
```

Audio is separate: **`cs8409-headset-capture.patch`** goes on top of the
jackdanyell CS8409 driver (automatic mic switching, Apple EarPods buttons); the
patcher's `audio` module applies it and DKMS-builds the result.

## Trying a build without risking the working one

```bash
sudo scripts/imac-test-entry stage <known-good-amdgpu.ko.zst>   # current UKI becomes "/Test - 5K boot fixes"
sudo scripts/imac-test-entry promote                            # the test build becomes the default
sudo scripts/imac-test-entry drop                               # remove the test entry
sudo scripts/imac-alt-entry add <name> path/to/amdgpu.ko        # a named entry with its own UKI
sudo scripts/imac-alt-entry list
```

Install the new module, then `stage` it: the image you just built becomes the
test entry and the known-good module goes back into the default, so the default
never runs anything untested. `imac-alt-entry` builds a separate UKI from a
private copy of the module tree instead, for entries that need their own
cmdline (the backlight test). Both refuse a module whose vermagic is not the
running kernel.

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

- Kernel 7.2.3 + this stack, `amdgpu.tiled_stitch=1`, Omarchy/Hyprland.
- Result: genuine 5120×2880 as one display, both tiles HBR2×4, 10-bpc, genlocked,
  seamless under motion, zero GPU faults.
- Silicon limit, unrelated to this patch: YouTube 4K is CPU-decoded (Polaris has
  no VP9/AV1 hardware).
