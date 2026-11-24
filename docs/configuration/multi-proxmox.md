# Several Proxmox clusters

A Shiftmox cluster can use VMs on **independent Proxmox clusters** — separate
Proxmox installations, each with its own API and token (not nodes of one
Proxmox cluster; those you simply list in `proxmox_nodes`). Masters, workers
and autoscale workers can each go to any of them, so a cluster can span sites
or move autoscale capacity to another Proxmox.

## Configure

The `proxmox_api_*` and `proxmox_*` settings in `cluster.yml` describe the
**main** cluster. Name the others in `proxmox_clusters` and place VMs with
`<cluster>/<node>`:

```yaml
proxmox_clusters:
  site2:
    api_host: 10.20.0.11
    api_token_secret: "{{ vault_site2_token_secret }}"   # in vault.yml
    disk_storage: local-lvm          # defaults: the main cluster's values
    bridge: vmbr1
    # api_port, api_user, api_token_id, validate_certs,
    # iso_node, iso_storage, vlan, region

proxmox_nodes: [node02, site2/pve11, node03]   # round-robin: master-1 lands on site2
autoscale_proxmox_nodes: [site2/pve11, site2/pve12]
node_overrides:
  worker-1: { pve_node: site2/pve12 }
```

A bare node name means the main cluster (`proxmox_main_cluster`, default `main`).

On a node of the other Proxmox cluster, create its API user and token with the
same permissions and print the secret:

```bash
./ocp.sh token --print       # on site2's node; copy the secret into vault.yml
```

## What runs where

| | Per Proxmox cluster |
|---|---|
| Preflight | token + permissions, nodes online, storage/bridge/VMIDs/RAM ([reality check](../deploy/ansible.md#does-clusteryml-match-reality)) |
| Agent ISO | uploaded once per cluster (`iso_storage` on `iso_node`) |
| VMs | created through that cluster's API, with its storage, bridge and VLAN |
| Redfish BMC | one emulator talks to all clusters; each autoscale slot is created on its own cluster; a cluster that is briefly unreachable keeps its last known VMs |
| Destroy | VMs are only deleted where cluster, VMID **and** name match |
| CCM / CSI | one entry per cluster in their config; each cluster is its own `topology.kubernetes.io/region` (`region`, default the cluster's name; the main one uses `proxmox_region`) |
| ipi provisioner, runner LXC | main cluster only |

## Network requirements

OpenShift doesn't know about Proxmox clusters — all nodes are one cluster
network. So every Proxmox cluster must carry **the same L2 network**
(`machine_network`) on its bridge, e.g. a stretched VLAN:

- keepalived VIPs (`api_vip`, `ingress_vip`) move between masters, also across sites;
- autoscale workers get their address by DHCP from the BMC host;
- `ipi` boots nodes from the bootstrap VM on that network.

Latency between sites matters for etcd: keep masters within a few ms of
each other. Spreading **workers** (and autoscale workers) is the easy case.

## Limits

- kubemox mode (`autoscale_vm_provisioning: kubemox`) only uses the main
  cluster; use `on_demand` (the default) for slots on other clusters.
- The serial console recorder only sees VMs on the Proxmox host it runs on.
- `./ocp.sh autoscale-debug` reads VM state with `qm` on the local host.
