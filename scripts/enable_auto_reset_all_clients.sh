#!/usr/bin/env bash
set -euo pipefail

RESET_DAYS="${1:-30}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run this script as root."
  fi
}

validate_days() {
  [[ "$RESET_DAYS" =~ ^[0-9]+$ ]] || die "Reset days must be a positive integer."
  (( RESET_DAYS > 0 )) || die "Reset days must be greater than 0."
}

install_sqlite3() {
  if command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 already installed: $(command -v sqlite3)"
    return
  fi

  log "Installing sqlite3..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sqlite3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sqlite || dnf install -y sqlite3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sqlite || yum install -y sqlite3
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache sqlite
  else
    die "Unsupported package manager. Install sqlite3 manually and re-run."
  fi
}

find_db() {
  local candidates=()
  local bin_dir

  if [[ -n "${SUI_DB_FOLDER:-}" ]]; then
    candidates+=("${SUI_DB_FOLDER}/s-ui.db")
  fi

  if command -v s-ui >/dev/null 2>&1; then
    bin_dir="$(cd "$(dirname "$(command -v s-ui)")" && pwd)"
    candidates+=("${bin_dir}/db/s-ui.db")
  fi

  candidates+=(
    "/usr/local/s-ui/db/s-ui.db"
    "/app/db/s-ui.db"
    "/opt/s-ui/db/s-ui.db"
    "/srv/s-ui/db/s-ui.db"
  )

  local db
  for db in "${candidates[@]}"; do
    if [[ -f "$db" ]]; then
      printf '%s\n' "$db"
      return 0
    fi
  done

  db="$(
    find /usr/local /app /opt /srv /root -maxdepth 5 -type f -name 's-ui.db' 2>/dev/null \
      | head -n 1 || true
  )"
  if [[ -n "$db" ]]; then
    printf '%s\n' "$db"
    return 0
  fi

  return 1
}

table_exists() {
  local db="$1"
  local table="$2"
  sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${table}';" | grep -qx '1'
}

get_columns() {
  local db="$1"
  sqlite3 "$db" "PRAGMA table_info(clients);" | awk -F'|' '{print $2}'
}

pick_column() {
  local cols="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if grep -Fxq "$candidate" <<<"$cols"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

detect_timestamp_unit() {
  local db="$1"
  local next_reset_col="$2"
  local sample

  sample="$({
    sqlite3 "$db" "SELECT COALESCE(MAX(CASE WHEN \"${next_reset_col}\" > 0 THEN \"${next_reset_col}\" END), 0) FROM clients;"
  } | tr -d '[:space:]')"

  if [[ -z "$sample" || "$sample" == "0" ]]; then
    sample="$({
      sqlite3 "$db" "SELECT COALESCE(MAX(CASE WHEN expiry > 0 THEN expiry END), 0) FROM clients;"
    } | tr -d '[:space:]')"
  fi

  if [[ -z "$sample" || "$sample" == "0" ]]; then
    printf 'seconds\n'
    return 0
  fi

  if (( sample >= 100000000000 )); then
    printf 'milliseconds\n'
  else
    printf 'seconds\n'
  fi
}

main() {
  require_root
  validate_days
  install_sqlite3

  local db
  db="$(find_db)" || die "Could not locate s-ui.db automatically."
  log "Using database: $db"

  table_exists "$db" "clients" || die "Table 'clients' not found in $db"

  local cols
  cols="$(get_columns "$db")"

  local auto_reset_col reset_days_col next_reset_col
  auto_reset_col="$(pick_column "$cols" auto_reset autoReset)" || die "Could not find auto reset column."
  reset_days_col="$(pick_column "$cols" reset_days resetDays)" || die "Could not find reset days column."
  next_reset_col="$(pick_column "$cols" next_reset nextReset)" || die "Could not find next reset column."

  log "Detected clients columns:"
  printf '%s\n' "$cols"
  log "Using columns: ${auto_reset_col}, ${reset_days_col}, ${next_reset_col}"

  local backup="${db}.bak.autoreset.$(date +%F-%H%M%S)"
  log "Creating online backup: $backup"
  sqlite3 "$db" ".backup '$backup'"

  local unit now next_ts
  unit="$(detect_timestamp_unit "$db" "$next_reset_col")"
  now="$(date +%s)"
  if [[ "$unit" == "milliseconds" ]]; then
    next_ts="$(( (now + RESET_DAYS * 86400) * 1000 ))"
  else
    next_ts="$(( now + RESET_DAYS * 86400 ))"
  fi

  log "Detected timestamp unit for next reset: ${unit}"
  log "Setting all clients to auto-reset every ${RESET_DAYS} days."
  log "Next reset value to write: ${next_ts}"

  sqlite3 "$db" <<SQL
PRAGMA busy_timeout=10000;
BEGIN IMMEDIATE;
UPDATE clients
SET "${auto_reset_col}" = 1,
    "${reset_days_col}" = ${RESET_DAYS},
    "${next_reset_col}" = ${next_ts};
COMMIT;
SQL

  log "Verifying result..."
  sqlite3 "$db" <<SQL
.headers on
.mode column
SELECT COUNT(*) AS users,
       SUM(CASE WHEN "${auto_reset_col}" IN (1, '1', 'true', 'TRUE') THEN 1 ELSE 0 END) AS enabled_auto_reset_users,
       MIN("${reset_days_col}") AS min_reset_days,
       MAX("${reset_days_col}") AS max_reset_days,
       MIN("${next_reset_col}") AS min_next_reset,
       MAX("${next_reset_col}") AS max_next_reset
FROM clients;
SELECT id, name, "${auto_reset_col}" AS auto_reset, "${reset_days_col}" AS reset_days, "${next_reset_col}" AS next_reset
FROM clients
ORDER BY id
LIMIT 10;
SQL

  log "Done. Backup file: $backup"
}

main "$@"
