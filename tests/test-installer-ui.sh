#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"

# shellcheck source=../install-jellyfin-stack.sh
source "${REPO_DIR}/install-jellyfin-stack.sh"

attach_ui_terminal() { :; }
use_whiptail() { return 0; }
header_info() { :; }
whiptail() { printf '%s' "$MOCK_CHOICE" >&2; }

MOCK_CHOICE=1
SETTINGS_MODE="advanced"
VERBOSE=0
prepare_terminal_ui
[[ "$SETTINGS_MODE" == "default" && "$VERBOSE" == "0" ]]

MOCK_CHOICE=2
SETTINGS_MODE="advanced"
VERBOSE=0
prepare_terminal_ui
[[ "$SETTINGS_MODE" == "default" && "$VERBOSE" == "1" ]]

MOCK_CHOICE=3
SETTINGS_MODE="default"
VERBOSE=0
prepare_terminal_ui
[[ "$SETTINGS_MODE" == "advanced" && "$VERBOSE" == "0" ]]

# Exercise the complete Advanced Settings collector with deterministic answers.
ui_input() { printf '%s\n' "${3:-}"; }
ui_required_input() {
  if [[ "$1" == "Media Storage" && -z "${3:-}" ]]; then
    printf '192.0.2.10:/media\n'
  else
    printf '%s\n' "${3:-test-value}"
  fi
}
ui_yesno() { return 1; }
ui_gpu_menu() { printf 'off\n'; }

CTID=998001
NAS_EXPORT=""
START_STACK=1
AUTO_CONFIGURE=1
collect_advanced_settings
[[ "$NAS_EXPORT" == "192.0.2.10:/media" ]]
[[ "$GPU_MODE" == "off" ]]
[[ "$START_STACK" == "0" && "$AUTO_CONFIGURE" == "0" ]]

printf 'installer UI mode tests passed\n'
