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
