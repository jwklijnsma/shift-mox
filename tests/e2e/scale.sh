#!/usr/bin/env bash
# Scale test for platform baremetal (install_method agent / ipi), after
# shellcheck disable=SC2329  # check functions are called indirectly (wait_for / check)
# `./ocp.sh autoscale`:
#
#   OC=... KUBECONFIG=... tests/e2e/scale.sh <slot name prefix> <cluster name> [--autoscaler]
#
#   1. scale the worker MachineSet +1 -> the Redfish BMC creates a VM in a free
#      slot, Metal3 installs it, the node joins and runs a pod
#   2. --autoscaler: same, but triggered by the ClusterAutoscaler (a pending pod)
#   3. scale back down, removing exactly the new machine -> node gone, host
#      back to "available"; on a Proxmox host also: the VM is deleted again
#
# Exit code = number of failed checks.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/e2e/lib.sh disable=SC1091
. "$here/lib.sh"

prefix="$1" cluster="$2" use_autoscaler="${3:-}"
: "${OC:?OC not set}" "${KUBECONFIG:?KUBECONFIG not set}"
export KUBECONFIG
mapi=openshift-machine-api
ns=e2e-scale
up_timeout="${E2E_SCALE_TIMEOUT:-4500}"     # VM create + ISO boot + RHCOS + MCO reboot

ms="$(k -n "$mapi" get machinesets -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.metadata.labels.machine\.openshift\.io/cluster-api-machine-role}{"\n"}{end}' \
      | awk '$2 == "worker" {print $1; exit}')"
[[ -n "$ms" ]] || die "no worker MachineSet"
replicas="$(k -n "$mapi" get machineset "$ms" -o jsonpath='{.spec.replicas}')"
info "MachineSet $ms has $replicas replica(s)"

machines() { k -n "$mapi" get machines -l "machine.openshift.io/cluster-api-machineset=$ms" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }
before="$(machines)"
new_machine() { comm -13 <(echo "$before") <(machines) | head -1; }
node_of() { k -n "$mapi" get machine "$1" -o jsonpath='{.status.nodeRef.name}'; }

new_node_ready() {
  local m n
  m="$(new_machine)"; [[ -n "$m" ]] || return 1
  n="$(node_of "$m")"; [[ -n "$n" ]] || return 1
  [[ "$(k get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]]
}

scale_up() {
  if [[ "$use_autoscaler" == --autoscaler ]]; then
    # One pod per worker plus one more, never two on a node -> one stays
    # pending until the ClusterAutoscaler has added a worker
    local workers
    workers="$(k get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)"
    k create namespace "$ns" >/dev/null 2>&1
    k -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: spread}
spec:
  replicas: $(( workers + 1 ))
  selector: {matchLabels: {app: spread}}
  template:
    metadata: {labels: {app: spread}}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {app: spread}}}
      nodeSelector: {node-role.kubernetes.io/worker: ""}
      containers:
        - name: web
          image: ${E2E_IMAGE:-registry.access.redhat.com/ubi9/httpd-24:latest}
          resources: {requests: {cpu: 100m, memory: 64Mi}}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
EOF
    info "pending pods created; waiting for the ClusterAutoscaler"
  else
    k -n "$mapi" scale machineset "$ms" --replicas=$(( replicas + 1 )) >/dev/null
    info "scaled $ms to $(( replicas + 1 ))"
  fi
}

# --- up --------------------------------------------------------------------------
scale_up
start=$(date +%s)
if ! wait_for "$up_timeout" "new worker joined and Ready" new_node_ready; then
  CHECK_FAILED=$((CHECK_FAILED + 1))
  k -n "$mapi" get machines,bmh -o wide || true
else
  m="$(new_machine)"; n="$(node_of "$m")"
  info "new machine $m -> node $n after $(( ($(date +%s) - start) / 60 )) min"
  on_slot() { [[ "$n" == "$prefix"-* ]]; }
  check "new node is an autoscale slot ($prefix-N)" on_slot
  # a pod pinned to the new node really runs there
  k create namespace "$ns" >/dev/null 2>&1
  k -n "$ns" run pinned --image="${E2E_IMAGE:-registry.access.redhat.com/ubi9/httpd-24:latest}" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$n\"}}" >/dev/null
  pinned_ok() { [[ "$(k -n "$ns" get pod pinned -o jsonpath='{.status.phase}')" == Running ]]; }
  wait_for 600 "pod runs on the new node $n" pinned_ok || CHECK_FAILED=$((CHECK_FAILED + 1))
fi

# --- down ------------------------------------------------------------------------
m="$(new_machine)"
if [[ -n "$m" ]]; then
  n="$(node_of "$m")"
  slot="$(k -n "$mapi" get machine "$m" -o jsonpath='{.metadata.annotations.metal3\.io/BareMetalHost}' | cut -d/ -f2)"
  k delete namespace "$ns" --wait=false >/dev/null 2>&1
  # Remove exactly this machine (the MachineSet would otherwise pick one at random)
  k -n "$mapi" annotate machine "$m" machine.openshift.io/delete-machine=true --overwrite >/dev/null
  k -n "$mapi" scale machineset "$ms" --replicas="$replicas" >/dev/null
  info "scaled $ms back to $replicas (removing $m / $n / host $slot)"
  machine_gone() { ! k -n "$mapi" get machine "$m" >/dev/null 2>&1; }
  node_gone() { [[ -z "$n" ]] || ! k get node "$n" >/dev/null 2>&1; }
  host_available() { [[ -z "$slot" || "$(k -n "$mapi" get bmh "$slot" -o jsonpath='{.status.provisioning.state}')" == available ]]; }
  wait_for 1800 "machine $m deleted" machine_gone || CHECK_FAILED=$((CHECK_FAILED + 1))
  wait_for 600 "node $n removed" node_gone || CHECK_FAILED=$((CHECK_FAILED + 1))
  wait_for 1800 "host $slot back to available" host_available || CHECK_FAILED=$((CHECK_FAILED + 1))
  # On demand: the reaper deletes the stopped VM after the grace time (300 s)
  if command -v pvesh >/dev/null 2>&1 && [[ -n "$slot" ]]; then
    vm_gone() { ! pvesh get /cluster/resources --type vm --output-format json | grep -qF "\"name\":\"$slot.$cluster\""; }
    wait_for 1200 "VM of $slot deleted by the BMC (on demand)" vm_gone || CHECK_FAILED=$((CHECK_FAILED + 1))
  fi
else
  fail "nothing to scale down" || CHECK_FAILED=$((CHECK_FAILED + 1))
  k -n "$mapi" scale machineset "$ms" --replicas="$replicas" >/dev/null 2>&1
  k delete namespace "$ns" --wait=false >/dev/null 2>&1
fi

info "scale: $CHECK_FAILED failed check(s)"
exit "$CHECK_FAILED"
