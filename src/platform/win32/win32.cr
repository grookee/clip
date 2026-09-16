# Plain C-callable Win32 API - no COM vtable calls. COM-heavy subsystems
# (WASAPI enumerate, SAPI voice) live in the shim DLL.

module Win32
  alias WCHAR = UInt16
  alias BOOL = LibC::Int
  alias DWORD = UInt32
  alias HANDLE = Void*
  alias HWND = Void*
  alias HMODULE = Void*
  alias LRESULT = LibC::IntPtrT
  alias WPARAM = LibC::UIntPtrT
  alias LPARAM = LibC::IntPtrT

  @[Link("ole32")]
  lib Ole32
    fun CoInitializeEx(pvReserved : Void*, dwCoInit : DWORD) : Int32
    fun CoUninitialize : Void
  end

  def self.ole_initialize(mode : DWORD) : Int32
    Ole32.CoInitializeEx(nil, mode)
  end

  def self.ole_uninitialize
    Ole32.CoUninitialize
  end

  @[Link("kernel32")]
  lib Kernel32
    fun GetModuleFileNameW(h : HMODULE, buf : WCHAR*, size : DWORD) : DWORD
    fun GetModuleHandleW(name : WCHAR*) : HMODULE
    fun GetLocalTime(t : Void*)
    fun QueryFullProcessImageNameW(process : HANDLE, flags : DWORD, buf : WCHAR*, size : DWORD*) : BOOL
    fun OpenProcess(access : DWORD, inherit : BOOL, pid : DWORD) : HANDLE
    fun TerminateProcess(process : HANDLE, exit_code : DWORD) : BOOL
    fun CloseHandle(h : HANDLE) : BOOL
    fun FormatMessageW(flags : DWORD, source : Void*, id : DWORD, lang : DWORD, buf : WCHAR*, size : DWORD, args : Void*) : DWORD
    fun GetLastError : DWORD
    fun GetTickCount64 : UInt64
    fun FreeConsole : BOOL
    fun Sleep(ms : DWORD) : Void
    fun CreateMutexW(attr : Void*, owner : BOOL, name : WCHAR*) : HANDLE
  end

  struct SYSTEMTIME
    property year : UInt16 = 0_u16
    property month : UInt16 = 0_u16
    property day_of_week : UInt16 = 0_u16
    property day : UInt16 = 0_u16
    property hour : UInt16 = 0_u16
    property minute : UInt16 = 0_u16
    property second : UInt16 = 0_u16
    property milliseconds : UInt16 = 0_u16
  end

  @[Link("user32")]
  lib User32
    alias WNDPROC = (HWND, UInt32, WPARAM, LPARAM) -> LRESULT

    # Lives inside `lib` so the layout matches the C WNDCLASSW (module-level
    # structs pack extra padding).
    struct WNDCLASSW
      style : UInt32
      lpfn_wnd_proc : WNDPROC
      cb_cls_extra : LibC::Int
      cb_wnd_extra : LibC::Int
      h_instance : HMODULE
      h_icon : Void*
      h_cursor : Void*
      h_bg : Void*
      lpsz_menu : WCHAR*
      lpsz_class_name : WCHAR*
    end

    fun RegisterClassW(wc : Void*) : UInt16
    fun CreateWindowExW(ex : DWORD, class_name : WCHAR*, window_name : WCHAR*,
                        style : DWORD, x : LibC::Int, y : LibC::Int, w : LibC::Int, h : LibC::Int,
                        parent : HWND, menu : Void*, instance : HMODULE, param : Void*) : HWND
    fun DestroyWindow(h : HWND) : BOOL
    fun DefWindowProcW(h : HWND, msg : UInt32, w : WPARAM, l : LPARAM) : LRESULT
    fun GetMessageW(msg : Void*, h : HWND, filter_min : UInt32, filter_max : UInt32) : BOOL
    fun PeekMessageW(msg : Void*, h : HWND, filter_min : UInt32, filter_max : UInt32, remove : UInt32) : BOOL
    fun TranslateMessage(msg : Void*) : BOOL
    fun DispatchMessageW(msg : Void*) : LRESULT
    fun PostQuitMessage(code : LibC::Int) : Void
    fun PostMessageW(h : HWND, msg : UInt32, w : WPARAM, l : LPARAM) : BOOL
    fun RegisterHotKey(h : HWND, id : LibC::Int, modifiers : DWORD, vk : UInt32) : BOOL
    fun UnregisterHotKey(h : HWND, id : LibC::Int) : BOOL
    fun SetTimer(h : HWND, id : UInt64, elapse : DWORD, proc : Void*) : UInt64
    fun KillTimer(h : HWND, id : UInt64) : BOOL
    fun GetWindowThreadProcessId(h : HWND, pid : DWORD*) : DWORD
    fun GetForegroundWindow : HWND
    fun GetConsoleWindow : HWND
    fun IsWindow(h : HWND) : BOOL
    fun GetSystemMetrics(idx : LibC::Int) : LibC::Int
    fun GetDC(h : HWND) : Void*
    fun ReleaseDC(h : HWND, dc : Void*) : LibC::Int
    fun MessageBoxW(owner : HWND, text : WCHAR*, caption : WCHAR*, type_ : UInt32) : LibC::Int
    fun ShowWindow(h : HWND, cmd : LibC::Int) : BOOL
    fun UpdateWindow(h : HWND) : BOOL
    fun SetWindowPos(h : HWND, after : HWND, x : LibC::Int, y : LibC::Int, w : LibC::Int, height : LibC::Int, flags : UInt32) : BOOL
    fun SetForegroundWindow(h : HWND) : BOOL
    fun LoadCursorW(instance : HMODULE, name : WCHAR*) : Void*
    fun LoadIconW(instance : HMODULE, name : WCHAR*) : Void*
    fun GetStockObject(idx : LibC::Int) : Void*
    fun EnumWindows(proc : WNDPROC_ENUM, l_param : LPARAM) : BOOL
    fun GetWindowTextW(h : HWND, buf : WCHAR*, size : LibC::Int) : LibC::Int
    fun GetClassNameW(h : HWND, buf : WCHAR*, size : LibC::Int) : LibC::Int
    fun CreatePopupMenu : Void*
    fun AppendMenuW(menu : Void*, flags : UInt32, id : LibC::UIntPtrT, item : WCHAR*) : BOOL
    fun TrackPopupMenu(menu : Void*, flags : UInt32, x : LibC::Int, y : LibC::Int, reserved : LibC::Int, h : HWND, rect : Void*) : BOOL
    fun DestroyMenu(menu : Void*) : BOOL
    fun GetCursorPos(pt : Void*) : BOOL
  end

  struct POINT
    property x : Int32 = 0
    property y : Int32 = 0
  end

  struct MSG
    hwnd : HWND
    message : UInt32
    w_param : WPARAM
    l_param : LPARAM
    time : DWORD
    pt_x : Int32
    pt_y : Int32
    private_data : DWORD
  end

  alias WNDPROC_ENUM = (HWND, LPARAM) -> BOOL

  enum CommonMessages : UInt32
    HotkeyBase = 0x0400
  end

  def self.register_hotkey(hwnd : HWND, id : Int32, mods : UInt32, vk : UInt32) : Bool
    User32.RegisterHotKey(hwnd, id, mods, vk) != 0
  end

  def self.get_last_error_message : String
    buf = Slice(WCHAR).new(512)
    n = Kernel32.FormatMessageW(0x00001000_u32, nil, Kernel32.GetLastError, 0, buf, 512, nil)
    return "unknown error" if n == 0
    String.from_utf16(Slice.new(buf.to_unsafe, n.to_i32)).strip
  end

  # Claims a session-local named mutex held for the life of the process.
  # Returns false when another kirk instance already holds it
  # (GetLastError 183). The handle is intentionally never closed; the OS
  # releases it on process exit, so a crashed predecessor never wedges us.
  def self.claim_single_instance(name : String) : Bool
    h = Kernel32.CreateMutexW(nil, 1_i32, to_wstr(name))
    return false if h.null?
    Kernel32.GetLastError != 183_u32
  end

  def self.wstr_to_string(ptr : WCHAR*) : String
    return "" if ptr.null?
    len = 0
    while ptr[len] != 0
      len += 1
    end
    String.from_utf16(Slice.new(ptr, len))
  end

  # Copies s as null-terminated UTF-16 for Win32 calls. String#to_utf16
  # has NO terminator, so passing its .to_unsafe directly over-reads into
  # heap garbage (tray menu CJK suffixes, flaky voice grammar/screenshot
  # paths). The copy is GC-managed and outlives the call.
  def self.to_wstr(s : String) : WCHAR*
    u16 = s.to_utf16
    ptr = Pointer(WCHAR).malloc(u16.size + 1)
    ptr.copy_from(u16.to_unsafe, u16.size)
    ptr[u16.size] = 0_u16
    ptr
  end

  def self.string_to_wstring(s : String) : WCHAR*
    to_wstr(s)
  end

  def self.dup_string(ptr : WCHAR*) : String
    wstr_to_string(ptr)
  end

  def self.executable_path : String
    buf = Slice(WCHAR).new(4096)
    n = Kernel32.GetModuleFileNameW(nil, buf, 4096)
    String.from_utf16(Slice.new(buf.to_unsafe, n.to_i32))
  end

  def self.get_system_metrics(idx : LibC::Int) : LibC::Int
    User32.GetSystemMetrics(idx)
  end

  def self.get_foreground_window : HWND
    User32.GetForegroundWindow
  end

  # Hides an inherited console so kirk presents purely as a GUI/tray app.
  def self.detach_console
    User32.ShowWindow(User32.GetConsoleWindow, 0)
    Kernel32.FreeConsole
  end

  def self.get_window_thread_process_id(h : HWND, pid : DWORD*)
    User32.GetWindowThreadProcessId(h, pid)
  end

  def self.get_window_text(h : HWND, buf : Slice(WCHAR), n : LibC::Int) : LibC::Int
    User32.GetWindowTextW(h, buf.to_unsafe, n)
  end

  def self.open_process(access : DWORD, inherit : Bool, pid : DWORD) : HANDLE
    Kernel32.OpenProcess(access, inherit ? 1_i32 : 0_i32, pid)
  end

  PROCESS_TERMINATE = 0x0001_u32

  def self.terminate_process(pid : DWORD) : Bool
    h = Kernel32.OpenProcess(PROCESS_TERMINATE, 0_i32, pid)
    return false if h.null?
    ok = Kernel32.TerminateProcess(h, 1_u32)
    Kernel32.CloseHandle(h)
    ok != 0_i32
  end

  def self.set_foreground_window(h : HWND) : Bool
    User32.SetForegroundWindow(h) != 0
  end

  def self.query_full_process_image_name(h : HANDLE, flags : DWORD, buf : WCHAR*, size : DWORD*) : BOOL
    Kernel32.QueryFullProcessImageNameW(h, flags, buf, size)
  end

  def self.close_handle(h : HANDLE) : BOOL
    Kernel32.CloseHandle(h)
  end

  def self.get_tick_count64 : UInt64
    Kernel32.GetTickCount64
  end

  def self.get_module_handle : HMODULE
    Kernel32.GetModuleHandleW(nil)
  end

  def self.load_cursor(instance : HMODULE, id : UInt32) : Void*
    User32.LoadCursorW(instance, Pointer(WCHAR).new(id.to_u64))
  end

  def self.register_class(wc : User32::WNDCLASSW*) : UInt16
    User32.RegisterClassW(wc.as(Void*))
  end

  def self.create_window(instance : HMODULE, class_name : WCHAR*, x : Int32, y : Int32, w : Int32, h : Int32) : HWND
    User32.CreateWindowExW(0, class_name, nil, 0, x, y, w, h,
      nil, nil, instance, nil)
  end

  def self.get_message(msg : MSG*, h : HWND, min : UInt32, max : UInt32) : LibC::Int
    User32.GetMessageW(msg.as(Void*), h, min, max)
  end

  def self.translate_message(msg : MSG*) : Bool
    User32.TranslateMessage(msg.as(Void*)) != 0
  end

  def self.dispatch_message(msg : MSG*) : LRESULT
    User32.DispatchMessageW(msg.as(Void*))
  end

  def self.def_window_proc(h : HWND, msg : UInt32, w : WPARAM, l : LPARAM) : LRESULT
    User32.DefWindowProcW(h, msg, w, l)
  end

  def self.post_quit_message(code : Int32)
    User32.PostQuitMessage(code)
  end

  def self.post_message(h : HWND, msg : UInt32, w : WPARAM, l : LPARAM) : Bool
    User32.PostMessageW(h, msg, w, l) != 0
  end

  def self.set_timer(h : HWND, id : LibC::UIntPtrT, elapse : UInt32) : LibC::UIntPtrT
    User32.SetTimer(h, id, elapse, nil)
  end

  def self.kill_timer(h : HWND, id : LibC::UIntPtrT) : Bool
    User32.KillTimer(h, id) != 0
  end

  def self.unregister_hotkey(h : HWND, id : Int32) : Bool
    User32.UnregisterHotKey(h, id) != 0
  end

  def self.destroy_window(h : HWND) : Bool
    User32.DestroyWindow(h) != 0
  end

  def self.open_folder(path : String)
    Shell32.ShellExecuteW(nil, to_wstr("open"), to_wstr(path), nil, nil, 1)
  end

  # Opens a Windows Settings page (e.g. "ms-settings:speech"). Best-effort:
  # returns the ShellExecute result code, callers log and move on.
  def self.open_settings_page(page : String)
    Shell32.ShellExecuteW(nil, to_wstr("open"), to_wstr(page), nil, nil, 1)
  end

  MB_YESNO       = 0x04_u32
  MB_ICONWARNING = 0x30_u32
  IDYES          =        6

  # Blocking Yes/No prompt. Safe to call from the main/UI thread; do not call
  # from inside a WndProc re-entrancy-sensitive path more than once per event
  # (callers gate with a shown-once flag).
  def self.confirm_dialog(owner : HWND, caption : String, text : String) : Bool
    User32.MessageBoxW(owner, to_wstr(text), to_wstr(caption), MB_YESNO | MB_ICONWARNING) == IDYES
  end

  def self.timestamp : String
    t = SYSTEMTIME.new
    Kernel32.GetLocalTime(pointerof(t).as(Void*))
    "#{t.year.to_s.rjust(4, '0')}#{t.month.to_s.rjust(2, '0')}#{t.day.to_s.rjust(2, '0')}-#{t.hour.to_s.rjust(2, '0')}#{t.minute.to_s.rjust(2, '0')}#{t.second.to_s.rjust(2, '0')}"
  end

  @[Link("shell32")]
  lib Shell32
    fun Shell_NotifyIconW(msg : DWORD, data : Void*) : BOOL
    fun ShellExecuteW(hwnd : Void*, op : WCHAR*, file : WCHAR*, params : WCHAR*, dir : WCHAR*, show : LibC::Int) : LibC::IntPtrT
  end

  struct NOTIFYICONDATAW
    property n_cb_size : DWORD = 0_u32
    property n_owner : HWND = Pointer(Void).null
    property n_u_id : DWORD = 0_u32
    property n_u_flags : DWORD = 0_u32
    property n_u_callback : DWORD = 0_u32
    property n_icon : Void* = Pointer(Void).null
    property n_tip : StaticArray(WCHAR, 128) = StaticArray(UInt16, 128).new(0_u16)
    property n_state : DWORD = 0_u32
    property n_state_mask : DWORD = 0_u32
    property n_info : StaticArray(WCHAR, 256) = StaticArray(UInt16, 256).new(0_u16)
    property n_timeout : DWORD = 0_u32
    property n_info_title : StaticArray(WCHAR, 64) = StaticArray(UInt16, 64).new(0_u16)
    property n_info_flags : DWORD = 0_u32
    property n_guid : StaticArray(UInt8, 16) = StaticArray(UInt8, 16).new(0_u8)
    property n_balloon_icon : Void* = Pointer(Void).null
  end

  def self.shell_notify_icon(msg : DWORD, nid : NOTIFYICONDATAW*) : Bool
    Shell32.Shell_NotifyIconW(msg, nid.as(Void*)) != 0
  end

  IDI_APPLICATION = 32512_u32

  # Kirk's own icon resource id (see native icon wiring in scripts/build.ps1).
  KIRK_ICON_ID = 1_u64

  # The exe's own icon so the tray shows the same mark as the title bar and
  # taskbar. Falls back to the system icon when the binary carries no icon
  # resource.
  def self.app_icon : Void*
    icon = User32.LoadIconW(get_module_handle, Pointer(WCHAR).new(KIRK_ICON_ID))
    return icon unless icon.null?
    User32.LoadIconW(nil, Pointer(WCHAR).new(IDI_APPLICATION.to_u64))
  end

  def self.create_popup_menu : Void*
    User32.CreatePopupMenu
  end

  def self.append_menu(menu : Void*, flags : UInt32, id : UInt32, item : WCHAR*?) : Bool
    User32.AppendMenuW(menu, flags, id.to_u64, item) != 0
  end

  def self.get_cursor_pos(pt : POINT*) : Bool
    User32.GetCursorPos(pt.as(Void*)) != 0
  end

  def self.track_popup_menu(menu : Void*, flags : UInt32, x : Int32, y : Int32, reserved : Int32, h : HWND) : Int32
    User32.TrackPopupMenu(menu, flags, x, y, reserved, h, nil)
  end

  def self.destroy_menu(menu : Void*) : Bool
    User32.DestroyMenu(menu) != 0
  end

  @[Link("winmm")]
  lib WinMM
    fun PlaySoundW(sound : WCHAR*, mod : HANDLE, flags : DWORD) : BOOL
  end

  SND_ASYNC     =     0x0001_u32
  SND_NODEFAULT =     0x0002_u32
  SND_FILENAME  = 0x00020000_u32

  # Fire-and-forget chime for clip saves. Best-effort: a missing file just
  # means silence, never an exception on the caller.
  def self.play_sound_file(path : String) : Bool
    return false if path.strip.empty?
    return false unless File.exists?(path)
    WinMM.PlaySoundW(to_wstr(path), Pointer(Void).null, SND_FILENAME | SND_ASYNC | SND_NODEFAULT) != 0
  rescue
    false
  end

  # Locates the bundled clip chime. Prefers the exe directory (installed /
  # staged layout), then the repo/dev layout, then %LOCALAPPDATA%\kirk.
  def self.clip_sound_path : String?
    ["clip.wav", "assets/clip.wav"].each do |rel|
      begin
        exe = executable_path
        unless exe.empty?
          p = File.join(File.dirname(exe), rel)
          return p if File.exists?(p)
        end
      rescue
      end
      return rel if File.exists?(rel)
    end
    begin
      local = ENV["LOCALAPPDATA"]? || ENV["USERPROFILE"]?
      if local
        p = File.join(local, "kirk", "clip.wav")
        return p if File.exists?(p)
      end
    rescue
    end
    nil
  end

  def self.play_clip_sound : Bool
    if p = clip_sound_path
      play_sound_file(p)
    else
      false
    end
  end

  @[Link("gdi32")]
  lib Gdi32
    fun CreateCompatibleDC(hdc : Void*) : Void*
    fun CreateCompatibleBitmap(hdc : Void*, w : LibC::Int, h : LibC::Int) : Void*
    fun BitBlt(dest : Void*, x : LibC::Int, y : LibC::Int, w : LibC::Int, h : LibC::Int,
               src : Void*, sx : LibC::Int, sy : LibC::Int, rop : UInt32) : BOOL
    fun SelectObject(hdc : Void*, obj : Void*) : Void*
    fun DeleteDC(hdc : Void*) : Bool
    fun DeleteObject(obj : Void*) : Bool
  end

  @[Link("gdiplus")]
  lib GdiPlus
    fun GdiplusStartup(token : UInt64*, input : Void*, output : Void*) : Int32
    fun GdiplusShutdown(token : UInt64)
    fun GdipCreateBitmapFromHBITMAP(hbm : Void*, hpal : Void*, bitmap : Void**) : Int32
    fun GdipDisposeImage(image : Void*) : Int32
    fun GdipSaveImageToFile(image : Void*, filename : WCHAR*, clsid : UInt8*, encoder_params : Void*) : Int32
    fun GdipGetImageEncodersSize(num : UInt32*, size : UInt32*) : Int32
    fun GdipGetImageEncoders(num : UInt32, size : UInt32, encoders : UInt8*) : Int32
    fun GdipGetImageWidth(image : Void*, width : UInt32*) : Int32
    fun GdipGetImageHeight(image : Void*, height : UInt32*) : Int32
  end

  struct GdiplusStartupInput
    property version : UInt32 = 0_u32
    debug_event_callback : Void*
    suppress_bg : BOOL
    suppress_external : BOOL
  end

  struct GdiplusStartupOutput
    hook : Void*
    unhook : Void*
  end

  def self.screenshot_to_png(path : String) : Bool
    token = 0_u64
    input = GdiplusStartupInput.new
    input.version = 1
    output = GdiplusStartupOutput.new
    if GdiPlus.GdiplusStartup(pointerof(token), pointerof(input).as(Void*), pointerof(output).as(Void*)) != 0
      return false
    end

    ok = false
    w = User32.GetSystemMetrics(0)
    h = User32.GetSystemMetrics(1)

    hdc_screen = User32.GetDC(nil)
    if !hdc_screen.null?
      hdc_mem = Gdi32.CreateCompatibleDC(hdc_screen)
      if !hdc_mem.null?
        hbmp = Gdi32.CreateCompatibleBitmap(hdc_screen, w, h)
        if !hbmp.null?
          old = Gdi32.SelectObject(hdc_mem, hbmp)
          if Gdi32.BitBlt(hdc_mem, 0, 0, w, h, hdc_screen, 0, 0, 0x00CC0020_u32) != 0 # SRCCOPY
            bitmap : Void* = Pointer(Void).null
            if GdiPlus.GdipCreateBitmapFromHBITMAP(hbmp, Pointer(Void).null, pointerof(bitmap)) == 0
              # PNG encoder CLSID {557CF406-1A04-11D3-9A73-0000F81EF32E}
              clsid = UInt8.static_array(0x06_u8, 0xF4_u8, 0x7C_u8, 0x55_u8, 0x04_u8, 0x1A_u8,
                0xD3_u8, 0x11_u8, 0x9A_u8, 0x73_u8, 0x00_u8, 0x00_u8,
                0xF8_u8, 0x1E_u8, 0xF3_u8, 0x2E_u8)
              ok = GdiPlus.GdipSaveImageToFile(bitmap, to_wstr(path), clsid.to_unsafe, nil) == 0
              GdiPlus.GdipDisposeImage(bitmap)
            end
          end
          Gdi32.SelectObject(hdc_mem, old)
          Gdi32.DeleteObject(hbmp)
        end
        Gdi32.DeleteDC(hdc_mem)
      end
      User32.ReleaseDC(nil, hdc_screen)
    end

    GdiPlus.GdiplusShutdown(token)
    ok
  end
end
