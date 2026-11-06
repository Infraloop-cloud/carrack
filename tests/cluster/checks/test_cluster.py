# SPDX-License-Identifier: Apache-2.0
"""The cluster"""

import pytest

from conftest import CONFIG, CONTROL_PLANE, WORKERS, condition, curl_pod, get, kubectl, node_params, on_node

BOOTSTRAP = CONFIG["bootstrap_kubeconfig"]
CLUSTER = CONFIG["cluster_kubeconfig"]
NAMESPACE = f"--namespace={CONFIG['cluster_namespace']}"
WORKER = WORKERS[0] if WORKERS else CONTROL_PLANE


def test_cluster_available():
    """Cluster API reports the cluster available"""
    cluster = get(BOOTSTRAP, NAMESPACE, f"cluster/{CONFIG['cluster_name']}")
    assert condition(cluster, "Available") == "True"


@node_params()
def test_machine_running(node):
    """The node's Machine is running"""
    machines = get(BOOTSTRAP, NAMESPACE, "machines")["items"]
    phases = {m.get("status", {}).get("nodeRef", {}).get("name"): m["status"].get("phase") for m in machines}
    assert phases.get(node.name) == "Running"


@node_params()
def test_node_ready(node):
    """The node is Ready"""
    assert condition(get(CLUSTER, f"node/{node.name}"), "Ready") == "True"


@node_params()
def test_node_kubelet(node):
    """The node runs the image's kubelet"""
    info = get(CLUSTER, f"node/{node.name}")["status"]["nodeInfo"]
    assert info["kubeletVersion"] == f"v{CONFIG['kubernetes_version']}"


@node_params()
def test_node_kernel(node):
    """The node runs the image's NVIDIA kernel"""
    info = get(CLUSTER, f"node/{node.name}")["status"]["nodeInfo"]
    assert info["kernelVersion"] == CONFIG["kernel"]


@pytest.mark.parametrize("workload", [
    "deployment/ovn-central",
    "daemonset/ovs-ovn",
    "deployment/kube-ovn-controller",
    "daemonset/kube-ovn-cni",
    "deployment/coredns",
])
def test_rolled_out(workload):
    """The workload is rolled out"""
    kubectl(CLUSTER, "--namespace=kube-system", "rollout", "status", workload, "--timeout=30s")


def test_api_through_service():
    """A pod on a worker reaches the API through its Service, by name"""
    # /readyz is open to anonymous clients.
    curl_pod(CLUSTER, "cluster-api-service", on_node(WORKER),
             "-sSfk", "--retry", "3", "https://kubernetes.default.svc.cluster.local/readyz")


def test_internet_from_worker():
    """A pod on a worker reaches the internet"""
    curl_pod(CLUSTER, "cluster-internet", on_node(WORKER),
             "-sS", "-o", "/dev/null", "-I", "--retry", "3", CONFIG["external_url"])


def test_pods_across_nodes():
    """A pod reaches a pod on another node (Geneve tunnels)"""
    pods = get(CLUSTER, "--namespace=kube-system", "pods", "--selector=k8s-app=kube-dns")["items"]
    target = next(pod for pod in pods if pod["status"].get("podIP"))
    target_node = target["spec"]["nodeName"]
    client = next(node for node in [CONTROL_PLANE, *WORKERS] if node.name != target_node)
    curl_pod(CLUSTER, "cluster-across-nodes", on_node(client),
             "-sSf", "--retry", "3", f"http://{target['status']['podIP']}:8181/ready")
