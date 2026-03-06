#!/usr/bin/env bash
set -euo pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOU'
Usage: gpu-audit.sh [--help]

Proxmox-oriented GPU audit:
- physical GPU inventory on host
- IOMMU/VFIO visibility
- passthrough mapping to vm-gpu-1 and vm-gpu-2
EOU
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

resolve_vmid_by_name() {
  local name="$1"
  qm list | awk -v vmname="$name" 'NR>1 && $2 == vmname {print $1; exit}'
}

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"

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
echo "[Passthrough mapping to GPU VMs]"
for vm_name in vm-gpu-1 vm-gpu-2; do
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
