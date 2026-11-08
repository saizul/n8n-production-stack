#!/usr/bin/env bash
# Dump PostgreSQL (custom format), verify it, apply retention, optionally upload via rclone.
# Usage: dump.sh [label]      Prints the path of the created dump as the last stdout line.
set -euo pipefail

# shellcheck disable=SC1091
[ -f /etc/backup.env ] && . /etc/backup.env

LABEL="${1:-}"
BACKUP_DIR="/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="n8n-${PGDATABASE}-${STAMP}${LABEL:+-$LABEL}.dump"
TARGET="${BACKUP_DIR}/${NAME}"
TMP="${TARGET}.tmp"

log() { echo "[backup] $(date '+%F %T') $*" >&2; }
trap 'rm -f "$TMP"' EXIT

log "dumping ${PGDATABASE}@${PGHOST} -> ${NAME}"
pg_dump --format=custom --compress=6 --no-owner --file="$TMP"

# A dump that cannot be listed cannot be restored: fail loudly.
pg_restore --list "$TMP" > /dev/null
mv "$TMP" "$TARGET"
log "ok ($(wc -c < "$TARGET") bytes)"

# Local retention (pre-restore safety dumps are pruned the same way).
if [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_DIR" -maxdepth 1 -name 'n8n-*.dump' -type f -mtime "+${RETENTION_DAYS}" -print -delete \
    | sed 's/^/[backup] pruned /' >&2 || true
fi

# Optional S3-compatible upload. Remote is configured through rclone env vars.
if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  export RCLONE_CONFIG_REMOTE_TYPE=s3
  export RCLONE_CONFIG_REMOTE_PROVIDER="${S3_PROVIDER:-AWS}"
  export RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
  export RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
  export RCLONE_CONFIG_REMOTE_REGION="${S3_REGION:-us-east-1}"
  [ -n "${S3_ENDPOINT:-}" ] && export RCLONE_CONFIG_REMOTE_ENDPOINT="$S3_ENDPOINT"
  DEST="REMOTE:${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX:-n8n}"
  log "uploading to ${DEST}"
  rclone copy "$TARGET" "$DEST" --s3-no-check-bucket
  remote_days="${BACKUP_S3_RETENTION_DAYS:-30}"
  if [ "$remote_days" -gt 0 ]; then
    rclone delete "$DEST" --min-age "${remote_days}d" --include 'n8n-*.dump' || log "remote prune failed (non-fatal)"
  fi
fi

date +%s > "${BACKUP_DIR}/.last_success"
echo "$TARGET"
