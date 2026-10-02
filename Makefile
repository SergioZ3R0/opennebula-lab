-include .env
export

COMPOSE ?= docker compose
ONE_VERSION ?= 7.4

.PHONY: help build up down reset logs smoke fe-shell node-shell pull

help:
	@echo "one-lab targets:"
	@echo "  make build   - build frontend + node images"
	@echo "  make up      - start the lab (detached)"
	@echo "  make down    - stop the lab"
	@echo "  make reset   - down + delete volumes (full wipe)"
	@echo "  make logs    - tail all logs"
	@echo "  make smoke   - basic health checks"
	@echo "  make fe-shell / node-shell"

build:
	$(COMPOSE) build

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

reset:
	$(COMPOSE) down -v

logs:
	$(COMPOSE) logs -f --tail=100

pull:
	$(COMPOSE) pull || true

smoke:
	@echo "== XML-RPC =="
	@curl -sf -X POST http://localhost:2633/RPC2 \
	  -d '<methodCall><methodName>system.version</methodName></methodCall>' && echo || (echo "XML-RPC FAIL"; exit 1)
	@echo "== onehost =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost list"'
	@echo "== onevm =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm list"'

fe-shell:
	docker exec -it one-lab-frontend bash

node-shell:
	docker exec -it one-lab-node1 bash
