#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for mlman, hookscript, watchdog, and inferctl.

MLMAN_CONFIG_ROLE="${MLMAN_CONFIG_ROLE:-host}"
MLMAN_CONFIG_JSON="${MLMAN_CONFIG_JSON:-/etc/mlman/mlman.conf}"
INFER_CONFIG_JSON="${INFER_CONFIG_JSON:-/etc/mlman/infer.conf}"
MLMAN_ACTIVE_CONFIG_JSON=""

# Legacy compatibility alias.
MLMAN_CONF_FILE="${MLMAN_CONF_FILE:-${MLMAN_CONFIG_JSON}}"

declare -a MLMAN_GPU_NODE_NAMES=()
declare -a MLMAN_ENABLED_GPU_NODE_NAMES=()
declare -A MLMAN_GPU_NODE_IP_BY_NAME=()
declare -A MLMAN_GPU_NODE_SSH_USER_BY_NAME=()
declare -A MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME=()
declare -A MLMAN_GPU_NODE_CORES_BY_NAME=()
declare -A MLMAN_GPU_NODE_GPU_COUNT_BY_NAME=()
declare -A MLMAN_GPU_NODE_ENABLED_BY_NAME=()

seed_default_gpu_nodes() {
  local n1="vm-gpu-1"
  local n2="vm-gpu-2"

  MLMAN_GPU_NODE_NAMES=("${n1}" "${n2}")
  MLMAN_ENABLED_GPU_NODE_NAMES=("${n1}" "${n2}")

  MLMAN_GPU_NODE_IP_BY_NAME["${n1}"]="${MLMAN_DEFAULT_GPU1_IP:-}"
  MLMAN_GPU_NODE_IP_BY_NAME["${n2}"]="${MLMAN_DEFAULT_GPU2_IP:-}"

  MLMAN_GPU_NODE_SSH_USER_BY_NAME["${n1}"]="${MLMAN_DEFAULT_GPU1_USER:-${MLMAN_DEFAULT_GPU_USER:-}}"
  MLMAN_GPU_NODE_SSH_USER_BY_NAME["${n2}"]="${MLMAN_DEFAULT_GPU2_USER:-${MLMAN_DEFAULT_GPU_USER:-}}"

  MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME["${n1}"]="${VM_GPU_1_MEMORY_MIB:-90112}"
  MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME["${n2}"]="${VM_GPU_2_MEMORY_MIB:-90112}"
  MLMAN_GPU_NODE_CORES_BY_NAME["${n1}"]="${VM_GPU_1_CORES:-96}"
  MLMAN_GPU_NODE_CORES_BY_NAME["${n2}"]="${VM_GPU_2_CORES:-96}"
  MLMAN_GPU_NODE_GPU_COUNT_BY_NAME["${n1}"]="${MLMAN_DEFAULT_GPU1_COUNT:-2}"
  MLMAN_GPU_NODE_GPU_COUNT_BY_NAME["${n2}"]="${MLMAN_DEFAULT_GPU2_COUNT:-2}"
  MLMAN_GPU_NODE_ENABLED_BY_NAME["${n1}"]="true"
  MLMAN_GPU_NODE_ENABLED_BY_NAME["${n2}"]="true"
}

resolve_gpu_defaults_from_common_user() {
  local common_user="${MLMAN_DEFAULT_GPU_USER:-}"
  if [[ -n "${common_user}" ]]; then
    [[ -z "${MLMAN_DEFAULT_GPU1_USER:-}" ]] && MLMAN_DEFAULT_GPU1_USER="${common_user}"
    [[ -z "${MLMAN_DEFAULT_GPU2_USER:-}" ]] && MLMAN_DEFAULT_GPU2_USER="${common_user}"
  fi
}

load_shared_config_defaults() {
  ML_MODE_STATE_DIR="${ML_MODE_STATE_DIR:-/var/lib/mlman}"
  ML_MODE_LOG_DIR="${ML_MODE_LOG_DIR:-/var/log/mlman}"
  ML_CONTROL_ROOT="${ML_CONTROL_ROOT:-/mnt/shared-storage/mlshare/control}"
  ML_CONTROL_LOCK_TIMEOUT_SEC="${ML_CONTROL_LOCK_TIMEOUT_SEC:-60}"
  ML_INFER_SSH_USER="${ML_INFER_SSH_USER:-root}"
  ML_INFER_SSH_HOST="${ML_INFER_SSH_HOST:-}"
  ML_INFERCTL_PATH="${ML_INFERCTL_PATH:-/usr/local/sbin/inferctl.sh}"
  ML_INFER_CONFIG_PATH_REMOTE="${ML_INFER_CONFIG_PATH_REMOTE:-/etc/mlman/infer.conf}"
  ML_SSH_CONNECT_TIMEOUT_SEC="${ML_SSH_CONNECT_TIMEOUT_SEC:-10}"

  VM_TRAIN_NAME="${VM_TRAIN_NAME:-vm-train}"
  VM_INFER_NAME="${VM_INFER_NAME:-vm-infer}"
  VM_TRAIN_MEMORY_MIB="${VM_TRAIN_MEMORY_MIB:-34816}"
  VM_INFER_MEMORY_MIB="${VM_INFER_MEMORY_MIB:-16384}"
  VM_TRAIN_CORES="${VM_TRAIN_CORES:-24}"
  VM_INFER_CORES="${VM_INFER_CORES:-16}"
  VM_DEFAULT_SOCKETS="${VM_DEFAULT_SOCKETS:-1}"
  VM_DEFAULT_NUMA="${VM_DEFAULT_NUMA:-1}"
  VM_DEFAULT_CPU_TYPE="${VM_DEFAULT_CPU_TYPE:-host}"
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

  HOST_RESERVED_MIB="${HOST_RESERVED_MIB:-30720}"
  VM_MEMORY_LIMIT_MIB="${VM_MEMORY_LIMIT_MIB:-231424}"
  MLMAN_RAY_HEAD_NODE="${MLMAN_RAY_HEAD_NODE:-}"

  MLMAN_DEFAULT_GPU1_IP="${MLMAN_DEFAULT_GPU1_IP:-}"
  MLMAN_DEFAULT_GPU2_IP="${MLMAN_DEFAULT_GPU2_IP:-}"
  MLMAN_DEFAULT_GPU_USER="${MLMAN_DEFAULT_GPU_USER:-}"
  MLMAN_DEFAULT_GPU1_USER="${MLMAN_DEFAULT_GPU1_USER:-}"
  MLMAN_DEFAULT_GPU2_USER="${MLMAN_DEFAULT_GPU2_USER:-}"
  MLMAN_DEFAULT_NET_IF="${MLMAN_DEFAULT_NET_IF:-eth0}"
}

require_json_config_tools() {
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to parse JSON config" >&2
    exit 1
  }
}

validate_json_config() {
  local config_path="$1"
  jq -e . "${config_path}" >/dev/null 2>&1 || {
    echo "error: invalid JSON config: ${config_path}" >&2
    exit 1
  }
}

reset_gpu_node_maps() {
  MLMAN_GPU_NODE_NAMES=()
  MLMAN_ENABLED_GPU_NODE_NAMES=()
  MLMAN_GPU_NODE_IP_BY_NAME=()
  MLMAN_GPU_NODE_SSH_USER_BY_NAME=()
  MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME=()
  MLMAN_GPU_NODE_CORES_BY_NAME=()
  MLMAN_GPU_NODE_GPU_COUNT_BY_NAME=()
  MLMAN_GPU_NODE_ENABLED_BY_NAME=()
}

parse_gpu_nodes_from_json() {
  local config_path="$1"

  MLMAN_DEFAULT_GPU1_IP=""
  MLMAN_DEFAULT_GPU2_IP=""
  MLMAN_DEFAULT_GPU_USER=""
  MLMAN_DEFAULT_GPU1_USER=""
  MLMAN_DEFAULT_GPU2_USER=""

  reset_gpu_node_maps

  while IFS=$'\t' read -r node_name node_ip node_user node_memory node_cores node_gpu_count node_enabled; do
    [[ -z "${node_name}" ]] && continue
    MLMAN_GPU_NODE_NAMES+=("${node_name}")
    MLMAN_GPU_NODE_IP_BY_NAME["${node_name}"]="${node_ip}"
    MLMAN_GPU_NODE_SSH_USER_BY_NAME["${node_name}"]="${node_user}"
    MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME["${node_name}"]="${node_memory}"
    MLMAN_GPU_NODE_CORES_BY_NAME["${node_name}"]="${node_cores}"
    MLMAN_GPU_NODE_GPU_COUNT_BY_NAME["${node_name}"]="${node_gpu_count}"
    MLMAN_GPU_NODE_ENABLED_BY_NAME["${node_name}"]="${node_enabled}"
    if [[ "${node_enabled}" == "true" ]]; then
      MLMAN_ENABLED_GPU_NODE_NAMES+=("${node_name}")
    fi
  done < <(
    jq -r '
      (.gpu_nodes // [])[] |
      [
        (.name // ""),
        (.ip // ""),
        (.ssh_user // ""),
        (.memory_mib // 90112),
        (.cores // 96),
        (.gpu_count // 2),
        (if (.enabled // true) then "true" else "false" end)
      ] | @tsv
    ' "${config_path}"
  )

  if [[ "${#MLMAN_GPU_NODE_NAMES[@]}" -eq 0 ]]; then
    resolve_gpu_defaults_from_common_user
    seed_default_gpu_nodes
  fi
}

finalize_legacy_gpu_aliases() {
  # Compatibility aliases for legacy code paths.
  if [[ "${#MLMAN_GPU_NODE_NAMES[@]}" -ge 1 ]]; then
    VM_GPU_1_NAME="${MLMAN_GPU_NODE_NAMES[0]}"
    VM_GPU_1_MEMORY_MIB="${MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME[${VM_GPU_1_NAME}]}"
    VM_GPU_1_CORES="${MLMAN_GPU_NODE_CORES_BY_NAME[${VM_GPU_1_NAME}]}"
    MLMAN_DEFAULT_GPU1_IP="${MLMAN_GPU_NODE_IP_BY_NAME[${VM_GPU_1_NAME}]}"
    MLMAN_DEFAULT_GPU1_USER="${MLMAN_GPU_NODE_SSH_USER_BY_NAME[${VM_GPU_1_NAME}]}"
  else
    VM_GPU_1_NAME="vm-gpu-1"
    VM_GPU_1_MEMORY_MIB="90112"
    VM_GPU_1_CORES="96"
  fi
  if [[ "${#MLMAN_GPU_NODE_NAMES[@]}" -ge 2 ]]; then
    VM_GPU_2_NAME="${MLMAN_GPU_NODE_NAMES[1]}"
    VM_GPU_2_MEMORY_MIB="${MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME[${VM_GPU_2_NAME}]}"
    VM_GPU_2_CORES="${MLMAN_GPU_NODE_CORES_BY_NAME[${VM_GPU_2_NAME}]}"
    MLMAN_DEFAULT_GPU2_IP="${MLMAN_GPU_NODE_IP_BY_NAME[${VM_GPU_2_NAME}]}"
    MLMAN_DEFAULT_GPU2_USER="${MLMAN_GPU_NODE_SSH_USER_BY_NAME[${VM_GPU_2_NAME}]}"
  else
    VM_GPU_2_NAME="vm-gpu-2"
    VM_GPU_2_MEMORY_MIB="90112"
    VM_GPU_2_CORES="96"
  fi
}

compute_vm_memory_limit_if_needed() {
  if [[ "${VM_MEMORY_LIMIT_MIB}" == "0" ]]; then
    local mem_sum=0
    local n
    local -a profile_nodes=()
    if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
      profile_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
    else
      profile_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
    fi
    for n in "${profile_nodes[@]}"; do
      mem_sum=$((mem_sum + MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME["${n}"]))
    done
    mem_sum=$((mem_sum + VM_TRAIN_MEMORY_MIB + VM_INFER_MEMORY_MIB))
    VM_MEMORY_LIMIT_MIB="${mem_sum}"
  fi
}

load_mlman_host_json_config() {
  load_shared_config_defaults
  MLMAN_ACTIVE_CONFIG_JSON="${MLMAN_CONFIG_JSON}"

  if [[ ! -f "${MLMAN_CONFIG_JSON}" ]]; then
    resolve_gpu_defaults_from_common_user
    seed_default_gpu_nodes
    return 0
  fi

  require_json_config_tools
  validate_json_config "${MLMAN_CONFIG_JSON}"

  ML_MODE_STATE_DIR="$(jq -r '.control.state_dir // "/var/lib/mlman"' "${MLMAN_CONFIG_JSON}")"
  ML_MODE_LOG_DIR="$(jq -r '.control.log_dir // "/var/log/mlman"' "${MLMAN_CONFIG_JSON}")"
  ML_CONTROL_ROOT="$(jq -r '.control.root // "/mnt/shared-storage/mlshare/control"' "${MLMAN_CONFIG_JSON}")"
  ML_CONTROL_LOCK_TIMEOUT_SEC="$(jq -r '.control.lock_timeout_sec // 60' "${MLMAN_CONFIG_JSON}")"
  ML_INFER_SSH_USER="$(jq -r '.control.infer_ssh_user // "root"' "${MLMAN_CONFIG_JSON}")"
  ML_INFER_SSH_HOST="$(jq -r '.control.infer_ssh_host // empty' "${MLMAN_CONFIG_JSON}")"
  ML_INFERCTL_PATH="$(jq -r '.control.inferctl_path // "/usr/local/sbin/inferctl.sh"' "${MLMAN_CONFIG_JSON}")"
  ML_INFER_CONFIG_PATH_REMOTE="$(jq -r '.control.infer_config_path // "/etc/mlman/infer.conf"' "${MLMAN_CONFIG_JSON}")"
  ML_SSH_CONNECT_TIMEOUT_SEC="$(jq -r '.control.ssh_connect_timeout_sec // 10' "${MLMAN_CONFIG_JSON}")"

  VM_TRAIN_NAME="$(jq -r '.vm_names.train // "vm-train"' "${MLMAN_CONFIG_JSON}")"
  VM_INFER_NAME="$(jq -r '.vm_names.infer // "vm-infer"' "${MLMAN_CONFIG_JSON}")"
  VM_TRAIN_MEMORY_MIB="$(jq -r '.profiles.train.memory_mib // 34816' "${MLMAN_CONFIG_JSON}")"
  VM_INFER_MEMORY_MIB="$(jq -r '.profiles.infer.memory_mib // 16384' "${MLMAN_CONFIG_JSON}")"
  VM_TRAIN_CORES="$(jq -r '.profiles.train.cores // 24' "${MLMAN_CONFIG_JSON}")"
  VM_INFER_CORES="$(jq -r '.profiles.infer.cores // 16' "${MLMAN_CONFIG_JSON}")"
  VM_DEFAULT_CPU_TYPE="$(jq -r '.resource_defaults.cpu // "host"' "${MLMAN_CONFIG_JSON}")"
  VM_DEFAULT_SOCKETS="$(jq -r '.resource_defaults.sockets // 1' "${MLMAN_CONFIG_JSON}")"
  VM_DEFAULT_NUMA="$(jq -r '.resource_defaults.numa // 1' "${MLMAN_CONFIG_JSON}")"

  HOST_RESERVED_MIB="$(jq -r '.limits.host_reserved_mib // 30720' "${MLMAN_CONFIG_JSON}")"
  VM_MEMORY_LIMIT_MIB="$(jq -r '.limits.vm_memory_limit_mib // 0' "${MLMAN_CONFIG_JSON}")"

  parse_gpu_nodes_from_json "${MLMAN_CONFIG_JSON}"
  finalize_legacy_gpu_aliases
  compute_vm_memory_limit_if_needed
}

load_infer_json_config() {
  load_shared_config_defaults
  MLMAN_ACTIVE_CONFIG_JSON="${INFER_CONFIG_JSON}"

  if [[ ! -f "${INFER_CONFIG_JSON}" ]]; then
    resolve_gpu_defaults_from_common_user
    seed_default_gpu_nodes
    return 0
  fi

  require_json_config_tools
  validate_json_config "${INFER_CONFIG_JSON}"

  ML_SSH_CONNECT_TIMEOUT_SEC="$(jq -r '.control.ssh_connect_timeout_sec // 10' "${INFER_CONFIG_JSON}")"

  MLMAN_DEFAULT_NET_IF="$(jq -r '.inference.net_if // "eth0"' "${INFER_CONFIG_JSON}")"
  MLMAN_RAY_HEAD_NODE="$(jq -r '.inference.ray_head_node // empty' "${INFER_CONFIG_JSON}")"
  VENV_PATH="$(jq -r '.inference.venv_path // "~/venv-vllm"' "${INFER_CONFIG_JSON}")"
  HF_HOME="$(jq -r '.inference.hf_home // "/mnt/shared/models/.hf"' "${INFER_CONFIG_JSON}")"
  HUGGINGFACE_HUB_CACHE="$(jq -r '.inference.huggingface_hub_cache // "/mnt/shared/models/.hf/hub"' "${INFER_CONFIG_JSON}")"
  TRANSFORMERS_CACHE="$(jq -r '.inference.transformers_cache // "/mnt/shared/models/.hf/transformers"' "${INFER_CONFIG_JSON}")"
  VLLM_DOWNLOAD_DIR="$(jq -r '.inference.vllm_download_dir // "/mnt/shared/models/.vllm"' "${INFER_CONFIG_JSON}")"
  INFER_LOG_DIR="$(jq -r '.inference.infer_log_dir // "/mnt/shared/logs/infer"' "${INFER_CONFIG_JSON}")"
  RAY_PORT="$(jq -r '.inference.ray_port // 6379' "${INFER_CONFIG_JSON}")"
  RAY_DASHBOARD_PORT="$(jq -r '.inference.ray_dashboard_port // 8265' "${INFER_CONFIG_JSON}")"
  VLLM_PORT="$(jq -r '.inference.vllm_port // 8000' "${INFER_CONFIG_JSON}")"
  VLLM_HEALTHCHECK_RETRIES="$(jq -r '.inference.vllm_healthcheck_retries // 30' "${INFER_CONFIG_JSON}")"
  VLLM_HEALTHCHECK_INTERVAL_SEC="$(jq -r '.inference.vllm_healthcheck_interval_sec // 2' "${INFER_CONFIG_JSON}")"

  parse_gpu_nodes_from_json "${INFER_CONFIG_JSON}"
  finalize_legacy_gpu_aliases
}

get_gpu_node_ip() {
  local node_name="$1"
  printf "%s\n" "${MLMAN_GPU_NODE_IP_BY_NAME[${node_name}]:-}"
}

get_gpu_node_user() {
  local node_name="$1"
  printf "%s\n" "${MLMAN_GPU_NODE_SSH_USER_BY_NAME[${node_name}]:-}"
}

get_gpu_node_memory_mib() {
  local node_name="$1"
  printf "%s\n" "${MLMAN_GPU_NODE_MEMORY_MIB_BY_NAME[${node_name}]:-0}"
}

get_gpu_node_cores() {
  local node_name="$1"
  printf "%s\n" "${MLMAN_GPU_NODE_CORES_BY_NAME[${node_name}]:-0}"
}

get_gpu_node_gpu_count() {
  local node_name="$1"
  printf "%s\n" "${MLMAN_GPU_NODE_GPU_COUNT_BY_NAME[${node_name}]:-0}"
}

gpu_node_is_enabled() {
  local node_name="$1"
  [[ "${MLMAN_GPU_NODE_ENABLED_BY_NAME[${node_name}]:-false}" == "true" ]]
}

get_ray_head_node_name() {
  if [[ -n "${MLMAN_RAY_HEAD_NODE:-}" ]]; then
    printf "%s\n" "${MLMAN_RAY_HEAD_NODE}"
    return 0
  fi
  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    printf "%s\n" "${MLMAN_ENABLED_GPU_NODE_NAMES[0]}"
    return 0
  fi
  if [[ "${#MLMAN_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    printf "%s\n" "${MLMAN_GPU_NODE_NAMES[0]}"
    return 0
  fi
  printf "\n"
}

case "${MLMAN_CONFIG_ROLE}" in
  host)
    load_mlman_host_json_config
    ;;
  infer)
    load_infer_json_config
    ;;
  *)
    echo "error: unknown MLMAN_CONFIG_ROLE: ${MLMAN_CONFIG_ROLE}" >&2
    exit 1
    ;;
esac

ML_MODE_STATE_FILE="${ML_MODE_STATE_FILE:-${ML_MODE_STATE_DIR}/state.env}"
ML_MODE_POLICY_LOG="${ML_MODE_POLICY_LOG:-${ML_MODE_LOG_DIR}/policy.log}"
ML_CONTROL_LOCK_FILE="${ML_CONTROL_LOCK_FILE:-${ML_CONTROL_ROOT}/cluster.lock}"
ML_MODEL_REGISTRY_FILE="${ML_MODEL_REGISTRY_FILE:-${ML_CONTROL_ROOT}/models.tsv}"
ML_ACTIVE_MODEL_FILE="${ML_ACTIVE_MODEL_FILE:-${ML_CONTROL_ROOT}/active-model.env}"

if [[ -z "${ML_INFER_SSH_HOST}" ]]; then
  ML_INFER_SSH_HOST="${VM_INFER_NAME}"
fi

ensure_runtime_dirs() {
  mkdir -p "${ML_MODE_STATE_DIR}" "${ML_MODE_LOG_DIR}"
  if [[ ! -f "${ML_MODE_STATE_FILE}" ]]; then
    write_kv_file "${ML_MODE_STATE_FILE}" \
      active_mode "idle" \
      last_switch_by "init" \
      last_switch_ts "$(date -Is)" \
      last_requested_mode "idle" \
      ram_guard_passed "true" \
      policy_version "v8"
  fi
}

sanitize_single_line() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf "%s" "${value}"
}

write_kv_file() {
  local file_path="$1"
  shift

  : >"${file_path}"
  while [[ $# -ge 2 ]]; do
    local key="$1"
    local value="$2"
    shift 2
    printf "%s=%s\n" "${key}" "$(sanitize_single_line "${value}")" >>"${file_path}"
  done
}

kv_get_or_default() {
  local file_path="$1"
  local wanted_key="$2"
  local default_value="$3"
  local value

  if value="$(awk -F'=' -v k="${wanted_key}" '$1==k {value=substr($0, index($0, "=")+1); found=1} END {if (!found) exit 1; print value}' "${file_path}" 2>/dev/null)"; then
    printf "%s\n" "${value}"
  else
    printf "%s\n" "${default_value}"
  fi
}

ensure_control_dir() {
  if [[ -d "${ML_CONTROL_ROOT}" ]]; then
    return 0
  fi
  mkdir -p "${ML_CONTROL_ROOT}" 2>/dev/null || {
    echo "error: cannot create control root: ${ML_CONTROL_ROOT}" >&2
    return 1
  }
}

run_with_control_lock() {
  local timeout="${ML_CONTROL_LOCK_TIMEOUT_SEC}"
  ensure_control_dir || return 1
  (
    flock -w "${timeout}" 9 || {
      echo "error: failed to acquire control lock: ${ML_CONTROL_LOCK_FILE}" >&2
      exit 1
    }
    "$@"
  ) 9>"${ML_CONTROL_LOCK_FILE}"
}

log_policy() {
  local msg="$1"
  ensure_runtime_dirs
  printf "%s %s\n" "$(date -Is)" "${msg}" >>"${ML_MODE_POLICY_LOG}"
}

load_state() {
  ensure_runtime_dirs
  active_mode="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "active_mode" "idle")"
  last_switch_by="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "last_switch_by" "init")"
  last_switch_ts="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "last_switch_ts" "")"
  last_requested_mode="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "last_requested_mode" "idle")"
  ram_guard_passed="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "ram_guard_passed" "false")"
  policy_version="$(kv_get_or_default "${ML_MODE_STATE_FILE}" "policy_version" "v8")"
}

save_state() {
  local active_mode="$1"
  local last_switch_by="$2"
  local last_requested_mode="$3"
  local ram_guard_passed="$4"
  ensure_runtime_dirs
  write_kv_file "${ML_MODE_STATE_FILE}" \
    active_mode "${active_mode}" \
    last_switch_by "${last_switch_by}" \
    last_switch_ts "$(date -Is)" \
    last_requested_mode "${last_requested_mode}" \
    ram_guard_passed "${ram_guard_passed}" \
    policy_version "v8"
}

save_active_model() {
  local model_alias="$1"
  local model_id="$2"
  local model_tp="$3"
  local model_pp="$4"
  local model_gpu_mem_util="$5"
  local switched_by="$6"
  ensure_control_dir || return 1
  write_kv_file "${ML_ACTIVE_MODEL_FILE}" \
    active_model_alias "${model_alias}" \
    active_model_id "${model_id}" \
    active_model_tp "${model_tp}" \
    active_model_pp "${model_pp}" \
    active_model_gpu_memory_utilization "${model_gpu_mem_util}" \
    switched_by "${switched_by}" \
    switched_at "$(date -Is)"
}

load_active_model() {
  [[ -f "${ML_ACTIVE_MODEL_FILE}" ]] || return 1
  active_model_alias="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "active_model_alias" "")"
  active_model_id="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "active_model_id" "")"
  active_model_tp="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "active_model_tp" "")"
  active_model_pp="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "active_model_pp" "")"
  active_model_gpu_memory_utilization="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "active_model_gpu_memory_utilization" "")"
  switched_by="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "switched_by" "")"
  switched_at="$(kv_get_or_default "${ML_ACTIVE_MODEL_FILE}" "switched_at" "")"
  [[ -n "${active_model_id}" ]]
}

require_qm() {
  if ! command -v qm >/dev/null 2>&1; then
    echo "error: qm command not found; run on Proxmox host" >&2
    exit 1
  fi
}

resolve_vmid_by_name() {
  local name="$1"
  require_qm
  qm list | awk -v vmname="${name}" 'NR>1 && $2 == vmname {print $1; exit}'
}

require_vmid() {
  local name="$1"
  local vmid
  vmid="$(resolve_vmid_by_name "${name}")"
  if [[ -z "${vmid}" ]]; then
    echo "error: VM '${name}' not found in qm list" >&2
    exit 1
  fi
  printf "%s\n" "${vmid}"
}

vm_status() {
  local vmid="$1"
  qm status "${vmid}" | awk '{print $2}'
}

vm_is_running() {
  local vmid="$1"
  [[ "$(vm_status "${vmid}")" == "running" ]]
}

current_runtime_mode() {
  local train_vmid infer_vmid train_running infer_running
  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"

  train_running=false
  infer_running=false
  vm_is_running "${train_vmid}" && train_running=true
  vm_is_running "${infer_vmid}" && infer_running=true

  if [[ "${train_running}" == "true" && "${infer_running}" == "true" ]]; then
    printf "conflict\n"
    return 0
  fi
  if [[ "${train_running}" == "true" ]]; then
    printf "train\n"
    return 0
  fi
  if [[ "${infer_running}" == "true" ]]; then
    printf "infer\n"
    return 0
  fi
  printf "idle\n"
}

inferctl_exec() {
  local target="${ML_INFER_SSH_USER}@${ML_INFER_SSH_HOST}"
  local remote_infer_config="${ML_INFER_CONFIG_PATH_REMOTE:-/etc/mlman/infer.conf}"
  local remote_cmd=""
  local arg
  command -v ssh >/dev/null 2>&1 || {
    echo "error: ssh not found; cannot reach vm-infer control plane" >&2
    return 1
  }
  for arg in "$@"; do
    remote_cmd+=" $(printf '%q' "${arg}")"
  done
  ssh -o BatchMode=yes -o ConnectTimeout="${ML_SSH_CONNECT_TIMEOUT_SEC}" "${target}" \
    "INFER_CONFIG_JSON=$(printf '%q' "${remote_infer_config}")${remote_cmd}"
}

stop_vm_graceful_then_force() {
  local vmid="$1"
  local timeout_seconds="${2:-60}"
  local vm_name="${3:-vm-${vmid}}"

  if ! vm_is_running "${vmid}"; then
    return 0
  fi

  log_policy "stop_request vmid=${vmid} name=${vm_name} mode=graceful timeout=${timeout_seconds}"
  qm shutdown "${vmid}" --timeout "${timeout_seconds}" >/dev/null 2>&1 || true

  if vm_is_running "${vmid}"; then
    log_policy "stop_escalate vmid=${vmid} name=${vm_name} mode=force"
    qm stop "${vmid}" >/dev/null 2>&1 || true
  fi

  if vm_is_running "${vmid}"; then
    log_policy "stop_failed vmid=${vmid} name=${vm_name}"
    return 1
  fi

  log_policy "stop_ok vmid=${vmid} name=${vm_name}"
  return 0
}

start_vm_if_needed() {
  local vmid="$1"
  local vm_name="${2:-vm-${vmid}}"
  if vm_is_running "${vmid}"; then
    return 0
  fi
  qm start "${vmid}" >/dev/null 2>&1
  log_policy "start_ok vmid=${vmid} name=${vm_name}"
}

get_vm_memory_mib() {
  local vmid="$1"
  qm config "${vmid}" | awk -F ': *' '$1=="memory" {print $2; exit}'
}

get_vm_config_value() {
  local vmid="$1"
  local key="$2"
  qm config "${vmid}" | awk -F ': *' -v cfg_key="${key}" '$1==cfg_key {print $2; exit}'
}

running_memory_sum_mib() {
  local total=0
  local vmid mem
  while read -r vmid; do
    [[ -z "${vmid}" ]] && continue
    if vm_is_running "${vmid}"; then
      mem="$(get_vm_memory_mib "${vmid}")"
      mem="${mem:-0}"
      total=$((total + mem))
    fi
  done < <(qm list | awk 'NR>1 {print $1}')
  printf "%s\n" "${total}"
}

ram_guard_check() {
  local sum_mib
  sum_mib="$(running_memory_sum_mib)"
  if ((sum_mib > VM_MEMORY_LIMIT_MIB)); then
    log_policy "ram_guard_failed running_sum_mib=${sum_mib} limit_mib=${VM_MEMORY_LIMIT_MIB}"
    return 1
  fi
  log_policy "ram_guard_ok running_sum_mib=${sum_mib} limit_mib=${VM_MEMORY_LIMIT_MIB}"
  return 0
}

memory_plan_check() {
  local vm_name vmid expected_mem actual_mem expected_sum actual_sum
  local -a profile_nodes=()
  expected_sum=0
  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    profile_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
  else
    profile_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
  fi

  for vm_name in "${profile_nodes[@]}"; do
    vmid="$(require_vmid "${vm_name}")"
    expected_mem="$(get_gpu_node_memory_mib "${vm_name}")"
    actual_mem="$(get_vm_memory_mib "${vmid}")"
    [[ "${actual_mem}" == "${expected_mem}" ]] || return 1
    expected_sum=$((expected_sum + expected_mem))
  done

  vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  actual_mem="$(get_vm_memory_mib "${vmid}")"
  [[ "${actual_mem}" == "${VM_TRAIN_MEMORY_MIB}" ]] || return 1
  expected_sum=$((expected_sum + VM_TRAIN_MEMORY_MIB))

  vmid="$(require_vmid "${VM_INFER_NAME}")"
  actual_mem="$(get_vm_memory_mib "${vmid}")"
  [[ "${actual_mem}" == "${VM_INFER_MEMORY_MIB}" ]] || return 1
  expected_sum=$((expected_sum + VM_INFER_MEMORY_MIB))

  actual_sum="${VM_MEMORY_LIMIT_MIB}"
  ((actual_sum >= expected_sum))
}

cpu_plan_check() {
  local vm_name vmid
  local cpu sockets cores numa expected_cores
  local -a profile_nodes=()
  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    profile_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
  else
    profile_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
  fi

  for vm_name in "${profile_nodes[@]}"; do
    vmid="$(require_vmid "${vm_name}")"
    cpu="$(get_vm_config_value "${vmid}" "cpu")"
    sockets="$(get_vm_config_value "${vmid}" "sockets")"
    cores="$(get_vm_config_value "${vmid}" "cores")"
    numa="$(get_vm_config_value "${vmid}" "numa")"
    expected_cores="$(get_gpu_node_cores "${vm_name}")"

    [[ "${cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
    [[ "${sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
    [[ "${cores}" == "${expected_cores}" ]] || return 1
    [[ "${numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
  done

  vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  cpu="$(get_vm_config_value "${vmid}" "cpu")"
  sockets="$(get_vm_config_value "${vmid}" "sockets")"
  cores="$(get_vm_config_value "${vmid}" "cores")"
  numa="$(get_vm_config_value "${vmid}" "numa")"
  [[ "${cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
  [[ "${sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
  [[ "${cores}" == "${VM_TRAIN_CORES}" ]] || return 1
  [[ "${numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1

  vmid="$(require_vmid "${VM_INFER_NAME}")"
  cpu="$(get_vm_config_value "${vmid}" "cpu")"
  sockets="$(get_vm_config_value "${vmid}" "sockets")"
  cores="$(get_vm_config_value "${vmid}" "cores")"
  numa="$(get_vm_config_value "${vmid}" "numa")"
  [[ "${cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
  [[ "${sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
  [[ "${cores}" == "${VM_INFER_CORES}" ]] || return 1
  [[ "${numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
}
