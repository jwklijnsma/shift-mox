#!/bin/bash
# Shiftmox autoscale repair (CronJob in openshift-machine-api):
# re-register autoscale BareMetalHosts that are stuck in an error state for
# MIN_AGE seconds and that no Machine uses. The Redfish BMC deletes any
# leftover VM once the host is "available" again.
set -euo pipefail
NS=openshift-machine-api
MIN_AGE="${MIN_AGE:-600}"
now="$(date +%s)"

oc -n "$NS" get baremetalhosts.metal3.io -l openshift5/role=autoscale-worker -o \
  jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.operationalStatus}{"|"}{.status.errorType}{"|"}{.spec.consumerRef.name}{"|"}{.status.lastUpdated}{"\n"}{end}' |
while IFS='|' read -r name op err consumer updated; do
  [[ -z "$name" ]] && continue
  if [[ -n "$consumer" ]]; then continue; fi                 # a worker runs on it
  if [[ "$op" != "error" && -z "$err" ]]; then continue; fi   # healthy
  age=$(( now - $(date -d "${updated:-1970-01-01T00:00:00Z}" +%s) ))
  if (( age < MIN_AGE )); then
    echo "$name: ${err:-error} for ${age}s - waiting (BMO may still recover it)"
    continue
  fi
  if [[ ! -s "/manifests/$name.yaml" ]]; then
    echo "$name: ${err:-error}, but no manifest to re-create it from - skipping"
    continue
  fi
  echo "$name: ${err:-error} for ${age}s - registering it again"
  oc -n "$NS" delete baremetalhosts.metal3.io "$name" --wait=true --timeout=10m
  oc apply -f "/manifests/$name.yaml"
done
echo "repair check done"
