#!/usr/bin/env bash
# Show how fresh the backups are, using the markers the backup container writes.
# Usage: scripts/backup-status.sh [--max-age HOURS] [--json] [--quiet]
#   --max-age HOURS  override BACKUP_MAX_AGE_HOURS for this check (0 = no age limit)
#   --json           machine-readable output (one JSON object)
#   --quiet          no output, exit code only (for cron or a monitoring agent)
# Exit codes: 0 = ok or no backup yet, 1 = last run failed or backup is stale, 2 = usage error,
#             3 = the backup container could not be queried.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --max-age)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { printf 'error: --max-age needs a whole number of hours\n' >&2; exit 2; }
      ARGS+=(--max-age "$2"); shift 2 ;;
    --json|--quiet) ARGS+=("$1"); shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

require_cmd docker
require_env_file

# docker compose exec also exits 1 when the service is down; tell that apart
# from a stale backup so monitors do not report the wrong problem.
if [ -z "$(compose ps --status running -q backup 2> /dev/null)" ]; then
  warn "the backup container is not running; start it with: make up"
  exit 3
fi

# status.sh exits 1 for a stale or failed backup; pass that through unchanged.
set +e
compose exec -T backup /usr/local/bin/status.sh ${ARGS[@]+"${ARGS[@]}"}
rc=$?
set -e
case "$rc" in
  0|1) exit "$rc" ;;
  *) warn "could not query the backup container (exit $rc); is the stack running? try: make ps"; exit 3 ;;
esac
