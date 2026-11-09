# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `scripts/restore-test.sh` and `make restore-test`: restore a dump into a throwaway PostgreSQL container and verify the core n8n tables, without touching the live stack.

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
