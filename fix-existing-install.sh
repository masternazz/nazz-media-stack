#!/usr/bin/env bash
# Download the current GitHub version and repair an existing media-stack LXC.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/masternazz/nazz-media-stack/main/fix-existing-install.sh)" -- 128
set -Eeuo pipefail
IFS=$'\n\t'

REPO="${REPO:-masternazz/nazz-media-stack}"
REF="${REF:-main}"
CTID="${1:-}"
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"
WORKDIR=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

cleanup() {
  if [[ -n "$WORKDIR" && -d "$WORKDIR" && "$WORKDIR" == /tmp/mediastack-fix.* ]]; then
    rm -rf -- "$WORKDIR"
  fi
}
trap cleanup EXIT

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" == "0" ]] || die "Run this on the Proxmox host as root."
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Usage: fix-existing-install.sh CTID"
command -v pct >/dev/null 2>&1 || die "pct is required; run this on Proxmox VE."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar >/dev/null 2>&1 || die "tar is required."

if [[ -f "${SCRIPT_DIR}/repair-existing.sh" &&
      -f "${SCRIPT_DIR}/jellyfin-stack/docker-compose.yml" ]]; then
  chmod +x "${SCRIPT_DIR}/repair-existing.sh" "${SCRIPT_DIR}"/jellyfin-stack/*.sh
  exec "${SCRIPT_DIR}/repair-existing.sh" "$@"
fi

umask 077
WORKDIR="$(mktemp -d /tmp/mediastack-fix.XXXXXX)"
curl_args=(
  --proto '=https'
  --tlsv1.2
  -fsSL
  --retry 3
  --connect-timeout 15
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

printf 'Downloading %s@%s repair assets...\n' "$REPO" "$REF"
curl "${curl_args[@]}" -o "${WORKDIR}/source.tar.gz" "$ARCHIVE_URL" ||
  die "Could not download ${ARCHIVE_URL}. If the repository is private, export GITHUB_TOKEN first."
tar -xzf "${WORKDIR}/source.tar.gz" -C "$WORKDIR"

SOURCE_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d -name '*-*' -print -quit)"
[[ -n "$SOURCE_DIR" && -f "${SOURCE_DIR}/repair-existing.sh" ]] ||
  die "The downloaded repository does not contain repair-existing.sh."

chmod +x "${SOURCE_DIR}/repair-existing.sh" "${SOURCE_DIR}"/jellyfin-stack/*.sh
"${SOURCE_DIR}/repair-existing.sh" "$@"
