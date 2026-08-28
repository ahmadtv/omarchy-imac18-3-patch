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
| Native 5120×2880 display | Not supported by the current Linux/Aquamarine tile path (tracked upstream, see below) |
| 3840×2160 panel-scaled fallback | Working, verified after reboot |
| Internal speakers and mic (CS8409) | Working, via out-of-tree DKMS driver |
| Boot entry in firmware picker | Named `Omarchy` entry registered, no more guessing at unlabeled icons |

## 1. Original black-screen problem

Omarchy reached disk decryption, then the internal display went black during the graphics handoff. The machine is an iMac18,3 with a Radeon Pro 575, not the older iMac17,1/R9 M380. Do not copy the older CIK/radeon workaround (`amdgpu.cik_support`, `radeon.cik_support`, or `amdgpu.dc=0`) onto this Polaris GPU.

The relevant observations were:

- The Radeon Pro 575 is natively supported by `amdgpu`.
- Omarchy regenerated `/boot/limine.conf`, so editing that generated file directly was not persistent.
- `quiet splash` returned after regeneration and could retrigger a Plymouth/greeter graphics-handoff failure.
- Persistent kernel arguments belong in `/etc/default/limine`, followed by `limine-mkinitcpio`.

## 2. Persistent boot fix

**Critical correction:** editing `/etc/default/limine` alone is not enough on this Omarchy setup. Omarchy builds a Unified Kernel Image (UKI) with `limine-mkinitcpio`, and that UKI has a kernel command line **embedded directly into it** at build time, sourced from `/etc/kernel/cmdline`—not from Limine's per-entry `cmdline:` line in `limine.conf`. The systemd-stub boot process uses the embedded value, so a `limine.conf` edit alone can silently have no effect even after a real reboot. Fix **both** files, in this order:

1. Edit `/etc/kernel/cmdline` (the actual source baked into the UKI):

```bash
sudo cp /etc/kernel/cmdline /etc/kernel/cmdline.bak
```

Add the following to the existing line in `/etc/kernel/cmdline` (keep your own root/encryption/resume values—never copy another machine's PARTUUID or resume offset):

```text
amdgpu.dc=1 amdgpu.exp_res_limit=1 video=eDP-1:3840x2160@60e
```

2. Also update `/etc/default/limine` for consistency (keeps `limine.conf`'s displayed entry in sync, and matters if Omarchy ever changes the UKI build to prefer the bootloader-supplied cmdline):

```bash
sudo cp /etc/default/limine /etc/default/limine.backup
```

Use [configs/limine.example](configs/limine.example) as a template.

- Use `KERNEL_CMDLINE[default]="..."`, not `+=`, to replace Omarchy's drop-in command line and prevent `quiet splash` from being appended again.
- Preserve the machine's existing root, encryption, Btrfs, resume, and `initramfs_async=0` parameters.
- Do not include `quiet splash`.

3. Rebuild the UKI and Limine entry (this re-embeds the new `/etc/kernel/cmdline` into the image):

```bash
sudo limine-mkinitcpio
```

4. Verify the cmdline that will actually boot is embedded in the UKI itself—do not trust `limine.conf` alone:

```bash
sudo objcopy -O binary --only-section=.cmdline /boot/EFI/Linux/omarchy_linux.efi /dev/stdout
```

The output must contain `video=eDP-1:3840x2160@60e`. If it doesn't, the rebuild didn't pick up `/etc/kernel/cmdline`.

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

### Selecting the boot entry at startup

This external SSD has no NVRAM boot entry by default, so the firmware's boot picker shows it as a blank/unlabeled icon. Register a proper named entry once, so it's unambiguous going forward:

```bash
sudo efibootmgr --create --disk /dev/sdX --part 1 --label "Omarchy" --loader '\EFI\BOOT\BOOTX64.EFI'
```

Replace `/dev/sdX` with the external SSD's device (check with `lsblk`; the ESP is the small `vfat` partition mounted at `/boot`). After this, at every boot: hold **Option** at power-on to bring up the firmware's boot picker, and select the entry labeled **Omarchy**.

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

## 6. Internal speakers and microphone (CS8409 codec)

The iMac18,3 uses a Cirrus Logic CS8409 HDA codec (subsystem ID `0x106b1000`). The in-kernel driver's generic autoconfig does not recognize a real speaker output complex on this board:

```bash
cat /proc/asound/card0/codec#0 | grep -i subsystem
journalctl -k -b | grep -i cs8409
```

Kernel log shows `speaker_outs=0` despite two pins typed `speaker`—a known gap for this exact machine, not a volume/mute misconfiguration.

Fix: install the out-of-tree, hardware-gated DKMS driver built specifically for this model:

```bash
sudo pacman -S --needed git gcc linux-headers make patch wget dkms
git clone https://github.com/jackdanyell/imac18-3-cs8409-linux-audio.git
cd imac18-3-cs8409-linux-audio
sudo ./install-imac18-3.sh
sudo reboot
```

The installer checks `product_name` (`iMac18,3`) and the HDA codec chip name before installing, so it refuses to run on other hardware. It builds via DKMS against the running kernel, so it survives kernel updates automatically. Requires `wget` to be installed (used to fetch the matching mainline kernel source for the codec patch).

Verify after reboot:

```bash
dkms status
wpctl status
```

Expect `snd_hda_macbookpro/<version>, <kernel>, x86_64: installed` and a working `Built-in Audio Analog Stereo` sink/source.

To remove: `sudo /path/to/install.cirrus.driver.sh -r` (restores the original in-kernel module).

## 7. Recovery and rollback

If the new 4K boot mode causes a black screen:

1. In Limine, boot the known-good snapshot entry.
2. Restore `/etc/kernel/cmdline.bak` to `/etc/kernel/cmdline` (this is the file that actually matters—see section 2).
3. Also restore `/etc/default/limine.backup` for consistency.
4. Run `sudo limine-mkinitcpio` again.
5. Reboot.

Alternatively, edit the Limine entry temporarily and remove only:

```text
video=eDP-1:3840x2160@60e
```

Do not edit or mount the internal macOS/OpenCore disk while troubleshooting the external Omarchy installation.

## 8. Post-reboot checklist

Run:

```bash
./scripts/verify.sh
```

Confirm visually that:

- The desktop is no longer horizontally or vertically stretched.
- Hyprland reports 3840×2160 around 60 Hz.
- The OWC adapter reconnects automatically after a cold boot.
- `enp11s0` receives DHCP and owns the default route.
- `dkms status` shows the CS8409 audio module installed, and speakers/mic work.

## Upstream references

- [Hyprland monitor configuration](https://wiki.hypr.land/0.55.0/Configuring/Basics/Monitors/)
- [Aquamarine tiled 5K modesetting issue #59](https://github.com/hyprwm/aquamarine/issues/59)
- [Aquamarine redundant-tile handling PR #238](https://github.com/hyprwm/aquamarine/pull/238)
- [Aquamarine standalone-capable tile proposal #354](https://github.com/hyprwm/aquamarine/pull/354)
- [Omarchy iMac17,1 discussion—useful context, but not the same GPU](https://github.com/basecamp/omarchy/discussions/5151)
- [drm/amd tiled-display tracking issue #4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) — the open upstream issue for native 5120×2880 support on tiled iMac 5K panels; the second DisplayPort tile link exists in hardware but `amdgpu` doesn't link-train or tile-group it yet.
- [jackdanyell/imac18-3-cs8409-linux-audio](https://github.com/jackdanyell/imac18-3-cs8409-linux-audio) — the DKMS audio driver used in section 6.

