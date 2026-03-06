#!/usr/bin/env bash
set -euo pipefail

hr() { printf "\n%s\n" "============================================================"; }
cmd() { command -v "$1" >/dev/null 2>&1; }
usage() {
  cat <<'EOF'
Usage: port-audit.sh [--help]

Shows listening TCP/UDP sockets and local firewall state (ufw/firewalld/nftables/iptables when available).

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

hr
echo "[Listening TCP/UDP sockets]"
if cmd ss; then
  ss -lntup || true
else
  echo "ss not found (iproute2)"
fi

hr
echo "[Firewall status]"
if cmd ufw; then
  echo "UFW:"
  sudo -n ufw status verbose 2>/dev/null || ufw status verbose 2>/dev/null || true
fi

if cmd firewall-cmd; then
  echo
  echo "firewalld:"
  sudo -n firewall-cmd --state 2>/dev/null || true
  sudo -n firewall-cmd --list-all 2>/dev/null || true
fi

if cmd nft; then
  echo
  echo "nftables (first ~200 lines):"
  sudo -n nft list ruleset 2>/dev/null | sed -n '1,200p' || true
fi

if cmd iptables; then
  echo
  echo "iptables (filter table rules):"
  sudo -n iptables -S 2>/dev/null || iptables -S 2>/dev/null || true
fi

echo
echo "Note: external reachability still depends on upstream NAT / security-groups."
echo "Done."
exit 0
