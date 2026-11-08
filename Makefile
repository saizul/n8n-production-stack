.DEFAULT_GOAL := help
SHELL := /bin/bash

WORKERS ?= 2
SERVICE ?=
FILE ?= latest

.PHONY: help init up down restart logs ps backup restore update scale health config lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

init: ## Generate .env with random secrets (refuses to overwrite)
	./scripts/init.sh

up: ## Build and start the stack in the background
	docker compose up -d --build --remove-orphans

down: ## Stop and remove containers (volumes are kept)
	docker compose down

restart: ## Restart all services
	docker compose restart

logs: ## Follow logs (SERVICE=n8n-main to filter)
	docker compose logs -f --tail=100 $(SERVICE)

ps: ## Show service status and health
	docker compose ps

backup: ## Run a backup now and copy it to ./backups
	./scripts/backup.sh

restore: ## Restore a backup (FILE=latest | name | /path/to.dump)
	./scripts/restore.sh $(FILE)

update: ## Pull images, back up, recreate (VERSION=2.46.7 to change n8n)
	./scripts/update.sh $(VERSION)

scale: ## Scale workers (WORKERS=4)
	docker compose up -d --no-recreate --scale n8n-worker=$(WORKERS)

health: ## Check health of every container
	./scripts/healthcheck.sh

config: ## Validate and print the resolved compose file
	docker compose config

lint: ## bash -n and shellcheck on all scripts
	@for f in scripts/*.sh backup/*.sh; do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null; then shellcheck -x scripts/*.sh backup/*.sh; else echo "shellcheck not installed, skipped"; fi
