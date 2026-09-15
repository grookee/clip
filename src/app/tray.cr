require "log"

module Kirk
  # System tray icon via Shell_NotifyIconW. Never memoize a pointer to a struct
  # being mutated; every Shell call builds a fresh NOTIFYICONDATAW.
  class TrayIcon
    alias MenuHandler = (String) -> Void

    NIM_ADD        =          0_u32
    NIM_MODIFY     =          1_u32
    NIM_DELETE     =          2_u32
    NIF_MESSAGE    = 0x00000001_u32
    NIF_ICON       = 0x00000002_u32
    NIF_TIP        = 0x00000004_u32
    NIF_INFO       = 0x00000010_u32
    NIF_STATE      = 0x00000008_u32
    WM_CONTEXTMENU =     0x007B_u32
    WM_RBUTTONUP   =     0x0205_u32
    TPM_RETURNCMD  =     0x0100_u32

    getter? created : Bool = false

    def initialize(@hwnd : Void*, @callback_message : UInt32, @menu_handler : MenuHandler)
    end

    def add : Bool
      n = nid
      result = Win32.shell_notify_icon(NIM_ADD, pointerof(n))
      @created = result != 0
      Log.info { "tray icon added: #{@created}" }
      @created
    end

    def remove
      return unless @created
      n = nid
      Win32.shell_notify_icon(NIM_DELETE, pointerof(n))
      @created = false
    end

    # Swaps only the hover tooltip, so a dead engine is visible without a popup.
    def set_tip(tip : String)
      return unless @created
      n = nid(tip)
      Win32.shell_notify_icon(NIM_MODIFY, pointerof(n))
    end

    def balloon(title : String, body : String)
      return unless @created
      n = Win32::NOTIFYICONDATAW.new
      n.n_cb_size = sizeof(Win32::NOTIFYICONDATAW).to_u32
      n.n_owner = @hwnd
      n.n_u_id = 1_u32
      n.n_u_flags = NIF_INFO | NIF_ICON
      n.n_info_flags = 1_u32 # NIIF_INFO

      t = title.to_utf16
      title_arr = StaticArray(Win32::WCHAR, 64).new(0_u16)
      nt = Math.min(t.size, 63)
      title_arr.to_unsafe.copy_from(t.to_unsafe, nt)
      title_arr[nt] = 0_u16
      n.n_info_title = title_arr

      b = body.to_utf16
      body_arr = StaticArray(Win32::WCHAR, 256).new(0_u16)
      nb = Math.min(b.size, 255)
      body_arr.to_unsafe.copy_from(b.to_unsafe, nb)
      body_arr[nb] = 0_u16
      n.n_info = body_arr

      Win32.shell_notify_icon(NIM_MODIFY, pointerof(n))
    end

    def handle_callback(hwnd : Void*, wp : Win32::WPARAM, lp : Win32::LPARAM) : Bool
      msg = lp.to_u32 & 0xFFFF
      case msg
      when WM_CONTEXTMENU, WM_RBUTTONUP
        show_menu(hwnd)
        return true
      end
      false
    end

    private def show_menu(hwnd : Void*)
      menu = Win32.create_popup_menu
      return if menu.null?

      actions = [
        {"Open Clips Folder", 1_u32},
        {"Open Buffer Folder", 2_u32},
        {"-----", 0_u32},
        {"Settings...", 3_u32},
        {"-----", 0_u32},
        {"Quit kirk", 9_u32},
      ]

      actions.each do |label, id|
        if label == "-----"
          Win32.append_menu(menu, 0x0800_u32, 0_u32, nil) # MF_SEPARATOR
        else
          widi = Win32.string_to_wstring(label)
          Win32.append_menu(menu, 0x0000_u32, id, widi) # MF_STRING
        end
      end

      pt = Win32::POINT.new
      Win32.get_cursor_pos(pointerof(pt))
      Win32.set_foreground_window(hwnd) # TrackPopupMenu requires this
      cmd = Win32.track_popup_menu(menu, TPM_RETURNCMD, pt.x, pt.y, 0, hwnd)
      Win32.destroy_menu(menu)
      case cmd.to_u32
      when 1 then @menu_handler.call("clips")
      when 2 then @menu_handler.call("buffer")
      when 3 then @menu_handler.call("settings")
      when 9 then @menu_handler.call("quit")
      end
    end

    # Crystal copies struct members on read, so UTF-16 fields are assembled in
    # local StaticArrays and assigned whole via their setters.
    private def nid(tip_text : String = "kirk") : Win32::NOTIFYICONDATAW
      n = Win32::NOTIFYICONDATAW.new
      n.n_cb_size = sizeof(Win32::NOTIFYICONDATAW).to_u32
      n.n_owner = @hwnd
      n.n_u_id = 1_u32
      n.n_u_flags = NIF_MESSAGE | NIF_ICON | NIF_TIP
      n.n_u_callback = @callback_message
      n.n_icon = Win32.app_icon

      tip = tip_text.to_utf16
      arr = StaticArray(Win32::WCHAR, 128).new(0_u16)
      nchars = Math.min(tip.size, 127)
      arr.to_unsafe.copy_from(tip.to_unsafe, nchars)
      arr[nchars] = 0_u16
      n.n_tip = arr
      n
    end
  end
end
