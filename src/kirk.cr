require "log"

require "./platform/win32/win32"
require "./platform/win32/shim"
require "./app/config"
require "./app/ffmpeg_engine"
require "./app/buffer"
require "./app/voice"
require "./app/storage"
require "./app/games"
require "./app/tray"
require "./app/application"

Win32.detach_console

# Must run before any window is created, or the dialog is bitmap-upscaled.
LibShim.kirk_ui_init_dpi

cfg = Kirk::Settings.load("kirk.yml")
app = Kirk::Application.new(cfg)
exit app.run
