# TODO

Open items for the iMac18,3 patch. Root causes are recorded here so nobody has
to re-derive them.

## Display — two boot artifacts (5K only)

**Patch layout (2026-09-06):** the boot-artifact work is split by confidence.
`patches/5k-early-modeset.patch` (half-dark password prompt, confirmed on
hardware) is applied by the installer and is what `Omarchy → linux` runs.
`patches/5k-genlock-settle-resync.patch` and `patches/5k-latch-clear.patch`
(skewed Apple logo) were promoted to the default on 2026-09-06 after a captured
teardown and a straight logo. `patches/5k-latch-clear-going-down-only.patch`
(promoted the same evening) restricts the latch clear to the reboot path; the
installer applies all five on top of the main patch. The default's module is
also kept at `~/.cache/kernel-5k-build/amdgpu.ko.zst.latch-going-down`. The `Test - 5K boot fixes` entry is gone; `Test - 5K-lean` belongs
to the lean-patch work and stays. A copy of the
default's module is kept at `~/.cache/kernel-5k-build/amdgpu.ko.zst.early-modeset`
for `imac-test-entry stage`.

Also observed: `limine-mkinitcpio` **preserved** both hand-added test entries,
`default_entry` and `timeout` across a regeneration (installer run, 2026-09-06),
so the "a regeneration drops the test entry" caveat in `imac-test-entry` is
weaker than stated.

Both root-caused. The password-prompt one is fixed and shipped; the Apple-logo one is
still open — see the patch layout note above.

### Skewed Apple logo on warm reboot (cold boot is fine)

The patch writes the panel-latch DPCD `0x4F1 = 1` to wake the slave tile in four
code paths, and **never tears it down** — there is no shutdown hook, `.remove`,
or suspend handler anywhere in the diff. The woken state therefore survives a
warm reboot, and Apple's firmware — which assumes the factory single-link state —
draws its boot logo into a panel configuration it doesn't expect. A cold boot
power-cycles the panel, which is why it looks correct then.

**Fix, second attempt (in the test entry now):** mirror the enable path.
`dp_write_tiled_stream_disable_latch()` writes `0x4F1 = 0` on root and slave
from `link_set_dpms_off()`, after `blank_stream()` and before `disable_link()`
— the stream is already dark, so nothing on screen can skew, and AUX is still
up. Every modeset then leaves the panel exactly as a cold boot found it; the
existing wake/train/enable-latch sequence brings it back. On reboot the
suspend-path display teardown runs this naturally.

**Why the mirror alone was not enough (measured, 2026-09-05):** over
`/dev/drm_dp_aux0` the clear takes effect instantly — root and slave both read
back `00` — but the panel raises HPD-RX and the detect path rewrites `01` within
2–10 ms (`detect connection ... reason=2` followed by `root wake 0x4F1`). At
reboot the stream-off runs before IRQs are suspended, so that interrupt wins.
`dc.apple_5k_going_down`, set from `amdgpu_pci_shutdown()` before teardown,
turns both wake paths into no-ops so the clear is the last word. In the test
entry. **Tested once, 2026-09-06: the Apple logo was still skewed** after a
warm reboot out of the test build (build identity confirmed from the
`stream-disable latch` lines that boot logged — not from the early-boot marker,
which that boot's truncated journal had lost).

Two readings remain, and reasoning cannot separate them: the clear did not run
in the final teardown (which happens after journald is gone, so it has never
been observed), or clearing the latch is not enough. To settle it, `ramoops` is
armed on the test entry only: `memmap=1M$0xa6b000000 ramoops.mem_address=…
ramoops.console_size=0x80000 ignore_loglevel` on its cmdline, plus
`/etc/systemd/system/ramoops-test.service` (conditional on that cmdline) to
load the module. After the next warm reboot out of the test entry,
`/sys/fs/pstore/console-ramoops-0` should hold the previous kernel's last
messages, including the teardown. Secure Boot is off, so `systemd-stub` honours
Limine's cmdline.

**Capture attempt 2026-09-06, lost:** the boot after the warm reboot landed on
`Omarchy → linux` (no `memmap` reservation, ramoops never loaded), so the
reserved region was reused and the teardown log with it. The owner also
reported the capture boot as "numbers on black" — that was `ignore_loglevel`
spraying the kernel log over the console — and a sheared desktop after login
(the intermittent genlock loss, not specific to that build). On request the
experimental entry was dropped and the test entry recreated as an exact clone
of `Omarchy → linux`; the harness is removed. The latch-clear work stays in
`patches/5k-latch-clear.patch` for whoever picks it up.

**Control experiment, run 2026-09-06:** warm reboot out of `Snapshots › 2`
(stock amdgpu, 4K fallback): Apple logo **straight but soft** — the firmware
fell back to single-link cleanly. After a 5K session it skews. So the patch is
the cause, and the state left behind is more than `0x4F1`: a shutdown clear of
that latch alone (with the wake paths gated) did not help. Prime remaining
suspect is the vendor source-table write at DPCD 0x310 on the slave link, which
stock never touches. Next step is evidence, not another guess: a silent kmsg
dump into reserved RAM at reboot is now armed on the default cmdline
(`printk.always_kmsg_dump=1` + ramoops; `/etc/default/limine`), readable from
`/sys/fs/pstore/dmesg-ramoops-*` on the following boot.

Gotcha found the hard way (first capture reboot came back empty): `ramoops`
refuses kmsg dumps above its `max_reason`, which defaults to OOPS (2); a
reboot dumps with reason SHUTDOWN (4). It needs `ramoops.max_reason=4` as well
as `printk.always_kmsg_dump=1`. Both are now on the cmdline. This kernel has
no `CONFIG_PSTORE_PMSG`, so there is no marker channel to test RAM survival
separately -- an empty dump on the next boot means the firmware does not
preserve that RAM across a warm reboot.

**Captured, 2026-09-06 20:24 (`evidence/shutdown-kmsg-2026-09-06.log`):** the
ramoops dump of the previous kernel's final messages — and it settles it. At
reboot **the display is never turned off.** The last commits (7 s before
reboot, the shutdown splash) still carry both streams; there is no
stream-disable, no zero-stream commit, nothing from the DM between the final
unmounts and the reboot. The very last thing the driver does — 80 ms before
`reboot: Restarting system` — is an HPD-RX re-detect of the slave that writes
the wake latch again (`root wake 0x4F1 stage=slave-predetect`, then
`stage=source-dpcd`). Apple's firmware therefore inherits a live, latched,
dual-tile panel. Every latch-clear attempt hung off the stream-disable path,
which simply does not run on this reboot path — so none of them ever executed
where it mattered.

**Fix, in the test entry:** `amdgpu_pci_shutdown()` now calls
`drm_atomic_helper_shutdown()` for the tiled panel (what i915 does in its
shutdown hook), with the going-down guard set first. That disables every CRTC
through a normal atomic commit, which runs the stream-disable latch clear, and
the re-detect can no longer re-wake the tile. Folded into
`patches/5k-latch-clear.patch`. The next dump will show whether it ran.

**Captured again, 20:38 (`evidence/shutdown-kmsg-2026-09-06-b.log`), from the
test build with the display shutdown:** it works as designed. `atomic-disable`
runs at 83.00 s, `stream-disable latch 0x4F1=0` at 83.08 s (status OK on both
links), then the HPD-RX re-detect fires as before — but with the wake paths
gated it finds the slave's AUX **dead for 300 ms** and gives up (`slave AUX
poll failed`, then the DP fallback candidates fail too), i.e. the tile stayed
asleep. Reboot at 84.86 s. So the panel is handed to the firmware with the
latch cleared and the second tile down — the state every earlier attempt was
aiming for and never reached. Cost: ~1.7 s of futile AUX polling at shutdown,
trimmable by also gating the pre-detect poll once the logo result is in.

**Captured 21:16 (`evidence/shutdown-kmsg-2026-09-06-f.log`), corrected test
build — and the owner saw a straight Apple logo.** Teardown in order:
`atomic-disable` (116.31 s) → `going-down slave reset 0x310=00 00 00, 0x10A=00`
(116.38, both OK) → `stream-disable latch 0x4F1=0` (116.38, OK on both links)
→ `going-down root eDP power off, holding T12` (116.45) → S5 at 117.16 →
reboot. No re-detect, no wake: the `link_detect()` gate held. One sample so
far; the fix is in the test entry (`patches/5k-latch-clear.patch`), default
untouched, pending the owner's decision to promote.

Two earlier attempts on the same day failed for reasons that had nothing to do
with the panel: capture -d showed the pre-detect poll skip made the shutdown
re-detect drop the slave sink before its stream disable ran, and the test
cycle before that ran the untouched default. The lesson is in the evidence
directory: never judge a shutdown-path change without the capture.

**Resolved 2026-09-06 (evening) — the jump and the black flashes were not
the re-sync.** A build that measured both tiles' scan positions before every
re-sync found them aligned on all 35 checks (0 re-syncs run), so the analysis
below was chasing the wrong thing. The real cause was the latch-clear patch
itself: `dp_write_tiled_stream_disable_latch()` cleared the second tile's wake
latch (0x4F1) on every ordinary stream-off, not only when going down. Each
latch write toggles that tile's HPD line; DM answers an HPD pulse with a full
`dc_link_detect(DETECT_REASON_HPD)`, which drops the sink, sets
`link_state_valid = false` and sends userspace a hotplug event, so the next
commit fails `pipe_need_reprogram()` for the slave pipe, tears the tile down,
re-trains it — and writes the latch again. Per boot: 30–40 slave re-detects,
36 re-trainings, 19 stream-offs (the pre-logo-fix builds had 4, 14 and none).
Fix: the whole disable-latch write is now gated on `apple_5k_going_down`
(`patches/5k-latch-clear-going-down-only.patch`). Verified boot: 4 re-detects,
11 trainings, 0 stream-offs, root link never re-trained, native 5K at 10-bit;
the owner reports the flashes and the pre-reboot skew are gone. The
measured-resync build was dropped as inert. Lesson: `journalctl -k` for older
boots is the cheapest regression test — compare the same counters across
builds before theorising.

Leftover, cosmetic: the warm-reboot Apple logo is straight but slightly soft.
After the teardown the firmware sees a single-tile panel (second tile asleep,
its registers reset) and draws the logo on one tile stretched across the
glass; a cold boot draws it crisp. Making the firmware draw at 5K would mean
handing it a panel with both tiles awake, which is exactly the state that
produced the skew — so any attempt has to find a state the firmware treats as
"fresh dual-tile" rather than "already running". Untested; not worth a
regression in the straight logo.

**Original analysis (superseded, kept for the record):** right after the
disk-encryption password is accepted the whole prompt box visibly shifts,
goes black, then the 5K desktop comes up clean. The boot log shows a burst of fbdev/Plymouth commits at ~14.7 s each
followed by `manual-trigger-sync` — the 250 ms settle-and-resync doing its
one-shot CRTC alignment on a live picture. It is the re-sync working, seen.
Timeline from the boot after the successful capture: the journal's first
15 s are lost (no `Linux version` line), so nothing *before* the prompt is
observable; *after* Enter there are **7 modesets and 4 delayed re-syncs in
90 ms** (14.67–14.76 s) ending exactly at the unlock (`first mount of
filesystem` at 14.76 s) — Plymouth's dialog transition and the fbdev/DRM
master handoff, each modeset blanking and each re-sync visibly realigning the
tiles. Then the compositor's own modesets at 18–21 s bring the clean 5K
desktop. On a single-tile panel this is a blink; here it is a jump.
Refinement if wanted: run the alignment before the first frame is shown
instead of after, or debounce the re-sync across a burst.

The same thing, mirrored, is visible for a moment *before* a reboot. Capture
2026-09-06-g, last 8 s of a session on the promoted build: the compositor's
exit hands the display to the shutdown splash through two modesets
(641.39, 641.61 s); each turns the slave stream off (latch cleared), re-trains
the slave link (three times the second round) and turns it back on, and the
tiles run unaligned until the delayed re-sync lands (642.10, 642.36 s) — that
window is the brief skew. The going-down sequence itself, 6 s later, is
clean: `atomic-disable` → slave registers reset → latch cleared → panel power
off → reboot. Same cause as the post-password jump, same refinement.

**Control experiment (original note):** boot the pre-5K `Snapshots › 2` entry
(stock amdgpu, `video=eDP-1:3840x2160@60e`, overlayfs root) and warm-reboot out
of it. If the Apple logo skews even then, the 5K patch is not the cause, and
the entire latch-clear stack should be removed.

**If the logo is still skewed after that**, the latch theory is wrong — the
panel state the firmware trips over is something other than 0x4F1 — and the
whole latch-clear stack should be removed rather than extended.

**First attempt, removed:** clearing the latch from `amdgpu_pci_shutdown()`.
That ran while the shutdown splash was still being scanned out, so the splash
itself skewed on the way down — and it did not fix the firmware logo either.
It also logged only at `DC_LOG_DC` (debug), so it could never be confirmed
from the journal. The replacement logs at info level; after a warm reboot out
of the test entry, this proves it fired at the previous shutdown:

```
journalctl -k -b -1 | grep 'stream-disable latch'
```

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

## Fixed: sheared desktop seam (slave tile loses genlock)

The artifact that actually bites in daily use, distinct from the boot-time ones.
The mode is a correct 5120x2880 throughout; what is lost is sync — the slave
stream's `sync_enabled` flips to 0 on some modeset and the two tiles scan out
of phase, which reads as a skewed/sheared seam. Calibrated against the owner's
eyes on 2026-09-05: `sync_enabled=0` in the `commit-after-dc` log line is the
skew.

**What was believed and is wrong:** that 8-bpc loses sync and 10-bpc keeps it.
On a fresh boot with `bitdepth = 10` pinned from the start the slave still came
up at `sync_enabled=0`, and a forced modeset re-locked it at 8-bit just as well.
The earlier "fix" worked because `hyprctl reload` forced a fresh modeset, not
because of the depth. Genlock is a coin-flip per modeset. `bitdepth = 10` stays
in `configs/monitors.lua` because this is a 10-bit panel, not as a fix.

**Workaround for now:** any modeset re-rolls the dice — toggle `bitdepth` in
`~/.config/hypr/monitors.lua` and `hyprctl reload`, check with
`journalctl -k -b 0 | grep commit-after-dc | tail -2`, repeat until both
streams say `sync_enabled=1`. Usually lands within two tries.

**Checked 2026-09-06, not the cause:** master selection. `set_master_stream()`
only considers streams that already have `triggered_crtc_reset.enabled`, and
on a fresh context none do, so the master is always index 0 — here the DP
slave tile (`master_link[1]` in every boot, good or bad). The root then resets
to the slave's VSYNC. That is identical between locked and unlocked boots, so
it does not explain the coin-flip; the `sync_enabled=0` on stream[0] in a bad
boot is that same master (event_source == itself) and is expected. What
differs between boots must be downstream: whether the GSL trigger-reset in
`dce110_enable_per_frame_crtc_position_reset()` actually took, or the panel's
own response to the phase. Making the eDP root the master instead is a cheap
experiment, not a diagnosis.

**Root cause found (2026-09-06)** — and it is exactly the design flaw, not
the panel. `set_master_stream()` only considers streams whose per-frame reset
is *already* enabled and falls back to stream[0]; the stitch adds the slave's
peer stream first, so on a clean commit the slave is picked as its own master
and never gets the reset. The DCE sync group is built from streams that carry
the reset, so the slave tile is left out. Seven modesets in one boot: every
commit with BOTH tiles flagged locked, every one with only the root flagged
sheared; the outcome depended on a stale flag surviving from the previous
commit. **Second finding, 2026-09-06 evening:** with both tiles flagged, login on the
promoted build *still* sheared, and the 10-bit switch (a later modeset) cured
it. `dc_commit_state_no_check()` runs `dc_trigger_sync()` right after
`apply_ctx_to_hw()`; on a full modeset the slave tile is re-woken and
re-trained inside that same commit, so the one-shot alignment
(`enable_timing_synchronization`) fires before both timing generators are
running. Note also that `enable_timing_multisync()` excludes the master, so
with two streams it programs no per-frame reset at all -- the visible lock
comes entirely from the one-shot alignment. Fix in the test entry (`patches/5k-genlock-settle-resync.patch`): a delayed
re-sync 250 ms after every tiled commit via `amdgpu_dm_trigger_timing_sync()`
(the debugfs knob's routine); it logs `manual-trigger-sync`.

**Fix, shipped 2026-09-06:** `patches/5k-genlock-deterministic.patch` flags both
tile streams before the master pick. Proven on hardware: six modesets in one
boot of the fixed build, every one locked at the first stage including the boot
commit. Promoted to the default; `bitdepth` back to 10 on 2026-09-06 — that modeset
locked first time on the promoted build (`XRGB2101010`, both streams
`sync_enabled=1`), and every commit of its first boot locked (6/6).

**Earlier note, kept for the record:** `dm_enable_per_frame_crtc_master_sync()` (see
`patches/genlock-fix.patch`) is where `triggered_crtc_reset.enabled` is set for
the slave; something about which stream `set_master_stream()` picks, or the
order the two tile streams land in the context, differs between the modesets
that lock and the ones that don't. The log's `master_link[N]` field is the lead.

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
