# Plan: 100% iMac18,3 hardware compatibility for Omarchy

Goal: one public, reproducible script — `setup-imac18-3.sh` — that takes a stock
Omarchy install on an iMac18,3 to full hardware compatibility, encoding every fix
from this project. This file is the working plan; the README stays settled-state only.

## Phase 0 — Inventory & current status (done)

| Component | Status |
|---|---|
| CPU (Kaby Lake i5) | ✅ works — thermals under load untested |
| GPU display | ✅ 3840×2160 fallback · 🚧 native 5K (separate session) |
| GPU color | ✅ fixed (`cm=dp3`) |
| GPU video encode (VCE) | ❌ hangs → full GPU reset (see `~/projects/vce-polaris-hang-brief.md`) |
| GPU video decode (UVD) | ✅ proven safe |
| Speakers/mic (CS8409) | ✅ fixed (DKMS + EQ) |
| HDMI audio out (GPU) | ❓ untested |
| FaceTime camera | ✅ works |
| Wi-Fi (BCM43602) | ⚠️ works, missing `clm_blob` firmware → limited channels |
| Built-in GbE Ethernet | ❓ detected, untested (needs cable) |
| SD card reader (BCM57765) | ❓ driver binding unknown, untested (needs card) |
| Thunderbolt 3 | ✅ works (OWC 10GbE enrolled) |
| Bluetooth | ⚠️ controller up — pairing/audio untested |
| Backlight control | ❓ `acpi_video0` exists, unverified — classic iMac gap |
| SMC fans + ~90 temp sensors | ✅ readable via `applesmc` — fan auto-ramp under load unknown (critical test) |
| Ambient light sensor | ❓ check applesmc `light` interface |
| Suspend/hibernate | ❌ broken, masked (settled) |
| Internal NVMe/SATA disks | detected; internal disks stay off-limits |

## Phase 1 — Functional tests (safe, quick)

Backlight up/down + revert · SD reader (user provides card) · Bluetooth pairing ·
built-in Ethernet (user provides cable) · HDMI audio probe · Wi-Fi `clm_blob`
firmware fix + channel verification · ambient light sensor check · full USB map.

## Phase 2 — Stress & stability (instrumented)

Every run wrapped in a thermal watchdog: log CPU pkg / GPU edge / fan RPM every 5 s,
auto-abort at CPU >95 °C or GPU >100 °C.

1. CPU burn (stress-ng, all cores, 3 min) — key question: does the SMC ramp the fan
   autonomously under Linux? If not, the patch needs a fan daemon (mbpfan-class).
2. GPU 3D burn (glmark2) — temps, power, clocks, no resets under 3D load.
3. Combined CPU+GPU burn (short), then ~30 min reduced-intensity endurance.
4. RAM stress (stress-ng VM workers).
5. Disk bench — external boot SSD only (fio); internal disks skipped.
6. Network — 10GbE iperf3 only if a peer device exists; otherwise skipped.
7. Explicitly excluded: any VCE encode in-session (Phase 3's safe protocol only).

Idle baseline (2026-09-02): CPU pkg 62 °C, GPU edge 57 °C, fan 1200 RPM (min; max 2700).

## Phase 3 — VCE encode hang fix (separate track)

Per `~/projects/vce-polaris-hang-brief.md`: parameter bisection against the confirmed
reproducer + the kernel "VCE VM mode" lead, run under the safe protocol
(`multi-user.target` + SSH/console, scheduled reboot window — GPU resets cost nothing
there). Reproducer confirmed properties so far: H.264 Constrained Baseline 1920×1160,
GOP 250 (keyframe every 8.33 s), no audio stream.

## Phase 4 — Fix what Phases 1–2 surface

Fan daemon if needed · Wi-Fi firmware · backlight fix · SD/BT/HDMI fixes as found.

## Phase 5 — Deliverable: TUI patch manager

Not a monolithic script — a patch *manager*: `imac-patcher` (bash + `gum`, which
Omarchy already ships; CLI flags `--status/--all/--only/--remove` as headless
fallback, plain prompts if gum is absent).

**Architecture.** Every patch is a module implementing a 4-function contract:
`detect` (applied? applicable?) · `apply` · `remove` · `verify`. The TUI is a loop
over the registry — status display, idempotency, selective apply, and removal all
fall out of this one contract. Reversibility is mandatory metadata.

**UX flow.** (1) DMI hardware gate: iMac18,3 or exit unless `--force`.
(2) Status table always shown first: `✓ applied · ✗ not applied · ⚠ partial · — n/a`.
(3) Three tiers:
  - **Safe** (pre-selected, fully reversible): audio DKMS, speaker EQ, `cm=dp3`,
    boot-picker naming, suspend mask, Wi-Fi firmware.
  - **Boot-critical** (pre-selected, flagged): cmdline + 3-way sync +
    `default_entry`. Auto-backup of every touched file; recovery steps printed
    BEFORE applying (lesson from the original install black screen).
  - **Experimental** (never pre-selected): 5K fix (first candidate, once the other
    session lands it; labeled untested-on-18,3 until proven; revert = boot the
    previous kernel/snapshot entry), VCE fixes when ready. No working revert →
    refused from this tier entirely.
(4) Simple run = apply all defaults with one confirm; advanced = multi-select.
(5) Remove mode lists only applied+reversible patches, runs `remove`, re-verifies.

**Portability.** Hardware gate and distro adapter are separate layers. Audio/EQ/color
patches are near distro-agnostic (any systemd+PipeWire Arch); boot patches get an
`omarchy` (Limine) backend now, contract leaves room for grub/systemd-boot backends
later. Launch target: Omarchy, tested. README updated to point at the tool.

## Needed from the user

SD card + Ethernet cable (Phase 1) · a scheduled reboot window (Phase 3) · a go-ahead
for Phase 2 at a time when a hot/loud machine for ~45 min is acceptable.
