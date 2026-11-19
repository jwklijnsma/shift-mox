# Quick start — on the Proxmox host

The simplest way: run everything on the Proxmox host itself. No separate
machine, no GitHub runner.

## 1. Get the code

```bash
ssh root@<proxmox-host>
git clone https://github.com/jwklijnsma/shift-mox /root/shiftmox
cd /root/shiftmox
```

!!! tip "Private repo"
    GitHub doesn't accept account passwords for git. Give the host a read-only
    [deploy key](../deploy/ocp-sh.md#updating-the-code-on-the-host) so
    `ocp.sh` can `git pull` itself.

## 2. Describe your cluster

```bash
$EDITOR group_vars/all/cluster.yml
```

The minimum to change: `cluster_name`, `base_domain`, the network
(`machine_network`, `gateway`, `dns_servers`, `api_vip`, `ingress_vip`,
`ip_start`), and Proxmox (`proxmox_nodes`, `proxmox_bridge`,
`proxmox_disk_storage`). See [cluster.yml](../configuration/cluster.md).

## 3. Deploy

```bash
./ocp.sh deploy
```

The first run:

- installs git, tmux, nmstate and a separate Ansible venv in
  `/opt/ansible-venv` (the hypervisor's own Python stays untouched);
- asks once for the pull secret and the Proxmox token secret
  (`./ocp.sh token` creates the token);
- creates `~/.ssh/id_ed25519` if you don't have one;
- runs the install inside a tmux session `ocp`, so a dropped SSH connection
  doesn't stop it. Logs go to `.work/`.

A full install takes about 1–2 hours. At the end you get:

```bash
./ocp.sh status     # nodes, version, unhealthy operators, console URL, kubeadmin password
```

## 4. Use the cluster

```bash
export PATH=/root/shiftmox/.work/bin/<version>:$PATH
export KUBECONFIG=/root/shiftmox/.work/<cluster>/kubeconfig
oc get nodes
cat .work/<cluster>/kubeadmin-password
```

## 5. Optional: worker autoscaling

```bash
./ocp.sh autoscale
```

Then scale in the console under **Compute › MachineSets › Edit Machine count**,
or let the ClusterAutoscaler do it. See [Autoscaling](../autoscaling/overview.md).
