#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The collection's capm3_host_wait_abort_command for the test's VMs: prints
# why and exits 0 if the VM of host CAPM3_HOST has failed in a way BMO does
# not report, exits 1 otherwise.
#
#  - The Ironic agent reported a failed command: a failed deploy step can
#    leave the host in "provisioning" with no error. QEMU truncates the
#    serial log whenever the VM starts, so it only holds the current boot.
#  - QEMU paused the VM after a failed disk write, for example when the
#    runner runs out of space for the growing qcow2. libvirt also reports
#    every VM as "paused (starting up)" while it starts; that doesn't count.
set -uo pipefail

host="${CAPM3_HOST:?}"

if failure="$(sudo grep -m1 -o 'Command failed: .*' "/var/log/libvirt/qemu/${host}-serial.log" 2> /dev/null)"; then
    echo "agent: ${failure:0:500}"
    exit 0
fi

state="$(sudo virsh --connect qemu:///system domstate "${host}" --reason 2> /dev/null)"
if [ "${state}" = "paused (I/O error)" ]; then
    echo "VM ${state}"
    exit 0
fi
exit 1
