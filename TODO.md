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

**2026-09-07, control with `reboot=pci`:** booted the pre-logo-fix module
(verbose core + stitch, no shutdown handling) with `reboot=pci` on the cmdline;
warm reboot gave a **straight logo**. So a hard PCI reset alone hides the woken
tile — which is why taprobane99 (who runs `reboot=pci`) never sees the skew.
Cost: a visibly longer black gap before the Apple logo (fuller firmware
re-init), and the ramoops region did not survive the reset (pstore empty
afterwards), so crash/shutdown captures are lost. The driver-side handoff in
the lean core gives the straight logo at normal reboot speed and keeps
ramoops; it stays. Not adopting `reboot=pci`.


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
reserved region was reused and the teardown log with it. The user also
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
build — and the user saw a straight Apple logo.** Teardown in order:
`atomic-disable` (116.31 s) → `going-down slave reset 0x310=00 00 00, 0x10A=00`
(116.38, both OK) → `stream-disable latch 0x4F1=0` (116.38, OK on both links)
→ `going-down root eDP power off, holding T12` (116.45) → S5 at 117.16 →
reboot. No re-detect, no wake: the `link_detect()` gate held. One sample so
far; the fix is in the test entry (`patches/5k-latch-clear.patch`), default
untouched, pending the user's decision to promote.

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
the user reports the flashes and the pre-reboot skew are gone. The
measured-resync build was dropped as inert. Lesson: `journalctl -k` for older
boots is the cheapest regression test — compare the same counters across
builds before theorising.

Cosmetic, and reported looking stock as of 2026-09-08 (cold boot and warm
reboot indistinguishable). The mechanism, for the record: after the teardown
the firmware sees a single-tile panel (second tile asleep, its registers reset)
and draws the logo on one tile stretched across the glass; whether that reads
as "soft" versus a crisp cold boot is marginal and not something the driver can
control after the handoff. Making the firmware draw at 5K would mean
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

### Blinks during the password prompt and at session start/exit (both builds)

Real kernel timestamps (dmesg, not journalctl -o short-monotonic — the journal
stamps early kernel lines with its own import time, ~14 s, which misled a first
read): amdgpu module load starts at 2.05 s, its init only runs at 6.01 s, fb0 at
6.38 s, the early modeset lands 1 ms later, cryptsetup prompt at 8.3 s. Between
6.4 s and 8.3 s there are **four more modesets**, and the verbose log shows why,
in strict order each time: stream enable → root latch + slave latch write (0x4F1)
→ `detect connection link[1] reason=2` (DETECT_REASON_HPD) on the slave →
connector-update → hotplug uevent → userspace re-modesets → atomic-disable /
atomic-enable → re-train → latch write → HPD… Three rounds until it settles.
Writing the latch pulses the slave's own HPD line; the driver treats its own
side effect as a plug event. Each round is one black blink, at the prompt and
again at session start (18–21 s) and at session exit. Same on the lean pair.

**Fixed 2026-09-07 (lean3, promoted):** `link_detect()` ignores
`DETECT_REASON_HPD` on a tiled slave that already has its sink; HPD-RX is
untouched. Re-detect rounds per boot 3 → 0, "enabling link 1 failed" gone,
modesets before the LUKS prompt 5 → 3. What remains is not the driver's: the
firmware→amdgpu takeover at 5.7 s (one frame), Plymouth's first two paints at
7.6 s (plane updates, not modesets), the 1.4 s black between Plymouth quitting
(15.8 s) and Hyprland's first modeset (17.3 s), and Hyprland's own config pass
at 19.7 s (three commits in 3 ms: aquamarine test commit, real commit, 10-bit
switch). A seamless splash→compositor handoff would be a Plymouth/Omarchy
arrangement.

**Measured, not the patch:** the 4 s between "module verification failed"
(2.1 s) and "unknown parameter" (6.1 s) is the kernel's own module loading for
a 30 MB module. On this machine xfs (8.7 MB) loads in 0.67 s, i915 (10.7 MB) in
0.64 s, nouveau (7.4 MB) in 0.41 s — it scales with size, and the stock amdgpu
is 33 MB (it carries 2.9 MB of BTF that ours lacks), so stock is no faster.
Decompression is not it: an uncompressed xfs insmod takes the same 0.68 s. So
5K cannot appear earlier than ~6.4 s with a modular amdgpu on this kernel; the
firmware framebuffer covers the gap. Nothing to do in the patch.

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

### Fixed 2026-09-11: DP-1 listed as a second display

With the stitch on, the slave tile's connector was marked `non-desktop` but
still read `connected`. Hyprland listed a disabled `DP-1` and reserved crtc 75
for it, and Omarchy's display panel showed a **DISPLAYS** section whose `DP-1`
row runs `hyprctl keyword monitor DP-1,preferred,auto,auto` -- one click from
enabling the tile as a second output underneath the stitched one.

`patches/imac5k-stitch-hide-slave.patch` reports the slave disconnected from
`amdgpu_dm_connector_detect()` when the stitch is on. Its dc_link and sink are
untouched, so the peer stream is unaffected; without `tiled_stitch` the tile is
reported as usual for compositors that stitch the pair themselves. Verified on a
test entry, two boots: `DP-1 disconnected`, Hyprland lists only eDP-1
(5120x2880, 10-bit), the peer stream is added on every modeset (`has_sink=1`),
no amdgpu/drm warnings, the panel's DISPLAYS section is gone, the centre seam is
seamless under drag/scroll/video (owner's eyes), and a warm reboot out of it was
clean.

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

## Hardware: functional test results (2026-09-07, cable + SD card + headset supplied)

| Item | State |
|---|---|
| Built-in Ethernet | **WORKS** — link 1000 Mb/s full duplex, `ping -I enp4s0f0` to the gateway 0 % loss, 0.25 ms |
| Bluetooth | **WORKS** — controller powered and pairable, an 8 s scan found 11 devices. Pairing itself still unexercised |
| Headphone output | **WORKS** — see the audio section below |
| Microphone (any) | **BROKEN** — see below. This corrects an earlier note that called the internal mic working |
| SD card reader | **BROKEN** — see below |
| Backlight | Root-caused, fix staged in a test entry — see below |
| Wi-Fi `clm_blob` | **Not locally fixable.** `linux-firmware` ships no `brcmfmac43602-pcie.clm_blob` at all (it has them for 43012/43430/43455/4354/4356/43570/4373/54591). Regulatory domain is applied anyway (`country KW: DFS-ETSI`), so the loss is the firmware's internal channel table, not the regdb. The only known source is Apple's own driver blob — a real lead, but it means reading the macOS volume |
| HDMI audio | **Cannot be tested on this machine.** The GPU exposes 7 HDMI PCMs but `/sys/class/drm/card1-HDMI*` is empty — there is no HDMI connector. The iMac's external video is Thunderbolt/DP. Remove this row unless a DP display is attached |
| Ambient light sensor | Works, reads ~500 lux (`iio:device0`, `acpi-als`). Still drives nothing — blocked on backlight |
| VA-API decode | Unverified — `vainfo`/`libva-utils` not installed |

## Backlight: root cause found

`amdgpu ... [drm] Skipping amdgpu DM backlight registration` at boot. In
`amdgpu_dm_register_backlight_device()` the driver returns early when
`acpi_video_backlight_use_native()` is false, handing backlight to ACPI. But
ACPI's is the broken one — the firmware bug is logged in the same boot:
`ACPI: video: [Firmware Bug]: ACPI(GFX0) defines _DOD but not _DOS`. So
`acpi_video0` accepts writes (0–79, values stick) while nothing owns the actual
panel. The panel also has **no eDP backlight over AUX** — DPCD 0x701 `GENERAL_CAP_1`
reads 0x00, so `backlight_adj` is not supported and the control must be the GPU's
PWM.

**Fix staged, not promoted:** boot entry `/Test - native backlight (brightness fix)`
with `acpi_backlight=native` appended to the cmdline. Secure Boot is disabled, so
the loader's cmdline does reach the stub — proved independently: boot −8's
`Command line:` carried `reboot=pci`, which is in *neither* UKI's embedded
`.cmdline` and so can only have come from Limine.

The entry is pinned to its **own private copy** of the kernel image
(`omarchy_linux-blnative.efi`), not to the shared `omarchy_linux.efi`. That is
deliberate and matters: `limine.conf` sets `hash_mismatch_panic: yes`, so an
entry pinned to the shared image **panics on selection** after any kernel or
module rebuild changes that file's hash. `limine-entry-tool` refreshes only its
own generated entry, and `imac-alt-entry`'s `repin_orphans()` skips plain
`omarchy_linux.efi`, so nothing would have repaired it. A private copy is never
rebuilt, so its hash cannot drift. `blnative` was also added to
`repin_orphans()`'s skip list, because that function re-pins with the *default*
cmdline and would silently drop `acpi_backlight=native`.

**Expected on the test boot:** `/sys/class/backlight/amdgpu_bl0` appears and
writes to it dim the panel. **Residual risk:** if it appears but does not dim,
read back `BL_PWM_CNTL` — a changing `BL_ACTIVE_INT_FRAC_CNT` with no visible
effect would mean the panel is on an SMC-managed board rail rather than the GPU's
PWM pin, and the next lead becomes `applesmc`, not amdgpu. Do **not** set
`amdgpu.backlight=1`; that forces the AUX path this panel does not have. Expected result: `amdgpu_bl0` appears under
`/sys/class/backlight/` and actually dims the panel. Default entry untouched.
If it works, the change belongs in `/etc/default/limine` `KERNEL_CMDLINE[default]`
and unlocks auto-brightness from the ALS.

## Audio: the internal mic works; a plugged-in headset breaks it (SOLVED, root cause proven)

**Confirmed on hardware 2026-09-07.** With nothing in the 3.5 mm jack, the
internal microphone records normally: `arecord -D hw:0,0 -f S32_LE -d4` gives
**peak 0.905, RMS 0.102** of full scale. Earlier reports in this file that "no
microphone works" were taken with a headset plugged in the whole time, which is
precisely the broken case.

Accurate state of this hardware:

| Case | Works? |
|---|---|
| Internal mic, nothing plugged in | **Yes** |
| Internal mic, headset plugged in | **No — silence** |
| Headset mic | **No — no route exists** |
| Headphone output | Pin path enables correctly; not yet confirmed audible |
| Inline headset buttons | **Working** — play/pause, volume up, volume down |

### Root cause, proven

The driver has two bring-up routines. `cs_8409_pcm_capture_pre_prepare_hook`
branches on `have_mike`: with a mic-equipped headset detected it calls
`cs_8409_headcapture_setup` (headset mic → CS8409 ADC **0x1a**) and **never calls
`cs_8409_capture_setup`**, which is what brings up the internal mic. But the PCM
stream stays bound to `intmike_adc_nid` = **0x23**. So the driver configures one
microphone and records from the other.

Two hardware reads confirm it, taken during a failing capture with a headset in:

- Vendor coef `0x82` read back **`0x0000`** — `DMIC2_SCL_EN (0x0002)` never set.
  Only `cs_8409_intmike_stream_on_nid` sets it (`patch_cirrus_real84.h:481`).
- Pin node `0x45` showed `Pin-ctls: 0x00` even mid-capture; that same function
  writes `SET_PIN_WIDGET_CONTROL 0x20` to it (`real84.h:489`). It never ran.
- Coef `0x09` = `0x0093`, so the iMac DMIC2 model config is **correct**. The
  per-model setup is fine; the code path is simply skipped.

**The `Capture Source` enum being unwritable is a red herring, not our bug.**
`mux_select()` in `sound/hda/codecs/generic.c` does
`old_path = get_input_path(...); if (!old_path) return 0;` — a *silent* no-change
return before `cur_mux` is assigned, so the write reports success and readback
stays 0. `input_paths[0][0]` is NULL because node 0x23's connection list is
`{0x45}` only: there is no route from headset-mic pin 0x3c to ADC 0x23. The imux
advertises an item the hardware cannot reach.

Candidate defects 1 and 3 from the earlier draft are **both wrong** and are
retracted. The one published iMac18,3 alsa-info dump is byte-identical to this
machine's pins, and `imac_pincfgs {0x44, 0x00800101}` only retasks the dead
line-in — uncommenting `snd_hda_apply_pincfgs` would not touch the mic.
`reg9_linein_dmic_mo` is genuinely never assigned but is read only in the
line-in path.

### FIXED 2026-09-07: headset capture works and follows the jack live

`patches/cs8409-headset-capture.patch` — one patch, four related fixes, all
confirmed on hardware. Supersedes the three separate patch files this section
previously referenced.

**The headline bug was that plug/unplug while capturing did nothing at all.**
The driver said so itself: `PLUGIN WHILE CAPTURING UNIMPLEMENTED!!`, with
`// NOTA BENE - no concept/implementation of plugging in while capturing!!` at
the top of the function. Since the routing setup only ran at stream start, any
application holding the microphone open across a jack change kept the old
routing forever. OBS does exactly that — which is why the mic appeared to work
and then died permanently the first time the jack was touched, and why it looked
random rather than reproducible.

Verified with a 90-second capture held open across a physical unplug and replug:

```
21:55:09  unplug     -> capture nid 0x1a -> 0x23 (jack 0 mike 0)
21:55:20  plug in
21:55:22  headset detected -> capture nid 0x23 -> 0x1a (jack 1 mike 1)
```

The converters swapped in `/proc/asound/card0/codec#0` to match, and **not one
2-second window lost audio** across either transition.

Also in the patch: capture follows the jack at stream start (the driver was
configuring one mic and recording from the other — silence with a headset in);
the internal mic amp is owned by the mixer instead of being stamped with a
hardcoded −12 dB while the control claimed +12 dB (−51.0 → −22.9 dBFS); and the
headset mic gets the +32 dB the CS42L83 has available but nobody was applying
(it was 35× quieter than the internal mic). Full reasoning is in the patch
header.

**Headset buttons: shipped and working (2026-09-08).** The earlier attempt was
excluded because a level-detect sweep clicked through live audio and jammed the
interrupt handler. That whole approach was unnecessary: each button raises a
distinct bit in the disambiguated interrupt word (volume down 0x10000, volume
up 0x20000 on the 0x1b79 detect register; play/pause 0x100/0x200 on 0x1b7c), so
`cs_8409_headset_button_event` now reads the button straight from the interrupt
and emits KEY_VOLUMEDOWN/KEY_VOLUMEUP/KEY_PLAYPAUSE — no sweep, no HSBIAS poking,
nothing that clicks. The one register needed is Detect Interrupt Mask 2 (0x1b7a):
plug-time detection re-masks it to 0xff, gating the play/pause bits, so after
detection it is set to the OSX steady-state 0xdc. On by default (`headset_buttons`).
Verified: each physical press delivers exactly one key, no repeats, and audio +
capture + jack-follow keep working across presses. ~200 lines of sweep/arming
scaffolding removed.

**Correction, after the first commit of this patch:** the re-route also called
`cs_8409_headplay_setup()`, mirroring the normal capture-start sequence, which
does reconfigure the playback/ASP path. With OBS holding the mic open the
re-route fired on every plug, and reconfiguring playback from inside a jack
event **left the speakers silent**. Removed — a capture-side re-route has no
business touching playback. Verified after removal: speakers work, both mics
work, jack reads correctly.

**Diagnostic lesson worth keeping:** "the speakers don't work" turned out to be
one application (the `blow-off-some-steam` shell plugin) while YouTube played
fine. Qt `SoundEffect` binds to the audio device when the plugin loads; ~5
driver reloads had left it holding handles to a device that no longer existed.
Restarting quickshell fixed it. **Before chasing a hardware output fault, check
whether a second application also has no sound** — and note that every driver
reload silently disconnects OBS, Chromium and the shell plugins from audio.

### FIXED 2026-09-08: the jack path raced stream setup

**Root cause (was listed as three separate bugs): a jack event and audio stream
setup were not serialised.** A headset unsol event and an app starting/stopping a
stream both drive the CS42L83 over i2c and toggle AFG power, non-atomically. When
they interleaved, status reads returned all zeros (a 70 ms stream setup was seen
taking 7.7 s) and the *unplug* interrupt in that window decoded as 0x00000000 and
was dropped. The driver then still believed the headset was in — sound to an empty
socket, capture on an absent mike — until a reload or replug. The "device with an
empty Ports list" and apps reporting "no microphone" were downstream of that; and
the `set-card-profile off/on` recovery previously suggested was itself destroying
and recreating the source object, breaking every connected app (that was the index
climb 58 -> 6000+ in one session — self-inflicted, not the jack).
Fix: one `spec->setup_mutex`, taken by the jack unsol handler for the whole event
and by the PCM prepare ops and open/cleanup/close hooks (prepare already holds it).
Also `cs_8409_cs42l83_mark_jack` now marks *all* jacks dirty (was headphone-only,
so the mic-jack kcontrol froze at its probe value), and the headset-mic pin-sense
override now requires `have_mike` as well as `jack_present`.
Verified on hardware: plug and unplug in both directions, with and without a
recording held open, switch sound and mic automatically with no dead window and
no missed unplug; internal mic −10 dBFS, headset mic −20 dBFS.

**2. (Likely resolved by the serialisation fix — watch.)** Headset mic level
dropped ~30 dB after a replug. Fresh driver load gives
−16 dBFS; after an unplug/replug the same setup measures −45 to −51 dBFS. The
boost *is* applied — `adc_level: boost 1 gain 12 dB (0x1d01 0x01 0x1d03 0x0c)`
is logged at the replug with the right values, and the module parameters are
intact. So gain reaches the codec but the signal arriving is weak: something
else in the CS42L83 front end comes back only partially configured on a replug.
Forcing a fresh capture stream recovers only a couple of dB, so it is not the
stream. Seen at least three times *before* the serialisation fix. The half-configured
front end is consistent with the unplug/re-detect racing stream setup, i.e. the
same root cause. After the fix, replugs measure −20 dBFS (healthy) across a full
session; left here so the user can flag it if it ever recurs.

**3. Operational trap, cost hours:** every driver reload silently disconnects
OBS, Chromium and the shell plugins from audio, and **Chromium can be left with
several orphaned audio services** (`utility-sub-type=audio`) if the service is
killed repeatedly — the browser then talks to a dead one and reports no
microphone even though the system is healthy. Kill *all* of them and let it
respawn exactly one. Check `pgrep -cf 'utility-sub-type=audio'`.

**Plug-in artefact (was: loud high-pitched artefact on headset plug-in).**
Reported clean as of 2026-09-08 — no static on plug or unplug after the
jack-event serialisation and the removal of the button HSBIAS-poking path.
Not instrumented (the per-call logging is compiled out of the shipped
build), so this rests on listening, not measurement; left here to re-open
if it ever recurs.

### Separate pre-existing driver bug: WirePlumber drops the card

The driver leaves `Internal Mic Boost Volume` at **3** when its ALSA range is
`max=2`. WirePlumber then fails with `Failed to set volume of 'Internal Mic
Boost': Invalid argument` and **drops the entire analog device**. Seen once
during this work (triggered by unplugging during module probe, which also logs
`headphone REMOVED 6 - UNIMPLEMENTED!!`). Clamping the control to 2 recovers it.
**This will recur** after any internal-mic capture if WirePlumber restarts. Not
fixed — needs a one-line clamp in the driver's control setup.

### Not a defect, but worth tuning

At `Internal Mic` 100 % plus +20 dB boost the capture peaks at 0.905, close to
clipping on ordinary room noise. Whoever wires this up should set a sane default
gain rather than leaving it at maximum.

### Open: choose speakers or the internal mic while a headset is plugged in

**Wanted:** the macOS-style choice — with earbuds in, pick "Speakers" (or the
internal microphone) from the volume panel and have the sound actually move.
The panel rows exist (the Omarchy change proposed as basecamp/omarchy#10985);
they were made honest again on
2026-09-09 by listing only ports the driver reports available, because picking
the other one moved the highlight and not the sound.

**Proven not to be hardware (experiment 2026-09-09, earbuds in, video playing):**
`pactl set-sink-port … analog-output-speaker` was accepted, PipeWire reported
Speakers active, and the codec did not move at all — `0x2c` (headphones) stayed
`Pin-ctls: 0x40: OUT`, `0x24/0x25` (speakers) stayed `0x00`, sound stayed on
the earbuds. The speaker pins are `0x00` *even while the speakers are playing*,
so the speakers are not driven through the standard pin controls: the driver
runs both amplifiers over its private I2C path to the CS42L83, and its
jack-detect handler is the only thing that ever sets the routing (headphone amp
on + speaker path off on insert, the reverse on removal). The card exposes no
Speaker/Headphone playback switch, so PipeWire's port switch writes to controls
the driver never reads. Capture is the same story: switching the source port
left the driver's `Capture Source` selector untouched. The hardware itself has
separate speaker and headphone amplifiers and separate mic inputs, and the
driver already toggles them independently — just in a fixed pattern copied
from what macOS does (Apple also hides the internal speakers when headphones
are plugged in).

**The fix is driver work, bounded:**
1. Expose real `Speaker Playback Switch` and `Headphone Playback Switch`
   kcontrols mapped to the I2C writes the jack handler already does.
2. Make the jack event set a *default* (headphones on insert, speakers on
   removal) instead of forcing it — i.e. re-apply the switches, don't bypass them.
3. Honour `Capture Source` the same way for the microphones (`0x1a` headset
   ADC vs `intmike_adc_nid`), so the panel's Internal / Headset Microphone
   rows become real.
Once the switches exist, PipeWire's `analog-output-speaker/headphones` paths
(which key on exactly those element names) work with no userspace change, the
panel's available-only rule can list both ports again, and the override is
honest. Upstreamable on the same jackdanyell PR.

**Why the internal-mic row cannot simply be hidden meanwhile (2026-09-09):**
PipeWire marks `analog-input-internal-mic` "not available" only when a jack
named *Mic* (or Dock/Front/Rear Mic) is plugged — `analog-input-internal-mic.conf`
has no rule for a jack named *Headset Mic*. Labelling the jack mic a headset mic
(needed for the "Headset Microphone" port and glyph) renamed the jack kcontrol
from "Mic Jack" to "Headset Mic Jack", so the internal mic now reads "unknown"
with a headset in, and the panel lists it. The driver cannot report anything
that yields "not available": the internal mic has a *phantom* jack, and the path
maps a phantom jack to "unknown" whether plugged or not. Upstream's omission is
deliberate — on drivers that honour the selector the internal mic is a valid
choice with a headset in. So the only clean end state is step 3 above; until
then the row is harmless (selecting it does nothing, as before).

**Risk:** the routing code is the touchy part of this driver — reconfiguring
the playback/ASP path from inside a jack event once produced the continuous
high-pitched tone on the headset output (see the comment in
`patch_cirrus_new84.h`). Budget a day with ear-testing, not an hour. Do it after
the headset-mic label reboot check.

## Speaker EQ — parked 2026-09-10

Taken out of the patcher on 2026-09-10 at the owner's call: the speakers sound
fine without it, and after that day's cold boot it had been silently off anyway.
Kept here, whole, to revisit.

**What it was.** A native Omarchy speaker tuning for this machine (bass shelf,
two peaking cuts, a high shelf and an LSP lookahead limiter), installed into
Omarchy's tunings directory and switched on with `omarchy-audio-tuning on`,
which runs it as its own PipeWire instance (`omarchy-speaker-tuning.service`,
`pipewire -c omarchy-speaker-tuning.conf`). The shell hides the physical sink
while a sink named `omarchy_speaker_tuning` fronts it, so the panel showed one
output, "iMac Audio".

**Why it went.** After a cold boot the service was `active (running)` but had
created no nodes: only the bare codec sink existed, so audio bypassed the EQ
while the patcher reported it applied. The same config started by hand came up
immediately, so the curve and graph are fine — it is a startup problem. It left
no trace because the tuning host config sets `log.level = 0`.

**Before bringing it back:**
1. Find why the host comes up empty at login. It starts `After=pipewire.service
   wireplumber.service` and connects, but its filter-chain nodes never appear;
   start it with `PIPEWIRE_DEBUG=3` from a boot to see why (candidates: the
   LV2 limiter loading before `lilv` can see `/usr/lib/lv2`, or the host
   racing WirePlumber's startup). Loading the filter-chain inside the main
   PipeWire through `pipewire.conf.d` would remove the second instance entirely.
2. Make `detect` check the live node (`pw-cli ls Node | grep
   omarchy_speaker_tuning`), not files and a service state — that is what let
   "applied" and "off" coexist.
3. The tuning also applies to the headphone jack (speakers and headphones are
   two ports on one sink here); see the note in `filter-chain.conf`.
4. The device names (`audio/wireplumber/51-imac-audio-names.conf`) moved to the
   `audio` module; with the tuning back, the bare sink would need a distinct
   name again, as it had ("iMac Direct (no EQ)").

**Needs** `lsp-plugins-lv2`. **Removal it performed** (already done on the
owner's machine): `omarchy-audio-tuning off`, then delete the tuning directory,
the kept copy and the pacman hook listed in the module below.

### The module, as it was in `scripts/imac-patcher`

```bash
# ═══════════════════════ module: eq ════════════════════════════════════════
# Installed as a native Omarchy speaker tuning rather than a loose filter-chain.
# That naming is not cosmetic: the shell hides the physical sink while a sink
# called omarchy_speaker_tuning fronts it, and excludes the tuning's own output
# from the application list -- so the stock path shows ONE output named for the
# speakers, where a hand-rolled chain shows the tuning and the hardware twice.
# It also makes the volume keys resolve through the filter to the real sink.
OMARCHY_TUNINGS="${OMARCHY_PATH:-/usr/share/omarchy}/default/audio/tunings"
EQ_TUNING_SRC="${REPO_DIR}/audio/tunings/imac18-3"
EQ_TUNING_DEST="${OMARCHY_TUNINGS}/imac18-3"
EQ_TUNING_KEEP="/usr/local/share/omarchy-imac5k/tunings/imac18-3"
EQ_TUNING_HOOK="/etc/pacman.d/hooks/imac-speaker-tuning.hook"
WP_NAMES_SRC="${REPO_DIR}/audio/wireplumber/51-imac-audio-names.conf"
WP_NAMES="${HOME}/.config/wireplumber/wireplumber.conf.d/51-imac-audio-names.conf"
mod_eq_title() { echo "Speaker tone EQ"; }
mod_eq_tier()  { echo safe; }
mod_eq_desc()  { echo "The codec does no DSP at all; macOS's warmth is entirely software EQ. Installs an Omarchy speaker tuning (bass shelf + lookahead limiter) and keeps it off the headphone jack."; }
mod_eq_detect() {
    local tuning=0 host=0
    [[ -f "${EQ_TUNING_DEST}/tuning.conf" ]] && tuning=1
    systemctl --user is-active omarchy-speaker-tuning.service &>/dev/null && host=1
    if (( tuning && host )); then echo applied
    elif (( tuning || host )); then echo partial
    else echo not-applied; fi
}
mod_eq_apply() {
    # Every Omarchy tuning ends in a lookahead limiter, which is an LV2 plugin;
    # omarchy-audio-tuning refuses to install without it.
    if [[ ! -e /usr/lib/lv2/lsp-plugins.lv2/limiter_stereo.ttl ]]; then
        say "installing the LV2 limiter the tuning needs"
        sudo pacman -S --needed --noconfirm lsp-plugins-lv2 || return 1
    fi
    [[ -f "${EQ_TUNING_SRC}/tuning.conf" ]] || { warn "tuning missing: ${EQ_TUNING_SRC}"; return 1; }
    say "installing the iMac18,3 tuning into ${EQ_TUNING_DEST}"
    sudo install -d -m755 "$EQ_TUNING_DEST" || return 1
    sudo install -m644 "${EQ_TUNING_SRC}/tuning.conf" "${EQ_TUNING_SRC}/filter-chain.conf" "$EQ_TUNING_DEST" || return 1
    # omarchy-settings owns that directory and an update replaces it, which
    # silently switches the EQ off. Keep a copy outside it and let pacman put
    # the tuning back after every omarchy-settings upgrade.
    sudo install -d -m755 "$EQ_TUNING_KEEP" || return 1
    sudo install -m644 "${EQ_TUNING_SRC}/tuning.conf" "${EQ_TUNING_SRC}/filter-chain.conf" "$EQ_TUNING_KEEP" || return 1
    sudo install -Dm644 "${REPO_DIR}/audio/pacman/imac-speaker-tuning.hook" "$EQ_TUNING_HOOK" || return 1

    # An earlier revision of this patch shipped the same curve as a loose
    # filter-chain fragment. Left in place it would run a second copy of the EQ
    # in series with the tuning.
    if [[ -f "$EQ_DEST" ]]; then
        say "removing the superseded standalone EQ fragment"
        rm -f "$EQ_DEST"
        systemctl --user disable --now filter-chain.service &>/dev/null
    fi

    omarchy-audio-tuning on || { warn "omarchy-audio-tuning refused — see the message above"; return 1; }

    # The codec publishes itself as its part number, "CS8409/CS42L83 Analog".
    say "installing readable device names"
    install -Dm644 "$WP_NAMES_SRC" "$WP_NAMES" || return 1
    systemctl --user restart wireplumber || true

    if omarchy-audio-tuning fronted-sink >/dev/null 2>&1; then
        say "one output, named iMac Audio — the bare codec is hidden behind it"
    else
        warn "the tuning sink is not fronting the hardware; the output list will still show both"
    fi
}
mod_eq_remove() {
    rm -f "$WP_NAMES"
    omarchy-audio-tuning off || true
    [[ -d "$EQ_TUNING_DEST" ]] && sudo rm -rf "$EQ_TUNING_DEST"
    sudo rm -rf "$EQ_TUNING_KEEP" "$EQ_TUNING_HOOK"
    say "tuning removed — output goes straight to the codec again"
}
```

### `audio/tunings/imac18-3/tuning.conf`

```bash
## Apple iMac18,3 (2017 27-inch 5K) internal speakers.
##
## Six biquads and a lookahead limiter, applied as a PipeWire filter-chain in
## front of the internal speaker sink. The CS8409/CS42L83 path does no DSP of
## its own on Linux: macOS supplies the voicing in software, so without this the
## speakers sound thin and bright compared with the same machine under macOS.

description="Apple iMac 27-inch 5K (18,3) speakers"
## Matched on the DMI product name, which is the only identifier Apple exposes
## here -- these machines carry no product SKU. "iMac18,3" is the 27-inch 5K;
## the 21.5-inch models are 18,1 and 18,2 and have different speakers, so this
## must stay an exact model string and never widen to "iMac".
match_dmi=("iMac18,3")
## The codec exposes speakers and headphones as two ports on ONE sink, unlike
## the split speaker/headphone sinks on machines with UCM profiles. See the note
## in filter-chain.conf about what that means for headphones.
## Unescaped dots: this is passed to awk as a string, where a backslash escape
## would be consumed before the regex sees it.
sink_pattern='^alsa_output.*analog-stereo$'

## Provenance. Tuned by ear on the hardware against the same machine running
## macOS as the reference, not fitted to a measured response. The figures the
## shipped tunings carry (magnitude RMS, group delay, limiter headroom) are
## deliberately absent rather than guessed: no multitone measurement has been
## taken on this machine yet.
derived_from="hand-tuned against macOS on the same unit"
validated_by="ahmadtv"
validated_hardware="iMac18,3 (2017 27-inch 5K)"
```

### `audio/tunings/imac18-3/filter-chain.conf`

```
# Apple iMac18,3 (2017 27-inch 5K) speaker tuning.
#
# Four active biquads and a lookahead limiter. The CS8409/CS42L83 codec applies
# no DSP on Linux, so this supplies the voicing macOS does in software: lift the
# low end the small sealed cabinets cannot produce, take the edge off the
# presence region, and tilt the top down.
#
# The limiter replaces a hard clamp used earlier. With a +7 dB low shelf, bass
# transients on a loud master exceed full scale, and a clamp resolves that by
# clipping them. The limiter resolves it by lookahead gain reduction instead,
# which is the same protection without the distortion. Input gain is left at
# unity so the perceived level matches what the clamp version produced; if the
# bass audibly pumps on dense material, trim "g_in" rather than raising "th".
#
# Channels are wired explicitly because the limiter is a stereo plugin; a mono
# graph is duplicated per channel and would limit each side independently,
# shifting the stereo image on bass transients.
#
# HEADPHONES: this codec exposes speakers and headphones as two ports on a
# single sink, not as separate sinks, so pinning the output to the speaker sink
# does not keep this tuning off headphones the way it does on machines with
# split sinks. The tuning therefore applies to the jack as well.
#
# That is deliberate and it is the owner's call. A bypass was built and dropped:
# it worked, but it is a background process compensating for how the device is
# modelled, and the real fix is to model the machine the way macOS does -- each
# port its own output -- which would make the name change on plug and take the
# tuning off headphones with nothing watching anything. That belongs in an ALSA
# UCM profile for this machine, not in a daemon.
#
# The node is called "iMac Audio" rather than "iMac Speakers" because it is the
# only output the panel shows and it carries the headphones too.

context.modules = [
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "iMac Audio"
      media.name       = "iMac Audio"

      filter.graph = {
        nodes = [
          { type = builtin name = s0_l label = bq_lowshelf  control = { "Freq" = 150.0  "Q" = 0.7 "Gain" = 7.0 } }
          { type = builtin name = s1_l label = bq_peaking   control = { "Freq" = 250.0  "Q" = 1.0 "Gain" = 2.0 } }
          { type = builtin name = s2_l label = bq_peaking   control = { "Freq" = 5000.0 "Q" = 1.0 "Gain" = -2.0 } }
          { type = builtin name = s3_l label = bq_highshelf control = { "Freq" = 8000.0 "Q" = 0.7 "Gain" = -3.0 } }

          { type = builtin name = s0_r label = bq_lowshelf  control = { "Freq" = 150.0  "Q" = 0.7 "Gain" = 7.0 } }
          { type = builtin name = s1_r label = bq_peaking   control = { "Freq" = 250.0  "Q" = 1.0 "Gain" = 2.0 } }
          { type = builtin name = s2_r label = bq_peaking   control = { "Freq" = 5000.0 "Q" = 1.0 "Gain" = -2.0 } }
          { type = builtin name = s3_r label = bq_highshelf control = { "Freq" = 8000.0 "Q" = 0.7 "Gain" = -3.0 } }

          { type   = lv2
            name   = limiter
            plugin = "http://lsp-plug.in/plugins/lv2/limiter_stereo"
            control = {
              # Both default to enabled: "alr" regulates level toward the
              # threshold and "boost" normalises the threshold up to full
              # scale. A fixed tuning must switch them off or its tone drifts
              # with programme level.
              "alr"   = 0
              "boost" = 0
              "g_in"  = 1.0
              "th"    = 0.891
            }
          }
        ]

        links = [
          { output = "s0_l:Out" input = "s1_l:In" }
          { output = "s1_l:Out" input = "s2_l:In" }
          { output = "s2_l:Out" input = "s3_l:In" }
          { output = "s3_l:Out" input = "limiter:in_l" }

          { output = "s0_r:Out" input = "s1_r:In" }
          { output = "s1_r:Out" input = "s2_r:In" }
          { output = "s2_r:Out" input = "s3_r:In" }
          { output = "s3_r:Out" input = "limiter:in_r" }
        ]

        inputs  = [ "s0_l:In" "s0_r:In" ]
        outputs = [ "limiter:out_l" "limiter:out_r" ]
      }

      audio.channels = 2
      audio.position = [ FL FR ]

      capture.props = {
        node.name   = "omarchy_speaker_tuning"
        media.class = Audio/Sink
      }
      playback.props = {
        node.name     = "omarchy_speaker_tuning_output"
        node.passive  = true
        target.object = "@SPEAKER_SINK@"
        # This stream is the filter's output and is a movable sink input like any
        # other, so anything that reroutes "all streams" to a newly selected
        # output would drag the processing along with it -- onto headphones, or
        # into the tuning's own sink, which is a cycle. Pin it.
        node.dont-move = true
        # If the speaker sink is not present yet -- the tuning host can start
        # before the device is discovered -- WirePlumber would otherwise link this
        # output to whatever default exists, quietly tuning the wrong device while
        # the tuning sink still looks healthy. Wait for the named target instead.
        node.dont-fallback = true
      }
    }
  }
]
```

### `audio/pacman/imac-speaker-tuning.hook`

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings

[Action]
Description = Restoring the iMac18,3 speaker tuning the Omarchy update overwrote
When = PostTransaction
Exec = /usr/bin/cp -r /usr/local/share/omarchy-imac5k/tunings/imac18-3 /usr/share/omarchy/default/audio/tunings/
```

## SD card reader: broken, and not for the reason it first looks

With a card inserted the controller *does* see it and starts initialising, then
fails: `mmc0: Skipping voltage switch` → `Timeout waiting for hardware interrupt`
→ `ADMA Err: 0x00000001` → `mmc0: error -110 whilst initialising SD card`.

The ADMA error is a red herring. Reloading `sdhci` with
`debug_quirks=0x40` (`SDHCI_QUIRK_BROKEN_ADMA`) drops the controller to PIO —
`mmc0: SDHCI controller on PCI [0000:04:00.1] using PIO` — and the card still
fails identically. So it is **not a DMA problem**. The failing command is
`Cmd: 0x0000333a`, i.e. CMD51 `SEND_SCR`, the first command that moves data over
the DATA lines; the card answers commands (`Resp[0]: 0x00000920`) but the data
phase times out. Combined with `Skipping voltage switch`, this looks like bus
signalling/timing, not DMA.

The kernel has **no quirk for this reader at all** — `grep -rn 57765` over
`sdhci-pci*.c` returns nothing, and the device is
`14e4:16bc BCM57765/57785 SDXC/MMC` on `sdhci-pci`.

**Three configurations tested on 2026-09-07 and eliminated** (each a
`modprobe -r` / `modprobe` cycle, all restored to stock afterwards):

| Config | Effect observed | Result |
|---|---|---|
| `debug_quirks=0x40` (BROKEN_ADMA) | controller ran `using PIO` | same CMD51 failure |
| `debug_quirks2=0x4` (NO_1_8_V) | the published Mac fix from Ubuntu #1307674 | same failure |
| `debug_quirks=0x10001380 debug_quirks2=0x204` | ChromeOS Broadcom set; `using ADMA` 32-bit, `ADMA Ptr` dropped to `0x79c43208` — below 4 GiB | same failure |

So **64-bit DMA, UHS/1.8 V signalling, and the DMA engine itself are all ruled
out.** The failure signature is identical every time: `Cmd: 0x0000333a`
(CMD51 `SEND_SCR`) → `Timeout waiting for hardware interrupt` → `-110`. The host
never raises Buffer Read Ready for the 8-byte SCR block.

**RULED OUT 2026-09-07: the ChromeOS register fixup is a no-op on this silicon.**
It was ported cleanly (entirely inside `sdhci-pci-core.c` as an `.ops` override
plus a `pci_ids` entry for `14e4:16bc`; no core `sdhci.c` change needed), built,
and instrumented with a printk to read the registers back. The writes land, but
they change nothing: `0x198` already had the `0x3000` bits clear, and `0x19c`
already held exactly `0x00500000`, the value the fixup writes. Decisive, not
merely untested. Source confirmed against the original LKML posting
(https://lkml.iu.edu/1311.1/04270.html) and the ChromeOS commit
(`fd1acc54a6b3db4e6503ccc4a9349f28b436031a`): `BCM57785_CR_MUX_CTL 0x198`,
`BCM57785_CR_CLK_CTL 0x19c`, hooked at the top of `sdhci_set_clock`.

**PCIe ASPM was eating the interrupts — and it explains a bad call I made.**
Both functions of `04:00.x` had ASPM L1 enabled. Measured: with ASPM on, `mmc0`
took **0 interrupts across 3 command timeouts in 30 s**; with it off, **459
interrupts in 35 s**. Disabling it also moved the failure back from
`Timeout waiting for hardware **cmd** interrupt` to the original data-phase
CMD51 failure. So the "worse signature" recorded earlier today was an **ASPM
artifact, not the card degrading** — that earlier note is retracted. The correct
register is `CAP_EXP+0x10.W`, not the `0x50` in the community workaround:
`sudo setpci -s 04:00.1 CAP_EXP+0x10.W=0x0040` (likewise `04:00.0`, `00:1c.1`).
This is a runtime config-space write and **reverts on reboot**.

**The true remaining fault: the DAT lines never deliver a byte.** At
`Cmd: 0x0000333a` (ACMD51) the card *responds correctly* (`Resp[0]: 0x00000920`).
`Present: 0x1fff0206` shows DAT inhibit, DAT line active and read transfer
active; `Int stat` stays `0x00000000` and `Sys addr` never advances. The
controller's own hardware data timeout (`Timeout: 0x0e`) never fires either — the
data state machine is **wedged, not slow**. Reproduced identically across ADMA
64-bit, ADMA 32-bit (pointer below 4 GiB), and plain SDMA, at 1-bit width and
100 kHz.

Command path works end to end; only the DAT path is dead, at any clock, any
width, any DMA engine, with the card answering.

**SECOND CARD TESTED 2026-09-07 — the diagnosis is confirmed and this is a
hardware fault, not a software one.** A different 128 GB card was inserted. It
got *further* than the first: it enumerated correctly and the kernel created a
block device — `mmcblk0: mmc0:e624 SD128 119 GiB`, and `lsblk` showed
`mmcblk0 119.1G`. So card identification, which reads the CID and CSD registers,
completed and reported the right capacity.

Then every data transfer failed:

```
dd if=/dev/mmcblk0 of=/dev/null bs=1M count=1   ->  0 bytes copied
fdisk -l /dev/mmcblk0                           ->  Input/output error
I/O error, dev mmcblk0, sector 0 op 0x0:(READ)
mmcblk0: recovery failed!
mmc0: tried to HW reset card, got error -2
```

**Zero bytes were ever read.** Two different cards, one of which the controller
identifies perfectly, both fail the moment the DAT lines must carry data — with
ASPM disabled, at 1-bit width, at 100 kHz, and across every DMA mode. The
possibility that the first card was simply worn is now eliminated.

**Conclusion: the SD reader's data path is broken at the hardware level** —
Apple's board wiring or mux between the BCM57765 and the slot, or a fault in the
reader itself. No driver change can fix this. Software avenues are exhausted:
the ChromeOS register fixup is a proven no-op on this silicon, every relevant
sdhci quirk combination has been tested, and disabling ASPM restored interrupt
delivery without restoring data.

**Status: still under investigation.** The Linux-side evidence points to a
hardware fault (identify OK, every data read fails), but that is being
cross-checked against macOS on the same machine before it is called dead — if
the same card reads under macOS, the reader silicon is fine and this reopens as
a Linux `sdhci` quirk problem. If anyone revisits it, the one
untried angle is whether macOS can read a card in this slot on this specific
machine — if macOS also cannot, the reader is simply dead and the row should be
removed from the hardware table rather than tracked as a gap.

Superseded (kept for the record): ChromeOS kernels carry a fixup for this
exact device (`{ PCI_VENDOR_ID_BROADCOM, 0x16bc, ... }` →
`SDHCI_QUIRK2_BROADCOM_REGISTERS`) that mainline has no equivalent of: an
undocumented PHY/data-path setup re-applied on **every `set_clock`** — clear bits
`0x3000` in register `0x198`; in `0x19c` clear `0x01a03f30`, set `0x00500000`,
and set bit 24 when `CTRL2 & VDD_180 && clock >= 200 MHz`. Those writes cannot be
expressed as a module parameter. On stock Linux this reader's data path is simply
left unconfigured, which matches the whole published BCM57765 corpus failing at
"Timeout waiting for Buffer Read Ready".

Origin: "[PATCH] mmc: disable UHS on broadcom sdhci", Stephen Hurd (Broadcom) via
Grant Grundler, 16 Nov 2013. Objected to over header placement and **never
merged**; it survives only in Chromium OS trees.

Also worth trying before the patch: disabling PCIe active-state power management
on the reader's root port. `tg3`, the Ethernet driver for the *same* BCM57765
silicon, documents no DMA errata for this chip but does carry PCIe link-power
workarounds and a `tg3_chk_missed_msi()` poll because the chip **drops
interrupts** — which is a better match for "timeout waiting for an interrupt"
than any DMA theory. The community workaround for this reader is
`setpci -s <bridge> 0x50.B=0x41`.

Superseded next steps (kept for the record): `debug_quirks2` UHS bits, and
forcing a lower bus speed or 1-bit width.
Everything was restored to stock (`debug_quirks=0`) afterwards. **Caution:**
unbinding `sdhci-pci` via sysfs while a card is failing wedges the writing process
in `D` state until the module is removed; use `modprobe -r` rather than
bind/unbind. That experiment also left this boot with a `W` kernel taint —
`WARNING drivers/mmc/host/sdhci.c:1180 sdhci_prepare_dma`, preceded by
`swiotlb ... overflow (mask 0)` because the DMA mask is not re-established after
a remove/re-probe — plus a logged 122 s hung task. Both are harmless and clear on
reboot; noted so nobody chases the WARN later as a real bug.

**Never worked, so not a regression:** 96 boots in the journal, zero `mmcblk`
devices ever, and only boot 0 had a card inserted.

Cleared 2026-09-07: the webcam needs no work — this model ships a standard USB
UVC camera (`05ac:8511`, `/dev/video0`), not the Broadcom PCIe part that needs
the reverse-engineered `facetimehd` driver. Nothing to patch.

## Thermals and stress testing (Phase 2, measured 2026-09-07)

Full run on the lean4 stack (srcversion 860A27A1), every load wrapped in a
watchdog sampling CPU/GPU/fan every 5 s and aborting at CPU > 95 °C or
GPU > 100 °C. Raw CSVs in `~/.cache/imac-phase2/`.

**The CPU sits at its design limit under any real load.** 4 cores at 100 % hit
97 °C in 30 s; at 60 % it hit 96 °C in 61 s; even 2 cores hit 96 °C by 171 s.
Five runs were aborted by the watchdog — three CPU runs plus the combined burn
and the RAM run. The ceiling is not mis-set — the SMC's
own control target *is* ~95 °C, so the plan's limit sits exactly where the
firmware deliberately holds the chip. **Consequence: a CPU endurance run cannot
be performed inside that safety envelope.** Raising it (TJmax is 100 °C and the
chip throttles itself) is a policy call for the user, not a silent change.

**The GPU is clean.** 25 minutes of 3D load total (5 min glmark2 @ 2560×1440,
score 7979; 20 min @ 1920×1080 endurance): zero GPU resets, zero ring timeouts,
zero amdgpu errors. `sclk` held its 1096 MHz maximum for all 61 samples of the
5-minute run and for 225 of 240 endurance samples (the other 15 dip to 976 or
1068 MHz, clustered away from the temperature peaks and consistent with
inter-scene idle rather than throttling). Endurance steady
state: GPU 80 °C avg / **95 °C peak**, CPU 84 °C avg (peak 95), fan ~1790 RPM.
Note the CPU
averages 84 °C, peaking at 95 °C, during a pure GPU load; the two share one cooling path, which
is why a combined burn trips the ceiling in 21 s. `power1_average` is not
exposed by this ASIC, so GPU power draw could not be logged.

**RAM** (`stress-ng --vm 2 --vm-bytes 8G --vm-method all`): 0 failures, but the
run was **aborted by the thermal watchdog at 25 s** of a planned 120 s, so this
is a 25-second pass, not a memory soak.
**Boot NVMe** (2 GB file, `--direct=1`): 3217 MB/s 1M read, 639 MB/s 1M write,
165 060 IOPS 4k random read at qd32. *No fio output was retained — re-run with
`--output-format=json` saved before citing these.* **10GbE**: link up at 10000 Mb/s but no
iperf3 peer answered, so throughput is untested. **VCE encode excluded** — it is
the known hang and belongs to its own track with the safe protocol.

Two notes for whoever repeats this. The original plan said "external boot SSD
only, internal disks skipped", written when Omarchy booted from external media;
the boot drive is now the internal NVMe, so that was benchmarked through a
temporary file and the SATA disks carrying macOS filesystems were left alone.
And Omarchy's `omarchy.idle` plugin was disabled for the duration
(`omarchy-shell shell setPluginEnabled 'omarchy.idle' 'false'`) so the
screensaver could not interfere, then re-enabled.

## Housekeeping

- Upload `.github/social-preview.png` in GitHub Settings → Social preview
  (no API for this; must be done in the web UI).
- **Done 2026-09-07:** swept 215 MB of stale ESP backups
  (`BOOTX64.EFI.pre-boot-artifacts-backup`, `BOOTX64.UKI.BACKUP`,
  `BOOTX64.UKI-bypass.backup`) after confirming `BOOTX64.EFI` is byte-identical
  to `limine_x64.efi`. `/boot` usage 764 M → 549 M.
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

Confirmed by the user from the two observed routes:

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

**Seen again 2026-09-07 00:01, default build** (boot 1a2565…-successor, kernel
7.1.9-arch1-2, full stack + all five increments): desktop sheared after login
while the driver reports both tile streams `sync_enabled=1` from the 22.3 s
commit onward and the 250 ms settle re-sync agreed; no later modeset, no
re-detect loop (7 detects, 0 re-trainings). So the driver's bookkeeping and
the panel disagree — the same shape as before the settle-resync. The two
lean-pair boots just before it (23:59, 00:00, same logic minus logging and
DPCD read-backs, plus the 9-byte tile-group fix) were clean; one sample each,
not evidence of a difference yet. Worth running the lean entry for several
boots to see whether the shear ever shows there. Workaround unchanged:
`hyprctl reload` forces a modeset.


The artifact that actually bites in daily use, distinct from the boot-time ones.
The mode is a correct 5120x2880 throughout; what is lost is sync — the slave
stream's `sync_enabled` flips to 0 on some modeset and the two tiles scan out
of phase, which reads as a skewed/sheared seam. Calibrated against the user's
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

**Settled 2026-09-07 by measurement** (see "Thermals" below): the SMC ramps the
fan on its own *and closes the loop* — under a 2-core burn it went 1200 → 1852 RPM
over 76 s and then held the CPU flat at 93–95 °C instead of letting it climb. It
is slow to start (25 s at minimum while the CPU is already at 94 °C) and never
exceeded 1941 of 2700 RPM. So a daemon is not needed for safety; it would only
buy the unused ~800 RPM at the cost of noise. Rejection stands.
