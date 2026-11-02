#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Cluster test for a carrack node image: provisions the image onto emulated
# bare-metal nodes with Metal3/CAPI and checks the resulting cluster.
#
# Stages:
#   Stage 1 — infrastructure: libvirt network, two empty UEFI VMs (a
#             control-plane node and a worker), sushy-tools (Redfish
#             emulator) and an HTTP server for the image.
#   Stage 2 — management cluster: a kind cluster (where Metal3 runs)
#             that can reach Redfish and the image server.
#   Stage 3 — Metal3: Cluster API with CAPM3 and IPAM (clusterctl), Ironic
#             (ironic-standalone-operator) and the Bare Metal Operator; the
#             VMs are enrolled as BareMetalHosts and inspected until available.
#   Stage 4 — provisioning: a CAPI cluster (metal3/cluster.yaml) with one
#             control-plane and one worker Machine, which CAPM3 provisions
#             onto the hosts with the image; kubeadm initialises the control
#             plane, the worker joins, and both nodes register with the
#             image's kubelet.
#   Stage 5 — cluster checks: Kube-OVN as the CNI, both nodes Ready on the
#             image's NVIDIA kernel, a pod on the worker reaching the API
#             through cluster DNS and Services and the internet, pods
#             reaching each other across nodes, and CAPI reporting the
#             cluster available.
#
# Usage: tests/cluster/run.sh <image.qcow2>   (its .sha256 must sit next to it)
#        tests/cluster/run.sh --cleanup        (tear down a KEEP=1 run)
#
# Needs x86_64 Linux with KVM, libvirt (qemu:///system), virt-install, OVMF,
# python3-libvirt, python3-venv, git, docker usable without sudo and
# passwordless sudo. kind, kubectl, clusterctl and helm are downloaded (pinned,
# checksum-verified) into STATE_DIR. Set GITHUB_TOKEN to avoid GitHub API rate
# limits in clusterctl. KEEP=1 leaves everything running after the test for
# debugging. KUBERNETES_VERSION is the version baked into the image (default:
# images/kubernetes-version), DIB_UBUNTU_NVIDIA_KERNEL its kernel (default:
# the ubuntu-nvidia-kernel element's).
#
# Many functions are only called through check, retry or try:
# shellcheck disable=SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$(cd "${SCRIPT_DIR}/../../images" && pwd)"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
STATE_DIR="${STATE_DIR:-/var/tmp/carrack-cluster}"

# Provisioning network. HOST_IP is the host's address on it, where the
# Redfish emulator, the image server and (published from kind) Ironic listen.
NET_NAME=carrack-prov
BRIDGE=carrackprov0
SUBNET=192.168.150.0/24
HOST_IP=192.168.150.1

# The emulated bare-metal hosts: one control-plane node, one worker. Their
# addresses are fixed DHCP leases (render_network); the control-plane node's
# address is the workload cluster's API endpoint. metal3/cluster.yaml picks
# hosts for each role by HOST_ROLE_LABEL.
CP_NODE=carrack-cp-0
WORKER_NODE=carrack-worker-0
NODES=("${CP_NODE}" "${WORKER_NODE}")
HOST_ROLE_LABEL=carrack.infraloop.cloud/role
declare -A NODE_ROLE=(["${CP_NODE}"]=control-plane ["${WORKER_NODE}"]=worker)
declare -A NODE_MAC=(["${CP_NODE}"]=52:54:00:ca:7a:20 ["${WORKER_NODE}"]=52:54:00:ca:7a:21)
declare -A NODE_IP=(["${CP_NODE}"]=192.168.150.20 ["${WORKER_NODE}"]=192.168.150.21)
# The control plane plus Kube-OVN's central components request about 2 CPUs.
declare -A NODE_VCPUS=(["${CP_NODE}"]=4 ["${WORKER_NODE}"]=2)
declare -A NODE_UUID=() # libvirt domain UUIDs, also the Redfish system IDs
CP_IP=${NODE_IP[${CP_NODE}]}
# The Ironic agent runs from RAM and downloads the qcow2 (about 1.1 GB) into
# its in-memory /tmp before writing it to disk: 4 GiB runs out of space
# there. Two 6 GiB VMs and kind fit the 16 GB runner because the hosts are
# provisioned one after the other.
NODE_MEMORY_MB=6144
VMEDIA_POOL=carrack-vmedia # also in sushy.conf
VMEDIA_POOL_DIR=/var/lib/libvirt/images/${VMEDIA_POOL}
SUSHY_VERSION=2.2.0
SUSHY_PORT=8000
HTTP_PORT=8080
REDFISH="http://${HOST_IP}:${SUSHY_PORT}/redfish/v1"

# Management cluster. Kubernetes 1.36 matches the node image's version.
KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
KUBECTL_VERSION=v1.36.4
KUBECTL_SHA256=8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a
KIND_CLUSTER=carrack-mgmt
KIND_NODE=${KIND_CLUSTER}-control-plane
CURL_IMAGE=quay.io/curl/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
# Ironic downloads its agent ramdisk from here, with this image, as UID/GID
# 997/994.
EXTERNAL_URL=https://tarballs.opendev.org/
CURL_EXTERNAL=(-sS -o /dev/null -I --retry 3 "${EXTERNAL_URL}") # curl_pod arguments
IPA_DOWNLOADER_IMAGE=quay.io/metal3-io/ironic-ipa-downloader:main_2026-10-07_72b868f7b2c6c4e4bcbf264c5876482acfe6a198@sha256:1531525f893a92b550097a8d8080f47ca0476d980720594114c28ca5da0ca547
BIN_DIR=${STATE_DIR}/bin
KUBECONFIG_FILE=${STATE_DIR}/kubeconfig

# Metal3. CAPI 1.14 (contract v1beta2) supports management clusters 1.33-1.37.
CAPI_VERSION=v1.14.3
CLUSTERCTL_SHA256=e56f397f55c6fdde6ee8c0fead4fb21270a50e05111180bf68c8ae6c82dfd917
CAPM3_VERSION=v1.14.2
IPAM_VERSION=v1.14.2
IRSO_VERSION=v0.12.0
IRSO_MANIFEST_SHA256=c3c60c4d1cd37ba8d8f0874ffb520d4a64b17f57923b16d578b8399c3d28c67c
IRONIC_VERSION=39.0
BMO_NAMESPACE=baremetal-operator-system # also in metal3/bmo
# Ironic runs with host networking on the kind node; kind publishes its API
# and image server on HOST_IP (render_kind_config), which Ironic advertises
# (render_ironic).
IRONIC_API_PORT=6385
IRONIC_HTTP_PORT=6180
IRONIC_API="http://${HOST_IP}:${IRONIC_API_PORT}"
BMH_NAMESPACE=carrack

# Workload cluster (stage 4), in the BareMetalHosts' namespace.
CLUSTER_NAME=carrack
KUBERNETES_VERSION="${KUBERNETES_VERSION:-$(< "${IMAGES_DIR}/kubernetes-version")}"
WORKLOAD_KUBECONFIG=${STATE_DIR}/workload.kubeconfig
# shellcheck source=SCRIPTDIR/../../images/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash
NODE_KERNEL="$(source "${IMAGES_DIR}/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash" &&
    echo "${DIB_UBUNTU_NVIDIA_KERNEL}")"

# Cluster checks (stage 5). carrack clusters use Kube-OVN, installed with its
# v2 Helm chart; the chart's default pod and service networks are the
# cluster's (metal3/cluster.yaml), and it runs OVN central on nodes labelled
# kube-ovn/role=master (set by kubelet, also there).
HELM_VERSION=v4.3.1
HELM_SHA256=0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
KUBE_OVN_VERSION=v1.16.17
KUBE_OVN_CHART=oci://ghcr.io/kubeovn/charts/kube-ovn-v2
KUBE_OVN_CHART_SHA256=e1e4b7f6df3310225e6e0572e673c33d76581253b0d064e10c6b5b54ef1aefa7

VIRSH=(sudo virsh --connect qemu:///system)
KIND=("${BIN_DIR}/kind")
KUBECTL=("${BIN_DIR}/kubectl" --kubeconfig "${KUBECONFIG_FILE}")
KUBECTL_WORKLOAD=("${BIN_DIR}/kubectl" --kubeconfig "${WORKLOAD_KUBECONFIG}")
# clusterctl and helm keep their config and caches in STATE_DIR, not the
# user's home.
CLUSTERCTL=(env "XDG_CONFIG_HOME=${STATE_DIR}/config" "${BIN_DIR}/clusterctl")
HELM=(env "HELM_CONFIG_HOME=${STATE_DIR}/helm/config" "HELM_CACHE_HOME=${STATE_DIR}/helm/cache"
    "HELM_DATA_HOME=${STATE_DIR}/helm/data" "${BIN_DIR}/helm" --kubeconfig "${WORKLOAD_KUBECONFIG}")

# --- Helpers ----------------------------------------------------------------

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; }

# check <description> <command...>: run a check, report it, stop the test on failure.
check() {
    local description="$1"
    shift
    if "$@"; then
        pass "${description}"
    else
        fail "${description}"
        exit 1
    fi
}

# retry <attempts> <delay seconds> <command...>
retry() {
    local attempts="$1" delay="$2"
    shift 2
    local i
    for ((i = 1; i <= attempts; i++)); do
        "$@" && return 0
        sleep "${delay}"
    done
    return 1
}

# try <command...>: run a cleanup step, ignoring its output and failure.
try() {
    "$@" > /dev/null 2>&1 || true
}

# sha256_ok <file> <sha256>
sha256_ok() {
    [ -f "$1" ] && echo "$2  $1" | sha256sum -c --status - 2> /dev/null
}

# fetch <dest> <url> <sha256>: download a pinned file, reusing an earlier
# download when its checksum still matches.
fetch() {
    local dest="$1" url="$2" sha256="$3"
    if sha256_ok "${dest}" "${sha256}"; then
        return 0
    fi
    mkdir -p "$(dirname "${dest}")"
    curl -sfL --retry 3 -o "${dest}.tmp" "${url}"
    if ! sha256_ok "${dest}.tmp" "${sha256}"; then
        rm -f "${dest}.tmp"
        echo "checksum mismatch for ${url}"
        exit 1
    fi
    mv "${dest}.tmp" "${dest}"
}

# install_tool <name> <url> <sha256>: a pinned binary in BIN_DIR.
install_tool() {
    fetch "${BIN_DIR}/$1" "$2" "$3"
    chmod +x "${BIN_DIR}/$1"
}

kubectl_quiet() {
    "${KUBECTL[@]}" "$@" > /dev/null
}

workload_quiet() {
    "${KUBECTL_WORKLOAD[@]}" "$@" > /dev/null
}

# pod_succeeds <kubeconfig> <pod name> <image> <pod spec overrides JSON>
# [command...]: run a pod to completion in that cluster, keeping its output in
# LOG_DIR.
pod_succeeds() {
    local kubectl=("${BIN_DIR}/kubectl" --kubeconfig "$1")
    local name="$2" image="$3" overrides="$4" rc=0
    shift 4
    local run=(run "${name}" --image="${image}" --restart=Never --overrides="${overrides}")
    if [ "$#" -gt 0 ]; then
        run+=(--command -- "$@")
    fi
    "${kubectl[@]}" "${run[@]}" > /dev/null
    if ! "${kubectl[@]}" wait "pod/${name}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s > /dev/null; then
        rc=1
    fi
    "${kubectl[@]}" logs "${name}" > "${LOG_DIR}/${name}.log" 2>&1 || true
    try "${kubectl[@]}" delete pod "${name}" --wait=false
    return "${rc}"
}

# curl_pod <kubeconfig> <pod name> <pod spec overrides JSON> <curl args...>:
# pod_succeeds with curl.
curl_pod() {
    local kubeconfig="$1" name="$2" overrides="$3"
    shift 3
    pod_succeeds "${kubeconfig}" "${name}" "${CURL_IMAGE}" "${overrides}" curl "$@"
}

node_disk() {
    echo "/var/lib/libvirt/images/$1.qcow2"
}

node_serial_log() {
    echo "/var/log/libvirt/qemu/$1-serial.log"
}

# Free space where the test writes (the VMs' disks grow as Ironic writes the
# image) and what takes it.
disk_usage() {
    df -h / /var/lib/libvirt/images "${STATE_DIR}" "${LOG_DIR}" 2> /dev/null | awk 'NR == 1 || !seen[$0]++'
    sudo du -sh /var/lib/libvirt/images /var/lib/docker "${STATE_DIR}" 2> /dev/null || true
}

# --- Setup, teardown and logs -----------------------------------------------

preflight() {
    local cmd
    for cmd in virsh virt-install qemu-img iptables curl python3 docker sha256sum git; do
        command -v "${cmd}" > /dev/null || { echo "missing command: ${cmd}"; exit 1; }
    done
    [ "$(uname -m)" = x86_64 ] || { echo "x86_64 only (OVMF, kind and kubectl are pinned for amd64)"; exit 1; }
    docker info > /dev/null 2>&1 || { echo "docker is not usable by $(id -un) without sudo"; exit 1; }
    [ -e /dev/kvm ] || { echo "/dev/kvm not found: KVM is required"; exit 1; }
    [[ "${KUBERNETES_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        { echo "KUBERNETES_VERSION must look like 1.36.5, got '${KUBERNETES_VERSION}'"; exit 1; }
    [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "OVMF (ovmf package) not installed"; exit 1; }
    python3 -c 'import libvirt' 2> /dev/null || { echo "python3-libvirt not installed"; exit 1; }
}

# Forwarding and NAT for the provisioning network. libvirt adds none
# (forward mode='open'), and docker sets the FORWARD policy to DROP, so the
# bridge needs explicit accepts — in DOCKER-USER when docker is running.
iptables_rules() {
    local action="$1" chain=FORWARD
    if sudo iptables -n -L DOCKER-USER > /dev/null 2>&1; then
        chain=DOCKER-USER
    fi
    local rules=(
        "-t nat POSTROUTING -s ${SUBNET} ! -d ${SUBNET} -j MASQUERADE"
        "-t filter ${chain} -i ${BRIDGE} -j ACCEPT"
        "-t filter ${chain} -o ${BRIDGE} -j ACCEPT"
    )
    local rule table rest
    for rule in "${rules[@]}"; do
        # shellcheck disable=SC2086 # rule is split into iptables arguments
        set -- ${rule}
        table=("$1" "$2")
        shift 2
        rest=("$@")
        if [ "${action}" = add ]; then
            sudo iptables "${table[@]}" -C "${rest[@]}" 2> /dev/null ||
                sudo iptables "${table[@]}" -I "${rest[@]}"
        else
            while sudo iptables "${table[@]}" -C "${rest[@]}" 2> /dev/null; do
                sudo iptables "${table[@]}" -D "${rest[@]}"
            done
        fi
    done
}

stop_pidfile() {
    local pidfile="${STATE_DIR}/$1.pid"
    if [ -f "${pidfile}" ]; then
        sudo kill "$(cat "${pidfile}")" 2> /dev/null || true
        rm -f "${pidfile}"
    fi
}

kind_cluster_exists() {
    [ -x "${BIN_DIR}/kind" ] && "${KIND[@]}" get clusters 2> /dev/null | grep -qx "${KIND_CLUSTER}"
}

teardown() {
    if kind_cluster_exists; then
        try "${KIND[@]}" delete cluster --name "${KIND_CLUSTER}"
    fi
    rm -f "${KUBECONFIG_FILE}" "${WORKLOAD_KUBECONFIG}"
    stop_pidfile sushy
    stop_pidfile http
    local node
    for node in "${NODES[@]}"; do
        try "${VIRSH[@]}" destroy "${node}"
        try "${VIRSH[@]}" undefine "${node}" --nvram
        sudo rm -f "$(node_disk "${node}")" "$(node_serial_log "${node}")"
    done
    try "${VIRSH[@]}" pool-destroy "${VMEDIA_POOL}"
    try "${VIRSH[@]}" pool-undefine "${VMEDIA_POOL}"
    sudo rm -rf "${VMEDIA_POOL_DIR}"
    try "${VIRSH[@]}" net-destroy "${NET_NAME}"
    try "${VIRSH[@]}" net-undefine "${NET_NAME}"
    iptables_rules del
}

collect_logs() {
    mkdir -p "${LOG_DIR}"
    # First and also on the console: with a full disk, the files below come
    # out empty.
    disk_usage | tee "${LOG_DIR}/disk.txt" || true
    local node
    for node in "${NODES[@]}"; do
        "${VIRSH[@]}" dumpxml "${node}" > "${LOG_DIR}/${node}.xml" 2>&1 || true
        # shellcheck disable=SC2024 # root to read, written as the invoking user
        sudo cat "$(node_serial_log "${node}")" > "${LOG_DIR}/${node}-serial.log" 2>&1 || true
    done
    "${VIRSH[@]}" net-dumpxml "${NET_NAME}" > "${LOG_DIR}/${NET_NAME}.xml" 2>&1 || true
    if kind_cluster_exists; then
        "${KUBECTL[@]}" get nodes,pods -A -o wide > "${LOG_DIR}/kubectl-get.txt" 2>&1 || true
        "${KUBECTL[@]}" get ironic,baremetalhosts -A -o yaml > "${LOG_DIR}/metal3.yaml" 2>&1 || true
        "${KUBECTL[@]}" -n "${BMO_NAMESPACE}" get pods -o yaml > "${LOG_DIR}/metal3-pods.yaml" 2>&1 || true
        "${KUBECTL[@]}" get clusters,kubeadmcontrolplanes,machinedeployments,machines,metal3clusters,metal3machines -A -o yaml \
            > "${LOG_DIR}/capi.yaml" 2>&1 || true
        {
            echo "### ${KIND_NODE}:/etc/resolv.conf"
            docker exec "${KIND_NODE}" cat /etc/resolv.conf
            echo "### CoreDNS Corefile"
            "${KUBECTL[@]}" -n kube-system get configmap coredns -o 'jsonpath={.data.Corefile}'
        } > "${LOG_DIR}/dns.txt" 2>&1 || true
        try "${KIND[@]}" export logs "${LOG_DIR}/kind" --name "${KIND_CLUSTER}"
    fi
    if [ -s "${WORKLOAD_KUBECONFIG}" ]; then
        "${KUBECTL_WORKLOAD[@]}" get nodes,pods -A -o wide --request-timeout=20s \
            > "${LOG_DIR}/workload-get.txt" 2>&1 || true
    fi
}

on_exit() {
    local rc=$?
    collect_logs
    if [ "${KEEP:-0}" = 1 ]; then
        echo "KEEP=1: leaving everything running; clean up with $0 --cleanup"
        echo "Management cluster: ${BIN_DIR}/kubectl --kubeconfig ${KUBECONFIG_FILE}"
        echo "Workload cluster: ${BIN_DIR}/kubectl --kubeconfig ${WORKLOAD_KUBECONFIG}"
    else
        teardown
    fi
    if [ "${rc}" -eq 0 ]; then
        echo "Cluster test passed. Logs: ${LOG_DIR}"
    else
        echo "Cluster test FAILED (exit ${rc}). Logs: ${LOG_DIR}"
    fi
    exit "${rc}"
}

# --- Stage 1: infrastructure ------------------------------------------------

# The provisioning network. forward mode='open' makes libvirt add no firewall
# rules of its own, so Ironic (in kind, on docker's bridge) can reach the
# agent on the VMs; iptables_rules adds the NAT that gives the VMs internet
# access. Each node gets a fixed DHCP lease.
render_network() {
    local node
    cat << EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='open'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${HOST_IP}' prefix='${SUBNET#*/}'>
    <dhcp>
      <range start='${HOST_IP%.*}.100' end='${HOST_IP%.*}.200'/>
EOF
    for node in "${NODES[@]}"; do
        echo "      <host mac='${NODE_MAC[${node}]}' name='${node}' ip='${NODE_IP[${node}]}'/>"
    done
    cat << EOF
    </dhcp>
  </ip>
</network>
EOF
}

# define_node <node>: an empty disk (Ironic writes the image onto it) and a
# UEFI VM, defined but not started: Ironic powers it on through Redfish.
define_node() {
    local node="$1" disk
    disk="$(node_disk "${node}")"
    sudo qemu-img create -q -f qcow2 "${disk}" 20G
    # shellcheck disable=SC2024 # the XML belongs to the invoking user
    sudo virt-install --connect qemu:///system --print-xml --import \
        --name "${node}" --memory "${NODE_MEMORY_MB}" --vcpus "${NODE_VCPUS[${node}]}" --cpu host-passthrough \
        --osinfo ubuntu24.04 \
        --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd \
        --disk "path=${disk},format=qcow2,bus=virtio" \
        --network "network=${NET_NAME},mac=${NODE_MAC[${node}]},model=virtio" \
        --serial "file,path=$(node_serial_log "${node}")" \
        --graphics none \
        > "${STATE_DIR}/${node}.xml"
    "${VIRSH[@]}" define "${STATE_DIR}/${node}.xml" > /dev/null
    NODE_UUID[${node}]=$("${VIRSH[@]}" domuuid "${node}" | tr -d '[:space:]')
    echo "${node}: UUID ${NODE_UUID[${node}]}, MAC ${NODE_MAC[${node}]}, ${NODE_ROLE[${node}]}"
}

# The Redfish helpers take the node's name.
redfish_power_state() {
    curl -sf "${REDFISH}/Systems/${NODE_UUID[$1]}" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["PowerState"])'
}

# redfish_reset <node> <reset type>
redfish_reset() {
    curl -sf -X POST -H 'Content-Type: application/json' -d "{\"ResetType\": \"$2\"}" \
        "${REDFISH}/Systems/${NODE_UUID[$1]}/Actions/ComputerSystem.Reset" > /dev/null
}

redfish_lists_node() {
    curl -sf "${REDFISH}/Systems" | grep -q "/redfish/v1/Systems/${NODE_UUID[$1]}\""
}

# power_state_is <node> <state>
power_state_is() {
    [ "$(redfish_power_state "$1")" = "$2" ]
}

image_served() {
    curl -sf "${IMAGE_CHECKSUM_URL}" | cmp -s - "${IMAGE_DIR}/${IMAGE_NAME}.qcow2.sha256"
}

stage_infra() {
    echo "=== Stage 1: infrastructure"
    mkdir -p "${STATE_DIR}" "${LOG_DIR}"

    sudo sysctl -q -w net.ipv4.ip_forward=1
    render_network > "${STATE_DIR}/network.xml"
    "${VIRSH[@]}" net-define "${STATE_DIR}/network.xml" > /dev/null
    "${VIRSH[@]}" net-start "${NET_NAME}" > /dev/null
    iptables_rules add

    # Where sushy-tools keeps inserted virtual media (sushy.conf).
    "${VIRSH[@]}" pool-define-as "${VMEDIA_POOL}" dir --target "${VMEDIA_POOL_DIR}" > /dev/null
    "${VIRSH[@]}" pool-build "${VMEDIA_POOL}" > /dev/null
    "${VIRSH[@]}" pool-start "${VMEDIA_POOL}" > /dev/null

    local node
    for node in "${NODES[@]}"; do
        define_node "${node}"
    done

    # sushy-tools needs libvirt's Python bindings, which only come from the
    # distribution (python3-libvirt). Runs as root: it manages libvirt
    # domains and their virtual media files.
    if [ ! -x "${STATE_DIR}/sushy-venv/bin/sushy-emulator" ]; then
        python3 -m venv --system-site-packages "${STATE_DIR}/sushy-venv"
        "${STATE_DIR}/sushy-venv/bin/pip" install -q "sushy-tools==${SUSHY_VERSION}"
    fi
    # shellcheck disable=SC2024 # the log belongs to the invoking user
    sudo nohup "${STATE_DIR}/sushy-venv/bin/sushy-emulator" \
        --config "${SCRIPT_DIR}/sushy.conf" -i "${HOST_IP}" -p "${SUSHY_PORT}" \
        > "${LOG_DIR}/sushy.log" 2>&1 &
    echo $! > "${STATE_DIR}/sushy.pid"

    python3 -m http.server "${HTTP_PORT}" --bind "${HOST_IP}" --directory "${IMAGE_DIR}" \
        > "${LOG_DIR}/http.log" 2>&1 &
    echo $! > "${STATE_DIR}/http.pid"

    check "Redfish emulator up" retry 30 1 curl -sf -o /dev/null "${REDFISH}/"
    for node in "${NODES[@]}"; do
        check "Redfish lists ${node}" redfish_lists_node "${node}"
        check "${node} is off" power_state_is "${node}" Off
        redfish_reset "${node}" On
        check "Redfish powers ${node} on" retry 30 1 power_state_is "${node}" On
        redfish_reset "${node}" ForceOff
        check "Redfish powers ${node} off" retry 30 1 power_state_is "${node}" Off
    done
    check "image served over HTTP" retry 10 1 image_served
}

# --- Stage 2: management cluster --------------------------------------------

# One node. Ironic will run on it with host networking; its API and image
# server are published on HOST_IP, which the Ironic resource advertises as its
# external IP. The VMs and sushy-tools (the BMC) reach Ironic there, so
# nothing has to route to the container's own address.
render_kind_config() {
    cat << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: ${IRONIC_API_PORT}
        hostPort: ${IRONIC_API_PORT}
        listenAddress: ${HOST_IP}
      - containerPort: ${IRONIC_HTTP_PORT}
        hostPort: ${IRONIC_HTTP_PORT}
        listenAddress: ${HOST_IP}
EOF
}

kind_create() {
    render_kind_config > "${STATE_DIR}/kind.yaml"
    "${KIND[@]}" create cluster --name "${KIND_CLUSTER}" --image "${KIND_NODE_IMAGE}" \
        --config "${STATE_DIR}/kind.yaml" --kubeconfig "${KUBECONFIG_FILE}" --wait 5m \
        > "${LOG_DIR}/kind-create.log" 2>&1
}

# kind copies the host's search domains into the node, and kubelet copies the
# node's into every pod, with ndots:5. On GitHub's runners that is the Azure
# internal domain, and lookups under it stop glibc's search-list walk before
# it tries the name itself: glibc-based images (Ironic's ramdisk downloader)
# cannot resolve external names, while musl-based ones can. The management
# cluster needs none of the host's search domains. kubelet re-reads the file
# for every new pod; /etc/resolv.conf is a bind mount, so rewrite it in place.
drop_host_search_domains() {
    docker exec "${KIND_NODE}" sh -c \
        'grep -v "^search " /etc/resolv.conf > /tmp/resolv.conf && cat /tmp/resolv.conf > /etc/resolv.conf'
}

# Ironic will run with host networking on the kind node, so the node itself
# must reach the host's provisioning address.
from_kind_node() {
    docker exec "${KIND_NODE}" curl -sf -o /dev/null "$1"
}

# Pod settings of Ironic's ramdisk-downloader init container.
downloader_overrides() {
    cat << EOF
{"spec": {
  "hostNetwork": true,
  "dnsPolicy": "ClusterFirstWithHostNet",
  "containers": [{
    "name": "dns-downloader",
    "image": "${IPA_DOWNLOADER_IMAGE}",
    "command": ["/bin/sh", "-c", "cat /etc/resolv.conf; curl -sS -o /dev/null -I ${EXTERNAL_URL}"],
    "securityContext": {
      "runAsUser": 997, "runAsGroup": 994, "readOnlyRootFilesystem": true,
      "capabilities": {"drop": ["ALL"]}
    }
  }]
}}
EOF
}

stage_mgmt() {
    echo "=== Stage 2: management cluster (kind)"
    install_tool kind \
        "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
        "${KIND_SHA256}"
    install_tool kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        "${KUBECTL_SHA256}"

    check "kind cluster ${KIND_CLUSTER} created" kind_create
    check "host search domains removed from ${KIND_NODE}" drop_host_search_domains
    check "management node Ready" \
        kubectl_quiet wait --for=condition=Ready node --all --timeout=300s
    check "CoreDNS available" \
        kubectl_quiet -n kube-system rollout status deployment/coredns --timeout=300s
    check "${KIND_NODE} reaches Redfish" retry 10 1 from_kind_node "${REDFISH}/"
    check "${KIND_NODE} reaches the image server" retry 10 1 from_kind_node "${IMAGE_CHECKSUM_URL}"

    # Ironic runs with host networking and dnsPolicy ClusterFirstWithHostNet,
    # so it resolves through CoreDNS from the node's network namespace.
    check "${KIND_NODE} reaches ${EXTERNAL_URL}" from_kind_node "${EXTERNAL_URL}"
    check "a pod reaches ${EXTERNAL_URL}" \
        curl_pod "${KUBECONFIG_FILE}" dns-pod '{"spec":{}}' "${CURL_EXTERNAL[@]}"
    check "a host-network pod reaches ${EXTERNAL_URL}" \
        curl_pod "${KUBECONFIG_FILE}" dns-hostnet \
        '{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}' "${CURL_EXTERNAL[@]}"
    # Same image and pod settings as Ironic's ramdisk downloader, which
    # resolves with glibc (the pods above use musl).
    check "a pod like Ironic's ramdisk downloader reaches ${EXTERNAL_URL}" \
        pod_succeeds "${KUBECONFIG_FILE}" dns-downloader "${IPA_DOWNLOADER_IMAGE}" "$(downloader_overrides)"
}

# --- Stage 3: Metal3 --------------------------------------------------------

clusterctl_init() {
    "${CLUSTERCTL[@]}" init --kubeconfig "${KUBECONFIG_FILE}" \
        --core "cluster-api:${CAPI_VERSION}" \
        --bootstrap "kubeadm:${CAPI_VERSION}" \
        --control-plane "kubeadm:${CAPI_VERSION}" \
        --infrastructure "metal3:${CAPM3_VERSION}" \
        --ipam "metal3:${IPAM_VERSION}" \
        --wait-providers --wait-provider-timeout 600 \
        > "${LOG_DIR}/clusterctl-init.log" 2>&1
}

deployments_available() {
    kubectl_quiet -n "$1" wait deployment --all --for=condition=Available --timeout=300s
}

# Ironic, managed by ironic-standalone-operator: virtual media only (no
# DHCP/iPXE), plain HTTP, ephemeral database, advertised on HOST_IP. BMO
# finds it by name and namespace (metal3/bmo). The operator defaults the
# ramdisk downloader to :latest; it is pinned here.
render_ironic() {
    cat << EOF
apiVersion: ironic.metal3.io/v1alpha1
kind: Ironic
metadata:
  name: ironic
  namespace: ${BMO_NAMESPACE}
spec:
  version: "${IRONIC_VERSION}"
  images:
    deployRamdiskDownloader: ${IPA_DOWNLOADER_IMAGE}
  networking:
    externalIP: ${HOST_IP}
  deployRamdisk:
    extraKernelParams: console=ttyS0
EOF
}

ironic_api_up() {
    curl -sf -o /dev/null "${IRONIC_API}/"
}

# render_bmh <node>: the VM as a BareMetalHost, driven through sushy-tools
# with virtual media. sushy-tools has no authentication, but BMO requires
# credentials. Cleaning is disabled: the disk is empty, and stage 4 writes it
# anyway (CAPM3 then sets the mode from metal3/cluster.yaml).
render_bmh() {
    local node="$1"
    cat << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${node}-bmc
  namespace: ${BMH_NAMESPACE}
type: Opaque
stringData:
  username: admin
  password: password
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${node}
  namespace: ${BMH_NAMESPACE}
  labels:
    ${HOST_ROLE_LABEL}: ${NODE_ROLE[${node}]}
spec:
  online: false
  bootMode: UEFI
  bootMACAddress: ${NODE_MAC[${node}]}
  automatedCleaningMode: disabled
  # The disk is virtio; BMO's default hint is /dev/sda.
  rootDeviceHints:
    deviceName: /dev/vda
  bmc:
    address: redfish-virtualmedia+${REDFISH}/Systems/${NODE_UUID[${node}]}
    credentialsName: ${node}-bmc
    disableCertificateVerification: true
EOF
}

# bmh_status <node>: "<state>|<error count>|<error message>", the message last
# so that it may itself contain "|".
bmh_status() {
    "${KUBECTL[@]}" -n "${BMH_NAMESPACE}" get baremetalhost "$1" \
        -o 'jsonpath={.status.provisioning.state}|{.status.errorCount}|{.status.errorMessage}' 2> /dev/null
}

# agent_failure <node>: the first command the Ironic agent on the VM reports
# as failed. BMO does not always surface these: a failed deploy step can leave
# the host in "provisioning" with no error. QEMU truncates the serial log
# whenever the VM starts, so it only holds the current boot.
agent_failure() {
    sudo grep -m1 -o 'Command failed: .*' "$(node_serial_log "$1")" 2> /dev/null
}

# vm_paused <node>: QEMU pauses a VM whose disk write fails, for example when
# the host runs out of space for the growing qcow2. Neither Ironic nor BMO
# notices: the host just stays in its current state. Only that reason counts:
# libvirt also reports every VM as "paused (starting up)" while it starts.
vm_paused() {
    local state
    state="$("${VIRSH[@]}" domstate "$1" --reason 2> /dev/null)" || return 1
    [[ "${state}" == "paused (I/O error)" ]] || return 1
    echo "${state}"
}

# wait_bmh_state <node> <state> <timeout seconds>: print each state the host
# passes through (and each new error) until it reaches <state>. BMO retries
# failed operations; give up after MAX_BMH_ERRORS of them, or as soon as the
# agent reports a failed command.
MAX_BMH_ERRORS=5
wait_bmh_state() {
    local node="$1" want="$2" deadline=$((SECONDS + $3))
    local state="" last="" errors="" error="" last_error="" failure=""
    while ((SECONDS < deadline)); do
        state="" errors="" error=""
        IFS='|' read -r state errors error < <(bmh_status "${node}") || true
        if [ "${state}" != "${last}" ]; then
            echo "  ${node}: ${state:-(no state yet)}"
            last="${state}"
        fi
        [ "${state}" = "${want}" ] && return 0
        if [ -n "${error}" ] && [ "${error}" != "${last_error}" ]; then
            echo "  ${node} error: ${error}"
            last_error="${error}"
        fi
        if [ "${errors:-0}" -ge "${MAX_BMH_ERRORS}" ]; then
            echo "  ${node}: giving up after ${errors} errors"
            return 1
        fi
        if failure="$(agent_failure "${node}")"; then
            echo "  ${node} agent: ${failure:0:500}"
            return 1
        fi
        if failure="$(vm_paused "${node}")"; then
            echo "  ${node} VM ${failure}"
            return 1
        fi
        sleep 10
    done
    return 1
}

stage_metal3() {
    echo "=== Stage 3: Metal3"
    install_tool clusterctl \
        "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-linux-amd64" \
        "${CLUSTERCTL_SHA256}"
    fetch "${STATE_DIR}/manifests/irso-${IRSO_VERSION}.yaml" \
        "https://github.com/metal3-io/ironic-standalone-operator/releases/download/${IRSO_VERSION}/install.yaml" \
        "${IRSO_MANIFEST_SHA256}"

    # Also installs cert-manager, which the Metal3 webhooks need.
    check "Cluster API ${CAPI_VERSION}, CAPM3 ${CAPM3_VERSION} and IPAM ${IPAM_VERSION} installed" \
        clusterctl_init

    check "ironic-standalone-operator ${IRSO_VERSION} installed" \
        kubectl_quiet apply --server-side -f "${STATE_DIR}/manifests/irso-${IRSO_VERSION}.yaml"
    check "ironic-standalone-operator ${IRSO_VERSION} available" \
        deployments_available ironic-standalone-operator-system

    # The operator's webhook may take a moment to answer after it is available.
    kubectl_quiet create namespace "${BMO_NAMESPACE}"
    render_ironic > "${STATE_DIR}/ironic.yaml"
    check "Ironic resource accepted" \
        retry 30 5 kubectl_quiet apply -f "${STATE_DIR}/ironic.yaml"
    # Includes downloading the agent ramdisk.
    check "Ironic ready" \
        kubectl_quiet -n "${BMO_NAMESPACE}" wait ironic/ironic --for=condition=Ready --timeout=900s
    check "Ironic API reachable at ${IRONIC_API}" retry 30 2 ironic_api_up

    check "Bare Metal Operator installed" \
        retry 3 10 kubectl_quiet apply -k "${SCRIPT_DIR}/metal3/bmo"
    check "Bare Metal Operator available" deployments_available "${BMO_NAMESPACE}"

    kubectl_quiet create namespace "${BMH_NAMESPACE}"
    local node
    for node in "${NODES[@]}"; do
        render_bmh "${node}" > "${STATE_DIR}/bmh-${node}.yaml"
        check "BareMetalHost ${node} accepted" \
            retry 30 5 kubectl_quiet apply -f "${STATE_DIR}/bmh-${node}.yaml"
    done
    # Registration, then inspection: Ironic boots the agent on each VM over
    # virtual media and the agent reports back. The hosts go through it
    # together.
    for node in "${NODES[@]}"; do
        check "${node} inspected and available" wait_bmh_state "${node}" available 1800
    done
}

# --- Stage 4: provisioning --------------------------------------------------

# The workload cluster's manifests: metal3/cluster.yaml with its variables
# filled in. clusterctl reads them from its environment (none of the script's
# variables are exported, hence NAME="${NAME}") and fails on any left unset.
render_cluster() {
    CLUSTER_NAME="${CLUSTER_NAME}" \
        CLUSTER_NAMESPACE="${BMH_NAMESPACE}" \
        CONTROL_PLANE_HOST="${CP_IP}" \
        KUBERNETES_VERSION="v${KUBERNETES_VERSION}" \
        IMAGE_URL="${IMAGE_URL}" \
        IMAGE_CHECKSUM_URL="${IMAGE_CHECKSUM_URL}" \
        HOST_ROLE_LABEL="${HOST_ROLE_LABEL}" \
        CONTROL_PLANE_HOST_ROLE="${NODE_ROLE[${CP_NODE}]}" \
        WORKER_HOST_ROLE="${NODE_ROLE[${WORKER_NODE}]}" \
        "${CLUSTERCTL[@]}" generate yaml --from "${SCRIPT_DIR}/metal3/cluster.yaml" \
        > "${STATE_DIR}/cluster.yaml"
}

# A Machine is Running once its Node exists and CAPM3 has set the Node's
# provider ID, which needs kubeadm init (or join) to have finished on the
# host. machines_running <timeout seconds>: all of the cluster's Machines.
machines_running() {
    kubectl_quiet -n "${BMH_NAMESPACE}" wait machine -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" \
        --for=jsonpath='{.status.phase}'=Running --timeout="$1s"
}

# CAPI keeps the workload cluster's admin kubeconfig in <cluster>-kubeconfig.
save_workload_kubeconfig() {
    (
        umask 077
        "${KUBECTL[@]}" -n "${BMH_NAMESPACE}" get secret "${CLUSTER_NAME}-kubeconfig" \
            -o 'jsonpath={.data.value}' | base64 -d > "${WORKLOAD_KUBECONFIG}"
    ) && [ -s "${WORKLOAD_KUBECONFIG}" ]
}

workload_api_ready() {
    "${KUBECTL_WORKLOAD[@]}" get --raw /readyz > /dev/null 2>&1
}

# node_info_is <node> <nodeInfo field> <value>
node_info_is() {
    [ "$("${KUBECTL_WORKLOAD[@]}" get node "$1" -o "jsonpath={.status.nodeInfo.$2}" 2> /dev/null)" = "$3" ]
}

stage_provision() {
    echo "=== Stage 4: provisioning (${CLUSTER_NAME}, Kubernetes v${KUBERNETES_VERSION})"
    check "cluster manifests rendered" render_cluster
    check "cluster ${CLUSTER_NAME} accepted" \
        retry 10 5 kubectl_quiet apply -f "${STATE_DIR}/cluster.yaml"

    # Ironic boots the agent again; it writes the image and a config drive
    # (kubeadm's cloud-init) to the disk, and the host then boots the image.
    # The worker's join configuration only exists once the control plane is
    # initialized, so the worker follows the control plane.
    check "${CP_NODE} provisioned with ${IMAGE_NAME}" wait_bmh_state "${CP_NODE}" provisioned 1800
    check "${CLUSTER_NAME} control plane initialized" \
        kubectl_quiet -n "${BMH_NAMESPACE}" wait "cluster/${CLUSTER_NAME}" \
        --for=condition=ControlPlaneInitialized --timeout=1200s
    check "workload kubeconfig saved" save_workload_kubeconfig
    check "workload API reachable at https://${CP_IP}:6443" \
        retry 30 5 workload_api_ready
    check "${WORKER_NODE} provisioned with ${IMAGE_NAME}" wait_bmh_state "${WORKER_NODE}" provisioned 1800
    check "control-plane and worker Machines running" machines_running 1200
    echo "  disk usage with both hosts provisioned:"
    disk_usage | sed 's/^/    /' || true
    local node
    for node in "${NODES[@]}"; do
        check "workload node ${node} runs kubelet v${KUBERNETES_VERSION}" \
            retry 10 5 node_info_is "${node}" kubeletVersion "v${KUBERNETES_VERSION}"
    done
}

# --- Stage 5: cluster checks ------------------------------------------------

install_helm() {
    local archive="${STATE_DIR}/downloads/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    fetch "${archive}" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${HELM_SHA256}"
    tar -xzf "${archive}" -C "${BIN_DIR}" --strip-components=1 linux-amd64/helm
}

# The chart from its OCI registry, checked against the pinned archive digest.
pull_kube_ovn_chart() {
    local dir="${STATE_DIR}/charts" chart
    chart="${dir}/kube-ovn-v2-${KUBE_OVN_VERSION}.tgz"
    rm -f "${chart}"
    mkdir -p "${dir}"
    "${HELM[@]}" pull "${KUBE_OVN_CHART}" --version "${KUBE_OVN_VERSION}" --destination "${dir}" \
        >> "${LOG_DIR}/helm.log" 2>&1 &&
        sha256_ok "${chart}" "${KUBE_OVN_CHART_SHA256}"
}

install_kube_ovn() {
    "${HELM[@]}" install kube-ovn "${STATE_DIR}/charts/kube-ovn-v2-${KUBE_OVN_VERSION}.tgz" \
        --namespace kube-system >> "${LOG_DIR}/helm.log" 2>&1
}

# The Kube-OVN components, in the order they come up.
kube_ovn_running() {
    local workload
    for workload in deployment/ovn-central daemonset/ovs-ovn deployment/kube-ovn-controller daemonset/kube-ovn-cni; do
        workload_quiet -n kube-system rollout status "${workload}" --timeout=600s || return 1
    done
}

# Pod spec overrides that put a test pod on <node>, past any taints.
on_node() {
    echo "{\"spec\":{\"nodeName\":\"$1\",\"tolerations\":[{\"operator\":\"Exists\"}]}}"
}

# A pod on one node fetches CoreDNS's readiness endpoint from a CoreDNS pod on
# the other, at its pod address: pod-to-pod traffic between nodes, which
# Kube-OVN carries in Geneve tunnels through the nodes' kernels.
across_nodes() {
    local node ip client
    read -r node ip < <("${KUBECTL_WORKLOAD[@]}" -n kube-system get pods -l k8s-app=kube-dns \
        -o jsonpath='{range .items[*]}{.spec.nodeName} {.status.podIP}{"\n"}{end}')
    [ -n "${ip:-}" ] || return 1
    client="${CP_NODE}"
    [ "${node}" = "${CP_NODE}" ] && client="${WORKER_NODE}"
    echo "  from ${client} to CoreDNS ${ip} on ${node}"
    curl_pod "${WORKLOAD_KUBECONFIG}" workload-across-nodes "$(on_node "${client}")" \
        -sSf --retry 3 "http://${ip}:8181/ready"
}

stage_cluster() {
    echo "=== Stage 5: cluster checks"
    install_helm

    check "Kube-OVN ${KUBE_OVN_VERSION} chart pulled and verified" retry 3 10 pull_kube_ovn_chart
    check "Kube-OVN ${KUBE_OVN_VERSION} installed" install_kube_ovn
    # ovs-ovn loads the node kernel's openvswitch module, on every node.
    check "Kube-OVN running on all nodes" kube_ovn_running
    local node
    for node in "${NODES[@]}"; do
        check "workload node ${node} Ready" \
            workload_quiet wait "node/${node}" --for=condition=Ready --timeout=300s
        check "${node} runs the NVIDIA kernel ${NODE_KERNEL}" node_info_is "${node}" kernelVersion "${NODE_KERNEL}"
    done
    check "workload CoreDNS available" \
        workload_quiet -n kube-system rollout status deployment/coredns --timeout=300s

    # Pod network, cluster DNS and kube-proxy on the worker: the API's
    # Service by name (/readyz is open to anonymous clients), then the
    # internet.
    check "a pod on ${WORKER_NODE} reaches the API through its Service" \
        curl_pod "${WORKLOAD_KUBECONFIG}" workload-api "$(on_node "${WORKER_NODE}")" \
        -sSfk --retry 3 https://kubernetes.default.svc.cluster.local/readyz
    check "a pod on ${WORKER_NODE} reaches ${EXTERNAL_URL}" \
        curl_pod "${WORKLOAD_KUBECONFIG}" workload-external "$(on_node "${WORKER_NODE}")" "${CURL_EXTERNAL[@]}"
    check "pods reach each other across nodes" across_nodes

    check "CAPI reports ${CLUSTER_NAME} available" \
        kubectl_quiet -n "${BMH_NAMESPACE}" wait "cluster/${CLUSTER_NAME}" --for=condition=Available --timeout=600s
}

# --- Main -------------------------------------------------------------------

case "${1:-}" in
    --cleanup)
        teardown
        exit 0
        ;;
    "" | -*)
        echo "usage: $0 <image.qcow2> | --cleanup"
        exit 2
        ;;
esac

IMAGE="$(realpath "$1")"
IMAGE_DIR="$(dirname "${IMAGE}")"
IMAGE_NAME="$(basename "${IMAGE}" .qcow2)"
[ -f "${IMAGE}" ] || { echo "image not found: ${IMAGE}"; exit 1; }
[ -f "${IMAGE_DIR}/${IMAGE_NAME}.qcow2.sha256" ] || { echo "missing ${IMAGE_NAME}.qcow2.sha256 next to the image"; exit 1; }
# Served by stage 1's HTTP server.
IMAGE_URL="http://${HOST_IP}:${HTTP_PORT}/${IMAGE_NAME}.qcow2"
IMAGE_CHECKSUM_URL="${IMAGE_URL}.sha256"

preflight
# Leftovers from an earlier KEEP=1 or interrupted run.
teardown
trap on_exit EXIT

stage_infra
stage_mgmt
stage_metal3
stage_provision
stage_cluster
