#!/usr/bin/env bash
# Pull new images, take a backup, then recreate containers.
# Usage: scripts/update.sh [n8n-version]     e.g. scripts/update.sh 2.46.7
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd docker
require_env_file

NEW_VERSION="${1:-}"
if [ -n "$NEW_VERSION" ]; then
  [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 2.46.7"
  export N8N_VERSION="$NEW_VERSION"
fi

log "Pulling images (n8n ${N8N_VERSION:-$(env_get N8N_VERSION)})"
compose pull
compose build --pull backup

log "Backing up before the upgrade"
compose up -d postgres backup
"$ROOT_DIR/scripts/backup.sh" pre-update

if [ -n "$NEW_VERSION" ]; then
  env_set N8N_VERSION "$NEW_VERSION"
  log "N8N_VERSION in .env set to $NEW_VERSION"
fi

log "Recreating containers"
compose up -d --remove-orphans
"$ROOT_DIR/scripts/healthcheck.sh" --wait 300
log "Update finished. Review release notes if n8n crossed a major version."
