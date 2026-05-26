#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="${HOSTS_FILE:-${SCRIPT_DIR}/hosts.txt}"
if [[ ! -f "${HOSTS_FILE}" && -f "${SCRIPT_DIR}/hosts.example" ]]; then
  HOSTS_FILE="${SCRIPT_DIR}/hosts.example"
fi

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6}"
REMOTE_KEY="${REMOTE_KEY:-~/.ssh/id_rsa}"
SKIP_FIRST_HOST="${SKIP_FIRST_HOST:-1}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./setup_worker_ssh_trust_from_master.sh

Run this on x2-1 only, after x2-1 can already SSH to x2-2/x2-3/x2-4.

Environment:
  HOSTS_FILE       Default: ./hosts.txt, fallback: ./hosts.example
  SSH_USER         Default: ubuntu
  SSH_PORT         Default: 22
  SSH_KEY          Master key used by x2-1 to login workers. Default: ~/.ssh/id_rsa
  REMOTE_KEY       Worker key to create/use on every worker. Default: ~/.ssh/id_rsa
  SKIP_FIRST_HOST  Skip x2-1 / first host. Default: 1

This script configures worker-to-cluster passwordless SSH:
  x2-2 -> x2-1/x2-3/x2-4
  x2-3 -> x2-1/x2-2/x2-4
  x2-4 -> x2-1/x2-2/x2-3
EOF
}

read_hosts() {
  [[ -f "${HOSTS_FILE}" ]] || die "missing hosts file: ${HOSTS_FILE}"
  mapfile -t ALL_HOSTS < <(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print $1 }
  ' "${HOSTS_FILE}")
  [[ "${#ALL_HOSTS[@]}" -gt 1 ]] || die "need at least 2 hosts in ${HOSTS_FILE}"

  if [[ "${SKIP_FIRST_HOST}" == "1" ]]; then
    WORKER_HOSTS=("${ALL_HOSTS[@]:1}")
  else
    WORKER_HOSTS=("${ALL_HOSTS[@]}")
  fi
  [[ "${#WORKER_HOSTS[@]}" -gt 0 ]] || die "no worker hosts found"
}

ssh_target() {
  local host="$1"
  if [[ "${host}" == *@* ]]; then
    printf '%s' "${host}"
  else
    printf '%s@%s' "${SSH_USER}" "${host}"
  fi
}

ssh_run() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" -p "${SSH_PORT}" ${SSH_OPTS} "$(ssh_target "${host}")" "$@"
}

ensure_worker_key() {
  local host="$1"
  log "ensure worker ssh key on ${host}"
  ssh_run "${host}" "bash -lc '
    set -Eeuo pipefail
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if [[ ! -f ${REMOTE_KEY} ]]; then
      ssh-keygen -t rsa -b 4096 -N \"\" -f ${REMOTE_KEY} -C \"ucloud-worker-\$(hostname)-\$(date +%F)\"
    fi
    chmod 600 ${REMOTE_KEY} || true
    chmod 644 ${REMOTE_KEY}.pub || true
    cat ${REMOTE_KEY}.pub
  '"
}

install_pubkey_on_worker() {
  local target_host="$1"
  local pubkey="$2"

  ssh_run "${target_host}" "bash -lc '
    set -Eeuo pipefail
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    tmp=\$(mktemp)
    cat > \"\${tmp}\"
    grep -qxF -f \"\${tmp}\" ~/.ssh/authorized_keys || cat \"\${tmp}\" >> ~/.ssh/authorized_keys
    rm -f \"\${tmp}\"
  '" <<< "${pubkey}"
}

test_worker_to_worker() {
  local from_host="$1"
  local to_host="$2"
  local to_target
  to_target="$(ssh_target "${to_host}")"

  log "test ${from_host} -> ${to_target}"
  ssh_run "${from_host}" "ssh -i ${REMOTE_KEY} -p ${SSH_PORT} -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new ${to_target} 'echo ok \$(hostname)'"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  command -v ssh >/dev/null || die "missing ssh"
  [[ -f "${SSH_KEY}" ]] || die "missing master SSH key: ${SSH_KEY}"
  chmod 600 "${SSH_KEY}" || true

  read_hosts
  log "hosts file: ${HOSTS_FILE}"
  log "worker hosts: ${WORKER_HOSTS[*]}"

  declare -A PUBKEYS
  local host
  for host in "${WORKER_HOSTS[@]}"; do
    PUBKEYS["${host}"]="$(ensure_worker_key "${host}" | tail -n 1)"
  done

  local source_host target_host
  for source_host in "${WORKER_HOSTS[@]}"; do
    for target_host in "${ALL_HOSTS[@]}"; do
      [[ "${source_host}" == "${target_host}" ]] && continue
      log "install ${source_host} public key on ${target_host}"
      install_pubkey_on_worker "${target_host}" "${PUBKEYS[${source_host}]}"
    done
  done

  log "verifying worker-to-cluster SSH"
  for source_host in "${WORKER_HOSTS[@]}"; do
    for target_host in "${ALL_HOSTS[@]}"; do
      [[ "${source_host}" == "${target_host}" ]] && continue
      test_worker_to_worker "${source_host}" "${target_host}"
    done
  done

  log "worker ssh trust setup completed"
}

main "$@"
