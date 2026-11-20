#!/usr/bin/env bash
# =============================================================================
# ocp.sh - Shiftmox: deploy OpenShift from the Proxmox host itself (or the runner LXC)
#
#   ./ocp.sh deploy            full install (runs inside tmux, logs to .work/)
#   ./ocp.sh deploy --rebuild  rebuild the agent ISO first (after editing cluster.yml)
#   ./ocp.sh wait              re-attach to an install that is already running
#   ./ocp.sh status            nodes, cluster version, console URL, kubeadmin password
#   ./ocp.sh destroy           delete VMs, ISO and local state (asks for confirmation)
#   ./ocp.sh autoscale         worker autoscaling: Redfish BMC, on-demand VMs,
#                              Metal3 hosts, ClusterAutoscaler (after deploy)
#   ./ocp.sh addons            Proxmox CSI driver (proxmox_csi_enabled) on a running cluster
#   ./ocp.sh autoscale-debug   everything about autoscaling in one report
#                              (MachineSets, Machines, hosts, nodes, CSRs,
#                              autoscaler + machine controller logs, Redfish BMC)
#   ./ocp.sh setup             only install tools and prepare secrets
#   ./ocp.sh token             (re)create the Proxmox API user + token (on the node)
#
# Options:
#   --no-tmux        run in the foreground instead of a tmux session
#   --public-api     use proxmox_api_host from cluster.yml even on the PVE host
#   --no-pull        don't git pull the latest code first
#   -h, --help       this help
#
# Environment (all optional, otherwise you are prompted once):
#   PROXMOX_API_TOKEN_SECRET  Proxmox API token secret
#   OCP_PULL_SECRET_FILE      path to your Red Hat pull secret
#   ANSIBLE_VAULT_PASSWORD_FILE  file holding the vault password
#   REPO_URL                  repo to clone when run outside a checkout
#   REPO_DIR                  where to clone it (default /root/shiftmox)
# =============================================================================
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/jwklijnsma/shift-mox}"
REPO_DIR="${REPO_DIR:-/root/shiftmox}"
VENV="${VENV:-/opt/ansible-venv}"
TMUX_SESSION="ocp"

c_info=$'\e[1;34m' c_ok=$'\e[1;32m' c_warn=$'\e[1;33m' c_err=$'\e[1;31m' c_off=$'\e[0m'
[[ -t 1 ]] || { c_info='' c_ok='' c_warn='' c_err='' c_off=''; }
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ✓ %s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s !  %s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s ✗ %s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

is_pve_host() { command -v pveversion >/dev/null 2>&1; }

# --- 1. locate or clone the repo ---------------------------------------------
find_repo() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/site.yml" ]]; then
    REPO_DIR="$here"
  elif [[ ! -f "$REPO_DIR/site.yml" ]]; then
    need_cmd git || apt_install git
    info "Cloning $REPO_URL to $REPO_DIR"
    git clone -q "$REPO_URL" "$REPO_DIR"
  fi
  cd "$REPO_DIR"
  update_repo
}

# Always run the latest code: fast-forward only, so local edits (cluster.yml)
# are never overwritten - if they conflict, git refuses and we keep going.
update_repo() {
  [[ "$NO_PULL" == 1 || ! -d .git ]] && return 0
  local before after out
  before="$(git rev-parse --short HEAD)"
  # Never prompt: a private repo without credentials must fail fast, not hang
  if out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
            git pull --ff-only -q 2>&1)"; then
    after="$(git rev-parse --short HEAD)"
    if [[ "$before" == "$after" ]]; then
      ok "code is up to date ($after)"
    else
      ok "updated code $before -> $after"
      # The running copy of this script is the old one: restart with the new one
      if ! git diff --quiet "$before" "$after" -- ocp.sh; then
        info "ocp.sh itself changed - restarting with the new version"
        exec "$REPO_DIR/ocp.sh" --no-pull "${ORIG_ARGS[@]}"
      fi
    fi
  elif grep -qiE 'username|password|authentication|terminal prompts disabled|permission denied|publickey|403' <<<"$out"; then
    warn "can't pull from $(git remote get-url origin): no GitHub credentials on this host."
    warn "Running the local code ($before). Set up a deploy key (README: 'Updating the code on the host')"
    warn "or skip this check with --no-pull."
  elif grep -qiE 'would be overwritten|not possible to fast-forward|diverg|merge' <<<"$out"; then
    warn "git pull refused - running OLD code ($before). Local changes that conflict:"
    git status --short --untracked-files=no >&2 || true
    warn "Keep your edits and update:  git stash && git pull && git stash pop"
  else
    warn "git pull failed ($(head -n1 <<<"$out")) - running the local code ($before)"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }
APT_UPDATED=0
apt_install() {
  [[ $EUID -eq 0 ]] || die "run as root (needed to install: $*)"
  info "Installing packages: $*"
  # apt's "configured multiple times" warnings are harmless; keep them off screen
  if [[ $APT_UPDATED == 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | grep -v '^W: ' || true
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

# nmstatectl: openshift-install uses it to validate the static network config.
# Debian/Proxmox has no nmstate package, so fall back to the upstream binary
# (needs only libc), pinned by checksum.
NMSTATE_VERSION=2.2.55
NMSTATE_SHA256=a0aaa72e9fd1c9df35a875339268cbe8acafdf269cfbca2b7a4897ba4033aa69
install_nmstatectl() {
  need_cmd nmstatectl && return 0
  if apt-cache show nmstate >/dev/null 2>&1; then
    apt_install nmstate && return 0
  fi
  [[ $EUID -eq 0 ]] || die "run as root (needed to install nmstatectl)"
  [[ "$(uname -m)" == x86_64 ]] || die "no nmstate package and no upstream binary for $(uname -m)"
  info "nmstate not in apt - installing nmstatectl $NMSTATE_VERSION from GitHub to /usr/local/bin"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/nm.zip" \
    "https://github.com/nmstate/nmstate/releases/download/v$NMSTATE_VERSION/nmstatectl-linux-x64.zip"
  echo "$NMSTATE_SHA256  $tmp/nm.zip" | sha256sum -c --quiet - || die "nmstatectl checksum mismatch"
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("nmstatectl", sys.argv[2])' \
    "$tmp/nm.zip" "$tmp"
  install -m 755 "$tmp/nmstatectl" /usr/local/bin/nmstatectl
  rm -rf "$tmp"
  nmstatectl --version >/dev/null || die "nmstatectl installed but does not run"
}

# --- 2. tools ------------------------------------------------------------------
setup_tools() {
  local pkgs=()
  need_cmd git        || pkgs+=(git)
  need_cmd tmux       || pkgs+=(tmux)
  need_cmd curl       || pkgs+=(curl)
  need_cmd getent     || pkgs+=(libc-bin)
  need_cmd dig        || pkgs+=(bind9-dnsutils)
  need_cmd ssh-keygen || pkgs+=(openssh-client)
  python3 -c 'import venv, ensurepip' 2>/dev/null || pkgs+=(python3-venv)
  if ((${#pkgs[@]})); then apt_install "${pkgs[@]}"; fi
  install_nmstatectl
  ok "nmstatectl $(nmstatectl --version 2>/dev/null | awk '{print $2}')"

  # Ansible goes in its own venv - never pip into the hypervisor's system python
  if [[ ! -x "$VENV/bin/ansible-playbook" ]]; then
    info "Creating Ansible venv in $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
  fi
  # Checked every run, so an existing venv also gets libraries added later.
  # requests_toolbelt: proxmox_template needs it for uploads > 256 MB (the ISO).
  if ! "$VENV/bin/python" -c 'import ansible, proxmoxer, requests, requests_toolbelt' 2>/dev/null; then
    info "Installing Python packages in $VENV"
    "$VENV/bin/pip" install -q ansible-core proxmoxer requests requests-toolbelt
  fi
  export PATH="$VENV/bin:$PATH"

  if [[ ! -d collections/ansible_collections/community/proxmox ]]; then
    info "Installing Ansible collections"
    ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null
  fi
  ok "tools ready ($(ansible --version | head -1))"
}

# --- 3. secrets ------------------------------------------------------------------
vault_file=group_vars/all/vault.yml

setup_secrets() {
  # Pull secret (OpenShift only - OKD needs none)
  mkdir -p secrets && chmod 700 secrets
  if [[ "$(cluster_var ocp_distribution)" == okd ]]; then
    ok "pull secret not needed (OKD)"
  elif [[ ! -s secrets/pull-secret.json ]]; then
    if [[ -n "${OCP_PULL_SECRET_FILE:-}" ]]; then
      install -m 600 "$OCP_PULL_SECRET_FILE" secrets/pull-secret.json
    else
      info "Paste your pull secret (https://console.redhat.com/openshift/install/pull-secret), then Enter:"
      local ps; IFS= read -r ps
      (umask 077; printf '%s' "$ps" > secrets/pull-secret.json)
    fi
  fi
  if [[ -s secrets/pull-secret.json ]]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "auths" in d' secrets/pull-secret.json \
      2>/dev/null || { rm -f secrets/pull-secret.json; die "pull secret is not valid JSON with an 'auths' key"; }
    ok "pull secret"
  fi

  # SSH key for the core user on the nodes
  if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
    info "Creating SSH key ~/.ssh/id_ed25519 (login to the nodes as 'core')"
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C "ocp@$(hostname)"
  fi
  ok "ssh key"

  # Proxmox API token secret
  if [[ ! -f "$vault_file" ]]; then
    if [[ -n "${PROXMOX_API_TOKEN_SECRET:-}" ]]; then
      write_vault "$PROXMOX_API_TOKEN_SECRET"
    elif is_pve_host; then
      cmd_token          # on the node itself: create it, no copy/paste
      return 0
    else
      local tok
      read -rsp "Proxmox API token secret: " tok; echo
      [[ -n "$tok" ]] || die "no token secret given"
      write_vault "$tok"
    fi
  fi
  ok "proxmox token"
}

write_vault() {
  (umask 077; printf -- '---\nproxmox_api_token_secret: "%s"\n' "$1" > "$vault_file")
  local a
  read -rp "Encrypt $vault_file with ansible-vault? [Y/n] " a
  if [[ "${a,,}" != n* ]]; then
    ansible-vault encrypt "$vault_file"
  fi
}

# On the Proxmox node: create the API user, its permissions and a fresh token
# with pveum, and store the secret in vault.yml. Re-running replaces the token.
cmd_token() {
  is_pve_host || die "'token' only works on the Proxmox node itself (needs pveum)"
  [[ $EUID -eq 0 ]] || die "run as root"
  local user tid secret
  user="$(cluster_var proxmox_api_user)"; tid="$(cluster_var proxmox_api_token_id)"
  [[ -n "$user" && -n "$tid" ]] || die "proxmox_api_user / proxmox_api_token_id missing in cluster.yml"
  info "Creating Proxmox API token $user!$tid"
  if [[ "$user" != *@pam ]] && pveum user add "$user" --comment "OpenShift deploy (ocp.sh)" >/dev/null 2>&1; then
    ok "user $user created"
  fi
  # PVESDNUser: needed since PVE 8 to attach VMs/LXCs to a bridge
  # PVEAuditor (read-only, Sys.Audit): needed by the Proxmox CCM (install_method external)
  pveum acl modify / --users "$user" --roles PVEVMAdmin,PVEDatastoreAdmin,PVESDNUser,PVEAuditor
  ok "permissions on / : PVEVMAdmin, PVEDatastoreAdmin, PVESDNUser, PVEAuditor"
  pveum user token remove "$user" "$tid" >/dev/null 2>&1 || true
  secret="$(pveum user token add "$user" "$tid" --privsep 0 --comment "ocp.sh" --output-format json \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
  [[ "$secret" =~ ^[0-9a-f-]{36}$ ]] || die "pveum did not return a token secret"
  ok "token $user!$tid created (privilege separation off)"
  [[ -f "$vault_file" ]] && cp -p "$vault_file" "$vault_file.bak"
  write_vault "$secret"
  ok "secret stored in $vault_file"
  warn "If GitHub Actions uses this token, update the PROXMOX_API_TOKEN_SECRET secret there too."
}

# Worker autoscaling. On the Proxmox node everything runs here: the Redfish BMC
# emulator becomes a service on this host (listening only on its IP on the
# cluster bridge), kubemox in the cluster reaches the API on that same IP, and
# both use their own token "autoscale" (created here, kept in secrets/).
bridge_ip() {  # IPv4 of this host on the cluster bridge (or its VLAN interface)
  local br vlan dev ip
  br="$(cluster_var proxmox_bridge)"; vlan="$(cluster_var proxmox_vlan)"
  for dev in ${vlan:+"$br.$vlan"} "$br"; do
    ip="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  done
  return 1
}

install_var() {  # read a plain value from group_vars/all/install.yml
  sed -nE "s/^$1:[[:space:]]*\"?([^\"#]+)\"?.*/\1/p" group_vars/all/install.yml | head -1 | xargs
}

# On the Proxmox node, the Redfish BMC (ipi), the load balancer (external) and
# the Proxmox API address for in-cluster clients (CCM, CSI) all use this
# host's address on the cluster bridge - like `autoscale` does.
# Sets HARGS (extra ansible-playbook arguments).
HARGS=()
host_role_args() {
  local method csi ip
  HARGS=()
  method="$(cluster_var install_method)"; method="${method:-agent}"
  csi="$(install_var proxmox_csi_enabled)"
  is_pve_host || return 0
  [[ "$method" == agent && "$csi" != true ]] && return 0
  ip="$(bridge_ip)" || die "this host has no IPv4 address on bridge $(cluster_var proxmox_bridge).
   install_method $method / the CSI driver need this host on the cluster network.
   Give the bridge an IP in $(cluster_var machine_network), or run from the runner LXC."
  [[ "$method" == external ]] && info "install_method external: api, api-int and *.apps must point to $ip (HAProxy on this host)"
  HARGS=(-e redfish_bmc_hosts=localhost -e "redfish_bmc_address=$ip"
         -e external_lb_hosts=localhost -e "external_lb_address=$ip"
         -e "autoscale_proxmox_api_host=$ip" -e autoscale_proxmox_validate_certs=false)
}

autoscale_token() {  # dedicated token for kubemox + emulator -> secrets/autoscale.json
  local f=secrets/autoscale.json user secret
  [[ -s "$f" ]] && return 0
  [[ $EUID -eq 0 ]] || die "run as root (creates a Proxmox API token)"
  user="$(cluster_var proxmox_api_user)"
  pveum user list --output-format json | python3 -c 'import json,sys; sys.exit(0 if any(u["userid"]==sys.argv[1] for u in json.load(sys.stdin)) else 1)' "$user" \
    || die "Proxmox user $user does not exist yet - run ./ocp.sh token (or deploy) first"
  pveum user token remove "$user" autoscale >/dev/null 2>&1 || true
  secret="$(pveum user token add "$user" autoscale --privsep 0 --comment "ocp.sh autoscale (kubemox + Redfish BMC)" \
            --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
  [[ "$secret" =~ ^[0-9a-f-]{36}$ ]] || die "pveum did not return a token secret"
  mkdir -p secrets && chmod 700 secrets
  (umask 077; printf '{"autoscale_proxmox_token_id": "autoscale", "autoscale_proxmox_token_secret": "%s"}\n' "$secret" > "$f")
  ok "token $user!autoscale created for autoscaling (revoke: pveum user token remove $user autoscale)"
}

cmd_autoscale() {
  if ! is_pve_host; then
    playbook autoscale.yml
    return
  fi
  local ip; ip="$(bridge_ip)" || die "this host has no IPv4 address on bridge $(cluster_var proxmox_bridge).
   The masters must reach the Redfish BMC and kubemox the Proxmox API on that network.
   Give the bridge an IP in $(cluster_var machine_network) (Datacenter > node > System > Network),
   or run the BMC elsewhere: ansible-playbook autoscale.yml -e redfish_bmc_hosts=runner"
  ok "cluster bridge address of this host: $ip"
  autoscale_token
  if command -v pve-firewall >/dev/null && pve-firewall status 2>/dev/null | grep -q 'enabled/running'; then
    warn "Proxmox firewall is on: allow TCP 8006 and 8443 from $(cluster_var machine_network) to this host"
  fi
  playbook autoscale.yml -e @secrets/autoscale.json \
    -e redfish_bmc_hosts=localhost -e redfish_bmc_address="$ip" \
    -e autoscale_proxmox_api_host="$ip" -e autoscale_proxmox_validate_certs=false
}

vault_args() {
  if head -c 14 "$vault_file" 2>/dev/null | grep -qF "\$ANSIBLE_VAULT"; then
    if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
      printf -- '--vault-password-file\n%s\n' "$ANSIBLE_VAULT_PASSWORD_FILE"
    else
      echo --ask-vault-pass
    fi
  fi
}

# --- 4. run --------------------------------------------------------------------
cluster_var() {  # read a plain value from cluster.yml
  sed -nE "s/^$1:[[:space:]]*\"?([^\"#]+)\"?.*/\1/p" group_vars/all/cluster.yml | head -1 | xargs
}

playbook() {
  local args=()
  mapfile -t args < <(vault_args)
  # On the PVE host: talk to the API over loopback, traffic never leaves the box.
  # The cert is issued for the public name, so validation is off for 127.0.0.1 only.
  if is_pve_host && [[ "$PUBLIC_API" != 1 ]]; then
    args+=(-e proxmox_api_host=127.0.0.1 -e proxmox_validate_certs=false)
  fi
  mkdir -p .work
  local log
  log=".work/${1%.yml}-$(date +%Y%m%d-%H%M%S).log"
  info "ansible-playbook $* (log: $REPO_DIR/$log)"
  local rc=0
  ANSIBLE_FORCE_COLOR=1 ansible-playbook "$@" "${args[@]}" 2>&1 | tee "$log" || rc=$?
  ((rc == 0)) || die "ansible-playbook $1 failed (exit $rc) - see the error above, full log: $REPO_DIR/$log"
}

in_tmux() {
  # Re-run this script inside tmux so a dropped SSH session doesn't kill a 1-2 h install
  [[ "$NO_TMUX" == 1 || -n "${TMUX:-}" ]] && return 1
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    warn "tmux session '$TMUX_SESSION' already exists - attaching to it"
    exec tmux attach -t "$TMUX_SESSION"
  fi
  info "Starting in tmux session '$TMUX_SESSION' (detach: Ctrl-b d, back: tmux attach -t $TMUX_SESSION)"
  info "Output is also saved to $REPO_DIR/.work/ocp-tmux.log"
  # tmux gets argv directly (no sh/dash in between). The window stays open
  # at the end, also after an error, so the message can't disappear.
  # --no-pull: this run already pulled.
  exec tmux new-session -s "$TMUX_SESSION" bash -c "$TMUX_WRAPPER" \
    "$REPO_DIR/ocp.sh" "${ORIG_ARGS[@]}" --no-pull
}

# shellcheck disable=SC2016  # expanded by the bash inside tmux, not here
TMUX_WRAPPER='log="$(dirname "$0")/.work/ocp-tmux.log"; mkdir -p "${log%/*}"
echo "=== $(date) ocp.sh $*" >> "$log"
"$0" "$@" 2>&1 | tee -a "$log"; rc=${PIPESTATUS[0]}
echo
if [ "$rc" -eq 0 ]; then echo "=== Finished OK."; else echo "=== FAILED (exit $rc) - see the output above or $log"; fi
echo "=== exit $rc" >> "$log"
read -r -p "Press Enter to close this window. " _'

cmd_status() {
  local name domain kc
  name="$(cluster_var cluster_name)"; domain="$(cluster_var base_domain)"
  kc=".work/$name/kubeconfig"
  [[ -f "$kc" ]] || die "no kubeconfig at $REPO_DIR/$kc - has the cluster been deployed?"
  export KUBECONFIG="$REPO_DIR/$kc"
  local oc=".work/bin/current/oc"
  # clusters deployed before bin/current existed: take the newest release dir
  [[ -x "$oc" ]] || oc="$(printf '%s\n' .work/bin/*/oc | sort -V | tail -n1)"
  [[ -x "$oc" ]] || die "no oc binary under $REPO_DIR/.work/bin - run ./ocp.sh setup first"
  "$oc" get nodes -o wide || true
  "$oc" get clusterversion || true
  "$oc" get co --no-headers 2>/dev/null | awk '$3!="True"||$4!="False"||$5!="False"{bad++} END{print (bad? bad" cluster operators not healthy" : "all cluster operators healthy")}' || true
  echo
  echo "Console:    https://console-openshift-console.apps.$name.$domain"
  echo "KUBECONFIG: export KUBECONFIG=$REPO_DIR/$kc"
  echo "oc:         $REPO_DIR/$oc"
  echo "kubeadmin:  $(cat ".work/$name/kubeadmin-password" 2>/dev/null || echo '?')"
}

cmd_autoscale_debug() {
  local name kc oc ns=openshift-machine-api out
  name="$(cluster_var cluster_name)"
  kc=".work/$name/kubeconfig"
  [[ -f "$kc" ]] || die "no kubeconfig at $REPO_DIR/$kc - has the cluster been deployed?"
  export KUBECONFIG="$REPO_DIR/$kc"
  oc=".work/bin/current/oc"
  [[ -x "$oc" ]] || oc="$(printf '%s\n' .work/bin/*/oc | sort -V | tail -n1)"
  [[ -x "$oc" ]] || die "no oc binary under $REPO_DIR/.work/bin"
  out=".work/autoscale-debug-$(date +%Y%m%d-%H%M%S).txt"
  sec() { printf '\n===== %s =====\n' "$1"; }
  # A report: empty greps and failing commands are normal, never abort.
  (
    trap - ERR; set +e +o pipefail
    sec "MachineSets / autoscalers"
    "$oc" -n "$ns" get machinesets.machine.openshift.io,machineautoscaler -o wide 2>&1
    "$oc" get clusterautoscaler -o yaml 2>&1 | sed -n '/^  spec:/,/^  status:/p'
    sec "Machines"
    "$oc" -n "$ns" get machines.machine.openshift.io -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name,HOST:.metadata.annotations.metal3\.io/BareMetalHost,ERROR:.status.errorMessage' 2>&1
    sec "BareMetalHosts"
    "$oc" -n "$ns" get baremetalhosts.metal3.io -o custom-columns='NAME:.metadata.name,STATE:.status.provisioning.state,OPSTATUS:.status.operationalStatus,ONLINE:.spec.online,POWERED:.status.poweredOn,CONSUMER:.spec.consumerRef.name,ERRTYPE:.status.errorType,ERROR:.status.errorMessage' 2>&1
    sec "Nodes"
    "$oc" get nodes -o wide 2>&1
    sec "Pending CSRs"
    "$oc" get csr 2>&1 | awk 'NR==1 || /Pending/'
    sec "Pending pods (what the autoscaler should react to)"
    "$oc" get pods -A --field-selector=status.phase=Pending -o wide 2>&1 | head -30
    sec "cluster-autoscaler log"
    "$oc" -n "$ns" logs deploy/cluster-autoscaler-default --tail=60 2>&1 | grep -v ' I[0-9]' | tail -40
    "$oc" -n "$ns" logs deploy/cluster-autoscaler-default --tail=300 2>&1 | grep -iE 'scale.?up|scale.?down|node group|max|unschedulable|error' | tail -25
    sec "machine-controller log (errors)"
    "$oc" -n "$ns" logs deploy/machine-api-controllers -c machine-controller --tail=400 2>&1 | grep -iE 'error|fail|host|no available' | tail -30
    sec "metal3 / BMO events"
    "$oc" -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | grep -iE 'baremetalhost|machine|worker-auto' | tail -30
    sec "repair CronJob"
    "$oc" -n "$ns" get cronjob autoscale-bmh-repair 2>&1
    j="$("$oc" -n "$ns" get jobs -o name 2>/dev/null | grep autoscale-bmh-repair | tail -n1)"
    [[ -n "$j" ]] && "$oc" -n "$ns" logs "$j" 2>&1 | tail -15
    sec "Redfish BMC (proxmox-redfish), not the routine GETs"
    journalctl -u proxmox-redfish --since "6 hours ago" --no-pager 2>&1 | grep -v '"GET /redfish' | tail -50
    sec "DHCP for the slots (proxmox-redfish-dhcp)"
    systemctl is-active proxmox-redfish-dhcp 2>&1
    journalctl -u proxmox-redfish-dhcp --since "6 hours ago" --no-pager 2>&1 | grep -E 'DHCP(OFFER|ACK|NAK|DISCOVER)|error|fail' | tail -15

    sec "Serial console of the autoscale workers (/var/log/proxmox-redfish)"
    local f
    for f in /var/log/proxmox-redfish/*.log; do
      [[ -f "$f" ]] || { echo "no console logs yet"; break; }
      echo "--- $f (last 80 lines)"
      sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' "$f" | grep -v '^[[:space:]]*$' | tail -80
    done

    sec "Proxmox VMs worker-auto-*"
    qm list 2>&1 | awk 'NR==1 || /worker-auto/'

    # Inside every running autoscale VM: why doesn't it become a node?
    local domain vmid vname slot ip
    domain="$(cluster_var cluster_name).$(cluster_var base_domain)"
    while read -r vmid vname; do
      slot="${vname%%.*}"
      # fixed IP of the slot: from the DHCP static leases (dhcp-host=mac,ip,name,...)
      ip="$(awk -F'[=,]' -v n="$slot" '$1 == "dhcp-host" && $4 == n {print $3; exit}' /etc/proxmox-redfish/dhcp.conf 2>/dev/null)"
      # fallback: the hardware-details annotation (BMO removes it after registration)
      [[ -n "$ip" ]] || ip="$("$oc" -n "$ns" get baremetalhosts.metal3.io "$slot" -o jsonpath='{.metadata.annotations.inspect\.metal3\.io/hardwaredetails}' 2>/dev/null \
            | grep -o '"ip": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
      sec "VM $vmid $vname (IP ${ip:-unknown})"
      shot=".work/autoscale-debug-console-$slot.png"
      echo "screendump /tmp/ocp-shot-$vmid.ppm" | qm monitor "$vmid" >/dev/null 2>&1 \
        && python3 - "/tmp/ocp-shot-$vmid.ppm" "$shot" <<'PY' && echo "console screenshot: $REPO_DIR/$shot"
import sys, zlib, struct
data = open(sys.argv[1], "rb").read()
parts = data.split(b"\n", 3)                     # P6 / w h / 255 / pixels
w, h = map(int, parts[1].split())
px = parts[3]
raw = b"".join(b"\x00" + px[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[2], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
PY
      rm -f "/tmp/ocp-shot-$vmid.ppm"
      [[ -n "$ip" ]] || continue
      if ping -c1 -W2 "$ip" >/dev/null 2>&1; then echo "ping: ok"; else echo "ping: NO ANSWER (network on the VM not up?)"; fi
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR \
          "core@$ip" "DOMAIN=$domain bash -s" <<'REMOTE' || echo "ssh core@$ip: not reachable (ignition probably didn't run - see the console screenshot)"
echo "hostname: $(hostnamectl hostname 2>/dev/null || hostname)"
ip -br a; ip r | head -3
echo "resolv: $(grep nameserver /etc/resolv.conf | tr '\n' ' ')"
echo "api-int: $(getent hosts api-int.$DOMAIN || echo 'DOES NOT RESOLVE')"
echo "MCS 22623: $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://api-int.$DOMAIN:22623/healthz)"
echo "API 6443:  $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://api-int.$DOMAIN:6443/readyz)"
echo "boots: $(journalctl --list-boots --no-pager 2>/dev/null | wc -l)"
echo "--- rpm-ostree status (boot image 9.x vs cluster 10.x?)"; rpm-ostree status 2>&1 | head -20
echo "--- failed units"; systemctl --failed --no-legend --no-pager
echo "--- autoscale-hosts / node-valid-hostname"; sudo journalctl -b --no-pager -u autoscale-hosts -u node-valid-hostname | tail -8
echo "--- machine-config-daemon-firstboot"; sudo journalctl -b --no-pager -u machine-config-daemon-firstboot | tail -15
echo "--- kubelet (last 40)"; sudo journalctl -b --no-pager -u kubelet | tail -40
echo "--- errors this boot"; sudo journalctl -b --no-pager -p err | tail -15
REMOTE
    done < <(qm list 2>/dev/null | awk '/worker-auto/ && $3=="running" {print $1, $2}')
  ) 2>&1 | tee "$out"
  echo
  ok "report saved to $REPO_DIR/$out"
}

cmd_destroy() {
  local name; name="$(cluster_var cluster_name)"
  warn "This deletes all VMs of cluster '$name', the agent ISO and $REPO_DIR/.work/$name."
  read -rp "Type the cluster name to confirm: " c
  [[ "$c" == "$name" ]] || die "not confirmed"
  playbook destroy.yml -e "confirm_destroy=$c"
}

# --- main ------------------------------------------------------------------------
ORIG_ARGS=("$@")
ACTION="" NO_TMUX=0 PUBLIC_API=0 REBUILD=0 NO_PULL=0
while (($#)); do
  case "$1" in
    deploy|wait|status|destroy|setup|token|autoscale|autoscale-debug|addons) ACTION="$1" ;;
    --rebuild)    REBUILD=1 ;;
    --no-tmux)    NO_TMUX=1 ;;
    --public-api) PUBLIC_API=1 ;;
    --no-pull)    NO_PULL=1 ;;
    -h|--help)    usage 0 ;;
    *) warn "unknown argument: $1"; usage 1 ;;
  esac
  shift
done
[[ -n "$ACTION" ]] || usage 1

main() {
  find_repo
  is_pve_host && info "Running on Proxmox VE host $(hostname) ($(pveversion | cut -d/ -f2))"
  case "$ACTION" in
    setup)   setup_tools; setup_secrets; ok "ready - run: $REPO_DIR/ocp.sh deploy" ;;
    deploy)  setup_tools; setup_secrets; in_tmux || true
             host_role_args
             playbook site.yml -e "agent_iso_rebuild=$([[ $REBUILD == 1 ]] && echo true || echo false)" "${HARGS[@]}"
             cmd_status ;;
    wait)    setup_tools; in_tmux || true
             host_role_args
             playbook site.yml --tags wait "${HARGS[@]}"; cmd_status ;;
    addons)  setup_tools; setup_secrets
             host_role_args
             playbook addons.yml "${HARGS[@]}" ;;
    status)  cmd_status ;;
    autoscale) setup_tools; setup_secrets; cmd_autoscale; cmd_status ;;
    autoscale-debug) cmd_autoscale_debug ;;
    token)   setup_tools; cmd_token ;;
    destroy) setup_tools; cmd_destroy ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
