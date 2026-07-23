#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/mediastack}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
DOWNLOADS_ENABLED="${DOWNLOADS_ENABLED:-1}"

info() { printf '\033[1;34m[verify]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[verify] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[verify] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

env_value() {
  local key="$1" default="${2:-}" value=""
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$ENV_FILE")"
  printf '%s\n' "${value:-$default}"
}

arr_get() {
  local service="$1" port="$2" version="$3" endpoint="$4"
  local key_file="${APP_DIR}/.${service}-api-key" key=""
  if [[ -s "$key_file" ]]; then
    key="$(cat "$key_file")"
  elif [[ -s "${APP_DIR}/config/${service}/config.xml" ]]; then
    key="$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "${APP_DIR}/config/${service}/config.xml" | head -n 1)"
  fi
  [[ -n "$key" ]] || die "Could not read the ${service} API key."
  curl -fsS --max-time 20 -H "X-Api-Key: ${key}" "http://127.0.0.1:${port}/api/${version}/${endpoint}"
}

bazarr_api_key() {
  local config="${APP_DIR}/config/bazarr/config/config.yaml" key=""
  [[ -r "$config" ]] || die "Bazarr config is not readable."
  key="$(awk '$1 == "apikey:" { key = $2; gsub(/["\047]/, "", key); print key; exit }' "$config")"
  [[ "$key" =~ ^[A-Za-z0-9._-]{16,}$ ]] || die "Could not read Bazarr's local API key."
  printf '%s\n' "$key"
}

bazarr_get() {
  local key="$1" endpoint="$2"
  curl -fsS --max-time 30 -H "X-Api-Key: ${key}" "http://127.0.0.1:6767/api/${endpoint}"
}

verify_containers() {
  local name state
  for name in prowlarr byparr sonarr radarr lidarr bazarr kavita mylar jellyfin jellyseerr wizarr jellystat-db jellystat recyclarr profilarr mediastack-home homarr portainer; do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    [[ "$state" == "running" ]] || die "Container ${name} is ${state:-missing}."
  done
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    for name in gluetun qbittorrent; do
      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
      [[ "$state" == "running" ]] || die "Container ${name} is ${state:-missing}."
    done
    [[ "$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null || true)" == "healthy" ]] || die "Gluetun is not healthy."
  else
    for name in gluetun qbittorrent; do
      state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
      [[ "$state" != "running" ]] || die "Container ${name} must remain stopped until VPN credentials are configured."
    done
  fi
  [[ "$(docker inspect -f '{{.State.Health.Status}}' profilarr 2>/dev/null || true)" == "healthy" ]] || die "Profilarr is not healthy."
  [[ "$(docker inspect -f '{{.State.Health.Status}}' jellystat-db 2>/dev/null || true)" == "healthy" ]] || die "Jellystat PostgreSQL is not healthy."
  info "Core containers are running; required health checks pass"
}

verify_web_uis() {
  local target portal
  for target in \
    http://127.0.0.1:8088/ \
    http://127.0.0.1:8096/health \
    http://127.0.0.1:5055/api/v1/settings/public \
    http://127.0.0.1:6868/auth/login \
    http://127.0.0.1:8989/ \
    http://127.0.0.1:7878/ \
    http://127.0.0.1:9696/ \
    http://127.0.0.1:8686/ \
    http://127.0.0.1:6767/ \
    http://127.0.0.1:5690/ \
    http://127.0.0.1:5000/ \
    http://127.0.0.1:8090/; do
    curl -kfsS --max-time 15 -o /dev/null "$target" || die "Web endpoint failed: ${target}"
  done
  curl -kfsS --max-time 15 -o /dev/null http://127.0.0.1:7575/ || die "Homarr dashboard (7575) is not responding."
  curl -kfsS --max-time 15 -o /dev/null https://127.0.0.1:9443/api/system/status || die "Portainer API is unavailable."
  portal="$(curl -fsS http://127.0.0.1:8088/)"
  grep -q 'Profilarr' <<<"$portal" || die "Media Stack Home is missing its Profilarr link."
  info "Media Stack Home and user-facing web apps are reachable"
}

verify_qbittorrent() {
  local cookie username password preferences categories login_response login_code
  cookie="$(mktemp)"
  login_response="$(mktemp)"
  chmod 0600 "$cookie"
  username="$(env_value QBITTORRENT_USER admin)"
  password="$(env_value QBITTORRENT_PASSWORD)"
  login_code="$(curl -sS --max-time 15 -o "$login_response" -w '%{http_code}' -c "$cookie" \
    -H 'Referer: http://127.0.0.1:8080' \
    --data-urlencode "username=${username}" --data-urlencode "password=${password}" \
    http://127.0.0.1:8080/api/v2/auth/login || true)"
  if [[ "$login_code" != "204" ]] &&
    { [[ "$login_code" != "200" ]] || ! grep -qx 'Ok\.' "$login_response"; }; then
    rm -f "$cookie" "$login_response"
    die "qBittorrent shared login failed."
  fi
  rm -f "$login_response"
  preferences="$(curl -fsS -b "$cookie" http://127.0.0.1:8080/api/v2/app/preferences)"
  jq -e '.save_path == "/data/torrents" and .temp_path == "/data/torrents/incomplete" and .temp_path_enabled == true' <<<"$preferences" >/dev/null || {
    rm -f "$cookie"; die "qBittorrent media paths are not configured.";
  }
  categories="$(curl -fsS -b "$cookie" http://127.0.0.1:8080/api/v2/torrents/categories)"
  jq -e 'has("movies") and has("tv") and has("anime") and has("music") and has("books") and has("comics")' <<<"$categories" >/dev/null || {
    rm -f "$cookie"; die "qBittorrent categories are incomplete.";
  }
  rm -f "$cookie"
  info "qBittorrent shared login, media paths, and categories pass"
}

verify_arr_wiring() {
  local roots clients applications
  roots="$(arr_get sonarr 8989 v3 rootfolder)"
  jq -e 'map(.path) | index("/data/media/tv") and index("/data/media/anime")' <<<"$roots" >/dev/null || die "Sonarr media roots are incomplete."
  roots="$(arr_get radarr 7878 v3 rootfolder)"
  jq -e 'map(.path) | index("/data/media/movies")' <<<"$roots" >/dev/null || die "Radarr media root is missing."
  roots="$(arr_get lidarr 8686 v1 rootfolder)"
  jq -e 'map(.path) | index("/data/media/music")' <<<"$roots" >/dev/null || die "Lidarr media root is missing."

  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    clients="$(arr_get sonarr 8989 v3 downloadclient)"
    jq -e '.[] | select(.implementation == "QBittorrent")' <<<"$clients" >/dev/null || die "Sonarr qBittorrent connection is missing."
    clients="$(arr_get radarr 7878 v3 downloadclient)"
    jq -e '.[] | select(.implementation == "QBittorrent")' <<<"$clients" >/dev/null || die "Radarr qBittorrent connection is missing."
    clients="$(arr_get lidarr 8686 v1 downloadclient)"
    jq -e '.[] | select(.implementation == "QBittorrent")' <<<"$clients" >/dev/null || die "Lidarr qBittorrent connection is missing."
  fi

  applications="$(arr_get prowlarr 9696 v1 applications)"
  jq -e 'map(.implementation) | index("Sonarr") and index("Radarr") and index("Lidarr")' <<<"$applications" >/dev/null || die "Prowlarr application sync is incomplete."
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    info "Sonarr, Radarr, Lidarr, qBittorrent, and Prowlarr wiring passes"
  else
    info "Sonarr, Radarr, Lidarr, and Prowlarr core wiring passes; VPN downloads are pending"
  fi
}

verify_bazarr() {
  local key settings providers languages profiles series movies path path_count=0 missing_count=0
  key="$(bazarr_api_key)"
  settings="$(bazarr_get "$key" system/settings)" || die "Bazarr API authentication failed."
  jq -e '
    .general.use_sonarr == true and
    .general.use_radarr == true and
    .sonarr.ip == "sonarr" and (.sonarr.port | tonumber) == 8989 and
    .radarr.ip == "radarr" and (.radarr.port | tonumber) == 7878
  ' <<<"$settings" >/dev/null || die "Bazarr Sonarr/Radarr connections are incomplete."

  providers="$(bazarr_get "$key" providers)"
  if [[ "$(jq '.general.enabled_providers // [] | length' <<<"$settings")" == "0" ]]; then
    warn "Bazarr has no enabled subtitle providers."
  elif [[ "$(jq '.data | length' <<<"$providers")" == "0" ]]; then
    warn "Bazarr does not recognize any configured subtitle provider in this build."
  fi

  languages="$(bazarr_get "$key" system/languages)"
  profiles="$(bazarr_get "$key" system/languages/profiles)"
  [[ "$(jq '[.[] | select(.enabled == true)] | length' <<<"$languages")" != "0" ]] || \
    warn "Bazarr has no enabled subtitle languages."
  [[ "$(jq 'length' <<<"$profiles")" != "0" ]] || \
    warn "Bazarr has no language profiles; series and movies cannot request wanted languages."

  series="$(bazarr_get "$key" 'series?length=-1')"
  movies="$(bazarr_get "$key" 'movies?length=-1')"
  jq -e '[.data[].path | select(. != null)] | all(startswith("/data/") or startswith("/qnap/"))' \
    <<<"$series" >/dev/null || die "Bazarr series paths do not match its shared Docker mounts."
  jq -e '[.data[].path | select(. != null)] | all(startswith("/data/") or startswith("/qnap/"))' \
    <<<"$movies" >/dev/null || die "Bazarr movie paths do not match its shared Docker mounts."

  while IFS= read -r path; do
    path_count=$((path_count + 1))
    docker exec bazarr test -e "$path" || missing_count=$((missing_count + 1))
  done < <(jq -r '.data[].path // empty' <<<"$series"; jq -r '.data[].path // empty' <<<"$movies")
  [[ "$path_count" == "0" || "$missing_count" -lt "$path_count" ]] || \
    die "Bazarr cannot see any Sonarr/Radarr catalog paths."
  [[ "$missing_count" == "0" ]] || warn "Bazarr cannot currently see ${missing_count}/${path_count} catalog paths."
  info "Bazarr API, Arr connections, path mapping, provider, and language checks completed"
}

verify_profilarr() {
  local cookie username password arrs databases
  cookie="$(mktemp)"
  chmod 0600 "$cookie"
  username="$(env_value PROFILARR_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  password="$(env_value PROFILARR_ADMIN_PASSWORD "$(env_value MEDIASTACK_ADMIN_PASSWORD)")"
  curl -fsS --max-time 20 -o /dev/null -c "$cookie" \
    -H 'Origin: http://127.0.0.1:6868' \
    --data-urlencode "username=${username}" --data-urlencode "password=${password}" \
    http://127.0.0.1:6868/auth/login || { rm -f "$cookie"; die "Profilarr shared login failed."; }
  arrs="$(curl -fsS -b "$cookie" http://127.0.0.1:6868/api/v1/arr)"
  jq -e 'map(.type) | index("sonarr") and index("radarr")' <<<"$arrs" >/dev/null || { rm -f "$cookie"; die "Profilarr Arr connections are incomplete."; }
  databases="$(curl -fsS -b "$cookie" http://127.0.0.1:6868/api/v1/databases)"
  jq -e '.[] | select(.repository_url == "https://github.com/Dictionarry-Hub/trash-pcd")' <<<"$databases" >/dev/null || {
    rm -f "$cookie"; die "Profilarr TRaSH Guides database is missing.";
  }
  rm -f "$cookie"
  info "Profilarr shared login, Sonarr/Radarr, and TRaSH database pass"
}

verify_jellyfin_and_seerr() {
  local username password token libraries public
  username="$(env_value JELLYFIN_ADMIN_USER admin)"
  password="$(env_value JELLYFIN_ADMIN_PASSWORD)"
  token="$(curl -fsS -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
    -H 'Content-Type: application/json' \
    -H 'X-Emby-Authorization: MediaBrowser Client="Mediastack Verifier", Device="Proxmox LXC", DeviceId="mediastack-verifier", Version="1.0.0"' \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Pw:$password}')" | jq -er '.AccessToken // .accessToken')"
  libraries="$(curl -fsS -H "X-Emby-Token: ${token}" http://127.0.0.1:8096/Library/VirtualFolders)"
  jq -e 'map(.Name // .name) | index("Movies") and index("TV Shows") and index("Anime") and index("Music") and index("Books")' <<<"$libraries" >/dev/null || die "Jellyfin libraries are incomplete."
  public="$(curl -fsS http://127.0.0.1:5055/api/v1/settings/public)"
  jq -e '.initialized == true' <<<"$public" >/dev/null || die "Seerr is not initialized."
  info "Jellyfin shared login/libraries and Seerr initialization pass"
}

verify_homarr() {
  local username response step
  username="$(env_value HOMARR_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  username="$(tr '[:upper:]' '[:lower:]' <<<"$username" | xargs)"
  response="$(curl -fsS --max-time 30 -G \
    --data-urlencode 'input={"json":null}' \
    -H 'x-trpc-source: mediastack-verifier' \
    http://127.0.0.1:7575/api/trpc/onboard.currentStep)"
  step="$(jq -er '.result.data.json.current // .result.data.current' <<<"$response")"
  [[ "$step" == "finish" ]] || die "Homarr onboarding is incomplete (current step: ${step})."
  docker exec homarr homarr users list 2>/dev/null |
    awk -F '\t' -v expected="$username" 'NR > 1 && tolower($2) == expected { found=1 } END { exit(found ? 0 : 1) }' ||
    die "Homarr shared admin user is missing."
  [[ -f "${APP_DIR}/.homarr-apps-created" ]] || die "Homarr's media-stack dashboard was not populated."
  info "Homarr shared admin user and populated dashboard pass"
}

verify_portainer() {
  local username password response token endpoints
  username="$(env_value PORTAINER_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  password="$(env_value PORTAINER_ADMIN_PASSWORD "$(env_value MEDIASTACK_ADMIN_PASSWORD)")"
  response="$(curl -kfsS --max-time 30 \
    -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Password:$password}')" \
    https://127.0.0.1:9443/api/auth)" ||
    die "Portainer shared login failed."
  token="$(jq -er '.jwt' <<<"$response")" || die "Portainer authentication did not return a token."
  endpoints="$(curl -kfsS --max-time 30 -H "Authorization: Bearer ${token}" \
    https://127.0.0.1:9443/api/endpoints)"
  jq -e '.[] | select((.URL // .Url // "") == "unix:///var/run/docker.sock")' <<<"$endpoints" >/dev/null ||
    die "Portainer's local Docker environment is missing."
  info "Portainer shared login and local Docker environment pass"
}

verify_backends() {
  local hwaccels
  docker exec recyclarr recyclarr config list local >/dev/null || die "Recyclarr local config is invalid."
  if [[ -e /dev/nvidia0 ]]; then
    hwaccels="$(docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -hwaccels 2>/dev/null)"
    grep -qi cuda <<<"$hwaccels" || die "Jellyfin FFmpeg does not expose CUDA."
  elif [[ -e /dev/dri/renderD128 ]]; then
    hwaccels="$(docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -hwaccels 2>/dev/null)"
    grep -qi vaapi <<<"$hwaccels" || die "Jellyfin FFmpeg does not expose VAAPI."
    docker exec jellyfin test -r /dev/dri/renderD128 ||
      die "Jellyfin cannot read /dev/dri/renderD128; check RENDER_GID/VIDEO_GID in the .env."
  fi
  info "Recyclarr and available GPU backend checks pass"
}

main() {
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}."
  command -v curl >/dev/null 2>&1 || die "curl is required."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  [[ "$DOWNLOADS_ENABLED" == "0" || "$DOWNLOADS_ENABLED" == "1" ]] ||
    die "DOWNLOADS_ENABLED must be 0 or 1."
  verify_containers
  verify_web_uis
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    verify_qbittorrent
  fi
  verify_arr_wiring
  verify_bazarr
  verify_profilarr
  verify_jellyfin_and_seerr
  verify_homarr
  verify_portainer
  verify_backends
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    touch "${APP_DIR}/.mediastack-configured"
    rm -f "${APP_DIR}/.mediastack-core-configured"
  else
    touch "${APP_DIR}/.mediastack-core-configured"
  fi
  info "All media-stack integration checks passed"
}

main "$@"
