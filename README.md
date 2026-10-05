# NVIDIA R580 Open-DKMS air-gap repository for RHEL 9

This public repository builds a complete offline DNF bundle for the planned
six-GPU RHEL 9.8 server:

| Item | Pinned value |
|---|---|
| Target kernel | `5.14.0-687.51.1.el9_8.x86_64` |
| GPU family | NVIDIA RTX PRO 6000 Blackwell |
| Driver branch | R580 |
| Driver version | `580.178.04` |
| Kernel-module flavor | Open |
| Build method | DKMS |
| DNF module stream | `nvidia-driver:580-open` |
| Expected GPU count | 6 |

The generated bundle contains two local repositories:

1. `drivers/` — signed NVIDIA R580.178.04 Open-DKMS and matching userspace RPMs.
2. `os-deps/` — the exact Red Hat `kernel-devel` RPM plus the RHEL/EPEL build
   dependencies needed when the target does not already have them.

It intentionally excludes the CUDA Toolkit, cuDNN, TensorRT, MATLAB, license
files, credentials, subscription certificates, and private environment data.
MATLAB R2026a `gpuArray`, Parallel Computing Toolbox, and Deep Learning Toolbox
use MATLAB's bundled CUDA runtime and need the compatible NVIDIA driver only.

## Download the ready-built bundle

The ready-built payload is published as a GitHub Release asset because several
RPMs exceed GitHub's normal per-file Git limit. It is part of this repository's
release, but it is intentionally not committed into Git history.

```bash
gh release download v2026.10.05-r580.178.04 \
  --repo BenjaminSisko/nvidia-r580-rhel9-airgap \
  --pattern 'nvidia-r580-rhel9-687.51.1-20261005.tar.gz*'

sha256sum -c nvidia-r580-rhel9-687.51.1-20261005.tar.gz.sha256
tar -xzf nvidia-r580-rhel9-687.51.1-20261005.tar.gz
```

That release contains 18 NVIDIA RPMs and 258 RHEL/EPEL dependency RPMs,
including the actual exact packages:

```text
kernel-devel-5.14.0-687.51.1.el9_8.x86_64.rpm
kernel-headers-5.14.0-687.51.1.el9_8.x86_64.rpm
kmod-nvidia-open-dkms-580.178.04-1.el9.noarch.rpm
```

No Red Hat entitlement certificate, CDN client key, password, token, private
key, host evidence, or internal URL is included. Vendor RPMs retain their own
licenses and terms; an operator must confirm that their organization is
authorized to use and redistribute the binary payload before mirroring it.

## Rebuild the payload

The connected builder must be an entitled RHEL 9 host with access to the
matching BaseOS/AppStream repositories and EPEL. The output under `dist/` is a
transport artifact and is ignored by Git.

## Build

On a connected, entitled RHEL 9 staging host:

```bash
sudo dnf install -y \
  curl createrepo_c dnf-plugins-core gnupg2 xorriso rpm-build

sudo ./scripts/build-driver-repo.sh --dry-run

sudo ./scripts/build-driver-repo.sh \
  --target-kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --driver-version 580.178.04
```

The non-dry build fails with exit code 42 unless the enabled entitled
RHEL/EPEL repositories can supply all required packages, including:

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

Every RPM signature is checked before repository metadata, checksums, the
tarball, or ISO is created.

## Import to the air-gapped repository server

After the approved optical-media transfer:

```bash
sudo ./repo-server-import.sh \
  --source /mnt/nvidia-media \
  --destination /srv/repos/nvidia-r580
```

Publish both directories through the existing internal repository service:

```text
/srv/repos/nvidia-r580/drivers/
/srv/repos/nvidia-r580/os-deps/
```

Adapt `nvidia-r580-internal.repo.example` to the approved internal HTTPS URL.

## Install on the GPU server

Boot the target kernel first and prove it:

```bash
uname -r
# expected: 5.14.0-687.51.1.el9_8.x86_64
```

Then use the explicit Open-DKMS path:

```bash
sudo ./client-install.sh \
  --kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --dkms-fallback
```

The installer refuses the older RHEL 9.7 kernel, refuses a proprietary NVIDIA
kmod, verifies the exact `kernel-devel` match, enables `nvidia-persistenced`,
and version-locks installed kernel packages. If Secure Boot is enabled, use the
site-approved module-signing process; the scripts never generate or enroll a
MOK.

After reboot:

```bash
sudo ./client-install.sh --validate --expected-gpus 6
```

Expected result: six GPUs and NVIDIA driver `580.178.04`.

## Documentation

- [Full installation procedure](docs/INSTALL.md)
- [Local-LLM context and troubleshooting boundaries](docs/LLM-CONTEXT.md)
- [Required package manifest](PACKAGE-MANIFEST.md)
- [2026-10-05 release build and verification record](docs/BUILD-RECORD-2026-10-05.md)
- [Security and disclosure policy](SECURITY.md)

## Source authorities

- [NVIDIA RHEL 9 package repository](https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/)
- [NVIDIA RHEL 9 precompiled-kmod status](https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/precompiled/)
- [NVIDIA Open GPU Kernel Modules installation guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/latest/kernel-modules.html)
- Red Hat Customer Portal and the organization's entitled RHEL repositories

## License

The automation and documentation in this repository are licensed under the MIT
License. Downloaded RPMs retain their vendors' licenses and redistribution
terms; the MIT License does not apply to them.
