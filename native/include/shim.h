#ifndef NATIVE_INCLUDE_SHIM_H_
#define NATIVE_INCLUDE_SHIM_H_

#include <stddef.h>
#include <stdint.h>
// NOTE (Google style exception): no <windows.h> here on purpose. It needs
// COBJMACROS/INITGUID defined first, and this header needs HWND from it -
// so every TU includes <windows.h> (via shim_internal.h or directly) before
// this header. wchar_t/uint32_t come from the includes above.

#ifdef __cplusplus
extern "C" {
#endif

/* link.exe only exports dllexport symbols; always export in this DLL. */
#ifdef KIRK_SHIM_DLL_EXPORTS
#undef KIRK_SHIM_DLL_EXPORTS /* not used; always export in this DLL */
#endif
#define KIRK_SHIM_API __declspec(dllexport)

typedef struct {
  wchar_t *id;
  wchar_t *name;
} kirk_audio_device;

typedef struct {
  kirk_audio_device *devices;
  uint32_t           count;
} kirk_audio_device_list;

/// Enumerates WASAPI capture devices. Returns 0 on success.
/// Caller must free the list with kirk_audio_enum_free.
KIRK_SHIM_API int kirk_audio_enum_capture(kirk_audio_device_list *out);

/// Enumerates WASAPI render (output) devices: speakers / headphones / HDMI.
/// Same ownership as capture; used for the system-audio loopback picker.
KIRK_SHIM_API int kirk_audio_enum_render(kirk_audio_device_list *out);

/// Frees a device list from kirk_audio_enum_capture.
KIRK_SHIM_API void kirk_audio_enum_free(kirk_audio_device_list *list);

/// Returns the default capture device id (UTF-16). Caller must free().
KIRK_SHIM_API wchar_t *kirk_audio_get_default_capture_id(void);

typedef struct kirk_voice_s *kirk_voice_handle;

/// Creates a recognizer. device_hint is matched against SAPI input descriptions,
/// falling back to the SAPI default input when NULL/empty/unmatched. The input
/// is always bound via SetInput; returns NULL when no input could be bound.
KIRK_SHIM_API kirk_voice_handle kirk_voice_create(const wchar_t *device_hint);

/// Last failure HRESULT from create/load/start (0 when healthy).
KIRK_SHIM_API long kirk_voice_last_hresult(void);

/// Friendly name of the bound SAPI input. Valid until handle destroy; do not free.
KIRK_SHIM_API const wchar_t *kirk_voice_input_name(kirk_voice_handle h);

/// Destroys a session and releases all COM resources.
KIRK_SHIM_API void kirk_voice_destroy(kirk_voice_handle h);

/// Loads a command grammar from an SRGS XML file. Returns 0 on success.
KIRK_SHIM_API int kirk_voice_load_grammar(kirk_voice_handle h, const wchar_t *srgs_path);

/// Starts / stops listening.
KIRK_SHIM_API int kirk_voice_start(kirk_voice_handle h);
KIRK_SHIM_API int kirk_voice_start_again(kirk_voice_handle h);
KIRK_SHIM_API void kirk_voice_stop(kirk_voice_handle h);

/// Polls the event queue. Fills *phrase_utf8 (caller must free) and
/// *confidence in [0..1]. Returns 1 if a recognition was handled, 0 otherwise.
/// Call from the same thread that created the session.
KIRK_SHIM_API int kirk_voice_poll(kirk_voice_handle h, char **phrase_utf8, float *confidence);

/// Cumulative event counters (sound/hypothesis/recognition/rejection) for
/// distinguishing a dead poll timer from an empty queue from unmatched audio.
KIRK_SHIM_API void kirk_voice_counters(unsigned long long *sound, unsigned long long *hyp,
                                       unsigned long long *reco, unsigned long long *reject);

/// Liveness probe: stream position advances with incoming audio. Returns 0 on success.
KIRK_SHIM_API int kirk_voice_status(kirk_voice_handle h, unsigned long long *stream_pos, unsigned *recog_state);

/// Enumerates installed SAPI recognizers (SPCAT_RECOGNIZERS) and SAPI audio
/// inputs (SPCAT_AUDIOIN). Same layout as WASAPI capture lists: free with
/// kirk_audio_enum_free. Returns 0 on success (count 0 = none installed),
/// -1 on COM/category failure.
KIRK_SHIM_API int kirk_voice_enum_recognizers(kirk_audio_device_list *out);
KIRK_SHIM_API int kirk_voice_enum_audio_inputs(kirk_audio_device_list *out);

#define KIRK_STR_LEN 260
#define KIRK_PATH_LEN 520

/// ABI with the Crystal dialog. Fixed-size UTF-16 buffers so the dialog can
/// live on a worker thread without shared heap strings.
typedef struct {
  uint32_t fps;
  uint32_t bitrate_kbps;
  uint32_t audio_bitrate_kbps;
  uint32_t replay_seconds;
  uint32_t segment_seconds;
  uint32_t storage_limit_gb;
  int32_t  capture_audio;
  int32_t  auto_delete_oldest;
  int32_t  run_at_startup;
  int32_t  start_minimized;
  int32_t  show_save_notifications;
  int32_t  voice_enabled;
  wchar_t  encoder[KIRK_STR_LEN];           /* "" = auto | h264_nvenc | h264_amf | h264_qsv | libx264 */
  wchar_t  mic_device[KIRK_STR_LEN];        /* dshow friendly name; "" = system default */
  wchar_t  clips_dir[KIRK_PATH_LEN];        /* "" = default LOCALAPPDATA clips folder */
  wchar_t  clip_name_pattern[KIRK_STR_LEN]; /* e.g. "clip-{timestamp}.mp4" */
  int32_t  hotkey_clip_mod;               /* MOD_* flags (0 = none) */
  int32_t  hotkey_clip_vk;                /* VK code; 0 = unbound */
  int32_t  hotkey_record_mod;
  int32_t  hotkey_record_vk;
  int32_t  hotkey_shot_mod;
  int32_t  hotkey_shot_vk;
  int32_t  verbose_logging;               /* extra local debug logging */
  int32_t  auto_start_recording;          /* start replay capture at launch */
  wchar_t  encoder_preset[64];            /* p1..p7 / speed|balanced|quality / x264 names; "" = p4 */
  uint32_t max_width;                     /* 0 = native; otherwise downscale cap */
  uint32_t max_height;                    /* 0 = native; otherwise downscale cap */
  /* Mini mixer (appended; keep existing order stable for FFI). */
  wchar_t  extra_audio_device[KIRK_STR_LEN]; /* 2nd dshow capture; "" = none (full list via config file) */
  int32_t  capture_system_audio;          /* WASAPI loopback: game / Discord / system output */
  wchar_t  system_audio_device[KIRK_STR_LEN]; /* render endpoint; "" = default output */
  int32_t  mic_gain_pct;                  /* 0..200, 100 = unity */
  int32_t  system_gain_pct;               /* 0..200, 100 = unity */
  int32_t  play_save_sound;               /* chime on clip save (Clip.wav) */
  /* Voice tuning (appended; keep existing order stable for FFI). */
  int32_t  voice_confidence_pct;          /* 1..100, SAPI floor as percent */
  int32_t  voice_cooldown_ms;             /* ignore repeat commands, 250..15000 */
} kirk_settings;

/// Opens the settings dialog. Blocking modal loop; returns 1 on success.
/// The result arrives via settings_msg (wParam 1 on Save) before return and
/// is readable with kirk_ui_last_saved. Snapshots are deep-copied.
KIRK_SHIM_API int kirk_ui_show(HWND owner, uint32_t settings_msg, const kirk_settings *initial);

/// Enables per-monitor-V2 DPI awareness. Call before any window is created.
KIRK_SHIM_API void kirk_ui_init_dpi(void);

/// Returns non-zero while a settings dialog is open.
KIRK_SHIM_API int kirk_ui_active(void);

/// Settings most recently saved by the dialog. Valid until the next
/// kirk_ui_show; NULL when nothing has been saved yet.
KIRK_SHIM_API const kirk_settings *kirk_ui_last_saved(void);

/// Enables/disables the HKCU Run autostart value.
KIRK_SHIM_API int kirk_set_run_at_startup(const wchar_t *cmdline, int enabled);

/// Converts UTF-16 to UTF-8. Caller must free().
KIRK_SHIM_API char *kirk_wstr_to_utf8(const wchar_t *wstr);

#ifdef __cplusplus
}
#endif

#endif  // NATIVE_INCLUDE_SHIM_H_
