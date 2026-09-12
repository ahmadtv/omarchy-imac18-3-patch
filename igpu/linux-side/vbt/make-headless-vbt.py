#!/usr/bin/env python3
# Generates vbt/headless-vbt.bin, which `imac-patcher --apply macos` installs.
#
# make-headless-vbt.py -- write a minimal, valid Intel VBT that declares NO
# display outputs, for i915.vbt_firmware= on the iMac18,3.
#
# Why: the iMac's HD 630 has no Intel VBT (no GOP, no OpRegion VBT expected once
# set_os exposes it). Without a VBT, i915 invents one: every DDI port becomes a
# connector, and port A is marked as an internal connector, i.e. eDP
# (intel_bios.c: init_vbt_missing_defaults()). The eDP init then does AUX /
# panel-power-sequencer work on DDI A even with i915.disable_display=1 --
# disable_display only short-circuits connector *detect*. On an iMac20,1 that
# probe left the AMD-driven internal panel blank (see ../README.md, section 1).
#
# A VBT with a valid header and an empty BDB (no "general definitions" block,
# hence no child devices) makes intel_setup_outputs() create no encoders at
# all on a DDI platform: intel_bios_for_each_encoder(display, intel_ddi_init)
# iterates an empty list. The display engine is still initialised (DMC, power
# wells, DC5/DC6), which is what package C-states need.
#
# Kernel checks this file must pass (drivers/gpu/drm/i915/display/intel_bios.c,
# intel_bios_is_valid_vbt()): "$VBT" signature, vbt_size <= file size,
# bdb_offset + sizeof(bdb_header) and bdb_offset + bdb_size inside vbt_size.
# The checksum is not checked by i915; it is set correctly anyway.
#
# Usage: ./make-headless-vbt.py [out-file]     (default: headless-vbt.bin here)
# `imac-patcher --apply macos` installs it as
# /usr/lib/firmware/imac18-3/headless-vbt.bin and boots with
# i915.vbt_firmware=imac18-3/headless-vbt.bin

import os
import struct
import sys

VBT_HEADER_FMT = "<20sHHHBBI16s"  # struct vbt_header (intel_vbt_defs.h), 48 bytes
BDB_HEADER_FMT = "<16sHHH"        # struct bdb_header, 22 bytes

VBT_SIG = b"$VBT KABYLAKE".ljust(20, b" ")
BDB_SIG = b"BIOS_DATA_BLOCK "      # 16 bytes, trailing space is part of it
VBT_HEADER_VERSION = 100
BDB_VERSION = 221                  # a typical SKL/KBL-era BDB version


def build() -> bytes:
    vbt_hdr_len = struct.calcsize(VBT_HEADER_FMT)
    bdb_hdr_len = struct.calcsize(BDB_HEADER_FMT)
    assert vbt_hdr_len == 48 and bdb_hdr_len == 22

    bdb = struct.pack(BDB_HEADER_FMT, BDB_SIG, BDB_VERSION, bdb_hdr_len, bdb_hdr_len)
    total = vbt_hdr_len + len(bdb)

    def header(checksum: int) -> bytes:
        return struct.pack(VBT_HEADER_FMT, VBT_SIG, VBT_HEADER_VERSION, vbt_hdr_len,
                           total, checksum, 0, vbt_hdr_len, bytes(16))

    body = header(0) + bdb
    checksum = (-sum(body)) & 0xFF
    blob = header(checksum) + bdb
    assert sum(blob) & 0xFF == 0
    return blob


def validate(blob: bytes) -> None:
    """Mirror intel_bios_is_valid_vbt() and find_raw_section() from 7.2.3."""
    sig, _ver, _hlen, vbt_size, _ck, _r, bdb_off, _aim = struct.unpack_from(VBT_HEADER_FMT, blob)
    assert len(blob) >= 48, "VBT header incomplete"
    assert sig[:4] == b"$VBT", "VBT invalid signature"
    assert vbt_size <= len(blob), "VBT incomplete (vbt_size overflows)"
    assert bdb_off + 22 <= vbt_size, "BDB header incomplete"
    bsig, _bver, bhlen, bdb_size = struct.unpack_from(BDB_HEADER_FMT, blob, bdb_off)
    assert bdb_off + bdb_size <= vbt_size, "BDB incomplete"
    assert bsig == BDB_SIG
    # find_raw_section(): walk blocks from header_size while index + 3 < total
    assert not (bhlen + 3 < bdb_size), "BDB unexpectedly contains blocks"


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "headless-vbt.bin")
    blob = build()
    validate(blob)
    with open(out, "wb") as f:
        f.write(blob)
    print(f"wrote {out}: {len(blob)} bytes, valid, 0 BDB blocks (no child devices)")


if __name__ == "__main__":
    main()
