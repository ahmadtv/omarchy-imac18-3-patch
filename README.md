# Omarchy on a 2017 27" 5K iMac (iMac18,3)

External-SSD Omarchy install, dual-booting with macOS/OpenCore on the internal disk. The internal disk is never touched — every fix here lives on the external drive.

## Hardware

- Apple iMac18,3 (27", 2017)
- AMD Radeon Pro 575 (Polaris, `1002:67df`, DCE 11.2 — not the older iMac17,1/R9 M380, and not a newer DCN-generation card)
- Omarchy on an external SSD, Linux 7.1.9, Hyprland 0.56.2

## Status

| | |
|---|---|
| Boot, display (3840×2160 fallback), audio, network, color | ✅ working |
| Native 5120×2880 | 🚧 not supported yet (upstream `amdgpu` gap) |
| Suspend / hibernate | ❌ broken, masked off |

Run `./scripts/verify.sh` any time to check kernel cmdline, GPU driver, monitor state, Thunderbolt, and networking in one shot.

## Settled

### Boot cmdline

The kernel command line lives in `/etc/default/limine`, **not** `/etc/kernel/cmdline`:

```
KERNEL_CMDLINE[default]="<your root/crypt/resume params> amdgpu.dc=1 amdgpu.exp_res_limit=1 amdgpu.runpm=0 video=eDP-1:3840x2160@60e quiet splash"
```

(Template: [`configs/limine.example`](configs/limine.example) — keep your own root/encryption/resume values, never copy another machine's.) Do **not** use the older iMac17,1-era workaround (`amdgpu.cik_support`, `radeon.cik_support`, `amdgpu.dc=0`) on this Polaris GPU — wrong hardware generation, will make things worse.

Rebuild, then **always sync every copy** — this ESP has three separate `limine.conf` files plus a fallback UKI, and only one gets updated automatically. Skipping this is the single most common reason a fix silently doesn't apply:

```bash
sudo limine-mkinitcpio
sudo cp /boot/limine.conf /boot/EFI/BOOT/limine.conf /boot/EFI/limine/limine.conf
sudo cp /boot/EFI/Linux/omarchy_linux.efi /boot/EFI/BOOT/BOOTX64.EFI
```

`default_entry` should target by name, not a numeric index — the index can silently drift to point at an old snapshot as new snapshots accumulate:

```
default_entry: Omarchy/linux
```

### Boot picker naming

Top-level firmware picker (hold Option at power-on) needs a named EFI entry and a FAT volume label, or it shows a blank/"NO NAME" icon:

```bash
sudo efibootmgr --create --disk /dev/sdX --part 1 --label "Omarchy" --loader '\EFI\limine\limine_x64.efi'
sudo fatlabel /dev/sdX1 OMARCHY
```

OpenCore's own internal menu is a *separate* picker with its own auto-detection — it doesn't read either of the above. Fix it the same way, with files on this same external ESP (no internal-disk edits needed):

```bash
sudo cp omarchy.icns /boot/EFI/Linux/omarchy_linux.efi.icns
printf 'OMARCHY' | sudo tee /boot/EFI/Linux/.contentDetails
```

### Display

The panel is a tiled display — two 2560×2880 links that combine into 5120×2880 natively. `amdgpu` doesn't yet link-train and combine the second link, so the desktop looks stretched unless a supported single-stream mode is forced. The `video=` parameter above (3840×2160) is that fallback — correct proportions, not native resolution.

### Color

The panel is wide-gamut (Display P3); Hyprland's default `srgb` color mode doesn't gamut-map for it, so everything looks oversaturated. Fixed in `~/.config/hypr/monitors.lua`:

```lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale, cm = "dp3" })
```

### Audio (CS8409 codec)

The in-kernel driver doesn't recognize a real speaker output on this board. Fix is a hardware-gated, model-specific DKMS driver:

```bash
git clone https://github.com/jackdanyell/imac18-3-cs8409-linux-audio.git
cd imac18-3-cs8409-linux-audio && sudo ./install-imac18-3.sh && sudo reboot
```

### Speaker tone (bass/treble)

This codec+amp path does zero processing (confirmed by the driver author) — macOS's fuller sound comes entirely from its own software EQ, which Linux has no equivalent of by default. Fixed with a PipeWire filter-chain EQ (native module, nothing extra installed): low-shelf bass boost, a couple of small corrective bands, and a `clamp` at the end so the boost can't cause digital clipping on bass-heavy audio. Template: [`configs/eq6.conf`](configs/eq6.conf) → copy to `~/.config/pipewire/filter-chain.conf.d/eq6.conf`. Creates a selectable "iMac Speaker EQ" output device; select it (or set as default) to hear it.

After enabling it, also re-check `wpctl get-volume` on the underlying hardware sink (`Built-in Audio Analog Stereo`) — it keeps its own independent volume, and if it's left at an old lower value your volume slider will silently cap out below 100%.

### OWC Thunderbolt 10GbE

Shows up in `boltctl` but stays unauthorized until enrolled:

```bash
boltctl enroll <uuid-from-boltctl-list> --policy auto
```

### Wi-Fi / Ethernet conflict

Running both on the same subnet, NetworkManager can withhold the wired default route in favor of Wi-Fi. Disable Wi-Fi to keep Ethernet primary:

```bash
nmcli radio wifi off
```

### Suspend / hibernate

Both hard-hang the machine every time — an Apple firmware ACPI S3 issue, not fixable via kernel parameters. Masked off rather than left to fail on accidental use:

```bash
sudo systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

## Still open

- **Native 5K** — a working out-of-tree kernel fix now exists (DPCD `0x4F1` wake of the hidden second tile link; portable patches for kernels 7.0.x and 7.2.2 posted upstream 2026-08-30). This panel (`APP 0xAE11`) is explicitly covered by the patch but **no iMac18,3 has tested it yet** — this machine would be the first. Catch: only GNOME/Mutter can stitch the two tiles today; Hyprland can't (would show two side-by-side 2560×2880 outputs). Full record, mechanism, model matrix, debunked dead ends, and a test plan: [`notes/5k-display-investigation.md`](notes/5k-display-investigation.md). Tracked upstream: [`drm/amd#4455`](https://gitlab.freedesktop.org/drm/amd/-/issues/4455)
- **Suspend/hibernate** — no fix short of custom ACPI/DSDT work
- **OpenCore-internal boot entry** — not retested since the latest boot-config fixes

## Recovery

If a boot change breaks something: boot the Limine snapshot entry → restore `/etc/default/limine.backup` → `sudo limine-mkinitcpio` → re-sync (above) → reboot. Never mount or edit the internal macOS/OpenCore disk while troubleshooting this external install.

## Note

Multiple assistants/agents can end up editing this machine's boot files concurrently. If a fix seems to silently un-apply, check for stray `.disabled` files under `/boot/EFI/` before assuming the fix itself is wrong.
