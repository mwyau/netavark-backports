#!/usr/bin/env bash
# Shared GitHub Actions orchestration. Outputs remain in the workspace.
set -Eeuo pipefail

ci_revision() {
  REVISION="$(python3 "${GITHUB_WORKSPACE:?}/scripts/check-source-version.py" --revision "$1" "$2")"
  export REVISION
}

ci_require() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || { echo "Missing required environment: $key" >&2; exit 2; }
  done
  [[ -d "$GITHUB_WORKSPACE/tests" ]] || {
    echo "Missing checked-out tests in GITHUB_WORKSPACE" >&2; exit 2;
  }
}

ci_container() {
  local mode="$1" image="$2"
  shift 2
  local -a options=(--rm --pull=always -v "$GITHUB_WORKSPACE:/work" -w /work)
  if [[ "$mode" == runtime ]]; then
    options+=(--privileged --security-opt seccomp=unconfined)
  elif [[ "$mode" != build ]]; then
    echo "Invalid container mode: $mode" >&2; return 2
  fi
  # Keep all docker options before IMAGE, then execute bash inside image.
  local -a extra=()
  while [[ $# -gt 0 && "$1" != bash ]]; do extra+=("$1"); shift; done
  [[ "${1:-}" == bash ]] || { echo "Missing bash command" >&2; return 2; }
  docker run "${options[@]}" "${extra[@]}" "$image" "$@"
}

case "${1:?expected deb or rpm}" in
  deb)
    ci_require GITHUB_WORKSPACE SUITE EXPECTED_ARCH
    case "$SUITE" in
      resolute|stonking) image="ubuntu:$SUITE" ;;
      experimental) image="debian:sid" ;;
      trixie|forky|sid) image="debian:$SUITE" ;;
      *) echo "Unsupported Debian/Ubuntu suite: $SUITE" >&2; exit 2 ;;
    esac
    case "$SUITE" in
      resolute|stonking) ci_revision ubuntu "$SUITE" ;;
      *) ci_revision debian "$SUITE" ;;
    esac
    
    ci_container build "$image" -e "SUITE=$SUITE" \
      -e "EXPECTED_ARCH=$EXPECTED_ARCH" -e "REVISION=$REVISION" \
      bash /work/scripts/build/deb.sh
    
    out="$GITHUB_WORKSPACE/dist/$SUITE/$EXPECTED_ARCH"
    shopt -s nullglob
    packages=("$out"/netavark_*_"$EXPECTED_ARCH".deb)
    [[ "${#packages[@]}" == 1 ]] || {
      echo "Expected exactly one native .deb in $out" >&2; exit 1;
    }
    dpkg-deb --field "${packages[0]}" Package | grep -Fx netavark
    
    # Experimental Netavark 2 requires Podman 6 and separate integration.
    # Build-only packages never appear in the release asset set.
    if [[ "$SUITE" == experimental ]]; then
      echo "Build-only Netavark 2.x: excluded from release"
      exit 0
    fi
    
    for mode in baseline upgrade patched; do
      ci_container runtime "$image" \
        -v "$out:/packages:ro" \
        -v "$GITHUB_WORKSPACE/tests:/tests:ro" \
        -e "NETAVARK_TEST_MODE=$mode" \
        bash /tests/published-port-integration.sh
    done
    for mode in fresh upgrade; do
      ci_container runtime "$image" \
        -v "$out:/packages:ro" \
        -v "$GITHUB_WORKSPACE/tests:/tests:ro" \
        -e "NETAVARK_DUALSTACK_MODE=$mode" \
        bash /tests/podman-dualstack.sh
    done
    echo "PASS: $SUITE / $EXPECTED_ARCH build and IPv4+IPv6 integration"
    test -n "$(find "$out/source" -maxdepth 1 -name '*.dsc' -print -quit)"
    ;;
  rpm)
    ci_require GITHUB_WORKSPACE RPM_PLATFORM RPM_IMAGE RPM_ARCH
    case "$RPM_PLATFORM" in
      fedora43|fedora44)
        release="${RPM_PLATFORM#fedora}"
        ci_revision fedora "$release"
        ci_container build "$RPM_IMAGE" \
          -e "FEDORA_RELEASE=$release" \
          -e "EXPECTED_ARCH=$RPM_ARCH" \
          -e "REVISION=$REVISION" \
          bash /work/scripts/build/fedora.sh
        out="$GITHUB_WORKSPACE/dist/$RPM_PLATFORM/$RPM_ARCH"
        shopt -s nullglob
        packages=("$out"/netavark-*.rpm)
        [[ "${#packages[@]}" == 1 ]] || {
          echo "Expected one Fedora candidate RPM in $out" >&2; exit 1;
        }
        for mode in fresh upgrade; do
          ci_container runtime "$RPM_IMAGE" \
            -v "$out:/packages:ro" \
            -v "$GITHUB_WORKSPACE/tests:/tests:ro" \
            -e "NETAVARK_DUALSTACK_MODE=$mode" \
            -e "REVISION=$REVISION" \
            bash /tests/podman-dualstack.sh
        done
        echo "PASS: Fedora $release / $RPM_ARCH patched Podman IPv4+IPv6 A/B"
        test -n "$(find "$out/source" -maxdepth 1 -name '*.src.rpm' -print -quit)"
        ;;
      leap16|leap161)
        case "$RPM_PLATFORM" in
          leap16) version=16.0 ;;
          leap161) version=16.1 ;;
        esac
        ci_revision opensuse "$version"
        ci_container build "$RPM_IMAGE" \
          -e "LEAP_VERSION=$version" -e "EXPECTED_ARCH=$RPM_ARCH" \
          -e "REVISION=$REVISION" \
          bash /work/scripts/build/opensuse.sh
        out="$GITHUB_WORKSPACE/dist/$RPM_PLATFORM/$RPM_ARCH"
        shopt -s nullglob
        packages=("$out"/netavark-[0-9]*.rpm)
        [[ "${#packages[@]}" == 1 ]] || {
          echo "Expected one patched Leap RPM in $out" >&2; exit 1;
        }
        for mode in fresh upgrade; do
          ci_container runtime "$RPM_IMAGE" \
            -v "$out:/packages:ro" \
            -v "$GITHUB_WORKSPACE/tests:/tests:ro" \
            -e "NETAVARK_DUALSTACK_MODE=$mode" -e "REVISION=$REVISION" \
            bash /tests/podman-dualstack.sh
        done
        echo "PASS: native Leap $version/$RPM_ARCH Podman dual-stack backport"
        ;;
      *)
        echo "Invalid RPM_PLATFORM=$RPM_PLATFORM" >&2; exit 2 ;;
    esac
    ;;
  *) echo 'usage: run.sh deb|rpm' >&2; exit 2 ;;
esac
