#!/usr/bin/env bash
# Container entrypoint: installs the cron schedule and runs crond in the foreground.
set -euo pipefail

SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"

# Export the full environment so cron jobs (which start with an empty one) see it.
export -p > /etc/backup.env
chmod 600 /etc/backup.env

mkdir -p /etc/crontabs
printf '%s /usr/local/bin/dump.sh >> /proc/1/fd/1 2>> /proc/1/fd/2\n' "$SCHEDULE" > /etc/crontabs/root

echo "[backup] schedule: '${SCHEDULE}' (TZ=${TZ:-UTC}), local retention: ${BACKUP_RETENTION_DAYS:-14} days"
if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  echo "[backup] remote upload enabled: s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX:-n8n}"
fi

if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  /usr/local/bin/dump.sh || echo "[backup] initial backup failed" >&2
fi

exec crond -f -l 8
