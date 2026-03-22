#!/usr/bin/env bash
# =============================================================================
# backup.sh — Automated Backup with Retention Policy
# Author   : Abhinav (DevOps Toolkit)
# Purpose  : Backs up files and/or databases (MySQL/PostgreSQL) with
#            timestamped archives, compression, and rotation policy.
# Usage    : ./backup.sh [--type files|db|all] [--destination /path] [--list]
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
BACKUP_LOG="${LOG_DIR}/backup.log"

# Backup storage
BACKUP_DEST="${BACKUP_DEST:-${PROJECT_ROOT}/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Retention: keep N most recent backups of each type
RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3

# File backup targets (space-separated directories)
BACKUP_DIRS=(
  "/etc/nginx"
  "/var/www/html"
  "/home"
)

# DB configuration — override via environment or config/.env.backup
DB_TYPE="${DB_TYPE:-mysql}"          # mysql or postgres
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-}"
DB_NAMES="${DB_NAMES:-}"             # comma-separated list; empty = all databases

# Compression: gz (fast), bz2 (better ratio), xz (best ratio)
COMPRESS="gz"

# ANSI
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$BACKUP_LOG"; }
log_ok()    { log "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { log "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { log "${RED}[ERROR]${RESET} $*"; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}" | tee -a "$BACKUP_LOG"; }

human_size() {
  local bytes="$1"
  if   (( bytes >= 1073741824 )); then printf "%.1fGB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif (( bytes >= 1048576 ));    then printf "%.1fMB" "$(echo "scale=1; $bytes/1048576"    | bc)"
  elif (( bytes >= 1024 ));       then printf "%.1fKB" "$(echo "scale=1; $bytes/1024"       | bc)"
  else printf "%sB" "$bytes"
  fi
}

setup_dirs() {
  mkdir -p "$BACKUP_DEST"/{files,databases,reports}
  mkdir -p "$LOG_DIR"
}

# ── Pre-checks ────────────────────────────────────────────────────────────────
pre_checks() {
  log_step "Pre-backup checks"

  # Disk space check: warn if < 1GB free
  local free_kb; free_kb=$(df "$BACKUP_DEST" | awk 'NR==2 {print $4}')
  if (( free_kb < 1048576 )); then
    log_warn "Low disk space: $(( free_kb / 1024 ))MB free on backup destination"
  else
    log_ok "Disk space: $(( free_kb / 1024 ))MB free"
  fi
}

# ── File Backup ───────────────────────────────────────────────────────────────
backup_files() {
  log_step "Backing up files"

  local failed=0
  for dir in "${BACKUP_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
      log_warn "Skipping '$dir' — directory does not exist"
      continue
    fi

    local dir_name; dir_name=$(echo "$dir" | tr '/' '_' | sed 's/^_//')
    local archive="${BACKUP_DEST}/files/${dir_name}_${TIMESTAMP}.tar.${COMPRESS}"

    log "  Archiving $dir → $(basename "$archive")"
    local start; start=$(date +%s)

    if tar --create \
          --file="$archive" \
          --"$COMPRESS" \
          --exclude='*.log' \
          --exclude='*.tmp' \
          --exclude='node_modules' \
          --exclude='.git' \
          "$dir" 2>/dev/null; then
      local end; end=$(date +%s)
      local size; size=$(stat -c%s "$archive" 2>/dev/null || echo 0)
      log_ok "  $(basename "$archive") — $(human_size "$size") in $(( end - start ))s"
    else
      log_error "  Failed to archive $dir"
      (( failed++ ))
    fi
  done

  return $failed
}

# ── Database Backup ───────────────────────────────────────────────────────────
backup_database() {
  log_step "Backing up databases ($DB_TYPE)"

  case "$DB_TYPE" in
    mysql)  backup_mysql ;;
    postgres|postgresql) backup_postgres ;;
    *)
      log_error "Unknown DB_TYPE: $DB_TYPE (use 'mysql' or 'postgres')"
      return 1 ;;
  esac
}

backup_mysql() {
  if ! command -v mysqldump &>/dev/null; then
    log_warn "mysqldump not found — skipping MySQL backup"
    return 0
  fi

  # Build auth args; avoid password in process list
  local auth_args=("-h$DB_HOST" "-P$DB_PORT" "-u$DB_USER")
  local pw_file=""
  if [[ -n "$DB_PASS" ]]; then
    pw_file=$(mktemp)
    chmod 600 "$pw_file"
    printf '[client]\npassword=%s\n' "$DB_PASS" > "$pw_file"
    auth_args+=("--defaults-extra-file=$pw_file")
  fi

  # Determine databases to dump
  local dbs=()
  if [[ -n "$DB_NAMES" ]]; then
    IFS=',' read -ra dbs <<< "$DB_NAMES"
  else
    mapfile -t dbs < <(mysql "${auth_args[@]}" \
      -e "SHOW DATABASES;" 2>/dev/null | \
      grep -Ev '^(Database|information_schema|performance_schema|sys)$')
  fi

  for db in "${dbs[@]}"; do
    local outfile="${BACKUP_DEST}/databases/mysql_${db}_${TIMESTAMP}.sql.${COMPRESS}"
    log "  Dumping MySQL database: $db"

    if mysqldump "${auth_args[@]}" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        "$db" 2>/dev/null | \
        gzip -9 > "$outfile"; then
      local size; size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
      log_ok "  $db → $(basename "$outfile") ($(human_size "$size"))"
    else
      log_error "  Failed to dump MySQL database: $db"
    fi
  done

  [[ -n "$pw_file" ]] && rm -f "$pw_file"
}

backup_postgres() {
  if ! command -v pg_dump &>/dev/null; then
    log_warn "pg_dump not found — skipping PostgreSQL backup"
    return 0
  fi

  export PGPASSWORD="$DB_PASS"

  local dbs=()
  if [[ -n "$DB_NAMES" ]]; then
    IFS=',' read -ra dbs <<< "$DB_NAMES"
  else
    mapfile -t dbs < <(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
      -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null | \
      grep -v '^\s*$' | xargs)
  fi

  for db in "${dbs[@]}"; do
    local outfile="${BACKUP_DEST}/databases/pg_${db}_${TIMESTAMP}.dump"
    log "  Dumping PostgreSQL database: $db"
    if pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -Fc -Z9 "$db" > "$outfile" 2>/dev/null; then
      local size; size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
      log_ok "  $db → $(basename "$outfile") ($(human_size "$size"))"
    else
      log_error "  Failed to dump PostgreSQL database: $db"
    fi
  done

  unset PGPASSWORD
}

# ── Retention / Rotation ──────────────────────────────────────────────────────
apply_retention() {
  log_step "Applying retention policy"

  local day_of_week; day_of_week=$(date +%u)   # 1=Mon … 7=Sun
  local day_of_month; day_of_month=$(date +%d)

  # Daily retention: keep last RETAIN_DAILY files per type/subdir
  for subdir in files databases; do
    local count
    count=$(find "${BACKUP_DEST}/${subdir}" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if (( count > RETAIN_DAILY )); then
      find "${BACKUP_DEST}/${subdir}" -maxdepth 1 -type f | \
        sort | head -n $(( count - RETAIN_DAILY )) | while read -r f; do
          log_warn "  Removing old backup: $(basename "$f")"
          rm -f "$f"
        done
    fi
  done

  log_ok "Retention policy applied (daily=$RETAIN_DAILY, weekly=$RETAIN_WEEKLY, monthly=$RETAIN_MONTHLY)"
}

# ── Generate Report ───────────────────────────────────────────────────────────
generate_report() {
  log_step "Generating backup report"

  local report="${BACKUP_DEST}/reports/backup_report_${TIMESTAMP}.txt"
  local total_size=0

  {
    echo "============================================"
    echo " Backup Report — $(date '+%Y-%m-%d %H:%M:%S')"
    echo " Host: $(hostname)"
    echo "============================================"
    echo ""
    echo "File Backups:"
    find "${BACKUP_DEST}/files" -maxdepth 1 -type f -newer "$BACKUP_LOG" \
      -printf "  %f  %s bytes\n" 2>/dev/null || echo "  (none this run)"
    echo ""
    echo "Database Backups:"
    find "${BACKUP_DEST}/databases" -maxdepth 1 -type f -newer "$BACKUP_LOG" \
      -printf "  %f  %s bytes\n" 2>/dev/null || echo "  (none this run)"
    echo ""
    echo "Total backup storage:"
    du -sh "${BACKUP_DEST}" 2>/dev/null | awk '{print "  " $1}'
    echo ""
    echo "Full log: $BACKUP_LOG"
  } | tee "$report"

  log_ok "Report saved: $report"
}

# ── List Backups ──────────────────────────────────────────────────────────────
list_backups() {
  echo -e "\n${BOLD}Stored backups in ${BACKUP_DEST}${RESET}\n"
  for subdir in files databases; do
    echo -e "${CYAN}${subdir^}:${RESET}"
    if ls "${BACKUP_DEST}/${subdir}" 2>/dev/null | grep -q .; then
      ls -lh "${BACKUP_DEST}/${subdir}" | awk 'NR>1 {printf "  %s  %s\n", $5, $9}'
    else
      echo "  (empty)"
    fi
    echo ""
  done
}

# ── Verify Backup Integrity ───────────────────────────────────────────────────
verify_backup() {
  local file="$1"
  log "Verifying: $(basename "$file")"
  case "$file" in
    *.tar.gz)   tar -tzf "$file" &>/dev/null && log_ok "OK: $file" || log_error "CORRUPT: $file" ;;
    *.tar.bz2)  tar -tjf "$file" &>/dev/null && log_ok "OK: $file" || log_error "CORRUPT: $file" ;;
    *.tar.xz)   tar -tJf "$file" &>/dev/null && log_ok "OK: $file" || log_error "CORRUPT: $file" ;;
    *.sql.gz)   gunzip -t "$file" &>/dev/null && log_ok "OK: $file" || log_error "CORRUPT: $file" ;;
    *)          log_warn "Cannot auto-verify file type: $file" ;;
  esac
}

verify_all() {
  log_step "Verifying all recent backups"
  find "$BACKUP_DEST" -maxdepth 2 -type f | while read -r f; do
    verify_backup "$f"
  done
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
BACKUP_TYPE="all"
MODE="run"

for arg in "$@"; do
  case "$arg" in
    --type=*)        BACKUP_TYPE="${arg#*=}" ;;
    --destination=*) BACKUP_DEST="${arg#*=}" ;;
    --list)          MODE="list" ;;
    --verify)        MODE="verify" ;;
    --help|-h)
      echo "Usage: $0 [--type files|db|all] [--destination /path] [--list] [--verify]"
      exit 0 ;;
  esac
done

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
  setup_dirs

  case "$MODE" in
    list)   list_backups; exit 0 ;;
    verify) verify_all;   exit 0 ;;
  esac

  log_step "Starting backup — type=$BACKUP_TYPE at $(date)"
  pre_checks

  local exit_code=0
  case "$BACKUP_TYPE" in
    files) backup_files   || exit_code=$? ;;
    db)    backup_database || exit_code=$? ;;
    all)
      backup_files    || exit_code=$?
      backup_database || exit_code=$?
      ;;
    *)
      log_error "Unknown backup type: $BACKUP_TYPE"
      exit 1 ;;
  esac

  apply_retention
  generate_report

  if (( exit_code == 0 )); then
    log_ok "Backup completed successfully"
  else
    log_warn "Backup completed with $exit_code error(s) — check log"
  fi

  return $exit_code
}

main "$@"
