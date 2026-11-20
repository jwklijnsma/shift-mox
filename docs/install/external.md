# Platform External + Proxmox CCM (external)

!!! warning "Experimental"
    Uses OpenShift's *platform External* (the path partners such as Oracle
    Cloud use for their own cloud integration) with the community
    [Proxmox cloud-controller-manager](https://github.com/sergelogvinov/proxmox-cloud-controller-manager).

With `install_method: external` the cluster is installed with the agent-based
installer, like `agent`, but tells OpenShift that a cloud-controller-manager
(CCM) for the infrastructure will be there:

```yaml
platform:
  external:
    platformName: proxmox
    cloudControllerManager: External
```

Every kubelet then runs with `--cloud-provider=external`, and each new node
waits (taint `node.cloudprovider.kubernetes.io/uninitialized`) until the
Proxmox CCM has found its VM. The CCM is part of the install manifests, so it
is running before the nodes need it.

## What the CCM does

| | |
|---|---|
| finds the VM | by name (VM `master-0.ocp5` for node `master-0`) **and** SMBIOS UUID |
| `spec.providerID` | `proxmox://<proxmox_region>/<vmid>` |
| labels | `topology.kubernetes.io/region` = `proxmox_region`, `topology.kubernetes.io/zone` = Proxmox node, instance type |
| node lifecycle | a Node whose VM is gone is deleted from the cluster |

It runs as a DaemonSet on the masters with host networking (so before the pod
network is up) in namespace `proxmox-ccm`, with the privileged SCC.

## Load balancer

Platform External has **no keepalived VIPs**. `api`, `api-int` and `*.apps`
must point at a load balancer. Shiftmox installs **HAProxy** on the
`external_lb_hosts` host (default: the runner LXC; `./ocp.sh` on the Proxmox
host uses the host itself):

| Port | Backends |
|---|---|
| 6443 | masters (`/readyz` check) |
| 22623 | masters (machine config server) |
| 80, 443 | workers (masters on a compact cluster) |

DNS for `external`:

| Record | Points to |
|---|---|
| `api.<cluster>.<domain>`, `api-int.<cluster>.<domain>` | `external_lb_address` |
| `*.apps.<cluster>.<domain>` | `external_lb_address` |

For **SNO** no load balancer is installed; all three records point at master-0.
The DNS preflight checks the right addresses for each case.

## Settings

In `group_vars/all/install.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `external_lb_address` | `runner_lxc_ip` | address HAProxy binds to; DNS points here |
| `external_platform_name` | `proxmox` | `platform.external.platformName` |
| `proxmox_ccm_chart_version` | `0.2.32` | Helm chart, rendered with `helm template` into the install |
| `proxmox_region` | `<cluster>-pve` | region name (shared with the CSI driver) |
| `proxmox_k8s_api_url` | `https://<autoscale_proxmox_api_host>:8006/api2/json` | Proxmox API as seen from the cluster |
| `proxmox_k8s_token_id` / `_secret` | the autoscale token (= deploy token by default) | token the CCM uses |

The CCM needs **`Sys.Audit`** and `VM.Audit`. `./ocp.sh token` now also grants
the read-only `PVEAuditor` role; for an existing token run it once more, or:

```bash
pveum acl modify / --users ansible@pve --roles PVEAuditor
```

## Limits

- **No Machine API**: no MachineSets, no BareMetalHosts, no
  `./ocp.sh autoscale` (it refuses). Adding workers later needs the agent
  "add nodes" flow, which Shiftmox doesn't automate yet.
- Changing `install_method` needs a fresh cluster.
- Whether the agent installer accepts a `platformName` other than `oci`
  depends on the release; if `agent create image` rejects it, set
  `external_platform_name` to what the error message allows.
