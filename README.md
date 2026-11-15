# AutoBrightness

Adaptive screen brightness for Windows laptops that **have no ambient light sensor** — the webcam is used as a light meter.

Windows only dims the screen to a fixed level on battery; it does not react to the room. MacBooks and many phones do (Auto-Brightness), because they ship an ambient light sensor (ALS). Most Windows laptops don't. This script adds the feature in software:

```
webcam frame ──▶ mean brightness (ffmpeg signalstats)
            ──▶ luminance → brightness curve
            ──▶ WMI WmiSetBrightness (internal panel)
```

Every 20 seconds it grabs one frame from the webcam, measures how bright the room is, and moves the internal display to a matching level — smoothly, without fighting you when you set the brightness yourself.

> Tested on an **ASUS ROG Zephyrus G14 (GA403UV), Windows 11**, which has no ACPI0008 / no sensor-class device at all. It works on any Windows 10/11 laptop whose internal panel responds to `WmiMonitorBrightness`.

## Why the webcam

`Get-PnpDevice -Class Sensor` returning nothing, no `ACPI0008` device and no "Ambient Light" PnP entity means there is literally no ALS to read. A front camera is the only light sensor such a machine has. A single downscaled frame, averaged, is a good enough proxy for room luminance — good enough to tell "sunlit desk" from "lamp at night".

The trade-off is the camera indicator LED lighting up for ~2 seconds per sample. If that bothers you, there is a clock-only mode that uses the time of day instead (see [Clock-only mode](#clock-only-mode)).

## Requirements

- Windows 10 or 11 with an internal display that supports WMI brightness control (`WmiMonitorBrightness`). External monitors are not covered.
- **ffmpeg** on `PATH`, or set `ffmpegPath` in the config. Install with `winget install Gyan.FFmpeg` if needed.
- PowerShell 5.1 (built in).
- No admin rights needed for normal use.

## Install

```powershell
git clone https://github.com/samtaiq/win-auto-brightness.git
cd win-auto-brightness

# 1. check your machine is supported
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action diag

# 2. try it in the foreground (Ctrl+C or close the window to stop)
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action run

# 3. or run it in the background and start it at logon
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action install
```

`install.bat` does step 3 for you (double-click it). `uninstall.bat` removes the logon task and stops the daemon.

## Commands

| Action | What it does |
| --- | --- |
| `-Action run` | Run in the foreground with live output (debugging) |
| `-Action start` / `stop` | Start / stop the background daemon |
| `-Action status` | Current brightness, last ambient reading, pause state |
| `-Action toggle` | Start if stopped, stop if running |
| `-Action pause -Minutes 60` | Pause automation for N minutes |
| `-Action resume` | Resume immediately |
| `-Action measure -Interval 3` | Sample 10 times and print ambient → mapped → current, **without changing brightness** (use it to tune the curve) |
| `-Action diag` | Hardware check: sensor, panel, brightness control, ffmpeg, camera |
| `-Action config` | Print the config file path and contents |
| `-Action install` / `uninstall` | Add / remove the logon task |

Extra parameters: `-FakeLuminance 200` (pretend the room is that bright, without opening the camera), `-Quiet` (no console output).

## How it decides

- **Sampling** — one webcam frame every `sampleIntervalSec` (default 20 s). Frames are downscaled to 32×18 before averaging, so a sample costs milliseconds of CPU.
- **Curve** — ambient luminance → brightness percent, interpolated in log space over `curve` (default: 3 → 8 %, 8 → 16 %, 18 → 28 %, 40 → 45 %, 80 → 62 %, 140 → 82 %, 210 → 100 %).
- **Big change = follow now** — a jump of ≥ `fastJumpThreshold` (25) points fades over ~1 second.
- **Small drift = smooth** — smaller differences use an exponential moving average (`alphaUp` / `alphaDown`), and changes under `deadband` are ignored, so clouds and noise don't make the screen flicker.
- **Hands off when you take over** — if the brightness you see differs from what the script last set by more than 5 points, it assumes you used the brightness keys and pauses for `manualOverrideHoldMin` (30 min).
- **Battery** — applies `batteryOffset` (−6 %) on battery.
- **Idle / locked / display off** — sampling is throttled or skipped.

## Configuration

`%LOCALAPPDATA%\AutoBrightness\config.json` — edit it and the running daemon picks up the change within one cycle.

| Key | Default | Meaning |
| --- | --- | --- |
| `source` | `camera` | `camera` or `clock` |
| `cameraName` | `""` | Camera to use; empty = auto-pick the first real (non-virtual) camera |
| `ffmpegPath` | `""` | Override the ffmpeg executable path |
| `sampleIntervalSec` | `20` | Seconds between samples |
| `burstFrames` | `3` | Frames captured per sample (median is used) |
| `curve` | see above | `[[luminance, brightness], ...]` pairs |
| `minBrightness` / `maxBrightness` | `5` / `100` | Clamp |
| `alphaUp` / `alphaDown` | `0.25` / `0.5` | EMA weight for small drifts |
| `deadband` | `2` | Ignore changes smaller than this |
| `fastJumpThreshold` | `25` | Δ that triggers an immediate fade |
| `manualOverrideHoldMin` | `30` | Pause length after you change brightness yourself (0 = never pause) |
| `batteryOffset` | `-6` | Brightness offset on battery |
| `idleThrottleFactor` | `5` | Multiply the interval when idle |
| `clockCurve` | see script | Hour → brightness, used by clock mode |

Runtime files live next to it: `state.json`, `daemon.pid`, `autobrightness.log`.

## Limitations

1. **The webcam LED blinks** for about 2 seconds per sample. Unavoidable without an ALS.
2. The camera is busy during a sample; if OBS / NVIDIA Broadcast is using it, that cycle fails and is retried later (logged).
3. **Internal panel only.** External monitors ignore `WmiSetBrightness`.
4. No lux calibration — the curve is empirical. Use `-Action measure` in your real lighting and edit `curve`.
5. Sampling every 20 s means a 10–20 s delay before reacting to a change in the room.

## Clock-only mode

No camera, no LED — brightness follows the time of day instead:

```json
{ "source": "clock" }
```

`clockCurve` maps hour → brightness (default: 30 % at midnight, 60 % at 08:00, 75 % at noon, 45 % at 20:00). It won't react to a lamp or a curtain, but it is silent and private.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action uninstall
```

Then delete `%LOCALAPPDATA%\AutoBrightness`. Restore your brightness manually — the script leaves the panel at whatever it last set.

---

# 中文說明

**用途**:幫沒有環境光感測器 (ALS) 的 Windows 筆電做「自動亮度」——像 macOS 的 Auto-Brightness。

Windows 本身只會在電池模式下把螢幕調暗一個固定值,不會跟著房間光線走。MacBook 有 ALS 所以會,大部分 Windows 筆電沒有。這支腳本用**前鏡頭當光度計**:每 20 秒拍一格 → 算平均亮度 → 查曲線 → 用 WMI 調內建螢幕亮度。

實測機型:**ASUS ROG Zephyrus G14 (GA403UV),Windows 11**,完全沒有 `ACPI0008` / 沒有 Sensor 類裝置。任何支援 `WmiMonitorBrightness` 的 Win10/11 筆電都可用。

**快速開始**

```powershell
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action diag    # 檢查硬件
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action run     # 前景試跑
powershell -ExecutionPolicy Bypass -File .\AutoBrightness.ps1 -Action install # 背景常駐 + 開機自啟
```

**行為重點**

- 大變動(≥25%)→ 1 秒淡入淡出立即跟;小漂移 → EMA 平滑;小於 2% 不動
- 你手動改亮度(差 >5%)→ 自動暫停 30 分鐘
- 用電池 -6%;閒置 / 鎖屏 / 螢幕關閉 → 降低或跳過採樣
- 改 `%LOCALAPPDATA%\AutoBrightness\config.json` 即時生效,不用重啟

**已知限制**

1. 每次取樣鏡頭 LED 會亮約 2 秒(沒有 ALS 的代價)
2. 取樣時鏡頭被佔用;OBS / NVIDIA Broadcast 撞用會失敗,下一輪重試
3. 只調**內建面板**,外接螢幕不受控
4. 曲線是經驗值,用 `-Action measure` 對住實際環境調 `curve`
5. 20 秒一次 → 環境變化後約 10–20 秒才反應

**純時鐘模式**(不用鏡頭、零 LED):`config.json` 改 `"source": "clock"`,用 `clockCurve` 按時間調(中午 75%、夜晚 30%)。

**移除**:`-Action uninstall`,再刪 `%LOCALAPPDATA%\AutoBrightness`。

## License

MIT
