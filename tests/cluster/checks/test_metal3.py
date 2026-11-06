# SPDX-License-Identifier: Apache-2.0
"""Metal3 on the bootstrap cluster"""

import pytest

from conftest import CONFIG, condition, get, http_get, kubectl, node_params

KUBECONFIG = CONFIG["bootstrap_kubeconfig"]


@pytest.mark.parametrize("kind,name", [
    ("CoreProvider", "cluster-api"),
    ("BootstrapProvider", "kubeadm"),
    ("ControlPlaneProvider", "kubeadm"),
    ("InfrastructureProvider", "metal3"),
    ("IPAMProvider", "metal3"),
], ids=lambda value: value)
def test_provider_installed(kind, name):
    """clusterctl installed the Cluster API provider"""
    providers = get(KUBECONFIG, "providers.clusterctl.cluster.x-k8s.io", "--all-namespaces")["items"]
    assert [p for p in providers if p.get("type") == kind and p.get("providerName") == name]


@pytest.mark.parametrize("namespace", [
    "cert-manager",
    "capi-system",
    "capi-kubeadm-bootstrap-system",
    "capi-kubeadm-control-plane-system",
    "capm3-system",
    "metal3-ipam-system",
    "ironic-standalone-operator-system",
    "baremetal-operator-system",
])
def test_deployments_available(namespace):
    """Every deployment in the namespace is available"""
    kubectl(KUBECONFIG, f"--namespace={namespace}", "wait", "deployment", "--all",
            "--for=condition=Available", "--timeout=30s")


def test_ironic_ready():
    """The Ironic resource is ready"""
    ironic = get(KUBECONFIG, "--namespace=baremetal-operator-system", "ironic/ironic")
    assert condition(ironic, "Ready") == "True"


def test_ironic_api():
    """Ironic's API answers on its published address"""
    assert http_get(CONFIG["ironic_api"])


@node_params()
def test_host_provisioned(node):
    """The BareMetalHost is provisioned, powered on and without errors"""
    host = get(KUBECONFIG, f"--namespace={CONFIG['cluster_namespace']}", f"baremetalhost/{node.name}")
    status = host["status"]
    assert status["provisioning"]["state"] == "provisioned"
    assert status.get("operationalStatus") == "OK"
    assert status.get("poweredOn") is True
    assert not status.get("errorCount"), status.get("errorMessage")
