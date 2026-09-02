# HANDOFF — native 5K on the iMac18,3: what was done, current state, next steps

Written 2026-09-02. For any future session (human or AI) picking this up.

## The headline

**Native, genlocked, seamless 5120×2880 is working on this iMac18,3 under
Omarchy/Hyprland** — the first confirmed on this model under Linux, verified
by eye (seamless under motion) and by logs (`sync_enabled=1`, both tiles
HBR2×4, 10-bpc, zero GPU faults). It currently runs from a USB-stick test
clone; the main SSD is still stock (4K fallback) pending one system update.

## How it works (3-layer patch stack, all in the amdgpu module)

1. **Wake**: the panel is two 2560×2880 tiles on two physical links; firmware
   leaves the second link dead for non-Apple OSes. Writing `1` to vendor DPCD
   register `0x4F1` on the eDP root wakes it (reverse-engineered from the
   Windows driver's `EnableSecondaryTileIfRequired`). eDP EDID then flips
   from "root-compat" `APP 0xAE11` to tile identity `0xAE12`.
2. **Stitch**: erik2's kernel-side commits present the tile pair as ONE
   5120×2880 output (synthesized EDID, slave hidden, one fb split across two
   streams) — this is what makes Hyprland work unmodified. Param:
   `amdgpu.tiled_stitch=1`.
3. **Genlock** (novel fix from this project): mainline never enables per-frame
   CRTC sync (a literal TODO in `dm_enable_per_frame_crtc_master_sync()`), so
   the tiles free-ran → black screen/modeset loop. Setting
   `triggered_crtc_reset.enabled` for the Apple slave tile makes
   `enable_timing_multisync()` program the DCE 11.2 GSL genlock →
   `sync_enabled=1` → panel latches → seamless.

## Repo artifacts (all in ahmadtv/omarchy-imac18-3, pushed)

- `patches/imac5k-amdgpu-7.2.2.patch` — the full stack as one clean diff vs
  pristine kernel 7.2.2 (verified applies). ~3.9k lines.
- `patches/README.md` — usage + safety rules (version gate, test on clone).
- `scripts/patch-imac5k-amdgpu.sh` — **no-second-kernel installer**: rebuilds
  only the amdgpu module for the running kernel, swaps it in with a stock
  backup, `--restore` to undo, adds the boot param, rebuilds initramfs,
  refuses cleanly on a non-7.2.x kernel or on a vermagic mismatch.
  NOT yet run end-to-end — test on the USB clone first.
- `notes/5k-display-investigation.md` — full technical record and dead ends.
- `notes/genlock-fix.patch` + `notes/issue-4455-comment.md` (+ `.html` rich
  version) — the upstream contribution. The comment was posted to
  drm/amd#4455 by the user (2026-09-02, needs a re-paste in Markdown mode —
  the first paste got escaped by GitLab's rich-text editor; attach
  `genlock-fix.patch` to it).

## Machine state

- **Main SSD (daily Omarchy)**: 100% stock. Kernel 7.1.9, 4K fallback
  (`video=eDP-1:3840x2160@60e`), untouched by all of this. Leftovers:
  `~/.cache/kernel-5k-build/` (~25GB of source trees/builds) and
  `/etc/default/limine.backup*` files — inert, deletable.
- **USB stick (SanDisk 28.7GB, "IMAC 5K TEST")**: full bootable clone (no
  Dropbox, unencrypted) with the working 5K kernel `7.2.2-imac5k-hypr`.
  Limine menu: Normal desktop / TEST B full-Hyprland 5K (the good one) /
  TEST B-TTY / TEST A. Keep as recovery + reference.
- Working build tree with everything applied:
  `~/.cache/kernel-5k-build/linux-7.2.2` (pristine copy in `pristine/`).

## The path to 5K on the main SSD (next session's job)

Arch core **already ships `linux 7.2.2.arch1-1`** (since 2026-08-31) — the
exact series the patch targets. So NO porting is needed:

1. `sudo pacman -Syu` (brings the SSD to kernel 7.2.2.arch1-1) + reboot
2. Optional but recommended: run `scripts/patch-imac5k-amdgpu.sh` **on the
   USB clone first** (update the clone, run script, verify 5K)
3. Run it on the SSD, reboot → native seamless 5K on the daily system
4. Keep the 4K `video=` parameter REMOVED on the 5K setup (script does not
   remove it — do it manually in `/etc/default/limine` when switching, then
   `limine-mkinitcpio` + sync the 3 limine.conf copies per README)

Note the script was hardened but never executed end-to-end; expect possible
small fixes on first run (it fails safe).

## When Omarchy moves past 7.2.x

The patch will stop applying (kernel display code churn; 7.3 already known to
need re-porting upstream). Process: take `patches/imac5k-amdgpu-7.2.2.patch`,
apply to the new kernel source, fix rejects (this session's port 7.0→7.2 had
only 4 rejected hunks — expect similar), regenerate, bump the version gate in
the script. Or better: check drm/amd#4455 — ports may already exist there
(taprobane99 actively maintains them), and the endgame is mainlining.

## Known limitations / quirks

- Audio DKMS (`snd_hda_macbookpro`) did not build for the custom kernel on
  the stick — revisit when installing on the SSD (needs headers for the
  running kernel; on stock Arch 7.2.2 + linux-headers it should just build).
- YouTube 4K = CPU decode (Polaris has no VP9/AV1 silicon). H.264/HEVC are
  hardware-decoded; consider VA-API setup + enhanced-h264ify.
- Keyring popup on the clone = benign clone artifact.
- The 5K boot shows a stretched left tile during early boot (pre-stitch) —
  cosmetic, known upstream.

## Credits

Community: mforce2 (wake/RE + base kernel), erik2 (stitch), taprobane99
(7.2.2 port + testing), agd5f/AMD (guidance). This project: first iMac18,3
validation + the genlock fix (posted upstream as mr_projects).
