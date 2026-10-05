# one-lab

**OpenNebula 7.4 self-contained lab** in Docker: front-end (oned + FireEdge + onegate + oneflow) + KVM compute node that **boots real VMs**.

https://github.com/SergioZ3R0/opennebula-lab

Built to fill a real gap: OpenNebula does not publish official container images for labs/testing. This is a light Debian-slim lab you can destroy and rebuild in seconds.

**Audience:** people who want a **working base cluster** to learn and break OpenNebula (CLI, FireEdge, VMs, networks, services). Not a production installer. Advanced features (VDC, OneKS/K8s, multi-tenant) are left for you to add on top.

## What you get (factory base)

| Component | Ports | Notes |
|-----------|-------|-------|
| Front-end `opennebula` | `2633` XML-RPC, `2616` FireEdge, `22` SSH | oned, onegate `:5030`, oneflow `:2474`, CLI |
| Node `node1` | `5900-5915` VM VNC | libvirt + qemu/KVM, auto-registered host |

Default seed (`.env.example`):

| Resource | Name | Purpose |
|----------|------|---------|
| VNET | `lab-nat` | bridge `br0`, `10.10.10.0/24`, NAT to internet |
| VNET | `lab-public` | dummy `onebr0`, `192.168.100.0/24` (lifecycle / multi-NIC) |
| Image | `ubuntu-cloud` | Ubuntu 24.04 cloudimg (downloaded on first boot) |
| Template | `ubuntu-cloud-ssh` | cloud-init users `ubuntu`/`lab` and `lab`/`lab`, 1 vCPU / 1G |

Also: shared `oneadmin` SSH keypair, auto host registration, sysadmin tools, public GHCR images.

**Not preloaded on purpose:** extra users/ACLs/VDCs, OneKS clusters, web VNC, services you have not defined. The cluster is meant to be extended and broken by you.

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
- First boot with Ubuntu seed downloads ~600MB into the default datastore

## Verified

| Check | Result |
|-------|--------|
| Host `node1` | ON / MONITORED (CPU, memory, KVM) |
| XML-RPC + FireEdge | up |
| onegate / oneflow | up (`:5030` / `:2474`) |
| VM boot | Ubuntu 24.04 cloud + cloud-init (`ubuntu`/`lab` or `lab`/`lab`) |
| SSH into guest | `lab@10.10.10.2` or `ubuntu@10.10.10.x` (NAT) from `node1` or `onevm ssh` |
| one9s | connects with `ONE_AUTH` / `ONE_XMLRPC` |

## Quick start (Docker Compose)

```bash
git clone https://github.com/SergioZ3R0/opennebula-lab.git
cd opennebula-lab
cp .env.example .env
docker compose pull    # pulls the GHCR images
docker compose up -d
# wait ~1-3 min (longer on first boot: Ubuntu image download)
make smoke
make doctor            # optional deeper checks
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

### Boot the seeded Ubuntu VM

```bash
docker exec -it one-lab-frontend bash -lc '
  su - oneadmin -c "onetemplate instantiate ubuntu-cloud-ssh --name lab-vm-01"
'
# wait until RUNNING, then from the NODE (NAT IPs are not routed via FE):
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm show lab-vm-01"' | grep ETH0_IP
docker exec -it one-lab-node1 bash -lc 'ssh lab@10.10.10.x'
# also works: ssh ubuntu@10.10.10.x
# password for both users: lab
```

`onevm ssh` hops FE → node → guest once keys/credentials are in place.

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

### Alternative: docker run (without compose)

Needs the same KVM/cgroup setup as compose (`--privileged`, `/dev/kvm`, cgroup mount):

```bash
docker network create one-lab

docker run -d --name one-lab-node1 --hostname node1 \
  --network one-lab \
  --privileged \
  --cgroupns host \
  --device /dev/kvm \
  -v /sys/fs/cgroup:/sys/fs/cgroup \
  -v one-ssh:/var/lib/one/.ssh \
  ghcr.io/sergioz3r0/opennebula-lab-node:7.4

docker run -d --name one-lab-frontend --hostname opennebula \
  --network one-lab \
  -p 2633:2633 -p 2616:2616 -p 2222:22 \
  -e ONEADMIN_PASSWORD=opennebula \
  -e REGISTER_HOSTS=node1 \
  -v one-data:/var/lib/one \
  -v one-ssh:/var/lib/one/.ssh \
  ghcr.io/sergioz3r0/opennebula-lab-frontend:7.4
```

## Access a VM console (VNC)

VMs expose a VNC display on the **node** (`5900 + display`). Compose publishes `5900-5915` on the host.

**Browsers do not open `vnc://` URLs.** This lab does **not** ship a web VNC client — you need a desktop VNC viewer.

```bash
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm show <vm>"' | grep -E 'PORT|PASSWD'
# example: PORT=5908  PASSWD=lab

sudo apt install tigervnc-viewer
vncviewer localhost:5908
```

Optional SSH tunnel if you prefer not to publish VNC ports:

```bash
docker exec -it one-lab-frontend bash -lc \
  'su - oneadmin -c "ssh -N -L 5908:node1:5908 node1"'
```

## Configuration (`.env`)

| Var | Default | Description |
|-----|---------|-------------|
| `ONE_VERSION` | `7.4` | OpenNebula package series / image tag |
| `ONEADMIN_PASSWORD` | `opennebula` | oneadmin password (XML-RPC + FireEdge) |
| `REGISTER_HOSTS` | `node1` | Hosts to auto-register (space separated) |
| `SEED_NETWORK` | `nat` | `dummy` \| `nat` \| `none`. `nat` seeds **both** `lab-nat` + `lab-public` |
| `SEED_UBUNTU_IMAGE` | `true` | Download Ubuntu cloudimg + create `ubuntu-cloud-ssh` template |
| `UBUNTU_IMAGE_URL` | Ubuntu 24.04 cloudimg | Override image source |
| `UBUNTU_TEMPLATE_NAME` | `ubuntu-cloud-ssh` | Default bootable template name |
| `UBUNTU_VCPU` / `UBUNTU_MEMORY` | `1` / `1024` | Default template size |
| `SEED_TINY_IMAGE` | `false` | Optional Alpine nocloud image (no SSH credentials) |
| `SETUP_NAT` | `true` | Create `br0` + MASQUERADE on nodes (required for `SEED_NETWORK=nat`) |
| `XMLRPC_PORT` / `FIREEDGE_PORT` | `2633` / `2616` | Host port mappings |
| `SSH_PORT` | `2222` | Front-end SSH (lab convenience) |
| `VNC_PORT_RANGE` | `5900-5915` | Published VNC consoles on the node |

Compose defaults to:

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
make smoke             # XML-RPC + host + daemon checks
make doctor            # KVM, bridges, gate/flow, seed inventory
make seed-info         # vnets / images / templates created by seed
make fe-shell          # shell in front-end
make node-shell        # shell in node
make reset             # wipe volumes (fresh lab)
make build             # build images locally (instead of pull)
```

Multi-node:

```bash
REGISTER_HOSTS="node1 node2" docker compose --profile multi up -d
```

## Learn and break it (by design)

This lab is a **base**. Use it to understand OpenNebula, then break it on purpose.

### First experiments

| Try | Command / action | What you learn |
|-----|------------------|----------------|
| Inventory | `make seed-info` / `onehost list` | What the cluster owns |
| Boot a VM | `onetemplate instantiate ubuntu-cloud-ssh` | Prolog, context, cloud-init |
| SSH guest | from `node1`: `ssh lab@10.10.10.x` | NAT path, guest networking |
| Console | VNC `localhost:5900+display` (desktop client) | Graphics, PASSWD from `onevm show` |
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
| MySQL instead of SQLite | out of scope for this lab by design |
| Web VNC / noVNC | deliberately not shipped |

Diagnostics when something breaks:

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

## Architecture

```
docker compose
├── opennebula (frontend)          debian:13-slim + OpenNebula 7.4 CE
│   ├── oned :2633                 XML-RPC (one9s, GOCA, CLI)
│   ├── onegate / oneflow
│   ├── FireEdge :2616             modern web UI
│   └── sshd :22                   node pulls qcow2 disks from FE
│       └── SSH as oneadmin ─────────────────────┐
└── node1 (kvm)                    debian:13-slim + opennebula-node-kvm
    ├── sshd / libvirtd / virtlogd
    ├── qemu (user=oneadmin) + /dev/kvm
    ├── bridges onebr0 / br0 (lab networks)
    └── VM VNC :5900+              ◄─────────────┘
```

Shared volume `one-ssh` holds the `oneadmin` keypair: the front-end generates it on first boot; the node installs it into `authorized_keys`.

## Using it with one9s

```bash
export ONE_AUTH="oneadmin:opennebula"
export ONE_XMLRPC="http://localhost:2633/RPC2"
./one9s
```

Real host state, VM lifecycle, datastores, ACLs and quotas — enough to reproduce issues safely. one9s talks to XML-RPC only; it does not need SSH into guests.

## How images are published

CI (`.github/workflows/publish.yml`) builds and pushes **only when image sources change** (`frontend/**`, `node/**`) or on tags `v*` / manual dispatch. README/docs-only commits do **not** rebuild packages.

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
- Uncompressed sizes (GHCR pull is compressed, smaller):
  - frontend ≈ **1.66 GB** (OpenNebula + FireEdge + Node.js + tools)
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
| FireEdge not up | `fireedge-server start` as oneadmin on the FE |
| Permission denied XML-RPC | `.env` `ONEADMIN_PASSWORD` vs `ONE_AUTH` |
| `docker pull` denied | Images are public; check tag (`7.4` vs `latest`) |

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Lab scripts are intentionally simple and meant to be forked.

