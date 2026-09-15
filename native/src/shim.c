#include "shim_internal.h"

#include "../include/shim.h"

int kirk_audio_enum_capture(kirk_audio_device_list *out) {
  if (!out) return -1;
  out->devices = NULL;
  out->count   = 0;

  IMMDeviceEnumerator *penum = NULL;
  HRESULT hr = CoCreateInstance(
    &KIRK_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
    &KIRK_IID_IMMDeviceEnumerator, (void **)&penum);
  if (FAILED(hr) || !penum) return -1;

  IMMDeviceCollection *pcoll = NULL;
  hr = IMMDeviceEnumerator_EnumAudioEndpoints(
    penum, eCapture, DEVICE_STATE_ACTIVE, &pcoll);
  if (FAILED(hr) || !pcoll) { IMMDeviceEnumerator_Release(penum); return -1; }

  UINT n = 0;
  IMMDeviceCollection_GetCount(pcoll, &n);
  if (n == 0) {
    IMMDeviceCollection_Release(pcoll);
    IMMDeviceEnumerator_Release(penum);
    return 0;
  }

  kirk_audio_device *devs = (kirk_audio_device *)calloc(n, sizeof(kirk_audio_device));
  UINT actual = 0;

  for (UINT i = 0; i < n; i++) {
    IMMDevice *pdev = NULL;
    IMMDeviceCollection_Item(pcoll, i, &pdev);
    if (!pdev) continue;

    LPWSTR wid = NULL;
    hr = IMMDevice_GetId(pdev, &wid);
    if (FAILED(hr) || !wid) { IMMDevice_Release(pdev); continue; }

    IPropertyStore *pps = NULL;
    hr = IMMDevice_OpenPropertyStore(pdev, STGM_READ, &pps);
    LPWSTR wname = NULL;
    if (SUCCEEDED(hr) && pps) {
      PROPVARIANT pv;
      PropVariantInit(&pv);
      IPropertyStore_GetValue(pps, &PKEY_Device_FriendlyName, &pv);
      if (pv.vt == VT_LPWSTR) wname = pv.pwszVal;
      else PropVariantClear(&pv);
      IPropertyStore_Release(pps);
    }

    devs[actual].id   = kirk_wstr_dup(wid);
    devs[actual].name = kirk_wstr_dup(wname ? wname : L"(unknown)");
    actual++;

    CoTaskMemFree(wid);
    if (wname) CoTaskMemFree(wname);
    IMMDevice_Release(pdev);
  }

  out->devices = devs;
  out->count   = actual;

  IMMDeviceCollection_Release(pcoll);
  IMMDeviceEnumerator_Release(penum);
  return 0;
}

void kirk_audio_enum_free(kirk_audio_device_list *list) {
  if (!list) return;
  for (uint32_t i = 0; i < list->count; i++) {
    free(list->devices[i].id);
    free(list->devices[i].name);
  }
  free(list->devices);
  list->devices = NULL;
  list->count   = 0;
}

wchar_t *kirk_audio_get_default_capture_id(void) {
  IMMDeviceEnumerator *penum = NULL;
  HRESULT hr = CoCreateInstance(
    &KIRK_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
    &KIRK_IID_IMMDeviceEnumerator, (void **)&penum);
  if (FAILED(hr) || !penum) return NULL;

  IMMDevice *pdev = NULL;
  hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(penum, eCapture, eConsole, &pdev);
  if (FAILED(hr) || !pdev) { IMMDeviceEnumerator_Release(penum); return NULL; }

  LPWSTR wid = NULL;
  hr = IMMDevice_GetId(pdev, &wid);
  IMMDevice_Release(pdev);
  IMMDeviceEnumerator_Release(penum);

  if (FAILED(hr) || !wid) return NULL;
  wchar_t *dup = kirk_wstr_dup(wid);
  CoTaskMemFree(wid);
  return dup;
}

char *kirk_wstr_to_utf8(const wchar_t *wstr) {
  if (!wstr) return NULL;
  int len = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, NULL, 0, NULL, NULL);
  if (len <= 0) return NULL;
  char *out = (char *)malloc(len);
  if (!out) return NULL;
  WideCharToMultiByte(CP_UTF8, 0, wstr, -1, out, len, NULL, NULL);
  return out;
}
