#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPT="${SCRIPT_DIR}/../watchdog/ml-mode-common.sh"
if [[ ! -f "${COMMON_SCRIPT}" ]]; then
  COMMON_SCRIPT="/usr/local/sbin/ml-mode-common.sh"
fi
# shellcheck source=../watchdog/ml-mode-common.sh
source "${COMMON_SCRIPT}"

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: server-audit.sh [--help]

Proxmox-oriented server audit for mlman architecture from:
  ${MLMAN_CONFIG_JSON}
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

declare -a profile_gpu_nodes=()
if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
  profile_gpu_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
else
  profile_gpu_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
fi

declare -a expected_names=("${profile_gpu_nodes[@]}" "${VM_TRAIN_NAME}" "${VM_INFER_NAME}")
declare -A expected_memory=()
declare -A expected_cores=()

for vm_name in "${profile_gpu_nodes[@]}"; do
  expected_memory["${vm_name}"]="$(get_gpu_node_memory_mib "${vm_name}")"
  expected_cores["${vm_name}"]="$(get_gpu_node_cores "${vm_name}")"
done
expected_memory["${VM_TRAIN_NAME}"]="${VM_TRAIN_MEMORY_MIB}"
expected_memory["${VM_INFER_NAME}"]="${VM_INFER_MEMORY_MIB}"
expected_cores["${VM_TRAIN_NAME}"]="${VM_TRAIN_CORES}"
expected_cores["${VM_INFER_NAME}"]="${VM_INFER_CORES}"

cfg_value() {
  local vmid="$1"
  local key="$2"
  qm config "$vmid" | awk -F ': *' -v k="$key" '$1==k {print $2; exit}'
}

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"
echo "User: $(id -un) (uid=$(id -u))"

hr
echo "[Config]"
echo "MLMAN_CONFIG_JSON=${MLMAN_CONFIG_JSON}"
echo "GPU nodes: ${MLMAN_GPU_NODE_NAMES[*]}"
echo "Enabled GPU nodes: ${MLMAN_ENABLED_GPU_NODE_NAMES[*]}"

hr
echo "[Platform]"
if cmd pveversion; then
  pveversion | sed -n '1,20p'
else
  echo "pveversion not found. This does not look like a Proxmox host."
fi

hr
echo "[Core services]"
for svc in pve-cluster pvedaemon pveproxy; do
  if systemctl is-active "$svc" >/dev/null 2>&1; then
    echo "$svc: active"
  else
    echo "$svc: NOT active"
  fi
done
if systemctl is-enabled ml-mode-watchdog.timer >/dev/null 2>&1; then
  echo "ml-mode-watchdog.timer: enabled"
else
  echo "ml-mode-watchdog.timer: disabled"
fi
systemctl is-active ml-mode-watchdog.timer >/dev/null 2>&1 \
  && echo "ml-mode-watchdog.timer: active" \
  || echo "ml-mode-watchdog.timer: NOT active"

hr
echo "[Resources]"
cmd lscpu && lscpu | sed -n '1,25p' || true
cmd free && free -h || true

hr
echo "[Storage]"
if findmnt -no TARGET /mnt/shared-storage >/dev/null 2>&1; then
  findmnt /mnt/shared-storage
else
  echo "/mnt/shared-storage is not mounted"
fi
if [[ -d /mnt/shared-storage/mlshare ]]; then
  ls -la /mnt/shared-storage/mlshare | sed -n '1,40p'
else
  echo "/mnt/shared-storage/mlshare not found"
fi

hr
echo "[VM inventory and profile checks]"
if ! cmd qm; then
  echo "qm not found"
  exit 1
fi
qm list

for vm_name in "${expected_names[@]}"; do
  vmid="$(resolve_vmid_by_name "$vm_name")"
  if [[ -z "$vmid" ]]; then
    echo "[MISSING] $vm_name"
    continue
  fi

  status="$(qm status "$vmid" | awk '{print $2}')"
  memory="$(cfg_value "$vmid" memory)"
  cores="$(cfg_value "$vmid" cores)"
  cpu_type="$(cfg_value "$vmid" cpu)"
  sockets="$(cfg_value "$vmid" sockets)"
  numa="$(cfg_value "$vmid" numa)"

  printf "%s (vmid=%s): status=%s memory=%s cores=%s cpu=%s sockets=%s numa=%s\n" \
    "$vm_name" "$vmid" "$status" "${memory:-?}" "${cores:-?}" "${cpu_type:-?}" "${sockets:-?}" "${numa:-?}"

  if [[ "${memory:-}" == "${expected_memory[$vm_name]}" ]]; then
    echo "  memory: OK (${expected_memory[$vm_name]} MiB)"
  else
    echo "  memory: MISMATCH expected=${expected_memory[$vm_name]} got=${memory:-unset}"
  fi

  if [[ "${cores:-}" == "${expected_cores[$vm_name]}" ]]; then
    echo "  cores: OK (${expected_cores[$vm_name]})"
  else
    echo "  cores: MISMATCH expected=${expected_cores[$vm_name]} got=${cores:-unset}"
  fi
done

hr
echo "Done."
exit 0
