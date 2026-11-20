# Installer-provisioned (ipi)

!!! warning "Experimental"
    Built from the OpenShift baremetal IPI documentation and the parts of
    Shiftmox that are proven (Redfish BMC, virtual media, Metal3). Report what
    breaks with `./ocp.sh autoscale-debug` and the installer log.

With `install_method: ipi` Shiftmox doesn't boot the nodes itself. It creates
**empty** VMs and lets the OpenShift installer do the rest through the same
Redfish BMC that powers [autoscaling](../autoscaling/overview.md):

```text
openshift-baremetal-install            (provisioner VM, CentOS Stream + libvirt)
   │ 1. starts the bootstrap VM (Ironic, API VIP) on bridge "baremetal"
   ▼
proxmox-redfish BMC                    (runner LXC, or the Proxmox host via ocp.sh)
   │ 2. Ironic: insert virtual media, set boot device, power on
   ▼  Proxmox API
master-N / worker-N VMs                3. boot the ramdisk, write RHCOS, reboot
   │
   ▼
cluster up → bootstrap VM removed → masters + workers are BareMetalHosts
```

## Steps `site.yml` runs

| Tag | What |
|---|---|
| `tools` | download `openshift-install` and `oc` |
| `bmc` | install / update the Redfish BMC; it now also exposes `master-N` and `worker-N` |
| `vms` | create the node VMs **powered off** with an empty CD drive; create the provisioner VM |
| `ipi` | on the provisioner: libvirt, bridge `baremetal`, extract `openshift-baremetal-install` from the release, `create manifests`, add Calico + hosts MachineConfigs, `create cluster` |
| `wait` | re-attach: `wait-for install-complete`, fetch kubeconfig + kubeadmin password |

`./ocp.sh deploy` does all of it; `./ocp.sh wait` re-attaches.

## Settings

In `group_vars/all/install.yml`:

| Variable | Default | Meaning |
|---|---|---|
| `ipi_provisioner_ip` | `192.168.50.6` | provisioner VM address (on `machine_network`) |
| `ipi_bootstrap_ip` | `192.168.50.7` | bootstrap VM address (there is no provisioning network) |
| `ipi_provisioner_vmid` | `vmid_start - 2` | VMID of the provisioner |
| `ipi_provisioner_size` | 6 cores, 24 GB, 150 GB | the bootstrap VM runs inside it |
| `ipi_provisioner_image_url` | CentOS Stream 10 GenericCloud | cloud image Proxmox downloads |
| `ipi_provisioner_image_storage` | `local` | storage with content **Import** |
| `ipi_ssh_private_key_file` | `ssh_pubkey_file` without `.pub` | Ansible's login to the provisioner |
| `ipi_node_network` | `static` | `static`: nmstate per host, matched by MAC; `dhcp`: static leases from the BMC host |
| `ipi_delete_provisioner` | `false` | delete the provisioner VM after the install |

## Requirements on top of `agent`

- **3 masters** (no SNO).
- **Nested virtualization** on `ipi_provisioner_pve_node` — the bootstrap VM
  runs inside the provisioner. Check on that host:
  `cat /sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) → `Y` / `1`.
- **Content type Import** on `ipi_provisioner_image_storage`
  (Datacenter › Storage › local › Content, Proxmox VE 8.4+).
- **Downloading the cloud image** needs `Sys.Modify` on the node, which the
  deploy token doesn't have. The playbook stops with the exact `wget` command
  to run once on the node.
- **The Redfish BMC must be reachable** from the bootstrap VM and the masters
  (TCP `redfish_bmc_port`, 8443), and the BMC must reach the bootstrap VM
  (it downloads the boot ISO from Ironic there).
- **DNS** exactly as for `agent`: `api`/`api-int` → `api_vip`, `*.apps` → `ingress_vip`.

## Node network

The installer applies `networkConfig` to both the ramdisk and the installed
node. Shiftmox writes it with `identifier: mac-address`, so the interface is
found by its MAC and the NIC name (`ens18` vs. something else on q35) can't
break it — that is what left autoscale workers without network earlier
(see [Troubleshooting](../troubleshooting.md)).

With `ipi_node_network: dhcp` there is no `networkConfig`; the BMC host answers
DHCP for every node MAC with a fixed lease (`proxmox-redfish-dhcp`). Simple,
but the masters then depend on that host whenever they reboot.

Hostnames come from MachineConfigs `99-master-openshift5-hosts` and
`99-worker-openshift5-hosts`, added at install time: `/etc/hosts` for all nodes
and the hostname by MAC. No PTR records needed.

## After the install

- **Console › Compute › Bare Metal Hosts** lists every node, with power
  controls.
- `./ocp.sh autoscale` works as with `agent`: it adds the `worker-auto-N`
  slots. Their DHCP leases, repair job and reaper are unchanged.
- The provisioner VM is only needed to (re)run the install; delete it or set
  `ipi_delete_provisioner: true`.
- `./ocp.sh destroy` removes the node VMs, the provisioner VM and the
  virtual-media ISOs.

## When it fails

| Symptom | Look at |
|---|---|
| stops at "Nested virtualization" | enable nested KVM on the Proxmox host, reboot |
| bootstrap VM never gets the API VIP | provisioner: `virsh list --all`, `virsh console <cluster>-bootstrap`; bridge `baremetal` must hold `ipi_provisioner_ip` |
| hosts stuck in `registering` / `inspecting` | `journalctl -u proxmox-redfish` on the BMC host; can the bootstrap VM reach `redfish_bmc_address:8443`? |
| node boots the ramdisk but has no network | the VM console in Proxmox; try `ipi_node_network: dhcp` |
| installer log | `/opt/shiftmox/<cluster>/.openshift_install.log` on the provisioner |
