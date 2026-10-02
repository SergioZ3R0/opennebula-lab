#!/usr/bin/env bash
set -euo pipefail

log() { echo "[one-lab:node] $*"; }

ONE_HOME="/var/lib/one"
ONE_SSH="${ONE_HOME}/.ssh"
SETUP_NAT="${SETUP_NAT:-false}"
NAT_BRIDGE="${NAT_BRIDGE:-br0}"
NAT_SUBNET="${NAT_SUBNET:-10.10.10.0/24}"

log "OpenNebula KVM node starting"

# --- oneadmin ----------------------------------------------------------------
if ! id oneadmin >/dev/null 2>&1; then
  useradd --create-home --home-dir "${ONE_HOME}" --shell /bin/bash oneadmin
fi
mkdir -p "${ONE_HOME}" "${ONE_SSH}" /var/log/one
chown -R oneadmin:oneadmin "${ONE_HOME}" /var/log/one

# oneadmin must manage libvirt/qemu
usermod -aG libvirt oneadmin 2>/dev/null || true
usermod -aG kvm oneadmin 2>/dev/null || true
usermod -aG libvirt-qemu oneadmin 2>/dev/null || true

# run qemu processes as oneadmin (package usually does this; enforce for containers)
QEMU_CONF="/etc/libvirt/qemu.conf"
if [ -f "${QEMU_CONF}" ]; then
  if grep -q '^user\s*=' "${QEMU_CONF}"; then
    sed -i 's/^user\s*=.*/user = "oneadmin"/' "${QEMU_CONF}"
  else
    echo 'user = "oneadmin"' >> "${QEMU_CONF}"
  fi
  if grep -q '^group\s*=' "${QEMU_CONF}"; then
    sed -i 's/^group\s*=.*/group = "libvirt"/' "${QEMU_CONF}"
  else
    echo 'group = "libvirt"' >> "${QEMU_CONF}"
  fi
fi

# --- sshd host keys + authorized_keys from shared volume ---------------------
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  log "Generating SSH host keys"
  ssh-keygen -A
fi

log "Waiting for FE public key (shared volume ${ONE_SSH})"
for i in $(seq 1 120); do
  if [ -f "${ONE_SSH}/id_rsa.pub" ]; then
    break
  fi
  sleep 1
  if [ "$i" -eq 120 ]; then
    log "ERROR: ${ONE_SSH}/id_rsa.pub never appeared"
    exit 1
  fi
done

mkdir -p "${ONE_SSH}"
# If the volume is mounted at /var/lib/one/.ssh on both sides, pubkey is already here.
# Ensure authorized_keys contains it (idempotent).
touch "${ONE_SSH}/authorized_keys"
if ! grep -qf "${ONE_SSH}/id_rsa.pub" "${ONE_SSH}/authorized_keys" 2>/dev/null; then
  cat "${ONE_SSH}/id_rsa.pub" >> "${ONE_SSH}/authorized_keys"
fi
# also drop a copy in home in case sshd looks elsewhere
mkdir -p /home/oneadmin/.ssh
touch /home/oneadmin/.ssh/authorized_keys
if ! grep -qf "${ONE_SSH}/id_rsa.pub" /home/oneadmin/.ssh/authorized_keys 2>/dev/null; then
  cat "${ONE_SSH}/id_rsa.pub" >> /home/oneadmin/.ssh/authorized_keys
fi
chmod 700 "${ONE_SSH}" /home/oneadmin/.ssh
chmod 600 "${ONE_SSH}/authorized_keys" /home/oneadmin/.ssh/authorized_keys
chown -R oneadmin:oneadmin "${ONE_SSH}" /home/oneadmin/.ssh
log "oneadmin authorized_keys ready"

# sshd: pubkey only, keep PAM (Debian needs it), tolerate FE retry floods
# MaxStartups format: start:rate:full — rate is a percentage (0-100)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/one-lab.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxStartups 100:30:1000
MaxAuthTries 6
LoginGraceTime 30
EOF
if ! /usr/sbin/sshd -t; then
  log "ERROR: sshd config invalid"
  cat /etc/ssh/sshd_config.d/one-lab.conf
fi

# --- dbus (required for virsh/libvirt qemu:///system in containers) ----------
log "Starting system dbus"
mkdir -p /run/dbus /var/run/dbus
if [ ! -S /var/run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork || log "WARN: dbus-daemon --system failed"
fi
sleep 1

# --- libvirtd ---------------------------------------------------------------
log "Starting libvirtd"
libvirtd -d --listen 2>/dev/null || /usr/sbin/libvirtd -d || {
  # fallback: no daemonize flag on some builds
  /usr/sbin/libvirtd >/tmp/libvirtd.out 2>/tmp/libvirtd.err &
}
sleep 2
# wait until virsh works
for i in $(seq 1 30); do
  if su -s /bin/bash oneadmin -c "virsh list --all" >/dev/null 2>&1; then
    log "libvirt OK"
    break
  fi
  sleep 1
done

# --- optional NAT bridge -----------------------------------------------------
if [ "${SETUP_NAT}" = "true" ]; then
  log "Setting up NAT bridge ${NAT_BRIDGE} (${NAT_SUBNET})"
  if ! ip link show "${NAT_BRIDGE}" >/dev/null 2>&1; then
    ip link add name "${NAT_BRIDGE}" type bridge
  fi
  ip addr replace 10.10.10.1/24 dev "${NAT_BRIDGE}" 2>/dev/null \
    || ip addr replace "${NAT_SUBNET%/*}.1/24" dev "${NAT_BRIDGE}"
  ip link set "${NAT_BRIDGE}" up
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  iptables -t nat -C POSTROUTING -s "${NAT_SUBNET}" ! -d "${NAT_SUBNET}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${NAT_SUBNET}" ! -d "${NAT_SUBNET}" -j MASQUERADE
  iptables -C FORWARD -i "${NAT_BRIDGE}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "${NAT_BRIDGE}" -j ACCEPT
  iptables -C FORWARD -o "${NAT_BRIDGE}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -o "${NAT_BRIDGE}" -j ACCEPT
fi

# --- sshd --------------------------------------------------------------------
log "Starting sshd"
if ! /usr/sbin/sshd; then
  log "ERROR: sshd failed to start (will keep retrying in supervisor loop)"
fi

# --- stay up -----------------------------------------------------------------
log "Node ready (hostname=$(hostname))"
trap 'log "Shutting down"; pkill libvirtd 2>/dev/null; pkill sshd 2>/dev/null; exit 0' SIGTERM SIGINT
while true; do
  if ! pgrep -x libvirtd >/dev/null 2>&1; then
    log "libvirtd died, restarting"
    libvirtd -d 2>/dev/null || /usr/sbin/libvirtd >/tmp/libvirtd.out 2>/tmp/libvirtd.err &
    sleep 2
  fi
  if ! pgrep -x sshd >/dev/null 2>&1; then
    log "sshd died, restarting"
    /usr/sbin/sshd || true
  fi
  sleep 10
done
