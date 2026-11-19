# cluster.yml

`group_vars/all/cluster.yml` describes the whole cluster. Change it, commit,
re-run.

## Distribution and version

```yaml
ocp_distribution: ocp               # ocp = Red Hat OpenShift, okd = OKD (SCOS)
ocp_version: "5.0.0"                # OpenShift: any z-stream on the mirror
okd_version: "5.0.0-okd-scos.6"     # OKD: a tag from github.com/okd-project/okd/releases
cluster_name: ocp5
base_domain: lab.example.nl         # API = api.ocp5.lab.example.nl
```

| | OpenShift (`ocp`) | OKD (`okd`) |
|---|---|---|
| What | Red Hat OpenShift Container Platform | community distribution, same code base |
| OS on the nodes | RHEL CoreOS | CentOS Stream CoreOS (SCOS) |
| Pull secret | required | not needed (placeholder) |
| Tools from | mirror.openshift.com | github.com/okd-project/okd releases |
| Release image | quay.io/openshift-release-dev | quay.io/okd/scos-release |
| Support / updates | subscription, Red Hat support | community, `stable` OKD channel |

OKD tags ending in `.ec.N` are pre-releases. Switching distribution on an
existing cluster isn't supported: `destroy.yml` first.

## Network

| Variable | Example | Meaning |
|---|---|---|
| `machine_network` | `192.168.50.0/24` | network of the node VMs |
| `gateway` | `192.168.50.1` | default gateway |
| `dns_servers` | `[192.168.50.200]` | resolvers for the nodes |
| `dns_check_server` | `10.0.3.98` | DNS server the preflight asks (empty = local resolver) |
| `prefix_length` | `24` | prefix of `machine_network` |
| `api_vip` / `ingress_vip` | `.10` / `.11` | VIPs (not used for SNO) |
| `cluster_network` | `10.128.0.0/14` | pod network |
| `service_network` | `172.30.0.0/16` | service network |
| `node_interface` | `ens18` | NIC name used in the agent network config (mapped by MAC) |

## CNI: Calico Open Source

```yaml
cni: Calico                 # or OVNKubernetes (the OpenShift default)
calico_version: "3.33.0"
calico_dataplane: Iptables  # or BPF (replaces kube-proxy)
calico_encapsulation: VXLAN # or IPIP / None
```

The `agent_iso` role downloads the release's Tigera operator manifests and
hands them to the installer, so Calico runs from the first boot.

- Changing CNI or Calico settings needs a fresh cluster
  (`destroy.yml`, then deploy with `-e agent_iso_rebuild=true`).
- OVN-only features (`EgressIP`, `EgressFirewall`, OVN secondary networks)
  don't apply; use Calico `NetworkPolicy` / `GlobalNetworkPolicy`.
- VXLAN needs UDP 4789 between the nodes.
- Calico on OpenShift is supported through Tigera, not Red Hat.

## Proxmox

| Variable | Default | Meaning |
|---|---|---|
| `proxmox_api_host` / `_port` | — / `8006` | Proxmox API (`ocp.sh` uses `127.0.0.1` on the host) |
| `proxmox_api_user` / `_token_id` | `ansible@pve` / `ocp` | API token; the secret is in `vault.yml` |
| `proxmox_validate_certs` | `false` | check the API certificate (set `true` with a real cert) |
| `proxmox_iso_node` | first of `proxmox_nodes` | node that receives the ISO |
| `proxmox_iso_storage` | `local` | storage for ISOs |
| `proxmox_disk_storage` | `local-zfs` | storage for VM disks |
| `proxmox_bridge` / `proxmox_vlan` | `vmbr1` / `""` | network for the VMs |

## Nodes — generated automatically

You don't list VMs by hand. Set counts, sizes and start values:

```yaml
ocp_master_count: 3       # 1 = SNO, 3 = compact / standard
ocp_worker_count: 2
vmid_start: 5100
ip_start: 192.168.50.21
proxmox_nodes: [node02]   # e.g. [pve01, pve02, pve03]
master_size: { cores: 8, memory: 24576, disk_gb: 120 }
worker_size: { cores: 8, memory: 16384, disk_gb: 120 }
```

| Field | Generated as |
|---|---|
| name | `master-0..2`, `worker-0..N` |
| VMID | `vmid_start` + n (masters first) |
| IP | `ip_start` + n |
| MAC | `52:54:00:` + last 3 IP octets in hex — stable and unique per IP |
| Proxmox host | round-robin over `proxmox_nodes` |
| CPU / RAM / disk | `master_size` / `worker_size` |

| Masters / workers | Result | Platform |
|---|---|---|
| 1 / 0 | Single Node OpenShift | `none` |
| 3 / 0 | compact (masters schedulable) | `baremetal` + VIPs |
| 3 / N | standard | `baremetal` + VIPs |

Tweak one node with `node_overrides` (e.g. `worker-1: { memory: 32768 }`) or
list everything yourself in `ocp_nodes_manual`. The playbook refuses IPs that
land on `.0`/`.255`, a VIP or the gateway.

## Other files

| File | What |
|---|---|
| `group_vars/all/autoscale.yml` | [autoscaling settings](../autoscaling/setup.md#settings) |
| `group_vars/all/runner.yml` | [runner LXC](../deploy/github-actions.md) size, IP, VMID |
| `group_vars/all/vault.yml` | [secrets](secrets.md), encrypted with ansible-vault |
| `group_vars/all/derived.yml` | computed values — don't edit |
