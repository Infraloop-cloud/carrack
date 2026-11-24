# SPDX-License-Identifier: Apache-2.0
"""Shared fixtures and helpers for the cluster test's checks.

The configuration comes from datacenter.yml (CARRACK_TEST_CONFIG, written from
carrack_test_config in vars.yml). Each check's docstring is its description
in the results table, which goes to the GitHub job summary when there is
one.
"""

import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import pytest
import testinfra

CONFIG = json.loads(Path(os.environ["CARRACK_TEST_CONFIG"]).read_text())
NODES = [SimpleNamespace(**node) for node in CONFIG["nodes"]]
CONTROL_PLANE = next(node for node in NODES if node.role == "control-plane")
WORKERS = [node for node in NODES if node.role == "worker"]


def node_params(nodes=None):
    """Parametrize a check over nodes, named after them."""
    return pytest.mark.parametrize("node", NODES if nodes is None else nodes, ids=lambda node: node.name)


@pytest.fixture(scope="session")
def config():
    return CONFIG


@pytest.fixture(scope="session")
def local():
    return testinfra.get_host("local://")


def http_get(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def kubectl(kubeconfig, *args, check=True, timeout=120):
    result = subprocess.run(
        [CONFIG["kubectl"], f"--kubeconfig={kubeconfig}", *args],
        capture_output=True, text=True, timeout=timeout, check=False)
    if check and result.returncode != 0:
        raise AssertionError(f"kubectl {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def get(kubeconfig, *args):
    return json.loads(kubectl(kubeconfig, "get", *args, "--output=json"))


def condition(obj, kind):
    """The status of a resource's condition, or None."""
    for item in obj.get("status", {}).get("conditions", []):
        if item["type"] == kind:
            return item["status"]
    return None


def on_node(node):
    """Pod overrides that put a test pod on a node, past any taints."""
    return {"spec": {"nodeName": node.name, "tolerations": [{"operator": "Exists"}]}}


def run_pod(kubeconfig, name, overrides, *command, image=None, timeout=180):
    """Run a pod to completion and return its output, kept in the log directory."""
    kubectl(kubeconfig, "delete", "pod", name, "--ignore-not-found", "--wait=true")
    kubectl(kubeconfig, "run", name, f"--image={image or CONFIG['curl_image']}", "--restart=Never",
            f"--overrides={json.dumps(overrides)}", "--command", "--", *command)
    try:
        deadline = time.monotonic() + timeout
        phase = ""
        while time.monotonic() < deadline:
            phase = kubectl(kubeconfig, "get", "pod", name, "--output=jsonpath={.status.phase}", check=False)
            if phase in ("Succeeded", "Failed"):
                break
            time.sleep(2)
        logs = kubectl(kubeconfig, "logs", name, check=False)
        Path(CONFIG["log_dir"], f"{name}.log").write_text(logs)
        assert phase == "Succeeded", f"pod {name}: {phase or 'not started'}\n{logs[-2000:]}"
        return logs
    finally:
        kubectl(kubeconfig, "delete", "pod", name, "--wait=false", check=False)


def curl_pod(kubeconfig, name, overrides, *args):
    return run_pod(kubeconfig, name, overrides, "curl", *args)


# --- Results table ------------------------------------------------------------

RESULTS = []
ICONS = {"passed": "✅", "failed": "❌", "skipped": "⏭️"}


def pytest_runtest_logreport(report):
    # A check's result, or why it never ran (a failed or skipped setup).
    if report.when == "call" or (report.when == "setup" and report.outcome != "passed"):
        RESULTS.append(report)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    doc = (item.function.__doc__ or item.name).strip().splitlines()[0]
    module = (item.module.__doc__ or item.module.__name__).strip().splitlines()[0]
    target = item.callspec.id if hasattr(item, "callspec") else ""
    report.carrack = (module, doc, target)


def pytest_sessionfinish(session):
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary or not RESULTS:
        return
    lines = []
    section = None
    for report in RESULTS:
        module, doc, target = report.carrack
        if module != section:
            section = module
            lines += ["", f"### {module}", "", "| | Check | Target | Time |", "|---|---|---|---|"]
        lines.append(f"| {ICONS.get(report.outcome, report.outcome)} | {doc} | {target} | {report.duration:.1f}s |")
    failures = [report for report in RESULTS if report.failed]
    for report in failures:
        module, doc, target = report.carrack
        crash = getattr(report.longrepr, "reprcrash", None)
        message = (crash.message if crash else str(report.longrepr))[:2000]
        lines += ["", f"<details><summary>❌ {doc} {target}</summary>", "", "```", message, "```", "", "</details>"]
    with open(summary, "a", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
