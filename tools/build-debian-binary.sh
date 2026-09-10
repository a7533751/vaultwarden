#!/usr/bin/env bash
set -euo pipefail

# Build Vaultwarden on Debian-based hosts (10/11) with the database features enabled.
# The resulting binary is placed in ./dist so that upstream updates to Vaultwarden
# don't conflict with this custom build helper.
#
# By default the script assumes it runs inside a Debian 10 (buster) or Debian 11 (bullseye)
# environment with build prerequisites installed. When running on a different host,
# execute it through a container, for example:
#   docker run --rm -v "$PWD":"$PWD" -w "$PWD" debian:bullseye \
#     bash tools/build-debian-binary.sh --install-deps
#
# Optional arguments:
#   --suite <buster|bullseye>   : Inform the script which Debian baseline you target (default: bullseye)
#   --target <triple>           : Override the Rust target (default: x86_64-unknown-linux-gnu)
#   --profile <profile>         : Cargo profile to build (default: release)
#   --features "<feat list>"    : Feature list passed to cargo (default enables sqlite/mysql/postgresql and vendored OpenSSL)
#   --out-dir <dir>             : Directory where the packaged artefact is stored (default: dist)
#   --no-strip                  : Skip stripping the resulting binary
#   --install-deps              : Install required Debian packages (needs root)
#   -h|--help                   : Show usage information
#
# Environment variables:
#   OPENSSL_STATIC              : If unset, defaults to 1 to force static OpenSSL
#   CARGO_TARGET_DIR            : Respected if set; otherwise Cargo's default is used

usage() {
  grep '^#' "$0" | sed 's/^#\s\{0,1\}//'
}

configure_old_release_sources() {
  local suite="$1"

  if [[ "${suite}" != "buster" ]]; then
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Warning: unable to retarget apt sources for ${suite} without root privileges." >&2
    echo "Install dependencies manually or rerun the script with elevated rights." >&2
    return 0
  fi

  local sources="/etc/apt/sources.list"
  if [[ -f "${sources}" ]]; then
    sed -i 's|https\?://deb.debian.org/debian-security|http://archive.debian.org/debian-security|g' "${sources}"
    sed -i 's|https\?://deb.debian.org/debian|http://archive.debian.org/debian|g' "${sources}"
    sed -i 's|https\?://security.debian.org/debian-security|http://archive.debian.org/debian-security|g' "${sources}"
  fi

  cat >/etc/apt/apt.conf.d/99-archive-repos <<'CONF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
CONF
}


configure_debian_archive_sources() {
  local sources="/etc/apt/sources.list"

  if [[ "${BUILD_SUITE:-}" != "bullseye" ]]; then
    return 0
  fi

  # Bullseye security mirrors can retain stale indexes while the advertised
  # .deb files disappear. Use the archived base suite, which has a
  # self-consistent package index and contains all build prerequisites.
  cat >"${sources}" <<EOF
deb [trusted=yes check-valid-until=no] http://archive.debian.org/debian ${BUILD_SUITE} main
EOF
}

ensure_clean_toolchain() {
  if [[ ! -f rust-toolchain.toml ]]; then
    echo "rust-toolchain.toml not found; run from the project root." >&2
    exit 1
  fi
}

install_dependencies() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "--install-deps requested but apt-get not available." >&2
    exit 1
  fi

  configure_old_release_sources "${BUILD_SUITE:-}"
  configure_debian_archive_sources

  # Debian's archived/old-stable suites can expose expired Release metadata
  # even when the mirror itself is reachable. Keep the validity override for
  # both suites so the dependency install does not fail on stale timestamps.
  rm -rf /var/lib/apt/lists/*
  mkdir -p /var/lib/apt/lists/partial
  apt-get -o Acquire::Check-Valid-Until=false update

  echo "Installing build prerequisites..."
  local packages=(
    build-essential
    clang
    git
    pkg-config
    libpq-dev
    libmariadb-dev
    libssl-dev
    zlib1g-dev
    ca-certificates
  )

  # The Bullseye archive is internally consistent, but the runner image may
  # already contain newer libc/OpenSSL/Perl packages.  Pin the package
  # families whose dependencies require matching versions so apt performs a
  # complete downgrade instead of mixing the runner state with the archive.
  if [[ "${BUILD_SUITE:-}" == "bullseye" ]]; then
    packages+=(
      'libc6=2.31-13+deb11u11'
      'libc6-dev=2.31-13+deb11u11'
      'libc6-i386=2.31-13+deb11u11'
      'libssl1.1=1.1.1w-0+deb11u1'
      'libssl-dev=1.1.1w-0+deb11u1'
      'perl-base=5.32.1-4+deb11u3'
      'perl=5.32.1-4+deb11u3'
    )
  fi

  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --allow-downgrades --no-install-recommends "${packages[@]}"
}

parse_rust_version() {
  local channel
  channel=$(sed -n 's/^channel\s*=\s*"\(.*\)"/\1/p' rust-toolchain.toml | head -n 1 || true)
  if [[ -z "${channel}" ]]; then
    echo "Unable to determine Rust toolchain version from rust-toolchain.toml" >&2
    exit 1
  fi
  printf '%s' "${channel}"
}

main() {
  local suite="bullseye"
  local target="x86_64-unknown-linux-gnu"
  local profile="release"
  local features="sqlite mysql postgresql vendored_openssl"
  local out_dir="dist"
  local strip_binary=1
  local install_deps=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --suite)
        suite="$2"
        shift 2
        ;;
      --target)
        target="$2"
        shift 2
        ;;
      --profile)
        profile="$2"
        shift 2
        ;;
      --features)
        features="$2"
        shift 2
        ;;
      --out-dir)
        out_dir="$2"
        shift 2
        ;;
      --install-deps)
        install_deps=1
        shift
        ;;
      --no-strip)
        strip_binary=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  ensure_clean_toolchain

  case "${suite}" in
    buster|bullseye)
      ;;
    *)
      echo "Unsupported suite '${suite}'. Use 'buster' or 'bullseye'." >&2
      exit 1
      ;;
  esac

  local rust_version
  rust_version=$(parse_rust_version)
  echo "Using Rust toolchain ${rust_version}"

  BUILD_SUITE="${suite}"

  if ! command -v rustup >/dev/null 2>&1; then
    echo "rustup is required but not found in PATH." >&2
    echo "Install Rust toolchain ${rust_version} before running this script." >&2
    exit 1
  fi

  if (( install_deps )); then
    install_dependencies
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo command not found; ensure Rust ${rust_version} is installed." >&2
    exit 1
  fi

  mkdir -p "${out_dir}"

  export OPENSSL_STATIC="${OPENSSL_STATIC:-1}"
  export CARGO_TERM_COLOR="${CARGO_TERM_COLOR:-always}"

  echo "Target     : ${target}"
  echo "Profile    : ${profile}"
  echo "Features   : ${features}"
  echo "Output dir : ${out_dir}"
  echo "Stripping  : $([[ ${strip_binary} -eq 1 ]] && echo yes || echo no)"

  rustup show active-toolchain >/dev/null || rustup default "${rust_version}"

  rustup toolchain install "${rust_version}" --profile minimal
  rustup default "${rust_version}"
  rustup target add "${target}" >/dev/null 2>&1 || true

  cargo fetch --locked
  cargo build --locked --target "${target}" --profile "${profile}" --features "${features}"

  local artefact_path="target/${target}/${profile}/vaultwarden"
  if [[ ! -x "${artefact_path}" ]]; then
    echo "Expected artefact at ${artefact_path} not found." >&2
    exit 1
  fi

  if (( strip_binary )); then
    if command -v strip >/dev/null 2>&1; then
      strip "${artefact_path}"
    else
      echo "strip not available; skipping stripping step."
    fi
  fi

  local package_name="vaultwarden-${target}-${suite}"
  local package_dir="${out_dir}/${package_name}"
  rm -rf "${package_dir}"
  mkdir -p "${package_dir}"

  cp "${artefact_path}" "${package_dir}/"
  cp LICENSE.txt "${package_dir}/" 2>/dev/null || true
  cp README.md "${package_dir}/" 2>/dev/null || true

  (cd "${out_dir}" && tar -czf "${package_name}.tar.gz" "${package_name}")

  echo "Packaged artefact created at ${out_dir}/${package_name}.tar.gz"
}

main "$@"
