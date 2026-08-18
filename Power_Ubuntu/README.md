# 🐧 Fast Ubuntu Setup
### Install essential packages, configure security, and customize your desktop in minutes

 
| From | To |
|-------|-----|
| <img width="430" alt="Screenshot 1" src="https://github.com/user-attachments/assets/28624090-a4c8-4783-a0f2-1c39eb50e770" /> | <img width="430" alt="Screenshot 2" src="https://github.com/user-attachments/assets/186c7cb4-71d6-4b9a-aafb-fba8be2c68f3" /> |


# one liner

Ubuntu 26.04 ships `wget` but **not** `curl`, so:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Ubuntu/ubuntu.sh)
```

Process substitution keeps **stdin attached to your terminal**, so the interactive
prompts still work — a plain `wget -qO- ... | bash` pipe would eat them and
silently answer nothing. It also leaves no `ubuntu.sh` lying around afterwards.

Unattended, no questions asked:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Ubuntu/ubuntu.sh) --full
```

Prefer `curl`? Install it first with `sudo apt install -y curl`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NVainer/OS_Ready/main/Power_Ubuntu/ubuntu.sh)
```

<br>

## 📦 What you get

| Section | What it does |
|---------|--------------|
| `essentials` | full system upgrade, git, wget/curl, flatpak + Flathub, codecs, fonts EULA, GNOME tweaks tools, build toolchain (build-essential, dkms, kernel headers) |
| `cli` | eza, zoxide, fzf, atuin, bat, ripgrep, fd, lazygit, gh, delta, btop, fastfetch, neovim… |
| `fonts` | JetBrains Mono, Fira Code, Cascadia Code, MesloLGS NF (Nerd Font) |
| `dev` | Docker, Podman + Distrobox, KVM/QEMU + virt-manager |
| `security` | UFW, fail2ban, AppArmor utils, KeePassXC |
| `autoupdates` | unattended security upgrades |
| `pro` | Ubuntu Pro — free ESM (10 yrs of universe security fixes) + Livepatch |
| `brave` | Brave via its official repo, replacing Firefox |
| `claude` | Claude Desktop via Anthropic's official APT repo |
| `gnome` | dark mode, dock at the bottom, sane Nautilus sorting |
| `theme` | purple **accent colour** (the native GNOME 47+ one, not a GTK theme hack) |
| `hebrew` | Hebrew (IL) layout with Alt+Shift toggle |
| `zsh` | ZSH + Oh-My-Zsh + **Starship** prompt, autosuggestions, syntax highlighting |
| `ssh` | disable or harden sshd — only if an SSH server is actually installed |

<br>

## ⚙️ Options

`./ubuntu.sh` is interactive by default. Flags:

| Flag | Effect |
|------|--------|
| `--full` | install everything, skip prompts |
| `--yes` / `-y` | accept all y/n prompts |
| `--only=A,B,C` | run only these sections |
| `--skip=A,B,C` | run all sections except these (can't combine with `--only`) |
| `--dry-run` | show what would run, change nothing |
| `--list-sections` | list every section |
| `--help` | full help |

**Sections:** `essentials cli fonts dev security autoupdates pro brave claude gnome theme hebrew zsh ssh`

## ✅ Requirements

- A fresh **Ubuntu 26.04 LTS** desktop (also works on recent LTS releases)
- Run as your **normal user** — it calls `sudo` when needed
- An internet connection

> Heads-up: on a brand-new Ubuntu release, some third-party APT repos (e.g. Docker) may not be published yet. Those sections are skipped with a warning; the rest still run.

## ↩️ Changed your mind?

apt 3.x (Ubuntu 25.10+) can roll back the package changes:

```bash
sudo apt history-list
```

```bash
sudo apt history-undo <id>
```

Your previous `~/.zshrc` is backed up next to it as `~/.zshrc.bak.<timestamp>`.

## 🧬 Notes for Ubuntu 26.04

- **sudo is `sudo-rs`**, not GNU sudo. `-E` / bare `--preserve-env` are gone —
  only `--preserve-env=LIST` works. This script passes variables inline instead.
- **Core utilities are `rust-coreutils`**; `cp`, `mv` and `rm` are still GNU.
- **Wayland only** — GNOME 50 dropped the Xorg session entirely.
- **Ptyxis** is the default terminal; GNOME Terminal and its settings schema are
  gone, so terminal theming targets Ptyxis. Window size is set in *cells*
  (`default-columns` / `default-rows`) because Wayland ignores pixel geometry.
- Third-party repos are registered in **deb822 `.sources`** format, matching
  Ubuntu's own `/etc/apt/sources.list.d/ubuntu.sources`.

<br><br>

# 🌀 For New Ubuntu Users  
1️⃣ Press **CTRL + ALT + T** to open the terminal  
2️⃣ Paste the one-liner with **CTRL + SHIFT + V**  
3️⃣ Hit **ENTER** and let the magic happen

<img width="800" height="380" alt="Screenshot 2025-08-11 121333" src="https://github.com/user-attachments/assets/2458b811-daab-401c-8840-5a9df0022b18" />
