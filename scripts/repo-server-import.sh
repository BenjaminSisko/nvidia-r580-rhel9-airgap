#!/usr/bin/env bash
# Verify and import a transported bundle onto an air-gapped repository server.

set -Eeuo pipefail

SOURCE=""
DESTINATION=""
ALLOW_EXISTING=0

usage() {
  cat <<'EOF'
Usage: sudo ./repo-server-import.sh --source /path/to/mounted-or-extracted-bundle \
  --destination /srv/repos/nvidia-r580 [--allow-existing]

This copies an already-created repository.  It does not configure Apache,
Nginx, firewall rules, DNS, TLS, or client systems.
EOF
}

while (($#)); do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --destination) DESTINATION="$2"; shift 2 ;;
    --allow-existing) ALLOW_EXISTING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "$SOURCE" && -n "$DESTINATION" ]] || { usage >&2; exit 2; }
[[ -d "$SOURCE/drivers/repodata" && -d "$SOURCE/os-deps/repodata" && -f "$SOURCE/SHA256SUMS" ]] \
  || { printf 'ERROR: source is not a complete repo bundle: %s\n' "$SOURCE" >&2; exit 1; }
[[ "$DESTINATION" = /* && "$DESTINATION" != / && "$DESTINATION" != /srv && "$DESTINATION" != /var ]] \
  || { printf 'ERROR: destination must be a specific absolute directory\n' >&2; exit 2; }
((EUID == 0)) || { printf 'ERROR: run as root on the repository server\n' >&2; exit 1; }

printf 'Verifying transport checksums...\n'
(cd "$SOURCE" && sha256sum -c SHA256SUMS)

for cmd in rpm gpg rsync; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: required command missing: %s\n' "$cmd" >&2; exit 1; }
done

expected_fingerprint="610C7B14E068A878070DA4E99CD0A493D42D0685"
observed_fingerprint="$(gpg --show-keys --with-colons --fingerprint "$SOURCE/NVIDIA-GPG-KEY-D42D0685.pub" 2>/dev/null | awk -F: '$1=="fpr" {print toupper($10); exit}')"
[[ "$observed_fingerprint" == "$expected_fingerprint" ]] \
  || { printf 'ERROR: NVIDIA key fingerprint mismatch\n' >&2; exit 1; }

verify_db="$(mktemp -d -t nvidia-rpmdb.XXXXXXXX)"
deps_verify_db="$(mktemp -d -t os-deps-rpmdb.XXXXXXXX)"
trap 'rm -rf -- "$verify_db" "$deps_verify_db"' EXIT
rpm --dbpath "$verify_db" --initdb
rpm --dbpath "$verify_db" --import "$SOURCE/NVIDIA-GPG-KEY-D42D0685.pub"
while IFS= read -r -d '' package; do
  result="$(rpm --dbpath "$verify_db" -K "$package")"
  printf '%s\n' "$result"
  [[ "$result" == *"signatures OK"* ]] \
    || { printf 'ERROR: package signature failed: %s\n' "$package" >&2; exit 1; }
done < <(find "$SOURCE/drivers" -maxdepth 1 -type f -name '*.rpm' -print0)

redhat_key="$SOURCE/keys/RPM-GPG-KEY-redhat-release"
epel_key="$SOURCE/keys/RPM-GPG-KEY-EPEL-9"
[[ -r "$redhat_key" && -r "$epel_key" ]] \
  || { printf 'ERROR: bundled Red Hat/EPEL public signing keys are missing\n' >&2; exit 1; }
rpm --dbpath "$deps_verify_db" --initdb
rpm --dbpath "$deps_verify_db" --import "$redhat_key" "$epel_key"
printf 'Verifying Red Hat/EPEL package signatures with isolated vendor trust...\n'
while IFS= read -r -d '' package; do
  result="$(rpm --dbpath "$deps_verify_db" -K "$package")"
  printf '%s\n' "$result"
  [[ "$result" == *"signatures OK"* ]] \
    || { printf 'ERROR: dependency package signature failed or signing key is unavailable: %s\n' "$package" >&2; exit 1; }
done < <(find "$SOURCE/os-deps" -maxdepth 1 -type f -name '*.rpm' -print0)

if [[ -d "$DESTINATION" && -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit)" ]] && ((ALLOW_EXISTING == 0)); then
  printf 'ERROR: destination is non-empty; inspect it, then rerun with --allow-existing for an idempotent overlay\n' >&2
  exit 1
fi

install -d -m 0755 "$DESTINATION"
rsync -a --itemize-changes "$SOURCE/" "$DESTINATION/"

(cd "$DESTINATION" && sha256sum -c SHA256SUMS)
test -s "$DESTINATION/drivers/repodata/repomd.xml"
test -s "$DESTINATION/os-deps/repodata/repomd.xml"

printf '\nImported successfully: %s\n' "$DESTINATION"
printf 'Publish both repository directories through your existing internal repo service:\n'
printf '  %s/drivers\n' "$DESTINATION"
printf '  %s/os-deps\n' "$DESTINATION"
printf 'Then copy and edit nvidia-r580-internal.repo.example for the client baseurl.\n'
