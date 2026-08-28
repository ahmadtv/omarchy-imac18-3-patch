# Omarchy on a 2017 27-inch 5K iMac (iMac18,3)

Working notes and reproducible fixes for running Omarchy from an external SSD on an Intel iMac18,3 while preserving macOS/OpenCore on the internal disk.

## Hardware tested

- Apple iMac18,3 (27-inch, 2017)
- Intel Core i5, 40 GB RAM
- AMD Radeon Pro 575 4 GB (`1002:67df`, Polaris/Ellesmere)
- Omarchy 4.0.1 on an external 2 TB WD My Passport SSD
- OWC Thunderbolt 3 10G Ethernet Adapter
- Linux 7.1.9, Hyprland 0.56.2, Aquamarine 0.14.0

The internal macOS/OpenCore disk was kept out of scope throughout installation and repair.

## Current status

| Component | Status |
|---|---|
| External Omarchy installation | Working |
| LUKS unlock and graphical boot | Working |
| Radeon Pro 575 acceleration | Working with `amdgpu` |
| OWC Thunderbolt 10GbE | Working at 10 Gb/s |
| Wi-Fi profile conflict | Resolved |
| Native 5120×2880 display | Not supported by the current Linux/Aquamarine tile path |
| 3840×2160 panel-scaled fallback | Installed in boot configuration; reboot verification pending |

## 1. Original black-screen problem

Omarchy reached disk decryption, then the internal display went black during the graphics handoff. The machine is an iMac18,3 with a Radeon Pro 575, not the older iMac17,1/R9 M380. Do not copy the older CIK/radeon workaround (`amdgpu.cik_support`, `radeon.cik_support`, or `amdgpu.dc=0`) onto this Polaris GPU.

The relevant observations were:

- The Radeon Pro 575 is natively supported by `amdgpu`.
- Omarchy regenerated `/boot/limine.conf`, so editing that generated file directly was not persistent.
- `quiet splash` returned after regeneration and could retrigger a Plymouth/greeter graphics-handoff failure.
- Persistent kernel arguments belong in `/etc/default/limine`, followed by `limine-mkinitcpio`.

## 2. Persistent boot fix

Back up the existing configuration first:

```bash
sudo cp /etc/default/limine /etc/default/limine.backup
```

Use [configs/limine.example](configs/limine.example) as a template. Keep the root and resume values from your own existing configuration—never copy another machine's UUID, PARTUUID, mapper, or resume offset.

Important changes:

- Use `KERNEL_CMDLINE[default]="..."`, not `+=`, to replace Omarchy's drop-in command line and prevent `quiet splash` from being appended again.
- Preserve the machine's existing root, encryption, Btrfs, resume, and `initramfs_async=0` parameters.
- Add:

```text
amdgpu.dc=1 amdgpu.exp_res_limit=1 video=eDP-1:3840x2160@60e
```

- Do not include `quiet splash`.

Rebuild the unified kernel image and Limine entry:

```bash
sudo limine-mkinitcpio
```

Verify the generated entry before rebooting:

```bash
sudo grep 'cmdline:' /boot/limine.conf
```

After reboot, verify:

```bash
cat /proc/cmdline
lspci -nnk | grep -A3 -i 'vga\|display'
hyprctl monitors all
hyprctl configerrors
```

Expected GPU driver:

```text
Kernel driver in use: amdgpu
```

## 3. Why the 5K panel appears skewed

The iMac panel is a tiled display, not a conventional single-stream 5K output. Its EDID reports:

- Two horizontal tiles, one vertical tile
- Each tile is 2560×2880
- Combined native framebuffer is 5120×2880
- When only the primary tile is driven, the panel can scale that image across the whole display
- Standalone scaled timings include 3840×2160, 3200×1800, and 2560×1440

Read-only DRM inspection showed two active CRTCs at `(0,0)` and `(2560,0)`, each 2560×2880, while Hyprland exposed only one 2560×2880 output. That mismatch makes the desktop look stretched/skewed.

Hyprland/Aquamarine currently cannot stitch this genuine two-stream iMac panel into one 5120×2880 Wayland output. Forcing modes from Hyprland after startup did not work reliably because the kernel had already activated the tiled layout. The practical workaround is therefore the kernel boot parameter:

```text
video=eDP-1:3840x2160@60e
```

This 4K fallback is supported by the panel's own EDID and should be tested after reboot. Do not persist a Hyprland `3200x1800` override; it looked more distorted during testing.

The user Hyprland monitor configuration was restored to Omarchy's safe default:

```lua
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
```

## 4. OWC Thunderbolt 10GbE fix

The adapter initially appeared in `boltctl` but was only connected, not stored or authorized. Consequently, its Aquantia PCI Ethernet controller did not exist in `lspci` or NetworkManager.

Identify the adapter:

```bash
boltctl list
```

Enroll it persistently, substituting the UUID shown by `boltctl`:

```bash
boltctl enroll YOUR-OWC-THUNDERBOLT-UUID --policy auto
```

Verify:

```bash
boltctl info YOUR-OWC-THUNDERBOLT-UUID
lspci -nnk | grep -A4 -i 'ethernet\|aquantia'
ip -brief link
nmcli device status
```

Expected hardware and driver:

```text
Aquantia AQC107S 10G Ethernet Controller
Kernel driver in use: atlantic
```

The tested interface appeared as `enp11s0`. The kernel confirmed a 10,000 Mb/s Ethernet link, while Thunderbolt negotiated 40 Gb/s (two 20 Gb/s lanes).

## 5. Wi-Fi and Ethernet conflict

With Wi-Fi and 10GbE connected to the same subnet, NetworkManager detected an IPv4 address conflict through the Wi-Fi MAC and withheld the wired default route. The Ethernet link and gateway were reachable, but internet traffic still followed Wi-Fi.

Because Ethernet was the desired primary connection, Wi-Fi was disabled and the wired profile renewed:

```bash
nmcli radio wifi off
nmcli connection down 'Wired connection 2'
nmcli connection up 'Wired connection 2'
```

The saved Wi-Fi profile was then deliberately removed:

```bash
nmcli connection delete id 'YourWifiNetworkName'
```

Do not copy that last command verbatim—replace the id with your own saved Wi-Fi profile name, and only run it if you intentionally want to forget that network.

Verification:

```bash
ip -4 route
nmcli device status
ping -I enp11s0 -c 3 1.1.1.1
```

The working result had a DHCP address, a default route through `enp11s0`, successful DNS, and successful internet pings.

## 6. Recovery and rollback

If the new 4K boot mode causes a black screen:

1. In Limine, boot the known-good snapshot entry.
2. Restore `/etc/default/limine.backup`.
3. Run `sudo limine-mkinitcpio` again.
4. Reboot.

Alternatively, edit the Limine entry temporarily and remove only:

```text
video=eDP-1:3840x2160@60e
```

Do not edit or mount the internal macOS/OpenCore disk while troubleshooting the external Omarchy installation.

## 7. Post-reboot checklist

Run:

```bash
./scripts/verify.sh
```

Confirm visually that:

- The desktop is no longer horizontally or vertically stretched.
- Hyprland reports 3840×2160 around 60 Hz.
- The OWC adapter reconnects automatically after a cold boot.
- `enp11s0` receives DHCP and owns the default route.

## Upstream references

- [Hyprland monitor configuration](https://wiki.hypr.land/0.55.0/Configuring/Basics/Monitors/)
- [Aquamarine tiled 5K modesetting issue #59](https://github.com/hyprwm/aquamarine/issues/59)
- [Aquamarine redundant-tile handling PR #238](https://github.com/hyprwm/aquamarine/pull/238)
- [Aquamarine standalone-capable tile proposal #354](https://github.com/hyprwm/aquamarine/pull/354)
- [Omarchy iMac17,1 discussion—useful context, but not the same GPU](https://github.com/basecamp/omarchy/discussions/5151)

