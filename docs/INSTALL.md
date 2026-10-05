# Installation and air-gap transfer procedure

## 1. Scope

This procedure prepares and installs NVIDIA R580.178.04 Open-DKMS for:

```text
RHEL: 9.8
Kernel: 5.14.0-687.51.1.el9_8.x86_64
GPU: 6x NVIDIA RTX PRO 6000 Blackwell
Workload: MATLAB 2026 driver-only use
```

The machine also has an older `5.14.0-611.*.el9_7` kernel. Keep it as an
operating-system rollback kernel, but boot the `687.51.1` kernel before the
NVIDIA installation. The installer intentionally refuses the older kernel.

## 2. Package decision

NVIDIA's RHEL 9 status page lists the target kernel but no exact precompiled
R580 kmod for it. NVIDIA's R580 Open stream supplies
`kmod-nvidia-open-dkms`, not a precompiled-open RPM. Therefore this build uses:

```text
nvidia-driver:580-open
kmod-nvidia-open-dkms-580.178.04-1.el9.noarch
matching NVIDIA userspace 580.178.04
exact kernel-devel and kernel-headers for uname -r
```

Do not substitute the proprietary `kmod-nvidia` package.

## 3. Connected staging host

Use a connected, entitled RHEL 9 host. It must have access to:

- NVIDIA's public RHEL 9 CUDA repository
- Red Hat BaseOS and AppStream containing the target kernel packages
- EPEL 9 containing DKMS

Install builder prerequisites:

```bash
sudo dnf install -y \
  curl createrepo_c dnf-plugins-core gnupg2 xorriso rpm-build
```

Confirm the exact Red Hat packages are available:

```bash
dnf repoquery --available \
  kernel-devel-5.14.0-687.51.1.el9_8.x86_64

dnf repoquery --available \
  kernel-headers-5.14.0-687.51.1.el9_8.x86_64
```

If either query has no result, stop. Do not use a Rocky Linux, AlmaLinux, or
different RHEL kernel-devel RPM.

Run the metadata and dependency availability check:

```bash
sudo ./scripts/build-driver-repo.sh \
  --target-kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --driver-version 580.178.04 \
  --dry-run
```

Then build:

```bash
sudo ./scripts/build-driver-repo.sh \
  --target-kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --driver-version 580.178.04
```

The build fails rather than producing a partial bundle when:

- the NVIDIA signing-key fingerprint changes;
- R580.178.04 Open-DKMS is missing;
- any exact-version NVIDIA userspace RPM is missing;
- target `kernel-devel` or `kernel-headers` is unavailable;
- any required RHEL/EPEL dependency cannot resolve;
- an RPM signature fails verification; or
- module metadata lacks `580-open`.

## 4. Inspect the generated output

The build creates `dist/nvidia-r580-driver-repo-YYYYMMDD/` with:

```text
repo-bundle/
├── drivers/                       NVIDIA DNF repository
├── os-deps/                       RHEL/EPEL dependency DNF repository
├── keys/                          Red Hat and EPEL public RPM signing keys
├── NVIDIA-GPG-KEY-D42D0685.pub
├── COVERAGE.txt
├── DRIVER_SETS.tsv
├── DKMS_FALLBACK_SETS.tsv
├── OS_DEPENDENCIES.tsv
├── MANIFEST.txt
├── SHA256SUMS
├── README.md
├── INSTALL.md
├── LLM-CONTEXT.md
├── client-install.sh
├── repo-server-import.sh
└── nvidia-r580-internal.repo.example
```

There is also a deterministic tarball and, by default, an ISO plus sidecar
SHA-256 files.

Review these records before burning media:

```bash
less repo-bundle/MANIFEST.txt
column -ts $'\t' repo-bundle/OS_DEPENDENCIES.tsv
column -ts $'\t' repo-bundle/DKMS_FALLBACK_SETS.tsv
(cd repo-bundle && sha256sum -c SHA256SUMS)
```

Confirm the manifest includes exactly:

```text
kernel-devel-5.14.0-687.51.1.el9_8.x86_64
kernel-headers-5.14.0-687.51.1.el9_8.x86_64
kmod-nvidia-open-dkms-580.178.04-1.el9.noarch
```

For this pinned build, the tarball and its sidecar checksum are also published
as the `v2026.10.05-r580.178.04` GitHub Release assets. Release assets keep the
large vendor RPMs out of Git history while making the complete repository
bundle downloadable as one verified object.

## 5. Burn and transfer

Record the ISO sidecar checksum in the change record. Burn the ISO using the
approved optical-media process, then verify the burned media against that
checksum before it crosses the air gap.

## 6. Import on the air-gapped repository server

Mount the disc and run:

```bash
sudo ./repo-server-import.sh \
  --source /mnt/nvidia-media \
  --destination /srv/repos/nvidia-r580
```

The importer verifies SHA-256 hashes first, then NVIDIA signatures using the
pinned NVIDIA key and Red Hat/EPEL signatures using the repository server's
installed trust store. It will not overwrite a non-empty destination unless
`--allow-existing` is explicitly supplied.

Publish both paths using the existing approved HTTP/TLS repository service:

```text
/srv/repos/nvidia-r580/drivers/
/srv/repos/nvidia-r580/os-deps/
```

This tool does not alter Apache/Nginx, TLS, DNS, firewalls, SELinux labels, or
repository-server authentication.

## 7. Configure the GPU server

Install the three public verification keys from the bundle through
configuration management:

```text
/etc/pki/rpm-gpg/NVIDIA-GPG-KEY-D42D0685.pub
/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
/etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9
```

Adapt `config/nvidia-r580-internal.repo.example` to the approved internal URLs
and install it as:

```text
/etc/yum.repos.d/nvidia-r580-internal.repo
```

Verify both repository IDs:

```bash
dnf repolist --enabled | grep -E \
  'nvidia-r580-internal|nvidia-r580-os-deps'

dnf module list nvidia-driver
```

## 8. Select and boot the target kernel

Confirm the target image exists:

```bash
test -f /boot/vmlinuz-5.14.0-687.51.1.el9_8.x86_64
```

Make it the default:

```bash
sudo grubby --set-default \
  /boot/vmlinuz-5.14.0-687.51.1.el9_8.x86_64

sudo grubby --default-kernel
sudo reboot
```

After reboot:

```bash
uname -r
```

Do not continue unless the output is exactly:

```text
5.14.0-687.51.1.el9_8.x86_64
```

## 9. Secure Boot decision

Check before installing:

```bash
mokutil --sb-state
```

If Secure Boot is enabled, use the organization's approved DKMS module-signing
and key-enrollment procedure. This project never creates a private signing key,
disables Secure Boot, or enrolls a MOK.

## 10. Install the driver

Run:

```bash
sudo ./client-install.sh \
  --kernel 5.14.0-687.51.1.el9_8.x86_64 \
  --dkms-fallback
```

The explicit flag is required because DKMS installs a compiler and build
toolchain on the accredited host. The script:

1. Confirms NVIDIA PCI devices exist.
2. Refuses any kernel except the pinned target.
3. Confirms both offline repositories are enabled.
4. Selects only an R580 open-licensed DKMS package.
5. Installs build dependencies from `nvidia-r580-os-deps` only.
6. Verifies installed `kernel-devel` exactly equals `uname -r`.
7. Installs exact matching NVIDIA userspace.
8. Enables `nvidia-persistenced`.
9. Applies DNF versionlocks to installed kernel packages.

Review `dkms status` before accepting the reboot:

```bash
dkms status
```

Expected kernel association:

```text
nvidia/580.178.04, 5.14.0-687.51.1.el9_8.x86_64, x86_64: installed
```

## 11. Reboot and validate

```bash
sudo reboot
sudo ./client-install.sh --validate --expected-gpus 6
```

Additional evidence:

```bash
uname -r
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

Acceptance criteria:

- running kernel is `5.14.0-687.51.1.el9_8.x86_64`;
- driver version is `580.178.04`;
- six RTX PRO 6000 GPUs are visible;
- no persistent NVRM/XID errors exist;
- persistence service is enabled and active; and
- kernel packages are versionlocked.

MATLAB validation, after MATLAB is installed and licensed:

```matlab
gpuDeviceTable
gpuDevice(1)
```

Expect six GPUs and Compute Capability 12.0. Do not enable
`parallel.gpu.enableCUDAForwardCompatibility`.

## 12. Patch cycle

Do not let a kernel update outrun the DKMS prerequisites:

```text
approve change
-> remove kernel versionlocks
-> add the new kernel and exact matching kernel-devel/kernel-headers to the bundle
-> install the kernel and development packages together
-> verify DKMS build
-> reboot
-> validate six GPUs
-> reapply versionlocks
```

## 13. Rollback

Retain the older RHEL 9.7 kernel as a bootable OS rollback. Unless its exact
development packages are also installed and DKMS is built for it, the NVIDIA
driver is not expected to operate when booted into that older kernel.

If the new driver fails, select the old kernel from GRUB, restore service
without GPU functionality, capture the DNF history transaction and journal
evidence, and follow the approved rollback/change process.
