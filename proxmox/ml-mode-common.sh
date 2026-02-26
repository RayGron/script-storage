#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for ml-mode, hookscript, and watchdog.

ML_MODE_STATE_DIR="${ML_MODE_STATE_DIR:-/var/lib/ml-mode}"
ML_MODE_LOG_DIR="${ML_MODE_LOG_DIR:-/var/log/ml-mode}"
ML_MODE_STATE_FILE="${ML_MODE_STATE_FILE:-${ML_MODE_STATE_DIR}/state.env}"
ML_MODE_POLICY_LOG="${ML_MODE_POLICY_LOG:-${ML_MODE_LOG_DIR}/policy.log}"

VM_TRAIN_NAME="${VM_TRAIN_NAME:-vm-train}"
VM_INFER_NAME="${VM_INFER_NAME:-vm-infer}"
VM_GPU_1_NAME="${VM_GPU_1_NAME:-vm-gpu-1}"
VM_GPU_2_NAME="${VM_GPU_2_NAME:-vm-gpu-2}"

HOST_RESERVED_MIB="${HOST_RESERVED_MIB:-30720}"
VM_MEMORY_LIMIT_MIB="${VM_MEMORY_LIMIT_MIB:-231424}"

VM_GPU_1_MEMORY_MIB="${VM_GPU_1_MEMORY_MIB:-90112}"
VM_GPU_2_MEMORY_MIB="${VM_GPU_2_MEMORY_MIB:-90112}"
VM_TRAIN_MEMORY_MIB="${VM_TRAIN_MEMORY_MIB:-34816}"
VM_INFER_MEMORY_MIB="${VM_INFER_MEMORY_MIB:-16384}"

VM_GPU_1_CORES="${VM_GPU_1_CORES:-96}"
VM_GPU_2_CORES="${VM_GPU_2_CORES:-96}"
VM_TRAIN_CORES="${VM_TRAIN_CORES:-24}"
VM_INFER_CORES="${VM_INFER_CORES:-16}"

VM_DEFAULT_SOCKETS="${VM_DEFAULT_SOCKETS:-1}"
VM_DEFAULT_NUMA="${VM_DEFAULT_NUMA:-1}"
VM_DEFAULT_CPU_TYPE="${VM_DEFAULT_CPU_TYPE:-host}"

ensure_runtime_dirs() {
  mkdir -p "${ML_MODE_STATE_DIR}" "${ML_MODE_LOG_DIR}"
  if [[ ! -f "${ML_MODE_STATE_FILE}" ]]; then
    cat >"${ML_MODE_STATE_FILE}" <<EOF
active_mode=idle
last_switch_by=init
last_switch_ts=$(date -Is)
last_requested_mode=idle
ram_guard_passed=true
policy_version=v6
EOF
  fi
}

log_policy() {
  local msg="$1"
  ensure_runtime_dirs
  printf "%s %s\n" "$(date -Is)" "${msg}" >>"${ML_MODE_POLICY_LOG}"
}

load_state() {
  ensure_runtime_dirs
  # shellcheck disable=SC1090
  source "${ML_MODE_STATE_FILE}"
}

save_state() {
  local active_mode="$1"
  local last_switch_by="$2"
  local last_requested_mode="$3"
  local ram_guard_passed="$4"
  ensure_runtime_dirs
  cat >"${ML_MODE_STATE_FILE}" <<EOF
active_mode=${active_mode}
last_switch_by=${last_switch_by}
last_switch_ts=$(date -Is)
last_requested_mode=${last_requested_mode}
ram_guard_passed=${ram_guard_passed}
policy_version=v6
EOF
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
  local gpu1 gpu2 train infer sum
  gpu1="$(require_vmid "${VM_GPU_1_NAME}")"
  gpu2="$(require_vmid "${VM_GPU_2_NAME}")"
  train="$(require_vmid "${VM_TRAIN_NAME}")"
  infer="$(require_vmid "${VM_INFER_NAME}")"

  local gpu1_mem gpu2_mem train_mem infer_mem
  gpu1_mem="$(get_vm_memory_mib "${gpu1}")"
  gpu2_mem="$(get_vm_memory_mib "${gpu2}")"
  train_mem="$(get_vm_memory_mib "${train}")"
  infer_mem="$(get_vm_memory_mib "${infer}")"

  [[ "${gpu1_mem}" == "${VM_GPU_1_MEMORY_MIB}" ]] || return 1
  [[ "${gpu2_mem}" == "${VM_GPU_2_MEMORY_MIB}" ]] || return 1
  [[ "${train_mem}" == "${VM_TRAIN_MEMORY_MIB}" ]] || return 1
  [[ "${infer_mem}" == "${VM_INFER_MEMORY_MIB}" ]] || return 1

  sum=$((gpu1_mem + gpu2_mem + train_mem + infer_mem))
  ((sum == VM_MEMORY_LIMIT_MIB))
}

cpu_plan_check() {
  local gpu1 gpu2 train infer
  gpu1="$(require_vmid "${VM_GPU_1_NAME}")"
  gpu2="$(require_vmid "${VM_GPU_2_NAME}")"
  train="$(require_vmid "${VM_TRAIN_NAME}")"
  infer="$(require_vmid "${VM_INFER_NAME}")"

  local gpu1_cpu gpu2_cpu train_cpu infer_cpu
  local gpu1_sockets gpu2_sockets train_sockets infer_sockets
  local gpu1_cores gpu2_cores train_cores infer_cores
  local gpu1_numa gpu2_numa train_numa infer_numa

  gpu1_cpu="$(get_vm_config_value "${gpu1}" "cpu")"
  gpu2_cpu="$(get_vm_config_value "${gpu2}" "cpu")"
  train_cpu="$(get_vm_config_value "${train}" "cpu")"
  infer_cpu="$(get_vm_config_value "${infer}" "cpu")"

  gpu1_sockets="$(get_vm_config_value "${gpu1}" "sockets")"
  gpu2_sockets="$(get_vm_config_value "${gpu2}" "sockets")"
  train_sockets="$(get_vm_config_value "${train}" "sockets")"
  infer_sockets="$(get_vm_config_value "${infer}" "sockets")"

  gpu1_cores="$(get_vm_config_value "${gpu1}" "cores")"
  gpu2_cores="$(get_vm_config_value "${gpu2}" "cores")"
  train_cores="$(get_vm_config_value "${train}" "cores")"
  infer_cores="$(get_vm_config_value "${infer}" "cores")"

  gpu1_numa="$(get_vm_config_value "${gpu1}" "numa")"
  gpu2_numa="$(get_vm_config_value "${gpu2}" "numa")"
  train_numa="$(get_vm_config_value "${train}" "numa")"
  infer_numa="$(get_vm_config_value "${infer}" "numa")"

  [[ "${gpu1_cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
  [[ "${gpu2_cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
  [[ "${train_cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1
  [[ "${infer_cpu}" == "${VM_DEFAULT_CPU_TYPE}" ]] || return 1

  [[ "${gpu1_sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
  [[ "${gpu2_sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
  [[ "${train_sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1
  [[ "${infer_sockets}" == "${VM_DEFAULT_SOCKETS}" ]] || return 1

  [[ "${gpu1_cores}" == "${VM_GPU_1_CORES}" ]] || return 1
  [[ "${gpu2_cores}" == "${VM_GPU_2_CORES}" ]] || return 1
  [[ "${train_cores}" == "${VM_TRAIN_CORES}" ]] || return 1
  [[ "${infer_cores}" == "${VM_INFER_CORES}" ]] || return 1

  [[ "${gpu1_numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
  [[ "${gpu2_numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
  [[ "${train_numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
  [[ "${infer_numa}" == "${VM_DEFAULT_NUMA}" ]] || return 1
}
