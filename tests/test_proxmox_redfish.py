"""Unit tests for the Proxmox Redfish driver, against fake Proxmox APIs.

    pip install sushy-tools==2.2.0 proxmoxer pytest
    pytest tests/
"""

import importlib
import logging
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "roles/proxmox_redfish/files"))


class FakeCluster:
    """Just enough of proxmoxer's chained API for the driver."""

    def __init__(self, name, vms=None):
        self.name = name
        self.vms = {v["vmid"]: dict(v, type="qemu", status="stopped") for v in vms or []}
        tag = abs(hash(name)) % 10000
        self.configs = {vmid: {"name": v["name"],
                               "smbios1": f"uuid=00000000-0000-0000-{tag:04d}-{vmid:012d}"}
                        for vmid, v in self.vms.items()}
        self.calls = []
        self.down = False
        self.next = 9000

    # api.cluster.resources.get / api.cluster.nextid.get
    @property
    def cluster(self):
        fake = self

        class _C:
            class resources:
                @staticmethod
                def get(type=None):
                    if fake.down:
                        raise ConnectionError(f"{fake.name} down")
                    return [dict(v) for v in fake.vms.values()]

            class nextid:
                @staticmethod
                def get():
                    return fake.next
        return _C

    def nodes(self, node):
        return _Node(self, node)


class _Node:
    def __init__(self, c, node):
        self.c, self.node = c, node

    def tasks(self, upid):
        class _T:
            class status:
                @staticmethod
                def get():
                    return {"status": "stopped", "exitstatus": "OK"}
        return _T

    @property
    def qemu(self):
        return _Qemu(self.c, self.node)

    def storage(self, name):
        c = self.c

        class _S:
            @staticmethod
            def content(volid):
                class _D:
                    @staticmethod
                    def delete():
                        c.calls.append(("iso-delete", volid))
                        return "UPID:del"
                return _D

            class upload:
                @staticmethod
                def post(**kw):
                    c.calls.append(("upload", name))
                    return "UPID:up"
        return _S


class _Qemu:
    def __init__(self, c, node):
        self.c, self.node = c, node

    def post(self, vmid, **cfg):
        self.c.calls.append(("create", self.node, vmid, cfg["name"]))
        self.c.vms[vmid] = {"vmid": vmid, "name": cfg["name"], "node": self.node,
                            "type": "qemu", "status": "stopped"}
        self.c.configs[vmid] = dict(cfg)
        return "UPID:create"

    def __call__(self, vmid):
        c = self.c

        class _VM:
            class config:
                @staticmethod
                def get():
                    return dict(c.configs[vmid])

                @staticmethod
                def put(**kw):
                    c.configs[vmid].update(kw)

            class status:
                class current:
                    @staticmethod
                    def get():
                        return {"status": c.vms[vmid]["status"]}

                class start:
                    @staticmethod
                    def post():
                        c.calls.append(("start", vmid))
                        c.vms[vmid]["status"] = "running"
                        return "UPID:start"

        return _VM


@pytest.fixture
def driver_factory(monkeypatch):
    def make(clusters, slots, default="main"):
        mod = importlib.import_module("proxmox_redfish")
        fakes = {}

        def fake_api(host, **kw):
            return fakes[host]

        monkeypatch.setattr(mod, "ProxmoxAPI", fake_api)
        cfg = {
            "SUSHY_PROXMOX_CLUSTERS": {
                n: {"host": n, "token_user": "u@pve", "token_name": "t",
                    "token_secret": "s", "verify_ssl": False, "iso_storage": f"iso-{n}"}
                for n in clusters},
            "SUSHY_PROXMOX_DEFAULT_CLUSTER": default,
            "SUSHY_PROXMOX_NAME_REGEX": r"^(master-\d+|worker-auto-\d+)\.ocp5$",
            "SUSHY_PROXMOX_SLOTS": slots,
        }
        fakes.update(clusters)
        mod.ProxmoxDriver.initialize(cfg, logging.getLogger("test"))
        return mod.ProxmoxDriver(), mod
    return make


SLOT = {"cores": 4, "memory": 8192, "disk_gb": 60, "mac": "52:54:00:00:00:30",
        "storage": "local-lvm", "bridge": "vmbr1", "vlan": ""}


def test_vms_from_all_clusters(driver_factory):
    main = FakeCluster("main", [{"vmid": 100, "name": "master-0.ocp5", "node": "pve1"}])
    site2 = FakeCluster("site2", [{"vmid": 100, "name": "master-1.ocp5", "node": "pve11"},
                                  {"vmid": 101, "name": "homeassistant", "node": "pve11"}])
    drv, _ = driver_factory({"main": main, "site2": site2}, [])
    names = sorted(drv.name(u) for u in drv.systems)
    assert names == ["master-0.ocp5", "master-1.ocp5"]      # regex hides homeassistant
    # same VMID on two clusters: two different systems
    assert drv.uuid("master-0.ocp5") != drv.uuid("master-1.ocp5")


def test_power_on_goes_to_the_right_cluster(driver_factory):
    main = FakeCluster("main", [{"vmid": 100, "name": "master-0.ocp5", "node": "pve1"}])
    site2 = FakeCluster("site2", [{"vmid": 100, "name": "master-1.ocp5", "node": "pve11"}])
    drv, _ = driver_factory({"main": main, "site2": site2}, [])
    drv.set_power_state("master-1.ocp5", "On")
    assert ("start", 100) in site2.calls and ("start", 100) not in main.calls


def test_slot_created_on_its_cluster(driver_factory):
    main = FakeCluster("main")
    site2 = FakeCluster("site2")
    slot = dict(SLOT, name="worker-auto-0", vm_name="worker-auto-0.ocp5",
                pve_cluster="site2", pve_node="pve12")
    drv, mod = driver_factory({"main": main, "site2": site2}, [slot])
    assert drv.get_power_state(mod.slot_uuid("worker-auto-0.ocp5")) == "Off"
    drv.set_power_state("worker-auto-0.ocp5", "On")
    assert ("create", "pve12", 9000, "worker-auto-0.ocp5") in site2.calls
    assert not [c for c in main.calls if c[0] == "create"]
    # the slot's UUID now belongs to the real VM
    assert drv.uuid("worker-auto-0.ocp5") == mod.slot_uuid("worker-auto-0.ocp5")


def test_slot_without_cluster_uses_default(driver_factory):
    main = FakeCluster("main")
    slot = dict(SLOT, name="worker-auto-1", vm_name="worker-auto-1.ocp5", pve_node="pve1")
    drv, _ = driver_factory({"main": main}, [slot])
    drv.set_power_state("worker-auto-1.ocp5", "On")
    assert main.calls[0][0] == "create"


def test_virtual_media_uses_the_clusters_iso_storage(driver_factory, tmp_path):
    site2 = FakeCluster("site2", [{"vmid": 7, "name": "master-1.ocp5", "node": "pve11"}])
    drv, _ = driver_factory({"main": FakeCluster("main"), "site2": site2}, [])
    iso = tmp_path / "boot.iso"
    iso.write_bytes(b"x")
    drv.set_boot_image("master-1.ocp5", "Cd", str(iso))
    assert ("upload", "iso-site2") in site2.calls
    assert site2.configs[7]["ide2"].startswith("iso-site2:iso/redfish-vmedia-7.iso")


def test_unreachable_cluster_keeps_its_vms(driver_factory, monkeypatch):
    main = FakeCluster("main", [{"vmid": 100, "name": "master-0.ocp5", "node": "pve1"}])
    site2 = FakeCluster("site2", [{"vmid": 5, "name": "master-1.ocp5", "node": "pve11"}])
    drv, _ = driver_factory({"main": main, "site2": site2}, [])
    assert len(drv.systems) == 2
    site2.down = True
    drv._invalidate()
    assert sorted(drv.name(u) for u in drv.systems) == ["master-0.ocp5", "master-1.ocp5"]


def test_single_cluster_config_still_works(monkeypatch):
    mod = importlib.import_module("proxmox_redfish")
    main = FakeCluster("main", [{"vmid": 1, "name": "worker-auto-0.ocp5", "node": "pve1"}])
    monkeypatch.setattr(mod, "ProxmoxAPI", lambda host, **kw: main)
    mod.ProxmoxDriver.initialize({
        "SUSHY_PROXMOX_HOST": "10.0.0.1", "SUSHY_PROXMOX_TOKEN_USER": "u@pve",
        "SUSHY_PROXMOX_TOKEN_NAME": "t", "SUSHY_PROXMOX_TOKEN_SECRET": "s",
        "SUSHY_PROXMOX_NAME_REGEX": r"^worker-auto-\d+\.ocp5$",
    }, logging.getLogger("test"))
    drv = mod.ProxmoxDriver()
    assert [drv.name(u) for u in drv.systems] == ["worker-auto-0.ocp5"]
