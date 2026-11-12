# Shared setup for the bats suite. Each test runs against a private copy of the
# repository in $BATS_TEST_TMPDIR, so the real .env is never read or written.
# Docker is replaced by a stub that records its arguments in $DOCKER_LOG.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup_stack() {
  STACK="$BATS_TEST_TMPDIR/stack"
  mkdir -p "$STACK" "$BATS_TEST_TMPDIR/bin"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/.env.example" "$REPO_ROOT/compose.yaml" "$STACK/"

  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$DOCKER_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DOCKER_LOG"
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export STACK DOCKER_LOG PATH
  cd "$STACK" || return 1
}

# Create a valid .env through init.sh, using a real-looking public domain.
make_env() {
  "$STACK/scripts/init.sh" --domain n8n.acme-corp.io --email ops@acme-corp.io > /dev/null 2>&1
}

# set_env KEY VALUE: replace or append KEY in the sandbox .env.
set_env() {
  bash -c '. "$1/scripts/common.sh"; env_set "$2" "$3"' _ "$STACK" "$1" "$2"
}

# del_env KEY: remove KEY from the sandbox .env.
del_env() {
  grep -vE "^$1=" "$STACK/.env" > "$STACK/.env.tmp" || true
  cat "$STACK/.env.tmp" > "$STACK/.env"
  rm -f "$STACK/.env.tmp"
}

preflight() {
  run "$STACK/scripts/preflight.sh" "$@"
}
