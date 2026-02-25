#!/usr/bin/env bash
set -euo pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"

hr
echo "[PCI: detected GPUs]"
if cmd lspci; then
  lspci -nn | egrep -i "vga|3d|display" || true
else
  echo "lspci not found (install pciutils)"
fi

hr
echo "[lshw (may need sudo for full info)]"
if cmd lshw; then
  if [[ $EUID -ne 0 ]]; then
    echo "(running without sudo; some fields may be missing)"
  fi
  lshw -C display 2>/dev/null || true
else
  echo "lshw not found (install lshw)"
fi

hr
echo "[NVIDIA]"
if cmd nvidia-smi; then
  nvidia-smi || true
  echo
  echo "GPUs:"
  nvidia-smi -L || true
  echo
  echo "Details:"
  nvidia-smi --query-gpu=index,name,uuid,serial,pci.bus_id,driver_version,vbios_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,power.limit \
    --format=csv,noheader,nounits || true
  echo
  echo "Topology (if supported):"
  nvidia-smi topo -m 2>/dev/null || true
else
  echo "nvidia-smi not found (no NVIDIA driver/tools or not NVIDIA GPU)."
fi

hr
echo "[AMD ROCm]"
if cmd rocm-smi; then
  rocm-smi || true
else
  echo "rocm-smi not found."
fi
if cmd rocminfo; then
  rocminfo | sed -n '1,120p' || true
fi

hr
echo "[Intel GPU]"
if cmd intel_gpu_top; then
  echo "intel_gpu_top exists (interactive tool)."
else
  echo "intel_gpu_top not found (package: intel-gpu-tools)."
fi

hr
echo "[Device nodes]"
ls -l /dev/nvidia* 2>/dev/null || true
ls -l /dev/dri/* 2>/dev/null || true

echo
echo "Done."