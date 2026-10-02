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

# ensure dummy/NAT networks have an address range (lease allocation)
ensure_ar() {
  local vnet="$1" ip="$2" size="$3" gw="$4" mask="$5"
  if onevnet show "${vnet}" >/dev/null 2>&1; then
    if ! onevnet show "${vnet}" --xml 2>/dev/null | grep -q '<AR>'; then
      log "Adding AR to ${vnet}"
      onevnet addar "${vnet}" --ip "${ip}" --size "${size}" --gateway "${gw}" --netmask "${mask}" \
        || log "WARN: addar failed for ${vnet}"
    fi
  fi
}
ensure_ar lab-public 192.168.100.2 200 192.168.100.1 255.255.255.0
ensure_ar lab-nat 10.10.10.2 100 10.10.10.1 255.255.255.0

# --- tiny image (optional) ---------------------------------------------------
# OpenNebula default datastore RESTRICTED_DIRS="/" and SAFE_DIRS="/var/tmp"
# so image sources must live under /var/tmp (not /tmp).
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
