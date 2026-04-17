#!/usr/bin/env bash
set -euo pipefail

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

has_column() {
  local cols="$1"
  local target="$2"
  grep -Fxq "$target" <<<"$cols"
}

main() {
  require_root
  install_sqlite3

  local db
  db="$(find_db)" || die "Could not locate s-ui.db automatically."
  log "Using database: $db"

  table_exists "$db" "clients" || die "Table 'clients' not found in $db"

  local cols
  cols="$(get_columns "$db")"

  has_column "$cols" "up" || die "Column 'up' not found in clients table."
  has_column "$cols" "down" || die "Column 'down' not found in clients table."

  log "Detected clients columns:"
  printf '%s\n' "$cols"

  local backup="${db}.bak.$(date +%F-%H%M%S)"
  log "Creating online backup: $backup"
  sqlite3 "$db" ".backup '$backup'"

  log "Resetting all clients current traffic without stopping s-ui..."
  sqlite3 "$db" <<'SQL'
PRAGMA busy_timeout=10000;
BEGIN IMMEDIATE;
UPDATE clients
SET up = 0,
    down = 0;
COMMIT;
SQL

  log "Verifying result..."
  sqlite3 "$db" <<'SQL'
.headers on
.mode column
SELECT COUNT(*) AS users, COALESCE(SUM(up + down), 0) AS current_usage_bytes
FROM clients;
SELECT id, name, up, down
FROM clients
ORDER BY id
LIMIT 10;
SQL

  log "Done. Backup file: $backup"
}

main "$@"
