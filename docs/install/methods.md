# Install methods

`install_method` in `group_vars/all/cluster.yml` decides how Shiftmox installs
the cluster. All three work for **OpenShift and OKD** (`ocp_distribution`).

```yaml
install_method: agent      # agent | ipi | external
```

| | `agent` (default) | `ipi` | `external` |
|---|---|---|---|
| Installer | agent-based (`openshift-install agent`) | baremetal IPI (`openshift-baremetal-install`) | agent-based |
| Platform | `baremetal` (`none` for SNO) | `baremetal` | `external` (`platformName: proxmox`) |
| Who creates the VMs | Ansible | Ansible, empty; Metal3 installs them | Ansible |
| How nodes boot the installer | agent ISO in the CD drive | Redfish virtual media, per node | agent ISO in the CD drive |
| Bootstrap | on the first master (rendezvous) | temporary VM on a provisioner VM | on the first master |
| API / ingress | keepalived VIPs | keepalived VIPs | HAProxy on the runner host (`external_lb_address`) |
| Masters and workers as BareMetalHosts | no (autoscale workers only) | **yes, all of them** | no |
| Worker autoscaling (`./ocp.sh autoscale`) | yes | yes | no Machine API |
| Proxmox cloud-controller-manager | no | no | **yes** (providerID, zones, node lifecycle) |
| [Proxmox CSI](csi.md) | optional | optional | optional |
| Topologies | SNO, compact, standard | compact, standard (3 masters) | SNO, compact, standard |
| Status | tested | experimental | experimental |

## Which one?

- **`agent`** — the proven path. Fewest moving parts, no extra VMs.
- **[`ipi`](ipi.md)** — everything is managed by Metal3 from the first minute: the
  console shows every node as a bare metal host with power controls, and
  replacing a broken master or worker goes through the normal OpenShift
  machine flows. Needs a provisioner VM with nested virtualization.
- **[`external`](external.md)** — Kubernetes knows the nodes are Proxmox VMs:
  nodes get `providerID: proxmox://<region>/<vmid>` and `topology.kubernetes.io/zone`
  = Proxmox node, and a Node whose VM is deleted disappears from the cluster.
  The price is no Machine API (no MachineSets, no autoscaling) and an external
  load balancer.

A real `platform: proxmox` in the installer doesn't exist; the
[design notes](../reference/native-platform.md) describe what it would take.

## Switching

The method is fixed when the cluster is installed. To switch:
`./ocp.sh destroy`, change `install_method`, `./ocp.sh deploy`.
