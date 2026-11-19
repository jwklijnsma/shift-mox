# Autoscaling — day-2 operations

## Scale by hand

=== "Console"

    **Compute › MachineSets › _worker MachineSet_ › ⋮ › Edit Machine count**

=== "CLI"

    ```bash
    oc -n openshift-machine-api get machineset
    oc -n openshift-machine-api scale machineset <worker-machineset> --replicas=4
    ```

Within the MachineAutoscaler's min/max the ClusterAutoscaler may change the
count again later.

## Let the autoscaler do it

The ClusterAutoscaler reacts to **pods that can't be scheduled**, not to CPU
load. To test it, ask for more than your workers have:

```bash
oc create deployment scale-test --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --replicas=10 -- sleep infinity
oc set resources deployment scale-test --requests=cpu=2,memory=2Gi
oc get pods -l app=scale-test            # some stay Pending
oc get machines -n openshift-machine-api -w
```

Delete the deployment and, after `autoscale_scale_down_unneeded_time` (10 min),
the extra workers are removed and their VMs deleted.

## Watch it happen

```bash
oc -n openshift-machine-api get machines,bmh -o wide
oc get csr; oc get nodes
journalctl -u proxmox-redfish -f                 # Redfish calls from Ironic
journalctl -u proxmox-redfish-dhcp -f            # DHCP for new workers
tail -f /var/log/proxmox-redfish/worker-auto-*.log   # serial consoles
qm list | grep worker-auto
```

A slot moves through `available` → `provisioning` → `provisioned`, and the
Machine through `Provisioning` → `Provisioned` → `Running` once the node joins.

## Self-repair

CronJob `autoscale-bmh-repair` runs every 5 minutes. A slot that's been in an
error state (e.g. *Inspection error*) for `autoscale_repair_min_age` (10 min)
and that no worker uses is deleted and registered again from a stored
definition. It may only delete the `worker-auto-*` hosts.

```bash
oc -n openshift-machine-api get cronjob autoscale-bmh-repair
oc -n openshift-machine-api logs job/<latest autoscale-bmh-repair job>
```

Re-running `./ocp.sh autoscale` also repairs broken unused slots.

## Change the limits

Edit `group_vars/all/autoscale.yml` and re-run `./ocp.sh autoscale`.
Raising `autoscale_max_workers` adds slots; lowering it doesn't delete existing
ones (delete the `BareMetalHost` by hand).

## Remove it

`destroy.yml` / `./ocp.sh destroy` also deletes autoscale VMs and leftover
`redfish-vmedia-*.iso` files. To keep the cluster but drop autoscaling: scale
the MachineSet back, delete the `MachineAutoscaler`, `ClusterAutoscaler` and the
`worker-auto-*` BareMetalHosts, and disable the three `proxmox-redfish*`
services.
