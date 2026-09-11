/*
 * fake-set-os-vN.efi - QEMU test harness. OVMF has no Apple set_os protocol,
 * so this installs a fake one (version FAKE_VERSION) that logs its calls, then runs the
 * real loader code in-process (imac-set-os.c is #included with its entry
 * point renamed) so the "protocol found" path is exercised too. It takes the
 * same LoadOptions as imac-set-os.efi.
 */
#define efi_main imac_set_os_main
#include "../imac-set-os.c"
#undef efi_main

#ifndef FAKE_VERSION
#define FAKE_VERSION 2
#endif

static UINT64 calls;   /* numbered, so the test can check the call order */

static void log_call(const CHAR16 *fn, const char *arg)
{
	CHAR16 buf[64];
	UINTN n = 0;
	while (arg[n] && n < 63) { buf[n] = (UINT8)arg[n]; n++; }
	buf[n] = 0;
	print(L"fake set_os: call ");
	print_dec(++calls);
	print(L": ");
	print(fn);
	print(L"(\"");
	print(buf);
	print(L"\")\r\n");
}

static EFI_STATUS EFIAPI fake_vendor(const char *s)  { log_call(L"set_os_vendor", s);  return EFI_SUCCESS; }
static EFI_STATUS EFIAPI fake_version(const char *s) { log_call(L"set_os_version", s); return EFI_SUCCESS; }

static APPLE_SET_OS fake = { FAKE_VERSION, fake_version, fake_vendor };

EFI_STATUS EFIAPI efi_main(EFI_HANDLE self, EFI_SYSTEM_TABLE *systab)
{
	EFI_GUID guid = APPLE_SET_OS_GUID;
	EFI_HANDLE h = 0;
	EFI_STATUS st;

	st = systab->BootServices->InstallProtocolInterface(&h, &guid, 0, &fake);
	if (EFI_ERROR(st))
		return st;
	systab->ConOut->OutputString(systab->ConOut, L"fake set_os: installed\r\n");
	st = imac_set_os_main(self, systab);
	systab->BootServices->UninstallProtocolInterface(h, &guid, &fake);
	return st;
}
