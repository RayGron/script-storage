#!/usr/bin/env bash
set -u
set -o pipefail

usage() {
  cat <<'EOU'
Usage: gpu-test.sh [--help]

Proxmox architecture test suite for:
- vm-gpu-1, vm-gpu-2, vm-train, vm-infer
- CPU/RAM profile compliance
- GPU passthrough presence in gpu VMs
- policy controls (hookscript + watchdog)
- shared-storage layout

Exit codes:
  0  overall PASS
  1  overall FAIL
  2  invalid usage
EOU
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

cmd() { command -v "$1" >/dev/null 2>&1; }

total=0
pass=0
fail=0
warn=0

record() {
  local status="$1"
  local check="$2"
  local details="$3"
  printf "[%s] %s - %s\n" "$status" "$check" "$details"

  case "$status" in
    PASS) ((pass += 1)) ;;
    FAIL) ((fail += 1)) ;;
    WARNING) ((warn += 1)) ;;
  esac
  ((total += 1))
}

resolve_vmid_by_name() {
  local name="$1"
  qm list | awk -v vmname="$name" 'NR>1 && $2 == vmname {print $1; exit}'
}

cfg_value() {
  local vmid="$1"
  local key="$2"
  qm config "$vmid" | awk -F ': *' -v k="$key" '$1==k {print $2; exit}'
}

check_required_cmd() {
  for binary in qm pveversion systemctl; do
    if cmd "$binary"; then
      record PASS "binary:$binary" "found"
    else
      record FAIL "binary:$binary" "missing"
    fi
  done
}

check_expected_vms() {
  local missing=0
  for vm_name in vm-gpu-1 vm-gpu-2 vm-train vm-infer; do
    vmid="$(resolve_vmid_by_name "$vm_name")"
    if [[ -n "$vmid" ]]; then
      record PASS "vm:$vm_name" "vmid=$vmid"
    else
      record FAIL "vm:$vm_name" "not found"
      missing=1
    fi
  done
  return "$missing"
}

check_resource_profile() {
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

  for vm_name in vm-gpu-1 vm-gpu-2 vm-train vm-infer; do
    vmid="$(resolve_vmid_by_name "$vm_name")"
    [[ -z "$vmid" ]] && continue

    memory="$(cfg_value "$vmid" memory)"
    cores="$(cfg_value "$vmid" cores)"
    cpu="$(cfg_value "$vmid" cpu)"
    sockets="$(cfg_value "$vmid" sockets)"
    numa="$(cfg_value "$vmid" numa)"

    [[ "$memory" == "${expected_memory[$vm_name]}" ]] \
      && record PASS "profile:$vm_name:memory" "${memory} MiB" \
      || record FAIL "profile:$vm_name:memory" "expected=${expected_memory[$vm_name]} got=${memory:-unset}"

    [[ "$cores" == "${expected_cores[$vm_name]}" ]] \
      && record PASS "profile:$vm_name:cores" "$cores" \
      || record FAIL "profile:$vm_name:cores" "expected=${expected_cores[$vm_name]} got=${cores:-unset}"

    [[ "$cpu" == "host" ]] \
      && record PASS "profile:$vm_name:cpu" "$cpu" \
      || record FAIL "profile:$vm_name:cpu" "expected=host got=${cpu:-unset}"

    [[ "$sockets" == "1" ]] \
      && record PASS "profile:$vm_name:sockets" "$sockets" \
      || record FAIL "profile:$vm_name:sockets" "expected=1 got=${sockets:-unset}"

    [[ "$numa" == "1" ]] \
      && record PASS "profile:$vm_name:numa" "$numa" \
      || record FAIL "profile:$vm_name:numa" "expected=1 got=${numa:-unset}"
  done
}

check_passthrough_profile() {
  for vm_name in vm-gpu-1 vm-gpu-2; do
    vmid="$(resolve_vmid_by_name "$vm_name")"
    [[ -z "$vmid" ]] && continue

    count="$(qm config "$vmid" | egrep '^hostpci[0-9]+:' | wc -l | awk '{print $1}')"
    if [[ "$count" -ge 2 ]]; then
      record PASS "gpu-passthrough:$vm_name" "hostpci lines=$count"
    elif [[ "$count" -eq 1 ]]; then
      record WARNING "gpu-passthrough:$vm_name" "only 1 hostpci mapping found"
    else
      record FAIL "gpu-passthrough:$vm_name" "no hostpci mappings"
    fi
  done
}

check_policy_guards() {
  local train_vmid infer_vmid
  train_vmid="$(resolve_vmid_by_name vm-train)"
  infer_vmid="$(resolve_vmid_by_name vm-infer)"

  if [[ -n "$train_vmid" ]]; then
    train_hook="$(cfg_value "$train_vmid" hookscript)"
    [[ "$train_hook" == "local:snippets/ml-mode-hook.sh" ]] \
      && record PASS "hook:vm-train" "$train_hook" \
      || record FAIL "hook:vm-train" "expected local:snippets/ml-mode-hook.sh got=${train_hook:-unset}"
  fi

  if [[ -n "$infer_vmid" ]]; then
    infer_hook="$(cfg_value "$infer_vmid" hookscript)"
    [[ "$infer_hook" == "local:snippets/ml-mode-hook.sh" ]] \
      && record PASS "hook:vm-infer" "$infer_hook" \
      || record FAIL "hook:vm-infer" "expected local:snippets/ml-mode-hook.sh got=${infer_hook:-unset}"
  fi

  if systemctl is-enabled ml-mode-watchdog.timer >/dev/null 2>&1; then
    record PASS "watchdog:enabled" "ml-mode-watchdog.timer enabled"
  else
    record FAIL "watchdog:enabled" "ml-mode-watchdog.timer disabled"
  fi

  if systemctl is-active ml-mode-watchdog.timer >/dev/null 2>&1; then
    record PASS "watchdog:active" "ml-mode-watchdog.timer active"
  else
    record FAIL "watchdog:active" "ml-mode-watchdog.timer not active"
  fi
}

check_storage_layout() {
  local root="/mnt/shared-storage/mlshare"
  if [[ -d "$root" ]]; then
    record PASS "storage:root" "$root exists"
  else
    record FAIL "storage:root" "$root missing"
    return
  fi

  for dir in datasets models checkpoints artifacts; do
    if [[ -d "$root/$dir" ]]; then
      record PASS "storage:$dir" "present"
    else
      record FAIL "storage:$dir" "missing"
    fi
  done
}

check_physical_gpu_count() {
  local expected actual
  expected="${EXPECTED_PHYSICAL_GPUS:-4}"

  if cmd nvidia-smi; then
    actual="$(nvidia-smi -L 2>/dev/null | wc -l | awk '{print $1}')"
    if [[ "$actual" -ge "$expected" ]]; then
      record PASS "host-gpus" "expected>=$expected got=$actual"
    else
      record FAIL "host-gpus" "expected>=$expected got=$actual"
    fi
  else
    record WARNING "host-gpus" "nvidia-smi not found"
  fi
}

check_required_cmd
check_expected_vms || true
check_resource_profile
check_passthrough_profile
check_policy_guards
check_storage_layout
check_physical_gpu_count

echo
printf "Summary: total=%d pass=%d warn=%d fail=%d\n" "$total" "$pass" "$warn" "$fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
