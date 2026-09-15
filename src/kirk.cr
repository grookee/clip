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

# Second instance exits immediately: without this, two processes each own
# a tray icon and a ~1GB rolling ffmpeg capture. The puts is best-effort:
# with no console attached the handle may be invalid, so never let it fail.
unless Win32.claim_single_instance("kirk-single-instance")
  begin
    STDERR.puts "kirk: another instance is already running; exiting"
  rescue
  end
  exit 0
end

# Must run before any window is created, or the dialog is bitmap-upscaled.
LibShim.kirk_ui_init_dpi

settings_path = Kirk::Settings.default_path
Kirk::Settings.migrate_legacy!(settings_path)
cfg = Kirk::Settings.load(settings_path)
app = Kirk::Application.new(cfg, settings_path)
exit app.run
