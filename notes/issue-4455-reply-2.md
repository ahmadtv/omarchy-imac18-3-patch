@taprobane99 Great questions — clarifying exactly what I ran, because my setup differs from yours in one important way: I'm on Hyprland (wlroots), which has no two-tile support at all. So I couldn't run your patch the way you do on GNOME (two outputs, Mutter stitching). My stack is:

1. Your `5k-imac-7.2.2.patch` as the base (wake + tile-pair wiring) — unmodified
2. erik2's two "tiled stitch" commits from his fork (`pro1-apple5k-tiled-stitch`: `b514ebd` + `2fe1cfd`), hand-ported onto your 7.2.2 base (4 rejected hunks) — presents the pair as ONE 5120×2880 output so any compositor works
3. The genlock addition on top

To answer a/b directly: **I never tested your patch alone** (no GNOME here), so no claim it doesn't work — it clearly does on Mutter setups. What I hit is specific to the stitched single-display path: with (1)+(2) but without (3), both tiles trained and the streams committed, but `sync_enabled` stayed 0, the tiles free-ran, and the panel never latched — black screen and an endless re-modeset loop. With (3): `sync_enabled=1`, rock solid, seamless under motion.

You're right that the hunk alone doesn't compile — `tiled_pair_apple` is a field added by erik2's stitch commits, not by your base. Two options:

**The full patch I actually run** (your base + erik2's stitch + genlock, as one diff against pristine 7.2.2 — it also applies cleanly to 7.1.9, zero rejects):
https://github.com/ahmadtv/omarchy-imac18-3/blob/main/patches/imac5k-amdgpu-7.2.2.patch

**For your tree without the stitch**, the same fix can gate on the `tiled_peer` wiring your base already does in `dm_helpers_wire_tiled_peer()`:

```c
if (stream->link && stream->link->tiled_peer &&
    stream->triggered_crtc_reset.event_source &&
    stream->triggered_crtc_reset.event_source != stream)
        stream->triggered_crtc_reset.enabled = true;
```

placed in `dm_enable_per_frame_crtc_master_sync()`, in the second loop, right before `set_multisync_trigger_params(stream)`. That should compile against your base alone.

On the Mutter comparison: I think they solve it at different layers. The Mutter work paces the two outputs in the compositor; this engages the DCE per-frame CRTC position reset (GSL) so the two tile CRTCs are locked in hardware. On the stitch path no compositor even knows there are two tiles, so hardware genlock is the only place it can happen. It may also reduce the seam tearing on the two-output path at the source — which is exactly why it's worth the test on your machine.

Happy to provide full dmesg/drm_info from the working boot. And the 7.3-rc1 port plus the one-click repo is great news — thank you for that.

-- Ahmad
