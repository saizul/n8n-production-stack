#!/usr/bin/env bats
# Argument handling and safety checks of the Docker-driven scripts.
# Docker is stubbed (see test_helper.bash), so these never touch a real stack.

load test_helper

setup() {
  setup_stack
}

@test "update.sh rejects a malformed version before calling docker" {
  make_env
  run ./scripts/update.sh latest
  [ "$status" -eq 1 ]
  [[ "$output" == *"version must look like 2.46.7"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

@test "update.sh requires .env" {
  run ./scripts/update.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *".env not found"* ]]
}

@test "update.sh stops before pulling when preflight fails" {
  make_env
  set_env POSTGRES_PASSWORD password
  run ./scripts/update.sh 2.46.7
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed the preflight check"* ]]
  [ ! -s "$DOCKER_LOG" ]
  grep -qx 'N8N_VERSION=2.46.6' .env
}

@test "restore.sh without arguments prints usage" {
  run ./scripts/restore.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: scripts/restore.sh"* ]]
}

@test "restore.sh aborts unless 'restore' is typed" {
  make_env
  run bash -c 'printf "no\n" | ./scripts/restore.sh latest'
  [ "$status" -eq 1 ]
  [[ "$output" == *"aborted"* ]]
  run grep -c 'pg_restore --clean' "$DOCKER_LOG"
  [ "$output" = "0" ]
}

@test "healthcheck.sh rejects a non-numeric --wait" {
  run ./scripts/healthcheck.sh --wait soon
  [ "$status" -eq 1 ]
  [[ "$output" == *"--wait needs a number"* ]]
}

@test "healthcheck.sh rejects unknown arguments" {
  run ./scripts/healthcheck.sh --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "backup.sh requires .env" {
  run ./scripts/backup.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *".env not found"* ]]
}
