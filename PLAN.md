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

## Phase 5 — Deliverable

`setup-imac18-3.sh`: idempotent, hardware-gated (refuses non-iMac18,3), applying every
settled fix — boot cmdline + 3-way sync + name-based `default_entry`, audio DKMS,
speaker EQ, `cm=dp3`, suspend masking, boot-picker naming — plus Phase 4 additions,
ending with a verify step. README updated to point at it.

## Needed from the user

SD card + Ethernet cable (Phase 1) · a scheduled reboot window (Phase 3) · a go-ahead
for Phase 2 at a time when a hot/loud machine for ~45 min is acceptable.
