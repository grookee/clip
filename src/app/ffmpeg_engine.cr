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

    private def capture_args : Array(String)
      seg = @segment_seconds.not_nil!
      fps = @fps.not_nil!

      args = Array(String).new
      args << "-hide_banner" << "-loglevel" << "error" << "-y"

      vw = Win32.get_system_metrics(78)
      vh = Win32.get_system_metrics(79)
      vw = Win32.get_system_metrics(0) if vw <= 0
      vh = Win32.get_system_metrics(1) if vh <= 0
      args << "-f" << "lavfi"
      args << "-i" << "ddagrab=video_size=#{vw}x#{vh}:framerate=#{fps}:draw_mouse=1"

      if @capture_audio
        device = @mic_device
        if device && !device.empty?
          args << "-f" << "dshow" << "-i" << "audio=#{device}"
        end
      end

      # ddagrab yields d3d11 hardware frames. Only NVENC consumes them
      # directly; AMF rejects d3d11 input (SubmitInput error 18, measured),
      # so every other encoder downloads to system memory first (bgr0, the
      # only format d3d11 download supports) and auto-scales from there.
      enc = encoder_name
      if enc != "h264_nvenc" && enc != "hevc_nvenc" && enc != "av1_nvenc"
        args << "-vf" << "hwdownload,format=bgra"
      end

      args << "-c:v" << enc
      case enc
      when "libx264", "libx265"
        args << "-preset" << "veryfast"
      end
      args << "-b:v" << "#{@bitrate_kbps}k"
      args << "-g" << (fps * seg).to_s # one segment per GOP, so every boundary is a keyframe
      # NVENC consumes the ddagrab d3d11 frames directly; forcing a software
      # pix_fmt would insert an impossible d3d11->yuv420p conversion.
      if enc != "h264_nvenc" && enc != "hevc_nvenc" && enc != "av1_nvenc"
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
