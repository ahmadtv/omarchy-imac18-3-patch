# Omarchy on a 2017 27" 5K iMac (iMac18,3)

External-SSD Omarchy install, dual-boot with macOS/OpenCore on the internal disk (not touched).

## Hardware

- iMac18,3, AMD Radeon Pro 575 (Polaris, `1002:67df`, DCE 11.2)
- Omarchy on external SSD, Linux 7.1.9, Hyprland 0.56.2

## Status

| | |
|---|---|
| Boot, display (3840×2160 fallback), audio, network, color | ✅ working |
| Native 5120×2880 | 🚧 not supported (upstream `amdgpu` gap) |
| Suspend / hibernate | ❌ broken, masked off |

## Settled

**Boot cmdline** — lives in `/etc/default/limine`, not `/etc/kernel/cmdline`:
```
KERNEL_CMDLINE[default]="<your root/crypt/resume params> amdgpu.dc=1 amdgpu.exp_res_limit=1 amdgpu.runpm=0 video=eDP-1:3840x2160@60e quiet splash"
```
Rebuild, then **always sync all copies** (three `limine.conf`s + the fallback UKI — otherwise a fix silently won't take effect):
```bash
sudo limine-mkinitcpio
sudo cp /boot/limine.conf /boot/EFI/BOOT/limine.conf /boot/EFI/limine/limine.conf
sudo cp /boot/EFI/Linux/omarchy_linux.efi /boot/EFI/BOOT/BOOTX64.EFI
```
`default_entry` targets by name, not a numeric index (index can silently drift to an old snapshot):
```
default_entry: Omarchy/linux
```

**Boot picker naming** — named EFI entry + FAT label (top-level firmware picker):
```bash
sudo efibootmgr --create --disk /dev/sdX --part 1 --label "Omarchy" --loader '\EFI\limine\limine_x64.efi'
sudo fatlabel /dev/sdX1 OMARCHY
```
OpenCore's own internal picker (separate from the above) reads these, placed on the same external ESP:
```bash
sudo cp omarchy.icns /boot/EFI/Linux/omarchy_linux.efi.icns
printf 'OMARCHY' | sudo tee /boot/EFI/Linux/.contentDetails
```

**Display** — native 5K needs `amdgpu` to combine two tile links; it doesn't yet. Fallback is the `video=` param above (3840×2160, correct proportions, not native res).

**Color** — panel is wide-gamut (Display P3); default `srgb` mode oversaturates. In `~/.config/hypr/monitors.lua`:
```lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale, cm = "dp3" })
```

**Audio** (CS8409 codec):
```bash
git clone https://github.com/jackdanyell/imac18-3-cs8409-linux-audio.git
cd imac18-3-cs8409-linux-audio && sudo ./install-imac18-3.sh && sudo reboot
```

**OWC Thunderbolt 10GbE**:
```bash
boltctl enroll <uuid-from-boltctl-list> --policy auto
```

**Wi-Fi/Ethernet conflict** — disable Wi-Fi, keep Ethernet primary:
```bash
nmcli radio wifi off
```

**Suspend/hibernate** — broken (Apple firmware ACPI S3 issue, not fixable via kernel params). Masked:
```bash
sudo systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

## Still open

- **Native 5K** — tracked upstream: [`drm/amd#4455`](https://gitlab.freedesktop.org/drm/amd/-/issues/4455)
- **Suspend/hibernate** — no fix short of custom ACPI/DSDT work
- **OpenCore-internal boot entry** — not retested since the latest boot-config fixes

## Recovery

Boot breaks → boot the Limine snapshot entry → restore `/etc/default/limine.backup` → `sudo limine-mkinitcpio` → re-sync (above) → reboot.

## Note

Multiple assistants/agents can end up editing this machine's boot files concurrently (this repo included) — if a fix seems to silently un-apply, check for stray `.disabled` files under `/boot/EFI/` before assuming the fix is wrong.
