#!/usr/bin/env bash
set -Eeuo pipefail
SUITE="${SUITE:?Set Debian suite}"
EXPECTED_ARCH="${EXPECTED_ARCH:?Set amd64 or arm64}"
REVISION="${REVISION:-1}"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || exit 2
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "$EXPECTED_ARCH" ]] || { echo "Architecture mismatch: $ARCH vs $EXPECTED_ARCH" >&2; exit 2; }
# Keep the minimum native revision and expected patch-family independently.
# An official +deb13u1 / +ubuntuN security upload must become the NEW base.
case "$SUITE" in
  trixie) MINIMUM=1.14.0-2; FAMILY=1.14; DIST=trixie ;;
  resolute) MINIMUM=1.16.1-3.1; FAMILY=1.16; DIST=resolute ;;
  stonking) MINIMUM=1.17.2-2; FAMILY=1.17; DIST=stonking ;;
  forky) MINIMUM=1.17.2-3; FAMILY=1.17; DIST=forky ;;
  sid) MINIMUM=1.17.2-3; FAMILY=1.17; DIST=sid ;;
  experimental) MINIMUM=2.0.0-1; FAMILY=2.0; DIST=sid ;;
  *) echo "Unsupported suite: $SUITE" >&2; exit 2 ;;
esac
source /work/scripts/deb-version.sh
export DEBIAN_FRONTEND=noninteractive
if [[ "$SUITE" == experimental ]]; then
  cat >/etc/apt/sources.list.d/netavark-source.sources <<'EOF'
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: sid experimental
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
elif [[ "$SUITE" == resolute || "$SUITE" == stonking ]]; then
  # Use Ubuntu's actual source package, never a Debian binary relabelled as Ubuntu.
  if [[ "$ARCH" == arm64 ]]; then
    UBUNTU_ARCHIVE=http://ports.ubuntu.com/ubuntu-ports
  else
    UBUNTU_ARCHIVE=http://archive.ubuntu.com/ubuntu
  fi
  cat >/etc/apt/sources.list.d/netavark-source.sources <<EOF
Types: deb-src
URIs: $UBUNTU_ARCHIVE
Suites: $SUITE ${SUITE}-updates ${SUITE}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
else
  cat >/etc/apt/sources.list.d/netavark-source.sources <<EOF
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: $SUITE
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
  if [[ "$SUITE" == trixie ]]; then
    cat >/etc/apt/sources.list.d/netavark-trixie-security.sources <<'EOF'
Types: deb-src
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
    cat >/etc/apt/sources.list.d/netavark-trixie-updates.sources <<'EOF'
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
  fi
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates dpkg-dev devscripts fakeroot quilt python3
# Resolve the highest available NATIVE source revision across release,
# security and updates pockets. Do not silently remain based on stale -2.
BASE=""
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  if [[ -z "$BASE" ]] || dpkg --compare-versions "$candidate" gt "$BASE"; then
    BASE="$candidate"
  fi
done < <(apt-cache showsrc netavark | awk '/^Version: / {print $2}' | sort -u)
[[ -n "$BASE" ]] || { echo "FAIL: no distribution Netavark source"; exit 1; }
dpkg --compare-versions "$BASE" ge "$MINIMUM" || {
  echo "FAIL: distro Netavark $BASE older than required $MINIMUM" >&2; exit 1;
}
ACTUAL_FAMILY="$(netavark_source_family "$BASE")"
[[ "$ACTUAL_FAMILY" == "$FAMILY" ]] || {
  echo "FAIL: native Netavark $BASE changed patch family $FAMILY -> $ACTUAL_FAMILY" >&2
  exit 1
}
# Fail if the distribution binary security candidate is newer than our
# matching source index. Never unknowingly repackage a stale source.
BINARY_CANDIDATE="$(apt-cache policy netavark | awk '/Candidate:/ {print $2; exit}')"
if [[ -n "$BINARY_CANDIDATE" && "$BINARY_CANDIDATE" != "(none)" ]] &&
   dpkg --compare-versions "$BASE" lt "$BINARY_CANDIDATE"; then
  echo "FAIL: native binary $BINARY_CANDIDATE is newer than source $BASE" >&2
  exit 1
fi
source_family=debian
[[ "$SUITE" == resolute || "$SUITE" == stonking ]] && source_family=ubuntu
python3 /work/scripts/check-source-version.py "$source_family" "$SUITE" "$BASE"
netavark_check_source_available "$BASE"
if [[ "${SOURCE_CHECK_ONLY:-0}" == 1 ]]; then
  echo "Current native source matches release/source-versions.json: $source_family/$SUITE $BASE"
  exit 0
fi
VERSION="$(netavark_downstream_version "$BASE" "$REVISION" "$SUITE")"
printf 'Selecting native source %s (%s) -> candidate %s\n' "$BASE" "$FAMILY" "$VERSION"
apt-get build-dep -y "netavark=$BASE"

mkdir -p "/work/build/$SUITE/$ARCH" "/work/dist/$SUITE/$ARCH"
cd "/work/build/$SUITE/$ARCH"
apt-get source "netavark=$BASE"
DIR="$(find . -maxdepth 1 -mindepth 1 -type d -name 'netavark-*' -print -quit)"
[[ -n "$DIR" ]] || { echo "Missing extracted Debian source" >&2; exit 1; }
cd "$DIR"
[[ "$(dpkg-parsechangelog -SVersion)" == "$BASE" ]] || { echo "Source version changed" >&2; exit 1; }
# Ubuntu Stonking carries an obsolete prost 0.12.6 quilt downgrade,
# while upstream Netavark 1.17.2 supports the distro's prost 0.14.
# Debian fixed the same problem in netavark 1.17.2-3 (bug #1145651)
# by dropping obsolete prost 0.12 and mozim 3 patches.
if [[ "$SUITE" == stonking ]]; then
  # New distro updates may already have removed these old compatibility
  # patches. Accept either BOTH (remove and reapply remaining series) or
  # NEITHER. One without the other needs manual packaging review.
  prost_patch=0013-compile-against-prost-12.6.patch
  mozim_patch=0005-Compile-against-mozim-3.patch
  have_prost=0
  have_mozim=0
  grep -Fxq "$prost_patch" debian/patches/series && have_prost=1
  grep -Fxq "$mozim_patch" debian/patches/series && have_mozim=1
  [[ "$have_prost" == "$have_mozim" ]] || {
    echo "FAIL: changed native Ubuntu quilt series; review required" >&2; exit 1;
  }
  if [[ "$have_prost" == 1 ]]; then
    echo "=== Drop obsolete Ubuntu prost 0.12 / mozim 3 downgrade patches ==="
    test -f "debian/patches/$prost_patch"
    test -f "debian/patches/$mozim_patch"
    export QUILT_PATCHES=debian/patches
    quilt pop -a
    sed -i '/^0013-compile-against-prost-12[.]6[.]patch$/d; /^0005-Compile-against-mozim-3[.]patch$/d' debian/patches/series
    quilt push -a
  fi
  grep -Fq 'prost = "0.14.1"' Cargo.toml || {
    echo "FAIL: unexpected Netavark 1.17.2 prost dependency"; exit 1;
  }
  grep -Fq 'tonic = "0.14.2"' Cargo.toml || {
    echo "FAIL: unexpected Netavark 1.17.2 tonic dependency"; exit 1;
  }
fi
# Apply the version-specific, reviewed unified-diff patch with Debian quilt.
# No Python rewriting of upstream source is performed during the package build.
export QUILT_PATCHES=debian/patches
PATCH_NAME=9999-allow-cross-bridge-published-ports.patch
cp "/work/patches/$FAMILY/0001-allow-published-ports-across-isolated-bridges.patch" "debian/patches/$PATCH_NAME"
printf '%s\n' "$PATCH_NAME" >> debian/patches/series
quilt push "$PATCH_NAME"
grep -Fq 'const DNAT_MASK: u32 = 0x1000;' src/firewall/nft.rs
grep -Fq 'Ensure we allow the DNAT packets before we consult the isolation chains' src/firewall/nft.rs
grep -Fq 'let isolation_handle = get_matching_rules_in_chain(' src/firewall/nft.rs

export DEBFULLNAME="Albert Yau"
export DEBEMAIL="albert@xddd.org"
dch --no-conf --newversion "$VERSION" --distribution "$DIST" --force-distribution \
  "Backport Netavark published-port isolation fix from PR #1483."
# Prepare an uploadable native source package for every suite.
dpkg-buildpackage -S -sa -us -uc
export DEB_BUILD_OPTIONS="parallel=2"
export CARGO_BUILD_JOBS=2
dpkg-buildpackage --build=full --no-sign -j2

cd ..
shopt -s nullglob
OUT="/work/dist/$SUITE/$ARCH"
files=("netavark_${VERSION}_${ARCH}.deb" "netavark_${VERSION}.dsc"
  "netavark_${VERSION}_source.changes"
  "netavark_${VERSION}.debian.tar."* "netavark_"*.orig.tar.*
  "netavark_${VERSION}_${ARCH}.buildinfo" "netavark_${VERSION}_${ARCH}.changes")
for file in "${files[@]}"; do [[ ! -f "$file" ]] || cp "$file" "$OUT/"; done
[[ -f "$OUT/netavark_${VERSION}_${ARCH}.deb" ]] || { echo "Missing built .deb" >&2; exit 1; }
# Validate the binary package metadata and execute the packaged binary.
DEB="$OUT/netavark_${VERSION}_${ARCH}.deb"
[[ "$(dpkg-deb --field "$DEB" Package)" == "netavark" ]]
[[ "$(dpkg-deb --field "$DEB" Version)" == "$VERSION" ]]
[[ "$(dpkg-deb --field "$DEB" Architecture)" == "$ARCH" ]]
TMP_BIN="$(mktemp -d)"
trap 'rm -rf "$TMP_BIN"' EXIT
dpkg-deb --extract "$DEB" "$TMP_BIN"
BIN="$(find "$TMP_BIN" -type f -name netavark -perm /111 -print -quit)"
[[ -n "$BIN" ]] || { echo "Netavark binary missing in deb" >&2; exit 1; }
"$BIN" --version | grep -F 'netavark'
(cd "$OUT"; sha256sum -- * > SHA256SUMS)
mkdir -p "$OUT/source"
for file in "$OUT"/*.dsc "$OUT"/*.debian.tar.* "$OUT"/*.orig.tar.* \
  "$OUT"/*_source.changes "$OUT"/*_source.buildinfo; do
  [[ -f "$file" ]] && cp "$file" "$OUT/source/" || :
done
test -n "$(find "$OUT/source" -maxdepth 1 -name '*.dsc' -print -quit)"
test -n "$(find "$OUT/source" -maxdepth 1 -name '*_source.changes' -print -quit)"
ls -lh "$OUT"
