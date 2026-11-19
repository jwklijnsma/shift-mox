#!/bin/bash
# openshift5: keep the cluster's nodes in /etc/hosts and give a freshly
# provisioned autoscale worker its hostname before NetworkManager starts.
# Mapping (/etc/autoscale-hosts, from MachineConfig 99-worker-openshift5-hosts):
#   <ip> <fqdn> <short name = hostname, as the installed nodes> [<mac>]
set -euo pipefail
map=/etc/autoscale-hosts
begin="# BEGIN openshift5 autoscale"
end="# END openshift5 autoscale"

# 1. /etc/hosts: replace our block, leave everything else (node-resolver, ...) alone
tmp="$(mktemp)"
sed "/^${begin}\$/,/^${end}\$/d" /etc/hosts > "$tmp"
{
  echo "$begin"
  awk '!/^[[:space:]]*#/ && NF >= 3 {print $1, $2, $3}' "$map"
  echo "$end"
} >> "$tmp"
cat "$tmp" > /etc/hosts      # write in place: keeps inode and SELinux label
rm -f "$tmp"

# 2. hostname, only when the node has none yet (never renames a running node)
current="$(cat /etc/hostname 2>/dev/null || true)"
if [[ -z "$current" || "$current" == localhost* ]]; then
  for f in /sys/class/net/*/address; do
    mac="$(tr '[:upper:]' '[:lower:]' < "$f")"
    name="$(awk -v m="$mac" 'NF >= 4 && tolower($4) == m {print $3; exit}' "$map")"
    if [[ -n "$name" ]]; then
      echo "$name" > /etc/hostname
      hostname "$name"
      echo "hostname set to $name (MAC $mac)"
      break
    fi
  done
fi
