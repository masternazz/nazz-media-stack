#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/mediastack}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"

info() { printf '\033[1;34m[finish-setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[finish-setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

env_value() {
  local key="$1" default="${2:-}" value=""
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$ENV_FILE")"
  printf '%s\n' "${value:-$default}"
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == CHANGE_ME* ]]
}

main() {
  [[ "$(id -u)" == "0" ]] || die "Run this as root inside the Jellyfin LXC."
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}."
  [[ -x "${APP_DIR}/configure-media-stack.sh" ]] || die "Missing configure-media-stack.sh."
  [[ -x "${APP_DIR}/verify-media-stack.sh" ]] || die "Missing verify-media-stack.sh."
  [[ -s "${APP_DIR}/.compose-command" ]] || die "Missing ${APP_DIR}/.compose-command."

  local vpn_user vpn_password qnap_enabled apply_trash subtitle_timer compose_cmd
  vpn_user="$(env_value NORDVPN_USER)"
  vpn_password="$(env_value NORDVPN_PASS)"
  if is_placeholder "$vpn_user" || is_placeholder "$vpn_password"; then
    die "Replace NORDVPN_USER and NORDVPN_PASS in ${ENV_FILE} with NordVPN manual-service credentials first."
  fi

  qnap_enabled="$(env_value QNAP_ENABLED 0)"
  apply_trash="$(env_value APPLY_TRASH 1)"
  subtitle_timer="$(env_value SUBTITLE_REPAIR_TIMER_ENABLED 1)"
  compose_cmd="$(cat "${APP_DIR}/.compose-command")"
  compose_cmd="${compose_cmd// --profile vpn/} --profile vpn"
  printf '%s\n' "$compose_cmd" >"${APP_DIR}/.compose-command"

  info "Starting every media-stack container, including Gluetun and qBittorrent"
  cd "$APP_DIR"
  bash -lc "cd '$APP_DIR' && ${compose_cmd} pull && ${compose_cmd} up -d"

  info "Applying application logins, libraries, paths, integrations, and dashboards"
  APP_DIR="$APP_DIR" \
    QNAP_ENABLED="$qnap_enabled" \
    APPLY_TRASH="$apply_trash" \
    DOWNLOADS_ENABLED=1 \
    "${APP_DIR}/configure-media-stack.sh"

  if [[ "$subtitle_timer" == "1" ]]; then
    info "Enabling the subtitle repair timer"
    APP_DIR="$APP_DIR" QNAP_REQUIRED="$qnap_enabled" \
      "${APP_DIR}/fix-subtitles.sh" --install-timer --timer-only
  fi

  info "Verifying the finished installation"
  APP_DIR="$APP_DIR" DOWNLOADS_ENABLED=1 "${APP_DIR}/verify-media-stack.sh"
  touch "${APP_DIR}/.mediastack-configured"
  rm -f "${APP_DIR}/.mediastack-core-configured"
  info "Media-stack setup is fully configured and verified."
}

main "$@"
