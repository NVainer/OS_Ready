#!/usr/bin/env bash
#
# Power_Hacker — turn a fresh Ubuntu GNOME install into a pentesting workstation.
#
# Usage:
#   ./ubuntu_kali.sh               interactive, per-section prompts
#   ./ubuntu_kali.sh --full        install everything, skip prompts
#   ./ubuntu_kali.sh --yes         accept all y/n prompts (alias of --full)
#   ./ubuntu_kali.sh --only=A,B,C  run only listed sections
#   ./ubuntu_kali.sh --skip=A,B,C  run all sections except these
#   ./ubuntu_kali.sh --dry-run     show what would run, then exit
#   ./ubuntu_kali.sh --help
#
# Sections: essentials cli fonts dev security pro firefox brave gnome theme
#           hebrew extensions zsh pentest metasploit burp wordlists payloads ssh
#
# Target: Ubuntu 26.04 LTS "Resolute Raccoon" (GNOME 50, Wayland-only, apt 3.x,
# rust-coreutils + sudo-rs by default). Older LTS releases still work — sections
# that need something newer detect and skip.
#
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly STARSHIP_URL='https://raw.githubusercontent.com/NVainer/OS_Ready/refs/heads/main/Power_Ubuntu/starship.toml'
readonly LOG_FILE="${HOME}/ubuntu_kali.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
readonly REAL_HOME
# Directory this script lives in — used to prefer local repo files over the network.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Burp Suite — bump this when a new release is out.
readonly BURP_VERSION='2025.8.7'
readonly VERSION='2.0.0'

# Sections to run, in order. Single source of truth shared by the main loop,
# the usage text, and --list-sections. `fonts` runs before `zsh` so the prompt
# has its Nerd Font glyphs the first time a shell opens.
SECTIONS=(
  essentials cli fonts dev security pro firefox brave
  gnome theme hebrew extensions
  zsh
  pentest metasploit burp wordlists payloads
  ssh
)

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Mutable state
FULL_INSTALL=false
ASSUME_YES=false
ONLY_SECTIONS=""
SKIP_SECTIONS=""
DRY_RUN=false
UI=false                 # pinned-logo + progress-bar mode (unattended TTY runs)
STAGE_TOTAL=0
STAGE_DONE=0
SUDO_KEEPALIVE_PID=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { echo -e "${GREEN}[+] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
err()  { echo -e "${RED}[x] $*${NC}" >&2; }

# Redraw the single in-place progress bar on the real terminal (fd 3). No-op
# unless the pinned-logo UI is active (verbose output goes to the log instead).
progress() {
  $UI || return 0
  local label=${1:-} width=32 done=$STAGE_DONE total=$STAGE_TOTAL i fill pct bar=''
  (( total > 0 )) || total=1
  if (( done > total )); then done=$total; fi
  pct=$(( done * 100 / total ))
  fill=$(( done * width / total ))
  for (( i = 0; i < width; i++ )); do
    if (( i < fill )); then bar+='█'; else bar+='░'; fi
  done
  printf '\r\e[K  [%s] %3d%%  %s' "$bar" "$pct" "$label" >&3
}

# -----------------------------------------------------------------------------
# Prompts
# -----------------------------------------------------------------------------
ask_yes() {
  $FULL_INSTALL && return 0
  $ASSUME_YES   && return 0
  local answer
  read -r -p "$1 (y/n): " answer
  [[ "${answer,,}" == "y" ]]
}

section_enabled() {
  local s=$1
  if [[ -n "$ONLY_SECTIONS" ]]; then
    [[ ",${ONLY_SECTIONS}," == *",${s},"* ]]
    return
  fi
  [[ -z "$SKIP_SECTIONS" || ",${SKIP_SECTIONS}," != *",${s},"* ]]
}

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Power_Hacker — turn Ubuntu into a pentesting workstation  (v${VERSION})

Usage: $0 [options]

  --full              install everything, skip prompts
  --yes, -y           accept all y/n prompts
  --only=A,B,C        run only listed sections
  --skip=A,B,C        run all sections except these
  --dry-run           print the sections that would run, then exit
  --list-sections     print every section name, then exit
  --version, -V       print version and exit
  --help, -h          show this

Sections: ${SECTIONS[*]}
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --full)          FULL_INSTALL=true ;;
      --yes|-y)        ASSUME_YES=true ;;
      --only=*)        ONLY_SECTIONS="${arg#--only=}" ;;
      --skip=*)        SKIP_SECTIONS="${arg#--skip=}" ;;
      --dry-run)       DRY_RUN=true ;;
      --list-sections) printf '%s\n' "${SECTIONS[@]}"; exit 0 ;;
      --version|-V)    echo "$VERSION"; exit 0 ;;
      --help|-h)       usage; exit 0 ;;
      *)               err "Unknown argument: $arg"; usage; exit 2 ;;
    esac
  done

  if [[ -n "$ONLY_SECTIONS" && -n "$SKIP_SECTIONS" ]]; then
    err "Use either --only or --skip, not both."
    exit 2
  fi

  # Reject unknown section names so a typo (--only=pentestt) doesn't silently no-op.
  local combined="${ONLY_SECTIONS:-$SKIP_SECTIONS}" name
  if [[ -n "$combined" ]]; then
    local -a requested
    IFS=',' read -ra requested <<< "$combined"
    for name in "${requested[@]}"; do
      if [[ " ${SECTIONS[*]} " != *" ${name} "* ]]; then
        err "Unknown section: '${name}'"
        echo "Valid sections: ${SECTIONS[*]}" >&2
        exit 2
      fi
    done
  fi
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  if [[ $EUID -eq 0 ]]; then
    err "Don't run as root. Run as your normal user — sudo is invoked as needed."
    exit 1
  fi
  if ! grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
    warn "This script is tuned for Ubuntu and may misbehave elsewhere."
    ask_yes "Continue anyway?" || exit 1
  fi
  # ICMP first (fast); fall back to HTTPS since many networks filter ping.
  # Use whichever HTTP client exists — Ubuntu 26.04 ships wget but not curl.
  if ! ping -c1 -W2 archive.ubuntu.com >/dev/null 2>&1 \
     && ! ping -c1 -W2 8.8.8.8         >/dev/null 2>&1 \
     && ! { command -v curl >/dev/null 2>&1 \
            && curl -fsS --max-time 5 -o /dev/null https://archive.ubuntu.com; } \
     && ! { command -v wget >/dev/null 2>&1 \
            && wget -q --timeout=5 -O /dev/null https://archive.ubuntu.com; }; then
    err "No network connectivity."
    exit 1
  fi

  local waited=0
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    [[ $waited -eq 0 ]] && log "Waiting for apt lock to free..."
    sleep 2
    waited=$(( waited + 2 ))
    if (( waited >= 60 )); then
      err "apt lock held >60s; aborting."
      exit 1
    fi
  done

  # NOTE (Ubuntu 25.10+): the default sudo is sudo-rs, not GNU sudo. `-v`, `-n`
  # and inline `VAR=value cmd` all work, but `-E` is SILENTLY IGNORED
  # ("preserving the entire environment is not supported") and bare
  # `--preserve-env` is gone — only `--preserve-env=LIST` survives. Never reach
  # for `sudo -E` here; pass the variables explicitly instead.
  sudo -v
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!

  # Ubuntu 26.04 doesn't ship curl, but several sections use it. Install it up
  # front so those work regardless of run order (e.g. --only=zsh skips essentials).
  if ! command -v curl >/dev/null 2>&1; then
    log "Installing curl (not shipped by default on this Ubuntu)..."
    sudo apt-get install -y -q curl \
      || { sudo apt-get update -qq && sudo apt-get install -y -q curl; } \
      || warn "curl install failed; sections that need it may not work."
  fi
}

cleanup() {
  local rc=$?
  if $UI; then printf '\n' >&3 2>/dev/null || true; fi
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  (( rc != 0 )) && warn "Aborted (exit $rc). See $LOG_FILE."
  return 0
}

# -----------------------------------------------------------------------------
# Terminal theming
# -----------------------------------------------------------------------------
setup_terminal() {
  # Theme the CURRENT session in-band with OSC escapes — works on any VTE
  # terminal (GNOME Terminal, Ptyxis, Console) regardless of gsettings, so the
  # window looks right immediately. Session-scoped (resets when the terminal closes).
  {
    printf '\e]10;#D3D3D3\a'
    printf '\e]11;#0C0C0C\a'
    local _i _pal=(000000 AA0000 00AA00 AA5500 0000AA AA00AA 00AAAA AAAAAA 555555 FF5555 55FF55 FFFF55 5555FF FF55FF 55FFFF FFFFFF)
    for _i in "${!_pal[@]}"; do printf '\e]4;%d;#%s\a' "$_i" "${_pal[$_i]}"; done
    printf '\e[8;44;150t'
  } > /dev/tty 2>/dev/null || true

  command -v gsettings >/dev/null 2>&1 || return 0

  # Ptyxis (GTK4) is Ubuntu 26.04's default terminal and the only one shipped.
  # GNOME Terminal is gone from the default install and its settings schema
  # (org.gnome.Terminal.ProfilesList) no longer exists, so there is nothing
  # else left to theme here.
  gsettings list-schemas 2>/dev/null | grep -qx org.gnome.Ptyxis || return 0

  gsettings set org.gnome.Ptyxis interface-style        'dark' || true
  gsettings set org.gnome.Ptyxis audible-bell           false  || true
  gsettings set org.gnome.Ptyxis toast-on-copy-clipboard false || true
  gsettings set org.gnome.Ptyxis prompt-on-close        false  || true
  gsettings set org.gnome.Ptyxis restore-session        false  || true

  # Wayland ignores pixel geometry, which is why window-size/restore-window-size
  # did nothing. Ptyxis sizes new windows in CELLS — these are the keys that stick.
  gsettings set org.gnome.Ptyxis default-columns 150 || true
  gsettings set org.gnome.Ptyxis default-rows     44 || true

  # Colours and scrollback live per-profile, keyed by the default profile UUID.
  # A long scrollback matters here: tool output during an engagement is evidence.
  local _pu
  _pu=$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'")
  if [[ -n "$_pu" ]]; then
    local _pp="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$_pu/"
    gsettings set "$_pp" palette          'linux' || true
    gsettings set "$_pp" bold-is-bright   true    || true
    gsettings set "$_pp" scrollback-lines 100000  || true
    gsettings set "$_pp" scroll-on-output false   || true
  fi
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
banner() {
  echo -e "${GREEN}"
  cat <<'BANNER'
██████╗ ██╗██╗  ██╗ ██████╗██╗  ██╗        ██████╗ ██╗   ██╗███████╗███████╗ ██╗ █████╗ ███╗   ██╗
██╔══██╗██║██║  ██║██╔════╝██║ ██╔╝        ██╔══██╗██║   ██║██╔════╝██╔════╝███║██╔══██╗████╗  ██║
██████╔╝██║███████║██║     █████╔╝         ██████╔╝██║   ██║███████╗███████╗╚██║███████║██╔██╗ ██║
██╔══██╗██║╚════██║██║     ██╔═██╗         ██╔══██╗██║   ██║╚════██║╚════██║ ██║██╔══██║██║╚██╗██║
██████╔╝███████╗██║╚██████╗██║  ██╗███████╗██║  ██║╚██████╔╝███████║███████║ ██║██║  ██║██║ ╚████║
╚═════╝ ╚══════╝╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝
BANNER
  echo -e "${NC}\n"
}

# -----------------------------------------------------------------------------
# apt helpers
# -----------------------------------------------------------------------------
apt_update() { sudo apt-get update -qq; }

# The inline `VAR=value` form is deliberate and works under sudo-rs: Ubuntu's
# default `%sudo ALL=(ALL:ALL) ALL` rule matches ALL, which permits SETENV.
# Do NOT "simplify" this to `sudo -E` — sudo-rs ignores that flag (see preflight).
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }

# Install only the packages that are actually installable, so a single name
# that's missing on a given Ubuntu release doesn't fail the batch. Checks the
# candidate version rather than `apt-cache show`, which also succeeds for
# virtual packages that have no installable candidate.
install_available() {
  local pkgs=() p cand
  for p in "$@"; do
    cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -n "$cand" && "$cand" != "(none)" ]]; then
      pkgs+=("$p")
    else
      warn "Package not installable on this release, skipping: $p"
    fi
  done
  # if-form: with `&&`, an all-skipped batch would return non-zero and abort
  # the calling section under `set -e`.
  if (( ${#pkgs[@]} )); then apt_install "${pkgs[@]}"; fi
}

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
# Register a third-party APT repo in deb822 (.sources) format — the native
# format on Ubuntu 26.04 (see /etc/apt/sources.list.d/ubuntu.sources) and what
# upstreams now publish. Replaces the legacy one-line `.list` + `signed-by=`.
#
#   add_apt_source <name> <key-url> <uris> <suites> <components> [architectures]
#
# Pass an empty <components> for a flat repo (a suite ending in '/').
add_apt_source() {
  local name=$1 key_url=$2 uris=$3 suites=$4 components=$5
  local arches=${6:-$(dpkg --print-architecture)}

  # Fetch the key to a temp file first: a dropped connection must not leave a
  # truncated keyring in place, and we need to see the bytes to know whether
  # it's ASCII-armored (.asc) or a binary keyring (.gpg) — apt cares.
  local tmp ext=gpg
  tmp=$(mktemp)
  if ! curl -fsSL "$key_url" -o "$tmp"; then
    rm -f "$tmp"
    err "Could not download signing key for '${name}' from ${key_url}"
    return 1
  fi
  # Read the first line directly rather than `head | grep`: under `pipefail` an
  # early-exiting grep can SIGPIPE head and make an armored key look binary,
  # which would leave apt with a keyring it can't parse.
  local firstline=''
  LC_ALL=C read -r firstline < "$tmp" || true
  [[ "$firstline" == *'BEGIN PGP'* ]] && ext=asc
  local keyring="/usr/share/keyrings/${name}-archive-keyring.${ext}"

  sudo install -m 0755 -d /usr/share/keyrings
  sudo install -m 0644 "$tmp" "$keyring"
  rm -f "$tmp"

  {
    echo 'Types: deb'
    echo "URIs: ${uris}"
    echo "Suites: ${suites}"
    [[ -n "$components" ]] && echo "Components: ${components}"
    echo "Architectures: ${arches}"
    echo "Signed-By: ${keyring}"
  } | sudo tee "/etc/apt/sources.list.d/${name}.sources" >/dev/null

  # Clear out anything an older version of this script left behind, so apt
  # doesn't warn about the same repo being configured twice.
  sudo rm -f "/etc/apt/sources.list.d/${name}.list" \
             "/etc/apt/sources.list.d/${name}-release.list" \
             "/etc/apt/keyrings/${name}.asc" \
             "/etc/apt/keyrings/${name}-archive-keyring.gpg" \
             "/usr/share/keyrings/${name}-archive-keyring.$([[ $ext == gpg ]] && echo asc || echo gpg)"
}

clone_if_missing() {
  local url=$1 dest=$2
  shift 2
  [[ -d "$dest" ]] && return 0
  git clone "$@" "$url" "$dest"
}

pin_to_favorites() {
  local desktop=$1
  command -v gsettings >/dev/null 2>&1 || return 0
  [[ -f "/usr/share/applications/$desktop" \
     || -f "$REAL_HOME/.local/share/applications/$desktop" ]] || return 0
  local current new
  current=$(gsettings get org.gnome.shell favorite-apps)
  [[ "$current" == *"$desktop"* ]] && return 0
  if [[ "$current" == "@as []" || "$current" == "[]" ]]; then
    new="['$desktop']"
  else
    new="${current%]}, '$desktop']"
  fi
  gsettings set org.gnome.shell favorite-apps "$new" || true
}

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------
section_essentials() {
  log "Pre-accepting MS core fonts EULA..."
  apt_update
  apt_install debconf-utils software-properties-common
  sudo debconf-set-selections <<'EOF'
msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true
ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true
EOF

  log "Installing essentials..."
  apt_install \
    git curl ca-certificates wget unzip \
    flatpak figlet \
    ubuntu-restricted-extras \
    gnome-tweaks gnome-shell-extension-manager \
    yaru-theme-gtk yaru-theme-icon

  # apt 3.x ships a converter for the legacy one-line sources format. Ubuntu's
  # own sources are already deb822; this cleans up any third-party .list files
  # left over from other installers (or older versions of this script).
  if apt modernize-sources --help >/dev/null 2>&1; then
    log "Converting legacy .list repos to deb822 .sources..."
    sudo apt modernize-sources -y >/dev/null 2>&1 || true
  fi

  # Flathub gives Flatpak somewhere to install from — GNOME Software/App Center
  # surfaces it automatically, so it's the one line that makes `flatpak` useful.
  if ! flatpak remote-list --columns=name 2>/dev/null | grep -qx 'flathub'; then
    log "Adding Flathub remote..."
    sudo flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  fi
}

# Modern CLI stack. Everything here is in the Ubuntu 26.04 archive — no PPAs,
# no curl|sh installers, no cargo builds. Older releases that lack a package
# just skip it (install_available).
section_cli() {
  ask_yes 'Install the modern CLI stack (eza, zoxide, fzf, atuin, bat, ripgrep, lazygit, gh...)?' || return 0

  log "Installing CLI quality-of-life tools..."
  install_available \
    tmux ripgrep fd-find bat jq btop tree ncdu \
    pipx python3-venv \
    eza zoxide fzf atuin \
    fastfetch tealdeer glow \
    lazygit gh git-delta \
    duf gping hyperfine sd procs xh \
    neovim micro \
    wl-clipboard

  # Ubuntu ships a couple of these under alternate binary names — add the
  # familiar names to ~/.local/bin so `bat` and `fd` just work.
  mkdir -p "$REAL_HOME/.local/bin"
  if [[ -x /usr/bin/batcat ]]; then ln -sf /usr/bin/batcat "$REAL_HOME/.local/bin/bat"; fi
  if [[ -x /usr/bin/fdfind ]]; then ln -sf /usr/bin/fdfind "$REAL_HOME/.local/bin/fd";  fi

  # tealdeer provides `tldr` but ships no cache; seed it so the first call works.
  if command -v tldr >/dev/null 2>&1; then
    tldr --update >/dev/null 2>&1 || true
  fi
}

section_fonts() {
  ask_yes 'Install coding fonts (JetBrains Mono, Fira Code, Cascadia, MesloLGS NF)?' || return 0

  log "Installing packaged coding fonts..."
  install_available \
    fonts-jetbrains-mono fonts-firacode fonts-cascadia-code fonts-powerline

  # Nerd Fonts are not packaged in the Ubuntu archive, and the prompt needs the
  # patched glyphs — so this one still comes from upstream.
  log "Installing MesloLGS NF (patched glyphs for the shell prompt)..."
  install_meslo_nf
}

# Run an independent install step so one failure (e.g. Docker's repo) doesn't
# skip the rest of the section. `set -e` still applies inside the sub-shell.
dev_step() {
  local label=$1; shift
  set +e; ( set -e; "$@" ); local rc=$?; set -e
  if (( rc != 0 )); then warn "Dev: ${label} step failed (exit $rc); continuing."; fi
}

section_dev() {
  ask_yes "Install Dev stack (Docker, Podman/Distrobox, KVM/QEMU + virt-manager, Go, VS Code, Sublime Text)?" || return 0
  dev_step "Docker"            _dev_docker
  dev_step "Podman/Distrobox"  _dev_containers
  dev_step "KVM/virt-manager"  _dev_virt
  dev_step "VS Code"           _dev_vscode
  dev_step "Sublime Text"      _dev_sublime
  # Ptyxis, not org.gnome.Terminal — GNOME Terminal isn't installed on 26.04,
  # so pinning it was a silent no-op.
  pin_to_favorites org.gnome.Ptyxis.desktop
}

_dev_docker() {
  log "Installing Docker..."

  local codename
  # shellcheck source=/dev/null  # os-release defines its own VERSION; subshell keeps it contained
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  # Docker's repo is codename-pinned. It has published for 26.04 ('resolute'),
  # but a brand-new release can lag for weeks — fall back to the newest LTS it
  # does support so Docker still installs (packages are codename-agnostic in
  # practice). Keeps working on the day 26.10 ships.
  if ! curl -fsIL "https://download.docker.com/linux/ubuntu/dists/${codename}/Release" >/dev/null 2>&1; then
    warn "Docker has no repo for '${codename}' yet; using '${DOCKER_FALLBACK:-noble}'."
    codename=${DOCKER_FALLBACK:-noble}
  fi

  add_apt_source docker \
    'https://download.docker.com/linux/ubuntu/gpg' \
    'https://download.docker.com/linux/ubuntu' \
    "$codename" \
    'stable'

  apt_update
  apt_install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$REAL_USER"
}

# Podman (daemonless, rootless) and Distrobox both ship in the 26.04 archive.
# Distrobox is genuinely useful here: it runs a real Kali container on top of
# Ubuntu when a tool only ships as a Kali package. Ptyxis is container-aware
# and offers a tab per container.
_dev_containers() {
  log "Installing Podman + Distrobox..."
  install_available podman distrobox
}

_dev_virt() {
  log "Installing KVM/QEMU/virt-manager + Go..."
  # Filtered install so a package that's dropped on a newer release (e.g.
  # bridge-utils) can't take virt-manager down with it.
  install_available \
    golang \
    qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients bridge-utils \
    virt-manager swtpm wl-clipboard
  sudo usermod -aG libvirt "$REAL_USER" || true
  sudo usermod -aG kvm     "$REAL_USER" || true
  # Start the libvirt daemon (monolithic or the newer modular one) and autostart
  # the default NAT network. virt-manager can only reach qemu:///system once you
  # re-login so the 'libvirt' group applies to your session.
  sudo systemctl enable --now libvirtd 2>/dev/null \
    || sudo systemctl enable --now virtqemud.socket 2>/dev/null || true
  sudo virsh net-autostart default 2>/dev/null || true
  sudo virsh net-start     default 2>/dev/null || true
}

_dev_vscode() {
  log "Installing VS Code (snap)..."
  sudo snap install --classic code
  pin_to_favorites code_code.desktop
}

_dev_sublime() {
  log "Installing Sublime Text..."
  # Flat repo: the suite ends in '/' and carries no components.
  add_apt_source sublime-text \
    'https://download.sublimetext.com/sublimehq-pub.gpg' \
    'https://download.sublimetext.com/' \
    'apt/stable/' \
    ''
  apt_update
  apt_install sublime-text
  pin_to_favorites sublime_text.desktop
  xdg-mime default sublime_text.desktop text/plain || true
}

section_security() {
  ask_yes "Install security tools (AppArmor utils, KeePassXC, gufw)?" || return 0
  log "Installing security tools..."
  # gufw pulls in ufw but we deliberately DON'T enable the firewall here: on a
  # pentest box a default deny-incoming policy blocks your own reverse shells and
  # listeners. fail2ban is skipped too — it guards SSH, which this profile
  # disables (section_ssh). Enable either by hand if an engagement calls for it.
  install_available gufw apparmor-utils keepassxc

  if systemctl list-unit-files | grep -q '^apache2.service'; then
    sudo systemctl disable apache2 || true
  fi
}

# Ubuntu Pro is free for personal use on up to 5 machines. ESM extends security
# coverage from `main` to the whole `universe` repo for 10 years — which is where
# most of the tooling on this box comes from — and Livepatch applies kernel CVE
# fixes without a reboot. Unlike unattended-upgrades, nothing here restarts your
# services mid-engagement; it only widens what `apt upgrade` can fix.
section_pro() {
  if ! command -v pro >/dev/null 2>&1; then
    warn "Ubuntu Pro client not present; skipping."
    return 0
  fi

  if pro status --format=json 2>/dev/null | grep -q '"attached": *true'; then
    log "Ubuntu Pro attached — enabling ESM + Livepatch..."
    sudo pro enable esm-infra esm-apps livepatch --assume-yes 2>/dev/null || true
    return 0
  fi

  # `pro attach` with no token opens an interactive browser flow and blocks
  # waiting on the user — never acceptable on an unattended run. Note this is
  # the one section that deliberately does NOT auto-accept under --full.
  if $FULL_INSTALL || $ASSUME_YES || [[ ! -t 0 ]]; then
    log "Ubuntu Pro is not attached (it's free for personal use, up to 5 machines)."
    log "  Turn it on later with:  sudo pro attach"
    return 0
  fi

  ask_yes 'Attach Ubuntu Pro now? (free: 10 yrs of security updates + Livepatch)' || return 0
  if ! sudo pro attach; then
    warn "pro attach did not complete; run 'sudo pro attach' later."
    return 0
  fi
  sudo pro enable esm-infra esm-apps livepatch --assume-yes 2>/dev/null || true
}

section_firefox() {
  ask_yes "Replace snap Firefox with apt/PPA Firefox + FoxyProxy policy?" || return 0

  log "Removing snap Firefox..."
  sudo snap remove firefox      2>/dev/null || true
  sudo apt-get purge -y firefox 2>/dev/null || true

  log "Adding Mozilla PPA and pinning it..."
  if ! sudo add-apt-repository -y ppa:mozillateam/ppa; then
    warn "Mozilla PPA not available for this Ubuntu release — skipping Firefox install."
    return 0
  fi
  sudo tee /etc/apt/preferences.d/mozilla-firefox >/dev/null <<'EOF'
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF
  apt_update
  apt_install firefox

  log "Installing FoxyProxy via enterprise policy..."
  sudo mkdir -p /etc/firefox/policies
  sudo tee /etc/firefox/policies/policies.json >/dev/null <<'EOF'
{
  "policies": {
    "Extensions": {
      "Install": [
        "https://addons.mozilla.org/firefox/downloads/latest/foxyproxy-standard/latest.xpi"
      ]
    }
  }
}
EOF
}

section_brave() {
  ask_yes "Install Brave browser?" || return 0
  # The keyring path below matches the .sources file Brave itself publishes.
  log "Installing Brave (official APT repo)..."
  add_apt_source brave-browser \
    'https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg' \
    'https://brave-browser-apt-release.s3.brave.com' \
    'stable' \
    'main'
  apt_update
  apt_install brave-browser
  pin_to_favorites brave-browser.desktop
}

section_gnome() {
  ask_yes 'Apply GNOME tweaks (dark mode, dock at bottom, Do Not Disturb, sane Nautilus sort)?' || return 0
  log "Tweaking GNOME..."

  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'                || true
  gsettings set org.gnome.shell.extensions.ding show-home false                       || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'        || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false              || true
  gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false           || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 60         || true
  gsettings set org.gnome.desktop.notifications show-banners false                    || true

  local favs
  favs=$(gsettings get org.gnome.shell favorite-apps)
  favs=$(echo "$favs" | sed "s/, 'yelp.desktop'//; s/'yelp.desktop', //; s/'yelp.desktop'//")
  gsettings set org.gnome.shell favorite-apps "$favs" || true

  gsettings set org.gnome.nautilus.preferences default-sort-order 'mtime'
  gsettings set org.gnome.nautilus.preferences default-sort-in-reverse-order true
}

section_theme() {
  ask_yes 'Apply the purple accent colour?' || return 0

  # GNOME 47+ exposes a native accent colour that libadwaita apps actually
  # honour (blue teal green yellow orange red pink purple slate brown).
  # The old `gtk-theme Yaru-purple-dark` trick only ever recoloured legacy GTK3
  # apps — on GNOME 50 that's a shrinking minority of the desktop, so most of
  # the system stayed stock blue. Set the real thing when it exists.
  if gsettings list-keys org.gnome.desktop.interface 2>/dev/null | grep -qx accent-color; then
    log "Setting the native GNOME accent colour to purple..."
    gsettings set org.gnome.desktop.interface accent-color 'purple'   || true
    gsettings set org.gnome.desktop.interface gtk-theme    'Yaru-dark' || true
  else
    warn "No native accent-color on this GNOME; falling back to the Yaru-purple theme."
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-purple-dark' 2>/dev/null \
      || warn "Couldn't set Yaru-purple-dark — is yaru-theme-gtk installed?"
  fi
}

section_hebrew() {
  ask_yes 'Add Hebrew (IL) keyboard layout with Alt+Shift toggle?' || return 0
  gsettings set org.gnome.desktop.input-sources xkb-options \
    "['grp:alt_shift_toggle', 'lv3:ralt_switch']" || true
  gsettings set org.gnome.desktop.input-sources sources \
    "[('xkb', 'us'), ('xkb', 'il')]" || true
}

section_extensions() {
  ask_yes 'Enable top-bar extensions (system-monitor, apps-menu, places-menu, workspaces) + VPN settings shortcut?' || return 0

  # On 26.04 `gnome-shell-extensions` is an empty transitional metapackage that
  # Debian says will likely be removed — the extensions are shipped as separate
  # packages now. Install exactly the four this section enables below.
  log "Installing the GNOME extensions this section enables..."
  install_available \
    gnome-shell-extension-system-monitor \
    gnome-shell-extension-apps-menu \
    gnome-shell-extension-places-menu \
    gnome-shell-extension-workspace-indicator

  mkdir -p "$REAL_HOME/.local/bin"
  cat > "$REAL_HOME/.local/bin/enable-extensions-toggle.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
EXTS=(
  system-monitor@gnome-shell-extensions.gcampax.github.com
  apps-menu@gnome-shell-extensions.gcampax.github.com
  places-menu@gnome-shell-extensions.gcampax.github.com
  workspace-indicator@gnome-shell-extensions.gcampax.github.com
)
gsettings set org.gnome.shell enabled-extensions \
  "['${EXTS[0]}', '${EXTS[1]}', '${EXTS[2]}', '${EXTS[3]}']"
for e in "${EXTS[@]}"; do
  gnome-extensions disable "$e" || true
  gnome-extensions enable  "$e" || true
done
rm -f "$HOME/.config/autostart/enable-extensions-toggle.desktop"
EOF
  chmod +x "$REAL_HOME/.local/bin/enable-extensions-toggle.sh"

  mkdir -p "$REAL_HOME/.config/autostart"
  cat > "$REAL_HOME/.config/autostart/enable-extensions-toggle.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Enable Extensions Toggle Once
Exec=$REAL_HOME/.local/bin/enable-extensions-toggle.sh
X-GNOME-Autostart-enabled=true
EOF

  # VPN settings launcher
  mkdir -p "$REAL_HOME/.local/share/applications"
  cat > "$REAL_HOME/.local/share/applications/vpn-settings.desktop" <<'EOF'
[Desktop Entry]
Name=VPN Settings
Exec=gnome-control-center network
Icon=/usr/share/icons/Yaru/scalable/status/view-private-symbolic.svg
Terminal=false
Type=Application
Categories=Settings;Network;
EOF
  chmod +x "$REAL_HOME/.local/share/applications/vpn-settings.desktop"
  pin_to_favorites vpn-settings.desktop
}

section_zsh() {
  ask_yes 'Install ZSH + Oh-My-Zsh + Starship prompt?' || return 0

  log "Installing zsh, Starship and shell plugins..."
  apt_install zsh zsh-common
  # Starship replaces Powerlevel10k: it's packaged in the Ubuntu archive (so no
  # git clone and no network fetch of a theme), actively maintained, cross-shell,
  # and noticeably faster in large git repos. The plugins are packaged too, so
  # apt keeps them updated instead of three unpinned clones drifting forever.
  install_available starship zsh-autosuggestions zsh-syntax-highlighting
  sudo chsh -s "$(command -v zsh)" "$REAL_USER"

  if [[ ! -d "$REAL_HOME/.oh-my-zsh" ]]; then
    log "Installing Oh-My-Zsh..."
    # Download to a file first: `sh -c "$(curl ...)"` would run an empty script
    # (and report success) if the download failed, leaving OMZ silently missing.
    local omz_installer
    omz_installer=$(mktemp)
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
      -o "$omz_installer"
    RUNZSH=no CHSH=no sh "$omz_installer"
    rm -f "$omz_installer"
  else
    log "Oh-My-Zsh already installed; skipping."
  fi

  # The prompt needs patched glyphs. Normally the `fonts` section has already
  # installed them; catch the --only=zsh case so the prompt isn't full of tofu.
  if ! fc-list 2>/dev/null | grep -qi 'MesloLGS NF'; then
    log "Installing MesloLGS NF (needed for the prompt glyphs)..."
    install_meslo_nf
  fi

  # Starship's config, preferring the copy shipped in the repo next to this
  # script. A missing config isn't fatal — Starship falls back to its defaults.
  log "Installing Starship config..."
  mkdir -p "$REAL_HOME/.config"
  local local_toml="$SCRIPT_DIR/../Power_Ubuntu/starship.toml"
  if [[ -f "$local_toml" ]]; then
    cp "$local_toml" "$REAL_HOME/.config/starship.toml"
  elif curl -fsSL "$STARSHIP_URL" -o "$REAL_HOME/.config/starship.toml.tmp"; then
    mv "$REAL_HOME/.config/starship.toml.tmp" "$REAL_HOME/.config/starship.toml"
  else
    rm -f "$REAL_HOME/.config/starship.toml.tmp"
    warn "Couldn't fetch starship.toml; Starship will use its default look."
  fi

  local zshrc="$REAL_HOME/.zshrc"
  if [[ ! -f "$zshrc" ]]; then
    warn "No .zshrc found (Oh-My-Zsh may not have created it); skipping shell config."
    return 0
  fi

  cp "$zshrc" "$zshrc.bak.$(date +%s)"

  # Oh-My-Zsh stays for its completions and history defaults, but Starship owns
  # the prompt, so OMZ's theme is emptied. Plugins load from /usr/share below
  # rather than through OMZ's plugin list.
  sed -i 's|^ZSH_THEME=.*|ZSH_THEME=""|' "$zshrc"
  sed -i 's/^plugins=.*/plugins=(git)/'  "$zshrc"

  # Drop anything a previous run of this script wrote, so re-running is a
  # replace rather than an append. Also strips the v1 Powerlevel10k wiring.
  sed -i '/^### BEGIN POWER_HACKER ###$/,/^### END POWER_HACKER ###$/d'                   "$zshrc"
  sed -i '/^### BEGIN ZSH COMPLETION BLOCK ###$/,/^### END ZSH COMPLETION BLOCK ###$/d'   "$zshrc"
  sed -i '/POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD/d; /\.p10k\.zsh/d'                   "$zshrc"

  # Quoted heredoc: everything below is written literally and evaluated by zsh
  # at shell startup, not expanded by bash here.
  cat >> "$zshrc" <<'EOF'
### BEGIN POWER_HACKER ###
# zsh doesn't read ~/.profile, so add ~/.local/bin (pipx, go install, our
# bat/fd shims) here.
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"

# Completion
autoload -Uz compinit
compinit
bindkey '^I' expand-or-complete
setopt AUTO_MENU LIST_PACKED
zstyle ':completion:*' completer _complete
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Suggestions (packaged by Ubuntu, kept current by apt)
[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] \
  && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Modern CLI wiring — each guarded, so a tool you didn't install stays silent.
command -v starship >/dev/null && eval "$(starship init zsh)"
command -v zoxide   >/dev/null && eval "$(zoxide init zsh)"          # z <dir>
command -v atuin    >/dev/null && eval "$(atuin init zsh --disable-up-arrow)"
[[ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -r /usr/share/doc/fzf/examples/completion.zsh   ]] && source /usr/share/doc/fzf/examples/completion.zsh

if command -v eza >/dev/null; then
  alias ls='eza --group-directories-first'
  alias ll='eza -lg  --group-directories-first --git'
  alias la='eza -lag --group-directories-first --git'
  alias lt='eza -T --level=2 --group-directories-first'
fi

# Handy on an engagement box.
[[ -d "$HOME/wordlists" ]] && export WORDLISTS="$HOME/wordlists"
[[ -d "$HOME/payloads"  ]] && export PAYLOADS="$HOME/payloads"

# Must stay last: syntax highlighting wraps every widget defined above it.
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
  && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
### END POWER_HACKER ###
EOF
}

install_meslo_nf() {
  local fontdir="$REAL_HOME/.local/share/fonts"
  mkdir -p "$fontdir"
  local base='https://github.com/romkatv/powerlevel10k-media/raw/master'
  local f out failed=0
  for f in \
    'MesloLGS%20NF%20Regular.ttf' \
    'MesloLGS%20NF%20Bold.ttf' \
    'MesloLGS%20NF%20Italic.ttf' \
    'MesloLGS%20NF%20Bold%20Italic.ttf'; do
    out="$fontdir/${f//%20/ }"
    [[ -f "$out" ]] && continue
    # Fonts are a nice-to-have (glyphs still render via fallback) — download to
    # a temp file so a dropped connection can't leave a truncated .ttf behind,
    # and never let a failure abort the rest of the section.
    if curl -fsSL "$base/$f" -o "$out.tmp"; then
      mv "$out.tmp" "$out"
    else
      rm -f "$out.tmp"
      failed=1
    fi
  done
  (( failed )) && warn "Some MesloLGS NF fonts failed to download; prompt glyphs may look off."
  fc-cache -f >/dev/null 2>&1 || true
}

section_pentest() {
  ask_yes "Install pentest tools (nmap, wireshark, sqlmap, hydra, ffuf, radare2, searchsploit, ProjectDiscovery suite, ...)?" || return 0
  log "Installing core pentest tools from apt..."
  apt_install \
    nmap aircrack-ng hashcat hydra gobuster sqlmap \
    john netcat-traditional tcpdump \
    openvpn whois nikto \
    postgresql postgresql-contrib libpq-dev libpcap-dev

  # Broader tool set — filtered so a name missing on a given release is skipped
  # rather than failing the whole batch.
  install_available \
    ffuf dnsutils dnsrecon enum4linux smbclient masscan proxychains4 \
    binwalk foremost steghide libimage-exiftool-perl radare2

  sudo systemctl enable --now postgresql

  # Wireshark's debconf asks whether non-root users may capture. Non-interactive
  # installs default to "no", leaving dumpcap root-only. Preseed "yes", then add
  # the user to the 'wireshark' group (effective after the next login).
  echo 'wireshark-common wireshark-common/install-setuid boolean true' \
    | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q wireshark
  sudo usermod -aG wireshark "$REAL_USER" || true

  # searchsploit / exploit-db archive — not packaged on Ubuntu, so clone the repo.
  if ! command -v searchsploit >/dev/null 2>&1 && [[ ! -d /opt/exploitdb ]]; then
    log "Installing searchsploit (exploit-db)..."
    if sudo git clone --depth=1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb; then
      sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit
    else
      warn "searchsploit clone failed; skipping."
    fi
  fi

  # ProjectDiscovery Go tools — installed into ~/.local/bin (on PATH via ~/.profile
  # after re-login). Needs the Dev section's Go; each install is best-effort.
  if command -v go >/dev/null 2>&1; then
    log "Installing ProjectDiscovery tools via 'go install' (this can take a while)..."
    local gotool
    for gotool in \
      github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest \
      github.com/projectdiscovery/httpx/cmd/httpx@latest \
      github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest \
      github.com/projectdiscovery/naabu/v2/cmd/naabu@latest; do
      GOBIN="$REAL_HOME/.local/bin" go install "$gotool" || warn "go install failed: $gotool"
    done
  else
    warn "Go not found (run the Dev section) — skipping nuclei/httpx/subfinder/naabu."
  fi

  # netexec (nxc — the CrackMapExec successor) via pipx.
  if command -v pipx >/dev/null 2>&1; then
    log "Installing netexec (nxc) via pipx..."
    pipx install netexec >/dev/null 2>&1 || warn "pipx install netexec failed; skipping."
    pipx ensurepath >/dev/null 2>&1 || true
  fi
}

section_metasploit() {
  ask_yes "Install Metasploit framework?" || return 0

  if dpkg -s metasploit-framework >/dev/null 2>&1; then
    log "Metasploit already installed; skipping."
    return 0
  fi

  # The omnibus installer ships a self-contained package (bundled Ruby, etc.),
  # so no separate build toolchain is needed here.
  local tmp
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    curl -fsSL \
      https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb \
      -o msfinstall
    chmod +x msfinstall
    # `yes` auto-answers any "update existing install?" prompt msfinstall throws.
    yes | sudo ./msfinstall
  )
  rm -rf "$tmp"

  # NOTE: don't auto-run `msfdb init` here — it's interactive (DB + webservice
  # prompts) and stalls under `tee`/non-tty stdin. Run it after first login.
  log "Metasploit installed. Run 'msfdb init' yourself after rebooting/logging back in."
}

section_burp() {
  ask_yes "Install Burp Suite Community ${BURP_VERSION}?" || return 0

  local installer="/tmp/burpsuite_community_linux_${BURP_VERSION}.sh"
  log "Downloading Burp Suite ${BURP_VERSION}..."
  if ! wget -q -O "$installer" \
       "https://portswigger-cdn.net/burp/releases/download?product=community&version=${BURP_VERSION}&type=Linux&format=Sh"; then
    warn "Burp download failed (version ${BURP_VERSION} may be outdated — update BURP_VERSION at the top of this script)."
    rm -f "$installer"
    return 0
  fi

  # Sanity-check the download before running it as root — a CDN error page saved
  # as the installer would otherwise be executed.
  if [[ "$(stat -c%s "$installer" 2>/dev/null || echo 0)" -lt 1000000 ]] \
     || ! head -c2 "$installer" | grep -q '#!'; then
    warn "Burp installer looks wrong (too small or not a shell script); skipping."
    rm -f "$installer"
    return 0
  fi

  chmod +x "$installer"
  sudo "$installer" -q -dir /opt/BurpSuiteCommunity -overwrite -nofilefailures
  rm -f "$installer"

  # Burp's install4j launcher gets a generated name, so glob for it rather than
  # parsing `ls`. if-form at the end: a bare `[[ ... ]] && cmd` would return
  # non-zero when no launcher is found and mark the whole section as failed.
  local burp_desktop='' cand
  for cand in "$REAL_HOME/.local/share/applications/"install4j*BurpSuiteCommunity.desktop; do
    [[ -f "$cand" ]] || continue
    burp_desktop=$(basename "$cand")
    break
  done
  if [[ -n "$burp_desktop" ]]; then
    pin_to_favorites "$burp_desktop"
  else
    warn "Couldn't find Burp's .desktop launcher; not pinning it."
  fi
}

section_wordlists() {
  ask_yes "Download Wordlists (SecLists + rockyou)?" || return 0
  log "Downloading wordlists to $REAL_HOME/wordlists ..."
  mkdir -p "$REAL_HOME/wordlists"
  clone_if_missing https://github.com/danielmiessler/SecLists.git "$REAL_HOME/wordlists/SecLists" --depth=1
  if [[ ! -f "$REAL_HOME/wordlists/rockyou.txt" ]]; then
    # Prefer the copy SecLists already ships; fall back to a direct download.
    local sl_rock="$REAL_HOME/wordlists/SecLists/Passwords/Leaked-Databases/rockyou.txt.tar.gz"
    if [[ -f "$sl_rock" ]]; then
      log "Extracting rockyou.txt from SecLists..."
      tar -xzf "$sl_rock" -C "$REAL_HOME/wordlists/"
    else
      wget -q -O "$REAL_HOME/wordlists/rockyou.txt" \
        https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt
    fi
    # Sanity-check size (~130 MB); warn if a truncated/failed download slipped through.
    if [[ -f "$REAL_HOME/wordlists/rockyou.txt" ]]; then
      local sz; sz=$(stat -c%s "$REAL_HOME/wordlists/rockyou.txt" 2>/dev/null || echo 0)
      (( sz > 100000000 )) || warn "rockyou.txt is smaller than expected ($sz bytes)."
    fi
  fi
}

section_payloads() {
  ask_yes "Download Payloads (PayloadsAllTheThings + php-reverse-shell)?" || return 0
  log "Downloading payloads to $REAL_HOME/payloads ..."
  mkdir -p "$REAL_HOME/payloads"
  clone_if_missing https://github.com/swisskyrepo/PayloadsAllTheThings.git "$REAL_HOME/payloads/PayloadsAllTheThings" --depth=1
  if [[ ! -f "$REAL_HOME/payloads/php-reverse-shell.php" ]]; then
    curl -fsSL https://raw.githubusercontent.com/pentestmonkey/php-reverse-shell/master/php-reverse-shell.php \
      -o "$REAL_HOME/payloads/php-reverse-shell.php"
  fi
}

section_ssh() {
  # openssh-server is not part of a fresh Ubuntu desktop install, so the old
  # unconditional "disable ssh" step was a no-op on the machines this script
  # actually targets. Only act when there really is an SSH server here.
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    log "No SSH server installed — nothing to disable."
    return 0
  fi

  if ask_yes "An SSH server is installed. Disable it? (recommended on a pentest box)"; then
    log "Disabling SSH service..."
    sudo systemctl disable --now ssh 2>/dev/null || true
    return 0
  fi

  ask_yes "Harden sshd instead (no root login, keys only)?" || return 0
  log "Hardening sshd..."
  sudo install -m 0755 -d /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/99-power-hacker.conf >/dev/null <<'EOF'
# Written by Power_Hacker.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  sudo systemctl reload ssh 2>/dev/null || true
  warn "Password logins are now off — make sure your key is in ~/.ssh/authorized_keys."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Show which sections would run, then exit — makes no changes.
  if $DRY_RUN; then
    echo "Sections that would run:"
    local s
    for s in "${SECTIONS[@]}"; do
      section_enabled "$s" && echo "  - $s"
    done
    exit 0
  fi

  # Tee everything to a log file for post-mortem debugging. The terminal keeps
  # colour; the log has ANSI colour codes stripped so it stays greppable.
  # fd 3/4 keep a handle on the real terminal (progress bar + restore at the end).
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "===== Power_Hacker v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S') — args: $* =====" >> "$LOG_FILE"
  exec 3>&1 4>&2
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

  trap cleanup EXIT INT TERM

  # Theme the terminal first thing, before the (possibly slow) preflight.
  setup_terminal

  preflight

  if ! $FULL_INSTALL && ! $ASSUME_YES && [[ -z "$ONLY_SECTIONS" ]]; then
    local full_choice
    read -r -p "Full install (recommended)? (y/n): " full_choice
    [[ "${full_choice,,}" == "y" ]] && FULL_INSTALL=true
  fi

  banner

  # On an unattended run in a real terminal, pin the logo and show a single
  # progress bar: route the verbose per-section output to the log only and draw
  # the bar on the terminal (fd 3). Interactive runs keep the scrolling output.
  if [[ -t 3 ]] && { $FULL_INSTALL || $ASSUME_YES; }; then
    UI=true
    local s0
    for s0 in "${SECTIONS[@]}"; do
      if section_enabled "$s0"; then STAGE_TOTAL=$(( STAGE_TOTAL + 1 )); fi
    done
    exec > >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE") 2>&1
    printf '\n' >&3
  fi

  local -a FAILED_SECTIONS=()
  local s rc
  for s in "${SECTIONS[@]}"; do
    section_enabled "$s" || continue
    progress "$s"
    # Best-effort: isolate each section in a subshell so one failure — e.g.
    # Docker's codename-pinned APT repo or the Mozilla PPA not yet published for
    # a brand-new Ubuntu release — doesn't abort the whole run. `set -e` still
    # applies inside the subshell, so a section still stops at its first real error.
    set +e
    ( set -e; "section_$s" )
    rc=$?
    set -e
    if (( rc != 0 )); then
      warn "Section '$s' did not finish cleanly (exit $rc); continuing."
      # In pinned-UI mode warn() only reaches the log — surface it on screen too.
      if $UI; then
        printf '\r\e[K  %b[!] %s failed (see log)%b\n' "$YELLOW" "$s" "$NC" >&3 2>/dev/null || true
      fi
      FAILED_SECTIONS+=("$s")
    fi
    STAGE_DONE=$(( STAGE_DONE + 1 ))
    progress "$s"
  done

  if $UI; then
    progress "done"
    printf '\n\n' >&3
    exec 1>&3 2>&4                 # restore the terminal for the closing screen
  fi

  trap - EXIT INT TERM
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  clear
  echo -e "\e[1;32m"
  figlet "All done!" 2>/dev/null || echo "All done!"
  echo -e "\e[0m"

  # Show off the freshly-configured system. fastfetch is the maintained
  # successor to neofetch, which was archived upstream.
  if command -v fastfetch >/dev/null 2>&1; then
    fastfetch 2>/dev/null || true
  fi

  if (( ${#FAILED_SECTIONS[@]} )); then
    warn "These sections reported errors (see $LOG_FILE): ${FAILED_SECTIONS[*]}"
  fi
  if [[ -d "$REAL_HOME/payloads" && -d "$REAL_HOME/wordlists" ]]; then
    echo -e "\e[1;34m[+] Payloads and Wordlists in $REAL_HOME\e[0m"
  fi
  echo
  echo "If you installed the Dev/Pentest stacks, log out and back in so the new"
  echo "group memberships (docker, kvm, libvirt, wireshark) and PATH take effect."
  echo "Full log: $LOG_FILE"
  echo
  echo "Changed your mind? apt 3.x can roll the package changes back:"
  echo "  sudo apt history-list        # find the transaction id"
  echo "  sudo apt history-undo <id>"
  echo
  echo "It's time to logout/login ☺"
  echo

  # Never auto-logout — only offer it when actually interactive. (An unattended
  # --full run would otherwise sign you straight out.)
  if [[ -t 0 ]] && ! $FULL_INSTALL && ! $ASSUME_YES; then
    local logout_now
    read -r -p "Log out now to apply everything? (y/n): " logout_now
    if [[ "${logout_now,,}" == "y" ]]; then
      gnome-session-quit --logout --no-prompt
    fi
  fi
}

main "$@"
