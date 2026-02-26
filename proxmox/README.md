# Proxmox ML Mode (Plan v6)

This directory implements:
- GUI-first control in Proxmox
- mutual exclusion between `vm-train` and `vm-infer`
- `idle` mode when both are stopped
- RAM guard in MiB with fixed memory plan

## Memory plan (MiB)

- `vm-gpu-1`: `90112`
- `vm-gpu-2`: `90112`
- `vm-train`: `34816`
- `vm-infer`: `16384`

Total VM memory: `231424` MiB  
Reserved for Proxmox host: `30720` MiB  
Total host memory: `262144` MiB

## Files

- `ml-mode-common.sh`: shared logic
- `ml-mode.sh`: CLI helper (`train|infer|stop|status|check|apply-profile`)
- `mlmode`: command wrapper for `mlmode train|infer|stop|status|check|apply-profile`
- `ml-mode-hook.sh`: hookscript (`pre-start` enforcement)
- `ml-mode-watchdog.sh`: anti-race watchdog
- `ml-mode-watchdog.service`: systemd service
- `ml-mode-watchdog.timer`: systemd timer (every 10s)
- `ml-mode-acceptance.sh`: acceptance checks

## Install on Proxmox host

Copy scripts:

```bash
sudo install -m 0755 proxmox/ml-mode.sh /usr/local/sbin/ml-mode.sh
sudo install -m 0755 proxmox/mlmode /usr/local/bin/mlmode
sudo install -m 0755 proxmox/ml-mode-hook.sh /usr/local/sbin/ml-mode-hook.sh
sudo install -m 0755 proxmox/ml-mode-watchdog.sh /usr/local/sbin/ml-mode-watchdog.sh
sudo install -m 0755 proxmox/ml-mode-acceptance.sh /usr/local/sbin/ml-mode-acceptance.sh
sudo install -m 0644 proxmox/ml-mode-common.sh /usr/local/sbin/ml-mode-common.sh
```

Install systemd units:

```bash
sudo install -m 0644 proxmox/ml-mode-watchdog.service /etc/systemd/system/ml-mode-watchdog.service
sudo install -m 0644 proxmox/ml-mode-watchdog.timer /etc/systemd/system/ml-mode-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now ml-mode-watchdog.timer
```

## Configure VM memory (MiB)

Resolve VMIDs:

```bash
sudo qm list
```

Set CPU + memory values in one command:

```bash
sudo mlmode apply-profile
```

This applies:
- `cpu=host`
- `sockets=1`
- `numa=1`
- `cores`: `vm-gpu-1=96`, `vm-gpu-2=96`, `vm-train=24`, `vm-infer=16`
- `memory/balloon`: `90112/90112/34816/16384` MiB
- `agent=1`

## Attach hookscript to control-plane VMs

```bash
sudo qm set <vmid-vm-train> --hookscript local:snippets/ml-mode-hook.sh
sudo qm set <vmid-vm-infer> --hookscript local:snippets/ml-mode-hook.sh
```

Notes:
- Put `ml-mode-hook.sh` into a Proxmox snippet storage path.
- The hookscript runs on every start from GUI/CLI/API.

## Daily use (GUI-first)

- Start `vm-train` from GUI: hookscript stops `vm-infer` first.
- Start `vm-infer` from GUI: hookscript stops `vm-train` first.
- Stop both manually in GUI: state becomes `idle`, watchdog does not auto-start anything.

Optional CLI:

```bash
mlmode train
mlmode infer
mlmode stop
mlmode status
mlmode check
mlmode apply-profile
```

## Acceptance checks

```bash
sudo /usr/local/sbin/ml-mode-acceptance.sh
```

Expected:
- memory values match `90112/90112/34816/16384`
- running memory sum is `<= 231424` MiB
- CPU profile matches `cpu=host`, `sockets=1`, `numa=1`, cores `96/96/24/16`
