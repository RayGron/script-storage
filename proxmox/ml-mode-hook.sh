#!/usr/bin/env bash
set -euo pipefail

# Proxmox VM hookscript.
# Args: <vmid> <phase>

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPT="${SCRIPT_DIR}/ml-mode-common.sh"
if [[ ! -f "${COMMON_SCRIPT}" ]]; then
  COMMON_SCRIPT="/usr/local/sbin/ml-mode-common.sh"
fi
# shellcheck source=./ml-mode-common.sh
source "${COMMON_SCRIPT}"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <vmid> <phase>" >&2
  exit 2
fi

TARGET_VMID="$1"
PHASE="$2"

if [[ "${PHASE}" != "pre-start" ]]; then
  exit 0
fi

TRAIN_VMID="$(require_vmid "${VM_TRAIN_NAME}")"
INFER_VMID="$(require_vmid "${VM_INFER_NAME}")"

if [[ "${TARGET_VMID}" == "${TRAIN_VMID}" ]]; then
  log_policy "hook pre-start target=${VM_TRAIN_NAME} vmid=${TARGET_VMID}"
  stop_vm_graceful_then_force "${INFER_VMID}" 60 "${VM_INFER_NAME}" || {
    save_state "infer" "hook" "train" "false"
    echo "error: cannot stop ${VM_INFER_NAME} before starting ${VM_TRAIN_NAME}" >&2
    exit 1
  }
  if ram_guard_check; then
    save_state "train" "hook" "train" "true"
  else
    save_state "idle" "hook" "train" "false"
    echo "error: RAM guard failed before starting ${VM_TRAIN_NAME}" >&2
    exit 1
  fi
fi

if [[ "${TARGET_VMID}" == "${INFER_VMID}" ]]; then
  log_policy "hook pre-start target=${VM_INFER_NAME} vmid=${TARGET_VMID}"
  stop_vm_graceful_then_force "${TRAIN_VMID}" 60 "${VM_TRAIN_NAME}" || {
    save_state "train" "hook" "infer" "false"
    echo "error: cannot stop ${VM_TRAIN_NAME} before starting ${VM_INFER_NAME}" >&2
    exit 1
  }
  if ram_guard_check; then
    save_state "infer" "hook" "infer" "true"
  else
    save_state "idle" "hook" "infer" "false"
    echo "error: RAM guard failed before starting ${VM_INFER_NAME}" >&2
    exit 1
  fi
fi
