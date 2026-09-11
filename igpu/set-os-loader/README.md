# imac-set-os.efi

A small EFI application that tells Apple firmware "Mac OS X is booting" and
then chainloads a Linux UKI. On the iMac18,3, Apple firmware hides the Intel
HD 630 iGPU (`00:02.0`, `8086:5912`) unless the loader calls the Apple
**set_os** protocol before `ExitBootServices`. The Linux EFI stub only makes
that call for a list of MacBookPro models (`apple_set_os()` in
`drivers/firmware/efi/libstub/x86-stub.c`), so this program makes it instead.

**Status: built and tested in QEMU/OVMF. Not yet booted on the iMac. Nothing
on `/boot` has been changed.** Whether set_os actually exposes the iGPU on an
iMac18,3 is still unknown; see "What could go wrong".

## What it does

```
Limine entry  --LoadOptions="\EFI\imac-set-os\omarchy_linux-igpu.efi <kernel cmdline>"-->  imac-set-os.efi
  1. LocateProtocol(c5c5da95-7d5c-45e6-b2f1-3fd52bb10077)   Apple set_os
       found:     version >= 2 -> set_os_vendor("Apple Inc.")
                  version >  0 -> set_os_version("Mac OS X 10.9")
       not found: print it and carry on
  2. LoadImage(<our DeviceHandle's device path> + FILEPATH(<first word>))
     child LoadOptions = the rest of our LoadOptions (UCS-2, NUL-terminated),
                         or none if there is no rest
     save everything printed so far in the volatile variable ImacSetOsStatus
     StartImage(child)                                        the UKI never returns
  3. any failure: print the EFI status, wait 5 s, return the status
```

These are the kernel's calls, strings and order. The protocol struct is
`{ u64 version; set_os_version(const char *); set_os_vendor(const char *); }`,
with version first and vendor second, and every function uses the MS ABI.
The on-screen line looks like `imac-set-os: set_os v2: vendor ok, version ok`
or `imac-set-os: set_os protocol not found (0x800000000000000E), continuing`.

Other details:

* The target path is the first word of LoadOptions. `/` becomes `\` and a
  leading `\` is added if missing. The file is read from the same volume
  (partition) the loader was loaded from.
* Control characters in the pass-through options become spaces. systemd-stub
  throws away LoadOptions that contain any character ≤ 0x1F.
* The loader writes the **`ImacSetOsStatus`** variable
  (vendor GUID `30c2e1ad-9ae4-471f-958c-21d8eb36faa8`) with
  `BOOTSERVICE|RUNTIME` attributes and no `NON_VOLATILE`, so it only lives in
  RAM and nothing goes to NVRAM. You can read it after boot, which matters
  because ConOut may not be visible on the iMac once Limine has set up its
  framebuffer.
* It never waits for a key. Every error path stalls for 5 s and returns.

## Files

| file | lines | what |
|---|---|---|
| `imac-set-os.c` | ~280 | the whole program |
| `efi.h` | ~150 | hand-written UEFI types and GUIDs. Only the members that are used are typed. `_Static_assert`s in the `.c` pin the table offsets to the spec. |
| `Makefile` | | `make`, `make check`, `make test`, `make clean` |
| `test/child.c` | | QEMU target: prints its LoadOptions, DeviceHandle and the `ImacSetOsStatus` variable, then returns |
| `test/fake-set-os.c` | | QEMU harness, built as `fake-set-os-v0/v1/v2.efi`: installs a fake set_os protocol of that version that logs its numbered calls, then runs the loader code in-process (`#include "../imac-set-os.c"`) |
| `test/run-qemu.sh` | | the smoke test (see "Verified") |

## Build

You need `clang` and `lld` (for `lld-link`). No gnu-efi, EDK2 or mingw.

```sh
make            # -> imac-set-os.efi
make check      # file / llvm-objdump / b2sum
make test       # also needs qemu-system-x86, edk2-ovmf, mtools, limine (util-linux for sfdisk)
```

The compiler is `clang -target x86_64-unknown-windows -ffreestanding -fno-builtin
-fshort-wchar -mno-red-zone -fno-stack-protector -mno-stack-arg-probe -Os`. The
linker is `lld-link /subsystem:efi_application /entry:efi_main /nodefaultlib /Brepro`.
With `/Brepro` there is no timestamp, so the same source and toolchain give the
same bytes. With clang/lld 22.1.8 (this machine, 2026-09-11) the b2sum is

```
69a5d25ceff4eb7bb24c2a5841aec9118e904bc0047711f8205d7ad8904aa2bf2ae8d1fda053f1935acf10906e459a3be2a7e76264e3f21609c3541fd9508aed  imac-set-os.efi
```

A different compiler version gives different bytes. The Limine hash pin below is only
valid for the binary you actually copy to the ESP, so compute it from that
file.

## Verify the binary

`make check` runs these. Expected results:

```
$ file imac-set-os.efi
imac-set-os.efi: PE32+ executable for EFI (application), x86-64, 3 sections
                                     (4608 bytes; .text 0x7e6 with clang 22.1.8 -Os)

$ llvm-objdump -h imac-set-os.efi
  0 .text    ... TEXT
  1 .rdata   ... DATA      strings, GUIDs, a /Brepro debug-directory entry
  2 .data    00000000 ...  zero raw bytes; VirtualSize ~0x220 (ST/BS pointers +
                           the status buffer, zero-filled by the loader)

$ llvm-objdump -p imac-set-os.efi | grep -E 'Subsystem|Characteristics'
Characteristics 0x22                 executable, large address aware (RELOCS_STRIPPED clear)
Subsystem       0000000a (EFI application)
```

The subsystem must be **10** (EFI application). A boot-service driver would be
11. There must be **no import directory**, because everything goes through the
system table. There is **no `.reloc`** either. All code and data references
are RIP-relative, so the image has no absolute addresses, and since
`RELOCS_STRIPPED` is clear the firmware may load it anywhere. OVMF loads it well
away from its 0x140000000 preferred base, so the tests cover this. The test
harness does have a `.reloc` (its fake protocol table holds function pointers),
and it loads fine too.

For a manual audit, `llvm-objdump -d imac-set-os.efi` should show only
intra-image `call`s plus indirect calls through the firmware tables.

## How the UKI treats LoadOptions (checked, not assumed)

**How the UKIs here are built.** `limine-mkinitcpio` runs `mkinitcpio --uki`.
`ukify` is not installed (package `systemd-ukify`), so mkinitcpio takes its
objcopy path: `/usr/lib/systemd/boot/efi/linuxx64.efi.stub` plus the sections
`.uname`, `.osrel`, `.cmdline`, optionally `.splash`, `.linux` and `.initrd`
(see `build_uki()` in `/usr/bin/mkinitcpio`). `/boot` is root-only (vfat
`fmask=0077`), so `objdump -h /boot/EFI/Linux/omarchy_linux.efi` was not run.
The UKI's own `StubInfo` variable reads `systemd-stub 261.2-1-arch`, and
`scripts/imac-alt-entry` already extracts `.cmdline` and `.initrd` from these
images. To check the section list yourself:
`sudo objdump -h /boot/EFI/Linux/omarchy_linux.efi`.

**systemd-stub 261** (`src/boot/stub.c`, `process_arguments()` and
`settle_command_line()`):

1. It uses LoadOptions if it was *not* started by the UEFI Shell,
   `LoadOptionsSize ≥ 2`, and no character before the first NUL is ≤ 0x1F.
   Otherwise it ignores them. A leading `@N` selects a UKI profile.
2. Non-empty LoadOptions are dropped only if Secure Boot is on **and** (the UKI
   has a `.cmdline` or it is a confidential VM).
3. If there is still a command line, it **replaces** the embedded `.cmdline`
   completely. The two are not merged. If there is none, the embedded
   `.cmdline` is used. `.cmdline` addons are appended after that.

**Secure Boot on this machine.** There is no `SecureBoot-8be4df61-…` variable
in efivarfs at all. The Apple firmware does not implement it. So rule 2 never
fires, and **the command line the kernel gets is whatever LoadOptions carry.**
The `.cmdline` baked into the UKI is only a fallback for empty LoadOptions.
The same already holds for today's default entry: Limine passes its `cmdline:`
as LoadOptions (Limine v12 `common/protos/chainload.c`), so the `cmdline:`
line in `limine.conf` wins over the embedded copy.

**Seen in QEMU** with that exact stub and the running `7.2.3-arch1-3` kernel,
in a UKI assembled the way mkinitcpio does it:

* with options: `Kernel command line: console=ttyS0 ignore_loglevel panic=-1 LOADOPTIONS_MARKER`.
  The embedded marker is absent, so the options replaced it.
* without options: `Kernel command line: console=ttyS0 ignore_loglevel panic=-1 EMBEDDED_CMDLINE_MARKER`

**How Limine starts the loader** (from its v12 source). Limine reads the
file itself, which is where it checks `#hash`, and calls `LoadImage` from a
memory-mapped device path. It then sets the child's `DeviceHandle` to the
partition handle and `FilePath` to the relative path. It sets `LoadOptions` to
`cmdline:` widened byte-by-byte to UCS-2, with the size including the NUL. If
the child returns, Limine calls `Exit()`, which goes back to OpenCore rather
than to the Limine menu. The loader relies on that `DeviceHandle` to find the
UKI on the same ESP.

## Draft Limine entry (not applied)

The loader and the UKI copy go in their own directory, `/boot/EFI/imac-set-os/`,
and **not** in `EFI/Linux/`. `scripts/imac-alt-entry`'s `repin_orphans` gives
any `EFI/Linux/omarchy_linux-*.efi` a *direct* entry with the default cmdline.
That entry would boot the copy without set_os and look like a failed test.

```
/Test - iGPU set_os (remove after confirming)
### Added by hand, not by limine-entry-tool. A config regeneration drops it,
### which leaves the known-good default -- the safe outcome.
comment: imac-set-os.efi -> omarchy_linux-igpu.efi, uki b2sum <UKI_B2 first 16 hex>
protocol: efi
path: boot():/EFI/imac-set-os/imac-set-os.efi#<LOADER_B2>
cmdline: /EFI/imac-set-os/omarchy_linux-igpu.efi <DEFAULT CMDLINE> module_blacklist=i915 snd_hda_core.gpu_bind=0
```

* **The hash pin only covers the file Limine loads, which is
  `imac-set-os.efi`.** The UKI copy is read by the firmware's `LoadImage`, and
  Limine never sees it, so a `#hash` on the UKI path inside `cmdline:` would
  just end up in the path string and break the lookup. The UKI's b2sum goes in
  `comment:`, and you check it by hand before rebooting (step 5). If a UKI pin
  enforced at boot is wanted, the loader would have to read the file and check
  BLAKE2b itself, which would roughly double its size. That has not been done.
* `snd_hda_core.gpu_bind=0` must accompany `module_blacklist=i915`. Once the iGPU
  is visible, snd_hda_intel tries to bind to i915 and returns -EPROBE_DEFER until
  i915 loads (`sound/hda/core/i915.c`, `snd_hdac_i915_init`) -- with i915
  blacklisted the whole PCH HD-audio controller, speakers and mics included,
  would never appear. `gpu_bind=0` makes `i915_gfx_present()` return false.
* `module_blacklist=i915` is there so the first boot answers one question: does
  `8086:5912` appear? It keeps a new GPU driver out of that boot. Try i915
  (probably with `i915.disable_display=1`, as the iMac20,1 reports did) in a
  second test.
* The target path can be written with `/` (as here) or `\`. Both reach the
  loader verbatim through Limine (both were tested), and the loader converts
  `/` to `\`. Forward slashes avoid any shell or heredoc escaping.
* Leaving out everything after the path would boot the copy's embedded
  `.cmdline`, which is the default cmdline as of when it was built. Writing it
  out keeps the entry self-describing.

## Test steps (safe, reversible)

This follows the repo rule: a non-default test entry, with the default entry
and its UKI left alone.

```sh
cd ~/Projects/omarchy-imac18-3/igpu/set-os-loader
make clean && make && make check && make test          # 1. build + QEMU

sudo mkdir -p /boot/EFI/imac-set-os                    # 2. install loader + UKI copy
sudo cp imac-set-os.efi /boot/EFI/imac-set-os/
sudo cp /boot/EFI/Linux/omarchy_linux.efi /boot/EFI/imac-set-os/omarchy_linux-igpu.efi

LOADER_B2=$(sudo b2sum /boot/EFI/imac-set-os/imac-set-os.efi | cut -d' ' -f1)   # 3. pins
UKI_B2=$(sudo b2sum /boot/EFI/imac-set-os/omarchy_linux-igpu.efi | cut -d' ' -f1)
[[ $LOADER_B2 == $(b2sum imac-set-os.efi | cut -d' ' -f1) ]] && echo "loader copy matches build"
CMDLINE=$(sudo grep -m1 '^  cmdline:' /boot/limine.conf | sed 's/^  cmdline: //')

sudo cp /boot/limine.conf /boot/limine.conf.pre-igpu   # 4. add the entry
sudo grep -n '^/Test - 5K boot fixes' /boot/limine.conf # if this prints a line, put the
                                                        # block ABOVE it (imac-test-entry
                                                        # `drop` deletes marker..EOF); else append:
sudo tee -a /boot/limine.conf >/dev/null <<EOF

/Test - iGPU set_os (remove after confirming)
### Added by hand, not by limine-entry-tool. A config regeneration drops it,
### which leaves the known-good default -- the safe outcome.
comment: imac-set-os.efi -> omarchy_linux-igpu.efi, uki b2sum ${UKI_B2:0:16}
protocol: efi
path: boot():/EFI/imac-set-os/imac-set-os.efi#${LOADER_B2}
cmdline: /EFI/imac-set-os/omarchy_linux-igpu.efi ${CMDLINE} module_blacklist=i915 snd_hda_core.gpu_bind=0
EOF

sudo tail -8 /boot/limine.conf                          # 5. re-read it: hashes match, the
sudo b2sum /boot/EFI/imac-set-os/*.efi                  #    default entry and default_entry
                                                        #    are untouched
```

Reboot and pick **"/Test - iGPU set_os"** in Limine. Do not change the default.

After boot:

```sh
tail -c +5 /sys/firmware/efi/efivars/ImacSetOsStatus-30c2e1ad-9ae4-471f-958c-21d8eb36faa8 | iconv -f UTF-16LE
                                           # what the loader saw: "set_os v2: vendor ok, version ok" or "not found"
lspci -nn | grep 8086:5912                 # THE check: Intel HD 630 at 00:02.0
cat /proc/cmdline                          # ends in module_blacklist=i915, so passthrough worked
lsmod | grep i915                          # empty (blacklisted)
journalctl -b -k | grep -iE '0000:00:02.0|ramoops'    # PCI enumeration; ramoops region still claimed
~/Projects/omarchy-imac18-3/scripts/verify.sh          # the usual 5K/amdgpu checks
```

Reading the result:

| ImacSetOsStatus | `8086:5912` | meaning |
|---|---|---|
| `v2: vendor ok, version ok` | present | it works. Next test: allow i915. |
| `v…: … ok` | absent | the firmware takes the call but the iMac18,3 does not gate the iGPU on it, or decides before this point. OpenCore's `SignalAppleOS` is no later, so it would not help either. |
| `protocol not found` | absent | the protocol is not reachable under OpenCore at this stage. Report it; don't touch OpenCore. |
| variable missing | – | the loader never reached `StartImage` (the UKI was booted some other way?), or the firmware refused `SetVariable`. |

Remove the test (or let the next `limine-mkinitcpio` / kernel update drop
the entry):

```sh
sudo cp /boot/limine.conf.pre-igpu /boot/limine.conf   # only if nothing else changed it since
sudo rm -r /boot/EFI/imac-set-os
```

The UKI copy does not follow kernel updates. After one, its kernel no longer
matches `/usr/lib/modules`. Re-copy it and re-pin, or drop the test.

## What could go wrong

* **Black screen or hang after the kernel starts.** Exposing the iGPU can
  change what the firmware sets up, such as stolen memory and the PCI layout.
  Hold power, boot again and take the default entry.
* **Loader error** (bad path, LoadImage failure): it prints the status and
  waits 5 s. Limine then exits to OpenCore, where you pick again.
* **ConOut not visible.** The Limine framebuffer or OpenCore's text renderer
  may hide the one-line message. The `ImacSetOsStatus` variable covers that.
* **OpenCore interplay.** OpenCore can install its own OS-info protocol
  (the same GUID). If it has, `LocateProtocol` returns the first one
  installed. The kernel faces the same situation on MacBookPros.

## Verified vs not verified

Verified, on this machine and in QEMU:

* The build with clang/lld 22.1.8: PE32+, subsystem 10, 3 sections, no
  imports, no relocations needed. Rebuilding gives the same b2sum (`/Brepro`).
* `test/run-qemu.sh`: QEMU 11.1.1, OVMF (edk2-ovmf 202608), a GPT disk with an
  ESP, and Limine 12.8.0 (the installed `/usr/share/limine/BOOTX64.EFI`) with
  `hash_mismatch_panic: yes` and b2sum-pinned `protocol: efi` entries. All 9
  cases pass:
  * not found → continue → chainload `child.efi`: LoadOptions arrive exactly
    (`hello  world a=b`, size 34 incl. NUL), DeviceHandle is set, and the
    child reads `ImacSetOsStatus` (attr 6, volatile)
  * forward slashes, no leading `\`, no options: the child gets
    `LoadOptions=NULL`, size 0
  * fake v2 protocol: call 1 is `set_os_vendor("Apple Inc.")` and call 2 is
    `set_os_version("Mac OS X 10.9")`, and the status reads
    `v2: vendor ok, version ok`
  * fake v1: only `set_os_version` is called. fake v0: nothing is called
    (`v0: nothing to call`). The chainload still happens in both.
  * no LoadOptions: prints status `0x…02`, waits 5 s (from the timestamps),
    returns, and the firmware carries on (boots the disk again)
  * missing target: `LoadImage failed, status 0x800000000000000E`, 5 s,
    returns
  * a systemd-stub 261.2 UKI with options: the kernel gets exactly the passed
    options
  * the same UKI without options: the kernel gets the embedded `.cmdline`
* Test-rig flake: in about 1 run in 20, the OVMF/KVM guest stalls **before
  the loader runs**. Usually OVMF has not even started the boot option, and
  the serial log shows no loader text at all. The loader prints before it does
  anything else, so `run-qemu.sh` retries a run only when none of the loader's
  text appears (up to 3 tries). A loader that hung or crashed at entry would
  still fail every try. `ONLY=<case> test/run-qemu.sh` reruns a single case.

Not verified:

* Anything on the real iMac: whether the Apple set_os protocol is reachable
  after OpenCore → Limine, and whether it exposes `8086:5912` on an iMac18,3.
* The section list of the real `/boot/EFI/Linux/omarchy_linux.efi` and the real
  `limine.conf` layout (both root-only). The entry format is taken from
  `scripts/imac-alt-entry`.
* Behaviour with Secure Boot on (not applicable to this machine).
