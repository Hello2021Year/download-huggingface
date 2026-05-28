#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LARGE_CONTAINER_NAME="${LARGE_CONTAINER_NAME:-qwen3-large-vllm}"
SMALL_CONTAINER_NAME="${SMALL_CONTAINER_NAME:-qwen3-30b-vllm}"
LARGE_PORT="${LARGE_PORT:-8000}"
SMALL_PORT="${SMALL_PORT:-8001}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-10}"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/dual_vllm_monitor_$(date '+%Y%m%d_%H%M%S').log}"

METRIC_FILTER="${METRIC_FILTER:-^(vllm:gpu_cache_usage_perc|vllm:num_requests_running|vllm:num_requests_waiting|vllm:request_success_total|vllm:request_prompt_tokens_total|vllm:request_generation_tokens_total|vllm:e2e_request_latency_seconds|vllm:time_to_first_token_seconds|vllm:time_per_output_token_seconds)}"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

section() {
  printf '\n===== %s =====\n' "$*"
}

service_health() {
  local name="$1"
  local port="$2"
  local models_url="http://127.0.0.1:${port}/v1/models"
  local metrics_url="http://127.0.0.1:${port}/metrics"
  local tmp
  tmp="$(mktemp)"

  printf '%-18s port=%-5s ' "${name}" "${port}"
  if curl -fsS --max-time 2 "${models_url}" >/dev/null 2>&1; then
    printf 'health=ready'
  else
    printf 'health=not-ready'
  fi

  if curl -fsS --max-time 2 "${metrics_url}" -o "${tmp}" >/dev/null 2>&1; then
    printf ' metrics=ok\n'
    awk -v pat="${METRIC_FILTER}" '
      $0 ~ pat && $0 !~ /^#/ { print "  " $0 }
    ' "${tmp}" | head -40
  else
    printf ' metrics=unavailable\n'
  fi

  rm -f "${tmp}"
}

container_status() {
  section "Docker containers"
  docker_cmd ps \
    --filter "name=^/${LARGE_CONTAINER_NAME}$" \
    --filter "name=^/${SMALL_CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' || true

  section "Docker stats"
  docker_cmd stats --no-stream \
    --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}' \
    "${LARGE_CONTAINER_NAME}" "${SMALL_CONTAINER_NAME}" 2>/dev/null || true
}

gpu_status() {
  section "GPU status"
  nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu \
    --format=csv,noheader,nounits || nvidia-smi -L

  section "GPU processes"
  nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory \
    --format=csv,noheader,nounits 2>/dev/null || true
}

recent_logs_if_unready() {
  local name="$1"
  local port="$2"
  if curl -fsS --max-time 2 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; then
    return
  fi

  section "Recent logs: ${name}"
  docker_cmd logs --tail 30 "${name}" 2>&1 || true
}

print_once() {
  section "Time"
  log "monitoring ${LARGE_CONTAINER_NAME}:${LARGE_PORT} and ${SMALL_CONTAINER_NAME}:${SMALL_PORT}"

  gpu_status
  container_status

  section "vLLM health and metrics"
  service_health "${LARGE_CONTAINER_NAME}" "${LARGE_PORT}"
  service_health "${SMALL_CONTAINER_NAME}" "${SMALL_PORT}"

  recent_logs_if_unready "${LARGE_CONTAINER_NAME}" "${LARGE_PORT}"
  recent_logs_if_unready "${SMALL_CONTAINER_NAME}" "${SMALL_PORT}"
}

usage() {
  cat <<'EOF'
Usage:
  ./monitor_qwen3_dual_vllm_a800.sh

Default:
  Poll GPU, Docker, /v1/models, and /metrics every 10 seconds.

Common options:
  INTERVAL_SECONDS=5
  LARGE_CONTAINER_NAME=qwen3-large-vllm
  SMALL_CONTAINER_NAME=qwen3-30b-vllm
  LARGE_PORT=8000
  SMALL_PORT=8001
  LOG_FILE=/tmp/dual_vllm_monitor.log

Run one snapshot only:
  ONCE=1 ./monitor_qwen3_dual_vllm_a800.sh
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  command -v nvidia-smi >/dev/null 2>&1 || {
    log "ERROR: missing nvidia-smi"
    exit 1
  }
  command -v curl >/dev/null 2>&1 || {
    log "ERROR: missing curl"
    exit 1
  }

  mkdir -p "${LOG_DIR}"
  log "write monitor log: ${LOG_FILE}"

  if [[ "${ONCE:-0}" == "1" ]]; then
    print_once | tee -a "${LOG_FILE}"
    exit 0
  fi

  while true; do
    print_once | tee -a "${LOG_FILE}"
    sleep "${INTERVAL_SECONDS}"
  done
}

main "$@"
