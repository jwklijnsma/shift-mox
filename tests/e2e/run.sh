#!/usr/bin/env bash
# End-to-end tests: deploy, verify, scale and destroy every install method
# with both CNIs, one case after the other, on a real Proxmox host.
#
#   ./ocp.sh e2e [options] [case ...]       (in tmux; recommended)
#   tests/e2e/run.sh [options] [case ...]
#
# Cases (default: all six):
#   agent-ovn agent-calico ipi-ovn ipi-calico external-ovn external-calico
#
# Options:
#   --keep              keep every cluster after its tests (no destroy)
#   --keep-failed       keep only clusters whose tests failed
#   --no-scale          skip the scale test
#   --autoscaler        scale test via the ClusterAutoscaler (pending pods)
#                       instead of scaling the MachineSet by hand
#   --list              show the cases and exit
#
# Settings: tests/e2e/settings.yml (copy settings.example.yml). Results:
# .work/e2e/<timestamp>/summary.md and junit.xml, logs per case and phase.
# shellcheck disable=SC2329  # check functions are called indirectly
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
cd "$repo" || exit 1
# shellcheck source=tests/e2e/lib.sh disable=SC1091
. "$here/lib.sh"

ALL_CASES=(agent-ovn agent-calico ipi-ovn ipi-calico external-ovn external-calico)
KEEP=none SCALE=1 AUTOSCALER="" CASES=()
while (($#)); do
  case "$1" in
    --keep)        KEEP=all ;;
    --keep-failed) KEEP=failed ;;
    --no-scale)    SCALE=0 ;;
    --autoscaler)  AUTOSCALER=--autoscaler ;;
    --no-pull)     ;;  # added by ocp.sh when it re-runs in tmux
    --list)        printf '%s\n' "${ALL_CASES[@]}"; exit 0 ;;
    -h|--help)     sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            die "unknown option $1" ;;
    *)             [[ " ${ALL_CASES[*]} " == *" $1 "* ]] || die "unknown case $1 (see --list)"; CASES+=("$1") ;;
  esac
  shift
done
((${#CASES[@]})) || CASES=("${ALL_CASES[@]}")
# All cases reuse the same addresses and VMIDs: a kept cluster blocks the next one
[[ "$KEEP" == all && ${#CASES[@]} -gt 1 ]] && die "--keep only works with a single case (they share addresses and VMIDs)"

settings="$here/settings.yml"
[[ -f "$settings" ]] || die "no $settings - copy tests/e2e/settings.example.yml and fill in your lab's addresses"
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host (the tests install a Redfish BMC / HAProxy there)"
command -v pveversion >/dev/null || warn "not a Proxmox host: ipi/external and the VM checks need one"

run_dir="$repo/.work/e2e/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
exec > >(tee -a "$run_dir/run.log") 2>&1
info "e2e run $run_dir: ${CASES[*]}"

# One vault password for the whole run, so nothing prompts after hours
cleanup_pass=""
if head -c 14 group_vars/all/vault.yml 2>/dev/null | grep -qF "\$ANSIBLE_VAULT" && [[ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  read -rsp "Vault password: " vp; echo
  ANSIBLE_VAULT_PASSWORD_FILE="$(mktemp)"; chmod 600 "$ANSIBLE_VAULT_PASSWORD_FILE"
  printf '%s' "$vp" > "$ANSIBLE_VAULT_PASSWORD_FILE"; unset vp
  export ANSIBLE_VAULT_PASSWORD_FILE
  cleanup_pass="$ANSIBLE_VAULT_PASSWORD_FILE"
fi
trap '[[ -n "$cleanup_pass" ]] && rm -f "$cleanup_pass"' EXIT

ocp() { "$repo/ocp.sh" --no-tmux --no-pull "$@"; }
setting() { sed -nE "s/^$1:[[:space:]]*\"?([^\"#]+)\"?.*/\\1/p" "$settings" | head -1 | xargs; }

# --- results ---------------------------------------------------------------------
declare -A RESULT DURATION
record() {  # record <case> <phase> <PASS|FAIL|SKIP> <seconds> [note]
  RESULT["$1/$2"]="$3${5:+ ($5)}"
  DURATION["$1/$2"]="$4"
}
write_reports() {
  local c p r junit="$run_dir/junit.xml" tests=0 failures=0 skipped=0 body=""
  {
    echo "# Shiftmox e2e $(basename "$run_dir")"
    echo
    echo "| case | deploy | verify | scale | destroy |"
    echo "|---|---|---|---|---|"
    for c in "${CASES[@]}"; do
      printf '| %s |' "$c"
      for p in deploy verify scale destroy; do
        r="${RESULT[$c/$p]:-}"
        if [[ "$r" == SKIP* || -z "$r" ]]; then printf ' %s |' "${r:--}"
        else printf ' %s %s min |' "$r" "$(( DURATION[$c/$p] / 60 ))"; fi
      done
      echo
    done
  } > "$run_dir/summary.md"
  for c in "${CASES[@]}"; do
    for p in deploy verify scale destroy; do
      r="${RESULT[$c/$p]:-}"; [[ -n "$r" ]] || continue
      tests=$((tests + 1))
      body+="  <testcase classname=\"shiftmox.e2e.$c\" name=\"$p\" time=\"${DURATION[$c/$p]:-0}\">"
      case "$r" in
        FAIL*) failures=$((failures + 1)); body+="<failure message=\"${r//\"/}\">see $c/$p.log</failure>" ;;
        SKIP*) skipped=$((skipped + 1)); body+="<skipped message=\"${r//\"/}\"/>" ;;
      esac
      body+="</testcase>"$'\n'
    done
  done
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="shiftmox-e2e" tests="%s" failures="%s" skipped="%s">\n%s</testsuite>\n' \
    "$tests" "$failures" "$skipped" "$body" > "$junit"
}

# phase <case> <phase> <command...>: run with a log, record PASS/FAIL + time
phase() {
  local c="$1" p="$2" start rc
  shift 2
  start=$(date +%s)
  info "[$c] $p"
  "$@" > "$run_dir/$c/$p.log" 2>&1
  rc=$?
  if ((rc == 0)); then
    record "$c" "$p" PASS $(( $(date +%s) - start ))
    pass "[$c] $p"
  else
    record "$c" "$p" FAIL $(( $(date +%s) - start )) "rc $rc"
    fail "[$c] $p (rc $rc, log: $run_dir/$c/$p.log)" || true
    tail -n 25 "$run_dir/$c/$p.log" | sed 's/^/      | /'
  fi
  write_reports
  return "$rc"
}

# --- one case ----------------------------------------------------------------------
make_env() {  # make_env <case> <env> <cluster name>
  local c="$1" env="$2" name="$3" method="${1%-*}" cni="${1#*-}"
  local dir="environments/$env"
  mkdir -p "$dir/secrets"
  {
    echo "# Generated by tests/e2e/run.sh for case $c - overwritten on every run"
    sed '/^---$/d' "$settings"
    echo
    echo "cluster_name: $name"
    echo "install_method: $method"
    echo "cni: $([[ "$cni" == ovn ]] && echo OVNKubernetes || echo Calico)"
  } > "$dir/cluster.yml"
  # the e2e environments use the main pull secret and vault
  [[ -f secrets/pull-secret.json ]] && ln -sf ../../../secrets/pull-secret.json "$dir/secrets/pull-secret.json"
  return 0
}

diagnostics() {  # diagnostics <case> <kubeconfig>
  local c="$1"
  [[ -f "$2" ]] || return 0
  {
    for what in clusterversion clusteroperators nodes "machines -A" "bmh -A" "pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded"; do
      echo "### oc get $what"
      # shellcheck disable=SC2086
      KUBECONFIG="$2" "$OC" get $what -o wide 2>&1 | head -100
    done
    echo "### events (warnings)"
    KUBECONFIG="$2" "$OC" get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -60
  } > "$run_dir/$c/diagnostics.txt"
}

cleanup_host() {  # cleanup_host <env>: what the e2e environment left on this host
  local env="$1" svc="proxmox-redfish-$1"
  command -v systemctl >/dev/null || return 0
  if [[ -f "/etc/systemd/system/$svc.service" ]]; then
    systemctl disable --now "$svc" >/dev/null 2>&1
    rm -f "/etc/systemd/system/$svc.service"; rm -rf "/etc/proxmox-redfish-$env"
  fi
  if [[ -f "/etc/proxmox-redfish-dhcp.d/50-sm-$env.conf" ]]; then
    rm -f "/etc/proxmox-redfish-dhcp.d/50-sm-$env.conf"
    if compgen -G "/etc/proxmox-redfish-dhcp.d/50-*.conf" >/dev/null; then
      systemctl restart proxmox-redfish-dhcp
    else
      systemctl disable --now proxmox-redfish-dhcp >/dev/null 2>&1
    fi
  fi
  # HAProxy from install_method external, only if Shiftmox wrote its config
  if grep -q 'Managed by Ansible (roles/external_lb)' /etc/haproxy/haproxy.cfg 2>/dev/null; then
    systemctl disable --now haproxy >/dev/null 2>&1
  fi
  local user; user="$(sed -nE 's/^proxmox_api_user:[[:space:]]*"?([^"#]+)"?.*/\1/p' group_vars/all/cluster.yml | head -1 | xargs)"
  command -v pveum >/dev/null && pveum user token remove "$user" "autoscale-$env" >/dev/null 2>&1
  rm -f "environments/$env/secrets/autoscale.json"
  systemctl daemon-reload >/dev/null 2>&1
  return 0
}

run_case() {
  local c="$1" method="${1%-*}" env="e2e-$1" name state kc ok=1 nodes csi=""
  # external needs its own DNS names (they point at the HAProxy host, not the VIPs)
  name="$([[ "$method" == external ]] && echo e2e-ext || echo e2e)"
  mkdir -p "$run_dir/$c"
  make_env "$c" "$env" "$name"
  state="$repo/.work/env/$env"
  kc="$state/$name/kubeconfig"
  nodes=$(( $(setting ocp_master_count) + $(setting ocp_worker_count) ))
  [[ "$(setting proxmox_csi_enabled)" == true ]] && csi="$(setting proxmox_csi_storage_class)" && csi="${csi:-proxmox-data}"

  if phase "$c" deploy ocp -E "$env" deploy; then
    OC="$state/bin/current/oc"
    export OC
    phase "$c" verify env KUBECONFIG="$kc" OC="$OC" \
      "$here/verify.sh" "$method" "$(sed -nE 's/^cni: (.*)/\1/p' "environments/$env/cluster.yml")" \
      "$nodes" "apps.$name.$(setting base_domain)" "$csi" || ok=0
    if [[ "$SCALE" == 0 ]]; then
      record "$c" scale SKIP 0 "--no-scale"
    elif [[ "$method" == external ]]; then
      record "$c" scale SKIP 0 "no Machine API on platform External"
    else
      phase "$c" scale bash -c "$(printf '%q ' "$repo/ocp.sh" --no-tmux --no-pull -E "$env" autoscale) && \
        KUBECONFIG=$(printf '%q' "$kc") OC=$(printf '%q' "$OC") $(printf '%q ' "$here/scale.sh" worker-auto "$name" $AUTOSCALER)" || ok=0
    fi
    ((ok)) || diagnostics "$c" "$kc"
  else
    ok=0
    OC="$state/bin/current/oc" diagnostics "$c" "$kc"
    record "$c" verify SKIP 0 "deploy failed"
    record "$c" scale SKIP 0 "deploy failed"
  fi

  if [[ "$KEEP" == all || ( "$KEEP" == failed && $ok == 0 ) ]]; then
    record "$c" destroy SKIP 0 "kept: ./ocp.sh -E $env destroy"
    warn "[$c] cluster kept - remove it with: OCP_CONFIRM_DESTROY=$name ./ocp.sh -E $env destroy"
  else
    phase "$c" destroy env OCP_CONFIRM_DESTROY="$name" "$repo/ocp.sh" --no-tmux --no-pull -E "$env" destroy
    cleanup_host "$env"
  fi
  write_reports
  return $(( ok == 1 ? 0 : 1 ))
}

failed=0
for c in "${CASES[@]}"; do
  if ! run_case "$c"; then
    failed=$((failed + 1))
    if [[ "$KEEP" == failed ]]; then
      warn "stopping: the kept cluster of $c uses the addresses and VMIDs of the next case"
      break
    fi
  fi
done

write_reports
echo
cat "$run_dir/summary.md"
echo
if ((failed)); then
  fail "$failed of ${#CASES[@]} case(s) failed - logs in $run_dir" || true
  exit 1
fi
pass "all ${#CASES[@]} case(s) passed - $run_dir"
