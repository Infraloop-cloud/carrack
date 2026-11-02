#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds the carrack NVIDIA node image (Ubuntu 24.04 + Kubernetes) with
# diskimage-builder and vexxhost/capo-image-elements. Used by CI
# (.github/workflows/images.yaml) and for local builds.
#
# Needs a Linux host with the packages from bindep.txt installed and working
# sudo (disk-image-create calls it for chroot/mount/losetup; the script
# itself must not run as root).
#
# Environment:
#   KUBERNETES_VERSION       Kubernetes version baked in (default 1.36.5)
#   CAPO_IMAGE_ELEMENTS_REF  capo-image-elements commit (pinned, bump deliberately)
#   OUTPUT_DIR               where the qcow2 and its .sha256 go (default images/output)
#   TMPDIR                   work dir for this script and diskimage-builder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.36.5}"
CAPO_IMAGE_ELEMENTS_REF="${CAPO_IMAGE_ELEMENTS_REF:-ebb93b14290312a7598c5871aa258a9343df4d17}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"

# Goes into file names, registry tags and CI step outputs.
if ! [[ "${KUBERNETES_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "KUBERNETES_VERSION must look like 1.36.5, got '${KUBERNETES_VERSION}'"
    exit 1
fi

# One image per Kubernetes minor version: patch releases overwrite it.
KUBERNETES_MINOR="${KUBERNETES_VERSION%.*}"
IMAGE_NAME="ubuntu-24.04-nvidia-${KUBERNETES_MINOR//./-}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/carrack-image.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Fetching vexxhost/capo-image-elements @ ${CAPO_IMAGE_ELEMENTS_REF}"
CAPO_DIR="${WORK_DIR}/capo-image-elements"
git init -q "${CAPO_DIR}"
git -C "${CAPO_DIR}" fetch -q --depth 1 https://github.com/vexxhost/capo-image-elements.git "${CAPO_IMAGE_ELEMENTS_REF}"
git -C "${CAPO_DIR}" -c advice.detachedHead=false checkout -q FETCH_HEAD

export ELEMENTS_PATH="${CAPO_DIR}/elements:${SCRIPT_DIR}/elements"
export DIB_RELEASE="noble"
export DIB_KUBERNETES_VERSION="${KUBERNETES_VERSION}"
export DIB_CLOUD_INIT_GROWPART_DEVICES='["/"]'
export DIB_SKIP_BASE_PACKAGE_INSTALL="1"
# DIB_IMAGE_SIZE deliberately unset: DIB then sizes the image from the
# built content. A fixed size silently becomes too small as elements are
# added ("No space left on device" late in the build).

mkdir -p "${OUTPUT_DIR}"
echo "Building ${IMAGE_NAME}.qcow2"
uv run --locked --project "${SCRIPT_DIR}" disk-image-create -t qcow2 -o "${OUTPUT_DIR}/${IMAGE_NAME}" \
    vm ubuntu-minimal block-device-kubernetes kubernetes ubuntu-nvidia-kernel

(cd "${OUTPUT_DIR}" && sha256sum "${IMAGE_NAME}.qcow2" > "${IMAGE_NAME}.qcow2.sha256")
cat "${OUTPUT_DIR}/${IMAGE_NAME}.qcow2.sha256"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "image-name=${IMAGE_NAME}" >> "${GITHUB_OUTPUT}"
    echo "kubernetes-version=${KUBERNETES_VERSION}" >> "${GITHUB_OUTPUT}"
fi
