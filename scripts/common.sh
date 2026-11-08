#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" > /dev/null 2>&1 || die "'$1' is required but not installed"
}

require_env_file() {
  [ -f "$ROOT_DIR/.env" ] || die ".env not found. Run scripts/init.sh first."
}

# Read KEY from .env (last occurrence wins, no shell evaluation).
env_get() {
  [ -f "$ROOT_DIR/.env" ] || return 0
  grep -E "^$1=" "$ROOT_DIR/.env" | tail -n 1 | cut -d= -f2- || true
}

# Set KEY=VALUE in .env (value must not contain '|' or newlines).
env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$ROOT_DIR/.env"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$ROOT_DIR/.env" > "$tmp"
  else
    cat "$ROOT_DIR/.env" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  cat "$tmp" > "$ROOT_DIR/.env"
  rm -f "$tmp"
}

compose() { docker compose "$@"; }
