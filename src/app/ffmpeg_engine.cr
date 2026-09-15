require "process"
require "log"
require "file_utils"

module Kirk
  # Drives ffmpeg: one long-lived capture into keyframe-aligned MPEG-TS
  # segments, plus short `-c copy` remuxes when a clip is saved.
  class FFmpegEngine
    getter buffer_dir : String
    getter segment_pat : String
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

    @proc : Process?
    @err_io : File?
    @resolved_encoder : String? = nil

    def initialize(@buffer_dir)
      @segment_pat = File.join(@buffer_dir, "seg_%05d.ts")
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
      @resolved_encoder = nil
    end

    def cycle_segments : Int32
      (@replay_seconds.not_nil! // @segment_seconds.not_nil!) + 2
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
    # x264 have their own preset names — so a raw passthrough only ever
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
        extra << "-quality" << q << "-rc" << "cbr" << "-usage" << "ultralowlatency"
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

    # Builds the -vf chain: mandatory hwdownload for every non-NVENC encoder
    # (AMF rejects d3d11 input with SubmitInput error 18, measured) plus an
    # optional downscale when max_width/max_height are set. The scale keeps
    # aspect ratio and forces even dimensions for yuv420p.
    private def video_filter(enc : String) : String?
      parts = Array(String).new
      needs_download = !nvenc_encoder?(enc)
      parts << "hwdownload" << "format=bgra" if needs_download

      mw = @max_width
      mh = @max_height
      if (mw && mw > 0) || (mh && mh > 0)
        if mw && mw > 0 && mh && mh > 0
          parts << "scale=w=#{mw}:h=#{mh}:force_original_aspect_ratio=decrease:flags=bilinear"
          parts << "scale=ceil(iw/2)*2:ceil(ih/2)*2"
        elsif mw && mw > 0
          parts << "scale=w='min(iw\\,#{mw})':h=-2:flags=bilinear"
        else
          parts << "scale=w=-2:h='min(ih\\,#{mh})':flags=bilinear"
        end
        # NVENC takes d3d11 frames zero-copy; once we download+scale the
        # frames are software, so normalize the pixel format in-filter
        # instead of via -pix_fmt (which would be a second conversion).
        parts << "format=yuv420p" if nvenc_encoder?(enc)
      end

      return nil if parts.empty?
      parts.join(",")
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

      vw = Win32.get_system_metrics(78)
      vh = Win32.get_system_metrics(79)
      vw = Win32.get_system_metrics(0) if vw <= 0
      vh = Win32.get_system_metrics(1) if vh <= 0
      args << "-f" << "lavfi"
      args << "-i" << "ddagrab=video_size=#{vw}x#{vh}:framerate=#{fps}:draw_mouse=1"

      if @capture_audio
        device = @mic_device
        if device && !device.empty?
          # Buffered dshow input: without these a busy game thread starves
          # the mic reader and ffmpeg aborts with "real-time buffer full".
          args << "-thread_queue_size" << "512" << "-f" << "dshow" << "-rtbufsize" << "256M" << "-i" << "audio=#{device}"
        end
      end

      enc = encoder_name
      if vf = video_filter(enc)
        args << "-vf" << vf
      end

      args << "-c:v" << enc
      preset_args(enc).each { |a| args << a }
      args << "-b:v" << "#{@bitrate_kbps}k"
      args << "-g" << (fps * seg).to_s # one segment per GOP, so every boundary is a keyframe
      # NVENC consumes the ddagrab d3d11 frames directly; forcing a software
      # pix_fmt would insert an impossible d3d11->yuv420p conversion.
      # (When scaling with NVENC the filter chain already ends in
      # format=yuv420p, so no -pix_fmt is needed there either.)
      if !nvenc_encoder?(enc)
        args << "-pix_fmt" << "yuv420p"
      end

      if @capture_audio && @mic_device && !@mic_device.empty?
        args << "-c:a" << "aac" << "-b:a" << "#{@audio_bitrate_kbps}k" << "-ar" << "44100" << "-ac" << "2"
      end

      args << "-f" << "segment"
      args << "-segment_time" << seg.to_s
      args << "-reset_timestamps" << "1"
      args << "-segment_format" << "mpegts"
      args << @segment_pat
      args
    end

    # Starts the rolling capture, clearing stale segments.
    def start_capture : Bool
      stop_capture

      FileUtils.mkdir_p(@buffer_dir)
      Dir.glob(File.join(@buffer_dir, "seg_*.ts").gsub('\\', '/')).each { |f| File.delete(f) rescue nil }

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
      true
    rescue ex
      Log.error(exception: ex) { "capture start failed" }
      begin
        @err_io.try(&.close)
      rescue
      end
      @err_io = nil
      false
    end

    def stop_capture
      p = @proc
      return unless p
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
      begin
        @err_io.try(&.close)
      rescue
      end
      @err_io = nil
    end

    def capture_running? : Bool
      p = @proc
      !p.nil? && !p.terminated?
    end

    def remux_segments(segments : Array(String), out_path : String) : Bool
      return false if segments.empty?
      FileUtils.mkdir_p(File.dirname(out_path))

      concat_name = if segments.size == 1
                      segments[0]
                    else
                      "concat:#{segments.join("|")}"
                    end

      args = [
        "-hide_banner", "-loglevel", "error",
        "-i", concat_name,
        "-map", "0",
        "-c", "copy",
        "-movflags", "+faststart",
        "-y", out_path,
      ]
      Log.info { "remux: spawning #{File.basename(@ffmpeg_path)} argcount=#{args.size}" }

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
