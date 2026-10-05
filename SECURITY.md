# Security policy

## Never commit to Git history

- RPM payloads, ISO images, generated repositories, or extracted vendor corpora
- Red Hat subscription certificates, entitlement keys, repository credentials,
  GitHub tokens, passwords, SSH private keys, MOK private keys, or license files
- Internal hostnames, IP addresses, repository URLs, inventories, ticket data,
  logs, command output, or vulnerability evidence

The public repository contains reproducible tooling and package manifests.
Large vendor binaries are carried only as a versioned GitHub Release asset,
with a published SHA-256 sidecar; they are never Git objects. The release must
not contain subscription certificates, CDN client keys, credentials, private
keys, or internal environment evidence.

## Supply-chain controls

- NVIDIA's public-key fingerprint is pinned in the builder.
- NVIDIA RPM signatures are checked in an isolated temporary RPM database.
- Red Hat and EPEL RPM signatures are checked against the bundled public vendor
  keys in an isolated temporary RPM database.
- SHA-256 hashes cover every file carried in the generated bundle.
- The importer verifies hashes and RPM signatures before copying any payload.
- The client selects only the R580 open module stream and rejects proprietary
  precompiled kmods.

Report a vulnerability through GitHub's private vulnerability-reporting
feature. Do not open a public issue containing secrets or internal evidence.
