#!/usr/bin/env bash
# One-command bootstrap for the Jellyfin media stack.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/masternazz/nazz-media-stack/main/install.sh)"
#
# Downloads this repository, then runs the Proxmox installer. Any arguments are
# passed straight through, e.g.:
#   bash -c "$(curl -fsSL .../install.sh)" -- --no-gui --nas-export 192.168.1.10:/volume1/media
set -Eeuo pipefail

REPO="${REPO:-masternazz/nazz-media-stack}"
REF="${REF:-main}"
ARCHIVE_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"

WORKDIR=""
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
}
trap cleanup EXIT

if [[ "$(id -u)" != "0" ]]; then
  echo 'ERROR: run this on the Proxmox host as root.' >&2
  exit 1
fi
for command_name in curl tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required.\n' "$command_name" >&2
    exit 1
  }
done

umask 077
WORKDIR="$(mktemp -d /tmp/jellyfin-stack-installer.XXXXXX)"
cd "$WORKDIR"

echo "Downloading ${REPO}@${REF} ..."
if ! curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  -o source.tar.gz "$ARCHIVE_URL"; then
  echo "ERROR: could not download ${ARCHIVE_URL}" >&2
  echo "If this repository is private, export GITHUB_TOKEN with a token that can read it." >&2
  exit 1
fi

tar -xzf source.tar.gz
cd "$(find . -maxdepth 1 -type d -name '*-*' ! -name '.' | head -n 1)"
chmod +x install-jellyfin-stack.sh jellyfin-stack/*.sh
./install-jellyfin-stack.sh "$@"
