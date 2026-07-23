#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_DIR}/jellyfin-stack/docker-compose.yml"
COMMAND_LOG="$(mktemp)"
MODE_DIR="$(mktemp -d)"

cleanup() {
  rm -f -- "$COMMAND_LOG"
  if [[ -n "$MODE_DIR" && -d "$MODE_DIR" && "$MODE_DIR" == /tmp/* ]]; then
    rm -rf -- "$MODE_DIR"
  fi
}
trap cleanup EXIT

# Gluetun and qBittorrent are the complete VPN boundary. Docker Compose must
# leave both disabled by default while every other service remains unprofiled.
profiled_services="$(
  awk '
    /^  [A-Za-z0-9_-]+:$/ {
      service = $1
      sub(/:$/, "", service)
      next
    }
    /^    profiles:$/ {
      getline
      if ($0 ~ /^      - vpn$/) {
        print service
      }
    }
  ' "$COMPOSE_FILE" | sort
)"
[[ "$profiled_services" == $'gluetun\nqbittorrent' ]]

service_count="$(
  awk '
    /^services:$/ { in_services = 1; next }
    in_services && /^[^[:space:]]/ { in_services = 0 }
    in_services && /^  [A-Za-z0-9_-]+:$/ { count++ }
    END { print count + 0 }
  ' "$COMPOSE_FILE"
)"
[[ "$service_count" == "20" ]]

# shellcheck source=../install-jellyfin-stack.sh
source "${REPO_DIR}/install-jellyfin-stack.sh"

pct_bash() {
  printf '%s\n' "$1" >>"$COMMAND_LOG"
}
compose_command() {
  printf 'docker compose -f docker-compose.yml'
}

APP_DIR="/opt/mediastack"
START_STACK=1

ENV_HAS_PLACEHOLDER=1
start_stack >/dev/null
grep -Fq "docker compose -f docker-compose.yml pull" "$COMMAND_LOG"
grep -Fq "docker compose -f docker-compose.yml up -d" "$COMMAND_LOG"
if grep -Fq -- "--profile vpn" "$COMMAND_LOG"; then
  printf 'no-VPN startup unexpectedly enabled the vpn profile\n' >&2
  exit 1
fi
grep -Fq '${compose_cmd} stop qbittorrent gluetun' "${REPO_DIR}/repair-existing.sh"
grep -Fq 'must remain stopped until VPN credentials are configured' \
  "${REPO_DIR}/jellyfin-stack/verify-media-stack.sh"
grep -Fq '"$DOWNLOADS_ENABLED" == "0" && "$container" == "qbittorrent"' \
  "${REPO_DIR}/jellyfin-stack/fix-subtitles.sh"

: >"$COMMAND_LOG"
ENV_HAS_PLACEHOLDER=0
start_stack >/dev/null
grep -Fq "docker compose -f docker-compose.yml --profile vpn pull" "$COMMAND_LOG"
grep -Fq "docker compose -f docker-compose.yml --profile vpn up -d" "$COMMAND_LOG"

# The subtitle timer must not auto-create qBittorrent while VPN mode is off.
(
  # shellcheck source=../jellyfin-stack/fix-subtitles.sh
  source "${REPO_DIR}/jellyfin-stack/fix-subtitles.sh"
  APP_DIR="$MODE_DIR"
  printf '%s\n' 'docker compose -f docker-compose.yml' >"${APP_DIR}/.compose-command"
  DOWNLOADS_ENABLED=auto
  resolve_downloads_mode
  [[ "$DOWNLOADS_ENABLED" == "0" ]]

  printf '%s\n' 'docker compose -f docker-compose.yml --profile vpn' >"${APP_DIR}/.compose-command"
  DOWNLOADS_ENABLED=auto
  resolve_downloads_mode
  [[ "$DOWNLOADS_ENABLED" == "1" ]]
)

printf 'no-VPN compose startup tests passed\n'
