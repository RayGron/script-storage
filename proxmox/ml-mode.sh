#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

usage() {
  cat <<'EOF'
Usage:
  ml-mode.sh train
  ml-mode.sh infer
  ml-mode.sh stop
  ml-mode.sh status
  ml-mode.sh check

Commands:
  train   Stop vm-infer (if running), start vm-train and GPU workers, enforce RAM guard.
  infer   Stop vm-train (if running), start vm-infer and GPU workers, enforce RAM guard.
  stop    Stop vm-train and vm-infer, keep system in idle mode.
  status  Show current vm status and policy state.
  check   Verify memory plan in MiB and RAM guard threshold.
EOF
}

switch_mode() {
  local target="$1"
  local by="${2:-cli}"
  local train_vmid infer_vmid gpu1_vmid gpu2_vmid

  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"
  gpu1_vmid="$(require_vmid "${VM_GPU_1_NAME}")"
  gpu2_vmid="$(require_vmid "${VM_GPU_2_NAME}")"

  if [[ "${target}" == "train" ]]; then
    stop_vm_graceful_then_force "${infer_vmid}" 60 "${VM_INFER_NAME}" || {
      save_state "infer" "${by}" "train" "false"
      echo "error: cannot stop ${VM_INFER_NAME}" >&2
      exit 1
    }
    start_vm_if_needed "${gpu1_vmid}" "${VM_GPU_1_NAME}"
    start_vm_if_needed "${gpu2_vmid}" "${VM_GPU_2_NAME}"
    start_vm_if_needed "${train_vmid}" "${VM_TRAIN_NAME}"
  else
    stop_vm_graceful_then_force "${train_vmid}" 60 "${VM_TRAIN_NAME}" || {
      save_state "train" "${by}" "infer" "false"
      echo "error: cannot stop ${VM_TRAIN_NAME}" >&2
      exit 1
    }
    start_vm_if_needed "${gpu1_vmid}" "${VM_GPU_1_NAME}"
    start_vm_if_needed "${gpu2_vmid}" "${VM_GPU_2_NAME}"
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
  local train_vmid infer_vmid gpu1_vmid gpu2_vmid
  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"
  gpu1_vmid="$(require_vmid "${VM_GPU_1_NAME}")"
  gpu2_vmid="$(require_vmid "${VM_GPU_2_NAME}")"

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
  ${VM_GPU_1_NAME} (${gpu1_vmid}): $(vm_status "${gpu1_vmid}")
  ${VM_GPU_2_NAME} (${gpu2_vmid}): $(vm_status "${gpu2_vmid}")
ram:
  running_sum_mib: $(running_memory_sum_mib)
  limit_mib: ${VM_MEMORY_LIMIT_MIB}
  host_reserved_mib: ${HOST_RESERVED_MIB}
EOF
}

run_check() {
  if memory_plan_check; then
    echo "memory plan check: PASS (${VM_GPU_1_MEMORY_MIB}/${VM_GPU_2_MEMORY_MIB}/${VM_TRAIN_MEMORY_MIB}/${VM_INFER_MEMORY_MIB} MiB)"
  else
    echo "memory plan check: FAIL (expected ${VM_GPU_1_MEMORY_MIB}/${VM_GPU_2_MEMORY_MIB}/${VM_TRAIN_MEMORY_MIB}/${VM_INFER_MEMORY_MIB} MiB)" >&2
    exit 1
  fi

  if ram_guard_check; then
    echo "ram guard check: PASS (running <= ${VM_MEMORY_LIMIT_MIB} MiB)"
  else
    echo "ram guard check: FAIL (running > ${VM_MEMORY_LIMIT_MIB} MiB)" >&2
    exit 1
  fi
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi
  case "$1" in
    train) switch_mode "train" "cli" ;;
    infer) switch_mode "infer" "cli" ;;
    stop) stop_both "cli" ;;
    status) show_status ;;
    check) run_check ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
