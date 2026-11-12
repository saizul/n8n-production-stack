#!/usr/bin/env bats
# Tests for the helpers in scripts/common.sh

load test_helper

setup() {
  setup_stack
  printf 'A=1\nB=first\nB=second\nC=x=y\n' > .env
}

helper() {
  run bash -c '. "$1/scripts/common.sh"; shift; "$@"' _ "$STACK" "$@"
}

@test "env_get returns the last occurrence" {
  helper env_get B
  [ "$status" -eq 0 ]
  [ "$output" = "second" ]
}

@test "env_get keeps '=' inside values" {
  helper env_get C
  [ "$output" = "x=y" ]
}

@test "env_get prints nothing for a missing key" {
  helper env_get MISSING
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "env_get does not match key prefixes" {
  printf 'AB=2\n' >> .env
  helper env_get A
  [ "$output" = "1" ]
}

@test "env_set replaces an existing key in place" {
  helper env_set A 42
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p .env)" = "A=42" ]
  [ "$(grep -c '^A=' .env)" -eq 1 ]
}

@test "env_set appends a new key" {
  helper env_set D new
  [ "$(tail -n 1 .env)" = "D=new" ]
}

@test "env_set preserves the file mode" {
  chmod 600 .env
  helper env_set A 5
  mode="$(stat -c '%a' .env 2> /dev/null || stat -f '%Lp' .env)"
  [ "$mode" = "600" ]
}

@test "require_env_file fails without .env" {
  rm .env
  helper require_env_file
  [ "$status" -eq 1 ]
  [[ "$output" == *"Run scripts/init.sh first"* ]]
}

@test "require_cmd fails for a missing command" {
  helper require_cmd definitely-not-installed-xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"is required but not installed"* ]]
}
