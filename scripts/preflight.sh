#!/usr/bin/env bash
# Validate .env before starting or updating the stack. Never prints secret values.
# Usage: scripts/preflight.sh [--env-file PATH] [--strict] [--quiet]
#   --env-file PATH  check PATH instead of ./.env
#   --strict         treat warnings as errors (exit 1 on any warning)
#   --quiet          print only problems and the summary line
# Exit codes: 0 = no errors, 1 = errors found (or warnings with --strict), 2 = usage error.
set -euo pipefail
CALLER_PWD="$PWD"
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ENV_FILE="$ROOT_DIR/.env"
STRICT=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      [ -n "${2:-}" ] || { printf 'error: --env-file needs a path\n' >&2; exit 2; }
      case "$2" in
        /*) ENV_FILE="$2" ;;
        *)  ENV_FILE="$CALLER_PWD/$2" ;;
      esac
      shift 2 ;;
    --strict) STRICT=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ERRORS=0
WARNINGS=0

if [ -t 1 ]; then
  C_OK=$'\033[1;32m' C_FAIL=$'\033[1;31m' C_WARN=$'\033[1;33m' C_END=$'\033[0m'
else
  C_OK='' C_FAIL='' C_WARN='' C_END=''
fi
ok()   { [ "$QUIET" -eq 1 ] || printf '  %sok%s    %s\n' "$C_OK" "$C_END" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_END" "$*"; ERRORS=$((ERRORS + 1)); }
note() { printf '  %sWARN%s  %s\n' "$C_WARN" "$C_END" "$*"; WARNINGS=$((WARNINGS + 1)); }

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run scripts/init.sh first."

# Read KEY from the env file: last occurrence wins, no shell evaluation, surrounding quotes stripped.
val() {
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
  v="${v%$'\r'}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# True if the value is an unfilled template placeholder such as CHANGE_ME.
is_placeholder() {
  case "$(to_lower "$1")" in
    *change_me*|*changeme*|*replace_me*|*your_*|*'<'*'>'*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- File hygiene -------------------------------------------------------------
check_file() {
  local mode dups name
  name="$(basename "$ENV_FILE")"
  mode="$(stat -c '%a' "$ENV_FILE" 2> /dev/null || stat -f '%Lp' "$ENV_FILE" 2> /dev/null || echo '?')"
  case "$mode" in
    600|400) ok "$name permissions are $mode" ;;
    '?') note "could not read permissions of $ENV_FILE" ;;
    *) note "$name is mode $mode; it holds secrets, run: chmod 600 $name" ;;
  esac

  if grep -q $'\r' "$ENV_FILE"; then
    note "$name has Windows (CRLF) line endings; values may end with a stray carriage return"
  fi

  dups="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | cut -d= -f1 | sort | uniq -d | tr '\n' ' ')"
  if [ -n "$dups" ]; then
    note "duplicate keys (the last one wins): ${dups% }"
  fi
}

# --- Required variables ---------------------------------------------------------
REQUIRED_VARS="N8N_HOST ACME_EMAIL POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD REDIS_PASSWORD N8N_ENCRYPTION_KEY"

check_required() {
  local key missing=""
  for key in $REQUIRED_VARS; do
    if [ -z "$(val "$key")" ]; then
      missing="$missing $key"
    fi
  done
  if [ -n "$missing" ]; then
    fail "required variables missing or empty:$missing"
  else
    ok "all required variables are set"
  fi
}

# --- Public endpoint ------------------------------------------------------------
HOSTNAME_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'

check_domain() {
  local host lower
  host="$(val N8N_HOST)"
  [ -n "$host" ] || return 0
  lower="$(to_lower "$host")"

  case "$host" in
    *://*) fail "N8N_HOST must be a bare hostname without a scheme (got '$host'), e.g. n8n.example.com"; return ;;
    */*)   fail "N8N_HOST must not contain a path (got '$host')"; return ;;
    *:*)   fail "N8N_HOST must not contain a port (got '$host'); Caddy serves 443"; return ;;
    *' '*) fail "N8N_HOST must not contain spaces"; return ;;
  esac

  if [ "${#host}" -gt 253 ]; then
    fail "N8N_HOST is longer than 253 characters"
    return
  fi
  if [[ "$lower" =~ $IPV4_RE ]]; then
    note "N8N_HOST is an IP address ($host); use a DNS name so Let's Encrypt can issue a normal certificate"
    return
  fi
  if ! [[ "$lower" =~ $HOSTNAME_RE ]]; then
    fail "N8N_HOST '$host' is not a valid fully qualified domain name"
    return
  fi
  if [ "$host" != "$lower" ]; then
    note "N8N_HOST contains upper-case letters; use '$lower' so generated webhook URLs are consistent"
  fi

  case "$lower" in
    example.com|*.example.com|example.org|*.example.org|example.net|*.example.net|*.example|*.test|*.invalid|*.localhost|*.local)
      note "N8N_HOST '$host' is a reserved/placeholder domain; Let's Encrypt cannot issue a certificate for it" ;;
    *) ok "N8N_HOST '$host' looks like a valid public hostname" ;;
  esac
}

check_email() {
  local email domain
  email="$(val ACME_EMAIL)"
  [ -n "$email" ] || return 0
  if ! [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    fail "ACME_EMAIL '$email' is not a valid e-mail address"
    return
  fi
  domain="$(to_lower "${email#*@}")"
  case "$domain" in
    example.com|example.org|example.net|*.example|*.test|*.invalid)
      note "ACME_EMAIL uses a placeholder domain; you will miss certificate expiry notices" ;;
    *) ok "ACME_EMAIL looks valid" ;;
  esac
}

# --- Secrets --------------------------------------------------------------------
# Lower-case values that must never be used as a secret.
WEAK_SECRETS="change_me changeme password passw0rd secret admin root n8n postgres redis 123456 12345678 123456789 qwerty letmein default test example"

# check_secret NAME MIN_LENGTH
check_secret() {
  local key="$1" min="$2" v lower weak first problems=0
  v="$(val "$key")"
  [ -n "$v" ] || return 0
  lower="$(to_lower "$v")"

  if is_placeholder "$v"; then
    fail "$key is still a placeholder; run scripts/init.sh or generate one with: openssl rand -hex 32"
    return
  fi
  for weak in $WEAK_SECRETS; do
    if [ "$lower" = "$weak" ]; then
      fail "$key uses a well-known default/weak value"
      return
    fi
  done
  first="${v:0:1}"
  if [ -z "${v//"$first"/}" ]; then
    fail "$key is a single repeated character"
    return
  fi
  if [ "${#v}" -lt "$min" ]; then
    fail "$key is ${#v} characters; use at least $min (openssl rand -hex 24)"
    problems=1
  fi
  case "$v" in
    *'$'*)
      # Compose interpolates $VAR in .env; a literal dollar sign must be written as $$.
      if [[ "$v" =~ \$[A-Za-z_{] ]]; then
        fail "$key contains '\$' followed by a name; Docker Compose will try to interpolate it (write \$\$ or use a hex secret)"
        problems=1
      fi ;;
  esac
  case "$v" in
    *' '*|*'#'*|*'"'*|*"'"*|*\\*)
      note "$key contains spaces, quotes, '#' or backslashes; these are fragile in .env, prefer a hex secret"
      problems=1 ;;
  esac
  [ "$problems" -eq 1 ] || ok "$key looks strong (${#v} characters)"
}

check_encryption_key() {
  local key
  key="$(val N8N_ENCRYPTION_KEY)"
  [ -n "$key" ] || return 0
  check_secret N8N_ENCRYPTION_KEY 32
  if ! [[ "$key" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
    note "N8N_ENCRYPTION_KEY contains unusual characters; hex or base64 keys are the safest"
  fi
}

check_secret_reuse() {
  local pg redis enc user
  pg="$(val POSTGRES_PASSWORD)"
  redis="$(val REDIS_PASSWORD)"
  enc="$(val N8N_ENCRYPTION_KEY)"
  user="$(val POSTGRES_USER)"
  # Placeholders are reported by check_secret already; do not report them twice.
  is_placeholder "$pg" && pg=""
  is_placeholder "$redis" && redis=""
  is_placeholder "$enc" && enc=""
  if [ -n "$pg" ] && [ "$pg" = "$redis" ]; then
    note "POSTGRES_PASSWORD and REDIS_PASSWORD are identical; use separate secrets"
  fi
  if [ -n "$enc" ] && { [ "$enc" = "$pg" ] || [ "$enc" = "$redis" ]; }; then
    fail "N8N_ENCRYPTION_KEY is reused as a database or Redis password"
  fi
  if [ -n "$pg" ] && [ "$(to_lower "$pg")" = "$(to_lower "$user")" ]; then
    fail "POSTGRES_PASSWORD equals POSTGRES_USER"
  fi
}

check_identifiers() {
  local key v
  for key in POSTGRES_DB POSTGRES_USER; do
    v="$(val "$key")"
    [ -n "$v" ] || continue
    if ! [[ "$v" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
      fail "$key '$v' must be a lower-case PostgreSQL identifier (letters, digits, underscore)"
    fi
  done
}

# --- Versions and tuning --------------------------------------------------------
check_version() {
  local v
  v="$(val N8N_VERSION)"
  if [ -z "$v" ]; then
    note "N8N_VERSION is not set; compose.yaml falls back to its built-in default"
  elif [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "N8N_VERSION is pinned to $v"
  else
    fail "N8N_VERSION '$v' must be an exact version like 2.46.7 (never latest/next or a partial tag)"
  fi
}

# check_int NAME MIN [MAX]
check_int() {
  local key="$1" min="$2" max="${3:-}" v
  v="$(val "$key")"
  [ -n "$v" ] || return 0
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    fail "$key '$v' must be a whole number"
  elif [ "$v" -lt "$min" ]; then
    fail "$key is $v; minimum is $min"
  elif [ -n "$max" ] && [ "$v" -gt "$max" ]; then
    note "$key is $v; values above $max are unusual, double-check it"
  fi
}

check_tuning() {
  local level
  check_int N8N_WORKER_REPLICAS 0 20
  check_int N8N_WEBHOOK_REPLICAS 1 10
  check_int N8N_WORKER_CONCURRENCY 1 50
  check_int EXECUTIONS_DATA_MAX_AGE 1
  check_int BACKUP_RETENTION_DAYS 1
  check_int BACKUP_S3_RETENTION_DAYS 1

  level="$(val N8N_LOG_LEVEL)"
  case "$level" in
    ''|error|warn|info|debug|silent) ;;
    *) fail "N8N_LOG_LEVEL '$level' must be one of: error warn info debug silent" ;;
  esac
  if [ "$level" = "debug" ]; then
    note "N8N_LOG_LEVEL=debug is verbose and may log sensitive data; use info in production"
  fi
}

check_booleans() {
  local key v
  for key in N8N_DIAGNOSTICS_ENABLED BACKUP_ON_START N8N_DISABLE_PRODUCTION_MAIN_PROCESS; do
    v="$(val "$key")"
    case "$v" in
      ''|true|false) ;;
      *) fail "$key '$v' must be true or false" ;;
    esac
  done
}

# --- Optional webhook processor ---------------------------------------------------
check_webhook_profile() {
  local profiles upstream disable_main enabled=0
  profiles="$(val COMPOSE_PROFILES)"
  upstream="$(val WEBHOOK_UPSTREAM)"
  disable_main="$(val N8N_DISABLE_PRODUCTION_MAIN_PROCESS)"
  case ",${profiles// /}," in *,webhook,*) enabled=1 ;; esac

  if [ "$enabled" -eq 1 ]; then
    [ "$upstream" = "n8n-webhook:5678" ] \
      || fail "COMPOSE_PROFILES includes webhook but WEBHOOK_UPSTREAM is '${upstream:-unset}'; set WEBHOOK_UPSTREAM=n8n-webhook:5678"
    [ "$disable_main" = "true" ] \
      || note "webhook profile is enabled but N8N_DISABLE_PRODUCTION_MAIN_PROCESS is not true; the main instance will still serve production webhooks"
    if [ "$upstream" = "n8n-webhook:5678" ] && [ "$disable_main" = "true" ]; then
      ok "webhook processor profile is consistent"
    fi
  else
    case "$upstream" in
      ''|n8n-main:5678) ;;
      n8n-webhook*) fail "WEBHOOK_UPSTREAM points to n8n-webhook but the webhook profile is not enabled (COMPOSE_PROFILES=webhook); Caddy would return 502" ;;
      *) note "WEBHOOK_UPSTREAM is '$upstream'; expected n8n-main:5678 or n8n-webhook:5678" ;;
    esac
    if [ "$disable_main" = "true" ]; then
      fail "N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true without the webhook profile: no process would serve production webhooks"
    fi
  fi
}

# --- Backups ----------------------------------------------------------------------
check_backups() {
  local schedule fields bucket provider
  schedule="$(val BACKUP_SCHEDULE)"
  if [ -n "$schedule" ]; then
    fields="$(printf '%s' "$schedule" | awk '{print NF}')"
    case "$schedule" in
      @hourly|@daily|@weekly|@monthly|@yearly|@annually|@midnight) ok "BACKUP_SCHEDULE is $schedule" ;;
      *)
        if [ "$fields" -ne 5 ]; then
          fail "BACKUP_SCHEDULE '$schedule' must have 5 cron fields (minute hour day month weekday)"
        elif ! [[ "$schedule" =~ ^[0-9*/,[:space:]-]+$ ]]; then
          fail "BACKUP_SCHEDULE '$schedule' contains characters cron does not understand"
        else
          ok "BACKUP_SCHEDULE is '$schedule'"
        fi ;;
    esac
  fi

  bucket="$(val BACKUP_S3_BUCKET)"
  if [ -z "$bucket" ]; then
    note "BACKUP_S3_BUCKET is empty: backups stay on this server only (no off-site copy)"
    return
  fi
  if ! [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    fail "BACKUP_S3_BUCKET '$bucket' is not a valid bucket name (3-63 lower-case letters, digits, '.' or '-'; no s3:// prefix)"
  fi
  [ -n "$(val S3_ACCESS_KEY_ID)" ] || fail "BACKUP_S3_BUCKET is set but S3_ACCESS_KEY_ID is empty"
  [ -n "$(val S3_SECRET_ACCESS_KEY)" ] || fail "BACKUP_S3_BUCKET is set but S3_SECRET_ACCESS_KEY is empty"
  provider="$(val S3_PROVIDER)"
  case "${provider:-AWS}" in
    AWS) ;;
    *) [ -n "$(val S3_ENDPOINT)" ] || fail "S3_PROVIDER=$provider needs S3_ENDPOINT" ;;
  esac
  case "$(val S3_ENDPOINT)" in
    ''|https://*) ;;
    http://*) note "S3_ENDPOINT uses plain http; backups would travel unencrypted" ;;
    *) fail "S3_ENDPOINT must start with https:// (got '$(val S3_ENDPOINT)')" ;;
  esac
}

# --- Run --------------------------------------------------------------------------
[ "$QUIET" -eq 1 ] || log "Checking $ENV_FILE"
check_file
check_required
check_domain
check_email
check_secret POSTGRES_PASSWORD 16
check_secret REDIS_PASSWORD 16
check_encryption_key
check_secret_reuse
check_identifiers
check_version
check_tuning
check_booleans
check_webhook_profile
check_backups

if [ "$QUIET" -eq 0 ] && [ -n "$(val N8N_ENCRYPTION_KEY)" ]; then
  printf '  note  keep a copy of N8N_ENCRYPTION_KEY outside this server (password manager)\n'
fi

printf 'preflight: %d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARNINGS" -gt 0 ]; then
  printf 'preflight: --strict is set, failing on warnings\n'
  exit 1
fi
exit 0
