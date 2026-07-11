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
# Sections: essentials dev security autoupdates brave gnome theme hebrew zsh ssh
#
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly P10K_URL='https://raw.githubusercontent.com/NVainer/OS_Ready/refs/heads/main/Power_Ubuntu/my_p10k.zsh'
readonly LOG_FILE="${HOME}/power_ubuntu.log"
readonly REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
readonly REAL_HOME
readonly VERSION='1.0.0'

# Sections to run, in order. Single source of truth shared by the main loop,
# the usage text, and --list-sections.
SECTIONS=(essentials dev security autoupdates brave gnome theme hebrew zsh ssh)

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

  # Prime sudo, then refresh it in the background so long sections don't re-prompt.
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
# Helpers used by multiple sections
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

  log "Installing essentials..."
  apt_install \
    git curl ca-certificates wget unzip \
    flatpak figlet \
    ubuntu-restricted-extras \
    gnome-tweaks gnome-shell-extensions \
    yaru-theme-gtk yaru-theme-icon \
    ffmpeg

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
  ask_yes "Install Dev stack (Docker, KVM/QEMU + virt-manager)?" || return 0
  dev_step "Docker"            _dev_docker
  dev_step "KVM/virt-manager"  _dev_virt
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

section_brave() {
  ask_yes "Replace Firefox with Brave?" || return 0

  log "Removing Firefox..."
  sudo snap remove firefox 2>/dev/null      || true
  sudo apt-get purge -y firefox 2>/dev/null || true

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
  ask_yes 'Apply GNOME tweaks (dark mode, dock at bottom, sane Nautilus sort)?' || return 0
  log "Tweaking GNOME..."

  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'                || true
  gsettings set org.gnome.shell.extensions.ding show-home false                       || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'        || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false              || true
  gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false           || true
  gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 60         || true

  # Drop yelp from favorites
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

  preflight

  # Only ask the top-level "Full install" question if the user didn't already
  # decide via flags.
  if ! $FULL_INSTALL && ! $ASSUME_YES && [[ -z "$ONLY_SECTIONS" ]]; then
    local full_choice
    read -r -p "Full install (recommended)? (y/n): " full_choice
    [[ "${full_choice,,}" == "y" ]] && FULL_INSTALL=true
  fi

  setup_terminal
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

  # All sections succeeded — disarm error restore.
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
  echo
  echo "If you installed the Dev stack, log out and back in so the new group"
  echo "memberships (docker, kvm, libvirt) take effect."
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
