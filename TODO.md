# TODO

Open items for the iMac18,3 patch. Root causes are recorded here so nobody has
to re-derive them.

## Display — two boot artifacts (5K only)

Both root-caused and **fixed in `patches/5k-boot-artifacts.patch`**; the fixes are
built and installed but not yet confirmed on a reboot. Confirm, then move this
section to a changelog.

### Skewed Apple logo on warm reboot (cold boot is fine)

The patch writes the panel-latch DPCD `0x4F1 = 1` to wake the slave tile in four
code paths, and **never tears it down** — there is no shutdown hook, `.remove`,
or suspend handler anywhere in the diff. The woken state therefore survives a
warm reboot, and Apple's firmware — which assumes the factory single-link state —
draws its boot logo into a panel configuration it doesn't expect. A cold boot
power-cycles the panel, which is why it looks correct then.

**Fix, implemented:** `link_apple_5k_root_panel_latch_clear()` writes `0x4F1 = 0`,
called from `amdgpu_pci_shutdown()` (reboot/poweroff, while AUX still works) and
from `amdgpu_dm_fini()` (module unload, so `--remove 5k` also leaves the panel
in the state the firmware expects). Low risk — only runs as the device goes down.

### Half-dark panel at the disk-encryption password prompt

An earlier note here claimed the 5120 mode goes live ~130 ms before the slave
tile wakes. **That was wrong.** From the boot log, the wake is early and fine —
`root wake 0x4F1 stage=slave-predetect` fires at 5.702 s, *before* the stitched
mode is published at 5.908 s. The real gap is elsewhere:

| t | event |
|---|---|
| 5.702 s | slave tile woken (`stage=slave-predetect`) |
| 5.908 s | `TILED_STITCH: exposed only stitched mode 5120x2880 on eDP-1` |
| 5.911 s | `fbcon: amdgpudrmfb (fb0) is primary` + `Deferring console take-over` |
| 5.93–6.84 s | thunderbolt / nvme / usb-storage / sdhci probing |
| **7.069 s** | `added peer slave-tile stream` — **first atomic modeset** |
| 7.10–7.12 s | slave link trained, `stream-enable latch 0x4F1` |

The slave tile only gets a DC stream during an atomic modeset (the stitch block
in `amdgpu_dm_atomic_check`), and `drm_client_setup()`'s initial fbdev config
deliberately stops short of committing one — `__drm_fb_helper_initial_config_and_unlock()`
probes, sets up the crtcs and calls `register_framebuffer()`, then leaves the
commit to a later hotplug or to fbcon taking over the console. With `quiet splash`
fbcon defers take-over, so that first commit landed **1.16 s** after fb0 went
live. For that whole window the panel presents the full-width stitched mode
while only the root tile scans out — long enough to cover the password prompt,
which Plymouth draws across all 5120 px (the initramfs carries `plymouth` and
`encrypt` hooks via `omarchy_hooks.conf`).

**Fix, implemented:** after `drm_client_setup()`, if this device drives a stitched
tile panel, issue a second `drm_client_dev_hotplug()`. That takes the
`dev->fb_helper` path, which *does* commit, so the peer tile stream is created
during probe instead of whenever something else happens to trigger a modeset.

### DP-1 phantom output (cosmetic, low priority)

`hyprctl` lists DP-1 as a disabled connector. It is functionally correct — the
kernel drives the panel over both links (`master_link[1]`) and the stitch depends
on it. **Do not disable it from the compositor**; that risks the fused output.
Clean fix is patch-level: mark the slave connector `non-desktop` so compositors
ignore it without powering it down.

## GPU video encode (VCE) hang

Hardware encode via VAAPI can hang the GPU: `ring vce0 timeout` → full GPU reset →
`VRAM is lost` → the Wayland session dies. Seen from both an ffmpeg transcode
(file-manager preview pipeline) and `gpu-screen-recorder`.

Ruled out: macroblock alignment, sandboxing/app version, file corruption. Hardware
*decode* of the same file is fine. RADV exposes no `VK_KHR_video_encode*` on
Polaris, so VCE is the only encode silicon — there is no alternate API.

Leads, in order:
1. **Mesa radeonsi encode path** — Mesa builds the VCE command stream, so this may
   be a driver bug rather than firmware. Bisect encode parameters (rate control,
   GOP/IDR, reference frames, slice config, dimensions) against the reproducer.
2. **Kernel `VCE VM mode`** — boot log says VCE runs in VM mode, which has a
   history of hang bugs on Polaris. Check `vce_v3_0.c` for the gating.
3. **Blast-radius reduction** — per-ring recovery instead of full-chip reset; and
   GL robustness in Hyprland/aquamarine so a reset doesn't kill the session.

Blunt fallback that works by construction: `amdgpu.ip_block_mask=0xfffffeff`
masks out VCE entirely — no hardware encode, hang impossible.

**Test safely:** reproduce from `multi-user.target` over SSH, not from a desktop
session, so a GPU reset costs nothing. Capture the devcoredump at
`/sys/class/drm/card*/device/devcoredump/data` on the first controlled repro.

## Hardware not yet covered

| Item | State |
|---|---|
| Wi-Fi `clm_blob` | Confirmed missing (`no clm_blob available`) → limited channels |
| Backlight | `acpi_video0` exists, pinned at max — needs a functional test |
| Ambient light sensor | Exposed by applesmc (`light`) — unused; could drive auto-brightness |
| SD card reader | `sdhci-pci` bound — untested (needs a card) |
| HDMI audio | 7 devices present — untested |
| Built-in Ethernet | Driver up, `NO-CARRIER` — untested (needs a cable) |
| Bluetooth | Controller powered — pairing untested |

## Housekeeping

- Upload `.github/social-preview.png` in GitHub Settings → Social preview
  (no API for this; must be done in the web UI).
- `\EFI\BOOT\BOOTX64.EFI` on this ESP is a *copy of the UKI*, not the Limine
  binary. It was found 2 days stale after a module rebuild — the firmware taking
  that fallback path would have booted the previous initramfs with the previous
  amdgpu module. `imac-patcher` already synced it; `patch-imac5k-amdgpu.sh` now
  does too. Anything that rebuilds the UKI must refresh it.

## Boot chain on this machine

Three EFI system partitions exist, but only one belongs to Omarchy:

| Partition | Disk | Contents |
|---|---|---|
| `nvme0n1p1` (2 GB, `OMARCHY`) | internal WD Blue SN5000 | Limine — Omarchy's own, stock |
| `sdb1` (200 MB, `EFI`) | USB "My Passport" | OpenCore (`EFI/OC/OpenCore.efi`), for macOS |
| `sdc1` (200 MB, `EFI`) | USB "WDC WD20NMVW" | Empty; same filesystem UUID as sdb1, i.e. a clone |

Firmware `BootOrder` is `0001,0080,0081` — `Boot0001 Omarchy` points at
`\EFI\limine\limine_x64.efi` and is first; the two `Mac OS X` entries follow.

### Non-stock: the Limine fallback bypass

Stock Omarchy sets `ENABLE_LIMINE_FALLBACK=yes` (see
`/etc/limine-entry-tool.d/omarchy-defaults.conf`), and `limine-install` acts on
it by placing **Limine** at `\EFI\BOOT\BOOTX64.EFI`.

On this machine that file is a copy of the UKI instead, with the real Limine
renamed `BOOTX64.LIMINE.EFI.unused`. Timestamps date the change: Limine was
written to both locations on 2026-08-28 12:29 (install), and `BOOTX64.UKI.BACKUP`
— a 75 MB UKI — appeared 2026-08-30 17:01, during the black-screen
troubleshooting. It was done to work around a "no config found" failure.

**Consequence:** booting via the ESP's default path (which the Mac's startup
picker uses when you select the EFI volume) shows *no menu at all* — a UKI has
none — and boots straight into whatever that copy holds. That is why a chosen
boot entry can appear to be ignored.

Confirmed by the owner from the two observed routes:

| Route | Lands on | Menu? |
|---|---|---|
| Alt at startup → "EFI" disk | `\EFI\BOOT\BOOTX64.EFI` (was a UKI copy) | none — boots straight in |
| No Alt → OpenCore → Omarchy | `\EFI\limine\limine_x64.efi` via `OpenLinuxBoot.efi` | Limine menu |

**Fixed 2026-09-05:** `BOOTX64.LIMINE.EFI.unused` restored as `BOOTX64.EFI`, so
both routes now reach Limine. The UKI copy is kept as `BOOTX64.UKI-bypass.backup`
until this is confirmed on hardware. The original "no config found" was most
likely the stale-copy bug below; `/boot/EFI/BOOT/limine.conf` now exists and is
in sync beside the binary.

Note the hook guard: `objcopy --only-section=X` exits 0 even when section X is
absent, so testing its exit status classifies *every* PE binary as a UKI — the
first version of the sync hook cheerfully overwrote Limine with a kernel image.
Extract and check for actual bytes instead.

### Fixed: shadowing limine.conf copies (root cause of the invisible snapshot)

There is exactly **one** limine.conf: `/boot/limine.conf`. An earlier belief in
this repo — that the ESP "carries three copies that must be kept in sync" — was
wrong, and was itself the bug.

Limine >= 10.3.0 loads the **first** config in its search order, so a copy at
`EFI/limine/` or `EFI/BOOT/` silently overrides the canonical one that
`limine-mkinitcpio` and `limine-snapper-sync` maintain. `limine-install` detects
these and says to delete them (see `check_limine_config_conflicts()`).

This project's own scripts created them — `imac-patcher`, the 5K installer and
`imac-test-entry` each copied `/boot/limine.conf` into both locations. The cost
showed up on 2026-09-05: a snapshot created at 18:58 appeared in `snapper list`
and in `/boot/limine.conf`, but the boot menu was reading a shadow copy from the
previous day and never showed it.

**Fixed:** the copies are removed (archived under
`/boot/limine-conf-shadow-backup/`), all three scripts now delete shadows
instead of creating them, and `scripts/95-limine-esp-hygiene` in
`/etc/boot/hooks/post.d/` removes any that reappear. Verified by recreating a
shadow and watching the hook delete it.

### A trap worth remembering

`objcopy -O binary --only-section=X file out` **exits 0 even when section X does
not exist** — it simply writes nothing. Testing its exit status to decide "is
this a UKI?" classifies every PE binary as one. The first version of the hygiene
hook did exactly that and overwrote the freshly restored Limine binary with a
74 MB kernel image on its next run. Extract and test for actual bytes instead.

The same mistake was latent in `imac-patcher`'s `verify_cmdline()`, which read
the embedded cmdline from the EFI fallback; once that path is stock Limine there
is no `.cmdline` there at all. It now reads the UKI directly.

## What a clean install actually needs

None of the boot repairs above. A fresh Omarchy install puts Limine at both
`\EFI\limine\limine_x64.efi` and `\EFI\BOOT\BOOTX64.EFI` (Omarchy sets
`ENABLE_LIMINE_FALLBACK=yes`) with a single `/boot/limine.conf`, so the menu
appears whichever route the firmware takes — with or without macOS or OpenCore
in the picture.

Both faults on this machine were self-inflicted: the UKI-over-fallback bypass
added by hand on 2026-08-30, and the shadow configs added by this repo's own
scripts. That is why the `boot` module *detects and repairs* rather than
assuming: on a healthy machine it reports `applied` and changes nothing.

## Fixed: skewed desktop after login (genlock lost at 8-bpc)

Distinct from the two boot artifacts above, and the one that actually bit in
daily use: after login the seam sheared, intermittently, on the *unmodified* 5K
build.

Cause, from the boot log: the panel comes up genlocked at 10-bpc, and the
compositor's own modeset then re-creates the streams at 8-bpc and the slave tile
loses sync:

| t | state |
|---|---|
| 24.9 s | peer stream added, `sync_enabled=0` |
| 29.3 s | both streams `sync_enabled=1`, `color_depth=10-bpc` — genlocked |
| 30.7 s | compositor modeset, `color_depth=8-bpc` |
| 31.4 s | slave `sync_enabled=0` — genlock gone, never recovers |

Two tiles scanning out of phase is what reads as "skewed". The mode is correct
5120x2880 throughout; only the sync is lost.

**Fix:** pin the compositor to 10-bit. In `~/.config/hypr/monitors.lua`:

```lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2,
             cm = "dp3", bitdepth = 10 })
```

Verified live with `hyprctl reload`, no reboot: `currentFormat` went
`XRGB8888` -> `XRGB2101010` and both tile streams returned to
`sync_enabled=1`, stable on re-check. Shipped in `configs/monitors.lua`.

Still unexplained: *why* the 8-bpc path fails to re-establish sync, when the
same code genlocks fine at 10-bpc. `dm_enable_per_frame_crtc_master_sync()` is
the place to look — see `patches/genlock-fix.patch`. Pinning 10-bit is a
workaround, not a root-cause fix, though on a 10-bit-capable P3 panel it is
what you want anyway.

## Considered and rejected

**Fan curve daemon.** Measured 85 °C with the fan at its 1200 RPM minimum and
concluded the SMC never ramps. That was wrong: later sampling under sustained
load showed it holding ~1500–1700 RPM, well above minimum. It does respond — it
just doesn't track temperature closely, and 85–96 °C is uncomfortable but not
dangerous on a chip that throttles at 100 °C. The daemon also caused audible
noise during ordinary work. Removed; the SMC has fan control.

If revisiting: establish the problem first — watch `sensors` and
`/sys/devices/platform/applesmc.768/fan1_input` under sustained load for several
minutes and confirm the fan genuinely stays pinned while temperatures climb.
