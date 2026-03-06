#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

TRAIN_VMID="$(require_vmid "${VM_TRAIN_NAME}")"
INFER_VMID="$(require_vmid "${VM_INFER_NAME}")"

load_state

train_running=false
infer_running=false
if vm_is_running "${TRAIN_VMID}"; then
  train_running=true
fi
if vm_is_running "${INFER_VMID}"; then
  infer_running=true
fi

if [[ "${train_running}" == "false" && "${infer_running}" == "false" ]]; then
  save_state "idle" "watchdog" "idle" "true"
  log_policy "watchdog idle_ok"
  exit 0
fi

if [[ "${train_running}" == "true" && "${infer_running}" == "true" ]]; then
  # Race resolver: preserve last requested mode, stop the opposite side.
  if [[ "${last_requested_mode}" == "train" ]]; then
    stop_vm_graceful_then_force "${INFER_VMID}" 60 "${VM_INFER_NAME}" || exit 1
    save_state "train" "watchdog" "train" "true"
    log_policy "watchdog conflict_resolved keep=train stop=infer"
  else
    stop_vm_graceful_then_force "${TRAIN_VMID}" 60 "${VM_TRAIN_NAME}" || exit 1
    save_state "infer" "watchdog" "infer" "true"
    log_policy "watchdog conflict_resolved keep=infer stop=train"
  fi
fi

if [[ "${train_running}" == "true" && "${infer_running}" == "false" ]]; then
  if ram_guard_check; then
    save_state "train" "watchdog" "train" "true"
  else
    save_state "train" "watchdog" "train" "false"
    exit 1
  fi
fi

if [[ "${train_running}" == "false" && "${infer_running}" == "true" ]]; then
  if ram_guard_check; then
    save_state "infer" "watchdog" "infer" "true"
  else
    save_state "infer" "watchdog" "infer" "false"
    exit 1
  fi
fi
