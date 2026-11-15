#!/usr/bin/env bash
# Dump PostgreSQL (custom format), verify it, apply retention, optionally upload via rclone.
# Usage: dump.sh [label]      Prints the path of the created dump as the last stdout line.
#
# Every run records its outcome in $BACKUP_DIR/.last_success or .last_failure
# (Unix timestamps, read by status.sh) and, when BACKUP_HEALTHCHECK_URL is set,
# pings an external monitor so a missed or failed backup raises an alert.
set -euo pipefail

BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-/etc/backup.env}"
# shellcheck disable=SC1090
[ -f "$BACKUP_ENV_FILE" ] && . "$BACKUP_ENV_FILE"

LABEL="${1:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="n8n-${PGDATABASE}-${STAMP}${LABEL:+-$LABEL}.dump"
TARGET="${BACKUP_DIR}/${NAME}"
TMP="${TARGET}.tmp"
STEP="starting"

log() { echo "[backup] $(date '+%F %T') $*" >&2; }

# Build the failure URL: BACKUP_HEALTHCHECK_FAIL_URL if set, otherwise the
# healthchecks.io convention "<url>/fail". URLs with a query string (Uptime Kuma
# push URLs, for example) get no automatic failure URL; the monitor then alerts
# when the success ping does not arrive in time.
fail_url() {
  local url="${BACKUP_HEALTHCHECK_URL:-}"
  if [ -n "${BACKUP_HEALTHCHECK_FAIL_URL:-}" ]; then
    printf '%s' "$BACKUP_HEALTHCHECK_FAIL_URL"
  elif [ -n "$url" ] && [[ "$url" != *\?* ]]; then
    printf '%s/fail' "${url%/}"
  fi
}

# ping URL: notify the monitor. Never fails the backup and never logs the URL,
# because monitor URLs usually embed a secret token.
ping_monitor() {
  local url="$1"
  [ -n "$url" ] || return 0
  if ! command -v curl > /dev/null 2>&1; then
    log "curl not found, monitor not notified"
    return 0
  fi
  curl -fsS --max-time 10 --retry 3 --retry-delay 2 -o /dev/null "$url" \
    || log "monitor ping failed (non-fatal)"
}

on_exit() {
  local status=$?
  rm -f "$TMP"
  if [ "$status" -ne 0 ]; then
    log "FAILED during: ${STEP} (exit ${status})"
    date +%s > "${BACKUP_DIR}/.last_failure" 2> /dev/null || true
    ping_monitor "$(fail_url)"
  fi
  exit "$status"
}
trap on_exit EXIT

STEP="dump"
log "dumping ${PGDATABASE}@${PGHOST} -> ${NAME}"
pg_dump --format=custom --compress=6 --no-owner --file="$TMP"

# A dump that cannot be listed cannot be restored: fail loudly.
STEP="verify"
pg_restore --list "$TMP" > /dev/null
mv "$TMP" "$TARGET"
log "ok ($(wc -c < "$TARGET" | tr -d ' ') bytes)"

# Local retention (pre-restore safety dumps are pruned the same way).
STEP="retention"
if [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_DIR" -maxdepth 1 -name 'n8n-*.dump' -type f -mtime "+${RETENTION_DAYS}" -print -delete \
    | sed 's/^/[backup] pruned /' >&2 || true
fi

# Optional S3-compatible upload. Remote is configured through rclone env vars.
if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  STEP="upload"
  export RCLONE_CONFIG_REMOTE_TYPE=s3
  export RCLONE_CONFIG_REMOTE_PROVIDER="${S3_PROVIDER:-AWS}"
  export RCLONE_CONFIG_REMOTE_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
  export RCLONE_CONFIG_REMOTE_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
  export RCLONE_CONFIG_REMOTE_REGION="${S3_REGION:-us-east-1}"
  if [ -n "${S3_ENDPOINT:-}" ]; then
    export RCLONE_CONFIG_REMOTE_ENDPOINT="$S3_ENDPOINT"
  fi
  DEST="REMOTE:${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX:-n8n}"
  log "uploading to ${DEST}"
  rclone copy "$TARGET" "$DEST" --s3-no-check-bucket
  remote_days="${BACKUP_S3_RETENTION_DAYS:-30}"
  if [ "$remote_days" -gt 0 ]; then
    rclone delete "$DEST" --min-age "${remote_days}d" --include 'n8n-*.dump' || log "remote prune failed (non-fatal)"
  fi
fi

STEP="finish"
date +%s > "${BACKUP_DIR}/.last_success"
ping_monitor "${BACKUP_HEALTHCHECK_URL:-}"
echo "$TARGET"
