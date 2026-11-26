#!/usr/bin/env bash
# Verify an installed cluster.
# shellcheck disable=SC2329  # check functions are called indirectly (wait_for / check)
#
#   OC=... KUBECONFIG=... tests/e2e/verify.sh <install_method> <cni> <expected nodes> <apps domain> [csi storageclass]
#
# Checks: cluster version + operators, nodes, the CNI, a workload across nodes
# (pod -> service, pod -> pod on another node, cluster DNS, route from
# outside), what the install method promises (BareMetalHosts for ipi,
# providerID / zones for external) and optionally a CSI volume.
# Exit code = number of failed checks (0 = all passed).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/e2e/lib.sh disable=SC1091
. "$here/lib.sh"

method="$1" cni="$2" want_nodes="$3" apps="$4" csi_class="${5:-}"
: "${OC:?OC not set}" "${KUBECONFIG:?KUBECONFIG not set}"
export KUBECONFIG
ns=e2e-smoke

# --- cluster ---------------------------------------------------------------------
cv_done() {
  [[ "$(k get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" == True ]] &&
  [[ "$(k get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" == False ]]
}
cos_healthy() {
  # every operator Available=True, Degraded=False, Progressing=False
  local bad
  bad="$(k get clusteroperators -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Degraded")].status}{.status.conditions[?(@.type=="Progressing")].status}{"\n"}{end}' \
         | awk '$2 != "TrueFalseFalse" {print $1}')"
  [[ -z "$bad" ]] || { echo "not healthy: $bad"; return 1; }
}
nodes_ready() {
  local total ready
  total="$(k get nodes --no-headers | wc -l)"
  ready="$(k get nodes --no-headers | awk '$2 ~ /^Ready/' | wc -l)"
  (( total == want_nodes && ready == want_nodes ))
}

wait_for 2700 "cluster version Available and settled" cv_done || CHECK_FAILED=$((CHECK_FAILED + 1))
wait_for 1800 "all cluster operators healthy" cos_healthy || { CHECK_FAILED=$((CHECK_FAILED + 1)); cos_healthy || true; }
wait_for 900 "$want_nodes nodes Ready" nodes_ready || { CHECK_FAILED=$((CHECK_FAILED + 1)); k get nodes || true; }

# --- CNI -------------------------------------------------------------------------
network_type() { [[ "$(k get network.config cluster -o jsonpath='{.status.networkType}')" == "$cni" ]]; }
check "network type is $cni" network_type
ds_ready() {  # ds_ready <namespace> <name>
  local want have
  want="$(k -n "$1" get ds "$2" -o jsonpath='{.status.desiredNumberScheduled}')"
  have="$(k -n "$1" get ds "$2" -o jsonpath='{.status.numberReady}')"
  [[ -n "$want" && "$want" == "$have" && "$want" -gt 0 ]]
}
if [[ "$cni" == Calico ]]; then
  tigera_ok() {
    local st
    st="$(k get tigerastatus -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}')"
    [[ -n "$st" ]] && ! grep -qv '^True$' <<<"$st"
  }
  check "Calico: tigerastatus all Available" tigera_ok
  check "Calico: calico-node on every node" ds_ready calico-system calico-node
else
  check "OVN-Kubernetes: ovnkube-node on every node" ds_ready openshift-ovn-kubernetes ovnkube-node
fi

# --- workload ----------------------------------------------------------------------
# UBI 9 (public, no pull secret): httpd for the server, curl + getent for the client
image="${E2E_IMAGE:-registry.access.redhat.com/ubi9/httpd-24:latest}"

k delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
k create namespace "$ns" >/dev/null
k -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      # one pod per node, so pod -> pod traffic really crosses nodes
      topologySpreadConstraints:
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: DoNotSchedule,
           labelSelector: {matchLabels: {app: web}}}
      tolerations:
        - {key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule}
      containers:
        - name: web
          image: $image
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /, port: 8080}, periodSeconds: 5}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            runAsNonRoot: true
            seccompProfile: {type: RuntimeDefault}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: web}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: {name: web}
spec:
  host: web-$ns.$apps
  to: {kind: Service, name: web}
  port: {targetPort: 8080}
  tls: {termination: edge}
---
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  tolerations:
    - {key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule}
  containers:
    - name: client
      image: $image
      command: [sleep, "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
EOF

web_ready() { [[ "$(k -n "$ns" get deploy web -o jsonpath='{.status.readyReplicas}')" == 2 ]]; }
client_ready() { [[ "$(k -n "$ns" get pod client -o jsonpath='{.status.phase}')" == Running ]]; }
wait_for 600 "test workload running" web_ready || CHECK_FAILED=$((CHECK_FAILED + 1))
wait_for 300 "client pod running" client_ready || CHECK_FAILED=$((CHECK_FAILED + 1))

in_client() { k -n "$ns" exec client -- "$@"; }
svc_ok() { in_client curl -sf --max-time 10 "http://web.$ns.svc:8080/" -o /dev/null; }
dns_ok() { in_client getent hosts kubernetes.default.svc.cluster.local; }
dns_ext_ok() { in_client getent hosts quay.io; }
pods_ok() {
  # every web pod, by pod IP - at least one is on another node than the client
  local ip n=0
  for ip in $(k -n "$ns" get pods -l app=web -o jsonpath='{.items[*].status.podIP}'); do
    in_client curl -sf --max-time 10 "http://$ip:8080/" -o /dev/null || return 1
    n=$((n + 1))
  done
  (( n == 2 ))
}
spread_ok() { (( $(k -n "$ns" get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l) == 2 )); }
route_ok() { curl -skf --max-time 15 "https://web-$ns.$apps/" -o /dev/null; }

check "web pods on 2 different nodes" spread_ok
check "pod -> service" svc_ok
check "pod -> pod across nodes" pods_ok
check "cluster DNS" dns_ok
check "external DNS from a pod" dns_ext_ok
wait_for 300 "route https://web-$ns.$apps from outside" route_ok || CHECK_FAILED=$((CHECK_FAILED + 1))

# --- install method ----------------------------------------------------------------------
platform() { k get infrastructure cluster -o jsonpath='{.status.platformStatus.type}'; }
case "$method" in
  agent)
    plat_ok() { [[ "$(platform)" == BareMetal || "$(platform)" == None ]]; }
    check "platform BareMetal" plat_ok
    ;;
  ipi)
    plat_ok() { [[ "$(platform)" == BareMetal ]]; }
    bmh_ok() {
      # every node is a provisioned, powered-on BareMetalHost
      local n
      n="$(k -n openshift-machine-api get bmh -o jsonpath='{range .items[*]}{.status.provisioning.state} {.status.poweredOn}{"\n"}{end}' \
           | grep -c '^provisioned true$')"
      (( n >= want_nodes ))
    }
    check "platform BareMetal" plat_ok
    check "all $want_nodes nodes are provisioned BareMetalHosts" bmh_ok
    ;;
  external)
    plat_ok() { [[ "$(platform)" == External ]]; }
    # all_nodes_match <jsonpath per node> <regex>: every node's value matches
    all_nodes_match() {
      local n
      n="$(k get nodes -o jsonpath="{range .items[*]}$1{\"\\n\"}{end}" | grep -cE "$2")"
      (( n == want_nodes ))
    }
    pid_ok() { all_nodes_match '{.spec.providerID}' '^proxmox://'; }
    zone_ok() { all_nodes_match '{.metadata.labels.topology\.kubernetes\.io/zone}' '.'; }
    taint_ok() { ! k get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].key}{"\n"}{end}' | grep -q 'node.cloudprovider.kubernetes.io/uninitialized'; }
    check "platform External" plat_ok
    check "CCM: every node has providerID proxmox://" pid_ok
    check "CCM: every node has a zone label" zone_ok
    check "CCM: no node left uninitialized" taint_ok
    ;;
esac

# --- CSI (optional) --------------------------------------------------------------------
if [[ -n "$csi_class" ]]; then
  k -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $csi_class
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  restartPolicy: Never
  containers:
    - name: w
      image: $image
      command: [sh, -c, "echo e2e > /data/f && sync && cat /data/f"]
      volumeMounts: [{name: d, mountPath: /data}]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
  volumes: [{name: d, persistentVolumeClaim: {claimName: data}}]
EOF
  writer_ok() { [[ "$(k -n "$ns" get pod writer -o jsonpath='{.status.phase}')" == Succeeded ]]; }
  wait_for 600 "CSI: volume from $csi_class written" writer_ok || CHECK_FAILED=$((CHECK_FAILED + 1))
fi

k delete namespace "$ns" --wait=false >/dev/null 2>&1
info "verify: $CHECK_FAILED failed check(s)"
exit "$CHECK_FAILED"
