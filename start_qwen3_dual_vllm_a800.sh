#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_BASE_DIR="${MODEL_BASE_DIR:-/mnt_upfs/models/qwen3}"
LARGE_MODEL_DIR_NAME="${LARGE_MODEL_DIR_NAME:-Qwen3-235B-A22B-Thinking-2507-FP8}"
SMALL_MODEL_DIR_NAME="${SMALL_MODEL_DIR_NAME:-Qwen3-30B-A3B-Thinking-2507-FP8}"

LARGE_GPUS="${LARGE_GPUS:-0,1,2,3}"
SMALL_GPUS="${SMALL_GPUS:-4,5,6,7}"

LARGE_PORT="${LARGE_PORT:-8000}"
SMALL_PORT="${SMALL_PORT:-8001}"
HOST="${HOST:-0.0.0.0}"

LARGE_TP_SIZE="${LARGE_TP_SIZE:-}"
SMALL_TP_SIZE="${SMALL_TP_SIZE:-}"
LARGE_PP_SIZE="${LARGE_PP_SIZE:-1}"
SMALL_PP_SIZE="${SMALL_PP_SIZE:-1}"
LARGE_MAX_MODEL_LEN="${LARGE_MAX_MODEL_LEN:-131072}"
SMALL_MAX_MODEL_LEN="${SMALL_MAX_MODEL_LEN:-32768}"
LARGE_MAX_NUM_SEQS="${LARGE_MAX_NUM_SEQS:-1}"
SMALL_MAX_NUM_SEQS="${SMALL_MAX_NUM_SEQS:-16}"
LARGE_GPU_MEMORY_UTILIZATION="${LARGE_GPU_MEMORY_UTILIZATION:-0.88}"
SMALL_GPU_MEMORY_UTILIZATION="${SMALL_GPU_MEMORY_UTILIZATION:-0.88}"

LARGE_CONTAINER_NAME="${LARGE_CONTAINER_NAME:-qwen3-large-vllm}"
SMALL_CONTAINER_NAME="${SMALL_CONTAINER_NAME:-qwen3-30b-vllm}"
LARGE_SERVED_MODEL_NAME="${LARGE_SERVED_MODEL_NAME:-qwen300b}"
SMALL_SERVED_MODEL_NAME="${SMALL_SERVED_MODEL_NAME:-qwen30b}"

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.11.0}"
DOCKER_MIRROR_PREFIX="${DOCKER_MIRROR_PREFIX:-docker.m.daocloud.io}"
PULL_IMAGE="${PULL_IMAGE:-auto}" # auto, 1, or 0
STOP_EXISTING="${STOP_EXISTING:-1}"
RUN_GPU_TEST="${RUN_GPU_TEST:-1}"
WAIT_READY="${WAIT_READY:-1}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-3600}"
READY_CHECK_INTERVAL="${READY_CHECK_INTERVAL:-10}"
START_GAP_SECONDS="${START_GAP_SECONDS:-20}"
SHM_SIZE="${SHM_SIZE:-64g}"
CACHE_DIR="${CACHE_DIR:-/mnt_upfs/vllm-cache}"
ENABLE_REASONING="${ENABLE_REASONING:-1}"
REASONING_PARSER="${REASONING_PARSER:-deepseek_r1}" # set empty to disable
ENABLE_EXPERT_PARALLEL="${ENABLE_EXPERT_PARALLEL:-1}"

LARGE_EXTRA_VLLM_ARGS="${LARGE_EXTRA_VLLM_ARGS:-}"
SMALL_EXTRA_VLLM_ARGS="${SMALL_EXTRA_VLLM_ARGS:-}"

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
  ./start_qwen3_dual_vllm_a800.sh

Default:
  Start two isolated vLLM Docker containers on one 8 x A800 80G host:
    - GPUs 0,1,2,3 -> Qwen large model, port 8000, tensor parallel 4
    - GPUs 4,5,6,7 -> Qwen 30B model,   port 8001, tensor parallel 4

Common overrides:
  MODEL_BASE_DIR=/mnt_upfs/models/qwen3
  LARGE_MODEL_DIR_NAME=Qwen3-235B-A22B-Thinking-2507-FP8
  SMALL_MODEL_DIR_NAME=Qwen3-30B-A3B-Thinking-2507-FP8

  LARGE_GPUS=0,1,2,3
  SMALL_GPUS=4,5,6,7
  LARGE_TP_SIZE=4
  SMALL_TP_SIZE=4
  LARGE_PP_SIZE=1
  SMALL_PP_SIZE=1

  LARGE_MAX_MODEL_LEN=131072
  SMALL_MAX_MODEL_LEN=32768
  LARGE_MAX_NUM_SEQS=1
  SMALL_MAX_NUM_SEQS=16

  LARGE_GPU_MEMORY_UTILIZATION=0.88
  SMALL_GPU_MEMORY_UTILIZATION=0.88

  VLLM_IMAGE=vllm/vllm-openai:v0.11.0
  PULL_IMAGE=auto
  ENABLE_REASONING=1
  REASONING_PARSER=deepseek_r1

Examples:
  ./start_qwen3_dual_vllm_a800.sh

  # If the large model OOMs, retry with a shorter context first.
  LARGE_MAX_MODEL_LEN=65536 ./start_qwen3_dual_vllm_a800.sh

  # Give 30B only two GPUs and leave 6,7 for another worker or experiments.
  SMALL_GPUS=4,5 SMALL_TP_SIZE=2 ./start_qwen3_dual_vllm_a800.sh

  # Use 6 GPUs for the large model and 2 GPUs for 30B.
  LARGE_GPUS=0,1,2,3,4,5 LARGE_TP_SIZE=2 LARGE_PP_SIZE=3 \
  SMALL_GPUS=6,7 SMALL_TP_SIZE=2 SMALL_PP_SIZE=1 \
    ./start_qwen3_dual_vllm_a800.sh

  # Try 7 GPUs for the large model and 1 GPU for 30B. Lower throughput is expected.
  LARGE_GPUS=0,1,2,3,4,5,6 LARGE_TP_SIZE=1 LARGE_PP_SIZE=7 \
  SMALL_GPUS=7 SMALL_TP_SIZE=1 SMALL_PP_SIZE=1 SMALL_MAX_MODEL_LEN=16384 SMALL_MAX_NUM_SEQS=4 \
    ./start_qwen3_dual_vllm_a800.sh

After start:
  docker logs -f qwen3-large-vllm
  docker logs -f qwen3-30b-vllm
  curl -s http://127.0.0.1:8000/v1/models
  curl -s http://127.0.0.1:8001/v1/models
EOF
}

csv_count() {
  local csv="$1"
  awk -F',' '{ print NF }' <<<"${csv}"
}

ensure_world_size_matches_gpus() {
  local role="$1"
  local gpus="$2"
  local tp_size="$3"
  local pp_size="$4"
  local gpu_count
  local world_size
  gpu_count="$(csv_count "${gpus}")"
  world_size=$((tp_size * pp_size))

  [[ "${world_size}" -eq "${gpu_count}" ]] || {
    die "${role}: TP_SIZE * PP_SIZE must equal selected GPU count; got TP=${tp_size}, PP=${pp_size}, GPUs=${gpus} (${gpu_count} GPUs)"
  }
}

csv_to_lines() {
  tr ',' '\n' <<<"$1" | awk 'NF { gsub(/[[:space:]]/, ""); print }'
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

image_with_mirror() {
  local image="$1"
  local prefix="$2"

  if [[ -z "${prefix}" ]]; then
    printf '%s' "${image}"
    return
  fi

  case "${image}" in
    docker.io/*)
      printf '%s/%s' "${prefix}" "${image#docker.io/}"
      ;;
    registry-1.docker.io/*)
      printf '%s/%s' "${prefix}" "${image#registry-1.docker.io/}"
      ;;
    */*/*)
      printf '%s' "${image}"
      ;;
    *)
      printf '%s/%s' "${prefix}" "${image}"
      ;;
  esac
}

check_no_gpu_overlap() {
  local large="$1"
  local small="$2"
  local overlap
  overlap="$(
    comm -12 \
      <(csv_to_lines "${large}" | sort -n) \
      <(csv_to_lines "${small}" | sort -n) || true
  )"
  [[ -z "${overlap}" ]] || die "GPU lists overlap: ${overlap//$'\n'/,}"
}

check_gpu_ids_exist() {
  local requested="$1"
  local gpu
  local available
  available="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | awk '{ print $1 }')"
  while IFS= read -r gpu; do
    grep -qxF "${gpu}" <<<"${available}" || die "GPU ${gpu} does not exist; available GPUs: ${available//$'\n'/,}"
  done < <(csv_to_lines "${requested}")
}

check_local_requirements() {
  command -v docker >/dev/null 2>&1 || die "missing docker"
  command -v nvidia-smi >/dev/null 2>&1 || die "missing nvidia-smi"
  command -v curl >/dev/null 2>&1 || die "missing curl"

  LARGE_TP_SIZE="${LARGE_TP_SIZE:-$(csv_count "${LARGE_GPUS}")}"
  SMALL_TP_SIZE="${SMALL_TP_SIZE:-$(csv_count "${SMALL_GPUS}")}"

  check_no_gpu_overlap "${LARGE_GPUS}" "${SMALL_GPUS}"
  check_gpu_ids_exist "${LARGE_GPUS}"
  check_gpu_ids_exist "${SMALL_GPUS}"
  ensure_world_size_matches_gpus "large model" "${LARGE_GPUS}" "${LARGE_TP_SIZE}" "${LARGE_PP_SIZE}"
  ensure_world_size_matches_gpus "30B model" "${SMALL_GPUS}" "${SMALL_TP_SIZE}" "${SMALL_PP_SIZE}"

  LARGE_MODEL_PATH_HOST="${LARGE_MODEL_PATH_HOST:-${MODEL_BASE_DIR}/${LARGE_MODEL_DIR_NAME}}"
  SMALL_MODEL_PATH_HOST="${SMALL_MODEL_PATH_HOST:-${MODEL_BASE_DIR}/${SMALL_MODEL_DIR_NAME}}"
  LARGE_MODEL_PATH_CONTAINER="${LARGE_MODEL_PATH_CONTAINER:-/models/${LARGE_MODEL_DIR_NAME}}"
  SMALL_MODEL_PATH_CONTAINER="${SMALL_MODEL_PATH_CONTAINER:-/models/${SMALL_MODEL_DIR_NAME}}"

  [[ -d "${LARGE_MODEL_PATH_HOST}" ]] || die "missing large model directory: ${LARGE_MODEL_PATH_HOST}"
  [[ -f "${LARGE_MODEL_PATH_HOST}/config.json" ]] || die "missing large model config.json: ${LARGE_MODEL_PATH_HOST}"
  [[ -d "${SMALL_MODEL_PATH_HOST}" ]] || die "missing 30B model directory: ${SMALL_MODEL_PATH_HOST}"
  [[ -f "${SMALL_MODEL_PATH_HOST}/config.json" ]] || die "missing 30B model config.json: ${SMALL_MODEL_PATH_HOST}"

  mkdir -p "${CACHE_DIR}/${LARGE_CONTAINER_NAME}" "${CACHE_DIR}/${SMALL_CONTAINER_NAME}"

  log "GPU summary:"
  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader || nvidia-smi -L
  log "large model path: ${LARGE_MODEL_PATH_HOST}"
  du -sh "${LARGE_MODEL_PATH_HOST}" || true
  log "30B model path: ${SMALL_MODEL_PATH_HOST}"
  du -sh "${SMALL_MODEL_PATH_HOST}" || true
}

pull_vllm_image() {
  local pull_image
  pull_image="$(image_with_mirror "${VLLM_IMAGE}" "${DOCKER_MIRROR_PREFIX}")"

  if docker_cmd image inspect "${VLLM_IMAGE}" >/dev/null 2>&1; then
    log "use local vLLM image: ${VLLM_IMAGE}"
    return
  fi

  if [[ "${pull_image}" != "${VLLM_IMAGE}" ]] && docker_cmd image inspect "${pull_image}" >/dev/null 2>&1; then
    log "use local mirrored vLLM image: ${pull_image}"
    docker_cmd tag "${pull_image}" "${VLLM_IMAGE}"
    return
  fi

  case "${PULL_IMAGE}" in
    0|false|FALSE|no|NO)
      die "vLLM image is missing locally and PULL_IMAGE=${PULL_IMAGE}: ${VLLM_IMAGE}"
      ;;
    1|true|TRUE|yes|YES|auto)
      ;;
    *)
      die "PULL_IMAGE must be auto, 1, or 0; got ${PULL_IMAGE}"
      ;;
  esac

  log "pull vLLM image: ${pull_image}"
  docker_cmd pull "${pull_image}"
  if [[ "${pull_image}" != "${VLLM_IMAGE}" ]]; then
    docker_cmd tag "${pull_image}" "${VLLM_IMAGE}"
  fi
}

stop_existing_containers() {
  [[ "${STOP_EXISTING}" == "1" ]] || return

  local name
  for name in "${LARGE_CONTAINER_NAME}" "${SMALL_CONTAINER_NAME}"; do
    if docker_cmd ps -aq --filter "name=^/${name}$" | grep -q .; then
      log "remove existing container: ${name}"
      docker_cmd rm -f "${name}"
    fi
  done
}

run_gpu_test() {
  [[ "${RUN_GPU_TEST}" == "1" ]] || return
  log "Docker GPU smoke test"
  docker_cmd run --rm --gpus "device=${LARGE_GPUS}" --ipc=host --entrypoint /bin/bash "${VLLM_IMAGE}" -lc 'nvidia-smi -L && python3 - <<PY
import importlib.metadata
print("vllm", importlib.metadata.version("vllm"))
PY'
}

append_common_args() {
  local -n out_args="$1"

  if [[ "${ENABLE_EXPERT_PARALLEL}" == "1" ]]; then
    out_args+=(--enable-expert-parallel)
  fi

  if [[ "${ENABLE_REASONING}" == "1" ]]; then
    out_args+=(--enable-reasoning)
  fi

  if [[ -n "${REASONING_PARSER}" ]]; then
    out_args+=(--reasoning-parser "${REASONING_PARSER}")
  fi
}

start_one_vllm() {
  local role="$1"
  local container_name="$2"
  local model_path_host="$3"
  local model_path_container="$4"
  local served_model_name="$5"
  local port="$6"
  local gpus="$7"
  local tp_size="$8"
  local pp_size="$9"
  local max_model_len="${10}"
  local max_num_seqs="${11}"
  local gpu_memory_utilization="${12}"
  local extra_vllm_args="${13}"

  local -a args=(
    --model "${model_path_container}"
    --served-model-name "${served_model_name}"
    --host "${HOST}"
    --port "${port}"
    --tensor-parallel-size "${tp_size}"
    --pipeline-parallel-size "${pp_size}"
    --max-model-len "${max_model_len}"
    --gpu-memory-utilization "${gpu_memory_utilization}"
    --max-num-seqs "${max_num_seqs}"
  )

  append_common_args args

  if [[ -n "${extra_vllm_args}" ]]; then
    # Intentional word splitting for CLI flags.
    # shellcheck disable=SC2206
    local extra_args=(${extra_vllm_args})
    args+=("${extra_args[@]}")
  fi

  log "start ${role}: container=${container_name} gpus=${gpus} tp=${tp_size} pp=${pp_size} port=${port}"
  docker_cmd run -d \
    --name "${container_name}" \
    --network host \
    --gpus "device=${gpus}" \
    --ipc=host \
    --shm-size "${SHM_SIZE}" \
    -v "${model_path_host}:${model_path_container}:ro" \
    -v "${CACHE_DIR}/${container_name}:/root/.cache/vllm" \
    "${VLLM_IMAGE}" \
    "${args[@]}"
}

wait_ready() {
  local name="$1"
  local port="$2"
  local url="http://127.0.0.1:${port}/v1/models"
  local start_ts
  start_ts="$(date +%s)"

  log "wait for ${name}: ${url}"
  while true; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      log "${name} is ready"
      return
    fi

    if ! docker_cmd ps --format '{{.Names}}' | grep -qxF "${name}"; then
      log "${name} exited; recent logs:"
      docker_cmd logs --tail 80 "${name}" || true
      die "${name} is not running"
    fi

    if (( "$(date +%s)" - start_ts > READY_TIMEOUT_SECONDS )); then
      log "${name} is not ready before timeout; recent logs:"
      docker_cmd logs --tail 80 "${name}" || true
      die "ready timeout for ${name}"
    fi

    sleep "${READY_CHECK_INTERVAL}"
  done
}

print_summary() {
  cat <<EOF

Started dual vLLM containers:
  large: ${LARGE_CONTAINER_NAME}
    GPUs: ${LARGE_GPUS}
    TP/PP: ${LARGE_TP_SIZE}/${LARGE_PP_SIZE}
    port: ${LARGE_PORT}
    model: ${LARGE_SERVED_MODEL_NAME}
    path: ${LARGE_MODEL_PATH_HOST}

  30B: ${SMALL_CONTAINER_NAME}
    GPUs: ${SMALL_GPUS}
    TP/PP: ${SMALL_TP_SIZE}/${SMALL_PP_SIZE}
    port: ${SMALL_PORT}
    model: ${SMALL_SERVED_MODEL_NAME}
    path: ${SMALL_MODEL_PATH_HOST}

Check:
  docker ps --filter name=qwen3
  docker logs -f ${LARGE_CONTAINER_NAME}
  docker logs -f ${SMALL_CONTAINER_NAME}
  curl -s http://127.0.0.1:${LARGE_PORT}/v1/models
  curl -s http://127.0.0.1:${SMALL_PORT}/v1/models

Monitor:
  ${SCRIPT_DIR}/monitor_qwen3_dual_vllm_a800.sh
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  check_local_requirements
  pull_vllm_image
  stop_existing_containers
  run_gpu_test

  start_one_vllm \
    "large model" \
    "${LARGE_CONTAINER_NAME}" \
    "${LARGE_MODEL_PATH_HOST}" \
    "${LARGE_MODEL_PATH_CONTAINER}" \
    "${LARGE_SERVED_MODEL_NAME}" \
    "${LARGE_PORT}" \
    "${LARGE_GPUS}" \
    "${LARGE_TP_SIZE}" \
    "${LARGE_PP_SIZE}" \
    "${LARGE_MAX_MODEL_LEN}" \
    "${LARGE_MAX_NUM_SEQS}" \
    "${LARGE_GPU_MEMORY_UTILIZATION}" \
    "${LARGE_EXTRA_VLLM_ARGS}"

  sleep "${START_GAP_SECONDS}"

  start_one_vllm \
    "30B model" \
    "${SMALL_CONTAINER_NAME}" \
    "${SMALL_MODEL_PATH_HOST}" \
    "${SMALL_MODEL_PATH_CONTAINER}" \
    "${SMALL_SERVED_MODEL_NAME}" \
    "${SMALL_PORT}" \
    "${SMALL_GPUS}" \
    "${SMALL_TP_SIZE}" \
    "${SMALL_PP_SIZE}" \
    "${SMALL_MAX_MODEL_LEN}" \
    "${SMALL_MAX_NUM_SEQS}" \
    "${SMALL_GPU_MEMORY_UTILIZATION}" \
    "${SMALL_EXTRA_VLLM_ARGS}"

  if [[ "${WAIT_READY}" == "1" ]]; then
    wait_ready "${LARGE_CONTAINER_NAME}" "${LARGE_PORT}"
    wait_ready "${SMALL_CONTAINER_NAME}" "${SMALL_PORT}"
  fi

  print_summary
}

main "$@"
