# Secrets

Nothing secret is committed in plain text.

| Secret | Where | Used for |
|---|---|---|
| Proxmox API token secret | `group_vars/all/vault.yml` (`proxmox_api_token_secret`) | everything that talks to Proxmox |
| Pull secret | `secrets/pull-secret.json` (gitignored) | OpenShift only, not OKD |
| SSH public key | `ssh_pubkey_file` (`~/.ssh/id_ed25519.pub`) | `core` user on the nodes |
| Redfish BMC password | `vault.yml` (`redfish_bmc_password`), optional | Ironic → proxmox-redfish |
| Autoscale token | `secrets/autoscale.json` (created by `ocp.sh autoscale`) | kubemox + Redfish BMC |
| kubeconfig, kubeadmin password | `.work/<cluster>/` (gitignored) | cluster access |

## vault.yml

```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
```

```yaml
proxmox_api_token_secret: "00000000-0000-0000-0000-000000000000"
# Optional: without it a random password is generated once in the state dir
redfish_bmc_password: "change-me"
```

`ocp.sh` asks for the token secret and pull secret on the first run and
handles the vault for you. Non-interactive: set `PROXMOX_API_TOKEN_SECRET`,
`OCP_PULL_SECRET_FILE` and `ANSIBLE_VAULT_PASSWORD_FILE`.

## A separate token for autoscaling

On the Proxmox host, `./ocp.sh autoscale` creates `ansible@pve!autoscale`
and keeps it in `secrets/autoscale.json`, so your deploy token is never copied
into the cluster. Revoke it any time:

```bash
pveum user token remove ansible@pve autoscale
```

Elsewhere, set `autoscale_proxmox_token_id` / `autoscale_proxmox_token_secret`.

## GitHub Actions

In CI the secrets come from the `proxmox` environment — see
[GitHub Actions](../deploy/github-actions.md#3-secrets). They're written to the
job's temp dir with mode 0600 and removed at the end of every job.
