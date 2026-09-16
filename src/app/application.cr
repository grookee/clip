require "log"
require "file_utils"
require "./ui_bridge"

module Kirk
  # Hidden message window + WndProc, tray icon/menu, hotkeys, timers, and the
  # fan-out into engine/buffer/storage actions.
  class Application
    WM_APP        = 0x8000_u32
    TRAY_CALLBACK = WM_APP + 1
    WM_CLIP_DONE  = WM_APP + 2
    WM_UI_DONE    = WM_APP + 3

    WM_HOTKEY  = 0x0312_u32
    WM_TIMER   = 0x0113_u32
    WM_CLOSE   = 0x0010_u32
    WM_DESTROY = 0x0002_u32

    HK_CLIP   = 0x5555_i32
    HK_RECORD = 0x5556_i32
    HK_SHOT   = 0x5557_i32

    TM_VOICE = 0x10_u64
    TM_HOUSE = 0x11_u64

    class_property instance : Application?

    getter dirs : NamedTuple(base: String, buffer: String, clips: String, logs: String)

    @hwnd : Win32::HWND?
    @tray : TrayIcon?
    @voice : Voice?
    @engine : FFmpegEngine?
    @buffer : BufferManager?
    @storage : StorageManager?
    @cfg : Settings
    @settings_path : String
    @log_io : IO?
    @log_backend : Log::IOBackend?
    @first_run = false
    @settings_open = false
    @voice_polls = 0_i64
    @house_ticks = 0_i64
    @voice_install_prompt_shown = false

    def self.new(cfg : Settings, settings_path : String) : self
      allocate.tap { |a| a.initialize(cfg, settings_path) }
    end

    def initialize(cfg : Settings, settings_path : String)
      @cfg = cfg
      @settings_path = settings_path
      @first_run = !File.exists?(settings_path)
      local = ENV["LOCALAPPDATA"]? || ENV["USERPROFILE"]? || "."
      base = File.join(local, "kirk")
      @dirs = {
        base:   base,
        buffer: File.join(base, "buffer"),
        clips:  File.join(base, "clips"),
        logs:   File.join(base, "logs"),
      }
      @dirs.each_value do |d|
        FileUtils.mkdir_p(d)
      end

      setup_logging
    end

    # The log file stays open for the life of the process. Reopening it per
    # toggle risks a Windows file-sharing violation, and an exception here
    # unwinds through the Win32 WndProc (a C callback), killing the process
    # with an access violation. A freshly-killed predecessor can also hold
    # the file briefly, so retry transient failures before falling back.
    private def setup_logging
      tries = 0
      loop do
        tries += 1
        begin
          if @log_backend.nil?
            @log_io = File.open(File.join(@dirs[:logs], "kirk.log"), "a")
            # Sync dispatcher: the main fiber blocks in GetMessage forever, so the
            # default Async logger's fiber never runs and lines sit unwritten.
            @log_backend = Log::IOBackend.new(@log_io.not_nil!, dispatcher: Log::DispatchMode::Sync)
          end
          level = @cfg.verbose_logging ? Log::Severity::Debug : Log::Severity::Info
          if backend = @log_backend
            Log.setup(level: level, backend: backend)
          else
            Log.setup(level: level)
          end
          break
        rescue ex
          if tries < 8
            sleep 250.milliseconds
            next
          end
          begin
            STDERR.puts "kirk: file logging unavailable after #{tries} tries (#{ex.message}); using stderr"
            Log.setup(level: Log::Severity::Info)
          rescue
          end
          break
        end
      end
    end

    def run : Int32
      Application.instance = self

      Log.info { "kirk starting (cwd=#{Dir.current}, voice_enabled=#{@cfg.voice_enabled}, conf=#{@cfg.voice_confidence}/high=#{@cfg.voice_high_confidence}, cooldown=#{@cfg.voice_cooldown_ms}ms, isolation=#{@cfg.voice_isolation_ms}ms, mic=#{@cfg.mic_device.inspect})" }

      wc = Win32::User32::WNDCLASSW.new
      wc.lpfn_wnd_proc = ->Application.wnd_proc(Win32::HWND, UInt32, Win32::WPARAM, Win32::LPARAM)
      wc.h_instance = Win32.get_module_handle
      class_name = "KirkHidden"
      wc.lpsz_class_name = Win32.to_wstr(class_name)
      wc.h_icon = Win32.app_icon
      wc.h_cursor = Win32.load_cursor(Pointer(Void).null, 32512_u32) # IDC_ARROW

      if Win32.register_class(pointerof(wc)) == 0
        Log.fatal { "RegisterClass failed: #{Win32.get_last_error_message}" }
        return 1
      end

      hwnd = Win32.create_window(Win32.get_module_handle, Win32.to_wstr(class_name), 0, 0, 0, 0)
      if hwnd.null?
        Log.fatal { "CreateWindow failed: #{Win32.get_last_error_message}" }
        return 1
      end
      @hwnd = hwnd

      start_timer(hwnd, TM_VOICE, 200_u32)
      start_timer(hwnd, TM_HOUSE, 1000_u32)

      register_all_hotkeys(hwnd)

      @tray = TrayIcon.new(hwnd, TRAY_CALLBACK, ->handle_tray_command(String))
      @tray.not_nil!.add
      @tray.not_nil!.balloon("kirk", "kirk is running in the tray.")
      open_settings if @first_run
      open_settings if ARGV.includes?("--open-settings")

      # Voice binds its own SAPI input; capture_audio only affects ffmpeg audio.
      Log.info { "audio: WASAPI default capture = #{win32_default_capture_name}" }
      Log.info { "audio: sources = #{win32_describe_audio_sources(@cfg)} (capture_audio=#{@cfg.capture_audio})" }

      @voice = Voice.new(@dirs[:logs], @cfg.voice_enabled)
      @voice.not_nil!.apply_settings(@cfg)
      phrases = Voice.parse_phrases(@cfg.voice_command)
      if phrases.empty?
        Log.warn { "voice: no phrases configured (listening INACTIVE)" }
      else
        @voice.not_nil!.start(@dirs[:logs], phrases, @cfg.mic_device)
      end
      update_voice_tray_status
      if (@voice.try(&.listening?) || false)
        log_voice_diagnostics
      else
        maybe_prompt_for_speech_install
      end

      @engine = FFmpegEngine.new(@dirs[:buffer])
      @engine.not_nil!.apply_settings(@cfg)

      seg0 = @cfg.segment_seconds
      seg0 = 2 if seg0 < 1
      cap = 2 + (@cfg.replay_seconds // seg0)
      @buffer = BufferManager.new(@dirs[:buffer], cap)
      @storage = StorageManager.new(clips_dir, @cfg.storage_limit_gb)

      if @cfg.auto_start_recording
        if e = @engine
          Log.info { "capture: auto-starting replay buffer at launch" }
          unless e.start_capture
            show_balloon("Recording failed", "Could not start capture - see kirk.log.")
          end
        end
      end

      message_loop(hwnd)

      hwnd = @hwnd
      if hwnd
        unregister_all_hotkeys(hwnd)
      end

      @buffer.try(&.prune)
      @engine.try(&.stop_capture)
      @voice.try(&.stop)
      @tray.try(&.remove)

      0
    end

    private def message_loop(hwnd : Win32::HWND)
      msg = Win32::MSG.new
      while (ret = Win32.get_message(pointerof(msg), hwnd, 0_u32, 0_u32)) != 0
        break if ret == -1
        Win32.translate_message(pointerof(msg))
        Win32.dispatch_message(pointerof(msg))
      end
    end

    private def start_timer(hwnd : Win32::HWND, id : UInt64, ms : UInt32)
      Win32.set_timer(hwnd, id, ms)
    end

    private def register_all_hotkeys(hwnd : Win32::HWND)
      unregister_all_hotkeys(hwnd)

      clip_mod = @cfg.hotkey_clip_mod.to_u32
      clip_vk = @cfg.hotkey_clip_vk.to_u32
      rec_mod = @cfg.hotkey_record_mod.to_u32
      rec_vk = @cfg.hotkey_record_vk.to_u32
      shot_mod = @cfg.hotkey_shot_mod.to_u32
      shot_vk = @cfg.hotkey_shot_vk.to_u32

      if clip_vk != 0
        ok = Win32.register_hotkey(hwnd, HK_CLIP.to_i32, clip_mod, clip_vk)
        Log.warn { "hotkey: F8 clip registration failed (key may be in use)" } unless ok
      end
      if rec_vk != 0
        ok = Win32.register_hotkey(hwnd, HK_RECORD.to_i32, rec_mod, rec_vk)
        Log.warn { "hotkey: F9 record registration failed (key may be in use)" } unless ok
      end
      if shot_vk != 0
        ok = Win32.register_hotkey(hwnd, HK_SHOT.to_i32, shot_mod, shot_vk)
        Log.warn { "hotkey: F10 screenshot registration failed (key may be in use)" } unless ok
      end
    end

    private def unregister_all_hotkeys(hwnd : Win32::HWND)
      Win32.unregister_hotkey(hwnd, HK_CLIP.to_i32)
      Win32.unregister_hotkey(hwnd, HK_RECORD.to_i32)
      Win32.unregister_hotkey(hwnd, HK_SHOT.to_i32)
    end

    def self.wnd_proc(hwnd : Win32::HWND, msg : UInt32, w_param : Win32::WPARAM, l_param : Win32::LPARAM) : Win32::LRESULT
      if app = Application.instance
        return app.handle_message(hwnd, msg, w_param, l_param)
      end
      Win32.def_window_proc(hwnd, msg, w_param, l_param)
    end

    def handle_message(hwnd : Win32::HWND, msg : UInt32, w_param : Win32::WPARAM, l_param : Win32::LPARAM) : Win32::LRESULT
      case msg
      when WM_HOTKEY
        handle_hotkey(w_param.to_i32)
        return 1.to_i64
      when WM_TIMER
        handle_timer(w_param.to_u64)
        return 0.to_i64
      when TRAY_CALLBACK
        if tray = @tray
          return 1.to_i64 if tray.handle_callback(hwnd, w_param, l_param)
        end
      when WM_CLIP_DONE
        ok = w_param.to_i32 == 1
        if ok
          show_balloon("Clip saved", "kirk saved your last #{@cfg.replay_seconds}s to the clips folder.")
        else
          show_balloon("Clip error", "Could not finalize that clip.")
        end
        return 0.to_i64
      when WM_UI_DONE
        @settings_open = false
        handle_ui_done(w_param.to_i32 == 1)
        return 0.to_i64
      when WM_CLOSE
        Win32.post_quit_message(0)
        return 0.to_i64
      when WM_DESTROY
        return 0.to_i64
      end
      Win32.def_window_proc(hwnd, msg, w_param, l_param)
    end

    private def handle_hotkey(id : Int32)
      case id
      when HK_CLIP.to_i32
        perform_clip
      when HK_RECORD.to_i32
        toggle_recording
      when HK_SHOT.to_i32
        perform_screenshot
      end
    end

    private def handle_timer(id : UInt64)
      case id
      when TM_VOICE
        poll_voice
      when TM_HOUSE
        poll_housekeeping
      end
    end

    private def perform_clip
      if e = @engine
        if buffer = @buffer
          segments = buffer.safe_segments
          if segments.empty?
            Log.warn { "clip: no segments to save" }
            show_balloon("No clip", "There was nothing to save.")
            return
          end
          name = clip_filename
          out_path = File.join(clips_path, name)
          Log.info { "clip: #{segments.size} segments -> #{out_path}" }
          audio = e.aligned_audio_segments(segments.size)
          Log.info { "clip: + #{audio.size} audio segments" } unless audio.empty?
          if e.remux_segments(segments, out_path, audio)
            Log.info { "clip: saved #{out_path}" }
            show_balloon("Clip saved", "kirk saved your last #{@cfg.replay_seconds}s to the clips folder.")
          else
            Log.error { "clip: remux failed for #{out_path}" }
            show_balloon("Clip error", "Could not finalize that clip.")
          end
        end
      end
    end

    private def toggle_recording
      if e = @engine
        if e.capture_running?
          e.stop_capture
          Log.info { "capture: stopped" }
          show_balloon("Recording stopped", "kirk stopped recording.")
        else
          Log.info { "capture: starting (#{win32_describe_audio_sources(@cfg)}, capture_audio=#{@cfg.capture_audio})" }
          log_voice_liveness("capture start")
          e.start_capture
          show_balloon("Recording started", "kirk is now recording.")
        end
      end
    end

    private def perform_screenshot
      if e = @engine
        dir = clips_path
        FileUtils.mkdir_p(dir)
        out_path = File.join(dir, "shot-#{Win32.timestamp}.png")
        if e.screenshot_frame(out_path)
          show_balloon("Screenshot saved", "Saved screenshot to the clips folder.")
        else
          show_balloon("Screenshot failed", "Could not take a screenshot.")
        end
      end
    end

    # Drains the whole queue per tick: one event per tick strands follow-ups
    # behind the cooldown window during loud/fast speech.
    private def poll_voice
      v = @voice
      return unless v
      @voice_polls += 1
      8.times do
        case v.poll
        when Voice::Action::Clip
          Log.info { "voice: clip command" }
          perform_clip
        when Voice::Action::Record
          Log.info { "voice: record command" }
          toggle_recording
        when Voice::Action::Screenshot
          Log.info { "voice: screenshot command" }
          perform_screenshot
        when Voice::Action::None
          break
        end
      end
    end

    # Stream position advances while audio frames reach SAPI; a stuck position
    # with voice complaints means the engine hears nothing.
    private def log_voice_liveness(context : String)
      v = @voice
      unless v && v.listening?
        Log.info { "voice: liveness [#{context}]: listening INACTIVE (enabled=#{@cfg.voice_enabled})" }
        return
      end
      if s = v.session
        if st = s.status
          pos, state = st
          Log.info { "voice: liveness [#{context}]: listening ACTIVE stream_pos=#{pos} audio_state=#{state}" }
        else
          Log.warn { "voice: liveness [#{context}]: status query failed" }
        end
      end
    end

    # Names the voice state and why. When listening, shows the ACTUAL bound
    # SAPI input, which often differs from the WASAPI default guess.
    private def update_voice_tray_status
      tip = if !@cfg.voice_enabled
              "kirk - voice OFF (enable in Settings > Voice commands)"
            elsif (v = @voice) && v.listening?
              input = v.session.try(&.input_name) || win32_default_capture_name
              "kirk - voice listening (#{input})"
            else
              "kirk - voice INACTIVE (see kirk.log)"
            end
      @tray.try(&.set_tip(tip))
      Log.info { "voice: status -> #{tip}" }
    end

    # One-line inventory of what SAPI offers, for support logs. No prompt.
    private def log_voice_diagnostics
      ok_r, recos = win32_list_speech_recognizers
      ok_a, inputs = win32_list_sapi_audio_inputs
      Log.info { "voice: recognizers ok=#{ok_r} count=#{recos.size}#{recos.empty? ? "" : " (" + recos.map(&.name).join("; ") + ")"}" }
      Log.info { "voice: sapi inputs ok=#{ok_a} count=#{inputs.size}#{inputs.empty? ? "" : " (" + inputs.map(&.name).join("; ") + ")"}" }
    end

    # On voice start failure, checks whether a speech prerequisite is missing
    # and - once per process - shows a balloon plus a Yes/No popup that opens
    # the right Settings page. Returns true when such a specific prompt was
    # shown, so callers skip their generic "see kirk.log" balloon.
    private def maybe_prompt_for_speech_install : Bool
      return false unless @cfg.voice_enabled
      return false if @voice_install_prompt_shown
      v = @voice
      # Only prompt when voice actually failed (disabled/empty-phrases paths
      # never reach here, but double-check via listening? when available).
      if v && v.listening?
        return false
      end
      ok_r, recos = win32_list_speech_recognizers
      ok_a, inputs = win32_list_sapi_audio_inputs
      Log.info { "voice: recognizers ok=#{ok_r} count=#{recos.size}#{recos.empty? ? "" : " (" + recos.map(&.name).join("; ") + ")"}" }
      Log.info { "voice: sapi inputs ok=#{ok_a} count=#{inputs.size}#{inputs.empty? ? "" : " (" + inputs.map(&.name).join("; ") + ")"}" }
      owner = @hwnd || Pointer(Void).null
      if ok_r && recos.empty?
        @voice_install_prompt_shown = true
        Log.warn { "voice: no SAPI speech recognizers installed - prompting to install" }
        show_balloon("Voice needs speech recognition", "No speech recognizer installed - voice is off, hotkeys still work.")
        if Win32.confirm_dialog(owner, "kirk - voice needs speech recognition", "No Windows speech recognizer is installed, so voice commands can't listen.\n\nHotkeys (F8/F9/F10) still work.\n\nOpen Windows speech settings to install one?\n(Time & language > Speech > add English, then restart kirk)")
          Win32.open_settings_page("ms-settings:speech")
        end
        return true
      end
      if ok_a && inputs.empty?
        @voice_install_prompt_shown = true
        Log.warn { "voice: no SAPI audio inputs found - prompting to check microphone" }
        show_balloon("Voice needs a microphone", "No speech microphone found - voice is off, hotkeys still work.")
        if Win32.confirm_dialog(owner, "kirk - no speech microphone", "Speech recognition is installed, but no speech microphone (SAPI audio input) was found.\n\nCheck the mic is enabled and Settings > Privacy > Microphone allows desktop apps.\n\nOpen microphone privacy settings?")
          Win32.open_settings_page("ms-settings:privacy-microphone")
        end
        return true
      end
      false
    end

    private def poll_housekeeping
      @buffer.try(&.prune)
      @storage.try(&.prune)
      # polls>0 with all counters 0 = events never arrive; sound/hyp>0 with
      # reco/reject 0 = audio flows but the grammar never matches.
      @house_ticks += 1
      if @house_ticks % 60 == 0
        s, h, r, j = win32_voice_counters
        listening = @voice.try(&.listening?) || false
        Log.info { "voice: heartbeat polls=#{@voice_polls} listening=#{listening} sound=#{s} hyp=#{h} reco=#{r} reject=#{j}" }
      end
    end

    # Central user feedback: Windows tray notification and/or the bundled
    # chime, per the "Clip saved feedback" setting (both / toast / sound /
    # off). Best-effort and exception-free: sound failures only log.
    private def show_balloon(title : String, message : String)
      if @cfg.show_save_notifications
        if tray = @tray
          tray.balloon(title, message)
        end
      end
      if @cfg.play_save_sound
        unless Win32.play_clip_sound
          Log.debug { "feedback: chime unavailable (#{Win32.clip_sound_path.inspect})" }
        end
      end
    rescue ex
      Log.debug { "feedback failed: #{ex.message}" }
    end

    private def handle_tray_command(cmd : String)
      case cmd
      when "clips"    then Win32.open_folder(clips_dir)
      when "buffer"   then Win32.open_folder(@dirs[:buffer])
      when "settings" then open_settings
      when "quit"     then Win32.post_quit_message(0)
      end
    end

    private def clips_dir : String
      d = @cfg.clips_dir
      d.empty? ? @dirs[:clips] : File.expand_path(d)
    end

    private def clips_path : String
      dir = File.dirname(clip_filename)
      dir == "." ? clips_dir : File.join(clips_dir, dir)
    end

    # {timestamp} becomes a yyyymmdd-hhmmss stamp; an .mp4 extension is guaranteed.
    private def clip_filename : String
      pat = @cfg.clip_name_pattern
      pat = "clip-{timestamp}.mp4" if pat.strip.empty?
      name = pat.gsub("{timestamp}", Win32.timestamp)
      name += ".mp4" unless name.downcase.ends_with?(".mp4")
      name
    end

    def open_settings
      hwnd = @hwnd
      return unless hwnd
      return if @settings_open
      return if LibShim.kirk_ui_active != 0

      cc = KirkSettings.new
      UIBridge.fill_cc(@cfg, pointerof(cc))
      # kirk_ui_show blocks with a nested loop that dispatches WM_UI_DONE first,
      # so the flag must be raised before the call. Assigning the return value
      # here left it stale-true: Settings opened once per process, then never again.
      @settings_open = true
      shown = LibShim.kirk_ui_show(hwnd, WM_UI_DONE.to_u32, pointerof(cc).as(Void*)) != 0
      @settings_open = false
      Log.info { "settings: dialog shown=#{shown}" }
    end

    private def handle_ui_done(saved : Bool)
      if saved
        ptr = LibShim.kirk_ui_last_saved
        if ptr.nil?
          Log.warn { "settings: no result from dialog" }
          return
        end

        # Settings is a struct: plain assignment copies every field. The old
        # hand-rolled copy silently dropped fields, so they never applied live.
        old = @cfg

        begin
          UIBridge.apply_from_cc(pointerof(@cfg), ptr.as(KirkSettings*).value)
          @cfg.save(@settings_path)
          apply_settings_live(old)
          Log.info { "settings: saved + applied" }
        rescue ex
          # An exception here would unwind through C frames and kill the process.
          Log.error { "settings: save/apply failed: #{ex.message}" }
          show_balloon("Settings error", "Could not save settings (see log).")
          return
        end

        show_balloon("Settings saved", "kirk settings were updated.")
      end
    end

    private def apply_settings_live(old : Settings)
      media_changed = old.fps != @cfg.fps ||
                      old.bitrate_kbps != @cfg.bitrate_kbps ||
                      old.audio_bitrate_kbps != @cfg.audio_bitrate_kbps ||
                      old.replay_seconds != @cfg.replay_seconds ||
                      old.segment_seconds != @cfg.segment_seconds ||
                      old.capture_audio != @cfg.capture_audio ||
                      old.mic_device != @cfg.mic_device ||
                      old.extra_audio_devices != @cfg.extra_audio_devices ||
                      old.capture_system_audio != @cfg.capture_system_audio ||
                      old.system_audio_device != @cfg.system_audio_device ||
                      old.mic_gain != @cfg.mic_gain ||
                      old.system_gain != @cfg.system_gain ||
                      old.hw_encoder != @cfg.hw_encoder ||
                      old.encoder_preset != @cfg.encoder_preset ||
                      old.max_width != @cfg.max_width ||
                      old.max_height != @cfg.max_height

      if engine = @engine
        was_running = engine.capture_running?
        engine.stop_capture if media_changed
        engine.apply_settings(@cfg)
        engine.start_capture if media_changed && was_running
        # Flipping auto-start ON mid-session takes effect without a restart.
        if !was_running && @cfg.auto_start_recording && !old.auto_start_recording
          Log.info { "capture: auto-start enabled in settings, starting now" }
          engine.start_capture
        end
      end

      seg = @cfg.segment_seconds
      seg = 2 if seg < 1
      cap = 2 + (@cfg.replay_seconds // seg)
      @buffer = BufferManager.new(@dirs[:buffer], cap)
      @storage = StorageManager.new(clips_dir, @cfg.storage_limit_gb)

      # Any voice field change needs a restart; watching only the enabled flag
      # silently dropped command/confidence/cooldown/mic edits.
      if old.voice_enabled != @cfg.voice_enabled ||
         old.voice_command != @cfg.voice_command ||
         old.voice_confidence != @cfg.voice_confidence ||
         old.voice_high_confidence != @cfg.voice_high_confidence ||
         old.voice_cooldown_ms != @cfg.voice_cooldown_ms ||
         old.voice_isolation_ms != @cfg.voice_isolation_ms ||
         old.mic_device != @cfg.mic_device
        restart_voice
      end
      Log.info { "audio: WASAPI default capture = #{win32_default_capture_name}" }
      Log.info { "audio: sources = #{win32_describe_audio_sources(@cfg)} (capture_audio=#{@cfg.capture_audio})" }

      if old.verbose_logging != @cfg.verbose_logging
        setup_logging
      end

      hotkey_changed = old.hotkey_clip_mod != @cfg.hotkey_clip_mod ||
                       old.hotkey_clip_vk != @cfg.hotkey_clip_vk ||
                       old.hotkey_record_mod != @cfg.hotkey_record_mod ||
                       old.hotkey_record_vk != @cfg.hotkey_record_vk ||
                       old.hotkey_shot_mod != @cfg.hotkey_shot_mod ||
                       old.hotkey_shot_vk != @cfg.hotkey_shot_vk
      if hotkey_changed
        hwnd = @hwnd
        register_all_hotkeys(hwnd) if hwnd
      end

      exe = "\"#{Win32.executable_path}\""
      LibShim.kirk_set_run_at_startup(Win32.to_wstr(exe), @cfg.run_at_startup ? 1 : 0)
    end

    private def restart_voice
      v = @voice
      prev_input = v.try(&.session.try(&.input_name))
      if v
        v.stop
        @voice = nil
      end
      unless @cfg.voice_enabled
        Log.info { "voice: disabled by settings (listening INACTIVE)" }
        update_voice_tray_status
        return
      end

      voice = Voice.new(@dirs[:logs], @cfg.voice_enabled)
      voice.apply_settings(@cfg)
      phrases = Voice.parse_phrases(@cfg.voice_command)
      if phrases.empty?
        Log.warn { "voice: no phrases configured after settings change (listening INACTIVE)" }
        show_balloon("Voice inactive", "No voice phrases configured - voice commands will not trigger.")
      else
        voice.start(@dirs[:logs], phrases, @cfg.mic_device)
        unless voice.listening?
          handled = maybe_prompt_for_speech_install
          show_balloon("Voice inactive", "Voice engine failed to start - see kirk.log for why.") unless handled
        end
      end
      @voice = voice
      log_voice_liveness("settings applied")
      update_voice_tray_status
      if voice.listening?
        cur = voice.session.try(&.input_name) || ""
        if cur != prev_input
          show_balloon("Voice listening", "Voice commands on '#{cur}'.")
        end
      end
    end
  end
end
