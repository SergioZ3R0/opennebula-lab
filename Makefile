-include .env
export

COMPOSE ?= docker compose
ONE_VERSION ?= 7.4
XMLRPC_PORT ?= 2633
FIREEDGE_PORT ?= 2616

.PHONY: help build up down reset logs smoke doctor fe-shell node-shell pull lint

help:
	@echo "one-lab targets:"
	@echo "  make build     - build frontend + node images"
	@echo "  make up        - start the lab (detached)"
	@echo "  make down      - stop the lab"
	@echo "  make reset     - down + delete volumes (full wipe)"
	@echo "  make logs      - tail all logs"
	@echo "  make smoke     - lab health (XML-RPC, host, daemons)"
	@echo "  make doctor    - lab diagnostics (KVM, bridges, daemons)"
	@echo "  make lint      - yamllint + compose config (same as CI)"
	@echo "  make fe-shell / node-shell"
	@echo ""
	@echo "OpenNebula itself: use the CLI inside the FE (su - oneadmin)."
	@echo "  e.g. onevm list · onetemplate instantiate · onevm ssh"

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

# Static checks aligned with .github/workflows/lint.yml (shellcheck runs in CI)
lint:
	@command -v yamllint >/dev/null || { echo "yamllint not installed"; exit 1; }
	yamllint -c .yamllint.yml docker-compose.yml .github/workflows/*.yml
	@cp -f .env.example .env.lint-check 2>/dev/null || true
	docker compose --env-file .env.example config --quiet
	@rm -f .env.lint-check
	@echo "lint OK (yamllint + compose config)"

# OpenNebula 7.x XML-RPC: one.system.version + session user:pass
define RPC_CHECK
curl -sf -X POST http://localhost:$(XMLRPC_PORT)/RPC2 \
  -d '<?xml version="1.0"?><methodCall><methodName>one.system.version</methodName><params><param><value><string>oneadmin:$(ONEADMIN_PASSWORD)</string></value></param></params></methodCall>' \
  | grep -q '<boolean>1</boolean>'
endef

smoke:
	@echo "== XML-RPC (one.system.version) =="
	@$(RPC_CHECK) && echo OK || (echo "XML-RPC FAIL"; exit 1)
	@echo "== onehost =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost list"'
	@echo "== onevm =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm list"'
	@echo "== daemons =="
	@docker exec one-lab-frontend bash -lc 'pgrep -x oned >/dev/null && echo "oned: OK" || echo "oned: MISSING"'
	@docker exec one-lab-frontend bash -lc 'pgrep -f oneflow-server >/dev/null && echo "oneflow: OK" || echo "oneflow: MISSING"'
	@docker exec one-lab-frontend bash -lc 'pgrep -f onegate-server >/dev/null && echo "onegate: OK" || echo "onegate: MISSING"'
	@docker exec one-lab-frontend bash -lc 'pgrep -f guacd >/dev/null && echo "guacd: OK" || echo "guacd: MISSING"'

doctor:
	@echo "== containers =="
	@docker ps --filter 'name=one-lab' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@echo "== host KVM device =="
	@test -e /dev/kvm && ls -l /dev/kvm || echo "MISSING /dev/kvm on docker host"
	@echo "== XML-RPC =="
	@$(RPC_CHECK) && echo "XML-RPC: OK" || echo "XML-RPC: FAIL"
	@echo "== FireEdge =="
	@curl -sf -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:$(FIREEDGE_PORT)/ || echo "FireEdge: FAIL"
	@echo "== OpenNebula resources =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost list; echo; onevnet list; echo; oneimage list; echo; onetemplate list; echo; onevm list"'
	@echo "== onegate / oneflow / guacd =="
	@docker exec one-lab-frontend bash -lc 'ss -tln | grep -E ":5030|:2474|:4822" || echo "gate/flow/guacd ports not listening"'
	@echo "== node bridges / libvirt =="
	@docker exec one-lab-node1 bash -lc 'ip -br link | grep -E "onebr|br0" || echo "lab bridges missing"; virsh -r -c qemu:///system list --all --name 2>/dev/null | grep -v "^$$" || echo "(no libvirt domains)"'
	@echo "== logs (last errors) =="
	@docker exec one-lab-frontend bash -lc 'grep -E "ERROR|WARN" /var/log/one/oned.log 2>/dev/null | tail -5 || true'

fe-shell:
	docker exec -it one-lab-frontend bash

node-shell:
	docker exec -it one-lab-node1 bash
