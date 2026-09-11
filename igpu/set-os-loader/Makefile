# imac-set-os.efi - clang + lld-link, no gnu-efi, no EDK2.
#   make            build imac-set-os.efi
#   make check      inspect the PE (subsystem 10, sections, no imports)
#   make test       also build the QEMU test images and run test/run-qemu.sh
# Needs: clang, lld (lld-link). `make test` also needs qemu-system-x86,
# edk2-ovmf, mtools and limine (its BOOTX64.EFI starts the test entries).

CC      := clang
LD      := lld-link
# -Os: small, loop-vectoriser-free code that is easy to read in objdump -d.
CFLAGS  := -target x86_64-unknown-windows -std=c11 -Os -Wall -Wextra -Werror \
           -ffreestanding -fno-builtin -fshort-wchar -mno-red-zone \
           -fno-stack-protector -mno-stack-arg-probe
# /Brepro: no timestamp, so the same source gives the same bytes (and b2sum).
LDFLAGS := /subsystem:efi_application /entry:efi_main /nodefaultlib /Brepro

all: imac-set-os.efi

%.o: %.c efi.h
	$(CC) $(CFLAGS) -c $< -o $@

test/fake-set-os-v%.o: test/fake-set-os.c imac-set-os.c efi.h
	$(CC) $(CFLAGS) -DFAKE_VERSION=$* -c $< -o $@

%.efi: %.o
	$(LD) $(LDFLAGS) /out:$@ $<

check: imac-set-os.efi
	file $<
	llvm-objdump -h $<
	llvm-objdump -p $< | grep -E 'Subsystem|AddressOfEntryPoint|DllCharacteristics'
	@! llvm-objdump -p $< | grep -q 'DLL Name' || { echo "unexpected imports"; exit 1; }
	@llvm-objdump -p $< | grep -q 'Subsystem.*0*a\b\|Subsystem *10' && echo "OK: subsystem 10 (EFI application), no imports"
	b2sum $<

test: imac-set-os.efi test/child.efi test/fake-set-os-v0.efi test/fake-set-os-v1.efi test/fake-set-os-v2.efi
	test/run-qemu.sh

clean:
	rm -f *.o *.efi *.lib test/*.o test/*.efi test/*.lib
	rm -rf test/out

.PHONY: all check test clean
.SECONDARY:
