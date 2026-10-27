#!/usr/bin/env bash
# One RPM-family build+test job per release/arch; Leap is stock-only.
set -Eeuo pipefail
source "$(dirname "$0")/ci-common.sh"
ci_require GITHUB_WORKSPACE RPM_PLATFORM RPM_IMAGE RPM_ARCH REVISION
case "$RPM_PLATFORM" in
  fedora43|fedora44)
    release="${RPM_PLATFORM#fedora}"
    ci_container build "$RPM_IMAGE" \
      -e "FEDORA_RELEASE=$release" \
      -e "EXPECTED_ARCH=$RPM_ARCH" \
      -e "REVISION=$REVISION" \
      bash /work/scripts/build-fedora.sh
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
        -e "NETAVARK_COMPOSE_MODE=$mode" \
        -e "REVISION=$REVISION" \
        bash /tests/podman-compose-dualstack.sh
    done
    echo "PASS: Fedora $release / $RPM_ARCH patched Compose IPv4+IPv6 A/B"
    ci_release_upload_if_main "${packages[0]}"
    ;;
  leap16|leap161)
    ci_container runtime "$RPM_IMAGE" \
      -v "$GITHUB_WORKSPACE/tests:/tests:ro" \
      -e "TEST_PLATFORM=$RPM_PLATFORM" \
      bash /tests/native-distro-network.sh
    echo "PASS: native Leap $RPM_PLATFORM stock networking (no patched RPM)"
    ;;
  *)
    echo "Invalid RPM_PLATFORM=$RPM_PLATFORM" >&2; exit 2 ;;
esac
