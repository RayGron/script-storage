# Proxmox Tools

This directory now has two parts:

- `watchdog/`: VM mode policy scripts (`mlmode`, hookscript, watchdog, acceptance checks)
- `audit/`: Proxmox-aware audit/test scripts for your architecture

## Architecture Assumed by Audit Scripts

- Proxmox host with NVIDIA GPUs
- VMs:
  - `vm-gpu-1`
  - `vm-gpu-2`
  - `vm-train`
  - `vm-infer`
- Shared data root on host:
  - `/mnt/shared-storage/mlshare`

## Scripts

### Watchdog policy

See: `watchdog/README.md`

### Proxmox audits

- `audit/server-audit.sh`
  - Host services, storage, VM inventory, and profile snapshot.
- `audit/gpu-audit.sh`
  - Physical GPU inventory, IOMMU/VFIO hints, passthrough mapping to GPU VMs.
- `audit/gpu-test.sh`
  - PASS/FAIL architecture checks (VM profile, passthrough, hookscript, watchdog, storage layout).

Run:

```bash
chmod +x proxmox/audit/*.sh
./proxmox/audit/server-audit.sh
./proxmox/audit/gpu-audit.sh
./proxmox/audit/gpu-test.sh
```
