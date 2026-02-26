#!/usr/bin/env bash
set -euo pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }
usage() {
  cat <<'EOF'
Usage: server-audit.sh [--help]

Collects a quick server health snapshot (CPU/RAM, disks, network, services, virtualization hints).

Exit codes:
  0  success
  2  invalid usage
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
echo "User: $(id -un) (uid=$(id -u))"
echo "Kernel: $(uname -a)"

hr
echo "[CPU / RAM]"
cmd lscpu && lscpu | sed -n '1,25p' || true
cmd free  && free -h || true
cmd vmstat && vmstat -S M 1 2 || true

hr
echo "[Disk]"
cmd df && df -hT -x tmpfs -x devtmpfs || true
cmd lsblk && lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS,MODEL | sed -n '1,200p' || true

hr
echo "[Network]"
cmd ip && {
  ip -br a
  echo
  ip route
} || true

hr
echo "[Services (docker, ssh)]"
cmd systemctl && {
  systemctl is-active docker 2>/dev/null && echo "docker: active" || echo "docker: not active"
  systemctl is-active ssh 2>/dev/null && echo "ssh: active" || echo "ssh: not active"
} || true

hr
echo "[Virtualization hints]"
cmd systemd-detect-virt && systemd-detect-virt || true
cmd dmesg && dmesg -T | egrep -i "iommu|vt-d|amd-vi|nvidia|nouveau|amdgpu|i915" | tail -n 50 || true

echo
echo "Done."
exit 0
