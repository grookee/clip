require "process"
require "log"
require "file_utils"

module Kirk
  # Drives ffmpeg: one long-lived capture into keyframe-aligned MPEG-TS
  # segments, plus short `-c copy` remuxes when a clip is saved.
  class FFmpegEngine
    getter buffer_dir : String
    getter segment_pat : String
    getter audio_pat : String
    property ffmpeg_path : String

    @replay_seconds = 30_i32
    @segment_seconds = 2_i32
    @fps = 60_i32
    @bitrate_kbps = 8000_i32
    @encoder_preset = "p4"
    @max_width = 0_i32
    @max_height = 0_i32
    @hw_encoder = ""
    @capture_audio = true
    @mic_device = ""
    @audio_bitrate_kbps = 128_i32
    @extra_audio_devices = [] of String
    @capture_system_audio = false
    @system_audio_device = ""
    @mic_gain = 1.0_f64
    @system_gain = 1.0_f64

    @proc : Process?
    @err_io : File?
    @audio_proc : Process?
    @audio_err_io : File?
    @resolved_encoder : String? = nil
    @gpu_family = Hash(String, String).new
    @gpu_probed_at = Hash(String, Time).new

    def initialize(@buffer_dir)
      @segment_pat = File.join(@buffer_dir, "seg_%05d.ts")
      @audio_pat = File.join(@buffer_dir, "aud_%05d.ts")
      @ffmpeg_path = FFmpegEngine.locate_ffmpeg
      Log.info { "ffmpeg binary: #{@ffmpeg_path}" }
    end

    def self.locate_ffmpeg : String
      candidates = [
        ENV["KIRK_FFMPEG"]?,
        File.join(File.dirname(Win32.executable_path), "ffmpeg.exe"),
      ]
      candidates.compact.each do |p|
        return p if File.exists?(p)
      end
      "ffmpeg.exe"
    end

    def apply_settings(cfg : Kirk::Settings)
      @replay_seconds = cfg.replay_seconds
      @segment_seconds = cfg.segment_seconds
      @fps = cfg.fps
      @bitrate_kbps = cfg.bitrate_kbps
      @encoder_preset = cfg.encoder_preset
      @max_width = cfg.max_width
      @max_height = cfg.max_height
      @hw_encoder = cfg.hw_encoder
      @capture_audio = cfg.capture_audio
      @mic_device = cfg.mic_device
      @audio_bitrate_kbps = cfg.audio_bitrate_kbps
      @extra_audio_devices = cfg.extra_audio_devices.dup
      @capture_system_audio = cfg.capture_system_audio
      @system_audio_device = cfg.system_audio_device
      @mic_gain = cfg.mic_gain
      @system_gain = cfg.system_gain
      @resolved_encoder = nil
      @gpu_family.clear
      @gpu_probed_at.clear
    end

    # Empty hw_encoder means auto: nvenc > amf > qsv > libx264, probed once
    # and cached. The probe test-encodes: listing an encoder in -encoders
    # only means the binary supports it (this AMD box lists h264_nvenc but
    # has no NVIDIA GPU, and selecting it captures nothing). The 320x240
    # frame is deliberate: AMF rejects smaller ones (Init error 5).
    # Measured 15s peaks at 1440p60/8Mbps: libx264 916MB, h264_amf 163MB.
    # On AMD cards this resolves to h264_amf; make sure Adrenalin drivers
    # are installed (Windows Update drivers often lack AMF) or you will
    # fall through to libx264 and see encoding lag.
    # An explicit hw_encoder setting always wins.
    private def encoder_usable?(enc : String) : Bool
      begin
        status = Process.run(@ffmpeg_path,
          ["-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", "nullsrc=s=320x240:r=10:d=1",
           "-c:v", enc, "-f", "null", "-"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        status.success?
      rescue
        false
      end
    end

    private def resolve_encoder : String
      if r = @resolved_encoder
        return r
      end
      forced = @hw_encoder
      if forced && !forced.empty?
        @resolved_encoder = forced
        return forced
      end
      found = "libx264"
      ["h264_nvenc", "h264_amf", "h264_qsv"].each do |candidate|
        if encoder_usable?(candidate)
          found = candidate
          break
        end
      end
      Log.info { "capture encoder: #{found}#{found == "libx264" ? " (no usable hardware encoder)" : " (auto-selected)"}" }
      @resolved_encoder = found
      found
    end

    private def encoder_name : String
      resolve_encoder
    end

    private def nvenc_encoder?(enc : String) : Bool
      enc == "h264_nvenc" || enc == "hevc_nvenc" || enc == "av1_nvenc"
    end

    private def amf_encoder?(enc : String) : Bool
      enc == "h264_amf" || enc == "hevc_amf" || enc == "av1_amf"
    end

    private def qsv_encoder?(enc : String) : Bool
      enc == "h264_qsv" || enc == "hevc_qsv" || enc == "av1_qsv"
    end

    # Maps the generic `encoder_preset` setting onto per-encoder options.
    # NVENC understands p1..p7, AMF wants speed|balanced|quality, QSV and
    # x264 have their own preset names - so a raw passthrough only ever
    # worked for NVENC and silently fell back to ffmpeg defaults elsewhere.
    private def preset_args(enc : String) : Array(String)
      extra = Array(String).new
      preset = (@encoder_preset || "p4").strip.downcase
      preset = "p4" if preset.empty?

      if nvenc_encoder?(enc)
        p = %w[p1 p2 p3 p4 p5 p6 p7].includes?(preset) ? preset : "p4"
        extra << "-preset" << p << "-tune" << "ll" << "-rc" << "cbr" << "-multipass" << "disabled"
      elsif amf_encoder?(enc)
        q = case preset
            when "speed", "fast", "ultrafast", "superfast", "veryfast", "p1", "p2", "p3" then "speed"
            when "quality", "slow", "slower", "veryslow", "p6", "p7"                     then "quality"
            else                                                                              "balanced"
            end
        # ultralowlatency drops B-frames: less encoding lag while gaming.
        # It also disables periodic IDR frames (infinite GOP), so the
        # segment muxer below would never see a splittable keyframe and the
        # buffer would sit at a single ever-growing seg_00000.ts.
        # forced_idr turns every forced I-frame into a real IDR.
        extra << "-quality" << q << "-rc" << "cbr" << "-usage" << "ultralowlatency"
        extra << "-forced_idr" << "true"
        extra << "-vbaq" << "true" if q != "speed"
      elsif qsv_encoder?(enc)
        p = case preset
            when "p1", "p2", "ultrafast", "superfast", "veryfast" then "veryfast"
            when "p3", "p4", "faster"                             then "faster"
            when "p5", "fast"                                     then "fast"
            when "p6", "p7", "medium", "slow"                     then "medium"
            when "slower", "veryslow"                             then "slower"
            else                                                       "veryfast"
            end
        extra << "-preset" << p << "-look_ahead" << "0"
      elsif enc == "libx264" || enc == "libx265"
        p = case preset
            when "ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow" then preset
            when "p1"                                                                                           then "ultrafast"
            when "p2"                                                                                           then "superfast"
            when "p3", "p4"                                                                                     then "veryfast"
            when "p5"                                                                                           then "faster"
            when "p6", "p7"                                                                                     then "fast"
            else                                                                                                     "veryfast"
            end
        extra << "-preset" << p << "-tune" << "zerolatency"
      end
      extra
    end

    # Concrete downscale target (even, aspect-preserved) or nil = native.
    # Computed in Crystal rather than with filter expressions so the GPU
    # chains below get exact dimensions. Mirrors the old filter logic: fit
    # inside the max box, shrink-only, force even for yuv420p.
    private def downscale_target(vw : Int32, vh : Int32) : Tuple(Int32, Int32)?
      mw = @max_width || 0
      mh = @max_height || 0
      return nil if mw <= 0 && mh <= 0
      return nil if vw <= 0 || vh <= 0
      tw = vw
      th = vh
      if mw > 0 && mh > 0
        s = Math.min(mw.to_f / vw, mh.to_f / vh)
        if s < 1.0
          tw = (vw * s).to_i & ~1
          th = (vh * s).to_i & ~1
        end
      elsif mw > 0
        if vw > mw
          tw = mw & ~1
          th = (vh.to_f * mw / vw).to_i & ~1
        end
      else
        if vh > mh
          th = mh & ~1
          tw = (vw.to_f * mh / vh).to_i & ~1
        end
      end
      tw = 2 if tw < 2
      th = 2 if th < 2
      return nil if tw >= vw && th >= vh
      {tw, th}
    end

    # Smoke-tests a GPU chain against REAL ddagrab frames (10 frames at
    # 10fps, ~1-2s). Synthetic hwupload textures have different provenance
    # and prove nothing: AMF interop accepts Desktop-Duplication textures
    # while rejecting hwupload-created ones (measured both ways). ddagrab
    # works wherever capture itself can run; where it can't (headless),
    # the probe fails fast and the CPU path is used.
    private def gpu_probe_run(enc : String, chain : String) : Tuple(Bool, String)
      err_io = IO::Memory.new
      begin
        status = Process.run(@ffmpeg_path,
          ["-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", "ddagrab=video_size=640x360:framerate=10:draw_mouse=0",
           "-vf", chain,
           "-c:v", enc, "-frames:v", "10", "-f", "null", "-"],
          output: Process::Redirect::Close, error: err_io)
        if status.success?
          return {true, ""}
        end
        detail = err_io.to_s.lines.map(&.strip).reject(&.empty?).first(2).join(" | ")[0, 300]
        {false, detail}
      rescue ex
        {false, ex.message.to_s[0, 200]}
      end
    end

    # Winning GPU family per encoder ("cpu" = fall back), cached with a 60s
    # retry on failure so one cold-start hiccup doesn't pin the session.
    private def gpu_family(enc : String) : String
      if fam = @gpu_family[enc]?
        return fam if fam != "cpu"
        if t = @gpu_probed_at[enc]?
          return "cpu" if (Time.utc - t) < 60.seconds
        end
      end
      fam = "cpu"
      detail = ""
      candidates = if nvenc_encoder?(enc)
                     [{"d3d11", "scale_d3d11=width=320:height=180"}]
                   elsif amf_encoder?(enc)
                     [{"d3d11", "scale_d3d11=width=320:height=180:format=nv12"},
                      {"vpp_amf", "vpp_amf=w=320:h=180:format=nv12"}]
                   elsif qsv_encoder?(enc)
                     [{"qsv", "hwmap=derive_device=qsv,scale_qsv=w=320:h=180"}]
                   else
                     [] of Tuple(String, String)
                   end
      candidates.each do |c|
        ok, err = gpu_probe_run(enc, c[1])
        if ok
          fam = c[0]
          break
        else
          detail = err
        end
      end
      @gpu_family[enc] = fam
      @gpu_probed_at[enc] = Time.utc
      if fam == "cpu"
        Log.warn { "capture: gpu zero-copy unavailable, CPU readback (#{enc}): #{detail}" }
      else
        Log.info { "capture: gpu zero-copy ACTIVE (#{enc} via #{fam})" }
      end
      fam
    end

    # Builds the -vf chain, GPU-first. Returns {filter_or_nil, gpu_path?}.
    # GPU chains are probe-gated: anything untested on this box (a filter
    # typo, a missing driver, a headless session) falls back to the legacy
    # CPU readback path with a warning instead of an empty buffer.
    private def video_filter(enc : String, vw : Int32, vh : Int32) : Tuple(String?, Bool)
      target = downscale_target(vw, vh)
      # NVENC eats ddagrab d3d11 directly: native needs no filter at all.
      if nvenc_encoder?(enc) && target.nil?
        return {nil, true}
      end
      unless enc == "libx264" || enc == "libx265"
        case gpu_family(enc)
        when "d3d11"
          if nvenc_encoder?(enc)
            if t = target
              return {"scale_d3d11=width=#{t[0]}:height=#{t[1]}", true}
            end
          else
            if t = target
              return {"scale_d3d11=width=#{t[0]}:height=#{t[1]}:format=nv12", true}
            end
            return {"scale_d3d11=format=nv12", true}
          end
        when "vpp_amf"
          if t = target
            return {"vpp_amf=w=#{t[0]}:h=#{t[1]}:format=nv12", true}
          end
          return {"vpp_amf=format=nv12", true}
        when "qsv"
          if t = target
            return {"hwmap=derive_device=qsv,scale_qsv=w=#{t[0]}:h=#{t[1]}", true}
          end
          return {"hwmap=derive_device=qsv", true}
        end
        Log.warn { "capture: gpu chain rejected for #{enc}, falling back to CPU readback" }
      end

      # Legacy CPU path: full-res GPU->CPU copy, then software convert.
      # Always works, costs ~1.2GB/s readback at 3440x1440@60.
      parts = Array(String).new
      parts << "hwdownload" << "format=bgra" unless nvenc_encoder?(enc)
      if t = target
        parts << "scale=w=#{t[0]}:h=#{t[1]}:flags=bilinear"
        # NVENC takes d3d11 frames zero-copy; once we download+scale the
        # frames are software, so normalize the pixel format in-filter
        # instead of via -pix_fmt (which would be a second conversion).
        parts << "format=yuv420p" if nvenc_encoder?(enc)
      end

      return {nil, false} if parts.empty?
      {parts.join(","), false}
    end

    private def capture_args : Array(String)
      seg = @segment_seconds.not_nil!
      fps = @fps.not_nil!

      args = Array(String).new
      # warning (not error) so lag signals reach ffmpeg.out.log: dropped
      # frames, encoder queue full, real-time buffer full. Progress stats
      # print at info level and would flood the rolling log, so stay one
      # level below that.
      args << "-hide_banner" << "-loglevel" << "warning" << "-stats" << "-y"
      # Parallelize the software convert+scale behind the capture thread.
      # Measured ~55 -> ~58fps headroom at 3440x1440 on RX 5600 XT.
      args << "-filter_threads" << "4"

      vw = Win32.get_system_metrics(78)
      vh = Win32.get_system_metrics(79)
      vw = Win32.get_system_metrics(0) if vw <= 0
      vh = Win32.get_system_metrics(1) if vh <= 0
      # Buffered video input: without this a busy game thread starves the
      # ddagrab reader and the vsync stage drops frames to catch up.
      args << "-thread_queue_size" << "512"
      args << "-f" << "lavfi"
      args << "-i" << "ddagrab=video_size=#{vw}x#{vh}:framerate=#{fps}:draw_mouse=1"

      # NOTE: audio is captured by a SEPARATE ffmpeg process (audio_args).
      # A combined A/V command drops ~5-8 video frames/s on this box even
      # though the encoder idles (q=4): the dshow audio clock drags the
      # vsync stage ("Past duration too large", frames arriving "late").
      # Proven by A/B: video-only = 0 drops/20s, same command + mapped
      # audio = ~100 drops/20s, across aresample/async/wallclock/dual-muxer
      # variants. Splitting removes the coupling by construction.

      enc = encoder_name
      vf_gpu = video_filter(enc, vw, vh)
      vf = vf_gpu[0]
      gpu = vf_gpu[1]
      if vf
        args << "-vf" << vf
      end

      args << "-c:v" << enc
      preset_args(enc).each { |a| args << a }
      args << "-b:v" << "#{@bitrate_kbps}k"
      args << "-g" << (fps * seg).to_s # one segment per GOP, so every boundary is a keyframe
      # -g alone is only a hint: AMF ultralowlatency ignores it (infinite
      # GOP, single seg_00000.ts that never rolls). Force an IDR every
      # segment so the segment muxer always has a split point, whatever the
      # encoder's GOP handling is.
      args << "-force_key_frames" << "expr:gte(t,n_forced*#{seg})"
      # GPU paths keep hardware frames (d3d11/qsv); forcing a software
      # pix_fmt would insert an impossible conversion or a silent
      # download. The CPU fallback path normalizes to yuv420p instead.
      if !gpu && !nvenc_encoder?(enc)
        args << "-pix_fmt" << "yuv420p"
      end

      args << "-f" << "segment"
      args << "-segment_time" << seg.to_s
      args << "-reset_timestamps" << "1"
      args << "-segment_format" << "mpegts"
      args << @segment_pat
      args
    end

    # Audio-only rolling capture. Runs as its own process so an audio device
    # clock can never stall the video vsync stage (see capture_args note).
    # Cuts on the same segment cadence so clip saves can tail-align the
    # two segment lists.
    #
    # Mini mixer: primary mic + up to N extra dshow devices + optional
    # loopback-capture device (Stereo Mix / VB-Cable output / Voicemeeter -
    # game / Discord / system output), mixed with amix into ONE aac stream
    # so the remux path below is unchanged.
    #
    # Everything is dshow: the vendored ffmpeg build has no wasapi demuxer
    # (and some system builds lack its loopback option, dying with
    # "Unrecognized option 'loopback'"), so wasapi inputs can never be
    # relied on. An empty mic_device means the system default mic resolved
    # to its dshow friendly name, NOT silence. An empty system device
    # (or capture_system_audio off) means mics only - plain speakers are
    # not capturable with this build.
    private def dshow_audio_input(name : String) : Array(String)
      # dshow parses audio=<name>; a stray double-quote in a friendly name
      # breaks the device match, so normalize it away. The whole token is
      # one argv element, so spaces need no quoting.
      safe = name.gsub('"', '\'')
      ["-thread_queue_size", "1024", "-f", "dshow", "-rtbufsize", "256M",
       "-i", "audio=#{safe}"]
    end

    # Probe for an ffmpeg demuxer (e.g. dshow). Guards against builds
    # compiled without it, which would otherwise die at spawn with
    # "Unknown input format".
    private def demuxer_supported?(name : String) : Bool
      begin
        buf = IO::Memory.new
        status = Process.run(@ffmpeg_path,
          ["-hide_banner", "-h", "demuxer=#{name}"],
          output: buf, error: buf)
        return false unless status.success?
        !buf.to_s.includes?("Unknown demuxer") && !buf.to_s.includes?("Unknown format")
      rescue
        false
      end
    end

    # Friendly name of the system default capture device (a dshow-usable
    # name), or nil when none can be determined.
    private def default_mic_name : String?
      name = win32_default_capture_name
      return nil if name.strip.empty?
      # Placeholders from the shim when no device exists.
      return nil if name.starts_with?("(")
      name
    rescue
      nil
    end

    private def audio_inputs(include_system : Bool) : Array({Array(String), Float64})
      inputs = [] of {Array(String), Float64}
      mic = @mic_device
      if mic && !mic.strip.empty?
        inputs << {dshow_audio_input(mic.strip), @mic_gain}
      elsif default_name = default_mic_name
        inputs << {dshow_audio_input(default_name), @mic_gain}
      end
      @extra_audio_devices.each do |d|
        name = d.strip
        next if name.empty?
        next if mic && !mic.strip.empty? && name.downcase == mic.strip.downcase
        inputs << {dshow_audio_input(name), 1.0}
      end
      if include_system && @capture_system_audio
        dev = @system_audio_device.strip
        if dev.empty?
          Log.warn { "audio: system audio ON but no source picked - recording mics only (pick a loopback capture device like Stereo Mix / VB-Cable output in Settings > Audio mixer)" }
        else
          inputs << {dshow_audio_input(dev), @system_gain}
        end
      end
      inputs
    end

    private def audio_cmd(inputs : Array({Array(String), Float64})) : Array(String)
      seg = @segment_seconds.not_nil!
      args = Array(String).new
      args << "-hide_banner" << "-loglevel" << "warning" << "-stats" << "-y"
      inputs.each { |in_args, _| in_args.each { |a| args << a } }

      if inputs.size == 1
        args << "-c:a" << "aac" << "-b:a" << "#{@audio_bitrate_kbps}k" << "-ar" << "44100" << "-ac" << "2"
      else
        # Normalize per-input (devices disagree on rate/layout) then apply
        # the mixer gain, then mix down to one stereo stream.
        parts = Array(String).new
        inputs.each_with_index do |(_, gain), i|
          g = gain.clamp(0.0, 2.0)
          parts << "[#{i}:a]aresample=44100,aformat=channel_layouts=stereo,volume=#{"%.3f" % g}[a#{i}]"
        end
        mix = inputs.each_index.map { |i| "[a#{i}]" }.join("")
        parts << "#{mix}amix=inputs=#{inputs.size}:duration=longest:dropout_transition=0:normalize=0[a]"
        args << "-filter_complex" << parts.join(";")
        args << "-map" << "[a]"
        args << "-c:a" << "aac" << "-b:a" << "#{@audio_bitrate_kbps}k" << "-ar" << "44100" << "-ac" << "2"
      end
      args << "-f" << "segment"
      args << "-segment_time" << seg.to_s
      args << "-reset_timestamps" << "1"
      args << "-segment_format" << "mpegts"
      args << @audio_pat
      args
    end

    private def audio_args(include_system : Bool = true) : Array(String)?
      return nil unless @capture_audio
      # dshow-only (see above): without it no audio input can work.
      unless demuxer_supported?("dshow")
        Log.error { "audio: ffmpeg has no dshow demuxer (#{@ffmpeg_path}) - audio disabled, video continues" }
        return nil
      end
      inputs = audio_inputs(include_system)
      if inputs.empty?
        Log.error { "audio: no mic device and no default capture device - audio disabled, video continues" }
        return nil
      end
      audio_cmd(inputs)
    end

    # Last lines of the audio ffmpeg log, for diagnosing a dead audio
    # process without opening another file.
    private def audio_log_tail(lines : Int32 = 8) : String
      path = File.join(@buffer_dir, "..", "logs", "ffmpeg.aud.log")
      return "(no log)" unless File.exists?(path)
      all = File.read_lines(path).map(&.strip).reject(&.empty?)
      all.last(lines).join(" | ")[0, 600]
    rescue
      "(unreadable log)"
    end

    # Spawns one audio ffmpeg process and watchdogs it: a bad device name
    # (or missing demuxer option, e.g. the old `-loopback` crash) exits
    # within milliseconds. Instead of leaving a dead process behind while
    # clips silently go quiet, report the log tail and return false so the
    # caller can fall back. The video process is never touched.
    private def start_audio_proc(acmd : Array(String), tag : String) : Bool
      Log.info { "spawn audio (#{tag}): #{@ffmpeg_path} #{acmd.join(" ")}" }
      aud_log = File.join(@buffer_dir, "..", "logs", "ffmpeg.aud.log")
      aud_io = File.new(aud_log, "w")
      @audio_err_io = aud_io
      proc = Process.new(@ffmpeg_path, acmd,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Close,
        error: aud_io)
      @audio_proc = proc
      # Bad inputs fail fast; a healthy rolling capture runs indefinitely.
      sleep 800.milliseconds
      if proc.terminated?
        begin
          aud_io.close
        rescue
        end
        @audio_err_io = nil
        @audio_proc = nil
        Log.error { "audio (#{tag}): ffmpeg exited at startup - #{audio_log_tail}" }
        return false
      end
      true
    rescue ex
      Log.error(exception: ex) { "audio (#{tag}): spawn failed" }
      begin
        @audio_err_io.try(&.close)
      rescue
      end
      @audio_err_io = nil
      @audio_proc = nil
      false
    end

    # Starts the rolling capture, clearing stale segments.
    def start_capture : Bool
      stop_capture

      FileUtils.mkdir_p(@buffer_dir)
      Dir.glob(File.join(@buffer_dir, "seg_*.ts").gsub('\\', '/')).each { |f| File.delete(f) rescue nil }
      Dir.glob(File.join(@buffer_dir, "aud_*.ts").gsub('\\', '/')).each { |f| File.delete(f) rescue nil }

      cmd = capture_args
      Log.info { "spawn: #{@ffmpeg_path} #{cmd.join(" ")}" }
      err_log = File.join(@buffer_dir, "..", "logs", "ffmpeg.out.log")
      FileUtils.mkdir_p(File.dirname(err_log))
      # Detached GUI process with no console: the inherited stdout handle is
      # invalid, so duplicating it for the child dies with DuplicateHandle.
      # ffmpeg at loglevel error writes diagnostics to stderr anyway.
      err_io = File.new(err_log, "w")
      @err_io = err_io
      @proc = Process.new(@ffmpeg_path, cmd,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Close,
        error: err_io)

      if acmd = audio_args(include_system: true)
        start_audio_proc(acmd, "full mix") || begin
          # A bad system-loopback name kills the whole mixer (one process).
          # Retry mics-only so a misconfigured loopback source degrades to
          # mic audio instead of silence.
          Log.warn { "audio: full mix failed, retrying mics-only" }
          if mcmd = audio_args(include_system: false)
            start_audio_proc(mcmd, "mics-only") || Log.error { "audio: mics-only mix failed too - clips will be video-only (see ffmpeg.aud.log)" }
          end
        end
      end
      true
    rescue ex
      Log.error(exception: ex) { "capture start failed" }
      begin
        @err_io.try(&.close)
      rescue
      end
      @err_io = nil
      begin
        @audio_err_io.try(&.close)
      rescue
      end
      @audio_err_io = nil
      false
    end

    def stop_capture
      p = @proc
      if p
        begin
          p.input.try(&.puts("q"))
        rescue
          nil
        end
        50.times do
          break if p.terminated?
          sleep 100.milliseconds
        end
        unless p.terminated?
          Win32.terminate_process(p.pid.to_u32)
          p.wait
        end
        @proc = nil
      end
      begin
        @err_io.try(&.close)
      rescue
      end
      @err_io = nil
      ap = @audio_proc
      if ap
        begin
          ap.input.try(&.puts("q"))
        rescue
          nil
        end
        50.times do
          break if ap.terminated?
          sleep 100.milliseconds
        end
        unless ap.terminated?
          Win32.terminate_process(ap.pid.to_u32)
          ap.wait
        end
        @audio_proc = nil
      end
      begin
        @audio_err_io.try(&.close)
      rescue
      end
      @audio_err_io = nil
    end

    def capture_running? : Bool
      p = @proc
      !p.nil? && !p.terminated?
    end

    def audio_running? : Bool
      ap = @audio_proc
      !ap.nil? && !ap.terminated?
    end

    # Audio segments tail-aligned to the video selection, or [] when audio
    # is unavailable/stale. Both processes cut every segment_seconds on
    # their own wallclock, so counts can differ by one at the edges; the
    # newest files cover the same window. A stale newest audio segment
    # (dead audio process) is rejected so clips never dub ancient audio
    # over fresh video.
    def aligned_audio_segments(video_count : Int32) : Array(String)
      return [] of String unless audio_running?
      return [] of String if video_count <= 0
      segs = Dir.glob(File.join(@buffer_dir, "aud_*.ts").gsub('\\', '/')).sort
      return [] of String if segs.empty?
      begin
        newest = File.info(segs.last).modification_time
        return [] of String if (Time.utc - newest) > (@segment_seconds * 2).seconds
      rescue
        return [] of String
      end
      n = Math.min(video_count, segs.size)
      segs.last(n)
    end

    def remux_segments(segments : Array(String), out_path : String, audio_segments : Array(String) = [] of String) : Bool
      return false if segments.empty?
      FileUtils.mkdir_p(File.dirname(out_path))

      args = [
        "-hide_banner", "-loglevel", "error",
      ] of String
      if audio_segments.empty?
        concat_name = if segments.size == 1
                        segments[0]
                      else
                        "concat:#{segments.join("|")}"
                      end
        args << "-i" << concat_name << "-map" << "0"
      else
        vname = segments.size == 1 ? segments[0] : "concat:#{segments.join("|")}"
        aname = audio_segments.size == 1 ? audio_segments[0] : "concat:#{audio_segments.join("|")}"
        args << "-i" << vname << "-i" << aname << "-map" << "0:v" << "-map" << "1:a"
      end
      args.concat(["-c", "copy", "-movflags", "+faststart", "-y", out_path])
      Log.info { "remux: spawning #{File.basename(@ffmpeg_path)} argcount=#{args.size} (audio=#{audio_segments.size} segs)" }

      # Same detached-process rule as start_capture: never Inherit.
      log = File.open(File.join(@buffer_dir, "..", "logs", "ffmpeg.out.log"), "a") rescue nil
      begin
        if log
          status = Process.run(@ffmpeg_path, args, output: log, error: log)
        else
          status = Process.run(@ffmpeg_path, args,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close)
        end
        Log.info { "remux: exit #{status.exit_code} success=#{status.success?}" }
        status.success?
      ensure
        begin
          log.try(&.close)
        rescue
        end
      end
    end

    def screenshot_frame(out_path : String) : Bool
      # Prefer GDI+ (no ffmpeg round trip for a single frame).
      return true if Win32.screenshot_to_png(out_path)

      args = [
        "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "ddagrab=framerate=30",
        "-frames:v", "1",
        "-y", out_path,
      ]
      log = File.open(File.join(@buffer_dir, "..", "logs", "ffmpeg.out.log"), "a") rescue nil
      begin
        if log
          Process.run(@ffmpeg_path, args, output: log, error: log).success?
        else
          Process.run(@ffmpeg_path, args,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close).success?
        end
      ensure
        begin
          log.try(&.close)
        rescue
        end
      end
    end
  end
end
