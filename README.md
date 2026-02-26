# Script Storage

A set of small Bash scripts for quick server, port, and GPU diagnostics.

It also includes Proxmox automation helpers for mutually exclusive
training/inference VM modes with RAM guard checks in MiB (see `proxmox/`).

## Requirements

- Linux
- `bash` (4+)
- Permission to run scripts (`chmod +x *.sh` if needed)
- Some checks require system utilities (`lspci`, `ss`, `ip`, `systemctl`, `python3`, etc.)
- Some checks use `sudo -n` (non-interactive); if not allowed, those checks are skipped

## Scripts

### `server-audit.sh`

Short host audit:
- CPU/RAM, disks, network
- `docker`/`ssh` service status
- virtualization hints and relevant `dmesg` lines

Run:

```bash
./server-audit.sh
```

Main dependencies: `lscpu`, `free`, `vmstat`, `df`, `lsblk`, `ip`, `systemctl`, `systemd-detect-virt`, `dmesg` (some optional).

### `port-audit.sh`

Shows local listening TCP/UDP sockets and current firewall status (`ufw`/`firewalld`/`nftables`/`iptables`).

Run:

```bash
./port-audit.sh
```

Main dependency: `ss`.  
Optional: `ufw`, `firewall-cmd`, `nft`, `iptables`, `sudo`.

### `port-audit-external.sh`

Checks TCP port reachability on a remote host using connection attempts (`/dev/tcp` + `timeout`).

Run:

```bash
./port-audit-external.sh <host> [\"22,80,443\" | \"1-1024\"]
```

Examples:

```bash
./port-audit-external.sh 192.168.1.10 "22,80,443"
./port-audit-external.sh example.com "1-1024"
```

Main dependencies: `timeout` (coreutils), `bash`.

### `gpu-audit.sh`

GPU and driver inventory:
- PCI detection (`lspci`)
- `lshw` output
- NVIDIA (`nvidia-smi`), AMD (`rocm-smi`/`rocminfo`), Intel (`intel_gpu_top`)
- device node checks (`/dev/nvidia*`, `/dev/dri/*`)

Run:

```bash
./gpu-audit.sh
```

Main dependency: `lspci`.  
Optional: `lshw`, `nvidia-smi`, `rocm-smi`, `rocminfo`, `intel_gpu_top`.

### `gpu-test.sh`

Extended GPU validation:
- compares physically visible GPUs vs workload-available GPUs
- vendor-specific availability checks (NVIDIA/AMD/Intel)
- compute smoke test via Python backends:
  - PyTorch (CUDA/ROCm)
  - CuPy (CUDA)
  - OpenCL (`pyopencl` + `numpy`)
- attempts automatic Python backend setup (pip/install) if missing

Run:

```bash
./gpu-test.sh
```

Exit codes:
- `0` - overall `PASS`
- `1` - overall `FAIL`

Main dependencies: `python3`, `lspci`.  
Optional (platform-dependent): `nvidia-smi`, `rocm-smi`/`rocminfo`, `pip`, `sudo`, Python packages (`torch`, `cupy`, `pyopencl`, `numpy`).

### `proxmox/` automation

Implements 4GPU-2VM-ITex policy:
- VM names: `vm-gpu-1`, `vm-gpu-2`, `vm-train`, `vm-infer`
- mutual exclusion for `vm-train` / `vm-infer` via hookscript + watchdog
- `idle` when both modes are stopped
- RAM plan in MiB:
  - `vm-gpu-1=90112`
  - `vm-gpu-2=90112`
  - `vm-train=34816`
  - `vm-infer=16384`
- RAM guard: running sum must stay `<= 231424` MiB

Details and setup steps: `proxmox/README.md`.
Command examples after install: `mlmode train|infer|stop|status|check`.
Resource profile apply command: `sudo mlmode apply-profile`.

## Quick Start

```bash
chmod +x *.sh
./server-audit.sh
./port-audit.sh
./gpu-audit.sh
./gpu-test.sh
```

## Help

Each script supports `-h` / `--help`:

```bash
./server-audit.sh --help
./port-audit.sh --help
./port-audit-external.sh --help
./gpu-audit.sh --help
./gpu-test.sh --help
```
