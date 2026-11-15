#!/usr/bin/env bash
# Report backup freshness from the markers written by dump.sh.
# Usage: status.sh [--max-age HOURS] [--json] [--quiet]
#   --max-age HOURS  maximum age of the last successful backup (default:
#                    BACKUP_MAX_AGE_HOURS or 26; 0 disables the age check)
#   --json           print one JSON object instead of text
#   --quiet          print nothing, only set the exit code (container healthcheck)
# Exit codes: 0 = ok (or no backup has run yet), 1 = stale or last run failed, 2 = usage error.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
MAX_AGE="${BACKUP_MAX_AGE_HOURS:-26}"
FORMAT=text
QUIET=0

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --max-age) [ $# -ge 2 ] || usage_error "--max-age needs a number of hours"; MAX_AGE="$2"; shift 2 ;;
    --json) FORMAT=json; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[[ "$MAX_AGE" =~ ^[0-9]+$ ]] || usage_error "--max-age needs a whole number of hours (got '${MAX_AGE}')"

# read_stamp FILE: print the Unix timestamp stored in FILE, or nothing.
read_stamp() {
  local v=""
  [ -f "$1" ] && v="$(head -n 1 "$1" | tr -dc '0-9')"
  printf '%s' "$v"
}

fmt_time() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null \
    || printf '@%s' "$1"
}

fmt_age() {
  local s="$1"
  if [ "$s" -lt 3600 ]; then
    printf '%dm' $((s / 60))
  elif [ "$s" -lt 172800 ]; then
    printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
  else
    printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
  fi
}

now="$(date +%s)"
last_ok="$(read_stamp "$BACKUP_DIR/.last_success")"
last_fail="$(read_stamp "$BACKUP_DIR/.last_failure")"

count=0
bytes=0
newest=""
if [ -d "$BACKUP_DIR" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    count=$((count + 1))
    size="$(wc -c < "$f" | tr -d ' ')"
    bytes=$((bytes + size))
    # names embed the timestamp (n8n-<db>-YYYYmmdd-HHMMSS[-label].dump), so the
    # lexically greatest name is the newest dump
    if [ -z "$newest" ] || [[ "$(basename "$f")" > "$(basename "$newest")" ]]; then
      newest="$f"
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'n8n-*.dump' 2> /dev/null)
fi

state=ok
reason=""
age=""
if [ -n "$last_ok" ]; then
  age=$((now - last_ok))
  [ "$age" -ge 0 ] || age=0
fi

if [ -n "$last_fail" ] && { [ -z "$last_ok" ] || [ "$last_fail" -gt "$last_ok" ]; }; then
  state=failed
  reason="the most recent backup run failed at $(fmt_time "$last_fail")"
elif [ -z "$last_ok" ]; then
  state=none
  reason="no backup has completed yet"
elif [ "$MAX_AGE" -gt 0 ] && [ "$age" -gt $((MAX_AGE * 3600)) ]; then
  state=stale
  reason="last successful backup is $(fmt_age "$age") old (limit ${MAX_AGE}h)"
fi

case "$state" in
  failed|stale) rc=1 ;;
  *) rc=0 ;;
esac

[ "$QUIET" -eq 1 ] && exit "$rc"

if [ "$FORMAT" = json ]; then
  newest_json=null
  [ -z "$newest" ] || newest_json="\"$(basename "$newest")\""
  printf '{"status":"%s","last_success":%s,"last_failure":%s,"age_seconds":%s,"max_age_hours":%s,"dumps":%d,"bytes":%d,"newest":%s}\n' \
    "$state" \
    "${last_ok:-null}" \
    "${last_fail:-null}" \
    "${age:-null}" \
    "$MAX_AGE" \
    "$count" \
    "$bytes" \
    "$newest_json"
  exit "$rc"
fi

echo "backup status: ${state}${reason:+ - $reason}"
if [ -n "$last_ok" ]; then
  echo "  last success:  $(fmt_time "$last_ok") ($(fmt_age "$age") ago)"
else
  echo "  last success:  never"
fi
if [ -n "$last_fail" ]; then
  echo "  last failure:  $(fmt_time "$last_fail")"
fi
if [ "$MAX_AGE" -gt 0 ]; then
  echo "  max age:       ${MAX_AGE}h"
else
  echo "  max age:       disabled"
fi
echo "  local dumps:   ${count} ($((bytes / 1024)) KiB)"
[ -z "$newest" ] || echo "  newest dump:   $(basename "$newest")"
exit "$rc"
