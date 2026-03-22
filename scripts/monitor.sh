#!/usr/bin/env bash
# =============================================================================
# monitor.sh — System Health Monitor
# Author   : Abhinav (DevOps Toolkit)
# Purpose  : Monitors CPU, RAM, Disk, and running services. Logs alerts and
#            generates a timestamped health report in /var/log or local logs/.
# Usage    : ./monitor.sh [--report] [--watch] [--threshold-cpu 85]
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
REPORT_FILE="${LOG_DIR}/health_report_$(date +%Y%m%d_%H%M%S).txt"
ALERT_LOG="${LOG_DIR}/alerts.log"

THRESHOLD_CPU=85       # Alert if CPU usage exceeds this %
THRESHOLD_RAM=80       # Alert if RAM usage exceeds this %
THRESHOLD_DISK=90      # Alert if any disk partition exceeds this %
WATCH_INTERVAL=5       # Seconds between checks in --watch mode

# Services to monitor (space-separated). Adjust for your stack.
SERVICES=("nginx" "mysql" "docker" "ssh")

# ANSI colours (disabled automatically in non-TTY environments)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log_alert() {
  local level="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$ALERT_LOG"
}

separator() { printf '%s\n' "$(printf '─%.0s' {1..60})"; }

ensure_log_dir() { mkdir -p "$LOG_DIR"; }

# ── CPU Usage ─────────────────────────────────────────────────────────────────
get_cpu_usage() {
  # Use /proc/stat for a 1-second sample — works on any Linux system
  local cpu1 cpu2
  cpu1=$(grep '^cpu ' /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')
  sleep 1
  cpu2=$(grep '^cpu ' /proc/stat | awk '{print $2+$3+$4+$5+$6+$7+$8, $5+$6}')

  local total1 idle1 total2 idle2
  total1=$(echo "$cpu1" | awk '{print $1}')
  idle1=$(echo  "$cpu1" | awk '{print $2}')
  total2=$(echo "$cpu2" | awk '{print $1}')
  idle2=$(echo  "$cpu2" | awk '{print $2}')

  local total_diff=$(( total2 - total1 ))
  local idle_diff=$(( idle2 - idle1 ))

  if [[ $total_diff -eq 0 ]]; then echo "0"; return; fi
  echo $(( 100 * (total_diff - idle_diff) / total_diff ))
}

check_cpu() {
  local usage
  usage=$(get_cpu_usage)
  local colour="$GREEN"
  local status="OK"

  if (( usage >= THRESHOLD_CPU )); then
    colour="$RED"; status="CRITICAL"
    log_alert "CRITICAL" "CPU usage at ${usage}% — threshold is ${THRESHOLD_CPU}%"
  elif (( usage >= THRESHOLD_CPU - 15 )); then
    colour="$YELLOW"; status="WARNING"
  fi

  printf "${BOLD}CPU Usage     :${RESET} ${colour}%3d%%${RESET}  [%s]\n" "$usage" "$status"
  echo "CPU_USAGE=${usage}%" >> "$REPORT_FILE"
}

# ── RAM Usage ─────────────────────────────────────────────────────────────────
check_ram() {
  local total used free usage
  total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  free=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  used=$(( total - free ))
  usage=$(( 100 * used / total ))

  local total_hr used_hr
  total_hr=$(awk "BEGIN {printf \"%.1f\", $total/1048576}") # KB → GB
  used_hr=$(awk  "BEGIN {printf \"%.1f\", $used/1048576}")

  local colour="$GREEN"; local status="OK"
  if (( usage >= THRESHOLD_RAM )); then
    colour="$RED"; status="CRITICAL"
    log_alert "CRITICAL" "RAM usage at ${usage}% (${used_hr}GB / ${total_hr}GB)"
  elif (( usage >= THRESHOLD_RAM - 15 )); then
    colour="$YELLOW"; status="WARNING"
  fi

  printf "${BOLD}RAM Usage     :${RESET} ${colour}%3d%%${RESET}  [%s]  (%sGB used of %sGB)\n" \
    "$usage" "$status" "$used_hr" "$total_hr"
  echo "RAM_USAGE=${usage}% (${used_hr}GB/${total_hr}GB)" >> "$REPORT_FILE"
}

# ── Disk Usage ────────────────────────────────────────────────────────────────
check_disk() {
  printf "${BOLD}Disk Usage    :${RESET}\n"
  echo "DISK_USAGE:" >> "$REPORT_FILE"

  while IFS= read -r line; do
    local use mount
    use=$(echo "$line"  | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    local size avail
    size=$(echo "$line"  | awk '{print $2}')
    avail=$(echo "$line" | awk '{print $4}')

    local colour="$GREEN"; local status="OK"
    if (( use >= THRESHOLD_DISK )); then
      colour="$RED"; status="CRITICAL"
      log_alert "CRITICAL" "Disk ${mount} at ${use}% — threshold is ${THRESHOLD_DISK}%"
    elif (( use >= THRESHOLD_DISK - 15 )); then
      colour="$YELLOW"; status="WARNING"
    fi

    printf "  %-20s ${colour}%3d%%${RESET}  [%s]  (%s avail of %s)\n" \
      "$mount" "$use" "$status" "$avail" "$size"
    echo "  $mount: ${use}% used" >> "$REPORT_FILE"
  done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | \
           grep -v 'tmpfs\|udev\|Source' | tail -n +2)
}

# ── Service Status ────────────────────────────────────────────────────────────
check_services() {
  printf "${BOLD}Services      :${RESET}\n"
  echo "SERVICES:" >> "$REPORT_FILE"

  for svc in "${SERVICES[@]}"; do
    local status colour
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      status="RUNNING"; colour="$GREEN"
    elif pgrep -x "$svc" &>/dev/null; then
      status="RUNNING (non-systemd)"; colour="$GREEN"
    else
      status="STOPPED"; colour="$RED"
      log_alert "WARNING" "Service '$svc' is not running"
    fi
    printf "  %-20s ${colour}%s${RESET}\n" "$svc" "$status"
    echo "  $svc: $status" >> "$REPORT_FILE"
  done
}

# ── Top Processes ─────────────────────────────────────────────────────────────
check_top_processes() {
  printf "${BOLD}Top Processes (by CPU):${RESET}\n"
  printf "  %-8s %-20s %6s %6s\n" "PID" "NAME" "CPU%" "MEM%"
  separator | sed 's/^/  /'
  ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=6 {printf "  %-8s %-20s %6s %6s\n", $2, $11, $3, $4}'
  echo "" >> "$REPORT_FILE"
}

# ── Network Stats ─────────────────────────────────────────────────────────────
check_network() {
  printf "${BOLD}Network       :${RESET}\n"
  # Show all non-loopback interfaces with their IP
  ip -4 addr show 2>/dev/null | awk '
    /^[0-9]+: / { iface = $2; sub(/:/, "", iface) }
    /inet /     { if (iface != "lo") printf "  %-15s %s\n", iface, $2 }
  ' || echo "  (ip command unavailable)"
}

# ── Main Report ───────────────────────────────────────────────────────────────
run_report() {
  ensure_log_dir
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

  # Write report header
  {
    echo "========================================"
    echo " System Health Report — $ts"
    echo " Host: $(hostname)"
    echo " Uptime: $(uptime -p 2>/dev/null || uptime)"
    echo "========================================"
  } | tee "$REPORT_FILE"

  echo ""
  separator
  check_cpu
  check_ram
  separator
  check_disk
  separator
  check_services
  separator
  check_top_processes
  check_network
  separator

  echo -e "\n${CYAN}Report saved to:${RESET} $REPORT_FILE"
  echo -e "${CYAN}Alerts log    :${RESET} $ALERT_LOG\n"
}

# ── Watch Mode ────────────────────────────────────────────────────────────────
run_watch() {
  echo -e "${CYAN}Starting watch mode — refreshing every ${WATCH_INTERVAL}s${RESET}"
  echo -e "${CYAN}Press Ctrl+C to exit${RESET}\n"
  while true; do
    clear
    run_report
    sleep "$WATCH_INTERVAL"
  done
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
MODE="report"
for arg in "$@"; do
  case "$arg" in
    --watch)           MODE="watch" ;;
    --report)          MODE="report" ;;
    --threshold-cpu=*) THRESHOLD_CPU="${arg#*=}" ;;
    --threshold-ram=*) THRESHOLD_RAM="${arg#*=}" ;;
    --threshold-disk=*) THRESHOLD_DISK="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--report] [--watch] [--threshold-cpu=N] [--threshold-ram=N] [--threshold-disk=N]"
      exit 0 ;;
  esac
done

case "$MODE" in
  watch)  run_watch ;;
  report) run_report ;;
esac
