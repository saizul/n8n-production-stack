#!/usr/bin/env bash
# Restore PostgreSQL from a backup. DESTRUCTIVE: replaces the current database contents.
# Usage: scripts/restore.sh <latest | file-in-backup-volume | /path/on/host.dump> [--yes]
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SOURCE="${1:-}"
ASSUME_YES="${2:-}"
[ -n "$SOURCE" ] || die "usage: scripts/restore.sh <latest|backup-name|/host/path.dump> [--yes]"

require_cmd docker
require_env_file

# Resolve the dump to a path inside the backup container.
if [ -f "$SOURCE" ]; then
  log "Copying host file into the backup container"
  compose cp "$SOURCE" "backup:/tmp/restore.dump"
  CONTAINER_PATH="/tmp/restore.dump"
elif [ "$SOURCE" = "latest" ]; then
  CONTAINER_PATH="$(compose exec -T backup sh -c 'ls -1t /backups/n8n-*.dump 2>/dev/null | head -n 1' | tr -d '\r')"
  [ -n "$CONTAINER_PATH" ] || die "no backups found in the backup volume"
else
  CONTAINER_PATH="/backups/$(basename "$SOURCE")"
  compose exec -T backup test -f "$CONTAINER_PATH" || die "no such backup in the volume: $CONTAINER_PATH"
fi

compose exec -T backup pg_restore --list "$CONTAINER_PATH" > /dev/null || die "not a valid pg_dump custom-format file"

warn "This will STOP n8n and REPLACE the database '$(env_get POSTGRES_DB)' with: $CONTAINER_PATH"
if [ "$ASSUME_YES" != "--yes" ]; then
  read -r -p "Type 'restore' to continue: " answer
  [ "$answer" = "restore" ] || die "aborted"
fi

log "Taking a safety backup of the current state"
compose exec -T backup /usr/local/bin/dump.sh pre-restore > /dev/null

log "Stopping n8n processes"
compose stop n8n-main n8n-worker n8n-webhook caddy

log "Restoring"
compose exec -T backup pg_restore --clean --if-exists --no-owner --no-privileges \
  --single-transaction --exit-on-error --dbname "$(env_get POSTGRES_DB)" "$CONTAINER_PATH"

log "Starting the stack"
compose up -d
log "Restore complete. Verify with: scripts/healthcheck.sh --wait 180"
