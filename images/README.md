# Node images

carrack's node image is built with [diskimage-builder](https://opendev.org/openstack/diskimage-builder)
(DIB) on top of [vexxhost/capo-image-elements](https://github.com/vexxhost/capo-image-elements),
which provides the Kubernetes elements (kubeadm, kubelet, containerd, ...).
carrack's own elements live in [`elements/`](elements/).

| Image | Elements |
|-------|----------|
| `ubuntu-24.04-nvidia-<kubernetes minor>.qcow2`, e.g. `ubuntu-24.04-nvidia-1-36.qcow2` | `vm ubuntu-minimal block-device-kubernetes kubernetes ubuntu-nvidia-kernel` |

## Building locally

Needs a Linux host (DIB's chroot build has no macOS equivalent), [uv](https://docs.astral.sh/uv/)
and working sudo. Run as a normal user; DIB calls sudo itself where needed.

```bash
uv sync --locked --project images
sudo apt-get install -y $(uv run --locked --project images bindep -b -f images/bindep.txt)

images/build.sh                              # Kubernetes from images/kubernetes-version
KUBERNETES_VERSION=1.36.4 images/build.sh    # another version

sudo images/check.sh images/output/ubuntu-24.04-nvidia-1-36.qcow2
```

`check.sh` takes its expectations from the `ubuntu-nvidia-kernel` element's defaults.
If you built with other values, pass them explicitly (sudo drops `DIB_*` variables):
`sudo images/check.sh --kernel 6.8.0-1070-nvidia --nvidia-fs 0 <image>`.

`TMPDIR` sets where DIB works; point it at a large disk if `/tmp` is small (add
`DIB_NO_TMPFS=1` if RAM is short).

`check.sh` inspects the image with libguestfs, without booting it.

## CI

[`.github/workflows/images.yaml`](../.github/workflows/images.yaml):

- **Pull requests** touching `images/**` build the image and run `check.sh`.
- **Pushes to main** and manual runs on main (`workflow_dispatch`, with an optional
  Kubernetes version) also publish it to the rolling
  [`latest-images`](https://github.com/Infraloop-cloud/carrack/releases/tag/latest-images)
  release. Manual runs on other branches only build and check.

> **For testing only.** Images in the `latest-images` release are CI builds meant
> for trying carrack out. They are replaced without notice, have no history and
> carry no support or update guarantees. For anything beyond testing, build your
> own images with `build.sh`.

The release holds one image per Kubernetes minor version, replaced by every build
from main; its tag points at the commit the images were built from.

```bash
curl -LO https://github.com/Infraloop-cloud/carrack/releases/download/latest-images/ubuntu-24.04-nvidia-1-36.qcow2
curl -LO https://github.com/Infraloop-cloud/carrack/releases/download/latest-images/ubuntu-24.04-nvidia-1-36.qcow2.sha256
sha256sum -c ubuntu-24.04-nvidia-1-36.qcow2.sha256
```

Both URLs can be given to Metal3/Ironic directly as the image URL and checksum URL.
The image is unavailable for the duration of an upload, and its checksum changes
with every build.

## Versions

- **capo-image-elements**: `CAPO_IMAGE_ELEMENTS_REF` in `build.sh`, a commit SHA.
  Its HEAD moves; bump deliberately.
- **diskimage-builder**: `pyproject.toml` / `uv.lock` (`uv lock --project images`).
