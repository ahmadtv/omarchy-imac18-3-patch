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
| External Omarchy installation | ✅ Working |
| LUKS unlock and graphical boot | ✅ Working |
| Radeon Pro 575 acceleration | ✅ Working with `amdgpu` |
| OWC Thunderbolt 10GbE | ✅ Working at 10 Gb/s |
| Wi-Fi profile conflict | ✅ Resolved |
| Native 5120×2880 display | 🚧 Not supported by the current Linux/Aquamarine tile path — ongoing (tracked upstream, see [section 3](#3-why-the-5k-panel-appears-skewed)) |
| 3840×2160 panel-scaled fallback | ✅ Working, verified after reboot |
| Internal speakers and mic (CS8409) | ✅ Working, via out-of-tree DKMS driver |
| Boot entry in firmware picker | ✅ Named `Omarchy` entry registered, no more guessing at unlabeled icons |
| Quiet graphical boot (`quiet splash`) | ✅ Working, confirmed safe on top of the full fix (section 2.4) |
| Top-level firmware boot entry ("OMARCHY", outside OpenCore) | ✅ Working—display correct, splash centered, confirmed 2026-08-30 |
| OpenCore-internal boot entry (deep inside OpenCore's own menu) | 🚧 Not yet retested since the 2.5/2.6 fixes below—was working before, unconfirmed after |
| Display color oversaturation vs. macOS | ✅ Fixed—see [section 10](#10-display-colors-oversaturated-compared-to-macos) |
| Suspend (S3) and hibernate | ❌ **Broken, likely unfixable without ACPI/DSDT work.** Every attempt hard-hangs the machine (see section 7). Do not use—mask both targets. |

## 1. Original black-screen problem

Omarchy reached disk decryption, then the internal display went black during the graphics handoff. The machine is an iMac18,3 with a Radeon Pro 575, not the older iMac17,1/R9 M380. Do not copy the older CIK/radeon workaround (`amdgpu.cik_support`, `radeon.cik_support`, or `amdgpu.dc=0`) onto this Polaris GPU.

The relevant observations were:

- The Radeon Pro 575 is natively supported by `amdgpu`.
- Omarchy regenerated `/boot/limine.conf`, so editing that generated file directly was not persistent.
- `quiet splash` returned after regeneration and could retrigger a Plymouth/greeter graphics-handoff failure.
- Persistent kernel arguments belong in `/etc/default/limine`, followed by `limine-mkinitcpio`.

## 2. Persistent boot fix

### 2.1 The real source of the embedded cmdline

Omarchy builds a Unified Kernel Image (UKI) with `limine-mkinitcpio`, and that UKI has a kernel command line **embedded directly into it** at build time. After extensive testing, the actual source is **`/etc/default/limine`'s `KERNEL_CMDLINE[default]`**—not `/etc/kernel/cmdline` (an earlier version of this doc claimed the opposite; that was wrong, confirmed by editing each file independently and checking which change actually altered the embedded UKI).

Edit `/etc/default/limine`:

```bash
sudo cp /etc/default/limine /etc/default/limine.backup
```

Use [configs/limine.example](configs/limine.example) as a template.

- Use `KERNEL_CMDLINE[default]="..."`, not `+=`, to replace Omarchy's drop-in command line and prevent `quiet splash` from being appended again (unless you deliberately want it—see 2.4).
- Preserve the machine's existing root, encryption, Btrfs, resume, and `initramfs_async=0` parameters.
- Add:

```text
amdgpu.dc=1 amdgpu.exp_res_limit=1 video=eDP-1:3840x2160@60e
```

Rebuild the UKI and Limine entry:

```bash
sudo limine-mkinitcpio
```

Verify the cmdline that will actually boot is embedded in the UKI itself—do not trust `limine.conf` alone:

```bash
sudo objcopy -O binary --only-section=.cmdline /boot/EFI/Linux/omarchy_linux.efi /dev/stdout
```

### 2.2 Critical gotcha: three copies of `limine.conf`, and a stale fallback UKI

This ESP has **three separate copies** of `limine.conf`, and `limine-mkinitcpio` only updates one of them:

```text
/boot/limine.conf              <- updated by limine-mkinitcpio
/boot/EFI/limine/limine.conf   <- NOT updated automatically
/boot/EFI/BOOT/limine.conf     <- NOT updated automatically
```

Worse: `/boot/EFI/BOOT/BOOTX64.EFI` (the universal generic fallback path every UEFI firmware checks first) was, on this install, **not Limine at all**—it was a frozen, stale copy of an old UKI build from install time, with the real Limine binary renamed alongside it as `BOOTX64.LIMINE.EFI`. Since `\EFI\BOOT\BOOTX64.EFI` is what firmware/OpenCore's generic auto-detection defaults to, every "just boot automatically" path was silently loading that old, unfixed UKI—completely bypassing every fix made afterward, with zero indication anything was wrong (no error, just old behavior).

**Symptoms this causes:** a fix appears to have no effect after a real reboot; two different boot-menu entries seem to give two different, inconsistent results even though they're "the same install"; verified-correct config on disk doesn't match `/proc/cmdline` after boot.

**Fix—after every `limine-mkinitcpio` run, always sync all copies:**

```bash
sudo cp /boot/limine.conf /boot/EFI/BOOT/limine.conf
sudo cp /boot/limine.conf /boot/EFI/limine/limine.conf
sudo cp /boot/EFI/Linux/omarchy_linux.efi /boot/EFI/BOOT/BOOTX64.EFI
```

**Always verify by extracting the embedded cmdline from the actual file firmware will load, not just the "main" one:**

```bash
sudo objcopy -O binary --only-section=.cmdline /boot/EFI/BOOT/BOOTX64.EFI /dev/stdout
```

If this doesn't match what you just set, nothing else you do will take effect until it does.

### 2.3 Verifying and selecting the boot entry at startup

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

This external SSD has no NVRAM boot entry by default, so the firmware's boot picker shows it as a blank/unlabeled icon ("no name"). Register a proper named entry once:

```bash
sudo efibootmgr --create --disk /dev/sdX --part 1 --label "Omarchy" --loader '\EFI\limine\limine_x64.efi'
```

Replace `/dev/sdX` with the external SSD's device (check with `lsblk`; the ESP is the small `vfat` partition mounted at `/boot`). Point the loader at `\EFI\limine\limine_x64.efi` specifically (the real Limine binary), not the generic `\EFI\BOOT\BOOTX64.EFI` path, to sidestep the stale-fallback trap in 2.2 entirely.

At every boot: hold **Option** at power-on to bring up the firmware's boot picker, and select the entry labeled **Omarchy**. Note that Mac NVRAM entries can get wiped by hard power-cycles (see section 7)—if the label disappears and reverts to a generic "Limine" entry auto-created by a pacman hook, that's expected; it points at the same file and works identically, just re-run the `efibootmgr --create` command above to relabel it.

### 2.4 Re-enabling `quiet splash`

`quiet splash` was originally excluded because it was suspected of retriggering the graphics-handoff black screen (section 1). That warning predated `amdgpu.dc=1` being properly set and predated the sync fix in 2.2. **Retested and confirmed working**: with `amdgpu.dc=1 amdgpu.exp_res_limit=1 amdgpu.runpm=0 video=eDP-1:3840x2160@60e` in place and all boot-file copies synced per 2.2, adding `quiet splash` back boots normally—graphical splash, password prompt, working desktop, no black screen. The original problem is understood to have been specific to the earlier fix state (missing `amdgpu.dc=1` and/or the sync bug), not `quiet splash` itself.

A separate, real cosmetic bug did show up along the way: the Plymouth splash (logo + password box) appeared shifted toward the lower-left instead of centered, at one point during testing. Root cause traced to Omarchy's own stock `plymouth` hook running *before* `kms` in `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` (dated from original install, never modified here)—Plymouth can initialize its canvas size before `amdgpu` applies the forced `video=` mode, so its centering math (`Window.GetWidth()/2`, correct code, wrong input) can be based on the panel's native tile size (2560×2880) instead of the actual active resolution. **This was not chased further and not fixed**—the boot-entry/`default_entry` fix in 2.5 below resolved the visible symptom without needing to touch this Omarchy default, and the current top-level boot path is confirmed correctly centered (see status table). Documented here only in case the symptom reappears; the hook-order fix, if ever needed, would be reordering `kms` before `plymouth` in that file.

### 2.5 `default_entry` can silently point at a stale snapshot instead of the current kernel

`limine.conf`'s `default_entry: 2` (the numeric-index form Omarchy's tooling originally wrote) does not get recalculated by any tool here—not `limine-entry-tool`, not `limine-mkinitcpio`—it's a static value from install time. As snapshots accumulate via `limine-snapper-sync`, that fixed number can end up resolving to a **stale snapshot's kernel entry** instead of the current "linux" entry, with no error or warning.

This exact thing happened: a snapshot from very early in this project's timeline (with an old, since-superseded `video=eDP-1:2560x1440@60e`) sat at the position `default_entry: 2` pointed to. Booting via the top-level firmware entry (which goes through Limine and respects `default_entry`) landed on that old snapshot instead of the current kernel—producing a different (and differently wrong) resolution than booting via OpenCore's internal menu, which bypasses Limine's menu logic and boots the current UKI directly. Two boot paths, "same install," different results—this was the cause.

**Fix**: Limine supports referencing `default_entry` by name/path instead of a fragile numeric index:

```text
default_entry: Omarchy/linux
```

(`Omarchy` and `linux` are this config's actual `/+` and `//` entry names—adjust if yours differ.) This is immune to snapshot count/ordering changes going forward. Applied and synced across all three `limine.conf` copies (section 2.2).

### 2.6 Making the ESP's own name show up correctly, and OpenCore's picker too

Two separate cosmetic-but-confusing issues, both fixed without touching the internal macOS/OpenCore disk:

**The firmware's native Option-key boot picker showed a blank/"NO NAME" icon** even after registering a named `efibootmgr` entry (section 2.3)—because Apple's own picker displays the **FAT filesystem's own volume label** for third-party bootloaders, not the EFI entry's description text. The ESP had no label set at all. Fix:

```bash
sudo fatlabel /dev/sdX1 OMARCHY
```

**OpenCore's own internal menu** (its separate picker, shown when you go through OpenCore itself rather than the top-level firmware picker directly) uses its own auto-detection for the Linux entry and doesn't read either of the above—it shows "no name" from its own scan. OpenCore (v0.7.8+) supports `.contentDetails` (plain-text display name) and a `.icns` icon file, both placed **on this same external ESP**, no internal-disk edit needed:

```bash
# Icon: place next to whatever OpenCore is detecting/booting
sudo cp your-icon.icns /boot/EFI/Linux/omarchy_linux.efi.icns
printf 'OMARCHY' | sudo tee /boot/EFI/Linux/.contentDetails /boot/EFI/Linux/omarchy_linux.efi.contentDetails
# Same convention applied to /boot/EFI/limine/ in case OpenCore scans that path instead
```

A minimal valid `.icns` can be hand-built from any PNG without needing macOS or `iconutil`—modern ICNS allows embedding a raw PNG directly in an `ic08` chunk: 8-byte magic `icns` + total length, then one chunk `ic08` + chunk length + raw PNG bytes. Not independently reverified from OpenCore's side this session (no internal-disk access)—flag here if it turns out not to take effect.

### 2.7 A second, uncoordinated agent had disabled Limine entirely—watch for this

Separately from all of the above: at one point this session, `/boot/EFI/limine/limine_x64.efi` and `/boot/EFI/BOOT/BOOTX64.LIMINE.EFI` were found renamed to `.disabled`/`.DISABLED`, with the registered `efibootmgr` "Omarchy" entry left pointing at the now-missing file. This was **not** done by the Claude session maintaining this doc—it turned out to be a *different*, independently-running AI agent (on this same machine, working from the macOS side) that hit a genuine "no config found" Limine error and worked around it by disabling Limine entirely, forcing boot through the raw fallback UKI instead.

That workaround sacrifices Limine's own menu, the named `default_entry` targeting in 2.5, and snapshot/rollback access, to route around what was very likely a **transient race**: multiple uncoordinated agents (this session, sub-agents spawned for sections 3.3/7, and the separate macOS-side agent) editing the same live `limine.conf`/UKI/binary files concurrently, with no locking, can easily catch a file mid-write.

**If boot config seems to unexplainably regress again, check for this first** before assuming a fix "didn't work":

```bash
ls /boot/EFI/limine/*.efi /boot/EFI/BOOT/*.EFI 2>&1   # look for stray .disabled files
sudo mv /boot/EFI/limine/limine_x64.efi.disabled /boot/EFI/limine/limine_x64.efi 2>/dev/null
sudo mv /boot/EFI/BOOT/BOOTX64.LIMINE.EFI.DISABLED /boot/EFI/BOOT/BOOTX64.LIMINE.EFI 2>/dev/null
```

If multiple agents/assistants have access to this machine's boot configuration, coordinate so only one touches it at a time—this class of bug (each agent "fixing" a problem the others' concurrent edits caused) can otherwise repeat indefinitely.

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

### 3.1 Follow-up investigation (2026-08-28): still blocked upstream

Re-checked whether anything had changed since the original investigation. Conclusion: **no**, this is still the known, tracked, not-yet-implemented AMD/Aquamarine tile-combining gap—nothing new to work around it was found.

- **No newer kernel helps.** The running kernel (7.1.9) is already newer than every other package available (`linux-lts` 6.18, `linux-zen` same version/different scheduler, `linux-mainline-panther-lake` is an unrelated Intel-platform audio-focused build). None carry more `amdgpu` tiled-display work than what's already running.
- **The July-2026 AMDGPU DC "Apple Studio Display" patch series (targeting v7.3) does not apply here.** Confirmed via the Phoronix writeup: that fix *hides/disconnects* a spurious second SST DisplayPort link on the external Studio Display so compositors stop trying to drive it—the opposite of what this iMac's internal eDP panel needs, which is combining two genuine tile links into one mode. Not backportable to this case.
- **No merged fix on `drm/amd` issue #4455** as of this check (GitLab's Anubis bot-challenge still blocks direct fetch; confirmed via search-engine snippets only). One community thread adds a detail not previously noted here: the second tile link is expected to be `DP-1` specifically (not `DP-2`/`DP-3`), based on general reasoning about amdgpu's connector enumeration order—unconfirmed against this exact hardware's debugfs, since that requires root not available this session.
- **Tested, and ruled out, a custom-mode-injection path that hadn't been tried before:** Hyprland 0.56.2 replaced its config parser with a Lua-based one, so the old `hyprctl keyword monitor ...` path used in prior wlr-randr-style attempts is deprecated in favor of `hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "5120x2880@60", ... })'`. This appeared to succeed—`hyprctl monitors` briefly reported `5120x2880@60` active with no config errors—but it does not reflect a real hardware modeset: the kernel's own connector mode list (`/sys/class/drm/card1-eDP-1/modes`, read directly from the driver) never contained `5120x2880`, Hyprland's own log has no corresponding DRM atomic-commit entry for the change, and a subsequent read reverted to `3840x2160` with no revert command issued. This is Hyprland accepting a config value into its internal state without a corresponding backend commit landing, not a working custom-mode mechanism. The underlying gap described in Aquamarine issues #59/#238/#354 stands unchanged.

Net result: no working or partial improvement found this session. The `video=eDP-1:3840x2160@60e` boot-parameter fallback (section 3) remains the correct approach until upstream `amdgpu` DC gains the link-training/tile-group logic tracked in #4455.

### 3.2 Reverse-engineering the Windows Boot Camp AMD driver (2026-08-28)

The GitLab #4455 maintainer's comment says the real fix needs "reverse-engineering the Windows Boot Camp AMD driver" to learn Apple's tile-combining sequence. Took a real run at that rather than treating it as a closed door. Concrete, previously-undocumented findings below—not a working fix, but a genuine lead for whoever picks this up next (upstream or a future session with better tooling).

**How the driver was obtained (no macOS needed):** Apple's Boot Camp driver downloads are served from a public, unauthenticated Software Update catalog—no Mac, no Boot Camp Assistant required:

```text
https://swscan.apple.com/content/catalogs/others/index-11-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog
```

Downloaded that catalog, found all `BootCampESD` product entries, fetched each one's English `.dist` file, and grepped for `iMac18,3` until a match came back (`061-97204`, ~663 MB). Its `pkg-ref` pointed at `BootCampESD.pkg` in the same directory. That `.pkg` is a `xar` archive; with no `xar` binary available and no root to install one, wrote a small pure-Python xar reader (~70 lines, stdlib only: `struct` + `zlib` + `xml.etree`) to pull out `Payload` (a gzip'd cpio), which extracts to `Library/Application Support/BootCamp/WindowsSupport.dmg`. That `.dmg` needed an HFS/ISO reader; rather than requiring `sudo pacman -S`, downloaded the standalone `7zz` binary from 7-zip.org (no install, no root) and used it to browse straight into the DMG.

Inside: `BootCamp/Drivers/AMD/AMDGraphics/Packages/Drivers/Display/WT6A_INF/B350622/`—the actual unpacked AMD driver package, INF included, no need to run the installer at all.

**Finding 1—confirmed this exact GPU gets Apple-specific driver behavior on Windows.** The INF (`C0350660.inf`) lists our precise hardware ID:

```text
"%AMD67DF.2%" = ati2mtag_Polaris10, PCI\VEN_1002&DEV_67DF&SUBSYS_0162106B&REV_C4
AMD67DF.2 = "Radeon Pro 575"
```

That device's install section (`[ati2mtag_Polaris10]`) applies `AddReg = ati2mtag_SoftwareDeviceSettings`, which sets:

```text
HKR,, PP_Apple_Bootcamp_Enable, %REG_DWORD%, 1
```

A sibling flag, `KMD_BootCampPlatform` (`REG_DWORD = 1`), is set the same way for the Vega/Vega20 device sections (2019 iMac/iMac Pro). So on real Windows/Boot Camp, this exact PCI ID (`1002:67DF`, subsystem `0162106B`) is driven with an explicit "this is Apple Boot Camp hardware" flag turned on—confirming the driver *does* branch on platform identity, not just EDID content.

**Finding 2—new, specific lead: undocumented DAL registry flags for tiled 5K, not present anywhere in the installer's own INF.** `strings` across the 60 MB kernel-mode driver itself (`atikmdag.sys`) turned up a small family of `DalShared::ModeManager`-adjacent registry-style flags that never appear in the INF's `AddReg` sections (meaning they're internally defaulted/toggled by the driver, not installer-set):

```text
DalEnableTiledDisplay
DalEnable5kTiledMode
DalAllowTiledDisplayGLSync
DalDisableNBP4KTiledDisplay
DalTiledRotatedOverride
Dal5K60PipeSplit
```

`DalEnable5kTiledMode` sits directly adjacent to `DalShared::ModeManager::ModeManager` in the string table—i.e. it's read by DAL's mode-management code, which is the layer responsible for deciding what timing/topology to present to the OS. This is a materially more specific lead than anything in the upstream issue or prior research: it's the actual internal name of the feature switch, not just "some magic happens."

**Where this stops, honestly:** turning these flag names into working kernel code needs real disassembly—finding what sets `DalEnable5kTiledMode` (almost certainly gated on the `PP_Apple_Bootcamp_Enable`/platform-detection path above, combined with the EDID tile block) and what code runs when it's true (the actual DPCD/link-training sequence for the second tile). That needs a disassembler (Ghidra/IDA) capable of handling a 60 MB stripped PE driver with no symbols; `objdump`/`strings` alone can't get there, and installing Ghidra here needs `sudo` that wasn't available this session. **This is the right handoff point**, not a dead end: the next step for anyone continuing this (upstream contributor or a future session with Ghidra/root access) is to disassemble `atikmdag.sys` around the `DalEnable5kTiledMode` string's cross-references and compare against `drivers/gpu/drm/amd/display/dc/` in the Linux kernel source for an equivalent (likely absent or stubbed) `dc_debug_options` field—AMD's DC/DAL code is substantially shared between the Windows and Linux drivers, so a Windows-only registry flag family like this is a strong signal of Linux-side code that either doesn't exist yet or exists but is never enabled/wired up for eDP.

**Note for anyone reproducing this:** the extracted driver files (`.pkg`/`.dmg`/`.sys`/`.dll`) are Apple/AMD proprietary binaries obtained under Apple's standard Boot Camp EULA for this Mac's own hardware—legitimate to download and analyze locally for interoperability, but **do not commit or redistribute them in this (public) repo.** Only the findings above (flag names, hardware IDs, technical analysis) are recorded here; the binaries themselves were kept out of the repo, in a local scratch directory.

### 3.3 The real upstream status, a legitimate community kernel, and a concrete patch target (2026-08-30)

Checked GitLab issue [`drm/amd#4455`](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) directly via its API/GraphQL endpoint (the web UI is Anubis-gated, but `curl`/GraphQL against `gitlab.freedesktop.org` works fine—see below). This corrects an earlier, too-pessimistic read from this same session: there *is* real, current activity, just not a merged fix yet.

**Real upstream engagement exists.** AMD's actual Linux graphics driver lead, **Alex Deucher (`agd5f`)**, has been directly engaged on this issue since March 2026. His technical roadmap, in his own words: identify which physical DP PHY carries the second tile (via VBIOS PHY tables + AUX/DPCD probing), hardcode `2560x2880` modelines on both links as a first step (ignore real EDID/tiling entirely at first), then wire up tile-group info once both links are lit. He explicitly said the driver just needs "the appropriate quirk"—see below, that mechanism already exists in-tree. He's waiting on a contributor to do the physical-wiring legwork; as of his last comment (April 2026) nobody had confirmed it yet for any model.

**A legitimate out-of-tree kernel already gets partial results—on the newer 2019 iMac19,x, not yet confirmed on our 2017 iMac18,3.** [`github.com/mcirsta/linux-imac-5k`](https://github.com/mcirsta/linux-imac-5k) (real project—its top-level README is an unrelated generic kernel-doc template with an odd "AI Coding Assistant" section, worth ignoring/not trusting, but the actual kernel patches are real and referenced by name in the GitLab thread). As of Aug 23-28, 2026, community members (`taprobane99`, `M4rt1n12`, `LandonTheCoder`) report:
- Tear-free real 5K on **GNOME**, combining this kernel with a Mutter patch "originally designed for the LG UltraFine 5K"
- On a different iMac (RX 480, so iMac19,x-class), a **less clean** result: "not a single screen, but 2 next to each other" rather than one seamless display
- Active work porting the patch set to newer/mainline kernels (7.0/7.2/CachyOS)
- Verified two `.pkg.tar.zst` Arch packages of this exact kernel build (`7.0.1-1-imac-5k-g5ca584fa84fb`) downloaded locally—version string matches `taprobane99`'s working GNOME report byte-for-byte. Installing/testing this on our actual iMac18,3 is a live option, not yet done (needs a real reboot to verify; not attempted this session pending user go-ahead).

**The concrete, exact patch target—more specific than anything found before.** AMD's DC driver already has the *mechanism* Alex Deucher said was needed: a per-panel quirk table.

```c
// drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm_helpers.c, apply_edid_quirks()
/*
 * Workaround for Apple Studio Display which exposes a 2x1 tiled panel
 * over two SST DP links. Hide the secondary tile from userspace so
 * compositors drive a single 5K stream on the primary link only.
 */
case drm_edid_encode_panel_id('A', 'P', 'P', 0xAE3A):
case drm_edid_encode_panel_id('A', 'P', 'P', 0xAE42):
case drm_edid_encode_panel_id('A', 'P', 'P', 0xAE46):
	edid_caps->panel_patch.disable_second_tile = true;
	break;
```

This is real, in-tree, shipping code—confirmed via GitHub code search across `torvalds/linux`. It only ever does the *opposite* of what our panel needs (hides a redundant tile instead of combining two real ones), and the three panel IDs listed are all Apple Studio Display, not any iMac.

**Our exact panel's ID, decoded from this session's own EDID dump:** manufacturer bytes `06 10` → `APP`, product code bytes `11 ae` (little-endian) → **`0xAE11`** (matches `edid-decode`'s "Model: 44561" = 0xAE11 exactly). This ID is **not** in the quirk table today.

The precise, actionable patch shape for anyone picking this up:
1. Add a new bool to `struct dc_panel_patch` in `dc_types.h` (e.g. `combine_second_tile`—the inverse of `disable_second_tile`)
2. Add `case drm_edid_encode_panel_id('A', 'P', 'P', 0xAE11):` to `apply_edid_quirks()`, setting that new flag
3. **The still-unsolved part**: somewhere in the link-detection path (`dc_link_detect()` / `amdgpu_dm_connector_detect()`), when that flag is set, actively probe/link-train the sibling connector (rather than hide it) and construct a real DRM tile-group spanning both—this is the actual link-training work nobody has done yet for this exact hardware.

**Even a working kernel-side fix would need a second, compositor-side piece for Hyprland—assessed this session, verdict: real feature work, not a quick patch.** Investigated Aquamarine's (Hyprland's DRM backend) actual tile-group code (`markRedundantTiles()` in `src/backend/drm/DRM.cpp`) and Hyprland's `CMonitor`. Finding: Aquamarine's existing tile fixes (issues #238, #354—both already merged) only ever do "pick one connector in a tile group, discard the rest"—there is no code path for keeping two tile connectors alive and stitching them into one logical output. `CMonitor` is hard-typed to one Aquamarine output. No maintainer discussion of true multi-CRTC stitching exists in either repo's history. Building it for real would need a new Aquamarine output type owning multiple CRTCs plus Hyprland render-pipeline changes to composite across two independent atomic commits without visible tearing between them—comparable in scope to GNOME/Mutter's existing (years-old, dedicated) tiled-monitor subsystem, not a portable bugfix. Feasible in principle; realistically multi-week upstream feature work with no existing design to build on, not something to expect quickly.

**Debunked this session, for the record (so future readers don't waste time on these again):**
- A polished "Verified configuration: 5120x2880 @ 60Hz on KDE Wayland" report circulated (LLM-paraphrased) traces back to a single unconfirmed forum post ([Arch Linux BBS, `8-bit-brett`](https://bbs.archlinux.org/viewtopic.php?id=312192)) whose *first* attempt at the same goal required `nomodeset` (no GPU acceleration) and whose second, unelaborated claim was never corroborated by anyone and directly contradicted the thread's most experienced participant's (`seth`) explicit prediction. Thread ends immediately after that final post.
- A separate "fully working 5K on X11" xrandr recipe was the *original poster's own first attempt* in that same thread, which they themselves described as "not crisp, just slightly blurry"—and its modeline uses non-reduced-blank timings requiring a physically implausible 1276.5 MHz pixel clock.
- `amdgpu.exp_res_limit=1`, cited in both of the above and in older forum folklore, is confirmed **not a real parameter** on this machine's kernel: `dmesg`/`journalctl -k` shows `amdgpu: unknown parameter 'exp_res_limit' ignored`, and it does not appear in `/sys/module/amdgpu/parameters/` at all.

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

## 7. Suspend and hibernate are broken—do not use

Both `systemctl suspend` and `systemctl hibernate` hard-hang this machine, every time, with no exceptions found across many attempts. The kernel log stops dead mid-transition (`PM: suspend entry (deep)` or `PM: hibernation: hibernation entry`) with nothing logged afterward—no crash trace, no resume, nothing. Recovery requires a hard power-cycle (hold the power button).

**Ruled out, with clean confirmed tests (config verified embedded in the running kernel before each test):**

- Sleep mode: `deep` and `s2idle` both hang identically (`/sys/power/mem_sleep`).
- The forced `video=eDP-1:3840x2160@60e` display override: removing it entirely made no difference.
- BACO/BAMACO GPU runtime power state: `amdgpu.runpm=0` (fully disables it) made no difference.
- Hibernate fails identically to suspend, ruling out anything suspend-specific (e.g. display-related) as the sole cause.

**`pm_trace` diagnostic** (`echo 1 > /sys/power/pm_trace`, then check the RTC-based hash match on the next boot after a hang) pointed to a `memory` pseudo-device as the last thing being processed—consistent with the hang happening very late, near actual ACPI S3 hardware entry, i.e. a firmware-level failure rather than a specific Linux driver bug.

**Likely root cause:** Apple's EFI/ACPI firmware implements S3 sleep exclusively for macOS's IOKit power management. Generic Linux ACPI sleep entry on real Mac firmware is a long-documented, cross-model class of problem, not specific to this GPU or this fix. No published fix for this exact model (iMac18,3) was found; existing public SSDT/DSDT work is either for making sleep work *in macOS* under Hackintosh setups (the opposite direction) or for unrelated non-Mac hardware.

**The only real remaining path** would be writing custom ACPI SSDT patches to fake macOS-compatible sleep behavior for Linux—a substantial, uncertain undertaking (typically pursued by dedicated OpenCore/Hackintosh ACPI projects), not attempted here.

**Recommendation:** don't use suspend or hibernate on this machine. Mask both to prevent accidental triggers (menu, keybinding, or command):

```bash
sudo systemctl mask suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

## 8. Recovery and rollback

If a boot-config change causes a black screen or other boot failure:

1. In Limine, boot the known-good snapshot entry.
2. Restore `/etc/default/limine.backup` to `/etc/default/limine` (see section 2.1 for why this is the file that matters).
3. Run `sudo limine-mkinitcpio` again.
4. **Re-sync all three `limine.conf` copies and the fallback `BOOTX64.EFI`** (section 2.2)—skipping this step is the single most common reason a "fix" silently doesn't apply.
5. Reboot.

Alternatively, edit `/etc/default/limine` temporarily and remove only:

```text
video=eDP-1:3840x2160@60e
```

Do not edit or mount the internal macOS/OpenCore disk while troubleshooting the external Omarchy installation.

## 9. Post-reboot checklist

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
- `sudo objcopy -O binary --only-section=.cmdline /boot/EFI/BOOT/BOOTX64.EFI /dev/stdout` matches `/proc/cmdline` (confirms the sync in section 2.2 held).
- `systemctl list-unit-files 'suspend*' 'hibernate*'` shows masked, not enabled (section 7).

## 10. Display colors oversaturated compared to macOS

This iMac's 27" 5K panel is a **wide-gamut (Display P3) panel**. macOS uses ColorSync to properly gamut-map standard sRGB content down for correct-looking colors on it. By default, Hyprland's color management preset here was `srgb`, which does not compute a real per-panel gamut-mapping transform—it assumes a generic sRGB target rather than reading this specific panel's actual wide-gamut primaries, so sRGB content renders wider/more vivid than intended.

**Researched first, confirmed no existing packaged fix for this exact combination** (Linux/Wayland + AMD Polaris/DCE display engine + wide-gamut Apple panel):
- General Wayland color management is still broadly immature (multiple Arch/Fedora forum reports of ICC profiles not taking effect).
- AMD's own detailed driver-specific color-management pipeline (plane-level CTM/degamma/3D-LUT, used e.g. for the Steam Deck's color accuracy) is advertised for **DCN 3.0 and newer only**—this GPU's **DCE 11.2** display engine predates that and has a reduced color pipeline.
- The one existing tool built for exactly this class of problem, [`AMDColorTweaks`](https://github.com/dantmnf/AMDColorTweaks) (EDID-based GPU-side sRGB clamp for AMD GPUs), is Windows-only with no Linux port.

**Fix found instead: Hyprland has its own EDID-aware color management mode.** Beyond `auto`/`srgb`, Hyprland's monitor `cm` option also supports `dcip3`, `dp3`, `adobe`, `wide`, `edid`, and `hdr` ([Hyprland issue #4377](https://github.com/hyprwm/Hyprland/issues/4377) and related discussions #11744/#12527 track this class of bug generally). `cm = "edid"` specifically manages color against **this panel's own EDID-reported gamut** instead of assuming generic sRGB—this is the correct mode for a panel like this one, and does not require the AMD DCN-specific pipeline since it uses the more widely-supported CRTC-level (not plane-level) DRM color properties.

Applied in `~/.config/hypr/monitors.lua`:

```lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale, cm = "edid" })
```

Note: `hyprctl eval 'hl.monitor({...})'` accepted `cm = "edid"` without error but did **not** actually apply it (`colorManagementPreset` stayed `srgb`)—matches the same "accepted into state without a backend commit" gap noted for custom modes in section 3.1. Editing `monitors.lua` directly and running `hyprctl reload` applied it correctly (verified via `hyprctl monitors all | grep colorManagement`).

**Confirmed fixed** (2026-08-30)—visually closer to the expected macOS rendering. If `edid` doesn't work for a different panel, try `dcip3`/`dp3`/`wide` next; if none help, that points at the DCE hardware-pipeline limitation being the real blocker rather than a config choice.

## Upstream references

- [Hyprland monitor configuration](https://wiki.hypr.land/0.55.0/Configuring/Basics/Monitors/)
- [Aquamarine tiled 5K modesetting issue #59](https://github.com/hyprwm/aquamarine/issues/59)
- [Aquamarine redundant-tile handling PR #238](https://github.com/hyprwm/aquamarine/pull/238)
- [Aquamarine standalone-capable tile proposal #354](https://github.com/hyprwm/aquamarine/pull/354)
- [Omarchy iMac17,1 discussion—useful context, but not the same GPU](https://github.com/basecamp/omarchy/discussions/5151)
- [drm/amd tiled-display tracking issue #4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455) — the open upstream issue for native 5120×2880 support on tiled iMac 5K panels; the second DisplayPort tile link exists in hardware but `amdgpu` doesn't link-train or tile-group it yet.
- [Omarchy MacBook sleep/suspend discussion #4695](https://github.com/basecamp/omarchy/discussions/4695) — same class of Mac+Omarchy sleep bug on T2 MacBooks (laptop-specific fixes don't apply to this desktop iMac, but useful background on Apple-firmware sleep incompatibility).
- [jackdanyell/imac18-3-cs8409-linux-audio](https://github.com/jackdanyell/imac18-3-cs8409-linux-audio) — the DKMS audio driver used in section 6.

