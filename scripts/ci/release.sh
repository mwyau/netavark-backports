#!/usr/bin/env bash
# Assemble verified artifacts from a single successful main-branch CI run.
set -Eeuo pipefail
[[ "${1:-}" == create ]] || { echo "usage: release.sh create INCOMING_DIR" >&2; exit 2; }
incoming="${2:?directory containing downloaded Actions artifacts}"
[[ -d "$incoming" ]] || { echo "Missing artifact directory: $incoming" >&2; exit 1; }
[[ "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == refs/heads/main ]] || {
  echo "Draft release assembly is restricted to successful main-branch CI" >&2; exit 2;
}
: "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
REVISION="$(cat "${GITHUB_WORKSPACE:?}/release/revision.txt")"
[[ "$REVISION" =~ ^[1-9][0-9]*$ ]] || exit 2
repo="$GITHUB_REPOSITORY"
tag="nv1483-r$REVISION-g${GITHUB_SHA:0:12}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
shopt -s nullglob

# Keep only the tested main binary RPMs, not debug or source RPMs.
# Exclude Debian experimental and experimental Leap binaries from the release.
mapfile -d '' binaries < <(
  find "$incoming" -type f \
    \( \( -name 'netavark_*_amd64.deb' -o -name 'netavark_*_arm64.deb' \) \
       ! -name '*~experimental_*' \
       -o -name 'netavark-1.17.2-*.fc43.x86_64.rpm' \
       -o -name 'netavark-1.17.2-*.fc43.aarch64.rpm' \
       -o -name 'netavark-1.17.2-*.fc44.x86_64.rpm' \
       -o -name 'netavark-1.17.2-*.fc44.aarch64.rpm' \) \
    -print0
)
[[ "${#binaries[@]}" == 14 ]] || {
  echo "Expected 14 tested DEB/Fedora RPM binaries, found ${#binaries[@]}" >&2; exit 1;
}
for f in "${binaries[@]}"; do
  [[ ! -e "$work/$(basename "$f")" ]] || { echo "Duplicate binary basename: $f" >&2; exit 1; }
  cp "$f" "$work/"
done
for suite in trixie resolute stonking forky sid; do
  for arch in amd64 arm64; do
    matches=("$work"/netavark_*"+xddd$REVISION~$suite"_"$arch".deb)
    [[ "${#matches[@]}" == 1 ]] || { echo "Missing $suite/$arch DEB" >&2; exit 1; }
    [[ "$(dpkg-deb --field "${matches[0]}" Package)" == netavark ]] || exit 1
  done
  src="$incoming/source-deb-$suite"
  [[ -d "$src" ]] || { echo "Missing Debian source artifact: $suite" >&2; exit 1; }
  ds=( "$src"/*.dsc )
  changes=( "$src"/*_source.changes )
  [[ "${#ds[@]}" == 1 && "${#changes[@]}" == 1 ]] || {
    echo "Incomplete Debian/Ubuntu source bundle $suite" >&2; exit 1;
  }
  tar -czf "$work/netavark-source-$suite-xddd$REVISION.tar.gz" -C "$src" .
done
for release in 43 44; do
  for arch in x86_64 aarch64; do
    rpms=( "$work"/netavark-1.17.2-*.xddd"$REVISION".fc"$release"."$arch".rpm )
    [[ "${#rpms[@]}" == 1 ]] || { echo "Missing Fedora $release/$arch RPM" >&2; exit 1; }
  done
  srpms=( "$incoming"/netavark-1.17.2-*.xddd"$REVISION".fc"$release".src.rpm/* )
  # A direct-file artifact downloads to a folder named after the source RPM.
  [[ "${#srpms[@]}" == 1 && "${srpms[0]}" == *.src.rpm ]] || {
    echo "Missing modified Fedora $release SRPM" >&2; exit 1;
  }
  cp "${srpms[0]}" "$work/"
done
(cd "$work"; sha256sum -- *.deb *.rpm *.tar.gz > SHA256SUMS)

# An existing release allocation of xdddN is not silently replaced.
previous="$(gh release list --repo "$repo" --limit 1000 --json tagName --jq '.[].tagName' |
  grep -E "^nv1483-r$REVISION-g[0-9a-f]{12}$" | head -n1 || true)"
if [[ -n "$previous" ]]; then
  old="$(gh release view "$previous" --repo "$repo" --json targetCommitish --jq .targetCommitish)"
  if [[ "$old" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "$old^{commit}" 2>/dev/null; then
    changes="$(git diff --name-only "$old" "$GITHUB_SHA" -- patches scripts tests release .github/workflows || true)"
    if [[ -z "$changes" ]]; then
      echo "Revision xddd$REVISION already has $previous; only docs changed, no new draft"
      exit 0
    fi
    echo "Source, tests or packaging changed without bumping release/revision.txt:" >&2
    printf '%s\n' "$changes" >&2
  else
    echo "Could not verify original revision target for $previous: $old" >&2
  fi
  exit 1
fi

gh release create "$tag" --repo "$repo" --target "$GITHUB_SHA" \
  --draft --prerelease \
  --title "Netavark backports xddd$REVISION" \
  --notes "Validated native packages and original source uploads from commit $GITHUB_SHA. Draft for review."
for f in "$work"/*; do
  gh release upload "$tag" "$f" --repo "$repo"
done
gh release view "$tag" --repo "$repo" --json url,isDraft,tagName,assets \
  --jq '{url,isDraft,tagName,assets:[.assets[].name]}'
