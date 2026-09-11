/*
 * child.efi - QEMU test target for imac-set-os.efi. Prints what it was given
 * and returns, so the chainload path can be checked without a kernel.
 */
#include "../efi.h"

EFI_STATUS EFIAPI efi_main(EFI_HANDLE self, EFI_SYSTEM_TABLE *st)
{
	EFI_GUID li_guid = LOADED_IMAGE_GUID;
	EFI_LOADED_IMAGE *li;
	SIMPLE_TEXT_OUTPUT *out = st->ConOut;
	CHAR16 buf[256];
	UINTN n = 0, size;

	if (EFI_ERROR(st->BootServices->HandleProtocol(self, &li_guid, (void **)&li)))
		return EFI_NOT_FOUND;
	size = li->LoadOptionsSize;

	out->OutputString(out, L"child started, LoadOptions=<");
	if (li->LoadOptions)
		for (CHAR16 *o = li->LoadOptions; n < size / 2 && n < 255 && o[n]; n++)
			buf[n] = o[n];
	buf[n] = 0;
	out->OutputString(out, buf);
	out->OutputString(out, L"> LoadOptionsSize=");
	n = 20;
	buf[n] = 0;
	do { buf[--n] = L'0' + size % 10; size /= 10; } while (size);
	out->OutputString(out, buf + n);
	out->OutputString(out, li->DeviceHandle ? L" DeviceHandle=set\r\n" : L" DeviceHandle=NULL\r\n");

	/* Read back the loader's status variable (what Linux would see in efivarfs). */
	EFI_GUID vendor = IMAC_SET_OS_VENDOR_GUID;
	UINT32 attr = 0;
	CHAR16 var[257];
	size = sizeof(var) - sizeof(CHAR16);
	if (EFI_ERROR(st->RuntimeServices->GetVariable(L"ImacSetOsStatus", &vendor, &attr, &size, var))) {
		out->OutputString(out, L"child: ImacSetOsStatus not set\r\n");
		return EFI_SUCCESS;
	}
	var[size / 2] = 0;
	out->OutputString(out, attr == 6 ? L"child: ImacSetOsStatus (attr 6, volatile) =\r\n"
	                                 : L"child: ImacSetOsStatus has unexpected attributes =\r\n");
	out->OutputString(out, var);
	return EFI_SUCCESS;
}
