# DevOps Automation Toolkit

> A production-grade collection of shell scripts for system monitoring, application deployment, automated backups, and log analysis.

**Author:** Abhinav | CSE (Cybersecurity) 
**Stack:** Bash · Linux · Nginx · MySQL/PostgreSQL · systemd  
**Purpose:** DevOps portfolio project demonstrating automation, reliability engineering, and operational tooling.

---

## Overview

| Script | Purpose | Key Concepts |
|---|---|---|
| `monitor.sh` | Real-time system health monitoring | `/proc/stat`, threshold alerts, TTY detection |
| `deploy.sh` | Zero-downtime deployment with auto-rollback | Atomic symlinks, health checks, release retention |
| `backup.sh` | File + database backup with rotation | `tar`, `mysqldump`, `pg_dump`, retention policy |
| `log_analyzer.sh` | Parse access logs → HTML report | `awk`, `grep`, HTML generation, status analysis |

---

## Quick Start

```bash
# Clone and set up
git clone https://github.com/yourusername/devops-toolkit.git
cd devops-toolkit
chmod +x scripts/*.sh

# Run health monitor (single report)
./scripts/monitor.sh

# Run health monitor in watch mode (refresh every 5s)
./scripts/monitor.sh --watch

# Deploy application (dry run first)
./scripts/deploy.sh --dry-run --env=staging
./scripts/deploy.sh --env=production

# Roll back last deployment
./scripts/deploy.sh --rollback

# Backup files + databases
./scripts/backup.sh --type=all

# List existing backups
./scripts/backup.sh --list

# Analyze Nginx logs (auto-detects log file)
./scripts/log_analyzer.sh

# Analyze specific log, last 12 hours
./scripts/log_analyzer.sh --log=/var/log/nginx/access.log --last-hours=12
```

---

## Project Structure

```
devops-toolkit/
├── scripts/
│   ├── monitor.sh          # System health monitor
│   ├── deploy.sh           # Deployment + rollback
│   ├── backup.sh           # Backup automation
│   └── log_analyzer.sh     # Log parsing + HTML reports
├── config/
│   ├── .env.production     # Production config (git-ignored)
│   └── .env.staging        # Staging config (git-ignored)
├── logs/                   # Auto-created at runtime
│   ├── alerts.log
│   ├── deploy_*.log
│   ├── backup.log
│   └── reports/
│       └── log_report_*.html
├── backups/                # Auto-created at runtime
│   ├── files/
│   ├── databases/
│   └── reports/
└── README.md
```

---

## Script Reference

### `monitor.sh` — System Health Monitor

Monitors CPU, RAM, disk usage, and service status. Alerts are written to `logs/alerts.log` when thresholds are exceeded.

```bash
./scripts/monitor.sh [OPTIONS]

Options:
  --report                  Generate a single health report (default)
  --watch                   Continuous mode, refresh every 5s
  --threshold-cpu=N         Alert threshold for CPU % (default: 85)
  --threshold-ram=N         Alert threshold for RAM % (default: 80)
  --threshold-disk=N        Alert threshold for disk % (default: 90)
```

**How it works:**
- CPU usage is calculated from a 1-second `/proc/stat` sample (no external tools needed)
- RAM is read from `/proc/meminfo` for accuracy
- Disk checks all non-tmpfs partitions via `df`
- Services checked via `systemctl is-active` with a `pgrep` fallback

---

### `deploy.sh` — Zero-Downtime Deployment

Implements the **releases/symlink** pattern used by tools like Capistrano and Deployer. Each deployment creates a timestamped release directory; the `current` symlink is atomically swapped only after dependencies are installed.

```bash
./scripts/deploy.sh [OPTIONS]

Options:
  --env=production|staging  Target environment (default: production)
  --branch=BRANCH           Git branch to deploy (default: main)
  --rollback                Roll back to the previous release
  --dry-run                 Show what would happen without executing
```

**Deployment flow:**
```
pre-flight checks → fetch code → install deps → swap symlink → restart service → health check
                                                                                      ↓ FAIL
                                                                                auto rollback
```

**Environment variables:**
```bash
APP_NAME=myapp
APP_DIR=/var/www/myapp
GIT_REPO=https://github.com/user/repo.git
GIT_BRANCH=main
SERVICE_NAME=myapp
HEALTH_CHECK_URL=http://localhost:8080/health
RELEASES_DIR=/var/www/releases/myapp
```

---

### `backup.sh` — Automated Backup

Supports both file-system and database backups with configurable retention policies.

```bash
./scripts/backup.sh [OPTIONS]

Options:
  --type=files|db|all       What to back up (default: all)
  --destination=/path       Override backup destination
  --list                    List all stored backups
  --verify                  Verify integrity of all backup archives
```

**Retention policy** (configurable in script):
- Daily: keep last 7
- Weekly: keep last 4
- Monthly: keep last 3

**Database support:**
- MySQL/MariaDB via `mysqldump --single-transaction` (non-locking)
- PostgreSQL via `pg_dump -Fc` (custom format, parallel-restore ready)
- Credentials never exposed in process list (uses MySQL options file)

---

### `log_analyzer.sh` — Log Analysis & Reporting

Parses Nginx/Apache Combined Log Format and produces a self-contained HTML report.

```bash
./scripts/log_analyzer.sh [OPTIONS]

Options:
  --log=/path/to/access.log   Log file to analyze (auto-detects if omitted)
  --output=report.html        Output path for HTML report
  --last-hours=N              Analyze only last N hours (default: 24; 0 = all)
  --top=N                     Show top N per category (default: 10)
```

**Report includes:**
- Total requests, 2xx/3xx/4xx/5xx counts, error rate, total bandwidth
- Top IPs, top endpoints, HTTP methods breakdown
- Status code distribution with colour-coded badges
- Top user agents
- Recent error log tail with syntax highlighting

---

## Automation with cron

```cron
# Run health monitor every 5 minutes, save report
*/5 * * * * /opt/devops-toolkit/scripts/monitor.sh --report >> /var/log/healthmon.log 2>&1

# Daily backup at 2am
0 2 * * * /opt/devops-toolkit/scripts/backup.sh --type=all >> /var/log/backup.log 2>&1

# Log analysis report every hour
0 * * * * /opt/devops-toolkit/scripts/log_analyzer.sh --last-hours=1 2>&1
```

---

## Security Notes

- Database passwords are never passed as CLI arguments (uses options files / env vars)
- Scripts use `set -euo pipefail` — fail fast on errors, undefined variables, and pipe failures
- Temporary files are created in `mktemp` directories and cleaned up via `trap EXIT`
- Backup archives exclude `.git`, `node_modules`, and `__pycache__` by default
- All scripts support `--dry-run` or equivalent for safe pre-flight testing

---

## Skills Demonstrated

| Area | Details |
|---|---|
| **Shell scripting** | `bash`, `awk`, `grep`, `sed`, `find`, `tar`, process substitution, arrays |
| **Linux internals** | `/proc/stat`, `/proc/meminfo`, `df`, `systemctl`, `pgrep` |
| **DevOps patterns** | Blue-green-style symlink deploys, health checks, auto-rollback |
| **Database ops** | `mysqldump`, `pg_dump`, credential handling best practices |
| **Observability** | Structured logging, HTML report generation, alert thresholds |
| **Reliability** | `set -euo pipefail`, `trap` cleanup, input validation, dry-run mode |

---


