#!/usr/bin/env bash
# Generate .env from .env.example with strong random secrets. Never overwrites.
# Usage: scripts/init.sh [--domain n8n.example.com] [--email you@example.com]
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOMAIN=""
EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email)  EMAIL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd openssl
[ -f .env.example ] || die ".env.example not found"
if [ -e .env ]; then
  die ".env already exists; refusing to overwrite. Delete it manually if you really want a fresh one (this changes your encryption key!)."
fi

if [ -z "$DOMAIN" ] && [ -t 0 ]; then read -r -p "Domain for n8n (e.g. n8n.example.com): " DOMAIN; fi
if [ -z "$EMAIL" ]  && [ -t 0 ]; then read -r -p "E-mail for Let's Encrypt notices: " EMAIL; fi

umask 077
cp .env.example .env

env_set POSTGRES_PASSWORD "$(openssl rand -hex 24)"
env_set REDIS_PASSWORD "$(openssl rand -hex 24)"
env_set N8N_ENCRYPTION_KEY "$(openssl rand -hex 32)"
[ -n "$DOMAIN" ] && env_set N8N_HOST "$DOMAIN"
[ -n "$EMAIL" ] && env_set ACME_EMAIL "$EMAIL"
chmod 600 .env

log ".env created (mode 600)."
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  warn "Edit .env and set N8N_HOST and ACME_EMAIL before starting the stack."
fi
warn "Back up N8N_ENCRYPTION_KEY from .env somewhere safe (password manager). Losing it makes stored credentials unrecoverable."
log "Next: make up"
