#!/usr/bin/env bash
# One native .deb build and validation per suite and architecture.
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
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
