// Must precede <windows.h> to get C bindings from the Windows SDK.
#define COBJMACROS
#define INITGUID

// NOTE (Google style exception): Windows SDK dependency order, not
// alphabetical — <windows.h> first, then the rest; shim.h last because it
// needs HWND from <windows.h>.
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <shobjidl.h>
#include <combaseapi.h>
#include <objbase.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include <vector>
#include <string>

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "uuid.lib")

#include "shim_internal.h"
#include "../include/shim.h"

// DWM attribute IDs are additive on newer SDKs/docs, so define locally.

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#define DWMWA_SYSTEMBACKDROP_TYPE       38
#define DWMWA_WINDOW_CORNER_PREFERENCE  33
#define DWMSBT_MAINWINDOW               2
#define DWMWCP_ROUND                    2

#define ACCENT_ENABLE_ACRYLICBLURBEHIND 4
#define WCA_ACCENT_POLICY               19

static const COLORREF GV_BG0  = RGB(0x28, 0x28, 0x28);  // #282828
static const COLORREF GV_BG0H = RGB(0x1d, 0x20, 0x21);  // #1d2021
static const COLORREF GV_BG1  = RGB(0x3c, 0x38, 0x36);  // #3c3836
static const COLORREF GV_BG2  = RGB(0x50, 0x49, 0x45);  // #504945
static const COLORREF GV_BG3  = RGB(0x66, 0x5c, 0x54);  // #665c54
static const COLORREF GV_FG0  = RGB(0xfb, 0xf1, 0xc7);  // #fbf1c7
static const COLORREF GV_FG1  = RGB(0xeb, 0xdb, 0xb2);  // #ebdbb2
static const COLORREF GV_FG2  = RGB(0xd5, 0xc4, 0xa1);  // #d5c4a1
static const COLORREF GV_GRAY = RGB(0x92, 0x83, 0x74);  // #928374
static const COLORREF GV_BLUE = RGB(0x83, 0xa5, 0x98);  // #83a598
static const COLORREF GV_ORG  = RGB(0xfe, 0x80, 0x19);  // #fe8019
static const COLORREF GV_RED  = RGB(0xfb, 0x49, 0x34);  // #fb4934

static const COLORREF GV_GREEN = RGB(0x9d, 0xb1, 0x7a);  // #9db17a (gruvbox best green)

static COLORREF gv_blend(COLORREF a, COLORREF b, float t) {
  int ar = GetRValue(a), ag = GetGValue(a), ab = GetBValue(a);
  int br = GetRValue(b), bg = GetGValue(b), bb = GetBValue(b);
  return RGB((int)(ar + (br - ar) * t), (int)(ag + (bg - ag) * t),
             (int)(ab + (bb - ab) * t));
}

#define MOD_ALT     0x0001
#define MOD_CONTROL 0x0002
#define MOD_SHIFT   0x0004
#define MOD_WIN     0x0008

struct ACCENT_POLICY_W {
  int  accent_state;
  int  accent_flags;
  DWORD gradient_color;
  int  animation_id;
};

struct WINCOMPATTRDATA_W {
  int  attribute;
  void *data;
  size_t size;
};

typedef int (WINAPI *SetWindowCompositionAttributeFn)(HWND, WINCOMPATTRDATA_W *);

// Returns the NT build number (0 on failure).
static long nt_build(void) {
  typedef LONG(WINAPI *RtlGetVersionFn)(void *);
  struct OSVI { ULONG size, major, minor, build, rev; WCHAR csd[128]; };
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return 0;
  RtlGetVersionFn fn = (RtlGetVersionFn)GetProcAddress(ntdll, "RtlGetVersion");
  if (!fn) return 0;
  OSVI vi;
  memset(&vi, 0, sizeof(vi));
  vi.size = sizeof(vi);
  if (fn(&vi) != 0) return 0;
  return (long)vi.build;
}

static void apply_backdrop(HWND hwnd) {
  long build = nt_build();
  if (build >= 22000) {
    int dark = 1;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    int backdrop = DWMSBT_MAINWINDOW;
    DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop));
    int corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
  } else if (build >= 17763) {
    int dark = 1;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    SetWindowCompositionAttributeFn fn = (SetWindowCompositionAttributeFn)
      GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute");
    if (fn) {
      ACCENT_POLICY_W accent;
      memset(&accent, 0, sizeof(accent));
      accent.accent_state = ACCENT_ENABLE_ACRYLICBLURBEHIND;
      accent.gradient_color = 0xB01D2021;
      WINCOMPATTRDATA_W data;
      data.attribute = WCA_ACCENT_POLICY;
      data.data = &accent;
      data.size = sizeof(accent);
      fn(hwnd, &data);
    }
  }
}


typedef HANDLE(WINAPI *SetProcessDpiContextFn)(HANDLE);
#ifndef DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
#define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((HANDLE)-4)
#endif
typedef HRESULT(WINAPI *SetProcessDpiAwarenessFn)(int);  // PROCESS_DPI_AWARENESS
typedef BOOL(WINAPI *SetProcessDPIAwareFn)(void);
typedef UINT(WINAPI *GetDpiForWindowFn)(HWND);
typedef HRESULT(WINAPI *GetDpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);
typedef BOOL(WINAPI *EnableNonClientDpiScalingFn)(HWND);
#ifndef MDT_EFFECTIVE_DPI
#define MDT_EFFECTIVE_DPI 0
#endif
#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif

// Process-wide, must run before the first window is created. Called from
// kirk_ui_init_dpi (Crystal startup) and again defensively in kirk_ui_show
// (no-op if windows already exist).
static void enable_dpi_awareness(void) {
  SetProcessDpiContextFn fn = (SetProcessDpiContextFn)
    GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetProcessDpiAwarenessContext");
  if (fn) {
    if (fn(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) return;
  }
  HMODULE shcore = LoadLibraryW(L"shcore.dll");
  if (shcore) {
    SetProcessDpiAwarenessFn f2 = (SetProcessDpiAwarenessFn)GetProcAddress(shcore, "SetProcessDpiAwareness");
    if (f2 && SUCCEEDED(f2(2 /* PerMonitor */))) { FreeLibrary(shcore); return; }
    FreeLibrary(shcore);
  }
  SetProcessDPIAwareFn f3 = (SetProcessDPIAwareFn)
    GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetProcessDPIAware");
  if (f3) f3();
}

static UINT ui_get_dpi_for_window(HWND hwnd) {
  GetDpiForWindowFn fn = (GetDpiForWindowFn)
    GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
  if (fn && hwnd) {
    UINT d = fn(hwnd);
    if (d >= 48 && d <= 768) return d;
  }
  return 0;
}

// DPI for the monitor containing pt (used before the dialog exists).
static UINT ui_get_dpi_for_point(POINT pt) {
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  HMODULE shcore = LoadLibraryW(L"shcore.dll");
  if (shcore) {
    GetDpiForMonitorFn fn = (GetDpiForMonitorFn)GetProcAddress(shcore, "GetDpiForMonitor");
    if (fn && mon) {
      UINT dx = 0, dy = 0;
      if (SUCCEEDED(fn(mon, MDT_EFFECTIVE_DPI, &dx, &dy)) && dx >= 48 && dx <= 768) {
        FreeLibrary(shcore);
        return dx;
      }
    }
    FreeLibrary(shcore);
  }
  HDC dc = GetDC(nullptr);
  UINT dpi = 96;
  if (dc) {
    int v = GetDeviceCaps(dc, LOGPIXELSY);
    if (v >= 48 && v <= 768) dpi = (UINT)v;
    ReleaseDC(nullptr, dc);
  }
  return dpi;
}

static void ui_enable_nc_scaling(HWND hwnd) {
  EnableNonClientDpiScalingFn fn = (EnableNonClientDpiScalingFn)
    GetProcAddress(GetModuleHandleW(L"user32.dll"), "EnableNonClientDpiScaling");
  if (fn && hwnd) fn(hwnd);
}


static HFONT make_font_dpi(int pt, int weight, bool italic, UINT dpi) {
  if (dpi < 48 || dpi > 768) dpi = 96;
  int px = -MulDiv(pt, (int)dpi, 72);
  return CreateFontW(px, 0, 0, 0, weight, italic ? TRUE : FALSE, FALSE, FALSE,
                     DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                     CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
}

static void draw_text(HDC dc, const wchar_t *s, const RECT *r, COLORREF c,
                      HFONT f, UINT fmt) {
  int bm = SetBkMode(dc, TRANSPARENT);
  HFONT of = (HFONT)SelectObject(dc, f);
  SetTextColor(dc, c);
  DrawTextW(dc, s, -1, (RECT *)r, fmt);
  SelectObject(dc, of);
  SetBkMode(dc, bm);
}

static void fill_round(HDC dc, const RECT *r, COLORREF c, int radius) {
  HBRUSH b = CreateSolidBrush(c);
  HBRUSH ob = (HBRUSH)SelectObject(dc, b);
  HPEN op = (HPEN)SelectObject(dc, GetStockObject(NULL_PEN));
  BeginPath(dc);
  RoundRect(dc, r->left, r->top, r->right, r->bottom, radius, radius);
  EndPath(dc);
  FillPath(dc);
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(b);
}

static void frame_round(HDC dc, const RECT *r, COLORREF c, int radius, int w) {
  HPEN p = CreatePen(PS_SOLID, w, c);
  HBRUSH ob = (HBRUSH)SelectObject(dc, GetStockObject(NULL_BRUSH));
  HPEN op = (HPEN)SelectObject(dc, p);
  BeginPath(dc);
  RoundRect(dc, r->left, r->top, r->right, r->bottom, radius, radius);
  EndPath(dc);
  StrokePath(dc);
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(p);
}

static void fill_rect(HDC dc, const RECT *r, COLORREF c) {
  HBRUSH b = CreateSolidBrush(c);
  FillRect(dc, r, b);
  DeleteObject(b);
}

// Cached-brush variants for the hot main-window paint path. No GDI
// create/destroy per shape: brushes/pens live on the UI struct.
static void ui_fill_round(HDC dc, const RECT *r, HBRUSH br, int radius) {
  if (!br) return;
  HBRUSH ob = (HBRUSH)SelectObject(dc, br);
  HPEN op = (HPEN)SelectObject(dc, GetStockObject(NULL_PEN));
  BeginPath(dc);
  RoundRect(dc, r->left, r->top, r->right, r->bottom, radius, radius);
  EndPath(dc);
  FillPath(dc);
  SelectObject(dc, op);
  SelectObject(dc, ob);
}

static void ui_frame_round(HDC dc, const RECT *r, HPEN pen, int radius) {
  if (!pen) return;
  HBRUSH ob = (HBRUSH)SelectObject(dc, GetStockObject(NULL_BRUSH));
  HPEN op = (HPEN)SelectObject(dc, pen);
  BeginPath(dc);
  RoundRect(dc, r->left, r->top, r->right, r->bottom, radius, radius);
  EndPath(dc);
  StrokePath(dc);
  SelectObject(dc, op);
  SelectObject(dc, ob);
}

static void ui_fill_rect(HDC dc, const RECT *r, HBRUSH br) {
  if (!br) return;
  FillRect(dc, r, br);
}

static void draw_caret(HDC dc, int cx, int cy, int sz, COLORREF c) {
  HBRUSH b = CreateSolidBrush(c);
  HBRUSH ob = (HBRUSH)SelectObject(dc, b);
  HPEN op = (HPEN)SelectObject(dc, GetStockObject(NULL_PEN));
  POINT p[3] = {{cx - sz, cy - sz}, {cx + sz, cy - sz}, {cx, cy + sz}};
  Polygon(dc, p, 3);
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(b);
}


enum FieldType {
  FT_SECTION,
  FT_STEP,
  FT_COMBO,
  FT_PRESET,
  FT_TOGGLE,
  FT_EDIT,
  FT_BUTTON,
  FT_HOTKEY,
};

enum HitSub { HS_NONE, HS_MINUS, HS_PLUS, HS_MAIN, HS_CANCEL, HS_SAVE, HS_RESET };

struct CField {
  FieldType type;
  int id;
  RECT rc = {0, 0, 0, 0};  // full row (layout region)
  RECT ctrl = {0, 0, 0, 0};  // control region (separate column)
  const wchar_t *label = nullptr;

  bool has_info = false;
  const wchar_t *tip = nullptr;
  RECT info = {0, 0, 0, 0};
  bool info_hover = false;

  int *pval = nullptr;
  int vmin = 0, vmax = 0;
  int step_inc = 1;
  const wchar_t *suffix = nullptr;

  std::vector<std::wstring> *items = nullptr;
  int *psel = nullptr;

  std::vector<int> *preset_vals = nullptr;  // parallel to items; last = sentinel
  bool custom = false;  // true = show inline stepper
  bool *pcustom = nullptr;  // persistent flag in UI

  int *pflag = nullptr;

  wchar_t *editbuf = nullptr;
  int editmax = 0;
  HWND edit = nullptr;

  int btnkind = 0;

  int *pvk = nullptr;
  int *pmod = nullptr;
  bool capturing = false;
  int cap_vk = 0, cap_mod = 0;
  bool cap_dirty = false;

  bool hover = false;
  bool down = false;
  int sub = HS_NONE;
};

struct Card { std::wstring title; RECT rc; };

static const wchar_t *enc_names[] = {
  L"Auto (recommended)",
  L"NVIDIA NVENC (H.264)",
  L"AMD AMF (H.264)",
  L"Intel QuickSync (H.264)",
  L"x264 (CPU)",
};
static const wchar_t *enc_vals[] = {
  L"",
  L"h264_nvenc",
  L"h264_amf",
  L"h264_qsv",
  L"libx264",
};
static const int enc_count = 5;

// Quality preset: generic names mapping onto per-encoder options in the
// capture engine (NVENC p1..p7, AMF speed|balanced|quality, QSV/x264 names).
// Last entry preserves a hand-edited kirk.yml value.
static const wchar_t *quality_names[] = {
  L"Performance (least lag)",
  L"Fast",
  L"Balanced (recommended)",
  L"Good",
  L"Quality (sharpest)",
  L"Custom (kirk.yml)",
};
static const wchar_t *quality_vals[] = {
  L"p1",
  L"p3",
  L"p4",
  L"p5",
  L"p7",
  L"",
};
static const int quality_count = 6;

// Resolution cap: downscale the capture before encoding. Native = full
// desktop. 1080p is the sweet spot for AMD iGPUs / 4K desktops. Last entry
// preserves hand-edited max_width/max_height from kirk.yml.
static const wchar_t *res_names[] = {
  L"Native (full desktop)",
  L"720p (1280x720 or smaller)",
  L"1080p (1920x1080 or smaller)",
  L"1440p (2560x1440 or smaller)",
  L"Custom (kirk.yml)",
};
static const int res_w[] = {0, 1280, 1920, 2560, -1};
static const int res_h[] = {0, 720, 1080, 1440, -1};
static const int res_count = 5;


struct UI {
  HWND hwnd = nullptr;
  HWND owner = nullptr;
  UINT done_msg = 0;
  int dpi = 96;
  float k = 1.0f;
  bool mica = false;

  std::vector<CField> f;
  std::vector<Card> cards;
  std::vector<RECT> hdr;
  std::vector<std::wstring> mic_items;
  std::vector<std::wstring> extra_items;   // "(None)" + capture devices
  std::vector<std::wstring> render_items;  // "(Default output)" + render devices

  HFONT fTitle = nullptr, fSec = nullptr, fLbl = nullptr, fVal = nullptr, fBtn = nullptr;
  HBRUSH brEdit = nullptr;

  // Cached GDI resources: created once per dialog (and rebuilt on DPI
  // change only for fonts). Eliminates per-paint Create/Delete churn that
  // made hover/scroll repaint expensive.
  HBRUSH brBg0 = nullptr, brBg0H = nullptr, brBg1 = nullptr, brBg2 = nullptr;
  HBRUSH brBg3 = nullptr, brGreen = nullptr, brOrg = nullptr, brKnob = nullptr;
  HPEN penBg1 = nullptr, penBg3 = nullptr, penOrg = nullptr, penRed = nullptr;
  HCURSOR curArrow = nullptr, curHand = nullptr;
  bool mouse_tracked = false;

  kirk_settings S;
  int micSel = 0, encSel = 0, presetSel = 2, resSel = 0;
  int extraSel = 0, sysDevSel = 0;
  bool fpsCustom = false, vbrCustom = false, abrCustom = false;
  int clientW = 0, clientH = 0;

  int content_end = 0;  // bottom of the scrolled content
  int scroll_top = 0;  // fixed top of scrolling region
  int scrolled_h = 0;  // client-visible height of scrolling region
  int scroll_max = 0;
  int scroll_y = 0;
  bool closed = false;  // set in WM_DESTROY; modal loop exits on this

  // owner-drawn gruvbox scrollbar (no WS_VSCROLL): geometry lives in the
  // right margin so it never overlaps cards; drag state for thumb moves.
  RECT rcTrack = {0, 0, 0, 0};
  RECT rcThumb = {0, 0, 0, 0};
  bool sbHover = false;
  bool sbThumbHover = false;
  bool sbDragging = false;
  int sbDragOff = 0;

  RECT rcSave, rcCancel, rcReset;
  RECT rcWarn;
  RECT rcTip;  // help text area bottom-left

  int focus = -1;  // -1 = none

  int S_(int dip) const { return (int)(dip * k + 0.5f); }
  // Centralized corner-radius scale (DIP): one value per size class so
  // controls of the same type can never drift apart.
  int R_ctrl(void) const { return S_(7); }  // steppers, combos, inputs, hotkeys, buttons
  int R_card(void) const { return S_(10); }  // section cards, dialogs, popups
};

// Preset tables for fps / bitrates. Labels include units; last entry is
// always "Custom…" whose preset_vals sentinel is INT_MIN.
static const int FPS_VALS[] = {30, 60, 90, 120, 144, 240};
static const wchar_t *FPS_LABELS[] = {L"30 fps", L"60 fps", L"90 fps", L"120 fps", L"144 fps", L"240 fps"};
static const int VBR_VALS[] = {8000, 16000, 25000, 50000, 100000};
static const wchar_t *VBR_LABELS[] = {L"8 Mbps", L"16 Mbps", L"25 Mbps", L"50 Mbps", L"100 Mbps"};
static const int ABR_VALS[] = {128, 192, 256, 320};
static const wchar_t *ABR_LABELS[] = {L"128 kbps", L"192 kbps", L"256 kbps", L"320 kbps"};

static int preset_index_of(const std::vector<int> *vals, int v) {
  if (!vals) return -1;
  for (size_t i = 0; i < vals->size(); i++) {
    if ((*vals)[i] == v) return (int)i;
  }
  return -1;
}

static bool preset_value_known(const std::vector<int> *vals, int v) {
  return preset_index_of(vals, v) >= 0;
}

static UI *g_ui = nullptr;
static LONG g_active = 0;
static kirk_settings *g_saved = nullptr;

static HWND g_popup = nullptr;
static UI *g_popup_ui = nullptr;
static int g_popup_field = 0;
static int g_popup_hover = -1;
// First visible row in the dropdown popup. The popup window is capped at 12
// rows, but lists like the mic enumeration can be longer — without this the
// entries below the fold were painted off-window and unreachable.
static int g_popup_top = 0;


#define TM_TIP 0x30
static HWND g_tip = nullptr;
static const wchar_t *g_tip_text = nullptr;
static int g_tip_field = -1;

static LRESULT CALLBACK tip_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  switch (m) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(h, &ps);
      RECT rc;
      GetClientRect(h, &rc);
      int pad = g_ui ? g_ui->S_(12) : 12;
      fill_round(dc, &rc, GV_BG1, g_ui ? g_ui->R_ctrl() : 6);
      frame_round(dc, &rc, GV_BG3, g_ui ? g_ui->R_ctrl() : 6, 1);
      if (g_tip_text) {
        RECT tr = {pad, pad, rc.right - pad, rc.bottom - pad};
        HFONT ft = g_ui ? g_ui->fLbl : nullptr;
        draw_text(dc, g_tip_text, &tr, GV_FG0, ft, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
      }
      EndPaint(h, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
  }
  return DefWindowProcW(h, m, w, l);
}

static void tip_show(POINT anchor, const wchar_t *text, int field_id) {
  static bool class_done = false;
  if (!class_done) {
    WNDCLASSW wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = tip_proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = L"KirkTip";
    RegisterClassW(&wc);
    class_done = true;
  }
  // Already showing this exact tooltip: just keep it alive, do not destroy
  // + recreate the window on every mousemove (that was the hover-lag storm).
  if (g_tip && g_tip_text == text && g_tip_field == field_id) return;
  if (g_tip) DestroyWindow(g_tip);
  if (!g_ui || !text) { g_tip = nullptr; g_tip_text = nullptr; g_tip_field = -1; return; }

  g_tip_text = text;
  g_tip_field = field_id;
  HDC dc = GetDC(g_ui->hwnd);
  HFONT old = (HFONT)SelectObject(dc, g_ui->fLbl);
  SIZE sz;
  GetTextExtentPoint32W(dc, text, (int)wcslen(text), &sz);
  SelectObject(dc, old);
  ReleaseDC(g_ui->hwnd, dc);

  int pad = g_ui->S_(8);
  int w = sz.cx + pad * 2;
  int h = sz.cy + pad * 2;

  int x = anchor.x + g_ui->S_(16);
  int y = anchor.y + g_ui->S_(16);

  MONITORINFO mi;
  memset(&mi, 0, sizeof(mi));
  mi.cbSize = sizeof(mi);
  HMONITOR mon = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  GetMonitorInfoW(mon, &mi);
  if (x + w > mi.rcWork.right) x = mi.rcWork.right - w;
  if (y + h > mi.rcWork.bottom) y = anchor.y - h - g_ui->S_(12);
  if (x < mi.rcWork.left) x = mi.rcWork.left;
  if (y < mi.rcWork.top) y = mi.rcWork.top;

  g_tip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                          L"KirkTip", L"",
                          WS_POPUP, x, y, w, h,
                          g_ui->hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (g_tip) ShowWindow(g_tip, SW_SHOWNOACTIVATE);
}

static void tip_hide(void) {
  if (g_tip) {
    DestroyWindow(g_tip);
    g_tip = nullptr;
    g_tip_text = nullptr;
    g_tip_field = -1;
  } else {
    g_tip_text = nullptr;
    g_tip_field = -1;
  }
}


static CField *find_field(int id) {
  for (auto &fd : g_ui->f) {
    if (fd.id == id) return &fd;
  }
  return nullptr;
}

static RECT rf(UI *u, int x, int y, int w, int h) {
  RECT r = {x, y, x + w, y + h};
  return r;
}

static void step_rects(const RECT &ctrl, RECT *minus, RECT *val, RECT *plus, float k) {
  int cx = ctrl.left;
  int w = (int)(26 * k + 0.5f), h = ctrl.bottom - ctrl.top;
  int gap = (int)(8 * k + 0.5f);
  int vw = (ctrl.right - ctrl.left) - 2 * w - 2 * gap;
  minus->left = cx; minus->top = ctrl.top; minus->right = cx + w; minus->bottom = ctrl.bottom;
  val->left = cx + w + gap; val->top = ctrl.top; val->right = val->left + vw; val->bottom = ctrl.bottom;
  plus->left = val->right + gap; plus->top = ctrl.top; plus->right = plus->left + w; plus->bottom = ctrl.bottom;
}


static const wchar_t *vk_name(int vk) {
  if (vk >= L'A' && vk <= L'Z') {
    static wchar_t buf[2] = {0, 0};
    buf[0] = (wchar_t)vk;
    return buf;
  }
  if (vk >= L'0' && vk <= L'9') {
    static wchar_t buf[2] = {0, 0};
    buf[0] = (wchar_t)vk;
    return buf;
  }
  if (vk >= VK_F1 && vk <= VK_F24) {
    static wchar_t buf[8];
    swprintf_s(buf, 8, L"F%d", vk - VK_F1 + 1);
    return buf;
  }
  switch (vk) {
    case VK_SPACE: return L"Space";
    case VK_ESCAPE: return L"Esc";
    case VK_TAB: return L"Tab";
    case VK_RETURN: return L"Enter";
    case VK_BACK: return L"Backspace";
    case VK_DELETE: return L"Delete";
    case VK_INSERT: return L"Insert";
    case VK_HOME: return L"Home";
    case VK_END: return L"End";
    case VK_PRIOR: return L"Page Up";
    case VK_NEXT: return L"Page Down";
    case VK_LEFT: return L"\u2190";
    case VK_RIGHT: return L"\u2192";
    case VK_UP: return L"\u2191";
    case VK_DOWN: return L"\u2193";
    case VK_SNAPSHOT: return L"Print Screen";
    case VK_PAUSE: return L"Pause";
    case VK_OEM_PLUS: return L"+";
    case VK_OEM_MINUS: return L"-";
    case VK_OEM_PERIOD: return L".";
    case VK_OEM_COMMA: return L",";
    default: return L"";
  }
}

static void hotkey_text(int vk, int mod, wchar_t *out, int n) {
  std::wstring s;
  if (mod & MOD_CONTROL) s += L"Ctrl+";
  if (mod & MOD_ALT) s += L"Alt+";
  if (mod & MOD_SHIFT) s += L"Shift+";
  if (mod & MOD_WIN) s += L"Win+";
  if (vk == 0) {
    wcsncpy_s(out, n, L"(none)", _TRUNCATE);
    return;
  }
  const wchar_t *nm = vk_name(vk);
  s += nm;
  if (nm[0] == 0) {
    wchar_t hex[16];
    swprintf_s(hex, 16, L"[0x%X]", vk);
    s += hex;
  }
  wcsncpy_s(out, n, s.c_str(), _TRUNCATE);
}


static HICON app_icon(void) {
  return LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
}


static void ui_free_layout_items(UI *u) {
  for (auto &fd : u->f) {
    if ((fd.type == FT_COMBO && fd.items && fd.items != &u->mic_items &&
         fd.items != &u->extra_items && fd.items != &u->render_items) ||
        (fd.type == FT_PRESET && fd.items)) {
      delete fd.items;
      fd.items = nullptr;
    }
    if (fd.type == FT_PRESET && fd.preset_vals) {
      delete fd.preset_vals;
      fd.preset_vals = nullptr;
    }
  }
}

static void ui_make_preset(UI *u, CField &fd, const int *vals, const wchar_t **labels,
                           int nvals, int *pval, int vmin, int vmax, int step,
                           const wchar_t *suffix, bool *pcustom) {
  fd.items = new std::vector<std::wstring>();
  fd.preset_vals = new std::vector<int>();
  for (int i = 0; i < nvals; i++) {
    fd.items->push_back(labels[i]);
    fd.preset_vals->push_back(vals[i]);
  }
  fd.items->push_back(L"Custom\u2026");
  fd.preset_vals->push_back(INT_MIN);  // sentinel for Custom
  fd.pval = pval;
  fd.vmin = vmin;
  fd.vmax = vmax;
  fd.step_inc = step;
  fd.suffix = suffix;
  fd.pcustom = pcustom;
  int cur = pval ? *pval : 0;
  // Clamp meaningless zeros to a sane in-range value before deciding mode.
  if (cur < vmin || cur > vmax) {
    cur = vmin;
    if (pval) *pval = cur;
  }
  bool known = preset_value_known(fd.preset_vals, cur);
  bool want_custom = (pcustom && *pcustom) || !known;
  // If the loaded value is a preset but a previous explicit Custom pick
  // survived, keep Custom only when the value no longer matches.
  if (pcustom && *pcustom && known) {
    // keep explicit custom only if caller insists; otherwise show preset
    want_custom = *pcustom;
  }
  fd.custom = want_custom;
  if (pcustom) *pcustom = want_custom;
}

static void ui_layout(UI *u) {
  u->k = (float)u->dpi / 96.0f;
  auto S = [u](int v) { return (int)(v * u->k + 0.5f); };

  // Free owned combo vectors before rebuilding (DPI-change relayout).
  ui_free_layout_items(u);

  int MX = S(26);
  int CW = S(580);
  int cardX = MX, cardW = CW - 2 * MX;
  int cardPad = S(16);
  int colX = cardX + cardPad;
  int ctrlR = cardX + cardW - cardPad;
  int ctrlW = S(210);
  int ctrlL = ctrlR - ctrlW;
  int rowH = S(40);
  int ctrlH = S(28);
  int cardHead = S(34);
  u->clientW = CW;
  u->scroll_top = S(92);

  u->f.clear();
  u->f.reserve(32);
  u->cards.clear();

  // Sanitize meaningless zeros loaded from old configs before layout.
  if (u->S.fps < 10 || u->S.fps > 240) u->S.fps = 60;
  if (u->S.bitrate_kbps < 250 || u->S.bitrate_kbps > 200000) u->S.bitrate_kbps = 8000;
  if (u->S.audio_bitrate_kbps < 32 || u->S.audio_bitrate_kbps > 512) u->S.audio_bitrate_kbps = 192;
  if (u->S.replay_seconds < 5 || u->S.replay_seconds > 600) u->S.replay_seconds = 30;
  if (u->S.segment_seconds < 1 || u->S.segment_seconds > 15) u->S.segment_seconds = 2;
  if (u->S.storage_limit_gb < 1 || u->S.storage_limit_gb > 500) u->S.storage_limit_gb = 20;
  if (u->S.clip_name_pattern[0] == 0) {
    wcsncpy_s(u->S.clip_name_pattern, KIRK_STR_LEN, L"clip-{timestamp}.mp4", _TRUNCATE);
  }
  if (u->S.mic_gain_pct < 0 || u->S.mic_gain_pct > 200) u->S.mic_gain_pct = 100;
  if (u->S.system_gain_pct < 0 || u->S.system_gain_pct > 200) u->S.system_gain_pct = 100;

  // Top inset so the first card never sits flush under the header line.
  int y = u->scroll_top + S(8);

  auto begin_card = [&](const wchar_t *title) {
    Card c;
    c.title = title;
    c.rc = {cardX, y, cardX + cardW, y + cardHead};
    y += cardHead;
    u->cards.push_back(c);
  };
  auto end_card = [&]() {
    if (u->cards.empty()) return;
    Card &c = u->cards.back();
    c.rc.bottom = y + S(6);
    y = c.rc.bottom + S(14);
  };

  auto push_row = [&](FieldType t, int id, const wchar_t *label) {
    CField fd;
    fd.type = t;
    fd.id = id;
    fd.label = label;
    fd.rc = {colX, y, ctrlR, y + rowH};
    int ct = y + (rowH - ctrlH) / 2;
    fd.ctrl = {ctrlL, ct, ctrlR, ct + ctrlH};
    y += rowH;
    u->f.push_back(fd);
  };
  auto add_info = [&](int id, const wchar_t *tip) {
    CField *fd = find_field(id);
    if (!fd) return;
    int sz = S(16);
    fd->has_info = true;
    fd->tip = tip;
    // Initial rect: immediately to the right of the label column start.
    // The paint pass repositions it tightly after the measured label text
    // (label + 4-6px gap) so it always reads as one unit.
    int cy = fd->ctrl.top + (fd->ctrl.bottom - fd->ctrl.top - sz) / 2;
    fd->info = {fd->rc.left, cy, fd->rc.left + sz, cy + sz};
  };

  begin_card(L"General");
  push_row(FT_TOGGLE, 12, L"Run at startup");
  u->f.back().pflag = &u->S.run_at_startup;
  push_row(FT_TOGGLE, 13, L"Start minimized to tray");
  u->f.back().pflag = &u->S.start_minimized;
  push_row(FT_TOGGLE, 14, L"Notify when a clip is saved");
  u->f.back().pflag = &u->S.show_save_notifications;
  add_info(14, L"Show a tray message every time a clip is saved.");
  push_row(FT_TOGGLE, 22, L"Start recording with the app");
  u->f.back().pflag = &u->S.auto_start_recording;
  add_info(22, L"Keep the replay buffer always on, so voice commands and hotkeys never find an empty buffer.");
  end_card();

  begin_card(L"Replay buffer");
  push_row(FT_STEP, 7, L"Replay duration");
  u->f.back().pval = (int *)&u->S.replay_seconds; u->f.back().vmin = 5; u->f.back().vmax = 600;
  u->f.back().suffix = L" sec";
  add_info(7, L"How far back a clip goes when you save a replay.");
  end_card();

  begin_card(L"Video");
  push_row(FT_PRESET, 1, L"Frame rate");
  ui_make_preset(u, u->f.back(), FPS_VALS, FPS_LABELS, 6,
                 (int *)&u->S.fps, 10, 240, 1, L" fps", &u->fpsCustom);
  add_info(1, L"Recording frame rate. Higher uses more CPU/GPU.");
  push_row(FT_PRESET, 2, L"Video bitrate");
  ui_make_preset(u, u->f.back(), VBR_VALS, VBR_LABELS, 5,
                 (int *)&u->S.bitrate_kbps, 250, 200000, 1000, L" kbps", &u->vbrCustom);
  add_info(2, L"Encoding bitrate. Higher = larger, sharper clips.");
  push_row(FT_COMBO, 3, L"Encoder");
  u->f.back().items = new std::vector<std::wstring>();
  for (int i = 0; i < enc_count; i++) u->f.back().items->push_back(enc_names[i]);
  u->f.back().psel = &u->encSel;
  add_info(3, L"Hardware encoder. Auto picks the best available (NVENC > AMD AMF > QuickSync > CPU). On AMD, install Adrenalin drivers or AMF is missing and Auto falls back to laggy CPU encoding.");
  push_row(FT_COMBO, 23, L"Quality preset");
  u->f.back().items = new std::vector<std::wstring>();
  for (int i = 0; i < quality_count; i++) u->f.back().items->push_back(quality_names[i]);
  u->f.back().psel = &u->presetSel;
  add_info(23, L"Encoding effort. Performance = least lag (NVENC p1, AMF speed, x264 ultrafast). Balanced is recommended.");
  push_row(FT_COMBO, 24, L"Max resolution");
  u->f.back().items = new std::vector<std::wstring>();
  for (int i = 0; i < res_count; i++) u->f.back().items->push_back(res_names[i]);
  u->f.back().psel = &u->resSel;
  add_info(24, L"Downscale before encoding. Native 4K60 is heavy; 1080p fixes most lag with barely visible loss. Custom values can be set in kirk.yml.");
  end_card();

  begin_card(L"Audio mixer");
  push_row(FT_COMBO, 4, L"Recording mic");
  u->f.back().items = &u->mic_items;
  u->f.back().psel = &u->micSel;
  add_info(4, L"Microphone baked into recorded clips. (System default) follows Windows' default mic. Voice commands always use the system default mic, not this setting.");
  push_row(FT_COMBO, 25, L"Second mic (optional)");
  u->f.back().items = &u->extra_items;
  u->f.back().psel = &u->extraSel;
  add_info(25, L"Mix a second capture device in (e.g. a separate Discord mic). More than two? Add them in kirk.yml as extra_audio_devices.");
  push_row(FT_TOGGLE, 26, L"Capture system audio");
  u->f.back().pflag = &u->S.capture_system_audio;
  add_info(26, L"Mix in game / Discord / system output via loopback so it lands in clips, not just your speakers.");
  push_row(FT_COMBO, 27, L"System audio source");
  u->f.back().items = &u->render_items;
  u->f.back().psel = &u->sysDevSel;
  add_info(27, L"Which output to loop back. Default follows Windows' default speakers.");
  push_row(FT_STEP, 28, L"Mic gain");
  u->f.back().pval = (int *)&u->S.mic_gain_pct; u->f.back().vmin = 0; u->f.back().vmax = 200;
  u->f.back().step_inc = 5;
  u->f.back().suffix = L" %";
  add_info(28, L"Microphone loudness in the mix. 100% = unchanged.");
  push_row(FT_STEP, 29, L"System gain");
  u->f.back().pval = (int *)&u->S.system_gain_pct; u->f.back().vmin = 0; u->f.back().vmax = 200;
  u->f.back().step_inc = 5;
  u->f.back().suffix = L" %";
  add_info(29, L"Game / Discord loudness in the mix. 100% = unchanged.");
  push_row(FT_TOGGLE, 6, L"Capture microphone");
  u->f.back().pflag = &u->S.capture_audio;
  add_info(6, L"Master switch for ALL clip audio (mics + system). Does NOT affect voice commands (they always listen on the system default mic).");
  push_row(FT_PRESET, 5, L"Audio bitrate");
  ui_make_preset(u, u->f.back(), ABR_VALS, ABR_LABELS, 4,
                 (int *)&u->S.audio_bitrate_kbps, 32, 512, 16, L" kbps", &u->abrCustom);
  add_info(5, L"Audio quality for recorded clips.");
  end_card();

  begin_card(L"Voice commands");
  push_row(FT_TOGGLE, 15, L"Voice commands (\u201CKirk, clip that!\u201D)");
  u->f.back().pflag = &u->S.voice_enabled;
  add_info(15, L"Speak \u201CKirk, clip that!\u201D to save a clip hands-free. Always listens on the system default mic (independent of Capture microphone). Hover the tray icon to see listening status.");
  end_card();

  begin_card(L"Storage");
  push_row(FT_EDIT, 8, L"Clips folder");
  {
    CField &e = u->f.back();
    e.editbuf = (wchar_t *)u->S.clips_dir;
    e.editmax = KIRK_PATH_LEN;
    const int bw = S(88);
    e.ctrl.right -= bw + S(12);
    CField b;
    b.type = FT_BUTTON;
    b.id = 20;
    b.label = L"Browse...";
    b.btnkind = 0;
    b.rc = {e.ctrl.right + S(12), e.rc.top, e.ctrl.right + S(12) + bw, e.rc.bottom};
    int bt = e.rc.top + (rowH - ctrlH) / 2;
    b.ctrl = {e.ctrl.right + S(12), bt, e.ctrl.right + S(12) + bw, bt + ctrlH};
    u->f.push_back(b);
  }
  add_info(8, L"Folder where clips are saved. Empty = default app folder.");
  push_row(FT_EDIT, 9, L"Clip file name");
  u->f.back().editbuf = (wchar_t *)u->S.clip_name_pattern; u->f.back().editmax = KIRK_STR_LEN;
  add_info(9, L"File name pattern. Use {timestamp} for the date and time.");
  push_row(FT_STEP, 10, L"Storage limit");
  u->f.back().pval = (int *)&u->S.storage_limit_gb; u->f.back().vmin = 1; u->f.back().vmax = 500;
  u->f.back().step_inc = 1;
  u->f.back().suffix = L" GB";
  add_info(10, L"Maximum size of the clips folder before old clips are removed.");
  push_row(FT_TOGGLE, 11, L"Delete oldest clips automatically");
  u->f.back().pflag = &u->S.auto_delete_oldest;
  add_info(11, L"When the folder is full, remove the oldest clips first.");
  end_card();

  begin_card(L"Hotkeys");
  push_row(FT_HOTKEY, 16, L"Save replay");
  u->f.back().pvk = &u->S.hotkey_clip_vk; u->f.back().pmod = &u->S.hotkey_clip_mod;
  add_info(16, L"Click, then press a key combination to assign it.");
  push_row(FT_HOTKEY, 17, L"Toggle recording");
  u->f.back().pvk = &u->S.hotkey_record_vk; u->f.back().pmod = &u->S.hotkey_record_mod;
  push_row(FT_HOTKEY, 18, L"Screenshot");
  u->f.back().pvk = &u->S.hotkey_shot_vk; u->f.back().pmod = &u->S.hotkey_shot_mod;
  end_card();

  begin_card(L"Advanced / Debugging");
  y += S(4);
  u->rcWarn = {cardX + cardPad, u->cards.back().rc.top + cardHead + S(8),
               ctrlR, u->cards.back().rc.top + cardHead + S(8) + S(30)};
  y += S(38);
  push_row(FT_STEP, 19, L"Segment length");
  u->f.back().pval = (int *)&u->S.segment_seconds; u->f.back().vmin = 1; u->f.back().vmax = 15;
  u->f.back().step_inc = 1;
  u->f.back().suffix = L" sec";
  add_info(19, L"How long each rolling buffer file is. Affects capture stability.");
  push_row(FT_TOGGLE, 21, L"Verbose local logging");
  u->f.back().pflag = &u->S.verbose_logging;
  add_info(21, L"Write extra debug information to the local log file.");
  end_card();

  u->content_end = y + S(2);
  u->hdr.assign(1, RECT{S(MX), S(88), CW - MX, S(90)});
}


static void ui_invalidate_field(UI *u, CField &fd);
static LRESULT CALLBACK popup_proc(HWND h, UINT m, WPARAM w, LPARAM l);

static void popup_close() {
  if (g_popup) {
    ReleaseCapture();
    HWND owner = g_popup_ui ? g_popup_ui->hwnd : nullptr;
    DestroyWindow(g_popup);
    g_popup = nullptr;
    g_popup_ui = nullptr;
    if (owner && IsWindow(owner)) SetFocus(owner);
    if (g_ui && g_ui->hwnd) {
      CField *fd = find_field(g_popup_field);
      if (fd) ui_invalidate_field(g_ui, *fd);
      else InvalidateRect(g_ui->hwnd, nullptr, FALSE);
    }
  }
}

static int field_current_index(CField &fd) {
  if (fd.type == FT_PRESET && fd.items && fd.preset_vals && fd.pval) {
    if (fd.custom) return (int)fd.items->size() - 1;
    int idx = preset_index_of(fd.preset_vals, *fd.pval);
    if (idx >= 0) return idx;
    return (int)fd.items->size() - 1;
  }
  if (fd.psel) return *fd.psel;
  return 0;
}

static void popup_scroll_to(int top) {
  UI *u = g_popup_ui;
  CField *fd = u ? find_field(g_popup_field) : nullptr;
  int count = (fd && fd->items) ? (int)fd->items->size() : 0;
  int itemH = u ? u->S_(30) : 30;
  RECT rc = {0, 0, 0, 0};
  int shown = 12;
  if (g_popup) {
    GetClientRect(g_popup, &rc);
    int padY = u ? u->S_(8) : 8;
    shown = (rc.bottom - padY * 2) / itemH;
    if (shown < 1) shown = 1;
  }
  int maxtop = count - shown;
  if (maxtop < 0) maxtop = 0;
  if (top < 0) top = 0;
  if (top > maxtop) top = maxtop;
  if (top == g_popup_top) return;
  g_popup_top = top;
  if (g_popup) InvalidateRect(g_popup, nullptr, FALSE);
}

static void popup_ensure_visible(int idx) {
  UI *u = g_popup_ui;
  CField *fd = u ? find_field(g_popup_field) : nullptr;
  int count = (fd && fd->items) ? (int)fd->items->size() : 0;
  if (idx < 0 || idx >= count) return;
  int itemH = u ? u->S_(30) : 30;
  RECT rc = {0, 0, 0, 0};
  int shown = 12;
  if (g_popup) {
    GetClientRect(g_popup, &rc);
    int padY = u ? u->S_(8) : 8;
    shown = (rc.bottom - padY * 2) / itemH;
    if (shown < 1) shown = 1;
  }
  if (idx < g_popup_top) popup_scroll_to(idx);
  else if (idx >= g_popup_top + shown) popup_scroll_to(idx - shown + 1);
  else if (g_popup) InvalidateRect(g_popup, nullptr, FALSE);
}

static void popup_open(UI *u, CField &fd) {
  if (g_popup) popup_close();
  if (!fd.items || fd.items->empty()) return;

  g_popup_ui = u;
  g_popup_field = fd.id;
  g_popup_hover = field_current_index(fd);
  {
    int count = (int)fd.items->size();
    int shown = count < 12 ? count : 12;
    int cur = g_popup_hover;
    g_popup_top = 0;
    if (cur >= 0 && cur >= shown) {
      g_popup_top = cur - shown + 1;
      int maxtop = count - shown;
      if (maxtop < 0) maxtop = 0;
      if (g_popup_top > maxtop) g_popup_top = maxtop;
    }
  }

  int itemH = u->S_(30);
  int padY = u->S_(8);
  int w = fd.ctrl.right - fd.ctrl.left;
  int count = (int)fd.items->size();
  int shown = count < 12 ? count : 12;
  int h = padY * 2 + shown * itemH;

  POINT pt = {fd.ctrl.left, fd.ctrl.bottom - u->scroll_y + u->S_(4)};
  ClientToScreen(u->hwnd, &pt);

  MONITORINFO mi;
  memset(&mi, 0, sizeof(mi));
  mi.cbSize = sizeof(mi);
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  GetMonitorInfoW(mon, &mi);
  // Open below the control like a real dropdown. The old code opened AT the
  // control's top edge, so the popup covered the control and the opening
  // click's cursor sat on top of row 0: any jitter committed the row above
  // the intended one. Below-control placement keeps the cursor outside the
  // popup until the user deliberately moves into it.
  if (pt.y + h > mi.rcWork.bottom) {
    // No room below: flip above the control.
    POINT ptAbove = {fd.ctrl.left, fd.ctrl.top - u->scroll_y - u->S_(4) - h};
    ClientToScreen(u->hwnd, &ptAbove);
    if (ptAbove.y >= mi.rcWork.top) {
      pt = ptAbove;
    } else {
      pt.y = mi.rcWork.bottom - h;
    }
  }
  if (pt.y < mi.rcWork.top) pt.y = mi.rcWork.top;

  // The popup class must exist: without this CreateWindowExW fails and every
  // dropdown silently never opens (the reported dead-dropdown bug).
  {
    static bool popup_class_done = false;
    if (!popup_class_done) {
      WNDCLASSW wc;
      memset(&wc, 0, sizeof(wc));
      wc.lpfnWndProc = popup_proc;
      wc.hInstance = GetModuleHandleW(nullptr);
      wc.hbrBackground = nullptr;
      wc.lpszClassName = L"KirkPopup";
      if (RegisterClassW(&wc)) popup_class_done = true;
    }
  }

  g_popup = CreateWindowExW(
    WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
    L"KirkPopup", L"",
    WS_POPUP, pt.x, pt.y, w, h,
    u->hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!g_popup) return;

  ShowWindow(g_popup, SW_SHOWNOACTIVATE);
  SetCapture(g_popup);
  // Keyboard focus: without this, wheel/keys go to the main dialog behind
  // the popup (the dialog would scroll UNDER the open popup, offsetting
  // every row so clicks land on the wrong item).
  SetFocus(g_popup);
  ui_invalidate_field(u, fd);
}

static void popup_commit(int idx);

// Single shared hit-test: client Y -> item index, or -1. Paint, hover and
// click ALL use this, so the highlighted row and the committed row can
// never drift apart (the "click N selects N+1" class of bug).
static int popup_row_at(int y) {
  UI *u = g_popup_ui;
  CField *fd = u ? find_field(g_popup_field) : nullptr;
  if (!u || !fd || !fd->items) return -1;
  int itemH = u->S_(30), padY = u->S_(8);
  if (itemH <= 0 || y < padY) return -1;
  RECT rc = {0, 0, 0, 0};
  if (g_popup) GetClientRect(g_popup, &rc);
  if (rc.bottom - padY * 2 < itemH) return -1;
  // Clicks past the last VISIBLE row are misses even if more rows exist
  // below the fold (they're reachable via wheel/keys, not blind clicks).
  int vis_rows = (rc.bottom - padY * 2) / itemH;
  int rel = (y - padY) / itemH;
  if (rel < 0 || rel >= vis_rows) return -1;
  int idx = g_popup_top + rel;
  if (idx < 0 || idx >= (int)fd->items->size()) return -1;
  return idx;
}

static LRESULT CALLBACK popup_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  UI *u = g_popup_ui;
  switch (m) {
    case WM_MOUSEMOVE: {
      if (!u) break;
      POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
      RECT rc;
      GetClientRect(h, &rc);
      if (pt.x < 0 || pt.y < 0 || pt.x >= rc.right || pt.y >= rc.bottom) {
        popup_close();
        return 0;
      }
      int idx = popup_row_at(pt.y);
      if (idx != g_popup_hover) {
        g_popup_hover = idx;
        InvalidateRect(h, nullptr, FALSE);
      }
      return 0;
    }
    case WM_MOUSEWHEEL: {
      if (!u) break;
      int delta = GET_WHEEL_DELTA_WPARAM(w);
      int rows = delta / WHEEL_DELTA;
      if (rows == 0) rows = (delta > 0) ? 1 : -1;
      // Wheel up = earlier rows; 3 rows per notch.
      popup_scroll_to(g_popup_top - rows * 3);
      // Keep hover on a visible row so wheel-then-click lands correctly.
      {
        POINT pt;
        GetCursorPos(&pt);
        ScreenToClient(h, &pt);
        int idx = popup_row_at(pt.y);
        if (idx != g_popup_hover) {
          g_popup_hover = idx;
          InvalidateRect(h, nullptr, FALSE);
        }
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      if (!u) break;
      POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
      int idx = popup_row_at(pt.y);
      if (idx >= 0) {
        popup_commit(idx);
      } else {
        popup_close();
      }
      return 0;
    }
    case WM_LBUTTONUP:
      return 0;
    case WM_KEYDOWN: {
      if (!u) break;
      CField *fd = find_field(g_popup_field);
      int count = (fd && fd->items) ? (int)fd->items->size() : 0;
      if (w == VK_ESCAPE) { popup_close(); return 0; }
      if (count <= 0) break;
      int cur = g_popup_hover;
      if (cur < 0 || cur >= count) cur = field_current_index(*fd);
      switch (w) {
        case VK_UP: cur--; break;
        case VK_DOWN: cur++; break;
        case VK_PRIOR: cur -= 10; break;
        case VK_NEXT: cur += 10; break;
        case VK_HOME: cur = 0; break;
        case VK_END: cur = count - 1; break;
        case VK_RETURN:
          if (cur >= 0 && cur < count) popup_commit(cur);
          return 0;
        default: break;
      }
      if (cur < 0) cur = 0;
      if (cur >= count) cur = count - 1;
      g_popup_hover = cur;
      popup_ensure_visible(cur);
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(h, &ps);
      if (u) {
        RECT rc;
        GetClientRect(h, &rc);
        fill_rect(dc, &rc, GV_BG0H);
        CField *fd = find_field(g_popup_field);
        if (fd && fd->items) {
          int itemH = u->S_(30), padY = u->S_(8);
          int cur = field_current_index(*fd);
          int count = (int)fd->items->size();
          int y0 = padY - g_popup_top * itemH;
          for (int i = 0; i < count; i++) {
            int yt = y0 + i * itemH;
            if (yt + itemH < 0 || yt > rc.bottom) continue;
            RECT row = {0, yt, rc.right, yt + itemH};
            if (i == g_popup_hover) fill_rect(dc, &row, GV_BG1);
            if (i == cur) fill_rect(dc, &row, GV_BG2);
            RECT tr = {u->S_(10), row.top, row.right - u->S_(10), row.bottom};
            COLORREF c = GV_FG1;
            if (i == cur) c = GV_ORG;
            else if (i == g_popup_hover) c = GV_FG0;
            draw_text(dc, (*fd->items)[i].c_str(), &tr, c, u->fVal, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
          }
          if (count * itemH > rc.bottom - padY * 2) {
            int trackX0 = rc.right - u->S_(10);
            RECT track = {trackX0, padY, rc.right - u->S_(3), rc.bottom - padY};
            int total = count * itemH;
            int vis = rc.bottom - padY * 2;
            int thumbH = vis * vis / total;
            int minThumb = u->S_(20);
            if (thumbH < minThumb) thumbH = minThumb;
            if (thumbH > vis) thumbH = vis;
            int maxTop = count - vis / itemH;
            if (maxTop < 1) maxTop = 1;
            int thumbY = padY + (vis - thumbH) * g_popup_top / maxTop;
            ui_fill_round(dc, &track, u->brBg0H, (track.right - track.left) / 2);
            RECT thumb = {track.left, thumbY, track.right, thumbY + thumbH};
            ui_fill_round(dc, &thumb, u->brBg3, (thumb.right - thumb.left) / 2);
          }
          frame_round(dc, &rc, GV_BG3, u->R_ctrl(), 1);
        }
      }
      EndPaint(h, &ps);
      return 0;
    }
  }
  return DefWindowProcW(h, m, w, l);
}

// Commit a popup row; shared by click + keyboard.
static void popup_commit(int idx) {
  UI *u = g_popup_ui;
  if (!u) { popup_close(); return; }
  CField *fd = find_field(g_popup_field);
  if (!fd || !fd->items || idx < 0 || idx >= (int)fd->items->size()) {
    popup_close();
    return;
  }
  if (fd->type == FT_PRESET && fd->preset_vals && fd->pval) {
    int last = (int)fd->items->size() - 1;
    if (idx == last) {
      fd->custom = true;
      if (fd->pcustom) *fd->pcustom = true;
    } else {
      *fd->pval = (*fd->preset_vals)[idx];
      if (*fd->pval < fd->vmin) *fd->pval = fd->vmin;
      if (*fd->pval > fd->vmax) *fd->pval = fd->vmax;
      fd->custom = false;
      if (fd->pcustom) *fd->pcustom = false;
    }
  } else if (fd->psel) {
    *fd->psel = idx;
  }
  int fid = g_popup_field;
  popup_close();
  CField *mfd = find_field(fid);
  if (u->hwnd && mfd) {
    ui_invalidate_field(u, *mfd);
    UpdateWindow(u->hwnd);
  } else if (u->hwnd) {
    InvalidateRect(u->hwnd, nullptr, FALSE);
  }
}


static LRESULT CALLBACK edit_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  if (m == WM_KEYDOWN && (w == VK_ESCAPE || w == VK_RETURN || w == VK_TAB)) {
    HWND p = GetParent(h);
    if (p) {
      SendMessageW(p, m, w, l);
      return 0;
    }
  }
  WNDPROC oldp = (WNDPROC)GetWindowLongPtrW(h, GWLP_USERDATA);
  return CallWindowProcW(oldp, h, m, w, l);
}

static void create_edits(UI *u) {
#ifndef EM_SETCUEBANNER
#define EM_SETCUEBANNER 0x1501
#endif
  for (auto &fd : u->f) {
    if (fd.type != FT_EDIT) continue;
    fd.edit = CreateWindowExW(0, L"EDIT", fd.editbuf,
                              WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP,
                              fd.ctrl.left, fd.ctrl.top - u->scroll_y,
                              fd.ctrl.right - fd.ctrl.left, fd.ctrl.bottom - fd.ctrl.top,
                              u->hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (fd.edit) {
      SendMessageW(fd.edit, WM_SETFONT, (WPARAM)u->fVal, TRUE);
      if (fd.id == 9) {
        SendMessageW(fd.edit, EM_SETCUEBANNER, (WPARAM)TRUE, (LPARAM)L"clip-{timestamp}.mp4");
      } else if (fd.id == 8) {
        SendMessageW(fd.edit, EM_SETCUEBANNER, (WPARAM)TRUE, (LPARAM)L"Default: %LOCALAPPDATA%\\kirk\\clips");
      }
      WNDPROC oldp = (WNDPROC)SetWindowLongPtrW(fd.edit, GWLP_WNDPROC, (LONG_PTR)edit_proc);
      SetWindowLongPtrW(fd.edit, GWLP_USERDATA, (LONG_PTR)oldp);
    }
  }
}


static void ui_sync_edits(UI *u) {
  for (auto &fd : u->f) {
    if (fd.type != FT_EDIT || !fd.edit) continue;
    SetWindowPos(fd.edit, nullptr,
                 fd.ctrl.left, fd.ctrl.top - u->scroll_y,
                 fd.ctrl.right - fd.ctrl.left, fd.ctrl.bottom - fd.ctrl.top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

static void ui_update_scrollbar(UI *u) {
  u->rcTrack = {0, 0, 0, 0};
  u->rcThumb = {0, 0, 0, 0};
  if (u->scroll_max <= 0 || u->scrolled_h <= 0) return;
  int trackW = u->S_(10);
  int trackX1 = u->clientW - u->S_(8);
  int trackX0 = trackX1 - trackW;
  int trackY0 = u->scroll_top + u->S_(4);
  int trackY1 = u->scroll_top + u->scrolled_h - u->S_(4);
  if (trackY1 <= trackY0) return;
  u->rcTrack = {trackX0, trackY0, trackX1, trackY1};
  int trackH = trackY1 - trackY0;
  int total = u->content_end - u->scroll_top;
  if (total < 1) total = 1;
  int minThumb = u->S_(28);
  int thumbH = (int)((long long)trackH * u->scrolled_h / total);
  if (thumbH < minThumb) thumbH = minThumb;
  if (thumbH > trackH) thumbH = trackH;
  int thumbY = trackY0;
  if (trackH > thumbH) {
    thumbY = trackY0 + (int)((long long)u->scroll_y * (trackH - thumbH) / u->scroll_max);
  }
  u->rcThumb = {trackX0, thumbY, trackX1, thumbY + thumbH};
}

static void ui_footer(UI *u) {
  int bw = u->S_(118), bh = u->S_(34);
  int by = u->clientH - bh - u->S_(18);
  int r = u->S_(26) + (u->clientW - u->S_(52)) - u->S_(16);
  u->rcCancel = {r - 2 * bw - u->S_(12), by, r - bw - u->S_(12), by + bh};
  u->rcSave = {r - bw, by, r, by + bh};
  int rbw = u->S_(150);
  u->rcReset = {u->S_(26), by, u->S_(26) + rbw, by + bh};
  u->scrolled_h = by - u->scroll_top - u->S_(6);
  if (u->scrolled_h < 0) u->scrolled_h = 0;
  u->scroll_max = (u->content_end - u->scroll_top) - u->scrolled_h;
  if (u->scroll_max < 0) u->scroll_max = 0;
  if (u->scroll_y > u->scroll_max) u->scroll_y = u->scroll_max;
  if (u->scroll_max <= 0) {
    u->scroll_y = 0;
    u->sbDragging = false;
    u->sbHover = false;
    u->sbThumbHover = false;
  }
  // Owner-drawn scrollbar only: deliberately no WS_VSCROLL / SetScrollInfo
  // so the OS chrome never shows.
  ui_update_scrollbar(u);
}

static void ui_scroll_to(UI *u, int y) {
  if (y < 0) y = 0;
  if (y > u->scroll_max) y = u->scroll_max;
  if (y == u->scroll_y) return;
  // A scrolling dialog under an open popup offsets every row: close the
  // popup instead of letting clicks land on the wrong item.
  popup_close();
  u->scroll_y = y;
  ui_update_scrollbar(u);
  ui_sync_edits(u);
  InvalidateRect(u->hwnd, nullptr, FALSE);
}

// Returns field index whose control/pill was clicked, and the sub-element.
// `pt` is in content coordinates (already scroll-adjusted).

static int hit_row(POINT pt, HitSub *sub) {
  *sub = HS_NONE;
  UI *u = g_ui;
  if (!u) return -1;

  // footer buttons (pt here is in client coords for footer, content coords for rows;
  // footer rects are client-relative so check them before scroll adjustment by caller)
  if (PtInRect(&u->rcSave, pt)) { *sub = HS_SAVE; return -1; }
  if (PtInRect(&u->rcCancel, pt)) { *sub = HS_CANCEL; return -1; }
  if (PtInRect(&u->rcReset, pt)) { *sub = HS_RESET; return -1; }

  for (size_t i = 0; i < u->f.size(); i++) {
    CField &fd = u->f[i];
    if (fd.type == FT_EDIT) continue;
    if (pt.x < fd.ctrl.left || pt.x >= fd.ctrl.right || pt.y < fd.rc.top || pt.y >= fd.rc.bottom) continue;
    switch (fd.type) {
      case FT_STEP: {
        RECT mn, vl, pl;
        step_rects(fd.ctrl, &mn, &vl, &pl, u->k);
        if (PtInRect(&mn, pt)) *sub = HS_MINUS;
        else if (PtInRect(&pl, pt)) *sub = HS_PLUS;
        else *sub = HS_MAIN;
        return (int)i;
      }
      case FT_PRESET: {
        if (fd.custom) {
          RECT mn, vl, pl;
          step_rects(fd.ctrl, &mn, &vl, &pl, u->k);
          if (PtInRect(&mn, pt)) *sub = HS_MINUS;
          else if (PtInRect(&pl, pt)) *sub = HS_PLUS;
          else *sub = HS_MAIN;
        } else {
          *sub = HS_MAIN;
        }
        return (int)i;
      }
      case FT_COMBO:
      case FT_TOGGLE:
      case FT_HOTKEY:
      case FT_BUTTON:
        *sub = HS_MAIN;
        return (int)i;
      default:
        return (int)i;
    }
  }
  return -1;
}

static int hit_info(POINT pt) {
  UI *u = g_ui;
  if (!u) return -1;
  for (size_t i = 0; i < u->f.size(); i++) {
    CField &fd = u->f[i];
    if (!fd.has_info) continue;
    if (PtInRect(&fd.info, pt)) return (int)i;
  }
  return -1;
}


static bool hk_conflicts_with_other(UI *u, int field_id, int vk, int mod) {
  if (vk == 0) return false;
  int slots[3][2] = {
    {16, 0}, {17, 1}, {18, 2},
  };
  int self = 0;
  for (int i = 0; i < 3; i++) if (slots[i][0] == field_id) self = i;
  int cur[3][2] = {
    {u->S.hotkey_clip_vk, u->S.hotkey_clip_mod},
    {u->S.hotkey_record_vk, u->S.hotkey_record_mod},
    {u->S.hotkey_shot_vk, u->S.hotkey_shot_mod},
  };
  for (int i = 0; i < 3; i++) {
    if (i == self) continue;
    if (cur[i][0] == vk && cur[i][1] == mod) return true;
  }
  return false;
}

// Probe: can we grab this combo system-wide right now on a scratch hotkey id?
static bool hk_try_register(UI *u, int vk, int mod) {
  if (vk == 0) return true;
  RegisterHotKey(u->hwnd, 0x7777, (UINT)mod, (UINT)vk);
  return UnregisterHotKey(u->hwnd, 0x7777) != 0;
}


// Field rows live in content coords (offset by scroll_y); invalidation needs
// client coords. Forgetting the offset paints nothing for scrolled rows, so
// bottom toggles (e.g. Verbose logging) appeared to react seconds late.
static void ui_invalidate_field(UI *u, CField &fd) {
  if (!u || !u->hwnd) return;
  RECT r = fd.rc;
  r.top -= u->scroll_y;
  r.bottom -= u->scroll_y;
  InvalidateRect(u->hwnd, &r, FALSE);
}

static void hk_begin_capture(UI *u, CField &fd) {
  tip_hide();
  for (auto &of : u->f) of.capturing = false;
  fd.capturing = true;
  u->focus = (int)(&fd - u->f.data());
  ui_invalidate_field(u, fd);
}

static void hk_end_capture(UI *u, CField &fd) {
  fd.capturing = false;
  ui_invalidate_field(u, fd);
}

static void stepper_change(CField &fd, bool plus) {
  if (!fd.pval || !g_ui || !g_ui->hwnd) return;
  int inc = fd.step_inc > 0 ? fd.step_inc : 1;
  int v = *fd.pval;
  v += plus ? inc : -inc;
  if (v < fd.vmin) v = fd.vmin;
  if (v > fd.vmax) v = fd.vmax;
  *fd.pval = v;
  // Immediate visual flip: synchronous repaint so the control reacts on the
  // next frame even if the message queue is backed up with timers. Any
  // persistence happens later on Save, never before redraw.
  ui_invalidate_field(g_ui, fd);
  UpdateWindow(g_ui->hwnd);
}

static void toggle_change(CField &fd) {
  if (!fd.pflag || !g_ui || !g_ui->hwnd) return;
  *fd.pflag = *fd.pflag ? 0 : 1;
  // Repaint synchronously; persistence happens on Save, never before redraw.
  ui_invalidate_field(g_ui, fd);
  UpdateWindow(g_ui->hwnd);
}

static void ui_reset_defaults(UI *u) {
  u->S.fps = 60;
  u->S.bitrate_kbps = 8000;
  u->S.audio_bitrate_kbps = 192;
  u->S.replay_seconds = 30;
  u->S.segment_seconds = 2;
  u->S.storage_limit_gb = 20;
  u->S.capture_audio = 1;
  u->S.auto_delete_oldest = 1;
  u->S.run_at_startup = 0;
  u->S.start_minimized = 1;
  u->S.show_save_notifications = 1;
  u->S.voice_enabled = 1;
  u->S.verbose_logging = 0;
  u->S.auto_start_recording = 1;
  u->S.encoder[0] = 0;
  wcsncpy_s(u->S.encoder_preset, 64, L"p4", _TRUNCATE);
  u->S.max_width = 0;
  u->S.max_height = 0;
  u->S.mic_device[0] = 0;
  u->S.extra_audio_device[0] = 0;
  u->S.capture_system_audio = 0;
  u->S.system_audio_device[0] = 0;
  u->S.mic_gain_pct = 100;
  u->S.system_gain_pct = 100;
  u->S.clips_dir[0] = 0;
  wcsncpy_s(u->S.clip_name_pattern, KIRK_STR_LEN, L"clip-{timestamp}.mp4", _TRUNCATE);
  u->S.hotkey_clip_mod = 0; u->S.hotkey_clip_vk = 0x77;
  u->S.hotkey_record_mod = 0; u->S.hotkey_record_vk = 0x78;
  u->S.hotkey_shot_mod = 0; u->S.hotkey_shot_vk = 0x79;
  u->encSel = 0;
  u->presetSel = 2;
  u->resSel = 0;
  u->micSel = 0;
  u->extraSel = 0;
  u->sysDevSel = 0;
  u->fpsCustom = false; u->vbrCustom = false; u->abrCustom = false;
  for (auto &fd : u->f) {
    if (fd.type == FT_PRESET && fd.pval && fd.preset_vals) {
      int cur = *fd.pval;
      if (fd.id == 1) { fd.custom = false; }
      else if (fd.id == 2) { fd.custom = false; }
      else if (fd.id == 5) { fd.custom = false; }
      (void)cur;
    }
    if (fd.type == FT_HOTKEY) {
      fd.cap_dirty = false;
      fd.capturing = false;
    }
    if (fd.type == FT_EDIT && fd.edit && fd.editbuf) {
      SetWindowTextW(fd.edit, fd.editbuf);
    }
  }
  for (auto &fd : u->f) {
    if (fd.type == FT_PRESET && fd.pcustom) {
      *fd.pcustom = false;
      fd.custom = false;
    }
  }
  if (u->hwnd) {
    InvalidateRect(u->hwnd, nullptr, FALSE);
    UpdateWindow(u->hwnd);
  }
}

static void browse_folder() {
  IFileDialog *dlg = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_IFileDialog, (void **)&dlg);
  if (FAILED(hr) || !dlg) return;

  DWORD opts;
  dlg->GetOptions(&opts);
  dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
  dlg->SetTitle(L"Choose the clips folder");

  if (SUCCEEDED(dlg->Show(g_ui->hwnd))) {
    IShellItem *item = nullptr;
    if (SUCCEEDED(dlg->GetResult(&item)) && item) {
      PWSTR path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
        CField *fd = find_field(8);
        if (fd) {
          wcsncpy_s(fd->editbuf, KIRK_PATH_LEN, path, _TRUNCATE);
          if (fd->edit) SendMessageW(fd->edit, WM_SETTEXT, 0, (LPARAM)path);
        }
        CoTaskMemFree(path);
      }
      item->Release();
    }
  }
  dlg->Release();
}

static void finish_dialog(UI *u, bool saved) {
  tip_hide();
  if (!saved) {
  } else {
    for (auto &fd : u->f) {
      if (fd.type == FT_EDIT && fd.edit) {
        GetWindowTextW(fd.edit, fd.editbuf, fd.editmax);
      }
      if (fd.type == FT_HOTKEY && fd.cap_dirty) {
        if (fd.pvk) *fd.pvk = fd.cap_vk;
        if (fd.pmod) *fd.pmod = fd.cap_mod;
      }
    }
    wcsncpy_s(u->S.encoder, KIRK_STR_LEN, enc_vals[u->encSel], _TRUNCATE);
    // Custom (last) preserves a hand-edited kirk.yml value.
    if (u->presetSel >= 0 && u->presetSel < quality_count - 1) {
      wcsncpy_s(u->S.encoder_preset, 64, quality_vals[u->presetSel], _TRUNCATE);
    } else if (u->S.encoder_preset[0] == 0) {
      wcsncpy_s(u->S.encoder_preset, 64, L"p4", _TRUNCATE);
    }
    if (u->resSel >= 0 && u->resSel < res_count - 1) {
      u->S.max_width = (uint32_t)res_w[u->resSel];
      u->S.max_height = (uint32_t)res_h[u->resSel];
    } // Custom (last) leaves S.max_* untouched.
    if (u->micSel <= 0) {
      u->S.mic_device[0] = 0;
    } else if (u->micSel < (int)u->mic_items.size()) {
      // mic_items[0] is "(System default)"; micSel is already a mic_items
      // index (matched as dev_i -> micSel = i+1). The old code copied
      // mic_items[micSel-1], shifting every choice down one row on save:
      // the dialog showed N but saved N-1 (the "selects the item above"
      // bug, most visible on the mic dropdown).
      if (u->mic_items[(size_t)u->micSel] == L"(System default)") {
        u->S.mic_device[0] = 0;
      } else {
        wcsncpy_s(u->S.mic_device, KIRK_STR_LEN, u->mic_items[(size_t)u->micSel].c_str(), _TRUNCATE);
      }
    } else {
      u->S.mic_device[0] = 0;
    }
    // Second mic: extra_items[0] is "(None)"; extraSel is a direct index.
    if (u->extraSel <= 0 || u->extraSel >= (int)u->extra_items.size()) {
      u->S.extra_audio_device[0] = 0;
    } else if (u->extra_items[(size_t)u->extraSel] == L"(None)") {
      u->S.extra_audio_device[0] = 0;
    } else {
      wcsncpy_s(u->S.extra_audio_device, KIRK_STR_LEN, u->extra_items[(size_t)u->extraSel].c_str(), _TRUNCATE);
    }
    // System loopback source: render_items[0] is "(Default output)".
    if (u->sysDevSel <= 0 || u->sysDevSel >= (int)u->render_items.size()) {
      u->S.system_audio_device[0] = 0;
    } else if (u->render_items[(size_t)u->sysDevSel] == L"(Default output)") {
      u->S.system_audio_device[0] = 0;
    } else {
      wcsncpy_s(u->S.system_audio_device, KIRK_STR_LEN, u->render_items[(size_t)u->sysDevSel].c_str(), _TRUNCATE);
    }
    if (u->S.mic_gain_pct < 0 || u->S.mic_gain_pct > 200) u->S.mic_gain_pct = 100;
    if (u->S.system_gain_pct < 0 || u->S.system_gain_pct > 200) u->S.system_gain_pct = 100;

    if (!g_saved) g_saved = (kirk_settings *)calloc(1, sizeof(kirk_settings));
    if (g_saved) memcpy(g_saved, &u->S, sizeof(kirk_settings));
  }

  InterlockedExchange(&g_active, 0);
  if (u->owner && u->done_msg) {
    // Synchronous: the owner's WM_UI_DONE handler runs before the modal
    // loop exits, so no queued message is left behind for the loop to pump.
    // (PostMessage here used to race the loop's WM_QUIT exit: the save
    // result was sometimes never dispatched, and the thread-wide
    // PostQuitMessage below was consumed by the modal loop instead of the
    // app loop — so closing Settings swallowed an app-level Quit/WM_CLOSE
    // and the process lingered until killed.)
    SendMessageW(u->owner, u->done_msg, saved ? 1 : 0, 0);
  }
  DestroyWindow(u->hwnd);
}


static void draw_info_icon(HDC dc, UI *u, CField &fd) {
  RECT r = fd.info;
  int sz = r.right - r.left;
  HBRUSH br = fd.info_hover ? u->brBg2 : u->brBg1;
  HPEN pen = fd.info_hover ? u->penOrg : u->penBg3;
  ui_fill_round(dc, &r, br, sz / 2);
  ui_frame_round(dc, &r, pen, sz / 2);
  draw_text(dc, L"i", &r, fd.info_hover ? GV_FG0 : GV_FG2, g_ui->fSec,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void ui_paint(UI *u, HDC dc, RECT client) {
  ui_fill_rect(dc, &client, u->brBg0);

  draw_text(dc, L"kirk", &(RECT{ u->S_(26), u->S_(24), u->clientW - u->S_(26), u->S_(56) }),
            GV_FG0, u->fTitle, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
  draw_text(dc, L"Replay buffer, recording & storage settings",
            &(RECT{ u->S_(27), u->S_(58), u->clientW - u->S_(26), u->S_(84) }),
            GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
  ui_fill_rect(dc, &u->hdr[0], u->brBg3);

  RECT scroll = {client.left, u->scroll_top, client.right, u->scroll_top + u->scrolled_h};
  SaveDC(dc);
  IntersectClipRect(dc, scroll.left, scroll.top, scroll.right, scroll.bottom + 1);
  SetViewportOrgEx(dc, 0, -u->scroll_y, nullptr);

  for (auto &c : u->cards) {
    ui_fill_round(dc, &c.rc, u->brBg0H, u->R_card());
    ui_frame_round(dc, &c.rc, u->penBg1, u->R_card());
    draw_text(dc, c.title.c_str(),
              &(RECT{ c.rc.left + u->S_(16), c.rc.top + u->S_(8),
                      c.rc.right - u->S_(16), c.rc.top + u->S_(34) }),
              GV_GRAY, u->fSec, DT_LEFT | DT_SINGLELINE | DT_VCENTER);
  }

  if (u->rcWarn.bottom > u->rcWarn.top) {
    ui_fill_round(dc, &u->rcWarn, u->brBg0H, u->R_card());
    ui_frame_round(dc, &u->rcWarn, u->penRed, u->R_card());
    draw_text(dc, L"\u26A0  NOT TO BE MESSED WITH UNLESS YOU KNOW WHAT YOU ARE DOING",
              &u->rcWarn, GV_RED, u->fSec,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }

  {
    HFONT oldf = (HFONT)SelectObject(dc, u->fLbl);
    for (auto &fd : u->f) {
      if (!fd.has_info || !fd.label) continue;
      SIZE tsz = {0, 0};
      GetTextExtentPoint32W(dc, fd.label, (int)wcslen(fd.label), &tsz);
      int iconSz = u->S_(16);
      int gap = u->S_(5);
      int maxLeft = fd.ctrl.left - iconSz - u->S_(8);
      int iconLeft = fd.rc.left + tsz.cx + gap;
      if (iconLeft > maxLeft) iconLeft = maxLeft;
      if (iconLeft < fd.rc.left) iconLeft = fd.rc.left;
      int cy = fd.ctrl.top + ((fd.ctrl.bottom - fd.ctrl.top) - iconSz) / 2;
      fd.info = {iconLeft, cy, iconLeft + iconSz, cy + iconSz};
    }
    SelectObject(dc, oldf);
  }

  for (auto &fd : u->f) {
    int lrRight = fd.has_info ? fd.info.left - u->S_(5) : fd.ctrl.left - u->S_(12);
    RECT lr = {fd.rc.left, fd.rc.top, lrRight, fd.rc.bottom};
    switch (fd.type) {
      case FT_STEP: {
        RECT mn, vl, pl;
        step_rects(fd.ctrl, &mn, &vl, &pl, u->k);
        draw_text(dc, fd.label, &lr, GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        HBRUSH mbr = (fd.sub == HS_MINUS) ? u->brBg3 : u->brBg2;
        ui_fill_round(dc, &mn, mbr, u->R_ctrl());
        draw_text(dc, L"\u2212", &mn, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        ui_fill_round(dc, &vl, u->brBg1, u->R_ctrl());
        wchar_t txt[64];
        swprintf_s(txt, 64, L"%d%s", *fd.pval, fd.suffix ? fd.suffix : L"");
        draw_text(dc, txt, &vl, GV_FG0, u->fVal, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        HBRUSH pbr = (fd.sub == HS_PLUS) ? u->brBg3 : u->brBg2;
        ui_fill_round(dc, &pl, pbr, u->R_ctrl());
        draw_text(dc, L"+", &pl, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        break;
      }
      case FT_PRESET: {
        if (fd.custom && fd.pval) {
          RECT mn, vl, pl;
          step_rects(fd.ctrl, &mn, &vl, &pl, u->k);
          draw_text(dc, fd.label, &lr, GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
          HBRUSH mbr = (fd.sub == HS_MINUS) ? u->brBg3 : u->brBg2;
          ui_fill_round(dc, &mn, mbr, u->R_ctrl());
          draw_text(dc, L"\u2212", &mn, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
          ui_fill_round(dc, &vl, u->brBg1, u->R_ctrl());
          wchar_t txt[64];
          swprintf_s(txt, 64, L"%d%s", *fd.pval, fd.suffix ? fd.suffix : L"");
          draw_text(dc, txt, &vl, GV_FG0, u->fVal, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
          HBRUSH pbr = (fd.sub == HS_PLUS) ? u->brBg3 : u->brBg2;
          ui_fill_round(dc, &pl, pbr, u->R_ctrl());
          draw_text(dc, L"+", &pl, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
          draw_caret(dc, vl.right - u->S_(10), vl.top + (vl.bottom - vl.top) / 2, u->S_(3), GV_GRAY);
        } else {
          RECT cr = fd.ctrl;
          draw_text(dc, fd.label, &lr, GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
          HBRUSH bg = fd.hover ? u->brBg1 : u->brBg2;
          HPEN fr = fd.hover ? u->penBg3 : u->penBg1;
          ui_fill_round(dc, &cr, bg, u->R_ctrl());
          ui_frame_round(dc, &cr, fr, u->R_ctrl());
          if (fd.items && fd.pval) {
            int sel = preset_index_of(fd.preset_vals, *fd.pval);
            RECT tr = {cr.left + u->S_(12), cr.top, cr.right - u->S_(28), cr.bottom};
            const wchar_t *text = (sel >= 0 && sel < (int)fd.items->size()) ? (*fd.items)[sel].c_str() : L"Custom\u2026";
            draw_text(dc, text, &tr, GV_FG0, u->fVal, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
          }
          draw_caret(dc, cr.right - u->S_(16), cr.top + (cr.bottom - cr.top) / 2, u->S_(4), GV_FG1);
        }
        break;
      }
      case FT_COMBO: {
        RECT cr = fd.ctrl;
        draw_text(dc, fd.label, &lr, GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        HBRUSH bg = fd.hover ? u->brBg1 : u->brBg2;
        HPEN fr = fd.hover ? u->penBg3 : u->penBg1;
        ui_fill_round(dc, &cr, bg, u->R_ctrl());
        ui_frame_round(dc, &cr, fr, u->R_ctrl());
        if (fd.psel && fd.items) {
          int sel = *fd.psel;
          RECT tr = {cr.left + u->S_(12), cr.top, cr.right - u->S_(28), cr.bottom};
          const wchar_t *text = (sel >= 0 && sel < (int)fd.items->size()) ? (*fd.items)[sel].c_str() : L"";
          draw_text(dc, text, &tr, GV_FG0, u->fVal, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        }
        draw_caret(dc, cr.right - u->S_(16), cr.top + (cr.bottom - cr.top) / 2, u->S_(4), GV_FG1);
        break;
      }
      case FT_TOGGLE: {
        draw_text(dc, fd.label, &lr, GV_FG1, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        int pw = (int)(48 * u->k + 0.5f);
        int ph = (int)(22 * u->k + 0.5f);
        RECT pill = {fd.ctrl.right - pw, fd.ctrl.top + (fd.ctrl.bottom - fd.ctrl.top - ph) / 2,
                     fd.ctrl.right, fd.ctrl.top + (fd.ctrl.bottom - fd.ctrl.top - ph) / 2 + ph};
        bool on = fd.pflag && *fd.pflag != 0;
        HBRUSH c = on ? u->brGreen : u->brBg2;
        ui_fill_round(dc, &pill, c, (pill.bottom - pill.top) / 2);
        int pad = u->S_(3);
        int d = pill.bottom - pill.top - 2 * pad;
        RECT knob;
        if (on) knob = {pill.right - pad - d, pill.top + pad, pill.right - pad, pill.bottom - pad};
        else knob = {pill.left + pad, pill.top + pad, pill.left + pad + d, pill.bottom - pad};
        ui_fill_round(dc, &knob, u->brKnob, d / 2);
        RECT cob = pill;
        if (on) cob.right = knob.left - u->S_(4);
        else cob.left = knob.right + u->S_(4);
        draw_text(dc, on ? L"ON" : L"OFF", &cob, GV_FG0, u->fLbl,
                  on ? DT_RIGHT | DT_VCENTER | DT_SINGLELINE : DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
      }
      case FT_EDIT: {
        RECT chip = fd.ctrl;
        InflateRect(&chip, u->S_(2), u->S_(3));
        ui_fill_round(dc, &chip, u->brBg2, u->R_ctrl());
        draw_text(dc, fd.label, &lr, GV_FG2, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        break;
      }
      case FT_BUTTON: {
        HBRUSH bg = (fd.hover || fd.down) ? u->brBg2 : u->brBg1;
        ui_fill_round(dc, &fd.ctrl, bg, u->R_ctrl());
        ui_frame_round(dc, &fd.ctrl, fd.id == 20 ? u->penBg3 : u->penOrg, u->R_ctrl());
        COLORREF tc = (fd.id == 20) ? GV_FG1 : GV_BG0H;
        draw_text(dc, fd.label, &fd.ctrl, tc, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        break;
      }
      case FT_HOTKEY: {
        draw_text(dc, fd.label, &lr, GV_FG1, u->fLbl, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
        RECT cr = fd.ctrl;
        HBRUSH bg = (fd.capturing || fd.hover || fd.down) ? u->brBg1 : u->brBg2;
        HPEN fr = fd.capturing ? u->penOrg : (fd.hover ? u->penBg3 : u->penBg1);
        ui_fill_round(dc, &cr, bg, u->R_ctrl());
        ui_frame_round(dc, &cr, fr, u->R_ctrl());
        wchar_t txt[64];
        if (fd.capturing) {
          wcsncpy_s(txt, 64, L"Press a key combination...", _TRUNCATE);
          draw_text(dc, txt, &cr, GV_ORG, u->fVal, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        } else if (fd.cap_dirty) {
          hotkey_text(fd.cap_vk, fd.cap_mod, txt, 64);
          draw_text(dc, txt, &cr, GV_FG0, u->fVal, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        } else {
          hotkey_text(fd.pvk ? *fd.pvk : 0, fd.pmod ? *fd.pmod : 0, txt, 64);
          draw_text(dc, txt, &cr, GV_FG0, u->fVal, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        break;
      }
      case FT_SECTION:
        break;
    }
  }

  for (auto &fd : u->f) {
    if (fd.has_info) draw_info_icon(dc, u, fd);
  }

  if (u->focus >= 0 && u->focus < (int)u->f.size()) {
    CField &fd = u->f[u->focus];
    if (fd.type == FT_TOGGLE && fd.pflag) {
      int pw = (int)(48 * u->k + 0.5f);
      int ph = (int)(22 * u->k + 0.5f);
      RECT pill = {fd.ctrl.right - pw, fd.ctrl.top + (fd.ctrl.bottom - fd.ctrl.top - ph) / 2,
                   fd.ctrl.right, fd.ctrl.top + (fd.ctrl.bottom - fd.ctrl.top - ph) / 2 + ph};
      InflateRect(&pill, u->S_(2), u->S_(2));
      ui_frame_round(dc, &pill, u->penOrg, (pill.bottom - pill.top) / 2);
    } else if (fd.type != FT_EDIT && (fd.type != FT_BUTTON || fd.id == 20)) {
      ui_frame_round(dc, &fd.ctrl, u->penOrg, u->R_ctrl());
    }
  }

  RestoreDC(dc, -1);

  if (u->scroll_max > 0 && u->rcTrack.bottom > u->rcTrack.top) {
    int trackR = (u->rcTrack.right - u->rcTrack.left) / 2;
    ui_fill_round(dc, &u->rcTrack, u->brBg0H, trackR);
    HBRUSH tbr = u->sbDragging ? u->brOrg : (u->sbThumbHover ? u->brBg3 : u->brBg2);
    int thumbR = (u->rcThumb.right - u->rcThumb.left) / 2;
    if (u->rcThumb.bottom > u->rcThumb.top) {
      ui_fill_round(dc, &u->rcThumb, tbr, thumbR);
      if (u->sbDragging || u->sbThumbHover) {
        ui_frame_round(dc, &u->rcThumb, u->penOrg, thumbR);
      }
    }
  }

  draw_text(dc, L"Changes are applied when you save.",
            &(RECT{ u->rcReset.right + u->S_(12), u->rcCancel.top, u->rcCancel.left - u->S_(12), u->rcCancel.bottom }),
            GV_GRAY, u->fLbl, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  ui_fill_round(dc, &u->rcReset, u->brBg1, u->R_ctrl());
  ui_frame_round(dc, &u->rcReset, u->penBg3, u->R_ctrl());
  draw_text(dc, L"Reset to defaults", &u->rcReset, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  ui_fill_round(dc, &u->rcCancel, u->brBg1, u->R_ctrl());
  ui_frame_round(dc, &u->rcCancel, u->penBg3, u->R_ctrl());
  draw_text(dc, L"Cancel", &u->rcCancel, GV_FG1, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  ui_fill_round(dc, &u->rcSave, u->brOrg, u->R_ctrl());
  draw_text(dc, L"Save", &u->rcSave, GV_BG0H, u->fBtn, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void ui_make_resources(UI *u) {
  if (!u->brBg0) u->brBg0 = CreateSolidBrush(GV_BG0);
  if (!u->brBg0H) u->brBg0H = CreateSolidBrush(GV_BG0H);
  if (!u->brBg1) u->brBg1 = CreateSolidBrush(GV_BG1);
  if (!u->brBg2) u->brBg2 = CreateSolidBrush(GV_BG2);
  if (!u->brBg3) u->brBg3 = CreateSolidBrush(GV_BG3);
  if (!u->brGreen) u->brGreen = CreateSolidBrush(GV_GREEN);
  if (!u->brOrg) u->brOrg = CreateSolidBrush(GV_ORG);
  if (!u->brKnob) u->brKnob = CreateSolidBrush(GV_FG0);
  if (!u->brEdit) u->brEdit = CreateSolidBrush(GV_BG2);
  if (!u->penBg1) u->penBg1 = CreatePen(PS_SOLID, 1, GV_BG1);
  if (!u->penBg3) u->penBg3 = CreatePen(PS_SOLID, 1, GV_BG3);
  if (!u->penOrg) u->penOrg = CreatePen(PS_SOLID, 1, GV_ORG);
  if (!u->penRed) u->penRed = CreatePen(PS_SOLID, 1, GV_RED);
  if (!u->curArrow) u->curArrow = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
  if (!u->curHand) u->curHand = LoadCursorW(nullptr, MAKEINTRESOURCEW(32649));
}

static void ui_free_resources(UI *u) {
  if (u->brBg0) { DeleteObject(u->brBg0); u->brBg0 = nullptr; }
  if (u->brBg0H) { DeleteObject(u->brBg0H); u->brBg0H = nullptr; }
  if (u->brBg1) { DeleteObject(u->brBg1); u->brBg1 = nullptr; }
  if (u->brBg2) { DeleteObject(u->brBg2); u->brBg2 = nullptr; }
  if (u->brBg3) { DeleteObject(u->brBg3); u->brBg3 = nullptr; }
  if (u->brGreen) { DeleteObject(u->brGreen); u->brGreen = nullptr; }
  if (u->brOrg) { DeleteObject(u->brOrg); u->brOrg = nullptr; }
  if (u->brKnob) { DeleteObject(u->brKnob); u->brKnob = nullptr; }
  if (u->brEdit) { DeleteObject(u->brEdit); u->brEdit = nullptr; }
  if (u->penBg1) { DeleteObject(u->penBg1); u->penBg1 = nullptr; }
  if (u->penBg3) { DeleteObject(u->penBg3); u->penBg3 = nullptr; }
  if (u->penOrg) { DeleteObject(u->penOrg); u->penOrg = nullptr; }
  if (u->penRed) { DeleteObject(u->penRed); u->penRed = nullptr; }
  // stock cursors from LoadCursor(nullptr): do not destroy
  u->curArrow = nullptr;
  u->curHand = nullptr;
}

static void ui_make_fonts(UI *u) {
  if (u->fTitle) DeleteObject(u->fTitle);
  if (u->fSec) DeleteObject(u->fSec);
  if (u->fLbl) DeleteObject(u->fLbl);
  if (u->fVal) DeleteObject(u->fVal);
  if (u->fBtn) DeleteObject(u->fBtn);
  u->fTitle = make_font_dpi(20, FW_SEMIBOLD, false, (UINT)u->dpi);
  u->fSec   = make_font_dpi(9, FW_BOLD, false, (UINT)u->dpi);
  u->fLbl   = make_font_dpi(9, FW_NORMAL, false, (UINT)u->dpi);
  u->fVal   = make_font_dpi(10, FW_NORMAL, false, (UINT)u->dpi);
  u->fBtn   = make_font_dpi(10, FW_SEMIBOLD, false, (UINT)u->dpi);
  for (auto &fd : u->f) {
    if (fd.type == FT_EDIT && fd.edit) SendMessageW(fd.edit, WM_SETFONT, (WPARAM)u->fVal, TRUE);
  }
}

static void ui_move_focus(UI *u, int dir) {
  int n = (int)u->f.size();
  if (n == 0) return;
  // collect focusable fields
  int cur = u->focus;
  int i = 0;
  if (cur < 0) i = dir > 0 ? 0 : n - 1;
  else i = cur + dir;
  int guard = 0;
  while (guard++ < n) {
    if (i < 0) i = n - 1;
    if (i >= n) i = 0;
    CField &fd = u->f[i];
    bool focusable = fd.type == FT_STEP || fd.type == FT_COMBO || fd.type == FT_PRESET ||
                     fd.type == FT_TOGGLE ||
                     fd.type == FT_HOTKEY || fd.type == FT_EDIT ||
                     (fd.type == FT_BUTTON && fd.id == 20);
    if (focusable && i != cur) { u->focus = i; break; }
    i += dir;
  }
  if (u->focus >= 0) {
    CField &fd = u->f[u->focus];
    if (fd.type == FT_EDIT && fd.edit) SetFocus(fd.edit);
  }
  // Minimal repaint: old + new focus rings only (was full window).
  if (u->hwnd) {
    if (cur >= 0 && cur < (int)u->f.size()) ui_invalidate_field(u, u->f[cur]);
    if (u->focus >= 0 && u->focus < (int)u->f.size()) ui_invalidate_field(u, u->f[u->focus]);
  }
}

static LRESULT CALLBACK ui_wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
  UI *u = (UI *)GetWindowLongPtrW(h, GWLP_USERDATA);
  if (!u && m != WM_CREATE) return DefWindowProcW(h, m, w, l);

  switch (m) {
    case WM_NCCREATE: {
      LPCREATESTRUCTW cs = (LPCREATESTRUCTW)l;
      UI *uu = (UI *)cs->lpCreateParams;
      if (uu) {
        UINT d = ui_get_dpi_for_window(h);
        if (!d) {
          POINT pt = {cs->x, cs->y};
          if (pt.x == 0 && pt.y == 0) GetCursorPos((LPPOINT)&pt);
          d = ui_get_dpi_for_point(pt);
        }
        if (d >= 48 && d <= 768) { uu->dpi = (int)d; uu->k = (float)d / 96.0f; }
      }
      ui_enable_nc_scaling(h);
      return DefWindowProcW(h, m, w, l);
    }
    case WM_CREATE: {
      LPCREATESTRUCTW cs = (LPCREATESTRUCTW)l;
      u = (UI *)cs->lpCreateParams;
      u->mica = nt_build() >= 22000;
      {
        UINT d = ui_get_dpi_for_window(h);
        if (d >= 48 && d <= 768) { u->dpi = (int)d; u->k = (float)d / 96.0f; }
      }
      ui_make_resources(u);
      ui_make_fonts(u);
      ui_layout(u);
      apply_backdrop(h);  // once: never re-applied on hover/paint/setting change
      create_edits(u);
      ui_footer(u);
      ui_sync_edits(u);
      return 0;
    }
    case WM_GETMINMAXINFO: {
      MINMAXINFO *mmi = (MINMAXINFO *)l;
      RECT f = {0, 0, u->S_(610), u->S_(460)};
      DWORD style = (DWORD)GetWindowLongPtrW(h, GWL_STYLE);
      AdjustWindowRectEx(&f, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE, 0);
      (void)style;
      mmi->ptMinTrackSize.x = f.right - f.left;
      mmi->ptMinTrackSize.y = f.bottom - f.top;
      return 0;
    }
    case WM_SIZE: {
      RECT rc;
      popup_close();  // geometry moved: a stale popup would mis-hit
      GetClientRect(h, &rc);
      u->clientW = rc.right;
      u->clientH = rc.bottom;
      ui_footer(u);
      ui_sync_edits(u);
      InvalidateRect(h, nullptr, FALSE);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC:
      if (u) {
        HDC dc = (HDC)w;
        SetTextColor(dc, GV_FG1);
        SetBkColor(dc, GV_BG2);
        return (LRESULT)u->brEdit;
      }
      return (LRESULT)GetStockObject(NULL_BRUSH);
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(h, &ps);
      RECT rc;
      GetClientRect(h, &rc);
      if (rc.right > 0 && rc.bottom > 0) {
        HDC mem = CreateCompatibleDC(dc);
        HBITMAP bmp = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
        if (mem && bmp) {
          HBITMAP obm = (HBITMAP)SelectObject(mem, bmp);
          ui_paint(u, mem, rc);
          // Blit only the damaged rect instead of the full surface.
          int dx = ps.rcPaint.right - ps.rcPaint.left;
          int dy = ps.rcPaint.bottom - ps.rcPaint.top;
          if (dx > 0 && dy > 0)
            BitBlt(dc, ps.rcPaint.left, ps.rcPaint.top, dx, dy,
                   mem, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY);
          else
            BitBlt(dc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
          SelectObject(mem, obm);
        }
        if (bmp) DeleteObject(bmp);
        if (mem) DeleteDC(mem);
      }
      EndPaint(h, &ps);
      return 0;
    }
    case WM_TIMER:
      if (w == TM_TIP) {
        KillTimer(h, TM_TIP);
        tip_hide();
      }
      return 0;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
      POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
      if (g_popup) {
        popup_close();
        return 0;
      }
      tip_hide();
      // Owner-drawn scrollbar first (client coords): thumb drag or track page.
      if (u->scroll_max > 0 && u->rcTrack.bottom > u->rcTrack.top) {
        if (PtInRect(&u->rcThumb, pt)) {
          u->sbDragging = true;
          u->sbDragOff = pt.y - u->rcThumb.top;
          SetCapture(h);
          InvalidateRect(h, &u->rcTrack, FALSE);
          return 0;
        }
        if (PtInRect(&u->rcTrack, pt)) {
          if (pt.y < u->rcThumb.top) ui_scroll_to(u, u->scroll_y - u->scrolled_h);
          else ui_scroll_to(u, u->scroll_y + u->scrolled_h);
          return 0;
        }
      }
      // Footer buttons live in client coords: check before scroll offset.
      if (PtInRect(&u->rcSave, pt)) { finish_dialog(u, true); return 0; }
      if (PtInRect(&u->rcCancel, pt)) { finish_dialog(u, false); return 0; }
      if (PtInRect(&u->rcReset, pt)) {
        int rc = MessageBoxW(h,
          L"Reset all settings to the recommended defaults?\n\nYour current values will be replaced in this dialog. Nothing is saved until you press Save.",
          L"kirk \u2014 Reset to defaults", MB_YESNO | MB_ICONQUESTION);
        if (rc == IDYES) ui_reset_defaults(u);
        return 0;
      }
      POINT cpt = pt;
      cpt.y += u->scroll_y;

      HitSub sub;
      int idx = hit_row(cpt, &sub);
      if (idx < 0) {
        int old = u->focus;
        u->focus = -1;
        if (sub == HS_SAVE) finish_dialog(u, true);
        else if (sub == HS_CANCEL) finish_dialog(u, false);
        else if (sub == HS_RESET) {
          int rc = MessageBoxW(h,
            L"Reset all settings to the recommended defaults?\n\nYour current values will be replaced in this dialog. Nothing is saved until you press Save.",
            L"kirk \u2014 Reset to defaults", MB_YESNO | MB_ICONQUESTION);
          if (rc == IDYES) ui_reset_defaults(u);
        }
        else if (old >= 0 && old < (int)u->f.size()) ui_invalidate_field(u, u->f[old]);
        return 0;
      }
      {
        int old = u->focus;
        u->focus = idx;
        if (old != idx) {
          if (old >= 0 && old < (int)u->f.size()) ui_invalidate_field(u, u->f[old]);
          ui_invalidate_field(u, g_ui->f[idx]);
        }
      }
      CField &fd = g_ui->f[idx];
      bool opened_popup = false;
      if ((fd.type == FT_STEP || (fd.type == FT_PRESET && fd.custom)) && sub != HS_MAIN) {
        fd.down = true;
        stepper_change(fd, sub == HS_PLUS);
      } else if (fd.type == FT_STEP || (fd.type == FT_PRESET && fd.custom)) {
        // Custom numeric mode: main click re-opens presets so users can
        // leave Custom without hunting for another control.
        fd.down = true;
        popup_open(u, fd);
        opened_popup = true;
      } else if (fd.type == FT_PRESET) {
        popup_open(u, fd);
        opened_popup = true;
      } else if (fd.type == FT_COMBO) {
        popup_open(u, fd);
        opened_popup = true;
      } else if (fd.type == FT_TOGGLE) {
        toggle_change(fd);
      } else if (fd.type == FT_HOTKEY) {
        if (fd.capturing) hk_end_capture(u, fd);
        else hk_begin_capture(u, fd);
      } else if (fd.type == FT_BUTTON) {
        if (fd.id == 20) {
          fd.down = true;
          browse_folder();
          fd.down = false;
          ui_invalidate_field(u, fd);
        }
      }
      // Root cause fix for dead dropdowns: the old code called SetCapture(h)
      // right after popup_open, stealing mouse capture back from the popup
      // so the popup never received clicks. Only capture when no popup opened.
      if (!opened_popup) SetCapture(h);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (u->sbDragging) {
        u->sbDragging = false;
        if (GetCapture() == h) ReleaseCapture();
        InvalidateRect(h, nullptr, FALSE);
        return 0;
      }
      if (GetCapture() == h) ReleaseCapture();
      for (auto &fd : g_ui->f) fd.down = false;
      return 0;
    }
    case WM_MOUSEMOVE: {
      POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
      // Thumb drag: map mouse Y back to scroll offset.
      if (u->sbDragging && u->scroll_max > 0) {
        int trackH = u->rcTrack.bottom - u->rcTrack.top;
        int thumbH = u->rcThumb.bottom - u->rcThumb.top;
        int range = trackH - thumbH;
        int y = 0;
        if (range > 0) {
          y = (int)((long long)(pt.y - u->sbDragOff - u->rcTrack.top) * u->scroll_max / range);
        }
        ui_scroll_to(u, y);
        SetCursor(u->curHand ? u->curHand : LoadCursorW(nullptr, MAKEINTRESOURCEW(32649)));
        return 0;
      }
      if (!(w & MK_LBUTTON) && GetCapture() == h && !u->sbDragging) ReleaseCapture();
      POINT cpt = pt;
      cpt.y += u->scroll_y;

      // info icon hover + tooltip (tooltip window reused, not recreated)
      int info = hit_info(cpt);
      for (size_t i = 0; i < g_ui->f.size(); i++) {
        CField &fd = g_ui->f[i];
        if (fd.info_hover != ((int)i == info)) {
          fd.info_hover = (int)i == info;
          ui_invalidate_field(u, fd);
        }
      }
      if (info >= 0 && g_ui->f[info].tip) {
        POINT sp = pt;
        ClientToScreen(h, &sp);
        tip_show(sp, g_ui->f[info].tip, info);
        // Refresh the auto-hide timer without stacking duplicates.
        KillTimer(h, TM_TIP);
        SetTimer(h, TM_TIP, 6000, nullptr);
      } else if (info < 0) {
        tip_hide();
        KillTimer(h, TM_TIP);
      }

      HitSub sub;
      int idx = hit_row(cpt, &sub);
      bool changed = false;
      for (size_t i = 0; i < g_ui->f.size(); i++) {
        CField &fd = g_ui->f[i];
        bool hov = (int)i == idx;
        if (fd.hover != hov || (hov && fd.sub != sub)) {
          fd.hover = hov;
          fd.sub = hov ? sub : HS_NONE;
          changed = true;
          ui_invalidate_field(u, fd);
        }
      }

      // scrollbar hover (client coords)
      if (u->scroll_max > 0) {
        bool th = PtInRect(&u->rcThumb, pt) != 0;
        bool tr = PtInRect(&u->rcTrack, pt) != 0;
        if (th != u->sbThumbHover || tr != u->sbHover) {
          u->sbThumbHover = th;
          u->sbHover = tr;
          InvalidateRect(h, &u->rcTrack, FALSE);
        }
      }

      // cursor: hand over anything clickable (combos, presets, toggles,
      // hotkeys, buttons, steppers, footer, scrollbar) so affordance is obvious.
      bool clickable = info >= 0 || idx >= 0 || u->sbHover;
      if (!clickable) {
        if (PtInRect(&u->rcSave, pt) || PtInRect(&u->rcCancel, pt) || PtInRect(&u->rcReset, pt))
          clickable = true;
      }
      SetCursor(clickable ? (u->curHand ? u->curHand : LoadCursorW(nullptr, MAKEINTRESOURCEW(32649)))
                          : (u->curArrow ? u->curArrow : LoadCursorW(nullptr, MAKEINTRESOURCEW(32512))));

      if (!u->mouse_tracked) {
        TRACKMOUSEEVENT tme;
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = h;
        if (TrackMouseEvent(&tme)) u->mouse_tracked = true;
      }
      (void)changed;
      return 0;
    }
    case WM_MOUSELEAVE: {
      bool any = false;
      for (auto &fd : g_ui->f) {
        if (fd.hover || fd.sub != HS_NONE || fd.info_hover) any = true;
        fd.hover = false; fd.sub = HS_NONE; fd.info_hover = false;
      }
      if (u->sbHover || u->sbThumbHover) {
        any = true;
        u->sbHover = false;
        u->sbThumbHover = false;
      }
      tip_hide();
      KillTimer(h, TM_TIP);
      u->mouse_tracked = false;
      SetCursor(u->curArrow ? u->curArrow : LoadCursorW(nullptr, MAKEINTRESOURCEW(32512)));
      // Only repaint rows that were actually hovered (was full window).
      if (any) {
        for (auto &fd : g_ui->f) ui_invalidate_field(u, fd);
        if (u->scroll_max > 0) InvalidateRect(h, &u->rcTrack, FALSE);
      }
      return 0;
    }
    case WM_MOUSEWHEEL: {
      // A focused popup owns the wheel: otherwise the dialog scrolls UNDER
      // the open popup and every row offsets, so clicks land on the wrong
      // item. (Wheel can still arrive here if focus stayed behind.)
      if (g_popup && g_popup_ui == u) {
        SendMessageW(g_popup, WM_MOUSEWHEEL, w, l);
        return 0;
      }
      short delta = GET_WHEEL_DELTA_WPARAM(w);
      int step = u->S_(44);
      ui_scroll_to(u, u->scroll_y - (delta / WHEEL_DELTA) * step);
      return 0;
    }
    // No WM_VSCROLL: the scrollbar is owner-drawn (thumb drag / track
    // click / wheel above); there is no native control to send scroll
    // messages.
    case WM_KEYDOWN: {
      // capture-mode first
      CField *cap = nullptr;
      for (auto &fd : g_ui->f) if (fd.capturing) { cap = &fd; break; }

      if (cap) {
        if (w == VK_ESCAPE) {
          hk_end_capture(u, *cap);
          return 0;
        }
        if (w == VK_TAB) { hk_end_capture(u, *cap); ui_move_focus(u, GetKeyState(VK_SHIFT) < 0 ? -1 : 1); return 0; }
        // modifier/lock keys alone don't form a combination
        int vk = (int)w;
        if (vk == VK_CONTROL || vk == VK_SHIFT || vk == VK_MENU || vk == VK_LWIN || vk == VK_RWIN ||
            vk == VK_CAPITAL || vk == VK_NUMLOCK || vk == VK_SCROLL)
          return 0;
        int mod = 0;
        if (GetKeyState(VK_CONTROL) & 0x8000) mod |= MOD_CONTROL;
        if (GetKeyState(VK_MENU) & 0x8000) mod |= MOD_ALT;
        if (GetKeyState(VK_SHIFT) & 0x8000) mod |= MOD_SHIFT;
        if ((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) mod |= MOD_WIN;

        if (vk == VK_BACK || vk == VK_DELETE) {
          cap->cap_vk = 0; cap->cap_mod = 0; cap->cap_dirty = true;
          hk_end_capture(u, *cap);
          return 0;
        }

        // keyboard safety: bare letters/numbers would swallow typing
        if (mod == 0 && !(vk >= VK_F1 && vk <= VK_F24)) {
          MessageBoxW(h, L"Add a modifier (Ctrl/Alt/Shift) or use a function key (F1-F24).",
                      L"kirk \u2014 Hotkey", MB_OK | MB_ICONINFORMATION);
          return 0;
        }

        int cur_vk = cap->pvk ? *cap->pvk : 0;
        int cur_mod = cap->pmod ? *cap->pmod : 0;
        bool same = (cur_vk == vk && cur_mod == mod);
        if (!same && hk_conflicts_with_other(u, cap->id, vk, mod)) {
          MessageBoxW(h, L"That combination is already used by another kirk action. Choose a different one.",
                      L"kirk \u2014 Hotkey conflict", MB_OK | MB_ICONWARNING);
          return 0;
        }
        if (!same && !hk_try_register(u, vk, mod)) {
          MessageBoxW(h, L"That combination is unavailable \u2014 another application is already using it. Choose a different one.",
                      L"kirk \u2014 Hotkey unavailable", MB_OK | MB_ICONWARNING);
          return 0;
        }

        cap->cap_vk = vk; cap->cap_mod = mod; cap->cap_dirty = true;
        hk_end_capture(u, *cap);
        return 0;
      }

      if (w == VK_ESCAPE) {
        if (g_popup) popup_close();
        else finish_dialog(u, false);
        return 0;
      }
      if (w == VK_TAB) {
        ui_move_focus(u, GetKeyState(VK_SHIFT) < 0 ? -1 : 1);
        return 0;
      }
      if (w == VK_SPACE && u->focus >= 0 && u->focus < (int)u->f.size()) {
        CField &fd = u->f[u->focus];
        if (fd.type == FT_TOGGLE) toggle_change(fd);
        else if (fd.type == FT_HOTKEY) hk_begin_capture(u, fd);
        else if (fd.type == FT_BUTTON && fd.id == 20) browse_folder();
        else if (fd.type == FT_COMBO || fd.type == FT_PRESET) popup_open(u, fd);
        return 0;
      }
      if (w == VK_RETURN) {
        if (u->focus >= 0 && u->focus < (int)u->f.size()) {
          CField &fd = u->f[u->focus];
          if (fd.type == FT_HOTKEY) { hk_begin_capture(u, fd); return 0; }
          if (fd.type == FT_COMBO || fd.type == FT_PRESET) { popup_open(u, fd); return 0; }
          if (fd.type == FT_BUTTON && fd.id == 20) { browse_folder(); return 0; }
          if (fd.type == FT_EDIT) { finish_dialog(u, true); return 0; }
          if (fd.type == FT_TOGGLE || fd.type == FT_STEP) return 0;
        }
        finish_dialog(u, true);
        return 0;
      }
      if ((w == VK_UP || w == VK_LEFT || w == VK_DOWN || w == VK_RIGHT) &&
          u->focus >= 0 && u->focus < (int)u->f.size()) {
        CField &fd = u->f[u->focus];
        if (fd.type == FT_STEP || (fd.type == FT_PRESET && fd.custom)) {
          bool plus = (w == VK_UP || w == VK_RIGHT);
          stepper_change(fd, plus);
          return 0;
        }
        if (fd.type == FT_PRESET && !fd.custom && fd.preset_vals && fd.pval) {
          bool plus = (w == VK_UP || w == VK_RIGHT);
          int cur = preset_index_of(fd.preset_vals, *fd.pval);
          int last_preset = (int)fd.preset_vals->size() - 2;
          if (cur < 0) cur = 0;
          else cur += plus ? 1 : -1;
          if (cur < 0) cur = 0;
          if (cur > last_preset) cur = last_preset;
          *fd.pval = (*fd.preset_vals)[cur];
          ui_invalidate_field(u, fd);
          UpdateWindow(h);
          return 0;
        }
      }
      return 0;
    }
    case WM_COMMAND:
      return 0;
    case WM_DPICHANGED: {
      // Per-monitor DPI: rebuild scale-dependent state, keep values.
      UINT ndpi = HIWORD(w);
      if (ndpi >= 48 && ndpi <= 768) {
        u->dpi = (int)ndpi;
        u->k = (float)ndpi / 96.0f;
      } else {
        UINT d = ui_get_dpi_for_window(h);
        if (d >= 48 && d <= 768) { u->dpi = (int)d; u->k = (float)d / 96.0f; }
      }
      tip_hide();
      if (g_popup) popup_close();
      // Destroy edit HWNDs before relayout (positions are DPI-scaled).
      for (auto &fd : u->f) {
        if (fd.type == FT_EDIT && fd.edit) { DestroyWindow(fd.edit); fd.edit = nullptr; }
      }
      u->focus = -1;
      u->scroll_y = 0;
      u->sbDragging = false;
      u->sbHover = false;
      u->sbThumbHover = false;
      ui_make_fonts(u);
      ui_layout(u);
      create_edits(u);
      ui_footer(u);
      ui_sync_edits(u);
      // System suggests a new window rect in lParam.
      if (l) {
        RECT *nr = (RECT *)l;
        SetWindowPos(h, nullptr, nr->left, nr->top,
                     nr->right - nr->left, nr->bottom - nr->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      }
      InvalidateRect(h, nullptr, FALSE);
      return 0;
    }
    case WM_DESTROY:
      if (g_popup) popup_close();
      tip_hide();
      KillTimer(h, TM_TIP);
      DeleteObject(u->fTitle);
      DeleteObject(u->fSec);
      DeleteObject(u->fLbl);
      DeleteObject(u->fVal);
      DeleteObject(u->fBtn);
      u->fTitle = u->fSec = u->fLbl = u->fVal = u->fBtn = nullptr;
      ui_free_resources(u);
      // Never PostQuitMessage here: the quit is thread-wide and would be
      // consumed by this dialog's modal loop instead of the app's message
      // loop, so an app-level Quit/WM_CLOSE arriving while Settings is open
      // was swallowed (process lingered). The modal loop exits on `closed`;
      // an app quit arriving mid-modal is re-posted for the app loop.
      u->closed = true;
      return 0;
    case WM_CLOSE:
      finish_dialog(u, false);
      return 0;
  }
  return DefWindowProcW(h, m, w, l);
}


extern "C" {

void kirk_ui_init_dpi(void) {
  static LONG once = 0;
  if (InterlockedExchange(&once, 1) != 0) return;
  enable_dpi_awareness();
}

int kirk_ui_show(HWND owner, uint32_t settings_msg, const kirk_settings *initial) {
  if (!initial) return 0;
  if (InterlockedExchange(&g_active, 1) != 0) {
    HWND existing = FindWindowW(L"KirkSettingsWnd", nullptr);
    if (existing) SetForegroundWindow(existing);
    return 1;
  }

  enable_dpi_awareness();  // defensive: no-op if windows already exist

  UI *u = new UI;
  u->owner = owner;
  u->done_msg = settings_msg;
  memcpy(&u->S, initial, sizeof(kirk_settings));

  u->mic_items.push_back(L"(System default)");
  u->extra_items.push_back(L"(None)");
  u->render_items.push_back(L"(Default output)");
  u->micSel = 0;
  u->extraSel = 0;
  u->sysDevSel = 0;
  {
    // WASAPI enumeration needs COM on this thread; init locally so the
    // dialog open path never depends on caller COM state.
    HRESULT cok = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    kirk_audio_device_list devs;
    memset(&devs, 0, sizeof(devs));
    if (kirk_audio_enum_capture(&devs) == 0) {
      for (uint32_t i = 0; i < devs.count; i++) {
        std::wstring name = devs.devices[i].name ? devs.devices[i].name : L"(unknown)";
        u->mic_items.push_back(name);
        u->extra_items.push_back(name);
        if (devs.devices[i].name && u->S.mic_device[0] &&
            wcscmp(devs.devices[i].name, u->S.mic_device) == 0) {
          u->micSel = (int)i + 1;
        }
        if (devs.devices[i].name && u->S.extra_audio_device[0] &&
            wcscmp(devs.devices[i].name, u->S.extra_audio_device) == 0) {
          u->extraSel = (int)i + 1;
        }
      }
      kirk_audio_enum_free(&devs);
    }
    kirk_audio_device_list outs;
    memset(&outs, 0, sizeof(outs));
    if (kirk_audio_enum_render(&outs) == 0) {
      for (uint32_t i = 0; i < outs.count; i++) {
        std::wstring name = outs.devices[i].name ? outs.devices[i].name : L"(unknown)";
        u->render_items.push_back(name);
        if (outs.devices[i].name && u->S.system_audio_device[0] &&
            wcscmp(outs.devices[i].name, u->S.system_audio_device) == 0) {
          u->sysDevSel = (int)i + 1;
        }
      }
      kirk_audio_enum_free(&outs);
    }
    if (SUCCEEDED(cok)) CoUninitialize();
  }

  u->encSel = 0;
  for (int i = 0; i < enc_count; i++) {
    if (wcscmp(initial->encoder, enc_vals[i]) == 0) { u->encSel = i; break; }
  }

  // Quality preset: match stored value case-insensitively, else Custom.
  u->presetSel = quality_count - 1;
  if (initial->encoder_preset[0] == 0) {
    u->presetSel = 2;  // empty = p4 Balanced
    wcsncpy_s(u->S.encoder_preset, 64, L"p4", _TRUNCATE);
  } else {
    for (int i = 0; i < quality_count - 1; i++) {
      if (_wcsicmp(initial->encoder_preset, quality_vals[i]) == 0) { u->presetSel = i; break; }
    }
  }

  // Resolution cap: match stored dimensions, else Custom (preserves yml).
  u->resSel = res_count - 1;
  for (int i = 0; i < res_count - 1; i++) {
    if ((int)initial->max_width == res_w[i] && (int)initial->max_height == res_h[i]) { u->resSel = i; break; }
  }
  if (initial->max_width == 0 && initial->max_height == 0) u->resSel = 0;

  g_ui = u;

  // Per-monitor DPI at the cursor (where the window will appear), not the
  // system-wide DC value — fixes blurry/upscaled rendering at 125-200%.
  {
    POINT cur = {0, 0};
    GetCursorPos((LPPOINT)&cur);
    UINT d = ui_get_dpi_for_point(cur);
    u->dpi = (d >= 48 && d <= 768) ? (int)d : 96;
  }
  u->k = (float)u->dpi / 96.0f;
  ui_layout(u);

  WNDCLASSW wc;
  memset(&wc, 0, sizeof(wc));
  wc.lpfnWndProc = (WNDPROC)ui_wndproc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hIcon = app_icon();
  wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
  wc.hbrBackground = nullptr;
  wc.lpszClassName = L"KirkSettingsWnd";
  RegisterClassW(&wc);

  // pick a default height: fit the monitor where the window opens, else scroll
  RECT work = {0, 0, 0, 0};
  {
    POINT cur = {0, 0};
    GetCursorPos((LPPOINT)&cur);
    HMONITOR mon = MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (mon && GetMonitorInfoW(mon, &mi)) work = mi.rcWork;
    else SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  }
  int capH = (int)((work.bottom - work.top) * 0.86f);
  int foot = u->S_(34) + u->S_(18) + u->S_(6);
  int totalContent = u->content_end + foot;
  int wantH = totalContent < capH ? totalContent : capH;
  u->clientH = wantH;
  u->clientW = u->S_(580);
  ui_footer(u);

  // No WS_VSCROLL: the scrollbar is owner-drawn in gruvbox colors.
  DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;

  RECT frame = {0, 0, u->clientW, u->clientH};
  AdjustWindowRectEx(&frame, style, FALSE, 0);

  int ww = frame.right - frame.left, wh = frame.bottom - frame.top;
  int mw = u->S_(610), mh = u->S_(460);
  if (ww < mw) ww = mw;
  if (wh < mh) wh = mh;
  int cx = work.left + ((work.right - work.left) - ww) / 2;
  int cy = work.top + ((work.bottom - work.top) - wh) / 2;
  if (cx < work.left) cx = work.left;
  if (cy < work.top) cy = work.top;
  u->hwnd = CreateWindowExW(
    0, L"KirkSettingsWnd", L"kirk \u2014 Settings",
    style,
    cx, cy, ww, wh,
    owner, nullptr, wc.hInstance, (LPVOID)u);
  if (!u->hwnd) {
    InterlockedExchange(&g_active, 0);
    g_ui = nullptr;
    ui_free_layout_items(u);
    delete u;
    return 0;
  }
  SetWindowLongPtrW(u->hwnd, GWLP_USERDATA, (LONG_PTR)u);
  ShowWindow(u->hwnd, SW_SHOWNORMAL);
  SetForegroundWindow(u->hwnd);

  // Modal loop on the calling thread. Exits when the dialog is destroyed
  // (`closed`, set in WM_DESTROY) — never via PostQuitMessage, which is
  // thread-wide and used to swallow app-level Quit/WM_CLOSE posted while
  // Settings was open (the 15s harness timeout / lingering process). An
  // app quit arriving mid-modal is re-posted so the app loop still quits.
  MSG msg;
  while (!u->closed) {
    int r = GetMessageW(&msg, nullptr, 0, 0);
    if (r == 0) {
      if (!u->closed && u->hwnd && IsWindow(u->hwnd)) DestroyWindow(u->hwnd);
      PostQuitMessage((int)msg.wParam);
      break;
    }
    if (r < 0) break;
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }

  ui_free_layout_items(u);
  u->f.clear();
  g_ui = nullptr;
  delete u;
  return 1;
}

int kirk_ui_active(void) {
  return InterlockedCompareExchange(&g_active, 0, 0) ? 1 : 0;
}

const kirk_settings *kirk_ui_last_saved(void) {
  return g_saved;
}

int kirk_set_run_at_startup(const wchar_t *cmdline, int enabled) {
  HKEY key;
  LONG hr = RegCreateKeyExW(HKEY_CURRENT_USER,
                            L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                            0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (hr != ERROR_SUCCESS) return -1;
  if (enabled) {
    hr = RegSetValueExW(key, L"kirk", 0, REG_SZ,
                        (const BYTE *)cmdline, (DWORD)((wcslen(cmdline) + 1) * sizeof(wchar_t)));
  } else {
    hr = RegDeleteValueW(key, L"kirk");
    if (hr == ERROR_FILE_NOT_FOUND) hr = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return hr == ERROR_SUCCESS ? 0 : -1;
}

}  // extern "C"