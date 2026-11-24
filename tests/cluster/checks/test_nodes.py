# SPDX-License-Identifier: Apache-2.0
"""The nodes, over SSH"""

import pytest
import testinfra

from conftest import CONFIG, NODES

KERNEL = CONFIG["kernel"]


@pytest.fixture(scope="module", params=NODES, ids=lambda node: node.name)
def host(request):
    return testinfra.get_host(f"ssh://{request.param.ip}", ssh_config=CONFIG["ssh_config"])


def test_kernel(host):
    """The image's NVIDIA kernel is running"""
    assert host.check_output("uname -r") == KERNEL


def test_kernel_held(host):
    """The NVIDIA kernel's package is installed and held"""
    status = host.check_output("dpkg-query --show --showformat='${Status}' linux-image-%s", KERNEL)
    assert status == "hold ok installed"


def test_nvidia_fs_module(host):
    """The kernel has the nvidia-fs module"""
    if not CONFIG["nvidia_fs"]:
        pytest.skip("image built without nvidia-fs")
    host.run_expect([0], "modinfo --field=filename nvidia-fs")


@pytest.mark.parametrize("service", ["containerd", "kubelet"])
def test_service(host, service):
    """The service is running and enabled"""
    assert host.service(service).is_running
    assert host.service(service).is_enabled


def test_kubelet_version(host):
    """kubelet is the image's version"""
    assert host.check_output("kubelet --version") == f"Kubernetes v{CONFIG['kubernetes_version']}"


def test_cloud_init_done(host):
    """cloud-init finished (kubeadm ran from the config drive)"""
    # Exits 2 for "done" with recoverable errors, such as deprecated keys.
    assert "status: done" in host.run("cloud-init status").stdout


def test_swap_off(host):
    """Swap is off"""
    assert host.check_output("swapon --noheadings") == ""


def test_root_grown(host):
    """The root filesystem grew to the disk"""
    size = int(host.check_output("findmnt --bytes --noheadings --output=SIZE /"))
    assert size > 15 * 2**30, f"{size / 2**30:.1f} GiB"


def test_openvswitch_loaded(host):
    """The kernel's openvswitch module is loaded (Kube-OVN)"""
    assert host.file("/sys/module/openvswitch").is_directory


def test_geneve_tunnel(host):
    """Kube-OVN's Geneve tunnel interface exists"""
    assert host.interface("genev_sys_6081").exists
