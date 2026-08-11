#!/usr/bin/env bash
# upgrade-to-0.12.5.sh — upgrade an existing EveJS / evejs-xeve install to stock 0.12.5
#
# You must supply the official EveJS v0.12.5 release yourself (zip or extracted folder).
# This script never downloads it.
#
# Typical use (from your current server tree):
#   tools/evejs-upgrade/upgrade-to-0.12.5.sh
#   tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ~/Downloads/EveJS\ -\ v0.12.5.zip
#   tools/evejs-upgrade/upgrade-to-0.12.5.sh --source /path/to/v0.12.5 --root /path/to/install
#
# Safe defaults:
#   - stops Docker compose
#   - creates a tree backup next to the install
#   - creates a universe snapshot if tools/server-snapshot is present
#   - reuses the existing Docker data volume (accounts/characters/market)
#   - copies certs, _local/, custom tools, LAN override, and character portraits
#   - drops X-Eve / Living Universe code (not present in stock 0.12.5)
#   - optionally keeps solo skill/structure timers from the old install
#
set -euo pipefail

TOOL_NAME="evejs-upgrade"
TOOL_VERSION="1.0.0"
TARGET_VERSION="0.12.5"

log()  { printf '%s\n' "$*"; }
ok()   { printf '  OK  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*"; }
err()  { printf ' FAIL %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '  ..  %s\n' "$*"; }
header() {
  printf '\n============================================================\n'
  printf '  %s\n' "$*"
  printf '============================================================\n'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZIP_PATH=""
SOURCE_DIR=""
ROOT=""
KEEP_TIMERS=1
SKILL_SPEED=""
UPWELL_SCALE=""
DO_BUILD=1
DO_START=1
DO_SNAPSHOT=1
DRY_RUN=0
ASSUME_YES=0
BACKUP_PARENT=""

usage() {
  cat <<EOF
${TOOL_NAME} v${TOOL_VERSION} — upgrade EveJS install → stock ${TARGET_VERSION}

USAGE
  upgrade-to-0.12.5.sh [options]

OPTIONS
  --zip PATH          Path to official "EveJS - v0.12.5.zip" (or similar)
  --source PATH       Path to already-extracted v0.12.5 folder (contains compose.yaml + config/)
  --root PATH         Install root to upgrade (default: EVEJS_ROOT, or cwd if it looks like EveJS)
  --backup-parent DIR Where to place the pre-upgrade tree backup (default: parent of --root)

  --keep-timers       Keep skillTrainingSpeed / upwellTimerScale from old config (default)
  --no-keep-timers    Use stock 1 / 1 timers from the release zip
  --skill-speed N     Force skillTrainingSpeed (e.g. 3600)
  --upwell-scale N    Force upwellTimerScale (e.g. 0.01)

  --skip-snapshot     Do not run tools/server-snapshot even if present
  --skip-build        Do not docker compose build
  --skip-start        Do not docker compose up after upgrade
  --yes               Non-interactive (required flags must still be valid)
  --dry-run           Print plan only
  -h, --help          This help

ZIP AUTO-DETECT
  If --zip / --source are omitted, searches common locations for a 0.12.5 zip/folder:
    \$HOME/Downloads, \$HOME/downloads, Desktop, cwd, parent of --root
  Names matched (case-insensitive): *0.12.5*, *v0.12.5*, EveJS*.zip

WHAT IS PRESERVED
  - Docker named volume (gameStore / market / SDE) — characters and accounts stay
  - server/certs (TLS)
  - _local/ (snapshots, LAN state, private tools data)
  - tools/ you added (lan-play, server-snapshot, solo-rpg-preset, …) merged back
  - compose.lan.yaml if present
  - Character / Alliance images under generated/ and migrated into the volume

WHAT GOES AWAY
  - X-Eve / Living Universe / Family Estate server code (not in stock 0.12.5)
  - Flat evejs.config*.json model → modular config/*.json

REQUIREMENTS
  - bash, docker (compose v2), unzip (for --zip), python3 (recommended)
  - Official EveJS ${TARGET_VERSION} zip or extracted tree
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --zip) ZIP_PATH="${2:-}"; shift 2 ;;
      --source) SOURCE_DIR="${2:-}"; shift 2 ;;
      --root) ROOT="${2:-}"; shift 2 ;;
      --backup-parent) BACKUP_PARENT="${2:-}"; shift 2 ;;
      --keep-timers) KEEP_TIMERS=1; shift ;;
      --no-keep-timers) KEEP_TIMERS=0; shift ;;
      --skill-speed) SKILL_SPEED="${2:-}"; shift 2 ;;
      --upwell-scale) UPWELL_SCALE="${2:-}"; shift 2 ;;
      --skip-snapshot) DO_SNAPSHOT=0; shift ;;
      --skip-build) DO_BUILD=0; shift ;;
      --skip-start) DO_START=0; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
  done
}

looks_like_evejs_root() {
  local d="$1"
  [[ -f "${d}/compose.yaml" || -f "${d}/compose.yml" ]] || return 1
  [[ -d "${d}/server" ]] || return 1
  return 0
}

looks_like_0125_tree() {
  local d="$1"
  [[ -f "${d}/compose.yaml" || -f "${d}/compose.yml" ]] || return 1
  [[ -d "${d}/config" ]] || return 1
  [[ -f "${d}/config/version.json" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$d/config/version.json" <<'PY' 2>/dev/null || return 1
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8")).get("evejsVersion", "")
sys.exit(0 if str(v).startswith("0.12.5") else 1)
PY
  else
    grep -q '0.12.5' "${d}/config/version.json" 2>/dev/null || return 1
  fi
  return 0
}

resolve_root() {
  if [[ -n "${ROOT}" ]]; then
    ROOT="$(cd "${ROOT}" && pwd)"
    looks_like_evejs_root "${ROOT}" || die "--root does not look like an EveJS install: ${ROOT}"
    return 0
  fi
  if [[ -n "${EVEJS_ROOT:-}" ]]; then
    ROOT="$(cd "${EVEJS_ROOT}" && pwd)"
    looks_like_evejs_root "${ROOT}" || die "EVEJS_ROOT does not look like EveJS: ${ROOT}"
    return 0
  fi
  if looks_like_evejs_root "${PWD}"; then
    ROOT="${PWD}"
    return 0
  fi
  # Script lives in tools/evejs-upgrade → parent of tools is install root
  local candidate
  candidate="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  if looks_like_evejs_root "${candidate}"; then
    ROOT="${candidate}"
    return 0
  fi
  die "Could not find EveJS root. Pass --root /path/to/install or cd there first."
}

find_zip_candidates() {
  local -a dirs=()
  local d
  for d in \
    "${HOME}/Downloads" \
    "${HOME}/downloads" \
    "${HOME}/Desktop" \
    "${HOME}/desktop" \
    "${PWD}" \
    "$(dirname "${ROOT}")" \
    "${ROOT}"
  do
    [[ -d "${d}" ]] && dirs+=("${d}")
  done
  # shellcheck disable=SC2068
  find "${dirs[@]}" -maxdepth 2 -type f \( \
    -iname '*0.12.5*.zip' -o -iname '*v0.12.5*.zip' -o -iname 'EveJS*.zip' \
  \) 2>/dev/null | sort -u
}

find_source_candidates() {
  local -a dirs=()
  local d
  for d in \
    "${HOME}/Downloads" \
    "${HOME}/downloads" \
    "/tmp" \
    "${PWD}" \
    "$(dirname "${ROOT}")"
  do
    [[ -d "${d}" ]] && dirs+=("${d}")
  done
  local cand
  while IFS= read -r cand; do
    [[ -d "${cand}" ]] || continue
    if looks_like_0125_tree "${cand}"; then
      printf '%s\n' "${cand}"
    elif [[ -d "${cand}/v0.12.5" ]] && looks_like_0125_tree "${cand}/v0.12.5"; then
      printf '%s\n' "${cand}/v0.12.5"
    fi
  done < <(find "${dirs[@]}" -maxdepth 3 -type d \( -iname 'v0.12.5' -o -iname '*0.12.5*' \) 2>/dev/null | sort -u)
}

resolve_release() {
  if [[ -n "${SOURCE_DIR}" ]]; then
    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"
    if [[ -d "${SOURCE_DIR}/v0.12.5" ]] && looks_like_0125_tree "${SOURCE_DIR}/v0.12.5"; then
      SOURCE_DIR="${SOURCE_DIR}/v0.12.5"
    fi
    looks_like_0125_tree "${SOURCE_DIR}" || die "--source is not a v0.12.5 tree: ${SOURCE_DIR}"
    ok "release tree: ${SOURCE_DIR}"
    return 0
  fi

  if [[ -z "${ZIP_PATH}" ]]; then
    local hits
    hits="$(find_zip_candidates || true)"
    if [[ -n "${hits}" ]]; then
      local count
      count="$(printf '%s\n' "${hits}" | grep -c . || true)"
      if [[ "${count}" -eq 1 ]]; then
        ZIP_PATH="$(printf '%s\n' "${hits}" | head -1)"
        info "auto-detected zip: ${ZIP_PATH}"
      else
        warn "Multiple zips found:"
        printf '%s\n' "${hits}" | sed 's/^/    /'
        if [[ "${ASSUME_YES}" -eq 1 ]]; then
          die "Pass --zip explicitly when multiple matches exist."
        fi
        read -r -p "Path to 0.12.5 zip (or empty to try extracted folders): " ZIP_PATH || true
      fi
    fi
  fi

  if [[ -z "${ZIP_PATH}" && -z "${SOURCE_DIR}" ]]; then
    local shits
    shits="$(find_source_candidates || true)"
    if [[ -n "${shits}" ]]; then
      local sc
      sc="$(printf '%s\n' "${shits}" | grep -c . || true)"
      if [[ "${sc}" -eq 1 ]]; then
        SOURCE_DIR="$(printf '%s\n' "${shits}" | head -1)"
        info "auto-detected extracted tree: ${SOURCE_DIR}"
      else
        warn "Multiple extracted 0.12.5 trees:"
        printf '%s\n' "${shits}" | sed 's/^/    /'
        if [[ "${ASSUME_YES}" -eq 1 ]]; then
          die "Pass --source or --zip explicitly when multiple matches exist."
        fi
        read -r -p "Path to extracted v0.12.5 folder: " SOURCE_DIR || true
      fi
    fi
  fi

  if [[ -n "${ZIP_PATH}" ]]; then
    [[ -f "${ZIP_PATH}" ]] || die "zip not found: ${ZIP_PATH}"
    command -v unzip >/dev/null 2>&1 || die "unzip is required to extract --zip"
    local extract_dir
    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/evejs-0.12.5-XXXXXX")"
    info "extracting zip → ${extract_dir}"
    unzip -q "${ZIP_PATH}" -d "${extract_dir}"
    if looks_like_0125_tree "${extract_dir}"; then
      SOURCE_DIR="${extract_dir}"
    elif looks_like_0125_tree "${extract_dir}/v0.12.5"; then
      SOURCE_DIR="${extract_dir}/v0.12.5"
    else
      # one top-level dir?
      local only
      only="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"
      if [[ -n "${only}" ]] && looks_like_0125_tree "${only}"; then
        SOURCE_DIR="${only}"
      else
        die "Zip did not contain a recognizable EveJS v0.12.5 tree (need config/version.json with evejsVersion 0.12.5)."
      fi
    fi
    ok "extracted release: ${SOURCE_DIR}"
    return 0
  fi

  if [[ -n "${SOURCE_DIR}" ]]; then
    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"
    looks_like_0125_tree "${SOURCE_DIR}" || die "Not a v0.12.5 tree: ${SOURCE_DIR}"
    ok "release tree: ${SOURCE_DIR}"
    return 0
  fi

  die "No EveJS v0.12.5 release found.
  Download the official zip, then re-run with:
    $0 --zip /path/to/EveJS-v0.12.5.zip
  or extract it and pass:
    $0 --source /path/to/v0.12.5"
}

detect_volume_name() {
  local compose="${ROOT}/compose.yaml"
  [[ -f "${compose}" ]] || compose="${ROOT}/compose.yml"
  local name=""
  if [[ -f "${compose}" ]]; then
    name="$(awk '
      /^volumes:/ {in_vol=1; next}
      in_vol && /^[^[:space:]#]/ {in_vol=0}
      in_vol && /name:[[:space:]]*/ {
        line=$0
        sub(/.*name:[[:space:]]*/, "", line)
        gsub(/["\r]/, "", line)
        print line
        exit
      }
    ' "${compose}" 2>/dev/null || true)"
  fi
  if [[ -z "${name}" ]]; then
    # common DML / X-Eve layout
    if docker volume inspect evejs-xeve-data >/dev/null 2>&1; then
      name="evejs-xeve-data"
    elif docker volume inspect evejs-data >/dev/null 2>&1; then
      name="evejs-data"
    else
      name="evejs-xeve-data"
    fi
  fi
  printf '%s\n' "${name}"
}

detect_project_name() {
  local compose="${ROOT}/compose.yaml"
  [[ -f "${compose}" ]] || compose="${ROOT}/compose.yml"
  local name=""
  if [[ -f "${compose}" ]]; then
    name="$(awk '/^name:/{print $2; exit}' "${compose}" 2>/dev/null | tr -d '\r' || true)"
  fi
  [[ -n "${name}" ]] || name="$(basename "${ROOT}")"
  printf '%s\n' "${name}"
}

read_old_timers() {
  # Prefer values already set via flags
  if [[ -n "${SKILL_SPEED}" && -n "${UPWELL_SCALE}" ]]; then
    return 0
  fi
  local skill="" upwell=""
  # New modular config
  if [[ -f "${ROOT}/config/gameplay.json" ]] && command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - "${ROOT}/config/gameplay.json" <<'PY'
import json, sys
p=sys.argv[1]
try:
  c=json.load(open(p,encoding="utf-8"))
except Exception:
  raise SystemExit(0)
sk=c.get("skills",{}).get("skillTrainingSpeed")
up=c.get("structures",{}).get("upwellTimerScale")
if sk is not None: print(f"skill={sk!r}")
if up is not None: print(f"upwell={up!r}")
PY
)"
    skill="${skill:-}"
    # shellcheck disable=SC2154
    :
  fi
  # Old flat configs
  local f
  for f in \
    "${ROOT}/evejs.config.local.json" \
    "${ROOT}/evejs.config.x-eve.local.json" \
    "${ROOT}/evejs.config.x-eve.json"
  do
    [[ -f "${f}" ]] || continue
    if [[ -z "${skill}" ]]; then
      skill="$(grep -oE '"skillTrainingSpeed"[[:space:]]*:[[:space:]]*[0-9.]+' "${f}" | tail -1 | grep -oE '[0-9.]+$' || true)"
    fi
    if [[ -z "${upwell}" ]]; then
      upwell="$(grep -oE '"upwellTimerScale"[[:space:]]*:[[:space:]]*[0-9.]+' "${f}" | tail -1 | grep -oE '[0-9.]+$' || true)"
    fi
  done
  # from python modular parse
  if command -v python3 >/dev/null 2>&1 && [[ -f "${ROOT}/config/gameplay.json" ]]; then
    local out
    out="$(python3 - "${ROOT}/config/gameplay.json" <<'PY'
import json, sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
sk=c.get("skills",{}).get("skillTrainingSpeed")
up=c.get("structures",{}).get("upwellTimerScale")
print(sk if sk is not None else "")
print(up if up is not None else "")
PY
)"
    skill="${skill:-$(printf '%s\n' "${out}" | sed -n '1p')}"
    upwell="${upwell:-$(printf '%s\n' "${out}" | sed -n '2p')}"
  fi

  [[ -n "${SKILL_SPEED}" ]] || SKILL_SPEED="${skill}"
  [[ -n "${UPWELL_SCALE}" ]] || UPWELL_SCALE="${upwell}"
}

apply_timers() {
  local gameplay="${ROOT}/config/gameplay.json"
  [[ -f "${gameplay}" ]] || return 0
  if [[ "${KEEP_TIMERS}" -ne 1 && -z "${SKILL_SPEED}" && -z "${UPWELL_SCALE}" ]]; then
    info "keeping stock timers from release"
    return 0
  fi
  # Values were captured from the old tree before it was moved aside.
  local skill="${SKILL_SPEED:-3600}"
  local upwell="${UPWELL_SCALE:-0.01}"
  if [[ "${KEEP_TIMERS}" -ne 1 ]]; then
    skill="${SKILL_SPEED:-1}"
    upwell="${UPWELL_SCALE:-1}"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${gameplay}" "${skill}" "${upwell}" <<'PY'
import json, sys
path, skill, upwell = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(path, encoding="utf-8"))
def num(s):
    s = str(s).strip()
    return float(s) if "." in s else int(s)
cfg.setdefault("skills", {})["skillTrainingSpeed"] = num(skill)
cfg.setdefault("structures", {})["upwellTimerScale"] = float(upwell)
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2) + "\n")
print(f"skillTrainingSpeed={cfg['skills']['skillTrainingSpeed']} upwellTimerScale={cfg['structures']['upwellTimerScale']}")
PY
  else
    warn "python3 not found — edit config/gameplay.json manually for timers"
  fi
}

patch_compose_continuity() {
  local project="$1"
  local volume="$2"
  local compose="${ROOT}/compose.yaml"
  [[ -f "${compose}" ]] || compose="${ROOT}/compose.yml"
  [[ -f "${compose}" ]] || die "compose.yaml missing after upgrade"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing — patch compose.yaml manually (project=${project} volume=${volume})"
    return 0
  fi
  python3 - "${compose}" "${project}" "${volume}" <<'PY'
import re, sys
path, project, volume = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
# project name
text2, n = re.subn(r'(?m)^name:\s*\S+', f'name: {project}', text, count=1)
text = text2 if n else f'name: {project}\n' + text
# image tags: evejs-local → <project>-local if present
text = re.sub(r'image:\s*evejs-local\b', f'image: {project}-local', text)
text = re.sub(r'image:\s*evejs-xeve-local\b', f'image: {project}-local', text)
# volume keys and names — normalize common stock names to existing volume
text = text.replace('evejs-data', volume)
# if volume key accidentally became weird, fix volumes section
# ensure external named volume for pre-existing data
if f'name: {volume}' in text and 'external: true' not in text:
    text = re.sub(
        rf'(  {re.escape(volume)}:\n    name: {re.escape(volume)})',
        rf'\1\n    external: true',
        text,
        count=1,
    )
# logs volume
logs = f'{project}-logs'
text = text.replace('evejs-logs', logs)
# network name
text = re.sub(r'name:\s*evejs-net\b', f'name: {project}-net', text)
text = re.sub(r'name:\s*evejs-xeve-net\b', f'name: {project}-net', text)
# Character legacy mount if Alliance is mounted but Character is not
if 'generated/Alliance:' in text and 'generated/Character:' not in text:
    text = text.replace(
        '- ./server/src/_secondary/image/generated/Alliance:/app/server/src/_secondary/image/generated/Alliance',
        '- ./server/src/_secondary/image/generated/Alliance:/app/server/src/_secondary/image/generated/Alliance\n'
        '      - ./server/src/_secondary/image/generated/Character:/app/server/src/_secondary/image/generated/Character',
    )
open(path, 'w', encoding='utf-8').write(text)
print(f'patched compose: project={project} volume={volume}')
PY
}

write_lan_compose_if_missing() {
  # Only write a template if user already had one (we restore it). If stock has none, skip.
  return 0
}

migrate_portraits_to_volume() {
  local volume="$1"
  local char_src="${ROOT}/server/src/_secondary/image/generated/Character"
  local all_src="${ROOT}/server/src/_secondary/image/generated/Alliance"
  if ! docker volume inspect "${volume}" >/dev/null 2>&1; then
    warn "volume ${volume} not found yet — portraits will use host legacy path after start"
    return 0
  fi
  if [[ -d "${char_src}" ]] && [[ "$(find "${char_src}" -type f 2>/dev/null | wc -l)" -gt 0 ]]; then
    info "copying character portraits into volume ${volume}…"
    docker run --rm \
      -v "${volume}:/data" \
      -v "${char_src}:/portraits:ro" \
      alpine sh -c 'mkdir -p /data/gameStore/images/Character && cp -a /portraits/. /data/gameStore/images/Character/ && echo "Character files: $(find /data/gameStore/images/Character -type f | wc -l)"'
    ok "character portraits in volume"
  else
    warn "no legacy Character portraits found under generated/Character"
  fi
  if [[ -d "${all_src}" ]] && [[ "$(find "${all_src}" -type f 2>/dev/null | wc -l)" -gt 0 ]]; then
    docker run --rm \
      -v "${volume}:/data" \
      -v "${all_src}:/logos:ro" \
      alpine sh -c 'mkdir -p /data/gameStore/images/Alliance && cp -a /logos/. /data/gameStore/images/Alliance/ && echo "Alliance files: $(find /data/gameStore/images/Alliance -type f | wc -l)"'
    ok "alliance logos in volume"
  fi
}

preserve_custom_tools() {
  local bak="$1"
  local t
  mkdir -p "${ROOT}/tools"
  for t in lan-play solo-rpg-preset server-snapshot dml-server-control dmspack-install-windows tq-import evejs-upgrade; do
    if [[ -d "${bak}/tools/${t}" ]]; then
      rm -rf "${ROOT}/tools/${t}"
      cp -a "${bak}/tools/${t}" "${ROOT}/tools/"
      ok "restored tools/${t}"
    fi
  done
}

confirm() {
  local msg="$1"
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${msg} [y/N] " ans || true
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *) die "Aborted." ;;
  esac
}

main() {
  parse_args "$@"
  header "${TOOL_NAME} v${TOOL_VERSION} → EveJS ${TARGET_VERSION}"

  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"

  resolve_root
  ok "install root: ${ROOT}"

  resolve_release

  local project volume
  project="$(detect_project_name)"
  volume="$(detect_volume_name)"
  ok "compose project: ${project}"
  ok "data volume:     ${volume}"

  if [[ "${KEEP_TIMERS}" -eq 1 ]]; then
    # capture timers before tree is replaced
    read_old_timers || true
    info "timers to apply: skillTrainingSpeed=${SKILL_SPEED:-3600} upwellTimerScale=${UPWELL_SCALE:-0.01}"
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    header "Dry run — no changes"
    cat <<EOF
  root:     ${ROOT}
  release:  ${SOURCE_DIR}
  project:  ${project}
  volume:   ${volume}
  timers:   keep=${KEEP_TIMERS} skill=${SKILL_SPEED:-default} upwell=${UPWELL_SCALE:-default}
  snapshot: ${DO_SNAPSHOT}
  build:    ${DO_BUILD}
  start:    ${DO_START}
EOF
    exit 0
  fi

  confirm "Upgrade ${ROOT} to stock EveJS ${TARGET_VERSION} (volume ${volume} kept)?"

  # Stop stack
  header "Stopping stack"
  (
    cd "${ROOT}"
    docker compose stop 2>/dev/null || true
    docker compose -f compose.yaml -f compose.lan.yaml stop 2>/dev/null || true
  ) || true
  ok "compose stop attempted"

  # Snapshot
  if [[ "${DO_SNAPSHOT}" -eq 1 && -x "${ROOT}/tools/server-snapshot/server-snapshot.sh" ]]; then
    header "Universe snapshot"
    (cd "${ROOT}" && bash tools/server-snapshot/server-snapshot.sh create) || warn "snapshot failed (continuing)"
  else
    info "snapshot skipped"
  fi

  # Tree backup
  header "Tree backup"
  local stamp bak parent
  stamp="$(date +%Y%m%d-%H%M%S)"
  parent="${BACKUP_PARENT:-$(dirname "${ROOT}")}"
  bak="${parent}/$(basename "${ROOT}")-backup-pre-${TARGET_VERSION}-${stamp}"
  info "moving current tree → ${bak}"
  mv "${ROOT}" "${bak}"
  ok "backup: ${bak}"

  # Stage new tree
  header "Install ${TARGET_VERSION}"
  mkdir -p "${ROOT}"
  cp -a "${SOURCE_DIR}/." "${ROOT}/"

  # Restore local assets
  header "Restore local assets"
  mkdir -p "${ROOT}/server/certs" "${ROOT}/_local" "${ROOT}/tools"
  if [[ -d "${bak}/server/certs" ]]; then
    cp -a "${bak}/server/certs/." "${ROOT}/server/certs/"
    ok "certs"
  fi
  if [[ -d "${bak}/server/src/_secondary/express/certs" ]]; then
    mkdir -p "${ROOT}/server/src/_secondary/express/certs"
    cp -a "${bak}/server/src/_secondary/express/certs/." "${ROOT}/server/src/_secondary/express/certs/" 2>/dev/null || true
  fi
  if [[ -d "${bak}/server/src/_secondary/image/generated" ]]; then
    mkdir -p "${ROOT}/server/src/_secondary/image/generated"
    cp -a "${bak}/server/src/_secondary/image/generated/." "${ROOT}/server/src/_secondary/image/generated/"
    ok "generated images (Character/Alliance/…)"
  fi
  if [[ -d "${bak}/_local" ]]; then
    cp -a "${bak}/_local/." "${ROOT}/_local/"
    ok "_local/"
  fi
  if [[ -f "${bak}/compose.lan.yaml" ]]; then
    cp -a "${bak}/compose.lan.yaml" "${ROOT}/compose.lan.yaml"
    ok "compose.lan.yaml"
  fi
  if [[ -f "${bak}/.env" ]]; then
    cp -a "${bak}/.env" "${ROOT}/.env"
    ok ".env"
  fi
  # archive old configs for reference
  mkdir -p "${ROOT}/_local/pre-${TARGET_VERSION}-configs"
  for f in evejs.config.local.json evejs.config.x-eve.json evejs.config.x-eve.local.json compose.yaml; do
    [[ -f "${bak}/${f}" ]] && cp -a "${bak}/${f}" "${ROOT}/_local/pre-${TARGET_VERSION}-configs/" 2>/dev/null || true
  done

  preserve_custom_tools "${bak}"

  # Continuity + timers
  header "Compose continuity + timers"
  patch_compose_continuity "${project}" "${volume}"
  apply_timers

  # Portraits → volume (0.12.5 runtime location)
  header "Migrate portraits into data volume"
  migrate_portraits_to_volume "${volume}"

  # Notes
  cat > "${ROOT}/_local/UPGRADE-${TARGET_VERSION}.md" <<EOF
# Upgrade to EveJS v${TARGET_VERSION}

Date: $(date -u +%Y-%m-%dT%H:%MZ)
Tool: ${TOOL_NAME} v${TOOL_VERSION}

## Preserved
- Docker volume: ${volume}
- Tree backup: ${bak}
- Certs, _local/, custom tools, generated images

## Removed by design
- X-Eve / Living Universe server code (not in stock ${TARGET_VERSION})

## Timers
- skillTrainingSpeed: ${SKILL_SPEED:-stock}
- upwellTimerScale: ${UPWELL_SCALE:-stock}

## Config
Stock ${TARGET_VERSION} uses modular \`config/*.json\` (not evejs.config.local.json).
EOF
  ok "wrote _local/UPGRADE-${TARGET_VERSION}.md"

  # Build / start
  if [[ "${DO_BUILD}" -eq 1 ]]; then
    header "Docker build"
    (cd "${ROOT}" && docker compose build init)
    ok "image built"
  fi

  if [[ "${DO_START}" -eq 1 ]]; then
    header "Start stack"
    # clean stale named network labels if any
    docker network rm "${project}-net" 2>/dev/null || true
    (cd "${ROOT}" && docker compose up --detach --force-recreate)
    info "waiting for server health…"
    local i st
    for i in $(seq 1 60); do
      st="$(docker inspect -f '{{.State.Health.Status}}' "${project}-server-1" 2>/dev/null || echo missing)"
      if [[ "${st}" == "healthy" ]]; then
        ok "server healthy"
        break
      fi
      if docker inspect -f '{{.State.Status}}' "${project}-server-1" 2>/dev/null | grep -q exited; then
        warn "server exited — check: docker compose -f ${ROOT}/compose.yaml logs --tail 80 server"
        break
      fi
      sleep 5
    done
    curl -fsS --max-time 5 "http://127.0.0.1:26002/health" >/dev/null 2>&1 \
      && ok "proxy /health OK" \
      || warn "proxy health not reachable yet"
  fi

  header "Done"
  cat <<EOF
  Install:   ${ROOT}
  Backup:    ${bak}
  Volume:    ${volume} (universe preserved)
  Version:   stock EveJS ${TARGET_VERSION}

  Edit timers:  ${ROOT}/config/gameplay.json
  Restart:      cd ${ROOT} && docker compose restart server

  Rollback tree:
    docker compose -f ${ROOT}/compose.yaml down
    mv ${ROOT} ${ROOT}.failed
    mv ${bak} ${ROOT}
EOF
}

main "$@"
