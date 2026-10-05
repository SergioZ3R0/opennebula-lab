#!/usr/bin/env bash
set -euo pipefail

log() { echo "[one-lab:seed] $*"; }

SEED_NETWORK="${SEED_NETWORK:-nat}"
SEED_UBUNTU_IMAGE="${SEED_UBUNTU_IMAGE:-true}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
UBUNTU_IMAGE_NAME="${UBUNTU_IMAGE_NAME:-ubuntu-cloud}"
UBUNTU_TEMPLATE_NAME="${UBUNTU_TEMPLATE_NAME:-ubuntu-cloud-ssh}"
UBUNTU_VCPU="${UBUNTU_VCPU:-1}"
UBUNTU_MEMORY="${UBUNTU_MEMORY:-1024}"
SEED_TINY_IMAGE="${SEED_TINY_IMAGE:-false}"
TINY_IMAGE_URL="${TINY_IMAGE_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.0-x86_64-bios-cloudinit-r0.qcow2}"
TINY_IMAGE_NAME="${TINY_IMAGE_NAME:-alpine-tiny}"

# wait until onedatastore works
for _ in $(seq 1 60); do
  if onedatastore list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

log "Datastores:"
onedatastore list || true
onehost list || true

# --- virtual networks --------------------------------------------------------
# Base keeps two lab networks when NAT is on: dummy for lifecycle, bridge for real IPs.
create_lab_public() {
  if onevnet show lab-public >/dev/null 2>&1; then
    log "Network lab-public already exists"
    return 0
  fi
  log "Creating dummy network 'lab-public'"
  cat > /tmp/one-vnet-public.xml <<'EOF'
<NETWORK>
  <NAME>lab-public</NAME>
  <DESCRIPTION>OpenNebula lab public network (dummy driver)</DESCRIPTION>
  <VN_MAD>dummy</VN_MAD>
  <BRIDGE>onebr0</BRIDGE>
  <NETWORK_ADDRESS>192.168.100.0</NETWORK_ADDRESS>
  <NETWORK_MASK>255.255.255.0</NETWORK_MASK>
  <AR_POOL>
    <AR>
      <TYPE>IP4</TYPE>
      <IP>192.168.100.2</IP>
      <SIZE>200</SIZE>
      <GATEWAY>192.168.100.1</GATEWAY>
    </AR>
  </AR_POOL>
</NETWORK>
EOF
  onevnet create /tmp/one-vnet-public.xml || log "WARN: could not create lab-public"
}

create_lab_nat() {
  if onevnet show lab-nat >/dev/null 2>&1; then
    log "Network lab-nat already exists"
    return 0
  fi
  log "Creating NAT/bridge network 'lab-nat' (expects br0 on nodes)"
  cat > /tmp/one-vnet-nat.xml <<'EOF'
<NETWORK>
  <NAME>lab-nat</NAME>
  <DESCRIPTION>OpenNebula lab NAT network (bridge br0)</DESCRIPTION>
  <VN_MAD>bridge</VN_MAD>
  <BRIDGE>br0</BRIDGE>
  <NETWORK_ADDRESS>10.10.10.0</NETWORK_ADDRESS>
  <NETWORK_MASK>255.255.255.0</NETWORK_MASK>
  <AR_POOL>
    <AR>
      <TYPE>IP4</TYPE>
      <IP>10.10.10.2</IP>
      <SIZE>100</SIZE>
      <GATEWAY>10.10.10.1</GATEWAY>
    </AR>
  </AR_POOL>
</NETWORK>
EOF
  onevnet create /tmp/one-vnet-nat.xml || log "WARN: could not create lab-nat"
}

case "${SEED_NETWORK}" in
  dummy)
    create_lab_public
    ;;
  nat)
    create_lab_public
    create_lab_nat
    ;;
  none)
    log "SEED_NETWORK=none, skipping vnets"
    ;;
  *)
    log "WARN: unknown SEED_NETWORK=${SEED_NETWORK}, skipping vnets"
    ;;
esac

ensure_ar() {
  local vnet="$1" ip="$2" size="$3" gw="$4" mask="$5"
  onevnet show "${vnet}" >/dev/null 2>&1 || return 0
  # Empty AR_POOL still emits <AR><![CDATA[]]></AR>; look for a real range element.
  if onevnet show "${vnet}" --xml 2>/dev/null | grep -qE '<(TYPE|IP|IP_END)>'; then
    log "AR already present on ${vnet}"
    return 0
  fi
  log "Adding AR to ${vnet}"
  onevnet addar "${vnet}" --ip "${ip}" --size "${size}" --gateway "${gw}" --netmask "${mask}" \
    || log "WARN: addar failed for ${vnet}"
}
ensure_ar lab-public 192.168.100.2 200 192.168.100.1 255.255.255.0
ensure_ar lab-nat 10.10.10.2 100 10.10.10.1 255.255.255.0

# Pick network for the default bootable template: prefer NAT, fallback dummy.
template_vnet="lab-public"
if onevnet show lab-nat >/dev/null 2>&1; then
  template_vnet="lab-nat"
fi

# --- Ubuntu cloud image + template (default learning path) -------------------
# OpenNebula default datastore RESTRICTED_DIRS="/" and SAFE_DIRS="/var/tmp"
# so image sources must live under /var/tmp (not /tmp).
import_ubuntu_image() {
  if oneimage show "${UBUNTU_IMAGE_NAME}" >/dev/null 2>&1; then
    log "Image ${UBUNTU_IMAGE_NAME} already exists"
    return 0
  fi
  log "Downloading Ubuntu cloud image: ${UBUNTU_IMAGE_URL}"
  local tmp="/var/tmp/${UBUNTU_IMAGE_NAME}.img"
  if ! curl -fL --retry 3 --connect-timeout 20 -o "${tmp}" "${UBUNTU_IMAGE_URL}"; then
    log "WARN: could not download Ubuntu image"
    return 1
  fi
  chmod 644 "${tmp}"
  cat > "/var/tmp/${UBUNTU_IMAGE_NAME}.xml" <<EOF
<IMAGE>
  <NAME>${UBUNTU_IMAGE_NAME}</NAME>
  <TYPE>OS</TYPE>
  <PERSISTENT>YES</PERSISTENT>
  <PATH>${tmp}</PATH>
  <DEV_PREFIX>vd</DEV_PREFIX>
  <FORMAT>qcow2</FORMAT>
</IMAGE>
EOF
  if oneimage create "/var/tmp/${UBUNTU_IMAGE_NAME}.xml" -d default; then
    log "Image ${UBUNTU_IMAGE_NAME} imported"
  else
    log "WARN: oneimage create failed for ${UBUNTU_IMAGE_NAME}"
    return 1
  fi
}

create_ubuntu_template() {
  if onetemplate show "${UBUNTU_TEMPLATE_NAME}" >/dev/null 2>&1; then
    log "Template ${UBUNTU_TEMPLATE_NAME} already exists"
    return 0
  fi
  if ! oneimage show "${UBUNTU_IMAGE_NAME}" >/dev/null 2>&1; then
    log "WARN: skip template, image ${UBUNTU_IMAGE_NAME} missing"
    return 1
  fi
  # Inject the shared oneadmin pubkey so onevm ssh works via ProxyJump without passwords
  local fe_pubkey=""
  if [ -s /var/lib/one/.ssh/id_rsa.pub ]; then
    fe_pubkey="$(tr -d '\n' </var/lib/one/.ssh/id_rsa.pub)"
  fi
  log "Creating template ${UBUNTU_TEMPLATE_NAME} on ${template_vnet} (cloud-init users: lab/ubuntu password lab)"
  cat > /tmp/one-template-ubuntu.xml <<EOF
<TEMPLATE>
  <NAME>${UBUNTU_TEMPLATE_NAME}</NAME>
  <DESCRIPTION>Ubuntu cloud image with cloud-init (login lab / lab). SSH key optional via context.</DESCRIPTION>
  <CPU>${UBUNTU_VCPU}</CPU>
  <MEMORY>${UBUNTU_MEMORY}</MEMORY>
  <OS>
    <ARCH>x86_64</ARCH>
  </OS>
  <GRAPHICS>
    <TYPE>vnc</TYPE>
    <LISTEN>0.0.0.0</LISTEN>
    <PASSWD>lab</PASSWD>
    <KEYMAP>es</KEYMAP>
  </GRAPHICS>
  <CONTEXT>
    <NETWORK>YES</NETWORK>
    <USERNAME>lab</USERNAME>
    <SSH_PUBLIC_KEY>${fe_pubkey}</SSH_PUBLIC_KEY>
    <USER_DATA>#cloud-config
users:
  - default
  - name: lab
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${fe_pubkey}
chpasswd:
  list: |
    lab:lab
    ubuntu:lab
  expire: false
ssh_pwauth: true
ssh_authorized_keys:
  - ${fe_pubkey}
</USER_DATA>
  </CONTEXT>
  <DISK>
    <IMAGE>${UBUNTU_IMAGE_NAME}</IMAGE>
  </DISK>
  <NIC>
    <NETWORK>${template_vnet}</NETWORK>
  </NIC>
</TEMPLATE>
EOF
  if onetemplate create /tmp/one-template-ubuntu.xml; then
    log "Template ${UBUNTU_TEMPLATE_NAME} created"
  else
    log "WARN: onetemplate create failed"
    return 1
  fi
}

if [ "${SEED_UBUNTU_IMAGE}" = "true" ]; then
  import_ubuntu_image || true
  create_ubuntu_template || true
fi

# --- tiny Alpine image (optional lifecycle tests) ----------------------------
if [ "${SEED_TINY_IMAGE}" = "true" ]; then
  if ! oneimage show "${TINY_IMAGE_NAME}" >/dev/null 2>&1; then
    log "Downloading tiny cloud image: ${TINY_IMAGE_URL}"
    tmp="/var/tmp/${TINY_IMAGE_NAME}.qcow2"
    if curl -fL --retry 3 -o "${tmp}" "${TINY_IMAGE_URL}"; then
      chmod 644 "${tmp}"
      cat > "/var/tmp/${TINY_IMAGE_NAME}.xml" <<EOF
<IMAGE>
  <NAME>${TINY_IMAGE_NAME}</NAME>
  <TYPE>OS</TYPE>
  <PERSISTENT>YES</PERSISTENT>
  <PATH>${tmp}</PATH>
  <DEV_PREFIX>vd</DEV_PREFIX>
  <FORMAT>qcow2</FORMAT>
</IMAGE>
EOF
      oneimage create "/var/tmp/${TINY_IMAGE_NAME}.xml" -d default \
        && log "Image ${TINY_IMAGE_NAME} imported" \
        || log "WARN: oneimage create failed"
    else
      log "WARN: could not download tiny image"
    fi
  fi
fi

log "Seed done"
onevnet list || true
oneimage list || true
onetemplate list || true
