// Must precede <windows.h> to get C bindings from the Windows SDK.
#define COBJMACROS
#define INITGUID

// NOTE (Google style exception): Windows SDK dependency order, not
// alphabetical - <windows.h> first, then the rest; shim.h last because it
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
  // Recognizer selected at create time. reco_tag is always a usable BCP-47
  // grammar language (falls back to en-US when the LANGID is unknown);
  // reco_langid is 0 when unknown; reco_id is the SAPI token id ("" unknown).
  unsigned         reco_langid;
  wchar_t          reco_tag[16];
  wchar_t         *reco_id;
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

// Parses the SAPI "Language" attribute ("409", "409;809", ...) to a LANGID.
// Takes the first value; returns 1 on success.
static int kirk_parse_lang_attr(const wchar_t *s, unsigned *out) {
  if (!s || !*s || !out) return 0;
  wchar_t *end = NULL;
  unsigned long v = wcstoul(s, &end, 16);
  if (end == s || v == 0 || v > 0xFFFF) return 0;
  *out = (unsigned)v;
  return 1;
}

// Reads a recognizer token's language: Attributes/Language -> LANGID.
static int kirk_reco_token_langid(ISpObjectToken *tok, unsigned *out) {
  if (!tok || !out) return 0;
  ISpDataKey *attrs = NULL;
  if (FAILED(tok->OpenKey(L"Attributes", &attrs)) || !attrs) return 0;
  LPWSTR val = NULL;
  HRESULT hr = attrs->GetStringValue(L"Language", &val);
  attrs->Release();
  if (FAILED(hr) || !val) return 0;
  int ok = kirk_parse_lang_attr(val, out);
  CoTaskMemFree(val);
  return ok;
}

static void kirk_set_reco_info(kirk_voice_handle h, unsigned langid, const wchar_t *token_id) {
  if (!h) return;
  h->reco_langid = langid;
  // LANGID -> BCP-47 via the OS so every language maps correctly.
  wchar_t tag[16] = {0};
  int got = 0;
  if (langid != 0) {
    int n = GetLocaleInfoW(MAKELCID(langid, SORT_DEFAULT), LOCALE_SNAME, tag, 16);
    if (n > 0 && tag[0]) got = 1;
  }
  const wchar_t *fallback = L"en-US";
  wcsncpy(h->reco_tag, got ? tag : fallback, 15);
  h->reco_tag[15] = 0;
  free(h->reco_id);
  h->reco_id = NULL;
  if (token_id && *token_id) {
    size_t n = wcslen(token_id) + 1;
    h->reco_id = (wchar_t *)malloc(n * sizeof(wchar_t));
    if (h->reco_id) wcscpy(h->reco_id, token_id);
  }
}

// BCP-47 ("en-US", "en_US", "en") -> LANGID via the OS. Returns 1 on success.
// "auto"/NULL/empty is not a language (returns 0).
static int kirk_bcp47_to_langid(const wchar_t *hint, unsigned *out) {
  if (!hint || !*hint || !out) return 0;
  wchar_t norm[32] = {0};
  size_t j = 0;
  for (size_t i = 0; hint[i] && j + 1 < 32; i++) {
    wchar_t c = hint[i];
    if (c == L'_') c = L'-';
    norm[j++] = towlower(c);
  }
  norm[j] = 0;
  if (wcscmp(norm, L"auto") == 0) return 0;
  wchar_t canonical[32] = {0};
  wcsncpy(canonical, hint, 31);
  for (size_t i = 0; canonical[i]; i++)
    if (canonical[i] == L'_') canonical[i] = L'-';
  LCID lcid = LocaleNameToLCID(canonical, 0);
  if (lcid == 0) return 0;
  unsigned langid = (unsigned)(lcid & 0xFFFF);
  if (langid == 0) return 0;
  *out = langid;
  return 1;
}

kirk_voice_handle kirk_voice_create(const wchar_t *device_id, const wchar_t *lang_hint) {
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
  kirk_set_reco_info(h, 0, NULL);

  // Select the speech recognizer BEFORE SetInput/CreateRecoContext. Without
  // SetRecognizer SAPI uses whatever default Windows happens to have (e.g.
  // en-GB 809) while the app generates an en-US grammar -> LoadCmdFromFile
  // fails with SPERR_LANGID_MISMATCH (0x80045052).
  {
    unsigned want = 0;
    int have_want = kirk_bcp47_to_langid(lang_hint, &want);
    ISpObjectTokenCategory *rcat = NULL;
    hr = CoCreateInstance(CLSID_SpObjectTokenCategory, NULL, CLSCTX_INPROC_SERVER,
                          IID_ISpObjectTokenCategory, (void **)&rcat);
    if (SUCCEEDED(hr) && rcat) {
      if (SUCCEEDED(rcat->SetId(SPCAT_RECOGNIZERS, FALSE))) {
        IEnumSpObjectTokens *ret = NULL;
        if (SUCCEEDED(rcat->EnumTokens(NULL, NULL, &ret)) && ret) {
          ULONG rn = 0;
          ret->GetCount(&rn);
          ISpObjectToken *best = NULL, *primary = NULL, *first = NULL, *def = NULL;
          unsigned best_lang = 0, primary_lang = 0, first_lang = 0, def_lang = 0;
          wchar_t best_id[512] = {0}, primary_id[512] = {0}, first_id[512] = {0}, def_id_buf[512] = {0};
          LPWSTR defId = NULL;
          if (FAILED(rcat->GetDefaultTokenId(&defId))) defId = NULL;
          for (ULONG i = 0; i < rn; i++) {
            ISpObjectToken *t = NULL;
            if (FAILED(ret->Next(1, &t, NULL)) || !t) continue;
            unsigned lang = 0;
            kirk_reco_token_langid(t, &lang);
            LPWSTR tid = NULL;
            t->GetId(&tid);
            if (!first) {
              first = t; first_lang = lang;
              if (tid) wcsncpy(first_id, tid, 511);
              CoTaskMemFree(tid);
              continue;
            }
            if (defId && tid && wcscmp(tid, defId) == 0 && !def) {
              def = t; def_lang = lang;
              wcsncpy(def_id_buf, tid, 511);
              CoTaskMemFree(tid);
              continue;
            }
            if (have_want && lang == want && !best) {
              best = t; best_lang = lang;
              if (tid) wcsncpy(best_id, tid, 511);
              CoTaskMemFree(tid);
              continue;
            }
            if (have_want && !primary && lang != 0 &&
                PRIMARYLANGID((WORD)lang) == PRIMARYLANGID((WORD)want)) {
              primary = t; primary_lang = lang;
              if (tid) wcsncpy(primary_id, tid, 511);
              CoTaskMemFree(tid);
              continue;
            }
            CoTaskMemFree(tid);
            t->Release();
          }
          ret->Release();
          ISpObjectToken *sel = NULL;
          unsigned sel_lang = 0;
          wchar_t sel_id[512] = {0};
          if (have_want && best) {
            sel = best; sel_lang = best_lang; wcsncpy(sel_id, best_id, 511);
          } else if (have_want && primary) {
            sel = primary; sel_lang = primary_lang; wcsncpy(sel_id, primary_id, 511);
          } else if (!have_want && def) {
            sel = def; sel_lang = def_lang; wcsncpy(sel_id, def_id_buf, 511);
          } else if (def) {
            // Explicit request with no match: stay on the default so an
            // en-GB default + en-US request doesn't silently switch dialects;
            // the grammar is still generated from the actual recognizer.
            sel = def; sel_lang = def_lang; wcsncpy(sel_id, def_id_buf, 511);
          } else if (have_want && first) {
            sel = first; sel_lang = first_lang; wcsncpy(sel_id, first_id, 511);
          } else if (first) {
            sel = first; sel_lang = first_lang; wcsncpy(sel_id, first_id, 511);
          }
          // Release non-selected candidates.
          ISpObjectToken *cands[4] = {best, primary, first, def};
          for (int k = 0; k < 4; k++)
            if (cands[k] && cands[k] != sel) cands[k]->Release();
          if (sel) {
            if (SUCCEEDED(recog->SetRecognizer(sel)))
              kirk_set_reco_info(h, sel_lang, sel_id[0] ? sel_id : NULL);
            else
              kirk_set_reco_info(h, sel_lang, sel_id[0] ? sel_id : NULL);
            sel->Release();
          }
          if (defId) CoTaskMemFree(defId);
        }
      }
      rcat->Release();
    }
  }

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
    // let SAPI pick its default audio input - the same thing .NET's
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
      free(h->input_desc);
      free(h->reco_id);
      free(h);
      return NULL;
    }
  } else {
    hr = recog->SetInput(chosen, TRUE);
    g_voice_last_hr = hr;
    if (FAILED(hr)) {
      chosen->Release();
      recog->Release();
      free(h->input_desc);
      free(h->reco_id);
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
    free(h->reco_id);
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
  free(h->reco_id);
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

unsigned kirk_voice_recognizer_langid(kirk_voice_handle h) {
  if (!h) return 0;
  return h->reco_langid;
}

const wchar_t *kirk_voice_recognizer_tag(kirk_voice_handle h) {
  if (!h || !h->reco_tag[0]) return L"en-US";
  return h->reco_tag;
}

const wchar_t *kirk_voice_recognizer_id(kirk_voice_handle h) {
  if (!h || !h->reco_id) return L"";
  return h->reco_id;
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
