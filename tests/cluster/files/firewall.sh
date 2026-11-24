#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Forwarding and NAT for the provisioning network. libvirt adds none
# (forward mode='open'), and docker sets the FORWARD policy to DROP, so the
# bridge needs explicit accepts — in DOCKER-USER when docker is running.
#
# Usage (as root): firewall.sh add|del <subnet> <bridge>
set -euo pipefail

action="$1" subnet="$2" bridge="$3"
chain=FORWARD
if iptables -n -L DOCKER-USER > /dev/null 2>&1; then
    chain=DOCKER-USER
fi

rules=(
    "nat POSTROUTING -s ${subnet} ! -d ${subnet} -j MASQUERADE"
    "filter ${chain} -i ${bridge} -j ACCEPT"
    "filter ${chain} -o ${bridge} -j ACCEPT"
)
for rule in "${rules[@]}"; do
    # shellcheck disable=SC2086 # rule is split into iptables arguments
    set -- ${rule}
    table="$1"
    shift
    if [ "${action}" = add ]; then
        iptables -t "${table}" -C "$@" 2> /dev/null || iptables -t "${table}" -I "$@"
    else
        while iptables -t "${table}" -C "$@" 2> /dev/null; do
            iptables -t "${table}" -D "$@"
        done
    fi
done
