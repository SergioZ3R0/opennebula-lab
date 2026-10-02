# one-lab

**OpenNebula 7.4 self-contained lab** in Docker: front-end (oned + FireEdge) + KVM compute node.

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
- `/dev/kvm` on the host (hardware virtualization: VT-x/AMD-V)
- ~2–4 GB free RAM for the full lab with a tiny VM
- Compose service uses `cgroup: host` + `/sys/fs/cgroup` bind mount (required for libvirt/qemu in containers)

## Boot a VM

```bash
# .env
SEED_TINY_IMAGE=true

docker compose pull && docker compose up -d
# wait for host ON, then:
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "oneimage list; onehost list"'
```

Then create a template and instantiate (or use FireEdge UI / one9s):

```bash
docker exec -it one-lab-frontend bash -lc 'su - oneadmin'
onevm list
```

Verified: Alpine tiny cloud image boots on `node1` with KVM (`virsh list` → `running`).

### What the lab needs for real VMs

| Piece | Why |
|-------|-----|
| `/dev/kvm` | KVM acceleration |
| `cgroup: host` | libvirt creates qemu cgroups |
| FE `sshd` | qcow2 TM clone: node pulls disks from FE |
| `virtlogd` | libvirt qemu log socket |
| bridges `onebr0`/`br0` | dummy/NAT vnet XML references them |
| `/dev/kvm` group access | oneadmin must read/write kvm device |

## Docker images

Images are published on **GitHub Container Registry (GHCR)**. They are **public** — no login needed to pull.

| Image | Pull command |
|-------|----------------|
| Front-end | `docker pull ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4` |
| KVM node | `docker pull ghcr.io/sergioz3r0/opennebula-lab-node:7.4` |

Tags:

| Tag | Meaning |
|-----|---------|
| `7.4` | OpenNebula 7.4 (pinned, recommended) |
| `latest` | Latest build from `main` |

Example:

```bash
docker pull ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
docker pull ghcr.io/sergioz3r0/opennebula-lab-node:7.4
```

## Quick start (Docker Compose)

```bash
git clone https://github.com/SergioZ3R0/opennebula-lab.git
cd opennebula-lab
cp .env.example .env
docker compose pull    # pulls the GHCR images above
docker compose up -d
# wait ~1–2 min for host ON + FireEdge
```

Smoke test:

```bash
make smoke
# or manually:
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost list"'
```

Then connect:

```bash
# one9s
ONE_AUTH="oneadmin:opennebula" ONE_XMLRPC="http://localhost:2633/RPC2" one9s

# CLI
docker exec -it one-lab-frontend bash -lc 'su - oneadmin -c "onevm list"'

# FireEdge UI
open http://localhost:2616   # oneadmin / opennebula
```

### Alternative: docker run (without compose)

```bash
docker network create one-lab

docker run -d --name one-lab-node1 --hostname node1 \
  --network one-lab \
  --privileged \
  --device /dev/kvm \
  -v one-ssh:/var/lib/one/.ssh \
  ghcr.io/sergioz3r0/opennebula-lab-node:7.4

docker run -d --name one-lab-frontend --hostname opennebula \
  --network one-lab \
  -p 2633:2633 -p 2616:2616 \
  -e ONEADMIN_PASSWORD=opennebula \
  -e REGISTER_HOSTS=node1 \
  -v one-data:/var/lib/one \
  -v one-ssh:/var/lib/one/.ssh \
  ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
```

## Configuration (`.env`)

| Var | Default | Description |
|-----|---------|-------------|
| `ONE_VERSION` | `7.4` | OpenNebula package series / image tag |
| `ONEADMIN_PASSWORD` | `opennebula` | oneadmin password (XML-RPC + FireEdge) |
| `REGISTER_HOSTS` | `node1` | Hosts to auto-register (space separated) |
| `SEED_NETWORK` | `dummy` | `dummy` \| `nat` \| `none` |
| `SEED_TINY_IMAGE` | `false` | Import a tiny Alpine cloud image on first boot (use `/var/tmp` — datastore RESTRICTED_DIRS) |
| `SETUP_NAT` | `false` | Create `br0` + MASQUERADE on nodes (use with `SEED_NETWORK=nat`) |
| `XMLRPC_PORT` / `FIREEDGE_PORT` | `2633` / `2616` | Host port mappings |

The compose file defaults to:

```
ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
ghcr.io/sergioz3r0/opennebula-lab-node:7.4
```

## Everyday commands

```bash
docker compose pull    # refresh images from GHCR
docker compose up -d   # start
docker compose down    # stop (keep volumes)
make logs              # follow logs
make smoke             # XML-RPC + onehost + onevm checks
make fe-shell          # shell in front-end
make node-shell        # shell in node
make reset             # wipe volumes (fresh lab)
make build             # build images locally (instead of pull)
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

## Build images yourself (optional)

If you prefer building instead of pulling from GHCR:

```bash
docker compose build
# or
make build
```

## Architecture

```
docker compose
├── opennebula (frontend)          debian:13-slim + OpenNebula 7.4 CE
│   ├── oned :2633                 XML-RPC (one9s, GOCA, CLI)
│   ├── onegate / oneflow
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

## How images are published

CI (`.github/workflows/publish.yml`) builds and pushes on every push to `main` (and on tags `v*`):

- `ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4`
- `ghcr.io/sergioz3r0/opennebula-lab-frontend:latest`
- `ghcr.io/sergioz3r0/opennebula-lab-node:7.4`
- `ghcr.io/sergioz3r0/opennebula-lab-node:latest`

Package pages:
- https://github.com/users/SergioZ3R0/packages/container/package/opennebula-lab-frontend
- https://github.com/users/SergioZ3R0/packages/container/package/opennebula-lab-node

## Design notes / weight

- Base: `debian:13-slim` (OpenNebula CE supports Debian 12/13)
- `--no-install-recommends`, docs/man/locale stripped
- No legacy Ruby Sunstone (FireEdge is the UI since 6.10)
- SQLite, not MySQL
- Node image includes **ruby** (IM probes) + **dbus** (virsh/libvirt) — required for a working KVM host
- Uncompressed sizes (GHCR pull is compressed, smaller):
  - frontend ≈ **1.65 GB** (OpenNebula + FireEdge + Node.js + tools)
  - node ≈ **1.17 GB** (qemu + libvirt + ruby + tools)
- Runtime RAM: oned+sqlite ≈ 200–300 MB; one tiny VM ≈ +256 MB
- Requires `/dev/kvm` on the Docker host

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Host stuck in `init`/`err` | `docker logs one-lab-frontend` → oned.log; SSH from FE: `docker exec one-lab-frontend bash -lc 'su - oneadmin -c "ssh node1 true"'` |
| No `/dev/kvm` | Host needs VT-x/AMD-V; node entrypoint chmods kvm and adds oneadmin to its group |
| `CPU tuning is not available` | Missing `cgroup: host` in compose / cgroup bind mount |
| `Cannot access KVM kernel module` | `/dev/kvm` not passed or oneadmin lacks device permission |
| VM `PROLOG_FAILURE` (copy disk) | FE sshd must run — node pulls qcow2 from FE |
| `Cannot get interface MTU on onebr0` | Node must create lab bridges (`onebr0`, `br0`) |
| Image import `RESTRICTED_DIRS` | Put qcow2 under `/var/tmp` (SAFE_DIRS), not `/tmp` |
| FireEdge not up | `docker exec one-lab-frontend bash -lc 'su - oneadmin -c "fireedge-server start"'` |
| Permission denied XML-RPC | Password mismatch: check `.env` `ONEADMIN_PASSWORD` vs `ONE_AUTH` |
| `docker pull` denied | Images are public; if still denied check the tag (`7.4` vs `latest`) |

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Lab scripts are intentionally simple and meant to be forked.
