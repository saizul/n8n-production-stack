#!/usr/bin/env bash
# Verify a backup by restoring it into a throwaway PostgreSQL container.
# Read-only for the live stack: nothing is stopped, replaced or written to the production database.
# Usage: scripts/restore-test.sh [latest | file-in-backup-volume | /path/on/host.dump]
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SOURCE="${1:-latest}"
# Tables every n8n database must contain once migrations have run.
REQUIRED_TABLES=(workflow_entity credentials_entity execution_entity)

require_cmd docker

# Use the same PostgreSQL image as the stack so the dump is tested against the real server major version.
IMAGE="$(awk '/^  postgres:/ {f=1; next} f && /^[[:space:]]+image:/ {print $2; exit}' "$ROOT_DIR/compose.yaml")"
[ -n "$IMAGE" ] || die "could not read the postgres image from compose.yaml"

WORKDIR="$(mktemp -d)"
CONTAINER="n8n-restore-test-$$"
cleanup() {
  docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Resolve the dump to a file on the host.
if [ -f "$SOURCE" ]; then
  DUMP="$SOURCE"
else
  require_env_file
  if [ "$SOURCE" = "latest" ]; then
    REMOTE="$(compose exec -T backup sh -c 'ls -1t /backups/n8n-*.dump 2>/dev/null | head -n 1' | tr -d '\r')"
    [ -n "$REMOTE" ] || die "no backups found in the backup volume"
  else
    REMOTE="/backups/$(basename "$SOURCE")"
    compose exec -T backup test -f "$REMOTE" || die "no such backup in the volume: $REMOTE"
  fi
  log "Copying $(basename "$REMOTE") out of the backup container"
  compose cp "backup:${REMOTE}" "$WORKDIR/restore.dump"
  DUMP="$WORKDIR/restore.dump"
fi
[ -s "$DUMP" ] || die "dump is empty: $DUMP"

log "Starting throwaway $IMAGE"
docker run -d --name "$CONTAINER" --network none \
  -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=restore_test \
  "$IMAGE" > /dev/null

for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -q -U postgres -d restore_test && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -q -U postgres -d restore_test || die "throwaway PostgreSQL did not become ready"

docker cp "$DUMP" "$CONTAINER:/tmp/restore.dump"
docker exec "$CONTAINER" pg_restore --list /tmp/restore.dump > /dev/null || die "not a valid pg_dump custom-format file"

log "Restoring $(basename "$SOURCE") into the throwaway database"
docker exec "$CONTAINER" pg_restore --no-owner --no-privileges --exit-on-error \
  -U postgres -d restore_test /tmp/restore.dump || die "pg_restore failed"

psql_q() { docker exec "$CONTAINER" psql -U postgres -d restore_test -Atq -c "$1"; }

failed=0
for table in "${REQUIRED_TABLES[@]}"; do
  if [ "$(psql_q "SELECT to_regclass('public.${table}') IS NOT NULL")" = "t" ]; then
    log "table ${table}: $(psql_q "SELECT count(*) FROM public.${table}") rows"
  else
    warn "required table missing: ${table}"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || die "restore test FAILED: the dump does not look like an n8n database"

log "Restore test passed ($(psql_q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'") public tables)"
