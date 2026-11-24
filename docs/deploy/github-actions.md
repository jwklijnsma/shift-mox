# GitHub Actions

Deploy and destroy from a workflow, on a **self-hosted runner in an LXC on the
Proxmox host**. The deploy has to reach the cluster nodes on the private
bridge (port 8090 on master-0 during install, 6443 after), so a GitHub-hosted
runner can't do it. The runner only makes *outbound* HTTPS connections to
GitHub: nothing has to be opened.

```mermaid
flowchart LR
    GH[GitHub] <-- outbound HTTPS only --- R
    subgraph host[Proxmox host]
        R["runner LXC<br/>192.168.50.5"]
        API[Proxmox API :8006]
        N["cluster nodes<br/>:6443 / :8090"]
    end
    R --> API
    R --> N
```

!!! danger "Keep the repo private"
    On a public repo anyone could open a pull request that runs code on your
    runner.

## 1. Prerequisites

- Root SSH from your machine to the Proxmox host, and `paramiko`
  (`pip install paramiko`) — Ansible configures the LXC with `pct exec`
  through the host, so the container needs no SSH server.
- The host's address in `inventory/hosts.yml` (`pve01`).
- Runner settings in `group_vars/all/runner.yml`:

| Variable | Default |
|---|---|
| `runner_lxc_vmid` | `5099` |
| `runner_lxc_ip` | `192.168.50.5` (on `machine_network`, outside the node range) |
| `runner_lxc_cores` / `_memory` / `_disk_gb` | `2` / `4096` / `40` |
| `runner_lxc_template_pattern` | newest Debian 13/12 standard template |

## 2. Create the LXC and register the runner

```bash
# token: repo › Settings › Actions › Runners › New self-hosted runner
ansible-playbook runner.yml --ask-vault-pass
# or: export GITHUB_PAT=...  (fine-grained, Administration: read/write on this repo)
```

This creates an unprivileged LXC (nesting on, starts on boot) on the cluster
network and installs git, python3-venv, nmstate, dig, a `ghrunner` user, the
latest Actions runner as a systemd service (labels
`self-hosted, linux, proxmox`) and `/var/lib/ocp-deploy` for cluster state.
Re-running is safe.

## 3. Secrets

Repo › Settings › Environments › New environment `proxmox`:

| Secret | Value |
|---|---|
| `PROXMOX_API_TOKEN_SECRET` | the Proxmox API token secret |
| `OCP_PULL_SECRET` | your pull secret (JSON) — not needed for OKD |
| `OCP_SSH_PUBKEY` | public SSH key for the `core` user |
| `ANSIBLE_VAULT_PASSWORD` | optional, only with a committed encrypted `vault.yml` |
| `REDFISH_BMC_PASSWORD` | for the `autoscale` stage: same as the BMC's `redfish_bmc_password` |
| `SHIFTMOX_EXTRA_VARS` | optional JSON with more variables, e.g. `{"vault_site2_token_secret": "…"}` for [another Proxmox cluster](../configuration/multi-proxmox.md) |

For an [environment](../configuration/environments.md) `lab`, create the GitHub
environment **`proxmox-lab`** with its own secrets and run the workflow with
input *environment* = `lab`. Runs of different environments don't block each other.

!!! tip
    Add yourself as **required reviewer** on the environment to get an approval
    click before every deploy or destroy.

## 4. Run

Actions › *Deploy OpenShift on Proxmox* › Run workflow:

| Input | Use |
|---|---|
| action = deploy, stage = all | full install (~1–2 h, job timeout 4 h) |
| stage = iso / vms | only that stage |
| stage = wait | re-attach to an install that is running |
| stage = autoscale | autoscaling, cluster part (see below) |
| rebuild_iso = true | after changing `cluster.yml` before the VMs exist |
| environment = lab | work on `environments/lab/` (secrets from GitHub environment `proxmox-lab`) |
| action = destroy, confirm = `<cluster_name>` | delete VMs, ISO and state |

**Autoscale stage:** the runner user can't install system services, so install
the Redfish BMC once from your machine (`ansible-playbook autoscale.yml --tags bmc`)
and store its password as `REDFISH_BMC_PASSWORD`.

## Notes

- Deploys never start from a push. `lint.yml` (syntax check, ansible-lint,
  ruff, shellcheck) runs on every push/PR on GitHub-hosted runners, without
  secrets. `docs.yml` builds and publishes this site.
- Cluster state, kubeconfig and kubeadmin password stay on the runner in
  `/var/lib/ocp-deploy/<cluster>/`; they're never uploaded as artifacts:
  `sudo -u ghrunner oc --kubeconfig /var/lib/ocp-deploy/<cluster>/kubeconfig get nodes`
- Only one deploy runs at a time (concurrency group).
- **Lock down the API**: restrict 8006 on the Proxmox firewall to your own IPs
  plus the runner. If the runner can't reach the public API name (no hairpin
  NAT), set a repository *variable* `PROXMOX_API_HOST` with an address that
  works from the LXC.
