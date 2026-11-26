# End-to-end tests

`tests/e2e/` deploys real clusters on your Proxmox host, tests them, scales
them and removes them again — every install method with both CNIs:

| Case | Install method | CNI | Scale test |
|---|---|---|---|
| `agent-ovn` | agent | OVN-Kubernetes | MachineSet +1 / −1 |
| `agent-calico` | agent | Calico | MachineSet +1 / −1 |
| `ipi-ovn` | ipi | OVN-Kubernetes | MachineSet +1 / −1 |
| `ipi-calico` | ipi | Calico | MachineSet +1 / −1 |
| `external-ovn` | external | OVN-Kubernetes | skipped: no Machine API on platform External |
| `external-calico` | external | Calico | skipped |

The cases run **one after the other** and reuse the same addresses and VMIDs,
so the lab needs room for one test cluster at a time (default 3 masters +
1 worker + 1 autoscale worker, ~80 GB RAM; ipi adds the 24 GB provisioner).
A full run takes many hours — run single cases while you work on one area.

## Set up

1. Settings — addresses, VMIDs and sizes **outside** every other cluster:

    ```bash
    cp tests/e2e/settings.example.yml tests/e2e/settings.yml
    $EDITOR tests/e2e/settings.yml
    ```

2. DNS — the agent and ipi cases use cluster name `e2e`, the external cases
   `e2e-ext` (their records point at the HAProxy on the Proxmox host):

    | Record | Points to |
    |---|---|
    | `api.e2e.<domain>`, `api-int.e2e.<domain>` | `api_vip` |
    | `*.apps.e2e.<domain>` | `ingress_vip` |
    | `api.e2e-ext.<domain>`, `api-int.e2e-ext.<domain>`, `*.apps.e2e-ext.<domain>` | the Proxmox host's IP on `proxmox_bridge` |

3. The usual one-time setup on the Proxmox host (`./ocp.sh setup`): the e2e
   environments use the main `group_vars/all/vault.yml` and
   `secrets/pull-secret.json`. For ipi also [nested virtualization and the
   *Import* content type](../install/ipi.md#requirements-on-top-of-agent).

## Run

On the Proxmox host, as root:

```bash
./ocp.sh e2e                          # all six cases, in tmux session ocp-e2e
./ocp.sh e2e agent-ovn ipi-calico     # only these
./ocp.sh e2e --keep-failed            # leave a failed cluster for debugging (and stop)
./ocp.sh e2e --keep agent-calico      # keep the cluster (single case only)
./ocp.sh e2e --autoscaler             # scale via the ClusterAutoscaler instead of by hand
./ocp.sh e2e --no-scale               # deploy + verify only
```

The vault password is asked once at the start. For a run without any prompt,
set `ANSIBLE_VAULT_PASSWORD_FILE`.

## What a case does

1. **deploy** — writes `environments/e2e-<case>/cluster.yml` (your settings +
   `install_method`, `cni`, `cluster_name`) and runs `./ocp.sh -E e2e-<case> deploy`,
   preflight included.
2. **verify** (`tests/e2e/verify.sh`)
    - cluster version settled, every cluster operator Available / not Degraded /
      not Progressing, all nodes Ready
    - the CNI: network type, Calico `tigerastatus` + `calico-node`, or OVN `ovnkube-node`
    - a workload: two web pods on two nodes, pod → service, pod → pod across
      nodes, cluster DNS, external DNS, the route over HTTPS from outside
    - **ipi**: every node is a provisioned, powered-on BareMetalHost
    - **external**: platform External, every node has `providerID: proxmox://…`
      and a zone label, no node left with the `uninitialized` taint
    - with `proxmox_csi_enabled: true`: a PVC is bound and written
3. **scale** (`tests/e2e/scale.sh`, agent and ipi) — `./ocp.sh autoscale`, then:
    - the worker MachineSet +1 (or, with `--autoscaler`, pods that only fit on
      one more node): the Redfish BMC creates a VM in a free slot, Metal3
      installs it, the node `worker-auto-N` joins and runs a pod
    - back to the old size, removing exactly that machine: machine and node
      gone, host back to `available`, and the VM deleted again (on demand)
4. **destroy** — `./ocp.sh -E e2e-<case> destroy`, then the test's own BMC
   service, DHCP leases, HAProxy and autoscale token are removed from the host.

A failed phase collects `diagnostics.txt` (cluster operators, nodes,
machines, hosts, failing pods, warning events).

## Results

`.work/e2e/<timestamp>/`:

```text
summary.md          one row per case: deploy / verify / scale / destroy, with times
junit.xml           the same for CI tooling
run.log             everything
<case>/deploy.log   per phase; diagnostics.txt on failure
```
