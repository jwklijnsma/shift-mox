#!/bin/bash
# Record the serial console of every running autoscale worker VM on this
# Proxmox host to /var/log/proxmox-redfish/<vm name>.log (kept after the VM
# is deleted - that's the point: why didn't the worker join?).
#   usage: proxmox-redfish-console.sh '<VM name regex>'
set -u
re="$1"
dir=/var/log/proxmox-redfish
mkdir -p "$dir"
declare -A pids=()

while true; do
  while read -r vmid name status; do
    [[ "$status" == running && "$name" =~ $re ]] || continue
    sock="/var/run/qemu-server/$vmid.serial0"
    [[ -S "$sock" ]] || continue
    pid="${pids[$vmid]:-}"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      printf '\n===== %s: console of %s (VMID %s) =====\n' "$(date -Is)" "$name" "$vmid" >> "$dir/$name.log"
      socat -u "UNIX-CONNECT:$sock" "OPEN:$dir/$name.log,creat,append" 2>/dev/null &
      pids[$vmid]=$!
    fi
  done < <(qm list 2>/dev/null | awk 'NR > 1 {print $1, $2, $3}')
  sleep 5
done
