#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ml-mode-common.sh
source "${SCRIPT_DIR}/ml-mode-common.sh"

usage() {
  cat <<'EOF'
Usage: ml-mode-acceptance.sh

Checks:
  1) VM memory values match configured profile from mlman JSON
  2) Running VM memory sum is <= configured RAM guard limit
  3) CPU profile matches configured defaults and per-VM core plan
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if memory_plan_check; then
  echo "[PASS] memory values in MiB match configured plan"
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
  echo "[PASS] CPU profile matches expected plan: cpu=${VM_DEFAULT_CPU_TYPE}, sockets=${VM_DEFAULT_SOCKETS}, numa=${VM_DEFAULT_NUMA}"
else
  echo "[FAIL] CPU profile does not match expected plan" >&2
  exit 1
fi
