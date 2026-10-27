#!/usr/bin/env bash
# GitHub Releases: upload individual raw binaries; never Actions ZIP artifacts.
# Builds cannot publish final releases; this code creates and updates DRAFTS.
set -Eeuo pipefail
action="${1:?init, upload or finalize}"
: "${GITHUB_SHA:?}"
: "${GITHUB_REPOSITORY:?}"
REVISION="$(cat "${GITHUB_WORKSPACE:?}/release/revision.txt")"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid revision: $REVISION" >&2; exit 2; }
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || {
  echo "Refusing to write a release outside the protected main branch" >&2; exit 2;
}
tag="nv1483-r$REVISION-g${GITHUB_SHA:0:12}"
repo="$GITHUB_REPOSITORY"
case "$action" in
  init)
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
      echo "Refusing to reuse existing tag/release $tag" >&2; exit 1
    fi
    # Prevent publishing distinct package bytes under the same xddd revision.
    previous="$(gh release list --repo "$repo" --limit 1000 --json tagName \
      --jq '.[].tagName' | grep -E "^nv1483-r${REVISION}-g[0-9a-f]{12}$" || true)"
    [[ -z "$previous" ]] || {
      echo "xddd$REVISION already allocated: $previous" >&2
      echo "Bump release/revision.txt in a reviewed PR before another release" >&2
      exit 1
    }
    gh release create "$tag" --repo "$repo" --target "$GITHUB_SHA" \
      --draft --prerelease \
      --title "Netavark PR #1483 candidate r$REVISION (${GITHUB_SHA:0:12})" \
      --notes "Unreviewed draft. Per-distro raw binaries arrive only after runtime tests pass. No automatic publication. PR #1522 excluded."
    ;;
  upload)
    file="${2:?single .deb or .rpm path required}"
    [[ -f "$file" ]] || { echo "Package missing: $file" >&2; exit 1; }
    [[ "$file" == *.deb || "$file" == *.rpm ]] || {
      echo "Only individual raw .deb and .rpm supported" >&2; exit 2;
    }
    gh release view "$tag" --repo "$repo" --json isDraft \
      --jq .isDraft | grep -Fx true
    sha256sum "$file"
    # An existing asset is never clobbered on a retry.
    gh release upload "$tag" "$file" --repo "$repo"
    ;;
  finalize)
    gh release view "$tag" --repo "$repo" --json isDraft \
      --jq .isDraft | grep -Fx true
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    gh release download "$tag" --repo "$repo" --dir "$work" --pattern '*.deb'
    gh release download "$tag" --repo "$repo" --dir "$work" --pattern '*.rpm'
    shopt -s nullglob
    files=("$work"/*.deb "$work"/*.rpm)
    # 5 validated Debian/Ubuntu suites * 2 arches + 2 Fedora releases * 2.
    [[ "${#files[@]}" == 14 ]] || {
      echo "Expected exactly 14 individual candidate binaries, found ${#files[@]}" >&2
      printf '%s\n' "${files[@]}" >&2
      exit 1
    }
    for suite in trixie resolute stonking forky sid; do
      for arch in amd64 arm64; do
        matches=("$work"/netavark_*"+xddd$REVISION~${suite}_$arch.deb")
        [[ "${#matches[@]}" == 1 ]] || {
          echo "Missing or duplicate Debian/Ubuntu $suite/$arch candidate" >&2
          exit 1
        }
        [[ "$(dpkg-deb --field "${matches[0]}" Package)" == netavark ]] || exit 1
      done
    done
    for release in 43 44; do
      for arch in x86_64 aarch64; do
        matches=("$work"/netavark-1.17.2-*.xddd$REVISION.fc$release.$arch.rpm)
        [[ "${#matches[@]}" == 1 ]] || {
          echo "Missing/duplicate native Fedora $release / $arch RPM" >&2; exit 1;
        }
      done
    done
    (cd "$work" && sha256sum -- *.deb *.rpm > SHA256SUMS)
    gh release upload "$tag" "$work/SHA256SUMS" --repo "$repo"
    gh release edit "$tag" --repo "$repo" --notes \
      "DRAFT, NOT PUBLISHED: all required native builds and runtime tests passed. Assets: 10 standalone .deb, 4 standalone .rpm, SHA256SUMS. Experimental Netavark 2 excluded; openSUSE Leap is stock-only. PR #1522 excluded. Ubuntu PPA source files require a separate source-upload process. Review and approve manually."
    gh release view "$tag" --repo "$repo" --json url,isDraft,tagName,assets \
      --jq '{url,isDraft,tagName,assets:[.assets[].name]}'
    ;;
  *)
    echo "Unknown release subcommand $action" >&2
    exit 2 ;;
esac
