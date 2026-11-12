# Troubleshooting

Start with `make ps` and `make logs SERVICE=<name>`, then `./scripts/healthcheck.sh`.

## Compose refuses to start: "required variable is missing"

`.env` is missing or incomplete. Run `./scripts/init.sh`, then set `N8N_HOST` and `ACME_EMAIL`.

## `make up` stops with "preflight: N error(s)"

`scripts/preflight.sh` found a problem in `.env`; each `FAIL` line names the variable and the fix. Correct it and run `make preflight` again. Warnings (`WARN`) do not block the start. See the README section "Preflight check" for the full list.

## No HTTPS certificate / browser shows a certificate error

- `make logs SERVICE=caddy` and look for ACME errors.
- DNS must resolve to this server (`dig +short $N8N_HOST`), and ports 80 and 443 must be reachable. Check the cloud provider firewall as well as the host firewall.
- Let's Encrypt rate-limits repeated failures. Fix the cause, then `docker compose restart caddy` and wait.
- Certificates are stored in the `caddy_data` volume. Do not delete that volume casually.

## Editor loads but shows "Connection lost" or workflows do not update live

Push uses WebSocket/SSE. Make sure nothing else sits between Caddy and the browser that blocks upgrades (some CDNs or corporate proxies). If you use Cloudflare, enable WebSockets and use "Full (strict)" TLS.

## Webhooks return 404

- Production URLs only work for **active** workflows; test URLs (`/webhook-test/...`) only while "Listen for test event" is running.
- `N8N_HOST` must match the public hostname. The generated webhook URL shown in the editor should be `https://<your host>/webhook/...`.
- With the webhook profile enabled, confirm `n8n-webhook` is healthy and `WEBHOOK_UPSTREAM=n8n-webhook:5678` is set.

## Webhook URLs show `localhost` or `http://`

`N8N_WEBHOOK_URL` is derived from `N8N_HOST`. Recreate the containers after changing `.env`: `make up`.

## "Mismatching encryption keys" / credentials cannot be decrypted

`N8N_ENCRYPTION_KEY` differs from the one used when the credentials were saved. After a migration or restore, put the original key in `.env` and recreate: `make up`. Main and all workers must share one key.

## Workers do not pick up executions

- `docker compose ps` must show workers `healthy`. Check `make logs SERVICE=n8n-worker`.
- Redis password mismatch shows as `NOAUTH` or `WRONGPASS`. Redis keeps `REDIS_PASSWORD` from the compose command at start; recreate Redis and n8n after changing it.
- Main and workers must run the **same n8n version**. After an upgrade, recreate all of them (`make up`).

## Executions stuck in "running" after a restart

If a worker is killed mid-execution (OOM, power loss) the execution may remain "running". Raise `N8N_WORKER_MEMORY`, reduce `N8N_WORKER_CONCURRENCY`, and use the stop button on the execution. A stop grace period of 60 s lets workers finish on `docker compose stop`.

## Out-of-memory (containers restarted, exit code 137)

`docker inspect <container> --format '{{.State.OOMKilled}}'`. Raise the limit in `.env` (`N8N_WORKER_MEMORY=2g`) or lower concurrency. Large binary data in workflows is the usual cause.

## "binary data filesystem mode is not supported in queue mode"

This stack sets `N8N_DEFAULT_BINARY_DATA_MODE=database` so main and workers share binary data. Do not set it back to `filesystem`.

## Postgres: "password authentication failed"

The password in `.env` only applies when the data volume is first initialised. If you regenerated `.env` after the first start, either restore the old values or change the role password:

```bash
docker compose exec postgres psql -U n8n -d n8n -c "ALTER USER n8n WITH PASSWORD 'new-password';"
```

and update `POSTGRES_PASSWORD` in `.env`, then `make up`. Starting from scratch (destroys data): `docker compose down -v`.

## Backups

- `make logs SERVICE=backup` shows each run. `docker compose exec backup ls -lh /backups` lists files.
- The schedule uses the container timezone (`TZ` in `.env`).
- `pg_dump: error: aborting because of server version mismatch`: the client in `backup/Dockerfile` must match the Postgres major version. Rebuild with `docker compose build --no-cache backup`.
- S3 upload errors: check `S3_PROVIDER`, `S3_ENDPOINT` (needed for non-AWS), region and key permissions. Test manually: `docker compose exec backup /usr/local/bin/dump.sh test`.

## Restore fails with "already exists" or lock errors

`restore.sh` stops n8n first and uses `--clean --if-exists` in one transaction. If another client still holds connections, stop it and retry. A failed restore rolls back, leaving the previous data intact; a `pre-restore` dump was also saved to the backup volume.

## Disk is filling up

`docker system df`, `du -sh /var/lib/docker/volumes/*`. Lower `EXECUTIONS_DATA_MAX_AGE`, reduce `BACKUP_RETENTION_DAYS`, and prune old images with `docker image prune`.

## Reset everything (destroys all data)

```bash
docker compose down -v
rm .env && ./scripts/init.sh
```
