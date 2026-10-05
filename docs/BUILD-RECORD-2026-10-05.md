# Build record: 2026-10-05 R580 air-gap bundle

## Result

```text
Release tag: v2026.10.05-r580.178.04
Asset: nvidia-r580-rhel9-687.51.1-20261005.tar.gz
SHA-256: published in the adjacent .sha256 release asset
Compressed size: approximately 488 MiB
Target kernel: 5.14.0-687.51.1.el9_8.x86_64
NVIDIA stream: nvidia-driver:580-open
NVIDIA version: 580.178.04
Kernel-module path: Open-DKMS
NVIDIA RPM count: 18
RHEL/EPEL dependency RPM count: 258
```

## Package sources

- NVIDIA RPMs, module metadata, and public signing key came from NVIDIA's
  public RHEL 9 x86_64 CUDA repository.
- The exact RHEL 9.8 kernel packages and their Red Hat dependencies came from
  Red Hat CDN access on the entitled connected repository staging server.
- DKMS and its EPEL dependencies came from EPEL 9 Everything.
- Cross-major access on the RHEL 8.10 staging server used an ephemeral RHEL 9
  repository definition. It did not change the server's enabled repositories,
  installed packages, subscription identity, or system RPM trust database.

## Required exact files observed in the bundle

```text
repo-bundle/drivers/kmod-nvidia-open-dkms-580.178.04-1.el9.noarch.rpm
repo-bundle/os-deps/kernel-devel-5.14.0-687.51.1.el9_8.x86_64.rpm
repo-bundle/os-deps/kernel-headers-5.14.0-687.51.1.el9_8.x86_64.rpm
```

## Verification completed

- All 18 NVIDIA RPM signatures passed against NVIDIA key fingerprint
  `610C7B14E068A878070DA4E99CD0A493D42D0685` in an isolated RPM database.
- All 258 RHEL/EPEL RPM signatures passed against the bundled public Red Hat
  and EPEL 9 keys in an isolated RPM database.
- `createrepo_c` metadata exists for `drivers/` and `os-deps/`.
- NVIDIA upstream module metadata was injected into `drivers/repodata/`.
- A local-only `dnf module list nvidia-driver:580-open` found the stream.
- A local-only `dnf repoquery` found both exact kernel packages.
- `sha256sum -c repo-bundle/SHA256SUMS` passed before packaging.
- The transferred tarball matched its adjacent sidecar SHA-256 file.

## Important limitation

This record proves package identity, signatures, repository metadata, and the
presence of the exact dependency set. It does not prove successful DKMS
compilation or GPU operation. Final acceptance requires installing on the
RHEL 9.8 GPU server, rebooting, and proving that `nvidia-smi` detects all six
RTX PRO 6000 GPUs with driver `580.178.04`.
