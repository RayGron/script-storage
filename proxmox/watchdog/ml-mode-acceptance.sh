#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

usage() {
  cat <<'EOF'
Usage: ml-mode-acceptance.sh

Checks:
  1) VM memory values are exactly:
     vm-gpu-1=90112, vm-gpu-2=90112, vm-train=34816, vm-infer=16384 (MiB)
  2) Running VM memory sum is <= 231424 MiB
  3) CPU profile is exactly:
     cpu=host, sockets=1, numa=1, cores=96/96/24/16
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if memory_plan_check; then
  echo "[PASS] memory values in MiB match expected plan: 90112/90112/34816/16384"
else
  echo "[FAIL] memory values do not match expected plan" >&2
  exit 1
fi

if ram_guard_check; then
  echo "[PASS] RAM guard: running memory sum <= ${VM_MEMORY_LIMIT_MIB} MiB"
else
  echo "[FAIL] RAM guard: running memory sum > ${VM_MEMORY_LIMIT_MIB} MiB" >&2
  exit 1
fi

if cpu_plan_check; then
  echo "[PASS] CPU profile matches expected plan: cpu=${VM_DEFAULT_CPU_TYPE}, sockets=${VM_DEFAULT_SOCKETS}, cores=${VM_GPU_1_CORES}/${VM_GPU_2_CORES}/${VM_TRAIN_CORES}/${VM_INFER_CORES}, numa=${VM_DEFAULT_NUMA}"
else
  echo "[FAIL] CPU profile does not match expected plan" >&2
  exit 1
fi
