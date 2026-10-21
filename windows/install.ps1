# Installs GlucoseTray for the current user: copies it to %LOCALAPPDATA%, writes the
# settings file, adds it to Startup and starts it. Run through install.cmd, or without a
# checkout (downloads the latest release):
#   powershell -ExecutionPolicy Bypass -c "irm https://github.com/dogfootruler-kr/glucose-bar/releases/latest/download/install.ps1 | iex"
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'GlucoseTray'
$cfgDir = Join-Path $env:APPDATA 'GlucoseTray'
$cfgPath = Join-Path $cfgDir 'config.json'
New-Item -ItemType Directory -Force $dest, $cfgDir | Out-Null
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'GlucoseTray.ps1' }
if ($local -and (Test-Path $local)) {
    Copy-Item $local $dest -Force
    Set-Content (Join-Path $dest 'VERSION') 'local'  # replaced by the latest release on the first update check
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repo = 'dogfootruler-kr/glucose-bar'
    $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
    Invoke-WebRequest "https://github.com/$repo/releases/download/$tag/GlucoseTray.ps1" -OutFile (Join-Path $dest 'GlucoseTray.ps1') -UseBasicParsing
    Set-Content (Join-Path $dest 'VERSION') $tag
}

if (-not (Test-Path $cfgPath)) {
    $server = Read-Host 'Server address [http://glucose-work:8765]'
    if (-not $server) { $server = 'http://glucose-work:8765' }
    $mmol = (Read-Host 'Use mmol/L instead of mg/dL? [y/N]') -match '^[yY]'
    [ordered]@{ server = $server; mmol = $mmol; alertLow = 70; alertHigh = 250; staleMinutes = 20 } |
        ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
}

$script = Join-Path $dest 'GlucoseTray.ps1'
$launchArgs = "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$script`""
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'GlucoseTray.lnk'))
$lnk.TargetPath = "$env:WINDIR\System32\conhost.exe"
$lnk.Arguments = $launchArgs
$lnk.WorkingDirectory = $dest
$lnk.Save()

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*GlucoseTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process "$env:WINDIR\System32\conhost.exe" $launchArgs
Write-Host "GlucoseTray is running (look in the tray, or the ^ overflow). Settings: $cfgPath"
