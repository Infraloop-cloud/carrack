# SPDX-License-Identifier: Apache-2.0
"""Emulated datacenter

Runs before Metal3 takes over the VMs: power-cycling them later would get in
Ironic's way.
"""

import json
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from conftest import CONFIG, http_get, node_params


def redfish(path=""):
    return json.loads(http_get(f"{CONFIG['redfish']}/{path}"))


def power_state(node):
    return redfish(f"Systems/{node.uuid}")["PowerState"]


def reset(node, kind):
    request = urllib.request.Request(
        f"{CONFIG['redfish']}/Systems/{node.uuid}/Actions/ComputerSystem.Reset",
        data=json.dumps({"ResetType": kind}).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    urllib.request.urlopen(request, timeout=30).close()


def wait_power_state(node, state, timeout=30):
    deadline = time.monotonic() + timeout
    while power_state(node) != state:
        assert time.monotonic() < deadline, f"{node.name} not {state} after {timeout}s"
        time.sleep(1)


def test_redfish():
    """sushy-tools answers Redfish"""
    assert redfish()["RedfishVersion"]


@node_params()
def test_vm_defined(local, node):
    """libvirt has the VM, with its UUID and MAC"""
    domain = ET.fromstring(local.check_output(f"sudo virsh --connect qemu:///system dumpxml {node.name}"))
    assert domain.findtext("uuid") == node.uuid
    macs = [mac.get("address") for mac in domain.iter("mac")]
    assert node.boot_mac in macs


@node_params()
def test_redfish_lists(node):
    """Redfish lists the VM as a system"""
    members = [member["@odata.id"] for member in redfish("Systems")["Members"]]
    assert f"/redfish/v1/Systems/{node.uuid}" in members


@node_params()
def test_power_cycle(node):
    """Redfish powers the VM on and off"""
    assert power_state(node) == "Off"
    reset(node, "On")
    wait_power_state(node, "On")
    reset(node, "ForceOff")
    wait_power_state(node, "Off")


def test_image_served():
    """The image server serves the image under test"""
    served = http_get(f"{CONFIG['image_url']}.sha256").decode()
    assert served == Path(CONFIG["image_checksum_file"]).read_text()
