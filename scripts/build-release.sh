#!/usr/bin/env bash
# Build the exact archive consumed by the hosted Nextcloud bootstrap.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUTPUT="${1:-${REPO_DIR}/dist/jellyfin-stack-installer.tar.gz}"

if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$(pwd)/${OUTPUT}"
fi

STAGING="$(mktemp -d /tmp/jellyfin-stack-release.XXXXXX)"
cleanup() {
  if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then
    rm -rf -- "$STAGING"
  fi
}
trap cleanup EXIT

mkdir -p "$(dirname -- "$OUTPUT")" "${STAGING}/jellyfin-stack-installer/jellyfin-stack"
install -m 0755 "${REPO_DIR}/install-jellyfin-stack.sh" \
  "${STAGING}/jellyfin-stack-installer/install-jellyfin-stack.sh"
cp -a "${REPO_DIR}/jellyfin-stack/." \
  "${STAGING}/jellyfin-stack-installer/jellyfin-stack/"
find "${STAGING}/jellyfin-stack-installer/jellyfin-stack" -type f -name '*.sh' -exec chmod 0755 {} +

tar -C "$STAGING" -czf "$OUTPUT" jellyfin-stack-installer
sha256sum "$OUTPUT"
