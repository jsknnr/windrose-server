#!/bin/bash
# shellcheck disable=SC2317
#
# Windrose Dedicated Server container entrypoint.
#
# Updates the server via SteamCMD, brings up a Wine environment (with an
# optional Xvfb display), applies configuration overrides from environment
# variables, launches the server, and forwards signals so the container
# shuts down cleanly.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log() {
  local level=$1
  shift
  printf '%s %s: %s\n' "$(date +'%Y-%m-%d %H:%M:%S,%3N')" "${level}" "$*"
}

fail() {
  log ERROR "$*"
  exit 1
}

require_env() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "Required environment variable is not set: ${name}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

require_env STEAMCMD_PATH
require_env WINDROSE_PATH
require_env STEAM_APP_ID
require_env WINEPREFIX

readonly STEAMCMD_BIN="${STEAMCMD_PATH}/steamcmd.sh"
readonly STEAM_MANIFEST_DIR="${WINDROSE_PATH}/steamapps"

readonly R5_DIR="${WINDROSE_PATH}/R5"
readonly SERVER_BIN="${R5_DIR}/Binaries/Win64/WindroseServer-Win64-Shipping.exe"
readonly SERVER_BIN_NAME="${SERVER_BIN##*/}"
readonly SERVER_DESC_FILE="${R5_DIR}/ServerDescription.json"
readonly WORLD_DESC_GLOB="${R5_DIR}/Saved/SaveProfiles/Default/RocksDB*/*/Worlds/*/WorldDescription.json"

WINE_BIN="$(command -v wine64 || command -v wine || true)"
WINESERVER_BIN="$(command -v wineserver || true)"
readonly WINE_BIN WINESERVER_BIN

readonly XVFB_DISPLAY="${XVFB_DISPLAY:-:0}"
readonly XVFB_RESOLUTION="${XVFB_RESOLUTION:-1024x768x24}"

readonly SKIP_CONFIG="${SKIP_CONFIG:-false}"
readonly BOOTSTRAP_TIMEOUT_SECS="${BOOTSTRAP_TIMEOUT_SECS:-300}"
readonly BOOTSTRAP_SETTLE_SECS="${BOOTSTRAP_SETTLE_SECS:-3}"
readonly SERVER_STOP_TIMEOUT_SECS="${SERVER_STOP_TIMEOUT_SECS:-30}"
readonly SERVER_KILL_TIMEOUT_SECS="${SERVER_KILL_TIMEOUT_SECS:-10}"

export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-steam}"
export WINEPREFIX

# ---------------------------------------------------------------------------
# Process tracking and signal handling
# ---------------------------------------------------------------------------

SERVER_PID=""
XVFB_PID=""
SHUTTING_DOWN=0

server_running() {
  pgrep -f "${SERVER_BIN_NAME}" >/dev/null 2>&1
}

reap_server_pid() {
  if [[ -n "${SERVER_PID}" ]]; then
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
}

# Stop the dedicated server. SIGINT to the wine process is forwarded by Wine
# as a CTRL_C_EVENT to the attached Windows console, which Unreal handles
# gracefully. Falls back to wineserver -k and finally SIGKILL on timeout.
stop_server() {
  local soft_timeout=${SERVER_STOP_TIMEOUT_SECS}
  local hard_timeout=${SERVER_KILL_TIMEOUT_SECS}

  if ! server_running; then
    reap_server_pid
    return 0
  fi

  local -a pids
  mapfile -t pids < <(pgrep -f "${SERVER_BIN_NAME}" 2>/dev/null || true)

  log INFO "Sending SIGINT to ${SERVER_BIN_NAME} (pids: ${pids[*]:-none})"
  (( ${#pids[@]} > 0 )) && kill -INT "${pids[@]}" 2>/dev/null || true

  local elapsed=0
  while (( elapsed < soft_timeout )) && server_running; do
    sleep 1
    ((elapsed += 1))
  done

  if server_running; then
    log WARN "Server did not exit within ${soft_timeout}s; killing wineserver"
    "${WINESERVER_BIN}" -k >/dev/null 2>&1 || true

    elapsed=0
    while (( elapsed < hard_timeout )) && server_running; do
      sleep 1
      ((elapsed += 1))
    done
  fi

  if server_running; then
    log ERROR "Server still running after wineserver -k; sending SIGKILL"
    pkill -KILL -f "${SERVER_BIN_NAME}" 2>/dev/null || true
  fi

  reap_server_pid
}

shutdown() {
  local signal=$1

  (( SHUTTING_DOWN == 0 )) || return
  SHUTTING_DOWN=1

  log INFO "Received ${signal}, forwarding shutdown to Windrose server"
  stop_server

  if [[ -n "${XVFB_PID}" ]] && kill -0 "${XVFB_PID}" 2>/dev/null; then
    kill "${XVFB_PID}" 2>/dev/null || true
    wait "${XVFB_PID}" 2>/dev/null || true
    XVFB_PID=""
  fi
}

on_error() {
  log ERROR "entrypoint.sh failed at line $2 with exit code $1"
}

trap 'shutdown SIGINT'  INT
trap 'shutdown SIGTERM' TERM
trap 'on_error $? $LINENO' ERR

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

preflight() {
  [[ -x "${STEAMCMD_BIN}" ]]    || fail "steamcmd not found or not executable: ${STEAMCMD_BIN}"
  [[ -n "${WINE_BIN}" ]]        || fail "wine was not found in PATH"
  [[ -n "${WINESERVER_BIN}" ]]  || fail "wineserver was not found in PATH"
  [[ -d "${WINDROSE_PATH}" ]]   || fail "Windrose install directory does not exist: ${WINDROSE_PATH}"
  command -v jq    >/dev/null   || fail "jq was not found in PATH"
  command -v pgrep >/dev/null   || fail "pgrep was not found in PATH"
}

# ---------------------------------------------------------------------------
# Steam update
# ---------------------------------------------------------------------------

update_server() {
  # Clear stale manifests left behind by interrupted Steam updates.
  rm -f "${STEAM_MANIFEST_DIR}/appmanifest_"*.acf >/dev/null 2>&1 || true

  log INFO "Updating Windrose Dedicated Server"
  "${STEAMCMD_BIN}" \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "${WINDROSE_PATH}" \
    +login anonymous \
    +app_update "${STEAM_APP_ID}" validate \
    +quit

  [[ -f "${SERVER_BIN}" ]] || fail "Windrose server binary was not found after update: ${SERVER_BIN}"
}

# ---------------------------------------------------------------------------
# Display (Xvfb)
# ---------------------------------------------------------------------------

wait_for_xvfb() {
  local socket="/tmp/.X11-unix/X${XVFB_DISPLAY#:}"
  local i

  for (( i = 0; i < 50; i++ )); do
    [[ -S "${socket}" ]] && return 0
    [[ -n "${XVFB_PID}" ]] && ! kill -0 "${XVFB_PID}" 2>/dev/null && return 1
    sleep 0.1
  done
  return 1
}

ensure_display() {
  if [[ -n "${DISPLAY:-}" ]]; then
    log INFO "Using existing DISPLAY=${DISPLAY}"
    return
  fi

  log INFO "DISPLAY is not set; starting Xvfb on ${XVFB_DISPLAY}"
  Xvfb "${XVFB_DISPLAY}" -screen 0 "${XVFB_RESOLUTION}" -nolisten tcp &
  XVFB_PID=$!

  wait_for_xvfb || fail "Xvfb failed to start on ${XVFB_DISPLAY}"

  export DISPLAY="${XVFB_DISPLAY}"
  export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11,windows}"
}

# ---------------------------------------------------------------------------
# Wine prefix
# ---------------------------------------------------------------------------

ensure_wine_prefix() {
  if [[ -f "${WINEPREFIX}/system.reg" ]]; then
    log INFO "Refreshing Wine prefix"
    "${WINE_BIN}" wineboot -u
  else
    log INFO "Initializing Wine prefix at ${WINEPREFIX}"
    "${WINE_BIN}" wineboot --init
  fi
}

# ---------------------------------------------------------------------------
# Config discovery
# ---------------------------------------------------------------------------

# Locate the WorldDescription.json the server generates under Saved/.
# Prints the path on success.
find_world_desc() {
  local path
  for path in ${WORLD_DESC_GLOB}; do
    [[ -f "${path}" ]] && { printf '%s\n' "${path}"; return 0; }
  done
  return 1
}

config_files_exist() {
  [[ -f "${SERVER_DESC_FILE}" ]] && find_world_desc >/dev/null
}

# ---------------------------------------------------------------------------
# Bootstrap: run the server once to let it generate default config files,
# then stop it so we can edit those files before the real launch.
# ---------------------------------------------------------------------------

bootstrap_config() {
  log INFO "Config files missing; starting server to generate defaults"

  "${WINE_BIN}" "${SERVER_BIN}" &
  SERVER_PID=$!

  local elapsed=0
  local started=0
  while (( elapsed < BOOTSTRAP_TIMEOUT_SECS )); do
    if config_files_exist; then
      log INFO "Default config files detected; waiting ${BOOTSTRAP_SETTLE_SECS}s for writes to settle"
      sleep "${BOOTSTRAP_SETTLE_SECS}"
      break
    fi

    # Only treat "not running" as failure once we've actually seen it run,
    # since pgrep won't match during the first second or two of startup.
    if server_running; then
      started=1
    elif (( started )); then
      stop_server
      fail "Server exited before generating configuration files"
    fi

    sleep 1
    ((elapsed += 1))
  done

  log INFO "Stopping bootstrap server"
  stop_server

  config_files_exist \
    || fail "Config files did not appear within ${BOOTSTRAP_TIMEOUT_SECS}s"
}

# ---------------------------------------------------------------------------
# JSON patching helpers
# ---------------------------------------------------------------------------

# Rewrite a JSON file in place by running the given jq filter. Extra arguments
# (e.g. --arg, --argjson) are forwarded to jq.
json_patch() {
  local file=$1 filter=$2
  shift 2
  local tmp
  tmp="$(mktemp)"
  jq "$@" "${filter}" "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

to_bool_json() {
  case "${1,,}" in
    true|1|yes|on)        echo true  ;;
    false|0|no|off|'')    echo false ;;
    *) fail "Expected boolean value, got: $1" ;;
  esac
}

# Set a world parameter keyed by a "WDS.Parameter.<suffix>" tag string.
#   $1 = file, $2 = category (BoolParameters|FloatParameters|TagParameters)
#   $3 = tag suffix, $4 = JSON-encoded value
world_param_patch() {
  local file=$1 category=$2 tag=$3 value=$4
  local key="{\"TagName\": \"WDS.Parameter.${tag}\"}"
  json_patch "${file}" \
    ".WorldDescription.WorldSettings.${category}[\$k] = \$v" \
    --arg k "${key}" --argjson v "${value}"
}

# ---------------------------------------------------------------------------
# Apply overrides: ServerDescription.json
# ---------------------------------------------------------------------------

apply_server_desc() {
  local file=${SERVER_DESC_FILE}
  local changed=0

  if [[ -n "${WINDROSE_SERVER_NAME+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.ServerName = $v' \
      --arg v "${WINDROSE_SERVER_NAME}"
    changed=1
  fi

  if [[ -n "${WINDROSE_INVITE_CODE+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.InviteCode = $v' \
      --arg v "${WINDROSE_INVITE_CODE}"
    changed=1
  fi

  if [[ -n "${WINDROSE_PASSWORD+x}" ]]; then
    local protected=true
    [[ -z "${WINDROSE_PASSWORD}" ]] && protected=false
    json_patch "${file}" '.ServerDescription_Persistent.Password = $v' \
      --arg v "${WINDROSE_PASSWORD}"
    json_patch "${file}" '.ServerDescription_Persistent.IsPasswordProtected = $v' \
      --argjson v "${protected}"
    changed=1
  fi

  if [[ -n "${WINDROSE_MAX_PLAYERS+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.MaxPlayerCount = $v' \
      --argjson v "${WINDROSE_MAX_PLAYERS}"
    changed=1
  fi

  if [[ -n "${WINDROSE_P2P_PROXY_ADDRESS+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.P2pProxyAddress = $v' \
      --arg v "${WINDROSE_P2P_PROXY_ADDRESS}"
    changed=1
  fi

  if [[ -n "${WINDROSE_REGION+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.UserSelectedRegion = $v' \
      --arg v "${WINDROSE_REGION}"
    changed=1
  fi

  if [[ -n "${WINDROSE_USE_DIRECT_CONNECTION+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.UseDirectConnection = $v' \
      --argjson v "$(to_bool_json "${WINDROSE_USE_DIRECT_CONNECTION}")"
    changed=1
  fi

  if [[ -n "${WINDROSE_DIRECT_CONNECTION_ADDRESS+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.DirectConnectionServerAddress = $v' \
      --arg v "${WINDROSE_DIRECT_CONNECTION_ADDRESS}"
    changed=1
  fi

  if [[ -n "${WINDROSE_DIRECT_CONNECTION_PORT+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.DirectConnectionServerPort = $v' \
      --argjson v "${WINDROSE_DIRECT_CONNECTION_PORT}"
    changed=1
  fi

  if [[ -n "${WINDROSE_DIRECT_CONNECTION_PROXY_ADDRESS+x}" ]]; then
    json_patch "${file}" '.ServerDescription_Persistent.DirectConnectionProxyAddress = $v' \
      --arg v "${WINDROSE_DIRECT_CONNECTION_PROXY_ADDRESS}"
    changed=1
  fi

  if (( changed )); then
    log INFO "Applied ServerDescription overrides"
  fi
}

# ---------------------------------------------------------------------------
# Apply overrides: WorldDescription.json
# ---------------------------------------------------------------------------

apply_world_desc() {
  local file
  file="$(find_world_desc)" || fail "WorldDescription.json not found"

  local changed=0

  if [[ -n "${WINDROSE_WORLD_NAME+x}" ]]; then
    json_patch "${file}" '.WorldDescription.WorldName = $v' \
      --arg v "${WINDROSE_WORLD_NAME}"
    changed=1
  fi

  if [[ -n "${WINDROSE_WORLD_PRESET+x}" ]]; then
    case "${WINDROSE_WORLD_PRESET}" in
      Easy|Medium|Hard|Custom) ;;
      *) fail "WINDROSE_WORLD_PRESET must be Easy|Medium|Hard|Custom, got: ${WINDROSE_WORLD_PRESET}" ;;
    esac
    json_patch "${file}" '.WorldDescription.WorldPresetType = $v' \
      --arg v "${WINDROSE_WORLD_PRESET}"
    changed=1
  fi

  if [[ -n "${WINDROSE_WORLD_COOP_QUESTS+x}" ]]; then
    world_param_patch "${file}" BoolParameters "Coop.SharedQuests" \
      "$(to_bool_json "${WINDROSE_WORLD_COOP_QUESTS}")"
    changed=1
  fi

  if [[ -n "${WINDROSE_WORLD_EASY_EXPLORE+x}" ]]; then
    world_param_patch "${file}" BoolParameters "EasyExplore" \
      "$(to_bool_json "${WINDROSE_WORLD_EASY_EXPLORE}")"
    changed=1
  fi

  # Map of env var -> tag suffix for float-valued world parameters.
  local -A float_params=(
    [WINDROSE_WORLD_MOB_HEALTH_MULTIPLIER]="MobHealthMultiplier"
    [WINDROSE_WORLD_MOB_DAMAGE_MULTIPLIER]="MobDamageMultiplier"
    [WINDROSE_WORLD_SHIP_HEALTH_MULTIPLIER]="ShipsHealthMultiplier"
    [WINDROSE_WORLD_SHIP_DAMAGE_MULTIPLIER]="ShipsDamageMultiplier"
    [WINDROSE_WORLD_BOARDING_DIFFICULTY_MULTIPLIER]="BoardingDifficultyMultiplier"
    [WINDROSE_WORLD_COOP_STATS_CORRECTION_MODIFIER]="Coop.StatsCorrectionModifier"
    [WINDROSE_WORLD_COOP_SHIP_STATS_CORRECTION_MODIFIER]="Coop.ShipStatsCorrectionModifier"
  )

  local var
  for var in "${!float_params[@]}"; do
    if [[ -n "${!var+x}" ]]; then
      world_param_patch "${file}" FloatParameters "${float_params[$var]}" "${!var}"
      changed=1
    fi
  done

  if [[ -n "${WINDROSE_WORLD_COMBAT_DIFFICULTY+x}" ]]; then
    case "${WINDROSE_WORLD_COMBAT_DIFFICULTY}" in
      Easy|Normal|Hard) ;;
      *) fail "WINDROSE_WORLD_COMBAT_DIFFICULTY must be Easy|Normal|Hard, got: ${WINDROSE_WORLD_COMBAT_DIFFICULTY}" ;;
    esac
    local combat_value
    combat_value=$(jq -n --arg t "WDS.Parameter.CombatDifficulty.${WINDROSE_WORLD_COMBAT_DIFFICULTY}" \
      '{TagName: $t}')
    world_param_patch "${file}" TagParameters "CombatDifficulty" "${combat_value}"
    changed=1
  fi

  if (( changed )); then
    log INFO "Applied WorldDescription overrides"
  fi
}

# ---------------------------------------------------------------------------
# Config orchestration
# ---------------------------------------------------------------------------

prepare_config() {
  if [[ "${SKIP_CONFIG,,}" == "true" ]]; then
    log INFO "SKIP_CONFIG=true; leaving configuration files untouched"
    [[ -f "${SERVER_DESC_FILE}" ]] \
      || fail "SKIP_CONFIG is set but ServerDescription.json is missing"
    find_world_desc >/dev/null \
      || fail "SKIP_CONFIG is set but WorldDescription.json is missing"
    return
  fi

  if ! config_files_exist; then
    bootstrap_config
  fi

  apply_server_desc
  apply_world_desc
}

# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

run_server() {
  log INFO "Starting Windrose Dedicated Server"
  "${WINE_BIN}" "${SERVER_BIN}" &
  SERVER_PID=$!

  local exit_code=0
  wait "${SERVER_PID}" || exit_code=$?
  SERVER_PID=""

  if (( exit_code == 0 )); then
    log INFO "Windrose Dedicated Server exited cleanly"
  else
    log ERROR "Windrose Dedicated Server exited with code ${exit_code}"
  fi

  return "${exit_code}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  preflight
  update_server
  ensure_display
  ensure_wine_prefix
  prepare_config

  local exit_code=0
  run_server || exit_code=$?
  exit "${exit_code}"
}

main "$@"
