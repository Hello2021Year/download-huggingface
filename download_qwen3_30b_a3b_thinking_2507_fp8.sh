#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-30B-A3B-Thinking-2507-FP8}"
MODEL_NAME="${MODEL_ID##*/}"
MODEL_DIR_BASE="${MODEL_DIR_BASE:-/mnt_upfs/models/qwen3}"
LOCAL_DIR="${LOCAL_DIR:-${MODEL_DIR_BASE}/${MODEL_NAME}}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HFD_SCRIPT="${HFD_SCRIPT:-${PWD}/hfd.sh}"
LOCK_DIR="${LOCK_DIR:-${MODEL_DIR_BASE}/.locks}"
HFD_ARGS="${HFD_ARGS:-}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null || die "missing command: $1"
}

download_hfd() {
  require_cmd wget
  if [[ ! -f "${HFD_SCRIPT}" ]]; then
    log "download hfd.sh from ${HF_ENDPOINT}/hfd/hfd.sh"
    wget -O "${HFD_SCRIPT}" "${HF_ENDPOINT}/hfd/hfd.sh"
    chmod +x "${HFD_SCRIPT}"
  fi
}

acquire_lock() {
  mkdir -p "${LOCK_DIR}"
  local lock_file="${LOCK_DIR}/${MODEL_NAME}.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock_file}"
    flock -n 9 || die "another download is already running: ${lock_file}"
    log "acquired lock ${lock_file}"
  else
    log "WARNING: flock not found; continuing without lock"
  fi
}

main() {
  mkdir -p "${LOCAL_DIR}" "${LOCK_DIR}"
  acquire_lock
  download_hfd

  log "model=${MODEL_ID}"
  log "local_dir=${LOCAL_DIR}"
  log "hf_endpoint=${HF_ENDPOINT}"
  df -h "${MODEL_DIR_BASE}" || true

  args=("${MODEL_ID}" "--local-dir" "${LOCAL_DIR}")
  if [[ -n "${HF_TOKEN:-}" ]]; then
    args+=("--hf_token" "${HF_TOKEN}")
  fi
  if [[ -n "${HFD_ARGS}" ]]; then
    # Intentional word splitting for hfd.sh flags, e.g. "--tool aria2c -x 8".
    extra_args=(${HFD_ARGS})
    args+=("${extra_args[@]}")
  fi

  export HF_ENDPOINT
  bash "${HFD_SCRIPT}" "${args[@]}"

  log "download completed: ${LOCAL_DIR}"
  du -sh "${LOCAL_DIR}" || true
}

main "$@"
