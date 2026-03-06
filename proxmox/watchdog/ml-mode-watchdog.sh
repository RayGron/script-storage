#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

watchdog_main() {
  local train_vmid infer_vmid
  local train_running infer_running

  train_vmid="$(require_vmid "${VM_TRAIN_NAME}")"
  infer_vmid="$(require_vmid "${VM_INFER_NAME}")"

  load_state

  train_running=false
  infer_running=false
  if vm_is_running "${train_vmid}"; then
    train_running=true
  fi
  if vm_is_running "${infer_vmid}"; then
    infer_running=true
  fi

  if [[ "${train_running}" == "false" && "${infer_running}" == "false" ]]; then
    save_state "idle" "watchdog" "idle" "true"
    log_policy "watchdog idle_ok"
    return 0
  fi

  if [[ "${train_running}" == "true" && "${infer_running}" == "true" ]]; then
    # Race resolver: preserve last requested mode, stop the opposite side.
    if [[ "${last_requested_mode}" == "train" ]]; then
      stop_vm_graceful_then_force "${infer_vmid}" 60 "${VM_INFER_NAME}" || return 1
      save_state "train" "watchdog" "train" "true"
      log_policy "watchdog conflict_resolved keep=train stop=infer"
    else
      stop_vm_graceful_then_force "${train_vmid}" 60 "${VM_TRAIN_NAME}" || return 1
      save_state "infer" "watchdog" "infer" "true"
      log_policy "watchdog conflict_resolved keep=infer stop=train"
    fi
  fi

  if [[ "${train_running}" == "true" && "${infer_running}" == "false" ]]; then
    if ram_guard_check; then
      save_state "train" "watchdog" "train" "true"
    else
      save_state "train" "watchdog" "train" "false"
      return 1
    fi
  fi

  if [[ "${train_running}" == "false" && "${infer_running}" == "true" ]]; then
    if ram_guard_check; then
      save_state "infer" "watchdog" "infer" "true"
    else
      save_state "infer" "watchdog" "infer" "false"
      return 1
    fi
  fi
}

run_with_control_lock watchdog_main
