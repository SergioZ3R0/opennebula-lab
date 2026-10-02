# one-lab

**OpenNebula 7.4 self-contained lab** in Docker: front-end (oned + FireEdge + scheduler) + KVM compute node.

https://github.com/SergioZ3R0/opennebula-lab

Built to fill a real gap: OpenNebula does not publish official container images for labs/testing. This is a light Debian-slim lab you can destroy and rebuild in seconds.

## What you get

| Component | Ports | Notes |
|-----------|-------|-------|
| Front-end `opennebula` | `2633` XML-RPC, `2616` FireEdge | oned, onegate, oneflow, FireEdge UI |
| Node `node1` | — | libvirt + qemu, auto-registered as KVM host |

- Shared `oneadmin` SSH keypair across containers (no manual key juggling)
- Auto host registration (`onehost create node1 -i kvm -v kvm`)
- Optional dummy/NAT virtual network seed
- Optional tiny Alpine cloud image seed
- Optional second node via compose profile `multi`
- Basic sysadmin tools preinstalled on both containers

### Included tools

```
ip a | ss -tulpn | ifconfig | ping | dig | nslookup
traceroute | mtr | tcpdump | netcat | lsof | htop
nano | tree | jq | git | rsync | unzip | file
psmisc | bash-completion | sudo
```

OpenNebula CLI on the front-end: `onevm`, `onehost`, `onevnet`, `oneimage`, `onedatastore`, `oneuser`, `oneacl`...
Node also has `virsh` for KVM/libvirt inspection.

## Requirements

- Docker + Docker Compose v2
- `/dev/kvm` on the host (hardware virtualization)
- ~2–4 GB free RAM for the full lab with a tiny VM

## Quick start

```bash
git clone https://github.com/SergioZ3R0/opennebula-lab.git
cd opennebula-lab
cp .env.example .env
make up
# wait ~1–2 min for host ON + FireEdge
make smoke
```

Or pull published images (no build):

```bash
cp .env.example .env
IMAGE_OWNER=SergioZ3R0 docker compose pull
IMAGE_OWNER=SergioZ3R0 docker compose up -d
```

Images:
- `ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4`
- `ghcr.io/sergioz3r0/opennebula-lab-node:7.4`

Then:

```bash
# one9s
ONE_AUTH="oneadmin:opennebula" ONE_XMLRPC="http://localhost:2633/RPC2" one9s

# CLI
docker exec -it one-lab-frontend bash -lc 'su - oneadmin -c "onevm list"'

# FireEdge UI
open http://localhost:2616   # oneadmin / opennebula
```

## Configuration (`.env`)

| Var | Default | Description |
|-----|---------|-------------|
| `ONE_VERSION` | `7.4` | OpenNebula package series |
| `ONEADMIN_PASSWORD` | `opennebula` | oneadmin password (XML-RPC + FireEdge) |
| `REGISTER_HOSTS` | `node1` | Hosts to register (space separated) |
| `SEED_NETWORK` | `dummy` | `dummy` \| `nat` \| `none` |
| `SEED_TINY_IMAGE` | `false` | Import a tiny Alpine qcow2 on first boot |
| `SETUP_NAT` | `false` | Create `br0` + MASQUERADE on nodes (use with `SEED_NETWORK=nat`) |
| `XMLRPC_PORT` / `FIREEDGE_PORT` | `2633` / `2616` | Host port mappings |

## Everyday commands

```bash
make build      # build images locally
make up         # start
make logs       # follow logs
make smoke      # XML-RPC + onehost + onevm checks
make fe-shell   # shell in front-end
make node-shell # shell in node
make reset      # wipe volumes (fresh lab)
```

Multi-node:

```bash
REGISTER_HOSTS="node1 node2" docker compose --profile multi up -d
```

NAT networking:

```bash
# .env
SEED_NETWORK=nat
SETUP_NAT=true
```

## Architecture

```
docker compose
├── opennebula (frontend)          debian:13-slim + OpenNebula 7.4 CE
│   ├── oned :2633                 XML-RPC (one9s, GOCA, CLI)
│   ├── scheduler / onegate / oneflow
│   └── FireEdge :2616             modern web UI
│       └── SSH as oneadmin ─────────────────────┐
└── node1 (kvm)                    debian:13-slim + opennebula-node-kvm
    ├── sshd  ◄──────────────────────────────────┘
    ├── libvirtd + qemu (user=oneadmin)
    └── /dev/kvm passthrough
```

Shared volume `one-ssh` holds the `oneadmin` keypair: the front-end generates it on first boot; the node installs it into `authorized_keys`.

## Using it with one9s

This lab is ideal to exercise one9s features without a production cluster:

```bash
export ONE_AUTH="oneadmin:opennebula"
export ONE_XMLRPC="http://localhost:2633/RPC2"
./one9s
```

You get real host state, real VM lifecycle, datastores, ACLs and quotas — enough to reproduce issues safely.

## Publishing to GHCR

Images are public and free to pull on GHCR (container registry currently free from GitHub).

This repo builds and pushes:

- `ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4`
- `ghcr.io/sergioz3r0/opennebula-lab-node:7.4`

Workflow: `.github/workflows/publish.yml` (push to `main` or tags `v*`).

Users can then run without building:

```bash
IMAGE_OWNER=SergioZ3R0 docker compose pull && IMAGE_OWNER=SergioZ3R0 docker compose up -d
```

## Design notes / weight

- Base: `debian:13-slim` (OpenNebula CE supports Debian 12/13)
- `--no-install-recommends`, docs/man/locale stripped
- No legacy Ruby Sunstone (FireEdge is the UI since 6.10)
- SQLite, not MySQL
- Node image includes **ruby** (IM probes) + **dbus** (virsh/libvirt) — required for a working KVM host
- Uncompressed sizes (pull on GHCR is compressed, smaller):
  - frontend ≈ **1.6 GB** (OpenNebula + FireEdge + Node.js)
  - node ≈ **1.0 GB** (qemu + libvirt + ruby)
- Runtime RAM: oned+sqlite ≈ 200–300 MB; one tiny VM ≈ +256 MB
- Requires `/dev/kvm` on the Docker host

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Host stuck in `init`/`err` | `docker logs one-lab-frontend` → oned.log; SSH from FE: `docker exec one-lab-frontend bash -lc 'su - oneadmin -c "ssh node1 true"'` |
| No `/dev/kvm` | Host needs VT-x/AMD-V; nested virt may need extra flags |
| FireEdge not up | `docker exec one-lab-frontend bash -lc 'su - oneadmin -c "fireedge start"'` |
| Permission denied XML-RPC | Password mismatch: check `.env` `ONEADMIN_PASSWORD` vs `ONE_AUTH` |

## License

Same as one9s / Apache-2.0 friendly. Lab scripts are intentionally simple and meant to be forked.
