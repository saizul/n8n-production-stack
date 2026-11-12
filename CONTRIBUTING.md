# Contributing

Thanks for helping improve this stack. Bug reports, documentation fixes and focused improvements are welcome.

## Ground rules

- Keep the stack small and boring: secure defaults, pinned versions, no optional magic.
- Never commit secrets. `.env` is git-ignored; only `.env.example` is tracked.
- One logical change per pull request, with a CHANGELOG entry under `Unreleased`.

## Development setup

```bash
./scripts/init.sh --domain n8n.test.example --email dev@example.com
docker compose config --quiet
docker compose --profile webhook config --quiet
make preflight
make lint
make test        # needs bats-core: apt install bats / brew install bats-core
pip install yamllint && yamllint -c .yamllint compose.yaml .github/workflows
```

CI runs the same checks. For runtime changes, bring the stack up on a test server and run `./scripts/healthcheck.sh --wait 180`, a backup and a restore.

## Shell scripts

- Start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Must pass `bash -n` and `shellcheck -x` without warnings.
- Quote variables, prefer `die`/`log`/`warn` helpers from `scripts/common.sh`.
- Add or update a test in `tests/` for behaviour changes. Tests must not need Docker: use the stub and sandbox from `tests/test_helper.bash`.
- New `.env` settings that can be misconfigured should get a check in `scripts/preflight.sh`.

## Bumping versions

1. Confirm the tag exists on the registry.
2. Update the tag in `compose.yaml` (and `.env.example` / README tables for n8n).
3. Read the release notes for breaking changes.
4. Add a CHANGELOG entry.

## Commit style

Short imperative subject line (`Add webhook profile healthcheck`), details in the body when needed.

## License

By contributing you agree that your contributions are licensed under the MIT License.
