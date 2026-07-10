#!/usr/bin/env bash
#
# ubuntu_to_kali — turn a fresh Ubuntu GNOME install into a pentesting workstation.
# Source for the compiled `ubuntu_kali` / `Fast` binary.
#
# Usage:
#   ./ubuntu_kali                  interactive, per-section prompts
#   ./ubuntu_kali --full           install everything, skip prompts
#   ./ubuntu_kali --yes            accept all y/n prompts (alias of --full)
#   ./ubuntu_kali --only=A,B,C     run only listed sections
#   ./ubuntu_kali --skip=A,B,C     skip listed sections
#   ./ubuntu_kali --help
#
# Sections: essentials dev security firefox brave gnome theme hebrew extensions
#           zsh pentest metasploit burp wordlists payloads ssh
#
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly P10K_URL='https://raw.githubusercontent.com/NVainer/OS_Ready/refs/heads/main/fast_ubuntu/my_p10k.zsh'
readonly LOG_FILE="${HOME}/ubuntu_kali.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
readonly REAL_HOME

# Burp Suite — bump this when a new release is out.
readonly BURP_VERSION='2025.8.7'

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Mutable state
FULL_INSTALL=false
ASSUME_YES=false
ONLY_SECTIONS=""
SKIP_SECTIONS=""
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
ubuntu_to_kali — turn Ubuntu into a pentesting workstation

Usage: $0 [options]

  --full              install everything, skip prompts
  --yes, -y           accept all y/n prompts
  --only=A,B,C        run only listed sections
  --skip=A,B,C        skip listed sections
  --help, -h          show this

Sections: essentials dev security firefox brave gnome theme hebrew extensions
          zsh pentest metasploit burp wordlists payloads ssh
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --full)      FULL_INSTALL=true ;;
      --yes|-y)    ASSUME_YES=true ;;
      --only=*)    ONLY_SECTIONS="${arg#--only=}" ;;
      --skip=*)    SKIP_SECTIONS="${arg#--skip=}" ;;
      --help|-h)   usage; exit 0 ;;
      *)           err "Unknown argument: $arg"; usage; exit 2 ;;
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
  if ! ping -c1 -W2 archive.ubuntu.com >/dev/null 2>&1 \
     && ! ping -c1 -W2 8.8.8.8         >/dev/null 2>&1; then
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
}

cleanup() {
  local rc=$?
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
  command -v gsettings >/dev/null 2>&1 || return 0
  local profile_id
  profile_id=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'") || return 0
  [[ -z "$profile_id" ]] && return 0

  PROFILE_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/"

  local key
  for key in background-color foreground-color font use-system-font use-theme-colors; do
    ORIG_TERM[$key]=$(gsettings get "$PROFILE_PATH" "$key" 2>/dev/null) || return 0
  done

  gsettings set "$PROFILE_PATH" use-theme-colors false
  gsettings set "$PROFILE_PATH" background-color '#000000'
  gsettings set "$PROFILE_PATH" foreground-color '#3CFF2D'
  gsettings set "$PROFILE_PATH" font 'Monospace 16'
  gsettings set "$PROFILE_PATH" use-system-font false
  TERM_CUSTOMIZED=true

  printf '\e[8;28;105t'
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
  gsettings set "$PROFILE_PATH" use-system-font true       || true
  gsettings set "$PROFILE_PATH" use-theme-colors false     || true
  gsettings set "$PROFILE_PATH" background-color '#150F1A' || true
  gsettings set "$PROFILE_PATH" foreground-color '#D3D3D3' || true
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

  if ! flatpak remote-list --columns=name 2>/dev/null | grep -qx 'flathub'; then
    log "Adding Flathub remote..."
    sudo flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  fi
}

section_dev() {
  ask_yes "Install Dev stack (Docker, KVM/QEMU, Go, VS Code, Sublime Text)?" || return 0

  log "Installing Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  local codename
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt_update
  apt_install \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$REAL_USER"

  log "Installing KVM/QEMU/virt-manager + Go..."
  apt_install \
    golang \
    qemu-system-x86 qemu-utils \
    libvirt-daemon-system libvirt-clients bridge-utils \
    virt-manager swtpm wl-clipboard
  sudo usermod -aG libvirt "$REAL_USER"
  sudo usermod -aG kvm     "$REAL_USER"

  log "Installing VS Code (snap)..."
  sudo snap install --classic code || warn "VS Code install failed."
  pin_to_favorites code_code.desktop

  log "Installing Sublime Text..."
  wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg \
    | sudo tee /etc/apt/keyrings/sublimehq-pub.asc > /dev/null
  echo -e 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc' \
    | sudo tee /etc/apt/sources.list.d/sublime-text.sources > /dev/null
  apt_update
  apt_install sublime-text
  pin_to_favorites sublime_text.desktop
  xdg-mime default sublime_text.desktop text/plain || true

  pin_to_favorites org.gnome.Terminal.desktop
}

section_security() {
  ask_yes "Install security tools (UFW, fail2ban, AppArmor utils, KeePassXC)?" || return 0
  log "Installing security tools..."
  apt_install gufw fail2ban apparmor-utils keepassxc

  sudo systemctl enable --now fail2ban
  sudo ufw --force enable

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

  # Headless launch to materialise the profile; ignore exit code.
  timeout 5s firefox --headless >/dev/null 2>&1 || true

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

  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
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
    "['grp:alt_shift_toggle', 'lv3:ralt_switch']"
  gsettings set org.gnome.desktop.input-sources sources \
    "[('xkb', 'us'), ('xkb', 'il')]"
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
  apt_install zsh zsh-common zsh-doc
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

  cp "$REAL_HOME/.zshrc" "$REAL_HOME/.zshrc.bak.$(date +%s)"
  sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|'                 "$REAL_HOME/.zshrc"
  sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$REAL_HOME/.zshrc"

  curl -fsSL "$P10K_URL" -o "$REAL_HOME/.p10k.zsh"

  if ! grep -q 'POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD' "$REAL_HOME/.zshrc"; then
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
  ask_yes "Install pentest tools (nmap, aircrack-ng, hashcat, hydra, gobuster, sqlmap, john, tcpdump, nikto, wireshark, postgresql, ...)?" || return 0
  log "Installing pentest tools..."
  apt_install \
    nmap aircrack-ng hashcat hydra gobuster sqlmap \
    john netcat-traditional tcpdump \
    openvpn whois nikto \
    postgresql postgresql-contrib libpq-dev

  sudo systemctl enable --now postgresql
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q wireshark
}

section_metasploit() {
  ask_yes "Install Metasploit framework?" || return 0

  if dpkg -s metasploit-framework >/dev/null 2>&1; then
    log "Metasploit already installed; skipping."
    return 0
  fi

  log "Installing Metasploit build deps..."
  apt_install build-essential zlib1g zlib1g-dev libpq-dev libpcap-dev libsqlite3-dev ruby ruby-dev

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
    wget -q -O "$REAL_HOME/wordlists/rockyou.txt" \
      https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt
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

  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1

  trap cleanup EXIT INT TERM

  preflight

  if ! $FULL_INSTALL && ! $ASSUME_YES && [[ -z "$ONLY_SECTIONS" ]]; then
    local full_choice
    read -r -p "Full install (recommended)? (y/n): " full_choice
    [[ "${full_choice,,}" == "y" ]] && FULL_INSTALL=true
  fi

  setup_terminal
  banner

  local sections=(
    essentials dev security firefox brave
    gnome theme hebrew extensions
    zsh
    pentest metasploit burp wordlists payloads
    ssh
  )
  local s
  for s in "${sections[@]}"; do
    section_enabled "$s" && "section_$s"
  done

  apply_endstate_terminal

  trap - EXIT INT TERM
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  clear
  echo -e "\e[1;32m"
  figlet "All done!" 2>/dev/null || echo "All done!"
  if [[ -d "$REAL_HOME/payloads" && -d "$REAL_HOME/wordlists" ]]; then
    echo -e "\e[1;34m[+] Payloads and Wordlists in $REAL_HOME"
  fi
  echo
  echo "It's time to logout/login ☺"
  echo -e "\e[0m"
  echo

  if ask_yes "Logout now?"; then
    gnome-session-quit --logout --no-prompt
  fi
}

main "$@"
