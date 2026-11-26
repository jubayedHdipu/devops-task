#!/usr/bin/env bash
set -euo pipefail

# Host health check and alerting script
# Exit codes: 0 = healthy, 1 = warning, 2 = critical

CPU_WARN_THRESHOLD=90
MEM_WARN_THRESHOLD=85
DISK_WARN_THRESHOLD=80
CRIT_THRESHOLD=95
LOG_FILE="health_log.txt"
MAX_LOG_BYTES=1048576 # 1 MiB log rotation threshold
OUTPUT_JSON=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Collects CPU, memory, disk usage (all mounted filesystems), load average,
and top 5 memory-consuming processes, appending results to a rotated log file.

Options:
  --cpu <percent>       CPU warning threshold percentage (default: ${CPU_WARN_THRESHOLD})
  --mem <percent>       Memory warning threshold percentage (default: ${MEM_WARN_THRESHOLD})
  --disk <percent>      Disk warning threshold percentage (default: ${DISK_WARN_THRESHOLD})
  --log-file <path>     Path to log file (default: ${LOG_FILE})
  --json                Output report in JSON format
  -h, --help            Show this help message and exit

Environment Variables:
  ALERT_WEBHOOK_URL     Optional Slack/Discord webhook URL for warning/critical alerts

Exit Codes:
  0  Healthy (all metrics within thresholds)
  1  Warning (one or more metrics exceeded warning threshold)
  2  Critical (one or more metrics >= ${CRIT_THRESHOLD}% or system check failure)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      CPU_WARN_THRESHOLD="${2:?Missing value for --cpu}"
      shift 2
      ;;
    --mem)
      MEM_WARN_THRESHOLD="${2:?Missing value for --mem}"
      shift 2
      ;;
    --disk)
      DISK_WARN_THRESHOLD="${2:?Missing value for --disk}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:?Missing value for --log-file}"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

rotate_log_if_needed() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [[ "$size" -ge "$MAX_LOG_BYTES" ]]; then
      [[ -f "${file}.2" ]] && rm -f "${file}.2"
      [[ -f "${file}.1" ]] && mv -f "${file}.1" "${file}.2"
      mv -f "$file" "${file}.1"
    fi
  fi
}

get_cpu_usage() {
  if [[ -r /proc/stat ]]; then
    local user nice system idle iowait irq softirq steal _
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    local total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local idle1=$((idle + iowait))
    sleep 0.5
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    local total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local idle2=$((idle + iowait))
    local diff_total=$((total2 - total1))
    local diff_idle=$((idle2 - idle1))
    if [[ "$diff_total" -gt 0 ]]; then
      echo $(( (100 * (diff_total - diff_idle)) / diff_total ))
      return
    fi
  fi
  echo 0
}

get_mem_usage() {
  if command -v free >/dev/null 2>&1; then
    free -m | awk '/^Mem:/ { if ($2 > 0) printf "%.0f", ($3 / $2) * 100; else print 0 }'
  else
    echo 0
  fi
}

get_load_avg() {
  if [[ -r /proc/loadavg ]]; then
    awk '{print $1", "$2", "$3}' /proc/loadavg
  else
    uptime | awk -F'load average:' '{print $2}' | xargs
  fi
}

TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
HOSTNAME_STR="$(hostname 2>/dev/null || echo 'unknown-host')"
CPU_PCT="$(get_cpu_usage)"
MEM_PCT="$(get_mem_usage)"
LOAD_AVG="$(get_load_avg)"
DISK_REPORT="$(df -P -x tmpfs -x devtmpfs | awk 'NR>1 {print $6":"$5}')"
TOP_PROCS="$(ps -eo pid,comm,%mem,%cpu --sort=-%mem 2>/dev/null | head -n 6 | tail -n 5 | awk '{printf "%s(pid=%s,mem=%s%%,cpu=%s%%); ", $2, $1, $3, $4}')"

EXIT_CODE=0
WARNINGS=()

if [[ "$CPU_PCT" -ge "$CRIT_THRESHOLD" ]]; then
  EXIT_CODE=2
  WARNINGS+=("[CRITICAL] CPU usage at ${CPU_PCT}% (critical >= ${CRIT_THRESHOLD}%)")
elif [[ "$CPU_PCT" -ge "$CPU_WARN_THRESHOLD" ]]; then
  [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
  WARNINGS+=("[WARNING] CPU usage at ${CPU_PCT}% (threshold: ${CPU_WARN_THRESHOLD}%)")
fi

if [[ "$MEM_PCT" -ge "$CRIT_THRESHOLD" ]]; then
  EXIT_CODE=2
  WARNINGS+=("[CRITICAL] Memory usage at ${MEM_PCT}% (critical >= ${CRIT_THRESHOLD}%)")
elif [[ "$MEM_PCT" -ge "$MEM_WARN_THRESHOLD" ]]; then
  [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
  WARNINGS+=("[WARNING] Memory usage at ${MEM_PCT}% (threshold: ${MEM_WARN_THRESHOLD}%)")
fi

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  mount_point="${entry%:*}"
  pct_raw="${entry##*:}"
  pct_num="${pct_raw%\%}"
  if [[ "$pct_num" =~ ^[0-9]+$ ]]; then
    if [[ "$pct_num" -ge "$CRIT_THRESHOLD" ]]; then
      EXIT_CODE=2
      WARNINGS+=("[CRITICAL] Disk usage on ${mount_point} at ${pct_num}% (critical >= ${CRIT_THRESHOLD}%)")
    elif [[ "$pct_num" -ge "$DISK_WARN_THRESHOLD" ]]; then
      [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1
      WARNINGS+=("[WARNING] Disk usage on ${mount_point} at ${pct_num}% (threshold: ${DISK_WARN_THRESHOLD}%)")
    fi
  fi
done <<< "$DISK_REPORT"

STATUS_LABEL="healthy"
[[ "$EXIT_CODE" -eq 1 ]] && STATUS_LABEL="warning"
[[ "$EXIT_CODE" -eq 2 ]] && STATUS_LABEL="critical"

DISK_INLINE="$(echo "$DISK_REPORT" | tr '\n' ' ' | xargs)"
WARN_TEXT="none"
if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  WARN_TEXT="$(printf '%s | ' "${WARNINGS[@]}")"
  WARN_TEXT="${WARN_TEXT% | }"
fi

LOG_ENTRY="[${TIMESTAMP}] host=${HOSTNAME_STR} status=${STATUS_LABEL} cpu=${CPU_PCT}% mem=${MEM_PCT}% load=\"${LOAD_AVG}\" disks=\"${DISK_INLINE}\" top5_mem=\"${TOP_PROCS}\" alerts=\"${WARN_TEXT}\""

rotate_log_if_needed "$LOG_FILE"
printf '%s\n' "$LOG_ENTRY" >> "$LOG_FILE"

if [[ "${#WARNINGS[@]}" -gt 0 ]] && [[ "$OUTPUT_JSON" == false ]]; then
  for msg in "${WARNINGS[@]}"; do
    echo "$msg"
  done
fi

if [[ "$OUTPUT_JSON" == true ]]; then
  cat <<EOF
{"timestamp":"${TIMESTAMP}","host":"${HOSTNAME_STR}","status":"${STATUS_LABEL}","exit_code":${EXIT_CODE},"cpu_percent":${CPU_PCT},"memory_percent":${MEM_PCT},"load_average":"${LOAD_AVG}","disks":"${DISK_INLINE}","top_processes":"${TOP_PROCS}","alerts":"${WARN_TEXT}"}
EOF
else
  echo "$LOG_ENTRY"
fi

# Send Slack/Discord notification if ALERT_WEBHOOK_URL is configured and status is non-healthy
if [[ "$EXIT_CODE" -gt 0 ]] && [[ -n "${ALERT_WEBHOOK_URL:-}" ]]; then
  if command -v curl >/dev/null 2>&1; then
    PAYLOAD="{\"text\":\"[${STATUS_LABEL^^}] ${HOSTNAME_STR}: ${WARN_TEXT}\",\"content\":\"[${STATUS_LABEL^^}] ${HOSTNAME_STR}: ${WARN_TEXT}\"}"
    curl -fsS -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
fi

exit "$EXIT_CODE"