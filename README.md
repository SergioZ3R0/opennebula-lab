# one-lab

**OpenNebula 7.4 self-contained lab** in Docker: front-end (oned + FireEdge) + KVM compute node that **boots real VMs**.

https://github.com/SergioZ3R0/opennebula-lab

Built to fill a real gap: OpenNebula does not publish official container images for labs/testing. This is a light Debian-slim lab you can destroy and rebuild in seconds.

## What you get

| Component | Ports | Notes |
|-----------|-------|-------|
| Front-end `opennebula` | `2633` XML-RPC, `2616` FireEdge, `22` SSH | oned, onegate, oneflow, FireEdge UI |
| Node `node1` | `5900-5915` VM VNC | libvirt + qemu/KVM, auto-registered host |

- Shared `oneadmin` SSH keypair across containers
- Auto host registration (`onehost create node1 -i kvm -v kvm`)
- **Real KVM VMs** (not mocks) — verified boot + SSH into guest
- Networks: dummy (lifecycle only) or NAT bridge (`br0` + MASQUERADE)
- Optional second node via compose profile `multi`
- Sysadmin tools preinstalled (`ip`, `htop`, `tcpdump`, `virsh`, ...)
- Public images on GHCR

Networking (bridge, VLAN, VDC, multiple vnets, ...) is up to you — the lab only provides the base FE + KVM node.

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
- ~2–4 GB free RAM for the full lab with a VM
- Compose uses `cgroup: host` + `/sys/fs/cgroup` bind (required for libvirt/qemu in containers)

## Verified

| Check | Result |
|-------|--------|
| Host `node1` | ON / MONITORED (CPU, memory, KVM) |
| XML-RPC + FireEdge | up |
| VM boot | Alpine + Ubuntu 24.04 with `-accel kvm` |
| SSH into guest | `lab@10.10.10.2` (NAT + cloud-init) |
| one9s | connects with `ONE_AUTH` / `ONE_XMLRPC` |

## Quick start (Docker Compose)

```bash
git clone https://github.com/SergioZ3R0/opennebula-lab.git
cd opennebula-lab
cp .env.example .env
docker compose pull    # pulls the GHCR images
docker compose up -d
# wait ~1–2 min for host ON + FireEdge
make smoke
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

## Boot a VM with SSH (NAT)

For guests you can SSH into (not just VNC console), use the NAT network + an image with cloud-init.

```bash
# .env
SEED_NETWORK=nat
SETUP_NAT=true

docker compose up -d
```

Import a cloud image (sources must live under `/var/tmp` — datastore `RESTRICTED_DIRS=/`):

```bash
docker exec one-lab-frontend bash -lc '
  curl -fL -o /var/tmp/ubuntu-cloud.img \
    https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
  su - oneadmin -c "oneimage create /var/tmp/ubuntu.xml -d default"   # PATH=/var/tmp/ubuntu-cloud.img, TYPE=OS, FORMAT=qcow2
'
```

Template with cloud-init (password + key) on `lab-nat`, instantiate, then from the **node** (VM IP is only routed there):

```bash
# get VM IP
docker exec one-lab-frontend bash -lc 'su - oneadmin -c "onevm show <vm>"' | grep ETH0_IP
# example: 10.10.10.2

docker exec -it one-lab-node1 bash -lc 'ssh lab@10.10.10.2'
# or with a key you injected via cloud-init USER_DATA / SSH_PUBLIC_KEY
```

`onevm ssh` hops FE → node → guest automatically once keys/credentials are in place.

Networking choice is yours: dummy for pure lifecycle/one9s tests, NAT if you need IPs, or your own bridge/VLAN/VDC on the node.

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
| `SEED_NETWORK` | `dummy` | `dummy` \| `nat` \| `none` |
| `SEED_TINY_IMAGE` | `false` | Import a tiny Alpine cloud image on first boot (`/var/tmp`) |
| `SETUP_NAT` | `false` | Create `br0` + MASQUERADE on nodes (use with `SEED_NETWORK=nat`) |
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

NAT networking (VMs with IPs):

```bash
# .env
SEED_NETWORK=nat
SETUP_NAT=true
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

