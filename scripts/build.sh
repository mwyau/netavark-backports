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
  resolute) BASE=1.16.1-3.1; FAMILY=1.16; DIST=resolute ;;
  stonking) BASE=1.17.2-2; FAMILY=1.17; DIST=stonking ;;
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
Suites: $SUITE
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
# Ubuntu Stonking carries an obsolete prost 0.12.6 quilt downgrade,
# while upstream Netavark 1.17.2 supports the distro's prost 0.14.
# Debian fixed the same problem in netavark 1.17.2-3 (bug #1145651)
# by removing 0013-compile-against-prost-12.6.patch.
if [[ "$SUITE" == stonking ]]; then
  echo "=== Removing obsolete Ubuntu prost 0.12 quilt patch ==="
  export QUILT_PATCHES=debian/patches
  test -f debian/patches/0013-compile-against-prost-12.6.patch
  grep -Fxq '0013-compile-against-prost-12.6.patch' debian/patches/series
  quilt pop -a
  sed -i '/^0013-compile-against-prost-12[.]6[.]patch$/d' debian/patches/series
  quilt push -a
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
if [[ "$SUITE" == resolute || "$SUITE" == stonking ]]; then
  # Launchpad PPAs accept signed source uploads, not CI-built binary .debs.
  # Produce an unsigned _source.changes to sign on a trusted local machine.
  dpkg-buildpackage -S -sa -us -uc
fi
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
ls -lh "$OUT"
 Cargo.toml || {
    echo "FAIL: unexpected Netavark 1.17.2 prost requirement" >&2; exit 1;
  }
  grep -Eq '^tonic = "0\.14\.2"
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
if [[ "$SUITE" == resolute || "$SUITE" == stonking ]]; then
  # Launchpad PPAs accept signed source uploads, not CI-built binary .debs.
  # Produce an unsigned _source.changes to sign on a trusted local machine.
  dpkg-buildpackage -S -sa -us -uc
fi
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
ls -lh "$OUT"
 Cargo.toml || {
    echo "FAIL: unexpected Netavark 1.17.2 tonic requirement" >&2; exit 1;
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
if [[ "$SUITE" == resolute || "$SUITE" == stonking ]]; then
  # Launchpad PPAs accept signed source uploads, not CI-built binary .debs.
  # Produce an unsigned _source.changes to sign on a trusted local machine.
  dpkg-buildpackage -S -sa -us -uc
fi
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
ls -lh "$OUT"
