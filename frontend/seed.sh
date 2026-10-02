#!/usr/bin/env bash
set -euo pipefail

log() { echo "[one-lab:seed] $*"; }

SEED_NETWORK="${SEED_NETWORK:-dummy}"
SEED_TINY_IMAGE="${SEED_TINY_IMAGE:-false}"
TINY_IMAGE_URL="${TINY_IMAGE_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.0-x86_64-bios-cloudinit-r0.qcow2}"
TINY_IMAGE_NAME="${TINY_IMAGE_NAME:-alpine-tiny}"

# wait until onedatastore works
for i in $(seq 1 60); do
  if onedatastore list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

log "Datastores:"
onedatastore list || true
onehost list || true

# --- virtual network ---------------------------------------------------------
if [ "${SEED_NETWORK}" = "dummy" ]; then
  if ! onevnet show lab-public >/dev/null 2>&1; then
    log "Creating dummy network 'lab-public'"
    cat > /tmp/one-vnet.xml <<'EOF'
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
    onevnet create /tmp/one-vnet.xml || log "WARN: could not create lab-public"
  else
    log "Network lab-public already exists"
  fi
elif [ "${SEED_NETWORK}" = "nat" ]; then
  # NAT requires the node entrypoint to create bridge br0 + MASQUERADE
  if ! onevnet show lab-nat >/dev/null 2>&1; then
    log "Creating NAT/bridge network 'lab-nat' (expects br0 on nodes)"
    cat > /tmp/one-vnet.xml <<'EOF'
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
    onevnet create /tmp/one-vnet.xml || log "WARN: could not create lab-nat"
  fi
fi

# --- tiny image (optional) ---------------------------------------------------
if [ "${SEED_TINY_IMAGE}" = "true" ]; then
  if ! oneimage show "${TINY_IMAGE_NAME}" >/dev/null 2>&1; then
    log "Downloading tiny cloud image: ${TINY_IMAGE_URL}"
    tmp="/tmp/${TINY_IMAGE_NAME}.qcow2"
    if curl -fL --retry 3 -o "${tmp}" "${TINY_IMAGE_URL}"; then
      oneimage create \
        --name "${TINY_IMAGE_NAME}" \
        --datastore default \
        --type OS \
        --persistent \
        "${tmp}" && log "Image ${TINY_IMAGE_NAME} imported" \
        || log "WARN: oneimage create failed"
      rm -f "${tmp}"
    else
      log "WARN: could not download tiny image"
    fi
  fi
fi

log "Seed done"
onevnet list || true
oneimage list || true
