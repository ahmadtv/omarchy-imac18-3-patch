#!/usr/bin/env bash
#
# patch-imac5k-amdgpu.sh — build a 5K-patched amdgpu module for the CURRENTLY
# running kernel and swap it in, WITHOUT installing a second kernel.
#
# What it does:
#   1. Fetches kernel source matching your running kernel version
#   2. Applies the iMac 5K patch stack (wake + stitch + genlock)
#   3. Builds ONLY the amdgpu module (against your kernel's own config +
#      Module.symvers, so it loads into the running kernel)
#   4. Backs up the stock amdgpu.ko and installs the patched one
#   5. Rebuilds the initramfs and adds `amdgpu.tiled_stitch=1`
#
# Re-run it after a kernel update to rebuild for the new kernel.
#   Restore the stock module any time with:  sudo ./patch-imac5k-amdgpu.sh --restore
#
# ── HONEST LIMITS — READ THESE ─────────────────────────────────────────────
# * The patch is version-specific. It is verified for kernels 7.1.x-7.2.x. On a kernel
#   whose amdgpu source differs enough (e.g. a future 7.3+), the patch will
#   FAIL TO APPLY and this script aborts cleanly without touching anything.
#   That case needs a human to re-port the patch — it is not a "just re-run" fix.
# * This replaces a core GPU module on your real system. If the built module
#   fails to load, you get software rendering until you --restore (your desktop
#   still boots). TEST ON THE USB CLONE FIRST, never first on your only install.
# * Needs ~8 GB free and 20–40 min of compile time (amdgpu/display is large).
# ───────────────────────────────────────────────────────────────────────────
set -euo pipefail

PATCH_KVER_SUPPORTED="7.1 7.2"   # kernel series this patch is verified to apply to
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/../patches/imac5k-amdgpu-7.2.2.patch"
WORK="${IMAC5K_WORK:-/home/${SUDO_USER:-$USER}/.cache/kernel-5k-build}"
KREL="$(uname -r)"                        # e.g. 7.2.2-arch1-1
KVER="${KREL%%-*}"                        # e.g. 7.2.2
KSERIES="${KVER%.*}"                      # e.g. 7.2
MODDIR="/usr/lib/modules/${KREL}/kernel/drivers/gpu/drm/amd/amdgpu"
BUILDLINK="/usr/lib/modules/${KREL}/build"

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 ${*:-}"

# ── restore mode ───────────────────────────────────────────────────────────
find_amdgpu() { find "$(dirname "$MODDIR")" -maxdepth 2 -name 'amdgpu.ko*' ! -name '*.stock-backup' 2>/dev/null | head -1; }
if [[ "${1:-}" == "--restore" ]]; then
	AMDKO="$(find_amdgpu)" || true
	BAK="${AMDKO}.stock-backup"
	[[ -f "$BAK" ]] || die "no backup found at ${BAK} — nothing to restore"
	say "restoring stock amdgpu module"
	cp -v "$BAK" "$AMDKO"
	depmod "$KREL"
	say "rebuilding initramfs"
	if command -v limine-mkinitcpio >/dev/null; then limine-mkinitcpio; else mkinitcpio -P; fi
	say "done — reboot to run the stock module. (You may also want to remove amdgpu.tiled_stitch from your cmdline.)"
	exit 0
fi

# ── sanity / version gate ──────────────────────────────────────────────────
[[ -f "$PATCH_FILE" ]] || die "patch not found: $PATCH_FILE"
say "running kernel: ${KREL}  (source version ${KVER}, series ${KSERIES})"
if [[ " ${PATCH_KVER_SUPPORTED} " != *" ${KSERIES} "* ]]; then
	cat >&2 <<EOF
$(printf '\033[1;31mABORT:\033[0m') this patch is verified for kernel series ${PATCH_KVER_SUPPORTED} but you are on ${KVER}.
It will not apply to a different amdgpu source and would produce a broken module.
This needs the patch re-ported to ${KSERIES}.x first (a human step, not a re-run).
Nothing was changed.
EOF
	exit 1
fi

command -v gcc >/dev/null || die "install build tools first:  pacman -S --needed base-devel bc cpio pahole"
[[ -e "$BUILDLINK/Module.symvers" ]] || die "install kernel headers first:  pacman -S linux-headers  (needed so the module matches this kernel)"

# ── fetch matching kernel source (for the driver .c files) ─────────────────
mkdir -p "$WORK"; cd "$WORK"
SRC="linux-${KVER}"
if [[ ! -d "$SRC" ]]; then
	say "downloading kernel ${KVER} source"
	MAJ="${KVER%%.*}"
	curl -fL --retry 3 -o "${SRC}.tar.xz" \
		"https://cdn.kernel.org/pub/linux/kernel/v${MAJ}.x/${SRC}.tar.xz" \
		|| die "could not download ${SRC}.tar.xz from kernel.org"
	say "extracting"
	tar -xf "${SRC}.tar.xz"
fi
cd "$SRC"

# ── configure to match the running kernel exactly (vermagic + symbols) ─────
say "configuring to match the running kernel"
cp "$BUILDLINK/.config" .config
cp "$BUILDLINK/Module.symvers" Module.symvers 2>/dev/null || true
# Arch's kernel release is e.g. 7.2.2-arch1-1 while kernel.org source builds
# as plain 7.2.2 -- write the suffix into a localversion file so the built
# module's vermagic matches `uname -r` exactly (else it refuses to load).
KSUFFIX="${KREL#"$KVER"}"                 # e.g. -arch1-1
printf '%s' "$KSUFFIX" > localversion
scripts/config --disable LOCALVERSION_AUTO 2>/dev/null || true
scripts/config --set-str LOCALVERSION "" 2>/dev/null || true
make olddefconfig >/dev/null
BUILTREL="$(make -s kernelrelease)"
[[ "$BUILTREL" == "$KREL" ]] || die "computed kernelrelease '$BUILTREL' != running '$KREL' — refusing to build a module that won't load"
say "kernelrelease matches running kernel: $BUILTREL"

# ── apply the 5K patch stack (idempotent: skip if already applied) ─────────
if patch -p1 --dry-run --force < "$PATCH_FILE" >/dev/null 2>&1; then
	say "applying iMac 5K patch stack"
	patch -p1 < "$PATCH_FILE"
elif patch -p1 -R --dry-run --force < "$PATCH_FILE" >/dev/null 2>&1; then
	say "patch already applied — reusing"
else
	die "patch did not apply cleanly to ${KVER} source. It likely needs re-porting for this kernel. Nothing installed."
fi

# ── build just the amdgpu module ───────────────────────────────────────────
say "preparing build (fast)"
make modules_prepare >/dev/null
say "building amdgpu module — this is the slow part (~20-40 min)"
make -j"$(nproc)" M=drivers/gpu/drm/amd/amdgpu modules \
	|| make -j"$(nproc)" drivers/gpu/drm/amd/amdgpu/amdgpu.ko \
	|| die "module build failed"

BUILT="$(find drivers/gpu/drm/amd/amdgpu -name amdgpu.ko | head -1)"
[[ -f "$BUILT" ]] || die "built amdgpu.ko not found"

# quick sanity: vermagic must match the running kernel or it won't load
VM="$(modinfo -F vermagic "$BUILT" 2>/dev/null | awk '{print $1}')"
[[ "$VM" == "$KREL" ]] || say "WARNING: built vermagic '$VM' != running '$KREL' — module may need --force; test on the clone first."

# ── install (compressed to match Arch's .ko.zst) with a stock backup ───────
AMDKO="$(find_amdgpu)" || die "stock amdgpu module not found under $MODDIR"
BAK="${AMDKO}.stock-backup"
[[ -f "$BAK" ]] || { say "backing up stock module -> $BAK"; cp "$AMDKO" "$BAK"; }

say "stripping debug info (matches stock packaging)"
strip --strip-debug "$BUILT"

say "installing patched amdgpu module"
case "$AMDKO" in
	*.zst) zstd -q -f -19 "$BUILT" -o "$AMDKO" ;;
	*.xz)  xz  -c "$BUILT" > "$AMDKO" ;;
	*)     cp "$BUILT" "$AMDKO" ;;
esac
depmod "$KREL"

# ── add the boot parameter (Limine, with the 3-copy sync) ──────────────────
if ! grep -q 'amdgpu.tiled_stitch=1' /etc/default/limine 2>/dev/null; then
	say "adding amdgpu.tiled_stitch=1 to the default cmdline"
	cp /etc/default/limine "/etc/default/limine.backup-5k-$(date +%s)"
	sed -i 's/\(KERNEL_CMDLINE\[default\]="[^"]*\)"/\1 amdgpu.tiled_stitch=1"/' /etc/default/limine
fi

say "rebuilding initramfs (bakes the patched module in)"
if command -v limine-mkinitcpio >/dev/null; then limine-mkinitcpio; else mkinitcpio -P; fi

# sync the Limine copies (this ESP has three — see the project README)
if [[ -f /boot/limine.conf ]]; then
	cp -f /boot/limine.conf /boot/EFI/BOOT/limine.conf 2>/dev/null || true
	cp -f /boot/limine.conf /boot/EFI/limine/limine.conf 2>/dev/null || true
fi

cat <<EOF

$(printf '\033[1;32mDONE.\033[0m') Patched amdgpu built for ${KREL} and installed.
Stock module backed up at: ${BAK}
Reboot to load it. Your compositor (Hyprland) must run for the single 5K output.

If anything looks wrong after reboot:  sudo $0 --restore
Re-run this script after any kernel update to rebuild for the new kernel
(it will refuse cleanly if the patch no longer applies to that version).
EOF
