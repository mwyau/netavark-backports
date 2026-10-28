#!/usr/bin/env bash
# Pure helpers for native source-family and version selection. Used by build
# and validation; never hardcode a stale upstream Debian package revision.
set -Eeuo pipefail

netavark_source_family() {
  case "$1" in
    1.14.*-*) printf '1.14\n' ;;
    1.16.*-*) printf '1.16\n' ;;
    1.17.*-*) printf '1.17\n' ;;
    2.0.*-*)  printf '2.0\n' ;;
    *) echo "UNSUPPORTED native Netavark source version: $1" >&2; return 2 ;;
  esac
}

netavark_downstream_version() {
  local base="$1" revision="$2" suite="$3" suffix version
  [[ "$revision" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid revision" >&2; return 2; }
  case "$suite" in
    resolute|stonking) suffix="ppaxddd" ;;
    trixie|forky|sid|experimental) suffix="xddd" ;;
    *) echo "Invalid suite: $suite" >&2; return 2 ;;
  esac
  dpkg --validate-version "$base"
  version="${base}${suffix}${revision}~${suite}"
  dpkg --validate-version "$version"
  dpkg --compare-versions "$version" gt "$base" || {
    echo "Downstream package must supersede the exact native source" >&2
    return 2
  }
  printf '%s\n' "$version"
}

netavark_check_source_available() {
  local version="$1"
  apt-cache showsrc netavark | awk -v want="$version" '
    /^Version: / && $2 == want {found=1}
    END {exit (!found)}
  ' || {
    echo "FAIL: binary candidate $version lacks an available matching native deb-src" >&2
    return 1
  }
}
