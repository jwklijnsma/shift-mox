# Ansible playbooks

`ocp.sh` is a wrapper around these playbooks. You can run them yourself from
any Linux controller that meets the [requirements](../getting-started/requirements.md#controller).

## Setup

```bash
ansible-galaxy collection install -r requirements.yml -p ./collections
mkdir -p secrets && cp ~/Downloads/pull-secret.txt secrets/pull-secret.json
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
$EDITOR group_vars/all/cluster.yml
```

## Playbooks

| Playbook | Does |
|---|---|
| `site.yml` | preflight → tools → agent ISO → upload → VMs → wait for install |
| `destroy.yml` | delete VMs (incl. autoscale workers), ISOs and state |
| `autoscale.yml` | [worker autoscaling](../autoscaling/setup.md) |
| `runner.yml` | create the [GitHub runner LXC](github-actions.md) |

```bash
ansible-playbook site.yml --ask-vault-pass
ansible-playbook destroy.yml --ask-vault-pass -e confirm_destroy=<cluster_name>
```

## Stages (tags) of site.yml

| Tag | Role | Does |
|---|---|---|
| `tools` | `tools` | download + verify `openshift-install` and `oc` |
| `iso` | `agent_iso`, `proxmox_iso` | render configs, build the agent ISO, upload it |
| `upload` | `proxmox_iso` | only upload the ISO |
| `vms` | `proxmox_vms` | create and start the VMs |
| `wait` | `wait_install` | wait for bootstrap / install-complete, print access info |

```bash
ansible-playbook site.yml --tags iso                  # only render configs + build ISO
ansible-playbook site.yml --tags wait                 # re-attach to a running install
ansible-playbook site.yml -e agent_iso_rebuild=true   # fresh ISO after config changes
```

## Preflight

Before anything is built, `site.yml` checks:

- the Proxmox API: the token works and has the needed permissions;
- the node names in `proxmox_nodes` exist in Proxmox and are online;
- DNS: `api`, `api-int` and `*.apps` resolve to the right addresses;
- **no wildcard on the cluster domain** — the installer would otherwise refuse
  to start and only fail after the ~1 h bootstrap timeout.

Generated IPs that land on network/broadcast, a VIP or the gateway are refused
when the node list is built.

`-e skip_dns_check=true` skips the DNS checks.

## Tags of autoscale.yml

| Tag | Does |
|---|---|
| `bmc` | (re)install the Redfish BMC, DHCP and console recorder on the BMC host |
| `cluster` | the OpenShift side: Metal3 hosts, MachineConfig, autoscaler, repair job |
