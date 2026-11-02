#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks the contents of a built image without booting it (libguestfs).
# Needs root: libguestfs cannot read Ubuntu's 0600 host kernels otherwise.
#
# Usage: sudo images/check.sh [--kernel VERSION] [--nvidia-fs 0|1] <image.qcow2>
#
# Defaults come from the ubuntu-nvidia-kernel element itself. Pass the
# options when the image was built with other values: sudo drops the DIB_*
# environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: $0 [--kernel VERSION] [--nvidia-fs 0|1] <image.qcow2>"
    exit 2
}

KERNEL=""
NVIDIA_FS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) KERNEL="${2:?}"; shift 2 ;;
        --nvidia-fs) NVIDIA_FS="${2:?}"; shift 2 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || usage
IMAGE="$1"

# shellcheck source=SCRIPTDIR/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash
source "${SCRIPT_DIR}/elements/ubuntu-nvidia-kernel/environment.d/11-ubuntu-nvidia-kernel.bash"
KERNEL="${KERNEL:-${DIB_UBUNTU_NVIDIA_KERNEL}}"
NVIDIA_FS="${NVIDIA_FS:-${DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS}}"

FAILED=0

check() {
    if "${@:2}"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        FAILED=1
    fi
}

SOURCES=$(virt-cat -a "${IMAGE}" /etc/apt/sources.list)
MODULES=$(virt-ls -a "${IMAGE}" /lib/modules)
DPKG_STATUS=$(virt-cat -a "${IMAGE}" /var/lib/dpkg/status)
GRUB_CFG=$(virt-cat -a "${IMAGE}" /boot/grub/grub.cfg)
# The default (first) entry's kernel; GRUB_DEFAULT=0 on Ubuntu.
GRUB_DEFAULT_LINUX=$(grep -m1 -E '^[[:space:]]*linux[[:space:]]' <<<"${GRUB_CFG}" || true)

echo "--- /etc/apt/sources.list"
echo "${SOURCES}"
echo "--- /lib/modules"
echo "${MODULES}"
echo "--- GRUB default entry"
echo "${GRUB_DEFAULT_LINUX}"
echo "---"

# shellcheck disable=SC2317 # called through check()
package_status() {
    awk -v pkg="$1" '
        $0 == "Package: " pkg { found = 1; next }
        found && /^Status:/ { print; exit }
        /^$/ { found = 0 }
    ' <<<"${DPKG_STATUS}"
}

# shellcheck disable=SC2317 # called through check()
held() {
    package_status "$1" | grep -qx "Status: hold ok installed"
}

# shellcheck disable=SC2317 # called through check()
installed() {
    package_status "$1" | grep -qE "^Status: (install|hold) ok installed$"
}

check "restricted component enabled" grep -qE '^deb .* restricted( |$)' <<<"${SOURCES}"
check "${KERNEL} modules present" grep -qx "${KERNEL}" <<<"${MODULES}"
check "linux-image-${KERNEL} held" held "linux-image-${KERNEL}"
check "linux-headers-${KERNEL} held" held "linux-headers-${KERNEL}"
check "GRUB boots ${KERNEL} by default" grep -qF "/vmlinuz-${KERNEL} " <<<"${GRUB_DEFAULT_LINUX}"
if [ "${NVIDIA_FS}" = "1" ]; then
    check "linux-modules-nvidia-fs-${KERNEL} installed" installed "linux-modules-nvidia-fs-${KERNEL}"
fi

exit "${FAILED}"
