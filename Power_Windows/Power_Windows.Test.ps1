#Requires -Version 5.1
<#
.SYNOPSIS
    Power_Windows (TEST BUILD) - verbose, instrumented copy for test runs.

.DESCRIPTION
    Same setup as Power_Windows.ps1, but VERBOSE and instrumented for testing:
    timestamped logs, per-step PASS/FAIL and timing, full error capture (including
    non-terminating errors), an environment probe, and a consolidated report file
    you can send back. Use -DryRun to walk the whole flow WITHOUT changing anything
    (no activation, downloads, installs, or registry edits) - safe on your main PC.

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

.PARAMETER DryRun
    Simulate the run: probe the environment and record what each step WOULD do,
    but make no changes. Safe to run on your main machine.

.EXAMPLE
    .\Power_Windows.Test.ps1 -DryRun
.EXAMPLE
    .\Power_Windows.Test.ps1 -Auto
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$DryRun
)

# =============================================================================
#  1. Self-elevation  (works from a file OR straight from the web via irm|iex)
# =============================================================================
$PowerWindowsUrl = 'https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.Test.ps1'

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Relaunch elevated from a file. When run from the web (no file on disk), fetch
    # ourselves to TEMP first so there is a file to hand to -File. Running elevated
    # with -ExecutionPolicy Bypass is what lets this work on a fresh, Restricted box.
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path $env:TEMP 'Power_Windows.Test.ps1'
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
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $scriptPath))
    if ($Auto)   { $argList += '-Auto' }
    if ($DryRun) { $argList += '-DryRun' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "[x] Elevation was cancelled or failed. Aborting." -ForegroundColor Red
    }
    return
}

$ErrorActionPreference = 'Continue'

# Mutable state
$script:Auto          = [bool]$Auto
$script:DryRun        = [bool]$DryRun
$script:AssumeAllApps = $false
$script:OfficeJob     = $null
$script:OfficeDest    = Join-Path $env:USERPROFILE 'Downloads\ProPlus2024Retail.img'
$script:OfficeUrl     = 'https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/en-us/ProPlus2024Retail.img'
$script:PwshExe       = $null
$script:LogFile       = $null
$script:ReportFile    = $null
$script:Results       = New-Object 'System.Collections.Generic.List[object]'
$script:Env           = [ordered]@{}

# Verbose test build: surface everything.
$VerbosePreference = 'Continue'

# Start-menu folder pins shown next to the power button (step 11). VisiblePlaces is an
# opaque sequence of 16-byte "place" GUIDs hardcoded in the Start menu - the bytes are
# not documented, so CAPTURE them from a machine where you enabled the folders you want:
#   Settings > Personalization > Start > Folders  ->  tick Explorer/Documents/Downloads/etc,
#   then run this and paste the hex string below (empty = leave Start folders unchanged):
#   ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' VisiblePlaces).VisiblePlaces | ForEach-Object { $_.ToString('X2') }) -join ''
$script:StartFoldersHex = ''

try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile    = Join-Path $env:USERPROFILE "Power_Windows_TEST_$stamp.log"
    $script:ReportFile = Join-Path $env:USERPROFILE "Power_Windows_TestReport_$stamp.txt"
    Start-Transcript -Path $script:LogFile -Append -ErrorAction Stop | Out-Null
} catch { }

# =============================================================================
#  Helpers
# =============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'DEBUG')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    switch ($Level) {
        'OK'    { Write-Host "[$ts] [+] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[$ts] [!] $Message" -ForegroundColor Yellow }
        'ERR'   { Write-Host "[$ts] [x] $Message" -ForegroundColor Red }
        'DEBUG' { Write-Host "[$ts] [.] $Message" -ForegroundColor DarkGray }
        default { Write-Host "[$ts] [*] $Message" -ForegroundColor Cyan }
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
    param(
        [Parameter(Mandatory, Position = 0)][string]$Title,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Action,
        [switch]$Mutating
    )
    Write-Section $Title
    if ($script:DryRun -and $Mutating) {
        Write-Log "[DRY-RUN] would run this step; skipping (no changes made)." WARN
        $script:Results.Add([pscustomobject]@{ Step = $Title; Status = 'SKIPPED (dry-run)'; DurationMs = 0; Error = '' })
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $errBefore = $global:Error.Count
    $status = 'PASS'; $detail = ''
    try {
        & $Action
    } catch {
        $status = 'FAIL'
        $detail = "$($_.Exception.Message)`n    at: $($_.InvocationInfo.PositionMessage)`n    stack: $($_.ScriptStackTrace)"
        Write-Log "STEP FAILED: $($_.Exception.Message)" ERR
        Write-Log "at: $($_.InvocationInfo.PositionMessage)" DEBUG
    }
    $sw.Stop()
    $added = $global:Error.Count - $errBefore
    if ($added -gt 0 -and $status -eq 'PASS') {
        $joined = (($global:Error[0..($added - 1)] | ForEach-Object { $_.ToString() }) -join ' | ')
        $status = 'PASS (with errors)'
        $detail = "non-terminating: $joined"
        Write-Log "$added non-terminating error(s): $joined" DEBUG
    }
    $script:Results.Add([pscustomobject]@{ Step = $Title; Status = $status; DurationMs = $sw.ElapsedMilliseconds; Error = $detail })
    $lvl = if ($status -like 'FAIL*') { 'ERR' } elseif ($status -like '*error*') { 'WARN' } else { 'OK' }
    Write-Log "$Title -> $status ($([int]$sw.ElapsedMilliseconds) ms)" $lvl
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
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
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
function Invoke-WindowsActivation {
    if (-not (Confirm-Action "Activate Windows now (MAS - HWID / permanent)?")) {
        Write-Log "Skipped Windows activation." WARN
        return
    }
    Write-Log "Running Microsoft Activation Scripts (HWID)..."
    try {
        $mas = Invoke-RestMethod -Uri 'https://get.activated.win' -ErrorAction Stop
        # /HWID = main menu option 1 (permanent HWID activation), fully unattended.
        & ([scriptblock]::Create($mas)) /HWID
        Write-Log "Activation routine finished (verify with 'slmgr /xpr')." OK
    } catch {
        Write-Log "Unattended activation failed: $($_.Exception.Message)" WARN
        Write-Log "Falling back to the interactive MAS menu (choose 1, then 1)..." INFO
        try { Invoke-Expression (Invoke-RestMethod -Uri 'https://get.activated.win') }
        catch { Write-Log "MAS could not be launched: $($_.Exception.Message)" ERR }
    }
}

# =============================================================================
#  4. Download Office 2024 (background)
# =============================================================================
function Start-OfficeDownload {
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
        Set-WinUserLanguageList -LanguageList $ordered -Force
        Write-Log "Language list set: $($ordered.LanguageTag -join ', ')" OK
    } catch {
        Write-Log "Failed to set languages: $($_.Exception.Message)" ERR
    }
}

# =============================================================================
#  6. Install apps (winget)
# =============================================================================
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
        Write-Log "Installing $name..."
        try {
            winget install --id $id -e --source winget `
                --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Log "$name installed." OK
            } else {
                Write-Log "${name}: winget exit code $LASTEXITCODE (may already be installed / needs restart)." WARN
            }
        } catch {
            Write-Log "$name failed: $($_.Exception.Message)" ERR
        }
    }
    Update-SessionPath
    $script:PwshExe = Get-PwshExe
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
    Write-TextFileNoBom -Path $Path -Content ($Json | ConvertTo-Json -Depth 32)
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

Import-Module -Name Microsoft.WinGet.CommandNotFound
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
          "template": "❯ ",
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
        try {
            winget install --id JanDeDobbeleer.OhMyPosh -e --source winget `
                --accept-source-agreements --accept-package-agreements
            Update-SessionPath
            Write-Log "oh-my-posh installed." OK
        } catch {
            Write-Log "oh-my-posh install failed: $($_.Exception.Message)" ERR
        }
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
try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null } catch { Write-Warning "NuGet provider: $($_.Exception.Message)" }
try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop } catch {}
foreach ($m in "PSReadLine","posh-git","Terminal-Icons") {
    try { Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop; Write-Host "[+] module installed: $m" }
    catch { Write-Warning "module ${m}: $($_.Exception.Message)" }
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
    if (-not (Confirm-Action "Enable dark mode (Windows + apps)?")) { Write-Log "Left theme unchanged." WARN; return }
    try {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if (-not (Test-Path $p)) { New-Item $p -Force | Out-Null }
        New-ItemProperty $p 'AppsUseLightTheme'   -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $p 'SystemUsesLightTheme' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Log "Dark mode enabled." OK
    } catch { Write-Log "Failed to enable dark mode: $($_.Exception.Message)" ERR }
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
    try {
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0 -Force
        # Also block it via policy so it stays gone.
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
        if (-not (Test-Path $pol)) { New-Item $pol -Force | Out-Null }
        New-ItemProperty $pol 'AllowNewsAndInterests' -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Log "Widgets button removed." OK
    } catch { Write-Log "Failed to remove Widgets: $($_.Exception.Message)" ERR }
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
#  Test reporting (verbose build only)
# =============================================================================
function Write-EnvironmentReport {
    Write-Section "Environment"
    $script:Env = [ordered]@{}
    $rec = {
        param($k, $v)
        $script:Env[$k] = "$v"
        Write-Log ("{0,-20}: {1}" -f $k, $v) DEBUG
    }
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        # ProductName still says "Windows 10" on Win11 - correct it from the build number.
        $osName = if ([int]$cv.CurrentBuild -ge 22000) { ($cv.ProductName -replace 'Windows 10', 'Windows 11') } else { $cv.ProductName }
        & $rec 'OS'             $osName
        & $rec 'DisplayVersion' $cv.DisplayVersion
        & $rec 'Build'          "$($cv.CurrentBuild).$($cv.UBR)"
        & $rec 'Edition'        $cv.EditionID
        & $rec 'InstallType'    $cv.InstallationType
    } catch { & $rec 'OS' "probe failed: $($_.Exception.Message)" }
    & $rec 'PowerShell' "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    & $rec 'Host'       $Host.Name
    & $rec 'User'       "$env:USERDOMAIN\$env:USERNAME"
    & $rec 'Admin'      (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    try { & $rec 'ExecPolicy' (Get-ExecutionPolicy) } catch { }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try { & $rec 'winget' ((winget --version 2>$null) | Select-Object -First 1) } catch { & $rec 'winget' 'present (version query failed)' }
    } else { & $rec 'winget' 'NOT FOUND' }
    $pw = Get-PwshExe
    & $rec 'pwsh'     $(if ($pw) { $pw } else { 'NOT FOUND' })
    & $rec 'OneDrive' $(if ($env:OneDrive) { $env:OneDrive } else { '(not set)' })
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        & $rec 'C: disk' ("{0} GB free / {1} GB" -f [math]::Round($d.FreeSpace / 1GB, 1), [math]::Round($d.Size / 1GB, 1))
    } catch { }
    & $rec 'Mode' $(if ($script:DryRun) { 'DRY-RUN' } else { 'LIVE' })
    & $rec 'Auto' $script:Auto
}

function Write-TestReport {
    $failed  = @($script:Results | Where-Object { $_.Status -like 'FAIL*' })
    $errored = @($script:Results | Where-Object { $_.Status -like '*with errors*' })
    $skipped = @($script:Results | Where-Object { $_.Status -like 'SKIPPED*' })
    $L = New-Object 'System.Collections.Generic.List[string]'
    $bar = ('=' * 72)
    $L.Add($bar)
    $L.Add('  POWER_WINDOWS - TEST REPORT')
    $L.Add("  Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $L.Add("  Mode      : $(if ($script:DryRun) { 'DRY-RUN' } else { 'LIVE' })   Auto=$($script:Auto)")
    $L.Add("  Summary   : $($script:Results.Count) steps | $($failed.Count) failed | $($errored.Count) with errors | $($skipped.Count) skipped")
    $L.Add($bar)
    $L.Add('')
    $L.Add('ENVIRONMENT')
    foreach ($k in $script:Env.Keys) { $L.Add(("  {0,-20}: {1}" -f $k, $script:Env[$k])) }
    $L.Add('')
    $L.Add('STEP RESULTS')
    foreach ($r in $script:Results) { $L.Add(("  {0,-42} {1,-20} {2,8} ms" -f $r.Step, $r.Status, $r.DurationMs)) }
    $L.Add('')
    $withDetail = @($script:Results | Where-Object { $_.Error })
    if ($withDetail.Count) {
        $L.Add('FAILURES / ERRORS (detail)')
        foreach ($r in $withDetail) {
            $L.Add('-' * 72)
            $L.Add("[$($r.Status)] $($r.Step)")
            $L.Add("  $($r.Error)")
        }
    } else {
        $L.Add('No failures or non-terminating errors were captured.')
    }
    $L.Add('')
    $L.Add("Full transcript (everything printed to the console): $($script:LogFile)")
    $L.Add($bar)
    $text = ($L -join "`r`n")
    if ($script:ReportFile) { try { Write-TextFileNoBom -Path $script:ReportFile -Content $text } catch { } }
    Write-Host ''
    Write-Host $text -ForegroundColor Gray
    Write-Section "Send these back to me"
    if ($script:ReportFile) { Write-Log "Report     : $($script:ReportFile)" OK }
    Write-Log "Transcript : $($script:LogFile)" OK
    Write-Log "Paste the report here (attach the transcript too if I ask for it)." INFO
}

# =============================================================================
#  Main
# =============================================================================
Write-Host ""
Write-Host "  ____                       __        ___           _                    " -ForegroundColor Cyan
Write-Host " |  _ \ _____      _____ _ __ \ \      / (_)_ __   __| | _____      _____  " -ForegroundColor Cyan
Write-Host " | |_) / _ \ \ /\ / / _ \ '__| \ \ /\ / /| | '_ \ / _\` |/ _ \ \ /\ / / __| " -ForegroundColor Cyan
Write-Host " |  __/ (_) \ V  V /  __/ |     \ V  V / | | | | | (_| | (_) \ V  V /\__ \ " -ForegroundColor Cyan
Write-Host " |_|   \___/ \_/\_/ \___|_|      \_/\_/  |_|_| |_|\__,_|\___/ \_/\_/ |___/ " -ForegroundColor Cyan
Write-Host ""
Write-Host "  Fresh Windows 11 (25H2+) setup  -  TEST / VERBOSE BUILD" -ForegroundColor Gray
if ($script:DryRun) { Write-Log "DRY-RUN: steps are simulated; NO changes will be made." WARN }
if ($script:Auto)   { Write-Log "Running in -Auto mode: all prompts auto-accepted." }
if ($script:LogFile) { Write-Log "Transcript: $($script:LogFile)" }

# 2. Connectivity gate
Write-Section "2. Internet connectivity"
if (-not (Test-Connectivity)) {
    Write-Log "No internet connection detected. Connect and re-run. Aborting." ERR
    try { Stop-Transcript | Out-Null } catch { }
    return
}

Write-EnvironmentReport

# 3-16  (all mutating -> skipped under -DryRun)
Invoke-Step "3. Activate Windows"          { Invoke-WindowsActivation } -Mutating
Invoke-Step "4. Download Office 2024"       { Start-OfficeDownload } -Mutating
Invoke-Step "5. Languages (English + Hebrew)" { Set-Languages } -Mutating
Invoke-Step "6. Install apps (winget)"      { Install-Apps } -Mutating
Invoke-Step "7. Default terminal + profile" { Set-DefaultTerminal } -Mutating
Invoke-Step "8. Configure PowerShell 7"     { Set-PowerShell7Environment } -Mutating
Invoke-Step "9. Turn off startup apps"      { Disable-StartupApps } -Mutating
Invoke-Step "10. Dark mode"                 { Set-DarkMode } -Mutating
Invoke-Step "11. Start folder pins"         { Set-StartFolders } -Mutating
Invoke-Step "12. Remove Widgets button"     { Disable-WidgetsButton } -Mutating
Invoke-Step "13. Clean taskbar"             { Clear-TaskbarPins } -Mutating
Invoke-Step "14. Never sleep/screen/hibernate" { Set-NeverSleep } -Mutating
Invoke-Step "15. Start recommendations off" { Disable-StartRecommendations } -Mutating
Invoke-Step "16. Do Not Disturb"            { Set-DoNotDisturb } -Mutating

# Apply taskbar/Start tweaks (steps 10-13, 15) by restarting Explorer.
if ($script:DryRun) {
    Write-Log "[DRY-RUN] would offer to restart Explorer; skipping." WARN
} elseif (Confirm-Action "Restart Explorer now to apply the taskbar/Start changes?") {
    Restart-Explorer
}

# Reconcile the background Office download last.
Complete-OfficeDownload

Write-Section "Done"
Write-Log "Power_Windows finished." OK
Write-Log "Recommended: restart Windows Terminal (font/profile) and sign out/in or reboot (language)." INFO
if ([string]::IsNullOrWhiteSpace($script:StartFoldersHex)) {
    Write-Log "Start folder pins (step 11) were skipped - set `$script:StartFoldersHex to enable them (see the capture note at the top)." INFO
}
Write-TestReport

if ($script:LogFile) { Write-Log "Full log: $($script:LogFile)" INFO }
try { Stop-Transcript | Out-Null } catch { }
