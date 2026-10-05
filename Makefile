-include .env
export

COMPOSE ?= docker compose
ONE_VERSION ?= 7.4

.PHONY: help build up down reset logs smoke doctor fe-shell node-shell pull seed-info

help:
	@echo "one-lab targets:"
	@echo "  make build     - build frontend + node images"
	@echo "  make up        - start the lab (detached)"
	@echo "  make down      - stop the lab"
	@echo "  make reset     - down + delete volumes (full wipe)"
	@echo "  make logs      - tail all logs"
	@echo "  make smoke     - basic health checks (XML-RPC, host, daemons)"
	@echo "  make doctor    - deeper diagnostics (KVM, bridges, gate/flow, seed)"
	@echo "  make seed-info - show what the seed created"
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

# OpenNebula 7.x XML-RPC: one.system.version + session user:pass
define RPC_CHECK
curl -sf -X POST http://localhost:2633/RPC2 \
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
	@curl -sf -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:2616/ || echo "FireEdge: FAIL"
	@echo "== OpenNebula resources =="
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost list; echo; onevnet list; echo; oneimage list; echo; onetemplate list; echo; onevm list"'
	@echo "== onegate / oneflow / guacd =="
	@docker exec one-lab-frontend bash -lc 'ss -tln | grep -E ":5030|:2474|:4822" || echo "gate/flow/guacd ports not listening"'
	@echo "== node bridges / libvirt =="
	@docker exec one-lab-node1 bash -lc 'ip -br link | grep -E "onebr|br0" || echo "lab bridges missing"; virsh -r -c qemu:///system list --all --name 2>/dev/null | grep -v "^$$" || echo "(no libvirt domains)"'
	@echo "== logs (last errors) =="
	@docker exec one-lab-frontend bash -lc 'grep -E "ERROR|WARN" /var/log/one/oned.log 2>/dev/null | tail -5 || true'

seed-info:
	@docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevnet list; echo; oneimage list; echo; onetemplate list; echo; onedatastore list"'

fe-shell:
	docker exec -it one-lab-frontend bash

node-shell:
	docker exec -it one-lab-node1 bash
