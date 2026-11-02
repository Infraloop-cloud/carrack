====================
ubuntu-nvidia-kernel
====================

Installs and holds a specific NVIDIA-optimized Ubuntu kernel (``linux-image-*-nvidia``)
alongside the kernel installed by ``ubuntu-minimal``, and enables Ubuntu's
``restricted`` archive component.

Kernel
------

The kernel image and headers are installed at an exact version and held with
``apt-mark hold``, so ``apt upgrade`` on a node never moves it. The metapackage
(``linux-image-nvidia-<series>``) is deliberately not used: components keyed on the
kernel version, such as the NVIDIA network-operator kernel allowlist, would silently
break after an unplanned kernel upgrade. Upgrading the kernel is a new image.

The hook runs as ``install.d/50-``, before elements building DKMS modules (Mellanox
OFED, NVIDIA driver, ...), so their modules get built for this kernel too.

The ``ubuntu-minimal`` kernel stays installed as a fallback boot entry. GRUB boots
the highest version; the build prints a warning if that is not the NVIDIA kernel.
Confirm with ``uname -r`` on first boot.

Restricted component
--------------------

``restricted`` is appended to ``DIB_DEBIAN_COMPONENTS`` (``ubuntu-common`` defaults
it to ``main,universe``), so the sources ``ubuntu-minimal`` writes for the release,
``-updates``, ``-security`` and ``-backports`` pockets include it. Components already
set by the user are kept. ``linux-modules-nvidia-fs-*`` and the NVIDIA driver packages
live in ``restricted``.

Environment variables
---------------------

``DIB_UBUNTU_NVIDIA_KERNEL``
  :Required: No
  :Default: ``6.8.0-1062-nvidia``
  :Description: Kernel version to install and hold
    (``linux-image-<version>``, ``linux-headers-<version>``).

``DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS``
  :Required: No
  :Default: ``1``
  :Description: Set to ``0`` to skip ``linux-modules-nvidia-fs-<version>``,
    Canonical's prebuilt GPUDirect Storage module for the kernel.
