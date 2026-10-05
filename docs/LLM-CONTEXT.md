# Local-LLM context: RHEL 9 NVIDIA R580 air-gap installation

## Purpose

This document gives an offline assistant enough authoritative local context to
help an operator build, import, install, validate, and troubleshoot this exact
NVIDIA deployment without Internet access. The assistant must also inspect the
current scripts, `MANIFEST.txt`, `SHA256SUMS`, and generated TSV records. This
document never overrides evidence from the actual host or bundle.

## Fixed deployment facts

```text
Operating system: RHEL 9.8
Selected kernel: 5.14.0-687.51.1.el9_8.x86_64
Older rollback kernel: 5.14.0-611.*.el9_7.x86_64
GPU hardware: 6x NVIDIA RTX PRO 6000 Blackwell
Compute capability: 12.0
Driver branch: R580
Driver version: 580.178.04
Kernel module: Open
Build mechanism: DKMS
DNF module stream: nvidia-driver:580-open
Expected GPU count: 6
```

The operator chose the newer installed RHEL 9.8 kernel. Do not direct the
installation at the older `611` kernel unless the operator explicitly changes
the approved target and rebuilds the dependency repository.

## Workload boundary

MATLAB R2026a with `gpuArray`, Parallel Computing Toolbox, and Deep Learning
Toolbox needs the NVIDIA driver but not a separately installed CUDA Toolkit.
MATLAB bundles its own CUDA runtime for those workflows.

CUDA Toolkit 12.8, cuDNN, and TensorRT are separate requirements only for such
work as GPU Coder, `mexcuda`, or external CUDA compilation. They are not part
of this repository. Never recommend CUDA 13.4 for this R2026a deployment and do
not enable `parallel.gpu.enableCUDAForwardCompatibility`.

## Why Open-DKMS is used

The NVIDIA RHEL 9 precompiled status page contains a `kernel-core` row for
`5.14.0-687.51.1.el9_8.x86_64`, but no exact R580 `kmod-nvidia` row. NVIDIA's
R580 `580-open` modular stream contains `kmod-nvidia-open-dkms`. The repository
does not currently provide a non-DKMS `kmod-nvidia-open` for this kernel.

The generic kernel-specific package named `kmod-nvidia` is not accepted as the
Open flavor by this project. Never substitute it merely to avoid installing a
compiler.

## Repository layout

The generated transport bundle contains:

```text
drivers/   signed NVIDIA R580.178.04 RPMs and upstream module metadata
os-deps/   exact RHEL/EPEL DKMS build dependencies and local repo metadata
```

The client repository IDs are:

```text
nvidia-r580-internal
nvidia-r580-os-deps
```

The exact kernel packages required are:

```text
kernel-devel-5.14.0-687.51.1.el9_8.x86_64
kernel-headers-5.14.0-687.51.1.el9_8.x86_64
```

The dependency repository also carries the resolved closure for:

```text
gcc
make
dkms
elfutils-libelf-devel
python3-dnf-plugin-versionlock
mokutil
pciutils
```

## NVIDIA package invariants

All driver-versioned packages must be exactly `580.178.04`. Important package
names include:

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

Despite their names, `nvidia-driver-cuda` and `nvidia-driver-cuda-libs` are
driver-side compute components; they are not the CUDA Toolkit.

## Evidence hierarchy

Use sources in this order:

1. Current host output: `uname -r`, RPM database, DKMS state, journal, services,
   PCI enumeration, Secure Boot state, and `nvidia-smi`.
2. The generated bundle's `MANIFEST.txt`, `SHA256SUMS`, TSV records, and DNF
   metadata.
3. Current scripts in the transported bundle.
4. This context file and `INSTALL.md`.
5. Historical tickets or recollections.

If evidence conflicts, state the conflict. Do not guess, silently normalize a
kernel string, or claim success based only on package installation.

## Non-negotiable safety boundaries

- Never install the NVIDIA `.run` file over an RPM installation.
- Never substitute a proprietary kmod for the approved Open module.
- Never mix NVIDIA kernel-module and userspace versions.
- Never build against a `kernel-devel` version different from `uname -r`.
- Never disable Secure Boot as a troubleshooting shortcut.
- Never generate or enroll a module-signing key without the approved process.
- Never upload Red Hat entitlement certificates, CDN client keys, credentials,
  private keys, or internal host evidence. Vendor RPMs are carried only in the
  versioned release bundle and retain their original licenses and terms.
- Never install CUDA Toolkit, cuDNN, TensorRT, or MATLAB unless the change scope
  explicitly includes those products.
- Never let a normal kernel update bypass the kernel versionlock.
- Never report the six-GPU installation as successful without `nvidia-smi`
  evidence after reboot.

## Normal installation decision tree

```text
Does lspci show NVIDIA hardware?
  no  -> stop and investigate hardware/firmware/PCIe enumeration
  yes -> is uname -r exactly 5.14.0-687.51.1.el9_8.x86_64?
           no  -> boot the pinned target kernel; do not install
           yes -> are both internal repositories enabled?
                    no  -> fix repository publication/configuration
                    yes -> does the bundle contain exact kernel-devel/headers?
                             no  -> rebuild on an entitled staging host
                             yes -> is Secure Boot enabled?
                                      yes -> verify approved module-signing path
                                      no/handled -> run client installer with
                                                    --dkms-fallback
```

## Pre-installation evidence

Collect:

```bash
cat /etc/redhat-release
uname -r
rpm -q kernel-core
lspci -nn | grep -i nvidia
mokutil --sb-state
dnf repolist --enabled
dnf module list nvidia-driver
rpm -qa | grep -E '^(nvidia|libnvidia|kmod-nvidia|cuda)' | sort
```

Stop for review if another NVIDIA installation already exists. Mixing a `.run`
installation with RPM packages commonly creates driver/library mismatches.

## Install command

```bash
sudo ./client-install.sh \
  --kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --dkms-fallback
```

The flag is intentionally explicit because the compiler, development headers,
and DKMS change the accredited package baseline.

## Validation evidence

After reboot, collect:

```bash
uname -r
dkms status
nvidia-smi
nvidia-smi --query-gpu=index,name,driver_version,pci.bus_id --format=csv
systemctl is-enabled nvidia-persistenced
systemctl is-active nvidia-persistenced
modinfo -F version nvidia
modinfo -F license nvidia
modinfo -F vermagic nvidia
dnf versionlock list
journalctl -b -k | grep -Ei 'nvidia|nvrm|xid'
```

Success requires all of the following:

```text
running kernel = 5.14.0-687.51.1.el9_8.x86_64
driver version = 580.178.04
GPU count = 6
GPU model = RTX PRO 6000
persistence service = enabled and active
kernel packages = versionlocked
no persistent NVRM/XID errors
```

## Troubleshooting map

### Installer refuses the kernel

Cause: the host booted the older `611` kernel or another update.

Actions:

```bash
uname -r
grubby --default-kernel
rpm -q kernel-core
```

Boot the exact target kernel. Do not override the installer guard.

### Exact kernel-devel is unavailable

Cause: the staging repository omitted an older RHEL erratum, the wrong minor
release is enabled, or the internal sync did not retain the package.

Required remedy: obtain the exact Red Hat-signed RPM through an entitled RHEL
source and rebuild `os-deps/`. Do not use a similarly named package from
another distribution.

### DKMS build fails

Collect:

```bash
dkms status
rpm -q "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)"
test -d "/usr/src/kernels/$(uname -r)" && echo present
find /var/lib/dkms/nvidia -name make.log -type f -print
journalctl -b -k | grep -Ei 'nvidia|lockdown|verification|secure'
```

Read the relevant `make.log`; do not repeatedly reinstall packages without
identifying the compilation or signing error.

### Module signature or lockdown failure

Cause: Secure Boot rejected the locally built module.

Actions: capture `mokutil --sb-state`, kernel logs, module signer information,
and the approved signing procedure. Do not disable Secure Boot and do not
invent a new MOK workflow.

### `nvidia-smi` reports driver/library mismatch

Cause: old modules remain loaded while new userspace is installed, or package
versions were mixed.

Actions:

```bash
cat /proc/driver/nvidia/version 2>/dev/null || true
modinfo -F version nvidia
rpm -qa | grep -E '^(nvidia|libnvidia|kmod-nvidia)' | sort
```

If the transaction is otherwise consistent, reboot into the pinned kernel.
Do not layer another driver over the current installation.

### Fewer than six GPUs appear

Collect:

```bash
lspci -nn | grep -i nvidia
nvidia-smi -L
nvidia-smi topo -m
journalctl -b -k | grep -Ei 'nvidia|nvrm|xid|pcie|aer'
```

If `lspci` also sees fewer than six devices, investigate firmware, PCIe slot,
power, riser, and hardware state before changing the driver.

### DNF module stream is not visible

Actions:

```bash
dnf clean all
dnf repolist --enabled
dnf module list nvidia-driver
test -s /path/to/drivers/repodata/repomd.xml
```

The builder injects upstream `modules.yaml`; copying only RPMs without
`repodata/` breaks modular resolution.

## Kernel update cycle

```text
remove versionlocks
-> add the new kernel and exact kernel-devel/kernel-headers to a newly built bundle
-> install them together
-> verify DKMS build for the new kernel
-> reboot
-> prove six GPUs and driver health
-> reapply versionlocks
```

The old `611` kernel may remain as an OS rollback, but NVIDIA is not guaranteed
to work under it unless DKMS was separately built for that exact kernel.

## Change-record summary template

Record:

```text
bundle build date and SHA-256
Git commit/tag of this tooling
target uname -r
kernel-devel and kernel-headers NEVRAs
NVIDIA driver version
RPM signature-verification result
Secure Boot state and approved signing path
DNF transaction ID
DKMS status
post-reboot six-GPU nvidia-smi output
kernel versionlock state
rollback kernel retained
```
