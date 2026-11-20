# Proxmox CSI driver

Optional, for every install method: PersistentVolumes become **Proxmox disks**
that are hot-plugged into the VM of the node the pod runs on, with the
[Proxmox CSI plugin](https://github.com/sergelogvinov/proxmox-csi-plugin).

```yaml
# group_vars/all/install.yml
proxmox_csi_enabled: true
proxmox_csi_storage: local-zfs          # any Proxmox storage with content "images"
proxmox_csi_storage_class: proxmox-data
proxmox_csi_default_class: true
proxmox_csi_fstype: xfs
```

Installed at the end of `./ocp.sh deploy`, or on a running cluster:

```bash
./ocp.sh addons                          # = ansible-playbook addons.yml
```

## What gets installed

| | |
|---|---|
| namespace `csi-proxmox` | privileged pod security; controller + node SAs get the privileged SCC |
| Helm release `proxmox-csi-plugin` | controller on the masters, node plugin on every node (masters too) |
| StorageClass `proxmox-data` | `WaitForFirstConsumer`, `Delete`, xfs, `ssd=1` |
| CronJob `proxmox-topology-labels` | *not on `external`*: sets region/zone labels per node (every 2 min), incl. autoscaled workers |

## How a volume finds its VM

The driver needs to know which VM a node is and on which Proxmox node it runs:

- **`external`**: from the CCM's `providerID` and zone label.
- **`agent` / `ipi`** (platform baremetal): the VM whose name starts with the
  node name **and** whose SMBIOS UUID matches the node's system UUID. The zone
  label comes from the CronJob, from the same node → Proxmox node map Shiftmox
  uses to create the VMs.

## Good to know

- **Local storage pins volumes.** On `local-zfs` / `lvm-thin` a volume lives on
  one Proxmox node; its pod can only run on VMs on that node. Shared storage
  (Ceph RBD, NFS) has no such limit.
- The VMs already use the required `VirtIO SCSI single` controller.
- Token: the in-cluster token (`proxmox_k8s_token_*`, default the autoscale
  token) needs `VM.Audit`, `VM.Config.Disk`, `Datastore.Allocate`,
  `Datastore.AllocateSpace`, `Datastore.Audit` — the deploy token has them.
- Disks show up in the VM's hardware list as `scsiN`; don't remove them there
  while a pod uses them.
