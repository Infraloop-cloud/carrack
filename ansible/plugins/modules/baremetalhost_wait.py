#!/usr/bin/python
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

DOCUMENTATION = r"""
module: baremetalhost_wait
short_description: Wait for a Metal3 BareMetalHost to reach a provisioning state
description:
  - Polls a BareMetalHost until its provisioning state is one of O(states).
  - The Bare Metal Operator retries failed operations; this module gives up
    once the host has failed O(max_errors) times, instead of waiting out
    O(timeout).
  - Some failures never reach the BareMetalHost, for example a deploy step
    that fails inside the Ironic agent, or a machine that stops responding.
    O(abort_command) can detect those from outside, such as from a serial
    console log.
  - Returns every state the host went through and every error it reported.
version_added: 0.1.0
author:
  - Infraloop.cloud (@Infraloop-cloud)
options:
  name:
    description: The BareMetalHost's name.
    type: str
    required: true
  namespace:
    description: The BareMetalHost's namespace.
    type: str
    required: true
  states:
    description: The provisioning states to wait for, such as V(available) or V(provisioned).
    type: list
    elements: str
    required: true
  timeout:
    description: Seconds to wait before failing.
    type: int
    default: 1800
  interval:
    description: Seconds between polls.
    type: int
    default: 10
  max_errors:
    description: Fail once the host's error count reaches this.
    type: int
    default: 5
  abort_command:
    description:
      - A shell command run on every poll, with the host's name in E(CAPM3_HOST).
        If it exits with 0, the module fails with the command's output as the reason.
    type: str
  kubeconfig:
    description: The kubeconfig of the cluster holding the BareMetalHost.
    type: path
    required: true
  kubectl:
    description: The kubectl binary.
    type: path
    default: kubectl
"""

EXAMPLES = r"""
- name: Wait for the host to be inspected
  carrack.capm3.baremetalhost_wait:
    name: node-0
    namespace: carrack
    states: [available]
    kubeconfig: ~/.carrack/bootstrap.kubeconfig
    kubectl: ~/.carrack/bin/kubectl
"""

RETURN = r"""
state:
  description: The host's last provisioning state.
  type: str
  returned: always
transitions:
  description: Every state the host went through, with the seconds since the start.
  type: list
  elements: dict
  returned: always
errors:
  description: Every distinct error message the host reported.
  type: list
  elements: str
  returned: always
"""

import json
import time

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec=dict(
            name=dict(type="str", required=True),
            namespace=dict(type="str", required=True),
            states=dict(type="list", elements="str", required=True),
            timeout=dict(type="int", default=1800),
            interval=dict(type="int", default=10),
            max_errors=dict(type="int", default=5),
            abort_command=dict(type="str"),
            kubeconfig=dict(type="path", required=True),
            kubectl=dict(type="path", default="kubectl"),
        ),
        supports_check_mode=True,
    )
    p = module.params
    name = p["name"]
    start = time.monotonic()
    state = ""
    transitions = []
    errors = []

    def result(**kwargs):
        return dict(state=state, transitions=transitions, errors=errors, **kwargs)

    if module.check_mode:
        module.exit_json(**result(changed=False))

    get = [p["kubectl"], "--kubeconfig", p["kubeconfig"], "--namespace", p["namespace"],
           "get", "baremetalhost", name, "--output", "json"]
    while True:
        elapsed = int(time.monotonic() - start)
        rc, out, err = module.run_command(get)
        status = json.loads(out).get("status", {}) if rc == 0 else {}
        current = status.get("provisioning", {}).get("state", "")
        if current != state or not transitions:
            state = current
            transitions.append(dict(state=state, seconds=elapsed))
        if state in p["states"]:
            module.exit_json(**result(changed=False))

        error = status.get("errorMessage", "")
        if error and error not in errors:
            errors.append(error)
        count = status.get("errorCount") or 0
        if count >= p["max_errors"]:
            module.fail_json(**result(msg=f"{name}: giving up after {count} errors: {error}"))

        if p["abort_command"]:
            rc, out, err = module.run_command(
                p["abort_command"], use_unsafe_shell=True, environ_update=dict(CAPM3_HOST=name))
            if rc == 0:
                module.fail_json(**result(msg=f"{name}: {out.strip()[:1000]}"))

        if elapsed >= p["timeout"]:
            module.fail_json(**result(
                msg=f"{name}: not {' or '.join(p['states'])} after {p['timeout']}s (state: {state or 'none'})"))
        time.sleep(p["interval"])


if __name__ == "__main__":
    main()
