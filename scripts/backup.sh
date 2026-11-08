#!/usr/bin/env bash
# Run an on-demand PostgreSQL backup now and copy it to ./backups on the host.
# Usage: scripts/backup.sh [label]
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd docker
require_env_file

LABEL="${1:-manual}"
log "Creating backup (label: $LABEL)"
remote_path="$(compose exec -T backup /usr/local/bin/dump.sh "$LABEL" | tail -n 1)"
[ -n "$remote_path" ] || die "backup produced no output"

mkdir -p "$ROOT_DIR/backups"
compose cp "backup:${remote_path}" "$ROOT_DIR/backups/"
log "Backup saved: backups/$(basename "$remote_path")"
