#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_ID="${MODEL_ID:-${1:-}}"
REVISION="${REVISION:-main}"

# cache: keep the normal Hugging Face snapshot cache layout.
# local: materialize files under MODEL_DIR_BASE/<repo-name>.
DOWNLOAD_TARGET="${DOWNLOAD_TARGET:-cache}"

HF_CACHE_DIR="${HF_CACHE_DIR:-/mnt_upfs/huggingface}"
MODEL_DIR_BASE="${MODEL_DIR_BASE:-/mnt_upfs/models/deepseek-v4}"
LOCK_DIR="${LOCK_DIR:-${HF_CACHE_DIR}/.locks}"
MAX_WORKERS="${MAX_WORKERS:-8}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
DOWNLOAD_BACKEND="${DOWNLOAD_BACKEND:-hf_hub}"
HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"

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
  MODEL_ID=deepseek-ai/DeepSeek-V4-Flash ./download_model.sh
  ./download_model.sh deepseek-ai/DeepSeek-V4-Pro

Wrappers:
  ./download_flash.sh
  ./download_pro.sh

Environment:
  HF_TOKEN                  Hugging Face token. Recommended for large downloads.
  HF_CACHE_DIR              Default: /mnt_upfs/huggingface
  HF_ENDPOINT               Default: https://hf-mirror.com
  DOWNLOAD_BACKEND          hf_hub or hfd. Default: hf_hub
  DOWNLOAD_TARGET           cache or local. Default: cache
  MODEL_DIR_BASE            Used only when DOWNLOAD_TARGET=local. Default: /mnt_upfs/models/deepseek-v4
  REVISION                  Default: main
  MAX_WORKERS               Default: 8
  HF_HUB_ENABLE_HF_TRANSFER Default: 1
  INSTALL_DEPS              Install huggingface_hub/hf_transfer if missing. Default: 1

Notes:
  Run this on one node only when /mnt_upfs is shared by all nodes.
EOF
}

if [[ -z "${MODEL_ID}" || "${MODEL_ID}" == "-h" || "${MODEL_ID}" == "--help" ]]; then
  usage
  exit 0
fi

case "${DOWNLOAD_TARGET}" in
  cache|local) ;;
  *) die "DOWNLOAD_TARGET must be 'cache' or 'local', got '${DOWNLOAD_TARGET}'" ;;
esac

case "${DOWNLOAD_BACKEND}" in
  hf_hub|hfd) ;;
  *) die "DOWNLOAD_BACKEND must be 'hf_hub' or 'hfd', got '${DOWNLOAD_BACKEND}'" ;;
esac

command -v python3 >/dev/null || die "missing python3"

ensure_python_deps() {
  if python3 - <<'PY' >/dev/null 2>&1
import huggingface_hub
PY
  then
    return 0
  fi

  [[ "${INSTALL_DEPS}" == "1" ]] || die "python package huggingface_hub is missing and INSTALL_DEPS=0"
  log "installing Python download dependencies under the current user"
  python3 -m pip install --user -U "huggingface_hub>=0.24.0" hf_transfer
}

safe_name() {
  printf '%s' "$1" | tr '/:' '__'
}

acquire_lock() {
  mkdir -p "${LOCK_DIR}"
  local lock_file="${LOCK_DIR}/$(safe_name "${MODEL_ID}").lock"

  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock_file}"
    flock -n 9 || die "another download is already running for ${MODEL_ID}: ${lock_file}"
    log "acquired lock ${lock_file}"
  else
    log "WARNING: flock is unavailable; continuing without a cross-process lock"
  fi
}

print_disk() {
  mkdir -p "${HF_CACHE_DIR}" "${MODEL_DIR_BASE}"
  log "disk status:"
  df -h "${HF_CACHE_DIR}" "${MODEL_DIR_BASE}" || true
}

download_snapshot() {
  export MODEL_ID REVISION DOWNLOAD_TARGET HF_CACHE_DIR MODEL_DIR_BASE MAX_WORKERS
  export HF_ENDPOINT HF_HUB_ENABLE_HF_TRANSFER

  if [[ -n "${HF_TOKEN:-}" ]]; then
    export HF_TOKEN
    export HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}"
  fi

  python3 - <<'PY'
import os
from pathlib import Path
from huggingface_hub import snapshot_download

model_id = os.environ["MODEL_ID"]
revision = os.environ["REVISION"]
target = os.environ["DOWNLOAD_TARGET"]
cache_dir = Path(os.environ["HF_CACHE_DIR"])
model_dir_base = Path(os.environ["MODEL_DIR_BASE"])
max_workers = int(os.environ["MAX_WORKERS"])
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or None

kwargs = {
    "repo_id": model_id,
    "revision": revision,
    "token": token,
    "max_workers": max_workers,
}

if target == "cache":
    kwargs["cache_dir"] = str(cache_dir)
else:
    local_name = model_id.replace("/", "__")
    local_dir = model_dir_base / local_name
    local_dir.mkdir(parents=True, exist_ok=True)
    kwargs["local_dir"] = str(local_dir)

path = snapshot_download(**kwargs)
print(path)
PY
}

download_hfd() {
  [[ "${DOWNLOAD_TARGET}" == "local" ]] || die "DOWNLOAD_BACKEND=hfd requires DOWNLOAD_TARGET=local"
  command -v wget >/dev/null || die "DOWNLOAD_BACKEND=hfd requires wget"

  export HF_ENDPOINT
  local hfd_path="${SCRIPT_DIR}/hfd.sh"
  local local_name="${MODEL_ID//\//__}"
  local local_dir="${MODEL_DIR_BASE}/${local_name}"
  mkdir -p "${local_dir}"

  if [[ ! -f "${hfd_path}" ]]; then
    log "downloading hfd.sh from ${HF_ENDPOINT}/hfd/hfd.sh"
    wget -O "${hfd_path}" "${HF_ENDPOINT}/hfd/hfd.sh"
    chmod +x "${hfd_path}"
  fi

  local args=("${MODEL_ID}" "--local-dir" "${local_dir}")
  if [[ -n "${HF_TOKEN:-}" ]]; then
    args+=("--hf_token" "${HF_TOKEN}")
  fi

  "${hfd_path}" "${args[@]}"
  printf '%s\n' "${local_dir}"
}

main() {
  log "model=${MODEL_ID}"
  log "revision=${REVISION}"
  log "target=${DOWNLOAD_TARGET}"
  log "backend=${DOWNLOAD_BACKEND}"
  log "hf_endpoint=${HF_ENDPOINT}"
  log "cache=${HF_CACHE_DIR}"
  if [[ "${DOWNLOAD_TARGET}" == "local" ]]; then
    log "local_dir_base=${MODEL_DIR_BASE}"
  fi

  if [[ "${DOWNLOAD_BACKEND}" == "hf_hub" ]]; then
    ensure_python_deps
  fi
  acquire_lock
  print_disk

  log "starting model download"
  if [[ "${DOWNLOAD_BACKEND}" == "hfd" ]]; then
    snapshot_path="$(download_hfd)"
  else
    snapshot_path="$(download_snapshot)"
  fi
  log "download completed"
  log "snapshot path: ${snapshot_path}"
  print_disk
}

main "$@"
