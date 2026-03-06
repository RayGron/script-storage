#!/usr/bin/env bash
set -u
set -o pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }
usage() {
  cat <<'EOF'
Usage: gpu-test.sh [--help]

Runs GPU availability checks and compute smoke tests (PyTorch/CuPy/OpenCL when available).

Exit codes:
  0  overall PASS
  1  overall FAIL
  2  invalid usage
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

total_checks=0
pass_count=0
fail_count=0
skip_count=0
warn_count=0
compute_checks=0
compute_pass=0
compute_gpu_total=0
compute_gpu_pass=0
backend_torch=0
backend_cupy=0
backend_opencl=0
declare -a system_gpu_list=()
declare -a available_gpu_list=()

record_result() {
  local check="$1"
  local status="$2"
  local details="$3"

  printf "[%s] %s - %s\n" "$status" "$check" "$details"

  case "$status" in
    PASS) ((pass_count += 1)) ;;
    FAIL) ((fail_count += 1)) ;;
    SKIP) ((skip_count += 1)) ;;
    WARNING) ((warn_count += 1)) ;;
    *) return 0 ;;
  esac

  ((total_checks += 1))
  if [[ "$check" == compute:* ]]; then
    ((compute_checks += 1))
    if [[ "$status" == "PASS" ]]; then
      ((compute_pass += 1))
    fi
  fi

  if [[ "$check" == compute:*:gpu* ]]; then
    ((compute_gpu_total += 1))
    if [[ "$status" == "PASS" ]]; then
      ((compute_gpu_pass += 1))
    fi
  fi
}

detect_python_backends() {
  backend_torch=0
  backend_cupy=0
  backend_opencl=0

  if ! cmd python3; then
    return 1
  fi

  local backend_state
  backend_state="$(python3 - <<'PY' 2>/dev/null
import importlib

def usable(name):
    try:
        importlib.import_module(name)
        return 1
    except Exception:
        return 0

print(f"torch={usable('torch')}")
print(f"cupy={usable('cupy')}")
print(f"pyopencl={usable('pyopencl')}")
PY
)"

  while IFS='=' read -r name value; do
    case "$name" in
      torch) backend_torch="${value:-0}" ;;
      cupy) backend_cupy="${value:-0}" ;;
      pyopencl) backend_opencl="${value:-0}" ;;
    esac
  done <<< "$backend_state"
  return 0
}

have_any_backend() {
  [[ "$backend_torch" -eq 1 || "$backend_cupy" -eq 1 || "$backend_opencl" -eq 1 ]]
}

ensure_pip_available() {
  if python3 -m pip --version >/dev/null 2>&1; then
    record_result "backend:pip" "PASS" "pip is available"
    return 0
  fi

  record_result "backend:pip" "SKIP" "pip not found. Attempting bootstrap."

  if python3 -m ensurepip --upgrade >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    record_result "backend:pip" "PASS" "pip bootstrapped with ensurepip"
    return 0
  fi

  local -a sudo_cmd=()
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if cmd sudo && sudo -n true >/dev/null 2>&1; then
      sudo_cmd=(sudo -n)
    else
      record_result "backend:pip" "FAIL" "pip missing and non-interactive privilege escalation is unavailable"
      return 1
    fi
  fi

  if cmd apt-get; then
    if DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get update -y >/dev/null 2>&1 \
      && DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y python3-pip >/dev/null 2>&1 \
      && python3 -m pip --version >/dev/null 2>&1; then
      record_result "backend:pip" "PASS" "pip installed via apt-get"
      return 0
    fi
  elif cmd dnf; then
    if "${sudo_cmd[@]}" dnf install -y python3-pip >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
      record_result "backend:pip" "PASS" "pip installed via dnf"
      return 0
    fi
  elif cmd yum; then
    if "${sudo_cmd[@]}" yum install -y python3-pip >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
      record_result "backend:pip" "PASS" "pip installed via yum"
      return 0
    fi
  elif cmd apk; then
    if "${sudo_cmd[@]}" apk add --no-cache py3-pip >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
      record_result "backend:pip" "PASS" "pip installed via apk"
      return 0
    fi
  fi

  record_result "backend:pip" "FAIL" "pip is unavailable and automatic installation failed"
  return 1
}

try_pip_install() {
  local label="$1"
  shift

  local log_file
  log_file="$(mktemp 2>/dev/null || echo "/tmp/gpu-test-install.log")"

  if python3 -m pip install --user --upgrade "$@" >"$log_file" 2>&1; then
    record_result "backend:install:${label}" "PASS" "Installed package(s): $*"
    rm -f "$log_file" >/dev/null 2>&1 || true
    return 0
  fi

  # Debian/Ubuntu PEP 668 guard: retry with explicit override flag.
  if grep -Eiq 'externally-managed-environment|PEP 668|externally managed' "$log_file"; then
    if python3 -m pip install --user --upgrade --break-system-packages "$@" >"$log_file" 2>&1; then
      record_result "backend:install:${label}" "PASS" "Installed package(s) with --break-system-packages: $*"
      rm -f "$log_file" >/dev/null 2>&1 || true
      return 0
    fi
  fi

  local tail_line
  tail_line="$(grep -Eim1 'ERROR:|error:|PEP 668|externally-managed-environment' "$log_file" || tail -n 1 "$log_file" || echo "pip install failed")"
  record_result "backend:install:${label}" "SKIP" "Install attempt failed: ${tail_line}"
  rm -f "$log_file" >/dev/null 2>&1 || true
  return 1
}

check_cupy_cuda_runtime() {
  if ! cmd python3; then
    return 1
  fi

  python3 - <<'PY' 2>/dev/null
import ctypes
import sys

missing = []
for lib in ("libcudart.so.12", "libcublas.so.12", "libnvrtc.so.12"):
    try:
        ctypes.CDLL(lib)
    except OSError as exc:
        missing.append(f"{lib}: {exc}")

curand_candidates = ("libcurand.so", "libcurand.so.10")
curand_ok = False
curand_err = ""
for lib in curand_candidates:
    try:
        ctypes.CDLL(lib)
        curand_ok = True
        break
    except OSError as exc:
        curand_err = str(exc)

if not curand_ok:
    missing.append(f"libcurand.so*: {curand_err}")

if missing:
    print("; ".join(missing))
    sys.exit(1)

print("CUDA runtime libraries for CuPy are available")
PY
}

append_python_cuda_lib_paths() {
  if ! cmd python3; then
    return 1
  fi

  local discovered
  discovered="$(python3 - <<'PY' 2>/dev/null
import importlib.util
from pathlib import Path

targets = [
    ("nvidia.cublas", "lib"),
    ("nvidia.cuda_runtime", "lib"),
    ("nvidia.cuda_nvrtc", "lib"),
    ("nvidia.curand", "lib"),
]

for module_name, subdir in targets:
    spec = importlib.util.find_spec(module_name)
    if not spec or not spec.submodule_search_locations:
        continue
    base = Path(next(iter(spec.submodule_search_locations)))
    lib_dir = base / subdir
    if lib_dir.is_dir():
        print(str(lib_dir))
PY
)"

  if [[ -z "$discovered" ]]; then
    return 1
  fi

  local changed=0
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ ":${LD_LIBRARY_PATH:-}:" != *":$dir:"* ]]; then
      if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:$dir"
      else
        LD_LIBRARY_PATH="$dir"
      fi
      changed=1
    fi
  done <<< "$discovered"

  export LD_LIBRARY_PATH

  if [[ $changed -eq 1 ]]; then
    record_result "backend:ldpath" "PASS" "Added Python CUDA library paths to LD_LIBRARY_PATH"
  else
    record_result "backend:ldpath" "SKIP" "Python CUDA library paths were already present in LD_LIBRARY_PATH"
  fi
  return 0
}

ensure_cupy_cuda_runtime() {
  if [[ "$backend_cupy" -ne 1 ]]; then
    return 0
  fi
  if [[ "$nvidia_gpu_count" -le 0 && "$nvidia_pci_count" -le 0 ]]; then
    return 0
  fi

  append_python_cuda_lib_paths || true

  local runtime_check
  runtime_check="$(check_cupy_cuda_runtime)"
  local runtime_rc=$?

  if [[ $runtime_rc -eq 0 ]]; then
    record_result "backend:cupy-runtime" "PASS" "$runtime_check"
    return 0
  fi

  record_result "backend:cupy-runtime" "SKIP" "Missing CUDA runtime libraries (${runtime_check}). Auto-install will be attempted."

  if ! ensure_pip_available; then
    return 1
  fi

  local install_ok=1
  if try_pip_install "cuda-cu12-libs" nvidia-cuda-runtime-cu12 nvidia-cublas-cu12 nvidia-cuda-nvrtc-cu12 nvidia-curand-cu12; then
    install_ok=0
  fi
  if try_pip_install "cupy-cuda12x-refresh" cupy-cuda12x; then
    install_ok=0
  fi

  append_python_cuda_lib_paths || true

  runtime_check="$(check_cupy_cuda_runtime)"
  runtime_rc=$?

  if [[ $runtime_rc -eq 0 ]]; then
    record_result "backend:cupy-runtime" "PASS" "CUDA runtime is healthy after install"
    return 0
  fi

  if [[ $install_ok -eq 0 ]]; then
    record_result "backend:cupy-runtime" "FAIL" "Runtime libs were installed but CuPy runtime is still unhealthy: ${runtime_check}"
  else
    record_result "backend:cupy-runtime" "FAIL" "Unable to install CUDA runtime libraries for CuPy"
  fi
  return 1
}

ensure_gpu_backend() {
  if ! cmd python3; then
    record_result "backend:check" "SKIP" "python3 not found"
    return 1
  fi

  if ! detect_python_backends; then
    record_result "backend:check" "SKIP" "Unable to inspect Python modules"
    return 1
  fi

  if have_any_backend; then
    local present=()
    [[ "$backend_torch" -eq 1 ]] && present+=("torch")
    [[ "$backend_cupy" -eq 1 ]] && present+=("cupy")
    [[ "$backend_opencl" -eq 1 ]] && present+=("pyopencl")
    record_result "backend:check" "PASS" "Detected Python GPU backend(s): ${present[*]}"
    ensure_cupy_cuda_runtime || true
    return 0
  fi

  record_result "backend:check" "SKIP" "No Python GPU backend detected. Auto-install will be attempted."

  if ! ensure_pip_available; then
    record_result "backend:install" "FAIL" "pip is not available and could not be installed automatically"
    return 1
  fi

  local install_ok=1

  # Prefer CUDA-enabled CuPy on NVIDIA hosts, then fallback to OpenCL backend.
  if [[ "$nvidia_gpu_count" -gt 0 || "$nvidia_pci_count" -gt 0 ]]; then
    if try_pip_install "cupy-cuda12x" cupy-cuda12x; then
      install_ok=0
    elif try_pip_install "cupy-cuda11x" cupy-cuda11x; then
      install_ok=0
    elif try_pip_install "opencl-fallback" numpy pyopencl; then
      install_ok=0
    fi
  else
    # Generic fallback for AMD/Intel/unknown setups.
    if try_pip_install "opencl" numpy pyopencl; then
      install_ok=0
    fi
  fi

  detect_python_backends || true
  if have_any_backend; then
    local present_after=()
    [[ "$backend_torch" -eq 1 ]] && present_after+=("torch")
    [[ "$backend_cupy" -eq 1 ]] && present_after+=("cupy")
    [[ "$backend_opencl" -eq 1 ]] && present_after+=("pyopencl")
    record_result "backend:ready" "PASS" "Available backend(s) after install attempt: ${present_after[*]}"
    ensure_cupy_cuda_runtime || true
    return 0
  fi

  if [[ "$install_ok" -eq 0 ]]; then
    record_result "backend:ready" "FAIL" "Packages were installed but no GPU backend is importable"
  else
    record_result "backend:ready" "FAIL" "Unable to install a usable Python GPU backend"
  fi
  return 1
}

pci_gpu_count=0
system_gpu_count=0
nvidia_pci_count=0
amd_pci_count=0
intel_pci_count=0
nvidia_gpu_count=0
amd_gpu_count=0
available_gpu_count=0
detected_gpu_count=0

echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "Date: $(date -Is)"

hr
echo "[GPU Inventory]"

pci_lines=""
if cmd lspci; then
  pci_lines="$(lspci -nn | grep -Ei 'vga|3d|display' || true)"
  if [[ -n "$pci_lines" ]]; then
    pci_gpu_count="$(printf '%s\n' "$pci_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    nvidia_pci_count="$(printf '%s\n' "$pci_lines" | grep -Eic '\[10de:' || true)"
    amd_pci_count="$(printf '%s\n' "$pci_lines" | grep -Eic '\[1002:' || true)"
    intel_pci_count="$(printf '%s\n' "$pci_lines" | grep -Eic '\[8086:' || true)"
    record_result "inventory:pci" "PASS" "${pci_gpu_count} GPU-class PCI device(s) detected"
    printf '%s\n' "$pci_lines"

    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # Exclude common virtual display adapter and keep physical GPU vendors.
      if [[ "$line" =~ \[1234:1111\] ]]; then
        continue
      fi
      if [[ "$line" =~ \[10de: || "$line" =~ \[1002: || "$line" =~ \[8086: ]]; then
        system_gpu_list+=("$line")
      fi
    done <<< "$pci_lines"
    system_gpu_count="${#system_gpu_list[@]}"
  else
    record_result "inventory:pci" "FAIL" "No GPU-class PCI devices detected"
  fi
else
  record_result "inventory:pci" "SKIP" "lspci not found (install pciutils)"
fi

echo
echo "System GPUs (physical PCI): ${system_gpu_count}"
if [[ "$system_gpu_count" -gt 0 ]]; then
  i=0
  for line in "${system_gpu_list[@]}"; do
    printf "  [%d] %s\n" "$i" "$line"
    ((i += 1))
  done
else
  echo "  none"
fi

hr
echo "[Vendor Availability Checks]"

if cmd nvidia-smi; then
  nvidia_list="$(nvidia-smi -L 2>&1)"
  nvidia_rc=$?
  if [[ $nvidia_rc -eq 0 ]]; then
    nvidia_gpu_count="$(printf '%s\n' "$nvidia_list" | grep -Ec '^GPU [0-9]+' || true)"
    if [[ "$nvidia_gpu_count" -gt 0 ]]; then
      record_result "availability:nvidia" "PASS" "nvidia-smi reports ${nvidia_gpu_count} GPU(s)"
      printf '%s\n' "$nvidia_list"
      while IFS= read -r line; do
        [[ "$line" =~ ^GPU[[:space:]][0-9]+: ]] || continue
        available_gpu_list+=("NVIDIA | $line")
      done <<< "$nvidia_list"
    else
      if [[ "$nvidia_pci_count" -gt 0 ]]; then
        record_result "availability:nvidia" "FAIL" "NVIDIA PCI devices present, but nvidia-smi lists no GPUs"
      else
        record_result "availability:nvidia" "SKIP" "nvidia-smi present, no NVIDIA GPUs found"
      fi
    fi
  else
    if [[ "$nvidia_pci_count" -gt 0 ]]; then
      record_result "availability:nvidia" "FAIL" "nvidia-smi failed while NVIDIA PCI devices exist: $nvidia_list"
    else
      record_result "availability:nvidia" "SKIP" "nvidia-smi failed and no NVIDIA PCI devices detected"
    fi
  fi
else
  if [[ "$nvidia_pci_count" -gt 0 ]]; then
    record_result "availability:nvidia" "FAIL" "NVIDIA PCI devices detected, but nvidia-smi is missing"
  else
    record_result "availability:nvidia" "SKIP" "nvidia-smi not found"
  fi
fi

if cmd rocm-smi; then
  rocm_smi_out="$(rocm-smi -i 2>&1)"
  rocm_smi_rc=$?
  if [[ $rocm_smi_rc -eq 0 ]]; then
    amd_gpu_count="$(printf '%s\n' "$rocm_smi_out" | grep -Eo 'GPU\[[0-9]+\]' | sort -u | wc -l | tr -d ' ')"
    if [[ "$amd_gpu_count" -gt 0 ]]; then
      record_result "availability:amd" "PASS" "rocm-smi reports ${amd_gpu_count} GPU(s)"
      printf '%s\n' "$rocm_smi_out"
      i=0
      while [[ "$i" -lt "$amd_gpu_count" ]]; do
        available_gpu_list+=("AMD | rocm-smi GPU[$i]")
        ((i += 1))
      done
    else
      if [[ "$amd_pci_count" -gt 0 ]]; then
        record_result "availability:amd" "FAIL" "AMD/ATI PCI devices present, but rocm-smi lists no GPUs"
      else
        record_result "availability:amd" "SKIP" "rocm-smi present, no AMD GPUs found"
      fi
    fi
  else
    if [[ "$amd_pci_count" -gt 0 ]]; then
      record_result "availability:amd" "FAIL" "rocm-smi failed while AMD/ATI PCI devices exist: $rocm_smi_out"
    else
      record_result "availability:amd" "SKIP" "rocm-smi failed and no AMD/ATI PCI devices detected"
    fi
  fi
elif cmd rocminfo; then
  rocminfo_out="$(rocminfo 2>&1)"
  rocminfo_rc=$?
  if [[ $rocminfo_rc -eq 0 ]]; then
    amd_gpu_count="$(printf '%s\n' "$rocminfo_out" | grep -Eic 'Name:[[:space:]]+gfx' || true)"
    if [[ "$amd_gpu_count" -gt 0 ]]; then
      record_result "availability:amd" "PASS" "rocminfo reports ${amd_gpu_count} GPU agent(s)"
      while IFS= read -r line; do
        [[ "$line" =~ Name:[[:space:]]+gfx ]] || continue
        gpu_name="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*Name:[[:space:]]*//')"
        available_gpu_list+=("AMD | ${gpu_name}")
      done <<< "$rocminfo_out"
    else
      if [[ "$amd_pci_count" -gt 0 ]]; then
        record_result "availability:amd" "FAIL" "AMD/ATI PCI devices present, but rocminfo lists no GPU agents"
      else
        record_result "availability:amd" "SKIP" "rocminfo present, no AMD GPU agents found"
      fi
    fi
  else
    if [[ "$amd_pci_count" -gt 0 ]]; then
      record_result "availability:amd" "FAIL" "rocminfo failed while AMD/ATI PCI devices exist"
    else
      record_result "availability:amd" "SKIP" "rocminfo failed and no AMD/ATI PCI devices detected"
    fi
  fi
else
  if [[ "$amd_pci_count" -gt 0 ]]; then
    record_result "availability:amd" "WARNING" "AMD/ATI PCI devices detected, but rocm-smi/rocminfo are missing"
  else
    record_result "availability:amd" "SKIP" "rocm-smi/rocminfo not found"
  fi
fi

if [[ "$intel_pci_count" -gt 0 ]]; then
  if compgen -G "/dev/dri/renderD*" >/dev/null; then
    record_result "availability:intel" "PASS" "Intel GPU PCI devices present and /dev/dri/renderD* exists"
    for render_node in /dev/dri/renderD*; do
      available_gpu_list+=("Intel | ${render_node}")
    done
  else
    record_result "availability:intel" "FAIL" "Intel GPU PCI devices present, but /dev/dri/renderD* is missing"
  fi
else
  record_result "availability:intel" "SKIP" "No Intel GPU-class PCI devices detected"
fi

available_gpu_count="${#available_gpu_list[@]}"

echo
echo "Workload-available GPUs: ${available_gpu_count}"
if [[ "$available_gpu_count" -gt 0 ]]; then
  i=0
  for line in "${available_gpu_list[@]}"; do
    printf "  [%d] %s\n" "$i" "$line"
    ((i += 1))
  done
else
  echo "  none"
fi

if [[ "$system_gpu_count" -gt 0 ]]; then
  if [[ "$available_gpu_count" -ne "$system_gpu_count" ]]; then
    record_result "availability:count-match" "WARNING" "System GPUs (${system_gpu_count}) != workload-available GPUs (${available_gpu_count})"
  else
    record_result "availability:count-match" "PASS" "System GPUs match workload-available GPUs (${available_gpu_count})"
  fi
fi

if [[ "$system_gpu_count" -gt 0 ]]; then
  detected_gpu_count="$system_gpu_count"
else
  detected_gpu_count=$((nvidia_gpu_count + amd_gpu_count + intel_pci_count))
fi

hr
echo "[Compute Smoke Test]"

ensure_gpu_backend || true

if cmd python3; then
  py_output="$(python3 - <<'PY'
import time

def emit(status, check, details):
    print(f"RESULT|{status}|{check}|{details}")

def test_torch():
    try:
        import torch
    except Exception:
        return False
    if not torch.cuda.is_available():
        return False
    count = torch.cuda.device_count()
    if count <= 0:
        return False

    passed = 0
    for i in range(count):
        name = "unknown"
        try:
            name = torch.cuda.get_device_name(i)
            torch.cuda.set_device(i)
            a = torch.randn((512, 512), device=f"cuda:{i}")
            b = torch.randn((512, 512), device=f"cuda:{i}")
            t0 = time.perf_counter()
            c = (a @ b).sum()
            torch.cuda.synchronize(i)
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            checksum = float(c.item())
            emit("PASS", f"compute:torch:gpu{i}", f"{name}; matmul ok; checksum={checksum:.4f}; elapsed_ms={elapsed_ms:.2f}")
            passed += 1
        except Exception as exc:
            emit("FAIL", f"compute:torch:gpu{i}", f"{name}; {type(exc).__name__}: {exc}")
    if passed > 0:
        emit("INFO", "compute:backend", "Using PyTorch CUDA/ROCm backend")
        return True
    return False

def test_cupy():
    try:
        import cupy as cp
    except Exception:
        return False
    try:
        count = cp.cuda.runtime.getDeviceCount()
    except Exception:
        return False
    if count <= 0:
        return False

    passed = 0
    for i in range(count):
        name = "unknown"
        try:
            with cp.cuda.Device(i):
                props = cp.cuda.runtime.getDeviceProperties(i)
                raw_name = props.get("name", b"unknown")
                if isinstance(raw_name, (bytes, bytearray)):
                    name = raw_name.decode(errors="replace")
                else:
                    name = str(raw_name)
                a = cp.random.random((512, 512), dtype=cp.float32)
                b = cp.random.random((512, 512), dtype=cp.float32)
                t0 = time.perf_counter()
                c = cp.matmul(a, b)
                checksum = float(c.sum().get())
                elapsed_ms = (time.perf_counter() - t0) * 1000.0
                emit("PASS", f"compute:cupy:gpu{i}", f"{name}; matmul ok; checksum={checksum:.4f}; elapsed_ms={elapsed_ms:.2f}")
                passed += 1
        except Exception as exc:
            emit("FAIL", f"compute:cupy:gpu{i}", f"{name}; {type(exc).__name__}: {exc}")
    if passed > 0:
        emit("INFO", "compute:backend", "Using CuPy CUDA backend")
        return True
    return False

def test_opencl():
    try:
        import pyopencl as cl
        import numpy as np
    except Exception:
        return False

    try:
        platforms = cl.get_platforms()
    except Exception:
        return False

    gpu_devices = []
    for platform in platforms:
        try:
            devices = platform.get_devices(device_type=cl.device_type.GPU)
        except Exception:
            devices = []
        for dev in devices:
            gpu_devices.append((platform, dev))

    if not gpu_devices:
        return False

    n = 262144
    host_a = np.ones(n, dtype=np.float32)
    host_b = np.full(n, 3.0, dtype=np.float32)
    kernel = """
    __kernel void saxpy(__global const float* a, __global const float* b, __global float* c) {
        int i = get_global_id(0);
        c[i] = a[i] * 2.0f + b[i];
    }
    """

    passed = 0
    for i, (platform, device) in enumerate(gpu_devices):
        name = f"{platform.name.strip()} / {device.name.strip()}"
        try:
            ctx = cl.Context(devices=[device])
            queue = cl.CommandQueue(ctx)
            mf = cl.mem_flags
            a_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=host_a)
            b_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=host_b)
            c_buf = cl.Buffer(ctx, mf.WRITE_ONLY, host_a.nbytes)
            prg = cl.Program(ctx, kernel).build()
            t0 = time.perf_counter()
            prg.saxpy(queue, (n,), None, a_buf, b_buf, c_buf)
            out = np.empty_like(host_a)
            cl.enqueue_copy(queue, out, c_buf)
            queue.finish()
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            expected = float((host_a * 2.0 + host_b).sum())
            checksum = float(out.sum())
            if abs(checksum - expected) <= max(1e-3, expected * 1e-5):
                emit("PASS", f"compute:opencl:gpu{i}", f"{name}; kernel ok; checksum={checksum:.2f}; elapsed_ms={elapsed_ms:.2f}")
                passed += 1
            else:
                emit("FAIL", f"compute:opencl:gpu{i}", f"{name}; checksum mismatch: got={checksum:.2f}, expected={expected:.2f}")
        except Exception as exc:
            emit("FAIL", f"compute:opencl:gpu{i}", f"{name}; {type(exc).__name__}: {exc}")
    if passed > 0:
        emit("INFO", "compute:backend", "Using OpenCL backend")
        return True
    return False

backend_used = test_torch() or test_cupy() or test_opencl()
if not backend_used:
    emit("SKIP", "compute:backend", "No supported Python GPU backend with visible devices (PyTorch/CuPy/OpenCL)")
PY
)"
  py_rc=$?

  if [[ $py_rc -ne 0 ]]; then
    record_result "compute:python" "FAIL" "python3 smoke test failed to execute"
  else
    while IFS='|' read -r tag status check details; do
      [[ "$tag" == "RESULT" ]] || continue
      if [[ "$status" == "INFO" ]]; then
        printf "[INFO] %s - %s\n" "$check" "$details"
      else
        record_result "$check" "$status" "$details"
      fi
    done <<< "$py_output"
  fi
else
  record_result "compute:python" "SKIP" "python3 not found"
fi

hr
echo "[Summary]"
echo "Detected GPUs (best effort): ${detected_gpu_count}"
echo "System GPUs (physical): ${system_gpu_count}, workload-available GPUs: ${available_gpu_count}"
echo "Checks: total=${total_checks}, pass=${pass_count}, fail=${fail_count}, warning=${warn_count}, skip=${skip_count}"
echo "Compute checks: ${compute_checks}, compute passes: ${compute_pass}"
echo "Compute GPU tests passed: ${compute_gpu_pass}/${compute_gpu_total}"

overall="PASS"
reason="GPU availability and compute smoke test look healthy"

if [[ "$detected_gpu_count" -eq 0 ]]; then
  overall="FAIL"
  reason="No GPUs detected"
elif [[ "$compute_pass" -eq 0 ]]; then
  overall="FAIL"
  reason="No compute smoke test passed"
elif [[ "$fail_count" -gt 0 ]]; then
  overall="FAIL"
  reason="One or more mandatory checks failed"
fi

echo "Overall: ${overall} - ${reason}"

if [[ "$overall" == "PASS" ]]; then
  exit 0
fi
exit 1
