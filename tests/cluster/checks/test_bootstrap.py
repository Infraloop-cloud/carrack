# SPDX-License-Identifier: Apache-2.0
"""Bootstrap cluster (kind)

Ironic runs with host networking on the kind node and resolves names through
CoreDNS (dnsPolicy ClusterFirstWithHostNet).
"""

import pytest
import testinfra

from conftest import CONFIG, curl_pod

KUBECONFIG = CONFIG["bootstrap_kubeconfig"]


@pytest.fixture(scope="module")
def kind_node():
    return testinfra.get_host(f"docker://{CONFIG['bootstrap_node']}")


def test_no_host_search_domains(kind_node):
    """The kind node has none of the host's DNS search domains"""
    assert not kind_node.file("/etc/resolv.conf").contains("^search ")


@pytest.mark.parametrize("url", [
    pytest.param(f"{CONFIG['redfish']}/", id="Redfish"),
    pytest.param(f"{CONFIG['image_url']}.sha256", id="image server"),
    pytest.param(CONFIG["external_url"], id="internet"),
])
def test_kind_node_reaches(kind_node, url):
    """The kind node reaches the service"""
    kind_node.run_expect([0], "curl -sSf -o /dev/null -I --retry 3 %s", url)


def test_pod_reaches_internet():
    """A pod resolves and reaches the internet"""
    curl_pod(KUBECONFIG, "bootstrap-pod", {"spec": {}}, "-sS", "-o", "/dev/null", "-I", "--retry", "3",
             CONFIG["external_url"])


def test_host_network_pod_reaches_internet():
    """A host-network pod, like Ironic, resolves and reaches the internet"""
    curl_pod(KUBECONFIG, "bootstrap-hostnet",
             {"spec": {"hostNetwork": True, "dnsPolicy": "ClusterFirstWithHostNet"}},
             "-sS", "-o", "/dev/null", "-I", "--retry", "3", CONFIG["external_url"])
