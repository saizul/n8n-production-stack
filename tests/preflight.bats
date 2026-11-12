#!/usr/bin/env bats
# Tests for scripts/preflight.sh

load test_helper

setup() {
  setup_stack
  make_env
}

@test "a freshly generated .env with a real domain passes" {
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: 0 error(s)"* ]]
  [[ "$output" == *"N8N_HOST 'n8n.acme-corp.io' looks like a valid public hostname"* ]]
}

@test "output never contains secret values" {
  local pg redis key
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  redis="$(grep '^REDIS_PASSWORD=' .env | cut -d= -f2-)"
  key="$(grep '^N8N_ENCRYPTION_KEY=' .env | cut -d= -f2-)"
  preflight
  [[ "$output" != *"$pg"* ]]
  [[ "$output" != *"$redis"* ]]
  [[ "$output" != *"$key"* ]]
}

@test "missing .env is an error" {
  rm .env
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "unknown argument is a usage error" {
  preflight --bogus
  [ "$status" -eq 2 ]
}

@test "--env-file checks another file, relative to the caller" {
  cp .env custom.env
  set_env N8N_HOST "bad host"
  cd "$BATS_TEST_TMPDIR"
  run "$STACK/scripts/preflight.sh" --env-file stack/custom.env
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom.env"* ]]
}

@test "the untouched .env.example template fails on placeholders" {
  preflight --env-file .env.example
  [ "$status" -eq 1 ]
  [[ "$output" == *"POSTGRES_PASSWORD is still a placeholder"* ]]
  [[ "$output" == *"REDIS_PASSWORD is still a placeholder"* ]]
  [[ "$output" == *"N8N_ENCRYPTION_KEY is still a placeholder"* ]]
  [[ "$output" != *"reused"* ]]
}

@test "missing required variables are listed" {
  del_env REDIS_PASSWORD
  set_env ACME_EMAIL ""
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"required variables missing or empty: ACME_EMAIL REDIS_PASSWORD"* ]]
}

@test "well-known weak passwords are rejected" {
  set_env POSTGRES_PASSWORD password
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"POSTGRES_PASSWORD uses a well-known default/weak value"* ]]
}

@test "short passwords are rejected" {
  set_env REDIS_PASSWORD "s3cr3tPass"
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"REDIS_PASSWORD is 10 characters; use at least 16"* ]]
}

@test "repeated-character secrets are rejected" {
  set_env POSTGRES_PASSWORD aaaaaaaaaaaaaaaaaaaaaaaa
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"single repeated character"* ]]
}

@test "encryption key shorter than 32 characters is rejected" {
  set_env N8N_ENCRYPTION_KEY 0123456789abcdef0123
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"N8N_ENCRYPTION_KEY is 20 characters; use at least 32"* ]]
}

@test "encryption key reused as a password is rejected" {
  local key
  key="$(grep '^N8N_ENCRYPTION_KEY=' .env | cut -d= -f2-)"
  set_env POSTGRES_PASSWORD "$key"
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"N8N_ENCRYPTION_KEY is reused"* ]]
}

@test "identical Postgres and Redis passwords only warn" {
  local pg
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  set_env REDIS_PASSWORD "$pg"
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTGRES_PASSWORD and REDIS_PASSWORD are identical"* ]]
}

@test "unescaped dollar interpolation in a secret is rejected" {
  # shellcheck disable=SC2016 # the literal \$HOME is the point of the test
  set_env POSTGRES_PASSWORD 'abcdefgh$HOMEabcdefgh'
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"Docker Compose will try to interpolate it"* ]]
}

@test "quoted values are unwrapped before checking" {
  local pg
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  set_env POSTGRES_PASSWORD "\"$pg\""
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTGRES_PASSWORD looks strong (48 characters)"* ]]
}

@test "N8N_HOST with a scheme is rejected" {
  set_env N8N_HOST https://n8n.acme-corp.io
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"without a scheme"* ]]
}

@test "N8N_HOST with a path or port is rejected" {
  set_env N8N_HOST n8n.acme-corp.io/editor
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contain a path"* ]]

  set_env N8N_HOST n8n.acme-corp.io:8443
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contain a port"* ]]
}

@test "N8N_HOST that is not a FQDN is rejected" {
  for host in localhost n8n_server.acme.io -n8n.acme.io n8n..acme.io; do
    set_env N8N_HOST "$host"
    preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a valid fully qualified domain name"* ]]
  done
}

@test "placeholder domains warn, and fail with --strict" {
  set_env N8N_HOST n8n.example.com
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"reserved/placeholder domain"* ]]

  preflight --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"--strict is set"* ]]
}

@test "upper-case and IP hosts warn" {
  set_env N8N_HOST N8N.Acme-Corp.io
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"upper-case"* ]]

  set_env N8N_HOST 203.0.113.10
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"is an IP address"* ]]
}

@test "invalid ACME_EMAIL is rejected" {
  set_env ACME_EMAIL "not-an-email"
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"ACME_EMAIL 'not-an-email' is not a valid e-mail address"* ]]
}

@test "unpinned or partial N8N_VERSION is rejected" {
  for v in latest next 2.46 v2.46.6; do
    set_env N8N_VERSION "$v"
    preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be an exact version"* ]]
  done
}

@test "invalid PostgreSQL identifiers are rejected" {
  set_env POSTGRES_USER "n8n-user"
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"POSTGRES_USER 'n8n-user' must be a lower-case PostgreSQL identifier"* ]]
}

@test "non-numeric tuning values are rejected" {
  set_env N8N_WORKER_CONCURRENCY ten
  set_env BACKUP_RETENTION_DAYS 0
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"N8N_WORKER_CONCURRENCY 'ten' must be a whole number"* ]]
  [[ "$output" == *"BACKUP_RETENTION_DAYS is 0; minimum is 1"* ]]
}

@test "invalid log level and booleans are rejected" {
  set_env N8N_LOG_LEVEL verbose
  set_env BACKUP_ON_START yes
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"N8N_LOG_LEVEL 'verbose' must be one of"* ]]
  [[ "$output" == *"BACKUP_ON_START 'yes' must be true or false"* ]]
}

@test "malformed backup schedule is rejected" {
  set_env BACKUP_SCHEDULE "0 3 * *"
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"must have 5 cron fields"* ]]

  set_env BACKUP_SCHEDULE "@daily"
  preflight
  [ "$status" -eq 0 ]
}

@test "consistent webhook profile passes" {
  set_env COMPOSE_PROFILES webhook
  set_env WEBHOOK_UPSTREAM n8n-webhook:5678
  set_env N8N_DISABLE_PRODUCTION_MAIN_PROCESS true
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"webhook processor profile is consistent"* ]]
}

@test "webhook profile without the matching upstream is rejected" {
  set_env COMPOSE_PROFILES webhook
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"set WEBHOOK_UPSTREAM=n8n-webhook:5678"* ]]
}

@test "webhook upstream without the profile is rejected" {
  set_env WEBHOOK_UPSTREAM n8n-webhook:5678
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"Caddy would return 502"* ]]
}

@test "disabling the main webhook process without the profile is rejected" {
  set_env N8N_DISABLE_PRODUCTION_MAIN_PROCESS true
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"no process would serve production webhooks"* ]]
}

@test "S3 bucket without credentials is rejected" {
  set_env BACKUP_S3_BUCKET my-n8n-backups
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"S3_ACCESS_KEY_ID is empty"* ]]
  [[ "$output" == *"S3_SECRET_ACCESS_KEY is empty"* ]]
}

@test "non-AWS S3 provider needs an https endpoint" {
  set_env BACKUP_S3_BUCKET my-n8n-backups
  set_env S3_ACCESS_KEY_ID EXAMPLEKEYID
  set_env S3_SECRET_ACCESS_KEY example-secret-placeholder
  set_env S3_PROVIDER Cloudflare
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"S3_PROVIDER=Cloudflare needs S3_ENDPOINT"* ]]

  set_env S3_ENDPOINT https://accountid.r2.cloudflarestorage.com
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" != *"BACKUP_S3_BUCKET is empty"* ]]
}

@test "S3 bucket with a scheme prefix is rejected" {
  set_env BACKUP_S3_BUCKET s3://my-n8n-backups
  set_env S3_ACCESS_KEY_ID EXAMPLEKEYID
  set_env S3_SECRET_ACCESS_KEY example-secret-placeholder
  preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a valid bucket name"* ]]
}

@test "loose file permissions and duplicate keys warn" {
  chmod 644 .env
  printf 'N8N_LOG_LEVEL=info\n' >> .env
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"is mode 644"* ]]
  [[ "$output" == *"duplicate keys (the last one wins): N8N_LOG_LEVEL"* ]]
}

@test "--quiet prints only problems and the summary" {
  set_env N8N_HOST n8n.example.com
  preflight --quiet
  [ "$status" -eq 0 ]
  [[ "$output" != *" ok "* ]]
  [[ "$output" == *"reserved/placeholder domain"* ]]
  [[ "$output" == *"preflight: 0 error(s), 2 warning(s)"* ]]
}
