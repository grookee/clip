require "log"
require "file_utils"

module Kirk
  # On-disk rolling replay buffer of MPEG-TS segments. The newest file is
  # still being written, so clip saves use everything before it.
  class BufferManager
    getter dir : String

    def initialize(@dir, @capacity : Int32)
      FileUtils.mkdir_p(@dir)
    end

    def capacity=(v : Int32)
      @capacity = v
    end

    def segments : Array(String)
      # Dir.glob mishandles Windows backslashes; always glob with forward slashes.
      Dir.glob(File.join(@dir, "seg_*.ts").gsub('\\', '/')).sort
    end

    # Everything except the newest entry, which ffmpeg may still be writing.
    def safe_segments : Array(String)
      s = segments
      s.size <= 1 ? [] of String : s[0..-2]
    end

    # Remove files that fall outside the replay window. Returns the count
    # of pruned files.
    def prune : Int32
      s = segments
      excess = s.size - @capacity
      return 0 if excess <= 0
      s[0...excess].each do |f|
        File.delete(f) rescue nil
        Log.debug { "pruned segment #{File.basename(f)}" }
      end
      excess
    end
  end
end
