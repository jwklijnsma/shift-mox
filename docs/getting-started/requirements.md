# Requirements

## Proxmox VE

- **Proxmox VE 8.x or 9.x.**
- **x86-64-v3 CPUs (AVX2)** on every host — RHCOS 10 needs it. The VMs use
  `cpu: host`.
- **An API token** for Ansible. `./ocp.sh token` creates it for you on the
  host, or by hand:

    ```bash
    pveum user add ansible@pve
    pveum user token add ansible@pve ocp --privsep 0
    pveum acl modify / --users ansible@pve --roles PVEVMAdmin,PVEDatastoreAdmin,PVESDNUser
    ```

- **ISO storage** that allows content `iso` (`local` by default). With VMs spread
  over several hosts it must be shared, or all VMs must run on
  `proxmox_iso_node`.
- **A bridge for the cluster network** (`proxmox_bridge`, e.g. `vmbr1`). For
  [autoscaling](../autoscaling/setup.md) the Proxmox host (or the runner LXC) also
  needs an IPv4 address on that network.

## DNS

Checked by the playbook before anything is built:

| Record | HA / compact | SNO |
|---|---|---|
| `api.<cluster>.<domain>` | `api_vip` | master-0 IP |
| `api-int.<cluster>.<domain>` | `api_vip` | master-0 IP |
| `*.apps.<cluster>.<domain>` | `ingress_vip` | master-0 IP |

!!! danger "No wildcard on the cluster domain itself"
    A record like `*.<cluster>.<domain>` — or a parent wildcard such as
    `*.<domain>` at your DNS provider — makes the installer refuse to start
    (`dns-wildcard-not-configured`). The preflight catches this. A wildcard on
    `*.apps.<cluster>.<domain>` is fine. See
    [Troubleshooting](../troubleshooting.md#install-never-starts-dns-wildcard).

Autoscaled workers need **no** DNS records: they get their name from DHCP and
an `/etc/hosts` MachineConfig.

## Pull secret

OpenShift (`ocp`) needs a pull secret from
<https://console.redhat.com/openshift/install/pull-secret>. OKD doesn't.

## Sizing

| Role | Minimum | Default in `cluster.yml` |
|---|---|---|
| master | 4 vCPU / 16 GB / 120 GB | 8 vCPU / 24 GB / 120 GB |
| worker | 2 vCPU / 8 GB / 120 GB | 8 vCPU / 16 GB / 120 GB |
| SNO | 8 vCPU / 16 GB / 120 GB | — |

## Controller

Only if you **don't** use `ocp.sh` on the Proxmox host (which installs all of
this itself): Linux x86_64 with

- `ansible-core` ≥ 2.16, `python3-proxmoxer`, `python3-requests`,
  `python3-requests-toolbelt` (ISO upload > 256 MB)
- `nmstate` (`nmstatectl`) — the agent installer validates static network
  config with it
- `dig`, ~10 GB free in `.work/`
