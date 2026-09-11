/*
 * imac-set-os.efi - announce "Mac OS X" to Apple firmware, then chainload a UKI.
 *
 * Apple firmware hides the iMac18,3's Intel HD 630 (00:02.0) unless the boot
 * loader calls the Apple set_os protocol before ExitBootServices. The Linux
 * EFI stub only does that for a list of MacBookPro models, so this program
 * does it instead and then starts the real kernel image:
 *
 *   LoadOptions = "<path-of-target.efi> [options passed to the target...]"
 *
 * 1. LocateProtocol(APPLE_SET_OS); if present call set_os_vendor("Apple Inc.")
 *    when version >= 2, then set_os_version("Mac OS X 10.9") when version > 0
 *    -- the same calls, strings and order as the kernel's apple_set_os().
 *    Not present: say so and carry on.
 * 2. LoadImage the target from the volume we were loaded from
 *    (LoadedImage->DeviceHandle + a FILEPATH node), give it the rest of our
 *    LoadOptions as its LoadOptions, StartImage it. Just before StartImage,
 *    everything printed so far is saved in the volatile EFI variable
 *    ImacSetOsStatus, so Linux can read what happened.
 * 3. Any failure: print the EFI status, wait 5 s, return the status so the
 *    caller (Limine -> OpenCore -> firmware) falls back. Never hangs.
 */
#include "efi.h"

static EFI_SYSTEM_TABLE  *ST;
static EFI_BOOT_SERVICES *BS;

/* Table layout guards: these offsets are fixed by the UEFI spec (x64). */
_Static_assert(__builtin_offsetof(EFI_SYSTEM_TABLE, BootServices) == 0x60, "ST");
_Static_assert(__builtin_offsetof(EFI_BOOT_SERVICES, HandleProtocol) == 0x98, "BS");
_Static_assert(__builtin_offsetof(EFI_BOOT_SERVICES, LoadImage) == 0xC8, "BS");
_Static_assert(__builtin_offsetof(EFI_BOOT_SERVICES, Stall) == 0xF8, "BS");
_Static_assert(__builtin_offsetof(EFI_BOOT_SERVICES, LocateProtocol) == 0x140, "BS");
_Static_assert(__builtin_offsetof(EFI_RUNTIME_SERVICES, SetVariable) == 0x58, "RT");
_Static_assert(__builtin_offsetof(EFI_LOADED_IMAGE, LoadOptionsSize) == 0x30, "LI");
_Static_assert(__builtin_offsetof(EFI_LOADED_IMAGE, LoadOptions) == 0x38, "LI");

/* ---- console output ---------------------------------------------------- */

/* Everything printed is also kept here and, just before StartImage, stored in
 * a volatile (RAM-only) EFI variable, so the booted system can read what
 * happened even if ConOut was not visible:
 *   tail -c +5 /sys/firmware/efi/efivars/ImacSetOsStatus-30c2e1ad-... | iconv -f UTF-16LE */
static CHAR16 rec[256];
static UINTN  rec_len;

static void print(const CHAR16 *s)
{
	for (UINTN i = 0; s[i] && rec_len < 255; i++)
		rec[rec_len++] = s[i];
	ST->ConOut->OutputString(ST->ConOut, (CHAR16 *)s);
}

static void publish_status(void)
{
	EFI_GUID vendor = IMAC_SET_OS_VENDOR_GUID;
	rec[rec_len] = 0;
	/* best effort: a failure here must not stop the boot */
	ST->RuntimeServices->SetVariable(L"ImacSetOsStatus", &vendor,
		EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS,
		(rec_len + 1) * sizeof(CHAR16), rec);
}

static void print_n(const CHAR16 *s, UINTN n)      /* n chars, not NUL-terminated */
{
	CHAR16 buf[65];
	while (n) {
		UINTN k = n < 64 ? n : 64;
		for (UINTN i = 0; i < k; i++)
			buf[i] = s[i];
		buf[k] = 0;
		print(buf);
		s += k;
		n -= k;
	}
}

static void print_hex(UINT64 v)
{
	CHAR16 buf[19] = L"0x";
	for (int i = 0; i < 16; i++)
		buf[2 + i] = L"0123456789ABCDEF"[(v >> (60 - 4 * i)) & 0xF];
	buf[18] = 0;
	print(buf);
}

static void print_dec(UINT64 v)
{
	CHAR16 buf[21];
	int i = 20;
	buf[i] = 0;
	do { buf[--i] = L'0' + v % 10; v /= 10; } while (v);
	print(buf + i);
}

static void print_status(EFI_STATUS st)
{
	if (EFI_ERROR(st)) print_hex(st); else print(L"ok");
}

/* Report a failed step, give the user time to read it, hand the status back. */
static EFI_STATUS fail(const CHAR16 *what, EFI_STATUS st)
{
	print(L"imac-set-os: ");
	print(what);
	print(L" failed, status ");
	print_hex(st);
	print(L"\r\nimac-set-os: returning to the firmware in 5 s\r\n");
	BS->Stall(5 * 1000 * 1000);
	return st;
}

/* ---- step 1: Apple set_os ---------------------------------------------- */

static void apple_set_os(void)
{
	EFI_GUID guid = APPLE_SET_OS_GUID;
	APPLE_SET_OS *set_os = 0;
	EFI_STATUS st;

	print(L"imac-set-os: set_os ");
	st = BS->LocateProtocol(&guid, 0, (void **)&set_os);
	if (EFI_ERROR(st) || !set_os) {
		print(L"protocol not found (");
		print_hex(st);
		print(L"), continuing\r\n");
		return;
	}
	print(L"v");                   /* e.g. "v2: vendor ok, version ok" */
	print_dec(set_os->version);
	print(L":");
	if (set_os->version >= 2) {
		st = set_os->set_os_vendor("Apple Inc.");
		print(L" vendor ");
		print_status(st);
		print(L",");
	}
	if (set_os->version > 0) {
		/* the kernel notes the version string doesn't seem to matter */
		st = set_os->set_os_version("Mac OS X 10.9");
		print(L" version ");
		print_status(st);
	} else {
		print(L" nothing to call");
	}
	print(L"\r\n");
}

/* ---- step 2: chainload -------------------------------------------------- */

static int is_space(CHAR16 c) { return c == L' ' || c == L'\t'; }

static UINTN node_len(const EFI_DEVICE_PATH *n)
{
	return n->Length[0] | (UINTN)n->Length[1] << 8;
}

/* <device path of `dev`> + FILEPATH(path[0..plen)) + END, in pool memory.
 * The path is normalised to UEFI form: '/' -> '\', leading '\' ensured. */
static EFI_STATUS file_device_path(EFI_HANDLE dev, const CHAR16 *path, UINTN plen,
                                   EFI_DEVICE_PATH **out)
{
	EFI_GUID dp_guid = DEVICE_PATH_GUID;
	EFI_DEVICE_PATH *head, *n;
	UINT8 *buf, *p;
	UINTN hlen = 0, flen, lead;
	EFI_STATUS st;

	st = BS->HandleProtocol(dev, &dp_guid, (void **)&head);
	if (EFI_ERROR(st))
		return st;
	for (n = head; n->Type != DP_TYPE_END; n = (EFI_DEVICE_PATH *)((UINT8 *)n + node_len(n))) {
		if (node_len(n) < 4 || hlen > 4096)
			return EFI_INVALID_PARAMETER;   /* malformed path; don't walk off */
		hlen += node_len(n);
	}

	lead = (path[0] == L'\\' || path[0] == L'/') ? 0 : 1;
	flen = 4 + (lead + plen + 1) * sizeof(CHAR16);
	if (flen > 0xFFFF)
		return EFI_INVALID_PARAMETER;

	st = BS->AllocatePool(EfiLoaderData, hlen + flen + 4, (void **)&buf);
	if (EFI_ERROR(st))
		return st;
	for (UINTN i = 0; i < hlen; i++)
		buf[i] = ((UINT8 *)head)[i];

	p = buf + hlen;                          /* FILEPATH node */
	p[0] = DP_TYPE_MEDIA; p[1] = DP_SUB_FILEPATH;
	p[2] = flen & 0xFF;   p[3] = flen >> 8;
	/* Name as little-endian UCS-2, written bytewise: hlen may be odd, so
	 * p + 4 is not necessarily CHAR16-aligned. */
	UINT8 *w = p + 4;
	if (lead) { *w++ = '\\'; *w++ = 0; }
	for (UINTN i = 0; i < plen; i++) {
		CHAR16 c = path[i] == L'/' ? L'\\' : path[i];
		*w++ = c & 0xFF;
		*w++ = c >> 8;
	}
	*w++ = 0; *w = 0;

	p += flen;                               /* END node */
	p[0] = DP_TYPE_END; p[1] = DP_SUB_END; p[2] = 4; p[3] = 0;

	*out = (EFI_DEVICE_PATH *)buf;
	return EFI_SUCCESS;
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE self, EFI_SYSTEM_TABLE *systab)
{
	EFI_GUID li_guid = LOADED_IMAGE_GUID;
	EFI_LOADED_IMAGE *li, *child_li;
	EFI_DEVICE_PATH *target;
	EFI_HANDLE child = 0;
	CHAR16 *opt, *child_opt = 0;
	UINTN len = 0, i = 0, p0, p1, rest;
	EFI_STATUS st;

	ST = systab;
	BS = systab->BootServices;

	apple_set_os();

	st = BS->HandleProtocol(self, &li_guid, (void **)&li);
	if (EFI_ERROR(st))
		return fail(L"HandleProtocol(LoadedImage)", st);

	/* Split "<path> <rest...>". LoadOptions may or may not be NUL-terminated. */
	opt = li->LoadOptions;
	if (opt)
		while (len < li->LoadOptionsSize / sizeof(CHAR16) && opt[len])
			len++;
	while (i < len && is_space(opt[i])) i++;
	p0 = i;
	while (i < len && !is_space(opt[i])) i++;
	p1 = i;
	while (i < len && is_space(opt[i])) i++;
	rest = len - i;
	if (p1 == p0) {
		print(L"imac-set-os: no target in LoadOptions; usage: <\\path\\to\\image.efi> [options]\r\n");
		return fail(L"parsing LoadOptions", EFI_INVALID_PARAMETER);
	}

	if (!li->DeviceHandle)
		return fail(L"finding our own volume (DeviceHandle is NULL)", EFI_NOT_FOUND);
	st = file_device_path(li->DeviceHandle, opt + p0, p1 - p0, &target);
	if (EFI_ERROR(st))
		return fail(L"building the target device path", st);

	/* Child options: the rest, NUL-terminated. systemd-stub drops LoadOptions
	 * that contain control characters, so map any to spaces. None at all ->
	 * no LoadOptions, and a UKI falls back to its embedded .cmdline. */
	if (rest) {
		st = BS->AllocatePool(EfiLoaderData, (rest + 1) * sizeof(CHAR16), (void **)&child_opt);
		if (EFI_ERROR(st))
			return fail(L"AllocatePool", st);
		for (UINTN k = 0; k < rest; k++)
			child_opt[k] = opt[i + k] < 0x20 ? L' ' : opt[i + k];
		child_opt[rest] = 0;
	}

	print(L"imac-set-os: loading ");
	print_n(opt + p0, p1 - p0);
	print(L" with ");
	print_dec(rest);
	print(L" chars of options\r\n");

	st = BS->LoadImage(0, self, target, 0, 0, &child);
	if (EFI_ERROR(st))
		return fail(L"LoadImage", st);

	st = BS->HandleProtocol(child, &li_guid, (void **)&child_li);
	if (EFI_ERROR(st)) {
		BS->UnloadImage(child);
		return fail(L"HandleProtocol(child LoadedImage)", st);
	}
	child_li->LoadOptions = child_opt;
	child_li->LoadOptionsSize = rest ? (UINT32)((rest + 1) * sizeof(CHAR16)) : 0;

	publish_status();

	/* A kernel never comes back from here. A plain EFI app may; pass its status on. */
	st = BS->StartImage(child, 0, 0);
	if (EFI_ERROR(st))
		return fail(L"StartImage", st);
	return st;
}
