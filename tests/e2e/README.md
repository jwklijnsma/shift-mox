# End-to-end tests

Deploy, verify, scale and destroy every install method (agent, ipi, external)
with both CNIs (OVN-Kubernetes, Calico) on a real Proxmox host:

```bash
cp tests/e2e/settings.example.yml tests/e2e/settings.yml   # addresses, VMIDs, sizes
./ocp.sh e2e                     # all six cases (hours), or: ./ocp.sh e2e agent-ovn
```

Docs: https://jwklijnsma.github.io/shift-mox/reference/e2e/
