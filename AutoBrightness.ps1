<#
AutoBrightness.ps1 -- ambient-light driven display brightness for Windows.

Target machine : ASUS ROG Zephyrus G14 GA403UV (this model has no ACPI0008 ambient light sensor)
Light source   : front UVC webcam used as a luminance meter (ffmpeg / dshow)
Output         : WMI WmiSetBrightness on the internal eDP panel

Usage:
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action diag
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action measure
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action start
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action status
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action pause -Minutes 60
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action stop
  powershell -ExecutionPolicy Bypass -File AutoBrightness.ps1 -Action install
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'start', 'stop', 'status', 'toggle', 'pause', 'resume',
                 'install', 'uninstall', 'diag', 'measure', 'config')]
    [string]$Action = 'status',

    [int]$Minutes = 0,
    [int]$Interval = 0,
    [double]$FakeLuminance = -1,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- paths / const

$Root       = Join-Path $env:LOCALAPPDATA 'AutoBrightness'
$ConfigPath = Join-Path $Root 'config.json'
$StatePath  = Join-Path $Root 'state.json'
$PidPath    = Join-Path $Root 'daemon.pid'
$LogPath    = Join-Path $Root 'autobrightness.log'
$TmpDir     = Join-Path $Root 'tmp'
$TaskName   = 'AutoBrightness'
$MutexName  = 'AutoBrightness-SingleInstance'
$WmiNs      = 'root/wmi'
$InternalFlag = 0x80000000
$CamTimeoutMs = 9000

foreach ($d in @($Root, $TmpDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$script:Quiet = [bool]$Quiet

# ---------------------------------------------------------------- logging

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $script:Quiet) {
        if ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
        elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    }
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item $LogPath ($LogPath + '.1') -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- config / state

function Get-DefaultConfig {
    [ordered]@{
        source                = 'camera'
        cameraName            = ''
        ffmpegPath            = ''
        sampleIntervalSec     = 20
        burstFrames           = 3
        curve                 = @(@(3, 8), @(8, 16), @(18, 28), @(40, 45), @(80, 62), @(140, 82), @(210, 100))
        minBrightness         = 5
        maxBrightness         = 100
        alphaUp               = 0.25
        alphaDown             = 0.50
        deadband              = 2
        fastJumpThreshold     = 25
        manualOverrideHoldMin = 30
        batteryOffset         = -6
        idleThrottleFactor    = 5
        clockCurve            = @(@(0, 30), @(6, 35), @(8, 60), @(12, 75), @(17, 70), @(20, 45), @(23, 32), @(24, 30))
    }
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        $cfg = Get-DefaultConfig
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $ConfigPath -Encoding UTF8
        return $cfg
    }
    try {
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        $cfg = Get-DefaultConfig
        foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        return $cfg
    } catch {
        Write-Log ('config.json unreadable, using defaults: ' + $_.Exception.Message) 'WARN'
        return Get-DefaultConfig
    }
}

function Read-State {
    $blank = [ordered]@{
        lastSetBrightness = -1
        smoothed          = -1
        suspendUntil      = 0
        lastLux           = -1
        lastTs            = 0
        lastError         = ''
    }
    if (-not (Test-Path $StatePath)) { return $blank }
    try {
        $o = (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
        $s = [ordered]@{}
        foreach ($k in @('lastSetBrightness', 'smoothed', 'suspendUntil', 'lastLux', 'lastTs')) {
            $v = $o.PSObject.Properties[$k]
            $s[$k] = if ($v -and $null -ne $v.Value) { [double]$v.Value } else { -1 }
        }
        $e = $o.PSObject.Properties['lastError']
        $s['lastError'] = if ($e -and $null -ne $e.Value) { [string]$e.Value } else { '' }
        return $s
    } catch { return $blank }
}

function Save-State {
    param($State)
    try { ($State | ConvertTo-Json -Depth 4) | Set-Content -Path $StatePath -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- display / WMI

$script:MethodCache = @()
$script:MethodCacheAt = 0

function Get-InternalDisplayInstance {
    $res = @()
    try {
        $res = @(Get-CimInstance -Namespace $WmiNs -ClassName WmiMonitorConnectionParams -ErrorAction Stop |
                 Where-Object { ([uint32]$_.VideoOutputTechnology -band $InternalFlag) -ne 0 } |
                 Select-Object -ExpandProperty InstanceName)
    } catch { }
    if ($res.Count -eq 0) {
        try {
            $res = @(Get-CimInstance -Namespace $WmiNs -ClassName WmiMonitorBrightness -ErrorAction Stop |
                     Select-Object -ExpandProperty InstanceName)
        } catch { }
    }
    return $res
}

function Get-BrightnessMethods {
    param([string[]]$Internal)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ((@($script:MethodCache).Count -gt 0) -and (($now - $script:MethodCacheAt) -lt 120000)) {
        return $script:MethodCache
    }
    $all = @(Get-CimInstance -Namespace $WmiNs -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }
    $picked = @()
    if (@($Internal).Count -gt 0) {
        $picked = @($all | Where-Object { $Internal -contains $_.InstanceName })
    }
    if ($picked.Count -eq 0) { $picked = $all }
    $script:MethodCache = $picked
    $script:MethodCacheAt = $now
    return $picked
}

function Get-CurrentBrightness {
    param([string[]]$Internal)
    try {
        $all = @(Get-CimInstance -Namespace $WmiNs -ClassName WmiMonitorBrightness -ErrorAction Stop)
        if ($all.Count -eq 0) { return -1 }
        $pick = $null
        if (@($Internal).Count -gt 0) {
            $pick = $all | Where-Object { $Internal -contains $_.InstanceName } | Select-Object -First 1
        }
        if (-not $pick) { $pick = $all | Select-Object -First 1 }
        return [int]$pick.CurrentBrightness
    } catch { return -1 }
}

function Set-BrightnessRaw {
    param([int]$Percent, [string[]]$Internal)
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    $methods = @(Get-BrightnessMethods -Internal $Internal)
    if ($methods.Count -eq 0) { throw 'no WmiMonitorBrightnessMethods instance' }
    foreach ($m in $methods) {
        Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness `
            -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$pct } -ErrorAction Stop | Out-Null
    }
}

function Set-BrightnessSmooth {
    param([int]$Target, [int]$Current, [string[]]$Internal)
    if ($Current -lt 0) { $Current = Get-CurrentBrightness -Internal $Internal }
    $delta = $Target - $Current
    if ([Math]::Abs($delta) -lt 2) {
        Set-BrightnessRaw -Percent $Target -Internal $Internal
        return
    }
    $steps = [Math]::Min(14, [Math]::Max(3, [Math]::Abs($delta)))
    for ($i = 1; $i -le $steps; $i++) {
        $v = [int][Math]::Round($Current + ($delta * $i / $steps))
        try { Set-BrightnessRaw -Percent $v -Internal $Internal } catch { }
        if ($i -lt $steps) { Start-Sleep -Milliseconds 55 }
    }
}

# ---------------------------------------------------------------- power / idle

Add-Type -Namespace AbNative -Name Power -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS {
    public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent;
    public byte SystemStatusFlag; public uint BatteryLifeTime; public uint BatteryFullLifeTime; }
[DllImport("user32.dll")]
public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
[DllImport("kernel32.dll")]
public static extern uint GetTickCount();
[DllImport("user32.dll")]
public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS sps);
'@ -ErrorAction SilentlyContinue

function Get-IdleSeconds {
    try {
        $lii = New-Object AbNative.Power+LASTINPUTINFO
        $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
        if ([AbNative.Power]::GetLastInputInfo([ref]$lii)) {
            return [double](([AbNative.Power]::GetTickCount() - $lii.dwTime) / 1000.0)
        }
    } catch { }
    return 0
}

function Get-OnAcPower {
    try {
        $st = New-Object AbNative.Power+SYSTEM_POWER_STATUS
        if ([AbNative.Power]::GetSystemPowerStatus([ref]$st)) { return ($st.ACLineStatus -eq 1) }
    } catch { }
    return $true
}

function Get-DisplayOffSeconds {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null)
        foreach ($line in $out) {
            if ("$line" -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
                return [int]([Convert]::ToInt32($Matches[1], 16))
            }
        }
    } catch { }
    finally { $ErrorActionPreference = $eap }
    return 900
}

function Test-SessionLocked {
    try { return [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue) } catch { return $false }
}

# ---------------------------------------------------------------- camera sampling

function Find-Ffmpeg {
    param($Cfg)
    if ($Cfg.ffmpegPath -and (Test-Path $Cfg.ffmpegPath)) { return [string]$Cfg.ffmpegPath }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $probe = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        'C:\ffmpeg\bin', 'C:\Program Files\ffmpeg\bin', (Join-Path $env:ProgramData 'chocolatey\bin')
    )
    foreach ($p in $probe) {
        if (-not (Test-Path $p)) { continue }
        $hit = Get-ChildItem -Path $p -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

function Get-CameraNames {
    param([string]$Ff)
    $names = @()
    if (-not $Ff) { return $names }
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    try {
        $out = @(& $Ff -hide_banner -list_devices true -f dshow -i dummy 2>&1)
        foreach ($line in $out) {
            if ("$line" -match '"([^"]+)"\s+\(video\)') { $names += $Matches[1] }
        }
    } catch { }
    finally { $ErrorActionPreference = $eap }
    return $names
}

function Select-Camera {
    param([string]$Ff, $Cfg)
    $all = @(Get-CameraNames -Ff $Ff)
    if ($all.Count -eq 0) { return '' }
    $want = [string]$Cfg.cameraName
    if ($want) {
        $hit = @($all | Where-Object { $_ -eq $want })
        if ($hit.Count -eq 0) { $hit = @($all | Where-Object { $_ -like "*$want*" }) }
        if ($hit.Count -gt 0) { return $hit[0] }
    }
    $virtual = @('NVIDIA Broadcast', 'OBS Virtual', 'Snap Camera', 'ManyCam', 'Virtual Camera', 'XSplit')
    $phy = @($all | Where-Object { $n = $_; -not ($virtual | Where-Object { $n -like "*$_*" }) })
    if ($phy.Count -eq 0) { $phy = $all }
    $rgb = @($phy | Where-Object { $_ -notmatch 'IR ' -and $_ -notmatch '\bIR\b' -and $_ -notmatch 'Infrared' })
    if ($rgb.Count -gt 0) { return $rgb[0] }
    return $phy[0]
}

function Read-Luminance {
    param([string]$Ff, [string]$Camera, [int]$Frames = 3)
    $statsFile = Join-Path $TmpDir 'stats.txt'
    $errFile = Join-Path $TmpDir 'ffmpeg.err.txt'
    Remove-Item $statsFile, $errFile -ErrorAction SilentlyContinue

    $dev = 'video="' + $Camera + '"'
    $vf = 'scale=32:18,signalstats,metadata=print:file=stats.txt'
    $argStr = '-hide_banner -loglevel error -nostdin -f dshow -i ' + $dev +
              ' -frames:v ' + $Frames + ' -vf "' + $vf + '" -f null -'

    $p = Start-Process -FilePath $Ff -ArgumentList $argStr -WorkingDirectory $TmpDir `
            -NoNewWindow -PassThru `
            -RedirectStandardError $errFile -ErrorAction Stop
    $done = $p.WaitForExit($CamTimeoutMs)
    if (-not $done) {
        try { $p.Kill() } catch { }
        throw ('camera read timeout after ' + $CamTimeoutMs + ' ms (device busy?)')
    }
    if (-not (Test-Path $statsFile)) {
        $err = ''
        if (Test-Path $errFile) { $err = [string](Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
        $err = ($err -replace '\s+', ' ').Trim()
        if ($err.Length -gt 180) { $err = $err.Substring(0, 180) }
        throw ('ffmpeg produced no frame stats: ' + $err)
    }

    $vals = @()
    foreach ($line in (Get-Content $statsFile -ErrorAction SilentlyContinue)) {
        if ("$line" -match 'YAVG=([0-9.]+)') { $vals += [double]$Matches[1] }
    }
    Remove-Item $statsFile, $errFile -ErrorAction SilentlyContinue
    if ($vals.Count -eq 0) { throw 'no YAVG values parsed' }
    $sorted = @($vals | Sort-Object)
    return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)]
}

# ---------------------------------------------------------------- mapping

function Get-MappedBrightness {
    param([double]$Luminance, $Curve, [int]$Min, [int]$Max)
    $x = [Math]::Max(0.35, [Math]::Min(255.0, $Luminance))
    $lx = [Math]::Log10($x)
    $pts = @()
    foreach ($pt in $Curve) {
        $a = [double]$pt[0]
        $b = [double]$pt[1]
        if ($a -gt 0) { $pts += , @([Math]::Log10($a), $b) }
    }
    if ($pts.Count -eq 0) { return $Min }
    $pts = @($pts | Sort-Object { $_[0] })
    $n = $pts.Count
    $v = [double]$pts[$n - 1][1]
    if ($lx -le $pts[0][0]) { $v = [double]$pts[0][1] }
    elseif ($lx -ge $pts[$n - 1][0]) { $v = [double]$pts[$n - 1][1] }
    else {
        for ($i = 0; $i -lt ($n - 1); $i++) {
            $x0 = [double]$pts[$i][0]; $y0 = [double]$pts[$i][1]
            $x1 = [double]$pts[$i + 1][0]; $y1 = [double]$pts[$i + 1][1]
            if ($lx -ge $x0 -and $lx -le $x1) {
                $t = if ($x1 -gt $x0) { ($lx - $x0) / ($x1 - $x0) } else { 0.0 }
                $v = $y0 + ($y1 - $y0) * $t
                break
            }
        }
    }
    return [int][Math]::Round([Math]::Max($Min, [Math]::Min($Max, $v)))
}

function Get-ClockBrightness {
    param($Curve, [int]$Min, [int]$Max)
    $now = (Get-Date).Hour + ((Get-Date).Minute / 60.0)
    $pts = @()
    foreach ($pt in $Curve) { $pts += , @([double]$pt[0], [double]$pt[1]) }
    if ($pts.Count -eq 0) { return $Min }
    $pts = @($pts | Sort-Object { $_[0] })
    $n = $pts.Count
    for ($i = 0; $i -lt ($n - 1); $i++) {
        if ($now -ge $pts[$i][0] -and $now -le $pts[$i + 1][0]) {
            $span = [double]$pts[$i + 1][0] - [double]$pts[$i][0]
            $t = if ($span -gt 0) { ($now - $pts[$i][0]) / $span } else { 0.0 }
            $v = [double]$pts[$i][1] + ([double]$pts[$i + 1][1] - [double]$pts[$i][1]) * $t
            return [int][Math]::Round([Math]::Max($Min, [Math]::Min($Max, $v)))
        }
    }
    return [int][Math]::Round([Math]::Max($Min, [Math]::Min($Max, [double]$pts[$n - 1][1])))
}

# ---------------------------------------------------------------- daemon loop

function Invoke-Cycle {
    param($Cfg, $State, [string[]]$Internal, [string]$Ff, [string]$Camera)

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([double]$State.suspendUntil -gt $now) { return $State }

    $sinceLast = $now - [double]$State.lastTs
    $interval = [int]$Cfg.sampleIntervalSec
    $throttle = 1
    $idle = Get-IdleSeconds
    if ($idle -gt ([double](Get-DisplayOffSeconds) * 0.4)) { $throttle = [int]$Cfg.idleThrottleFactor }
    if ($sinceLast -lt ($interval * $throttle)) { return $State }

    $lum = -1.0
    if ($FakeLuminance -ge 0) { $lum = $FakeLuminance }
    elseif ($Cfg.source -eq 'camera') {
        if (-not $Camera) { throw 'no camera found for luminance sampling' }
        $lum = Read-Luminance -Ff $Ff -Camera $Camera -Frames ([int]$Cfg.burstFrames)
    }

    $target = 0
    if ($Cfg.source -eq 'clock') {
        $target = Get-ClockBrightness -Curve $Cfg.clockCurve -Min ([int]$Cfg.minBrightness) -Max ([int]$Cfg.maxBrightness)
    } elseif ($Cfg.source -eq 'camera') {
        if ($lum -lt 0) { return $State }
        $target = Get-MappedBrightness -Luminance $lum -Curve $Cfg.curve -Min ([int]$Cfg.minBrightness) -Max ([int]$Cfg.maxBrightness)
    } else { return $State }

    $onAc = Get-OnAcPower
    if (-not $onAc) { $target = $target + [int]$Cfg.batteryOffset }
    $target = [int][Math]::Max([int]$Cfg.minBrightness, [Math]::Min([int]$Cfg.maxBrightness, $target))

    $cur = Get-CurrentBrightness -Internal $Internal
    $lastSet = [double]$State.lastSetBrightness
    if ($cur -gt 0 -and $lastSet -gt 0 -and [Math]::Abs($cur - $lastSet) -gt 5) {
        $hold = [int]$Cfg.manualOverrideHoldMin
        if ($hold -gt 0) {
            $State.suspendUntil = $now + ($hold * 60)
            Write-Log ("manual brightness change ($lastSet -> $cur); pausing auto for $hold min")
            Save-State $State
            return $State
        }
    }

    $prev = [double]$State.smoothed
    if ($prev -lt 0 -or $prev -gt 100) {
        $prev = if ($cur -ge 0) { [double]$cur } else { [double]$target }
    }

    # big ambient change = follow immediately (one fade); drift = smooth with EMA
    if ([Math]::Abs($target - $prev) -ge [int]$Cfg.fastJumpThreshold) {
        $newVal = $target
    } else {
        $alpha = if ($target -ge $prev) { [double]$Cfg.alphaUp } else { [double]$Cfg.alphaDown }
        $newVal = [int][Math]::Round($prev + ($target - $prev) * $alpha)
    }
    $newVal = [int][Math]::Max([int]$Cfg.minBrightness, [Math]::Min([int]$Cfg.maxBrightness, $newVal))

    $changed = $false
    if ($cur -lt 0 -or [Math]::Abs($newVal - $cur) -ge [int]$Cfg.deadband) {
        Set-BrightnessSmooth -Target $newVal -Current $cur -Internal $Internal
        $changed = $true
    }

    $State.smoothed = $newVal
    $State.lastSetBrightness = $newVal
    $State.lastLux = $lum
    $State.lastTs = $now
    $State.lastError = ''
    Save-State $State

    if ($changed) {
        Write-Log ("brightness {0}% (target {1}%, ambient {2:0.0}, ac={3})" -f $newVal, $target, $lum, [bool]$onAc)
    }
    return $State
}

function Invoke-Daemon {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $mutex.WaitOne(0)) {
        Write-Log 'another AutoBrightness instance is already running' 'WARN'
        return
    }
    try {
        $cfg = Get-Config
        $internal = @(Get-InternalDisplayInstance)
        $ff = Find-Ffmpeg -Cfg $cfg
        $cam = ''
        if ($cfg.source -eq 'camera' -and $FakeLuminance -lt 0) {
            $cam = Select-Camera -Ff $ff -Cfg $cfg
            if (-not $cam) {
                Write-Log 'no camera found; falling back to clock source' 'WARN'
                $cfg.source = 'clock'
            }
        }
        Write-Log ("daemon start: source={0} camera='{1}' ffmpeg='{2}' every {3}s" -f $cfg.source, $cam, $ff, $cfg.sampleIntervalSec)
        $state = Read-State
        $state.lastTs = 0
        $cfgStamp = (Get-Item $ConfigPath).LastWriteTimeUtc

        while ($true) {
            try {
                if ((Get-Item $ConfigPath).LastWriteTimeUtc -ne $cfgStamp) {
                    $cfg = Get-Config
                    $cfgStamp = (Get-Item $ConfigPath).LastWriteTimeUtc
                    Write-Log 'config reloaded'
                }
                if (Test-SessionLocked) { Start-Sleep -Seconds 30; continue }
                $state = Invoke-Cycle -Cfg $cfg -State $state -Internal $internal -Ff $ff -Camera $cam
            } catch {
                $msg = $_.Exception.Message
                if ([string]$state.lastError -ne $msg) { Write-Log $msg 'ERROR' }
                $state.lastError = $msg
                Save-State $state
            }
            Start-Sleep -Seconds ([Math]::Max(2, [int]$cfg.sampleIntervalSec))
        }
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
        Write-Log 'daemon stopped'
    }
}

# ---------------------------------------------------------------- control verbs

function Get-DaemonPid {
    if (-not (Test-Path $PidPath)) { return 0 }
    $v = [string](Get-Content $PidPath -Raw -ErrorAction SilentlyContinue)
    $n = 0
    if ([int]::TryParse($v.Trim(), [ref]$n)) {
        if (Get-Process -Id $n -ErrorAction SilentlyContinue) { return $n }
    }
    return 0
}

function Start-Daemon {
    $existing = Get-DaemonPid
    if ($existing) { Write-Log ("already running (pid $existing)") 'WARN'; return }
    $ps = (Get-Process -Id $PID).Path
    if (-not $ps) { $ps = 'powershell.exe' }
    $argList = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action run -Quiet'
    $p = Start-Process -FilePath $ps -ArgumentList $argList -WindowStyle Hidden -PassThru
    Set-Content -Path $PidPath -Value $p.Id -Encoding ASCII
    Write-Log ('started daemon pid ' + $p.Id)
}

function Stop-Daemon {
    $n = Get-DaemonPid
    if ($n) {
        try { Stop-Process -Id $n -Force -ErrorAction Stop; Write-Log ('stopped pid ' + $n) }
        catch { Write-Log ('failed to stop pid ' + $n + ': ' + $_.Exception.Message) 'ERROR' }
    } else {
        $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -like '*AutoBrightness*' -and $_.CommandLine -like '*-Action run*' })
        foreach ($o in $others) { try { Stop-Process -Id $o.ProcessId -Force } catch { } }
        Write-Log 'no tracked daemon; swept stray instances'
    }
    Remove-Item $PidPath -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- actions

function Show-Diag {
    $cfg = Get-Config
    $internal = @(Get-InternalDisplayInstance)
    $cur = Get-CurrentBrightness -Internal $internal
    $methods = @(Get-BrightnessMethods -Internal $internal)
    $ff = Find-Ffmpeg -Cfg $cfg
    $cams = @()
    if ($ff) { $cams = @(Get-CameraNames -Ff $ff) }
    $als = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
             Where-Object { $_.DeviceID -like 'ACPI0008*' -or $_.Name -match 'Ambient Light' })
    $cs = Get-CimInstance Win32_ComputerSystem
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $dpid = Get-DaemonPid
    $st = Read-State

    Write-Host ''
    Write-Host 'AutoBrightness diagnostics' -ForegroundColor Cyan
    Write-Host ('  machine          : {0} {1}' -f $cs.Manufacturer, $cs.Model)
    Write-Host ('  OS               : {0}' -f ((Get-CimInstance Win32_OperatingSystem).Caption))
    if ($als.Count) { Write-Host ('  ambient ALS      : PRESENT -> ' + (($als | Select-Object -ExpandProperty Name) -join ', ')) }
    else { Write-Host '  ambient ALS      : NONE (no ACPI0008 / no sensor class device)' }
    Write-Host ('  internal panel   : {0}' -f ($internal -join ', '))
    Write-Host ('  brightness now   : {0}%' -f $cur)
    if ($methods.Count) { Write-Host ('  brightness ctrl  : OK ({0} target)' -f $methods.Count) }
    else { Write-Host '  brightness ctrl  : UNAVAILABLE' }
    Write-Host ('  ffmpeg           : {0}' -f $(if ($ff) { $ff } else { 'MISSING' }))
    Write-Host ('  cameras          : {0}' -f $(if ($cams.Count) { $cams -join ' | ' } else { 'none' }))
    Write-Host ('  camera selected  : {0}' -f $(if ($ff) { Select-Camera -Ff $ff -Cfg $cfg } else { '' }))
    Write-Host ('  source / interval: {0} / {1}s' -f $cfg.source, $cfg.sampleIntervalSec)
    Write-Host ('  logon task       : {0}' -f $(if ($task) { [string]$task.State } else { 'not installed' }))
    Write-Host ('  daemon           : {0}' -f $(if ($dpid) { "running pid $dpid" } else { 'stopped' }))
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([double]$st.suspendUntil -gt $now) {
        Write-Host ('  auto suspended   : {0} min left' -f [Math]::Round(([double]$st.suspendUntil - $now) / 60.0, 1))
    }
    Write-Host ('  last ambient     : {0:0.0} -> {1}%' -f [double]$st.lastLux, [double]$st.lastSetBrightness)
    Write-Host ''
}

function Show-Status {
    $cfg = Get-Config
    $st = Read-State
    $n = Get-DaemonPid
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $susp = [double]$st.suspendUntil -gt $now
    Write-Host ('daemon    : {0}' -f $(if ($n) { "running (pid $n)" } else { 'stopped' }))
    Write-Host ('source    : {0}, every {1}s' -f $cfg.source, $cfg.sampleIntervalSec)
    $lastTs = [double]$st.lastTs
    $lastTxt = if ($lastTs -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds([long]$lastTs).ToLocalTime().ToString('HH:mm:ss') } else { 'never' }
    Write-Host ('ambient   : {0:0.0}  (sampled {1})' -f [double]$st.lastLux, $lastTxt)
    Write-Host ('applied   : {0}%' -f [double]$st.lastSetBrightness)
    if ($susp) { Write-Host ('suspended : yes, {0} min left' -f [Math]::Round(([double]$st.suspendUntil - $now) / 60.0, 1)) }
    else { Write-Host 'suspended : no' }
    if ($st.lastError) { Write-Host ('last err  : {0}' -f $st.lastError) }
    if ($cfg.source -eq 'camera') { Write-Host 'note      : webcam LED blinks while sampling (the camera is the light meter)' -ForegroundColor DarkGray }
}

function Invoke-Install {
    $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action run -Quiet'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'Ambient-light adaptive screen brightness' -Force | Out-Null
    Write-Log 'scheduled task installed (starts at logon)'
    Start-Daemon
}

function Invoke-Uninstall {
    Stop-Daemon
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Log 'scheduled task removed' }
}

# ---------------------------------------------------------------- entry point

switch ($Action) {
    'run' { $script:Quiet = $true; Invoke-Daemon }
    'start' { Start-Daemon }
    'stop' { Stop-Daemon }
    'status' { Show-Status }
    'diag' { Show-Diag }
    'install' { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'pause' {
        $m = if ($Minutes -gt 0) { $Minutes } else { 60 }
        $st = Read-State
        $st.suspendUntil = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ($m * 60)
        Save-State $st
        Write-Log ("auto brightness paused for $m min")
    }
    'resume' {
        $st = Read-State
        $st.suspendUntil = 0
        Save-State $st
        Write-Log 'auto brightness resumed'
    }
    'toggle' {
        $st = Read-State
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([double]$st.suspendUntil -gt $now) {
            $st.suspendUntil = 0
            Save-State $st
            Write-Log 'auto brightness resumed'
        } else {
            $m = if ($Minutes -gt 0) { $Minutes } else { 60 }
            $st.suspendUntil = $now + ($m * 60)
            Save-State $st
            Write-Log ("auto brightness paused for $m min")
        }
    }
    'measure' {
        $cfg = Get-Config
        $ff = Find-Ffmpeg -Cfg $cfg
        if (-not $ff) { throw 'ffmpeg not found' }
        $cam = Select-Camera -Ff $ff -Cfg $cfg
        if (-not $cam) { throw 'no camera found' }
        $internal = @(Get-InternalDisplayInstance)
        $count = if ($Interval -gt 0) { $Interval } else { 10 }
        Write-Host ("sampling '{0}' {1} times -- move between dark / normal / bright light" -f $cam, $count)
        Write-Host '   ambient   mapped   current'
        for ($i = 0; $i -lt $count; $i++) {
            try {
                $lum = Read-Luminance -Ff $ff -Camera $cam -Frames ([int]$cfg.burstFrames)
                $mapped = Get-MappedBrightness -Luminance $lum -Curve $cfg.curve -Min ([int]$cfg.minBrightness) -Max ([int]$cfg.maxBrightness)
                $cur = Get-CurrentBrightness -Internal $internal
                Write-Host ('   {0,7:0.0}   {1,5}%   {2,5}%' -f $lum, $mapped, $cur)
            } catch {
                Write-Host ('   error: ' + $_.Exception.Message) -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 700
        }
    }
    'config' {
        Write-Host ('config file: ' + $ConfigPath)
        (Get-Config | ConvertTo-Json -Depth 6)
    }
    default { Show-Status }
}
