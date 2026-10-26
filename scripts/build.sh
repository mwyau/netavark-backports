#!/usr/bin/env bash
set -Eeuo pipefail
SUITE="${SUITE:?Set Debian suite}"
EXPECTED_ARCH="${EXPECTED_ARCH:?Set amd64 or arm64}"
REVISION="${REVISION:-1}"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || exit 2
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "$EXPECTED_ARCH" ]] || { echo "Architecture mismatch: $ARCH vs $EXPECTED_ARCH" >&2; exit 2; }
case "$SUITE" in
  trixie) BASE=1.14.0-2; FAMILY=1.14; DIST=trixie ;;
  forky) BASE=1.17.2-3; FAMILY=1.17; DIST=forky ;;
  sid) BASE=1.17.2-3; FAMILY=1.17; DIST=sid ;;
  experimental) BASE=2.0.0-1; FAMILY=2.0; DIST=sid ;;
  *) echo "Unsupported suite: $SUITE" >&2; exit 2 ;;
esac
VERSION="$BASE+0xddd$REVISION~$SUITE"
dpkg --compare-versions "$VERSION" gt "$BASE"
export DEBIAN_FRONTEND=noninteractive
if [[ "$SUITE" == experimental ]]; then
  cat >/etc/apt/sources.list.d/netavark-source.sources <<'EOF'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: sid experimental
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
else
  cat >/etc/apt/sources.list.d/netavark-source.sources <<EOF
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates dpkg-dev devscripts fakeroot quilt python3
apt-get build-dep -y "netavark=$BASE"

mkdir -p "/work/build/$SUITE/$ARCH" "/work/dist/$SUITE/$ARCH"
cd "/work/build/$SUITE/$ARCH"
apt-get source "netavark=$BASE"
DIR="$(find . -maxdepth 1 -mindepth 1 -type d -name 'netavark-*' -print -quit)"
[[ -n "$DIR" ]] || { echo "Missing extracted Debian source" >&2; exit 1; }
cd "$DIR"
[[ "$(dpkg-parsechangelog -SVersion)" == "$BASE" ]] || { echo "Source version changed" >&2; exit 1; }
export QUILT_PATCHES=debian/patches
quilt new 9999-allow-cross-bridge-published-ports.patch
quilt add src/firewall/nft.rs
python3 /work/scripts/apply.py --family "$FAMILY"
quilt refresh
python3 - debian/patches/9999-allow-cross-bridge-published-ports.patch <<'PY'
from pathlib import Path
import sys
f=Path(sys.argv[1])
f.write_text("""Description: Backport cross-bridge published-port forwarding
 Mark Netavark DNAT connections and accept before bridge isolation.
Origin: backport, https://github.com/containers/netavark/pull/1483
Bug: https://github.com/containers/netavark/issues/709
Forwarded: not-needed
Last-Update: 2026-10-26

""" + f.read_text())
PY

export DEBFULLNAME="xddd Netavark Backport"
export DEBEMAIL="netavark-backport@localhost"
dch --no-conf --newversion "$VERSION" --distribution "$DIST" --force-distribution \
  "Backport Netavark published-port isolation fix from PR #1483."
export DEB_BUILD_OPTIONS="parallel=2"
export CARGO_BUILD_JOBS=2
dpkg-buildpackage --build=full --no-sign -j2

cd ..
shopt -s nullglob
OUT="/work/dist/$SUITE/$ARCH"
files=("netavark_${VERSION}_${ARCH}.deb" "netavark_${VERSION}.dsc"
  "netavark_${VERSION}.debian.tar."* "netavark_"*.orig.tar.*
  "netavark_${VERSION}_${ARCH}.buildinfo" "netavark_${VERSION}_${ARCH}.changes")
for file in "${files[@]}"; do [[ ! -f "$file" ]] || cp "$file" "$OUT/"; done
[[ -f "$OUT/netavark_${VERSION}_${ARCH}.deb" ]] || { echo "Missing built .deb" >&2; exit 1; }
(cd "$OUT"; sha256sum -- * > SHA256SUMS)
ls -lh "$OUT"
