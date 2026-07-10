# 🪟 Power_Windows

Opinionated post-install setup for a **fresh Windows 11 (25H2+)** — one PowerShell script.

Every action asks **Y/N** first (answer **A** during app installs to accept the rest). Pass `-Auto` to accept everything unattended.

## One-liner

Open **Windows PowerShell** and run — the script self-elevates to Administrator:

```powershell
irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.ps1 -OutFile "$env:TEMP\Power_Windows.ps1"; & "$env:TEMP\Power_Windows.ps1"
```

Unattended (accept every prompt):

```powershell
irm https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Windows/Power_Windows.ps1 -OutFile "$env:TEMP\Power_Windows.ps1"; & "$env:TEMP\Power_Windows.ps1" -Auto
```

## What it does

1. **Elevates** to an Administrator PowerShell (relaunches itself).
2. **Checks connectivity** — aborts if offline.
3. **Activates Windows** via [Microsoft Activation Scripts](https://github.com/massgravel/Microsoft-Activation-Scripts) (HWID / permanent, unattended).
4. **Downloads Office 2024** (`ProPlus2024Retail.img`) to `Downloads\` in the background.
5. **Sets languages** — English (primary) + Hebrew (secondary input).
6. **Installs apps** with `winget` (per-app prompt, or `A` for all): VC++ Redist, Python 3.14, Brave, Chrome, PowerShell 7, PowerToys, VirtualBox, VS Code, KeePassXC, Monitorian, Git, VLC.
7. **Windows Terminal** → default terminal application, default profile = PowerShell 7.
8. **Configures PowerShell 7** — oh-my-posh, Meslo Nerd Font, PSReadLine / posh-git / Terminal-Icons, and the custom profile + theme.
9. **Turns off all startup apps** (reversible from Task Manager).

## Notes

- Requires an internet connection and `winget` (App Installer, ships with Win 11).
- A full log is written to `%USERPROFILE%\Power_Windows_<timestamp>.log`.
- Restart Windows Terminal (font/profile) and sign out/in or reboot (language) after it finishes.
- The Office image is downloaded only — install it yourself afterwards.
