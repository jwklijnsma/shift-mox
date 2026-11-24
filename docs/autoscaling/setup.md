# Autoscaling — set up

## Requirements

- A cluster with platform **`baremetal`** (3 masters; not SNO), installed with
  this repo.
- A Linux host on the machine network for the Redfish BMC: the **Proxmox host
  itself** (with `ocp.sh`) or the **runner LXC**. Ironic on the masters must
  reach it on port 8443, and it must reach the Proxmox API and the masters.
- The Proxmox token needs `PVEVMAdmin`, `PVEDatastoreAdmin` (ISO upload) and
  `PVESDNUser`.
- **No DNS records** for the new workers.

## On the Proxmox host

```bash
./ocp.sh autoscale
```

`ocp.sh` takes care of the details:

- finds the host's IPv4 address on `proxmox_bridge` and runs the Redfish BMC,
  DHCP and console recorder there, listening **only on that address**, never
  on the public interface;
- lets the cluster reach the Proxmox API on that same address, so no firewall
  change for 8006 on the internet side;
- creates a separate token `ansible@pve!autoscale` in `secrets/autoscale.json`.

The host must have an IPv4 address on `proxmox_bridge` (e.g. `10.0.3.21/24` on
`vmbr0`); `ocp.sh` stops with a hint if it hasn't. With the Proxmox firewall
on, allow **TCP 8006 and 8443** and **DHCP (UDP 67)** from `machine_network`.

## Elsewhere (runner LXC / Ansible)

```bash
$EDITOR group_vars/all/autoscale.yml
ansible-playbook autoscale.yml --ask-vault-pass
```

By default the BMC goes on the runner LXC (`redfish_bmc_address: runner_lxc_ip`).
Another host: `-e redfish_bmc_hosts=<host> -e redfish_bmc_address=<its IP>`.

`--tags bmc` only (re)installs the BMC side, `--tags cluster` only the
OpenShift side. Re-running is safe: hosts that a worker runs on are never
touched.

## Settings

`group_vars/all/autoscale.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `autoscale_min_workers` | `ocp_worker_count` | lower bound for the autoscaler |
| `autoscale_max_workers` | `6` | upper bound; slots = max − installed workers |
| `autoscale_worker_size` | `worker_size` | CPU / RAM / disk of new workers |
| `autoscale_proxmox_nodes` | `proxmox_nodes` | where new VMs go (round-robin); `<cluster>/<node>` for [another Proxmox cluster](../configuration/multi-proxmox.md) |
| `autoscale_name_prefix` | `worker-auto` | slot names `worker-auto-0..N` |
| `autoscale_vm_provisioning` | `on_demand` | or `kubemox` (pre-created pool) |
| `autoscale_vm_delete_grace` | `300` | seconds a released VM is off before deletion |
| `autoscale_dhcp` | `true` | DHCP with static leases for the slots (recommended) |
| `autoscale_repair_min_age` | `600` | seconds in error before the repair job re-registers a host |
| `autoscale_scale_down_enabled` | `true` | let the autoscaler remove idle workers |
| `autoscale_scale_down_delay_after_add` | `10m` | wait after a scale-up before scaling down |
| `autoscale_scale_down_unneeded_time` | `10m` | how long a worker must be idle |
| `autoscale_scale_down_utilization_threshold` | `0.5` | "idle" = requests below 50 % |
| `autoscale_max_node_provision_time` | `45m` | after this an unregistered new worker is removed |
| `autoscale_cores_max` / `autoscale_memory_max_gib` | `256` / `1024` | cluster-wide limits |
| `redfish_bmc_address` / `_port` | runner IP / `8443` | where the BMC listens |
| `redfish_bmc_user` / `_password` | `metal3` / generated | BMC basic auth |
| `autoscale_proxmox_token_*` | deploy token | token for the BMC (and kubemox) |

IPs and MACs of the slots continue after the last installed node with the same
scheme, e.g. nodes `.91–.95` → slots `.96–.99`.

## What gets installed

**On the BMC host** (systemd services):

| Service | |
|---|---|
| `proxmox-redfish` | Redfish BMC (gunicorn, HTTPS, basic auth) |
| `proxmox-redfish-dhcp` | dnsmasq, DHCP only, static leases for the slot MACs |
| `proxmox-redfish-console` | serial console recorder (only on a Proxmox host) |

**In OpenShift** (`openshift-machine-api` unless noted):

| Object | |
|---|---|
| `BareMetalHost` `worker-auto-N` + `-bmc` secrets | the slots |
| `Provisioning` `provisioning-configuration` | Metal3 without a provisioning network (if missing) |
| `MachineConfig` `99-worker-openshift5-hosts` | `/etc/hosts` + hostname by MAC (applied without reboots via a node disruption policy) |
| `ClusterAutoscaler` `default`, `MachineAutoscaler` | the autoscaler |
| `CronJob` `autoscale-bmh-repair` + RBAC + ConfigMaps | self-repair |
| `ServiceAccount` `proxmox-redfish` | read-only token for the reaper |
