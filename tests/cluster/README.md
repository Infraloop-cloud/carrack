# Cluster test

Deploys a cluster from a carrack node image onto emulated bare-metal hosts
with the [`carrack.capm3`](../../ansible/) collection, the way a user would,
and checks the result with [testinfra](https://testinfra.readthedocs.io/).
CI runs it in [`.github/workflows/cluster-test.yaml`](../../.github/workflows/cluster-test.yaml).

```bash
tests/cluster/run.sh images/output/ubuntu-24.04-nvidia-1-36.qcow2
```

`run.sh`:

1. Sets up a Python environment from [`requirements.txt`](requirements.txt)
   (pinned by hash) and installs the collections in
   [`requirements.yml`](requirements.yml): `carrack.capm3` from this repository
   and `kubernetes.core`.
2. **Emulated datacenter** ([`datacenter.yml`](datacenter.yml)): a libvirt
   provisioning network, a UEFI VM for each host in [`vars.yml`](vars.yml) (a
   control-plane node and a worker), sushy-tools as their Redfish BMCs, an HTTP
   server for the image and an SSH key for the checks.
3. **Checks** of the datacenter, before Metal3 takes over the VMs.
4. **`carrack.capm3.deploy`**, with [`vars.yml`](vars.yml): kind, Metal3, the
   hosts enrolled and inspected, the cluster provisioned onto them, Kube-OVN.
   [`files/host-failed.sh`](files/host-failed.sh) stops the waits as soon as a
   VM's Ironic agent reports a failure or the VM is paused, which the
   BareMetalHosts don't always show.
5. **Checks** of the bootstrap cluster, Metal3, the cluster and, over SSH, the
   nodes themselves.
6. Collects logs into `tests/cluster/logs/` ([`logs.yml`](logs.yml)) and tears
   everything down ([`teardown.yml`](teardown.yml)), whatever the outcome.

Each check's docstring is its line in the results table, which also goes to
the GitHub job summary; the JUnit reports are in the logs.

## Requirements

x86_64 Linux with KVM, libvirt (`qemu:///system`), virt-install, OVMF,
python3-libvirt, python3-venv, docker usable without sudo, systemd and
passwordless sudo. The workflow installs the packages on GitHub's
ubuntu-24.04 runner.

`KEEP=1` leaves everything running after the test; `run.sh --cleanup` removes
it. `KUBERNETES_VERSION` (default: `images/kubernetes-version`) and
`DIB_UBUNTU_NVIDIA_KERNEL` (default: the `ubuntu-nvidia-kernel` element's) are
what the checks expect on the nodes.
