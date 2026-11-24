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
| `site.yml` | preflight → tools → agent ISO → upload → VMs → wait for install (per [install method](../install/methods.md)) |
| `destroy.yml` | delete VMs (incl. autoscale workers), ISOs and state |
| `autoscale.yml` | [worker autoscaling](../autoscaling/setup.md) |
| `addons.yml` | [Proxmox CSI driver](../install/csi.md) (also run at the end of `site.yml`) |
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
| `lb` | `external_lb` | HAProxy for api / ingress (`external` only) |
| `bmc` | `proxmox_redfish` | Redfish BMC for all node VMs (`ipi` only) |
| `vms` | `proxmox_vms`, `ipi` | create and start the VMs (`ipi`: create them off, plus the provisioner VM) |
| `ipi` | `ipi` | provisioner setup and `openshift-baremetal-install create cluster` |
| `wait` | `wait_install` | wait for bootstrap / install-complete, print access info |
| `csi` | `proxmox_csi` | Proxmox CSI driver when `proxmox_csi_enabled` |

`iso` and `upload` do nothing with `install_method: ipi` (no agent ISO).
`lb` and `bmc` run on `-e external_lb_hosts=…` / `-e redfish_bmc_hosts=…`
(default: the `runner` group); `./ocp.sh` on the Proxmox host passes `localhost`.

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

### Does cluster.yml match reality?

Then every value in `cluster.yml` is checked against the real Proxmox cluster
(role `preflight`). All problems are reported in one go:

| Stops the deploy | |
|---|---|
| Storage | `proxmox_disk_storage` exists on every VM node, is active and allows *Disk image*; `proxmox_iso_storage` allows *ISO image*; `proxmox_csi_storage` when CSI is on |
| Bridge | `proxmox_bridge` exists on every VM node (or is an SDN VNet); `proxmox_vlan` is 1–4094 |
| VMIDs / names | a planned VMID used by another VM, or a VM with the planned name under another VMID |
| Sizes | a VM with more cores or RAM than its Proxmox node; all cluster VMs together need more RAM than a node has |
| Addresses | node IPs, VIPs, gateway (and ipi / autoscale addresses) inside `machine_network`, `prefix_length` matching, no address used twice, no planned address that already answers ping |
| Secrets | the pull secret exists and has Red Hat registries (OpenShift); `ssh_pubkey_file` is a public key |

| Only a warning | |
|---|---|
| RAM / disk | not enough *free* RAM or storage on a node for the new VMs right now (thin storage can overcommit) |
| Network | the gateway doesn't answer ping; an autoscale slot IP is already in use |

VMs that already exist with the planned name and VMID count as *this*
cluster (a re-run), so they don't trigger the VMID or ping checks. The ping
checks only work when the controller is on `machine_network`.

`-e preflight_skip=true` skips these checks; `-e preflight_ping=false` only the pings.

## Tags of autoscale.yml

| Tag | Does |
|---|---|
| `bmc` | (re)install the Redfish BMC, DHCP and console recorder on the BMC host |
| `cluster` | the OpenShift side: Metal3 hosts, MachineConfig, autoscaler, repair job |
