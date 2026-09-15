require "../platform/win32/shim"
require "./config"

# Bridges Kirk::Settings <-> the native dialog ABI. Text travels as fixed-size
# UTF-16 buffers so the dialog can run on its own thread with no shared heap strings.
module Kirk::UIBridge
  # Takes a raw pointer because StaticArray is a value type: a by-value
  # parameter would copy, leaving the caller's buffer unwritten.
  def self.copy_wchars(dst : UInt16*, max : Int32, s : String)
    utf = s.to_utf16
    n = Math.min(utf.size, max - 1)
    utf.to_unsafe.copy_to(dst, n)
    dst[n] = 0_u16
  end

  def self.read_wchars(arr : StaticArray(UInt16, N)) : String forall N
    Win32.wstr_to_string(arr.to_unsafe)
  end

  # Both structs travel by pointer: a by-value parameter would copy, making
  # every write below a silent no-op.
  def self.fill_cc(s : Settings, cc : KirkSettings*)
    c = cc.value
    c.fps = s.fps.to_u32
    c.bitrate_kbps = s.bitrate_kbps.to_u32
    c.audio_bitrate_kbps = s.audio_bitrate_kbps.to_u32
    c.replay_seconds = s.replay_seconds.to_u32
    c.segment_seconds = s.segment_seconds.to_u32
    c.storage_limit_gb = s.storage_limit_gb.to_u32
    c.capture_audio = s.capture_audio ? 1 : 0
    c.auto_delete_oldest = s.auto_delete_oldest ? 1 : 0
    c.run_at_startup = s.run_at_startup ? 1 : 0
    c.start_minimized = s.start_minimized ? 1 : 0
    c.show_save_notifications = s.show_save_notifications ? 1 : 0
    c.voice_enabled = s.voice_enabled ? 1 : 0
    c.auto_start_recording = s.auto_start_recording ? 1 : 0
    c.hotkey_clip_mod = s.hotkey_clip_mod
    c.hotkey_clip_vk = s.hotkey_clip_vk
    c.hotkey_record_mod = s.hotkey_record_mod
    c.hotkey_record_vk = s.hotkey_record_vk
    c.hotkey_shot_mod = s.hotkey_shot_mod
    c.hotkey_shot_vk = s.hotkey_shot_vk
    c.verbose_logging = s.verbose_logging ? 1 : 0

    copy_wchars(c.encoder.to_unsafe, 260, s.hw_encoder)
    copy_wchars(c.mic_device.to_unsafe, 260, s.mic_device)
    copy_wchars(c.clips_dir.to_unsafe, 520, s.clips_dir)
    copy_wchars(c.clip_name_pattern.to_unsafe, 260, s.clip_name_pattern)
    cc.value = c
  end

  def self.apply_from_cc(s : Settings*, cc : KirkSettings)
    t = s.value
    fps = cc.fps.to_i32
    t.fps = (fps >= 10 && fps <= 240) ? fps : 60
    vbr = cc.bitrate_kbps.to_i32
    t.bitrate_kbps = (vbr >= 250 && vbr <= 200_000) ? vbr : 8000
    abr = cc.audio_bitrate_kbps.to_i32
    t.audio_bitrate_kbps = (abr >= 32 && abr <= 512) ? abr : 192
    rep = cc.replay_seconds.to_i32
    t.replay_seconds = (rep >= 5 && rep <= 600) ? rep : 30
    seg = cc.segment_seconds.to_i32
    t.segment_seconds = (seg >= 1 && seg <= 15) ? seg : 2
    lim = cc.storage_limit_gb.to_i32
    t.storage_limit_gb = (lim >= 1 && lim <= 500) ? lim : 20
    t.capture_audio = cc.capture_audio != 0
    t.auto_delete_oldest = cc.auto_delete_oldest != 0
    t.run_at_startup = cc.run_at_startup != 0
    t.start_minimized = cc.start_minimized != 0
    t.show_save_notifications = cc.show_save_notifications != 0
    t.voice_enabled = cc.voice_enabled != 0
    t.auto_start_recording = cc.auto_start_recording != 0
    t.hw_encoder = read_wchars(cc.encoder)
    t.mic_device = read_wchars(cc.mic_device)
    t.clips_dir = read_wchars(cc.clips_dir)
    pat = read_wchars(cc.clip_name_pattern)
    t.clip_name_pattern = pat.strip.empty? ? "clip-{timestamp}.mp4" : pat
    t.hotkey_clip_mod = cc.hotkey_clip_mod
    t.hotkey_clip_vk = cc.hotkey_clip_vk
    t.hotkey_record_mod = cc.hotkey_record_mod
    t.hotkey_record_vk = cc.hotkey_record_vk
    t.hotkey_shot_mod = cc.hotkey_shot_mod
    t.hotkey_shot_vk = cc.hotkey_shot_vk
    t.verbose_logging = cc.verbose_logging != 0
    s.value = t
  end
end
