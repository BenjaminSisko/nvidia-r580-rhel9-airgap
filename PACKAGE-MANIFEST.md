# Required package manifest

## Target

```text
Kernel: 5.14.0-687.51.1.el9_8.x86_64
Driver: 580.178.04
Stream: nvidia-driver:580-open
Mode: Open-DKMS
```

## NVIDIA repository content

All driver-versioned packages must resolve to exactly `580.178.04`:

```text
kmod-nvidia-open-dkms
libnvidia-cfg
libnvidia-fbc
libnvidia-gpucomp
libnvidia-ml
nvidia-driver
nvidia-driver-cuda
nvidia-driver-cuda-libs
nvidia-driver-libs
nvidia-kmod-common
nvidia-libXNVCtrl
nvidia-libXNVCtrl-devel
nvidia-modprobe
nvidia-persistenced
nvidia-settings
nvidia-xconfig
xorg-x11-nvidia
dnf-plugin-nvidia
```

The first 17 names reproduce NVIDIA's upstream `580-open/default` module
profile. `dnf-plugin-nvidia` is included in addition to the profile.

`nvidia-driver-cuda` and `nvidia-driver-cuda-libs` are driver-side compute
components. They are not the CUDA Toolkit.

## RHEL/EPEL dependency repository content

The builder resolves and downloads these packages and all dependencies:

```text
kernel-devel-5.14.0-687.51.1.el9_8.x86_64
kernel-headers-5.14.0-687.51.1.el9_8.x86_64
gcc
make
dkms
elfutils-libelf-devel
python3-dnf-plugin-versionlock
mokutil
pciutils
```

The generated `MANIFEST.txt` and `OS_DEPENDENCIES.tsv` contain the actual RPM
filenames and hashes used for a particular build.

## Deliberately excluded

```text
CUDA Toolkit
cuDNN
TensorRT
MATLAB
NVIDIA .run installer
proprietary kmod-nvidia
subscription credentials
private module-signing keys
```
