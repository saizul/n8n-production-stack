#!/usr/bin/env bats
# Tests for the backup container scripts (backup/dump.sh, backup/status.sh) and
# the host wrapper scripts/backup-status.sh. pg_dump, pg_restore, rclone, curl
# and docker are stubbed, so no database or network is needed.

# Each @test runs in its own subshell, so per-test exports are intentional.
# shellcheck disable=SC2030,SC2031

load test_helper

# make_stub NAME: a stub that logs "NAME args" to $CALLS and exits with
# $FAKE_<NAME>_RC (default 0).
make_stub() {
  local name="$1" var
  var="FAKE_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_RC"
  cat > "$BIN/$name" << STUB
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$CALLS"
exit "\${$var:-0}"
STUB
  chmod +x "$BIN/$name"
}

setup() {
  setup_stack
  BIN="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS"
  export BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
  export BACKUP_ENV_FILE="$BATS_TEST_TMPDIR/no-such-backup.env"
  export PGDATABASE=n8n PGHOST=postgres
  unset BACKUP_HEALTHCHECK_URL BACKUP_HEALTHCHECK_FAIL_URL BACKUP_S3_BUCKET BACKUP_MAX_AGE_HOURS
  mkdir -p "$BACKUP_DIR"

  make_stub pg_restore
  make_stub rclone
  make_stub curl
  # pg_dump writes a small fake dump to its --file= target, or fails on demand.
  cat > "$BIN/pg_dump" << 'STUB'
#!/usr/bin/env bash
if [ -n "${FAKE_PG_DUMP_FAIL:-}" ]; then
  echo "pg_dump: connection refused" >&2
  exit 1
fi
for a in "$@"; do
  case "$a" in --file=*) printf 'PGDMP fake' > "${a#--file=}" ;; esac
done
STUB
  chmod +x "$BIN/pg_dump"
}

dump() {
  run "$REPO_ROOT/backup/dump.sh" "$@"
}

backup_status() {
  run "$REPO_ROOT/backup/status.sh" "$@"
}

# stamp MARKER SECONDS_AGO
stamp() {
  echo $(($(date +%s) - $2)) > "$BACKUP_DIR/$1"
}

no_tmp_files() {
  [ -z "$(find "$BACKUP_DIR" -name '*.tmp')" ]
}

# --- dump.sh --------------------------------------------------------------------

@test "dump.sh writes a verified dump and records success" {
  dump nightly
  [ "$status" -eq 0 ]
  local path="${lines[${#lines[@]}-1]}"
  [[ "$path" == "$BACKUP_DIR"/n8n-n8n-*-nightly.dump ]]
  [ -f "$path" ]
  [ -s "$BACKUP_DIR/.last_success" ]
  [ ! -e "$BACKUP_DIR/.last_failure" ]
  grep -q '^pg_restore --list' "$CALLS"
  no_tmp_files
}

@test "dump.sh pings the monitor after a successful backup" {
  export BACKUP_HEALTHCHECK_URL="https://hc.example.com/ping/abc"
  dump
  [ "$status" -eq 0 ]
  grep -q '^curl .*https://hc.example.com/ping/abc$' "$CALLS"
  run grep -c '/fail' "$CALLS"
  [ "$output" = "0" ]
}

@test "dump.sh never prints the monitor URL" {
  export BACKUP_HEALTHCHECK_URL="https://hc.example.com/ping/token-value-123"
  FAKE_CURL_RC=22 dump
  [ "$status" -eq 0 ]
  [[ "$output" != *"token-value-123"* ]]
}

@test "a failed dump records the failure and pings <url>/fail" {
  export BACKUP_HEALTHCHECK_URL="https://hc.example.com/ping/abc/"
  FAKE_PG_DUMP_FAIL=1 dump
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED during: dump"* ]]
  [ -s "$BACKUP_DIR/.last_failure" ]
  [ ! -e "$BACKUP_DIR/.last_success" ]
  grep -q '^curl .*https://hc.example.com/ping/abc/fail$' "$CALLS"
  no_tmp_files
}

@test "an unreadable dump fails verification and is not kept" {
  FAKE_PG_RESTORE_RC=1 dump
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED during: verify"* ]]
  [ -z "$(find "$BACKUP_DIR" -name 'n8n-*.dump')" ]
  [ -s "$BACKUP_DIR/.last_failure" ]
  no_tmp_files
}

@test "BACKUP_HEALTHCHECK_FAIL_URL overrides the failure URL" {
  export BACKUP_HEALTHCHECK_URL="https://kuma.example.com/api/push/abc?status=up"
  export BACKUP_HEALTHCHECK_FAIL_URL="https://kuma.example.com/api/push/abc?status=down"
  FAKE_PG_DUMP_FAIL=1 dump
  [ "$status" -ne 0 ]
  grep -q 'status=down$' "$CALLS"
  run grep -c 'status=up' "$CALLS"
  [ "$output" = "0" ]
}

@test "URLs with a query string get no automatic /fail suffix" {
  export BACKUP_HEALTHCHECK_URL="https://kuma.example.com/api/push/abc?status=up"
  FAKE_PG_DUMP_FAIL=1 dump
  [ "$status" -ne 0 ]
  run grep -c '^curl' "$CALLS"
  [ "$output" = "0" ]
}

@test "a failed S3 upload is reported as a failed backup" {
  export BACKUP_S3_BUCKET=my-n8n-backups BACKUP_HEALTHCHECK_URL="https://hc.example.com/ping/abc"
  FAKE_RCLONE_RC=1 dump
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED during: upload"* ]]
  grep -q '^curl .*/ping/abc/fail$' "$CALLS"
  [ ! -e "$BACKUP_DIR/.last_success" ]
}

@test "an unreachable monitor does not fail the backup" {
  export BACKUP_HEALTHCHECK_URL="https://hc.example.com/ping/abc"
  FAKE_CURL_RC=7 dump
  [ "$status" -eq 0 ]
  [[ "$output" == *"monitor ping failed (non-fatal)"* ]]
  [ -s "$BACKUP_DIR/.last_success" ]
}

@test "dump.sh prunes local dumps older than the retention period" {
  touch -t 202001010000 "$BACKUP_DIR/n8n-n8n-20200101-030000.dump"
  BACKUP_RETENTION_DAYS=7 dump
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/n8n-n8n-20200101-030000.dump" ]
  [[ "$output" == *"pruned"* ]]
}

# --- status.sh ------------------------------------------------------------------

@test "status.sh is ok (exit 0) before the first backup" {
  backup_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup status: none - no backup has completed yet"* ]]
  [[ "$output" == *"last success:  never"* ]]
}

@test "status.sh reports a fresh backup as ok" {
  stamp .last_success 3600
  head -c 2048 /dev/zero > "$BACKUP_DIR/n8n-n8n-20260101-030000.dump"
  printf 'x' > "$BACKUP_DIR/n8n-n8n-20260102-030000-manual.dump"
  backup_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup status: ok"* ]]
  [[ "$output" == *"(1h 0m ago)"* ]]
  [[ "$output" == *"local dumps:   2 (2 KiB)"* ]]
  [[ "$output" == *"newest dump:   n8n-n8n-20260102-030000-manual.dump"* ]]
}

@test "status.sh flags a backup older than BACKUP_MAX_AGE_HOURS" {
  stamp .last_success $((30 * 3600))
  backup_status
  [ "$status" -eq 1 ]
  [[ "$output" == *"backup status: stale"* ]]
  [[ "$output" == *"(limit 26h)"* ]]
}

@test "--max-age overrides the limit and 0 disables it" {
  stamp .last_success $((30 * 3600))
  backup_status --max-age 48
  [ "$status" -eq 0 ]
  BACKUP_MAX_AGE_HOURS=0 backup_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"max age:       disabled"* ]]
}

@test "status.sh fails when the latest run failed" {
  stamp .last_success 7200
  stamp .last_failure 60
  backup_status
  [ "$status" -eq 1 ]
  [[ "$output" == *"backup status: failed"* ]]
}

@test "a success after a failure clears the failed state" {
  stamp .last_failure 7200
  stamp .last_success 60
  backup_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup status: ok"* ]]
  [[ "$output" == *"last failure:"* ]]
}

@test "status.sh --json emits one parsable object" {
  stamp .last_success 120
  printf 'x' > "$BACKUP_DIR/n8n-n8n-20260101-030000.dump"
  backup_status --json
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == '{"status":"ok",'* ]]
  [[ "$output" == *'"last_failure":null'* ]]
  [[ "$output" == *'"dumps":1,"bytes":1,"newest":"n8n-n8n-20260101-030000.dump"}' ]]
  if command -v python3 > /dev/null; then
    printf '%s' "$output" | python3 -c 'import json, sys; json.load(sys.stdin)'
  fi
}

@test "status.sh --quiet prints nothing" {
  stamp .last_failure 60
  backup_status --quiet
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "status.sh rejects bad arguments with exit 2" {
  backup_status --max-age soon
  [ "$status" -eq 2 ]
  backup_status --max-age
  [ "$status" -eq 2 ]
  backup_status --bogus
  [ "$status" -eq 2 ]
}

@test "end to end: dump.sh then status.sh reports ok" {
  dump
  [ "$status" -eq 0 ]
  backup_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup status: ok"* ]]
  [[ "$output" == *"local dumps:   1"* ]]
}

# --- scripts/backup-status.sh ---------------------------------------------------

# Docker stub: the backup service is running and status.sh exits with $FAKE_STATUS_RC.
running_backup_stub() {
  cat > "$BIN/docker" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  "compose ps --status running -q backup") echo 0123abcd ;;
  "compose exec -T backup /usr/local/bin/status.sh"*) echo "backup status: fake"; exit "\${FAKE_STATUS_RC:-0}" ;;
esac
exit 0
STUB
  chmod +x "$BIN/docker"
}

@test "backup-status.sh requires .env" {
  run ./scripts/backup-status.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *".env not found"* ]]
}

@test "backup-status.sh validates --max-age before calling docker" {
  make_env
  run ./scripts/backup-status.sh --max-age 1d
  [ "$status" -eq 2 ]
  [ ! -s "$DOCKER_LOG" ]
}

@test "backup-status.sh exits 3 when the backup container is not running" {
  make_env
  run ./scripts/backup-status.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"backup container is not running"* ]]
}

@test "backup-status.sh forwards options and the stale exit code" {
  make_env
  running_backup_stub
  FAKE_STATUS_RC=1 run ./scripts/backup-status.sh --max-age 48 --json
  [ "$status" -eq 1 ]
  grep -qx 'compose exec -T backup /usr/local/bin/status.sh --max-age 48 --json' "$DOCKER_LOG"
}

@test "backup-status.sh maps unexpected docker errors to exit 3" {
  make_env
  running_backup_stub
  FAKE_STATUS_RC=126 run ./scripts/backup-status.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not query the backup container"* ]]
}
