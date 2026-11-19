# Troubleshooting

## autoscale-debug

One command collects everything about autoscaling. Run it **on the Proxmox
host** (the worker VMs are only reachable from there):

```bash
./ocp.sh autoscale-debug
```

It prints and saves to `.work/autoscale-debug-<time>.txt`:

- MachineSets, autoscalers, Machines (phase, node, errors), BareMetalHosts
  (state, power, consumer, errors), nodes, pending CSRs and pods;
- cluster-autoscaler and machine-controller logs, Metal3 events, repair job;
- `proxmox-redfish` log (without the routine GETs), DHCP log, `qm list`;
- the tail of every worker's **serial console log**;
- **inside every running worker VM** (over SSH as `core`): hostname, network,
  DNS, reachability of `api-int` on 6443 and 22623, `rpm-ostree status`,
  first-boot and kubelet logs, failed units — plus a console screenshot.

## Where a new worker gets stuck

| Symptom | Look at | Usual cause |
|---|---|---|
| Machine stays `Provisioning`, no VM in `qm list` | `journalctl -u proxmox-redfish` | BMC unreachable from the masters (8443, firewall), wrong BMC password |
| Host in *Registration error* / *Inspection error* | `oc get bmh`, repair job | fixed automatically by the repair job after 10 min |
| VM runs, console: `ignition … network is unreachable` | DHCP log, console log | no network on first boot — see [below](#new-worker-has-no-network) |
| Machine `Provisioned`, no CSR, no node | `autoscale-debug` VM section | kubelet can't reach `api-int:6443`, or first boot failed |
| CSRs stay `Pending` | `oc get csr` | approve by hand: `oc adm certificate approve <name>`, then report it |
| Worker removed after 45 min | autoscaler event `DeleteUnregistered` | it never registered; the console log shows why |

## Known problems (all fixed in the code)

### Install never starts: DNS wildcard

`agent wait-for bootstrap-complete` times out after ~1 hour; the log shows
`dns-wildcard-not-configured` on every host.

**Cause:** a wildcard like `*.example.com` at your DNS provider makes
`<anything>.<cluster>.<domain>` resolve. **Fix:** remove it, or make your local
DNS authoritative for `<cluster>.<domain>` with only `api`, `api-int`,
`*.apps` and the nodes. The preflight now catches this in seconds. The running
VMs pick it up by themselves after the fix; reconnect with `./ocp.sh wait`.

### New worker has no network

Console: `ignition[…]: GET https://<api-vip>:22623/config/worker … connect: network is unreachable`, forever.

**Cause:** the static network config for new workers named the NIC `ens18`,
but on q35 VMs the kernel calls it differently (e.g. `enp6s18`). Metal3 copied
that non-matching config into the installed system, which then skipped DHCP.
**Fix:** with `autoscale_dhcp: true` (default) new workers use only DHCP,
answered by `proxmox-redfish-dhcp` with their fixed IP and hostname.

!!! note "Another DHCP server on the network"
    If your router also hands out DHCP on the machine network, it may answer
    first with a different IP. Give the `worker-auto` MACs reservations there
    too, or set `autoscale_dhcp: false`.

### Re-running the playbook powered off a worker

Fixed: hosts that a worker runs on are no longer re-applied (that reset
`spec.online` to `false`).

### `can't lock file '/var/lock/qemu-server/lock-<id>.conf'`

A hard stop waited for a running shutdown task. The BMC now uses
`overrule-shutdown` (Proxmox VE 8.1+).

### `PUT /nodes/<node>/qemu/config` 501

A freshly created VM isn't listed by Proxmox for a few seconds; the BMC now
remembers it locally (this could otherwise create a second VM).

### kubemox cleanup hangs

`oc delete virtualmachine` waited for kubemox's finalizer while the operator
wasn't running. The playbook now removes the finalizer and deletes the VM
through the Proxmox API itself.

## Handy commands

```bash
# oc on the Proxmox host
export PATH=/root/shiftmox/.work/bin/<version>:$PATH
export KUBECONFIG=/root/shiftmox/.work/<cluster>/kubeconfig

# log into a worker (from the Proxmox host)
ssh core@<worker IP>

# watch a worker boot live
qm terminal <vmid>                                 # exit: Ctrl+O
tail -f /var/log/proxmox-redfish/worker-auto-*.log
```
