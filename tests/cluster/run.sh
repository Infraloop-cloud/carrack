#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Cluster test for a carrack node image: runs the carrack.capm3 collection
# (../../ansible) against emulated bare-metal hosts and checks the result
# with testinfra. See README.md.
#
# Usage: tests/cluster/run.sh <image.qcow2>   (its .sha256 must sit next to it)
#        tests/cluster/run.sh --cleanup        (tear down a KEEP=1 run)
#
# Needs x86_64 Linux with KVM, libvirt (qemu:///system), virt-install, OVMF,
# python3-libvirt, python3-venv, docker usable without sudo, systemd and
# passwordless sudo. KEEP=1 leaves everything running after the test.
# KUBERNETES_VERSION is the version baked into the image (default:
# images/kubernetes-version), DIB_UBUNTU_NVIDIA_KERNEL its kernel and
# DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS whether it has nvidia-fs (default: the
# ubuntu-nvidia-kernel element's). Set GITHUB_TOKEN to avoid GitHub API rate
# limits in clusterctl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
STATE_DIR="${STATE_DIR:-/var/tmp/carrack-cluster}"
VENV="${STATE_DIR}/venv"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-$(< "${REPO_DIR}/images/kubernetes-version")}"
# shellcheck source=SCRIPTDIR/../../images/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash
source "${REPO_DIR}/images/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash"

export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"
export ANSIBLE_COLLECTIONS_PATH="${STATE_DIR}/collections"
export CARRACK_TEST_CONFIG="${STATE_DIR}/test-config.json"

# The Ansible and testinfra environment, pinned by hash. Rebuilt when the
# requirements change.
setup_venv() {
    local stamp="${VENV}/requirements.sha256"
    if ! sha256sum -c --status "${stamp}" 2> /dev/null; then
        mkdir -p "${STATE_DIR}"
        python3 -m venv --clear "${VENV}"
        "${VENV}/bin/pip" install -q --require-hashes --no-deps --only-binary :all: \
            -r "${SCRIPT_DIR}/requirements.txt"
        sha256sum "${SCRIPT_DIR}/requirements.txt" > "${stamp}"
    fi
    export PATH="${VENV}/bin:${PATH}"
    # The collection under test is installed afresh every time.
    (cd "${SCRIPT_DIR}" && ansible-galaxy collection install --force -r requirements.yml -p "${ANSIBLE_COLLECTIONS_PATH}")
}

playbook() {
    ansible-playbook "$@" -e "@${SCRIPT_DIR}/vars.yml" \
        -e "carrack_test_dir=${SCRIPT_DIR}" \
        -e "carrack_test_state_dir=${STATE_DIR}" \
        -e "carrack_test_log_dir=${LOG_DIR}" \
        -e "carrack_test_image=${IMAGE:-/nonexistent.qcow2}" \
        -e "carrack_test_kubernetes_version=${KUBERNETES_VERSION}" \
        -e "carrack_test_kernel=${DIB_UBUNTU_NVIDIA_KERNEL}" \
        -e "carrack_test_nvidia_fs=${DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS}"
}

# checks <name> <test files...>: one results table per call.
checks() {
    local name="$1"
    shift
    (cd "${SCRIPT_DIR}/checks" && pytest --junitxml="${LOG_DIR}/checks-${name}.xml" "$@")
}

on_exit() {
    local rc=$?
    playbook "${SCRIPT_DIR}/logs.yml" > "${LOG_DIR}/logs-playbook.log" 2>&1 || true
    if [ "${KEEP:-0}" = 1 ]; then
        echo "KEEP=1: leaving everything running; clean up with $0 --cleanup"
        echo "Bootstrap cluster: ${STATE_DIR}/capm3/bin/kubectl --kubeconfig ${STATE_DIR}/capm3/bootstrap.kubeconfig"
        echo "Cluster: ${STATE_DIR}/capm3/bin/kubectl --kubeconfig ${STATE_DIR}/capm3/carrack.kubeconfig"
    else
        playbook "${SCRIPT_DIR}/teardown.yml" > "${LOG_DIR}/teardown.log" 2>&1 || echo "teardown failed, see ${LOG_DIR}/teardown.log"
    fi
    if [ "${rc}" -eq 0 ]; then
        echo "Cluster test passed. Logs: ${LOG_DIR}"
    else
        echo "Cluster test FAILED (exit ${rc}). Logs: ${LOG_DIR}"
    fi
    exit "${rc}"
}

mkdir -p "${LOG_DIR}"
case "${1:-}" in
    --cleanup)
        setup_venv
        playbook "${SCRIPT_DIR}/teardown.yml"
        exit 0
        ;;
    "" | -*)
        echo "usage: $0 <image.qcow2> | --cleanup"
        exit 2
        ;;
esac

IMAGE="$(realpath "$1")"
[ -f "${IMAGE}" ] || { echo "image not found: ${IMAGE}"; exit 1; }
[ -f "${IMAGE}.sha256" ] || { echo "missing $(basename "${IMAGE}").sha256 next to the image"; exit 1; }
[[ "${KUBERNETES_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { echo "KUBERNETES_VERSION must look like 1.36.5, got '${KUBERNETES_VERSION}'"; exit 1; }

setup_venv
# Leftovers from an earlier KEEP=1 or interrupted run.
playbook "${SCRIPT_DIR}/teardown.yml" > "${LOG_DIR}/teardown-before.log" 2>&1
trap on_exit EXIT

echo "=== The emulated datacenter"
playbook "${SCRIPT_DIR}/datacenter.yml"
checks datacenter test_datacenter.py

echo "=== carrack.capm3.deploy"
playbook carrack.capm3.deploy

echo "=== Checks"
checks cluster test_bootstrap.py test_metal3.py test_cluster.py test_nodes.py
