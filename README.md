# one-lab

**OpenNebula 7.4 self-contained lab** in Docker: front-end (oned + FireEdge + onegate + oneflow + guacd) + KVM compute node that **boots real VMs**.

https://github.com/SergioZ3R0/opennebula-lab

Built to fill a real gap: OpenNebula does not publish official container images for labs/testing. This is a light Debian-slim lab you can destroy and rebuild in seconds.

**Audience:** people who want a **working base cluster** to learn and break OpenNebula (CLI, FireEdge, VMs, networks, services). Not a production installer. Advanced features (VDC, OneKS/K8s, multi-tenant) are left for you to add on top.

## What you get (factory base)

| Component | Host ports | Inside the FE |
|-----------|------------|---------------|
| Front-end `opennebula` | `2633` XML-RPC, `2616` FireEdge, `2222→22` SSH | oned, onegate `:5030`, oneflow `:2474`, guacd `:4822`, CLI |
| Node `node1` | `5900-5915` VM VNC | libvirt + qemu/KVM, auto-registered host |

`onegate`, `oneflow` and `guacd` listen on the FE network namespace. They are **not published to the host** by default (use `docker exec` or FireEdge). VNC **is** published so desktop clients work from the host.

Default seed (`.env.example`):

| Resource | Name | Purpose |
|----------|------|---------|
| VNET | `lab-nat` | bridge `br0`, `10.10.10.0/24`, NAT to internet (`SETUP_NAT=true`) |
| VNET | `lab-public` | dummy `onebr0`, `192.168.100.0/24` (lifecycle / multi-NIC) |
| Image | `ubuntu-cloud` | Ubuntu 24.04 cloudimg (downloaded on first boot, ~600MB) |
| Template | `ubuntu-cloud-ssh` | cloud-init users `lab` and `ubuntu`, password `lab`, 1 vCPU / 1G |

Also: shared `oneadmin` SSH keypair, auto host registration, sysadmin tools, public GHCR images.

**Not preloaded on purpose:** extra users/ACLs/VDCs, OneKS clusters, homemade web VNC/noVNC sidecars, services you have not defined. FireEdge + official **guacd** *is* included for browser consoles. The cluster is meant to be extended and broken by you.

### Included tools

```
ip a | ss -tulpn | ifconfig | ping | dig | nslookup
traceroute | mtr | tcpdump | netcat | lsof | htop
nano | tree | jq | git | rsync | unzip | file
psmisc | bash-completion | sudo
```

OpenNebula CLI on the front-end: `onevm`, `onehost`, `onevnet`, `oneimage`, `onedatastore`, `oneuser`, `oneacl`, `oneflow`, `onevdc`...
Node also has `virsh` for KVM/libvirt inspection.

## Requirements

- Docker + Docker Compose v2
- `/dev/kvm` on the host (hardware virtualization: VT-x/AMD-V)
- ~2–4 GB free RAM for the full lab with a VM
- Compose uses `cgroup: host` + `/sys/fs/cgroup` bind (required for libvirt/qemu in containers)
- Outbound internet on first boot (Ubuntu image download from cloud-images.ubuntu.com)

## Verified

| Check | Result |
|-------|--------|
| Host `node1` | ON / MONITORED (CPU, memory, KVM) |
| XML-RPC + FireEdge | up |
| onegate / oneflow / guacd | up (`:5030` / `:2474` / `:4822`) |
| VM boot | Ubuntu 24.04 cloud + cloud-init (`lab`/`lab` or `ubuntu`/`lab`) |
| SSH into guest | from `node1` or `onevm ssh` (ProxyJump) |
| FireEdge console | VNC in browser via guacd |
| one9s | connects with `ONE_AUTH` / `ONE_XMLRPC` |

## Quick start (Docker Compose)

```bash
git clone https://github.com/SergioZ3R0/opennebula-lab.git
cd opennebula-lab
cp .env.example .env
# optional: edit .env (password, ports, seed options)
docker compose pull    # GHCR images (public)
docker compose up -d
# wait until FE logs show "Lab front-end ready"
# first boot can take ~1-3 min+ while Ubuntu image downloads (~600MB)
make smoke
make doctor            # optional deeper checks
```

Then connect:

```bash
# one9s
ONE_AUTH="oneadmin:opennebula" ONE_XMLRPC="http://localhost:2633/RPC2" one9s

# CLI
docker exec -it one-lab-frontend bash -lc 'su - oneadmin -c "onevm list"'

# FireEdge UI (console VNC in browser)
open http://localhost:2616   # oneadmin / opennebula
```

### Boot the seeded Ubuntu VM

```bash
docker exec -it one-lab-frontend bash -lc '
  su - oneadmin -c "onetemplate instantiate ubuntu-cloud-ssh --name lab-vm-01"
'
# wait until RUNNING (onevm list → runn), then:
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm show lab-vm-01"' | grep ETH0_IP
# example IP: 10.10.10.2

# SSH from the NODE (NAT IPs are not routed via the FE):
docker exec -it one-lab-node1 bash -lc 'ssh lab@10.10.10.2'    # password: lab
# also: ssh ubuntu@10.10.10.2

# or from the FE via onevm ssh (ProxyJump through node1):
docker exec -it one-lab-frontend bash -lc \
  'su - oneadmin -c "onevm ssh 0 lab --cmd=\"hostname; whoami\""'
```

Networking choice is yours: NAT for real IPs + internet, dummy for pure lifecycle, or your own bridge/VLAN/VDC on the node.

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

```bash
docker pull ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
docker pull ghcr.io/sergioz3r0/opennebula-lab-node:7.4
```

> **Note:** after merging image-source changes (`frontend/**`, `node/**`), wait for CI (`publish` workflow) before `docker compose pull`. Local `make build` works without waiting.

### Alternative: docker run (without compose)

Needs the same KVM/cgroup setup and seed env as compose:

```bash
docker network create one-lab

docker run -d --name one-lab-node1 --hostname node1 \
  --network one-lab \
  --privileged \
  --cgroupns host \
  --device /dev/kvm \
  -v /sys/fs/cgroup:/sys/fs/cgroup \
  -v one-ssh:/var/lib/one/.ssh \
  -e SETUP_NAT=true \
  -e ONE_VERSION=7.4 \
  ghcr.io/sergioz3r0/opennebula-lab-node:7.4

docker run -d --name one-lab-frontend --hostname opennebula \
  --network one-lab \
  -p 2633:2633 -p 2616:2616 -p 2222:22 \
  -e ONEADMIN_PASSWORD=opennebula \
  -e REGISTER_HOSTS=node1 \
  -e SEED_NETWORK=nat \
  -e SEED_UBUNTU_IMAGE=true \
  -e SETUP_NAT=true \
  -e ONE_VERSION=7.4 \
  -v one-data:/var/lib/one \
  -v one-ssh:/var/lib/one/.ssh \
  ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
```

Publish VNC on the **node** container (`-p 5900-5915:...`) if you want desktop VNC from the host. FireEdge console uses guacd on the FE and reaches the node over the docker network (no host VNC publish required).

## Access a VM console (VNC)

### Option A: FireEdge + Guacamole (recommended)

The front-end runs **guacd** (Apache Guacamole), the official OpenNebula console proxy. Open **FireEdge** → VMs → select the VM → **Console**. VNC works in the browser without a desktop VNC client.

```bash
open http://localhost:2616   # oneadmin / opennebula
```

Notes:

- guacd lives on the FE (`:4822`) and reaches VM VNC on the node over the compose network (`node1:5900+`).
- Browser **SSH** through Guacamole still needs a network path from FE to the guest IP. NAT guests (`10.10.10.x`) are only routed on the node, so use CLI `onevm ssh` (ProxyJump) or SSH from `node1` for those.
- VNC password for the seeded template is `lab` (also shown in `onevm show`).

### Option B: desktop VNC client

VMs also expose a raw VNC display on the **node** (`5900 + display`). Compose publishes `5900-5915` on the host.

```bash
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm show <vm>"' | grep -E 'PORT|PASSWD'
# example: PORT=5900  PASSWD=lab

sudo apt install tigervnc-viewer
vncviewer localhost:5900
```

Optional SSH tunnel if you prefer not to publish VNC ports:

```bash
docker exec -it one-lab-frontend bash -lc \
  'su - oneadmin -c "ssh -N -L 5900:node1:5900 node1"'
```

## Configuration (`.env`)

Copy `.env.example` → `.env`. Compose and the Makefile read it.

| Var | Default | Description |
|-----|---------|-------------|
| `ONE_VERSION` | `7.4` | OpenNebula package series / image tag |
| `DEBIAN_RELEASE` | `13` | Debian release used in image builds / apt repo path |
| `REGISTRY` | `ghcr.io` | Container registry |
| `IMAGE_OWNER` | `sergioz3r0` | GHCR owner (lowercase) |
| `ONEADMIN_PASSWORD` | `opennebula` | oneadmin password (XML-RPC + FireEdge + `ONE_AUTH`) |
| `REGISTER_HOSTS` | `node1` | Hosts to auto-register (space separated) |
| `SEED_NETWORK` | `nat` | `dummy` \| `nat` \| `none`. **`nat` seeds both** `lab-nat` + `lab-public` |
| `SEED_UBUNTU_IMAGE` | `true` | Download Ubuntu cloudimg + create template |
| `UBUNTU_IMAGE_URL` | Ubuntu 24.04 cloudimg | Override image source |
| `UBUNTU_IMAGE_NAME` | `ubuntu-cloud` | Image name in OpenNebula |
| `UBUNTU_TEMPLATE_NAME` | `ubuntu-cloud-ssh` | Default bootable template name |
| `UBUNTU_VCPU` / `UBUNTU_MEMORY` | `1` / `1024` | Default template size |
| `SEED_TINY_IMAGE` | `false` | Optional Alpine nocloud image (no SSH credentials) |
| `TINY_IMAGE_URL` | Alpine 3.20 nocloud qcow2 | Alpine image source |
| `TINY_IMAGE_NAME` | `alpine-tiny` | Alpine image name |
| `SETUP_NAT` | `true` | Create `br0` + MASQUERADE on **nodes** (required for `SEED_NETWORK=nat`) |
| `XMLRPC_PORT` | `2633` | Host port → oned XML-RPC |
| `FIREEDGE_PORT` | `2616` | Host port → FireEdge UI |
| `SSH_PORT` | `2222` | Host port → FE sshd |
| `VNC_PORT_RANGE` | `5900-5915` | Published VNC consoles on the node |

Image refs used by compose:

```
${REGISTRY}/${IMAGE_OWNER}/opennebula-lab-frontend:${ONE_VERSION}
${REGISTRY}/${IMAGE_OWNER}/opennebula-lab-node:${ONE_VERSION}
```

### Seed modes

| `SEED_NETWORK` | `SETUP_NAT` | What you get |
|----------------|-------------|--------------|
| `nat` (default) | `true` (default) | `lab-nat` + `lab-public`, Ubuntu template on NAT, guest internet via MASQUERADE |
| `dummy` | `false` | `lab-public` only (no guest internet) |
| `none` | `false` | No vnets from seed (create your own) |

Set `SEED_UBUNTU_IMAGE=false` for an empty image/template pool (pure infra lab).

### Multi-node

```bash
# .env
REGISTER_HOSTS="node1 node2"

docker compose --profile multi up -d
```

- `node2` is optional (profile `multi`).
- Only `node1` publishes host VNC ports by default.
- `onevm ssh` ProxyJump is written for `node1`; for guests on `node2` SSH from that node or extend ssh_config.

## Everyday commands

```bash
docker compose pull    # refresh images from GHCR
docker compose up -d   # start
docker compose down    # stop (keep volumes)
make logs              # follow logs
make smoke             # lab health (XML-RPC + host + daemons)
make doctor            # lab diagnostics (KVM, bridges, daemons)
make fe-shell          # shell in front-end
make node-shell        # shell in node
make reset             # wipe volumes (fresh lab)
make build             # build images locally (instead of pull)
make help              # list targets
make lint              # yamllint + compose config (CI runs shellcheck too)
```

Day-to-day OpenNebula work happens **inside the front-end CLI** (`make fe-shell`, then `su - oneadmin`). This lab intentionally does **not** wrap `onevm` / `onetemplate` in Make targets so you learn the real tools.

```bash
su - oneadmin
onehost list
onevnet list
onetemplate list
onetemplate instantiate ubuntu-cloud-ssh --name lab-vm-01
onevm show lab-vm-01
onevm ssh lab-vm-01 lab
```

## Learn and break it (by design)

This lab is a **base**. Use it to understand OpenNebula, then break it on purpose.

### First experiments

| Try | Command / action | What you learn |
|-----|------------------|----------------|
| Inventory | `onehost list` / `onevnet list` / `oneimage list` / `onetemplate list` | CLI + resource model |
| Boot a VM | `onetemplate instantiate ubuntu-cloud-ssh --name lab-vm-01` | Templates, prolog, context |
| Console | FireEdge → VM → Console (VNC in browser) | guacd path, graphics |
| SSH guest | `onevm show lab-vm-01` then from `node1`: `ssh lab@<IP>` | NAT path, reading context |
| Users | `oneuser create labuser --password lab` | Multi-tenant basics |
| ACL | `oneacl add` / delete and retry as labuser | Permissions model |
| VDC | `onevdc create lab-vdc` + `onecluster addvdc` | Isolation boundaries |
| Extra node | `REGISTER_HOSTS="node1 node2" docker compose --profile multi up -d` | Scheduling across hosts |
| Services | define a oneflow service template | Multi-VM orchestration |

### Break it on purpose

| Break | How | Observe |
|-------|-----|---------|
| Kill host IM | `docker exec one-lab-node1 pkill libvirtd` | host → `ERR`/`init`, supervisor recovery |
| Bad bridge | create vnet with bridge `no-such-br` + instantiate | prolog failure, oned.log |
| Wrong datastore path | import image from `/tmp` | `RESTRICTED_DIRS` rejection |
| ACL lockout | revoke own permissions | how OpenNebula fails closed |
| Wipe and rebuild | `make reset && docker compose up -d` | full lifecycle in minutes |

### Extend it (when you want more)

| Goal | Hints |
|------|-------|
| VDC / multi-cluster | `onevdc`, `onecluster`, attach hosts/vnets/datastores |
| OneKS / K8s | install `opennebula-ks` on FE yourself; need RAM + Marketplace + OneGate (already running) |
| Extra bridges/VLAN | add links on the node, then vnets with your `VN_MAD`/bridge |
| Browser console | FireEdge + guacd `:4822` (VNC via node). Browser SSH still needs a path to guest IPs |
| Publish gate/flow on host | compose override mapping `5030`/`2474` (not in default lab) |
| MySQL instead of SQLite | out of scope for this lab by design |

Diagnostics when something breaks (lab plumbing; OpenNebula state via CLI):

```bash
make doctor
docker logs one-lab-frontend --tail 100
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onehost show 0; tail -50 /var/log/one/oned.log"'
docker exec one-lab-node1 bash -lc 'virsh -r -c qemu:///system list --all; ip -br a'
```

## Build images yourself (optional)

```bash
docker compose build
# or
make build
```

Use this when GHCR does not have your branch yet, or you changed `frontend/**` / `node/**` locally.

## Architecture

```
docker compose project: one-lab
├── opennebula (frontend)          debian:13-slim + OpenNebula 7.4 CE
│   ├── oned :2633                 XML-RPC (one9s, GOCA, CLI)
│   ├── onegate :5030              guest context API (FE network only)
│   ├── oneflow :2474              services (FE network only)
│   ├── guacd :4822                FireEdge Guacamole (browser VNC)
│   ├── FireEdge :2616             modern web UI
│   └── sshd :22                   node pulls qcow2 disks from FE
│       └── SSH as oneadmin ─────────────────────┐
└── node1 (kvm)                    debian:13-slim + opennebula-node-kvm
    ├── sshd / libvirtd / virtlogd
    ├── qemu (user=oneadmin) + /dev/kvm
    ├── bridges onebr0 / br0 (lab networks)
    └── VM VNC :5900+              ◄─────────────┘
         network one-lab (docker bridge) connects FE ↔ nodes
```

Shared volume `one-ssh` holds the `oneadmin` keypair: the front-end generates it on first boot; the node installs it into `authorized_keys`. Seed cloud-init also injects that pubkey into guests for `onevm ssh`.

## Using it with one9s

```bash
export ONE_AUTH="oneadmin:opennebula"
export ONE_XMLRPC="http://localhost:2633/RPC2"
./one9s
```

If you changed `ONEADMIN_PASSWORD` in `.env`, use that instead of `opennebula`.

Real host state, VM lifecycle, datastores, ACLs and quotas — enough to reproduce issues safely. one9s talks to XML-RPC only; it does not need SSH into guests.

## How images are published

CI (`.github/workflows/publish.yml`) builds and pushes **only when image sources change** (`frontend/**`, `node/**`) or on tags `v*` / manual dispatch. README/docs-only commits do **not** rebuild packages.

CI (`.github/workflows/lint.yml`) runs on **push to main** and **pull requests**:

| Job | What it checks |
|-----|----------------|
| shellcheck | `*.sh` (entrypoints, seed) |
| yamllint | `docker-compose.yml` + workflows (`.yamllint.yml`) |
| docker compose config | compose file resolves with `.env.example` |

Locally: `make lint` (yamllint + compose config). Shellcheck is enforced in GitHub Actions.

Tags on push to `main`:

- `ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4` / `:latest`
- `ghcr.io/sergioz3r0/opennebula-lab-node:7.4` / `:latest`

Package pages:
- https://github.com/users/SergioZ3R0/packages/container/package/opennebula-lab-frontend
- https://github.com/users/SergioZ3R0/packages/container/package/opennebula-lab-node

To force a rebuild without code changes: **Actions → publish → Run workflow**.

## Design notes / weight

- Base: `debian:13-slim` (OpenNebula CE supports Debian 12/13)
- `--no-install-recommends`, docs/man/locale stripped
- No legacy Ruby Sunstone (FireEdge is the UI since 6.10)
- SQLite, not MySQL
- Node image includes **ruby** (IM probes) + **dbus** (virsh/libvirt) — required for a working KVM host
- Front-end includes **guacd** for FireEdge consoles (official package, not a custom web VNC)
- Uncompressed sizes (GHCR pull is compressed, smaller; guacd adds a bit to the FE):
  - frontend ≈ **1.7 GB** (OpenNebula + FireEdge + guacd + Node.js + tools)
  - node ≈ **1.17 GB** (qemu + libvirt + ruby + tools)
- Runtime RAM: oned+sqlite ≈ 200–300 MB; one VM ≈ +0.5–1.5 GB
- Requires `/dev/kvm` on the Docker host

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Host stuck in `init`/`err` | `docker logs one-lab-frontend` → oned.log; SSH FE→node |
| No `/dev/kvm` | Host needs VT-x/AMD-V; node entrypoint fixes group access |
| `CPU tuning is not available` | Missing `cgroup: host` / cgroup bind mount |
| `Cannot access KVM kernel module` | `/dev/kvm` not passed or oneadmin lacks permission |
| VM `PROLOG_FAILURE` (copy disk) | FE sshd must run — node pulls qcow2 from FE |
| `Cannot get interface MTU on onebr0` | Node must create lab bridges (`onebr0`, `br0`) |
| Image import `RESTRICTED_DIRS` | Put qcow2 under `/var/tmp` (SAFE_DIRS), not `/tmp` |
| SSH to VM timeout from FE | VM NAT IP is only on the node — SSH from `node1` or `onevm ssh` |
| `onevm ssh` hangs / timeout | Missing ProxyJump in FE `ssh_config` or guest lacks oneadmin pubkey |
| FireEdge console blank | guacd must listen on FE `:4822`; check `make doctor` and FE logs |
| FireEdge not up | `fireedge-server start` as oneadmin on the FE |
| Permission denied XML-RPC | `.env` `ONEADMIN_PASSWORD` vs `ONE_AUTH` |
| `make smoke` fails right after `up -d` | First boot still downloading Ubuntu image; wait for `Lab front-end ready` |
| `docker pull` denied | Images are public; check tag (`7.4` vs `latest`) |
| Old images after merge | CI only rebuilds on `frontend/**` / `node/**` / tags `v*` / dispatch |

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Lab scripts are intentionally simple and meant to be forked.
