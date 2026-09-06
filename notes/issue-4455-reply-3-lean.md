@taprobane99 Challenge accepted — and you were right, it strips down a lot.

I took your 7.2.3 patch as the base (the mainline candidate: kernel exposes two proper tiles, compositor stitches — no erik2 stitch layer in this one) and did the human-editing pass:

**Result: 1141 diff lines, +636 added, 11 files** — vs 2107 lines / +1631 added / 12 files. Same mechanism, ~60% less code. It compiles clean (zero warnings) and applies with zero rejects to both **7.1.9 and 7.2.2** pristine source.

What went:
- All 8 `amdgpu_dm_log_apple5k_*` instrumentation functions and their call sites, the two colour-space/plane-type name tables, `edid_panel_id_to_str` / `edid_extension_tags_to_str` / `edid_is_apple_panel` (log-only), and every `APPLE5K:` `DC_LOG_INFO`/`drm_info` in the dc/link files (42 statements).
- The plumbing that only existed to feed those logs: `stage` string params, `elapsed_ms`/`dpcd_rev` out-params on the AUX poll, readback buffers after the DPCD writes, and the old/new EDID snapshot + "CHANGED/UNCHANGED" bookkeeping around the root re-read.
- The whole `dc/core/dc.c` hunk — it's a pure refactor of `program_timing_sync()` (splits an `if` into two temporaries) with no behaviour change, plus an unused include. Gone, one fewer file.

What stayed, untouched in logic: the panel-ID quirk table and the 6 `panel_patch` flags, `dm_helpers_wire_tiled_peer()`, the `0x4F1` root latch pulse, slave AUX pre-detect poll + fallback rewire, source-table revision, stream-enable latch, root EDID re-read after the slave exposes its tile block, `prefer_tile_native_mode`, and the pre-LT AUX-ready handling.

Plus the genlock fix folded in, in the form that compiles against your tree (gated on `tiled_peer` rather than erik2's `tiled_pair_apple`):

```c
if (stream->link && stream->link->tiled_peer &&
    stream->triggered_crtc_reset.event_source &&
    stream->triggered_crtc_reset.event_source != stream)
        stream->triggered_crtc_reset.enabled = true;
```

in `dm_enable_per_frame_crtc_master_sync()` before `set_multisync_trigger_params()`. That's the piece that gets `sync_enabled=1` so the tiles are hardware-locked — on the two-output path it should take care of the centre-seam tear at the source rather than in Mutter/KWin; would be very interested whether it makes your MutterTearFix unnecessary.

Boot-tested since: on the iMac18,3 (7.1.9-arch1-2), the lean core with erik2's stitch layered on top comes up at native 5120x2880 under Hyprland, seamless, no GPU resets or errors in the log — the same result as the verbose build it replaces. The core is byte-for-byte the same under both, so that covers the two-tile path as far as the panel bring-up goes; I can't demonstrate the compositor-stitched variant here because Hyprland has no tile support.

One honest caveat: I left the debugging out entirely rather than behind a knob — if you'd rather keep a `drm_dbg` or two for the Vega/iMac Pro hunt, easy to add back.

Patch (with a proper commit message; happy to rebase onto your 7.3-rc1 tree too):
https://github.com/ahmadtv/omarchy-imac18-3/blob/main/patches/imac5k-lean-core-7.2.x.patch

For anyone on a compositor without tile support (Hyprland, in my case), erik2's stitch stays a separate optional layer on top — kept out of this one on purpose so the mainline candidate stays small.

-- Ahmad
