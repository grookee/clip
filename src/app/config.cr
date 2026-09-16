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
    property mic_device : String = "" # empty = system default mic (resolved to its dshow name)
    property audio_bitrate_kbps : Int32 = 192

    # Mini audio mixer: one primary mic + optional extra capture devices +
    # optional loopback-capture device (Stereo Mix / VB-Cable output /
    # Voicemeeter - game / Discord / system output), mixed into a single
    # AAC track. Empty extra list = off. Empty system device = mics only
    # (plain speakers are not capturable with this ffmpeg build, which has
    # no wasapi loopback). Gains are linear multipliers (1.0 = unity),
    # clamped to 0.0..2.0.
    property extra_audio_devices : Array(String) = [] of String
    property capture_system_audio : Bool = false
    property system_audio_device : String = ""
    property mic_gain : Float64 = 1.0
    property system_gain : Float64 = 1.0

    # ";"-separated: phrases themselves contain commas, so "," fragments
    # every command into unmatchable pieces (silent voice-trigger failure).
    property voice_enabled : Bool = true
    # SAPI confidence floor. SAPI force-maps ANY speech onto the closest
    # grammar phrase at low confidence (clear commands and Discord chatter
    # decode in the same range), so the floor alone cannot separate them:
    # the chatter-burst gate in voice.cr does. Tune via Settings > Voice or
    # watch the `voice: heard ...` lines in kirk.log.
    property voice_confidence : Float64 = 0.01
    property voice_cooldown_ms : Int32 = 2500
    # Chatter-burst gate: a floor-passing candidate inside this window after
    # the previous contender needs voice_high_confidence to fire. Deliberate
    # commands are isolated; conversation comes in bursts.
    property voice_isolation_ms : Int32 = 1200
    # Confidence that bypasses the burst gate (clamped to >= floor at use).
    property voice_high_confidence : Float64 = 0.5
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
    # Chime on clip save (assets/clip.wav staged next to the exe).
    # Together with show_save_notifications this is a 4-way choice:
    # both on = notification + sound, either off, or both off = silent.
    property play_save_sound : Bool = true
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
      # 0 = native resolution; otherwise clamp to sane even-friendly bounds.
      # Odd widths break yuv420p, so force even below.
      if max_width != 0 && (max_width < 640 || max_width > 7680)
        self.max_width = 0
      elsif max_width % 2 != 0
        self.max_width -= 1
      end
      if max_height != 0 && (max_height < 360 || max_height > 4320)
        self.max_height = 0
      elsif max_height % 2 != 0
        self.max_height -= 1
      end
      allowed_presets = %w[p1 p2 p3 p4 p5 p6 p7 speed balanced quality
        ultrafast superfast veryfast faster fast medium
        slow slower veryslow]
      self.encoder_preset = "p4" unless allowed_presets.includes?(encoder_preset.strip.downcase)
      self.clip_name_pattern = "clip-{timestamp}.mp4" if clip_name_pattern.strip.empty?
      # Heal configs written by the pre-fix settings dialog, which saved the
      # literal "(System default)" label instead of "" (off-by-one in the
      # native save path). Both mean "default mic".
      if mic_device.strip == "(System default)"
        self.mic_device = ""
      else
        self.mic_device = mic_device.strip
      end
      self.system_audio_device = system_audio_device.strip
      # Extra devices: strip, drop empties/duplicates and the primary mic,
      # cap the list so one bad edit can't spawn dozens of ffmpeg inputs.
      seen = Hash(String, Bool).new
      seen[mic_device.downcase] = true unless mic_device.empty?
      clean = [] of String
      extra_audio_devices.each do |d|
        name = d.strip
        next if name.empty? || name == "(System default)" || name == "(None)"
        key = name.downcase
        next if seen[key]?
        seen[key] = true
        clean << name
        break if clean.size >= 4
      end
      self.extra_audio_devices = clean
      self.mic_gain = 1.0 if mic_gain < 0.0 || mic_gain > 2.0
      self.system_gain = 1.0 if system_gain < 0.0 || system_gain > 2.0
      self.voice_confidence = 0.01 if voice_confidence < 0.0 || voice_confidence > 1.0
      self.voice_high_confidence = 0.5 if voice_high_confidence < 0.0 || voice_high_confidence > 1.0
      self.voice_cooldown_ms = 2500 if voice_cooldown_ms < 250 || voice_cooldown_ms > 15000
      self.voice_isolation_ms = 1200 if voice_isolation_ms < 0 || voice_isolation_ms > 10000
      self
    end

    # Production settings location: %LOCALAPPDATA%\kirk\kirk.yml. The
    # install dir (and the process cwd under MSIX) is read-only, so a
    # cwd-relative config breaks once packaged.
    LEGACY_SETTINGS_PATH = "kirk.yml"

    def self.default_path : String
      local = ENV["LOCALAPPDATA"]? || ENV["USERPROFILE"]? || "."
      File.join(local, "kirk", "kirk.yml")
    end

    # One-time copy of a dev-install ./kirk.yml to the production path.
    # The legacy file is left in place, never deleted.
    def self.migrate_legacy!(path : String)
      return if File.exists?(path)
      return unless File.exists?(LEGACY_SETTINGS_PATH)
      begin
        Dir.mkdir_p(File.dirname(path))
        File.copy(LEGACY_SETTINGS_PATH, path)
        Log.info { "config: migrated legacy ./kirk.yml to #{path}" }
      rescue ex
        Log.warn { "config: legacy migration failed: #{ex.message}" }
      end
    end

    def self.load(path : String) : Settings
      return Settings.new unless File.exists?(path)
      begin
        return Settings.from_yaml(File.read(path)).sanitize!
      rescue ex
        Log.warn { "config parse error: #{ex.message}; using defaults" }
        begin
          File.copy(path, "#{path}.bad-#{Time.local.to_s("%Y%m%d-%H%M%S")}")
        rescue
        end
        return Settings.new
      end
    end

    def save(path : String)
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      # Atomic write: a crash/power cut mid-write used to leave a truncated
      # kirk.yml behind, and the next launch silently fell back to defaults
      # ("config is janky"). Write-temp + rename keeps the old file intact.
      tmp = "#{path}.tmp-#{Process.pid}"
      File.write(tmp, to_yaml)
      File.rename(tmp, path)
    rescue ex
      Log.warn { "config: save failed: #{ex.message}" }
      begin
        File.delete(tmp) if tmp && File.exists?(tmp)
      rescue
      end
    end
  end
end
