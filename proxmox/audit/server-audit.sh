#!/usr/bin/env bash
set -euo pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOU'
Usage: server-audit.sh [--help]

Proxmox-oriented server audit for the architecture:
- vm-gpu-1, vm-gpu-2, vm-train, vm-infer
- shared storage at /mnt/shared-storage/mlshare
- policy watchdog via ml-mode-watchdog.timer
EOU
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

expected_names=(vm-gpu-1 vm-gpu-2 vm-train vm-infer)

declare -A expected_memory=(
  [vm-gpu-1]=90112
  [vm-gpu-2]=90112
  [vm-train]=34816
  [vm-infer]=16384
)

declare -A expected_cores=(
  [vm-gpu-1]=96
  [vm-gpu-2]=96
  [vm-train]=24
  [vm-infer]=16
)

resolve_vmid_by_name() {
  local name="$1"
  qm list | awk -v vmname="$name" 'NR>1 && $2 == vmname {print $1; exit}'
}

cfg_value() {
  local vmid="$1"
  local key="$2"
  qm config "$vmid" | awk -F ': *' -v k="$key" '$1==k {print $2; exit}'
}

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"
echo "User: $(id -un) (uid=$(id -u))"

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
