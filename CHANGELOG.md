# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Backup monitoring. `dump.sh` records each run's outcome (`.last_success` / `.last_failure` in the backup volume) and, when `BACKUP_HEALTHCHECK_URL` is set, pings a dead man's switch (healthchecks.io style `<url>/fail` on failure, or `BACKUP_HEALTHCHECK_FAIL_URL`; Uptime Kuma push URLs work too). Pings never fail the backup and the URL is never logged.
- `backup/status.sh` in the backup image and `scripts/backup-status.sh` / `make backup-status` on the host: last success and failure, age limit, local dump count and size; `--json`, `--quiet`, `--max-age`; exit `1` when the last run failed or is older than `BACKUP_MAX_AGE_HOURS` (default 26), `3` when the backup container is not running.
- Preflight checks for `BACKUP_MAX_AGE_HOURS`, the monitor URLs (scheme, spaces, placeholders, never printed) and weekly/monthly schedules whose interval exceeds the age limit; a warning when no monitor URL is configured.
- bats tests for `dump.sh` (success, failed dump, failed verification, failed upload, retention, monitor pings), `status.sh` and `backup-status.sh`, with `pg_dump`, `pg_restore`, `rclone`, `curl` and `docker` stubbed.
- `scripts/preflight.sh` and `make preflight`: validate `.env` before starting the stack (required variables, placeholder and weak secrets, minimum secret and encryption key length, Compose `$` interpolation, `N8N_HOST` and `ACME_EMAIL` format, pinned `N8N_VERSION`, numeric and boolean settings, webhook profile consistency, backup schedule and S3 settings, file mode and duplicate keys). Supports `--strict`, `--quiet` and `--env-file`; never prints secret values.
- bats test suite in `tests/` for `preflight.sh`, `init.sh`, the `common.sh` helpers and the argument and safety checks of `update.sh`, `restore.sh`, `healthcheck.sh` and `backup.sh` (Docker is stubbed), plus `make test` and a CI job running it.
- `scripts/restore-test.sh` and `make restore-test`: restore a dump into a throwaway PostgreSQL container and verify the core n8n tables, without touching the live stack.

### Changed
- The `backup` container healthcheck also fails when the last backup run failed or the last success is older than `BACKUP_MAX_AGE_HOURS`, so `make health` and `update.sh` surface broken backups. A fresh install with no backup yet stays healthy. Weekly or monthly schedules need a larger `BACKUP_MAX_AGE_HOURS` (or `0`).
- The backup image now includes `curl` and `status.sh`; `dump.sh` honours `BACKUP_DIR` and `BACKUP_ENV_FILE` overrides (used by the tests).
- `make up` and `scripts/update.sh` run the preflight check first and stop on errors, so a broken `.env` fails before images are pulled or containers are recreated.
- CI runs the preflight check on the generated `.env`, asserts that the untouched template is rejected, and shellchecks the test files.

## [1.0.0] - 2026-11-08

### Added
- Docker Compose stack: n8n main, scalable n8n workers, optional webhook processor (profile `webhook`), PostgreSQL 16, Redis 7, Caddy 2 with automatic HTTPS and security headers.
- Backup service (Alpine, cron, `pg_dump` custom format, verification, local retention, optional S3 upload via rclone).
- Healthchecks, restart policies, resource limits, log rotation, named volumes and an internal-only backend network.
- Scripts: `init.sh`, `backup.sh`, `restore.sh`, `update.sh`, `healthcheck.sh`; Makefile with `up`, `down`, `logs`, `ps`, `backup`, `restore`, `update`, `scale`.
- Documentation: README with architecture diagram, TROUBLESHOOTING, CONTRIBUTING.
- GitHub Actions CI: Compose validation, Caddyfile validation, shellcheck, yamllint.

### Pinned versions
- n8n 2.46.6, PostgreSQL 16.15-alpine, Redis 7.4.12-alpine, Caddy 2.11.9-alpine, Alpine 3.21 (backup image).
