# Environments

One checkout of Shiftmox can manage several clusters side by side — a lab, a
test and a production cluster, or one OpenShift and one OKD cluster. Each
**environment** is a directory with that cluster's own settings, secrets and
state:

```text
environments/
  example/cluster.yml           template for `ocp.sh env new`
  lab/
    cluster.yml                 only what differs from group_vars/all/*.yml (commit this)
    vault.yml                   Proxmox token secret(s), encrypted (git-ignored)
    secrets/pull-secret.json    Red Hat pull secret (git-ignored)
    secrets/autoscale.json      autoscale token (created by ocp.sh autoscale)
.work/env/lab/                  state: tools, ISO, kubeconfig, logs
```

Without an environment everything works as before: `group_vars/all/cluster.yml`,
`secrets/` and `.work/`.

## Use

```bash
./ocp.sh env new lab                 # creates environments/lab/cluster.yml from the example
$EDITOR environments/lab/cluster.yml
./ocp.sh -E lab deploy               # or: SHIFTMOX_ENV=lab ./ocp.sh deploy
./ocp.sh -E lab status
./ocp.sh -E lab autoscale
./ocp.sh -E lab destroy
./ocp.sh env list
```

Every `ocp.sh` command takes `-E <name>`. A deploy in an environment runs in
its own tmux session (`ocp-<name>`), so two environments can install at the
same time.

Without `ocp.sh`:

```bash
ansible-playbook site.yml --ask-vault-pass \
  -e shiftmox_env=lab -e @environments/lab/cluster.yml -e @environments/lab/vault.yml
```

## How it works

`environments/<name>/cluster.yml` is loaded as **extra vars**: every value in
it overrides `group_vars/all/*.yml`, and everything else is inherited. Put only
the differences in it — at least `cluster_name`, the addresses (`machine_network`,
`gateway`, VIPs, `ip_start`) and `vmid_start`.

`shiftmox_env` moves the state to `.work/env/<name>/` and the pull secret to
`environments/<name>/secrets/pull-secret.json`.

!!! warning "Nothing may overlap"
    Two environments on the same Proxmox and network need different
    `cluster_name`, `vmid_start`, node IPs, VIPs and autoscale slot IPs. The
    [preflight](../deploy/ansible.md#does-clusteryml-match-reality) catches
    VMID and IP clashes with VMs that already exist.

## Shared hosts

| What | Per environment | Shared |
|---|---|---|
| Redfish BMC (autoscaling, ipi) | service `proxmox-redfish-<env>`, config `/etc/proxmox-redfish-<env>/` | Python venv `/opt/proxmox-redfish` |
| BMC port | **set `redfish_bmc_port`** (e.g. 8444) when two environments use the same BMC host — the role refuses a port another environment already uses | |
| DHCP for autoscale workers | leases in `/etc/proxmox-redfish-dhcp.d/50-sm-<env>.conf` | one `proxmox-redfish-dhcp` (dnsmasq) per host |
| Console recorder | | one `proxmox-redfish-console` per Proxmox host |
| GitHub Actions | GitHub environment `proxmox-<env>` with its own secrets; input *environment* | runner |

## Vault

`./ocp.sh -E lab setup` writes the token secret to `environments/lab/vault.yml`
and offers to encrypt it. If you also keep an encrypted
`group_vars/all/vault.yml`, use the **same vault password** for both: Ansible
always loads the group_vars one too.

Secrets of [extra Proxmox clusters](multi-proxmox.md) go into the same
`vault.yml`, e.g. `vault_site2_token_secret: "…"`.
