module Kirk
  # Reports the foreground app. Gameplay excludes the desktop and our own
  # windows; the title is logged alongside saved clips.
  class GameDetector
    struct ForegroundApp
      getter is_game : Bool
      getter name : String
      getter title : String
      getter pid : Int32

      def initialize(@is_game : Bool, @name : String, @title : String, @pid : Int32)
      end
    end

    NONGAME = {"explorer.exe", "kirk.exe", "dwm.exe"}

    def self.foreground : ForegroundApp
      hwnd = Win32.get_foreground_window
      pid = 0_u32
      Win32.get_window_thread_process_id(hwnd, pointerof(pid))

      title = ""
      if hwnd
        buf = Slice(Win32::WCHAR).new(512)
        n = Win32.get_window_text(hwnd, buf, 512)
        title = Win32.wstr_to_string(buf.to_unsafe) if n > 0
      end

      name = executable_name(pid)
      ForegroundApp.new(
        is_game: !NONGAME.includes?(name.downcase),
        name: name,
        title: title,
        pid: pid.to_i32,
      )
    end

    private def self.executable_name(pid : UInt32) : String
      return "" if pid == 0
      access = 0x1000_u32
      handle = Win32.open_process(access, false, pid)
      return "" if handle.nil?
      buf = Slice(Win32::WCHAR).new(1024)
      n = 1024_u32
      ok = Win32.query_full_process_image_name(handle, 0_u32, buf.to_unsafe, pointerof(n))
      Win32.close_handle(handle)
      return "" if ok == 0
      path = Win32.wstr_to_string(buf.to_unsafe)
      File.basename(path)
    end
  end
end
