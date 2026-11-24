# Environments

One directory per cluster:

```text
environments/<name>/
  cluster.yml               what differs from group_vars/all/*.yml (committed)
  vault.yml                 Proxmox token secret(s), ansible-vault encrypted (git-ignored)
  secrets/pull-secret.json  Red Hat pull secret (git-ignored)
```

```bash
./ocp.sh env new lab          # copies example/cluster.yml
$EDITOR environments/lab/cluster.yml
./ocp.sh -E lab deploy
```

Docs: https://jwklijnsma.github.io/shift-mox/configuration/environments/
