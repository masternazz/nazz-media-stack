#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ASSET_DIR="${SCRIPT_DIR}/jellyfin-stack"

CTID="${CTID:-auto}"
CT_HOSTNAME="${CT_HOSTNAME:-jellyfin}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-auto}"
TEMPLATE="${TEMPLATE:-auto}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-auto}"
DISK_GB="${DISK_GB:-32}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-8000}"
SWAP_MB="${SWAP_MB:-512}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
NAMESERVER="${NAMESERVER:-auto}"
TIMEZONE="${TZ:-auto}"
APP_DIR="${APP_DIR:-/opt/mediastack}"

PRIMARY_STORAGE_MODE="${PRIMARY_STORAGE_MODE:-nfs}"
LOCAL_MEDIA_STORAGE="${LOCAL_MEDIA_STORAGE:-auto}"
LOCAL_MEDIA_SIZE_GB="${LOCAL_MEDIA_SIZE_GB:-auto}"
HOST_NAS="${HOST_NAS:-/mnt/jellyfin-media}"
NAS_EXPORT="${NAS_EXPORT:-}"
HOST_QNAP="${HOST_QNAP:-/mnt/jellyfin-media-secondary}"
QNAP_EXPORT="${QNAP_EXPORT:-}"
ENABLE_QNAP=0
GPU_MODE="auto"
GPU_REQUIRE=0
START_STACK=1
AUTO_CONFIGURE=1
APPLY_TRASH=1
ENABLE_SUBTITLE_TIMER=1
REPLACE=0
DRY_RUN=0
GUI_MODE="auto"
SETTINGS_MODE="advanced"
VERBOSE="${VERBOSE:-0}"
ALLOW_PRIVILEGED_FALLBACK="${ALLOW_PRIVILEGED_FALLBACK:-1}"
ENV_FILE=""
ROOT_PASSWORD=""
SSH_PUBLIC_KEY_FILE=""
MEDIASTACK_ADMIN_USER="${MEDIASTACK_ADMIN_USER:-admin}"
MEDIASTACK_ADMIN_PASSWORD="${MEDIASTACK_ADMIN_PASSWORD:-}"

COMPOSE_SRC="${STACK_ASSET_DIR}/docker-compose.yml"
NVIDIA_COMPOSE_SRC="${STACK_ASSET_DIR}/docker-compose.nvidia.yml"
AMD_COMPOSE_SRC="${STACK_ASSET_DIR}/docker-compose.amd.yml"
ENV_EXAMPLE_SRC="${STACK_ASSET_DIR}/.env.example"
CONFIGURE_SRC="${STACK_ASSET_DIR}/configure-media-stack.sh"
VERIFY_SRC="${STACK_ASSET_DIR}/verify-media-stack.sh"
FIX_SUBTITLES_SRC="${STACK_ASSET_DIR}/fix-subtitles.sh"
FIX_SUBTITLES_SERVICE_SRC="${STACK_ASSET_DIR}/fix-subtitles.service"
FIX_SUBTITLES_TIMER_SRC="${STACK_ASSET_DIR}/fix-subtitles.timer"
PORTAL_SRC="${STACK_ASSET_DIR}/portal/index.html"
NVIDIA_ACTIVE=0
AMD_ACTIVE=0
ENV_HAS_PLACEHOLDER=0
RESOLVED_TEMPLATE_REF=""
UI_BACKTITLE="Jellyfin Media Stack | Proxmox VE"
LOG_FILE="${LOG_FILE:-}"
PRETTY_OUTPUT=0
CURRENT_STEP=""
SPINNER_PID=""
ERROR_HANDLED=0
PRIVILEGED_FALLBACK_USED=0

usage() {
  cat <<'EOF'
Usage:
  install-jellyfin-stack.sh [options]

Run this on a Proxmox VE host as root. It creates an unprivileged Debian LXC
with Docker and deploys the Jellyfin/media stack.

Core options:
  --ctid ID                 LXC ID to create, or auto/next (default: next free ID)
  --nextid                  Use the next free Proxmox ID
  --hostname NAME           LXC hostname (default: jellyfin)
  --storage NAME            Proxmox rootfs storage (default: auto-detect)
  --template-storage NAME   Proxmox template storage (default: auto-detect)
  --disk-gb GB              Root disk size in GB (default: 32)
  --cores COUNT             CPU cores (default: 2)
  --memory-mb MB            Memory in MB (default: 8000)
  --swap-mb MB              Swap in MB (default: 512)
  --template REF            Template ref or "auto" (default: auto Debian 13, fallback 12)
  --bridge NAME             Proxmox bridge (default: vmbr0)
  --vlan ID                 VLAN tag (default: untagged)
  --ip-config VALUE         Proxmox ip= value, e.g. dhcp or 192.168.1.50/24,gw=192.168.1.1
  --nameserver IP           Container DNS server (default: auto-detect a usable resolver)
  --timezone ZONE           Container timezone (default: Proxmox host timezone)

Storage:
  --media-storage MODE      Primary media storage: nfs or local (default: nfs)
  --local-media-storage ID  Proxmox storage for an onboard media disk (default: most free)
  --local-media-size GB     Onboard media disk size in GB (default: fit to free space, max 100)
  --nas-export EXPORT       Primary NFS export when --media-storage nfs is used
  --host-nas PATH           Host mount path passed to LXC /mnt/nas (default: /mnt/jellyfin-media)
  --enable-qnap             Mount QNAP export and pass to LXC /mnt/qnap
  --qnap-export EXPORT      Required when --enable-qnap is used
  --host-qnap PATH          Secondary host mount path (default: /mnt/jellyfin-media-secondary)

GPU:
  --gpu VENDOR              GPU passthrough: auto, nvidia, amd, or off (default: auto)
  --no-gpu                  Do not configure any GPU passthrough (CPU-only Jellyfin)
  --require-nvidia          Use NVIDIA and fail if it is not present on the Proxmox host
  --require-amd             Use AMD (VAAPI) and fail if it is not present on the Proxmox host
  --no-nvidia               Deprecated alias for --no-gpu

Stack/env:
  --env-file FILE           Use an existing .env; missing stack secrets are generated
  --no-start                Install files but do not run docker compose up
  --no-auto-configure       Start containers without first-run app/media integration
  --no-trash-profiles       Do not auto-apply TRaSH Guides quality profiles via Recyclarr
  --no-subtitle-repair-timer
                            Do not enable the safe weekly subtitle repair timer
  --root-password PASS      Set LXC root password (default: shared admin password)
  --ssh-public-key-file     File containing SSH public key(s) for root

Safety:
  --gui                     Force the terminal setup UI
  --no-gui                  Skip the setup UI for automation
  --verbose                 Show command output instead of the compact progress UI
  --no-privileged-fallback  Do not retry as privileged if host ACLs block unprivileged extraction
  --replace                 Stop and destroy an existing CTID before creating it
  --dry-run                 Print commands without changing anything
  -h, --help                Show this help

Example:
  NORDVPN_USER='token-user' NORDVPN_PASS='token-pass' \
    ./install-jellyfin-stack.sh --no-gui --nas-export 192.168.1.10:/volume1/media

Interactive setup:
  ./install-jellyfin-stack.sh

After first boot, apps live on the LXC IP:
  Media Stack Home 8088, Jellyfin 8096, Seerr 5055, Jellystat 3000,
  Profilarr (TRaSH GUI) 6868, Sonarr 8989, Radarr 7878,
  Prowlarr 9696, qBittorrent 8080, Lidarr 8686, Bazarr 6767, Wizarr 5690,
  Kavita 5000, Mylar 8090, Byparr 8191, Homarr 7575, Portainer 9443.
EOF
}

init_output() {
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/tmp/jellyfin-media-stack-$(date +%Y%m%d-%H%M%S).log"
  fi
  : >"$LOG_FILE"
  chmod 0600 "$LOG_FILE"

  if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]]; then
    PRETTY_OUTPUT=1
  fi
}

header_info() {
  [[ "$PRETTY_OUTPUT" == "1" ]] || return 0
  stop_spinner
  clear 2>/dev/null || printf '\033[2J\033[H'
  printf '\033[38;5;99m%s\033[0m\n' '     ╭────────────────────────────────────────────────────────────╮'
  printf '\033[38;5;99m%s\033[0m\n' '     │                                                            │'
  printf '\033[38;5;135m%s\033[0m\n' '     │              J E L L Y F I N   M E D I A                   │'
  printf '\033[38;5;141m%s\033[0m\n' '     │                       S T A C K                            │'
  printf '\033[38;5;99m%s\033[0m\n' '     │                                                            │'
  printf '\033[38;5;45m%s\033[0m\n' '     │        Proxmox VE  •  Guided LXC Deployment                 │'
  printf '\033[38;5;99m%s\033[0m\n' '     ╰────────────────────────────────────────────────────────────╯'
  printf '\n'
}

spinner() {
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while :; do
    printf '\r\033[2K  \033[38;5;141m%s\033[0m  %s' "${frames[$i]}" "$CURRENT_STEP" >&2
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
}

finish_step() {
  [[ -n "$CURRENT_STEP" ]] || return 0
  stop_spinner
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '\r\033[2K  \033[1;92m✔\033[0m  %s\n' "$CURRENT_STEP"
  fi
  CURRENT_STEP=""
}

fail_step() {
  local message="$1"
  stop_spinner
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '\r\033[2K  \033[1;91m✖\033[0m  %s\n' "${CURRENT_STEP:-$message}" >&2
  fi
  CURRENT_STEP=""
}

info() {
  finish_step
  CURRENT_STEP="$*"
  if [[ "$PRETTY_OUTPUT" == "1" && "$VERBOSE" != "1" && "$DRY_RUN" != "1" ]]; then
    spinner &
    SPINNER_PID=$!
  elif [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '  \033[1;94m●\033[0m  %s\n' "$*"
  else
    printf '==> %s\n' "$*"
  fi
}

warn() {
  finish_step
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '  \033[1;93m!\033[0m  %s\n' "$*" >&2
  else
    printf 'WARN: %s\n' "$*" >&2
  fi
}

die() {
  local message="$*"
  fail_step "$message"
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '  \033[1;91mERROR\033[0m  %s\n' "$message" >&2
    [[ -n "${LOG_FILE:-}" ]] && printf '  \033[38;5;245mLog: %s\033[0m\n' "$LOG_FILE" >&2
  else
    printf 'ERROR: %s\n' "$message" >&2
  fi
  exit 1
}

handle_error() {
  local code="$1" line="$2" command_text="$3"
  local failed_step="${CURRENT_STEP:-Installation}"
  [[ "$ERROR_HANDLED" == "1" ]] && exit "$code"
  ERROR_HANDLED=1
  fail_step "Installation failed"
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '  \033[1;91mERROR\033[0m  %s failed (exit %s).\n' "$failed_step" "$code" >&2
  else
    printf 'ERROR: %s failed on line %s (exit %s): %s\n' "$failed_step" "$line" "$code" "$command_text" >&2
  fi
  if [[ -s "${LOG_FILE:-}" ]]; then
    printf '\n  Last command output:\n' >&2
    tail -n 20 "$LOG_FILE" | sed 's/^/    /' >&2
    printf '  Full log: %s\n' "$LOG_FILE" >&2
  fi
  exit "$code"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    if [[ "$VERBOSE" == "1" ]]; then
      "$@"
    else
      "$@" >>"$LOG_FILE" 2>&1
    fi
  fi
}

run_shell() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash -lc %q\n' "$1"
  else
    if [[ "$VERBOSE" == "1" ]]; then
      bash -lc "$1"
    else
      bash -lc "$1" >>"$LOG_FILE" 2>&1
    fi
  fi
}

pct_bash() {
  local script="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] pct exec %q -- bash -lc %q\n' "$CTID" "$script"
  else
    if [[ "$VERBOSE" == "1" ]]; then
      pct exec "$CTID" -- bash -lc "$script"
    else
      pct exec "$CTID" -- bash -lc "$script" >>"$LOG_FILE" 2>&1
    fi
  fi
}

append_lxc_config() {
  local line="$1"
  local conf="/etc/pve/lxc/${CTID}.conf"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] append to %s if missing: %s\n' "$conf" "$line"
    return
  fi

  grep -Fxq "$line" "$conf" || printf '%s\n' "$line" >>"$conf"
}

rand_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c $((bytes * 2))
    printf '\n'
  fi
}

next_ctid() {
  local next=""

  if command -v pvesh >/dev/null 2>&1; then
    next="$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9' || true)"
  fi

  if [[ -z "$next" ]]; then
    next="$(pct list 2>/dev/null | awk 'NR > 1 && $1 > max { max = $1 } END { print max ? max + 1 : 100 }')"
  fi

  [[ "$next" =~ ^[0-9]+$ ]] || die "Could not determine the next Proxmox container ID."
  printf '%s\n' "$next"
}

resolve_ctid() {
  if [[ "$CTID" == "auto" || "$CTID" == "next" ]]; then
    CTID="$(next_ctid)"
    return
  fi

  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Invalid CTID: ${CTID}. Use a number, auto, or next."
}

attach_ui_terminal() {
  [[ "$GUI_MODE" != "off" ]] || return 0
  [[ -t 0 && -t 1 ]] && return 0

  # A common `curl | bash` bootstrap leaves the downloaded installer with pipe
  # stdin even though the SSH/local terminal is still available. Reattach it so
  # the guided installer cannot silently fall through to unattended defaults.
  if { exec 9<>/dev/tty; } 2>/dev/null; then
    exec <&9 >&9 2>&9
    PRETTY_OUTPUT=1
    return 0
  fi

  die "No interactive terminal is available. Run from a terminal, or use --no-gui and provide every required setting explicitly."
}

use_whiptail() {
  # ui_input/ui_password run inside command substitutions, where stdout is a
  # capture pipe even though stdin is still the controlling terminal.
  [[ "$GUI_MODE" != "off" && -t 0 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] &&
    command -v whiptail >/dev/null 2>&1
}

prepare_terminal_ui() {
  [[ "$GUI_MODE" != "off" ]] || return 0
  attach_ui_terminal

  if ! command -v whiptail >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "0" ]]; then
      info "Installing whiptail for the guided setup UI"
      if ! run apt-get update || ! run apt-get install -y whiptail; then
        warn "Could not install whiptail; using plain terminal prompts."
      fi
    else
      warn "whiptail is not installed; the dry run will use plain terminal prompts."
    fi
  fi

  finish_step
  header_info

  if use_whiptail; then
    local choice=""
    if ! choice="$(whiptail --backtitle "$UI_BACKTITLE" --title "SETTINGS" \
      --menu "Choose an installation mode:" 18 72 4 \
      "1" "Default Settings (recommended)" \
      "2" "Default Settings (with verbose output)" \
      "3" "Advanced Settings" \
      "4" "Exit installer" \
      3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
    case "$choice" in
      1) SETTINGS_MODE="default" ;;
      2) SETTINGS_MODE="default"; VERBOSE=1 ;;
      3) SETTINGS_MODE="advanced" ;;
      *) die "Setup cancelled." ;;
    esac
  else
    warn "whiptail is unavailable in this terminal; using plain prompts."
    local choice=""
    read -r -p "Installation mode: [1] Default, [2] Default verbose, [3] Advanced, [4] Exit [1]: " choice
    case "${choice:-1}" in
      1) SETTINGS_MODE="default" ;;
      2) SETTINGS_MODE="default"; VERBOSE=1 ;;
      3) SETTINGS_MODE="advanced" ;;
      *) die "Setup cancelled." ;;
    esac
  fi

  if [[ "$SETTINGS_MODE" == "default" ]]; then
    UI_BACKTITLE="Jellyfin Media Stack | Proxmox VE | Default Settings"
  else
    UI_BACKTITLE="Jellyfin Media Stack | Proxmox VE | Advanced Settings"
  fi
}

ui_input() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --backtitle "$UI_BACKTITLE" --title "$title" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
  else
    read -r -p "${prompt} [${default}]: " value
  fi

  printf '%s\n' "${value:-$default}"
}

ui_password() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --backtitle "$UI_BACKTITLE" --title "$title" --passwordbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
  else
    read -r -s -p "${prompt}${default:+ [already set]}: " value
    printf '\n' >&2
  fi

  printf '%s\n' "${value:-$default}"
}

ui_message() {
  local title="$1"
  local message="$2"
  if use_whiptail; then
    whiptail --backtitle "$UI_BACKTITLE" --title "$title" --msgbox "$message" 11 78 || die "Setup cancelled."
  else
    printf '\n%s: %s\n\n' "$title" "$message" >&2
  fi
}

ui_required_input() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""
  while :; do
    value="$(ui_input "$title" "$prompt" "$default")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
    ui_message "Required Setting" "${title} cannot be blank."
  done
}

ui_yesno() {
  local title="$1"
  local prompt="$2"
  local default="${3:-yes}"
  local result=0

  if use_whiptail; then
    if [[ "$default" == "yes" ]]; then
      if whiptail --backtitle "$UI_BACKTITLE" --title "$title" --yesno "$prompt" 10 78 3>&1 1>&2 2>&3; then
        return 0
      else
        result=$?
      fi
      [[ "$result" == "1" ]] && return 1
      die "Setup cancelled."
    fi
    if whiptail --backtitle "$UI_BACKTITLE" --defaultno --title "$title" --yesno "$prompt" 10 78 3>&1 1>&2 2>&3; then
      return 0
    else
      result=$?
    fi
    [[ "$result" == "1" ]] && return 1
    die "Setup cancelled."
  fi

  local suffix="[Y/n]"
  [[ "$default" == "no" ]] && suffix="[y/N]"
  local answer=""
  read -r -p "${prompt} ${suffix}: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

ui_gpu_menu() {
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --backtitle "$UI_BACKTITLE" --title "GPU Passthrough" --menu "Choose Jellyfin hardware transcoding." 15 78 4 \
      auto "Detect NVIDIA, then AMD, else CPU-only" \
      nvidia "NVIDIA (NVENC/CUDA)" \
      amd "AMD (VAAPI)" \
      off "CPU-only Jellyfin" \
      3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
    printf '%s\n' "$value"
    return
  fi

  value="$(ui_input "GPU Passthrough" "GPU mode: auto, nvidia, amd, or off" "$GPU_MODE")"
  case "$value" in
    auto|nvidia|amd|off) printf '%s\n' "$value" ;;
    *) warn "Unknown GPU mode '${value}', using auto."; printf 'auto\n' ;;
  esac
}

ui_confirm() {
  local summary="$1"
  local result=0

  if use_whiptail; then
    if whiptail --backtitle "$UI_BACKTITLE" --title "Ready To Install" --yesno "$summary" 24 88 3>&1 1>&2 2>&3; then
      return
    else
      result=$?
    fi
    [[ "$result" == "1" ]] && die "Setup cancelled."
    die "Setup cancelled."
  fi

  printf '\n%s\n\n' "$summary"
  ui_yesno "Ready To Install" "Continue with these settings?" "yes" || die "Setup cancelled."
}

ui_primary_storage_menu() {
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --backtitle "$UI_BACKTITLE" --title "Primary Media Storage" \
      --default-item "$PRIMARY_STORAGE_MODE" \
      --menu "Choose where Jellyfin media and downloads will be stored." 15 82 2 \
      nfs "NFS / NAS export (existing network storage)" \
      local "Onboard Proxmox storage (managed LXC media disk)" \
      3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
    printf '%s\n' "$value"
    return
  fi

  value="$(ui_input "Primary Media Storage" "Storage mode: nfs or local" "$PRIMARY_STORAGE_MODE")"
  case "$value" in
    nfs|local) printf '%s\n' "$value" ;;
    *) warn "Unknown storage mode '${value}', using nfs."; printf 'nfs\n' ;;
  esac
}

ui_network_menu() {
  local default_choice="untagged"
  local value=""
  [[ -n "$VLAN_TAG" ]] && default_choice="tagged"

  if use_whiptail; then
    if ! value="$(whiptail --backtitle "$UI_BACKTITLE" --title "Container Network" \
      --default-item "$default_choice" \
      --menu "Choose how this LXC connects to the network. Use the same VLAN as other working application containers on this Proxmox host." 16 88 2 \
      untagged "No VLAN tag (typical flat home network)" \
      tagged "Tagged VLAN (segmented Proxmox network)" \
      3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
    printf '%s\n' "$value"
    return
  fi

  value="$(ui_input "Container Network" "Network mode: untagged or tagged" "$default_choice")"
  case "$value" in
    untagged|tagged) printf '%s\n' "$value" ;;
    *) warn "Unknown network mode '${value}', using untagged."; printf 'untagged\n' ;;
  esac
}

collect_default_network() {
  local network_mode=""
  BRIDGE="$(ui_required_input "Container Network" "Proxmox bridge" "$BRIDGE")"
  network_mode="$(ui_network_menu)"
  if [[ "$network_mode" == "tagged" ]]; then
    VLAN_TAG="$(ui_required_input "Container Network" "VLAN ID used by working application containers" "$VLAN_TAG")"
  else
    VLAN_TAG=""
  fi
}

collect_primary_storage() {
  local advanced="${1:-0}"
  PRIMARY_STORAGE_MODE="$(ui_primary_storage_menu)"

  case "$PRIMARY_STORAGE_MODE" in
    local)
      [[ "$LOCAL_MEDIA_STORAGE" == "auto" ]] &&
        LOCAL_MEDIA_STORAGE="$(preferred_media_storage)"
      LOCAL_MEDIA_STORAGE="$(ui_required_input "Onboard Storage" "Proxmox storage pool for the managed media disk" "$LOCAL_MEDIA_STORAGE")"
      resolve_local_media_size
      LOCAL_MEDIA_SIZE_GB="$(ui_required_input "Onboard Storage" "Media disk size in GB" "$LOCAL_MEDIA_SIZE_GB")"
      NAS_EXPORT=""
      ;;
    nfs)
      NAS_EXPORT="$(ui_required_input "Media Storage" "Primary NFS export (for example 192.168.1.10:/volume1/media)" "$NAS_EXPORT")"
      if [[ "$advanced" == "1" ]]; then
        HOST_NAS="$(ui_required_input "Media Storage" "Proxmox host mount path for the primary export" "$HOST_NAS")"
      fi
      ;;
  esac
}

collect_secondary_nas() {
  local default_choice="no"
  [[ "$ENABLE_QNAP" == "1" ]] && default_choice="yes"
  if ui_yesno "Secondary NAS" "Enable a second NFS mount at /mnt/qnap?" "$default_choice"; then
    ENABLE_QNAP=1
    QNAP_EXPORT="$(ui_required_input "Secondary NAS" "Secondary NFS export (server:/path)" "$QNAP_EXPORT")"
    HOST_QNAP="$(ui_required_input "Secondary NAS" "Proxmox host mount path for the secondary export" "$HOST_QNAP")"
  else
    ENABLE_QNAP=0
  fi
}

collect_default_settings() {
  collect_default_network
  collect_primary_storage 0
  collect_secondary_nas
  GPU_MODE="auto"
  START_STACK=1
  AUTO_CONFIGURE=1
  APPLY_TRASH=1
  ENABLE_SUBTITLE_TIMER=1
}

collect_advanced_settings() {
  CTID="$(ui_input "Container ID" "Container ID. Leave as-is for the next free Proxmox ID." "$CTID")"
  resolve_ctid
  CT_HOSTNAME="$(ui_required_input "Hostname" "LXC hostname" "$CT_HOSTNAME")"
  ROOTFS_STORAGE="$(ui_required_input "Root Storage" "Proxmox rootfs storage" "$ROOTFS_STORAGE")"
  TEMPLATE_STORAGE="$(ui_required_input "Template Storage" "Proxmox template storage" "$TEMPLATE_STORAGE")"
  TEMPLATE="$(ui_required_input "Debian Template" "Template name/ref, or auto" "$TEMPLATE")"
  DISK_GB="$(ui_required_input "Disk" "Root disk size in GB" "$DISK_GB")"
  CORES="$(ui_required_input "CPU" "CPU cores" "$CORES")"
  MEMORY_MB="$(ui_required_input "Memory" "Memory in MB" "$MEMORY_MB")"
  SWAP_MB="$(ui_required_input "Swap" "Swap in MB" "$SWAP_MB")"
  BRIDGE="$(ui_required_input "Network" "Proxmox bridge" "$BRIDGE")"
  VLAN_TAG="$(ui_input "Network" "VLAN tag (leave blank for an untagged network)" "$VLAN_TAG")"
  IP_CONFIG="$(ui_required_input "Network" "Proxmox ip= value" "$IP_CONFIG")"
  NAMESERVER="$(ui_required_input "DNS" "Container nameserver (use auto to detect one from this host)" "$NAMESERVER")"
  TIMEZONE="$(ui_required_input "Timezone" "Container timezone" "$TIMEZONE")"
  APP_DIR="$(ui_required_input "App Path" "Media stack directory inside the LXC" "$APP_DIR")"
  collect_primary_storage 1
  collect_secondary_nas
  GPU_MODE="$(ui_gpu_menu)"

  if ui_yesno "Start Stack" "Pull images and start Docker Compose after install?" "$([[ "$START_STACK" == "1" ]] && printf yes || printf no)"; then
    START_STACK=1
  else
    START_STACK=0
  fi

  if [[ "$START_STACK" == "1" ]] && ui_yesno "Automatic Setup" "Configure and connect the media applications automatically?" "$([[ "$AUTO_CONFIGURE" == "1" ]] && printf yes || printf no)"; then
    AUTO_CONFIGURE=1
  else
    AUTO_CONFIGURE=0
  fi

  if [[ "$AUTO_CONFIGURE" == "1" ]] && ui_yesno "TRaSH Profiles" "Apply the default Recyclarr TRaSH profiles?" "$([[ "$APPLY_TRASH" == "1" ]] && printf yes || printf no)"; then
    APPLY_TRASH=1
  else
    APPLY_TRASH=0
  fi

  if [[ "$AUTO_CONFIGURE" == "1" ]] && ui_yesno "Subtitle Repair" "Enable the safe weekly subtitle repair timer?" "$([[ "$ENABLE_SUBTITLE_TIMER" == "1" ]] && printf yes || printf no)"; then
    ENABLE_SUBTITLE_TIMER=1
  else
    ENABLE_SUBTITLE_TIMER=0
  fi
}

collect_login_settings() {
  if pct status "$CTID" >/dev/null 2>&1; then
    local replace_prompt="CT${CTID} already exists. Destroy and replace it?"
    if [[ "$PRIMARY_STORAGE_MODE" == "local" ]]; then
      replace_prompt+=" WARNING: this also deletes its Proxmox-managed onboard media disk and all content on it."
    fi
    if ui_yesno "Existing CT${CTID}" "$replace_prompt" "no"; then
      REPLACE=1
    else
      REPLACE=0
    fi
  fi

  if ui_yesno "NordVPN" "Enter NordVPN manual-setup credentials now? Without them, the stack files are installed but containers will not start." "no"; then
    NORDVPN_USER="$(ui_required_input "NordVPN" "NordVPN manual-setup username" "${NORDVPN_USER:-}")"
    NORDVPN_PASS="$(ui_password "NordVPN" "NordVPN manual-setup password" "${NORDVPN_PASS:-}")"
    [[ -n "$NORDVPN_PASS" ]] || ui_message "VPN Password Missing" "The stack will remain stopped until NORDVPN_PASS is added to ${APP_DIR}/.env."
    export NORDVPN_USER NORDVPN_PASS
  fi

  MEDIASTACK_ADMIN_USER="$(ui_required_input "Shared Admin Login" "Admin username for Jellyfin, qBittorrent, Profilarr, and Portainer" "$MEDIASTACK_ADMIN_USER")"
  MEDIASTACK_ADMIN_PASSWORD="$(ui_password "Shared Admin Login" "Admin password (12+ characters) for the apps and LXC root login. Leave blank to generate one." "$MEDIASTACK_ADMIN_PASSWORD")"
  if [[ -n "$MEDIASTACK_ADMIN_PASSWORD" && ${#MEDIASTACK_ADMIN_PASSWORD} -lt 12 ]]; then
    ui_message "Invalid Password" "The shared admin password must be at least 12 characters. Leave it blank to generate a strong password."
    MEDIASTACK_ADMIN_PASSWORD=""
  fi
  resolve_login_credentials
}

settings_summary() {
  local mode_label="${SETTINGS_MODE^}"
  local primary_storage=""
  [[ "$VERBOSE" == "1" ]] && mode_label+=" (verbose)"
  if [[ "$PRIMARY_STORAGE_MODE" == "local" ]]; then
    primary_storage="onboard ${LOCAL_MEDIA_STORAGE}:${LOCAL_MEDIA_SIZE_GB}G -> /mnt/nas"
  else
    primary_storage="NFS ${NAS_EXPORT} -> ${HOST_NAS} -> /mnt/nas"
  fi
  cat <<EOF
Install Jellyfin Media Stack with these settings:

Mode: ${mode_label}
CTID / Hostname: ${CTID} / ${CT_HOSTNAME}
Root storage: ${ROOTFS_STORAGE}:${DISK_GB}G
Template storage: ${TEMPLATE_STORAGE}
CPU / RAM / Swap: ${CORES} cores / ${MEMORY_MB} MB / ${SWAP_MB} MB
Network: ${BRIDGE}, VLAN $([[ -n "$VLAN_TAG" ]] && printf '%s' "$VLAN_TAG" || printf 'untagged'), ip=${IP_CONFIG}
DNS / Timezone: ${NAMESERVER} / ${TIMEZONE}
Primary media: ${primary_storage}
Secondary NFS: $([[ "$ENABLE_QNAP" == "1" ]] && printf '%s -> %s -> /mnt/qnap' "$QNAP_EXPORT" "$HOST_QNAP" || printf 'disabled')
GPU: ${GPU_MODE}
Start / Auto-configure: $([[ "$START_STACK" == "1" ]] && printf yes || printf no) / $([[ "$AUTO_CONFIGURE" == "1" ]] && printf yes || printf no)
Shared admin user: ${MEDIASTACK_ADMIN_USER}
Container console: root / configured
Replace existing CT: $([[ "$REPLACE" == "1" ]] && printf yes || printf no)
EOF
}

show_install_plan() {
  local summary
  summary="$(settings_summary)"
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    header_info
    printf '  \033[1;97mInstallation plan\033[0m\n'
    printf '  \033[38;5;99m──────────────────────────────────────────────────────────────\033[0m\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  \033[38;5;250m%s\033[0m\n' "$line"
    done <<<"$summary"
    printf '  \033[38;5;99m──────────────────────────────────────────────────────────────\033[0m\n\n'
  else
    printf '%s\n\n' "$summary"
  fi
}

run_setup_ui() {
  if [[ "$GUI_MODE" == "off" ]]; then
    SETTINGS_MODE="unattended"
    return
  fi

  prepare_terminal_ui
  if [[ "$SETTINGS_MODE" == "default" ]]; then
    collect_default_settings
  else
    collect_advanced_settings
  fi
  collect_login_settings

  local summary
  summary="$(settings_summary)"
  ui_confirm "$summary"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) CTID="$2"; shift 2 ;;
      --nextid) CTID="auto"; shift ;;
      --hostname) CT_HOSTNAME="$2"; shift 2 ;;
      --storage) ROOTFS_STORAGE="$2"; shift 2 ;;
      --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
      --disk-gb) DISK_GB="$2"; shift 2 ;;
      --cores) CORES="$2"; shift 2 ;;
      --memory-mb) MEMORY_MB="$2"; shift 2 ;;
      --swap-mb) SWAP_MB="$2"; shift 2 ;;
      --template) TEMPLATE="$2"; shift 2 ;;
      --bridge) BRIDGE="$2"; shift 2 ;;
      --vlan) VLAN_TAG="$2"; shift 2 ;;
      --ip-config) IP_CONFIG="$2"; shift 2 ;;
      --nameserver) NAMESERVER="$2"; shift 2 ;;
      --timezone) TIMEZONE="$2"; shift 2 ;;
      --media-storage)
        case "$2" in
          nfs|local) PRIMARY_STORAGE_MODE="$2" ;;
          *) die "Invalid --media-storage value: $2. Use nfs or local." ;;
        esac
        shift 2
        ;;
      --local-media-storage) PRIMARY_STORAGE_MODE="local"; LOCAL_MEDIA_STORAGE="$2"; shift 2 ;;
      --local-media-size) PRIMARY_STORAGE_MODE="local"; LOCAL_MEDIA_SIZE_GB="$2"; shift 2 ;;
      --nas-export) NAS_EXPORT="$2"; shift 2 ;;
      --host-nas) HOST_NAS="$2"; shift 2 ;;
      --enable-qnap) ENABLE_QNAP=1; shift ;;
      --qnap-export) QNAP_EXPORT="$2"; shift 2 ;;
      --host-qnap) HOST_QNAP="$2"; shift 2 ;;
      --gpu)
        case "$2" in
          auto|nvidia|amd|off) GPU_MODE="$2" ;;
          *) die "Invalid --gpu value: $2. Use auto, nvidia, amd, or off." ;;
        esac
        shift 2
        ;;
      --no-gpu|--no-nvidia) GPU_MODE="off"; shift ;;
      --require-nvidia) GPU_MODE="nvidia"; GPU_REQUIRE=1; shift ;;
      --require-amd) GPU_MODE="amd"; GPU_REQUIRE=1; shift ;;
      --env-file) ENV_FILE="$2"; shift 2 ;;
      --no-start) START_STACK=0; shift ;;
      --no-auto-configure) AUTO_CONFIGURE=0; shift ;;
      --no-trash-profiles) APPLY_TRASH=0; shift ;;
      --no-subtitle-repair-timer) ENABLE_SUBTITLE_TIMER=0; shift ;;
      --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
      --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
      --gui) GUI_MODE="on"; shift ;;
      --no-gui) GUI_MODE="off"; shift ;;
      --verbose) VERBOSE=1; shift ;;
      --no-privileged-fallback) ALLOW_PRIVILEGED_FALLBACK=0; shift ;;
      --replace) REPLACE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

preflight() {
  [[ "$(id -u)" == "0" ]] || die "Run this on the Proxmox host as root."
  command -v pct >/dev/null 2>&1 || die "pct not found. This needs to run on Proxmox VE."
  command -v pveam >/dev/null 2>&1 || die "pveam not found. This needs to run on Proxmox VE."
  command -v pvesm >/dev/null 2>&1 || die "pvesm not found. This needs to run on Proxmox VE."
  [[ -f "$COMPOSE_SRC" ]] || die "Missing $COMPOSE_SRC"
  [[ -f "$NVIDIA_COMPOSE_SRC" ]] || die "Missing $NVIDIA_COMPOSE_SRC"
  [[ -f "$AMD_COMPOSE_SRC" ]] || die "Missing $AMD_COMPOSE_SRC"
  [[ -f "$ENV_EXAMPLE_SRC" ]] || die "Missing $ENV_EXAMPLE_SRC"
  [[ -f "$CONFIGURE_SRC" ]] || die "Missing $CONFIGURE_SRC"
  [[ -f "$VERIFY_SRC" ]] || die "Missing $VERIFY_SRC"
  [[ -f "$FIX_SUBTITLES_SRC" ]] || die "Missing $FIX_SUBTITLES_SRC"
  [[ -f "$FIX_SUBTITLES_SERVICE_SRC" ]] || die "Missing $FIX_SUBTITLES_SERVICE_SRC"
  [[ -f "$FIX_SUBTITLES_TIMER_SRC" ]] || die "Missing $FIX_SUBTITLES_TIMER_SRC"
  [[ -f "$PORTAL_SRC" ]] || die "Missing $PORTAL_SRC"
  [[ -z "$ENV_FILE" || -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"
  [[ -z "$SSH_PUBLIC_KEY_FILE" || -f "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key file not found: $SSH_PUBLIC_KEY_FILE"
}

first_active_storage() {
  local content="$1"
  pvesm status --content "$content" 2>/dev/null |
    awk 'NR > 1 && $3 == "active" { print $1 }'
}

preferred_media_storage() {
  local storage=""
  storage="$(
    pvesm status --content rootdir 2>/dev/null |
      awk 'NR > 1 && $3 == "active" && $6 ~ /^[0-9]+$/ && $6 > available {
        available = $6
        name = $1
      }
      END { print name }'
  )"
  printf '%s\n' "${storage:-$ROOTFS_STORAGE}"
}

storage_available_gib() {
  local storage="$1"
  pvesm status --content rootdir 2>/dev/null |
    awk -v storage="$storage" '
      NR > 1 && $1 == storage && $3 == "active" && $6 ~ /^[0-9]+$/ {
        print int($6 / 1048576)
        exit
      }'
}

recommended_local_media_size() {
  local available_gib root_commit_gib reserve_gib usable_gib
  available_gib="$(storage_available_gib "$LOCAL_MEDIA_STORAGE")"
  [[ "$available_gib" =~ ^[0-9]+$ ]] || return 1

  root_commit_gib=0
  [[ "$LOCAL_MEDIA_STORAGE" == "$ROOTFS_STORAGE" ]] && root_commit_gib="$DISK_GB"
  reserve_gib=$(( available_gib / 10 ))
  (( reserve_gib < 8 )) && reserve_gib=8
  usable_gib=$(( available_gib - root_commit_gib - reserve_gib ))
  (( usable_gib >= 8 )) || return 1
  (( usable_gib > 100 )) && usable_gib=100
  printf '%s\n' "$usable_gib"
}

resolve_local_media_size() {
  [[ "$PRIMARY_STORAGE_MODE" == "local" && "$LOCAL_MEDIA_SIZE_GB" == "auto" ]] || return 0
  local suggested_size=""
  suggested_size="$(recommended_local_media_size || true)"
  if [[ ! "$suggested_size" =~ ^[0-9]+$ || "$suggested_size" -lt 8 ]]; then
    local available_gib=""
    available_gib="$(storage_available_gib "$LOCAL_MEDIA_STORAGE")"
    die "Storage '${LOCAL_MEDIA_STORAGE}' has only ${available_gib:-unknown} GiB free. It cannot fit the ${DISK_GB} GiB root disk, an onboard media disk, and a safety reserve. Free space, choose another pool, or use NFS."
  fi
  LOCAL_MEDIA_SIZE_GB="$suggested_size"
}

validate_storage_capacity() {
  local root_available_gib media_available_gib required_gib
  root_available_gib="$(storage_available_gib "$ROOTFS_STORAGE")"
  [[ "$root_available_gib" =~ ^[0-9]+$ ]] ||
    die "Could not determine free space on root storage '${ROOTFS_STORAGE}'."

  required_gib="$DISK_GB"
  if [[ "$PRIMARY_STORAGE_MODE" == "local" && "$LOCAL_MEDIA_STORAGE" == "$ROOTFS_STORAGE" ]]; then
    required_gib=$(( DISK_GB + LOCAL_MEDIA_SIZE_GB ))
  fi
  (( required_gib <= root_available_gib )) ||
    die "Storage '${ROOTFS_STORAGE}' has ${root_available_gib} GiB free, but this install requests ${required_gib} GiB. Reduce the disk sizes or choose another storage pool."

  if [[ "$PRIMARY_STORAGE_MODE" == "local" && "$LOCAL_MEDIA_STORAGE" != "$ROOTFS_STORAGE" ]]; then
    media_available_gib="$(storage_available_gib "$LOCAL_MEDIA_STORAGE")"
    [[ "$media_available_gib" =~ ^[0-9]+$ ]] ||
      die "Could not determine free space on onboard media storage '${LOCAL_MEDIA_STORAGE}'."
    (( LOCAL_MEDIA_SIZE_GB <= media_available_gib )) ||
      die "Onboard media storage '${LOCAL_MEDIA_STORAGE}' has ${media_available_gib} GiB free, but the media disk requests ${LOCAL_MEDIA_SIZE_GB} GiB."
  fi
}

is_usable_nameserver() {
  local candidate="$1"
  local octet
  case "$candidate" in
    ""|127.*|0.0.0.0|::1|fe80:*|*%*) return 1 ;;
  esac

  if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local -a octets=()
    IFS='.' read -r -a octets <<<"$candidate"
    for octet in "${octets[@]}"; do
      (( 10#$octet <= 255 )) || return 1
    done
    return 0
  fi

  [[ "$candidate" == *:* && "$candidate" =~ ^[0-9A-Fa-f:]+$ ]]
}

detect_nameserver() {
  local candidate=""

  while IFS= read -r candidate; do
    if is_usable_nameserver "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null)

  if command -v resolvectl >/dev/null 2>&1; then
    while IFS= read -r candidate; do
      if is_usable_nameserver "$candidate"; then
        printf '%s\n' "$candidate"
        return
      fi
    done < <(resolvectl dns 2>/dev/null | sed -E 's/^[^:]+:[[:space:]]*//' | tr ' ' '\n')
  fi

  candidate="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print $3 }')"
  if is_usable_nameserver "$candidate"; then
    printf '%s\n' "$candidate"
    return
  fi

  printf '1.1.1.1\n'
}

resolve_nameserver() {
  if [[ -z "$NAMESERVER" || "$NAMESERVER" == "auto" ]]; then
    NAMESERVER="$(detect_nameserver)"
  fi
  is_usable_nameserver "$NAMESERVER" ||
    die "Nameserver must be a usable IPv4 or IPv6 address (got '${NAMESERVER}')."
}

resolve_platform_defaults() {
  local available=""

  if [[ "$ROOTFS_STORAGE" == "auto" ]]; then
    available="$(first_active_storage rootdir)"
    [[ -n "$available" ]] || die "No active Proxmox storage supports LXC root disks (content type: rootdir)."
    if grep -Fxq "local-lvm" <<<"$available"; then
      ROOTFS_STORAGE="local-lvm"
    elif grep -Fxq "local-zfs" <<<"$available"; then
      ROOTFS_STORAGE="local-zfs"
    else
      ROOTFS_STORAGE="$(head -n 1 <<<"$available")"
    fi
  fi

  if [[ "$TEMPLATE_STORAGE" == "auto" ]]; then
    available="$(first_active_storage vztmpl)"
    [[ -n "$available" ]] || die "No active Proxmox storage supports container templates (content type: vztmpl)."
    if grep -Fxq "local" <<<"$available"; then
      TEMPLATE_STORAGE="local"
    else
      TEMPLATE_STORAGE="$(head -n 1 <<<"$available")"
    fi
  fi

  if [[ "$TIMEZONE" == "auto" ]]; then
    TIMEZONE="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    [[ -n "$TIMEZONE" && "$TIMEZONE" != "n/a" ]] || TIMEZONE="$(cat /etc/timezone 2>/dev/null || true)"
    TIMEZONE="${TIMEZONE:-UTC}"
  fi

  resolve_nameserver

  if [[ "$LOCAL_MEDIA_STORAGE" == "auto" ]]; then
    LOCAL_MEDIA_STORAGE="$(preferred_media_storage)"
  fi
}

validate_integer() {
  local label="$1"
  local value="$2"
  local minimum="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${label} must be an integer (got '${value}')."
  (( 10#$value >= minimum )) || die "${label} must be at least ${minimum} (got '${value}')."
}

resolve_login_credentials() {
  local existing_value=""

  if [[ -n "$ENV_FILE" ]]; then
    existing_value="$(awk -F= '/^MEDIASTACK_ADMIN_USER=/{value=substr($0,index($0,"=")+1)} END{print value}' "$ENV_FILE")"
    [[ -n "$existing_value" ]] && MEDIASTACK_ADMIN_USER="$existing_value"
    existing_value="$(awk -F= '/^MEDIASTACK_ADMIN_PASSWORD=/{value=substr($0,index($0,"=")+1)} END{print value}' "$ENV_FILE")"
    [[ -n "$existing_value" ]] && MEDIASTACK_ADMIN_PASSWORD="$existing_value"
  fi

  [[ -n "$MEDIASTACK_ADMIN_PASSWORD" ]] ||
    MEDIASTACK_ADMIN_PASSWORD="$(rand_hex 18)"
  [[ ${#MEDIASTACK_ADMIN_PASSWORD} -ge 12 ]] ||
    die "The shared admin password must be at least 12 characters."

  # A usable console login is part of every install. The CLI can still provide
  # a separate root password explicitly with --root-password.
  [[ -n "$ROOT_PASSWORD" ]] || ROOT_PASSWORD="$MEDIASTACK_ADMIN_PASSWORD"
  [[ ${#ROOT_PASSWORD} -ge 8 ]] ||
    die "The LXC root password must be at least 8 characters."
}

validate_settings() {
  resolve_login_credentials
  resolve_nameserver
  resolve_local_media_size
  validate_integer "Disk size" "$DISK_GB" 8
  validate_integer "CPU cores" "$CORES" 1
  validate_integer "Memory" "$MEMORY_MB" 512
  validate_integer "Swap" "$SWAP_MB" 0

  [[ -z "$VLAN_TAG" || "$VLAN_TAG" =~ ^[0-9]+$ ]] || die "VLAN must be blank or an integer from 1 to 4094."
  if [[ -n "$VLAN_TAG" ]]; then
    (( 10#$VLAN_TAG >= 1 && 10#$VLAN_TAG <= 4094 )) || die "VLAN must be from 1 to 4094."
  fi

  case "$PRIMARY_STORAGE_MODE" in
    nfs)
      [[ -n "$NAS_EXPORT" ]] || die "A primary NFS export is required. Rerun the guided setup or pass --nas-export server:/path."
      [[ "$NAS_EXPORT" == *:* ]] || die "Invalid NFS export '${NAS_EXPORT}'. Expected server:/path."
      [[ "$HOST_NAS" == /* ]] || die "Primary host mount path must be absolute (got '${HOST_NAS}')."
      ;;
    local)
      validate_integer "Onboard media disk size" "$LOCAL_MEDIA_SIZE_GB" 8
      first_active_storage rootdir | grep -Fxq "$LOCAL_MEDIA_STORAGE" ||
        die "Onboard media storage '${LOCAL_MEDIA_STORAGE}' is not active or does not support LXC volumes."
      ;;
    *)
      die "Primary media storage mode must be nfs or local (got '${PRIMARY_STORAGE_MODE}')."
      ;;
  esac
  if [[ "$ENABLE_QNAP" == "1" ]]; then
    [[ -n "$QNAP_EXPORT" && "$QNAP_EXPORT" == *:* ]] || die "--enable-qnap requires --qnap-export server:/path."
    [[ "$HOST_QNAP" == /* ]] || die "Secondary host mount path must be absolute (got '${HOST_QNAP}')."
  fi
  [[ "$APP_DIR" == /* ]] || die "App path must be absolute (got '${APP_DIR}')."
  [[ -n "$BRIDGE" ]] || die "A Proxmox bridge is required."
  [[ -n "$IP_CONFIG" ]] || die "An IP configuration is required."
  [[ -n "$TIMEZONE" ]] || die "A timezone is required."

  first_active_storage rootdir | grep -Fxq "$ROOTFS_STORAGE" ||
    die "Storage '${ROOTFS_STORAGE}' is not active or does not support LXC root disks."
  first_active_storage vztmpl | grep -Fxq "$TEMPLATE_STORAGE" ||
    die "Template storage '${TEMPLATE_STORAGE}' is not active or does not support container templates."
  validate_storage_capacity
}

prepare_nfs_mount() {
  local name="$1"
  local export_path="$2"
  local host_path="$3"
  local required="$4"

  info "Preparing ${name} mount: ${export_path} -> ${host_path}"
  run apt-get update
  run apt-get install -y nfs-common
  run mkdir -p "$host_path"

  if mountpoint -q "$host_path"; then
    info "${host_path} is already mounted"
  else
    if ! run mount -t nfs -o rw,hard,noatime "$export_path" "$host_path"; then
      [[ "$required" == "1" ]] && die "Failed to mount required ${name} export ${export_path}"
      warn "Could not mount optional ${name}; continuing with an empty bind path."
    fi
  fi

  if [[ "$DRY_RUN" == "0" ]] && mountpoint -q "$host_path"; then
    if ! awk -v p="$host_path" '$2 == p { found = 1 } END { exit !found }' /etc/fstab; then
      printf '%s %s nfs rw,hard,noatime,_netdev,nofail 0 0\n' "$export_path" "$host_path" >>/etc/fstab
      info "Added ${host_path} to /etc/fstab"
    fi
  fi
}

resolve_template() {
  if [[ "$TEMPLATE" == *:* ]]; then
    RESOLVED_TEMPLATE_REF="$TEMPLATE"
    return
  fi

  local template_name="$TEMPLATE"
  if [[ "$template_name" == "auto" ]]; then
    info "Refreshing Proxmox template list"
    run pveam update
    template_name="$(pveam available --section system | awk '/debian-13-standard.*amd64/ { print $2; exit }')"
    if [[ -z "$template_name" ]]; then
      template_name="$(pveam available --section system | awk '/debian-12-standard.*amd64/ { print $2; exit }')"
    fi
    [[ -n "$template_name" ]] || die "No Debian 13/12 amd64 template found via pveam."
  fi

  if ! pveam list "$TEMPLATE_STORAGE" | grep -Fq "/${template_name}"; then
    info "Downloading template ${template_name} to ${TEMPLATE_STORAGE}"
    run pveam download "$TEMPLATE_STORAGE" "$template_name"
  fi

  RESOLVED_TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${template_name}"
}

create_container() {
  local template_ref="$1"
  local net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"
  [[ -n "$VLAN_TAG" ]] && net0+=",tag=${VLAN_TAG}"
  local args=(
    pct create "$CTID" "$template_ref"
    --hostname "$CT_HOSTNAME"
    --ostype debian
    --unprivileged 1
    --features "nesting=1,keyctl=1"
    --cores "$CORES"
    --memory "$MEMORY_MB"
    --swap "$SWAP_MB"
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}"
    --net0 "$net0"
    --timezone "$TIMEZONE"
    --onboot 1
    --start 0
    --description "Docker LXC for the Jellyfin media stack."
  )

  [[ -n "$NAMESERVER" ]] && args+=(--nameserver "$NAMESERVER")
  [[ -n "$ROOT_PASSWORD" ]] && args+=(--password "$ROOT_PASSWORD")
  [[ -n "$SSH_PUBLIC_KEY_FILE" ]] && args+=(--ssh-public-keys "$SSH_PUBLIC_KEY_FILE")
  if [[ "$PRIMARY_STORAGE_MODE" == "local" ]]; then
    args+=(--mp0 "${LOCAL_MEDIA_STORAGE}:${LOCAL_MEDIA_SIZE_GB},mp=/mnt/nas")
  else
    args+=(--mp0 "${HOST_NAS},mp=/mnt/nas")
  fi
  [[ "$ENABLE_QNAP" == "1" ]] && args+=(--mp1 "${HOST_QNAP},mp=/mnt/qnap")

  if pct status "$CTID" >/dev/null 2>&1; then
    if [[ "$REPLACE" == "1" ]]; then
      if [[ "$PRIMARY_STORAGE_MODE" == "local" ]]; then
        warn "CTID ${CTID} exists and --replace was set. Destroying it, including its managed onboard media disk."
      else
        warn "CTID ${CTID} exists and --replace was set. Destroying it."
      fi
      run pct stop "$CTID" --skiplock 1 || true
      run pct destroy "$CTID" --purge 1
    else
      die "CTID ${CTID} already exists. Use --ctid for a new ID or --replace to rebuild it."
    fi
  fi

  info "Creating CT${CTID} from ${template_ref}"
  local create_status=0
  if run "${args[@]}"; then
    :
  else
    create_status=$?
    if [[ "$ALLOW_PRIVILEGED_FALLBACK" == "1" ]] &&
      grep -Fq "rootfs: Cannot open: Permission denied" "$LOG_FILE" &&
      grep -Fq "lxc-usernsexec" "$LOG_FILE" &&
      ! pct status "$CTID" >/dev/null 2>&1; then
      fail_step "Unprivileged container creation failed"
      warn "This host's storage/ACL configuration blocks Proxmox unprivileged template extraction."
      warn "Retrying CT${CTID} as a privileged LXC. Fix the host ACL/noacl configuration to use unprivileged containers."
      local index
      for index in "${!args[@]}"; do
        if [[ "${args[$index]}" == "--unprivileged" ]]; then
          args[$(( index + 1 ))]=0
          break
        fi
      done
      PRIVILEGED_FALLBACK_USED=1
      info "Retrying CT${CTID} with the compatible privileged LXC mode"
      run "${args[@]}"
    else
      return "$create_status"
    fi
  fi
  if ! run pct set "$CTID" --tags "media;docker;jellyfin"; then
    warn "This Proxmox version did not accept optional container tags; continuing without them."
  fi
}

has_nvidia_gpu() {
  local device=""
  for device in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [[ -e "$device" ]] || return 1
  done
  command -v nvidia-smi >/dev/null 2>&1
}

# AMD/ATI PCI vendor id is 0x1002. A render node alone is not enough, because
# Intel iGPUs and NVIDIA also publish /dev/dri nodes.
has_amd_gpu() {
  local vendor_file=""
  [[ -e /dev/dri/renderD128 ]] || return 1
  for vendor_file in /sys/class/drm/card*/device/vendor; do
    [[ -r "$vendor_file" ]] || continue
    [[ "$(cat "$vendor_file")" == "0x1002" ]] && return 0
  done
  return 1
}

configure_lxc_devices() {
  info "Adding /dev/net/tun passthrough for Gluetun"
  append_lxc_config "lxc.cgroup2.devices.allow: c 10:200 rwm"
  append_lxc_config "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"

  if [[ "$GPU_MODE" == "off" ]]; then
    info "GPU passthrough disabled"
    return
  fi

  local vendor="$GPU_MODE"
  if [[ "$vendor" == "auto" ]]; then
    if has_nvidia_gpu; then
      vendor="nvidia"
    elif has_amd_gpu; then
      vendor="amd"
    else
      info "No NVIDIA or AMD GPU detected on the Proxmox host; deploying CPU-only Jellyfin."
      return
    fi
  fi

  case "$vendor" in
    nvidia) configure_nvidia_passthrough ;;
    amd) configure_amd_passthrough ;;
  esac
}

configure_amd_passthrough() {
  if ! has_amd_gpu; then
    [[ "$GPU_REQUIRE" == "1" ]] && die "AMD passthrough required, but no AMD render device (/dev/dri/renderD128 with vendor 0x1002) was found on the Proxmox host."
    warn "No AMD GPU detected on the Proxmox host; deploying CPU-only Jellyfin."
    return
  fi

  info "Adding AMD GPU (VAAPI) passthrough"
  AMD_ACTIVE=1
  # 226 is the DRM char-device major (card* and renderD*).
  append_lxc_config "lxc.cgroup2.devices.allow: c 226:* rwm"
  append_lxc_config "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
}

configure_nvidia_passthrough() {
  local required_devices=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools)
  local missing_devices=()
  local device=""
  for device in "${required_devices[@]}"; do
    [[ -e "$device" ]] || missing_devices+=("$device")
  done

  if (( ${#missing_devices[@]} > 0 )); then
    [[ "$GPU_REQUIRE" == "1" ]] && die "NVIDIA passthrough required, but these devices are missing: ${missing_devices[*]}"
    warn "Required NVIDIA devices are missing (${missing_devices[*]}); deploying CPU-only Jellyfin."
    return
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    [[ "$GPU_REQUIRE" == "1" ]] && die "NVIDIA passthrough required, but nvidia-smi is not installed on the Proxmox host."
    warn "nvidia-smi is not installed on the Proxmox host; deploying CPU-only Jellyfin."
    return
  fi

  info "Adding NVIDIA passthrough"
  NVIDIA_ACTIVE=1
  append_lxc_config "lxc.cgroup2.devices.allow: c 195:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 226:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 236:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 508:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 509:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 510:* rwm"
  append_lxc_config "lxc.cgroup2.devices.allow: c 511:* rwm"
  append_lxc_config "lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file"
  append_lxc_config "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file"
  append_lxc_config "lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file"
  append_lxc_config "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file"
  append_lxc_config "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file"
  append_lxc_config "lxc.mount.entry: /dev/nvidia-caps dev/nvidia-caps none bind,optional,create=dir"
  append_lxc_config "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
}

start_container() {
  info "Starting CT${CTID}"
  run pct start "$CTID"
  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  # Pin a real resolver inside the guest. Inheriting a Proxmox host's loopback
  # stub (for example 127.0.0.53) leaves the LXC unable to resolve package hosts.
  run pct set "$CTID" --nameserver "$NAMESERVER"
  run pct exec "$CTID" -- sh -c \
    'rm -f /etc/resolv.conf; printf "nameserver %s\noptions timeout:2 attempts:2 single-request-reopen\n" "$1" > /etc/resolv.conf' \
    sh "$NAMESERVER"

  local lxc_ip=""
  lxc_ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  info "Waiting for CT${CTID} network (${lxc_ip:-no DHCP address yet}, ${BRIDGE}, VLAN $([[ -n "$VLAN_TAG" ]] && printf '%s' "$VLAN_TAG" || printf 'untagged'))"

  # `getent hosts` can succeed with only an AAAA response even when the guest
  # has no IPv6 route and IPv4 DNS is not ready. Require both an IPv4 answer
  # and the same outbound TCP path that Debian's HTTP repositories need.
  local ready_count=0
  local dns_ready=0
  for _ in $(seq 1 15); do
    if pct exec "$CTID" -- timeout 6 getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
      dns_ready=1
      if pct exec "$CTID" -- timeout 6 bash -c \
         'exec 3<>/dev/tcp/deb.debian.org/80; exec 3>&-' \
         >/dev/null 2>&1; then
        ready_count=$(( ready_count + 1 ))
        if (( ready_count >= 3 )); then
          return
        fi
      else
        ready_count=0
      fi
    else
      ready_count=0
    fi
    sleep 2
  done
  if [[ "$dns_ready" == "0" ]]; then
    die "CT${CTID} received ${lxc_ip:-no DHCP address}, but IPv4 DNS through ${NAMESERVER} never became ready. Check ${BRIDGE}, the VLAN, DHCP, and DNS policy."
  fi
  die "CT${CTID} received ${lxc_ip:-a DHCP address} and resolved DNS, but cannot reach Debian over HTTP. The selected $([[ -n "$VLAN_TAG" ]] && printf 'VLAN %s' "$VLAN_TAG" || printf 'untagged network') has no working internet egress; rerun and choose the VLAN used by working application containers."
}

install_docker() {
  info "Installing Docker Engine and Compose plugin in CT${CTID}"
  # This single-quoted script is intentionally expanded inside the LXC.
  # shellcheck disable=SC2016
  pct_bash '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

wait_for_dns() {
  local attempt
  for attempt in $(seq 1 20); do
    if timeout 6 getent ahostsv4 deb.debian.org >/dev/null 2>&1 &&
       timeout 6 bash -c '"'"'exec 3<>/dev/tcp/deb.debian.org/80; exec 3>&-'"'"' \
         >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  echo "IPv4 DNS/HTTP did not reach deb.debian.org before the package-install timeout." >&2
  return 1
}

apt_retry() {
  local attempt
  for attempt in 1 2 3; do
    wait_for_dns
    if apt-get \
      -o Acquire::Retries=3 \
      -o Acquire::ForceIPv4=true \
      -o APT::Update::Error-Mode=any \
      "$@"; then
      return
    fi
    echo "apt-get failed (attempt ${attempt}/3); retrying..." >&2
    sleep $(( attempt * 5 ))
  done
  return 1
}

wait_for_dns
apt_retry update
apt_retry install -y ca-certificates curl gnupg jq python3 python3-yaml util-linux
install -m 0755 -d /etc/apt/keyrings
curl -4 --retry 5 --retry-all-errors --connect-timeout 15 -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
arch="$(dpkg --print-architecture)"
printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n" "$arch" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
wait_for_dns
apt_retry update
apt_retry install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
'
}

install_amd_userspace() {
  [[ "$AMD_ACTIVE" == "1" ]] || return 0

  info "Installing AMD VAAPI userspace in CT${CTID}"
  # Unlike NVIDIA, AMD needs no host-matched proprietary driver: the open Mesa
  # stack in the container talks to the kernel amdgpu driver through /dev/dri.
  # These packages give us vainfo for verification and a working VA driver.
  if ! pct_bash '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update
apt-get install -y --no-install-recommends mesa-va-drivers libva2 vainfo
'; then
    warn "AMD VAAPI userspace install did not complete; Jellyfin may still transcode using the drivers bundled in its image."
    return 0
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    pct exec "$CTID" -- vainfo --display drm --device /dev/dri/renderD128 >/dev/null 2>&1 ||
      warn "vainfo could not query /dev/dri/renderD128 inside the LXC; check that the host exposes an AMD render node."
  fi
}

install_nvidia_userspace() {
  [[ "$NVIDIA_ACTIVE" == "1" ]] || return 0

  local host_driver_version=""
  host_driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  [[ "$host_driver_version" =~ ^[0-9][0-9A-Za-z.+_-]*$ ]] || die "Could not determine the host NVIDIA driver version."

  info "Installing NVIDIA ${host_driver_version} userspace libraries in CT${CTID}"
  pct_bash "
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
. /etc/os-release
cat > /etc/apt/sources.list.d/nvidia-non-free.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: \${VERSION_CODENAME} \${VERSION_CODENAME}-updates
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: \${VERSION_CODENAME}-security
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
apt-get update
candidate=\$(apt-cache policy nvidia-smi | awk '/Candidate:/ { print \$2; exit }')
if [[ \"\$candidate\" != '${host_driver_version}' && \"\$candidate\" != '${host_driver_version}'-* && \"\$candidate\" != '${host_driver_version}'+* ]]; then
  printf 'ERROR: host NVIDIA driver is %s, but Debian offers nvidia-smi %s. Update the host driver or rerun with --no-nvidia.\n' '${host_driver_version}' \"\${candidate:-none}\" >&2
  exit 1
fi
packages=(
  nvidia-smi
  libnvidia-encode1
  libnvcuvid1
  libcuda1
  libnvidia-ptxjitcompiler1
  libnvidia-allocator1
)
versioned=()
for package in \"\${packages[@]}\"; do
  versioned+=(\"\${package}=\${candidate}\")
done
apt-get install -y --no-install-recommends \"\${versioned[@]}\"
nvidia-smi
"
}

create_media_dirs() {
  info "Creating media/config directories"
  pct_bash "
set -Eeuo pipefail
puid=\$(awk -F= '/^PUID=/{value=\$2} END{print value}' '${APP_DIR}/.env')
pgid=\$(awk -F= '/^PGID=/{value=\$2} END{print value}' '${APP_DIR}/.env')
[[ \"\$puid\" =~ ^[0-9]+$ && \"\$pgid\" =~ ^[0-9]+$ ]] || {
  printf 'ERROR: PUID and PGID in ${APP_DIR}/.env must be numeric.\n' >&2
  exit 1
}
mkdir -p '${APP_DIR}/config'
for dir in \
  '${APP_DIR}/config/qbittorrent' \
  '${APP_DIR}/config/prowlarr' \
  '${APP_DIR}/config/sonarr' \
  '${APP_DIR}/config/radarr' \
  '${APP_DIR}/config/lidarr' \
  '${APP_DIR}/config/bazarr' \
  '${APP_DIR}/config/kavita' \
  '${APP_DIR}/config/mylar' \
  '${APP_DIR}/config/jellyfin' \
  '${APP_DIR}/config/jellyseerr' \
  '${APP_DIR}/config/wizarr' \
  '${APP_DIR}/config/jellystat/db' \
  '${APP_DIR}/config/jellystat/backup-data' \
  '${APP_DIR}/config/recyclarr' \
  '${APP_DIR}/config/profilarr' \
  '${APP_DIR}/config/homarr' \
  /mnt/nas/media/movies \
  /mnt/nas/media/tv \
  /mnt/nas/media/anime \
  /mnt/nas/media/music \
  /mnt/nas/media/books \
  /mnt/nas/media/comics \
  /mnt/nas/torrents/movies \
  /mnt/nas/torrents/tv \
  /mnt/nas/torrents/anime \
  /mnt/nas/torrents/music \
  /mnt/nas/torrents/books \
  /mnt/nas/torrents/comics \
  /mnt/nas/torrents/incomplete \
  /mnt/nas/jellyfin-cache; do
  install -d -m 0777 \"\$dir\"
done
if [[ '${ENABLE_QNAP}' == '1' ]]; then
  install -d -m 0777 /mnt/qnap/media
fi
chown -R \"\$puid:\$pgid\" '${APP_DIR}/config'
"
}

push_stack_files() {
  info "Copying compose assets into CT${CTID}:${APP_DIR}"
  pct_bash "mkdir -p '${APP_DIR}/portal'"
  run pct push "$CTID" "$COMPOSE_SRC" "${APP_DIR}/docker-compose.yml" --perms 0644
  run pct push "$CTID" "$NVIDIA_COMPOSE_SRC" "${APP_DIR}/docker-compose.nvidia.yml" --perms 0644
  run pct push "$CTID" "$AMD_COMPOSE_SRC" "${APP_DIR}/docker-compose.amd.yml" --perms 0644
  run pct push "$CTID" "$ENV_EXAMPLE_SRC" "${APP_DIR}/.env.example" --perms 0644
  run pct push "$CTID" "$CONFIGURE_SRC" "${APP_DIR}/configure-media-stack.sh" --perms 0755
  run pct push "$CTID" "$VERIFY_SRC" "${APP_DIR}/verify-media-stack.sh" --perms 0755
  run pct push "$CTID" "$FIX_SUBTITLES_SRC" "${APP_DIR}/fix-subtitles.sh" --perms 0755
  run pct push "$CTID" "$FIX_SUBTITLES_SERVICE_SRC" "${APP_DIR}/fix-subtitles.service" --perms 0644
  run pct push "$CTID" "$FIX_SUBTITLES_TIMER_SRC" "${APP_DIR}/fix-subtitles.timer" --perms 0644
  run pct push "$CTID" "$PORTAL_SRC" "${APP_DIR}/portal/index.html" --perms 0644
}

ensure_env_entry() {
  local file="$1" key="$2" value="$3"
  if ! grep -qE "^${key}=" "$file"; then
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

write_env_file() {
  local tmp_env shared_admin_user shared_admin_password existing_value
  tmp_env="$(mktemp)"
  chmod 0600 "$tmp_env"

  shared_admin_user="${MEDIASTACK_ADMIN_USER:-admin}"
  shared_admin_password="${MEDIASTACK_ADMIN_PASSWORD:-$(rand_hex 18)}"

  if [[ -n "$ENV_FILE" ]]; then
    info "Using env file: ${ENV_FILE}"
    cp "$ENV_FILE" "$tmp_env"
    existing_value="$(awk -F= '/^MEDIASTACK_ADMIN_USER=/{value=substr($0,index($0,"=")+1)} END{print value}' "$tmp_env")"
    [[ -n "$existing_value" ]] && shared_admin_user="$existing_value"
    existing_value="$(awk -F= '/^MEDIASTACK_ADMIN_PASSWORD=/{value=substr($0,index($0,"=")+1)} END{print value}' "$tmp_env")"
    [[ -n "$existing_value" ]] && shared_admin_password="$existing_value"
  else
    info "Generating ${APP_DIR}/.env"
    cat >"$tmp_env" <<EOF
NORDVPN_USER=${NORDVPN_USER:-CHANGE_ME}
NORDVPN_PASS=${NORDVPN_PASS:-CHANGE_ME}
NORDVPN_COUNTRIES=${NORDVPN_COUNTRIES:-United States}

TZ=${TIMEZONE}
PUID=${PUID:-65534}
PGID=${PGID:-65534}

MEDIASTACK_ADMIN_USER=${shared_admin_user}
MEDIASTACK_ADMIN_PASSWORD=${shared_admin_password}

VPN_TYPE=${VPN_TYPE:-openvpn}
FIREWALL=${FIREWALL:-on}
FIREWALL_VPN_INPUT_PORTS=${FIREWALL_VPN_INPUT_PORTS:-6881}
FIREWALL_OUTBOUND_SUBNETS=${FIREWALL_OUTBOUND_SUBNETS:-192.168.0.0/16,172.16.0.0/12,10.0.0.0/8}

JELLYSTAT_DB_PASS=${JELLYSTAT_DB_PASS:-$(rand_hex 24)}
JELLYSTAT_JWT_SECRET=${JELLYSTAT_JWT_SECRET:-$(rand_hex 32)}
HOMARR_SECRET_ENCRYPTION_KEY=${HOMARR_SECRET_ENCRYPTION_KEY:-$(rand_hex 32)}
QBITTORRENT_USER=${QBITTORRENT_USER:-${shared_admin_user}}
QBITTORRENT_PASSWORD=${QBITTORRENT_PASSWORD:-${shared_admin_password}}
JELLYFIN_ADMIN_USER=${JELLYFIN_ADMIN_USER:-${shared_admin_user}}
JELLYFIN_ADMIN_PASSWORD=${JELLYFIN_ADMIN_PASSWORD:-${shared_admin_password}}
PROFILARR_ADMIN_USER=${PROFILARR_ADMIN_USER:-${shared_admin_user}}
PROFILARR_ADMIN_PASSWORD=${PROFILARR_ADMIN_PASSWORD:-${shared_admin_password}}
PORTAINER_ADMIN_USER=${PORTAINER_ADMIN_USER:-${shared_admin_user}}
PORTAINER_ADMIN_PASSWORD=${PORTAINER_ADMIN_PASSWORD:-${shared_admin_password}}
EOF
  fi

  # A supplied env file may intentionally contain only VPN credentials. Preserve
  # its values and add every key needed for a self-configuring installation.
  ensure_env_entry "$tmp_env" NORDVPN_USER "${NORDVPN_USER:-CHANGE_ME}"
  ensure_env_entry "$tmp_env" NORDVPN_PASS "${NORDVPN_PASS:-CHANGE_ME}"
  ensure_env_entry "$tmp_env" NORDVPN_COUNTRIES "${NORDVPN_COUNTRIES:-United States}"
  ensure_env_entry "$tmp_env" TZ "$TIMEZONE"
  ensure_env_entry "$tmp_env" PUID "${PUID:-65534}"
  ensure_env_entry "$tmp_env" PGID "${PGID:-65534}"
  ensure_env_entry "$tmp_env" MEDIASTACK_ADMIN_USER "$shared_admin_user"
  ensure_env_entry "$tmp_env" MEDIASTACK_ADMIN_PASSWORD "$shared_admin_password"
  ensure_env_entry "$tmp_env" VPN_TYPE "${VPN_TYPE:-openvpn}"
  ensure_env_entry "$tmp_env" FIREWALL "${FIREWALL:-on}"
  ensure_env_entry "$tmp_env" FIREWALL_VPN_INPUT_PORTS "${FIREWALL_VPN_INPUT_PORTS:-6881}"
  ensure_env_entry "$tmp_env" FIREWALL_OUTBOUND_SUBNETS "${FIREWALL_OUTBOUND_SUBNETS:-192.168.0.0/16,172.16.0.0/12,10.0.0.0/8}"
  ensure_env_entry "$tmp_env" JELLYSTAT_DB_PASS "${JELLYSTAT_DB_PASS:-$(rand_hex 24)}"
  ensure_env_entry "$tmp_env" JELLYSTAT_JWT_SECRET "${JELLYSTAT_JWT_SECRET:-$(rand_hex 32)}"
  ensure_env_entry "$tmp_env" HOMARR_SECRET_ENCRYPTION_KEY "${HOMARR_SECRET_ENCRYPTION_KEY:-$(rand_hex 32)}"
  ensure_env_entry "$tmp_env" QBITTORRENT_USER "${QBITTORRENT_USER:-${shared_admin_user}}"
  ensure_env_entry "$tmp_env" QBITTORRENT_PASSWORD "${QBITTORRENT_PASSWORD:-${shared_admin_password}}"
  ensure_env_entry "$tmp_env" JELLYFIN_ADMIN_USER "${JELLYFIN_ADMIN_USER:-${shared_admin_user}}"
  ensure_env_entry "$tmp_env" JELLYFIN_ADMIN_PASSWORD "${JELLYFIN_ADMIN_PASSWORD:-${shared_admin_password}}"
  ensure_env_entry "$tmp_env" PROFILARR_ADMIN_USER "${PROFILARR_ADMIN_USER:-${shared_admin_user}}"
  ensure_env_entry "$tmp_env" PROFILARR_ADMIN_PASSWORD "${PROFILARR_ADMIN_PASSWORD:-${shared_admin_password}}"
  ensure_env_entry "$tmp_env" PORTAINER_ADMIN_USER "${PORTAINER_ADMIN_USER:-${shared_admin_user}}"
  ensure_env_entry "$tmp_env" PORTAINER_ADMIN_PASSWORD "${PORTAINER_ADMIN_PASSWORD:-${shared_admin_password}}"

  if [[ "$AMD_ACTIVE" == "1" ]]; then
    # Jellyfin runs as PUID/PGID and must join the LXC's render/video groups to
    # open /dev/dri/renderD128, so resolve the real GIDs inside the container.
    local render_gid="" video_gid=""
    if [[ "$DRY_RUN" == "0" ]]; then
      render_gid="$(pct exec "$CTID" -- getent group render 2>/dev/null | awk -F: '{print $3}' | head -n 1 || true)"
      video_gid="$(pct exec "$CTID" -- getent group video 2>/dev/null | awk -F: '{print $3}' | head -n 1 || true)"
    fi
    ensure_env_entry "$tmp_env" RENDER_GID "${render_gid:-104}"
    ensure_env_entry "$tmp_env" VIDEO_GID "${video_gid:-44}"
    ensure_env_entry "$tmp_env" LIBVA_DRIVER_NAME "${LIBVA_DRIVER_NAME:-radeonsi}"
  fi

  local firewall_vpn_input_ports
  firewall_vpn_input_ports="$(awk -F= '/^FIREWALL_VPN_INPUT_PORTS=/{value=substr($0,index($0,"=")+1)} END{print value}' "$tmp_env")"
  if [[ ! "$firewall_vpn_input_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    warn "FIREWALL_VPN_INPUT_PORTS='${firewall_vpn_input_ports}' is incompatible with current Gluetun; using the exposed qBittorrent port 6881."
    sed -i 's/^FIREWALL_VPN_INPUT_PORTS=.*/FIREWALL_VPN_INPUT_PORTS=6881/' "$tmp_env"
  fi

  MEDIASTACK_ADMIN_USER="$(awk -F= '/^MEDIASTACK_ADMIN_USER=/{value=substr($0,index($0,"=")+1)} END{print value}' "$tmp_env")"
  MEDIASTACK_ADMIN_PASSWORD="$(awk -F= '/^MEDIASTACK_ADMIN_PASSWORD=/{value=substr($0,index($0,"=")+1)} END{print value}' "$tmp_env")"
  [[ -n "$MEDIASTACK_ADMIN_USER" ]] || die "MEDIASTACK_ADMIN_USER cannot be empty."
  [[ ${#MEDIASTACK_ADMIN_PASSWORD} -ge 12 ]] || die "MEDIASTACK_ADMIN_PASSWORD must be at least 12 characters."

  if grep -q 'CHANGE_ME' "$tmp_env"; then
    ENV_HAS_PLACEHOLDER=1
    warn "The generated .env still contains CHANGE_ME placeholders. Stack start will be skipped."
  fi

  run pct push "$CTID" "$tmp_env" "${APP_DIR}/.env" --perms 0600
  rm -f "$tmp_env"
}

compose_command() {
  if [[ "$NVIDIA_ACTIVE" == "1" ]]; then
    printf 'docker compose -f docker-compose.yml -f docker-compose.nvidia.yml'
  elif [[ "$AMD_ACTIVE" == "1" ]]; then
    printf 'docker compose -f docker-compose.yml -f docker-compose.amd.yml'
  else
    printf 'docker compose -f docker-compose.yml'
  fi
}

start_stack() {
  local cmd
  cmd="$(compose_command)"
  pct_bash "printf '%s\n' '${cmd}' > '${APP_DIR}/.compose-command'"

  if [[ "$START_STACK" != "1" || "$ENV_HAS_PLACEHOLDER" == "1" ]]; then
    warn "Skipping docker compose up. To start later:"
    warn "pct exec ${CTID} -- bash -lc \"cd ${APP_DIR} && \$(cat ${APP_DIR}/.compose-command) up -d\""
    return
  fi

  info "Pulling and starting media stack"
  pct_bash "cd '${APP_DIR}' && ${cmd} pull && ${cmd} up -d"
}

configure_stack() {
  if [[ "$AUTO_CONFIGURE" != "1" || "$START_STACK" != "1" || "$ENV_HAS_PLACEHOLDER" == "1" ]]; then
    warn "Skipping automatic app integration. To run it later:"
    warn "pct exec ${CTID} -- env APP_DIR='${APP_DIR}' QNAP_ENABLED='${ENABLE_QNAP}' APPLY_TRASH='${APPLY_TRASH}' '${APP_DIR}/configure-media-stack.sh'"
    return
  fi

  info "Configuring media storage paths and connecting the media applications"
  pct_bash "APP_DIR='${APP_DIR}' QNAP_ENABLED='${ENABLE_QNAP}' APPLY_TRASH='${APPLY_TRASH}' '${APP_DIR}/configure-media-stack.sh'"
}

enable_subtitle_repair_timer() {
  if [[ "$ENABLE_SUBTITLE_TIMER" != "1" ]]; then
    info "Automatic subtitle repair timer disabled"
    return
  fi
  if [[ "$START_STACK" != "1" || "$AUTO_CONFIGURE" != "1" || "$ENV_HAS_PLACEHOLDER" == "1" ]]; then
    warn "Skipping subtitle repair timer until the stack is started and automatically configured."
    warn "Enable it later with: APP_DIR='${APP_DIR}' QNAP_REQUIRED='${ENABLE_QNAP}' '${APP_DIR}/fix-subtitles.sh' --install-timer --timer-only"
    return
  fi
  info "Enabling safe after-boot and weekly subtitle repair"
  pct_bash "APP_DIR='${APP_DIR}' QNAP_REQUIRED='${ENABLE_QNAP}' '${APP_DIR}/fix-subtitles.sh' --install-timer --timer-only"
}

verify_stack() {
  info "Verification"
  pct_bash "docker --version && docker compose version"
  if [[ "$NVIDIA_ACTIVE" == "1" ]]; then
    pct_bash "nvidia-smi || true"
  fi
  if [[ "$AMD_ACTIVE" == "1" ]]; then
    pct_bash "vainfo --display drm --device /dev/dri/renderD128 2>&1 | head -n 20 || true"
  fi

  if [[ "$START_STACK" == "1" && "$ENV_HAS_PLACEHOLDER" == "0" ]]; then
    pct_bash "cd '${APP_DIR}' && \$(cat '${APP_DIR}/.compose-command') ps"
    # This single-quoted script is intentionally expanded inside the LXC.
    # shellcheck disable=SC2016
    pct_bash '
for port in 8088 8096 5055 3000 6868 8989 7878 9696 8080 8686 6767 5690 5000 8090 8191 7575 9443; do
  code="$(curl -ksS -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${port}/" || true)"
  printf "%s %s\n" "$port" "$code"
done
'
    if [[ "$AUTO_CONFIGURE" == "1" ]]; then
      pct_bash "APP_DIR='${APP_DIR}' '${APP_DIR}/verify-media-stack.sh'"
    fi
  fi
}

show_completion() {
  local lxc_ip=""
  local portal="not started"
  local completion_label="Completed successfully!"
  [[ "$DRY_RUN" == "1" ]] && completion_label="Dry run completed successfully!"
  if [[ "$DRY_RUN" == "0" ]]; then
    lxc_ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ "$START_STACK" == "1" && "$ENV_HAS_PLACEHOLDER" == "0" && -n "$lxc_ip" ]]; then
    portal="http://${lxc_ip}:8088"
  fi

  finish_step
  if [[ "$PRETTY_OUTPUT" == "1" ]]; then
    printf '\n'
    printf '  \033[38;5;99m╭──────────────────────────────────────────────────────────────╮\033[0m\n'
    printf '  \033[38;5;99m│\033[0m  \033[1;92m✔  %-55s\033[0m\033[38;5;99m│\033[0m\n' "$completion_label"
    printf '  \033[38;5;99m├──────────────────────────────────────────────────────────────┤\033[0m\n'
    printf '  \033[38;5;99m│\033[0m  LXC             \033[1;97mCT%-5s %-42s\033[0m\033[38;5;99m│\033[0m\n' "$CTID" "(${CT_HOSTNAME})"
    printf '  \033[38;5;99m│\033[0m  Compose path    \033[38;5;45m%-47s\033[0m\033[38;5;99m│\033[0m\n' "$APP_DIR"
    if [[ "$PRIVILEGED_FALLBACK_USED" == "1" ]]; then
      printf '  \033[38;5;99m│\033[0m  LXC security    \033[1;93m%-47s\033[0m\033[38;5;99m│\033[0m\n' "privileged fallback (host ACL incompatibility)"
    fi
    printf '  \033[38;5;99m│\033[0m  Media Stack UI  \033[38;5;45m%-47s\033[0m\033[38;5;99m│\033[0m\n' "$portal"
    printf '  \033[38;5;99m│\033[0m  Install log     \033[38;5;245m%-47s\033[0m\033[38;5;99m│\033[0m\n' "$LOG_FILE"
    printf '  \033[38;5;99m╰──────────────────────────────────────────────────────────────╯\033[0m\n'
    if [[ "$START_STACK" == "1" && "$ENV_HAS_PLACEHOLDER" == "0" ]]; then
      printf '\n  \033[1;97mShared login\033[0m  %s / %s\n' "$MEDIASTACK_ADMIN_USER" "$MEDIASTACK_ADMIN_PASSWORD"
      printf '  \033[38;5;245mCredentials are also stored in %s/.env inside CT%s (mode 0600).\033[0m\n' "$APP_DIR" "$CTID"
    fi
    printf '  \033[1;97mLXC console\033[0m  root / %s\n' "$ROOT_PASSWORD"
    printf '  \033[38;5;245mChange the root password after first login with: passwd\033[0m\n'
    printf '  \033[38;5;245mOnly expose reviewed media ports; keep admin applications internal.\033[0m\n\n'
  else
    printf '%s CT%s (%s)\n' "$completion_label" "$CTID" "$CT_HOSTNAME"
    printf 'Compose path: %s\n' "$APP_DIR"
    printf 'Media Stack UI: %s\n' "$portal"
    printf 'LXC console: root / %s\n' "$ROOT_PASSWORD"
    printf 'Install log: %s\n' "$LOG_FILE"
  fi
}

main() {
  parse_args "$@"
  init_output
  trap 'handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap 'stop_spinner' EXIT
  trap 'stop_spinner; exit 130' INT TERM
  preflight
  resolve_platform_defaults
  resolve_ctid
  run_setup_ui
  resolve_ctid
  validate_settings
  show_install_plan

  info "Deploying Jellyfin/media stack to CT${CTID}"
  if [[ "$PRIMARY_STORAGE_MODE" == "nfs" ]]; then
    prepare_nfs_mount "primary media" "$NAS_EXPORT" "$HOST_NAS" 1
  else
    info "Using Proxmox-managed onboard media disk ${LOCAL_MEDIA_STORAGE}:${LOCAL_MEDIA_SIZE_GB}G"
  fi
  if [[ "$ENABLE_QNAP" == "1" ]]; then
    prepare_nfs_mount "secondary media" "$QNAP_EXPORT" "$HOST_QNAP" 1
  else
    info "Secondary NAS disabled"
  fi

  resolve_template
  create_container "$RESOLVED_TEMPLATE_REF"
  configure_lxc_devices
  start_container
  install_docker
  install_nvidia_userspace
  install_amd_userspace
  push_stack_files
  write_env_file
  create_media_dirs
  start_stack
  configure_stack
  enable_subtitle_repair_timer
  verify_stack
  show_completion
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
