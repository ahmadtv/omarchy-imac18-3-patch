# Native 5K (5120×2880) on the iMac18,3 — investigation record

Status as of **2026-09-02**: a working out-of-tree kernel fix exists and portable patches are posted upstream; **no iMac18,3 has tested it yet — this machine would be the first data point.** Not mainlined. Hyprland cannot stitch the result yet.

This file is the full technical record. The README carries only the summary.

## The problem

The panel is a genuine two-tile display: two 2560×2880 halves, each on its own physical DisplayPort link, combining to 5120×2880. Stock `amdgpu` only ever drives the eDP link (one tile); the panel's scaler stretches it. The `video=eDP-1:3840x2160@60e` fallback forces a supported single-stream timing — correct proportions, sub-native resolution.

This machine's own EDID (decoded live): manufacturer `APP`, product `0xAE11` (= "Model 44561"), with Apple vendor-specific CTA blocks (OUI `00-10-FA`) that carry backlight-correction data — *not* tile info. The three extra DRM connectors (`DP-1/2/3`) show disconnected, zero-byte EDID, and (verified via debugfs `force` + `trigger_hotplug`) **no AUX/DDC response at all** when force-probed. That dead AUX is explained below.

## Why the second link is dead: the full mechanism (from drm/amd#4455)

Reverse-engineered (by `mforce2` + AI tooling, IDA Pro/Ghidra, from the Windows Boot Camp driver's `EnableSecondaryTileIfRequired` and two UEFI modules — Apple `ApplePlatformInfoDatabaseDxe.efi` + AMD GOP `CoreEG2.efi`):

- Mac firmware sets up "5K mode" pre-boot **only when it detects macOS/Windows booting**. Any non-Apple-signed bootloader (Limine included) gets the 4K-fallback path: the eDP presents a fallback EDID and the second tile's link stays unpowered — HPD low, AUX dead. (OCLP's chainload trick — `boot.efi` diagnostics → replaced `Product.efi` → any bootloader — preserves the firmware 5K init, which is why early experiments required OCLP.)
- The runtime fix that makes OCLP unnecessary: **write `1` to vendor DPCD register `0x4F1`** ("the 1265 one-byte command") on the **root eDP link**. This wakes the hidden secondary tile path. The slave then needs AUX-ready-before-link-training handling, a source-table rev, and a re-pulse of the latch at stream-enable.
- The eDP's EDID can change after the wake ("root-compat" vs "tile identity" EDIDs — `0xAE11`/`0xAE12` for the iMac18,3 family), so the patch re-reads it.

## The fix that exists today

- Kernel: [`mcirsta/linux-imac-5k`](https://github.com/mcirsta/linux-imac-5k) (branch `imac15-1-test-logging` is the live one; the repo's top-level README is an unrelated generic template — ignore it, the patches are real). Gated behind `amdgpu.apple5k_enable=1` (+ `apple5k_profile`, `apple5k_discovery_mode`, `apple5k_log_mask`, `apple5k_transition_hpd_guard`).
- **Portable patches** (posted 2026-08-30 by `taprobane99` on drm/amd#4455): `5k-imac-7.0.x.patch` (any 7.0.x kernel) and `5k-imac-7.2.2.patch` (mainline 7.2.2, built, confirmed 5K). Upload URLs use the project-ID form: `https://gitlab.freedesktop.org/-/project/4522/uploads/<hash>/<name>` (the `/drm/amd/uploads/...` form 404s). The 7.2.2 patch: ~1,600 added lines, 12 files (`amdgpu_dm.c`, `amdgpu_dm_helpers.c`, `dc/core/dc.c`, `dc/link/link_detection.c`, `link_dpms.c`, `link_dp_capability.c`, `link_dpcd.[ch]`, `link_dp_training.c`, `link_edp_panel_control.c`, `dc.h`, `dc_types.h`).
- The quirk hooks into the same `apply_edid_quirks()` panel-ID table AMD already uses in-tree (which today only *hides* the Apple Studio Display's redundant tile — IDs `0xAE3A/42/46`). The patch adds the dual-tile iMac family with an explicit comment: **"iMac18,3 family: AE11 root-compat, AE12 tile identity."** Role is chosen by connector signal (eDP=root, DP=slave), not panel-id alone.

### Model status (from the issue thread)

| Model | GPU | Status |
|---|---|---|
| iMac15,1 | R9 M290X | ✅ working (5K confirmed) |
| iMac17,1 | R9 M380/390/395X | ✅ working incl. GCN1 (PR #2), needs era-quirks: `amdgpu.dpm=0 reboot=pci acpi_backlight=native` |
| **iMac18,3** | **Radeon Pro 570/575/580** | **❓ explicitly supported in the patch, never tested — "the only iMac we are missing is 18,3" (mforce2, 2026-06-02)** |
| iMac19,1 | RX 570/580-class | ✅ working (developer's own machine) |
| iMacPro1,1 | Vega 56/64 | ❌ broken — traced to the missing Intel iGPU, not Vega itself |
| iMac20,x | Navi | different case: single link can carry 5K; `video=eDP-1:5120x2880MR@60e`-style forcing applies |

### Known rough edges

- Left tile stretched during boot animation (pre-compositor)
- Backlight: works via sysfs; `acpi_backlight=native` fixes a 400→500-nit cap on some models; GNOME slider missing, KDE slider works
- Custom kernel builds need AppArmor config restored for snaps on Ubuntu

## Compositor situation

The kernel fix exposes **two connectors with correct tile metadata** — stitching them into one seamless output is the compositor's job:

- **GNOME/Mutter**: works today (mature multi-cable tiled-display support)
- **KDE/KWin**: open MR by mforce2 — [plasma/kwin!9475](https://invent.kde.org/plasma/kwin/-/merge_requests/9475)
- **Hyprland/Aquamarine**: nothing. Verified in source: Aquamarine's tile logic (`markRedundantTiles()`) only ever picks one connector and discards siblings; Hyprland's `CMonitor` is hard-typed 1:1 to one output. True stitching = new architecture on both sides (assessed: multi-week feature work, no existing design).
- **Compositor-agnostic alternative**: erik2's [`pro1-apple5k-tiled-stitch`](https://github.com/erikolofsson/cachyos-linux/tree/pro1-apple5k-tiled-stitch) branch stitches in the kernel and presents **one 5K output** — would work with Hyprland unmodified. Considered unlikely to mainline, but attractive for a personal machine.

So on this Omarchy/Hyprland machine, the patched kernel alone should yield **two side-by-side 2560×2880 outputs** (like KDE shows today) — already a valid hardware-level success test, but not a seamless desktop without GNOME or the kernel-stitch branch.

## Local assets on this machine

- `~/Downloads/linux-imac-5k-7.0.1-1-x86_64.pkg.tar.zst` + headers — prebuilt Arch packages of the exact confirmed-working build (`7.0.1-1-imac-5k-g5ca584fa84fb`, matches taprobane99's working GNOME report string byte-for-byte)
- Both upstream patches downloaded to session scratch (re-fetchable from #4455)

## Dead ends & debunked claims (don't redo these)

- **`amdgpu.exp_res_limit=1` is not a real parameter** — `dmesg`: `amdgpu: unknown parameter 'exp_res_limit' ignored`; absent from `/sys/module/amdgpu/parameters/`. Called out independently in-thread as an AI hallucination (along with `amdgpu.mst=1` for this purpose).
- **xrandr/kscreen-doctor custom-mode injection does not produce real 5K on two-link iMacs.** Verified in-thread (`soyokaze812`): it only changes what the desktop renders; the GPU output stays 3840×2160. Venemo (AMD dev): the trick only genuinely works on 2020+ single-link iMacs. The circulated "Verified configuration: 5K on KDE Wayland" report and the "fully working 5K on X11" recipe both trace to comments by `matpauranoo` ("Mauro") in #4455 / the Arch BBS thread — polished, never corroborated, contradicted by in-thread testing. The X11 modeline (`1276.50 MHz` pixel clock, full-blanking CVT) is physically implausible for any single link on this hardware.
- Hyprland custom-mode injection (`hyprctl eval hl.monitor(...)` with an EDID-unlisted mode): accepted into compositor state, no hardware modeset lands (no atomic commit logged; kernel mode list unchanged; state silently reverts).
- Forcing `DP-1/2/3` via debugfs (`force` + `trigger_hotplug`): status flips to "connected" but AUX stays dead — no EDID, `*ERROR* No EDID found on connector`. Root cause is the missing `0x4F1` wake, above.
- The July-2026 AMDGPU "Apple Studio Display" patch (hides a redundant tile on one connector) is the *opposite* of what this panel needs; unrelated.
- Windows Boot Camp driver archaeology (this repo's earlier finding, still valid context): our GPU's INF sets `PP_Apple_Bootcamp_Enable=1`; `atikmdag.sys` carries `DalEnable5kTiledMode` etc. The 0x4F1 discovery came from exactly this binary, independently, with proper disassembly tooling.

## Testing plan for this machine (the first 18,3 data point)

1. **Baseline capture** (any kernel): boot with `drm.debug=0x1e log_buf_len=32M`, run the thread's `imacamdtest.sh`, save dmesg + all EDIDs — useful to contribute even before the patched kernel.
2. **Install the patched kernel** alongside the stock one (prebuilt 7.0.1 packages, or build 7.2.2 + `5k-imac-7.2.2.patch`). Keep the known-good Limine entry untouched; add a separate entry with `amdgpu.apple5k_enable=1 apple5k_log_mask=31 drm.debug=0x1e log_buf_len=32M` and **without** `video=eDP-1:3840x2160@60e` (a forced eDP mode would fight the 5K bring-up).
3. **Success criteria at hardware level** (works even under Hyprland): `card1-DP-1` (or sibling) becomes `connected` with a real EDID (expect product `0xAE12`, tile position 1,0); two active 2560×2880 CRTCs; `APPLE5K:` log lines showing the 0x4F1 wake and slave link training.
4. **Seamless-desktop test**: needs GNOME/Mutter on Wayland (install alongside, or a live USB with the patched kernel), or erik2's kernel-stitch branch for Hyprland.
5. Post results (either way) to [drm/amd#4455](https://gitlab.freedesktop.org/drm/amd/-/issues/4455).

## Upstream links

- Tracking issue: https://gitlab.freedesktop.org/drm/amd/-/issues/4455 (web UI is bot-gated; issue JSON + anonymous GraphQL work fine, REST notes need auth)
- Kernel: https://github.com/mcirsta/linux-imac-5k · docs: https://github.com/mcirsta/iMac_5K_Docs (see `RE_5K_iMac19_1_CURRENT.md`)
- KWin tile support MR: https://invent.kde.org/plasma/kwin/-/merge_requests/9475
- Kernel-side stitch alternative: https://github.com/erikolofsson/cachyos-linux/tree/pro1-apple5k-tiled-stitch
- OCLP 5K-UEFI background: https://khronokernel.com/macos/2021/12/08/5K-UEFI.html
