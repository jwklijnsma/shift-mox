# Repository layout

```text
site.yml  destroy.yml  autoscale.yml  runner.yml   playbooks
ocp.sh                                deploy / wait / status / destroy / autoscale from the PVE host
ansible.cfg  requirements.yml
zensical.toml  docs/                  this documentation site (Zensical)
renovate.json                         what Renovate updates (see Releases and updates)

inventory/hosts.yml                   localhost + Proxmox host + runner LXC
group_vars/all/
  cluster.yml                         <- the cluster (edit this)
  autoscale.yml                       <- autoscaling settings
  runner.yml                          <- runner LXC
  vault.yml(.example)                 <- secrets (ansible-vault)
  derived.yml                         computed values (generated nodes, slots, ...)

roles/
  tools             download + verify openshift-install and oc
  agent_iso         render install-config / agent-config, Calico, build agent ISO
  proxmox_iso       upload the ISO to Proxmox
  proxmox_vms       create + start the VMs (UEFI, q35, cpu=host, virtio)
  wait_install      wait for bootstrap / install-complete, print access info
  github_runner     install + register the Actions runner in the LXC
  proxmox_redfish   Redfish BMC (sushy-tools + Proxmox driver, gunicorn),
                    DHCP for the slots, serial console recorder
  ocp_autoscale     BareMetalHosts, MachineConfig, ClusterAutoscaler,
                    repair CronJob, (optional) kubemox pool

.github/workflows/
  deploy.yml        manual deploy / destroy / autoscale on the self-hosted runner
  lint.yml          syntax check, ansible-lint, ruff, shellcheck on push / PR
  docs.yml          build and publish this site to GitHub Pages
  release.yml       tag a release + GitHub release (by hand or from auto-release)
  auto-release.yml  release after a merged PR and every Monday
  automerge.yml     merge patch/minor dependency PRs once checks pass
  renovate.yml      run Renovate (dependency update PRs) every 4 hours
```

## State (not in git)

| Path | What |
|---|---|
| `.work/bin/<version>/` | `openshift-install`, `oc`, `helm` |
| `.work/<cluster>/` | kubeconfig, kubeadmin password, install state, rendered configs |
| `.work/*.log` | `ocp.sh` and tmux logs, `autoscale-debug` reports |
| `secrets/` | pull secret, autoscale token |
| `/var/log/proxmox-redfish/` | worker serial console logs (on the Proxmox host) |
| `/etc/proxmox-redfish/` | BMC config, TLS cert, htpasswd, DHCP config |
