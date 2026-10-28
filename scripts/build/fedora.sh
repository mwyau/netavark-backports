#!/usr/bin/env bash
# Rebuild Fedora 43/44 native source RPM with PR #1483 only.
set -Eeuo pipefail
FEDORA_RELEASE="${FEDORA_RELEASE:?expected Fedora 43 or 44}"
[[ "$FEDORA_RELEASE" == 43 || "$FEDORA_RELEASE" == 44 ]] || { echo "Unsupported Fedora release" >&2; exit 2; }
REVISION="$(python3 /work/scripts/check-source-version.py --revision fedora "$FEDORA_RELEASE")"
EXPECTED_ARCH="${EXPECTED_ARCH:?expected x86_64 or aarch64}"
ARCH="$(rpm --eval '%{_arch}')"
[[ "$ARCH" == "$EXPECTED_ARCH" ]] || { echo "FAIL: architecture mismatch"; exit 2; }
grep -q "release $FEDORA_RELEASE" /etc/fedora-release
dnf -y install dnf-plugins-core rpm-build rpmdevtools git-core patch python3
mkdir -p "/work/dist/fedora${FEDORA_RELEASE}/$ARCH" /tmp/netavark-fedora-src
cd /tmp/netavark-fedora-src
dnf download --source netavark
shopt -s nullglob
SRPMS=(netavark-*.src.rpm)
[[ "${#SRPMS[@]}" == 1 ]] || { echo "FAIL: expected exactly one Fedora Netavark SRPM"; exit 1; }
# Preserve the exact native Fedora SRPM release (including a security
# update), rather than resetting it to Release: 1 each CI invocation.
NATIVE_RELEASE="$(rpm -qp --qf '%{RELEASE}' "${SRPMS[0]}")"
NATIVE_EPOCH="$(rpm -qp --qf '%{EPOCH}' "${SRPMS[0]}")"
NATIVE_VERSION="$(rpm -qp --qf '%{VERSION}' "${SRPMS[0]}")"
[[ "$NATIVE_RELEASE" == *".fc$FEDORA_RELEASE" ]] || {
  echo "FAIL: unexpected Fedora native SRPM release $NATIVE_RELEASE" >&2; exit 1;
}
NATIVE_RELEASE_STEM="${NATIVE_RELEASE%.fc$FEDORA_RELEASE}"
[[ "$NATIVE_RELEASE_STEM" =~ ^[0-9]+([.][0-9]+)*$ ]] || {
  echo "FAIL: native release needs human review: $NATIVE_RELEASE" >&2; exit 1;
}
python3 /work/scripts/check-source-version.py fedora "$FEDORA_RELEASE" "$NATIVE_VERSION-$NATIVE_RELEASE"
if [[ "${SOURCE_CHECK_ONLY:-0}" == 1 ]]; then
  echo "Current native source matches release/source-versions.json: fedora/$FEDORA_RELEASE"
  exit 0
fi
[[ "$NATIVE_VERSION" == 1.17.2 ]] || { echo "FAIL: unsupported Netavark patch family"; exit 1; }
printf 'Native Fedora %s source: %s:%s-%s\n' "$FEDORA_RELEASE" "$NATIVE_EPOCH" "$NATIVE_VERSION" "$NATIVE_RELEASE"
rpm -ivh --nodeps "${SRPMS[0]}"
SPEC="$(find /root/rpmbuild/SPECS -maxdepth 1 -name netavark.spec -print -quit)"
[[ -n "$SPEC" ]] || exit 1
grep -Eq '^Version:[[:space:]]*1[.]17[.]2[[:space:]]*$' "$SPEC"
grep -Eq '^Release:[[:space:]]*%autorelease[[:space:]]*$' "$SPEC"
grep -Fq '%autosetup' "$SPEC"
cp /work/patches/1.17/0001-allow-published-ports-across-isolated-bridges.patch \
  /root/rpmbuild/SOURCES/9000-allow-cross-bridge-published-ports.patch
sed -i '/^%description$/i Patch9000: 9000-allow-cross-bridge-published-ports.patch' "$SPEC"
sed -i "s/^Release:[[:space:]]*%autorelease\$/Release: ${NATIVE_RELEASE_STEM}.xddd${REVISION}%{?dist}/" "$SPEC"
dnf -y builddep "$SPEC"
rpmbuild -ba "$SPEC" --define '_smp_mflags -j2'
shopt -s nullglob
RPMS=(/root/rpmbuild/RPMS/"$ARCH"/netavark-1.17.2-*.xddd${REVISION}.fc${FEDORA_RELEASE}."$ARCH".rpm)
[[ "${#RPMS[@]}" == 1 ]] || {
  echo "FAIL: expected one Fedora patched RPM"; find /root/rpmbuild/RPMS -name 'netavark*.rpm'; exit 1;
}
NATIVE_BINARY="netavark-1.17.2-${NATIVE_RELEASE}"
NEW_BINARY_RELEASE="$(rpm -qp --qf '%{RELEASE}' "${RPMS[0]}")"
[[ "$NEW_BINARY_RELEASE" == "${NATIVE_RELEASE_STEM}.xddd${REVISION}.fc${FEDORA_RELEASE}" ]] || {
  echo "FAIL: built release does not inherit native Fedora SRPM version" >&2; exit 1;
}
OUT="/work/dist/fedora${FEDORA_RELEASE}/$ARCH"
cp "${RPMS[0]}" "$OUT/"
mkdir -p "$OUT/source"
source_rpms=(/root/rpmbuild/SRPMS/netavark-1.17.2-*.xddd"$REVISION".fc"$FEDORA_RELEASE".src.rpm)
test "${#source_rpms[@]}" -eq 1 || { echo "Missing modified Fedora SRPM" >&2; exit 1; }
cp "${source_rpms[0]}" "$OUT/source/"
rpm -qp --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' "$OUT"/*.rpm
sha256sum "$OUT"/*.rpm | tee "$OUT/SHA256SUMS"
