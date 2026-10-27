#!/usr/bin/env bash
# Debian ordering and native revision inheritance regression.
set -Eeuo pipefail
source "$(dirname "$0")/../scripts/deb-version.sh"
for data in \
  '1.14.0-2 trixie 1.14.0-2+xddd1~trixie 1.14' \
  '1.14.0-2+deb13u1 trixie 1.14.0-2+deb13u1+xddd1~trixie 1.14' \
  '1.14.0-2+deb13u2 trixie 1.14.0-2+deb13u2+xddd1~trixie 1.14' \
  '1.16.1-3.1 resolute 1.16.1-3.1+xddd1~resolute 1.16' \
  '1.17.2-2 stonking 1.17.2-2+xddd1~stonking 1.17' \
  '2.0.0-1 experimental 2.0.0-1+xddd1~experimental 2.0'; do
  read -r base suite expect family <<<"$data"
  [[ "$(netavark_downstream_version "$base" 1 "$suite")" == "$expect" ]]
  [[ "$(netavark_source_family "$base")" == "$family" ]]
  dpkg --compare-versions "$base" lt "$expect"
done
dpkg --compare-versions '1.14.0-2+deb13u2' gt \
  '1.14.0-2+deb13u1+xddd1~trixie'
# A stale downstream build based on -2 would mask new official +deb13u1.
# The build therefore resolves the latest installed-candidate source each run.
dpkg --compare-versions '1.14.0-2+xddd1~trixie' gt '1.14.0-2+deb13u1'
if netavark_source_family '1.18.0-1'; then
  echo 'FAIL: unsupported family must not silently reuse an older patch' >&2
  exit 1
fi
echo "PASS: +xddd version sorting, security revision inheritance and fail-closed families"
