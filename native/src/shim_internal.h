#ifndef NATIVE_SRC_SHIM_INTERNAL_H_
#define NATIVE_SRC_SHIM_INTERNAL_H_

// Must precede <windows.h> to get C bindings from the Windows SDK.
#define COBJMACROS
#define INITGUID

// NOTE (Google style exception): Windows SDK order matters here —
// <windows.h> + <objbase.h> must come before <mmdeviceapi.h> /
// <functiondiscoverykeys_devpkey.h>, so this group is dependency-ordered,
// not alphabetical.
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "advapi32.lib")

static inline wchar_t *kirk_wstr_dup(const wchar_t *src) {
  if (!src) return NULL;
  size_t len = wcslen(src) + 1;
  wchar_t *dst = (wchar_t *)malloc(len * sizeof(wchar_t));
  if (dst) wcscpy(dst, src);
  return dst;
}

/* The SDK declares these as extern const but ships no definition, so define them here. */
static const CLSID KIRK_CLSID_MMDeviceEnumerator =
  {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const IID KIRK_IID_IMMDeviceEnumerator =
  {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};

#endif  // NATIVE_SRC_SHIM_INTERNAL_H_
