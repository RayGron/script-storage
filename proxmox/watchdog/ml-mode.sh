#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

usage() {
  cat <<EOF
Usage:
  mlman train
  mlman infer
  mlman stop
  mlman status
  mlman check
  mlman apply-profile
  mlman model-list
  mlman model-use <alias> [--nodes <name1,name2,...>] [--head-node <name>] [--net-if <iface>]
  mlman model-current
  mlman model-status [--nodes <name1,name2,...>] [--head-node <name>] [--net-if <iface>]

Commands:
  train         Stop vm-infer (if running), start vm-train and enabled GPU workers, enforce RAM guard.
  infer         Stop vm-train (if running), start vm-infer and enabled GPU workers, enforce RAM guard.
  stop          Stop vm-train and vm-infer, keep system in idle mode.
  status        Show current vm status and policy state.
  check         Verify memory+CPU plan and RAM guard threshold.
  apply-profile Apply recommended CPU/memory/NUMA settings to all configured VMs.
  model-list    List model aliases from model registry file.
  model-use     Switch active inference model via vm-infer inferctl.
  model-current Show currently active model tracked by control state.
  model-status  Show vm-infer inference stack status via inferctl.

Model registry format (${ML_MODEL_REGISTRY_FILE}):
  alias|model_id|tp|pp|gpu_memory_utilization
Example:
  qwen3.5-7b|Qwen/Qwen3.5-7B-Instruct|2|2|0.90

Defaults for nodes/network/head are loaded from:
  ${MLMAN_CONFIG_JSON}
EOF
}

ensure_gpu_nodes_available() {
  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -eq 0 ]]; then
    echo "error: no enabled GPU nodes configured in ${MLMAN_CONFIG_JSON}" >&2
    return 1
  fi
  return 0
}

switch_mode() {
  local target="$1"
  local by="${2:-cli}"
  local train_vmid infer_vmid
  local gpu_name gpu_vmid

  ensure_gpu_nodes_available

  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"

  if [[ "${target}" == "train" ]]; then
    stop_vm_graceful_then_force "${infer_vmid}" 60 "${VM_INFER_NAME}" || {
      save_state "infer" "${by}" "train" "false"
      echo "error: cannot stop ${VM_INFER_NAME}" >&2
      exit 1
    }
    for gpu_name in "${MLMAN_ENABLED_GPU_NODE_NAMES[@]}"; do
      gpu_vmid="$(require_vmid "${gpu_name}")"
      start_vm_if_needed "${gpu_vmid}" "${gpu_name}"
    done
    start_vm_if_needed "${train_vmid}" "${VM_TRAIN_NAME}"
  else
    stop_vm_graceful_then_force "${train_vmid}" 60 "${VM_TRAIN_NAME}" || {
      save_state "train" "${by}" "infer" "false"
      echo "error: cannot stop ${VM_TRAIN_NAME}" >&2
      exit 1
    }
    for gpu_name in "${MLMAN_ENABLED_GPU_NODE_NAMES[@]}"; do
      gpu_vmid="$(require_vmid "${gpu_name}")"
      start_vm_if_needed "${gpu_vmid}" "${gpu_name}"
    done
    start_vm_if_needed "${infer_vmid}" "${VM_INFER_NAME}"
  fi

  if ram_guard_check; then
    save_state "${target}" "${by}" "${target}" "true"
    echo "mode switched: ${target}"
  else
    save_state "idle" "${by}" "${target}" "false"
    echo "error: RAM guard failed after switching to ${target}" >&2
    exit 1
  fi
}

stop_both() {
  local by="${1:-cli}"
  local train_vmid infer_vmid
  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"
  stop_vm_graceful_then_force "${train_vmid}" 60 "${VM_TRAIN_NAME}" || true
  stop_vm_graceful_then_force "${infer_vmid}" 60 "${VM_INFER_NAME}" || true

  if ram_guard_check; then
    save_state "idle" "${by}" "idle" "true"
  else
    save_state "idle" "${by}" "idle" "false"
  fi
  echo "mode switched: idle"
}

show_status() {
  local train_vmid infer_vmid gpu_name gpu_vmid
  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"

  load_state
  cat <<EOF
state:
  active_mode: ${active_mode}
  last_switch_by: ${last_switch_by}
  last_switch_ts: ${last_switch_ts}
  last_requested_mode: ${last_requested_mode}
  ram_guard_passed: ${ram_guard_passed}
vms:
  ${VM_TRAIN_NAME} (${train_vmid}): $(vm_status "${train_vmid}")
  ${VM_INFER_NAME} (${infer_vmid}): $(vm_status "${infer_vmid}")
EOF
  for gpu_name in "${MLMAN_GPU_NODE_NAMES[@]}"; do
    gpu_vmid="$(resolve_vmid_by_name "${gpu_name}")"
    if [[ -n "${gpu_vmid}" ]]; then
      echo "  ${gpu_name} (${gpu_vmid}): $(vm_status "${gpu_vmid}") enabled=$(gpu_node_is_enabled "${gpu_name}" && echo true || echo false)"
    else
      echo "  ${gpu_name}: missing-in-qm enabled=$(gpu_node_is_enabled "${gpu_name}" && echo true || echo false)"
    fi
  done

  cat <<EOF
ram:
  running_sum_mib: $(running_memory_sum_mib)
  limit_mib: ${VM_MEMORY_LIMIT_MIB}
  host_reserved_mib: ${HOST_RESERVED_MIB}
EOF
  if load_active_model; then
    cat <<EOF
model:
  active_model_alias: ${active_model_alias}
  active_model_id: ${active_model_id}
  tp: ${active_model_tp}
  pp: ${active_model_pp}
  gpu_memory_utilization: ${active_model_gpu_memory_utilization}
  switched_by: ${switched_by}
  switched_at: ${switched_at}
EOF
  else
    echo "model:"
    echo "  active_model: unset"
  fi
}

run_check() {
  local mem_chunks=()
  local core_chunks=()
  local gpu_name
  local -a profile_nodes=()

  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    profile_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
  else
    profile_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
  fi

  for gpu_name in "${profile_nodes[@]}"; do
    mem_chunks+=("${gpu_name}=$(get_gpu_node_memory_mib "${gpu_name}")")
    core_chunks+=("${gpu_name}=$(get_gpu_node_cores "${gpu_name}")")
  done
  mem_chunks+=("${VM_TRAIN_NAME}=${VM_TRAIN_MEMORY_MIB}")
  mem_chunks+=("${VM_INFER_NAME}=${VM_INFER_MEMORY_MIB}")
  core_chunks+=("${VM_TRAIN_NAME}=${VM_TRAIN_CORES}")
  core_chunks+=("${VM_INFER_NAME}=${VM_INFER_CORES}")

  if memory_plan_check; then
    echo "memory plan check: PASS (${mem_chunks[*]} MiB)"
  else
    echo "memory plan check: FAIL (${mem_chunks[*]} expected)" >&2
    exit 1
  fi

  if ram_guard_check; then
    echo "ram guard check: PASS (running <= ${VM_MEMORY_LIMIT_MIB} MiB)"
  else
    echo "ram guard check: FAIL (running > ${VM_MEMORY_LIMIT_MIB} MiB)" >&2
    exit 1
  fi

  if cpu_plan_check; then
    echo "cpu plan check: PASS (cpu=${VM_DEFAULT_CPU_TYPE}, sockets=${VM_DEFAULT_SOCKETS}, cores=${core_chunks[*]}, numa=${VM_DEFAULT_NUMA})"
  else
    echo "cpu plan check: FAIL (expected cpu=${VM_DEFAULT_CPU_TYPE}, sockets=${VM_DEFAULT_SOCKETS}, cores=${core_chunks[*]}, numa=${VM_DEFAULT_NUMA})" >&2
    exit 1
  fi
}

apply_profile() {
  local train_vmid infer_vmid gpu_name gpu_vmid
  local -a profile_nodes=()
  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"

  if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
    profile_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
  else
    profile_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
  fi

  for gpu_name in "${profile_nodes[@]}"; do
    gpu_vmid="$(require_vmid "${gpu_name}")"
    qm set "${gpu_vmid}" \
      --cpu "${VM_DEFAULT_CPU_TYPE}" \
      --sockets "${VM_DEFAULT_SOCKETS}" \
      --cores "$(get_gpu_node_cores "${gpu_name}")" \
      --numa "${VM_DEFAULT_NUMA}" \
      --memory "$(get_gpu_node_memory_mib "${gpu_name}")" \
      --balloon "$(get_gpu_node_memory_mib "${gpu_name}")" \
      --agent 1
  done

  qm set "${train_vmid}" --cpu "${VM_DEFAULT_CPU_TYPE}" --sockets "${VM_DEFAULT_SOCKETS}" --cores "${VM_TRAIN_CORES}" --numa "${VM_DEFAULT_NUMA}" --memory "${VM_TRAIN_MEMORY_MIB}" --balloon "${VM_TRAIN_MEMORY_MIB}" --agent 1
  qm set "${infer_vmid}" --cpu "${VM_DEFAULT_CPU_TYPE}" --sockets "${VM_DEFAULT_SOCKETS}" --cores "${VM_INFER_CORES}" --numa "${VM_DEFAULT_NUMA}" --memory "${VM_INFER_MEMORY_MIB}" --balloon "${VM_INFER_MEMORY_MIB}" --agent 1

  echo "profile applied: CPU and memory settings updated for ${#profile_nodes[@]} GPU VMs + ${VM_TRAIN_NAME}/${VM_INFER_NAME}"
}

model_registry_exists() {
  [[ -f "${ML_MODEL_REGISTRY_FILE}" ]]
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

model_list() {
  if ! model_registry_exists; then
    echo "model registry not found: ${ML_MODEL_REGISTRY_FILE}" >&2
    return 1
  fi

  printf "%-20s %-56s %-4s %-4s %-8s\n" "ALIAS" "MODEL_ID" "TP" "PP" "GPU_MEM"
  awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
      for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      tp = ($3 == "" ? "2" : $3)
      pp = ($4 == "" ? "2" : $4)
      gm = ($5 == "" ? "0.90" : $5)
      printf "%-20s %-56s %-4s %-4s %-8s\n", $1, $2, tp, pp, gm
    }
  ' "${ML_MODEL_REGISTRY_FILE}"
}

read_model_entry() {
  local alias="$1"
  local line

  if ! model_registry_exists; then
    echo "error: model registry not found: ${ML_MODEL_REGISTRY_FILE}" >&2
    return 1
  fi

  line="$(awk -F'|' -v wanted="${alias}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
      for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      if ($1 == wanted) {
        print $1 "|" $2 "|" $3 "|" $4 "|" $5
        found=1
        exit 0
      }
    }
    END { if (!found) exit 1 }
  ' "${ML_MODEL_REGISTRY_FILE}")" || {
    echo "error: model alias not found: ${alias}" >&2
    return 1
  }

  IFS='|' read -r MODEL_ALIAS MODEL_ID MODEL_TP MODEL_PP MODEL_GPU_MEM_UTIL <<<"${line}"
  MODEL_TP="${MODEL_TP:-2}"
  MODEL_PP="${MODEL_PP:-2}"
  MODEL_GPU_MEM_UTIL="${MODEL_GPU_MEM_UTIL:-0.90}"

  if ! is_positive_int "${MODEL_TP}"; then
    echo "error: invalid tp for alias '${alias}': ${MODEL_TP}" >&2
    return 1
  fi
  if ! is_positive_int "${MODEL_PP}"; then
    echo "error: invalid pp for alias '${alias}': ${MODEL_PP}" >&2
    return 1
  fi
  if ! is_valid_gpu_mem_util "${MODEL_GPU_MEM_UTIL}"; then
    echo "error: invalid gpu_memory_utilization for alias '${alias}': ${MODEL_GPU_MEM_UTIL}" >&2
    return 1
  fi

  if [[ -z "${MODEL_ID}" ]]; then
    echo "error: model_id is empty for alias: ${alias}" >&2
    return 1
  fi
}

ensure_infer_mode_for_model_switch() {
  local mode
  mode="$(current_runtime_mode)"
  if [[ "${mode}" != "infer" ]]; then
    echo "error: model switch allowed only in infer mode; current mode=${mode}" >&2
    return 1
  fi
  return 0
}

parse_inferctl_target_args() {
  local ctx="$1"
  shift

  local nodes_csv=""
  local head_node=""
  local net_if="${MLMAN_DEFAULT_NET_IF:-eth0}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes)
        [[ $# -ge 2 ]] || { echo "error: --nodes requires a value" >&2; return 1; }
        nodes_csv="${2:-}"
        shift 2
        ;;
      --head-node)
        [[ $# -ge 2 ]] || { echo "error: --head-node requires a value" >&2; return 1; }
        head_node="${2:-}"
        shift 2
        ;;
      --net-if)
        [[ $# -ge 2 ]] || { echo "error: --net-if requires a value" >&2; return 1; }
        net_if="${2:-}"
        shift 2
        ;;
      *)
        echo "error: unknown argument for ${ctx}: $1" >&2
        return 1
        ;;
    esac
  done

  INFERCTL_NODES_CSV="${nodes_csv}"
  INFERCTL_HEAD_NODE="${head_node}"
  INFERCTL_NET_IF="${net_if}"
}

model_use_impl() {
  local alias="$1"
  local by="${2:-cli}"
  local nodes_csv="$3"
  local head_node="$4"
  local net_if="$5"
  local -a cmd

  ensure_infer_mode_for_model_switch
  read_model_entry "${alias}"

  cmd=(
    "${ML_INFERCTL_PATH}" switch-model
    --model-id "${MODEL_ID}"
    --tp "${MODEL_TP}"
    --pp "${MODEL_PP}"
    --gpu-memory-utilization "${MODEL_GPU_MEM_UTIL}"
    --net-if "${net_if}"
  )
  if [[ -n "${nodes_csv}" ]]; then
    cmd+=(--nodes "${nodes_csv}")
  fi
  if [[ -n "${head_node}" ]]; then
    cmd+=(--head-node "${head_node}")
  fi

  inferctl_exec "${cmd[@]}"

  save_active_model "${MODEL_ALIAS}" "${MODEL_ID}" "${MODEL_TP}" "${MODEL_PP}" "${MODEL_GPU_MEM_UTIL}" "${by}"
  log_policy "model_switch_ok alias=${MODEL_ALIAS} model_id=${MODEL_ID} tp=${MODEL_TP} pp=${MODEL_PP} gpu_mem=${MODEL_GPU_MEM_UTIL} by=${by}"
  echo "model switched: alias=${MODEL_ALIAS} model_id=${MODEL_ID} tp=${MODEL_TP} pp=${MODEL_PP}"
}

model_current() {
  if load_active_model; then
    cat <<EOF
active_model_alias=${active_model_alias}
active_model_id=${active_model_id}
active_model_tp=${active_model_tp}
active_model_pp=${active_model_pp}
active_model_gpu_memory_utilization=${active_model_gpu_memory_utilization}
switched_by=${switched_by}
switched_at=${switched_at}
EOF
  else
    echo "active model is not set"
    return 1
  fi
}

model_status_impl() {
  local nodes_csv="$1"
  local head_node="$2"
  local net_if="$3"
  local -a cmd

  cmd=("${ML_INFERCTL_PATH}" status --net-if "${net_if}")
  [[ -n "${nodes_csv}" ]] && cmd+=(--nodes "${nodes_csv}")
  [[ -n "${head_node}" ]] && cmd+=(--head-node "${head_node}")

  inferctl_exec "${cmd[@]}"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  case "$1" in
    train)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      run_with_control_lock switch_mode "train" "cli"
      ;;
    infer)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      run_with_control_lock switch_mode "infer" "cli"
      ;;
    stop)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      run_with_control_lock stop_both "cli"
      ;;
    status)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      show_status
      ;;
    check)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      run_check
      ;;
    apply-profile)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      run_with_control_lock apply_profile
      ;;
    model-list)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      model_list
      ;;
    model-use)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      local alias="$2"
      shift 2
      parse_inferctl_target_args "model-use" "$@" || { usage >&2; exit 2; }
      run_with_control_lock model_use_impl "${alias}" "cli" "${INFERCTL_NODES_CSV}" "${INFERCTL_HEAD_NODE}" "${INFERCTL_NET_IF}"
      ;;
    model-current)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      model_current
      ;;
    model-status)
      [[ $# -ge 1 ]] || { usage; exit 2; }
      shift 1
      parse_inferctl_target_args "model-status" "$@" || { usage >&2; exit 2; }
      model_status_impl "${INFERCTL_NODES_CSV}" "${INFERCTL_HEAD_NODE}" "${INFERCTL_NET_IF}"
      ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
