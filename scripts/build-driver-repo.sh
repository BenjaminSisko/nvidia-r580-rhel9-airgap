#!/usr/bin/env bash
# Stage a complete NVIDIA R580 Open-DKMS repository for one air-gapped RHEL 9
# GPU-server kernel. NVIDIA RPMs come from NVIDIA's public RHEL 9 repository.
# The exact Red Hat kernel-devel RPM and its build dependencies are downloaded
# from the staging host's entitled RHEL/EPEL repositories into a second local
# repository. Subscription-controlled RPMs are output artifacts and must never
# be committed to this public source repository.

set -Eeuo pipefail
shopt -s nullglob

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly NVIDIA_BASE_URL="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64"
readonly STATUS_URL="${NVIDIA_BASE_URL}/precompiled/"
readonly NVIDIA_KEY_FINGERPRINT="610C7B14E068A878070DA4E99CD0A493D42D0685"
readonly MODULE_STREAM="580-open"
readonly DEFAULT_TARGET_KERNEL="5.14.0-687.51.1.el9_8.x86_64"
readonly DEFAULT_DRIVER_VERSION="580.178.04"

AS_OF="$(date +%F)"
WINDOW_DAYS=365
OUTPUT_DIR="${SCRIPT_DIR}/../dist/nvidia-r580-driver-repo-${AS_OF//-/}"
TARGET_KERNEL="$DEFAULT_TARGET_KERNEL"
DRIVER_VERSION="$DEFAULT_DRIVER_VERSION"
DRY_RUN=0
MAKE_ISO=1
STATUS_SOURCE=""
INDEX_SOURCE=""
MODULES_SOURCE=""
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage: ./build-driver-repo.sh [options]

Builds a complete driver-and-build-dependency DNF bundle for an air-gapped repo
server. The output contains two repositories: the exact NVIDIA R580 Open-DKMS
driver set, and the exact RHEL/EPEL build dependencies for the selected kernel.

Options:
  --output DIR          Output directory under dist/
  --target-kernel NVR   Target uname -r (default: 5.14.0-687.51.1.el9_8.x86_64)
  --driver-version VER  Exact R580 version (default: 580.178.04)
  --as-of YYYY-MM-DD    End of the coverage window (default: today)
  --window-days N       Coverage window (default: 365)
  --status-html FILE    Saved NVIDIA precompiled status page (test/replay)
  --repo-index FILE     Saved NVIDIA RHEL 9 repository index (test/replay)
  --modules-yaml FILE   Saved upstream modules.yaml[.gz] (test/replay)
  --no-iso              Produce the repository directory/tar only
  --dry-run             Fetch and analyze metadata; download no RPMs
  --log FILE            Log path (default: OUTPUT/build.log)
  -h, --help            Show help

Exit 42: the exact driver or kernel-devel package is unavailable.
EOF
}

while (($#)); do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --target-kernel) TARGET_KERNEL="$2"; shift 2 ;;
    --driver-version) DRIVER_VERSION="$2"; shift 2 ;;
    --as-of) AS_OF="$2"; shift 2 ;;
    --window-days) WINDOW_DAYS="$2"; shift 2 ;;
    --status-html) STATUS_SOURCE="$2"; shift 2 ;;
    --repo-index) INDEX_SOURCE="$2"; shift 2 ;;
    --modules-yaml) MODULES_SOURCE="$2"; shift 2 ;;
    --no-iso) MAKE_ISO=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$AS_OF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { printf 'ERROR: invalid --as-of\n' >&2; exit 2; }
[[ "$WINDOW_DAYS" =~ ^[0-9]+$ ]] && ((WINDOW_DAYS > 0)) || { printf 'ERROR: invalid --window-days\n' >&2; exit 2; }
[[ "$TARGET_KERNEL" =~ ^5\.14\.0-[0-9]+\.[0-9]+\.[0-9]+\.el9_[0-9]+\.x86_64$ ]] \
  || { printf 'ERROR: invalid --target-kernel: %s\n' "$TARGET_KERNEL" >&2; exit 2; }
[[ "$DRIVER_VERSION" =~ ^580\.[0-9]+\.[0-9]+$ ]] \
  || { printf 'ERROR: --driver-version must be an R580 version\n' >&2; exit 2; }

timestamp() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"; }

for cmd in bash curl python3 awk grep sort sha256sum gzip gpg; do need "$cmd"; done
if ((!DRY_RUN)); then
  for cmd in rpm dnf createrepo_c modifyrepo_c tar; do need "$cmd"; done
  dnf download --help >/dev/null 2>&1 \
    || die "dnf download is unavailable; install dnf-plugins-core on the staging host"
  if ((MAKE_ISO)); then need xorriso; fi
fi

if ((DRY_RUN)); then
  WORK_ROOT="$(mktemp -d -t nvidia-driver-repo.XXXXXXXX)"
  LOG_FILE="${LOG_FILE:-${WORK_ROOT}/build.log}"
else
  mkdir -p "$OUTPUT_DIR"
  WORK_ROOT="${OUTPUT_DIR}/work"
  LOG_FILE="${LOG_FILE:-${OUTPUT_DIR}/build.log}"
fi
mkdir -p "$WORK_ROOT/sources" "$(dirname -- "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

SOURCE_DIR="${WORK_ROOT}/sources"
STATUS_HTML="${SOURCE_DIR}/precompiled.html"
REPO_INDEX="${SOURCE_DIR}/repo-index.html"
REPOMD="${SOURCE_DIR}/repomd.xml"
MODULES_YAML="${SOURCE_DIR}/modules.yaml"
NVIDIA_KEY="${SOURCE_DIR}/D42D0685.pub"
RPM_LIST="${WORK_ROOT}/repo-rpms.txt"
COVERAGE_TSV="${WORK_ROOT}/coverage.tsv"
ALL_DKMS_TSV="${WORK_ROOT}/dkms-fallbacks-all.tsv"
DKMS_TSV="${WORK_ROOT}/dkms-selected.tsv"

fetch_or_copy() {
  local source="$1" url="$2" destination="$3"
  if [[ -n "$source" ]]; then
    [[ -r "$source" ]] || die "cannot read source: $source"
    if [[ "$source" == *.gz ]]; then gzip -dc -- "$source" > "$destination"; else cp -f -- "$source" "$destination"; fi
  else
    curl --fail --location --silent --show-error --retry 4 "$url" -o "$destination"
  fi
}

log "Reading NVIDIA's RHEL 9 repository and precompiled-kmod status"
fetch_or_copy "$STATUS_SOURCE" "$STATUS_URL" "$STATUS_HTML"
fetch_or_copy "$INDEX_SOURCE" "${NVIDIA_BASE_URL}/" "$REPO_INDEX"

if [[ -n "$MODULES_SOURCE" ]]; then
  fetch_or_copy "$MODULES_SOURCE" "" "$MODULES_YAML"
else
  fetch_or_copy "" "${NVIDIA_BASE_URL}/repodata/repomd.xml" "$REPOMD"
  modules_href="$(python3 - "$REPOMD" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
ns = {'r': 'http://linux.duke.edu/metadata/repo'}
for data in root.findall('r:data', ns):
    if data.get('type') == 'modules':
        print(data.find('r:location', ns).get('href'))
        break
else:
    raise SystemExit('modules metadata not present')
PY
)"
  module_blob="${SOURCE_DIR}/modules.blob"
  fetch_or_copy "" "${NVIDIA_BASE_URL}/${modules_href}" "$module_blob"
  gzip -dc -- "$module_blob" > "$MODULES_YAML"
fi

fetch_or_copy "" "${NVIDIA_BASE_URL}/D42D0685.pub" "$NVIDIA_KEY"
observed_fingerprint="$(gpg --show-keys --with-colons --fingerprint "$NVIDIA_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print toupper($10); exit}')"
[[ "$observed_fingerprint" == "$NVIDIA_KEY_FINGERPRINT" ]] \
  || die "NVIDIA signing-key fingerprint mismatch: ${observed_fingerprint:-none}"

python3 "$SCRIPT_DIR/parse_sources.py" list-rpms --repo-index "$REPO_INDEX" > "$RPM_LIST"
python3 "$SCRIPT_DIR/parse_sources.py" module-streams --modules "$MODULES_YAML" | grep -Fxq "$MODULE_STREAM" \
  || die "module metadata does not contain ${MODULE_STREAM}"

latest_rpm_for() {
  local name="$1" version="$2" arch="$3"
  grep -E "^${name}-${version//./\\.}-.*\.${arch}\.rpm$" "$RPM_LIST" | sort -V | tail -n 1
}

userspace_names=(
  libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver
  nvidia-driver-cuda nvidia-driver-cuda-libs nvidia-driver-libs
  nvidia-kmod-common nvidia-libXNVCtrl nvidia-libXNVCtrl-devel
  nvidia-modprobe nvidia-persistenced nvidia-settings nvidia-xconfig
  xorg-x11-nvidia
)

set +e
python3 "$SCRIPT_DIR/parse_sources.py" coverage \
  --status-html "$STATUS_HTML" --repo-index "$REPO_INDEX" \
  --as-of "$AS_OF" --days "$WINDOW_DAYS" --require-covered > "$COVERAGE_TSV"
coverage_rc=$?
set -e
((coverage_rc == 0 || coverage_rc == 42)) || die "coverage parser failed (${coverage_rc})"

covered_count="$(awk -F '\t' '$3=="COVERED" {n++} END {print n+0}' "$COVERAGE_TSV")"
gap_count="$(awk -F '\t' '$3=="GAP" {n++} END {print n+0}' "$COVERAGE_TSV")"
log "Last-${WINDOW_DAYS}-day coverage: ${covered_count} covered, ${gap_count} gaps"

set +e
python3 "$SCRIPT_DIR/parse_sources.py" dkms-fallbacks \
  --repo-index "$REPO_INDEX" --coverage "$COVERAGE_TSV" \
  --require-all > "$ALL_DKMS_TSV"
dkms_rc=$?
set -e
((dkms_rc == 0 || dkms_rc == 42)) || die "open-DKMS fallback parser failed (${dkms_rc})"

awk -F '\t' -v wanted="$DRIVER_VERSION" \
  'NR == 1 || $1 == wanted' "$ALL_DKMS_TSV" > "$DKMS_TSV"
dkms_count="$(awk -F '\t' '$1 != "driver_version" && $2=="AVAILABLE" {n++} END {print n+0}' "$DKMS_TSV")"
log "Selected target kernel: ${TARGET_KERNEL}"
log "Selected R580 Open-DKMS version: ${DRIVER_VERSION}"

if ((covered_count == 0)); then
  log "NOTICE: no non-DKMS precompiled OPEN R580 kmod exists in the NVIDIA RHEL 9 repository."
  log "The bundle will contain signed open-DKMS emergency fallback sets; the target must opt in with --dkms-fallback."
fi

if ((dkms_count == 0)); then
  log "BLOCKED: exact R580 Open-DKMS ${DRIVER_VERSION} is unavailable."
  cat "$DKMS_TSV"
  if ((!DRY_RUN)); then
    cp -f -- "$COVERAGE_TSV" "${OUTPUT_DIR}/COVERAGE.txt"
    cp -f -- "$DKMS_TSV" "${OUTPUT_DIR}/DKMS_SELECTED.txt"
  fi
  exit 42
fi

while IFS=$'\t' read -r driver status dkms_file reason; do
  [[ "$driver" == "driver_version" || "$status" != "AVAILABLE" ]] && continue
  for name in "${userspace_names[@]}"; do
    arch=x86_64
    [[ "$name" == nvidia-kmod-common ]] && arch=noarch
    [[ -n "$(latest_rpm_for "$name" "$driver" "$arch")" ]] \
      || die "repository index lacks matching userspace RPM: ${name} ${driver} ${arch}"
  done
done < "$DKMS_TSV"

plugin="$(grep -E '^dnf-plugin-nvidia-.*\.noarch\.rpm$' "$RPM_LIST" | sort -V | tail -n 1)"
[[ -n "$plugin" ]] || die "dnf-plugin-nvidia missing from upstream repository"

if ((DRY_RUN)); then
  need dnf
  for required in \
    "kernel-devel-${TARGET_KERNEL}" \
    "kernel-headers-${TARGET_KERNEL}" \
    gcc make dkms elfutils-libelf-devel python3-dnf-plugin-versionlock mokutil pciutils; do
    dnf -q repoquery --available --qf '%{nevra}' "$required" | grep -q . \
      || { log "BLOCKED: required RHEL/EPEL package is unavailable: ${required}"; exit 42; }
  done
  log "Entitled RHEL/EPEL repositories expose the complete target dependency set."
  log "Dry-run passed. No RPMs or repository artifacts were written."
  exit 0
fi

REPO_ROOT="${OUTPUT_DIR}/repo-bundle"
DRIVERS_DIR="${REPO_ROOT}/drivers"
OS_DEPS_DIR="${REPO_ROOT}/os-deps"
mkdir -p "$DRIVERS_DIR" "$OS_DEPS_DIR" "${REPO_ROOT}/docs"

log "Downloading exact RHEL/EPEL build dependencies for ${TARGET_KERNEL}"
os_dependency_specs=(
  "kernel-devel-${TARGET_KERNEL}"
  "kernel-headers-${TARGET_KERNEL}"
  gcc
  make
  dkms
  elfutils-libelf-devel
  python3-dnf-plugin-versionlock
  mokutil
  pciutils
)

if ! dnf -y download --resolve --alldeps --archlist=x86_64,noarch \
  --destdir "$OS_DEPS_DIR" "${os_dependency_specs[@]}"; then
  log "BLOCKED: the staging host's enabled entitled RHEL/EPEL repositories do not provide the complete dependency set."
  log "Required exact package: kernel-devel-${TARGET_KERNEL}"
  log "Enable the matching RHEL BaseOS/AppStream and EPEL repositories, then rerun."
  exit 42
fi

exact_kernel_devel=""
for package in "$OS_DEPS_DIR"/*.rpm; do
  name="$(rpm -qp --qf '%{NAME}' "$package")"
  [[ "$name" == kernel-devel ]] || continue
  package_kernel="$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$package")"
  if [[ "$package_kernel" == "$TARGET_KERNEL" ]]; then
    exact_kernel_devel="$package"
    break
  fi
done
[[ -n "$exact_kernel_devel" ]] \
  || { log "BLOCKED: downloaded payload lacks kernel-devel-${TARGET_KERNEL}"; exit 42; }

printf 'target_kernel\tpackage\n%s\t%s\n' \
  "$TARGET_KERNEL" "$(basename -- "$exact_kernel_devel")" > "${REPO_ROOT}/OS_DEPENDENCIES.tsv"

download_rpm() {
  local filename="$1"
  [[ -s "${DRIVERS_DIR}/${filename}" ]] && return 0
  curl --fail --location --show-error --retry 4 --continue-at - \
    "${NVIDIA_BASE_URL}/${filename}" -o "${DRIVERS_DIR}/${filename}"
}

verify_open_kmod() {
  local path="$1" kernel="$2" driver="$3" name version license provides conflicts
  IFS='|' read -r name version license < <(rpm -qp --qf '%{NAME}|%{VERSION}|%{LICENSE}\n' "$path")
  provides="$(rpm -qp --provides "$path")"
  conflicts="$(rpm -qp --conflicts "$path" || true)"
  [[ "$name" == kmod-nvidia-open* && "$name" != *dkms* ]]
  [[ "$version" == "$driver" ]]
  [[ "$license" =~ (GPL|MIT) ]]
  [[ "$provides" == *"kmod(nvidia.ko)"* ]]
  [[ "$provides" == *"${kernel}"* ]]
  [[ "$conflicts" != *"kmod-nvidia-open"* ]]
}

verify_open_dkms() {
  local path="$1" driver="$2" name version license
  IFS='|' read -r name version license < <(rpm -qp --qf '%{NAME}|%{VERSION}|%{LICENSE}\n' "$path")
  [[ "$name" == "kmod-nvidia-open-dkms" ]]
  [[ "$version" == "$driver" ]]
  [[ "$license" =~ (GPL|MIT) ]]
}

download_userspace_set() {
  local driver="$1" name arch filename
  for name in "${userspace_names[@]}"; do
    arch=x86_64
    [[ "$name" == nvidia-kmod-common ]] && arch=noarch
    filename="$(latest_rpm_for "$name" "$driver" "$arch")"
    [[ -n "$filename" ]] || die "missing exact userspace RPM: ${name} ${driver} ${arch}"
    download_rpm "$filename"
  done
}

printf 'kernel\tdriver_version\tpackage_files_semicolon_separated\n' > "${REPO_ROOT}/DRIVER_SETS.tsv"
while IFS=$'\t' read -r release_date kernel status driver kmod_file proprietary dkms_status dkms_driver reason; do
  [[ "$release_date" == "release_date" || "$status" != "COVERED" ]] && continue
  download_rpm "$kmod_file"
  verify_open_kmod "${DRIVERS_DIR}/${kmod_file}" "$kernel" "$driver" \
    || die "candidate is not a verified precompiled-open kmod: $kmod_file"
  download_userspace_set "$driver"
  files="$(find "$DRIVERS_DIR" -maxdepth 1 -type f -name "*${driver}*.rpm" -printf '%f\n' | sort -V | paste -sd';' -)"
  printf '%s\t%s\t%s\n' "$kernel" "$driver" "$files" >> "${REPO_ROOT}/DRIVER_SETS.tsv"
done < "$COVERAGE_TSV"

printf 'driver_version\topen_dkms_rpm\tpackage_files_semicolon_separated\n' > "${REPO_ROOT}/DKMS_FALLBACK_SETS.tsv"
while IFS=$'\t' read -r driver status dkms_file reason; do
  [[ "$driver" == "driver_version" || "$status" != "AVAILABLE" ]] && continue
  download_rpm "$dkms_file"
  verify_open_dkms "${DRIVERS_DIR}/${dkms_file}" "$driver" \
    || die "candidate is not a verified R580 open-DKMS package: $dkms_file"
  download_userspace_set "$driver"
  files="$(find "$DRIVERS_DIR" -maxdepth 1 -type f -name "*${driver}*.rpm" -printf '%f\n' | sort -V | paste -sd';' -)"
  printf '%s\t%s\t%s\n' "$driver" "$dkms_file" "$files" >> "${REPO_ROOT}/DKMS_FALLBACK_SETS.tsv"
done < "$DKMS_TSV"

download_rpm "$plugin"

log "Checking RPM signatures before repository creation"
verify_db="$(mktemp -d -t nvidia-stage-rpmdb.XXXXXXXX)"
trap 'rm -rf -- "$verify_db"' EXIT
rpm --dbpath "$verify_db" --initdb
rpm --dbpath "$verify_db" --import "$NVIDIA_KEY"
while IFS= read -r -d '' package; do
  result="$(rpm --dbpath "$verify_db" -K "$package")"
  printf '%s\n' "$result"
  [[ "$result" == *"signatures OK"* ]] || die "RPM signature verification failed: $package"
done < <(find "$DRIVERS_DIR" -type f -name '*.rpm' -print0)

redhat_key=/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
epel_key=/etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9
[[ -r "$redhat_key" ]] || die "Red Hat public RPM key is unavailable: $redhat_key"
[[ -r "$epel_key" ]] || die "EPEL 9 public RPM key is unavailable: $epel_key"
os_verify_db="$(mktemp -d -t os-deps-stage-rpmdb.XXXXXXXX)"
trap 'rm -rf -- "$verify_db" "$os_verify_db"' EXIT
rpm --dbpath "$os_verify_db" --initdb
rpm --dbpath "$os_verify_db" --import "$redhat_key" "$epel_key"
log "Checking Red Hat/EPEL RPM signatures with isolated vendor trust"
while IFS= read -r -d '' package; do
  result="$(rpm --dbpath "$os_verify_db" -K "$package")"
  printf '%s\n' "$result"
  [[ "$result" == *"signatures OK"* ]] \
    || die "RHEL/EPEL RPM signature verification failed or key is unavailable: $package"
done < <(find "$OS_DEPS_DIR" -maxdepth 1 -type f -name '*.rpm' -print0)

createrepo_c --update --database "$DRIVERS_DIR"
cp -f -- "$MODULES_YAML" "${DRIVERS_DIR}/modules.yaml"
modifyrepo_c --mdtype=modules "${DRIVERS_DIR}/modules.yaml" "${DRIVERS_DIR}/repodata/"
createrepo_c --update --database "$OS_DEPS_DIR"

cp -f -- "$NVIDIA_KEY" "${REPO_ROOT}/NVIDIA-GPG-KEY-D42D0685.pub"
mkdir -p "${REPO_ROOT}/keys"
cp -f -- "$redhat_key" "$epel_key" "${REPO_ROOT}/keys/"
cp -f -- "$COVERAGE_TSV" "${REPO_ROOT}/COVERAGE.txt"
cp -f -- "$SCRIPT_DIR/repo-server-import.sh" "$REPO_ROOT/"
cp -f -- "$SCRIPT_DIR/client-install.sh" "$REPO_ROOT/"
cp -f -- "$SCRIPT_DIR/../README.md" "$REPO_ROOT/README.md"
cp -f -- "$SCRIPT_DIR/../docs/INSTALL.md" "${REPO_ROOT}/docs/INSTALL.md"
cp -f -- "$SCRIPT_DIR/../docs/LLM-CONTEXT.md" "${REPO_ROOT}/docs/LLM-CONTEXT.md"
cp -f -- "$SCRIPT_DIR/../PACKAGE-MANIFEST.md" "$REPO_ROOT/"
cp -f -- "$SCRIPT_DIR/../config/nvidia-r580-internal.repo.example" "$REPO_ROOT/"

{
  printf 'Built UTC: %s\n' "$(timestamp)"
  printf 'Coverage window: %s days ending %s\n' "$WINDOW_DAYS" "$AS_OF"
  printf 'Module stream: %s\n' "$MODULE_STREAM"
  printf 'Target kernel: %s\n' "$TARGET_KERNEL"
  printf 'Selected driver version: %s\n' "$DRIVER_VERSION"
  printf 'Precompiled-open covered kernels: %s\n' "$covered_count"
  printf 'Precompiled-open GAP kernels: %s\n' "$gap_count"
  printf 'Open-DKMS driver sets: %s\n' "$dkms_count"
  printf 'Repository path after import: set by the repo-server operator\n'
  printf 'NVIDIA RPM count: %s\n' "$(find "$DRIVERS_DIR" -type f -name '*.rpm' | wc -l)"
  printf 'RHEL/EPEL dependency RPM count: %s\n' "$(find "$OS_DEPS_DIR" -type f -name '*.rpm' | wc -l)"
  printf '\nNVIDIA packages:\n'
  find "$DRIVERS_DIR" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' | sort -V
  printf '\nRHEL/EPEL dependency packages:\n'
  find "$OS_DEPS_DIR" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' | sort -V
} > "${REPO_ROOT}/MANIFEST.txt"

(
  cd "$REPO_ROOT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

tar --sort=name --mtime="${AS_OF} 00:00:00 UTC" --owner=0 --group=0 --numeric-owner \
  -C "$OUTPUT_DIR" -czf "${OUTPUT_DIR}/nvidia-r580-driver-repo-${AS_OF//-/}.tar.gz" repo-bundle
sha256sum "${OUTPUT_DIR}/nvidia-r580-driver-repo-${AS_OF//-/}.tar.gz" \
  > "${OUTPUT_DIR}/nvidia-r580-driver-repo-${AS_OF//-/}.tar.gz.sha256"

if ((MAKE_ISO)); then
  xorriso -as mkisofs -quiet -iso-level 3 -R -J -joliet-long \
    -V "NVR580_${AS_OF//-/}" -o "${OUTPUT_DIR}/nvidia-r580-${AS_OF//-/}-vol1.iso" "$REPO_ROOT"
  sha256sum "${OUTPUT_DIR}/nvidia-r580-${AS_OF//-/}-vol1.iso" \
    > "${OUTPUT_DIR}/nvidia-r580-${AS_OF//-/}-vol1.iso.sha256"
fi

log "SUCCESS: repo bundle ready at ${REPO_ROOT}"
