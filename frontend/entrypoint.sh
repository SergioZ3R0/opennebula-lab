#!/usr/bin/env bash
set -euo pipefail

log() { echo "[one-lab:fe] $*"; }

ONEADMIN_PASSWORD="${ONEADMIN_PASSWORD:-opennebula}"
REGISTER_HOSTS="${REGISTER_HOSTS:-node1}"
SEED_NETWORK="${SEED_NETWORK:-nat}"          # dummy | nat | none
SEED_UBUNTU_IMAGE="${SEED_UBUNTU_IMAGE:-true}"
SEED_TINY_IMAGE="${SEED_TINY_IMAGE:-false}"
ONE_HOME="/var/lib/one"
ONE_SSH="${ONE_HOME}/.ssh"
ONE_AUTH_SESSION="oneadmin:${ONEADMIN_PASSWORD}"

xmlrpc_ok() {
  # OpenNebula 7.x XML-RPC: one.system.version with session string
  curl -sf -X POST http://127.0.0.1:2633/RPC2 \
    -d "<?xml version=\"1.0\"?><methodCall><methodName>one.system.version</methodName><params><param><value><string>${ONE_AUTH_SESSION}</string></value></param></params></methodCall>" \
    2>/dev/null | grep -q '<boolean>1</boolean>'
}

log "OpenNebula ${ONE_VERSION:-?} front-end starting"

# --- oneadmin user / home ---------------------------------------------------
if ! id oneadmin >/dev/null 2>&1; then
  useradd --create-home --home-dir "${ONE_HOME}" --shell /bin/bash oneadmin
fi
mkdir -p "${ONE_HOME}" "${ONE_SSH}" "${ONE_HOME}/.one" \
         /var/log/one /var/lib/one/datastores /var/lib/one/remotes \
         /var/lock/one /run/one /run/sshd
chown -R oneadmin:oneadmin "${ONE_HOME}" /var/log/one /var/lock/one /run/one

# stale locks/pids from a previous container process block oned on restart
rm -f /var/lock/one/one /run/one/oned.pid /var/run/one/oned.pid \
      /var/lib/one/.one/monitord.pid 2>/dev/null || true

# --- oneadmin credentials ----------------------------------------------------
echo "oneadmin:${ONEADMIN_PASSWORD}" > "${ONE_HOME}/.one/one_auth"
chown oneadmin:oneadmin "${ONE_HOME}/.one/one_auth"
chmod 600 "${ONE_HOME}/.one/one_auth"

# --- SSH keypair (shared volume: node will pick it up) -----------------------
if [ ! -f "${ONE_SSH}/id_rsa" ]; then
  log "Generating oneadmin SSH keypair"
  su -s /bin/bash oneadmin -c "ssh-keygen -t rsa -b 2048 -N '' -f ${ONE_SSH}/id_rsa"
fi
chmod 700 "${ONE_SSH}"
chmod 600 "${ONE_SSH}/id_rsa" 2>/dev/null || true
chmod 644 "${ONE_SSH}/id_rsa.pub" 2>/dev/null || true
chown -R oneadmin:oneadmin "${ONE_SSH}"

# OpenNebula ships a friendly ssh_config for oneadmin
# Lab containers regenerate host keys on recreate — be permissive
# NAT/dummy guest IPs live on the KVM node bridges, not on the FE network:
# onevm ssh and guest access must ProxyJump via the compute node.
cat > "${ONE_SSH}/config" <<EOF
Host *
  IdentityFile ${ONE_SSH}/id_rsa
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ControlMaster auto
  ControlPath ${ONE_SSH}/cm-%r@%h:%p
  ControlPersist 5m

# lab guest subnets (br0 NAT + dummy public) are only routed on the node
Host 10.10.10.* 192.168.100.*
  ProxyJump oneadmin@node1
EOF
chown oneadmin:oneadmin "${ONE_SSH}/config"
chmod 600 "${ONE_SSH}/config"
# drop stale known_hosts (host keys change when containers are recreated)
rm -f "${ONE_SSH}/known_hosts"
touch "${ONE_SSH}/known_hosts"
chown oneadmin:oneadmin "${ONE_SSH}/known_hosts"
chmod 600 "${ONE_SSH}/known_hosts"

# --- sshd (required: node pulls qcow2 disks from FE via ssh) ------------------
log "Starting sshd on front-end"
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -A
fi
mkdir -p /run/sshd
# accept the shared oneadmin pubkey (node also writes it into the same volume)
if [ -f "${ONE_SSH}/id_rsa.pub" ]; then
  touch "${ONE_SSH}/authorized_keys"
  if ! grep -qf "${ONE_SSH}/id_rsa.pub" "${ONE_SSH}/authorized_keys" 2>/dev/null; then
    cat "${ONE_SSH}/id_rsa.pub" >> "${ONE_SSH}/authorized_keys"
  fi
  chown oneadmin:oneadmin "${ONE_SSH}/authorized_keys"
  chmod 600 "${ONE_SSH}/authorized_keys"
fi
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/one-lab.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxStartups 100:30:1000
EOF
/usr/sbin/sshd || log "WARN: sshd failed to start"

# --- database migrate (quiet; oned also bootstraps on first start) ----------
if command -v onedb >/dev/null 2>&1; then
  log "Checking database state"
  if su -s /bin/bash oneadmin -c "onedb version" >/tmp/onedb.ver 2>/dev/null; then
    log "onedb version: $(tr -d '\n' </tmp/onedb.ver)"
  fi
fi

# --- start services (no systemd) --------------------------------------------
log "Starting oned"
su -s /bin/bash oneadmin -c "oned start" >/tmp/oned.out 2>/tmp/oned.err || {
  log "oned start failed: $(tr '\n' ' ' </tmp/oned.err)"
  # clear locks again and try foreground
  rm -f /var/lock/one/one /run/one/oned.pid 2>/dev/null || true
  su -s /bin/bash oneadmin -c "oned -f" >/tmp/oned.out 2>/tmp/oned.err &
}

# wait until XML-RPC answers
log "Waiting for oned XML-RPC on :2633"
for i in $(seq 1 90); do
  if xmlrpc_ok; then
    log "oned is up"
    break
  fi
  sleep 1
  if [ "$i" -eq 90 ]; then
    log "ERROR: oned did not become ready"
    tail -n 50 /tmp/oned.err /var/log/one/oned.log 2>/dev/null || true
    exit 1
  fi
done

# scheduler runs inside oned as MAD (one_sched) in OpenNebula 7.x — no separate daemon
log "Scheduler is managed by oned (SCHED_MAD=one_sched)"

# --- onegate / oneflow (needed for services, context, multi-tier labs) -------
# Debian packages do not ship /usr/bin wrappers for gate; start via ruby/oneflow-server.
if [ -f /etc/one/onegate-server.conf ]; then
  # listen on all interfaces so guests can reach onegate once routing exists
  sed -i 's/:bind: 127.0.0.1/:bind: 0.0.0.0/' /etc/one/onegate-server.conf || true
fi
if [ -f /etc/one/oneflow-server.conf ]; then
  sed -i 's/:host: 127.0.0.1/:host: 0.0.0.0/' /etc/one/oneflow-server.conf || true
fi

log "Starting oneflow"
if command -v oneflow-server >/dev/null 2>&1; then
  su -s /bin/bash oneadmin -c "oneflow-server start" >/tmp/flow.out 2>/tmp/flow.err \
    || log "WARN: oneflow-server start failed: $(tr '\n' ' ' </tmp/flow.err 2>/dev/null)"
else
  log "WARN: oneflow-server binary not found"
fi

log "Starting onegate"
if [ -f /usr/lib/one/onegate/onegate-server.rb ]; then
  su -s /bin/bash oneadmin -c \
    "nohup ruby /usr/lib/one/onegate/onegate-server.rb >>/var/log/one/onegate.log 2>&1 &" \
    >/tmp/gate.out 2>/tmp/gate.err \
    || log "WARN: onegate start failed: $(tr '\n' ' ' </tmp/gate.err 2>/dev/null)"
else
  log "WARN: onegate-server.rb not found"
fi
sleep 2

# --- guacd (FireEdge Guacamole proxy: browser VNC/SSH/RDP consoles) ----------
# Official path is FireEdge + guacd; without it console features are dead.
# Package env: /etc/one/guacd -> OPTS="-b 0.0.0.0"
# Binary: /usr/share/one/guacd/sbin/guacd  (needs LD_LIBRARY_PATH)
log "Starting guacd"
GUACD_BIN="/usr/share/one/guacd/sbin/guacd"
GUACD_LIB="/usr/share/one/guacd/lib"
GUACD_OPTS="-b 0.0.0.0"
if [ -f /etc/one/guacd ]; then
  # shellcheck disable=SC1091
  OPTS=""
  # shellcheck source=/dev/null
  . /etc/one/guacd || true
  if [ -n "${OPTS:-}" ]; then
    GUACD_OPTS="${OPTS}"
  fi
fi
if [ -x "${GUACD_BIN}" ]; then
  su -s /bin/bash oneadmin -c \
    "HOME=/var/lib/one LD_LIBRARY_PATH=${GUACD_LIB} nohup ${GUACD_BIN} -f ${GUACD_OPTS} >>/var/log/one/guacd.log 2>&1 &" \
    || log "WARN: guacd start failed"
  for i in $(seq 1 15); do
    if ss -tln 2>/dev/null | grep -q ':4822'; then
      log "guacd is up on :4822"
      break
    fi
    sleep 1
  done
  ss -tln 2>/dev/null | grep -q ':4822' || {
    log "WARN: guacd not listening on :4822"
    tail -n 20 /var/log/one/guacd.log 2>/dev/null || true
  }
else
  log "WARN: guacd binary not found (${GUACD_BIN})"
fi

# --- FireEdge ----------------------------------------------------------------
log "Starting FireEdge"
# sunstone_auth is created by oned; fireedge-server is the official launcher
if su -s /bin/bash oneadmin -c "fireedge-server start"; then
  log "fireedge-server start OK"
else
  log "WARN: fireedge-server start failed, trying node directly"
  su -s /bin/bash oneadmin -c "node /usr/lib/one/fireedge/dist/index.js" \
    >/tmp/fireedge.out 2>/tmp/fireedge.err &
fi
for i in $(seq 1 45); do
  if curl -sf -o /dev/null http://127.0.0.1:2616/ 2>/dev/null \
     || curl -sf -o /dev/null http://127.0.0.1:2616/fireedge 2>/dev/null \
     || (echo >/dev/tcp/127.0.0.1/2616) 2>/dev/null; then
    log "FireEdge is up on :2616"
    break
  fi
  sleep 1
done

# --- wait for compute nodes (SSH) and register them --------------------------
log "Registering hosts: ${REGISTER_HOSTS}"
su -s /bin/bash oneadmin -c "onehost list" || true

wait_ssh() {
  local host="$1"
  log "Waiting for SSH on ${host} as oneadmin"
  # populate known_hosts once, then batch-mode probe
  su -s /bin/bash oneadmin -c "ssh-keyscan -H -T 3 ${host} >> ${ONE_SSH}/known_hosts" 2>/dev/null || true
  for i in $(seq 1 60); do
    if su -s /bin/bash oneadmin -c "ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new oneadmin@${host} true" 2>/dev/null; then
      log "SSH to ${host} OK"
      return 0
    fi
    sleep 2
  done
  log "ERROR: SSH to ${host} never succeeded"
  return 1
}

register_host() {
  local host="$1"
  if su -s /bin/bash oneadmin -c "onehost show ${host}" >/dev/null 2>&1; then
    log "Host ${host} already registered"
  else
    su -s /bin/bash oneadmin -c "onehost create ${host} -i kvm -v kvm"
    log "Host ${host} registered"
  fi
  # ensure remotes are on the node (IM probes need them + ruby)
  log "Syncing remotes to ${host}"
  su -s /bin/bash oneadmin -c "rsync -a -e ssh /var/lib/one/remotes/ ${host}:/var/lib/one/remotes/" \
    || log "WARN: remotes rsync to ${host} failed"
  log "Waiting for host ${host} ON"
  for i in $(seq 1 90); do
    local stat
    stat=$(su -s /bin/bash oneadmin -c "onehost list --csv" 2>/dev/null \
      | awk -F, -v h="${host}" '$2==h {print toupper($NF)}' | tr -d '"')
    if [ "${stat}" = "ON" ]; then
      log "Host ${host} is ON"
      return 0
    fi
    sleep 2
  done
  log "WARN: host ${host} did not reach ON (state=${stat:-?}); check oned.log"
  su -s /bin/bash oneadmin -c "onehost list" || true
  su -s /bin/bash oneadmin -c "onehost show ${host}" 2>/dev/null | grep -A2 ERROR || true
  return 1
}

for host in ${REGISTER_HOSTS}; do
  if wait_ssh "${host}"; then
    register_host "${host}" || true
  else
    log "WARN: skipping registration for ${host}"
  fi
done

# --- seed --------------------------------------------------------------------
if [ "${SEED_NETWORK}" != "none" ] || [ "${SEED_UBUNTU_IMAGE}" = "true" ] || [ "${SEED_TINY_IMAGE}" = "true" ]; then
  SEED_NETWORK="${SEED_NETWORK}" \
  SEED_UBUNTU_IMAGE="${SEED_UBUNTU_IMAGE}" \
  SEED_TINY_IMAGE="${SEED_TINY_IMAGE}" \
  UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-}" \
  UBUNTU_IMAGE_NAME="${UBUNTU_IMAGE_NAME:-}" \
  UBUNTU_TEMPLATE_NAME="${UBUNTU_TEMPLATE_NAME:-}" \
  UBUNTU_VCPU="${UBUNTU_VCPU:-}" \
  UBUNTU_MEMORY="${UBUNTU_MEMORY:-}" \
  TINY_IMAGE_URL="${TINY_IMAGE_URL:-}" \
  TINY_IMAGE_NAME="${TINY_IMAGE_NAME:-}" \
    su -s /bin/bash oneadmin -c "/seed.sh" || log "WARN: seed finished with errors"
fi

log "Lab front-end ready"
log "  XML-RPC : http://localhost:2633/RPC2"
log "  FireEdge: http://localhost:2616  (oneadmin / ${ONEADMIN_PASSWORD})"
log "  onegate : http://localhost:5030   (guest context API)"
log "  oneflow : http://localhost:2474   (services)"
log "  one9s   : ONE_AUTH=\"oneadmin:${ONEADMIN_PASSWORD}\" ONE_XMLRPC=\"http://localhost:2633/RPC2\""
log "  First boot with SEED_UBUNTU_IMAGE=true downloads ~600MB into the default datastore"

# keep container alive; reap stray children; retry late host registration
trap 'log "Shutting down"; su -s /bin/bash oneadmin -c "oned stop" || true; exit 0' SIGTERM SIGINT
while true; do
  # restart oned if it dies (lab resilience)
  if ! xmlrpc_ok; then
    log "oned not responding, restarting"
    su -s /bin/bash oneadmin -c "oned start" || su -s /bin/bash oneadmin -c "oned -f" &
    sleep 5
  fi
  if ! pgrep -x sshd >/dev/null 2>&1; then
    log "fe sshd died, restarting"
    /usr/sbin/sshd || true
  fi
  if ! pgrep -f "puma.*2474" >/dev/null 2>&1 && ! pgrep -f oneflow-server >/dev/null 2>&1; then
    log "oneflow died, restarting"
    su -s /bin/bash oneadmin -c "oneflow-server start" || true
  fi
  if ! pgrep -f "puma.*5030" >/dev/null 2>&1 && ! pgrep -f onegate-server >/dev/null 2>&1; then
    log "onegate died, restarting"
    su -s /bin/bash oneadmin -c \
      "nohup ruby /usr/lib/one/onegate/onegate-server.rb >>/var/log/one/onegate.log 2>&1 &" || true
  fi
  if ! pgrep -f guacd >/dev/null 2>&1; then
    log "guacd died, restarting"
    su -s /bin/bash oneadmin -c \
      "HOME=/var/lib/one LD_LIBRARY_PATH=/usr/share/one/guacd/lib nohup /usr/share/one/guacd/sbin/guacd -f -b 0.0.0.0 >>/var/log/one/guacd.log 2>&1 &" || true
  fi
  # retry host registration / recovery if any REGISTER_HOSTS are missing or not ON
  for host in ${REGISTER_HOSTS}; do
    stat=$(su -s /bin/bash oneadmin -c "onehost list --csv" 2>/dev/null \
      | awk -F, -v h="${host}" '$2==h {print toupper($NF)}' | tr -d '"')
    if [ -z "${stat}" ]; then
      if su -s /bin/bash oneadmin -c "ssh -o BatchMode=yes -o ConnectTimeout=3 oneadmin@${host} true" 2>/dev/null; then
        log "Late registration for ${host}"
        su -s /bin/bash oneadmin -c "onehost create ${host} -i kvm -v kvm" || true
        su -s /bin/bash oneadmin -c "rsync -a -e ssh /var/lib/one/remotes/ ${host}:/var/lib/one/remotes/" || true
      fi
    elif [ "${stat}" = "ERR" ] || [ "${stat}" = "ERROR" ]; then
      log "Host ${host} in ERROR — resync remotes and re-enable"
      su -s /bin/bash oneadmin -c "rsync -a -e ssh /var/lib/one/remotes/ ${host}:/var/lib/one/remotes/" || true
      su -s /bin/bash oneadmin -c "onehost enable ${host}" || true
    elif [ "${stat}" != "ON" ]; then
      log "Host ${host} state=${stat}"
    fi
  done
  sleep 15
done
