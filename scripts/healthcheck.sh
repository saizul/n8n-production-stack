#!/usr/bin/env bash
# Report container health for the stack. Exit 0 only if everything is healthy.
# Usage: scripts/healthcheck.sh [--wait SECONDS] [--external]
#   --wait N     keep polling up to N seconds for containers to become healthy
#   --external   also probe https://$N8N_HOST/healthz
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WAIT=0
EXTERNAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="${2:-}"; [[ "$WAIT" =~ ^[0-9]+$ ]] || die "--wait needs a number"; shift 2 ;;
    --external) EXTERNAL=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd docker

check_once() {
  local ids bad=0 id line name state health
  ids="$(compose ps -q)"
  [ -n "$ids" ] || { warn "no containers running"; return 1; }
  for id in $ids; do
    line="$(docker inspect -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")"
    IFS='|' read -r name state health <<< "$line"
    name="${name#/}"
    if [ "$state" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
      printf '  %-40s %s\n' "$name" "ok ($health)"
    else
      printf '  %-40s %s\n' "$name" "FAIL (state=$state health=$health)"
      bad=1
    fi
  done
  return "$bad"
}

deadline=$(( $(date +%s) + WAIT ))
until check_once; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "stack is not healthy (see TROUBLESHOOTING.md)"
  fi
  sleep 5
  echo "  ... waiting"
done

if [ "$EXTERNAL" -eq 1 ]; then
  require_cmd curl
  host="$(env_get N8N_HOST)"
  [ -n "$host" ] || die "N8N_HOST not set in .env"
  curl -fsS --max-time 15 "https://${host}/healthz" > /dev/null || die "https://${host}/healthz is not reachable"
  echo "  external https://${host}/healthz ok"
fi
log "All services healthy"
