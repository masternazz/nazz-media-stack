#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/mediastack}"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"
QNAP_ENABLED="${QNAP_ENABLED:-0}"
APPLY_TRASH="${APPLY_TRASH:-1}"
DOWNLOADS_ENABLED="${DOWNLOADS_ENABLED:-1}"

info() { printf '\033[1;34m[configure]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[configure] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[configure] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

env_value() {
  local key="$1"
  local default="${2:-}"
  local value=""
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$ENV_FILE")"
  printf '%s\n' "${value:-$default}"
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempts="${3:-90}"
  local attempt=0
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl -ksS --max-time 5 -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  die "${name} did not become reachable at ${url}."
}

wait_for_container() {
  local name="$1"
  local attempt=0
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)" == "running" ]]; then
      return 0
    fi
    sleep 2
  done
  die "Container ${name} did not reach the running state."
}

api_key() {
  local service="$1"
  local config="${APP_DIR}/config/${service}/config.xml"
  local key=""
  local attempt=0
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if [[ -f "$config" ]]; then
      key="$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$config" | head -n 1)"
      [[ -n "$key" ]] && { printf '%s\n' "$key"; return 0; }
    fi
    sleep 2
  done
  die "Could not read the ${service} API key from ${config}."
}

validate_storage() {
  local puid pgid test_file
  puid="$(env_value PUID 65534)"
  pgid="$(env_value PGID 65534)"
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ ]] || die "PUID and PGID must be numeric."

  info "Validating primary media storage paths"
  for path in \
    /mnt/nas/media \
    /mnt/nas/torrents \
    /mnt/nas/media/movies \
    /mnt/nas/media/tv \
    /mnt/nas/media/anime \
    /mnt/nas/media/music \
    /mnt/nas/media/books \
    /mnt/nas/media/comics \
    /mnt/nas/torrents/movies \
    /mnt/nas/torrents/tv \
    /mnt/nas/torrents/anime \
    /mnt/nas/torrents/music \
    /mnt/nas/torrents/books \
    /mnt/nas/torrents/comics \
    /mnt/nas/torrents/incomplete \
    /mnt/nas/jellyfin-cache; do
    install -d -m 0777 "$path"
  done

  test_file="/mnt/nas/torrents/.mediastack-write-test-$$"
  if command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid "$puid" --regid "$pgid" --clear-groups touch "$test_file" ||
      die "Media storage is not writable by PUID ${puid}:PGID ${pgid}."
  else
    touch "$test_file" || die "Media storage torrent path is not writable."
  fi
  rm -f -- "$test_file"

  if [[ "$QNAP_ENABLED" == "1" ]]; then
    [[ -d /mnt/qnap/media ]] || die "QNAP was enabled, but /mnt/qnap/media is unavailable."
  fi
}

qb_login() {
  local cookie="$1"
  local username="$2"
  local password="$3"
  local code="" response=""
  response="$(mktemp)"
  code="$(curl -sS --max-time 10 -o "$response" -w '%{http_code}' -c "$cookie" \
    -H 'Referer: http://127.0.0.1:8080' \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    http://127.0.0.1:8080/api/v2/auth/login || true)"
  if [[ "$code" == "204" ]] || { [[ "$code" == "200" ]] && grep -qx 'Ok\.' "$response"; }; then
    rm -f "$response"
    return 0
  fi
  rm -f "$response"
  return 1
}

configure_qbittorrent() {
  local username password temporary_password cookie preferences
  username="$(env_value QBITTORRENT_USER admin)"
  password="$(env_value QBITTORRENT_PASSWORD)"
  [[ -n "$password" ]] || die "QBITTORRENT_PASSWORD is missing from ${ENV_FILE}."
  cookie="$(mktemp)"
  chmod 0600 "$cookie"

  info "Configuring qBittorrent paths, credentials, and categories"
  if ! qb_login "$cookie" "$username" "$password"; then
    temporary_password="$(docker logs qbittorrent 2>&1 |
      sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' |
      awk -F': ' '/temporary password is provided for this session/ { value = $NF } END { print value }')"
    [[ -n "$temporary_password" ]] || { rm -f "$cookie"; die "Could not find qBittorrent's temporary password in its logs."; }
    qb_login "$cookie" admin "$temporary_password" || { rm -f "$cookie"; die "Could not authenticate to qBittorrent."; }
  fi

  preferences="$(jq -n \
    --arg username "$username" \
    --arg password "$password" \
    '{save_path:"/data/torrents",temp_path:"/data/torrents/incomplete",temp_path_enabled:true,web_ui_username:$username,web_ui_password:$password,web_ui_address:"*",web_ui_port:8080,listen_port:6881}')"
  curl -fsS -b "$cookie" -H 'Referer: http://127.0.0.1:8080' \
    --data-urlencode "json=${preferences}" \
    http://127.0.0.1:8080/api/v2/app/setPreferences >/dev/null

  rm -f "$cookie"
  cookie="$(mktemp)"
  chmod 0600 "$cookie"
  qb_login "$cookie" "$username" "$password" || { rm -f "$cookie"; die "qBittorrent did not accept its configured credentials."; }

  local category save_path categories endpoint
  categories="$(curl -fsS -b "$cookie" http://127.0.0.1:8080/api/v2/torrents/categories)"
  while IFS='|' read -r category save_path; do
    if jq -e --arg category "$category" 'has($category)' <<<"$categories" >/dev/null; then
      endpoint=editCategory
    else
      endpoint=createCategory
    fi
    curl -fsS -b "$cookie" \
      -H 'Referer: http://127.0.0.1:8080' \
      --data-urlencode "category=${category}" \
      --data-urlencode "savePath=${save_path}" \
      "http://127.0.0.1:8080/api/v2/torrents/${endpoint}" >/dev/null
  done <<'EOF'
movies|/data/torrents/movies
tv|/data/torrents/tv
anime|/data/torrents/anime
music|/data/torrents/music
books|/data/torrents/books
comics|/data/torrents/comics
EOF
  rm -f "$cookie"
}

declare -A ARR_PORT=( [sonarr]=8989 [radarr]=7878 [lidarr]=8686 [prowlarr]=9696 )
declare -A ARR_API=( [sonarr]=v3 [radarr]=v3 [lidarr]=v1 [prowlarr]=v1 )

arr_request() {
  local service="$1" method="$2" endpoint="$3" key="$4" data="${5:-}"
  local args=(-fsS -X "$method" -H "X-Api-Key: ${key}" -H 'Content-Type: application/json')
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "http://127.0.0.1:${ARR_PORT[$service]}/api/${ARR_API[$service]}/${endpoint}"
}

arr_test() {
  local service="$1" endpoint="$2" key="$3" data="$4"
  local response_file code message
  response_file="$(mktemp)"
  code="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "X-Api-Key: ${key}" -H 'Content-Type: application/json' -d "$data" \
    "http://127.0.0.1:${ARR_PORT[$service]}/api/${ARR_API[$service]}/${endpoint}" || true)"
  if [[ "$code" == 2* ]]; then
    rm -f "$response_file"
    return 0
  fi
  message="$(jq -r '[.. | objects | (.errorMessage? // .message?) | select(type == "string")] | unique | join("; ")' "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"
  die "${service} rejected ${endpoint} (HTTP ${code:-none})${message:+: ${message}}"
}

ensure_root_folder() {
  local service="$1" key="$2" path="$3"
  local payload metadata_profile_id quality_profile_id
  if arr_request "$service" GET rootfolder "$key" | jq -e --arg path "$path" '.[] | select(.path == $path)' >/dev/null; then
    return
  fi
  info "Adding ${service} root folder ${path}"
  if [[ "$service" == "lidarr" ]]; then
    metadata_profile_id="$(arr_request lidarr GET metadataprofile "$key" | jq -er '.[0].id')"
    quality_profile_id="$(arr_request lidarr GET qualityprofile "$key" | jq -er '.[0].id')"
    payload="$(jq -n --arg path "$path" \
      --argjson metadata_profile_id "$metadata_profile_id" \
      --argjson quality_profile_id "$quality_profile_id" \
      '{name:"Music",path:$path,defaultMetadataProfileId:$metadata_profile_id,defaultQualityProfileId:$quality_profile_id}')"
  else
    payload="$(jq -n --arg path "$path" '{path:$path}')"
  fi
  arr_test "$service" rootfolder "$key" "$payload"
}

ensure_download_client() {
  local service="$1" key="$2" category_field="$3" category="$4" username="$5" password="$6"
  local payload existing
  existing="$(arr_request "$service" GET downloadclient "$key")"
  if jq -e '.[] | select(.implementation == "QBittorrent")' <<<"$existing" >/dev/null; then
    info "${service} already has a qBittorrent download client; leaving it unchanged"
    return
  fi

  payload="$(arr_request "$service" GET downloadclient/schema "$key" | jq \
    --arg category_field "$category_field" \
    --arg category "$category" \
    --arg username "$username" \
    --arg password "$password" '
      .[] | select(.implementation == "QBittorrent") |
      .name = "qBittorrent via Gluetun" |
      .enable = true |
      .priority = 1 |
      .removeCompletedDownloads = true |
      .removeFailedDownloads = true |
      .fields |= map(
        if .name == "host" then .value = "gluetun"
        elif .name == "port" then .value = 8080
        elif .name == "useSsl" then .value = false
        elif .name == "username" then .value = $username
        elif .name == "password" then .value = $password
        elif .name == $category_field then .value = $category
        else . end)')"
  [[ -n "$payload" ]] || die "Could not build the ${service} qBittorrent configuration."
  arr_test "$service" downloadclient/test "$key" "$payload"
  arr_request "$service" POST downloadclient "$key" "$payload" >/dev/null
  info "Connected ${service} to qBittorrent through Gluetun"
}

configure_arr_roots() {
  local sonarr_key radarr_key lidarr_key
  sonarr_key="$(api_key sonarr)"
  radarr_key="$(api_key radarr)"
  lidarr_key="$(api_key lidarr)"

  ensure_root_folder sonarr "$sonarr_key" /data/media/tv
  ensure_root_folder sonarr "$sonarr_key" /data/media/anime
  ensure_root_folder radarr "$radarr_key" /data/media/movies
  ensure_root_folder lidarr "$lidarr_key" /data/media/music
  if [[ "$QNAP_ENABLED" == "1" ]]; then
    [[ -d /mnt/qnap/media/tv ]] && ensure_root_folder sonarr "$sonarr_key" /qnap/media/tv
    [[ -d /mnt/qnap/media/anime ]] && ensure_root_folder sonarr "$sonarr_key" /qnap/media/anime
    [[ -d /mnt/qnap/media/movies ]] && ensure_root_folder radarr "$radarr_key" /qnap/media/movies
    [[ -d /mnt/qnap/media/music ]] && ensure_root_folder lidarr "$lidarr_key" /qnap/media/music
  fi

  printf '%s\n' "$sonarr_key" >"${APP_DIR}/.sonarr-api-key"
  printf '%s\n' "$radarr_key" >"${APP_DIR}/.radarr-api-key"
  printf '%s\n' "$lidarr_key" >"${APP_DIR}/.lidarr-api-key"
  chmod 0600 "${APP_DIR}/.sonarr-api-key" "${APP_DIR}/.radarr-api-key" "${APP_DIR}/.lidarr-api-key"
}

configure_arr_downloads() {
  local qbit_user qbit_password sonarr_key radarr_key lidarr_key
  qbit_user="$(env_value QBITTORRENT_USER admin)"
  qbit_password="$(env_value QBITTORRENT_PASSWORD)"
  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  lidarr_key="$(cat "${APP_DIR}/.lidarr-api-key")"

  ensure_download_client sonarr "$sonarr_key" tvCategory tv "$qbit_user" "$qbit_password"
  ensure_download_client radarr "$radarr_key" movieCategory movies "$qbit_user" "$qbit_password"
  ensure_download_client lidarr "$lidarr_key" musicCategory music "$qbit_user" "$qbit_password"
}

ensure_prowlarr_application() {
  local implementation="$1" base_url="$2" app_key="$3" prowlarr_key="$4"
  local existing payload
  existing="$(arr_request prowlarr GET applications "$prowlarr_key")"
  if jq -e --arg implementation "$implementation" '.[] | select(.implementation == $implementation)' <<<"$existing" >/dev/null; then
    info "Prowlarr already has a ${implementation} application; leaving it unchanged"
    return
  fi
  payload="$(arr_request prowlarr GET applications/schema "$prowlarr_key" | jq \
    --arg implementation "$implementation" \
    --arg base_url "$base_url" \
    --arg api_key "$app_key" '
      .[] | select(.implementation == $implementation) |
      .name = $implementation |
      .enable = true |
      .syncLevel = "fullSync" |
      .fields |= map(
        if .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
        elif .name == "baseUrl" then .value = $base_url
        elif .name == "apiKey" then .value = $api_key
        else . end)')"
  [[ -n "$payload" ]] || die "Could not build the Prowlarr ${implementation} application."
  arr_test prowlarr applications/test "$prowlarr_key" "$payload"
  arr_request prowlarr POST applications "$prowlarr_key" "$payload" >/dev/null
  info "Connected Prowlarr to ${implementation}"
}

configure_prowlarr() {
  local prowlarr_key sonarr_key radarr_key lidarr_key
  prowlarr_key="$(api_key prowlarr)"
  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  lidarr_key="$(cat "${APP_DIR}/.lidarr-api-key")"
  ensure_prowlarr_application Sonarr http://sonarr:8989 "$sonarr_key" "$prowlarr_key"
  ensure_prowlarr_application Radarr http://radarr:7878 "$radarr_key" "$prowlarr_key"
  ensure_prowlarr_application Lidarr http://lidarr:8686 "$lidarr_key" "$prowlarr_key"
}

configure_bazarr() {
  local config="${APP_DIR}/config/bazarr/config/config.yaml"
  local sonarr_key radarr_key
  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  for _ in $(seq 1 90); do [[ -f "$config" ]] && break; sleep 2; done
  [[ -f "$config" ]] || die "Bazarr did not create ${config}."

  info "Connecting Bazarr to Sonarr and Radarr"
  docker stop bazarr >/dev/null
  SONARR_API_KEY="$sonarr_key" RADARR_API_KEY="$radarr_key" BAZARR_CONFIG="$config" python3 - <<'PY'
import os
import yaml

path = os.environ["BAZARR_CONFIG"]
with open(path, "r", encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}

general = config.setdefault("general", {})
general["use_sonarr"] = True
general["use_radarr"] = True

sonarr = config.setdefault("sonarr", {})
sonarr.update({"ip": "sonarr", "port": 8989, "base_url": "", "ssl": False,
               "apikey": os.environ["SONARR_API_KEY"]})
radarr = config.setdefault("radarr", {})
radarr.update({"ip": "radarr", "port": 7878, "base_url": "", "ssl": False,
               "apikey": os.environ["RADARR_API_KEY"]})

with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
  docker start bazarr >/dev/null
  wait_for_url Bazarr http://127.0.0.1:6767 60
}

configure_recyclarr() {
  local config_dir="${APP_DIR}/config/recyclarr"
  local sonarr_key radarr_key
  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  info "Writing Recyclarr connection configuration"
  install -d -m 0700 "$config_dir"
  cat >"${config_dir}/secrets.yml" <<EOF
series_base_url: http://sonarr:8989
series_api_key: ${sonarr_key}
movies_base_url: http://radarr:7878
movies_api_key: ${radarr_key}
EOF

  if [[ "$APPLY_TRASH" == "1" ]]; then
    # Recyclarr v8 auto-loads configs/<template>.yml. Generate the TRaSH starter
    # templates (Radarr HD Bluray + WEB, Sonarr WEB-1080p) and inject our
    # connection details through the secrets file. Profilarr stays available for
    # GUI customization on top of this baseline.
    info "Generating TRaSH Guides configs via Recyclarr templates"
    rm -f "${config_dir}/recyclarr.yml"
    rm -f "${config_dir}/configs/"*.yml 2>/dev/null || true
    docker exec recyclarr recyclarr config create --template hd-bluray-web --force >/dev/null 2>&1 || true
    docker exec recyclarr recyclarr config create --template web-1080p --force >/dev/null 2>&1 || true
    if [[ -f "${config_dir}/configs/hd-bluray-web.yml" && -f "${config_dir}/configs/web-1080p.yml" ]]; then
      sed -i -e 's|base_url: Put your Radarr URL here|base_url: !secret movies_base_url|' \
             -e 's|api_key: Put your API key here|api_key: !secret movies_api_key|' \
             "${config_dir}/configs/hd-bluray-web.yml"
      sed -i -e 's|base_url: Put your Sonarr URL here|base_url: !secret series_base_url|' \
             -e 's|api_key: Put your API key here|api_key: !secret series_api_key|' \
             "${config_dir}/configs/web-1080p.yml"
      chown -R "$(env_value PUID 65534):$(env_value PGID 65534)" "$config_dir"
      chmod 0600 "${config_dir}/secrets.yml" "${config_dir}/configs/"*.yml
      info "Applying TRaSH Guides quality profiles and custom formats via Recyclarr"
      if docker exec recyclarr recyclarr sync >/dev/null 2>&1; then
        info "Recyclarr applied TRaSH profiles: Radarr 'HD Bluray + WEB' and Sonarr 'WEB-1080p'"
      else
        warn "Recyclarr sync did not finish cleanly; TRaSH profiles may be partial. Re-run later with: docker exec recyclarr recyclarr sync"
      fi
    else
      warn "Recyclarr could not generate TRaSH template configs; skipping profile sync. Set them up in Profilarr (:6868)."
      chown -R "$(env_value PUID 65534):$(env_value PGID 65534)" "$config_dir"
      chmod 0600 "${config_dir}/secrets.yml"
    fi
  else
    cat >"${config_dir}/recyclarr.yml" <<'EOF'
sonarr:
  series:
    base_url: !secret series_base_url
    api_key: !secret series_api_key
radarr:
  movies:
    base_url: !secret movies_base_url
    api_key: !secret movies_api_key
EOF
    chown -R "$(env_value PUID 65534):$(env_value PGID 65534)" "$config_dir"
    chmod 0600 "${config_dir}/secrets.yml" "${config_dir}/recyclarr.yml"
    docker exec recyclarr recyclarr config list local >/dev/null 2>&1 || warn "Recyclarr config was written but its local-file validation did not complete."
  fi
}

profilarr_form_post() {
  local cookie="$1" path="$2"
  shift 2
  local code
  code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
    -b "$cookie" -c "$cookie" \
    -H 'Origin: http://127.0.0.1:6868' \
    "$@" "http://127.0.0.1:6868${path}" || true)"
  [[ "$code" == "200" || "$code" == "204" || "$code" == "303" ]]
}

configure_profilarr() {
  local username password setup_code cookie arrs databases sonarr_key radarr_key response code
  local needs_sonarr=0 needs_radarr=0
  username="$(env_value PROFILARR_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  password="$(env_value PROFILARR_ADMIN_PASSWORD "$(env_value MEDIASTACK_ADMIN_PASSWORD)")"
  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  [[ -n "$password" ]] || die "Profilarr credentials are missing from ${ENV_FILE}."

  cookie="$(mktemp)"
  response="$(mktemp)"
  chmod 0600 "$cookie" "$response"
  setup_code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:6868/auth/setup || true)"
  if [[ "$setup_code" == "200" ]]; then
    info "Creating the Profilarr admin account"
    if ! profilarr_form_post "$cookie" /auth/setup \
      --data-urlencode "username=${username}" \
      --data-urlencode "password=${password}" \
      --data-urlencode "confirmPassword=${password}"; then
      rm -f "$cookie" "$response"
      die "Profilarr did not accept its initial admin account."
    fi
  elif ! profilarr_form_post "$cookie" /auth/login \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}"; then
    rm -f "$cookie" "$response"
    warn "Profilarr is already initialized with different credentials; complete its connections in the GUI."
    return 0
  fi

  arrs="$(curl -fsS --max-time 20 -b "$cookie" http://127.0.0.1:6868/api/v1/arr)" || {
    rm -f "$cookie" "$response"
    die "Could not read Profilarr's Arr connections through its API."
  }
  jq -e '.[] | select(.type == "sonarr" and .url == "http://sonarr:8989")' <<<"$arrs" >/dev/null || needs_sonarr=1
  jq -e '.[] | select(.type == "radarr" and .url == "http://radarr:7878")' <<<"$arrs" >/dev/null || needs_radarr=1

  if [[ "$needs_sonarr" == "1" || "$needs_radarr" == "1" ]]; then
    if [[ "$needs_sonarr" == "1" ]]; then
      info "Connecting Profilarr to Sonarr"
      profilarr_form_post "$cookie" /arr/new \
        --data-urlencode 'name=Sonarr' \
        --data-urlencode 'type=sonarr' \
        --data-urlencode 'url=http://sonarr:8989' \
        --data-urlencode 'external_url=' \
        --data-urlencode "api_key=${sonarr_key}" \
        --data-urlencode 'tags=[]' || die "Profilarr did not accept the Sonarr connection."
    fi
    if [[ "$needs_radarr" == "1" ]]; then
      info "Connecting Profilarr to Radarr"
      profilarr_form_post "$cookie" /arr/new \
        --data-urlencode 'name=Radarr' \
        --data-urlencode 'type=radarr' \
        --data-urlencode 'url=http://radarr:7878' \
        --data-urlencode 'external_url=' \
        --data-urlencode "api_key=${radarr_key}" \
        --data-urlencode 'tags=[]' || die "Profilarr did not accept the Radarr connection."
    fi
  fi

  databases="$(curl -fsS --max-time 20 -b "$cookie" http://127.0.0.1:6868/api/v1/databases)"
  if ! jq -e '.[] | select(.repository_url == "https://github.com/Dictionarry-Hub/trash-pcd")' <<<"$databases" >/dev/null; then
    info "Linking the TRaSH Guides database in Profilarr"
    code="$(curl -sS --max-time 180 -o "$response" -w '%{http_code}' \
      -b "$cookie" -X POST -H 'Content-Type: application/json' \
      -d '{"name":"TRaSH Guides","repository_url":"https://github.com/Dictionarry-Hub/trash-pcd","branch":"main"}' \
      http://127.0.0.1:6868/api/v1/databases || true)"
    if [[ "$code" != "201" ]]; then
      warn "Profilarr is connected to Sonarr/Radarr, but its TRaSH database link returned HTTP ${code:-none}. Add it in the GUI if it is still absent."
    fi
  fi
  rm -f "$cookie" "$response"
}

configure_portainer() {
  local username password check_code response code token endpoints
  username="$(env_value PORTAINER_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  password="$(env_value PORTAINER_ADMIN_PASSWORD "$(env_value MEDIASTACK_ADMIN_PASSWORD)")"
  [[ ${#password} -ge 12 ]] || die "Portainer's admin password must be at least 12 characters."
  response="$(mktemp)"
  chmod 0600 "$response"

  check_code="$(curl -ksS --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/api/users/admin/check || true)"
  if [[ "$check_code" != "204" ]]; then
    info "Creating the Portainer admin account"
    code="$(curl -ksS --max-time 30 -o "$response" -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Password:$password}')" \
      https://127.0.0.1:9443/api/users/admin/init || true)"
    if [[ "$code" != "200" && "$code" != "201" ]]; then
      warn "Portainer first-admin API returned HTTP ${code:-none}; restarting it once in case its five-minute setup window expired."
      docker restart portainer >/dev/null
      wait_for_url Portainer https://127.0.0.1:9443/api/system/status 45
      code="$(curl -ksS --max-time 30 -o "$response" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Password:$password}')" \
        https://127.0.0.1:9443/api/users/admin/init || true)"
    fi
    if [[ "$code" != "200" && "$code" != "201" ]]; then
      warn "Portainer response: $(tr '\n' ' ' <"$response" | head -c 500)"
      rm -f "$response"
      die "Portainer did not create its admin account (HTTP ${code:-none})."
    fi
  else
    info "Portainer admin account already exists"
  fi

  code="$(curl -ksS --max-time 30 -o "$response" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Password:$password}')" \
    https://127.0.0.1:9443/api/auth || true)"
  token="$(jq -r '.jwt // empty' "$response" 2>/dev/null || true)"
  if [[ "$code" != "200" || -z "$token" ]]; then
    rm -f "$response"
    die "Portainer did not accept the configured shared login."
  fi

  endpoints="$(curl -kfsS --max-time 30 -H "Authorization: Bearer ${token}" \
    https://127.0.0.1:9443/api/endpoints)"
  if ! jq -e '.[] | select((.URL // .Url // "") == "unix:///var/run/docker.sock")' <<<"$endpoints" >/dev/null; then
    info "Adding Portainer's local Docker environment"
    code="$(curl -ksS --max-time 30 -o "$response" -w '%{http_code}' \
      -X POST -H "Authorization: Bearer ${token}" \
      -F 'Name=local' -F 'EndpointCreationType=1' \
      https://127.0.0.1:9443/api/endpoints || true)"
    if [[ "$code" != "200" && "$code" != "201" ]]; then
      warn "Portainer response: $(tr '\n' ' ' <"$response" | head -c 500)"
      rm -f "$response"
      die "Portainer admin exists, but its local Docker environment could not be created (HTTP ${code:-none})."
    fi
  fi

  rm -f "$response"
}

jellyfin_auth_token() {
  local username="$1" password="$2" device_id response
  device_id="mediastack-$(hostname | tr -cd 'A-Za-z0-9_-')"
  response="$(curl -fsS -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
    -H 'Content-Type: application/json' \
    -H "X-Emby-Authorization: MediaBrowser Client=\"Mediastack Installer\", Device=\"Proxmox LXC\", DeviceId=\"${device_id}\", Version=\"1.0.0\"" \
    -d "$(jq -n --arg username "$username" --arg password "$password" '{Username:$username,Pw:$password}')")"
  jq -er '.AccessToken // .accessToken' <<<"$response"
}

add_jellyfin_library() {
  local token="$1" name="$2" collection_type="$3"
  shift 3
  local current encoded_name encoded_type paths_json body
  current="$(curl -fsS -H "X-Emby-Token: ${token}" http://127.0.0.1:8096/Library/VirtualFolders)"
  if jq -e --arg name "$name" '.[] | select(.Name == $name or .name == $name)' <<<"$current" >/dev/null; then
    info "Jellyfin library ${name} already exists"
    return
  fi
  encoded_name="$(jq -rn --arg value "$name" '$value|@uri')"
  encoded_type="$(jq -rn --arg value "$collection_type" '$value|@uri')"
  paths_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  body="$(jq -n --argjson paths "$paths_json" '{LibraryOptions:{EnableRealtimeMonitor:true,EnableInternetProviders:true,PathInfos:($paths|map({Path:.}))}}')"
  curl -fsS -X POST \
    -H "X-Emby-Token: ${token}" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "http://127.0.0.1:8096/Library/VirtualFolders?name=${encoded_name}&collectionType=${encoded_type}&refreshLibrary=false" >/dev/null
  info "Added Jellyfin library ${name}"
}

configure_jellyfin() {
  local username password completed token
  username="$(env_value JELLYFIN_ADMIN_USER admin)"
  password="$(env_value JELLYFIN_ADMIN_PASSWORD)"
  [[ -n "$password" ]] || die "JELLYFIN_ADMIN_PASSWORD is missing from ${ENV_FILE}."
  completed="$(curl -fsS http://127.0.0.1:8096/System/Info/Public | jq -r '.StartupWizardCompleted // .startupWizardCompleted // false')"
  if [[ "$completed" != "true" ]]; then
    info "Completing Jellyfin's initial setup"
    curl -fsS -X POST http://127.0.0.1:8096/Startup/Configuration \
      -H 'Content-Type: application/json' \
      -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
    # Jellyfin's wizard seeds its first user on this GET; the following POST
    # updates that user. A POST against a completely empty database returns 404.
    curl -fsS http://127.0.0.1:8096/Startup/User >/dev/null
    curl -fsS -X POST http://127.0.0.1:8096/Startup/User \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg name "$username" --arg password "$password" '{Name:$name,Password:$password}')" >/dev/null
    curl -fsS -X POST http://127.0.0.1:8096/Startup/RemoteAccess \
      -H 'Content-Type: application/json' \
      -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
    curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete >/dev/null
  fi

  token="$(jellyfin_auth_token "$username" "$password")"
  [[ -n "$token" ]] || die "Could not authenticate to Jellyfin after setup."

  local movies=(/media/movies) tv=(/media/tv) anime=(/media/anime) music=(/media/music) books=(/media/books /media/comics)
  if [[ "$QNAP_ENABLED" == "1" ]]; then
    [[ -d /qnap_media/movies ]] && movies+=(/qnap_media/movies)
    [[ -d /qnap_media/tv ]] && tv+=(/qnap_media/tv)
    [[ -d /qnap_media/anime ]] && anime+=(/qnap_media/anime)
    [[ -d /qnap_media/music ]] && music+=(/qnap_media/music)
    [[ -d /qnap_media/books ]] && books+=(/qnap_media/books)
    [[ -d /qnap_media/comics ]] && books+=(/qnap_media/comics)
  fi
  add_jellyfin_library "$token" Movies movies "${movies[@]}"
  add_jellyfin_library "$token" 'TV Shows' tvshows "${tv[@]}"
  add_jellyfin_library "$token" Anime tvshows "${anime[@]}"
  add_jellyfin_library "$token" Music music "${music[@]}"
  add_jellyfin_library "$token" Books books "${books[@]}"
  curl -fsS -X POST -H "X-Emby-Token: ${token}" http://127.0.0.1:8096/Library/Refresh >/dev/null
}

configure_seerr() {
  local username password cookie public initialized server_type login_body libraries enabled_ids init_response
  local sonarr_key radarr_key
  username="$(env_value JELLYFIN_ADMIN_USER admin)"
  password="$(env_value JELLYFIN_ADMIN_PASSWORD)"
  cookie="$(mktemp)"
  chmod 0600 "$cookie"
  public="$(curl -fsS http://127.0.0.1:5055/api/v1/settings/public)" || return 1
  initialized="$(jq -r '.initialized // false' <<<"$public")" || return 1
  server_type="$(jq -r '.mediaServerType // 4' <<<"$public")" || return 1
  if [[ "$initialized" != "true" ]]; then
    info "Initializing Seerr with Jellyfin"
  fi
  if [[ "$server_type" == "4" ]]; then
    login_body="$(jq -n --arg username "$username" --arg password "$password" \
      '{username:$username,password:$password,hostname:"jellyfin",port:8096,useSsl:false,urlBase:"",email:"",serverType:2}')" || return 1
  else
    login_body="$(jq -n --arg username "$username" --arg password "$password" \
      '{username:$username,password:$password}')" || return 1
  fi
  curl -fsS -c "$cookie" -X POST http://127.0.0.1:5055/api/v1/auth/jellyfin \
    -H 'Content-Type: application/json' -d "$login_body" >/dev/null || return 1

  sonarr_key="$(cat "${APP_DIR}/.sonarr-api-key")"
  radarr_key="$(cat "${APP_DIR}/.radarr-api-key")"
  configure_seerr_arr sonarr 8989 "$sonarr_key" /data/media/tv "$cookie" || return 1
  configure_seerr_arr radarr 7878 "$radarr_key" /data/media/movies "$cookie" || return 1

  libraries="$(curl -fsS -b "$cookie" 'http://127.0.0.1:5055/api/v1/settings/jellyfin/library?sync=true')" || return 1
  enabled_ids="$(jq -r '[.[].id] | map(tostring) | join(",")' <<<"$libraries")" || return 1
  if [[ -n "$enabled_ids" ]]; then
    curl -fsS -G -b "$cookie" \
      --data-urlencode 'sync=true' \
      --data-urlencode "enable=${enabled_ids}" \
      http://127.0.0.1:5055/api/v1/settings/jellyfin/library >/dev/null || return 1
  fi
  if [[ "$initialized" != "true" ]]; then
    init_response="$(curl -fsS -b "$cookie" -X POST http://127.0.0.1:5055/api/v1/settings/initialize)" || return 1
    jq -e '.initialized == true' <<<"$init_response" >/dev/null || return 1
    curl -fsS -b "$cookie" -X POST http://127.0.0.1:5055/api/v1/settings/main \
      -H 'Content-Type: application/json' -d '{"locale":"en"}' >/dev/null || return 1
  fi
  rm -f "$cookie"
}

configure_seerr_arr() {
  local service="$1" port="$2" key="$3" root="$4" cookie="$5"
  local current test_payload test_response profile_id profile_name final_payload
  current="$(curl -fsS -b "$cookie" "http://127.0.0.1:5055/api/v1/settings/${service}")" || return 1
  if jq -e 'length > 0' <<<"$current" >/dev/null; then
    info "Seerr already has ${service}; leaving it unchanged"
    return
  fi
  test_payload="$(jq -n --arg hostname "$service" --arg key "$key" --argjson port "$port" \
    '{hostname:$hostname,port:$port,apiKey:$key,useSsl:false,baseUrl:""}')"
  test_response="$(curl -fsS -b "$cookie" -X POST "http://127.0.0.1:5055/api/v1/settings/${service}/test" \
    -H 'Content-Type: application/json' -d "$test_payload")" || return 1
  profile_id="$(jq -er '.profiles[0].id' <<<"$test_response")" || return 1
  profile_name="$(jq -er '.profiles[0].name' <<<"$test_response")" || return 1
  if [[ "$service" == "radarr" ]]; then
    final_payload="$(jq -n --arg key "$key" --arg root "$root" --arg profile_name "$profile_name" \
      --argjson profile_id "$profile_id" \
      '{name:"Radarr",hostname:"radarr",port:7878,apiKey:$key,useSsl:false,baseUrl:"",activeProfileId:$profile_id,activeProfileName:$profile_name,activeDirectory:$root,is4k:false,minimumAvailability:"released",isDefault:true,externalUrl:"",syncEnabled:true,preventSearch:false}')"
  else
    final_payload="$(jq -n --arg key "$key" --arg root "$root" --arg profile_name "$profile_name" \
      --argjson profile_id "$profile_id" \
      '{name:"Sonarr",hostname:"sonarr",port:8989,apiKey:$key,useSsl:false,baseUrl:"",activeProfileId:$profile_id,activeProfileName:$profile_name,activeDirectory:$root,is4k:false,enableSeasonFolders:true,isDefault:true,externalUrl:"",syncEnabled:true,preventSearch:false}')"
  fi
  curl -fsS -b "$cookie" -X POST "http://127.0.0.1:5055/api/v1/settings/${service}" \
    -H 'Content-Type: application/json' -d "$final_payload" >/dev/null || return 1
  info "Connected Seerr to ${service}"
}

homarr_trpc_query() {
  local procedure="$1" response code
  response="$(mktemp)"
  code="$(curl -sS --max-time 30 -o "$response" -w '%{http_code}' \
    -G --data-urlencode 'input={"json":null}' \
    -H 'x-trpc-source: mediastack-installer' \
    "http://127.0.0.1:7575/api/trpc/${procedure}" || true)"
  if [[ "$code" != "200" ]] ||
    ! jq -e 'has("result") and (has("error") | not)' "$response" >/dev/null 2>&1; then
    rm -f "$response"
    return 1
  fi
  cat "$response"
  rm -f "$response"
}

homarr_trpc_mutate() {
  local procedure="$1" input="${2:-null}" response request code
  response="$(mktemp)"
  request="$(jq -cn --argjson value "$input" '{json:$value}')"
  code="$(curl -sS --max-time 90 -o "$response" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -H 'x-trpc-source: mediastack-installer' \
    -d "$request" \
    "http://127.0.0.1:7575/api/trpc/${procedure}" || true)"
  if [[ "$code" != "200" ]] ||
    ! jq -e 'has("result") and (has("error") | not)' "$response" >/dev/null 2>&1; then
    warn "Homarr procedure ${procedure} returned HTTP ${code:-none}."
    rm -f "$response"
    return 1
  fi
  rm -f "$response"
}

homarr_onboarding_step() {
  local response
  response="$(homarr_trpc_query onboard.currentStep)" ||
    die "Could not read Homarr's onboarding state."
  jq -er '.result.data.json.current // .result.data.current' <<<"$response"
}

configure_homarr() {
  local username password step lxc_ip apps payload attempt
  username="$(env_value HOMARR_ADMIN_USER "$(env_value MEDIASTACK_ADMIN_USER admin)")"
  username="$(tr '[:upper:]' '[:lower:]' <<<"$username" | xargs)"
  password="$(env_value HOMARR_ADMIN_PASSWORD "$(env_value MEDIASTACK_ADMIN_PASSWORD)")"
  [[ "$username" =~ ^[a-z0-9][a-z0-9._-]{2,31}$ ]] ||
    die "Homarr's admin username must be 3-32 letters, numbers, dots, underscores, or hyphens."
  [[ ${#password} -ge 8 ]] || die "Homarr's admin password must contain at least eight characters."

  info "Initializing Homarr's admin login and media dashboard"
  for ((attempt = 1; attempt <= 8; attempt++)); do
    step="$(homarr_onboarding_step)"
    case "$step" in
      start)
        homarr_trpc_mutate onboard.nextStep '{}' ||
          die "Homarr did not advance from its start screen."
        ;;
      user)
        payload="$(jq -cn --arg username "$username" --arg password "$password" \
          '{username:$username,password:$password,confirmPassword:$password}')"
        homarr_trpc_mutate user.initUser "$payload" ||
          die "Homarr did not create its shared admin account."
        ;;
      settings)
        payload='{"analytics":{"enableGeneral":false},"crawlingAndIndexing":{"noIndex":true,"noFollow":true,"noTranslate":true,"noSiteLinksSearchBox":false}}'
        homarr_trpc_mutate serverSettings.initSettings "$payload" ||
          die "Homarr did not save its initial settings."
        ;;
      integrations)
        if [[ ! -f "${APP_DIR}/.homarr-apps-created" ]]; then
          lxc_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
          [[ -n "$lxc_ip" ]] || lxc_ip="$(hostname -I | awk '{print $1}')"
          [[ -n "$lxc_ip" ]] || die "Could not determine the LXC IPv4 address for Homarr links."
          apps="$(jq -cn --arg ip "$lxc_ip" '[
            {name:"Media Stack Home",href:("http://"+$ip+":8088"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/homarr.svg"},
            {name:"Jellyfin",href:("http://"+$ip+":8096"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/jellyfin.svg"},
            {name:"Seerr",href:("http://"+$ip+":5055"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/seerr.svg"},
            {name:"Jellystat",href:("http://"+$ip+":3000"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/jellystat.svg"},
            {name:"Wizarr",href:("http://"+$ip+":5690"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/wizarr.svg"},
            {name:"Sonarr",href:("http://"+$ip+":8989"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/sonarr.svg"},
            {name:"Radarr",href:("http://"+$ip+":7878"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/radarr.svg"},
            {name:"Lidarr",href:("http://"+$ip+":8686"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/lidarr.svg"},
            {name:"Prowlarr",href:("http://"+$ip+":9696"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/prowlarr.svg"},
            {name:"Bazarr",href:("http://"+$ip+":6767"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/bazarr.svg"},
            {name:"qBittorrent",href:("http://"+$ip+":8080"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/qbittorrent.svg"},
            {name:"Profilarr",href:("http://"+$ip+":6868"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/profilarr.svg"},
            {name:"Kavita",href:("http://"+$ip+":5000"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/kavita.svg"},
            {name:"Mylar",href:("http://"+$ip+":8090"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/mylar.svg"},
            {name:"Byparr",href:("http://"+$ip+":8191"),iconUrl:null},
            {name:"Portainer",href:("https://"+$ip+":9443"),iconUrl:"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/portainer.svg"}
          ]')"
          homarr_trpc_mutate onboard.createAppsFromDiscovery "$apps" ||
            die "Homarr did not create the media-stack application links."
          touch "${APP_DIR}/.homarr-apps-created"
        fi
        homarr_trpc_mutate onboard.setupIntegrations 'null' ||
          die "Homarr did not build its initial dashboard."
        ;;
      finish)
        if ! docker exec homarr homarr users list 2>/dev/null |
          awk -F '\t' -v expected="$username" 'NR > 1 && tolower($2) == expected { found=1 } END { exit(found ? 0 : 1) }'; then
          die "Homarr finished onboarding, but the shared admin user is missing."
        fi
        info "Homarr admin login and application dashboard are ready"
        return
        ;;
      import|group)
        homarr_trpc_mutate onboard.nextStep '{}' ||
          die "Homarr could not skip the unused ${step} onboarding step."
        ;;
      *)
        die "Homarr returned an unknown onboarding step: ${step:-empty}."
        ;;
    esac
  done
  die "Homarr onboarding did not finish."
}

main() {
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}."
  command -v curl >/dev/null 2>&1 || die "curl is required."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  command -v python3 >/dev/null 2>&1 || die "python3 is required."
  [[ "$DOWNLOADS_ENABLED" == "0" || "$DOWNLOADS_ENABLED" == "1" ]] ||
    die "DOWNLOADS_ENABLED must be 0 or 1."

  validate_storage
  # Portainer closes its first-admin endpoint after five minutes. Initialize it
  # before waiting for any slower media or VPN container.
  wait_for_container portainer
  wait_for_url Portainer https://127.0.0.1:9443/api/system/status 90
  configure_portainer

  for container in sonarr radarr lidarr prowlarr bazarr jellyfin jellyseerr profilarr mediastack-home homarr; do
    wait_for_container "$container"
  done
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    wait_for_container gluetun
    wait_for_container qbittorrent
    wait_for_url qBittorrent http://127.0.0.1:8080 90
  else
    warn "VPN credentials are pending; qBittorrent and its Arr download-client connections will be configured later."
  fi
  wait_for_url Sonarr http://127.0.0.1:8989 90
  wait_for_url Radarr http://127.0.0.1:7878 90
  wait_for_url Lidarr http://127.0.0.1:8686 90
  wait_for_url Prowlarr http://127.0.0.1:9696 90
  wait_for_url Bazarr http://127.0.0.1:6767 90
  wait_for_url Jellyfin http://127.0.0.1:8096/health 90
  wait_for_url 'Jellyfin API' http://127.0.0.1:8096/System/Info/Public 120
  wait_for_url Seerr http://127.0.0.1:5055/api/v1/settings/public 90
  wait_for_url Profilarr http://127.0.0.1:6868/auth/setup 90
  wait_for_url 'Media Stack Home' http://127.0.0.1:8088 60
  wait_for_url Homarr http://127.0.0.1:7575 120

  configure_arr_roots
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    configure_qbittorrent
    configure_arr_downloads
  fi
  configure_prowlarr
  configure_bazarr
  configure_recyclarr
  configure_profilarr
  configure_jellyfin
  if ! (configure_seerr); then
    warn "Automatic Seerr setup did not finish; complete its setup at port 5055."
  fi
  configure_homarr

  cat >"${APP_DIR}/INSTALL-RESULTS.txt" <<EOF
Automatic media-stack configuration completed.

- Primary media and torrent paths were validated for the configured PUID/PGID.
- Sonarr, Radarr, and Lidarr use the shared /data/media roots.
- Prowlarr syncs indexers to Sonarr, Radarr, and Lidarr.
- Bazarr is connected to Sonarr and Radarr.
- Jellyfin has Movies, TV Shows, Anime, Music, and Books libraries.
- Recyclarr applied a TRaSH Guides baseline (Sonarr WEB-1080p, Radarr HD Bluray + WEB) when enabled; Profilarr provides the full TRaSH GUI for customization.
- Profilarr provides the normal TRaSH Guides web UI and is preconnected to Sonarr/Radarr.
- Portainer is initialized with the shared admin login and local Docker environment.
- Homarr is initialized with the shared admin login and a populated media-stack dashboard.
- Media Stack Home on port 8088 links every user-facing application.

The shared UI login is stored only in /opt/mediastack/.env (mode 0600).
EOF
  if [[ "$DOWNLOADS_ENABLED" == "1" ]]; then
    cat >>"${APP_DIR}/INSTALL-RESULTS.txt" <<'EOF'
- qBittorrent uses /data/torrents and has per-application categories.
- Sonarr, Radarr, and Lidarr download through qBittorrent via Gluetun.
EOF
  else
    cat >>"${APP_DIR}/INSTALL-RESULTS.txt" <<'EOF'

VPN setup is pending. Add real NORDVPN_USER and NORDVPN_PASS values, then run:
  /usr/local/sbin/mediastack-finish-setup
EOF
  fi
  chmod 0644 "${APP_DIR}/INSTALL-RESULTS.txt"
  info "Automatic media-stack configuration completed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
