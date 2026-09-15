require "yaml"

# Serializable configuration. All fields have sane defaults so a fresh
# install works without a config file.
module Kirk
  struct Settings
    include YAML::Serializable

    # Replay buffer depth in seconds (how far "clip that!" goes back).
    property replay_seconds : Int32 = 30

    # Length of one on-disk segment in seconds. Loss on clip save is tiny (2s default).
    property segment_seconds : Int32 = 2

    property fps : Int32 = 60
    property bitrate_kbps : Int32 = 8000
    property encoder_preset : String = "p4"
    property max_width : Int32 = 0 # 0 = native desktop resolution
    property max_height : Int32 = 0

    # "" = auto (nvenc > amf > qsv > x264).
    property hw_encoder : String = ""

    property capture_audio : Bool = true
    property mic_device : String = "" # empty = ffmpeg dshow default
    property audio_bitrate_kbps : Int32 = 192

    # ";"-separated: phrases themselves contain commas, so "," fragments
    # every command into unmatchable pieces (silent voice-trigger failure).
    property voice_enabled : Bool = true
    # SAPI confidence floor. Clear speech decodes at 0.017-0.041 while room
    # noise emits no text, so the word match itself is the signal; the old
    # 0.60 default could never fire.
    property voice_confidence : Float64 = 0.01
    property voice_cooldown_ms : Int32 = 2500
    property voice_command : String = "Kirk, clip that!;" \
                                      "Kirk clip that;" \
                                      "Kirk, clip it!;" \
                                      "Hey Kirk, clip that!;" \
                                      "Clip that, Kirk!"

    property hotkey_clip_mod : Int32 = 0
    property hotkey_clip_vk : Int32 = 0x77
    property hotkey_record_mod : Int32 = 0
    property hotkey_record_vk : Int32 = 0x78
    property hotkey_shot_mod : Int32 = 0
    property hotkey_shot_vk : Int32 = 0x79

    property storage_limit_gb : Int32 = 20
    property auto_delete_oldest : Bool = true
    property clips_dir : String = "" # empty = %LOCALAPPDATA%\kirk\clips
    property clip_name_pattern : String = "clip-{timestamp}.mp4"

    property start_minimized : Bool = true
    property show_save_notifications : Bool = true
    property run_at_startup : Bool = false
    # Start capture at launch so a voice command or hotkey never finds an empty buffer.
    property auto_start_recording : Bool = true

    property verbose_logging : Bool = false

    def initialize
    end

    def sanitize! : self
      self.fps = 60 if fps < 10 || fps > 240
      self.bitrate_kbps = 8000 if bitrate_kbps < 250 || bitrate_kbps > 200_000
      self.audio_bitrate_kbps = 192 if audio_bitrate_kbps < 32 || audio_bitrate_kbps > 512
      self.replay_seconds = 30 if replay_seconds < 5 || replay_seconds > 600
      self.segment_seconds = 2 if segment_seconds < 1 || segment_seconds > 15
      self.storage_limit_gb = 20 if storage_limit_gb < 1 || storage_limit_gb > 500
      self.clip_name_pattern = "clip-{timestamp}.mp4" if clip_name_pattern.strip.empty?
      # The stale 0.60 default never fires where SAPI decodes at 0.017-0.041;
      # migrate exactly that value, leave explicit user values untouched.
      if voice_confidence == 0.60
        self.voice_confidence = 0.01
        Log.info { "config: migrated stale voice_confidence 0.60 -> 0.01 (see voice log lines to tune)" }
      end
      self.voice_confidence = 0.01 if voice_confidence < 0.0 || voice_confidence > 1.0
      self
    end

    def self.load(path : String) : Settings
      return Settings.new unless File.exists?(path)
      begin
        return Settings.from_yaml(File.read(path)).sanitize!
      rescue ex
        Log.warn { "config parse error: #{ex.message}; using defaults" }
        return Settings.new
      end
    end

    def save(path : String)
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path, to_yaml)
    end
  end
end
