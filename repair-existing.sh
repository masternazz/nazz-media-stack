#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/jellyfin-stack"
APP_DIR="/opt/mediastack"
CTID="${1:-}"
QNAP_ENABLED="${QNAP_ENABLED:-auto}"
APPLY_TRASH="${APPLY_TRASH:-1}"
SUBTITLE_REPAIR_TIMER_ENABLED="${SUBTITLE_REPAIR_TIMER_ENABLED:-1}"

usage() {
  cat <<'EOF'
Usage:
  ./repair-existing.sh CTID

Repairs and completes an existing Jellyfin Media Stack LXC in place. It
preserves the existing .env, application configs, databases, and media.

Optional environment overrides:
  QNAP_ENABLED=0|1
  APPLY_TRASH=0|1
  SUBTITLE_REPAIR_TIMER_ENABLED=0|1
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

pct_bash() {
  pct exec "$CTID" -- bash -lc "$1"
}

env_value_in_lxc() {
  local key="$1"
  pct_bash "awk -v key='$key' 'index(\$0,key \"=\")==1 {value=substr(\$0,length(key)+2)} END {print value}' '${APP_DIR}/.env'"
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == CHANGE_ME* ]]
}

main() {
  [[ "$CTID" != "-h" && "$CTID" != "--help" ]] || { usage; exit 0; }
  [[ "$(id -u)" == "0" ]] || die "Run this on the Proxmox host as root."
  [[ "$CTID" =~ ^[0-9]+$ ]] || { usage; die "CTID must be numeric."; }
  command -v pct >/dev/null 2>&1 || die "pct is required; run this on Proxmox VE."
  pct config "$CTID" >/dev/null 2>&1 || die "CT${CTID} does not exist."
  [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] || pct start "$CTID"

  for file in \
    docker-compose.yml \
    docker-compose.nvidia.yml \
    docker-compose.amd.yml \
    configure-media-stack.sh \
    verify-media-stack.sh \
    finish-media-stack-setup.sh \
    fix-subtitles.sh \
    fix-subtitles.service \
    fix-subtitles.timer; do
    [[ -f "${ASSET_DIR}/${file}" ]] || die "Missing ${ASSET_DIR}/${file}."
  done
  [[ -f "${ASSET_DIR}/portal/index.html" ]] || die "Missing ${ASSET_DIR}/portal/index.html."

  pct_bash "test -f '${APP_DIR}/.env' && test -s '${APP_DIR}/.compose-command'" ||
    die "CT${CTID} is not an installed Jellyfin Media Stack container."

  printf 'Updating setup assets in CT%s without replacing application data...\n' "$CTID"
  pct push "$CTID" "${ASSET_DIR}/docker-compose.yml" "${APP_DIR}/docker-compose.yml" --perms 0644
  pct push "$CTID" "${ASSET_DIR}/docker-compose.nvidia.yml" "${APP_DIR}/docker-compose.nvidia.yml" --perms 0644
  pct push "$CTID" "${ASSET_DIR}/docker-compose.amd.yml" "${APP_DIR}/docker-compose.amd.yml" --perms 0644
  pct push "$CTID" "${ASSET_DIR}/configure-media-stack.sh" "${APP_DIR}/configure-media-stack.sh" --perms 0755
  pct push "$CTID" "${ASSET_DIR}/verify-media-stack.sh" "${APP_DIR}/verify-media-stack.sh" --perms 0755
  pct push "$CTID" "${ASSET_DIR}/finish-media-stack-setup.sh" "${APP_DIR}/finish-media-stack-setup.sh" --perms 0755
  pct push "$CTID" "${ASSET_DIR}/fix-subtitles.sh" "${APP_DIR}/fix-subtitles.sh" --perms 0755
  pct push "$CTID" "${ASSET_DIR}/fix-subtitles.service" "${APP_DIR}/fix-subtitles.service" --perms 0644
  pct push "$CTID" "${ASSET_DIR}/fix-subtitles.timer" "${APP_DIR}/fix-subtitles.timer" --perms 0644
  pct push "$CTID" "${ASSET_DIR}/portal/index.html" "${APP_DIR}/portal/index.html" --perms 0644
  pct_bash "ln -sfn '${APP_DIR}/finish-media-stack-setup.sh' /usr/local/sbin/mediastack-finish-setup"

  if [[ "$QNAP_ENABLED" == "auto" ]]; then
    if pct_bash "findmnt -rn /mnt/qnap >/dev/null 2>&1"; then
      QNAP_ENABLED=1
    else
      QNAP_ENABLED=0
    fi
  fi
  [[ "$QNAP_ENABLED" == "0" || "$QNAP_ENABLED" == "1" ]] || die "QNAP_ENABLED must be 0 or 1."

  pct_bash "
set -Eeuo pipefail
set_key() {
  key=\"\$1\" value=\"\$2\"
  if grep -q \"^\${key}=\" '${APP_DIR}/.env'; then
    sed -i \"s|^\${key}=.*|\${key}=\${value}|\" '${APP_DIR}/.env'
  else
    printf '%s=%s\\n' \"\$key\" \"\$value\" >>'${APP_DIR}/.env'
  fi
}
set_key QNAP_ENABLED '${QNAP_ENABLED}'
set_key APPLY_TRASH '${APPLY_TRASH}'
set_key SUBTITLE_REPAIR_TIMER_ENABLED '${SUBTITLE_REPAIR_TIMER_ENABLED}'
chmod 0600 '${APP_DIR}/.env'
"

  local vpn_user vpn_password downloads_enabled=1 compose_cmd
  vpn_user="$(env_value_in_lxc NORDVPN_USER)"
  vpn_password="$(env_value_in_lxc NORDVPN_PASS)"
  if is_placeholder "$vpn_user" || is_placeholder "$vpn_password"; then
    downloads_enabled=0
  fi
  compose_cmd="$(pct_bash "cat '${APP_DIR}/.compose-command'")"
  compose_cmd="${compose_cmd// --profile vpn/}"

  if [[ "$downloads_enabled" == "1" ]]; then
    compose_cmd+=" --profile vpn"
    pct_bash "printf '%s\n' '${compose_cmd}' > '${APP_DIR}/.compose-command'"
    pct_bash "cd '${APP_DIR}' && ${compose_cmd} pull && ${compose_cmd} up -d"
  else
    printf 'VPN credentials are still placeholders; repairing core apps only.\n'
    pct_bash "printf '%s\n' '${compose_cmd}' > '${APP_DIR}/.compose-command'"
    pct_bash "cd '${APP_DIR}' && { ${compose_cmd} stop qbittorrent gluetun >/dev/null 2>&1 || true; }"
    pct_bash "cd '${APP_DIR}' && ${compose_cmd} pull && ${compose_cmd} up -d"
  fi

  pct_bash "APP_DIR='${APP_DIR}' QNAP_ENABLED='${QNAP_ENABLED}' APPLY_TRASH='${APPLY_TRASH}' DOWNLOADS_ENABLED='${downloads_enabled}' '${APP_DIR}/configure-media-stack.sh'"

  if [[ "$SUBTITLE_REPAIR_TIMER_ENABLED" == "1" ]]; then
    pct_bash "APP_DIR='${APP_DIR}' QNAP_REQUIRED='${QNAP_ENABLED}' '${APP_DIR}/fix-subtitles.sh' --install-timer --timer-only"
  fi
  pct_bash "APP_DIR='${APP_DIR}' DOWNLOADS_ENABLED='${downloads_enabled}' '${APP_DIR}/verify-media-stack.sh'"

  if [[ "$downloads_enabled" == "1" ]]; then
    printf 'CT%s is fully configured and verified.\n' "$CTID"
  else
    printf 'CT%s core apps are configured. Add NordVPN manual credentials, then run:\n' "$CTID"
    printf '  pct exec %s -- /usr/local/sbin/mediastack-finish-setup\n' "$CTID"
  fi
}

main "$@"
