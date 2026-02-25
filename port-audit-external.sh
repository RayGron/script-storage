#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <host> \"22,80,443\" | \"1-1024\""
  exit 1
}

cmd() { command -v "$1" >/dev/null 2>&1; }

[[ $# -eq 2 ]] || usage
HOST="$1"
SPEC="$2"

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