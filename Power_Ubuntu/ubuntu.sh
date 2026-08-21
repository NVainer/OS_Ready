#!/usr/bin/env bash
#
# Power_Ubuntu — opinionated post-install setup for Ubuntu (GNOME).
#
# Usage:
#   ./ubuntu.sh                    interactive, per-section prompts
#   ./ubuntu.sh --full             install everything, skip prompts
#   ./ubuntu.sh --yes              accept all y/n prompts (alias of --full)
#   ./ubuntu.sh --only=dev,zsh     run only listed sections
#   ./ubuntu.sh --skip=ssh,hebrew  run all sections except these
#   ./ubuntu.sh --dry-run          show what would run, then exit
#   ./ubuntu.sh --help
#
# Sections: essentials cli fonts dev security autoupdates pro brave claude gnome
#           theme hebrew zsh ssh
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
readonly LOG_FILE="${HOME}/power_ubuntu.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
readonly REAL_HOME
# Directory this script lives in — used to prefer local repo files over the network.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION='2.0.0'

# Sections to run, in order. Single source of truth shared by the main loop,
# the usage text, and --list-sections. `fonts` runs before `zsh` so the prompt
# has its Nerd Font glyphs the first time a shell opens.
SECTIONS=(essentials cli fonts dev security autoupdates pro brave claude gnome theme hebrew zsh ssh)

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

# Decide whether a section should run based on --only / --skip.
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
Power_Ubuntu — opinionated Ubuntu post-install setup  (v${VERSION})

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

  # Reject unknown section names so a typo (--only=zshh) doesn't silently no-op.
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

  # Prime sudo first (so the password prompt appears with context rather than
  # from the apt-lock probe below), then refresh it in the background so long
  # sections don't re-prompt.
  #
  # NOTE (Ubuntu 25.10+): the default sudo is sudo-rs, not GNU sudo. `-v`, `-n`
  # and inline `VAR=value cmd` all work, but `-E` is SILENTLY IGNORED
  # ("preserving the entire environment is not supported") and bare
  # `--preserve-env` is gone — only `--preserve-env=LIST` survives. Never reach
  # for `sudo -E` here; pass the variables explicitly instead.
  sudo -v
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!

  # Wait for apt lock — bail after 60s rather than running forever.
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
  # The font is deliberately left alone (system font stays); prompt glyphs come
  # from fontconfig fallback once the `fonts` section installs MesloLGS NF.
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
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣠⣤⡤⠤⣀⢀⣠⠤⠒⠤⠤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⡮⡁⠁⠁⣠⣀⠐⢹⠛⠁⠀⠀⠀⠘⢳⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⣿⣿⣿⣦⡀⠀⠈⢻⡆⠸⡄⠀⣠⣠⢀⣰⣾⣿⣿⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⣿⣿⣿⢻⣿⣷⡦⠁⢀⣉⠐⠖⢀⣀⠈⠙⢿⣿⣿⢿⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⠏⣿⢹⠇⡾⢹⡟⣰⣾⣿⣿⣿⣦⣿⣿⣿⣶⡀⠹⡇⠚⣿⣿⣇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⡟⢀⡏⢸⢀⠃⠸⣱⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⡐⠀⠈⠁⠈⠆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡟⡂⢸⠃⠀⠐⠀⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⣠⠀⠀⠀⠀⠈⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⡇⠃⣾⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⣻⠀⠀⠀⠀⠀⢡⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡟⠋⠀⡿⢀⠀⠀⢀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⣧⢸⣆⠀⠀⠀⠀⠈⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡅⠀⢀⡇⢸⠀⠀⣠⠅⡀⠉⠉⠉⠉⠁⣹⡟⠈⠉⠤⠰⠒⠈⣿⠀⠀⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠂⡆⢸⠄⠀⣷⣶⣿⢼⣴⣧⡀⢠⣿⣿⣤⣾⣶⣿⡿⣿⢻⠀⠀⠀⠀⠀⠘⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⡄⠀⡇⠸⠀⠀⢻⣿⣿⣿⣾⣿⣇⢸⣿⣿⣿⣿⣿⣿⣷⣿⣘⠰⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠇⡅⢀⡇⠃⡄⠀⢷⢿⣿⣿⠟⣱⣿⣿⣿⣿⣿⣭⠙⢿⢱⣿⡏⠀⠀⠀⠀⠀⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⡇⠀⠀⢁⡇⠀⢸⠐⠁⠠⣾⠦⠉⠉⢋⡿⠉⠿⣆⠈⠟⣿⠇⡀⠀⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⡋⠀⠀⠸⡇⠀⠸⣶⠀⠁⠀⠀⠀⠀⢀⠁⠤⠄⠁⠀⣸⠏⠀⠁⠀⠀⠀⠘⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠌⠀⠀⢀⠀⠹⣄⠀⢻⡇⢀⠀⠛⠛⠛⠓⠛⠛⠋⣴⢢⡟⠀⠀⠃⠐⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢡⢠⠆⠀⢹⡂⢸⡇⣾⡣⠐⣦⣤⣤⣴⣶⣿⣿⣸⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠾⠳⠀⣸⠈⣷⡄⢧⢻⣧⡻⠚⠛⠛⠛⢫⣿⡿⠃⢀⡀⣠⠀⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⠃⢀⣿⣸⣯⠻⣎⠀⢻⣿⣾⣧⣦⣾⣿⣿⠃⣰⣿⣣⣿⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⡏⣿⣷⣝⠆⠘⠦⡀⠈⠁⠀⠉⠋⠉⠀⣰⢟⣵⣿⣿⢠⣠⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⠤⣺⢻⣿⣟⣿⣿⣿⣷⣄⠀⠀⠀⠀⠀⢀⠀⡀⣐⣵⣿⣿⣿⣿⠈⣿⣿⡽⣶⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⡴⠋⠀⢰⡿⣼⣿⣿⢹⣿⣿⣿⣿⣷⣄⡀⠀⢀⠀⣠⣾⣿⣿⣿⣿⣿⣿⠐⣿⣿⣿⣞⢿⣿⣿⣶⣤⣄⡀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢠⣶⡿⠋⠁⠀⠀⠸⢱⣿⣿⡇⢸⣿⣿⣿⣿⣿⣿⡿⠒⠒⠛⠿⣿⣿⣿⣿⣿⣿⡏⠐⢸⣿⣿⣿⣧⡉⠻⣿⣿⣿⡿⠃⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠈⠁⠀⠀⠀⠐⠁⢸⣿⣿⡇⠘⣿⣿⣿⣿⠟⠋⠀⠀⠀⠀⠀⠀⠙⢿⣿⣿⣿⡇⠀⠐⠛⠛⠻⢿⣷⡄⠘⠻⠋⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⠛⠋⠁⠀⣿⣿⠟⢁⣀⡀⠀⠀⠀⠀⠀⢀⣤⣀⡙⢿⣿⠃⠀⠀⠀⠁⠁⠁⠘⠝⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠁⠁⠀⠀⠀⠈⢠⣴⣿⣟⣰⡀⠀⠀⠀⢠⣾⣱⣿⣿⣶⣤⡆⠀⠀⢀⡀⡀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⣿⣿⡟⣿⣿⠂⠀⠀⠀⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀⠁⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠛⠛⠷⠿⠿⠃⠀⠀⠀⢿⠿⠿⠿⠟⠛⠉⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⢸⡆⠀⠀⠀⠀⢸⡆⠀⠀⢀⣴⡂⠀⠀⠀⠀⠀⠀⣶⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⢸⣧⠶⢶⣄⠀⢸⡇⠀⢠⡾⢹⡀⠀⢠⡴⠶⠶⠀⣿⠀⣴⠖⠀⠀⠀⠀⠀⠀⣶⡴⠆⢰⡆⠀⢰⡆⠀⣴⠶⠶⠀⢠⡶⠶⠆⠀⠉⢀⡇⠀⠀⢰⠶⠶⣆⠀⢰⣦⠶⢶⡄⠀⠀⠀
⠀⠀⠀⢸⡇⠀⠀⣿⠀⢸⡇⣴⣿⣤⣼⣧⠀⣿⠁⠀⠀⠀⣿⣾⡁⠀⠀⠀⠀⠀⠀⠀⣿⠀⠀⢸⡇⠀⢸⡇⠀⠛⠶⣤⡀⠘⠷⣦⡄⠀⠀⢀⡇⠀⠀⣴⠶⠖⣿⠀⢸⡇⠀⢸⡇⠀⠀⠀
⠀⠀⠀⠸⠷⠦⠾⠋⠀⠸⠇⠀⠀⠀⠸⠃⠀⠙⠷⠶⠶⠀⠿⠈⠻⠦⠀⠶⠶⠶⠶⠀⠿⠀⠀⠘⠷⠶⠾⠇⠀⠶⠶⠾⠁⠶⠦⠾⠃⠀⠀⠘⠇⠀⠀⠻⠦⠾⠿⠀⠸⠇⠀⠸⠇⠀⠀⠀
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
# Helpers used by multiple sections
# -----------------------------------------------------------------------------
# Register a third-party APT repo in deb822 (.sources) format — the native
# format on Ubuntu 26.04 (see /etc/apt/sources.list.d/ubuntu.sources) and what
# upstreams now publish. Replaces the legacy one-line `.list` + `signed-by=`.
#
#   add_apt_source <name> <key-url> <uris> <suites> <components> [architectures]
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

  sudo tee "/etc/apt/sources.list.d/${name}.sources" >/dev/null <<EOF
Types: deb
URIs: ${uris}
Suites: ${suites}
Components: ${components}
Architectures: ${arches}
Signed-By: ${keyring}
EOF

  # Clear out anything an older version of this script left behind, so apt
  # doesn't warn about the same repo being configured twice.
  sudo rm -f "/etc/apt/sources.list.d/${name}.list" \
             "/etc/apt/sources.list.d/${name}-release.list" \
             "/etc/apt/keyrings/${name}.asc" \
             "/etc/apt/keyrings/${name}-archive-keyring.gpg" \
             "/usr/share/keyrings/${name}-archive-keyring.$([[ $ext == gpg ]] && echo asc || echo gpg)"
}

pin_to_favorites() {
  local desktop=$1
  command -v gsettings >/dev/null 2>&1 || return 0
  [[ -f "/usr/share/applications/$desktop" ]] || return 0
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
  apt_install debconf-utils
  sudo debconf-set-selections <<'EOF'
msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true
ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true
EOF

  # Bring the base system fully up to date before layering anything on top of
  # it. full-upgrade, not upgrade: on a freshly released Ubuntu the pending set
  # routinely includes packages that can only advance if something is removed,
  # and plain `upgrade` holds those back forever. Spelled `apt-get` because
  # `apt` prints "does not have a stable CLI interface" when run from a script.
  log "Applying pending system updates (full-upgrade)..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q

  log "Installing essentials..."
  apt_install \
    git curl ca-certificates wget unzip \
    flatpak figlet \
    ubuntu-restricted-extras \
    gnome-tweaks gnome-shell-extension-manager \
    yaru-theme-gtk yaru-theme-icon \
    ffmpeg

  # Toolchain and kernel headers, so anything that builds a module through DKMS
  # (VirtualBox guest additions, out-of-tree Wi-Fi and GPU drivers) has what it
  # needs. linux-headers-generic rides along because the full-upgrade above may
  # have staged a newer kernel: until the reboot `uname -r` still names the old
  # one, and the metapackage is what keeps headers tracking the kernel you will
  # actually boot into.
  log "Installing the build toolchain and kernel headers..."
  install_available build-essential dkms "linux-headers-$(uname -r)" linux-headers-generic

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
  if (( rc != 0 )); then
    warn "Dev: ${label} step failed (exit $rc); continuing."
    # In pinned-UI mode warn() only reaches the log — surface it on screen too.
    if $UI; then
      printf '\r\e[K  %b[!] dev: %s failed (see log)%b\n' "$YELLOW" "$label" "$NC" >&3 2>/dev/null || true
    fi
    DEV_FAILED=1   # dynamic scope: sets section_dev's local, read back below
  fi
  return 0
}

section_dev() {
  ask_yes "Install Dev stack (Docker, Podman/Distrobox, KVM/QEMU + virt-manager)?" || return 0
  local DEV_FAILED=0
  dev_step "Docker"            _dev_docker
  dev_step "Podman/Distrobox"  _dev_containers
  dev_step "KVM/virt-manager"  _dev_virt
  # Report a failed step upward so 'dev' lands in the closing summary rather
  # than being visible only to whoever reads the log.
  (( DEV_FAILED == 0 ))
}

_dev_docker() {
  log "Installing Docker..."

  local codename
  # /etc/os-release sets VERSION, a name this script has already frozen with
  # `readonly` — and readonly attributes are INHERITED by subshells, so sourcing
  # it inside $( ) died with "VERSION: readonly variable" and took the whole
  # Docker step with it. A separate bash process starts with a clean slate.
  # shellcheck disable=SC2016
  codename=$(bash -c '. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"')
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
# Ptyxis is container-aware and will offer a tab per Distrobox/Podman container.
_dev_containers() {
  log "Installing Podman + Distrobox..."
  install_available podman distrobox
}

_dev_virt() {
  log "Installing KVM/QEMU/virt-manager..."
  # Filtered install so a package that's dropped on a newer release (e.g.
  # bridge-utils) can't take virt-manager down with it.
  install_available \
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

section_security() {
  ask_yes "Install security tools (UFW, fail2ban, AppArmor utils, KeePassXC)?" || return 0
  log "Installing security tools..."
  install_available gufw fail2ban apparmor-utils keepassxc

  sudo systemctl enable --now fail2ban || true
  sudo ufw --force enable || true

  if systemctl list-unit-files | grep -q '^apache2.service'; then
    sudo systemctl disable apache2 || true
  fi
}

section_autoupdates() {
  ask_yes "Enable automatic security updates (unattended-upgrades)?" || return 0
  log "Enabling unattended-upgrades..."
  apt_install unattended-upgrades
  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  sudo systemctl enable --now unattended-upgrades 2>/dev/null || true
}

# Ubuntu Pro is free for personal use on up to 5 machines and is the single
# biggest security win available on a desktop: ESM extends security coverage
# from `main` to the whole `universe` repo for 10 years, and Livepatch applies
# kernel CVE fixes without a reboot. Nothing here is installed by default.
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

section_brave() {
  ask_yes "Replace Firefox with Brave?" || return 0

  # Install Brave first, remove Firefox after — a failed install (repo outage,
  # network hiccup) must never leave the system without any browser.
  # The keyring path below matches the .sources file Brave itself publishes.
  log "Installing Brave (official APT repo)..."
  add_apt_source brave-browser \
    'https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg' \
    'https://brave-browser-apt-release.s3.brave.com' \
    'stable' \
    'main'
  apt_update
  apt_install brave-browser

  log "Removing Firefox..."
  sudo snap remove firefox 2>/dev/null      || true
  sudo apt-get purge -y firefox 2>/dev/null || true

  pin_to_favorites brave-browser.desktop
}

# Claude Desktop, from Anthropic's own APT repo. Anthropic documents the legacy
# one-line `.list` form; this registers the identical repo in deb822, the way
# every other third-party source here is registered — and add_apt_source's
# cleanup removes a claude-desktop.list left behind by a manual install.
section_claude() {
  ask_yes 'Install Claude Desktop (official Anthropic APT repo)?' || return 0

  log "Installing Claude Desktop (official APT repo)..."
  add_apt_source claude-desktop \
    'https://downloads.claude.ai/claude-desktop/key.asc' \
    'https://downloads.claude.ai/claude-desktop/apt/stable' \
    'stable' \
    'main' \
    'amd64 arm64'
  apt_update
  apt_install claude-desktop

  pin_to_favorites com.anthropic.Claude.desktop
}

section_gnome() {
  ask_yes 'Apply GNOME tweaks (dark mode, dock at bottom, sane Nautilus sort)?' || return 0
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping GNOME tweaks."
    return 0
  fi
  log "Tweaking GNOME..."

  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'                || true
  gsettings set org.gnome.shell.extensions.ding show-home false                       || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'        || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false              || true
  gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false           || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 60         || true

  # Drop yelp from favorites
  local favs
  favs=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo '')
  if [[ -n "$favs" ]]; then
    favs=$(echo "$favs" | sed "s/, 'yelp.desktop'//; s/'yelp.desktop', //; s/'yelp.desktop'//")
    gsettings set org.gnome.shell favorite-apps "$favs" || true
  fi

  gsettings set org.gnome.nautilus.preferences default-sort-order 'mtime'         || true
  gsettings set org.gnome.nautilus.preferences default-sort-in-reverse-order true || true
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
  log "Adding the Hebrew (IL) layout (Alt+Shift switches)..."
  gsettings set org.gnome.desktop.input-sources xkb-options \
    "['grp:alt_shift_toggle', 'lv3:ralt_switch']" || true
  gsettings set org.gnome.desktop.input-sources sources \
    "[('xkb', 'us'), ('xkb', 'il')]" || true
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
  # Don't pipe fc-list into `grep -q`: under `pipefail` grep exits at the first
  # match and SIGPIPEs fc-list, so the pipeline returns 141 and this guard never
  # fires (the same trap the keyring probe in add_apt_source works around).
  local installed_fonts
  installed_fonts=$(fc-list 2>/dev/null || true)
  if [[ "$installed_fonts" != *'MesloLGS NF'* ]]; then
    log "Installing MesloLGS NF (needed for the prompt glyphs)..."
    install_meslo_nf
  fi

  # Starship's config, preferring the copy next to this script (repo clone).
  # A missing config isn't fatal — Starship just uses its own defaults.
  log "Installing Starship config..."
  mkdir -p "$REAL_HOME/.config"
  if [[ -f "$SCRIPT_DIR/starship.toml" ]]; then
    cp "$SCRIPT_DIR/starship.toml" "$REAL_HOME/.config/starship.toml"
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
  sed -i '/^### BEGIN POWER_UBUNTU ###$/,/^### END POWER_UBUNTU ###$/d'             "$zshrc"
  sed -i '/^### BEGIN ZSH COMPLETION BLOCK ###$/,/^### END ZSH COMPLETION BLOCK ###$/d' "$zshrc"
  sed -i '/POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD/d; /\.p10k\.zsh/d'            "$zshrc"

  # Quoted heredoc: everything below is written literally and evaluated by zsh
  # at shell startup, not expanded by bash here.
  cat >> "$zshrc" <<'EOF'
### BEGIN POWER_UBUNTU ###
# zsh doesn't read ~/.profile, so add ~/.local/bin (pipx, our bat/fd shims) here.
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
# fzf before atuin, and the order matters: both bind Ctrl-R and the one loaded
# last wins. fzf's history widget only greps ~/.zsh_history, while atuin searches
# its own database (dedup, timestamps, per-directory), so atuin takes Ctrl-R and
# fzf keeps Ctrl-T (files) and Alt-C (cd), which nothing else contests.
[[ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -r /usr/share/doc/fzf/examples/completion.zsh   ]] && source /usr/share/doc/fzf/examples/completion.zsh
# --disable-up-arrow leaves the arrow keys on plain zsh history.
command -v atuin    >/dev/null && eval "$(atuin init zsh --disable-up-arrow)"

if command -v eza >/dev/null; then
  alias ls='eza --group-directories-first'
  alias ll='eza -lg  --group-directories-first --git'
  alias la='eza -lag --group-directories-first --git'
  alias lt='eza -T --level=2 --group-directories-first'
fi

# Must stay last: syntax highlighting wraps every widget defined above it.
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
  && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
### END POWER_UBUNTU ###
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
    # and never let a failure abort the rest of the zsh section.
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

section_ssh() {
  # openssh-server is not part of a fresh Ubuntu desktop install, so the old
  # unconditional "disable ssh" step was a no-op on the machines this script
  # actually targets. Only act when there really is an SSH server here.
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    log "No SSH server installed — nothing to disable."
    return 0
  fi

  if ask_yes "An SSH server is installed. Disable it?"; then
    log "Disabling SSH service..."
    sudo systemctl disable --now ssh 2>/dev/null || true
    return 0
  fi

  ask_yes "Harden sshd instead (no root login, keys only)?" || return 0
  log "Hardening sshd..."
  sudo install -m 0755 -d /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/99-power-ubuntu.conf >/dev/null <<'EOF'
# Written by Power_Ubuntu.
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
  echo "===== Power_Ubuntu v${VERSION} — $(date '+%Y-%m-%d %H:%M:%S') — args: $* =====" >> "$LOG_FILE"
  exec 3>&1 4>&2
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

  trap cleanup EXIT INT TERM

  # Theme the terminal first thing, before the (possibly slow) preflight.
  setup_terminal

  preflight

  # Only ask the top-level "Full install" question if the user didn't already
  # decide via flags.
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
    # Docker's codename-pinned APT repo not yet published for a brand-new Ubuntu
    # release — doesn't abort the whole run. `set -e` still applies inside the
    # subshell, so a section still stops at its first real error.
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

  # All sections succeeded — disarm error restore.
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
  echo
  echo "If you installed the Dev stack, log out and back in so the new group"
  echo "memberships (docker, kvm, libvirt) take effect."
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
