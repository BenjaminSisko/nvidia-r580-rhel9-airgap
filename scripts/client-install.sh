#!/usr/bin/env bash
# Target-side installer for the paired NVIDIA and RHEL/EPEL offline repos.

set -Eeuo pipefail

REPO_ID="nvidia-r580-internal"
DEPS_REPO_ID="nvidia-r580-os-deps"
EXPECTED_KERNEL="5.14.0-687.51.1.el9_8.x86_64"
EXPECTED_GPUS=6
VALIDATE_ONLY=0
ASSUME_YES=0
NO_REBOOT=0
DKMS_FALLBACK=0

usage() {
  cat <<'EOF'
Usage: sudo ./client-install.sh [options]

Options:
  --repoid ID          Internal DNF repository ID (default: nvidia-r580-internal)
  --deps-repoid ID     Bundled RHEL/EPEL dependency repo (default: nvidia-r580-os-deps)
  --kernel NVR         Required uname -r (default: 5.14.0-687.51.1.el9_8.x86_64)
  --expected-gpus N    Expected NVIDIA device count (default: 6)
  --validate           Post-reboot validation only
  --dkms-fallback      Explicitly allow open DKMS when this kernel is a GAP
  --yes                Do not prompt before package installation
  --no-reboot          Do not offer to reboot after installation
  -h, --help           Show help

Both internal .repo definitions must already be installed through the site's
normal repository-management process. This script never adds an Internet repo.
EOF
}

while (($#)); do
  case "$1" in
    --repoid) REPO_ID="$2"; shift 2 ;;
    --deps-repoid) DEPS_REPO_ID="$2"; shift 2 ;;
    --kernel) EXPECTED_KERNEL="$2"; shift 2 ;;
    --expected-gpus) EXPECTED_GPUS="$2"; shift 2 ;;
    --validate) VALIDATE_ONLY=1; shift ;;
    --dkms-fallback) DKMS_FALLBACK=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

((EUID == 0)) || { printf 'ERROR: run as root\n' >&2; exit 1; }
[[ "$EXPECTED_GPUS" =~ ^[0-9]+$ ]] || { printf 'ERROR: --expected-gpus must be numeric\n' >&2; exit 2; }

validate() {
  command -v nvidia-smi >/dev/null 2>&1 || { printf 'ERROR: nvidia-smi is not installed\n' >&2; return 1; }
  nvidia-smi
  count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
  [[ "$count" -eq "$EXPECTED_GPUS" ]] \
    || { printf 'ERROR: expected %s GPUs; nvidia-smi found %s\n' "$EXPECTED_GPUS" "$count" >&2; return 1; }
  printf '\nMATLAB checks (run as a licensed MATLAB user):\n'
  printf '  gpuDeviceTable             %% expect %s GPUs\n' "$EXPECTED_GPUS"
  printf '  gpuDevice(1)               %% expect ComputeCapability 12.0 and the installed driver\n'
  printf '\nDo not run parallel.gpu.enableCUDAForwardCompatibility for this Blackwell/MATLAB 2026 deployment.\n'
  if rpm -q kmod-nvidia-open-dkms >/dev/null 2>&1 && command -v dkms >/dev/null 2>&1; then
    printf '\nOpen-DKMS status:\n'
    dkms status
  fi
}

if ((VALIDATE_ONLY)); then validate; exit; fi

for cmd in dnf rpm lspci; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: required command missing: %s\n' "$cmd" >&2; exit 1; }
done

printf 'Detected NVIDIA PCI functions:\n'
lspci | grep -i nvidia || { printf 'ERROR: no NVIDIA PCI devices detected\n' >&2; exit 1; }

running_kernel="$(uname -r)"
[[ "$running_kernel" == "$EXPECTED_KERNEL" ]] || {
  printf 'ERROR: this bundle targets %s, but the running kernel is %s\n' \
    "$EXPECTED_KERNEL" "$running_kernel" >&2
  printf 'Boot the target kernel before installing the NVIDIA driver.\n' >&2
  exit 42
}
mapfile -t installed_kernels < <(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V)
printf '\nRunning kernel: %s\nInstalled kernels:\n' "$running_kernel"
printf '  %s\n' "${installed_kernels[@]}"

dnf -q repolist --enabled | awk '{print $1}' | grep -Fxq "$REPO_ID" \
  || { printf 'ERROR: internal repository is not enabled: %s\n' "$REPO_ID" >&2; exit 1; }
dnf -q repolist --enabled | awk '{print $1}' | grep -Fxq "$DEPS_REPO_ID" \
  || { printf 'ERROR: bundled dependency repository is not enabled: %s\n' "$DEPS_REPO_ID" >&2; exit 1; }

repo_only=(--disablerepo='*' --enablerepo="$REPO_ID")
deps_only=(--disablerepo='*' --enablerepo="$DEPS_REPO_ID")

dnf -q "${repo_only[@]}" module list nvidia-driver | grep -F '580-open' >/dev/null \
  || { printf 'ERROR: %s does not expose nvidia-driver:580-open module metadata\n' "$REPO_ID" >&2; exit 1; }

nevra_format='%{name}-%{epoch}:%{version}-%{release}.%{arch}'
kmod_line="$(dnf -q "${repo_only[@]}" repoquery --disable-modular-filtering --available \
  --whatprovides "kernel-modules = ${running_kernel}" \
  --qf "%{name}|%{version}|${nevra_format}|%{license}" | awk -F '|' '$1 ~ /^kmod-nvidia-open/ && $1 !~ /dkms/ && $2 ~ /^580\./ {print; exit}')"

install_mode="precompiled"

if [[ -z "$kmod_line" ]]; then
  printf 'Running kernel is a GAP in the internal precompiled-open repository: %s\n' "$running_kernel" >&2
  if ((DKMS_FALLBACK == 0)); then
    printf 'This pinned target requires Open-DKMS. Rerun with --dkms-fallback after change approval.\n' >&2
    exit 42
  fi
  kmod_line="$(dnf -q "${repo_only[@]}" repoquery --disable-modular-filtering --available \
    --qf "%{name}|%{version}|${nevra_format}|%{license}" kmod-nvidia-open-dkms \
    | awk -F '|' '$1 == "kmod-nvidia-open-dkms" && $2 ~ /^580\./ {print}' \
    | sort -t '|' -k2,2V | tail -n 1)"
  [[ -n "$kmod_line" ]] \
    || { printf 'ERROR: --dkms-fallback was requested, but no R580 open-DKMS package is in %s\n' "$REPO_ID" >&2; exit 42; }
  install_mode="dkms"
fi

IFS='|' read -r kmod_name driver_version kmod_nevra kmod_license <<< "$kmod_line"
[[ "$kmod_license" =~ (GPL|MIT) ]] \
  || { printf 'ERROR: candidate kmod does not carry an open-source license: %s\n' "$kmod_license" >&2; exit 1; }

package_names=(
  libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver
  nvidia-driver-cuda nvidia-driver-cuda-libs nvidia-driver-libs
  nvidia-kmod-common nvidia-libXNVCtrl nvidia-libXNVCtrl-devel
  nvidia-modprobe nvidia-persistenced nvidia-settings nvidia-xconfig
  xorg-x11-nvidia
)
plugin_nevra="$(dnf -q "${repo_only[@]}" repoquery --disable-modular-filtering --available --qf "$nevra_format" dnf-plugin-nvidia | sort -V | tail -n 1)"
[[ -n "$plugin_nevra" ]] || { printf 'ERROR: dnf-plugin-nvidia is missing from %s\n' "$REPO_ID" >&2; exit 1; }
packages=("$kmod_nevra" "$plugin_nevra")
for name in "${package_names[@]}"; do
  nevra="$(dnf -q "${repo_only[@]}" repoquery --disable-modular-filtering --available --qf "$nevra_format" "${name}-${driver_version}*" | sort -V | tail -n 1)"
  [[ -n "$nevra" ]] || { printf 'ERROR: matching userspace package missing: %s %s\n' "$name" "$driver_version" >&2; exit 1; }
  packages+=("$nevra")
done

printf '\nSelected driver %s for kernel %s.\n' "$driver_version" "$running_kernel"
if [[ "$install_mode" == "dkms" ]]; then
  printf '\nWARNING: EMERGENCY OPEN-DKMS FALLBACK SELECTED.\n' >&2
  printf 'This installs gcc, make, exact kernel-devel, and dkms from the verified offline dependency repository.\n' >&2
  printf 'It compiles the NVIDIA kernel modules on this host and changes the installed-package/security baseline.\n' >&2
  printf 'The installed kernel-devel version MUST exactly match uname -r: %s\n\n' "$running_kernel" >&2
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -Fqi enabled; then
    printf 'Secure Boot is enabled. The locally built module must be signed by a key the host already trusts.\n' >&2
    printf 'This helper does not create or enroll a MOK; verify the site-approved module-signing path before reboot.\n\n' >&2
  fi

  dependencies=(
    gcc make dkms elfutils-libelf-devel "kernel-headers-${running_kernel}"
    "kernel-devel-${running_kernel}"
  )
  for dependency in "${dependencies[@]}"; do
    if rpm -q "$dependency" >/dev/null 2>&1; then
      printf 'Dependency ready (installed): %s\n' "$dependency"
      continue
    fi
    candidates="$(dnf -q "${deps_only[@]}" repoquery --available --qf "%{repoid}|${nevra_format}" "$dependency" || true)"
    candidate="$(printf '%s\n' "$candidates" | sed -n '1p')"
    [[ -n "$candidate" ]] \
      || { printf 'ERROR: required DKMS dependency is unavailable from %s: %s\n' "$DEPS_REPO_ID" "$dependency" >&2; exit 1; }
    [[ "${candidate%%|*}" == "$DEPS_REPO_ID" ]] \
      || { printf 'ERROR: dependency %s did not resolve from %s\n' "$dependency" "$DEPS_REPO_ID" >&2; exit 1; }
    printf 'Dependency ready (%s): %s\n' "${candidate%%|*}" "${candidate#*|}"
  done
else
  printf 'Using a precompiled open kmod; gcc, make, kernel-devel, and dkms will not be installed by this script.\n'
fi
printf 'CUDA Toolkit, cuDNN, and TensorRT will not be installed.\n'
if ((ASSUME_YES == 0)); then
  if [[ "$install_mode" == "dkms" ]]; then
    read -r -p 'Install the emergency open-DKMS driver and build toolchain? [y/N] ' answer
  else
    read -r -p 'Install this precompiled driver set? [y/N] ' answer
  fi
  [[ "$answer" =~ ^[Yy]$ ]] || { printf 'Cancelled.\n'; exit 0; }
fi

if [[ "$install_mode" == "dkms" ]]; then
  dnf -y "${deps_only[@]}" install "${dependencies[@]}"
  installed_kernel_devel="$(rpm -q kernel-devel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' || true)"
  printf '%s\n' "$installed_kernel_devel" | grep -Fxq "$running_kernel" \
    || { printf 'ERROR: installed kernel-devel does not exactly match uname -r (%s)\n' "$running_kernel" >&2; exit 1; }
  printf 'Verified exact kernel-devel match: %s\n' "$running_kernel"
fi

dnf -y "${repo_only[@]}" module enable nvidia-driver:580-open
dnf -y install "${packages[@]}"
systemctl enable nvidia-persistenced.service

if ! dnf -q versionlock list >/dev/null 2>&1; then
  dnf -y "${deps_only[@]}" install python3-dnf-plugin-versionlock
fi
mapfile -t kernel_package_names < <(rpm -qa --qf '%{NAME}\n' | grep '^kernel' | sort -u)
((${#kernel_package_names[@]} > 0)) && dnf versionlock add "${kernel_package_names[@]}"

printf '\nInstalled. Kernel packages are versionlocked so a later customer-repo update cannot outrun the kmod.\n'
if [[ "$install_mode" == "dkms" ]]; then
  printf 'DKMS patch cycle: unlock kernel* -> install the new kernel and its exact matching kernel-devel together -> verify the DKMS build -> reboot -> validate -> relock.\n'
else
  printf 'Precompiled patch cycle: unlock kernel* -> install the new covered kernel and matching driver together -> reboot -> validate -> relock.\n'
fi

if ((NO_REBOOT == 0)); then
  read -r -p 'Reboot now? [y/N] ' answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then systemctl reboot; fi
fi
printf 'After reboot: sudo %s --validate --expected-gpus %s\n' "$0" "$EXPECTED_GPUS"
