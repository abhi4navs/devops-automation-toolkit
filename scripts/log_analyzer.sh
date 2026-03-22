#!/usr/bin/env bash
# =============================================================================
# log_analyzer.sh — Log Analysis & HTML Report Generator
# Author   : Abhinav (DevOps Toolkit)
# Purpose  : Parses Nginx/Apache access logs, extracts key metrics (top IPs,
#            endpoints, status codes, error rates), and renders an HTML report.
# Usage    : ./log_analyzer.sh [--log /path/to/access.log] [--output report.html]
#            [--format nginx|apache|combined] [--last-hours N]
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${PROJECT_ROOT}/logs"
REPORT_DIR="${PROJECT_ROOT}/logs/reports"

# Default log file locations to try (in order)
DEFAULT_LOG_PATHS=(
  "/var/log/nginx/access.log"
  "/var/log/apache2/access.log"
  "/var/log/httpd/access_log"
)

LOG_FILE=""
OUTPUT_FILE="${REPORT_DIR}/log_report_$(date +%Y%m%d_%H%M%S).html"
LOG_FORMAT="nginx"   # nginx | apache | combined
LAST_HOURS=24        # Analyze last N hours; 0 = all
TOP_N=10             # Show top N entries per category
TMP_DIR=$(mktemp -d)

# ANSI
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log()       { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()    { echo -e "${GREEN}✔${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}⚠${RESET}  $*"; }
log_error() { echo -e "${RED}✘${RESET}  $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Find Log File ─────────────────────────────────────────────────────────────
find_log_file() {
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    log_ok "Using log: $LOG_FILE"
    return 0
  fi

  for path in "${DEFAULT_LOG_PATHS[@]}"; do
    if [[ -f "$path" && -r "$path" ]]; then
      LOG_FILE="$path"
      log_ok "Auto-detected log: $LOG_FILE"
      return 0
    fi
  done

  # Fall back to generating a sample log for demonstration
  log_warn "No real log file found — generating sample data for demo"
  generate_sample_log
}

generate_sample_log() {
  LOG_FILE="${TMP_DIR}/sample_access.log"
  local ips=("192.168.1.10" "10.0.0.42" "203.0.113.5" "198.51.100.9"
             "172.16.0.8" "192.0.2.44" "198.51.100.20" "203.0.113.99"
             "10.10.0.1" "192.168.0.77")
  local methods=("GET" "GET" "GET" "POST" "PUT" "DELETE" "GET")
  local endpoints=("/" "/api/users" "/api/health" "/static/app.js" "/api/login"
                   "/api/data" "/admin" "/api/metrics" "/favicon.ico" "/api/v2/users")
  local codes=(200 200 200 200 301 404 500 403 200 304)
  local agents=("Mozilla/5.0" "curl/7.68.0" "python-requests/2.25.1" "Googlebot/2.1")

  for i in $(seq 1 500); do
    local ip="${ips[$((RANDOM % ${#ips[@]}))]}"
    local method="${methods[$((RANDOM % ${#methods[@]}))]}"
    local endpoint="${endpoints[$((RANDOM % ${#endpoints[@]}))]}"
    local code="${codes[$((RANDOM % ${#codes[@]}))]}"
    local size=$(( RANDOM % 50000 + 100 ))
    local agent="${agents[$((RANDOM % ${#agents[@]}))]}"
    local ts; ts=$(date -d "-$(( RANDOM % 86400 )) seconds" '+%d/%b/%Y:%H:%M:%S +0000' 2>/dev/null || date '+%d/%b/%Y:%H:%M:%S +0000')
    echo "${ip} - - [${ts}] \"${method} ${endpoint} HTTP/1.1\" ${code} ${size} \"-\" \"${agent}\""
  done > "$LOG_FILE"

  log_ok "Sample log generated: $LOG_FILE (500 entries)"
}

# ── Filter by Time Window ─────────────────────────────────────────────────────
filter_log() {
  local filtered="${TMP_DIR}/filtered.log"

  if (( LAST_HOURS == 0 )); then
    cp "$LOG_FILE" "$filtered"
  else
    # Convert hours to seconds and filter lines within the window
    local cutoff; cutoff=$(date -d "-${LAST_HOURS} hours" '+%d/%b/%Y:%H:%M:%S' 2>/dev/null || cat "$LOG_FILE")
    # Simple heuristic: take last portion of log assuming roughly chronological
    local total_lines; total_lines=$(wc -l < "$LOG_FILE")
    # Estimate ~100 req/hr and take last N*100 lines as a fast approximation
    local take=$(( LAST_HOURS * 100 ))
    (( take > total_lines )) && take=$total_lines
    tail -n "$take" "$LOG_FILE" > "$filtered"
  fi

  echo "$filtered"
}

# ── Parse Metrics ─────────────────────────────────────────────────────────────
parse_metrics() {
  local log_to_parse="$1"

  log_step "Parsing log metrics"

  # Total requests
  TOTAL=$(wc -l < "$log_to_parse")
  log_ok "Total requests: $TOTAL"

  # HTTP status code distribution
  awk '{print $9}' "$log_to_parse" | sort | uniq -c | sort -rn \
    > "${TMP_DIR}/status_codes.txt"
  log_ok "Status codes extracted"

  # Count specific groups
  CNT_2XX=$(awk '{print $9}' "$log_to_parse" | grep -c '^2' || true)
  CNT_3XX=$(awk '{print $9}' "$log_to_parse" | grep -c '^3' || true)
  CNT_4XX=$(awk '{print $9}' "$log_to_parse" | grep -c '^4' || true)
  CNT_5XX=$(awk '{print $9}' "$log_to_parse" | grep -c '^5' || true)

  # Top IPs
  awk '{print $1}' "$log_to_parse" | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    > "${TMP_DIR}/top_ips.txt"
  log_ok "Top IPs extracted"

  # Top endpoints
  awk '{print $7}' "$log_to_parse" | cut -d'?' -f1 | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    > "${TMP_DIR}/top_endpoints.txt"
  log_ok "Top endpoints extracted"

  # Top user agents
  awk -F'"' '{print $6}' "$log_to_parse" | \
    awk '{$1=$1; print}' | sort | uniq -c | sort -rn | head -n "$TOP_N" \
    > "${TMP_DIR}/top_agents.txt"
  log_ok "User agents extracted"

  # HTTP methods distribution
  awk '{print $6}' "$log_to_parse" | tr -d '"' | sort | uniq -c | sort -rn \
    > "${TMP_DIR}/methods.txt"
  log_ok "HTTP methods extracted"

  # Bandwidth (sum of bytes column)
  TOTAL_BYTES=$(awk '{sum += $10} END {print sum+0}' "$log_to_parse")
  log_ok "Bandwidth calculated: $(( TOTAL_BYTES / 1048576 ))MB"

  # Error lines (4xx and 5xx)
  grep -E ' [45][0-9]{2} ' "$log_to_parse" | tail -20 > "${TMP_DIR}/errors.txt" || true
  log_ok "Errors extracted"

  # Requests per hour histogram
  awk '{print $4}' "$log_to_parse" | \
    grep -oP '\d{2}/\w+/\d{4}:\d{2}' | \
    sort | uniq -c \
    > "${TMP_DIR}/req_per_hour.txt"
  log_ok "Hourly histogram built"
}

# ── HTML Report Builder ───────────────────────────────────────────────────────
build_table_rows() {
  local file="$1"
  local max="${2:-20}"
  local n=0
  while IFS= read -r line && (( n < max )); do
    local count; count=$(echo "$line" | awk '{print $1}')
    local value; value=$(echo "$line" | awk '{$1=""; sub(/^ /, ""); print}' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    local pct=$(( 100 * count / (TOTAL > 0 ? TOTAL : 1) ))
    echo "<tr><td>${value}</td><td>${count}</td><td><div class=\"bar\"><div class=\"bar-fill\" style=\"width:${pct}%\"></div></div></td></tr>"
    (( n++ ))
  done < "$file"
}

build_status_rows() {
  while IFS= read -r line; do
    local count; count=$(echo "$line" | awk '{print $1}')
    local code; code=$(echo "$line"  | awk '{print $2}')
    local cls="success"
    case "${code:0:1}" in
      3) cls="redirect" ;;
      4) cls="error4"   ;;
      5) cls="error5"   ;;
    esac
    echo "<tr><td><span class=\"badge $cls\">${code}</span></td><td>${count}</td></tr>"
  done < "${TMP_DIR}/status_codes.txt"
}

generate_html_report() {
  log_step "Generating HTML report"
  mkdir -p "$REPORT_DIR"

  local error_rate=0
  (( TOTAL > 0 )) && error_rate=$(( 100 * (CNT_4XX + CNT_5XX) / TOTAL ))

  local bw_mb=$(( TOTAL_BYTES / 1048576 ))
  local avg_size=0
  (( TOTAL > 0 )) && avg_size=$(( TOTAL_BYTES / TOTAL ))

  cat > "$OUTPUT_FILE" << HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Access Log Report — $(date '+%Y-%m-%d')</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #f5f6fa; color: #2d3436; font-size: 14px; }
  header { background: #2d3436; color: #fff; padding: 1.5rem 2rem;
           display: flex; justify-content: space-between; align-items: center; }
  header h1 { font-size: 1.3rem; font-weight: 600; }
  header p  { font-size: 0.8rem; opacity: 0.7; margin-top: 2px; }
  .badge-header { background: #00b894; color: #fff; padding: 4px 12px;
                  border-radius: 20px; font-size: 12px; font-weight: 600; }
  main { max-width: 1100px; margin: 1.5rem auto; padding: 0 1rem; }
  .grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 1.5rem; }
  .metric { background: #fff; border-radius: 8px; padding: 1.2rem 1.5rem;
            border-left: 4px solid #0984e3; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .metric.green { border-color: #00b894; }
  .metric.red   { border-color: #d63031; }
  .metric.amber { border-color: #fdcb6e; }
  .metric-label { font-size: 11px; text-transform: uppercase; letter-spacing: .5px;
                  color: #636e72; margin-bottom: 6px; }
  .metric-val   { font-size: 1.8rem; font-weight: 700; color: #2d3436; }
  .metric-sub   { font-size: 11px; color: #b2bec3; margin-top: 4px; }
  .card { background: #fff; border-radius: 8px; padding: 1.25rem 1.5rem; margin-bottom: 1.25rem;
          box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .card h2 { font-size: 0.95rem; font-weight: 600; color: #636e72;
             text-transform: uppercase; letter-spacing: .5px; margin-bottom: 1rem; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #f1f2f6; }
  th { font-size: 11px; text-transform: uppercase; letter-spacing: .4px; color: #b2bec3; }
  tr:hover td { background: #f9f9fb; }
  td:first-child { font-family: monospace; font-size: 13px; max-width: 320px;
                   overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  td:nth-child(2) { font-weight: 600; width: 70px; }
  td:last-child { width: 200px; }
  .bar { background: #f1f2f6; border-radius: 4px; height: 8px; }
  .bar-fill { background: linear-gradient(90deg, #0984e3, #74b9ff);
              height: 8px; border-radius: 4px; min-width: 2px; }
  .badge { padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }
  .badge.success  { background: #d4edda; color: #155724; }
  .badge.redirect { background: #d1ecf1; color: #0c5460; }
  .badge.error4   { background: #fff3cd; color: #856404; }
  .badge.error5   { background: #f8d7da; color: #721c24; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }
  .error-log { font-family: monospace; font-size: 12px; background: #2d3436; color: #dfe6e9;
               border-radius: 6px; padding: 1rem; overflow-x: auto; max-height: 200px; overflow-y: auto; }
  .error-log p { margin-bottom: 4px; line-height: 1.5; }
  .error-log .err4 { color: #fdcb6e; }
  .error-log .err5 { color: #ff7675; }
  footer { text-align: center; padding: 2rem; color: #b2bec3; font-size: 12px; }
  @media (max-width: 768px) { .grid-4 { grid-template-columns: 1fr 1fr; } .grid-2 { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header>
  <div>
    <h1>Access Log Report</h1>
    <p>$(basename "$LOG_FILE") &nbsp;·&nbsp; Generated $(date '+%Y-%m-%d %H:%M:%S') &nbsp;·&nbsp; Last ${LAST_HOURS}h</p>
  </div>
  <span class="badge-header">DevOps Toolkit</span>
</header>
<main>

  <div class="grid-4">
    <div class="metric"><div class="metric-label">Total Requests</div>
      <div class="metric-val">${TOTAL}</div>
      <div class="metric-sub">in analysis window</div></div>
    <div class="metric green"><div class="metric-label">2xx Success</div>
      <div class="metric-val">${CNT_2XX}</div>
      <div class="metric-sub">$(( TOTAL > 0 ? 100 * CNT_2XX / TOTAL : 0 ))% of traffic</div></div>
    <div class="metric red"><div class="metric-label">Error Rate</div>
      <div class="metric-val">${error_rate}%</div>
      <div class="metric-sub">${CNT_4XX} client / ${CNT_5XX} server</div></div>
    <div class="metric amber"><div class="metric-label">Bandwidth</div>
      <div class="metric-val">${bw_mb}MB</div>
      <div class="metric-sub">avg ${avg_size} bytes/req</div></div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h2>Top ${TOP_N} IPs</h2>
      <table><thead><tr><th>IP Address</th><th>Requests</th><th>Share</th></tr></thead>
      <tbody>$(build_table_rows "${TMP_DIR}/top_ips.txt")</tbody></table>
    </div>
    <div class="card">
      <h2>Top ${TOP_N} Endpoints</h2>
      <table><thead><tr><th>Endpoint</th><th>Hits</th><th>Share</th></tr></thead>
      <tbody>$(build_table_rows "${TMP_DIR}/top_endpoints.txt")</tbody></table>
    </div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h2>HTTP Status Codes</h2>
      <table><thead><tr><th>Code</th><th>Count</th></tr></thead>
      <tbody>$(build_status_rows)</tbody></table>
    </div>
    <div class="card">
      <h2>HTTP Methods</h2>
      <table><thead><tr><th>Method</th><th>Count</th><th>Share</th></tr></thead>
      <tbody>$(build_table_rows "${TMP_DIR}/methods.txt")</tbody></table>
    </div>
  </div>

  <div class="card">
    <h2>Top ${TOP_N} User Agents</h2>
    <table><thead><tr><th>User Agent</th><th>Requests</th><th>Share</th></tr></thead>
    <tbody>$(build_table_rows "${TMP_DIR}/top_agents.txt")</tbody></table>
  </div>

  <div class="card">
    <h2>Recent Errors (4xx / 5xx)</h2>
    <div class="error-log">
$(while IFS= read -r line; do
  if echo "$line" | grep -q ' 5[0-9][0-9] '; then
    echo "<p class='err5'>$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</p>"
  else
    echo "<p class='err4'>$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</p>"
  fi
done < "${TMP_DIR}/errors.txt")
    </div>
  </div>

</main>
<footer>
  DevOps Automation Toolkit · log_analyzer.sh · $(hostname) · $(date '+%Y')
</footer>
</body>
</html>
HTML

  log_ok "HTML report written to: $OUTPUT_FILE"
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --log=*)        LOG_FILE="${arg#*=}" ;;
    --output=*)     OUTPUT_FILE="${arg#*=}" ;;
    --format=*)     LOG_FORMAT="${arg#*=}" ;;
    --last-hours=*) LAST_HOURS="${arg#*=}" ;;
    --top=*)        TOP_N="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--log FILE] [--output FILE] [--format nginx|apache] [--last-hours N] [--top N]"
      exit 0 ;;
  esac
done

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}Log Analyzer — DevOps Toolkit${RESET}"
  find_log_file
  local filtered_log; filtered_log=$(filter_log)
  parse_metrics "$filtered_log"
  generate_html_report

  # Print quick summary to terminal
  echo ""
  echo -e "${BOLD}Quick Summary:${RESET}"
  printf "  %-20s %s\n" "Total requests:"  "$TOTAL"
  printf "  %-20s %s\n" "2xx (success):"   "$CNT_2XX"
  printf "  %-20s %s\n" "4xx (client err):" "$CNT_4XX"
  printf "  %-20s %s\n" "5xx (server err):" "$CNT_5XX"
  printf "  %-20s %sMB\n" "Bandwidth:"     "$(( TOTAL_BYTES / 1048576 ))"
  echo ""
  echo -e "${CYAN}Open the report:${RESET} $OUTPUT_FILE"
}

main "$@"
