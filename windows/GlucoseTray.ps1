# GlucoseTray: glucose in the Windows system tray, read from a GlucoseBar server
# (the Mac running server/libre_server.py, reached over Tailscale).
# Settings: %APPDATA%\GlucoseTray\config.json (written by install.ps1).

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Native -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);'

$ConfigPath = Join-Path $env:APPDATA 'GlucoseTray\config.json'
$Config = [ordered]@{
    server = 'http://glucose-work:8765'
    mmol = $false
    alertLow = 70
    alertHigh = 250
    staleMinutes = 20
}
if (Test-Path $ConfigPath) {
    (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $Config[$_.Name] = $_.Value }
}
$Server = $Config.server.TrimEnd('/')

$State = @{ reading = $null; error = $null; lastAlert = @{}; snoozeUntil = [DateTime]::MinValue; iconHandle = [IntPtr]::Zero }

function Format-Glucose([int]$mgdl) {
    if ($Config.mmol) { return ($mgdl / 18.0182).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) }
    return "$mgdl"
}

function Get-Time($value) {
    # PowerShell 7 already turns ISO dates into DateTime; 5.1 leaves strings.
    if ($value -is [DateTime]) { return $value.ToUniversalTime() }
    return [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 0, 0, 31, 31)
    $size = if ($text.Length -ge 3) { 12 } else { 15 }
    $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $fmt)
    $g.Dispose()
    $handle = $bmp.GetHicon()
    $Tray.Icon = [System.Drawing.Icon]::FromHandle($handle)
    $bmp.Dispose()
    if ($State.iconHandle -ne [IntPtr]::Zero) { [Native.User32]::DestroyIcon($State.iconHandle) | Out-Null }
    $State.iconHandle = $handle
}

# Tray tooltips are limited to 63 characters.
function Set-Tip([string]$text) { $Tray.Text = $text.Substring(0, [Math]::Min(63, $text.Length)) }

function Send-Alert([string]$kind, [string]$title, [string]$message, [int]$repeatMinutes) {
    $now = Get-Date
    if ($now -lt $State.snoozeUntil) { return }
    $last = $State.lastAlert[$kind]
    if ($last -and ($now - $last).TotalMinutes -lt $repeatMinutes) { return }
    $State.lastAlert[$kind] = $now
    $Tray.ShowBalloonTip(10000, $title, $message, [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Update-Glucose {
    try {
        $resp = Invoke-RestMethod -Uri "$Server/glucose?hours=1" -TimeoutSec 10
        $State.reading = $resp.reading
        $State.error = $resp.error
    } catch {
        $State.error = "Can't reach $Server"
    }

    $r = $State.reading
    if (-not $r) {
        Set-TrayIcon '--' ([System.Drawing.Color]::Gray)
        Set-Tip "GlucoseTray: $($State.error)"
        return
    }

    $mgdl = [int]$r.mgdl
    $age = [int]((Get-Date).ToUniversalTime() - (Get-Time $r.timestamp)).TotalMinutes
    $stale = $age -gt $Config.staleMinutes
    $color = if ($stale) { [System.Drawing.Color]::Gray }
             elseif ($mgdl -lt $r.targetLow) { [System.Drawing.Color]::FromArgb(215, 38, 38) }
             elseif ($mgdl -gt $r.targetHigh) { [System.Drawing.Color]::FromArgb(230, 120, 0) }
             else { [System.Drawing.Color]::FromArgb(30, 150, 70) }
    Set-TrayIcon (Format-Glucose $mgdl) $color

    $unit = if ($Config.mmol) { 'mmol/L' } else { 'mg/dL' }
    $delta = ''
    if ($null -ne $r.delta) {
        $d = [int]$r.delta
        $sign = if ($d -ge 0) { '+' } else { '-' }
        $delta = " $sign$(Format-Glucose ([Math]::Abs($d)))"
    }
    $tip = "$(Format-Glucose $mgdl) $unit $($r.arrow)$delta, $age min ago"
    if ($State.error) { $tip += ' (offline)' }
    Set-Tip $tip

    if ($stale) {
        Send-Alert 'stale' 'No glucose data' "Last reading was $age minutes ago." 30
    } elseif ($mgdl -le $Config.alertLow) {
        Send-Alert 'low' "Low: $(Format-Glucose $mgdl) $unit $($r.arrow)" 'Glucose is at or below your low alert.' 15
    } elseif ($mgdl -ge $Config.alertHigh) {
        Send-Alert 'high' "High: $(Format-Glucose $mgdl) $unit $($r.arrow)" 'Glucose is at or above your high alert.' 60
    }
}

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('Open web page', $null, { Start-Process "$Server/" }) | Out-Null
$menu.Items.Add('Refresh now', $null, { Update-Glucose }) | Out-Null
$menu.Items.Add('Snooze alerts 30 min', $null, { $State.snoozeUntil = (Get-Date).AddMinutes(30) }) | Out-Null
$menu.Items.Add('Edit settings (then Quit and reopen)', $null, { Start-Process notepad.exe $ConfigPath }) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('Quit', $null, { $Tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null
$Tray.ContextMenuStrip = $menu
$Tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Start-Process "$Server/" } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.add_Tick({ Update-Glucose })
$timer.Start()

Update-Glucose
[System.Windows.Forms.Application]::Run()
$Tray.Dispose()
