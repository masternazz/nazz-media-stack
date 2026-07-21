#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_ASSET_DIR="${SCRIPT_DIR}/jellyfin-stack"

CTID="${CTID:-auto}"
CT_HOSTNAME="${CT_HOSTNAME:-Jellyfin}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-auto}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
DISK_GB="${DISK_GB:-60}"
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-8000}"
SWAP_MB="${SWAP_MB:-512}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-6}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"
TIMEZONE="${TZ:-America/New_York}"
APP_DIR="${APP_DIR:-/opt/mediastack}"

HOST_NAS="${HOST_NAS:-/mnt/synology}"
NAS_EXPORT="${NAS_EXPORT:-nas.example.lan:/volume1/media}"
HOST_QNAP="${HOST_QNAP:-/mnt/qnap_media}"
QNAP_EXPORT="${QNAP_EXPORT:-nas.example.lan:/share/media}"
ENABLE_QNAP=0
NVIDIA_MODE="auto"
START_STACK=1
AUTO_CONFIGURE=1
APPLY_TRASH=1
ENABLE_SUBTITLE_TIMER=1
REPLACE=0
DRY_RUN=0
GUI_MODE="auto"
ENV_FILE=""
ROOT_PASSWORD=""
SSH_PUBLIC_KEY_FILE=""
MEDIASTACK_ADMIN_USER="${MEDIASTACK_ADMIN_USER:-admin}"
MEDIASTACK_ADMIN_PASSWORD="${MEDIASTACK_ADMIN_PASSWORD:-}"

COMPOSE_SRC="${STACK_ASSET_DIR}/docker-compose.yml"
NVIDIA_COMPOSE_SRC="${STACK_ASSET_DIR}/docker-compose.nvidia.yml"
ENV_EXAMPLE_SRC="${STACK_ASSET_DIR}/.env.example"
CONFIGURE_SRC="${STACK_ASSET_DIR}/configure-media-stack.sh"
VERIFY_SRC="${STACK_ASSET_DIR}/verify-media-stack.sh"
FIX_SUBTITLES_SRC="${STACK_ASSET_DIR}/fix-subtitles.sh"
FIX_SUBTITLES_SERVICE_SRC="${STACK_ASSET_DIR}/fix-subtitles.service"
FIX_SUBTITLES_TIMER_SRC="${STACK_ASSET_DIR}/fix-subtitles.timer"
PORTAL_SRC="${STACK_ASSET_DIR}/portal/index.html"
NVIDIA_ACTIVE=0
ENV_HAS_PLACEHOLDER=0
RESOLVED_TEMPLATE_REF=""

usage() {
  cat <<'EOF'
Usage:
  install-jellyfin-stack.sh [options]

Run this on a Proxmox VE host as root. It creates an unprivileged Debian LXC
with Docker and deploys the Jellyfin/media stack.

Core options:
  --ctid ID                 LXC ID to create, or auto/next (default: next free ID)
  --nextid                  Use the next free Proxmox ID
  --hostname NAME           LXC hostname (default: Jellyfin)
  --storage NAME            Proxmox storage for rootfs (default: local-lvm)
  --disk-gb GB              Root disk size in GB (default: 60)
  --cores COUNT             CPU cores (default: 2)
  --memory-mb MB            Memory in MB (default: 8000)
  --swap-mb MB              Swap in MB (default: 512)
  --template REF            Template ref or "auto" (default: auto Debian 13, fallback 12)
  --bridge NAME             Proxmox bridge (default: vmbr0)
  --vlan ID                 VLAN tag (default: 6)
  --ip-config VALUE         Proxmox ip= value, e.g. dhcp or 192.168.1.50/24,gw=192.168.1.1
  --nameserver IP           Container DNS server (default: 1.1.1.1)

Storage:
  --nas-export EXPORT       Required NFS export (default: nas.example.lan:/volume1/media)
  --host-nas PATH           Host mount path passed to LXC /mnt/nas (default: /mnt/synology)
  --enable-qnap             Mount QNAP export and pass to LXC /mnt/qnap
  --qnap-export EXPORT      QNAP NFS export (default: nas.example.lan:/share/media)
  --host-qnap PATH          Host QNAP mount path (default: /mnt/qnap_media)

GPU:
  --no-nvidia               Do not configure NVIDIA passthrough
  --require-nvidia          Fail if NVIDIA devices are not present on the Proxmox host

Stack/env:
  --env-file FILE           Use an existing .env; missing stack secrets are generated
  --no-start                Install files but do not run docker compose up
  --no-auto-configure       Start containers without first-run app/NAS integration
  --no-trash-profiles       Do not auto-apply TRaSH Guides quality profiles via Recyclarr
  --no-subtitle-repair-timer
                            Do not enable the safe weekly subtitle repair timer
  --root-password PASS      Set root password for the LXC
  --ssh-public-key-file     File containing SSH public key(s) for root

Safety:
  --gui                     Force the terminal setup UI
  --no-gui                  Skip the setup UI for automation
  --replace                 Stop and destroy an existing CTID before creating it
  --dry-run                 Print commands without changing anything
  -h, --help                Show this help

Example:
  NORDVPN_USER='token-user' NORDVPN_PASS='token-pass' \
    ./install-jellyfin-stack.sh --no-gui --storage local-lvm

Interactive setup:
  ./install-jellyfin-stack.sh

After first boot, apps live on the LXC IP:
  Media Stack Home 8088, Jellyfin 8096, Seerr 5055, Jellystat 3000,
  Profilarr (TRaSH GUI) 6868, Sonarr 8989, Radarr 7878,
  Prowlarr 9696, qBittorrent 8080, Lidarr 8686, Bazarr 6767, Wizarr 5690,
  Kavita 5000, Mylar 8090, Byparr 8191, Homarr 7575, Portainer 9443.
EOF
}

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_shell() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash -lc %q\n' "$1"
  else
    bash -lc "$1"
  fi
}

pct_bash() {
  local script="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] pct exec %q -- bash -lc %q\n' "$CTID" "$script"
  else
    pct exec "$CTID" -- bash -lc "$script"
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

use_whiptail() {
  [[ "$GUI_MODE" != "off" && -t 0 && -t 1 && -n "${TERM:-}" ]] && command -v whiptail >/dev/null 2>&1
}

ui_input() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --title "$title" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3)"; then
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
    if ! value="$(whiptail --title "$title" --passwordbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
  else
    read -r -s -p "${prompt}${default:+ [already set]}: " value
    printf '\n' >&2
  fi

  printf '%s\n' "${value:-$default}"
}

ui_yesno() {
  local title="$1"
  local prompt="$2"
  local default="${3:-yes}"
  local result=0

  if use_whiptail; then
    if [[ "$default" == "yes" ]]; then
      if whiptail --title "$title" --yesno "$prompt" 10 78 3>&1 1>&2 2>&3; then
        return 0
      else
        result=$?
      fi
      [[ "$result" == "1" ]] && return 1
      die "Setup cancelled."
    fi
    if whiptail --defaultno --title "$title" --yesno "$prompt" 10 78 3>&1 1>&2 2>&3; then
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

ui_nvidia_menu() {
  local value=""

  if use_whiptail; then
    if ! value="$(whiptail --title "GPU Passthrough" --menu "Choose Jellyfin NVIDIA passthrough mode." 14 78 4 \
      auto "Use NVIDIA if devices exist" \
      require "Fail if NVIDIA is missing" \
      off "CPU-only Jellyfin" \
      3>&1 1>&2 2>&3)"; then
      die "Setup cancelled."
    fi
    printf '%s\n' "$value"
    return
  fi

  value="$(ui_input "GPU Passthrough" "NVIDIA mode: auto, require, or off" "$NVIDIA_MODE")"
  case "$value" in
    auto|require|off) printf '%s\n' "$value" ;;
    *) warn "Unknown NVIDIA mode '${value}', using auto."; printf 'auto\n' ;;
  esac
}

ui_confirm() {
  local summary="$1"
  local result=0

  if use_whiptail; then
    if whiptail --title "Ready To Install" --yesno "$summary" 24 88 3>&1 1>&2 2>&3; then
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

run_setup_ui() {
  [[ "$GUI_MODE" == "off" ]] && return
  [[ "$GUI_MODE" == "auto" && ! -t 0 ]] && return

  if ! use_whiptail; then
    warn "whiptail not available; using plain terminal prompts."
  fi

  CTID="$(ui_input "Container ID" "Container ID. Leave as-is for the next free Proxmox ID." "$CTID")"
  resolve_ctid
  CT_HOSTNAME="$(ui_input "Hostname" "LXC hostname" "$CT_HOSTNAME")"
  ROOTFS_STORAGE="$(ui_input "Root Storage" "Proxmox rootfs storage" "$ROOTFS_STORAGE")"
  DISK_GB="$(ui_input "Disk" "Root disk size in GB" "$DISK_GB")"
  CORES="$(ui_input "CPU" "CPU cores" "$CORES")"
  MEMORY_MB="$(ui_input "Memory" "Memory in MB" "$MEMORY_MB")"
  SWAP_MB="$(ui_input "Swap" "Swap in MB" "$SWAP_MB")"
  BRIDGE="$(ui_input "Network" "Bridge" "$BRIDGE")"
  VLAN_TAG="$(ui_input "Network" "VLAN tag" "$VLAN_TAG")"
  IP_CONFIG="$(ui_input "Network" "Proxmox ip= value" "$IP_CONFIG")"
  NAMESERVER="$(ui_input "DNS" "Container nameserver" "$NAMESERVER")"
  APP_DIR="$(ui_input "App Path" "Media stack directory inside the LXC" "$APP_DIR")"
  NAS_EXPORT="$(ui_input "Synology" "Required Synology NFS export" "$NAS_EXPORT")"
  HOST_NAS="$(ui_input "Synology" "Proxmox host mount path for Synology" "$HOST_NAS")"

  if ui_yesno "QNAP" "Enable QNAP NFS mount and /mnt/qnap bind?" "no"; then
    ENABLE_QNAP=1
    QNAP_EXPORT="$(ui_input "QNAP" "QNAP NFS export" "$QNAP_EXPORT")"
    HOST_QNAP="$(ui_input "QNAP" "Proxmox host mount path for QNAP" "$HOST_QNAP")"
  else
    ENABLE_QNAP=0
  fi

  NVIDIA_MODE="$(ui_nvidia_menu)"

  if ui_yesno "Start Stack" "Pull images and start Docker Compose after install?" "yes"; then
    START_STACK=1
  else
    START_STACK=0
  fi

  if pct status "$CTID" >/dev/null 2>&1; then
    if ui_yesno "Existing CT${CTID}" "CT${CTID} already exists. Destroy and replace it?" "no"; then
      REPLACE=1
    else
      REPLACE=0
    fi
  fi

  if ui_yesno "NordVPN" "Enter NordVPN manual-setup credentials now?" "no"; then
    NORDVPN_USER="$(ui_input "NordVPN" "NordVPN manual-setup username" "${NORDVPN_USER:-}")"
    NORDVPN_PASS="$(ui_password "NordVPN" "NordVPN manual-setup password" "${NORDVPN_PASS:-}")"
    export NORDVPN_USER NORDVPN_PASS
  fi

  MEDIASTACK_ADMIN_USER="$(ui_input "Shared Admin Login" "Admin username for Jellyfin, qBittorrent, Profilarr, and Portainer" "$MEDIASTACK_ADMIN_USER")"
  MEDIASTACK_ADMIN_PASSWORD="$(ui_password "Shared Admin Login" "Admin password (12+ characters). Leave blank to generate one." "$MEDIASTACK_ADMIN_PASSWORD")"
  if [[ -n "$MEDIASTACK_ADMIN_PASSWORD" && ${#MEDIASTACK_ADMIN_PASSWORD} -lt 12 ]]; then
    die "The shared admin password must be at least 12 characters for Portainer."
  fi

  local summary
  summary="Install Jellyfin/media stack with these settings:

CTID: ${CTID}
Hostname: ${CT_HOSTNAME}
Storage: ${ROOTFS_STORAGE}:${DISK_GB}G
CPU/RAM/Swap: ${CORES} cores, ${MEMORY_MB} MB RAM, ${SWAP_MB} MB swap
Network: ${BRIDGE}, VLAN ${VLAN_TAG}, ip=${IP_CONFIG}, DNS ${NAMESERVER}
Synology: ${NAS_EXPORT} -> ${HOST_NAS} -> /mnt/nas
QNAP: $([[ "$ENABLE_QNAP" == "1" ]] && printf '%s -> %s -> /mnt/qnap' "$QNAP_EXPORT" "$HOST_QNAP" || printf 'disabled')
NVIDIA: ${NVIDIA_MODE}
Start stack: $([[ "$START_STACK" == "1" ]] && printf 'yes' || printf 'no')
Auto-configure apps/NAS: $([[ "$AUTO_CONFIGURE" == "1" ]] && printf 'yes' || printf 'no')
Shared admin user: ${MEDIASTACK_ADMIN_USER}
Replace existing CT: $([[ "$REPLACE" == "1" ]] && printf 'yes' || printf 'no')"

  ui_confirm "$summary"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) CTID="$2"; shift 2 ;;
      --nextid) CTID="auto"; shift ;;
      --hostname) CT_HOSTNAME="$2"; shift 2 ;;
      --storage) ROOTFS_STORAGE="$2"; shift 2 ;;
      --disk-gb) DISK_GB="$2"; shift 2 ;;
      --cores) CORES="$2"; shift 2 ;;
      --memory-mb) MEMORY_MB="$2"; shift 2 ;;
      --swap-mb) SWAP_MB="$2"; shift 2 ;;
      --template) TEMPLATE="$2"; shift 2 ;;
      --bridge) BRIDGE="$2"; shift 2 ;;
      --vlan) VLAN_TAG="$2"; shift 2 ;;
      --ip-config) IP_CONFIG="$2"; shift 2 ;;
      --nameserver) NAMESERVER="$2"; shift 2 ;;
      --nas-export) NAS_EXPORT="$2"; shift 2 ;;
      --host-nas) HOST_NAS="$2"; shift 2 ;;
      --enable-qnap) ENABLE_QNAP=1; shift ;;
      --qnap-export) QNAP_EXPORT="$2"; shift 2 ;;
      --host-qnap) HOST_QNAP="$2"; shift 2 ;;
      --no-nvidia) NVIDIA_MODE="off"; shift ;;
      --require-nvidia) NVIDIA_MODE="require"; shift ;;
      --env-file) ENV_FILE="$2"; shift 2 ;;
      --no-start) START_STACK=0; shift ;;
      --no-auto-configure) AUTO_CONFIGURE=0; shift ;;
      --no-trash-profiles) APPLY_TRASH=0; shift ;;
      --no-subtitle-repair-timer) ENABLE_SUBTITLE_TIMER=0; shift ;;
      --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
      --ssh-public-key-file) SSH_PUBLIC_KEY_FILE="$2"; shift 2 ;;
      --gui) GUI_MODE="on"; shift ;;
      --no-gui) GUI_MODE="off"; shift ;;
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
  [[ -f "$COMPOSE_SRC" ]] || die "Missing $COMPOSE_SRC"
  [[ -f "$NVIDIA_COMPOSE_SRC" ]] || die "Missing $NVIDIA_COMPOSE_SRC"
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
  local net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},tag=${VLAN_TAG},type=veth"
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
    --nameserver "$NAMESERVER"
    --timezone "$TIMEZONE"
    --onboot 1
    --start 0
    --description "Docker LXC for Jellyfin media stack. Generated by homelab-docs scripts/proxmox/install-jellyfin-stack.sh."
  )

  [[ -n "$ROOT_PASSWORD" ]] && args+=(--password "$ROOT_PASSWORD")
  [[ -n "$SSH_PUBLIC_KEY_FILE" ]] && args+=(--ssh-public-keys "$SSH_PUBLIC_KEY_FILE")

  if pct status "$CTID" >/dev/null 2>&1; then
    if [[ "$REPLACE" == "1" ]]; then
      warn "CTID ${CTID} exists and --replace was set. Destroying it."
      run pct stop "$CTID" --skiplock 1 || true
      run pct destroy "$CTID" --purge 1
    else
      die "CTID ${CTID} already exists. Use --ctid for a new ID or --replace to rebuild it."
    fi
  fi

  info "Creating CT${CTID} from ${template_ref}"
  run "${args[@]}"
  run pct set "$CTID" -mp0 "${HOST_NAS},mp=/mnt/nas"
  run pct set "$CTID" -mp1 "${HOST_QNAP},mp=/mnt/qnap"
  run pct set "$CTID" --tags "media;docker;jellyfin"
}

configure_lxc_devices() {
  info "Adding /dev/net/tun passthrough for Gluetun"
  append_lxc_config "lxc.cgroup2.devices.allow: c 10:200 rwm"
  append_lxc_config "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"

  if [[ "$NVIDIA_MODE" == "off" ]]; then
    info "NVIDIA passthrough disabled"
    return
  fi

  local required_devices=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools)
  local missing_devices=()
  local device=""
  for device in "${required_devices[@]}"; do
    [[ -e "$device" ]] || missing_devices+=("$device")
  done

  if (( ${#missing_devices[@]} > 0 )); then
    [[ "$NVIDIA_MODE" == "require" ]] && die "NVIDIA passthrough required, but these devices are missing: ${missing_devices[*]}"
    warn "Required NVIDIA devices are missing (${missing_devices[*]}); deploying CPU-only Jellyfin."
    return
  fi

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    [[ "$NVIDIA_MODE" == "require" ]] && die "NVIDIA passthrough required, but nvidia-smi is not installed on the Proxmox host."
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

  for _ in $(seq 1 60); do
    if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  die "CT${CTID} started, but DNS/network did not become ready."
}

install_docker() {
  info "Installing Docker Engine and Compose plugin in CT${CTID}"
  # This single-quoted script is intentionally expanded inside the LXC.
  # shellcheck disable=SC2016
  pct_bash '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update
apt-get install -y ca-certificates curl gnupg jq python3 python3-yaml util-linux
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
arch="$(dpkg --print-architecture)"
printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n" "$arch" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
'
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

  info "Configuring NAS paths and connecting the media applications"
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

main() {
  parse_args "$@"
  preflight
  resolve_ctid
  run_setup_ui
  resolve_ctid

  info "Deploying Jellyfin/media stack to CT${CTID}"
  prepare_nfs_mount "Synology media" "$NAS_EXPORT" "$HOST_NAS" 1
  if [[ "$ENABLE_QNAP" == "1" ]]; then
    prepare_nfs_mount "QNAP media" "$QNAP_EXPORT" "$HOST_QNAP" 1
  else
    info "QNAP disabled; ${HOST_QNAP} will be an empty optional bind path"
    run mkdir -p "$HOST_QNAP"
  fi

  resolve_template
  create_container "$RESOLVED_TEMPLATE_REF"
  configure_lxc_devices
  start_container
  install_docker
  install_nvidia_userspace
  push_stack_files
  write_env_file
  create_media_dirs
  start_stack
  configure_stack
  enable_subtitle_repair_timer
  verify_stack

  info "Done. LXC: CT${CTID} (${CT_HOSTNAME})"
  info "Compose path: ${APP_DIR}"
  if [[ "$START_STACK" == "1" && "$ENV_HAS_PLACEHOLDER" == "0" ]]; then
    local lxc_ip
    lxc_ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$lxc_ip" ]] && info "Open Media Stack Home: http://${lxc_ip}:8088"
    info "Shared admin username: ${MEDIASTACK_ADMIN_USER}"
    info "Shared admin password: ${MEDIASTACK_ADMIN_PASSWORD}"
    info "Credentials are also stored in ${APP_DIR}/.env inside CT${CTID} (mode 0600)."
  fi
  info "If you reverse-proxy this stack, expose only reviewed ports and keep admin apps internal."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
