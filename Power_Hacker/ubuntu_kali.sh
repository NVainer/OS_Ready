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
# Sections: essentials dev security firefox brave gnome theme hebrew extensions
#           zsh pentest metasploit burp wordlists payloads ssh
#
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly P10K_URL='https://raw.githubusercontent.com/NVainer/OS_Ready/refs/heads/main/Power_Ubuntu/my_p10k.zsh'
readonly LOG_FILE="${HOME}/ubuntu_kali.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
readonly REAL_HOME

# Burp Suite — bump this when a new release is out.
readonly BURP_VERSION='2025.8.7'
readonly VERSION='1.0.0'

# Sections to run, in order. Single source of truth shared by the main loop,
# the usage text, and --list-sections.
SECTIONS=(
  essentials dev security firefox brave
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
TERM_CUSTOMIZED=false
PROFILE_PATH=""
SUDO_KEEPALIVE_PID=""
declare -A ORIG_TERM=()

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
  $UI && printf '\n' >&3 2>/dev/null || true
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if (( rc != 0 )); then
    restore_terminal_on_error "$rc"
  fi
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
    printf '\e[8;28;105t'
  } > /dev/tty 2>/dev/null || true

  # Persistent theming for GNOME Terminal via gsettings (a no-op elsewhere).
  command -v gsettings >/dev/null 2>&1 || return 0
  local profile_id
  profile_id=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'") || return 0
  [[ -z "$profile_id" ]] && return 0

  PROFILE_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/"

  local key
  for key in background-color foreground-color font use-system-font use-theme-colors palette; do
    ORIG_TERM[$key]=$(gsettings get "$PROFILE_PATH" "$key" 2>/dev/null || echo '')
  done

  # Apply the clean end-state look up front so the whole run looks nice:
  # MesloLGS NF, near-black background, and the "Linux" 16-colour palette.
  gsettings set "$PROFILE_PATH" use-theme-colors false     || true
  gsettings set "$PROFILE_PATH" use-system-font  false     || true
  gsettings set "$PROFILE_PATH" font 'MesloLGS NF 12'      || true
  gsettings set "$PROFILE_PATH" background-color '#0C0C0C' || true
  gsettings set "$PROFILE_PATH" foreground-color '#D3D3D3' || true
  gsettings set "$PROFILE_PATH" palette \
    "['#000000', '#AA0000', '#00AA00', '#AA5500', '#0000AA', '#AA00AA', '#00AAAA', '#AAAAAA', '#555555', '#FF5555', '#55FF55', '#FFFF55', '#5555FF', '#FF55FF', '#55FFFF', '#FFFFFF']" || true
  TERM_CUSTOMIZED=true
}

restore_terminal_on_error() {
  local rc=${1:-$?}
  $TERM_CUSTOMIZED || return 0
  local key
  for key in "${!ORIG_TERM[@]}"; do
    gsettings set "$PROFILE_PATH" "$key" "${ORIG_TERM[$key]}" 2>/dev/null || true
  done
  warn "Aborted (exit $rc). Terminal restored."
}

apply_endstate_terminal() {
  $TERM_CUSTOMIZED || return 0
  # Clean dark look: MesloLGS NF (installed for Powerlevel10k), a near-black
  # background, and the classic "Linux" 16-colour palette.
  gsettings set "$PROFILE_PATH" use-theme-colors false || true
  gsettings set "$PROFILE_PATH" use-system-font  false || true
  gsettings set "$PROFILE_PATH" font 'MesloLGS NF 12'  || true
  gsettings set "$PROFILE_PATH" background-color '#0C0C0C' || true
  gsettings set "$PROFILE_PATH" foreground-color '#D3D3D3' || true
  gsettings set "$PROFILE_PATH" palette \
    "['#000000', '#AA0000', '#00AA00', '#AA5500', '#0000AA', '#AA00AA', '#00AAAA', '#AAAAAA', '#555555', '#FF5555', '#55FF55', '#FFFF55', '#5555FF', '#FF55FF', '#55FFFF', '#FFFFFF']" || true
  printf '\e[8;28;125t'
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
apt_update()  { sudo apt-get update -qq; }
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }

# Install only the packages that actually exist in the configured repos, so a
# single name that's missing on a given Ubuntu release doesn't fail the batch.
install_available() {
  local pkgs=() p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    else
      warn "Package not in repos, skipping: $p"
    fi
  done
  (( ${#pkgs[@]} )) && apt_install "${pkgs[@]}"
}

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
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
    gnome-tweaks gnome-shell-extensions \
    yaru-theme-gtk yaru-theme-icon

  log "Installing CLI quality-of-life tools..."
  install_available \
    tmux ripgrep fd-find bat jq btop tree ncdu \
    pipx python3-venv

  # Ubuntu ships a couple of these under alternate binary names — add the
  # familiar names to ~/.local/bin so `bat` and `fd` just work.
  mkdir -p "$REAL_HOME/.local/bin"
  [[ -x /usr/bin/batcat ]] && ln -sf /usr/bin/batcat "$REAL_HOME/.local/bin/bat"
  [[ -x /usr/bin/fdfind ]] && ln -sf /usr/bin/fdfind "$REAL_HOME/.local/bin/fd"

  if ! flatpak remote-list --columns=name 2>/dev/null | grep -qx 'flathub'; then
    log "Adding Flathub remote..."
    sudo flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  fi
}

# Run an independent install step so one failure (e.g. Docker's repo) doesn't
# skip the rest of the section. `set -e` still applies inside the sub-shell.
dev_step() {
  local label=$1; shift
  set +e; ( set -e; "$@" ); local rc=$?; set -e
  if (( rc != 0 )); then warn "Dev: ${label} step failed (exit $rc); continuing."; fi
}

section_dev() {
  ask_yes "Install Dev stack (Docker, KVM/QEMU + virt-manager, Go, VS Code, Sublime Text)?" || return 0
  dev_step "Docker"            _dev_docker
  dev_step "KVM/virt-manager"  _dev_virt
  dev_step "VS Code"           _dev_vscode
  dev_step "Sublime Text"      _dev_sublime
  pin_to_favorites org.gnome.Terminal.desktop
}

_dev_docker() {
  log "Installing Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  local codename
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  # Docker's repo is codename-pinned; if it hasn't published for a brand-new
  # release yet, fall back to the newest LTS it does support so Docker still
  # installs (its packages are codename-agnostic in practice).
  if ! curl -fsIL "https://download.docker.com/linux/ubuntu/dists/${codename}/Release" >/dev/null 2>&1; then
    warn "Docker has no repo for '${codename}' yet; using '${DOCKER_FALLBACK:-noble}'."
    codename=${DOCKER_FALLBACK:-noble}
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt_update
  apt_install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$REAL_USER"
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
  wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
    | sudo tee /etc/apt/keyrings/sublimehq-pub.asc > /dev/null
  echo -e 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc' \
    | sudo tee /etc/apt/sources.list.d/sublime-text.sources > /dev/null
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
  log "Installing Brave (official APT repo)..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSLo /etc/apt/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    | sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null
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
  ask_yes 'Apply purple Yaru theme?' || return 0
  if ! gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-purple-dark' 2>/dev/null; then
    warn "Couldn't set Yaru-purple-dark — is yaru-theme-gtk installed?"
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
  ask_yes 'Install ZSH + Oh-My-Zsh + Powerlevel10k?' || return 0

  log "Installing zsh..."
  apt_install zsh zsh-common
  sudo chsh -s "$(command -v zsh)" "$REAL_USER"

  if [[ ! -d "$REAL_HOME/.oh-my-zsh" ]]; then
    log "Installing Oh-My-Zsh..."
    RUNZSH=no CHSH=no sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    log "Oh-My-Zsh already installed; skipping."
  fi

  log "Installing MesloLGS NF font (Powerlevel10k recommended)..."
  install_meslo_nf

  log "Installing Powerlevel10k + plugins..."
  local zsh_custom="${ZSH_CUSTOM:-$REAL_HOME/.oh-my-zsh/custom}"
  clone_if_missing https://github.com/romkatv/powerlevel10k.git              "$zsh_custom/themes/powerlevel10k"             --depth=1
  clone_if_missing https://github.com/zsh-users/zsh-autosuggestions.git      "$zsh_custom/plugins/zsh-autosuggestions"
  clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting.git  "$zsh_custom/plugins/zsh-syntax-highlighting"

  if [[ -f "$REAL_HOME/.zshrc" ]]; then
    cp "$REAL_HOME/.zshrc" "$REAL_HOME/.zshrc.bak.$(date +%s)"
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|'                 "$REAL_HOME/.zshrc"
    sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$REAL_HOME/.zshrc"
  else
    warn "~/.zshrc not found (Oh-My-Zsh may not have created it); skipping theme/plugin rewrite."
  fi

  curl -fsSL "$P10K_URL" -o "$REAL_HOME/.p10k.zsh"

  if [[ -f "$REAL_HOME/.zshrc" ]] && ! grep -q 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD' "$REAL_HOME/.zshrc"; then
    cat >> "$REAL_HOME/.zshrc" <<'EOF'
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
### BEGIN ZSH COMPLETION BLOCK ###
autoload -Uz compinit
compinit
bindkey '^I' expand-or-complete
setopt AUTO_MENU LIST_PACKED
zstyle ':completion:*' completer _complete
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
### END ZSH COMPLETION BLOCK ###
EOF
  fi
}

install_meslo_nf() {
  local fontdir="$REAL_HOME/.local/share/fonts"
  mkdir -p "$fontdir"
  local base='https://github.com/romkatv/powerlevel10k-media/raw/master'
  local f out
  for f in \
    'MesloLGS%20NF%20Regular.ttf' \
    'MesloLGS%20NF%20Bold.ttf' \
    'MesloLGS%20NF%20Italic.ttf' \
    'MesloLGS%20NF%20Bold%20Italic.ttf'; do
    out="$fontdir/${f//%20/ }"
    [[ -f "$out" ]] || curl -fsSL "$base/$f" -o "$out"
  done
  fc-cache -f >/dev/null
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

  local burp_desktop
  burp_desktop="$(basename "$(ls "$REAL_HOME/.local/share/applications/"install4j*BurpSuiteCommunity.desktop 2>/dev/null | head -n1)")" || true
  [[ -n "$burp_desktop" ]] && pin_to_favorites "$burp_desktop"
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
  ask_yes "Disable SSH service?" || return 0
  log "Disabling SSH service..."
  sudo systemctl disable --now ssh 2>/dev/null || true
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

  apply_endstate_terminal

  trap - EXIT INT TERM
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  clear
  echo -e "\e[1;32m"
  figlet "All done!" 2>/dev/null || echo "All done!"
  echo -e "\e[0m"
  if (( ${#FAILED_SECTIONS[@]} )); then
    warn "These sections reported errors (see $LOG_FILE): ${FAILED_SECTIONS[*]}"
  fi
  if [[ -d "$REAL_HOME/payloads" && -d "$REAL_HOME/wordlists" ]]; then
    echo -e "\e[1;34m[+] Payloads and Wordlists in $REAL_HOME\e[0m"
  fi
  echo
  echo "If you installed the Dev/Pentest stacks, log out and back in so the new"
  echo "group memberships (docker, kvm, libvirt, wireshark) and PATH take effect."
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
