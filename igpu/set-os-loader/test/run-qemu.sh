#!/usr/bin/env bash
#
# QEMU/OVMF smoke test for imac-set-os.efi, through the same chain as the
# iMac minus OpenCore: OVMF -> Limine (the installed /usr/share/limine
# BOOTX64.EFI, hash-pinned entries, hash_mismatch_panic: yes) -> loader -> target.
#
# OVMF has no Apple set_os protocol, so the plain loader exercises "not found,
# continue"; test/fake-set-os.efi installs a fake v2 protocol first and runs
# the same loader code, exercising "found". The UKI cases boot the running
# kernel inside a systemd-stub UKI assembled exactly like mkinitcpio's objcopy
# path, to see which command line the kernel really gets.
#
# Every case gets its own /limine.conf on the ESP image; serial output lands in
# test/out/<case>.log. ONLY=<case> runs a single case.
set -uo pipefail
cd "$(dirname "$0")/.."

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
LIMINE=/usr/share/limine/BOOTX64.EFI
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
KERNEL=/usr/lib/modules/$(uname -r)/vmlinuz
OUT=test/out
ESP=$OUT/esp
pass=0 failn=0

for f in "$OVMF_CODE" "$OVMF_VARS" "$LIMINE" imac-set-os.efi test/child.efi test/fake-set-os-v{0,1,2}.efi; do
	[[ -f $f ]] || { echo "missing $f"; exit 1; }
done
rm -rf "$OUT"; mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/imac-set-os" "$ESP/EFI/test"
cp "$LIMINE" "$ESP/EFI/BOOT/BOOTX64.EFI"
cp imac-set-os.efi test/fake-set-os-v{0,1,2}.efi "$ESP/EFI/imac-set-os/"
cp test/child.efi "$ESP/EFI/test/"

# UKI the way mkinitcpio builds one without ukify: objcopy the sections onto
# the systemd stub at increasing VMAs. No .initrd: the kernel only has to get
# far enough to print "Kernel command line:" and then panic (panic=-1 +
# -no-reboot ends QEMU).
build_uki() {
	local align off
	align=$(objdump -p "$STUB" | awk '/SectionAlignment/ {print strtonum("0x"$2)}')
	off=$(objdump -h "$STUB" | awk 'NF==7 {s=strtonum("0x"$3); o=strtonum("0x"$4)} END {print s+o}')
	up() { echo $(( ($1 + align - 1) / align * align )); }
	off=$(up "$off")
	printf 'console=ttyS0 ignore_loglevel panic=-1 EMBEDDED_CMDLINE_MARKER\n\0' > "$OUT/cmdline"
	printf '%s' "$(uname -r)" > "$OUT/uname"
	grep -v '^VERSION_ID=' /etc/os-release > "$OUT/osrel"
	local args=() s f
	for s in .uname:uname .osrel:osrel .cmdline:cmdline .linux:KERNEL; do
		f=$OUT/${s#*:}; [[ ${s#*:} == KERNEL ]] && f=$KERNEL
		args+=(--add-section "${s%%:*}=$f" --change-section-vma "${s%%:*}=$(printf 0x%x "$off")")
		off=$(( off + $(up "$(stat -Lc %s "$f")") ))
	done
	objcopy "$STUB" -p "${args[@]}" "$ESP/EFI/test/uki.efi"
}
have_uki=0
if [[ -r $KERNEL && -f $STUB ]] && build_uki; then have_uki=1; fi

# A GPT disk image with one EFI System Partition (at 1 MiB), like the iMac's
# ESP, filled with mtools -- no root, no loop devices, no mounts.
IMG=$OUT/disk.img
truncate -s 80M "$IMG"
printf 'label: gpt\nstart=2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q "$IMG"
PART="$IMG@@1M"
mformat -i "$PART" -F -T $(( (80 - 2) * 2048 )) ::
mcopy -s -i "$PART" "$ESP/EFI" ::/


# run <case> <loader: imac-set-os|fake-set-os-vN> <cmdline|-> <seconds> <expect-regex>...
run() {
	local name=$1 app=$2 cmd=$3 secs=$4; shift 4
	[[ -n ${ONLY:-} && $name != "$ONLY" ]] && return 0     # ONLY=<case> runs one case
	local hash; hash=$(b2sum "$app.efi" test/"$app.efi" 2>/dev/null | head -1 | cut -d' ' -f1)
	{
		printf 'timeout: 0\nhash_mismatch_panic: yes\nserial: yes\n\n/%s\n    protocol: efi\n' "$name"
		printf '    path: boot():/EFI/imac-set-os/%s.efi#%s\n' "$app" "$hash"
		[[ $cmd != - ]] && printf '    cmdline: %s\n' "$cmd"
	} > "$OUT/limine.conf"
	mcopy -o -i "$PART" "$OUT/limine.conf" ::/limine.conf
	local try
	for try in 1 2 3; do
		cp "$OVMF_VARS" "$OUT/vars.fd"
		timeout "$secs" qemu-system-x86_64 -machine q35 -enable-kvm -cpu host -m 1024 -no-reboot \
			-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
			-drive if=pflash,format=raw,file="$OUT/vars.fd" \
			-drive format=raw,file="$IMG" -nic none -display none -monitor none \
			-serial stdio </dev/null 2>&1 \
			| while IFS= read -r l || [[ -n $l ]]; do printf '%(%s)T %s\n' -1 "${l//$'\r'/}"; done > "$OUT/$name.log"
		# The loader prints before doing anything else. If none of its text is
		# in the log, our code never ran: OVMF (seen ~1 run in 20) or Limine
		# stalled first. That is a test-rig flake, so retry; anything else counts.
		grep -qaE 'imac-set-os:|fake set_os:' "$OUT/$name.log" && break
		echo "  [$name] firmware stalled before the loader ran (try $try), retrying"
	done
	local ok=1 re
	for re in "$@"; do        # "!regex" = must NOT appear
		if [[ $re == !* ]]; then
			grep -qaE -- "${re#!}" "$OUT/$name.log" && { ok=0; echo "  [$name] unexpected: ${re#!}"; }
		else
			grep -qaE -- "$re" "$OUT/$name.log" || { ok=0; echo "  [$name] missing: $re"; }
		fi
	done
	if ((ok)); then pass=$((pass+1)); echo "PASS $name"; else failn=$((failn+1)); echo "FAIL $name (see $OUT/$name.log)"; fi
	grep -aE 'imac-set-os:|fake set_os|, version|child|Kernel command line' "$OUT/$name.log" | sed 's/^/    /'
}

run notfound-chainload imac-set-os '\EFI\test\child.efi hello  world a=b' 20 \
	'set_os protocol not found' 'loading \\EFI\\test\\child.efi with 16 chars' \
	'child started, LoadOptions=<hello  world a=b> LoadOptionsSize=34 DeviceHandle=set' \
	'ImacSetOsStatus \(attr 6, volatile\)' '^[0-9]+ imac-set-os: set_os protocol not found'
run slashes-no-options imac-set-os 'EFI/test/child.efi' 20 \
	'loading EFI/test/child.efi with 0 chars' 'child started, LoadOptions=<> LoadOptionsSize=0 DeviceHandle=set'
run fake-v2 fake-set-os-v2 '\EFI\test\child.efi from-fake' 20 \
	'call 1: set_os_vendor\("Apple Inc."\)' 'call 2: set_os_version\("Mac OS X 10.9"\)' \
	'imac-set-os: set_os v2:' '^[0-9]+  vendor ok,' '^[0-9]+  version ok$' 'child started, LoadOptions=<from-fake>'
run fake-v1 fake-set-os-v1 '\EFI\test\child.efi v1' 20 \
	'call 1: set_os_version\("Mac OS X 10.9"\)' '!set_os_vendor' \
	'imac-set-os: set_os v1:' '^[0-9]+  version ok$' 'child started, LoadOptions=<v1>'
run fake-v0 fake-set-os-v0 '\EFI\test\child.efi v0' 20 \
	'!fake set_os: call' 'imac-set-os: set_os v0: nothing to call' 'child started, LoadOptions=<v0>'
run no-target imac-set-os - 25 \
	'no target in LoadOptions' 'parsing LoadOptions failed, status 0x8000000000000002' 'returning to the firmware in 5 s'
run missing-file imac-set-os '\EFI\test\nope.efi x' 25 \
	'LoadImage failed, status 0x800000000000000E' 'returning to the firmware in 5 s'
if ((have_uki)); then
	run uki-loadoptions imac-set-os '\EFI\test\uki.efi console=ttyS0 ignore_loglevel panic=-1 LOADOPTIONS_MARKER' 60 \
		'Kernel command line: .*LOADOPTIONS_MARKER' '!Kernel command line: .*EMBEDDED_CMDLINE_MARKER'
	run uki-no-options imac-set-os '\EFI\test\uki.efi' 60 \
		'Kernel command line: .*EMBEDDED_CMDLINE_MARKER' '!LOADOPTIONS_MARKER'
else
	echo "SKIP uki cases (need readable $KERNEL and $STUB)"
fi
echo "$pass passed, $failn failed"
((failn == 0))
