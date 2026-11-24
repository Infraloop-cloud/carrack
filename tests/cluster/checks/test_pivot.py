# SPDX-License-Identifier: Apache-2.0
"""The cluster, managing itself after the pivot"""

import base64
import json
import urllib.request

import pytest

from conftest import CONFIG, condition, get, http_get, kubectl, node_params

BOOTSTRAP = CONFIG["bootstrap_kubeconfig"]
CLUSTER = CONFIG["cluster_kubeconfig"]
NAMESPACE = f"--namespace={CONFIG['cluster_namespace']}"
BMO_NAMESPACE = "--namespace=baremetal-operator-system"


@pytest.fixture(scope="module")
def ironic_auth():
    """The Authorization header for the cluster's Ironic API."""
    ironic = get(CLUSTER, BMO_NAMESPACE, "ironic/ironic")
    secret = get(CLUSTER, BMO_NAMESPACE, f"secret/{ironic['spec']['apiCredentialsName']}")["data"]
    user, password = (base64.b64decode(secret[key]).decode() for key in ("username", "password"))
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def ironic_get(auth, path):
    request = urllib.request.Request(CONFIG["pivot_ironic_api"] + path, headers={
        "Authorization": auth, "X-OpenStack-Ironic-API-Version": "latest"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


@pytest.mark.parametrize("kind,name", [
    ("CoreProvider", "cluster-api"),
    ("BootstrapProvider", "kubeadm"),
    ("ControlPlaneProvider", "kubeadm"),
    ("InfrastructureProvider", "metal3"),
    ("IPAMProvider", "metal3"),
], ids=lambda value: value)
def test_provider_installed(kind, name):
    """clusterctl installed the Cluster API provider in the cluster"""
    providers = get(CLUSTER, "providers.clusterctl.cluster.x-k8s.io", "--all-namespaces")["items"]
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
    """Every deployment in the cluster's namespace is available"""
    kubectl(CLUSTER, f"--namespace={namespace}", "wait", "deployment", "--all",
            "--for=condition=Available", "--timeout=30s")


def test_ironic_ready():
    """The cluster's Ironic resource is ready"""
    assert condition(get(CLUSTER, BMO_NAMESPACE, "ironic/ironic"), "Ready") == "True"


def test_ironic_node():
    """The cluster's Ironic runs on its chosen node"""
    pods = get(CLUSTER, BMO_NAMESPACE, "pods")["items"]
    ironic = [pod for pod in pods if pod["metadata"]["name"].startswith("ironic")]
    assert ironic, [pod["metadata"]["name"] for pod in pods]
    assert {pod["spec"].get("nodeName") for pod in ironic} == {CONFIG["pivot_ironic_host"]}


def test_ironic_api():
    """The cluster's Ironic API answers on its node's address"""
    assert http_get(CONFIG["pivot_ironic_api"])


@node_params()
def test_ironic_adopted(node, ironic_auth):
    """The cluster's Ironic adopted the host: active, not in maintenance"""
    ironic_node = ironic_get(ironic_auth, f"v1/nodes/{CONFIG['cluster_namespace']}~{node.name}")
    assert ironic_node["provision_state"] == "active", ironic_node.get("last_error")
    assert not ironic_node["maintenance"], ironic_node.get("maintenance_reason")


@node_params()
def test_host_provisioned(node):
    """The BareMetalHost is in the cluster: provisioned, powered on, not paused"""
    host = get(CLUSTER, NAMESPACE, f"baremetalhost/{node.name}")
    status = host["status"]
    assert status["provisioning"]["state"] == "provisioned"
    assert status.get("operationalStatus") == "OK"
    assert status.get("poweredOn") is True
    assert not status.get("errorCount"), status.get("errorMessage")
    assert "baremetalhost.metal3.io/paused" not in host["metadata"].get("annotations", {})


def test_cluster_available():
    """Cluster API, in the cluster, reports it available"""
    cluster = get(CLUSTER, NAMESPACE, f"cluster/{CONFIG['cluster_name']}")
    assert condition(cluster, "Available") == "True"
    assert not cluster["spec"].get("paused")


@node_params()
def test_machine_running(node):
    """The node's Machine, in the cluster, is running"""
    machines = get(CLUSTER, NAMESPACE, "machines")["items"]
    phases = {m.get("status", {}).get("nodeRef", {}).get("name"): m["status"].get("phase") for m in machines}
    assert phases.get(node.name) == "Running"


def test_bootstrap_emptied():
    """Nothing of the cluster is left in the bootstrap cluster"""
    left = get(BOOTSTRAP, NAMESPACE, "clusters,machines,baremetalhosts,secrets")["items"]
    # Kubernetes' own, if any.
    left = [item for item in left if item["kind"] != "Secret"
            or item.get("type") != "kubernetes.io/service-account-token"]
    assert not left, [f"{item['kind']}/{item['metadata']['name']}" for item in left]


def test_bootstrap_ironic_deleted():
    """The bootstrap cluster's Ironic is gone"""
    assert not get(BOOTSTRAP, BMO_NAMESPACE, "ironic")["items"]
