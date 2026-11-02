# SPDX-License-Identifier: Apache-2.0
#
# NVIDIA kernel version to install and hold, see install.d/50-ubuntu-nvidia-kernel.
export DIB_UBUNTU_NVIDIA_KERNEL=${DIB_UBUNTU_NVIDIA_KERNEL:-6.8.0-1062-nvidia}
# Also install Canonical's prebuilt GPUDirect Storage module for that kernel
# (linux-modules-nvidia-fs-<kernel>).
export DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS=${DIB_UBUNTU_NVIDIA_KERNEL_NVIDIA_FS:-1}

# Enable Ubuntu's "restricted" component in the apt sources ubuntu-minimal
# writes (release, -updates, -security, -backports): linux-modules-nvidia-fs-*
# and the NVIDIA driver packages only exist there. Without it apt can resolve
# e.g. nvidia-dkms-580-server-open to an unrelated virtual package.
#
# Sorts after ubuntu-common's 10-ubuntu-distro-name.bash, which defaults
# DIB_DEBIAN_COMPONENTS to main,universe; components chosen by the user are
# kept.
case ",${DIB_DEBIAN_COMPONENTS:-main,universe}," in
    *,restricted,*)
        ;;
    *)
        export DIB_DEBIAN_COMPONENTS="${DIB_DEBIAN_COMPONENTS:-main,universe},restricted"
        ;;
esac
