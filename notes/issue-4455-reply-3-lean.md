@taprobane99 Challenge accepted — and you were right, it strips down a lot.

I took your 7.2.3 patch as the base (the mainline candidate: kernel exposes two proper tiles, compositor stitches — no erik2 stitch layer in this one) and did the human-editing pass:

**Result: 1141 diff lines, +636 added, 11 files** — vs 2107 lines / +1631 added / 12 files. Same mechanism, ~60% less code. It compiles clean (zero warnings) and applies with zero rejects to both **7.1.9 and 7.2.2** pristine source.

What went:
- All 8 `amdgpu_dm_log_apple5k_*` instrumentation functions and their call sites, the two colour-space/plane-type name tables, `edid_panel_id_to_str` / `edid_extension_tags_to_str` / `edid_is_apple_panel` (log-only), and every `APPLE5K:` `DC_LOG_INFO`/`drm_info` in the dc/link files (42 statements).
- The plumbing that only existed to feed those logs: `stage` string params, `elapsed_ms`/`dpcd_rev` out-params on the AUX poll, readback buffers after the DPCD writes, and the old/new EDID snapshot + "CHANGED/UNCHANGED" bookkeeping around the root re-read.
- The whole `dc/core/dc.c` hunk — it's a pure refactor of `program_timing_sync()` (splits an `if` into two temporaries) with no behaviour change, plus an unused include. Gone, one fewer file.

What stayed, untouched in logic: the panel-ID quirk table and the 6 `panel_patch` flags, `dm_helpers_wire_tiled_peer()`, the `0x4F1` root latch pulse, slave AUX pre-detect poll + fallback rewire, source-table revision, stream-enable latch, root EDID re-read after the slave exposes its tile block, `prefer_tile_native_mode`, and the pre-LT AUX-ready handling.

Plus the genlock fix folded in — and here I have to correct my earlier comment. The 4-line version I posted (enable the per-frame reset on the non-master stream after `set_master_stream()`) turned out to be a coin flip per modeset: `set_master_stream()` only considers streams whose reset is *already* enabled and falls back to `stream[0]`, so whether the tiles locked depended on a stale flag surviving from the previous commit. Measured over seven modesets: every commit where both tile streams carried the reset locked, every one where only one did sheared, at any bit depth. The fix is to flag both tiles *before* the pick:

```c
for (i = 0; i < context->stream_count; i++) {
        stream = context->streams[i];
        if (stream && stream->link && stream->link->tiled_peer)
                stream->triggered_crtc_reset.enabled = true;
}

set_master_stream(context->streams, context->stream_count);
```

in `dm_enable_per_frame_crtc_master_sync()`. Verified 6/6 modesets locked since, including the clean boot commit. That's the piece that gets both tiles into the hardware sync group; on the two-output path it should take care of the centre-seam tear at the source rather than in Mutter/KWin — would be very interested whether it makes your MutterTearFix unnecessary. Updated `genlock-fix.patch` attached.

Boot-tested since: on the iMac18,3 (7.1.9-arch1-2), the lean core with erik2's stitch layered on top comes up at native 5120x2880 under Hyprland, seamless, no GPU resets or errors in the log — the same result as the verbose build it replaces — and it has been my daily default for the last few boots, warm reboots and shutdowns included. The core is byte-for-byte the same under both, so that covers the two-tile path as far as the panel bring-up goes; I can't demonstrate the compositor-stitched variant here because Hyprland has no tile support.

One honest caveat: I left the debugging out entirely rather than behind a knob — if you'd rather keep a `drm_dbg` or two for the Vega/iMac Pro hunt, easy to add back.

One heads-up that applies to your patch as much as to this one: the wake leaves the panel in a state Apple's firmware can't recover from. A warm reboot out of a 5K session gives a skewed Apple logo on the next boot; a warm reboot out of a stock session does not (checked as a control), so the patch is the cause. The fix direction, confirmed here with a ramoops capture of the shutdown and a straight logo afterwards: shut the display down on the reboot path (amdgpu's PCI shutdown never disables the streams, so nothing hung off stream-disable ever ran), and while going down put the slave back to its factory state (0x4F1, 0x310, 0x10A cleared, root panel powered off for T12) with the wake paths gated off so the HPD-RX re-detect can't undo it. It's in the lean core patch linked below (the `amdgpu_pci_shutdown()` hunk plus the going-down gates), about 130 lines, and it's what my machine has run as the default since. Do you see the skewed logo on GNOME too?

Patch (with a proper commit message; happy to rebase onto your 7.3-rc1 tree too):
https://github.com/ahmadtv/omarchy-imac18-3/blob/main/patches/imac5k-lean-core-7.2.x.patch

For anyone on a compositor without tile support (Hyprland, in my case), erik2's stitch stays a separate optional layer on top — kept out of this one on purpose so the mainline candidate stays small.

-- Ahmad
