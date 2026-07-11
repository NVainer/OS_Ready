# 🪟 Power_Windows

Opinionated post-install setup for a **fresh Windows 11 (25H2+)** — one PowerShell script.

Every action asks **Y/N** first (answer **A** during app installs to accept the rest). Pass `-Auto` to accept everything unattended.

## One-liner

Open **Windows PowerShell** and paste — it runs from memory (no execution-policy prompt),
fetches itself to TEMP, and self-elevates to Administrator:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.ps1)))
```

Unattended (accept every prompt):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.ps1))) -Auto
```

## Testing — `Power_Windows.Test.ps1`

A verbose, instrumented copy for trial runs. It timestamps every line, records each step's
**PASS / FAIL / timing**, captures full error detail (including non-terminating errors),
probes the environment, and writes a consolidated report you can send back.

```powershell
# Safe DRY RUN — walks the whole flow and changes nothing (fine on your main PC):
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.Test.ps1))) -DryRun

# Real run (use a VM or a machine you actually intend to set up):
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.Test.ps1)))
```

> This runs from memory, so a fresh Windows' `Restricted` policy never blocks it (execution
> policy only gates `.ps1` **files**). The script fetches itself to TEMP and self-elevates with
> `-ExecutionPolicy Bypass`, so the whole thing is a single paste.

When it finishes, send back **`%USERPROFILE%\Power_Windows_TestReport_<timestamp>.txt`**
(and the `Power_Windows_TEST_<timestamp>.log` transcript if asked). `-DryRun` proves the
harness — elevation, connectivity, environment probe, prompts, reporting — with zero side effects.

## What it does

1. **Elevates** to an Administrator PowerShell (relaunches itself).
2. **Checks connectivity** — aborts if offline.
3. **Activates Windows** via [Microsoft Activation Scripts](https://github.com/massgravel/Microsoft-Activation-Scripts) (HWID / permanent, unattended).
4. **Downloads Office 2024** (`ProPlus2024Retail.img`) to `Downloads\` in the background.
5. **Sets languages** — English (primary) + Hebrew (secondary input).
6. **Installs apps** with `winget` (per-app prompt, or `A` for all): VC++ Redist, Python 3.14, Brave, Chrome, PowerShell 7, PowerToys, VirtualBox, VS Code, KeePassXC, Monitorian, Git, VLC. (Closes the PowerToys welcome window it pops open.)
7. **Windows Terminal** → default terminal application, default profile = PowerShell 7.
8. **Configures PowerShell 7** — oh-my-posh, Meslo Nerd Font, PSReadLine / posh-git / Terminal-Icons, and the custom profile + theme.
9. **Turns off all startup apps** (reversible from Task Manager).
10. **Windows (dark) theme** — applies the built-in dark theme (dark mode **and** the matching dark wallpaper).
11. **Start folder pins** next to the power button (see note below).
12. **Disables Widgets** (weather & news) via the supported policy — the button's own toggle is write-protected on Win11, so this may show as "managed by your organization".
13. **Cleans the taskbar** — hides Task View, Search, Chat, Copilot and clears app pins (only Start remains).
14. **Never** sleep / screen-off / hibernate (plugged in and on battery).
15. **Turns off** Start/Explorer recommendations, recent files, Jump List items, and Start tips.
16. **Do Not Disturb** on (silences notification banners).
17. **Cleans the desktop** (removes shortcuts, keeps Recycle Bin and real files) and **removes bloatware apps** — Xbox suite, LinkedIn, Feedback Hub, Get Help, Get Started, Clipchamp, Solitaire.
18. **Installs & activates Office** — waits for the download, mounts the image, runs `Setup.exe`, waits for it to finish, unmounts, then activates with MAS Ohook.

## Notes

- Requires an internet connection and `winget` (App Installer, ships with Win 11).
- A full log is written to `%USERPROFILE%\Power_Windows_<timestamp>.log`.
- Steps 10-16 write per-user (HKCU) settings — run as the user whose desktop you're setting up. Explorer is restarted at the end to apply taskbar/Start changes.
- **Elevation** opens the admin session as a **Windows Terminal tab** (in a dedicated `Power_Windows` window) and closes the original window it was launched from. Windows' security model keeps elevated tabs out of an unelevated window, so it's a separate elevated window that repeat runs share as tabs — not a tab inside your original window.
- Restart Windows Terminal (font/profile) and sign out/in or reboot (language) after it finishes.
- **Office** is downloaded during the run and installed at the end (step 17): the image is mounted and `Setup.exe` is run **from the image root** (so it finds its `Office\` payload). It keeps waiting while Office is actively installing and gives up after **5 min with no progress** (or 40 min total), leaving the image mounted if it can't confirm completion.

### Step 11 — Start folder pins (needs one capture)

The folders shown next to the power button are stored in an **undocumented binary blob** (`VisiblePlaces`), unique to each combination of folders. To set yours exactly, enable them once on any machine via **Settings → Personalization → Start → Folders**, then capture the bytes:

```powershell
((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' VisiblePlaces).VisiblePlaces | ForEach-Object { $_.ToString('X2') }) -join ''
```

Paste the resulting hex string into `$script:StartFoldersHex` near the top of the script. Left empty, step 11 is skipped (no risk of a broken Start menu).

### Step 16 — Do Not Disturb

Windows 11's literal "Do not disturb" toggle is an opaque CloudStore blob that scripts can't set reliably, so the script achieves the same effect by disabling toast notification banners.
