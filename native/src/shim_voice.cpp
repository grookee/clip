// Must precede <windows.h> to get C bindings from the Windows SDK.
#define COBJMACROS
#define INITGUID

// NOTE (Google style exception): Windows SDK dependency order, not
// alphabetical — <windows.h> first, then the rest; shim.h last because it
// needs HWND from <windows.h>.
#include <windows.h>
#include <objbase.h>
#include <sapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#pragma comment(lib, "sapi.lib")

#include "shim_internal.h"
#include "../include/shim.h"

struct kirk_voice_s {
  ISpRecognizer   *recog;
  ISpRecoContext  *ctx;
  ISpRecoGrammar  *grammar;
  wchar_t         *input_desc;
};

static HRESULT g_voice_last_hr = S_OK;

// Distinguishes a dead poll timer from an empty queue from unmatched audio.
static unsigned long long g_cnt_sound = 0;
static unsigned long long g_cnt_hyp = 0;
static unsigned long long g_cnt_reco = 0;
static unsigned long long g_cnt_reject = 0;

static void kirk_voice_set_desc(kirk_voice_handle h, const wchar_t *desc) {
  if (!h) return;
  free(h->input_desc);
  h->input_desc = NULL;
  if (desc && *desc) {
    size_t n = wcslen(desc) + 1;
    h->input_desc = (wchar_t *)malloc(n * sizeof(wchar_t));
    if (h->input_desc) wcscpy(h->input_desc, desc);
  }
}

static int wcsicontains(const wchar_t *hay, const wchar_t *needle) {
  if (!hay || !needle || !*needle) return 0;
  size_t hn = wcslen(hay), nn = wcslen(needle);
  if (nn > hn) return 0;
  for (size_t i = 0; i + nn <= hn; i++) {
    size_t j = 0;
    while (j < nn && towlower(hay[i + j]) == towlower(needle[j])) j++;
    if (j == nn) return 1;
  }
  return 0;
}

static void kirk_voice_release_com(kirk_voice_handle h) {
  if (!h) return;
  if (h->grammar) { h->grammar->Release(); h->grammar = NULL; }
  if (h->ctx)     { h->ctx->Release();     h->ctx     = NULL; }
  if (h->recog)   { h->recog->Release();     h->recog   = NULL; }
}

kirk_voice_handle kirk_voice_create(const wchar_t *device_id) {
  // device_hint is matched against SAPI input descriptions, else the SAPI
  // default token is used. SetInput must always be called: without it the
  // in-proc recognizer hears nothing and logs nothing.
  g_voice_last_hr = S_OK;

  ISpRecognizer *recog = NULL;
  HRESULT hr = CoCreateInstance(CLSID_SpInprocRecognizer, NULL, CLSCTX_INPROC_SERVER,
                                IID_ISpRecognizer, (void **)&recog);
  if (FAILED(hr) || !recog) { g_voice_last_hr = hr; return NULL; }

  kirk_voice_handle h = (kirk_voice_handle)calloc(1, sizeof(struct kirk_voice_s));
  if (!h) { recog->Release(); return NULL; }
  h->recog = recog;

  ISpObjectToken *chosen = NULL;
  wchar_t chosen_desc[256] = {0};
  {
    ISpObjectTokenCategory *cat = NULL;
    hr = CoCreateInstance(CLSID_SpObjectTokenCategory, NULL, CLSCTX_INPROC_SERVER,
                          IID_ISpObjectTokenCategory, (void **)&cat);
    if (SUCCEEDED(hr) && cat) {
      if (SUCCEEDED(cat->SetId(SPCAT_AUDIOIN, FALSE))) {
        IEnumSpObjectTokens *et = NULL;
        if (SUCCEEDED(cat->EnumTokens(NULL, NULL, &et)) && et) {
          ULONG n = 0;
          et->GetCount(&n);
          for (ULONG i = 0; i < n; i++) {
            ISpObjectToken *tok = NULL;
            if (FAILED(et->Next(1, &tok, NULL)) || !tok) continue;
            LPWSTR desc = NULL;
            tok->GetStringValue(NULL, &desc);
            int match = (device_id && *device_id && desc) ? wcsicontains(desc, device_id) : 0;
            if (match && !chosen) {
              chosen = tok; // owns the reference
              wcsncpy(chosen_desc, desc ? desc : L"(?)", 255);
            } else {
              tok->Release();
            }
            CoTaskMemFree(desc);
            if (chosen) break;
          }
          et->Release();
        }
        if (!chosen) {
          LPWSTR defId = NULL;
          if (SUCCEEDED(cat->GetDefaultTokenId(&defId)) && defId) {
            ISpObjectToken *tok = NULL;
            IEnumSpObjectTokens *et2 = NULL;
            if (SUCCEEDED(cat->EnumTokens(NULL, NULL, &et2)) && et2) {
              ULONG n2 = 0;
              et2->GetCount(&n2);
              for (ULONG i = 0; i < n2 && !chosen; i++) {
                ISpObjectToken *t = NULL;
                if (FAILED(et2->Next(1, &t, NULL)) || !t) continue;
                LPWSTR id = NULL, desc = NULL;
                t->GetId(&id);
                if (id && wcscmp(id, defId) == 0) {
                  chosen = t;
                  t->GetStringValue(NULL, &desc);
                  wcsncpy(chosen_desc, desc ? desc : L"(?)", 255);
                  CoTaskMemFree(desc);
                } else {
                  t->Release();
                }
                CoTaskMemFree(id);
              }
              et2->Release();
            }
            CoTaskMemFree(defId);
          }
          // Fallback: GetDefaultTokenId can fail/missing on machines that
          // never set a default (fresh Win11, speech pack just installed)
          // even though usable tokens exist. Take the first token rather
          // than failing outright.
          if (!chosen) {
            IEnumSpObjectTokens *et3 = NULL;
            if (SUCCEEDED(cat->EnumTokens(NULL, NULL, &et3)) && et3) {
              ISpObjectToken *t = NULL;
              if (SUCCEEDED(et3->Next(1, &t, NULL)) && t) {
                LPWSTR desc = NULL;
                t->GetStringValue(NULL, &desc);
                wcsncpy(chosen_desc, desc ? desc : L"(?)", 255);
                CoTaskMemFree(desc);
                chosen = t;
              }
              et3->Release();
            }
          }
        }
      }
      cat->Release();
    }
  }

  if (!chosen) {
    // No explicit token (no hint match and no usable default). Last resort:
    // let SAPI pick its default audio input — the same thing .NET's
    // SetInputToDefaultAudioDevice() and the SAPI tutorials do via
    // SetInput(NULL, TRUE). Covers machines where token enumeration yields
    // nothing usable but a default capture device exists (WASAPI shows a
    // mic, Discord hears it). Shared-recognizer apps work on such machines
    // for the same reason: they never require an explicit token either.
    hr = recog->SetInput(NULL, TRUE);
    g_voice_last_hr = hr;
    if (SUCCEEDED(hr)) {
      kirk_voice_set_desc(h, L"(default audio input)");
    } else {
      // No SAPI audio input at all: speech runtime broken or no capture
      // device visible to SAPI. Distinct from SetInput failures so the log
      // points at "no input" instead of a stale S_OK.
      g_voice_last_hr = (HRESULT)0x8004503A; // SPERR_NOT_FOUND
      recog->Release();
      free(h);
      return NULL;
    }
  } else {
    hr = recog->SetInput(chosen, TRUE);
    g_voice_last_hr = hr;
    if (FAILED(hr)) {
      chosen->Release();
      recog->Release();
      free(h);
      return NULL;
    }
    kirk_voice_set_desc(h, chosen_desc[0] ? chosen_desc : L"(default)");
    chosen->Release();
  }

  // SAPI swallows weak-but-correct decodes as empty FALSE_RECOGNITIONs, so the
  // app can never see or tune them. 20/100 re-emits them as low-confidence
  // RECOGNITIONs; the app's own floor + grammar match + cooldown still gate
  // what fires. Best-effort: failure here must not break creation.
  {
    ISpProperties *props = NULL;
    if (SUCCEEDED(recog->QueryInterface(IID_ISpProperties, (void **)&props)) && props) {
      props->SetPropertyNum(L"CFGConfidenceRejectionThreshold", 20);
      props->Release();
    }
  }

  ISpRecoContext *ctx = NULL;
  hr = recog->CreateRecoContext(&ctx);
  if (FAILED(hr) || !ctx) {
    g_voice_last_hr = hr;
    kirk_voice_release_com(h);
    free(h->input_desc);
    free(h);
    return NULL;
  }

  // FALSE_RECOGNITION surfaces below-threshold utterances, HYPOTHESIS partial
  // matches, SOUND_START/END proves audio frames reach the engine at all.
  ULONGLONG want = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_FALSE_RECOGNITION) |
                   SPFEI(SPEI_HYPOTHESIS) | SPFEI(SPEI_SOUND_START) |
                   SPFEI(SPEI_SOUND_END) | SPFEI(SPEI_PHRASE_START);
  ctx->SetInterest(want, want);

  h->ctx = ctx;
  return h;
}

void kirk_voice_destroy(kirk_voice_handle h) {
  if (!h) return;
  kirk_voice_stop(h);
  kirk_voice_release_com(h);
  free(h->input_desc);
  free(h);
}

HRESULT kirk_voice_last_hresult(void) {
  return g_voice_last_hr;
}

// Valid until the handle is destroyed; do not free.
const wchar_t *kirk_voice_input_name(kirk_voice_handle h) {
  if (!h || !h->input_desc) return L"(none)";
  return h->input_desc;
}

int kirk_voice_load_grammar(kirk_voice_handle h, const wchar_t *srgs_path) {
  // Null handle used to return -1 without touching g_voice_last_hr, leaving
  // a stale S_OK behind: callers logged "grammar load FAILED ... hr=0x0".
  // Report E_POINTER so a null handle is never confused with a grammar error.
  if (!h || !h->ctx) { g_voice_last_hr = (HRESULT)0x80004003; return -1; }
  if (h->grammar) { h->grammar->Release(); h->grammar = NULL; }
  ISpRecoGrammar *grammar = NULL;
  HRESULT hr = h->ctx->CreateGrammar(0, &grammar);
  if (FAILED(hr) || !grammar) { g_voice_last_hr = hr; return -1; }
  hr = grammar->LoadCmdFromFile(srgs_path, SPLO_DYNAMIC);
  if (FAILED(hr)) { g_voice_last_hr = hr; grammar->Release(); return -1; }
  h->grammar = grammar;
  g_voice_last_hr = S_OK;
  return 0;
}

int kirk_voice_start(kirk_voice_handle h) {
  if (!h || !h->grammar) { g_voice_last_hr = (HRESULT)0x80004003; return -1; }
  HRESULT hr = h->grammar->SetRuleIdState(0, SPRS_ACTIVE);
  g_voice_last_hr = hr;
  return SUCCEEDED(hr) ? 0 : -1;
}

int kirk_voice_start_again(kirk_voice_handle h) {
  return kirk_voice_start(h);
}

void kirk_voice_stop(kirk_voice_handle h) {
  if (!h || !h->grammar) return;
  h->grammar->SetRuleIdState(0, SPRS_INACTIVE);
}

int kirk_voice_poll(kirk_voice_handle h, char **phrase_utf8, float *confidence) {
  if (!h || !h->ctx || !phrase_utf8) return 0;
  *phrase_utf8 = NULL;
  if (confidence) *confidence = 0.0f;

  SPEVENT evt;
  ULONG fetched = 0;
  HRESULT hr = h->ctx->GetEvents(1, &evt, &fetched);
  if (FAILED(hr) || fetched == 0) return 0;

  // Audio-flow markers carry no phrase. Count everything first, and release
  // any owned result so unreleased hypotheses can't pile up.
  if (evt.eEventId == SPEI_SOUND_START || evt.eEventId == SPEI_SOUND_END) { g_cnt_sound++; return 0; }
  if (evt.eEventId == SPEI_HYPOTHESIS || evt.eEventId == SPEI_PHRASE_START) {
    g_cnt_hyp++;
    if (evt.elParamType == SPET_LPARAM_IS_OBJECT && evt.lParam)
      ((ISpRecoResult *)evt.lParam)->Release();
    return 0;
  }
  if (evt.eEventId == SPEI_FALSE_RECOGNITION) g_cnt_reject++;
  else if (evt.eEventId == SPEI_RECOGNITION) g_cnt_reco++;
  else return 0;

  // lParam is an owned ISpRecoResult* and must be Released.
  ISpRecoResult *result = (ISpRecoResult *)evt.lParam;
  if (!result) return 0;

  // Element-range GetText returns NULL text on some false rejections even
  // though the phrase has words. Fall back to joining per-element text so
  // every rejection is visible with its confidence.
  LPWSTR text = NULL;
  int text_is_malloc = 0;
  if (FAILED(result->GetText(SP_GETWHOLEPHRASE, SP_GETWHOLEPHRASE, TRUE, &text, NULL)) || !text) {
    if (text) { CoTaskMemFree(text); text = NULL; }
    SPPHRASE *tmp = NULL;
    if (SUCCEEDED(result->GetPhrase(&tmp)) && tmp) {
      size_t need = 1;
      for (ULONG i = 0; i < tmp->Rule.ulCountOfElements; i++)
        if (tmp->pElements[i].pszDisplayText) need += wcslen(tmp->pElements[i].pszDisplayText) + 1;
      LPWSTR joined = (LPWSTR)malloc(need * sizeof(wchar_t));
      if (joined) {
        joined[0] = 0;
        for (ULONG i = 0; i < tmp->Rule.ulCountOfElements; i++) {
          if (tmp->pElements[i].pszDisplayText) {
            if (joined[0]) wcscat(joined, L" ");
            wcscat(joined, tmp->pElements[i].pszDisplayText);
          }
        }
        if (joined[0]) { text = joined; text_is_malloc = 1; }
        else free(joined);
      }
      CoTaskMemFree(tmp);
    }
  }
  if (text) {
    char *utf8 = kirk_wstr_to_utf8(text);
    if (utf8) { *phrase_utf8 = utf8; }
    if (text_is_malloc) free(text);
    else CoTaskMemFree(text);
  }

  if (confidence) {
    SPPHRASE *ph = NULL;
    if (SUCCEEDED(result->GetPhrase(&ph)) && ph) {
      if (ph->Rule.ulCountOfElements > 0) {
        float sum = 0.0f;
        for (ULONG i = 0; i < ph->Rule.ulCountOfElements; i++)
          sum += ph->pElements[i].SREngineConfidence;
        *confidence = sum / (float)ph->Rule.ulCountOfElements;
      }
      CoTaskMemFree(ph);
    }
  }

  result->Release();
  return *phrase_utf8 ? 1 : 0;
}

void kirk_voice_counters(unsigned long long *sound, unsigned long long *hyp,
                         unsigned long long *reco, unsigned long long *reject) {
  if (sound) *sound = g_cnt_sound;
  if (hyp) *hyp = g_cnt_hyp;
  if (reco) *reco = g_cnt_reco;
  if (reject) *reject = g_cnt_reject;
}

int kirk_voice_status(kirk_voice_handle h, unsigned long long *stream_pos, unsigned *recog_state) {
  if (!h || !h->recog) return -1;
  SPRECOGNIZERSTATUS st;
  memset(&st, 0, sizeof(st));
  if (FAILED(h->recog->GetStatus(&st))) return -1;
  if (stream_pos) *stream_pos = st.ullRecognitionStreamPos;
  if (recog_state) *recog_state = (unsigned)st.AudioStatus.State;
  return 0;
}

// Shared enumerator for SAPI token categories (recognizers, audio inputs).
// Output layout matches kirk_audio_device_list so callers free it with
// kirk_audio_enum_free. Count 0 with return 0 means "none installed".
static int kirk_voice_enum_category(const wchar_t *cat_id, kirk_audio_device_list *out) {
  if (!out || !cat_id) return -1;
  out->devices = NULL;
  out->count   = 0;

  ISpObjectTokenCategory *cat = NULL;
  HRESULT hr = CoCreateInstance(CLSID_SpObjectTokenCategory, NULL, CLSCTX_INPROC_SERVER,
                                IID_ISpObjectTokenCategory, (void **)&cat);
  if (FAILED(hr) || !cat) return -1;
  hr = cat->SetId(cat_id, FALSE);
  if (FAILED(hr)) { cat->Release(); return -1; }

  IEnumSpObjectTokens *et = NULL;
  hr = cat->EnumTokens(NULL, NULL, &et);
  if (FAILED(hr) || !et) { cat->Release(); return -1; }

  ULONG n = 0;
  et->GetCount(&n);
  if (n == 0) { et->Release(); cat->Release(); return 0; }

  kirk_audio_device *devs = (kirk_audio_device *)calloc(n, sizeof(kirk_audio_device));
  if (!devs) { et->Release(); cat->Release(); return -1; }
  ULONG actual = 0;

  for (ULONG i = 0; i < n; i++) {
    ISpObjectToken *tok = NULL;
    if (FAILED(et->Next(1, &tok, NULL)) || !tok) continue;
    LPWSTR id = NULL, desc = NULL;
    tok->GetId(&id);
    tok->GetStringValue(NULL, &desc);
    devs[actual].id   = kirk_wstr_dup(id ? id : L"");
    devs[actual].name = kirk_wstr_dup(desc ? desc : L"(unknown)");
    actual++;
    CoTaskMemFree(id);
    CoTaskMemFree(desc);
    tok->Release();
  }

  et->Release();
  cat->Release();
  out->devices = devs;
  out->count   = actual;
  return 0;
}

int kirk_voice_enum_recognizers(kirk_audio_device_list *out) {
  return kirk_voice_enum_category(SPCAT_RECOGNIZERS, out);
}

int kirk_voice_enum_audio_inputs(kirk_audio_device_list *out) {
  return kirk_voice_enum_category(SPCAT_AUDIOIN, out);
}
