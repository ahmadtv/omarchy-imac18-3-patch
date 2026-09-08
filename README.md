<div align="center">

# 🖥️ Omarchy on iMac 5K (18,3)

**Omarchy on the 2017 27″ 5K iMac (iMac18,3) — running the way it should.**

![hardware](https://img.shields.io/badge/hardware-iMac18,3-111?logo=apple&logoColor=white)
![display](https://img.shields.io/badge/display-5120×2880-e91e63)
![kernel](https://img.shields.io/badge/kernel-7.1–7.2-1f6feb?logo=linux&logoColor=white)
[![built for Omarchy](https://img.shields.io/badge/built_for-Omarchy-7c3aed?logo=archlinux&logoColor=white)](https://omarchy.org)
![reversible](https://img.shields.io/badge/every_change-reversible-2ea043)
![license](https://img.shields.io/badge/license-MIT-555)

![iMac18,3 Patch — native 5120×2880, working speakers and mic, true wide-gamut colour](.github/social-preview.png)

</div>

Native **5120×2880**, real **speakers and mic**, true **wide-gamut colour** — the hardware Apple leaves half-asleep for everyone but macOS, woken up. **One command. Every change reversible. Nothing touched without asking.**

[Omarchy](https://omarchy.org)'s whole promise is *“we can fix everything.”* This points that at a 2017 iMac.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ahmadtv/omarchy-imac5k/main/install)
```

> For the **2017 27-inch iMac (iMac18,3)**. Built and tested on Omarchy (Arch + Hyprland); the audio, colour and EQ pieces are largely distro-agnostic.

---

## ✨ What this patch makes work

| | |
|---|---|
| 🖥️ **Native 5K** | Full **5120×2880**. The panel is two 2560×2880 tiles Apple leaves dormant; this wakes the second one, stitches both into one display, and genlocks them so they scan in lockstep — seamless under motion. |
| 🔊 **Speakers & mic** | The CS8409 codec the kernel can't drive at all — now with working speakers and both the internal **and** headset mic, with **automatic switching** on plug/unplug just like macOS. |
| 🎧 **Apple EarPods** | Fully supported. Plug them in and audio + mic follow the jack; unplug and it's back to internal — automatically. All three **inline buttons** work too: play/pause, volume up, volume down. |
| 🎚️ **macOS-style sound** | The codec does zero DSP; macOS's warmth is pure software EQ. A PipeWire profile brings it back. |
| 🎨 **True colour** | The wide-gamut **Display P3** panel mapped correctly, instead of the oversaturated mess of stock sRGB. |

## 🖥️ On the machine

The patcher on a fully set-up iMac18,3 — everything applied:

![imac-patcher menu, every patch applied](docs/patcher-menu.png)

…and what that gets you — `fastfetch` on the running 5K desktop:

![fastfetch on the 5K desktop: 5120×2880 genlocked, patched amdgpu, CS8409 audio](docs/system-info.png)

## ✅ Already fine out of the box

No patch needed — these just work on Omarchy / Linux:

🌐 Ethernet · 📶 Wi-Fi · 🔷 Bluetooth · 📷 Webcam · ⌨️ Keyboard & trackpad · 🔌 USB · ⚡ Thunderbolt / 10GbE

Thunderbolt is on the in-tree `atlantic`/`thunderbolt` drivers — tested with an **OWC Thunderbolt 3 10GbE** adapter. Like on any Linux box, a Thunderbolt device needs a one-time authorization the first time you plug it in (`boltctl enroll`, or your desktop's prompt); after that it's remembered. Nothing this patch does — just how Thunderbolt security works.

## 🚫 Not working (yet)

Straight about the gaps:

- 💳 **SD / memory-card reader** — not working yet. The card is recognised, then every read fails at the data phase; **still being worked on** — cross-checking against macOS on the same machine to tell a driver quirk from a genuine hardware fault.
- 🔆 **Auto-brightness** — the ambient-light sensor is present but not wired to the backlight.
- 😴 **Suspend / sleep** — hard-hangs the machine (Apple firmware); masked off so nothing triggers it by accident.
- 🎬 **Video encode (VCE)** — hangs the GPU on some transcodes; under investigation.

---

## 🧩 Install

The one-liner above clones the patcher and opens its menu. Or do it by hand:

```bash
git clone https://github.com/ahmadtv/omarchy-imac5k
cd omarchy-imac5k && ./scripts/imac-patcher
```

The patcher shows what's applied, what isn't, and lets you pick — **nothing is applied without asking**. Omakase in spirit: sensible defaults, and you can send any of it back. Each piece is a separate, reversible step:

```bash
./scripts/imac-patcher --apply 5k      # native 5K (rebuilds only the amdgpu module)
./scripts/imac-patcher --apply audio   # speakers, mics, EarPods + buttons
./scripts/imac-patcher --remove 5k     # full undo, any time
```

**The 5K module needs kernel 7.1.x or 7.2.x** and the patcher refuses anything else — a mis-applied GPU patch means a broken display, so a newer kernel must be re-ported by hand first. You supply nothing else: the installer fetches the matching kernel source itself (≈8 GB, ~20–40 min the first build; re-runs are fast). Re-run after any kernel update.

Audio uses the same model — it clones the upstream [jackdanyell](https://github.com/jackdanyell/imac18-3-cs8409-linux-audio) driver at the verified commit and applies [`patches/cs8409-headset-capture.patch`](patches/cs8409-headset-capture.patch) on top, then DKMS-builds it so it survives kernel updates.

> **Not on Omarchy?** Mark Pronkin maintains a universal fork — [`imac5k-universal-linux-patcher`](https://github.com/MarkPronkin/imac5k-universal-linux-patcher) — with one-command install/update, automatic dependency install, and preliminary Fedora support (more distros in progress).

---

## ⚠️ Before you touch suspend

Suspend and hibernate **hard-hang this machine, every time** — an Apple firmware ACPI issue no kernel parameter fixes; recovery is a hard power-cycle. The patcher masks the sleep targets so nothing triggers them by accident:

```bash
sudo systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

## 🛟 Safety

Every patch backs up what it replaces and can be reversed. Boot-related changes print their recovery steps first. A new `amdgpu` build never has to replace the working one to be tried — `scripts/imac-alt-entry` boots it from its own hash-pinned Limine entry with the default untouched. See [`patches/README.md`](patches/README.md).

## 🔬 Under the hood

- **Native 5K, the three layers (wake · stitch · genlock)** and the install rules → [`patches/README.md`](patches/README.md)
- **Open items, root causes and rejected approaches** → [`TODO.md`](TODO.md)

## 🤝 Contributing

On an **iMac18,3** and hit a bug, or made part of this better? [Open an issue or PR](../../issues) — I'll pull in what's solid.

## 🙏 Credits

Native 5K builds on community work from [drm/amd#4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) — mforce2 (tile wake), erik2 (stitch), taprobane99 (7.2.x port), with guidance from AMD's Alex Deucher. The genlock fix and the first verified iMac18,3 result came from this project. Audio driver by [jackdanyell](https://github.com/jackdanyell/imac18-3-cs8409-linux-audio). Multi-distro fork by [Mark Pronkin](https://github.com/MarkPronkin/imac5k-universal-linux-patcher).

---

_Omarchy’s promise is “we can fix everything.” This is one more thing, fixed._
