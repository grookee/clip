# kirk

<p align="center">
  <a href="https://github.com/grookee/clip/actions/workflows/ci.yml"><img src="https://github.com/grookee/clip/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
</p>

~ tiny gameplay clipping for windows.

hit a hotkey, keep the last n seconds. everything runs locally - no accounts,
no cloud, no telemetry.

## features

- rolling replay buffer; `f8` saves the last n seconds to mp4
- local voice commands (`"kirk, clip that!"`) via sapi, nothing leaves the machine
- `f9` toggles recording, `f10` takes a screenshot
- hardware encoding when available (nvenc > amf > qsv), x264 fallback
- system tray with a native settings dialog
- clip-saved feedback: windows notification, chime, both, or silent
- storage cap with oldest-first auto-delete
- clips, config, and logs all live under `%localappdata%\kirk`

---

## getting started

### prerequisites

- windows 10/11 x64
- to build: crystal 1.13+, visual studio 2022 build tools, powershell

### install

grab the `.msix` from
[releases](https://github.com/grookee/clip/releases), trust the bundled `.cer`
once, then `add-appxpackage`. or unzip the portable build anywhere and run
`kirk.exe`.

### build from source

```powershell
powershell -executionpolicy bypass -file scripts\build.ps1
```

the exe lands in `build\`. for an installer package:

```powershell
powershell -executionpolicy bypass -file scripts\build_msix.ps1
```

## configuration

settings live in `%localappdata%\kirk\kirk.yml` (a legacy `./kirk.yml`
migrates there on first run). everything is editable in the settings dialog;
the main knobs:

| key                  | purpose                                  |
| -------------------- | ---------------------------------------- |
| `replay_seconds`     | how far back a clip goes                 |
| `segment_seconds`    | on-disk buffer chunk size                |
| `fps`                | capture framerate                        |
| `bitrate_kbps`       | video bitrate                            |
| `hw_encoder`         | `""` = auto, or `h264_nvenc` etc.        |
| `encoder_preset`     | quality/speed: `p1`..`p7`, `speed`/`balanced`/`quality`, or x264 names |
| `max_width`          | downscale cap, `0` = native (e.g. `1920`) |
| `max_height`         | downscale cap, `0` = native (e.g. `1080`) |
| `capture_audio`      | master switch for clip audio (mics + system) |
| `mic_device`         | primary mic, `""` = system default mic       |
| `extra_audio_devices`| extra mics mixed in (list, e.g. `["Yeti"]`)  |
| `capture_system_audio` | loop back game/discord output into clips   |
| `system_audio_device`| loopback *capture* device (e.g. `Stereo Mix`, `CABLE-A Output`), `""` = mics only |
| `mic_gain`           | mic loudness, `1.0` = unity (0..2)           |
| `system_gain`        | system-audio loudness, `1.0` = unity (0..2)  |
| `voice_enabled`      | voice commands on/off                    |
| `voice_language`     | `"auto"` = follow the Windows default recognizer (fixes `0x80045052` on en-GB/de machines), or `"en-US"`/`"en-GB"` etc. to prefer that recognizer |
| `voice_command`      | `;`-separated trigger phrases            |
| `voice_confidence`   | accept floor, `0.01` = lenient (tune in Settings > Voice) |
| `voice_cooldown_ms`  | repeat-command ignore window              |
| `voice_isolation_ms` | chatter-burst window (kirk.yml only)      |
| `voice_high_confidence` | bypasses the burst gate (kirk.yml only) |
| `hotkey_clip_vk`     | clip hotkey (`0x77` = f8)                |
| `storage_limit_gb`   | max clip folder size                     |
| `clips_dir`          | `""` = default clips folder              |
| `show_save_notifications` | windows notification on clip save   |
| `play_save_sound`  | chime (`clip.wav`) on clip save            |
| `verbose_logging`    | extra local logging                      |

## project structure

```
src/
  kirk.cr            entry point
  app/               settings, capture engine, voice, tray, ui bridge
  platform/win32/    win32 + shim ffi bindings
native/
  src/               shim dll: audio, voice (sapi), settings dialog
  include/           shared c abi header
scripts/             builds, msix packager, keyboard diagnostic
.github/workflows/  ci build + tagged releases
```

## scripts

| command                          | what it does                        |
| -------------------------------- | ----------------------------------- |
| `scripts\build.ps1`              | full build: shim.dll + kirk.exe     |
| `scripts\build_shim.ps1`         | native shim only                    |
| `scripts\build_msix.ps1`         | package (and optionally sign) msix  |
| `scripts\diag_keyboard.ps1`      | prove hotkeys never swallow typing  |

## license

[GPLv3](LICENSE)
