#!/usr/bin/env bash
# Rebuild Fedora 43/44 native source RPM with PR #1483 only.
set -Eeuo pipefail
FEDORA_RELEASE="${FEDORA_RELEASE:?expected Fedora 43 or 44}"
REVISION="${REVISION:?positive integer downstream revision required}"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid downstream revision" >&2; exit 2; }
[[ "$FEDORA_RELEASE" == 43 || "$FEDORA_RELEASE" == 44 ]] || { echo "Unsupported Fedora release" >&2; exit 2; }
EXPECTED_ARCH="${EXPECTED_ARCH:?expected x86_64 or aarch64}"
ARCH="$(rpm --eval '%{_arch}')"
[[ "$ARCH" == "$EXPECTED_ARCH" ]] || { echo "FAIL: architecture mismatch"; exit 2; }
grep -q "release $FEDORA_RELEASE" /etc/fedora-release
dnf -y install dnf-plugins-core rpm-build rpmdevtools git-core patch
mkdir -p "/work/dist/fedora${FEDORA_RELEASE}/$ARCH" /tmp/netavark-fedora-src
cd /tmp/netavark-fedora-src
dnf download --source netavark
shopt -s nullglob
SRPMS=(netavark-1.17.2-*.src.rpm)
[[ "${#SRPMS[@]}" == 1 ]] || { echo "FAIL: missing pinned Fedora $FEDORA_RELEASE 1.17.2 SRPM"; exit 1; }
rpm -ivh --nodeps "${SRPMS[0]}"
SPEC="$(find /root/rpmbuild/SPECS -maxdepth 1 -name netavark.spec -print -quit)"
[[ -n "$SPEC" ]] || exit 1
grep -Eq '^Version:[[:space:]]*1[.]17[.]2[[:space:]]*$' "$SPEC"
grep -Eq '^Release:[[:space:]]*%autorelease[[:space:]]*$' "$SPEC"
grep -Fq '%autosetup' "$SPEC"
cp /work/patches/1.17/0001-allow-published-ports-across-isolated-bridges.patch \
  /root/rpmbuild/SOURCES/9000-allow-cross-bridge-published-ports.patch
sed -i '/^%description$/i Patch9000: 9000-allow-cross-bridge-published-ports.patch' "$SPEC"
sed -i 's/^Release:[[:space:]]*%autorelease$/Release: 1.xddd${REVISION}%{?dist}/' "$SPEC"
dnf -y builddep "$SPEC"
rpmbuild -ba "$SPEC" --define '_smp_mflags -j2'
shopt -s nullglob
RPMS=(/root/rpmbuild/RPMS/"$ARCH"/netavark-1.17.2-1.xddd${REVISION}.fc${FEDORA_RELEASE}."$ARCH".rpm)
[[ "${#RPMS[@]}" == 1 ]] || {
  echo "FAIL: expected one Fedora patched RPM"; find /root/rpmbuild/RPMS -name 'netavark*.rpm'; exit 1;
}
OUT="/work/dist/fedora${FEDORA_RELEASE}/$ARCH"
cp "${RPMS[0]}" "$OUT/"
rpm -qp --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' "$OUT"/*.rpm
sha256sum "$OUT"/*.rpm | tee "$OUT/SHA256SUMS"
