require "log"

module Kirk
  # Enforces the max clip-folder size by removing the oldest finished clips.
  class StorageManager
    getter dir : String

    def initialize(@dir, @limit_gb : Int32)
      Dir.mkdir_p(@dir)
    end

    def clips
      Dir.glob(File.join(@dir, "*.mp4")).sort
    end

    def used_bytes : Int64
      clips.sum { |f| File.size(f) rescue 0_i64 }
    end

    def bytes_to_delete : Int64
      used = used_bytes
      limit = @limit_gb.to_i64 * 1024 * 1024 * 1024
      used > limit ? used - limit : 0_i64
    end

    # Delete oldest clips until under the limit. Returns count deleted.
    def prune : Int32
      deleted = 0
      loop do
        need = bytes_to_delete
        break if need <= 0
        oldest = clips.first?
        break unless oldest
        File.delete(oldest) rescue nil
        deleted += 1
        Log.info { "storage: removed #{File.basename(oldest)}" }
      end
      deleted
    end
  end
end
