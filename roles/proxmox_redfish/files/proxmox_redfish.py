#!/usr/bin/env python3
"""Redfish BMC emulator for Proxmox VE VMs, with VMs created on demand.

Runs the OpenStack sushy-tools Redfish emulator (sushy-emulator) with a
Proxmox VE system driver, so OpenShift's Metal3 / Ironic can treat Proxmox VMs
as bare-metal hosts with a "redfish-virtualmedia" BMC:

    Ironic ──Redfish──► this emulator ──Proxmox API──► VM power, boot order,
                                                      virtual CD (ISO upload)

On-demand slots (SUSHY_PROXMOX_SLOTS): every autoscale worker is a "slot" with
a fixed name, MAC and size. While no VM exists for a slot, the emulator reports
it as a powered-off machine built from the slot definition. The first request
that changes the machine (power on, boot mode/device, virtual media) creates
the VM in Proxmox. A background reaper deletes the VM again once the matching
BareMetalHost is back to "available" (deprovisioned, not claimed by a Machine,
offline) and the VM has been off for SUSHY_PROXMOX_DELETE_GRACE seconds. If
the OpenShift API can't be asked, nothing is deleted.

Only VMs whose name matches SUSHY_PROXMOX_NAME_REGEX are visible, so the
emulator can't touch the control plane or unrelated VMs.

Several independent Proxmox clusters (SUSHY_PROXMOX_CLUSTERS): every VM is
looked up in all of them, and each slot says on which cluster its VM is
created (slot "pve_cluster"). A cluster that can't be reached keeps its last
known VM list, so its machines don't vanish from Ironic.

Runs under gunicorn (see the systemd unit); the config file comes from
SUSHY_EMULATOR_CONFIG. Config (python file, sushy-tools style):
    SUSHY_PROXMOX_CLUSTERS        dict name -> {host, port, token_user,
                                  token_name, token_secret, verify_ssl,
                                  iso_storage (content "iso", virtual media)}
    SUSHY_PROXMOX_DEFAULT_CLUSTER name used for slots without pve_cluster
    (single cluster, older configs: SUSHY_PROXMOX_HOST, _PORT, _TOKEN_USER,
     _TOKEN_NAME, _TOKEN_SECRET, _VERIFY_SSL, _ISO_STORAGE)
    SUSHY_PROXMOX_NAME_REGEX      which VMs are exposed, e.g. ^worker-auto-\\d+\\.ocp5$
    SUSHY_PROXMOX_SLOTS           list of dicts: name, vm_name, pve_cluster,
                                  pve_node, cores, memory (MB), disk_gb, mac,
                                  storage, bridge, vlan
    SUSHY_PROXMOX_DELETE_GRACE    seconds a released VM must be off (default 300)
    SUSHY_K8S_API                 https://<api>:6443 (for the reaper)
    SUSHY_K8S_TOKEN               token that may list BareMetalHosts
    SUSHY_K8S_NAMESPACE           openshift-machine-api
plus the usual SUSHY_EMULATOR_* settings (listen port, TLS, auth file).
"""

import os
import re
import tempfile
import threading
import time
import uuid as uuidlib

import requests
from proxmoxer import ProxmoxAPI
from sushy_tools import error
from sushy_tools.emulator import main as sushy_main
from sushy_tools.emulator import memoize
from sushy_tools.emulator.resources.systems.base import AbstractSystemsDriver

_DISK_RE = re.compile(r"^(scsi|sata|virtio|ide)\d+$")
_NET_RE = re.compile(r"^net\d+$")
_SIZE_RE = re.compile(r"size=(\d+(?:\.\d+)?)([KMGT]?)")
_UNITS = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
_CACHE_TTL = 5
_REAP_INTERVAL = 60
_CREATED_TTL = 300


def slot_uuid(vm_name):
    """Stable system UUID for a slot; written into the VM's smbios1."""
    return str(uuidlib.uuid5(uuidlib.NAMESPACE_DNS, vm_name))


class ProxmoxDriver(AbstractSystemsDriver):
    """sushy-tools system driver backed by the Proxmox VE API."""

    def __init__(self):
        cfg = self._config
        clusters = cfg.get("SUSHY_PROXMOX_CLUSTERS") or {"main": {
            "host": cfg["SUSHY_PROXMOX_HOST"],
            "port": cfg.get("SUSHY_PROXMOX_PORT", 8006),
            "token_user": cfg["SUSHY_PROXMOX_TOKEN_USER"],
            "token_name": cfg["SUSHY_PROXMOX_TOKEN_NAME"],
            "token_secret": cfg["SUSHY_PROXMOX_TOKEN_SECRET"],
            "verify_ssl": cfg.get("SUSHY_PROXMOX_VERIFY_SSL", True),
            "iso_storage": cfg.get("SUSHY_PROXMOX_ISO_STORAGE", "local"),
        }}
        self._default = cfg.get("SUSHY_PROXMOX_DEFAULT_CLUSTER") or next(iter(clusters))
        self._clusters = {
            name: {
                "api": ProxmoxAPI(
                    c["host"], port=int(c.get("port", 8006)),
                    user=c["token_user"], token_name=c["token_name"],
                    token_value=c["token_secret"],
                    verify_ssl=bool(c.get("verify_ssl", True)), timeout=120),
                "iso_storage": c.get("iso_storage", "local"),
            }
            for name, c in clusters.items()
        }
        self._name_re = re.compile(cfg["SUSHY_PROXMOX_NAME_REGEX"])
        self._slots = {s["vm_name"]: s for s in cfg.get("SUSHY_PROXMOX_SLOTS") or []}
        self._grace = int(cfg.get("SUSHY_PROXMOX_DELETE_GRACE", 300))
        self._k8s_api = cfg.get("SUSHY_K8S_API")
        self._k8s_token = cfg.get("SUSHY_K8S_TOKEN")
        self._k8s_ns = cfg.get("SUSHY_K8S_NAMESPACE", "openshift-machine-api")
        self._lock = threading.Lock()
        self._create_locks = {n: threading.Lock() for n in self._slots}
        self._vms = []
        self._vms_by_cluster = {}
        self._vms_at = 0.0
        self._created = {}
        self._uuids = {}
        self._off_since = {}
        if self._slots and self._k8s_api and self._k8s_token:
            threading.Thread(target=self._reaper, daemon=True,
                             name="proxmox-reaper").start()

    # ------------------------------------------------------------------ helpers
    def _list(self):
        with self._lock:
            if time.time() - self._vms_at > _CACHE_TTL:
                for cname, c in self._clusters.items():
                    try:
                        res = c["api"].cluster.resources.get(type="vm")
                    except Exception as exc:  # noqa: BLE001 - keep last known list
                        self._logger.warning("Proxmox cluster %s unreachable: %s", cname, exc)
                        continue
                    self._vms_by_cluster[cname] = [
                        dict(v, cluster=cname) for v in res
                        if v.get("type") == "qemu" and not v.get("template")
                        and self._name_re.search(v.get("name", ""))
                    ]
                self._vms = [v for vs in self._vms_by_cluster.values() for v in vs]
                self._vms_at = time.time()
            # A VM we just created shows up in cluster/resources only after a
            # few seconds; until then use what we know, so nobody sees the
            # slot as VM-less (and creates a second VM).
            listed = {v["name"] for v in self._vms}
            for name, v in list(self._created.items()):
                if name in listed or time.time() - v["created"] > _CREATED_TTL:
                    self._created.pop(name)
            return list(self._vms) + [dict(v) for v in self._created.values()]

    def _invalidate(self):
        with self._lock:
            self._vms_at = 0.0

    def _virtual(self, slot):
        """A slot without a VM: looks like a powered-off machine."""
        return {"vmid": None, "name": slot["vm_name"], "node": slot["pve_node"],
                "cluster": self._cluster_of_slot(slot), "slot": slot}

    def _cluster_of_slot(self, slot):
        return slot.get("pve_cluster") or self._default

    def _api_of(self, v):
        """Proxmox API of the cluster a VM (or slot) lives on."""
        return self._clusters[v.get("cluster") or self._default]["api"]

    def _iso_storage_of(self, v):
        return self._clusters[v.get("cluster") or self._default]["iso_storage"]

    @staticmethod
    def _key(v):
        return (v.get("cluster"), v["vmid"])

    def _vm(self, identity):
        """Find a VM (or VM-less slot) by UUID, name or VMID."""
        ident = str(identity)
        vms = self._list()
        for v in vms:
            if ident in (v["name"], str(v["vmid"])):
                return v
        for v in vms:
            if self._uuid_of(v) == ident:
                return v
        existing = {v["name"] for v in vms}
        for name, slot in self._slots.items():
            if name not in existing and ident in (name, slot_uuid(name)):
                return self._virtual(slot)
        raise error.NotFound(f"No Proxmox VM matches system {identity}")

    def _qemu(self, v):
        return self._api_of(v).nodes(v["node"]).qemu(v["vmid"])

    def _slot_config(self, slot):
        """What the VM's config will look like once it is created."""
        tag = f",tag={slot['vlan']}" if str(slot.get("vlan") or "") else ""
        return {
            "name": slot["vm_name"],
            "ostype": "l26",
            "machine": "q35",
            "bios": "ovmf",
            "cpu": "host",
            "sockets": 1,
            "cores": int(slot["cores"]),
            "numa": 1,
            "memory": int(slot["memory"]),
            "balloon": 0,
            "scsihw": "virtio-scsi-single",
            "scsi0": f"{slot['storage']}:{int(slot['disk_gb'])},iothread=1,"
                     f"discard=on,ssd=1",
            "efidisk0": f"{slot['storage']}:1,efitype=4m,pre-enrolled-keys=0",
            "net0": f"virtio={slot['mac']},bridge={slot['bridge']}{tag}",
            "ide2": "none,media=cdrom",
            "boot": "order=scsi0;ide2;net0",
            "smbios1": f"uuid={slot_uuid(slot['vm_name'])}",
            "onboot": 0,
            # RHCOS logs its whole boot (ignition, network, firstboot) to
            # ttyS0; proxmox-redfish-console records it on the PVE host.
            "serial0": "socket",
            "tags": "openshift;autoscale;on-demand",
        }

    def _config_of(self, v):
        if v["vmid"] is None:
            cfg = self._slot_config(v["slot"])
            # report the disk as an existing volume with its size
            cfg["scsi0"] = f"{v['slot']['storage']}:new,size={int(v['slot']['disk_gb'])}G"
            return cfg
        return self._qemu(v).config.get()

    def _uuid_of(self, v):
        if v["vmid"] is None:
            return slot_uuid(v["name"])
        key = self._key(v)
        if key not in self._uuids:
            smbios = self._config_of(v).get("smbios1", "")
            m = re.search(r"uuid=([0-9a-fA-F-]{36})", smbios)
            self._uuids[key] = (
                m.group(1).lower() if m else
                str(uuidlib.uuid5(uuidlib.NAMESPACE_URL,
                                  f"proxmox-vm-{v.get('cluster')}-{v['vmid']}")))
        return self._uuids[key]

    def _wait(self, v, upid, timeout=600):
        node = self._api_of(v).nodes(v["node"])
        end = time.time() + timeout
        while time.time() < end:
            st = node.tasks(upid).status.get()
            if st.get("status") == "stopped":
                if st.get("exitstatus") != "OK":
                    raise error.FishyError(
                        f"Proxmox task {upid} failed: {st.get('exitstatus')}")
                return
            time.sleep(1)
        raise error.FishyError(f"Proxmox task {upid} timed out")

    def _ensure(self, identity):
        """Return the VM for identity, creating it first for a VM-less slot."""
        v = self._vm(identity)
        if v["vmid"] is not None:
            return v
        slot = v["slot"]
        with self._create_locks[slot["vm_name"]]:
            self._invalidate()
            v = self._vm(identity)          # someone else may have created it
            if v["vmid"] is not None:
                return v
            cluster = self._cluster_of_slot(slot)
            api = self._clusters[cluster]["api"]
            node = api.nodes(slot["pve_node"])
            vmid = int(api.cluster.nextid.get())
            self._logger.info("Creating VM %s (%s) on %s/%s for slot %s", vmid,
                              slot["vm_name"], cluster, slot["pve_node"], slot["name"])
            upid = node.qemu.post(vmid=vmid, **self._slot_config(slot))
            self._wait({"node": slot["pve_node"], "cluster": cluster}, upid, timeout=900)
            created = {"vmid": vmid, "node": slot["pve_node"], "name": slot["vm_name"],
                       "cluster": cluster, "type": "qemu", "status": "stopped",
                       "created": time.time()}
            with self._lock:
                self._created[slot["vm_name"]] = created
            self._invalidate()
            self._off_since.pop(slot["vm_name"], None)
            return dict(created)

    def _delete_vm(self, v):
        self._logger.info("Deleting released VM %s (%s)", v["vmid"], v["name"])
        self._wait(v, self._qemu(v).delete(purge=1, **{"destroy-unreferenced-disks": 1}))
        iso_storage = self._iso_storage_of(v)
        volid = f"{iso_storage}:iso/{self._iso_name(v)}"
        try:
            self._wait(v, self._api_of(v).nodes(v["node"]).storage(
                iso_storage).content(volid).delete())
        except Exception as exc:  # noqa: BLE001 - usually: no ISO left
            self._logger.debug("No ISO %s to remove: %s", volid, exc)
        self._uuids.pop(self._key(v), None)
        with self._lock:
            self._created.pop(v["name"], None)
        self._invalidate()

    # ------------------------------------------------------------------ reaper
    def _bmhs(self):
        """BareMetalHosts by name, or None when the API can't be asked."""
        url = (f"{self._k8s_api}/apis/metal3.io/v1alpha1/namespaces/"
               f"{self._k8s_ns}/baremetalhosts")
        try:
            items = self._k8s_get(url).get("items", [])
            return {b["metadata"]["name"]: b for b in items}
        except Exception as exc:  # noqa: BLE001
            self._logger.warning("Reaper: can't list BareMetalHosts (%s); "
                                 "not deleting anything", exc)
            return None

    def _k8s_get(self, url):
        # The API is addressed by its VIP, which isn't in the serving cert.
        r = requests.get(url, timeout=20, verify=False,
                         headers={"Authorization": f"Bearer {self._k8s_token}"})
        r.raise_for_status()
        return r.json()

    @staticmethod
    def _released(bmh):
        st = (bmh.get("status") or {}).get("provisioning") or {}
        spec = bmh.get("spec") or {}
        return (st.get("state") in ("available", "ready")
                and not spec.get("consumerRef")
                and not spec.get("online", False))

    def reap_once(self, now=None):
        """Delete VMs whose BareMetalHost has been released. Returns names."""
        now = now if now is not None else time.time()
        self._invalidate()
        vms = [v for v in self._list() if v["name"] in self._slots]
        if not vms:
            self._off_since.clear()
            return []
        bmhs = self._bmhs()
        if bmhs is None:
            return []
        deleted = []
        for v in vms:
            slot = self._slots[v["name"]]
            bmh = bmhs.get(slot["name"])
            if v.get("status") != "stopped" or bmh is None or not self._released(bmh):
                self._off_since.pop(v["name"], None)
                continue
            since = self._off_since.setdefault(v["name"], now)
            if now - since >= self._grace:
                with self._create_locks[v["name"]]:
                    self._delete_vm(v)
                self._off_since.pop(v["name"], None)
                deleted.append(v["name"])
        return deleted

    def _reaper(self):
        while True:
            time.sleep(_REAP_INTERVAL)
            try:
                self.reap_once()
            except Exception:  # keep the thread alive
                self._logger.exception("Reaper run failed")

    def _hard_stop(self, status):
        """qm stop that aborts a running shutdown task instead of waiting
        for its lock (overrule-shutdown, Proxmox VE 8.1+)."""
        try:
            return status.stop.post(**{"overrule-shutdown": 1})
        except Exception as exc:  # older PVE: unknown parameter
            if "overrule-shutdown" not in str(exc):
                raise
            return status.stop.post()

    def _disks(self, cfg):
        return [k for k in sorted(cfg) if _DISK_RE.match(k)
                and "media=cdrom" not in str(cfg[k])]

    @staticmethod
    def _iso_name(v):
        return f"redfish-vmedia-{v['vmid']}.iso"

    # ---------------------------------------------------- AbstractSystemsDriver
    @property
    def driver(self):
        return "<proxmox>"

    @property
    def systems(self):
        vms = self._list()
        existing = {v["name"] for v in vms}
        return ([self._uuid_of(v) for v in vms]
                + [slot_uuid(n) for n in self._slots if n not in existing])

    def uuid(self, identity):
        return self._uuid_of(self._vm(identity))

    def name(self, identity):
        return self._vm(identity)["name"]

    def get_power_state(self, identity):
        v = self._vm(identity)
        if v["vmid"] is None:
            return "Off"
        st = self._qemu(v).status.current.get()
        return "On" if st.get("status") == "running" else "Off"

    def set_power_state(self, identity, state):
        v = self._vm(identity)
        if v["vmid"] is None:
            if state in ("ForceOff", "GracefulShutdown", "Nmi"):
                return                      # nothing there to switch off
            v = self._ensure(identity)
        status = self._qemu(v).status
        running = self.get_power_state(identity) == "On"
        if state in ("On", "ForceOn"):
            if not running:
                self._wait(v, status.start.post())
        elif state == "ForceOff":
            if running:
                self._wait(v, self._hard_stop(status))
        elif state == "GracefulShutdown":
            if running:
                # Ironic falls back to ForceOff itself; keep the shutdown task
                # (and its VM lock) short.
                status.shutdown.post(timeout=120)
        elif state == "GracefulRestart":
            if running:
                status.reboot.post()
            else:
                self._wait(v, status.start.post())
        elif state == "ForceRestart":
            if running:
                self._wait(v, status.reset.post())
            else:
                self._wait(v, status.start.post())
        elif state == "PushPowerButton":
            self._wait(v, (status.shutdown if running else status.start).post())
        else:
            raise error.NotSupportedError(f"Power state {state} not supported")
        self._off_since.pop(v["name"], None)
        self._invalidate()

    def get_boot_device(self, identity):
        cfg = self._config_of(self._vm(identity))
        m = re.search(r"order=([^,\s]+)", cfg.get("boot", ""))
        first = m.group(1).split(";")[0] if m else ""
        if first.startswith("net"):
            return "Pxe"
        if first and "media=cdrom" in str(cfg.get(first, "")):
            return "Cd"
        return "Hdd"

    def set_boot_device(self, identity, boot_source):
        v = self._ensure(identity)
        cfg = self._config_of(v)
        disks = self._disks(cfg)
        cds = [k for k in sorted(cfg) if _DISK_RE.match(k)
               and "media=cdrom" in str(cfg[k])]
        nets = [k for k in sorted(cfg) if _NET_RE.match(k)]
        groups = {"Hdd": disks, "Cd": cds, "Pxe": nets}
        if boot_source not in groups:
            raise error.NotSupportedError(f"Boot device {boot_source}")
        order = groups[boot_source] + [d for k in ("Hdd", "Cd", "Pxe")
                                       if k != boot_source for d in groups[k]]
        self._qemu(v).config.put(boot="order=" + ";".join(order))

    def get_boot_mode(self, identity):
        cfg = self._config_of(self._vm(identity))
        return "UEFI" if cfg.get("bios") == "ovmf" else "Legacy"

    def set_boot_mode(self, identity, boot_mode):
        want = {"UEFI": "ovmf", "Legacy": "seabios"}.get(boot_mode)
        if not want:
            raise error.BadRequest(f"Unknown boot mode {boot_mode}")
        v = self._vm(identity)
        if v["vmid"] is None and want == "ovmf":
            return                          # created as UEFI anyway
        v = self._ensure(identity)
        if self._config_of(v).get("bios", "seabios") != want:
            self._qemu(v).config.put(bios=want)

    def get_secure_boot(self, identity):
        return False

    def set_secure_boot(self, identity, secure):
        if secure:
            raise error.NotSupportedError("Secure boot is not supported")

    def get_total_memory(self, identity):
        mb = int(self._config_of(self._vm(identity)).get("memory", 512))
        return max(1, mb // 1024)

    def get_total_cpus(self, identity):
        cfg = self._config_of(self._vm(identity))
        return int(cfg.get("cores", 1)) * int(cfg.get("sockets", 1))

    def get_processors(self, identity):
        cfg = self._config_of(self._vm(identity))
        return [{
            "id": f"CPU{i}", "socket": f"CPU {i}",
            "model": cfg.get("cpu", "kvm64").split(",")[0],
            "vendor": "QEMU", "cores": str(cfg.get("cores", 1)),
            "threads": str(cfg.get("cores", 1)),
        } for i in range(int(cfg.get("sockets", 1)))]

    def get_nics(self, identity):
        cfg = self._config_of(self._vm(identity))
        nics = []
        for k in sorted(cfg):
            if _NET_RE.match(k):
                m = re.search(r"=([0-9A-Fa-f:]{17})", cfg[k])
                if m:
                    nics.append({"id": m.group(1).lower(),
                                 "mac": m.group(1).lower()})
        return nics

    def get_simple_storage_collection(self, identity):
        cfg = self._config_of(self._vm(identity))
        out = {}
        for k in self._disks(cfg):
            m = _SIZE_RE.search(str(cfg[k]))
            size = int(float(m.group(1)) * _UNITS[m.group(2)]) if m else 0
            bus = re.sub(r"\d+$", "", k)
            ctl = out.setdefault(bus, {"Id": bus, "Name": bus,
                                       "DeviceList": []})
            ctl["DeviceList"].append({"Name": k, "CapacityBytes": size})
        return out

    def get_boot_image(self, identity, device):
        if device != "Cd":
            return None, False, False
        cfg = self._config_of(self._vm(identity))
        ide2 = str(cfg.get("ide2", ""))
        inserted = bool(ide2) and not ide2.startswith("none")
        return (ide2.split(",")[0] if inserted else None), True, inserted

    def set_boot_image(self, identity, device, boot_image=None,
                       write_protected=True):
        if device != "Cd":
            raise error.NotSupportedError(f"Virtual media {device}")
        if boot_image is None and self._vm(identity)["vmid"] is None:
            return                          # eject on a VM that isn't there
        v = self._ensure(identity)
        iso_storage = self._iso_storage_of(v)
        storage = self._api_of(v).nodes(v["node"]).storage(iso_storage)
        iso = self._iso_name(v)
        volid = f"{iso_storage}:iso/{iso}"
        qemu = self._qemu(v)

        # Always detach first - Proxmox refuses to delete an ISO in use.
        qemu.config.put(ide2="none,media=cdrom")
        try:
            self._wait(v, storage.content(volid).delete())
        except Exception as exc:  # noqa: BLE001 - usually: not there yet
            self._logger.debug("No old ISO %s to remove: %s", volid, exc)

        if boot_image:
            self._logger.info("Uploading %s to %s for VM %s", boot_image,
                              volid, v["vmid"])
            # proxmoxer takes the multipart file name from the open file's
            # path, and Proxmox wants it to end in .iso: upload via a symlink.
            with tempfile.TemporaryDirectory() as tmp:
                link = os.path.join(tmp, iso)
                os.symlink(os.path.abspath(boot_image), link)
                with open(link, "rb") as fh:
                    upid = storage.upload.post(content="iso", filename=fh)
            self._wait(v, upid, timeout=1800)
            qemu.config.put(ide2=f"{volid},media=cdrom")


def _systems(self):
    ProxmoxDriver.initialize(self.config, self.logger)
    return ProxmoxDriver()


# Swap the libvirt/OpenStack backend selection for the Proxmox driver.
sushy_main.Application.systems = property(memoize.memoize()(_systems))

# WSGI entry point. Run with ONE worker process (threads are fine): the VM
# cache, the just-created-VM list and the reaper thread live in-process.
#   SUSHY_EMULATOR_CONFIG=/etc/proxmox-redfish/emulator.conf \
#   gunicorn --workers 1 --threads 8 --certfile ... --keyfile ... proxmox_redfish:app
app = sushy_main.app


if __name__ == "__main__":
    sushy_main.main()        # Flask development server, for manual testing only
