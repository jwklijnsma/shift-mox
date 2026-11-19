# ocp.sh

`ocp.sh` runs everything from the Proxmox host itself (or inside the runner
LXC: `pct enter 5099`).

## Commands

| Command | Does |
|---|---|
| `./ocp.sh deploy` | full install, ends with the status |
| `./ocp.sh deploy --rebuild` | fresh agent ISO first (after editing `cluster.yml`) |
| `./ocp.sh wait` | re-attach to an install that is running |
| `./ocp.sh status` | nodes, version, unhealthy operators, console URL, kubeadmin password |
| `./ocp.sh destroy` | delete VMs, ISO and state (type the cluster name to confirm) |
| `./ocp.sh autoscale` | set up [worker autoscaling](../autoscaling/setup.md) |
| `./ocp.sh autoscale-debug` | one [debug report](../troubleshooting.md#autoscale-debug) for autoscaling |
| `./ocp.sh setup` | only install tools and prepare secrets |
| `./ocp.sh token` | (re)create the Proxmox API user + token |

## Options

| Option | Effect |
|---|---|
| `--no-tmux` | run in the foreground instead of the tmux session `ocp` |
| `--public-api` | use `proxmox_api_host` from `cluster.yml` instead of `127.0.0.1` |
| `--no-pull` | don't `git pull` first |

## What it does for you

- Installs git, tmux, nmstate and an Ansible venv in `/opt/ansible-venv`.
- Asks once for the pull secret and the Proxmox token secret.
- Creates `~/.ssh/id_ed25519` if needed.
- Runs long operations in tmux (`tmux attach -t ocp`); output is also in
  `.work/ocp-tmux.log`.
- Talks to the Proxmox API over `127.0.0.1`.
- For `autoscale`: finds the host's IP on `proxmox_bridge`, runs the Redfish
  BMC there and creates a dedicated token (see
  [Autoscaling › Set up](../autoscaling/setup.md#on-the-proxmox-host)).

## Using oc on the host

The tools live in the state dir, not on your `PATH`:

```bash
export PATH=/root/shiftmox/.work/bin/<version>:$PATH
export KUBECONFIG=/root/shiftmox/.work/<cluster>/kubeconfig
```

## Updating the code on the host

`ocp.sh` runs `git pull` first. For a private repo, give the host a read-only
deploy key:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/shiftmox_deploy -C "deploy@$(hostname)"
cat ~/.ssh/shiftmox_deploy.pub     # repo › Settings › Deploy keys › Add (leave "write" off)
cat >> ~/.ssh/config <<'CFG'
Host github.com
    IdentityFile ~/.ssh/shiftmox_deploy
    IdentitiesOnly yes
CFG
cd /root/shiftmox && git remote set-url origin git@github.com:jwklijnsma/shift-mox.git
git pull
```

Without credentials `ocp.sh` warns and runs the local code.
