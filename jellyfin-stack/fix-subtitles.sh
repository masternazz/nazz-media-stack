#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/mediastack}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
BAZARR_CONFIG="${BAZARR_CONFIG:-${APP_DIR}/config/bazarr/config/config.yaml}"
BAZARR_URL="${BAZARR_URL:-http://127.0.0.1:6767}"
JELLYFIN_URL="${JELLYFIN_URL:-http://127.0.0.1:8096}"
JELLYFIN_API_KEY_FILE="${JELLYFIN_API_KEY_FILE:-${APP_DIR}/.jellyfin-api-key}"
QNAP_REQUIRED="${QNAP_REQUIRED:-1}"
PROVIDER_CHANGES=1
DRY_RUN=0
INSTALL_TIMER=0
TIMER_ONLY=0
STATUS_ONLY=0
TASK_WAIT_SECONDS="${TASK_WAIT_SECONDS:-3600}"
SKIP_BAZARR_TASKS=0
LOCK_FILE="${LOCK_FILE:-/run/lock/mediastack-fix-subtitles.lock}"

BAZARR_API_KEY=""
ENGLISH_PROFILE_ID=""
MEDIA_CATALOG_COUNT=0
MEDIA_VISIBLE_COUNT=0
MEDIA_MISSING_COUNT=0
declare -A MEDIA_DIRS=()
declare -A MEDIA_FILES=()

info() { printf '\033[1;34m[subtitle-repair]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[subtitle-repair] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[subtitle-repair] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: fix-subtitles.sh [options]

Run this as root inside the media-stack LXC. It refuses to operate on an
underlying directory when a required media mount is absent.

Options:
  --dry-run                 Inspect and print changes without applying them
  --skip-qnap               Treat /mnt/qnap as intentionally unavailable
  --require-qnap            Require /mnt/qnap to be NFS (default)
  --enable-free-providers   Preserve providers and add safe no-auth providers
                            that this Bazarr build supports (default)
  --no-provider-changes     Check providers without changing them
  --install-timer           Install and enable the bundled systemd timer
  --timer-only              With --install-timer, exit after installing it
  --status                  Show Bazarr background-job progress without changes
  -h, --help                Show this help

The repair selectively recreates stale media bind mounts, repairs sidecar
directory writes and read-only access to cataloged video files, asks Bazarr to
sync/index/search, and asks Jellyfin to refresh its libraries. It never grants
video-file write access or performs a recursive chmod. Secrets are read locally
and are never printed.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --skip-qnap) QNAP_REQUIRED=0; shift ;;
      --require-qnap) QNAP_REQUIRED=1; shift ;;
      --enable-free-providers) PROVIDER_CHANGES=1; shift ;;
      --no-provider-changes) PROVIDER_CHANGES=0; shift ;;
      --install-timer) INSTALL_TIMER=1; shift ;;
      --timer-only) TIMER_ONLY=1; shift ;;
      --status) STATUS_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ "$TIMER_ONLY" == "0" || "$INSTALL_TIMER" == "1" ]] || die "--timer-only requires --install-timer."
  [[ "$STATUS_ONLY" == "0" || ( "$INSTALL_TIMER" == "0" && "$TIMER_ONLY" == "0" ) ]] || \
    die "--status cannot be combined with timer installation."
}

env_value() {
  local key="$1" default="${2:-}" value=""
  [[ -f "$ENV_FILE" ]] || { printf '%s\n' "$default"; return; }
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$ENV_FILE")"
  printf '%s\n' "${value:-$default}"
}

preflight() {
  [[ "$(id -u)" == "0" ]] || die "Run this repair as root inside the media-stack LXC."
  [[ -d "$APP_DIR" ]] || die "Media-stack directory is missing: ${APP_DIR}"
  [[ -f "$ENV_FILE" ]] || die "Media-stack environment file is missing: ${ENV_FILE}"
  local command_name
  for command_name in curl docker findmnt flock jq python3 realpath setpriv stat timeout; do
    command -v "$command_name" >/dev/null 2>&1 || die "${command_name} is required."
  done
  [[ "$TASK_WAIT_SECONDS" =~ ^[0-9]+$ && "$TASK_WAIT_SECONDS" -ge 30 ]] || \
    die "TASK_WAIT_SECONDS must be an integer of at least 30 seconds."
  [[ "$QNAP_REQUIRED" == "0" || "$QNAP_REQUIRED" == "1" ]] || die "QNAP_REQUIRED must be 0 or 1."
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another subtitle repair is already running (lock: ${LOCK_FILE})."
}

install_timer() {
  local source_dir service_src timer_src defaults_file
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  service_src="${source_dir}/fix-subtitles.service"
  timer_src="${source_dir}/fix-subtitles.timer"
  defaults_file="/etc/default/mediastack-subtitles"
  [[ -f "$service_src" && -f "$timer_src" ]] || \
    die "The bundled fix-subtitles.service and fix-subtitles.timer must be next to this script."

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] install systemd service from ${service_src}"
    info "[dry-run] install systemd timer from ${timer_src}"
    info "[dry-run] write ${defaults_file} with APP_DIR and QNAP_REQUIRED (no secrets)"
    info "[dry-run] systemctl enable --now fix-subtitles.timer"
    return
  fi

  [[ "$APP_DIR" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "APP_DIR contains characters unsafe for the systemd environment file."
  install -m 0644 "$service_src" /etc/systemd/system/fix-subtitles.service
  install -m 0644 "$timer_src" /etc/systemd/system/fix-subtitles.timer
  {
    printf 'APP_DIR=%s\n' "$APP_DIR"
    printf 'QNAP_REQUIRED=%s\n' "$QNAP_REQUIRED"
  } >"$defaults_file"
  chmod 0644 "$defaults_file"
  systemctl daemon-reload
  systemctl enable --now fix-subtitles.timer >/dev/null
  info "Installed and enabled fix-subtitles.timer"
}

verify_storage_mount() {
  local path="$1" label="$2" required_type="${3:-any}"
  local target="" fstype="" source="" records="" selected="" nearest=""
  [[ -d "$path" ]] || die "${label} path is missing: ${path}"
  records="$(timeout 10 findmnt -rn -T "$path" -o TARGET,FSTYPE,SOURCE || true)"
  [[ -n "$records" ]] || \
    die "Could not inspect ${label} mount at ${path}."
  selected="$(awk -v path="$path" '$1 == path { record = $0 } END { print record }' <<<"$records")"
  nearest="$(awk 'NF { record = $0 } END { print record }' <<<"$records")"
  if [[ -z "$selected" ]]; then
    IFS=' ' read -r target fstype source <<<"$nearest"
    die "${path} is not a mount point; refusing to use its underlying directory (nearest mount: ${target:-unknown})."
  fi
  IFS=' ' read -r target fstype source <<<"$selected"
  if [[ "$required_type" == "nfs" && "$fstype" != "nfs" && "$fstype" != "nfs4" ]]; then
    die "${path} is ${fstype:-unknown}, not NFS; refusing to use it for ${label}."
  fi
  timeout 10 stat -L -- "$path" >/dev/null || die "${label} mount is present but unresponsive: ${path}"
  info "${label} is an active ${fstype} mount (${source})"
}

load_compose_command() {
  local command_line=""
  if [[ -s "${APP_DIR}/.compose-command" ]]; then
    command_line="$(head -n 1 "${APP_DIR}/.compose-command")"
  else
    command_line="docker compose -f docker-compose.yml"
    warn "${APP_DIR}/.compose-command is missing; using the base Compose file."
  fi
  local old_ifs="$IFS"
  IFS=' ' read -r -a COMPOSE_COMMAND <<<"$command_line"
  IFS="$old_ifs"
  [[ "${COMPOSE_COMMAND[0]:-}" == "docker" && "${COMPOSE_COMMAND[1]:-}" == "compose" ]] || \
    die "Unexpected command in ${APP_DIR}/.compose-command."
}

mount_identity() {
  timeout 10 stat -Lc '%d:%i' -- "$1" 2>/dev/null
}

container_mount_identity() {
  local container="$1" path="$2"
  timeout 10 docker exec "$container" stat -Lc '%d:%i' -- "$path" 2>/dev/null
}

inspect_bind_mount() {
  local container="$1" source="$2" destination="$3"
  local actual_source="" host_identity="" container_identity=""

  if ! docker inspect "$container" >/dev/null 2>&1; then
    warn "${container} is missing and must be recreated."
    return 1
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
    warn "${container} is not running and must be recreated."
    return 1
  fi
  actual_source="$(docker inspect "$container" | jq -r --arg destination "$destination" \
    '.[0].Mounts[]? | select(.Type == "bind" and .Destination == $destination) | .Source' | head -n 1)"
  if [[ -z "$actual_source" || "$(realpath -m -- "$actual_source")" != "$(realpath -m -- "$source")" ]]; then
    warn "${container}:${destination} is not bound from ${source}."
    return 1
  fi

  host_identity="$(mount_identity "$source" || true)"
  container_identity="$(container_mount_identity "$container" "$destination" || true)"
  if [[ -z "$host_identity" || "$host_identity" != "$container_identity" ]]; then
    warn "${container}:${destination} holds a stale filesystem view of ${source}."
    return 1
  fi
  return 0
}

verify_and_repair_container_binds() {
  local -a bind_specs=(
    'qbittorrent|/mnt/nas|/data' 'qbittorrent|/mnt/qnap|/qnap'
    'sonarr|/mnt/nas|/data' 'sonarr|/mnt/qnap|/qnap'
    'radarr|/mnt/nas|/data' 'radarr|/mnt/qnap|/qnap'
    'bazarr|/mnt/nas|/data' 'bazarr|/mnt/qnap|/qnap'
    'lidarr|/mnt/nas|/data' 'lidarr|/mnt/qnap|/qnap'
    'mylar|/mnt/nas|/data' 'mylar|/mnt/qnap|/qnap'
    'jellyfin|/mnt/nas/media|/media' 'jellyfin|/mnt/qnap/media|/qnap_media'
    'jellyfin|/mnt/nas/jellyfin-cache|/cache'
  )
  local -A recreate=()
  local spec container source destination
  for spec in "${bind_specs[@]}"; do
    IFS='|' read -r container source destination <<<"$spec"
    if [[ "$QNAP_REQUIRED" == "0" && "$source" == /mnt/qnap* ]]; then
      continue
    fi
    if ! inspect_bind_mount "$container" "$source" "$destination"; then
      recreate["$container"]=1
    fi
  done

  if (( ${#recreate[@]} == 0 )); then
    info "Docker media bind mounts point at the current NFS filesystems"
    return
  fi

  local -a containers=()
  mapfile -t containers < <(printf '%s\n' "${!recreate[@]}" | sort)
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would force-recreate: ${containers[*]}"
    return
  fi

  load_compose_command
  info "Force-recreating containers with stale or missing binds: ${containers[*]}"
  (cd "$APP_DIR" && "${COMPOSE_COMMAND[@]}" up -d --no-deps --force-recreate "${containers[@]}")

  local attempt state
  for container in "${containers[@]}"; do
    state=""
    for attempt in $(seq 1 60); do
      state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
      [[ "$state" == "true" ]] && break
      sleep 2
    done
    [[ "$state" == "true" ]] || die "${container} did not become ready after recreation."
  done

  for spec in "${bind_specs[@]}"; do
    IFS='|' read -r container source destination <<<"$spec"
    [[ "$QNAP_REQUIRED" == "0" && "$source" == /mnt/qnap* ]] && continue
    inspect_bind_mount "$container" "$source" "$destination" || \
      die "${container}:${destination} is still stale after recreation."
  done
  info "Recreated containers now point at the current NFS filesystems"
}

wait_for_bazarr() {
  local attempt
  for attempt in $(seq 1 60); do
    curl -fsS --max-time 5 -o /dev/null "${BAZARR_URL}/" && return
    sleep 2
  done
  die "Bazarr did not become reachable at ${BAZARR_URL}."
}

read_bazarr_api_key() {
  [[ -r "$BAZARR_CONFIG" ]] || die "Bazarr config is not readable: ${BAZARR_CONFIG}"
  BAZARR_API_KEY="$(awk '$1 == "apikey:" { key = $2; gsub(/["\047]/, "", key); print key; exit }' "$BAZARR_CONFIG")"
  [[ "$BAZARR_API_KEY" =~ ^[A-Za-z0-9._-]{16,}$ ]] || die "Could not parse Bazarr's API key from its local config."
  info "Read Bazarr API key from local protected configuration"
}

bazarr_get() {
  local endpoint="$1"
  curl -fsS --max-time 30 -H "X-Api-Key: ${BAZARR_API_KEY}" "${BAZARR_URL}/api/${endpoint}"
}

bazarr_get_query() {
  local endpoint="$1"
  shift
  curl -fsS --max-time 60 --get -H "X-Api-Key: ${BAZARR_API_KEY}" "$@" "${BAZARR_URL}/api/${endpoint}"
}

verify_bazarr_connections() {
  local settings
  settings="$(bazarr_get system/settings)" || die "Bazarr API authentication failed."
  jq -e '
    .general.use_sonarr == true and
    .general.use_radarr == true and
    .sonarr.ip == "sonarr" and (.sonarr.port | tonumber) == 8989 and
    .radarr.ip == "radarr" and (.radarr.port | tonumber) == 7878
  ' <<<"$settings" >/dev/null || die "Bazarr is not connected to the expected Sonarr/Radarr container endpoints."
  info "Bazarr API and Sonarr/Radarr connections pass"
}

post_provider_list() {
  local providers_json="$1" provider
  local -a curl_args=(
    -fsS --max-time 60 -X POST
    -H "X-Api-Key: ${BAZARR_API_KEY}"
  )
  while IFS= read -r provider; do
    curl_args+=(--data-urlencode "settings-general-enabled_providers=${provider}")
  done < <(jq -r '.[]' <<<"$providers_json")
  curl "${curl_args[@]}" "${BAZARR_URL}/api/system/settings" >/dev/null
}

configure_and_verify_providers() {
  local settings current desired provider_status validated provider
  local -a candidates=(subf2m podnapisi tvsubtitles supersubtitles)
  settings="$(bazarr_get system/settings)"
  current="$(jq -c '.general.enabled_providers // [] | map(select(type == "string")) | unique' <<<"$settings")"
  info "Bazarr currently has $(jq 'length' <<<"$current") configured provider(s)"

  if [[ "$PROVIDER_CHANGES" == "0" ]]; then
    [[ "$(jq 'length' <<<"$current")" -gt 0 ]] || warn "Bazarr has no enabled subtitle providers."
    provider_status="$(bazarr_get providers)"
    info "Bazarr recognizes $(jq '.data | length' <<<"$provider_status") configured provider(s)"
    return
  fi

  desired="$(jq -cn --argjson current "$current" --argjson additions \
    '["subf2m","podnapisi","tvsubtitles","supersubtitles"]' '$current + ($additions - $current)')"
  if [[ "$desired" == "$current" ]]; then
    info "Safe no-auth provider candidates are already configured"
  elif [[ "$DRY_RUN" == "1" ]]; then
    for provider in "${candidates[@]}"; do
      jq -e --arg provider "$provider" 'index($provider)' <<<"$current" >/dev/null || \
        info "[dry-run] would request no-auth provider: ${provider}"
    done
  else
    post_provider_list "$desired"
    info "Requested safe no-auth providers while preserving existing providers"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    provider_status="$(bazarr_get providers)"
    info "Bazarr currently recognizes $(jq '.data | length' <<<"$provider_status") configured provider(s)"
    return
  fi

  settings="$(bazarr_get system/settings)"
  desired="$(jq -c '.general.enabled_providers // [] | map(select(type == "string")) | unique' <<<"$settings")"
  provider_status="$(bazarr_get providers)"
  validated="$desired"
  for provider in "${candidates[@]}"; do
    if jq -e --arg provider "$provider" 'index($provider)' <<<"$current" >/dev/null; then
      continue
    fi
    if ! jq -e --arg provider "$provider" '.data | map(.name) | index($provider)' <<<"$provider_status" >/dev/null; then
      warn "${provider} is unavailable in this Bazarr build; removing only that newly added candidate."
      validated="$(jq -c --arg provider "$provider" 'map(select(. != $provider))' <<<"$validated")"
    fi
  done
  if [[ "$validated" != "$desired" ]]; then
    post_provider_list "$validated"
  fi

  settings="$(bazarr_get system/settings)"
  jq -e --argjson expected "$validated" \
    '(.general.enabled_providers // [] | sort) == ($expected | sort)' <<<"$settings" >/dev/null || \
    die "Bazarr did not retain the validated provider list."
  [[ "$(jq 'length' <<<"$validated")" -gt 0 ]] || die "Bazarr has no supported enabled providers."
  info "Bazarr provider settings validate through the API"
}

configure_and_verify_analyzer() {
  local settings current
  settings="$(bazarr_get system/settings)"
  current="$(jq -r '.general.embedded_subtitles_parser // empty' <<<"$settings")"
  if [[ "$current" == "mediainfo" ]]; then
    info "Bazarr embedded-subtitle analyzer is MediaInfo"
    return
  fi
  if ! timeout 20 docker exec bazarr mediainfo --Version >/dev/null 2>&1; then
    warn "Bazarr MediaInfo is unavailable; preserving embedded-subtitle analyzer: ${current:-unset}"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would switch Bazarr embedded-subtitle analyzer from ${current:-unset} to MediaInfo"
    return
  fi
  curl -fsS --max-time 60 -X POST -H "X-Api-Key: ${BAZARR_API_KEY}" \
    --data-urlencode 'settings-general-embedded_subtitles_parser=mediainfo' \
    "${BAZARR_URL}/api/system/settings" >/dev/null
  settings="$(bazarr_get system/settings)"
  [[ "$(jq -r '.general.embedded_subtitles_parser // empty' <<<"$settings")" == "mediainfo" ]] || \
    die "Bazarr did not retain the MediaInfo embedded-subtitle analyzer setting."
  info "Switched Bazarr embedded-subtitle analyzer to MediaInfo after live FFprobe failures"
}

verify_bazarr_languages() {
  local languages profiles enabled_names enabled_count profile_count
  languages="$(bazarr_get system/languages)"
  profiles="$(bazarr_get system/languages/profiles)"
  enabled_count="$(jq '[.[] | select(.enabled == true)] | length' <<<"$languages")"
  profile_count="$(jq 'length' <<<"$profiles")"
  enabled_names="$(jq -r '[.[] | select(.enabled == true) | .name] | join(", ")' <<<"$languages")"
  [[ "$enabled_count" -gt 0 ]] || die "Bazarr has no enabled subtitle languages."
  [[ "$profile_count" -gt 0 ]] || warn "Bazarr has no language profiles; automatic searches cannot choose wanted languages."
  if ! jq -e '.[] | select(.enabled == true and .code2 == "en")' <<<"$languages" >/dev/null; then
    warn "English is not enabled in Bazarr. Language/profile policy is intentionally left unchanged."
  fi
  ENGLISH_PROFILE_ID="$(jq -r '
    [ .[] | select(any(.items[]?; .language == "en")) ] as $english
    | (($english | map(select((.name // "" | ascii_downcase) == "english"))) + $english)
    | .[0].profileId // empty
  ' <<<"$profiles")"
  [[ -n "$ENGLISH_PROFILE_ID" ]] || warn "Bazarr has no English language profile for unassigned catalog items."
  info "Bazarr enabled languages (${enabled_count}): ${enabled_names}; language profiles: ${profile_count}"
}

assign_unprofiled_english() {
  local series movies unassigned_series unassigned_movies series_count movie_count id
  series="$(bazarr_get_query series --data-urlencode 'length=-1')"
  movies="$(bazarr_get_query movies --data-urlencode 'length=-1')"
  unassigned_series="$(jq -c '[.data[] | select(.profileId == null) | .sonarrSeriesId]' <<<"$series")"
  unassigned_movies="$(jq -c '[.data[] | select(.profileId == null) | .radarrId]' <<<"$movies")"
  series_count="$(jq 'length' <<<"$unassigned_series")"
  movie_count="$(jq 'length' <<<"$unassigned_movies")"
  (( series_count > 0 || movie_count > 0 )) || { info "All Bazarr series and movies have language profiles"; return; }
  if [[ -z "$ENGLISH_PROFILE_ID" ]]; then
    warn "Cannot assign ${series_count} series and ${movie_count} movies without an English profile."
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would assign English profile ${ENGLISH_PROFILE_ID} to ${series_count} series and ${movie_count} movies without profiles"
    return
  fi

  if (( series_count > 0 )); then
    local -a series_args=(-fsS --max-time 60 -X POST -H "X-Api-Key: ${BAZARR_API_KEY}")
    while IFS= read -r id; do
      series_args+=(--data-urlencode "seriesid=${id}" --data-urlencode "profileid=${ENGLISH_PROFILE_ID}")
    done < <(jq -r '.[]' <<<"$unassigned_series")
    curl "${series_args[@]}" "${BAZARR_URL}/api/series" >/dev/null
  fi
  if (( movie_count > 0 )); then
    local -a movie_args=(-fsS --max-time 60 -X POST -H "X-Api-Key: ${BAZARR_API_KEY}")
    while IFS= read -r id; do
      movie_args+=(--data-urlencode "radarrid=${id}" --data-urlencode "profileid=${ENGLISH_PROFILE_ID}")
    done < <(jq -r '.[]' <<<"$unassigned_movies")
    curl "${movie_args[@]}" "${BAZARR_URL}/api/movies" >/dev/null
  fi
  info "Assigned English profile ${ENGLISH_PROFILE_ID} to ${series_count} series and ${movie_count} movies that had no profile"
}

run_bazarr_task() {
  local task_id="$1" description="$2" tasks running elapsed=0 observed=0
  tasks="$(bazarr_get system/tasks)"
  jq -e --arg task_id "$task_id" '.data[] | select(.job_id == $task_id)' <<<"$tasks" >/dev/null || \
    die "Bazarr does not expose the '${task_id}' task required for ${description}."
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would run Bazarr task: ${description} (${task_id})"
    return
  fi

  info "Starting Bazarr task: ${description}"
  curl -fsS --max-time 30 -X POST --get -H "X-Api-Key: ${BAZARR_API_KEY}" \
    --data-urlencode "taskid=${task_id}" "${BAZARR_URL}/api/system/tasks" >/dev/null
  sleep 2
  while (( elapsed < TASK_WAIT_SECONDS )); do
    tasks="$(bazarr_get system/tasks)" || { warn "Could not poll Bazarr task ${task_id}; continuing."; return; }
    running="$(jq -r --arg task_id "$task_id" '.data[] | select(.job_id == $task_id) | .job_running' <<<"$tasks")"
    if [[ "$running" == "true" ]]; then
      observed=1
    elif [[ "$observed" == "1" || "$elapsed" -ge 4 ]]; then
      info "Bazarr task completed or returned to idle: ${description}"
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  die "Timed out waiting for Bazarr task: ${description}"
}

detect_active_bazarr_jobs() {
  local jobs active count summary
  jobs="$(bazarr_get system/jobs)" || die "Could not inspect Bazarr's background job queue."
  active="$(jq -c '[.data[] | select(.status == "pending" or .status == "running")]' <<<"$jobs")"
  count="$(jq 'length' <<<"$active")"
  (( count > 0 )) || { info "Bazarr background job queue is idle"; return; }
  summary="$(jq -r 'map("\(.job_name) [\(.status), \(.progress_value // 0)/\(.progress_max // 0)]") | join(", ")' <<<"$active")"
  SKIP_BAZARR_TASKS=1
  warn "Bazarr already has ${count} active or pending background job(s): ${summary}"
  warn "No duplicate sync, index, or search jobs will be queued by this run."
}

container_path_to_host() {
  local container_path="$1" host_path root real_path
  case "$container_path" in
    /data) host_path=/mnt/nas; root=/mnt/nas ;;
    /data/*) host_path="/mnt/nas/${container_path#/data/}"; root=/mnt/nas ;;
    /qnap) host_path=/mnt/qnap; root=/mnt/qnap ;;
    /qnap/*)
      [[ "$QNAP_REQUIRED" == "1" ]] || return 1
      host_path="/mnt/qnap/${container_path#/qnap/}"; root=/mnt/qnap
      ;;
    *) return 1 ;;
  esac
  real_path="$(timeout 10 realpath -e -- "$host_path" 2>/dev/null || true)"
  [[ -n "$real_path" && ( "$real_path" == "$root" || "$real_path" == "$root/"* ) ]] || return 1
  printf '%s\n' "$real_path"
}

catalog_media_path() {
  local path="$1" kind="$2" directory="" host_directory="" host_file=""
  [[ -n "$path" && "$path" != "null" ]] || return
  MEDIA_CATALOG_COUNT=$((MEDIA_CATALOG_COUNT + 1))

  case "$path" in
    /data|/data/*|/qnap|/qnap/*) ;;
    *) warn "Bazarr ${kind} path is outside its shared media mounts: ${path}"; MEDIA_MISSING_COUNT=$((MEDIA_MISSING_COUNT + 1)); return ;;
  esac
  if [[ "$QNAP_REQUIRED" == "0" && "$path" == /qnap* ]]; then
    warn "Skipping intentionally disabled QNAP ${kind} path: ${path}"
    return
  fi

  if [[ "$kind" == "series" ]]; then
    directory="$path"
  else
    directory="${path%/*}"
  fi

  host_directory="$(container_path_to_host "$directory" || true)"
  if [[ -z "$host_directory" ]]; then
    warn "Refusing to repair an unresolved or escaping path: ${directory}"
    MEDIA_MISSING_COUNT=$((MEDIA_MISSING_COUNT + 1))
    return
  fi
  MEDIA_DIRS["$directory"]="$host_directory"
  if [[ "$kind" != "series" ]]; then
    host_file="$(container_path_to_host "$path" || true)"
    [[ -n "$host_file" ]] && MEDIA_FILES["$path"]="$host_file"
  fi
}

validate_bazarr_media_directories() {
  local directory
  for directory in "${!MEDIA_DIRS[@]}"; do
    if timeout 10 docker exec bazarr test -d "$directory"; then
      MEDIA_VISIBLE_COUNT=$((MEDIA_VISIBLE_COUNT + 1))
      continue
    fi
    warn "Bazarr cannot see subtitle directory: ${directory}"
    MEDIA_MISSING_COUNT=$((MEDIA_MISSING_COUNT + 1))
    unset 'MEDIA_DIRS[$directory]'
  done

  if (( MEDIA_CATALOG_COUNT > 0 && MEDIA_VISIBLE_COUNT == 0 )); then
    die "Bazarr cannot see any directories for its ${MEDIA_CATALOG_COUNT} catalog entries."
  fi
}

collect_bazarr_media_directories() {
  local series movies episodes series_id path unassigned_series unassigned_movies
  series="$(bazarr_get_query series --data-urlencode 'length=-1')"
  movies="$(bazarr_get_query movies --data-urlencode 'length=-1')"
  unassigned_series="$(jq '[.data[] | select(.profileId == null)] | length' <<<"$series")"
  unassigned_movies="$(jq '[.data[] | select(.profileId == null)] | length' <<<"$movies")"
  [[ "$unassigned_series" == "0" ]] || warn "${unassigned_series} Bazarr series have no language profile and will not receive automatic subtitles."
  [[ "$unassigned_movies" == "0" ]] || warn "${unassigned_movies} Bazarr movies have no language profile and will not receive automatic subtitles."

  while IFS= read -r path; do
    catalog_media_path "$path" "series"
  done < <(jq -r '.data[] | .path // empty' <<<"$series")

  while IFS= read -r series_id; do
    episodes="$(bazarr_get_query episodes --data-urlencode "seriesid[]=${series_id}")"
    while IFS= read -r path; do
      catalog_media_path "$path" "episode"
    done < <(jq -r '.data[] | .path // empty' <<<"$episodes")
  done < <(jq -r '.data[] | .sonarrSeriesId' <<<"$series")

  while IFS= read -r path; do
    catalog_media_path "$path" "movie"
  done < <(jq -r '.data[] | .path // empty' <<<"$movies")

  validate_bazarr_media_directories
  info "Bazarr path check: ${MEDIA_VISIBLE_COUNT} subtitle directories visible for ${MEDIA_CATALOG_COUNT} catalog entries"
  [[ "$MEDIA_MISSING_COUNT" == "0" ]] || warn "${MEDIA_MISSING_COUNT} stale or inaccessible Bazarr director$( [[ "$MEDIA_MISSING_COUNT" == "1" ]] && printf 'y' || printf 'ies' ) need review in Sonarr/Radarr."
}

directory_writable_by_bazarr() {
  local directory="$1" puid="$2" pgid="$3"
  timeout 10 docker exec --user "${puid}:${pgid}" bazarr sh -c 'test -d "$1" && test -w "$1" && test -x "$1"' sh "$directory"
}

repair_subtitle_directory_permissions() {
  local puid pgid directory host_directory owner group repaired=0 failed=0
  puid="$(env_value PUID 65534)"
  pgid="$(env_value PGID 65534)"
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || die "PUID and PGID in ${ENV_FILE} must be numeric."

  for directory in "${!MEDIA_DIRS[@]}"; do
    host_directory="${MEDIA_DIRS[$directory]}"
    if directory_writable_by_bazarr "$directory" "$puid" "$pgid"; then
      continue
    fi
    owner="$(stat -Lc '%u' -- "$host_directory")"
    group="$(stat -Lc '%g' -- "$host_directory")"
    if [[ "$DRY_RUN" == "1" ]]; then
      info "[dry-run] would repair directory only: ${host_directory}"
      continue
    fi

    info "Repairing directory write access (not media files): ${host_directory}"
    if [[ "$owner" == "$puid" ]]; then
      setpriv --reuid "$puid" --regid "$pgid" --clear-groups chmod u+rwx -- "$host_directory" || true
    elif [[ "$group" == "$pgid" ]]; then
      setpriv --reuid "$owner" --regid "$pgid" --clear-groups chmod g+rwx -- "$host_directory" || true
    elif setpriv --reuid "$owner" --regid "$pgid" --clear-groups chgrp "$pgid" -- "$host_directory"; then
      setpriv --reuid "$owner" --regid "$pgid" --clear-groups chmod g+rwx -- "$host_directory" || true
    else
      warn "Could not assign group ${pgid} to ${host_directory}; no world-writable fallback was used."
    fi

    if directory_writable_by_bazarr "$directory" "$puid" "$pgid"; then
      repaired=$((repaired + 1))
    else
      warn "Bazarr still cannot write directory: ${directory}"
      failed=$((failed + 1))
    fi
  done
  [[ "$failed" == "0" ]] || die "${failed} subtitle director$( [[ "$failed" == "1" ]] && printf 'y' || printf 'ies' ) remain unwritable."
  info "Subtitle directory permissions pass; repaired ${repaired} director$( [[ "$repaired" == "1" ]] && printf 'y' || printf 'ies' )"
}

file_readable_by_bazarr() {
  local host_file="$1" puid="$2" pgid="$3"
  timeout 10 setpriv --reuid "$puid" --regid "$pgid" --clear-groups test -r "$host_file"
}

repair_media_file_read_permissions() {
  local puid pgid container_file host_file owner group repaired=0 failed=0
  puid="$(env_value PUID 65534)"
  pgid="$(env_value PGID 65534)"
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || die "PUID and PGID in ${ENV_FILE} must be numeric."

  for container_file in "${!MEDIA_FILES[@]}"; do
    host_file="${MEDIA_FILES[$container_file]}"
    if file_readable_by_bazarr "$host_file" "$puid" "$pgid"; then
      continue
    fi
    repaired=$((repaired + 1))
    [[ "$DRY_RUN" == "1" ]] && continue

    owner="$(stat -Lc '%u' -- "$host_file")"
    group="$(stat -Lc '%g' -- "$host_file")"
    setpriv --reuid "$owner" --regid "$group" --clear-groups chmod a+r -- "$host_file" || true
    if ! file_readable_by_bazarr "$host_file" "$puid" "$pgid"; then
      warn "Bazarr still cannot read cataloged media file: ${container_file}"
      failed=$((failed + 1))
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would add read-only access to ${repaired} cataloged media file(s)"
    return
  fi
  [[ "$failed" == "0" ]] || die "${failed} cataloged media file(s) remain unreadable by Bazarr."
  info "Cataloged media-file read access passes; repaired ${repaired} file(s) without adding write permission"
}

read_jellyfin_api_key() {
  local key="" db_file=""
  if [[ -s "$JELLYFIN_API_KEY_FILE" ]]; then
    key="$(head -n 1 "$JELLYFIN_API_KEY_FILE" | tr -d '\r\n')"
  else
    for db_file in \
      "${APP_DIR}/config/jellyfin/data/data/jellyfin.db" \
      "${APP_DIR}/config/jellyfin/data/jellyfin.db" \
      "${APP_DIR}/config/jellyfin/jellyfin.db"; do
      [[ -r "$db_file" ]] || continue
      key="$(python3 - "$db_file" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=5)
try:
    tables = [row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND lower(name) LIKE '%apikey%'"
    )]
    for table in tables:
        quoted = '"' + table.replace('"', '""') + '"'
        columns = [row[1] for row in connection.execute(f"PRAGMA table_info({quoted})")]
        token_column = next((column for column in columns if column.lower() in ("accesstoken", "token", "apikey")), None)
        if not token_column:
            continue
        token_quoted = '"' + token_column.replace('"', '""') + '"'
        row = connection.execute(
            f"SELECT {token_quoted} FROM {quoted} WHERE {token_quoted} IS NOT NULL ORDER BY rowid DESC LIMIT 1"
        ).fetchone()
        if row and isinstance(row[0], str) and row[0].strip():
            print(row[0].strip())
            break
finally:
    connection.close()
PY
)"
      [[ -n "$key" ]] && break
    done
  fi
  [[ "$key" =~ ^[A-Za-z0-9._-]{16,}$ ]] || return 1
  printf '%s\n' "$key"
}

refresh_jellyfin() {
  local key=""
  key="$(read_jellyfin_api_key || true)"
  if [[ -z "$key" ]]; then
    [[ "$DRY_RUN" == "1" ]] && { warn "No existing Jellyfin API key found; the real repair would stop before refresh."; return; }
    die "No existing Jellyfin API key found. Create one in Jellyfin Dashboard > API Keys or place it in ${JELLYFIN_API_KEY_FILE} (mode 0600)."
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would refresh Jellyfin with an existing local API key"
    return
  fi
  curl -fsS --max-time 30 -o /dev/null -H "X-Emby-Token: ${key}" "${JELLYFIN_URL}/System/Info" || \
    die "The existing Jellyfin API key did not authenticate."
  curl -fsS --max-time 30 -o /dev/null -X POST -H "X-Emby-Token: ${key}" "${JELLYFIN_URL}/Library/Refresh"
  info "Requested Jellyfin library refresh"
}

main() {
  parse_args "$@"
  preflight
  if [[ "$STATUS_ONLY" == "1" ]]; then
    wait_for_bazarr
    read_bazarr_api_key
    detect_active_bazarr_jobs
    return
  fi
  acquire_lock
  if [[ "$INSTALL_TIMER" == "1" ]]; then
    install_timer
    [[ "$TIMER_ONLY" == "1" ]] && return
  fi

  verify_storage_mount /mnt/nas "Primary media storage"
  if [[ "$QNAP_REQUIRED" == "1" ]]; then
    verify_storage_mount /mnt/qnap "QNAP" nfs
  else
    warn "QNAP checks are disabled intentionally; no repair will touch /mnt/qnap."
  fi
  verify_and_repair_container_binds
  wait_for_bazarr
  read_bazarr_api_key
  verify_bazarr_connections
  configure_and_verify_providers
  configure_and_verify_analyzer
  verify_bazarr_languages
  detect_active_bazarr_jobs

  if [[ "$SKIP_BAZARR_TASKS" == "0" ]]; then
    run_bazarr_task update_series "sync series from Sonarr"
    run_bazarr_task update_movies "sync movies from Radarr"
  fi
  assign_unprofiled_english
  collect_bazarr_media_directories
  repair_subtitle_directory_permissions
  repair_media_file_read_permissions
  if [[ "$SKIP_BAZARR_TASKS" == "0" ]]; then
    run_bazarr_task series_full_scan_subtitles "index all existing episode subtitles"
    run_bazarr_task movies_full_scan_subtitles "index all existing movie subtitles"
    run_bazarr_task wanted_search_missing_subtitles_series "search for missing series subtitles"
    run_bazarr_task wanted_search_missing_subtitles_movies "search for missing movie subtitles"
    info "Bazarr accepted the background index and missing-subtitle search jobs"
  fi
  refresh_jellyfin
  info "Subtitle repair completed safely"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
