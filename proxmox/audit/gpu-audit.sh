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
Usage: gpu-audit.sh [--help]

Proxmox-oriented GPU audit using node list from:
  ${MLMAN_CONFIG_JSON}
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"

hr
echo "[Configured GPU nodes]"
for vm_name in "${MLMAN_GPU_NODE_NAMES[@]}"; do
  echo "${vm_name}: ip=$(get_gpu_node_ip "${vm_name}") user=$(get_gpu_node_user "${vm_name}") enabled=$(gpu_node_is_enabled "${vm_name}" && echo true || echo false)"
done

hr
echo "[PCI GPUs on host]"
if cmd lspci; then
  lspci -nn | egrep -i "vga|3d|display" || true
else
  echo "lspci not found"
fi

hr
echo "[NVIDIA host view]"
if cmd nvidia-smi; then
  nvidia-smi || true
  echo
  nvidia-smi -L || true
  echo
  nvidia-smi topo -m 2>/dev/null || true
else
  echo "nvidia-smi not found"
fi

hr
echo "[IOMMU / VFIO hints]"
if cmd dmesg; then
  dmesg | egrep -i "iommu|vfio|vt-d|amd-vi" | tail -n 80 || true
else
  echo "dmesg not found"
fi

if cmd lsmod; then
  echo
  echo "Loaded vfio modules:"
  lsmod | egrep '^vfio|^kvm' || true
fi

hr
echo "[Passthrough mapping to configured GPU VMs]"
profile_gpu_nodes=()
if [[ "${#MLMAN_ENABLED_GPU_NODE_NAMES[@]}" -gt 0 ]]; then
  profile_gpu_nodes=("${MLMAN_ENABLED_GPU_NODE_NAMES[@]}")
else
  profile_gpu_nodes=("${MLMAN_GPU_NODE_NAMES[@]}")
fi

for vm_name in "${profile_gpu_nodes[@]}"; do
  vmid="$(resolve_vmid_by_name "$vm_name")"
  if [[ -z "$vmid" ]]; then
    echo "[MISSING] $vm_name"
    continue
  fi

  echo "$vm_name (vmid=$vmid)"
  map_lines="$(qm config "$vmid" | egrep '^hostpci[0-9]+:' || true)"
  if [[ -z "$map_lines" ]]; then
    echo "  hostpci mapping: none"
  else
    count="$(printf '%s\n' "$map_lines" | sed '/^$/d' | wc -l | awk '{print $1}')"
    echo "  hostpci mapping count: $count"
    printf '%s\n' "$map_lines" | sed 's/^/  /'
  fi
done

hr
echo "Done."
exit 0
