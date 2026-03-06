# Proxmox MLMAN (JSON Config)

This directory implements:
- `mlman` control CLI for Proxmox ML mode switching
- mutual exclusion between `vm-train` and `vm-infer`
- dynamic GPU node inventory for Ray/vLLM inference
- watchdog + hookscript policy enforcement
- acceptance and audit helpers using separate host/inference config files

## Config Source

Host config file:
- `/etc/mlman/mlman.conf` (JSON, used by `mlman`, hookscript, watchdog, audit)
- `limits.vm_memory_limit_mib=0` means "auto-calc from configured VM memory profile sum"

Inference config file on `vm-infer`:
- `/etc/mlman/infer.conf` (JSON, used by `inferctl.sh`)

- `jq` must be installed where `mlman` or `inferctl.sh` run

Default model registry file:
- `/mnt/shared-storage/mlshare/control/models.tsv`

Default active model state:
- `/mnt/shared-storage/mlshare/control/active-model.env`

Example config templates:
- `mlman.conf.example`
- `infer.conf.example`

Minimal `mlman.conf` shape:

```json
{
  "vm_names": { "train": "vm-train", "infer": "vm-infer" },
  "control": { "infer_config_path": "/etc/mlman/infer.conf" },
  "gpu_nodes": [
    { "name": "vm-gpu-1", "ip": "192.168.88.101", "ssh_user": "mlops1", "gpu_count": 2, "memory_mib": 90112, "cores": 96, "enabled": true }
  ]
}
```

Minimal `infer.conf` shape:

```json
{
  "gpu_nodes": [
    { "name": "vm-gpu-1", "ip": "192.168.88.101", "ssh_user": "mlops1", "gpu_count": 2, "enabled": true }
  ],
  "inference": { "ray_head_node": "vm-gpu-1", "net_if": "eth0" }
}
```

`gpu_nodes[]` can contain any number of GPU VMs, which enables horizontal scaling. The list is intentionally duplicated across the two configs because host policy and infer runtime are now separated.

## Files

- `ml-mode-common.sh`: shared config/state/helpers (JSON parsing via `jq`)
- `ml-mode.sh`: main controller (`train|infer|stop|status|check|apply-profile|model-*`)
- `mlman`: preferred wrapper command
- `inferctl.sh`: remote inference control (Ray/vLLM) on `vm-infer`
- `ml-mode-hook.sh`: Proxmox hookscript (`pre-start` conflict prevention)
- `ml-mode-watchdog.sh`: anti-race watchdog
- `ml-mode-watchdog.service`: systemd service
- `ml-mode-watchdog.timer`: systemd timer
- `ml-mode-acceptance.sh`: profile and RAM guard checks
- `models.example.tsv`: model alias registry example

## Install on Proxmox Host

```bash
sudo install -d -m 0755 /usr/local/sbin /usr/local/bin /etc/mlman
sudo install -m 0755 proxmox/watchdog/ml-mode.sh /usr/local/sbin/ml-mode.sh
sudo install -m 0755 proxmox/watchdog/ml-mode-common.sh /usr/local/sbin/ml-mode-common.sh
sudo install -m 0755 proxmox/watchdog/ml-mode-hook.sh /usr/local/sbin/ml-mode-hook.sh
sudo install -m 0755 proxmox/watchdog/ml-mode-watchdog.sh /usr/local/sbin/ml-mode-watchdog.sh
sudo install -m 0755 proxmox/watchdog/ml-mode-acceptance.sh /usr/local/sbin/ml-mode-acceptance.sh
sudo install -m 0755 proxmox/watchdog/mlman /usr/local/bin/mlman
sudo install -m 0644 proxmox/watchdog/mlman.conf.example /etc/mlman/mlman.conf
```

Systemd:

```bash
sudo install -m 0644 proxmox/watchdog/ml-mode-watchdog.service /etc/systemd/system/ml-mode-watchdog.service
sudo install -m 0644 proxmox/watchdog/ml-mode-watchdog.timer /etc/systemd/system/ml-mode-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now ml-mode-watchdog.timer
```

## Install inferctl on `vm-infer`

`mlman` calls `inferctl.sh` remotely over SSH on the infer control VM.

```bash
sudo install -d -m 0755 /usr/local/sbin /etc/mlman
sudo install -m 0755 proxmox/watchdog/inferctl.sh /usr/local/sbin/inferctl.sh
sudo install -m 0755 proxmox/watchdog/ml-mode-common.sh /usr/local/sbin/ml-mode-common.sh
sudo install -m 0644 proxmox/watchdog/infer.conf.example /etc/mlman/infer.conf
```

## Hookscript Setup

Attach hookscript to control-plane VMs:

```bash
sudo qm set <vmid-vm-train> --hookscript local:snippets/ml-mode-hook.sh
sudo qm set <vmid-vm-infer> --hookscript local:snippets/ml-mode-hook.sh
```

## Daily Use

Core mode control:

```bash
mlman train
mlman infer
mlman stop
mlman status
mlman check
mlman apply-profile
```

Inference model operations:

```bash
mlman model-list
mlman model-use qwen3.5-7b
mlman model-use qwen3.5-7b --nodes vm-gpu-1,vm-gpu-2 --head-node vm-gpu-1 --net-if eth0
mlman model-current
mlman model-status
```

## Acceptance Check

```bash
sudo /usr/local/sbin/ml-mode-acceptance.sh
```

Checks:
- VM memory values match JSON profile
- Running VM memory sum is within configured RAM guard limit
- CPU profile matches configured defaults and per-VM core plan
