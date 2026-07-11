#Requires -Version 5.1
<#
.SYNOPSIS
    Power_Windows - opinionated post-install setup for a fresh Windows 11 (25H2+).

.DESCRIPTION
    One script to activate, install and configure a fresh Windows box.
    Every action asks Y/N first (answer A during app installs to accept the rest),
    unless you pass -Auto, which accepts everything.

    Steps:
      1. Self-elevate to an Administrator PowerShell
      2. Verify internet connectivity (aborts if offline)
      3. Activate Windows (Microsoft Activation Scripts - HWID/permanent)
      4. Download Office 2024 image in the background
      5. Set languages: English (primary) + Hebrew (secondary)
      6. Install apps with winget (per-app prompt, or A for all)
      7. Make Windows Terminal the default terminal + default profile = PowerShell 7
      8. Configure PowerShell 7 (oh-my-posh, Meslo Nerd Font, modules, profile)
      9. Turn off all startup apps

.PARAMETER Auto
    Accept every prompt automatically (unattended run).

.EXAMPLE
    .\Power_Windows.ps1
.EXAMPLE
    .\Power_Windows.ps1 -Auto
#>
[CmdletBinding()]
param(
    [switch]$Auto
)

# =============================================================================
#  1. Self-elevation  (works from a file OR straight from the web via irm|iex)
# =============================================================================
$PowerWindowsUrl = 'https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.ps1'

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Relaunch elevated from a file. When run from the web (no file on disk), fetch
    # ourselves to TEMP first so there is a file to hand to -File. Running elevated
    # with -ExecutionPolicy Bypass is what lets this work on a fresh, Restricted box.
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path $env:TEMP 'Power_Windows.ps1'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host "[*] Fetching Power_Windows to $scriptPath ..." -ForegroundColor Cyan
            Invoke-RestMethod -Uri $PowerWindowsUrl -OutFile $scriptPath -ErrorAction Stop
        } catch {
            Write-Host "[x] Could not download the script: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }
    Write-Host "[*] Elevating to Administrator..." -ForegroundColor Cyan
    $psArgs = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $scriptPath
    if ($Auto) { $psArgs += ' -Auto' }
    # Prefer opening the elevated session as a Windows Terminal tab. Windows keeps
    # elevated tabs in their own WT window (separate from an unelevated one), so this
    # is a dedicated "Power_Windows" window that repeat runs share as tabs; it can't be
    # merged into an unelevated window. Fall back to a standard elevated console.
    $launched = $false
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        $wtArgs = '-M -w Power_Windows new-tab --title "Power_Windows (admin)" powershell.exe {0}' -f $psArgs
        try { Start-Process -FilePath 'wt.exe' -Verb RunAs -ArgumentList $wtArgs -ErrorAction Stop; $launched = $true }
        catch {
            if ($_.Exception.Message -match 'cancel') { return }
            Write-Host "[!] Windows Terminal launch failed; using a standard elevated window." -ForegroundColor Yellow
        }
    }
    if (-not $launched) {
        try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs -ErrorAction Stop; $launched = $true }
        catch { Write-Host "[x] Elevation was cancelled or failed. Aborting." -ForegroundColor Red }
    }
    if ($launched) {
        # The elevated session has taken over. Exit THIS process cleanly (code 0) so the
        # launching terminal closes the window/tab itself - Windows Terminal and the classic
        # console both auto-close on a 0 exit, but keep the tab open on a forced kill.
        Start-Sleep -Milliseconds 750
        [Environment]::Exit(0)
    }
    return
}

$ErrorActionPreference = 'Continue'

# Mutable state
$script:Auto          = [bool]$Auto
$script:AssumeAllApps = $false
$script:OfficeJob     = $null
$script:OfficeDest    = Join-Path $env:USERPROFILE 'Downloads\ProPlus2024Retail.img'
$script:OfficeUrl     = 'https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/en-us/ProPlus2024Retail.img'
$script:PwshExe       = $null
$script:LogFile       = $null

# Start-menu folder pins shown next to the power button (step 11). VisiblePlaces is an
# opaque sequence of 16-byte "place" GUIDs hardcoded in the Start menu - the bytes are
# not documented, so CAPTURE them from a machine where you enabled the folders you want:
#   Settings > Personalization > Start > Folders  ->  tick Explorer/Documents/Downloads/etc,
#   then run this and paste the hex string below (empty = leave Start folders unchanged):
#   ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' VisiblePlaces).VisiblePlaces | ForEach-Object { $_.ToString('X2') }) -join ''
$script:StartFoldersHex = '86087352AA5143429F7B2776584659D4BC248A140CD68942A0806ED9BBA24882CED5342D5AFA434582F222E6EAF7773C2FB367E3DE895543BFCE61F37B18A9374AB0BD744AF9684F8BD64398071DA8BC'

try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $env:USERPROFILE "Power_Windows_$stamp.log"
    Start-Transcript -Path $script:LogFile -Append -ErrorAction Stop | Out-Null
} catch { }

# =============================================================================
#  Helpers
# =============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO'
    )
    switch ($Level) {
        'OK'   { Write-Host "[+] $Message" -ForegroundColor Green }
        'WARN' { Write-Host "[!] $Message" -ForegroundColor Yellow }
        'ERR'  { Write-Host "[x] $Message" -ForegroundColor Red }
        default { Write-Host "[*] $Message" -ForegroundColor Cyan }
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("===  $Title  ===") -ForegroundColor Magenta
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$AllowAll
    )
    if ($script:Auto) { return $true }
    if ($AllowAll -and $script:AssumeAllApps) { return $true }
    while ($true) {
        $suffix = if ($AllowAll) { '[Y]es / [N]o / [A]ll' } else { '[Y]es / [N]o' }
        $resp = (Read-Host "$Message  $suffix").Trim().ToLower()
        switch -Regex ($resp) {
            '^(y|yes)$' { return $true }
            '^(n|no|)$' { return $false }
            '^(a|all)$' {
                if ($AllowAll) { $script:AssumeAllApps = $true; return $true }
                Write-Log "Please answer Y or N." WARN
            }
            default { Write-Log "Please answer Y, N$(if($AllowAll){' or A'})." WARN }
        }
    }
}

function Invoke-Step {
    param([string]$Title, [scriptblock]$Action)
    Write-Section $Title
    try { & $Action }
    catch { Write-Log "Step '$Title' failed: $($_.Exception.Message)" ERR }
}

function Update-SessionPath {
    # Pull fresh Machine + User PATH so freshly-installed tools resolve this session.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Write-TextFileNoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Get-PwshExe {
    $cmd = Get-Command pwsh -ErrorAction Ignore
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
            "$env:ProgramFiles\PowerShell\7-preview\pwsh.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# =============================================================================
#  2. Connectivity
# =============================================================================
function Test-Connectivity {
    Write-Log "Checking internet connectivity..."
    try {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction Stop) {
            Write-Log "Internet connection detected." OK
            return $true
        }
    } catch { }
    try {
        $null = Invoke-WebRequest -Uri 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Log "Internet connection detected." OK
        return $true
    } catch { }
    return $false
}

# =============================================================================
#  3. Activate Windows  (MAS - HWID / permanent)
# =============================================================================
function Get-MasScript {
    # Download the MAS script with retry (get.activated.win occasionally fails DNS).
    # Each failed attempt's transient error is dropped so it doesn't dirty the caller's step.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $before = $global:Error.Count
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            return (Invoke-RestMethod -Uri 'https://get.activated.win' -Verbose:$false -ErrorAction Stop)
        } catch {
            while ($global:Error.Count -gt $before) { $global:Error.RemoveAt(0) }
            if ($attempt -lt 3) { Write-Log "Could not reach get.activated.win (attempt $attempt/3); retrying..." WARN; Start-Sleep -Seconds ($attempt * 5) }
            else { throw "get.activated.win unreachable after 3 attempts: $($_.Exception.Message)" }
        }
    }
}

function Invoke-WindowsActivation {
    if (-not (Confirm-Action "Activate Windows now (MAS - HWID / permanent)?")) {
        Write-Log "Skipped Windows activation." WARN
        return
    }
    Write-Log "Running Microsoft Activation Scripts (HWID)..."
    try {
        $mas = Get-MasScript
        # /HWID = main menu option 1 (permanent HWID activation), fully unattended.
        $masErr = $global:Error.Count
        & ([scriptblock]::Create($mas)) /HWID
        while ($global:Error.Count -gt $masErr) { $global:Error.RemoveAt(0) }  # drop MAS's benign registry-probe errors
        Write-Log "Activation routine finished (verify with 'slmgr /xpr')." OK
    } catch {
        Write-Log "Windows activation failed: $($_.Exception.Message)" ERR
    }
}

# =============================================================================
#  4. Download Office 2024 (background)
# =============================================================================
function Start-OfficeDownload {
    if ((Test-Path $script:OfficeDest) -and ((Get-Item $script:OfficeDest).Length -gt 4GB)) {
        Write-Log "Office image already downloaded ($([math]::Round((Get-Item $script:OfficeDest).Length / 1GB, 1)) GB); skipping the download." OK
        return
    }
    if (-not (Confirm-Action "Download Office 2024 (ProPlus2024Retail.img, ~6 GB) in the background?")) {
        Write-Log "Skipped Office download." WARN
        return
    }
    try {
        $downloads = Split-Path $script:OfficeDest -Parent
        if (-not (Test-Path $downloads)) { New-Item -ItemType Directory -Force -Path $downloads | Out-Null }
        $script:OfficeJob = Start-Job -Name OfficeDownload -ScriptBlock {
            param($src, $dst)
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                Start-BitsTransfer -Source $src -Destination $dst -ErrorAction Stop
            } catch {
                (New-Object System.Net.WebClient).DownloadFile($src, $dst)
            }
        } -ArgumentList $script:OfficeUrl, $script:OfficeDest
        Write-Log "Office download started in the background -> $($script:OfficeDest)" OK
    } catch {
        Write-Log "Could not start Office download: $($_.Exception.Message)" ERR
    }
}

function Complete-OfficeDownload {
    if (-not $script:OfficeJob) { return }
    $job = Get-Job -Id $script:OfficeJob.Id -ErrorAction SilentlyContinue
    if (-not $job) { return }
    Write-Section "Finishing Office download"
    if ($job.State -eq 'Running') {
        Write-Log "Office is still downloading. Waiting for it to finish (leave this window open)..." WARN
        Wait-Job $job | Out-Null
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    if ($job.State -eq 'Completed' -and (Test-Path $script:OfficeDest)) {
        Write-Log "Office image ready: $($script:OfficeDest)" OK
    } else {
        Write-Log "Office download did not complete cleanly (job state: $($job.State)). Re-run if needed." WARN
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

# Wait until the Office click-to-run install is finished. Returns $true on completion.
function Wait-OfficeInstall {
    # Give up after $StallMinutes with NO progress (installer idle and no new apps),
    # rather than blocking for a fixed hour. Keeps waiting while Office is installing.
    # $MaxMinutes is a hard safety cap.
    param([int]$StallMinutes = 8, [int]$MaxMinutes = 40)
    Write-Log "Waiting for Office to install (gives up after $StallMinutes min with no progress)..."
    $start = Get-Date
    $lastProgress = Get-Date
    $roots = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16')
    )
    $core = @('WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE')
    $maxSeen = 0
    $prevCpu = $null
    $idle = 0
    while ($true) {
        Start-Sleep -Seconds 15
        $office16 = $roots | Where-Object { Test-Path $_ } | Select-Object -First 1
        $present = @()
        if ($office16) { foreach ($a in $core) { if (Test-Path (Join-Path $office16 $a)) { $present += $a } } }
        $count = $present.Count
        $c2r = Get-Process -Name 'OfficeC2RClient' -ErrorAction Ignore
        $cpu = if ($c2r) { [double](($c2r | Measure-Object -Property CPU -Sum).Sum) } else { 0.0 }
        $now = Get-Date
        # Busy = the click-to-run client is running AND burning CPU (actively installing).
        # When it sits on the "You're all set!" dialog it uses ~no CPU, so it counts as idle
        # and we can finish and close it - even though the process is still alive.
        $busy = ([bool]$c2r) -and ($null -eq $prevCpu -or ($cpu - $prevCpu) -ge 2)
        if ($busy -or $count -gt $maxSeen) { $lastProgress = $now; if ($count -gt $maxSeen) { $maxSeen = $count } }
        if ($count -eq $core.Count -and -not $busy) {
            $idle++
            if ($idle -ge 2) { Write-Log "Office installation complete." OK; return $true }
        } else {
            $idle = 0
        }
        $prevCpu = $cpu
        if (($now - $lastProgress).TotalMinutes -ge $StallMinutes) {
            Write-Log "No Office install progress for $StallMinutes min - giving up (Setup likely failed)." WARN
            return $false
        }
        if (($now - $start).TotalMinutes -ge $MaxMinutes) {
            Write-Log "Office install exceeded $MaxMinutes min - giving up." WARN
            return $false
        }
    }
}

# Mount the downloaded Office image, run Setup, wait, unmount, then activate (Ohook).
function Install-Office {
    if (-not (Test-Path $script:OfficeDest)) {
        Write-Log "Office image not found ($($script:OfficeDest)); nothing to install." WARN
        return
    }
    if (-not (Confirm-Action "Install Office from the downloaded image now?")) {
        Write-Log "Skipped Office install." WARN
        return
    }
    $mounted = $false
    $installed = $false
    try {
        $vp = $VerbosePreference; $VerbosePreference = 'SilentlyContinue'  # silence Storage's CDXML import dump
        Import-Module Storage -ErrorAction SilentlyContinue
        $VerbosePreference = $vp
        Write-Log "Mounting $($script:OfficeDest)..."
        Mount-DiskImage -ImagePath $script:OfficeDest -ErrorAction Stop | Out-Null
        $mounted = $true
        Start-Sleep -Seconds 3
        $drive = (Get-DiskImage -ImagePath $script:OfficeDest | Get-Volume).DriveLetter
        if (-not $drive) { Start-Sleep -Seconds 3; $drive = (Get-DiskImage -ImagePath $script:OfficeDest | Get-Volume).DriveLetter }
        if (-not $drive) { throw "Could not determine the mounted drive letter." }
        Write-Log "Mounted at ${drive}:" OK
        $setup = Join-Path "${drive}:\" 'Setup.exe'
        if (-not (Test-Path $setup)) {
            $found = Get-ChildItem "${drive}:\" -Filter 'Setup*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $setup = $found.FullName }
        }
        if (-not (Test-Path $setup)) { throw "Setup.exe not found on the mounted image." }
        Write-Log "Launching Office setup: $setup"
        # Run from the image root so Setup.exe finds its Office\ payload via relative paths.
        Start-Process -FilePath $setup -WorkingDirectory "${drive}:\" | Out-Null
        $installed = Wait-OfficeInstall
        if ($installed) {
            # Close the "You're all set!" dialog gracefully, then force any leftover UI.
            Get-Process -Name 'OfficeC2RClient', 'Setup' -ErrorAction Ignore | ForEach-Object { $_.CloseMainWindow() | Out-Null }
            Start-Sleep -Seconds 2
            Get-Process -Name 'OfficeC2RClient', 'Setup' -ErrorAction Ignore | Stop-Process -Force -ErrorAction Ignore
        }
    } catch {
        Write-Log "Office install failed: $($_.Exception.Message)" ERR
    } finally {
        if ($mounted) {
            if ($installed) {
                try { Dismount-DiskImage -ImagePath $script:OfficeDest -ErrorAction Stop | Out-Null; Write-Log "Unmounted the Office image." OK }
                catch { Write-Log "Could not unmount the image: $($_.Exception.Message)" WARN }
            } else {
                Write-Log "Leaving the image mounted (install not confirmed). Unmount it yourself once Office is in." WARN
            }
        }
    }
    if ($installed) {
        if (Confirm-Action "Activate Office now (MAS Ohook)?") {
            Write-Log "Running MAS Ohook (Office activation)..."
            try {
                $mas = Get-MasScript
                $masErr = $global:Error.Count
                & ([scriptblock]::Create($mas)) /Ohook
                while ($global:Error.Count -gt $masErr) { $global:Error.RemoveAt(0) }  # drop MAS's benign registry-probe errors
                Write-Log "Office activation routine finished." OK
            } catch { Write-Log "Office activation failed: $($_.Exception.Message)" ERR }
        }
    } else {
        Write-Log "Skipping Office activation (install did not confirm complete)." WARN
    }
}

# =============================================================================
#  5. Languages: English (primary) + Hebrew (secondary)
# =============================================================================
function Set-Languages {
    Write-Log "Setting languages: English (primary), Hebrew (secondary)..."
    try {
        $cur = Get-WinUserLanguageList
        if ($cur.LanguageTag -notcontains 'en-US') { $cur.Add('en-US') }
        if ($cur.LanguageTag -notcontains 'he')    { $cur.Add('he') }

        $ordered = @()
        foreach ($tag in @('en-US', 'he')) {
            $obj = $cur | Where-Object { $_.LanguageTag -eq $tag } | Select-Object -First 1
            if ($obj) { $ordered += $obj }
        }
        foreach ($obj in $cur) {
            if (@('en-US', 'he') -notcontains $obj.LanguageTag) { $ordered += $obj }
        }
        Set-WinUserLanguageList -LanguageList $ordered -Force -WarningAction SilentlyContinue
        Write-Log "Language list set: $($ordered.LanguageTag -join ', ')" OK
    } catch {
        Write-Log "Failed to set languages: $($_.Exception.Message)" ERR
    }
}

# =============================================================================
#  6. Install apps (winget)
# =============================================================================
function Install-WingetApp {
    param([string]$Id, [string]$Name)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -eq 1) { Write-Log "Installing $Name..." }
        else { Write-Log "Retry $attempt/3 for $Name (transient failure)..." WARN; Start-Sleep -Seconds ($attempt * 5) }
        try {
            winget install --id $Id -e --source winget --accept-source-agreements --accept-package-agreements
            $code = $LASTEXITCODE
            if ($code -eq 0 -or $code -eq -1978335189) { Write-Log "$Name installed." OK; return $true }
            Write-Log "${Name}: winget exit code $code" WARN
        } catch { Write-Log "$Name error: $($_.Exception.Message)" ERR }
    }
    Write-Log "$Name did NOT install after 3 attempts." ERR
    return $false
}

function Close-PowerToysWindow {
    # PowerToys pops its "Welcome" window open after install; close it during setup.
    $pt = Get-Process -Name 'PowerToys*' -ErrorAction SilentlyContinue
    if ($pt) {
        $pt | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log "Closed the PowerToys welcome window." OK
    }
}

function Install-Apps {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log "winget (App Installer) not found - skipping app installs. Install 'App Installer' from the Store, then re-run." ERR
        return
    }

    $apps = [ordered]@{
        'Microsoft.VCRedist.2015+.x64' = 'Visual C++ Redistributable 2015+ (x64)'
        'Python.Python.3.14'           = 'Python 3.14'
        'Brave.Brave'                  = 'Brave Browser'
        'Google.Chrome'                = 'Google Chrome'
        'Microsoft.PowerShell'         = 'PowerShell 7'
        'Microsoft.PowerToys'          = 'PowerToys'
        'Oracle.VirtualBox'            = 'VirtualBox'
        'Microsoft.VisualStudioCode'   = 'Visual Studio Code'
        'KeePassXCTeam.KeePassXC'      = 'KeePassXC'
        'emoacht.Monitorian'           = 'Monitorian'
        'Git.Git'                      = 'Git'
        'VideoLAN.VLC'                 = 'VLC media player'
    }

    Write-Log "Answer A at any prompt to install all remaining apps without asking again."
    foreach ($id in $apps.Keys) {
        $name = $apps[$id]
        if (-not (Confirm-Action "Install $name  ($id)?" -AllowAll)) {
            Write-Log "Skipped $name." WARN
            continue
        }
        Install-WingetApp -Id $id -Name $name | Out-Null
    }
    Update-SessionPath
    $script:PwshExe = Get-PwshExe
    Close-PowerToysWindow
}

# =============================================================================
#  Windows Terminal settings.json helpers
# =============================================================================
function Get-WTSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Read-WTSettings {
    $path = Get-WTSettingsPath
    if (-not $path) {
        Write-Log "Windows Terminal settings.json not found (open Terminal once to generate it)." WARN
        return $null
    }
    $raw = Get-Content $path -Raw
    $json = $null
    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Strip // line comments (older WT settings are JSONC) and retry.
        $stripped = ($raw -split "`n" | ForEach-Object { $_ -replace '^\s*//.*$', '' }) -join "`n"
        try { $json = $stripped | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Log "Could not parse Windows Terminal settings.json - leaving it untouched." ERR; return $null }
    }
    return [pscustomobject]@{ Path = $path; Json = $json }
}

function Save-WTSettings {
    param([string]$Path, $Json)
    Copy-Item $Path "$Path.bak" -Force -ErrorAction SilentlyContinue
    $content = $Json | ConvertTo-Json -Depth 32
    # Windows Terminal may hold the file open; retry, and never leave it read-only.
    for ($i = 1; $i -le 4; $i++) {
        try {
            $item = Get-Item $Path -ErrorAction SilentlyContinue
            if ($item -and $item.IsReadOnly) { $item.IsReadOnly = $false }
            Write-TextFileNoBom -Path $Path -Content $content
            return
        } catch { Start-Sleep -Milliseconds 400 }
    }
    Write-Log "Could not update Windows Terminal settings.json after retries." WARN
}

function Get-WTPwshProfile {
    param($Json, [switch]$Create)
    if (-not $Json.profiles -or -not $Json.profiles.list) { return $null }
    $p = $Json.profiles.list | Where-Object {
        $_.source -eq 'Windows.Terminal.PowershellCore' -or
        $_.commandline -like '*pwsh.exe*' -or
        $_.name -eq 'PowerShell'
    } | Select-Object -First 1
    if (-not $p -and $Create -and $script:PwshExe) {
        $p = [pscustomobject]@{
            guid             = "{$([guid]::NewGuid())}"
            name             = 'PowerShell'
            commandline      = $script:PwshExe
            startingDirectory = '%USERPROFILE%'
        }
        $Json.profiles.list += $p
    }
    return $p
}

# =============================================================================
#  7. Default terminal application + default profile = PowerShell 7
# =============================================================================
function Set-DefaultTerminal {
    # (a) Make Windows Terminal the default terminal application (Win11 console delegation).
    try {
        $key = 'HKCU:\Console\%%Startup'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'DelegationConsole'  -Value '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'DelegationTerminal' -Value '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' -PropertyType String -Force | Out-Null
        Write-Log "Windows Terminal set as the default terminal application." OK
    } catch {
        Write-Log "Failed to set default terminal application: $($_.Exception.Message)" ERR
    }

    # (b) Default profile = PowerShell 7 (only if pwsh is installed).
    if (-not $script:PwshExe) {
        Write-Log "PowerShell 7 not installed - leaving Windows Terminal default profile unchanged." WARN
        return
    }
    try {
        $wt = Read-WTSettings
        if (-not $wt) { return }
        $pwshProfile = Get-WTPwshProfile -Json $wt.Json -Create
        if (-not $pwshProfile) {
            Write-Log "Could not find/create a PowerShell 7 profile in Windows Terminal." WARN
            return
        }
        if ($wt.Json.PSObject.Properties['defaultProfile']) {
            $wt.Json.defaultProfile = $pwshProfile.guid
        } else {
            $wt.Json | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $pwshProfile.guid -Force
        }
        Save-WTSettings -Path $wt.Path -Json $wt.Json
        Write-Log "Windows Terminal default profile set to PowerShell 7." OK
    } catch {
        Write-Log "Failed to set default profile: $($_.Exception.Message)" ERR
    }
}

# =============================================================================
#  8. Configure PowerShell 7 (oh-my-posh, Meslo font, modules, profile)
# =============================================================================

# --- embedded profile files (recreated verbatim on the fresh machine) --------
$ProfileMain = @'
# Load Oh My Posh with a Powerlevel10k theme
$primary = Join-Path $env:OneDrive 'Documents\PowerShell\my-powershell-theme.json'
$backup  = Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\my-powershell-theme.json'
$cfg = @($primary,$backup) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cfg) { $cfg = Join-Path $env:USERPROFILE 'Documents\PowerShell\my-powershell-theme.json'
                 oh-my-posh config export --format json | Set-Content $cfg }
oh-my-posh init pwsh --config $cfg | Invoke-Expression


# Nice extras
Import-Module PSReadLine
Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ListView
Import-Module posh-git
Import-Module Terminal-Icons
#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module

Import-Module -Name Microsoft.WinGet.CommandNotFound -ErrorAction SilentlyContinue
#f45873b3-b655-43a6-b217-97c00aa0db58
'@

$ProfileAllHosts = @'

#region conda initialize
# !! Contents within this block are managed by 'conda init' !!
If (Test-Path "C:\Users\netan\anaconda3\Scripts\conda.exe") {
    (& "C:\Users\netan\anaconda3\Scripts\conda.exe" "shell.powershell" "hook") | Out-String | ?{$_} | Invoke-Expression
}
#endregion

'@

$ThemeJson = @'
{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "blocks": [
    {
      "alignment": "left",
      "segments": [
        {
          "foreground": "#FF6AC1",
          "style": "plain",
          "template": "{{ .UserName }}@{{ .HostName }} ",
          "type": "session"
        },
        {
          "foreground": "#77E4F7",
          "properties": {
            "style": "full"
          },
          "style": "plain",
          "template": "{{ .Path }} ",
          "type": "path"
        },
        {
          "foreground": "#FFE700",
          "style": "plain",
          "template": "{{ .HEAD }} ",
          "type": "git"
        },
        {
          "foreground": "#43D426",
          "style": "plain",
          "template": "\u276f ",
          "type": "text"
        }
      ],
      "type": "prompt"
    }
  ],
  "version": 3
}
'@

$PwshConfigJson = @'
{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned"}
'@

function Set-PowerShell7Environment {
    if (-not $script:PwshExe) {
        Write-Log "PowerShell 7 not installed - skipping PowerShell 7 configuration." WARN
        return
    }

    # (a) oh-my-posh via winget, then refresh PATH so the child pwsh sees it.
    if (Confirm-Action "Install oh-my-posh (prompt theme engine)?") {
        if (Install-WingetApp -Id 'JanDeDobbeleer.OhMyPosh' -Name 'oh-my-posh') { Update-SessionPath }
    }

    # (b) Write the profile files into PowerShell 7's real profile folder.
    try {
        $ps7ProfilePath = (& $script:PwshExe -NoProfile -Command '$PROFILE.CurrentUserCurrentHost').Trim()
        if ($ps7ProfilePath) {
            $ps7Dir = Split-Path $ps7ProfilePath -Parent
            if (-not (Test-Path $ps7Dir)) { New-Item -ItemType Directory -Force -Path $ps7Dir | Out-Null }

            foreach ($f in @(
                    @{ Name = 'Microsoft.PowerShell_profile.ps1'; Body = $ProfileMain },
                    @{ Name = 'profile.ps1';                      Body = $ProfileAllHosts },
                    @{ Name = 'my-powershell-theme.json';         Body = $ThemeJson },
                    @{ Name = 'powershell.config.json';           Body = $PwshConfigJson })) {
                $dest = Join-Path $ps7Dir $f.Name
                if (Test-Path $dest) { Copy-Item $dest "$dest.bak" -Force -ErrorAction SilentlyContinue }
                Write-TextFileNoBom -Path $dest -Content $f.Body
            }
            Write-Log "PowerShell 7 profile written to $ps7Dir" OK
        }
    } catch {
        Write-Log "Failed to write PowerShell 7 profile: $($_.Exception.Message)" ERR
    }

    # (c) In a real pwsh process: trust gallery, install modules, install Meslo font.
    try {
        $block = @'
$ErrorActionPreference = "Continue"
try { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force } catch {}
$useRes = [bool](Get-Command Install-PSResource -ErrorAction Ignore)
if ($useRes) {
    try { Set-PSResourceRepository -Name PSGallery -Trusted -ErrorAction Stop } catch {}
} else {
    try { Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null } catch { Write-Warning "NuGet provider: $($_.Exception.Message)" }
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch {}
}
foreach ($m in "PSReadLine","posh-git","Terminal-Icons","Microsoft.WinGet.CommandNotFound") {
    try {
        if ($useRes) { Install-PSResource -Name $m -TrustRepository -Scope CurrentUser -ErrorAction Stop }
        else { Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop }
        Write-Host "[+] module installed: $m"
    } catch { Write-Warning "module ${m}: $($_.Exception.Message)" }
}
$omp = (Get-Command oh-my-posh -ErrorAction SilentlyContinue).Source
if (-not $omp) { $c = Join-Path $env:LOCALAPPDATA "Programs\oh-my-posh\bin\oh-my-posh.exe"; if (Test-Path $c) { $omp = $c } }
if ($omp) { try { & $omp font install meslo; Write-Host "[+] Meslo Nerd Font installed" } catch { Write-Warning "font install: $($_.Exception.Message)" } }
else { Write-Warning "oh-my-posh not found on PATH; run 'oh-my-posh font install meslo' manually" }
'@
        $tmp = Join-Path $env:TEMP 'pw_ps7_setup.ps1'
        Write-TextFileNoBom -Path $tmp -Content $block
        Write-Log "Installing PowerShell 7 modules and Meslo Nerd Font (in pwsh)..."
        & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $tmp
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "PowerShell 7 module/font setup failed: $($_.Exception.Message)" ERR
    }

    # (d) Set the PowerShell 7 profile font face in Windows Terminal.
    try {
        $wt = Read-WTSettings
        if ($wt) {
            $pwshProfile = Get-WTPwshProfile -Json $wt.Json -Create
            if ($pwshProfile) {
                $face = 'MesloLGM Nerd Font'
                if ($pwshProfile.PSObject.Properties['font'] -and $pwshProfile.font) {
                    if ($pwshProfile.font.PSObject.Properties['face']) { $pwshProfile.font.face = $face }
                    else { $pwshProfile.font | Add-Member -NotePropertyName face -NotePropertyValue $face -Force }
                } else {
                    $pwshProfile | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{ face = $face }) -Force
                }
                Save-WTSettings -Path $wt.Path -Json $wt.Json
                Write-Log "Windows Terminal PowerShell 7 font set to '$face'." OK
            }
        }
    } catch {
        Write-Log "Failed to set Windows Terminal font: $($_.Exception.Message)" ERR
    }
}

# =============================================================================
#  9. Turn off all startup apps
# =============================================================================
function Disable-StartupApps {
    if (-not (Confirm-Action "Turn OFF all current startup apps?")) {
        Write-Log "Left startup apps unchanged." WARN
        return
    }
    # Task-Manager-style disable: write a 'disabled' blob into StartupApproved.
    # First byte 0x03 = disabled (0x02 = enabled). Fully reversible from Task Manager.
    $disabled = [byte[]](0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    $count = 0

    $runMap = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
           Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
           Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
           Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    )

    foreach ($m in $runMap) {
        if (-not (Test-Path $m.Run)) { continue }
        if (-not (Test-Path $m.Approved)) { New-Item -Path $m.Approved -Force | Out-Null }
        foreach ($name in (Get-Item $m.Run).Property) {
            try {
                New-ItemProperty -Path $m.Approved -Name $name -Value $disabled -PropertyType Binary -Force | Out-Null
                Write-Log "Disabled startup: $name" OK
                $count++
            } catch {
                Write-Log "Could not disable '$name': $($_.Exception.Message)" WARN
            }
        }
    }

    # Startup folder shortcuts (per-user + all-users).
    $approvedSF = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    if (-not (Test-Path $approvedSF)) { New-Item -Path $approvedSF -Force | Out-Null }
    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $folder -or -not (Test-Path $folder)) { continue }
        foreach ($item in Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue) {
            try {
                New-ItemProperty -Path $approvedSF -Name $item.Name -Value $disabled -PropertyType Binary -Force | Out-Null
                Write-Log "Disabled startup item: $($item.Name)" OK
                $count++
            } catch {
                Write-Log "Could not disable '$($item.Name)': $($_.Exception.Message)" WARN
            }
        }
    }

    Write-Log "Turned off $count startup entr$(if($count -eq 1){'y'}else{'ies'})." OK
    Write-Log "Note: some packaged (Store) app startup tasks may still need toggling in Settings > Apps > Startup." INFO
}

# =============================================================================
#  10-16. Personalization
#  NOTE: these write per-user (HKCU) UI settings, so run the script as the same
#  user whose desktop you are setting up. Most need an Explorer restart to show.
# =============================================================================

# --- 10. Dark mode -----------------------------------------------------------
function Set-DarkMode {
    if (-not (Confirm-Action "Apply the Windows (dark) theme (dark mode + matching wallpaper)?")) { Write-Log "Left theme unchanged." WARN; return }
    try {
        # Dark toggles (also set by the theme; kept as a fallback if the theme is missing).
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $p)) { New-Item $p -Force | Out-Null }
        New-ItemProperty $p 'AppsUseLightTheme'    -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $p 'SystemUsesLightTheme' -Value 0 -PropertyType DWord -Force | Out-Null

        # Apply the built-in "Windows (dark)" theme so the wallpaper matches the selection.
        $darkTheme = Join-Path $env:SystemRoot 'Resources\Themes\dark.theme'
        if (Test-Path $darkTheme) {
            Start-Process $darkTheme | Out-Null
            Start-Sleep -Seconds 4
            # Applying a .theme opens the Settings app; close it.
            Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log "Applied Windows (dark) theme (dark mode + wallpaper)." OK
        } else {
            Write-Log "dark.theme not found; applied dark mode via registry only." WARN
        }
    } catch { Write-Log "Failed to apply dark theme: $($_.Exception.Message)" ERR }
}

# --- 11. Start menu folder pins (next to power button) -----------------------
function Set-StartFolders {
    if ([string]::IsNullOrWhiteSpace($script:StartFoldersHex)) {
        Write-Log "Start folder pins not configured (VisiblePlaces hex is empty) - skipping. See the capture note near the top of this script." WARN
        return
    }
    if (-not (Confirm-Action "Set the Start menu folder pins (next to the power button)?")) { Write-Log "Left Start folders unchanged." WARN; return }
    try {
        $hex = ($script:StartFoldersHex -replace '[^0-9A-Fa-f]', '')
        if ($hex.Length -eq 0 -or $hex.Length % 32 -ne 0) {
            Write-Log "VisiblePlaces hex is not a whole number of 16-byte GUIDs - skipping to avoid a broken Start menu." ERR
            return
        }
        $bytes = New-Object 'System.Collections.Generic.List[byte]'
        for ($i = 0; $i -lt $hex.Length; $i += 2) { $bytes.Add([Convert]::ToByte($hex.Substring($i, 2), 16)) }
        $startKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'
        if (-not (Test-Path $startKey)) { New-Item $startKey -Force | Out-Null }
        reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Start' "$env:USERPROFILE\Power_Windows_Start_backup.reg" /y 2>$null | Out-Null
        New-ItemProperty -Path $startKey -Name 'VisiblePlaces' -Value ([byte[]]$bytes.ToArray()) -PropertyType Binary -Force | Out-Null
        Write-Log "Start folder pins set ($([int]($bytes.Count / 16)) folders). Backup: Power_Windows_Start_backup.reg" OK
    } catch { Write-Log "Failed to set Start folders: $($_.Exception.Message)" ERR }
}

# --- 12. Remove the Widgets button (weather/news, taskbar left) ---------------
function Disable-WidgetsButton {
    if (-not (Confirm-Action "Remove the Widgets (weather & news) button from the taskbar?")) { return }
    # The HKCU TaskbarDa toggle is write-protected on Win11 (only Settings/Explorer may set
    # it), so disable Widgets via the supported policy instead. Needs elevation (we are).
    $errBefore = $global:Error.Count
    try {
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
        if (-not (Test-Path $pol)) { New-Item $pol -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty $pol 'AllowNewsAndInterests' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Log "Widgets disabled via policy (effective after the Explorer restart)." OK
    } catch {
        Write-Log "Could not disable Widgets: $($_.Exception.Message)" WARN
    }
    while ($global:Error.Count -gt $errBefore) { $global:Error.RemoveAt(0) }  # keep the step clean
}

# --- 13. Clean the taskbar: Task View, Search, Chat, Copilot, app pins --------
function Clear-TaskbarPins {
    if (-not (Confirm-Action "Remove all taskbar buttons except Start (Task View, Search, Chat, Copilot, app pins)?")) { return }
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    try {
        Set-ItemProperty $adv -Name 'ShowTaskViewButton' -Value 0 -Force
        Set-ItemProperty $adv -Name 'TaskbarMn'          -Value 0 -Force   # Chat
        New-ItemProperty $adv -Name 'ShowCopilotButton'  -Value 0 -PropertyType DWord -Force | Out-Null
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value 0 -Force
        Write-Log "Hid Task View, Search, Chat and Copilot buttons." OK
    } catch { Write-Log "Failed to hide taskbar buttons: $($_.Exception.Message)" WARN }
    # App pins (Edge/Store/etc.) - best effort; Win11 pin storage varies by build.
    try {
        $tb = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        if (Test-Path $tb) {
            reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' "$env:USERPROFILE\Power_Windows_Taskband_backup.reg" /y 2>$null | Out-Null
            Remove-ItemProperty $tb -Name 'Favorites'        -ErrorAction SilentlyContinue
            Remove-ItemProperty $tb -Name 'FavoritesResolve' -ErrorAction SilentlyContinue
            Write-Log "Cleared pinned taskbar apps (backup: Power_Windows_Taskband_backup.reg). Some pins may need manual unpin on 25H2." OK
        }
    } catch { Write-Log "Could not clear app pins: $($_.Exception.Message)" WARN }
}

# --- 14. Never sleep / screen off / hibernate --------------------------------
function Set-NeverSleep {
    if (-not (Confirm-Action "Set screen, sleep and hibernate timeouts to Never?")) { return }
    try {
        foreach ($t in 'monitor-timeout-ac', 'monitor-timeout-dc', 'standby-timeout-ac', 'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc') {
            powercfg /change $t 0 | Out-Null
        }
        Write-Log "Screen, sleep and hibernate set to Never (plugged in and on battery)." OK
    } catch { Write-Log "powercfg failed: $($_.Exception.Message)" ERR }
}

# --- 15. Turn off Start / File Explorer recommendations ----------------------
function Disable-StartRecommendations {
    if (-not (Confirm-Action "Turn off recommended/recent files in Start, Explorer and Jump Lists, plus Start tips?")) { return }
    try {
        $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        New-ItemProperty $adv 'Start_TrackDocs'           -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $adv 'Start_IrisRecommendations' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Log "Start recommendations and recent-file tracking turned off." OK
    } catch { Write-Log "Failed to turn off recommendations: $($_.Exception.Message)" ERR }
}

# --- 16. Do Not Disturb ------------------------------------------------------
function Set-DoNotDisturb {
    if (-not (Confirm-Action "Turn on Do Not Disturb (silence notification banners)?")) { return }
    # Windows 11's literal DND switch is an opaque CloudStore blob that scripts can't set
    # reliably. The stable equivalent is turning off toast banners, which we do here.
    try {
        $pn = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
        if (-not (Test-Path $pn)) { New-Item $pn -Force | Out-Null }
        New-ItemProperty $pn 'ToastEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
        $ns = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        if (-not (Test-Path $ns)) { New-Item $ns -Force | Out-Null }
        New-ItemProperty $ns 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Log "Do Not Disturb on (notification banners silenced)." OK
    } catch { Write-Log "Failed to set Do Not Disturb: $($_.Exception.Message)" ERR }
}

# --- Clean app shortcuts off the desktop (keep Recycle Bin and real files) ---
function Remove-DesktopShortcuts {
    if (-not (Confirm-Action "Delete the app shortcuts on the desktop (Recycle Bin and real files are kept)?")) { return }
    try {
        $count = 0
        foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
            if (-not $d -or -not (Test-Path $d)) { continue }
            Get-ChildItem -Path $d -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.lnk', '.url' } |
                ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop; $count++ } catch { } }
        }
        Write-Log "Removed $count desktop shortcut$(if ($count -eq 1) { '' } else { 's' })." OK
    } catch { Write-Log "Failed to clean desktop shortcuts: $($_.Exception.Message)" ERR }
}

# --- Restart Explorer so taskbar/Start changes take effect -------------------
function Restart-Explorer {
    try {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        Write-Log "Restarted Explorer to apply taskbar/Start changes." OK
    } catch { Write-Log "Could not restart Explorer: $($_.Exception.Message)" WARN }
}

# =============================================================================
#  Main
# =============================================================================
Write-Host ""
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$logo = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qOA4qOg4qOk4qGk4qCk4qOA4qKA4qOg4qCk4qCS4qCk4qCk4qOA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDiooDio7Tioa7ioYHioIHioIHio6Dio4DioJDiornioJvioIHioIDioIDioIDioJjiorPio6bioYDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKjsOKjv+Kjv+Kjv+KjpuKhgOKggOKgiOKiu+KhhuKguOKhhOKggOKjoOKjoOKigOKjsOKjvuKjv+Kjv+KjhOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qO84qO/4qO/4qO/4qK74qO/4qO34qGm4qCB4qKA4qOJ4qCQ4qCW4qKA4qOA4qCI4qCZ4qK/4qO/4qO/4qK/4qO/4qOn4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDio7zioI/io7/iornioIfiob7iornioZ/io7Dio77io7/io7/io7/io6bio7/io7/io7/io7bioYDioLnioYfioJrio7/io7/io4fioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKisOKhn+KigOKhj+KiuOKigOKgg+KguOKjseKjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+KggOKhkOKggOKgiOKggeKgiOKghuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qKA4qGf4qGC4qK44qCD4qCA4qCQ4qCA4qKg4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qO/4qGH4qOg4qCA4qCA4qCA4qCA4qCI4qGA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDio7jioYfioIPio77ioIDioIDioIDioIDiorjio7/io7/io7/io7/io7/io7/io7/io7/io7/io7/io7/io7/ioYfio7vioIDioIDioIDioIDioIDioqHioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKhn+Kgi+KggOKhv+KigOKggOKggOKigOKjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kgv+Kjp+KiuOKjhuKggOKggOKggOKggOKgiOKhhOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qGF4qCA4qKA4qGH4qK44qCA4qCA4qOg4qCF4qGA4qCJ4qCJ4qCJ4qCJ4qCB4qO54qGf4qCI4qCJ4qCk4qCw4qCS4qCI4qO/4qCA4qCA4qCA4qCA4qCA4qCB4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioYDioIDioILioYbiorjioITioIDio7fio7bio7/iorzio7Tio6fioYDioqDio7/io7/io6Tio77io7bio7/iob/io7/iorvioIDioIDioIDioIDioIDioJjioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKhh+KhhOKggOKhh+KguOKggOKggOKiu+Kjv+Kjv+Kjv+KjvuKjv+Kjh+KiuOKjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjt+Kjv+KjmOKgsOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCH4qGF4qKA4qGH4qCD4qGE4qCA4qK34qK/4qO/4qO/4qCf4qOx4qO/4qO/4qO/4qO/4qO/4qOt4qCZ4qK/4qKx4qO/4qGP4qCA4qCA4qCA4qCA4qCA4qGE4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioqDioYfioIDioIDiooHioYfioIDiorjioJDioIHioKDio77ioKbioInioIniooviob/ioInioL/io4bioIjioJ/io7/ioIfioYDioIDioIDioIDioIDioIHioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKiuOKhi+KggOKggOKguOKhh+KggOKguOKjtuKggOKggeKggOKggOKggOKggOKigOKggeKgpOKghOKggeKggOKjuOKgj+KggOKggeKggOKggOKggOKgmOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCM4qCA4qCA4qKA4qCA4qC54qOE4qCA4qK74qGH4qKA4qCA4qCb4qCb4qCb4qCT4qCb4qCb4qCL4qO04qKi4qGf4qCA4qCA4qCD4qCQ4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioqHioqDioIbioIDiornioYLiorjioYfio77ioaPioJDio6bio6Tio6Tio7Tio7bio7/io7/io7jioIHioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKgvuKgs+KggOKjuOKgiOKjt+KhhOKip+Kiu+Kjp+Khu+KgmuKgm+Kgm+Kgm+Kiq+Kjv+Khv+Kgg+KigOKhgOKjoOKggOKgg+KggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCY4qCD4qKA4qO/4qO44qOv4qC74qOO4qCA4qK74qO/4qO+4qOn4qOm4qO+4qO/4qO/4qCD4qOw4qO/4qOj4qO/4qGE4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDiooDio7TioY/io7/io7fio53ioIbioJjioKbioYDioIjioIHioIDioInioIvioInioIDio7Diop/io7Xio7/io7/ioqDio6Dio4DioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKjgOKgpOKjuuKiu+Kjv+Kjn+Kjv+Kjv+Kjv+Kjt+KjhOKggOKggOKggOKggOKggOKigOKggOKhgOKjkOKjteKjv+Kjv+Kjv+Kjv+KgiOKjv+Kjv+KhveKjtuKjpOKjgOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qOg4qG04qCL4qCA4qKw4qG/4qO84qO/4qO/4qK54qO/4qO/4qO/4qO/4qO34qOE4qGA4qCA4qKA4qCA4qOg4qO+4qO/4qO/4qO/4qO/4qO/4qO/4qCQ4qO/4qO/4qO/4qOe4qK/4qO/4qO/4qO24qOk4qOE4qGA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioqDio7biob/ioIvioIHioIDioIDioLjiorHio7/io7/ioYfiorjio7/io7/io7/io7/io7/io7/iob/ioJLioJLioJvioL/io7/io7/io7/io7/io7/io7/ioY/ioJDiorjio7/io7/io7/io6fioYnioLvio7/io7/io7/iob/ioIPioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKgiOKggeKggOKggOKggOKgkOKggeKiuOKjv+Kjv+Khh+KgmOKjv+Kjv+Kjv+Kjv+Kgn+Kgi+KggOKggOKggOKggOKggOKggOKgmeKiv+Kjv+Kjv+Kjv+Khh+KggOKgkOKgm+Kgm+Kgu+Kiv+Kjt+KhhOKgmOKgu+Kgi+KggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qC44qCb4qCL4qCB4qCA4qO/4qO/4qCf4qKB4qOA4qGA4qCA4qCA4qCA4qCA4qCA4qKA4qOk4qOA4qGZ4qK/4qO/4qCD4qCA4qCA4qCA4qCB4qCB4qCB4qCY4qCd4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIHioIHioIDioIDioIDioIjioqDio7Tio7/io5/io7DioYDioIDioIDioIDioqDio77io7Hio7/io7/io7bio6TioYbioIDioIDiooDioYDioYDioIDioIHioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKguOKjv+Kjv+Khn+Kjv+Kjv+KgguKggOKggOKggOKjv+Kjv+Kjv+Kjv+Kjv+Kjv+Kjv+Khh+KggOKggOKggeKggeKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggOKggA0K4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCI4qCb4qCb4qC34qC/4qC/4qCD4qCA4qCA4qCA4qK/4qC/4qC/4qC/4qCf4qCb4qCJ4qCB4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCA4qCADQrioIDioIDioIDiorjioYbioIDioIDioIDioIDiorjioYbioIDioIDiooDio7TioYLioIDioIDioIDioIDioIDioIDio7bioIDioIDioIDioIDioIDioIDio7DioYDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDio4Dio6TioYbioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIDioIANCuKggOKggOKggOKiuOKjp+KgtuKituKjhOKggOKiuOKhh+KggOKioOKhvuKiueKhgOKggOKioOKhtOKgtuKgtuKggOKjv+KggOKjtOKgluKggOKituKhvuKgk+Kis+KjsuKgguKggOKjtuKhtOKghuKisOKhhuKggOKisOKhhuKggOKjtOKgtuKgtuKggOKioOKhtuKgtuKghuKggOKgieKigOKhh+KggOKggOKisOKgtuKgtuKjhuKggOKisOKjpuKgtuKituKhhOKggOKggOKggA0K4qCA4qCA4qCA4qK44qGH4qCA4qCA4qO/4qCA4qK44qGH4qO04qO/4qOk4qO84qOn4qCA4qO/4qCB4qCA4qCA4qCA4qO/4qO+4qGB4qCA4qCA4qO84qO34qOk4qO04qO/4qGE4qCA4qO/4qCA4qCA4qK44qGH4qCA4qK44qGH4qCA4qCb4qC24qOk4qGA4qCY4qC34qOm4qGE4qCA4qCA4qKA4qGH4qCA4qCA4qO04qC24qCW4qO/4qCA4qK44qGH4qCA4qK44qGH4qCA4qCA4qCADQrioIDioIDioIDioLjioLfioKbioL7ioIvioIDioLjioIfioIDioIDioIDioLjioIPioIDioJnioLfioLbioLbioIDioL/ioIjioLvioKbioIDioIDioIDioLPioIPioIDioIDioIDioL/ioIDioIDioJjioLfioLbioL7ioIfioIDioLbioLbioL7ioIHioLbioKbioL7ioIPioIDioIDioJjioIfioIDioIDioLvioKbioL7ioL/ioIDioLjioIfioIDioLjioIfioIDioIDioIANCuKggA=='))
$script:esc = [char]27
# Enable VT processing so the scroll-region codes render (Windows Terminal has it on;
# the classic console needs it enabled explicitly).
try {
    $vt = Add-Type -PassThru -Name PwVt -Namespace PwWin -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
    $h = $vt::GetStdHandle(-11); $mode = 0; [void]$vt::GetConsoleMode($h, [ref]$mode); [void]$vt::SetConsoleMode($h, $mode -bor 4)
} catch { }
Clear-Host
[Console]::Write("$($script:esc)[r")                       # clear any prior scroll region
Write-Host $logo -ForegroundColor Cyan
Write-Host "  Fresh Windows 11 (25H2+) setup" -ForegroundColor Gray
# Pin the logo: confine scrolling to the region beneath it so the art stays put.
try {
    $hdr = [Console]::CursorTop
    $winH = [Console]::WindowHeight
    if ($winH -gt ($hdr + 4)) {
        [Console]::Write("$($script:esc)[$($hdr + 1);${winH}r")   # DECSTBM: scroll region below the header
        [Console]::SetCursorPosition(0, $hdr)                     # move the cursor into the region
    }
} catch { }
if ($script:Auto) { Write-Log "Running in -Auto mode: all prompts auto-accepted." }
if ($script:LogFile) { Write-Log "Logging to $($script:LogFile)" }

# 2. Connectivity gate
Write-Section "2. Internet connectivity"
if (-not (Test-Connectivity)) {
    Write-Log "No internet connection detected. Connect and re-run. Aborting." ERR
    [Console]::Write("$($script:esc)[r")   # release the fixed-logo scroll region
    try { Stop-Transcript | Out-Null } catch { }
    return
}

# 3-9
Invoke-Step "3. Activate Windows"          { Invoke-WindowsActivation }
Invoke-Step "4. Download Office 2024"       { Start-OfficeDownload }
Invoke-Step "5. Languages (English + Hebrew)" { Set-Languages }
Invoke-Step "6. Install apps (winget)"      { Install-Apps }
Invoke-Step "7. Default terminal + profile" { Set-DefaultTerminal }
Invoke-Step "8. Configure PowerShell 7"     { Set-PowerShell7Environment }
Invoke-Step "9. Turn off startup apps"      { Disable-StartupApps }
Invoke-Step "10. Dark mode"                 { Set-DarkMode }
Invoke-Step "11. Start folder pins"         { Set-StartFolders }
Invoke-Step "12. Remove Widgets button"     { Disable-WidgetsButton }
Invoke-Step "13. Clean taskbar"             { Clear-TaskbarPins }
Invoke-Step "14. Never sleep/screen/hibernate" { Set-NeverSleep }
Invoke-Step "15. Start recommendations off" { Disable-StartRecommendations }
Invoke-Step "16. Do Not Disturb"            { Set-DoNotDisturb }
Invoke-Step "17. Clean desktop shortcuts"   { Remove-DesktopShortcuts }

# Apply taskbar/Start tweaks (steps 10-13, 15) by restarting Explorer.
if (Confirm-Action "Restart Explorer now to apply the taskbar/Start changes?") { Restart-Explorer }

# Reconcile the background Office download, then mount / install / activate Office.
Complete-OfficeDownload
Invoke-Step "18. Install + activate Office" { Install-Office }

Write-Section "Done"
Write-Log "Power_Windows finished." OK
Write-Log "Recommended: restart Windows Terminal (font/profile) and sign out/in or reboot (language)." INFO
if ([string]::IsNullOrWhiteSpace($script:StartFoldersHex)) {
    Write-Log "Start folder pins (step 11) were skipped - set `$script:StartFoldersHex to enable them (see the capture note at the top)." INFO
}
if ($script:LogFile) { Write-Log "Full log: $($script:LogFile)" INFO }
[Console]::Write("$($script:esc)[r")   # release the fixed-logo scroll region
try { Stop-Transcript | Out-Null } catch { }
