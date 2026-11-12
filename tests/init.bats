#!/usr/bin/env bats
# Tests for scripts/init.sh

load test_helper

setup() {
  setup_stack
}

@test "creates .env with mode 600 and the given domain and e-mail" {
  run ./scripts/init.sh --domain n8n.acme-corp.io --email ops@acme-corp.io
  [ "$status" -eq 0 ]
  [ -f .env ]
  mode="$(stat -c '%a' .env 2> /dev/null || stat -f '%Lp' .env)"
  [ "$mode" = "600" ]
  grep -qx 'N8N_HOST=n8n.acme-corp.io' .env
  grep -qx 'ACME_EMAIL=ops@acme-corp.io' .env
}

@test "replaces every CHANGE_ME with distinct hex secrets of the expected length" {
  ./scripts/init.sh --domain n8n.acme-corp.io --email ops@acme-corp.io
  run grep -cE '^[A-Z0-9_]+=CHANGE_ME' .env
  [ "$output" = "0" ]
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  redis="$(grep '^REDIS_PASSWORD=' .env | cut -d= -f2-)"
  key="$(grep '^N8N_ENCRYPTION_KEY=' .env | cut -d= -f2-)"
  [[ "$pg" =~ ^[0-9a-f]{48}$ ]]
  [[ "$redis" =~ ^[0-9a-f]{48}$ ]]
  [[ "$key" =~ ^[0-9a-f]{64}$ ]]
  [ "$pg" != "$redis" ]
}

@test "keeps every key from .env.example" {
  ./scripts/init.sh --domain n8n.acme-corp.io --email ops@acme-corp.io
  diff <(grep -oE '^[A-Z0-9_]+=' .env.example) <(grep -oE '^[A-Z0-9_]+=' .env)
}

@test "refuses to overwrite an existing .env" {
  ./scripts/init.sh --domain n8n.acme-corp.io --email ops@acme-corp.io
  before="$(cat .env)"
  run ./scripts/init.sh --domain other.acme-corp.io --email a@acme-corp.io
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite"* ]]
  [ "$(cat .env)" = "$before" ]
}

@test "warns when domain and e-mail are not given" {
  run ./scripts/init.sh < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"set N8N_HOST and ACME_EMAIL"* ]]
}

@test "rejects unknown arguments" {
  run ./scripts/init.sh --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
  [ ! -e .env ]
}

@test "generated .env passes preflight" {
  ./scripts/init.sh --domain n8n.acme-corp.io --email ops@acme-corp.io
  run ./scripts/preflight.sh
  [ "$status" -eq 0 ]
}
