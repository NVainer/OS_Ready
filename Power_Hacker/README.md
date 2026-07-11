
# 🐧 Ubuntu → 🐉 Kali (on Wayland...)
### Install essential packages, configure security, and customize your desktop in minutes

 
| From | To |
|-------|-----|
| <img width="430" alt="Screenshot 1" src="https://github.com/user-attachments/assets/dd63124a-4fcc-4939-b4c5-a2aad7a6d171" /> | <img width="430" alt="Screenshot 2" src="https://github.com/user-attachments/assets/ed2988db-9573-4bd4-b067-55617ebc12e7" /> |


# one liner

Ubuntu 26.04 ships `wget` (but not `curl`), so:

```bash
wget https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Hacker/ubuntu_kali.sh && chmod +x ubuntu_kali.sh && ./ubuntu_kali.sh
```

Prefer `curl`? Install it first with `sudo apt install -y curl`:

```bash
curl -L -O https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Hacker/ubuntu_kali.sh && chmod +x ubuntu_kali.sh && ./ubuntu_kali.sh
```

<br>

## ⚙️ Options

`./ubuntu_kali.sh` is interactive by default. Flags:

| Flag | Effect |
|------|--------|
| `--full` | install everything, skip prompts |
| `--only=A,B,C` | run only these sections |
| `--skip=A,B,C` | run all sections except these |
| `--dry-run` | show what would run, change nothing |
| `--list-sections` | list every section |
| `--help` | full help |

**Sections:** `essentials dev security firefox brave gnome theme hebrew extensions zsh pentest metasploit burp wordlists payloads ssh`

## ✅ Requirements & notes

- A fresh **Ubuntu 26.04 LTS** desktop (also works on recent LTS releases)
- Run as your **normal user** — it calls `sudo` when needed
- The firewall is **not** auto-enabled on this profile (it would block your own listeners / reverse shells)
- Go and pipx tools land in `~/.local/bin` — **log out and back in** after setup so group memberships and PATH take effect
- On a brand-new release, some third-party repos (Docker, Mozilla PPA) may lag; those sections are skipped with a warning and the rest still run

<br><br>

# 🌀 For New Ubuntu Users  
1️⃣ Press **CTRL + ALT + T** to open the terminal  
2️⃣ Paste the one-liner with **CTRL + SHIFT + V**  
3️⃣ Hit **ENTER** and let the magic happen

<img width="800" height="380" alt="Screenshot 2025-08-11 121333" src="https://github.com/user-attachments/assets/2458b811-daab-401c-8840-5a9df0022b18" />
 
