#!/usr/bin/env bash
# Native openSUSE Leap source RPM builder. Experimental until both arches pass.
set -Eeuo pipefail
LEAP_VERSION="${LEAP_VERSION:?expected 16.0 or 16.1}"
EXPECTED_ARCH="${EXPECTED_ARCH:?x86_64 or aarch64}"
[[ "$LEAP_VERSION" == 16.0 || "$LEAP_VERSION" == 16.1 ]] || exit 2
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || exit 2
ARCH="$(rpm --eval '%{_arch}')"
[[ "$ARCH" == "$EXPECTED_ARCH" ]] || exit 2
case "$LEAP_VERSION" in
  16.0) FAMILY=1.14; PLATFORM=leap16 ;;
  16.1) FAMILY=1.17; PLATFORM=leap161 ;;
esac
REVISION="$(python3 /work/scripts/check-source-version.py --revision opensuse "$LEAP_VERSION")"
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install --no-recommends \
  rpm-build patch python3 findutils tar gzip
zypper --non-interactive addrepo -f \
  "https://download.opensuse.org/source/distribution/leap/$LEAP_VERSION/repo/oss/" netavark-native-source
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive source-install -D netavark
top="$(rpm --eval '%{_topdir}')"
spec="$top/SPECS/netavark.spec"
[[ -s "$spec" ]] || { echo "Missing Leap netavark SPEC: $spec" >&2; exit 1; }
source_version="$(rpm -q --define 'default_firewall_backend nftables' --specfile --qf '%{VERSION}\n' "$spec" | head -n1)"
native_release="$(rpm -q --define 'default_firewall_backend nftables' --specfile --qf '%{RELEASE}\n' "$spec" | head -n1)"
[[ -n "$native_release" && "$native_release" != "(none)" ]] || exit 1
python3 /work/scripts/check-source-version.py opensuse "$LEAP_VERSION" "$source_version-$native_release"
if [[ "${SOURCE_CHECK_ONLY:-0}" == 1 ]]; then
  echo "Current native source matches release/source-versions.json: opensuse/$LEAP_VERSION"
  exit 0
fi
grep -Eq '^%autosetup([[:space:]]|$)' "$spec" || {
  echo "Unknown native SPEC patch application; needs review" >&2; exit 1;
}
# Native Leap uses %autosetup -a1; the reviewed unified diff has a/ and b/
# prefixes, which require -p1. Existing native patches must be checked too.
if grep -Eq '^Patch[0-9]+:' "$spec"; then
  echo "Existing native patch series requires manual review before changing strip level" >&2
  exit 1
fi
sed -i '/^%autosetup[[:space:]]/s/^%autosetup /%autosetup -p1 /' "$spec"
grep -Eq '^Release:[[:space:]]*' "$spec" || exit 1
[[ "$native_release" != *xddd* ]] || exit 1
cp "/work/patches/$FAMILY/0001-allow-published-ports-across-isolated-bridges.patch" \
  "$top/SOURCES/9000-netavark-published-ports.patch"
awk '
  /^%description([[:space:]]|$)/ && !done {
    print "Patch9000: 9000-netavark-published-ports.patch"
    done=1
  }
  {print}
  END {if (!done) exit 1}
' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
sed -i "0,/^Release:[[:space:]]*/s/^Release:[[:space:]]*.*/Release: ${native_release}.xddd${REVISION}/" "$spec"
zypper --non-interactive source-install -d netavark
rpmbuild -ba "$spec" --define "_topdir $top" --define '_smp_mflags -j2' --define 'default_firewall_backend nftables'
out="/work/dist/$PLATFORM/$ARCH"
mkdir -p "$out/source"
shopt -s nullglob
packages=("$top"/RPMS/"$ARCH"/netavark-[0-9]*.xddd"$REVISION"."$ARCH".rpm)
sources=("$top"/SRPMS/netavark-[0-9]*.xddd"$REVISION".src.rpm)
[[ "${#packages[@]}" == 1 && "${#sources[@]}" == 1 ]] || {
  echo "Expected exactly one patched Leap RPM and SRPM" >&2; exit 1;
}
cp "${packages[0]}" "$out/"
cp "${sources[0]}" "$out/source/"
cp "$spec" "$out/source/netavark.spec"
cp "$top/SOURCES/9000-netavark-published-ports.patch" "$out/source/"
rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$out"/*.rpm
(cd "$out" && sha256sum -- *.rpm > SHA256SUMS)
