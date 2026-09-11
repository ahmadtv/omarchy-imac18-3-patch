/*
 * efi.h - the minimum of UEFI needed by imac-set-os.efi, written by hand from
 * the UEFI 2.10 specification so the whole program can be audited without
 * gnu-efi or EDK2. Only the members that are used carry real types; the rest
 * are `void *` placeholders that keep the table offsets right.
 */
#ifndef IMAC_EFI_H
#define IMAC_EFI_H

typedef unsigned char       UINT8;
typedef unsigned short      UINT16;
typedef unsigned int        UINT32;
typedef unsigned long long  UINT64;
typedef UINT64              UINTN;
typedef UINT16              CHAR16;     /* UCS-2; needs -fshort-wchar for L"" */
typedef UINT8               BOOLEAN;
typedef UINTN               EFI_STATUS;
typedef void               *EFI_HANDLE;

#define EFIAPI __attribute__((ms_abi))  /* already the default for -target *-windows */

#define EFI_SUCCESS            0ULL
#define EFI_ERR(n)             (0x8000000000000000ULL | (n))
#define EFI_INVALID_PARAMETER  EFI_ERR(2)
#define EFI_NOT_FOUND          EFI_ERR(14)
#define EFI_ERROR(s)           (((long long)(s)) < 0)

typedef struct { UINT32 d1; UINT16 d2, d3; UINT8 d4[8]; } EFI_GUID;

typedef struct {
	UINT64 Signature;
	UINT32 Revision, HeaderSize, CRC32, Reserved;
} EFI_TABLE_HEADER;

typedef struct SIMPLE_TEXT_OUTPUT {
	void *Reset;
	EFI_STATUS (EFIAPI *OutputString)(struct SIMPLE_TEXT_OUTPUT *self, CHAR16 *s);
	/* TestString, QueryMode, SetMode, SetAttribute, ... not used */
} SIMPLE_TEXT_OUTPUT;

/* Device path node header. Nodes are packed and variable length. */
typedef struct {
	UINT8 Type, SubType, Length[2];
} EFI_DEVICE_PATH;
#define DP_TYPE_MEDIA   0x04
#define DP_SUB_FILEPATH 0x04
#define DP_TYPE_END     0x7F
#define DP_SUB_END      0xFF

typedef struct {
	EFI_TABLE_HEADER Hdr;
	void *RaiseTPL, *RestoreTPL;
	void *AllocatePages, *FreePages, *GetMemoryMap;
	EFI_STATUS (EFIAPI *AllocatePool)(UINT32 type, UINTN size, void **buf);
	EFI_STATUS (EFIAPI *FreePool)(void *buf);
	void *CreateEvent, *SetTimer, *WaitForEvent, *SignalEvent, *CloseEvent, *CheckEvent;
	/* Install/Uninstall are only used by test/fake-set-os.c */
	EFI_STATUS (EFIAPI *InstallProtocolInterface)(EFI_HANDLE *h, EFI_GUID *proto,
	                                              UINT32 iface_type, void *iface);
	void *ReinstallProtocolInterface;
	EFI_STATUS (EFIAPI *UninstallProtocolInterface)(EFI_HANDLE h, EFI_GUID *proto, void *iface);
	EFI_STATUS (EFIAPI *HandleProtocol)(EFI_HANDLE h, EFI_GUID *proto, void **iface);
	void *Reserved, *RegisterProtocolNotify, *LocateHandle, *LocateDevicePath;
	void *InstallConfigurationTable;
	EFI_STATUS (EFIAPI *LoadImage)(BOOLEAN boot_policy, EFI_HANDLE parent,
	                               EFI_DEVICE_PATH *path, void *src, UINTN src_size,
	                               EFI_HANDLE *image);
	EFI_STATUS (EFIAPI *StartImage)(EFI_HANDLE image, UINTN *exit_size, CHAR16 **exit_data);
	void *Exit;
	EFI_STATUS (EFIAPI *UnloadImage)(EFI_HANDLE image);
	void *ExitBootServices, *GetNextMonotonicCount;
	EFI_STATUS (EFIAPI *Stall)(UINTN microseconds);
	void *SetWatchdogTimer, *ConnectController, *DisconnectController;
	void *OpenProtocol, *CloseProtocol, *OpenProtocolInformation;
	void *ProtocolsPerHandle, *LocateHandleBuffer;
	EFI_STATUS (EFIAPI *LocateProtocol)(EFI_GUID *proto, void *registration, void **iface);
	/* ... rest not used */
} EFI_BOOT_SERVICES;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	void *GetTime, *SetTime, *GetWakeupTime, *SetWakeupTime;
	void *SetVirtualAddressMap, *ConvertPointer;
	/* GetVariable is only used by test/child.c */
	EFI_STATUS (EFIAPI *GetVariable)(CHAR16 *name, EFI_GUID *vendor, UINT32 *attr,
	                                 UINTN *size, void *data);
	void *GetNextVariableName;
	EFI_STATUS (EFIAPI *SetVariable)(CHAR16 *name, EFI_GUID *vendor, UINT32 attr,
	                                 UINTN size, void *data);
	/* ... rest not used */
} EFI_RUNTIME_SERVICES;
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 0x2
#define EFI_VARIABLE_RUNTIME_ACCESS     0x4   /* no NON_VOLATILE (0x1): RAM only */

typedef struct {
	EFI_TABLE_HEADER Hdr;
	CHAR16 *FirmwareVendor;
	UINT32 FirmwareRevision;
	EFI_HANDLE ConsoleInHandle;  void *ConIn;
	EFI_HANDLE ConsoleOutHandle; SIMPLE_TEXT_OUTPUT *ConOut;
	EFI_HANDLE StdErrHandle;     SIMPLE_TEXT_OUTPUT *StdErr;
	EFI_RUNTIME_SERVICES *RuntimeServices;
	EFI_BOOT_SERVICES *BootServices;
	UINTN NumberOfTableEntries;
	void *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
	UINT32 Revision;
	EFI_HANDLE ParentHandle;
	EFI_SYSTEM_TABLE *SystemTable;
	EFI_HANDLE DeviceHandle;        /* volume the image was loaded from */
	EFI_DEVICE_PATH *FilePath;
	void *Reserved;
	UINT32 LoadOptionsSize;         /* in bytes */
	void *LoadOptions;
	void *ImageBase;
	UINT64 ImageSize;
	UINT32 ImageCodeType, ImageDataType;
	void *Unload;
} EFI_LOADED_IMAGE;

#define EfiLoaderData 2

#define LOADED_IMAGE_GUID \
	{ 0x5b1b31a1, 0x9562, 0x11d2, { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define DEVICE_PATH_GUID \
	{ 0x09576e91, 0x6d3f, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }

/* Our own vendor GUID for the volatile status variable (random, uuidgen):
 * Linux: /sys/firmware/efi/efivars/ImacSetOsStatus-30c2e1ad-9ae4-471f-958c-21d8eb36faa8 */
#define IMAC_SET_OS_VENDOR_GUID \
	{ 0x30c2e1ad, 0x9ae4, 0x471f, { 0x95, 0x8c, 0x21, 0xd8, 0xeb, 0x36, 0xfa, 0xa8 } }

/*
 * Apple "set_os" protocol, as used by the Linux EFI stub
 * (drivers/firmware/efi/libstub/x86-stub.c apple_set_os(), GUID from
 * include/linux/efi.h APPLE_SET_OS_PROTOCOL_GUID). Note the member order:
 * set_os_version comes BEFORE set_os_vendor. Strings are 8-bit ASCII.
 */
#define APPLE_SET_OS_GUID \
	{ 0xc5c5da95, 0x7d5c, 0x45e6, { 0xb2, 0xf1, 0x3f, 0xd5, 0x2b, 0xb1, 0x00, 0x77 } }
typedef struct {
	UINT64 version;
	EFI_STATUS (EFIAPI *set_os_version)(const char *version);
	EFI_STATUS (EFIAPI *set_os_vendor)(const char *vendor);
} APPLE_SET_OS;

#endif
