#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Zero-Downtime Application Deployment with Rollback
# Author   : Abhinav (DevOps Toolkit)
# Purpose  : Pulls latest code, runs pre-deploy checks, restarts service, and
#            automatically rolls back if health checks fail post-deploy.
# Usage    : ./deploy.sh [--env production|staging] [--rollback] [--dry-run]
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
DEPLOY_LOG="${LOG_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"

# Override these via environment variables or a .env file
APP_NAME="${APP_NAME:-myapp}"
APP_DIR="${APP_DIR:-/var/www/$APP_NAME}"
GIT_REPO="${GIT_REPO:-}"                    # e.g. https://github.com/user/repo.git
GIT_BRANCH="${GIT_BRANCH:-main}"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"    # systemd service name
DEPLOY_USER="${DEPLOY_USER:-www-data}"
RELEASES_DIR="${RELEASES_DIR:-/var/www/releases/$APP_NAME}"
MAX_RELEASES=5                              # Keep last N releases for rollback
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-http://localhost:8080/health}"
HEALTH_RETRIES=5
HEALTH_RETRY_DELAY=3                        # seconds between health check retries

ENV="production"
DRY_RUN=false
ROLLBACK_MODE=false

# ANSI colours
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; BLUE='\033[0;34m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; BLUE=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log()       { local msg="[$(date '+%H:%M:%S')] $*"; echo -e "$msg" | tee -a "$DEPLOY_LOG"; }
log_info()  { log "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { log "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { log "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { log "${RED}[ERROR]${RESET} $*"; }
log_step()  { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}" | tee -a "$DEPLOY_LOG"; }

run() {
  # Wrapper: logs the command, skips execution in dry-run mode
  log_info "CMD: $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "(dry-run) Skipped."
    return 0
  fi
  "$@"
}

# ── Pre-flight Checks ─────────────────────────────────────────────────────────
pre_flight_checks() {
  log_step "Running pre-flight checks"

  local errors=0

  # Check required tools
  for tool in git curl rsync; do
    if command -v "$tool" &>/dev/null; then
      log_ok "$tool found ($(command -v "$tool"))"
    else
      log_error "$tool is not installed — required for deployment"
      (( errors++ ))
    fi
  done

  # Check disk space (need at least 500MB free)
  local free_kb
  free_kb=$(df "$PROJECT_ROOT" | awk 'NR==2 {print $4}')
  if (( free_kb < 512000 )); then
    log_warn "Low disk space: only $(( free_kb / 1024 ))MB free (recommended: 500MB+)"
  else
    log_ok "Disk space OK: $(( free_kb / 1024 ))MB available"
  fi

  # Check if this is a git repo when APP_DIR exists
  if [[ -d "$APP_DIR/.git" ]]; then
    log_ok "Git repository found at $APP_DIR"
  elif [[ -n "$GIT_REPO" ]]; then
    log_info "App dir not found — will clone $GIT_REPO"
  else
    log_warn "APP_DIR=$APP_DIR not set or missing. Set GIT_REPO to enable auto-clone."
  fi

  if (( errors > 0 )); then
    log_error "Pre-flight failed with $errors error(s). Aborting."
    exit 1
  fi

  log_ok "All pre-flight checks passed"
}

# ── Load Environment Config ───────────────────────────────────────────────────
load_env_config() {
  local env_file="${PROJECT_ROOT}/config/.env.${ENV}"
  if [[ -f "$env_file" ]]; then
    log_info "Loading config from $env_file"
    # shellcheck source=/dev/null
    set -a; source "$env_file"; set +a
  else
    log_warn "No env config file at $env_file — using defaults/exports"
  fi
}

# ── Create Release ────────────────────────────────────────────────────────────
create_release() {
  log_step "Creating new release"

  local release_id; release_id=$(date +%Y%m%d%H%M%S)
  local release_path="${RELEASES_DIR}/${release_id}"

  log_info "Release ID: $release_id"
  log_info "Release path: $release_path"

  run mkdir -p "$release_path"

  if [[ -d "$APP_DIR/.git" ]]; then
    log_info "Fetching latest code from origin/$GIT_BRANCH"
    run git -C "$APP_DIR" fetch origin
    run git -C "$APP_DIR" checkout "$GIT_BRANCH"
    run git -C "$APP_DIR" pull origin "$GIT_BRANCH"

    local commit_hash; commit_hash=$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log_ok "At commit: $commit_hash"

    run rsync -a --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
      "${APP_DIR}/" "${release_path}/"
  elif [[ -n "$GIT_REPO" ]]; then
    log_info "Cloning $GIT_REPO → $release_path"
    run git clone --branch "$GIT_BRANCH" --depth 1 "$GIT_REPO" "$release_path"
  else
    log_warn "No source configured — copying current APP_DIR contents"
    run rsync -a "${APP_DIR}/" "${release_path}/"
  fi

  # Write deploy metadata
  if [[ "$DRY_RUN" == "false" ]]; then
    cat > "${release_path}/.deploy_meta" <<META
RELEASE_ID=$release_id
DEPLOY_TIME=$(date --iso-8601=seconds)
GIT_BRANCH=${GIT_BRANCH}
DEPLOYED_BY=$(whoami)
ENV=$ENV
META
  fi

  echo "$release_path"
}

# ── Install Dependencies ──────────────────────────────────────────────────────
install_deps() {
  local release_path="$1"
  log_step "Installing dependencies"

  if [[ -f "${release_path}/requirements.txt" ]]; then
    log_info "Python project detected"
    run pip install -q -r "${release_path}/requirements.txt"
  elif [[ -f "${release_path}/package.json" ]]; then
    log_info "Node.js project detected"
    run npm ci --prefix "$release_path" --silent
  elif [[ -f "${release_path}/Gemfile" ]]; then
    log_info "Ruby project detected"
    run bundle install --gemfile "${release_path}/Gemfile" --quiet
  elif [[ -f "${release_path}/go.mod" ]]; then
    log_info "Go project detected"
    run go build -C "$release_path" ./...
  else
    log_warn "No known dependency file found — skipping install step"
  fi
}

# ── Symlink & Activate ────────────────────────────────────────────────────────
activate_release() {
  local release_path="$1"
  log_step "Activating release"

  local current_link="${RELEASES_DIR}/current"

  # Save previous release for potential rollback
  if [[ -L "$current_link" ]]; then
    local prev; prev=$(readlink "$current_link")
    log_info "Previous release: $prev"
    echo "$prev" > "${LOG_DIR}/.last_release"
  fi

  run ln -sfn "$release_path" "$current_link"
  log_ok "Symlink updated: $current_link → $release_path"
}

# ── Service Restart ───────────────────────────────────────────────────────────
restart_service() {
  log_step "Restarting service: $SERVICE_NAME"

  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    run systemctl reload-or-restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      log_ok "$SERVICE_NAME restarted successfully"
    else
      log_error "$SERVICE_NAME failed to restart"
      return 1
    fi
  else
    log_warn "systemd service '$SERVICE_NAME' not found — checking for process"
    if pgrep -x "$SERVICE_NAME" &>/dev/null; then
      log_ok "$SERVICE_NAME process is running (non-systemd)"
    else
      log_warn "Service not managed by systemd and not detected — skipping restart"
    fi
  fi
}

# ── Health Check ─────────────────────────────────────────────────────────────
run_health_check() {
  log_step "Running post-deploy health checks"

  if [[ -z "$HEALTH_CHECK_URL" ]]; then
    log_warn "HEALTH_CHECK_URL not set — skipping HTTP health check"
    return 0
  fi

  log_info "Polling $HEALTH_CHECK_URL (up to ${HEALTH_RETRIES} attempts)"

  local attempt=1
  while (( attempt <= HEALTH_RETRIES )); do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
      log_ok "Health check passed (HTTP $http_code) on attempt $attempt"
      return 0
    else
      log_warn "Attempt $attempt/$HEALTH_RETRIES — HTTP $http_code (expected 200)"
      (( attempt++ ))
      sleep "$HEALTH_RETRY_DELAY"
    fi
  done

  log_error "Health check failed after $HEALTH_RETRIES attempts"
  return 1
}

# ── Rollback ──────────────────────────────────────────────────────────────────
do_rollback() {
  log_step "ROLLING BACK"

  local last_release_file="${LOG_DIR}/.last_release"
  if [[ ! -f "$last_release_file" ]]; then
    log_error "No previous release record found. Manual intervention required."
    exit 1
  fi

  local prev_release; prev_release=$(cat "$last_release_file")
  if [[ ! -d "$prev_release" ]]; then
    log_error "Previous release dir '$prev_release' does not exist"
    exit 1
  fi

  log_warn "Rolling back to: $prev_release"
  run ln -sfn "$prev_release" "${RELEASES_DIR}/current"
  restart_service || log_warn "Service restart after rollback had issues — check manually"
  log_ok "Rollback complete. Now at: $prev_release"
}

# ── Prune Old Releases ────────────────────────────────────────────────────────
prune_releases() {
  log_step "Pruning old releases (keeping last $MAX_RELEASES)"

  local count
  count=$(find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)

  if (( count > MAX_RELEASES )); then
    # Sort by name (timestamp-based), delete oldest
    find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d | \
      sort | head -n $(( count - MAX_RELEASES )) | while read -r old_dir; do
        log_info "Removing old release: $old_dir"
        run rm -rf "$old_dir"
      done
    log_ok "Pruned $(( count - MAX_RELEASES )) old release(s)"
  else
    log_info "Only $count release(s) — nothing to prune"
  fi
}

# ── Deployment Summary ────────────────────────────────────────────────────────
print_summary() {
  local status="$1"; local release_path="${2:-N/A}"
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
  if [[ "$status" == "success" ]]; then
    echo -e "${BOLD}║  ${GREEN}✔  DEPLOYMENT SUCCESSFUL${RESET}${BOLD}             ║${RESET}"
  else
    echo -e "${BOLD}║  ${RED}✘  DEPLOYMENT FAILED + ROLLED BACK${RESET}${BOLD}  ║${RESET}"
  fi
  echo -e "${BOLD}╠══════════════════════════════════════╣${RESET}"
  printf  "${BOLD}║${RESET}  %-18s %-18s ${BOLD}║${RESET}\n" "App:" "$APP_NAME"
  printf  "${BOLD}║${RESET}  %-18s %-18s ${BOLD}║${RESET}\n" "Environment:" "$ENV"
  printf  "${BOLD}║${RESET}  %-18s %-18s ${BOLD}║${RESET}\n" "Branch:" "$GIT_BRANCH"
  printf  "${BOLD}║${RESET}  %-18s %-18s ${BOLD}║${RESET}\n" "Time:" "$(date '+%H:%M:%S')"
  echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
  echo -e "  Deploy log: ${CYAN}${DEPLOY_LOG}${RESET}\n"
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --env=*)       ENV="${arg#*=}" ;;
    --branch=*)    GIT_BRANCH="${arg#*=}" ;;
    --rollback)    ROLLBACK_MODE=true ;;
    --dry-run)     DRY_RUN=true; log_warn "DRY RUN MODE — no changes will be made" ;;
    --help|-h)
      echo "Usage: $0 [--env=production|staging] [--branch=main] [--rollback] [--dry-run]"
      exit 0 ;;
  esac
done

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
  log_step "Starting deployment — $APP_NAME @ $ENV"
  log_info "Deploy log: $DEPLOY_LOG"

  if [[ "$ROLLBACK_MODE" == "true" ]]; then
    do_rollback
    exit 0
  fi

  load_env_config
  pre_flight_checks

  local release_path
  release_path=$(create_release)

  install_deps "$release_path"
  activate_release "$release_path"
  restart_service

  # Post-deploy health check with auto-rollback on failure
  if ! run_health_check; then
    log_error "Health check failed — triggering automatic rollback"
    do_rollback
    print_summary "failed" "$release_path"
    exit 1
  fi

  prune_releases
  print_summary "success" "$release_path"
}

main "$@"
