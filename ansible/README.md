# carrack.capm3

An Ansible collection that deploys a first Kubernetes cluster onto bare-metal
machines with [Cluster API](https://cluster-api.sigs.k8s.io/) and
[Metal3](https://metal3.io/) (CAPM3), using carrack's node images (see
[`images/`](../images/)).

It runs everything from the machine you run Ansible on:

1. **tools**: downloads pinned, checksum-verified kind, kubectl, clusterctl
   and helm into `~/.carrack/bin`.
2. **bootstrap**: creates a temporary [kind](https://kind.sigs.k8s.io/)
   cluster, with Ironic's ports published on your machine's provisioning
   address.
3. **metal3**: installs Cluster API, CAPM3 and IPAM (clusterctl), Ironic
   (ironic-standalone-operator) and the Bare Metal Operator into it.
4. **hosts**: enrolls your machines as BareMetalHosts, which Ironic inspects
   through their BMCs (Redfish virtual media).
5. **cluster**: creates the cluster: CAPM3 writes the image to every host,
   kubeadm initialises the control plane and the workers join. Saves its
   admin kubeconfig to `~/.carrack/<cluster>.kubeconfig`.
6. **cni**: installs [Kube-OVN](https://kubeovn.github.io/).

Moving Cluster API and Metal3 into the new cluster, so that it manages itself
and the bootstrap cluster can go, is planned.

## Requirements

- x86_64 Linux with Docker, usable without sudo.
- ansible-core 2.20 or later, the `kubernetes.core` collection and its Python
  libraries (`kubernetes`, `jsonpatch`, `requests-oauthlib`).
- Machines whose BMCs support Redfish virtual media, on a network your
  machine can reach and where Ironic, on your machine, can reach them.
- A carrack node image and its `.sha256`, served over HTTP(S) to the
  machines (for example the
  [`latest-images`](https://github.com/Infraloop-cloud/carrack/releases/tag/latest-images)
  release, for testing).
- Optionally `GITHUB_TOKEN` in the environment: clusterctl reads provider
  releases from the GitHub API, which rate-limits anonymous clients.

## Install

```bash
ansible-galaxy collection install \
  'git+https://github.com/Infraloop-cloud/carrack.git#/ansible,main'
```

## Use

Describe the cluster in a vars file, `cluster.yml`:

```yaml
capm3_ironic_ip: 192.168.150.1                 # your machine, on the provisioning network
capm3_kubernetes_version: 1.36.5                # the one in the image
capm3_image_url: https://example.com/ubuntu-24.04-nvidia-1-36.qcow2
capm3_image_checksum_url: https://example.com/ubuntu-24.04-nvidia-1-36.qcow2.sha256
capm3_control_plane_endpoint: 192.168.150.20    # the control-plane host's address
capm3_ssh_authorized_keys:
  - ssh-ed25519 AAAA... you@example.com
capm3_hosts:
  - name: node-0
    role: control-plane
    boot_mac: 52:54:00:ca:7a:20
    bmc:
      address: redfish-virtualmedia+https://10.0.0.10/redfish/v1/Systems/1
      username: admin
      password: "{{ vault_node_0_bmc_password }}"
  - name: node-1
    role: worker
    boot_mac: 52:54:00:ca:7a:21
    root_device_hints:
      deviceName: /dev/nvme0n1
    bmc:
      address: redfish-virtualmedia+https://10.0.0.11/redfish/v1/Systems/1
      username: admin
      password: "{{ vault_node_1_bmc_password }}"
```

Keep BMC passwords out of plain text, for example with
[Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html).

```bash
ansible-playbook carrack.capm3.deploy -e @cluster.yml
kubectl --kubeconfig ~/.carrack/carrack.kubeconfig get nodes
```

The playbook can be run again: it skips what already exists.
`ansible-playbook carrack.capm3.destroy -e @cluster.yml` deletes the bootstrap
cluster. Until the cluster manages itself, that leaves nothing to replace
failed machines or manage the hosts.

### Hosts

Every host in `capm3_hosts` becomes a node. Fields:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | The BareMetalHost's name, also the node's. |
| `role` | yes | `control-plane` (exactly one) or `worker`. |
| `boot_mac` | yes | MAC address of the NIC the host boots from. |
| `bmc.address` | yes | The BMC's Metal3 address, e.g. `redfish-virtualmedia+https://<bmc>/redfish/v1/Systems/<id>`. |
| `bmc.username`, `bmc.password` | yes | BMC credentials. |
| `bmc.disable_certificate_verification` | no | Skip TLS verification of the BMC (default `false`). |
| `boot_mode` | no | `UEFI` (default) or `UEFISecureBoot`. |
| `root_device_hints` | no | Which disk to write the image to, as [Metal3 root device hints](https://book.metal3.io/bmo/root_device_hints) (e.g. `deviceName: /dev/vda`). |
| `automated_cleaning_mode` | no | `metadata` (default) or `disabled`. |

The hosts get their addresses from DHCP on their network; the control-plane
host's address must be fixed, as `capm3_control_plane_endpoint`.

### Settings

The main settings, with their defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `capm3_cluster_name` | `carrack` | The cluster's name. |
| `capm3_namespace` | `carrack` | Namespace of the cluster and its hosts in the bootstrap cluster. |
| `capm3_work_dir` | `~/.carrack` | Tools, rendered manifests and kubeconfigs. |
| `capm3_ssh_user` | `carrack` | User created on every node for `capm3_ssh_authorized_keys`, with passwordless sudo. |
| `capm3_pod_cidr`, `capm3_service_cidr` | `10.16.0.0/16`, `10.96.0.0/12` | The cluster's networks (Kube-OVN's defaults). |
| `capm3_ironic_extra_kernel_params` | | Kernel parameters for Ironic's agent, e.g. a serial console. |
| `capm3_host_wait_abort_command` | | Shell command that detects host failures the BareMetalHosts don't show (see the `baremetalhost_wait` module). |

Every pinned version and checksum is a role default, in `roles/*/defaults/main.yml`.

## Testing

[`tests/cluster`](../tests/cluster/) runs this collection against emulated
bare-metal machines (libvirt VMs behind sushy-tools' Redfish) in CI, and checks
the result with testinfra.
