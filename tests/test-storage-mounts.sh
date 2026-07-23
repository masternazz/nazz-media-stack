#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"

# shellcheck source=../jellyfin-stack/fix-subtitles.sh
source "${REPO_DIR}/jellyfin-stack/fix-subtitles.sh"

MOCK_MOUNT_RECORD="/tmp ext4 /dev/mapper/pve-media"
timeout() {
  local seconds="$1"
  local command_name="$2"
  shift 2
  : "$seconds"
  case "$command_name" in
    findmnt) printf '%s\n' "$MOCK_MOUNT_RECORD" ;;
    stat) return 0 ;;
    *) command "$command_name" "$@" ;;
  esac
}

# A distinct local Proxmox volume is accepted for primary media.
verify_storage_mount /tmp "Primary media storage" >/dev/null

# A secondary NAS still has to be NFS.
if (verify_storage_mount /tmp "Secondary NAS" nfs >/dev/null 2>&1); then
  printf 'expected a non-NFS secondary mount to be rejected\n' >&2
  exit 1
fi

MOCK_MOUNT_RECORD="/tmp nfs4 192.0.2.10:/media"
verify_storage_mount /tmp "Primary media storage" >/dev/null
verify_storage_mount /tmp "Secondary NAS" nfs >/dev/null

# Never accept a plain directory on the container root filesystem.
MOCK_MOUNT_RECORD="/ ext4 /dev/mapper/pve-root"
if (verify_storage_mount /tmp "Primary media storage" >/dev/null 2>&1); then
  printf 'expected an underlying rootfs directory to be rejected\n' >&2
  exit 1
fi

printf 'storage mount safety tests passed\n'
