#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: port-audit-external.sh <host> ["22,80,443" | "1-1024"] [--help]

Checks TCP port reachability on a target host via /dev/tcp probes.

Exit codes:
  0  script executed successfully
  1  runtime dependency error
  2  invalid usage
EOF
}

cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "error: invalid arguments" >&2
  usage >&2
  exit 2
fi
HOST="$1"
SPEC="${2:-1-65535}"

timeout_cmd="timeout"
if ! cmd timeout; then
  echo "timeout not found (coreutils)."
  exit 1
fi

expand_ports() {
  local s="$1"
  if [[ "$s" =~ ^[0-9]+-[0-9]+$ ]]; then
    local a="${s%-*}" b="${s#*-}"
    for ((p=a; p<=b; p++)); do echo "$p"; done
  else
    echo "$s" | tr ',' '\n' | sed '/^$/d'
  fi
}

probe_tcp() {
  local host="$1" port="$2"
  # bash TCP connect
  if $timeout_cmd 2 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null; then
    echo "OPEN  tcp/$port"
  else
    echo "CLOSED tcp/$port"
  fi
}

echo "Target: $HOST"
echo "Ports:  $SPEC"
echo "Date:   $(date -Is)"
echo

while read -r p; do
  [[ "$p" =~ ^[0-9]+$ ]] || continue
  probe_tcp "$HOST" "$p"
done < <(expand_ports "$SPEC")
exit 0
