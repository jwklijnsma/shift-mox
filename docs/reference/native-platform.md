# Design: a native `platform: proxmox`

Shiftmox gets OpenShift onto Proxmox with what the installer already has:
`baremetal` (agent or [IPI](../install/ipi.md)) plus a Redfish BMC, or
[`external`](../install/external.md) plus the Proxmox CCM. A real
`platform: proxmox` — like `vsphere` or `nutanix` — doesn't exist. This page
describes what it would take, so the work can be planned as a project of its
own.

## What a platform is in OpenShift

| Piece | Repository | For Proxmox |
|---|---|---|
| install-config types + validation | `openshift/installer` `pkg/types/proxmox` | API URL, token, node(s), storage, bridge, template |
| infrastructure provisioning | installer, Cluster API provider (since 4.16 the installer runs CAPI in-process) | [CAPMOX](https://github.com/ionos-cloud/cluster-api-provider-proxmox) creates the bootstrap + master VMs |
| `Infrastructure` CR | `openshift/api` (`PlatformType`, `ProxmoxPlatformSpec/Status`) | new enum value + spec — an API change in the release payload |
| Machine API provider | `machine-api-provider-proxmox` (new) | MachineSets → VMs; could wrap CAPMOX or the Proxmox API directly |
| cloud-controller-manager | `cluster-cloud-controller-manager-operator` | ship the Proxmox CCM as an operand |
| storage | `cluster-storage-operator` | ship the Proxmox CSI driver + operator |
| on-prem networking | `machine-config-operator` templates | keepalived/haproxy/coredns as on vSphere/Nutanix |
| boot image | RHCOS/SCOS **qcow2** imported as a Proxmox template | per-release image stream metadata |
| credentials | `cloud-credential-operator` | Proxmox token in `kube-system` |

## Effort, roughly

1. **Fork installer + API** (types, validation, assets, CAPMOX in-process,
   bootstrap ignition via cloud-init/`fw_cfg`): the bulk of the work.
2. **Machine API provider**: a controller turning `Machine` objects into VMs
   (clone template, set cloud-init user-data = worker ignition, start).
3. **Operators**: wire CCM + CSI into the existing operators, or install them
   as extra manifests (what `external` already does).
4. **Release payload**: none of the above is in Red Hat's or OKD's payload.
   It means building and signing a custom OKD release (`oc adm release new`)
   and keeping it current with every z-stream. For OpenShift (`ocp`) this is
   not supportable.

Realistically: weeks of Go work for a first version, and an ongoing rebase
burden. OKD would be the only target.

## Why Shiftmox doesn't do this (yet)

The three install methods cover most of what a native platform adds:

| Native-platform feature | Shiftmox today |
|---|---|
| installer creates all VMs | `ipi` (installer powers + installs, Ansible only creates empty VMs) |
| MachineSets that create VMs | Metal3 + Redfish BMC on-demand slots (`agent`, `ipi`) |
| providerID, zones, node lifecycle | Proxmox CCM (`external`) |
| dynamic volumes on Proxmox storage | Proxmox CSI (all methods) |

The missing combination is *Machine API **and** CCM at the same time*: platform
`baremetal` reserves the providerID for Metal3, platform `external` has no
Machine API. A possible middle step, without forking the installer, is a small
Machine API provider for platform External that reuses the Redfish driver's VM
creation — a project for later.
