#!/usr/bin/env bash
set -euo pipefail

log() { echo "[one-lab:fe] $*"; }

ONEADMIN_PASSWORD="${ONEADMIN_PASSWORD:-opennebula}"
REGISTER_HOSTS="${REGISTER_HOSTS:-node1}"
SEED_NETWORK="${SEED_NETWORK:-dummy}"          # dummy | nat | none
SEED_TINY_IMAGE="${SEED_TINY_IMAGE:-false}"
ONE_HOME="/var/lib/one"
ONE_SSH="${ONE_HOME}/.ssh"

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
if [ ! -f "${ONE_SSH}/config" ]; then
  cat > "${ONE_SSH}/config" <<EOF
Host *
  IdentityFile ${ONE_SSH}/id_rsa
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${ONE_SSH}/known_hosts
  LogLevel ERROR
EOF
  chown oneadmin:oneadmin "${ONE_SSH}/config"
  chmod 600 "${ONE_SSH}/config"
fi
touch "${ONE_SSH}/known_hosts"
chown oneadmin:oneadmin "${ONE_SSH}/known_hosts"
chmod 600 "${ONE_SSH}/known_hosts"

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
  if curl -sf -o /dev/null -X POST http://127.0.0.1:2633/RPC2 \
      -d '<methodCall><methodName>system.version</methodName></methodCall>'; then
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

# optional services — ignore failures (not critical for lab)
su -s /bin/bash oneadmin -c "onegate start" >/tmp/gate.out 2>/tmp/gate.err || true
su -s /bin/bash oneadmin -c "oneflow start" >/tmp/flow.out 2>/tmp/flow.err \
  || su -s /bin/bash oneadmin -c "opennebula-flow start" >/tmp/flow.out 2>/tmp/flow.err || true

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
if [ "${SEED_NETWORK}" != "none" ] || [ "${SEED_TINY_IMAGE}" = "true" ]; then
  SEED_NETWORK="${SEED_NETWORK}" SEED_TINY_IMAGE="${SEED_TINY_IMAGE}" \
    su -s /bin/bash oneadmin -c "/seed.sh" || log "WARN: seed finished with errors"
fi

log "Lab front-end ready"
log "  XML-RPC : http://localhost:2633/RPC2"
log "  FireEdge: http://localhost:2616  (oneadmin / ${ONEADMIN_PASSWORD})"
log "  one9s   : ONE_AUTH=\"oneadmin:${ONEADMIN_PASSWORD}\" ONE_XMLRPC=\"http://localhost:2633/RPC2\""

# keep container alive; reap stray children; retry late host registration
trap 'log "Shutting down"; su -s /bin/bash oneadmin -c "oned stop" || true; exit 0' SIGTERM SIGINT
while true; do
  # restart oned if it dies (lab resilience)
  if ! curl -sf -o /dev/null -X POST http://127.0.0.1:2633/RPC2 \
      -d '<methodCall><methodName>system.version</methodName></methodCall>' 2>/dev/null; then
    log "oned not responding, restarting"
    su -s /bin/bash oneadmin -c "oned start" || su -s /bin/bash oneadmin -c "oned -f" &
    sleep 5
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
