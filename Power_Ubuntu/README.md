# 🐧 Fast Ubuntu Setup
### Install essential packages, configure security, and customize your desktop in minutes

 
| From | To |
|-------|-----|
| <img width="430" alt="Screenshot 1" src="https://github.com/user-attachments/assets/28624090-a4c8-4783-a0f2-1c39eb50e770" /> | <img width="430" alt="Screenshot 2" src="https://github.com/user-attachments/assets/186c7cb4-71d6-4b9a-aafb-fba8be2c68f3" /> |


# one liner

Ubuntu 26.04 ships `wget` (but not `curl`), so:

```bash
wget https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Ubuntu/ubuntu.sh && chmod +x ubuntu.sh && ./ubuntu.sh
```

Prefer `curl`? Install it first with `sudo apt install -y curl`:

```bash
curl -L -O https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Ubuntu/ubuntu.sh && chmod +x ubuntu.sh && ./ubuntu.sh
```

<br>

## ⚙️ Options

`./ubuntu.sh` is interactive by default. Flags:

| Flag | Effect |
|------|--------|
| `--full` | install everything, skip prompts |
| `--only=A,B,C` | run only these sections |
| `--skip=A,B,C` | run all sections except these |
| `--dry-run` | show what would run, change nothing |
| `--list-sections` | list every section |
| `--help` | full help |

**Sections:** `essentials dev security autoupdates brave gnome theme hebrew zsh ssh`

## ✅ Requirements

- A fresh **Ubuntu 26.04 LTS** desktop (also works on recent LTS releases)
- Run as your **normal user** — it calls `sudo` when needed
- An internet connection

> Heads-up: on a brand-new Ubuntu release, some third-party APT repos (e.g. Docker) may not be published yet. Those sections are skipped with a warning; the rest still run.

<br><br>

# 🌀 For New Ubuntu Users  
1️⃣ Press **CTRL + ALT + T** to open the terminal  
2️⃣ Paste the one-liner with **CTRL + SHIFT + V**  
3️⃣ Hit **ENTER** and let the magic happen

<img width="800" height="380" alt="Screenshot 2025-08-11 121333" src="https://github.com/user-attachments/assets/2458b811-daab-401c-8840-5a9df0022b18" />
 
