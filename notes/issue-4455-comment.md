**Confirmed working on iMac18,3 — and a fix for the tile genlock (seamless, no seam under motion)**

Reporting the first iMac18,3 (27" 5K, 2017, Radeon Pro 575 / POLARIS10 / DCE 11.2) confirmed working at native, genlocked 5120×2880, on Omarchy (Hyprland/Wayland).

Built on the community 5K kernel work (the `0x4F1` root-latch wake + tile-pair wiring) rebased onto 7.2.2, plus erik2's single-display stitch, plus one additional fix that turned out to be the missing piece for a *stable, seam-free* image.

## The genlock gap

With the wake + stitch in place, both tiles trained (eDP root + DP slave, HBR2 ×4, 10-bpc) and the driver committed a single 5120×2880 stream pair — but the panel showed a black/unstable image (endless re-modeset), and `sync_enabled` was `0` in every commit. The two 2560×2880 tile streams were free-running.

Root cause: `dm_enable_per_frame_crtc_master_sync()` sets each stream's `event_source` (master) but never enables the per-frame CRTC reset — `multi_sync_enabled` is a standing TODO in mainline:

```c
/* TODO: add a function to read AMD VSDB bits and set
 * crtc_sync_master.multi_sync_enabled flag
 * For now it's set to false */
```

So `triggered_crtc_reset.enabled` stays false, `enable_timing_multisync()` finds nothing to program, and the tiles never lock — which is exactly what the panel's TCON needs to latch native dual-tile mode.

## The fix

Since the two halves are already known to be one Apple tiled panel (`link->tiled_pair_apple`), enable the per-frame reset on the slave tile so it hard-syncs to the master's VSYNC. `enable_timing_multisync()` → `dce110_enable_per_frame_crtc_position_reset()` (GSL) then locks the tiles.

Result on iMac18,3: `sync_enabled` flips `0 → 1`, and the desktop is stable and **seamless under motion** (windows dragged across the tile boundary, fast scrolling, video — no tear at the seam). ~14-line diff, gated strictly to `tiled_pair_apple` so it can't affect any other display:

```c
if (stream->link && stream->link->tiled_pair_apple &&
    stream->triggered_crtc_reset.event_source &&
    stream->triggered_crtc_reset.event_source != stream)
        stream->triggered_crtc_reset.enabled = true;
```

(full diff attached)

Happy to share full dmesg / drm_info from the working boot. Since DCE 11.2 (Polaris) is the same TG family used across most of the affected iMacs, this should apply beyond the 18,3 — worth a test on the 15,1 / 17,1 / 19,1 that already had the wake working.

— mr_projects
