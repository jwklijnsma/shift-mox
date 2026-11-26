# Shiftmox — OpenShift / OKD 5 on Proxmox VE, from code

[![Lint](https://github.com/jwklijnsma/shift-mox/actions/workflows/lint.yml/badge.svg)](https://github.com/jwklijnsma/shift-mox/actions/workflows/lint.yml)
[![Docs](https://github.com/jwklijnsma/shift-mox/actions/workflows/docs.yml/badge.svg)](https://jwklijnsma.github.io/shift-mox/)
[![Release](https://img.shields.io/github/v/release/jwklijnsma/shift-mox?sort=semver)](https://github.com/jwklijnsma/shift-mox/releases)

Deploys **OpenShift Container Platform or OKD 5** on **Proxmox VE** with the
agent-based installer — and makes the workers **scale themselves**, from the
OpenShift console or the ClusterAutoscaler, with worker VMs created in Proxmox
only when they're needed.

📖 **Documentation: <https://jwklijnsma.github.io/shift-mox/>**

```
cluster.yml ─► Ansible ─► agent ISO ─► Proxmox API ─► VMs ─► OpenShift
                                                                 │
 ClusterAutoscaler / console ─► MachineSet ─► Metal3 ─► Redfish BMC for Proxmox
                                                                 │
                                         worker VM created on demand, deleted after scale-down
```

## Features

- **One file describes the cluster** — `group_vars/all/cluster.yml`. VMs (names,
  VMIDs, IPs, MACs, placement) are generated from counts and sizes.
- **Three install methods** — agent-based (default: no PXE, no bootstrap VM, no
  external load balancer), **installer-provisioned** (baremetal IPI: the
  installer powers and installs every VM through a Redfish BMC for Proxmox), or
  **platform External** with the Proxmox cloud-controller-manager.
- **Proxmox CSI driver** (optional) — PersistentVolumes as Proxmox disks.
- **Environments** — several clusters from one checkout (`./ocp.sh -E lab deploy`).
- **Several Proxmox clusters** — masters, workers and autoscale workers can be
  spread over independent Proxmox installations (each with its own API/token).
- **OpenShift or OKD**, **SNO / compact / standard** topologies.
- **Calico Open Source** CNI at install time (or OVN-Kubernetes).
- **`ocp.sh`** — runs everything on the Proxmox host itself, in tmux.
- **GitHub Actions** — manual deploy/destroy on a self-hosted runner LXC; lint
  and docs on every push.
- **Worker autoscaling** — scale from **Compute › MachineSets**, or let the
  ClusterAutoscaler react to `Pending` pods. A Redfish BMC for Proxmox lets
  OpenShift's Metal3 create, power and delete worker VMs.
- **Self-healing and debuggable** — a repair CronJob for broken hosts, serial
  console logs per worker, and `./ocp.sh autoscale-debug`.

## Quick start (on the Proxmox host)

```bash
git clone https://github.com/jwklijnsma/shift-mox /root/shiftmox
cd /root/shiftmox
$EDITOR group_vars/all/cluster.yml    # domain, network, nodes, Proxmox
./ocp.sh deploy                       # ~1–2 h; asks once for pull secret + Proxmox token
./ocp.sh status
./ocp.sh autoscale                    # optional: worker autoscaling
```

Requirements in short: Proxmox VE 8/9 with x86-64-v3 CPUs, an API token
(`./ocp.sh token`), DNS for `api`, `api-int` and `*.apps` — **without** a
wildcard on the cluster domain itself — and a pull secret for OpenShift.
Details: [Requirements](https://jwklijnsma.github.io/shift-mox/getting-started/requirements/).

## Commands

| Command | Does |
|---|---|
| `./ocp.sh deploy [--rebuild]` | full install (fresh agent ISO with `--rebuild`) |
| `./ocp.sh wait` | re-attach to a running install |
| `./ocp.sh status` | nodes, version, operators, console URL, kubeadmin password |
| `./ocp.sh destroy` | delete VMs, ISO and state |
| `./ocp.sh autoscale` | set up worker autoscaling |
| `./ocp.sh autoscale-debug` | one report of everything autoscaling, incl. inside the worker VMs |
| `./ocp.sh addons` | Proxmox CSI driver on a running cluster |
| `./ocp.sh e2e` | end-to-end tests: agent / ipi / external × OVN / Calico — deploy, verify, scale, destroy |
| `./ocp.sh token` / `setup` | Proxmox API token / only tools and secrets |

Without `ocp.sh`: `ansible-playbook site.yml | destroy.yml | autoscale.yml | addons.yml | runner.yml`
— see [Ansible playbooks](https://jwklijnsma.github.io/shift-mox/deploy/ansible/).

## Documentation

| | |
|---|---|
| [Quick start](https://jwklijnsma.github.io/shift-mox/getting-started/quickstart/) | deploy from the Proxmox host |
| [cluster.yml](https://jwklijnsma.github.io/shift-mox/configuration/cluster/) | every setting, generated nodes, Calico, OKD vs OpenShift |
| [Secrets](https://jwklijnsma.github.io/shift-mox/configuration/secrets/) | vault, pull secret, tokens |
| [Environments](https://jwklijnsma.github.io/shift-mox/configuration/environments/) | several clusters from one checkout |
| [Several Proxmox clusters](https://jwklijnsma.github.io/shift-mox/configuration/multi-proxmox/) | VMs on independent Proxmox installations |
| [Install methods](https://jwklijnsma.github.io/shift-mox/install/methods/) | agent vs. installer-provisioned (ipi) vs. platform External + CCM, CSI |
| [GitHub Actions](https://jwklijnsma.github.io/shift-mox/deploy/github-actions/) | runner LXC, secrets, workflow |
| [Autoscaling: how it works](https://jwklijnsma.github.io/shift-mox/autoscaling/overview/) | Metal3, Redfish BMC, on-demand VMs, DHCP |
| [Autoscaling: set up](https://jwklijnsma.github.io/shift-mox/autoscaling/setup/) | requirements, settings, what gets installed |
| [Autoscaling: operations](https://jwklijnsma.github.io/shift-mox/autoscaling/operations/) | scale, test, watch, repair |
| [Troubleshooting](https://jwklijnsma.github.io/shift-mox/troubleshooting/) | `autoscale-debug` and every problem we've solved |

The docs are in [`docs/`](docs/), built with [Zensical](https://zensical.org). Preview locally:

```bash
pip install -r requirements-docs.txt && zensical serve
```

## Layout

```text
site.yml destroy.yml autoscale.yml addons.yml runner.yml   playbooks
ocp.sh                                          all-in-one wrapper for the Proxmox host
group_vars/all/cluster.yml                      <- the cluster
group_vars/all/autoscale.yml                    <- autoscaling
group_vars/all/install.yml                      <- ipi / external / CCM / CSI settings
environments/<name>/cluster.yml                 <- per-environment overrides
roles/                                          tools, agent_iso, proxmox_iso, proxmox_vms,
                                                wait_install, github_runner,
                                                proxmox_redfish, ocp_autoscale, ipi,
                                                external_lb, proxmox_csi
docs/ zensical.toml                             documentation site (Zensical)
.github/workflows/                              deploy, lint, docs, release, auto-release, automerge
```

> **Lab and test use.** Proxmox VE is not a Red Hat certified hypervisor for
> OpenShift; the `none` / `baremetal` agent platforms work, but treat this as a
> lab or test setup.
