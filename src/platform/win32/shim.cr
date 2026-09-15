require "./win32"

# Bindings to the native shim DLL. The shim owns COM objects internally
# (WASAPI enumerator, SAPI recognizers) because Crystal cannot call COM
# vtable methods at runtime.

@[Link("shim")]
lib LibShim
  alias WChar = UInt16

  struct AudioDevice
    id : WChar*
    name : WChar*
  end

  struct AudioDeviceList
    devices : AudioDevice*
    count : UInt32
  end

  # WASAPI
  fun kirk_audio_enum_capture(list : AudioDeviceList*) : LibC::Int
  fun kirk_audio_enum_free(list : AudioDeviceList*)
  fun kirk_audio_get_default_capture_id : WChar*

  fun kirk_ui_init_dpi : Void
  fun kirk_ui_show(owner : Void*, settings_msg : UInt32, initial : Void*) : LibC::Int
  fun kirk_ui_active : LibC::Int
  fun kirk_ui_last_saved : Void*
  fun kirk_set_run_at_startup(cmdline : WChar*, enabled : LibC::Int) : LibC::Int

  fun kirk_voice_create(device_hint : WChar*) : Void*
  fun kirk_voice_last_hresult : LibC::Long
  fun kirk_voice_input_name(handle : Void*) : WChar*
  fun kirk_voice_destroy(handle : Void*)
  fun kirk_voice_load_grammar(handle : Void*, srgs_path : WChar*) : LibC::Int
  fun kirk_voice_start(handle : Void*) : LibC::Int
  fun kirk_voice_stop(handle : Void*)
  fun kirk_voice_poll(handle : Void*, phrase_utf8 : UInt8**, confidence : LibC::Float*) : LibC::Int
  fun kirk_voice_counters(sound : UInt64*, hyp : UInt64*, reco : UInt64*, reject : UInt64*) : Void
  fun kirk_voice_status(handle : Void*, stream_pos : UInt64*, recog_state : UInt32*) : LibC::Int

  fun kirk_wstr_to_utf8(wstr : WChar*) : UInt8*
end

struct MicDevice
  getter id : String
  getter name : String

  def initialize(@id, @name)
  end
end

# Enumerates active WASAPI capture endpoints as UTF-8 strings.
def win32_list_microphones : Array(MicDevice)
  list = LibShim::AudioDeviceList.new
  return [] of MicDevice if LibShim.kirk_audio_enum_capture(pointerof(list)) != 0

  mics = [] of MicDevice
  n = list.count
  i = 0
  while i < n
    dev = list.devices + i
    id = Win32.wstr_to_string(dev.value.id)
    name = Win32.wstr_to_string(dev.value.name)
    mics << MicDevice.new(id, name)
    i += 1
  end

  LibShim.kirk_audio_enum_free(pointerof(list))
  mics
end

# ABI struct mirroring kirk_settings in the shim DLL. Field order/types match
# the C declaration, which is all the FFI cares about.
struct KirkSettings
  property fps : UInt32 = 0_u32
  property bitrate_kbps : UInt32 = 0_u32
  property audio_bitrate_kbps : UInt32 = 0_u32
  property replay_seconds : UInt32 = 0_u32
  property segment_seconds : UInt32 = 0_u32
  property storage_limit_gb : UInt32 = 0_u32
  property capture_audio : LibC::Int = 0
  property auto_delete_oldest : LibC::Int = 0
  property run_at_startup : LibC::Int = 0
  property start_minimized : LibC::Int = 0
  property show_save_notifications : LibC::Int = 0
  property voice_enabled : LibC::Int = 0
  property encoder : StaticArray(UInt16, 260) = StaticArray(UInt16, 260).new(0_u16)
  property mic_device : StaticArray(UInt16, 260) = StaticArray(UInt16, 260).new(0_u16)
  property clips_dir : StaticArray(UInt16, 520) = StaticArray(UInt16, 520).new(0_u16)
  property clip_name_pattern : StaticArray(UInt16, 260) = StaticArray(UInt16, 260).new(0_u16)
  property hotkey_clip_mod : Int32 = 0
  property hotkey_clip_vk : Int32 = 0
  property hotkey_record_mod : Int32 = 0
  property hotkey_record_vk : Int32 = 0
  property hotkey_shot_mod : Int32 = 0
  property hotkey_shot_vk : Int32 = 0
  property verbose_logging : Int32 = 0
  property auto_start_recording : Int32 = 0
end

class VoiceSession
  getter handle : Void*?

  def initialize(@handle = nil)
  end

  protected def native_handle! : Void*
    @handle.not_nil!
  end

  def valid? : Bool
    !@handle.nil?
  end

  def load_grammar(path : String) : Bool
    h = native_handle!
    LibShim.kirk_voice_load_grammar(h, path.to_utf16.to_unsafe) == 0
  end

  def start : Bool
    h = native_handle!
    LibShim.kirk_voice_start(h) == 0
  end

  def stop
    h = native_handle!
    LibShim.kirk_voice_stop(h)
  end

  # Drains one queued event per call; callers loop until nil so a burst of
  # hypotheses can't strand the wake phrase past its cooldown window.
  def poll : {String, LibC::Float}?
    h = native_handle!
    ph = Pointer(UInt8).null
    conf = 0.0_f32
    return nil if LibShim.kirk_voice_poll(h, pointerof(ph), pointerof(conf)) == 0

    s = String.new(ph)
    LibC.free(ph)
    return {s, conf}
  end

  # Stream position advances while audio frames reach the engine.
  def status : {UInt64, UInt32}?
    h = native_handle!
    pos = 0_u64
    state = 0_u32
    return nil if LibShim.kirk_voice_status(h, pointerof(pos), pointerof(state)) != 0
    {pos, state}
  end

  def input_name : String
    h = native_handle!
    Win32.wstr_to_string(LibShim.kirk_voice_input_name(h))
  end
end

def win32_voice_counters : {UInt64, UInt64, UInt64, UInt64}
  s = 0_u64
  h = 0_u64
  r = 0_u64
  j = 0_u64
  LibShim.kirk_voice_counters(pointerof(s), pointerof(h), pointerof(r), pointerof(j))
  {s, h, r, j}
end

def win32_voice_last_hresult : Int32
  LibShim.kirk_voice_last_hresult.to_i32
end

# Voice always listens on the system default input; the "Recording mic"
# setting only affects ffmpeg clip audio.
def win32_default_capture_name : String
  # WASAPI enumeration needs COM on this thread; without this the lookup
  # always reports "no device".
  cok = Win32.ole_initialize(0x0)
  begin
    ptr = LibShim.kirk_audio_get_default_capture_id
    return "(no default capture device)" if ptr.null?
    id = Win32.wstr_to_string(ptr)
    LibC.free(ptr.as(Void*))
    win32_list_microphones.each do |m|
      return m.name if m.id == id
    end
    id.empty? ? "(unknown default device)" : id
  ensure
    Win32.ole_uninitialize if cok >= 0
  end
end

def win32_resolve_recording_mic_label(mic_device : String) : String
  return "(System default) -> #{win32_default_capture_name} [NO mic audio: empty device adds no dshow input]" if mic_device.strip.empty?
  mic_device
end

# A NULL return means no input could be bound (silent engine): the native side
# always binds an input via SetInput.
def win32_voice_create(device_hint : String? = nil) : VoiceSession
  Win32.ole_initialize(0x0)
  if hint = device_hint
    if hint.strip.empty?
      h = LibShim.kirk_voice_create(nil)
    else
      h = LibShim.kirk_voice_create(hint.to_utf16.to_unsafe)
    end
  else
    h = LibShim.kirk_voice_create(nil)
  end
  VoiceSession.new(h)
end

def win32_voice_destroy(session : VoiceSession)
  h = session.valid? ? session.handle.not_nil! : nil
  return unless h
  LibShim.kirk_voice_destroy(h)
  Win32.ole_uninitialize
end
