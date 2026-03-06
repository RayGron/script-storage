#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPT="${SCRIPT_DIR}/ml-mode-common.sh"
if [[ ! -f "${COMMON_SCRIPT}" ]]; then
  COMMON_SCRIPT="/usr/local/sbin/ml-mode-common.sh"
fi
# shellcheck source=./ml-mode-common.sh
source "${COMMON_SCRIPT}"

usage() {
  cat <<EOF
Usage:
  inferctl.sh switch-model --model-id <id> [--tp <n>] [--pp <n>] [--gpu-memory-utilization <0-1>] [--nodes <name1,name2,...>] [--head-node <name>] [--net-if <iface>]
  inferctl.sh status [--nodes <name1,name2,...>] [--head-node <name>] [--net-if <iface>]
  inferctl.sh stop [--nodes <name1,name2,...>] [--head-node <name>] [--net-if <iface>]

Node defaults are loaded from:
  ${MLMAN_CONFIG_JSON}
EOF
}

declare -a SELECTED_GPU_NODES=()
RAY_HEAD_NODE=""
VLLM_PID_FILE=""
VLLM_LEGACY_MATCH_PATTERN=""

parse_nodes_csv() {
  local csv="$1"
  local token trimmed
  local seen=0
  local -A seen_nodes=()
  SELECTED_GPU_NODES=()

  if [[ -z "${csv}" ]]; then
    for token in "${MLMAN_ENABLED_GPU_NODE_NAMES[@]}"; do
      [[ -n "${seen_nodes[${token}]+x}" ]] && continue
      seen_nodes["${token}"]=1
      SELECTED_GPU_NODES+=("${token}")
    done
    return 0
  fi

  IFS=',' read -r -a raw_nodes <<<"${csv}"
  for token in "${raw_nodes[@]}"; do
    trimmed="$(echo "${token}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "${trimmed}" ]] && continue
    if [[ -z "${MLMAN_GPU_NODE_ENABLED_BY_NAME[${trimmed}]+x}" ]]; then
      echo "error: unknown GPU node in --nodes: ${trimmed}" >&2
      exit 2
    fi
    [[ -n "${seen_nodes[${trimmed}]+x}" ]] && continue
    seen_nodes["${trimmed}"]=1
    SELECTED_GPU_NODES+=("${trimmed}")
    seen=1
  done

  if [[ "${seen}" -eq 0 ]]; then
    echo "error: --nodes provided but empty after parsing" >&2
    exit 2
  fi
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

resolve_target_nodes() {
  local nodes_csv="$1"
  local head_override="$2"
  local head_candidate

  parse_nodes_csv "${nodes_csv}"
  if [[ "${#SELECTED_GPU_NODES[@]}" -eq 0 ]]; then
    echo "error: no GPU nodes selected (check ${MLMAN_CONFIG_JSON})" >&2
    exit 2
  fi

  if [[ -n "${head_override}" ]]; then
    head_candidate="${head_override}"
  else
    head_candidate="$(get_ray_head_node_name)"
  fi
  [[ -z "${head_candidate}" ]] && head_candidate="${SELECTED_GPU_NODES[0]}"

  if ! array_contains "${head_candidate}" "${SELECTED_GPU_NODES[@]}"; then
    echo "error: head node '${head_candidate}' is not in selected nodes: ${SELECTED_GPU_NODES[*]}" >&2
    exit 2
  fi
  RAY_HEAD_NODE="${head_candidate}"
}

validate_selected_nodes_runtime() {
  local node_name node_ip node_user
  for node_name in "${SELECTED_GPU_NODES[@]}"; do
    node_ip="$(get_gpu_node_ip "${node_name}")"
    node_user="$(get_gpu_node_user "${node_name}")"
    if [[ -z "${node_ip}" ]]; then
      echo "error: missing IP for GPU node '${node_name}' in ${MLMAN_CONFIG_JSON}" >&2
      exit 2
    fi
    if [[ -z "${node_user}" ]]; then
      echo "error: missing ssh_user for GPU node '${node_name}' in ${MLMAN_CONFIG_JSON}" >&2
      exit 2
    fi
  done
}

validate_parallelism() {
  local tp="$1"
  local pp="$2"
  local required available node_name
  local node_gpu_count

  required=$((tp * pp))
  available=0
  for node_name in "${SELECTED_GPU_NODES[@]}"; do
    node_gpu_count="$(get_gpu_node_gpu_count "${node_name}")"
    if ! [[ "${node_gpu_count}" =~ ^[0-9]+$ ]]; then
      echo "error: invalid gpu_count for node '${node_name}': ${node_gpu_count}" >&2
      exit 2
    fi
    available=$((available + node_gpu_count))
  done

  if ((available < required)); then
    echo "error: insufficient GPUs for tp*pp (${tp}*${pp}=${required}) across selected nodes (${available})" >&2
    exit 2
  fi
}

is_positive_int() {
  local v="$1"
  [[ "${v}" =~ ^[1-9][0-9]*$ ]]
}

is_valid_gpu_mem_util() {
  local v="$1"
  [[ "${v}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || return 1
  awk -v n="${v}" 'BEGIN { exit !(n > 0 && n <= 1.0) }'
}

ssh_gpu_node() {
  local node_name="$1"
  local script="$2"
  local node_ip node_user

  node_ip="$(get_gpu_node_ip "${node_name}")"
  node_user="$(get_gpu_node_user "${node_name}")"

  ssh -o BatchMode=yes -o ConnectTimeout="${ML_SSH_CONNECT_TIMEOUT_SEC}" "${node_user}@${node_ip}" \
    "bash -lc $(printf '%q' "${script}")"
}

common_remote_env() {
  printf 'VENV_PATH_VAL=%q\n' "${VENV_PATH}"
  cat <<'EOF'
if [[ "${VENV_PATH_VAL}" == "~/"* ]]; then
  VENV_PATH_VAL="${HOME}/${VENV_PATH_VAL#~/}"
fi
source "${VENV_PATH_VAL}/bin/activate"
EOF
  printf 'export HF_HOME=%q\n' "${HF_HOME}"
  printf 'export HUGGINGFACE_HUB_CACHE=%q\n' "${HUGGINGFACE_HUB_CACHE}"
  printf 'export TRANSFORMERS_CACHE=%q\n' "${TRANSFORMERS_CACHE}"
  printf 'export VLLM_DOWNLOAD_DIR=%q\n' "${VLLM_DOWNLOAD_DIR}"
  printf 'export NCCL_SOCKET_IFNAME=%q\n' "${NET_IF}"
}

start_ray_head_node() {
  local head_name="$1"
  local head_ip script
  local q_head_ip q_ray_port q_dash_port

  head_ip="$(get_gpu_node_ip "${head_name}")"
  printf -v q_head_ip '%q' "${head_ip}"
  printf -v q_ray_port '%q' "${RAY_PORT}"
  printf -v q_dash_port '%q' "${RAY_DASHBOARD_PORT}"
  script="$(common_remote_env)
ray stop --force || true
ray start --head --node-ip-address ${q_head_ip} --port ${q_ray_port} --dashboard-host 0.0.0.0 --dashboard-port ${q_dash_port}"
  ssh_gpu_node "${head_name}" "${script}"
}

start_ray_worker_node() {
  local node_name="$1"
  local head_name="$2"
  local node_ip head_ip script
  local q_head_addr q_node_ip

  node_ip="$(get_gpu_node_ip "${node_name}")"
  head_ip="$(get_gpu_node_ip "${head_name}")"
  printf -v q_head_addr '%q' "${head_ip}:${RAY_PORT}"
  printf -v q_node_ip '%q' "${node_ip}"

  script="$(common_remote_env)
ray stop --force || true
ray start --address ${q_head_addr} --node-ip-address ${q_node_ip}"
  ssh_gpu_node "${node_name}" "${script}"
}

start_ray_cluster() {
  local head_name="$1"
  local node_name
  start_ray_head_node "${head_name}"
  for node_name in "${SELECTED_GPU_NODES[@]}"; do
    [[ "${node_name}" == "${head_name}" ]] && continue
    start_ray_worker_node "${node_name}" "${head_name}"
  done
}

ray_status() {
  local head_name="$1"
  local script
  script="$(common_remote_env)
ray status"
  ssh_gpu_node "${head_name}" "${script}"
}

start_vllm() {
  local head_name="$1"
  local model_id="$2"
  local tp="$3"
  local pp="$4"
  local gpu_mem_util="$5"
  local model_safe script
  local q_model_id q_vllm_port q_tp q_pp q_gpu_mem q_download_dir q_log_dir q_log_file q_pid_file q_legacy_match

  model_safe="$(printf '%s' "${model_id}" | tr -c '[:alnum:]._-' '_')"
  [[ -z "${model_safe}" ]] && model_safe="model"
  printf -v q_model_id '%q' "${model_id}"
  printf -v q_vllm_port '%q' "${VLLM_PORT}"
  printf -v q_tp '%q' "${tp}"
  printf -v q_pp '%q' "${pp}"
  printf -v q_gpu_mem '%q' "${gpu_mem_util}"
  printf -v q_download_dir '%q' "${VLLM_DOWNLOAD_DIR}"
  printf -v q_log_dir '%q' "${INFER_LOG_DIR}"
  printf -v q_log_file '%q' "${INFER_LOG_DIR}/vllm_${model_safe}.log"
  VLLM_PID_FILE="${INFER_LOG_DIR}/vllm.pid"
  VLLM_LEGACY_MATCH_PATTERN="vllm serve .* --port ${VLLM_PORT}([[:space:]]|\$)"
  printf -v q_pid_file '%q' "${VLLM_PID_FILE}"
  printf -v q_legacy_match '%q' "${VLLM_LEGACY_MATCH_PATTERN}"

  script="$(common_remote_env)
export NCCL_DEBUG=INFO
mkdir -p ${q_log_dir}
if [[ -f ${q_pid_file} ]]; then
  old_pid=\$(cat ${q_pid_file} 2>/dev/null || true)
  if [[ -n \"\${old_pid}\" ]] && kill -0 \"\${old_pid}\" 2>/dev/null; then
    kill \"\${old_pid}\" 2>/dev/null || true
    sleep 2
    kill -9 \"\${old_pid}\" 2>/dev/null || true
  fi
fi
pkill -f -- ${q_legacy_match} 2>/dev/null || true
nohup vllm serve ${q_model_id} \
  --host 0.0.0.0 \
  --port ${q_vllm_port} \
  --distributed-executor-backend ray \
  --tensor-parallel-size ${q_tp} \
  --pipeline-parallel-size ${q_pp} \
  --download-dir ${q_download_dir} \
  --gpu-memory-utilization ${q_gpu_mem} \
  > ${q_log_file} 2>&1 < /dev/null &
echo \$! > ${q_pid_file}"
  ssh_gpu_node "${head_name}" "${script}"
}

wait_vllm_health() {
  local head_name="$1"
  local retries="${VLLM_HEALTHCHECK_RETRIES}"
  local interval="${VLLM_HEALTHCHECK_INTERVAL_SEC}"
  local head_ip i

  head_ip="$(get_gpu_node_ip "${head_name}")"
  for ((i = 1; i <= retries; i += 1)); do
    if curl -fsS "http://${head_ip}:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
  done

  echo "error: vLLM healthcheck failed at http://${head_ip}:${VLLM_PORT}/v1/models" >&2
  return 1
}

cmd_switch_model() {
  local model_id="$1"
  local tp="$2"
  local pp="$3"
  local gpu_mem_util="$4"

  if ! is_positive_int "${tp}"; then
    echo "error: --tp must be a positive integer, got: ${tp}" >&2
    exit 2
  fi
  if ! is_positive_int "${pp}"; then
    echo "error: --pp must be a positive integer, got: ${pp}" >&2
    exit 2
  fi
  if ! is_valid_gpu_mem_util "${gpu_mem_util}"; then
    echo "error: --gpu-memory-utilization must be in range (0,1], got: ${gpu_mem_util}" >&2
    exit 2
  fi

  validate_selected_nodes_runtime
  validate_parallelism "${tp}" "${pp}"
  start_ray_cluster "${RAY_HEAD_NODE}"
  start_vllm "${RAY_HEAD_NODE}" "${model_id}" "${tp}" "${pp}" "${gpu_mem_util}"
  wait_vllm_health "${RAY_HEAD_NODE}"
  echo "switch-model: OK model_id=${model_id} tp=${tp} pp=${pp} gpu_mem=${gpu_mem_util} head=${RAY_HEAD_NODE} nodes=${SELECTED_GPU_NODES[*]}"
}

cmd_status() {
  local head_ip
  local rc=0
  validate_selected_nodes_runtime
  head_ip="$(get_gpu_node_ip "${RAY_HEAD_NODE}")"
  echo "[Ray status on ${RAY_HEAD_NODE} (${head_ip})]"
  if ! ray_status "${RAY_HEAD_NODE}"; then
    rc=1
  fi
  echo
  echo "[vLLM /v1/models on ${head_ip}:${VLLM_PORT}]"
  if ! curl -fsS "http://${head_ip}:${VLLM_PORT}/v1/models"; then
    rc=1
  fi
  echo
  return "${rc}"
}

cmd_stop() {
  local node_name script
  local q_pid_file q_legacy_match
  validate_selected_nodes_runtime
  VLLM_PID_FILE="${INFER_LOG_DIR}/vllm.pid"
  VLLM_LEGACY_MATCH_PATTERN="vllm serve .* --port ${VLLM_PORT}([[:space:]]|\$)"
  printf -v q_pid_file '%q' "${VLLM_PID_FILE}"
  printf -v q_legacy_match '%q' "${VLLM_LEGACY_MATCH_PATTERN}"

  for node_name in "${SELECTED_GPU_NODES[@]}"; do
    if [[ "${node_name}" == "${RAY_HEAD_NODE}" ]]; then
      script="$(common_remote_env)
if [[ -f ${q_pid_file} ]]; then
  old_pid=\$(cat ${q_pid_file} 2>/dev/null || true)
  if [[ -n \"\${old_pid}\" ]] && kill -0 \"\${old_pid}\" 2>/dev/null; then
    kill \"\${old_pid}\" 2>/dev/null || true
    sleep 2
    kill -9 \"\${old_pid}\" 2>/dev/null || true
  fi
  rm -f ${q_pid_file} || true
fi
pkill -f -- ${q_legacy_match} 2>/dev/null || true
ray stop --force || true"
    else
      script="$(common_remote_env)
ray stop --force || true"
    fi
    ssh_gpu_node "${node_name}" "${script}"
  done
  echo "stop: OK nodes=${SELECTED_GPU_NODES[*]}"
}

main() {
  NET_IF="${NET_IF:-${MLMAN_DEFAULT_NET_IF:-eth0}}"
  VENV_PATH="${VENV_PATH:-~/venv-vllm}"
  HF_HOME="${HF_HOME:-/mnt/shared/models/.hf}"
  HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-/mnt/shared/models/.hf/hub}"
  TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/mnt/shared/models/.hf/transformers}"
  VLLM_DOWNLOAD_DIR="${VLLM_DOWNLOAD_DIR:-/mnt/shared/models/.vllm}"
  INFER_LOG_DIR="${INFER_LOG_DIR:-/mnt/shared/logs/infer}"
  RAY_PORT="${RAY_PORT:-6379}"
  RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
  VLLM_PORT="${VLLM_PORT:-8000}"
  VLLM_HEALTHCHECK_RETRIES="${VLLM_HEALTHCHECK_RETRIES:-30}"
  VLLM_HEALTHCHECK_INTERVAL_SEC="${VLLM_HEALTHCHECK_INTERVAL_SEC:-2}"

  local command="${1:-}"
  shift || true

  case "${command}" in
    switch-model)
      local model_id=""
      local tp="2"
      local pp="2"
      local gpu_mem_util="0.90"
      local nodes_csv=""
      local head_node=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model-id)
            [[ $# -ge 2 ]] || { echo "error: --model-id requires a value" >&2; exit 2; }
            model_id="${2:-}"
            shift 2
            ;;
          --tp)
            [[ $# -ge 2 ]] || { echo "error: --tp requires a value" >&2; exit 2; }
            tp="${2:-}"
            shift 2
            ;;
          --pp)
            [[ $# -ge 2 ]] || { echo "error: --pp requires a value" >&2; exit 2; }
            pp="${2:-}"
            shift 2
            ;;
          --gpu-memory-utilization)
            [[ $# -ge 2 ]] || { echo "error: --gpu-memory-utilization requires a value" >&2; exit 2; }
            gpu_mem_util="${2:-}"
            shift 2
            ;;
          --nodes)
            [[ $# -ge 2 ]] || { echo "error: --nodes requires a value" >&2; exit 2; }
            nodes_csv="${2:-}"
            shift 2
            ;;
          --head-node)
            [[ $# -ge 2 ]] || { echo "error: --head-node requires a value" >&2; exit 2; }
            head_node="${2:-}"
            shift 2
            ;;
          --net-if)
            [[ $# -ge 2 ]] || { echo "error: --net-if requires a value" >&2; exit 2; }
            NET_IF="${2:-}"
            shift 2
            ;;
          -h|--help) usage; exit 0 ;;
          *)
            echo "error: unknown argument for switch-model: $1" >&2
            usage >&2
            exit 2
            ;;
        esac
      done

      if [[ -z "${model_id}" ]]; then
        echo "error: --model-id is required for switch-model" >&2
        usage >&2
        exit 2
      fi

      resolve_target_nodes "${nodes_csv}" "${head_node}"
      cmd_switch_model "${model_id}" "${tp}" "${pp}" "${gpu_mem_util}"
      ;;
    status)
      local nodes_csv=""
      local head_node=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --nodes)
            [[ $# -ge 2 ]] || { echo "error: --nodes requires a value" >&2; exit 2; }
            nodes_csv="${2:-}"
            shift 2
            ;;
          --head-node)
            [[ $# -ge 2 ]] || { echo "error: --head-node requires a value" >&2; exit 2; }
            head_node="${2:-}"
            shift 2
            ;;
          --net-if)
            [[ $# -ge 2 ]] || { echo "error: --net-if requires a value" >&2; exit 2; }
            NET_IF="${2:-}"
            shift 2
            ;;
          -h|--help) usage; exit 0 ;;
          *)
            echo "error: unknown argument for status: $1" >&2
            usage >&2
            exit 2
            ;;
        esac
      done
      resolve_target_nodes "${nodes_csv}" "${head_node}"
      cmd_status
      ;;
    stop)
      local nodes_csv=""
      local head_node=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --nodes)
            [[ $# -ge 2 ]] || { echo "error: --nodes requires a value" >&2; exit 2; }
            nodes_csv="${2:-}"
            shift 2
            ;;
          --head-node)
            [[ $# -ge 2 ]] || { echo "error: --head-node requires a value" >&2; exit 2; }
            head_node="${2:-}"
            shift 2
            ;;
          --net-if)
            [[ $# -ge 2 ]] || { echo "error: --net-if requires a value" >&2; exit 2; }
            NET_IF="${2:-}"
            shift 2
            ;;
          -h|--help) usage; exit 0 ;;
          *)
            echo "error: unknown argument for stop: $1" >&2
            usage >&2
            exit 2
            ;;
        esac
      done
      resolve_target_nodes "${nodes_csv}" "${head_node}"
      cmd_stop
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      echo "error: unknown command: ${command}" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
