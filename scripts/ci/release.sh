#!/usr/bin/env bash
# Verify a full snapshot; create a draft only after a reviewed version change.
set -Eeuo pipefail
mode="${1:?verify or create}"
incoming="${2:?downloaded workflow artifacts}"
[[ "$mode" == verify || "$mode" == create ]] || exit 2
[[ -d "$incoming" ]] || { echo "Missing $incoming" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="${GITHUB_REPOSITORY:?}"
base="${BASE_TAG:-}"

if [[ -n "$base" ]]; then
  [[ "$base" =~ ^netavark-[0-9]{8}\.[1-9][0-9]*$ ]] || exit 2
  mkdir -p "$work/previous"
  gh release download "$base" --repo "$repo" --dir "$work/previous"
  python3 scripts/ci/verify-release.py "$work/previous" "$work/previous/versions.json"
  python3 scripts/ci/snapshot.py "$incoming" "$work/candidate" "$work/previous"
else
  python3 scripts/ci/snapshot.py "$incoming" "$work/candidate"
fi
python3 scripts/ci/verify-release.py "$work/candidate"

if [[ "$mode" == verify ]]; then
  echo "Verified complete release snapshot; no draft created"
  exit 0
fi
[[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF" == refs/heads/main ]] || {
  echo "Draft creation requires a push to main" >&2; exit 2;
}
: "${GH_TOKEN:?}" "${GITHUB_SHA:?}"
if [[ -n "$base" ]] && cmp -s "$work/previous/versions.json" release/versions.json; then
  echo "No new package revisions; refusing duplicate release" >&2
  exit 1
fi
tags="$(gh release list --repo "$repo" --limit 1000 --json tagName --jq '.[].tagName')"
stamp="$(date -u +%Y%m%d)"
last_seq="$(printf '%s\n' "$tags" |
  sed -nE "s/^netavark-${stamp}\.([1-9][0-9]*)$/\1/p" | sort -n | tail -n1)"
tag="netavark-${stamp}.$(( ${last_seq:-0} + 1 ))"
gh release create "$tag" --repo "$repo" --target "$GITHUB_SHA" \
  --draft --prerelease --title "Netavark backports $tag" \
  --notes "Validated snapshot from $GITHUB_SHA. Unchanged artifacts are carried from ${base:-the first build}. Review versions.json and SHA256SUMS before publication."
for asset in "$work/candidate"/*; do
  name="${asset##*/}"
  label=""
  case "$name" in
    netavark_*~trixie_*.deb|netavark-source-trixie-*) label="Debian Trixie" ;;
    netavark_*~forky_*.deb|netavark-source-forky-*) label="Debian Forky" ;;
    netavark_*~sid_*.deb|netavark-source-sid-*) label="Debian Sid" ;;
    netavark_*~resolute_*.deb|netavark-source-resolute-*) label="Ubuntu Resolute" ;;
    netavark_*~stonking_*.deb|netavark-source-stonking-*) label="Ubuntu Stonking" ;;
    *.fc43.*.rpm) label="Fedora 43" ;;
    *.fc44.*.rpm) label="Fedora 44" ;;
    *-160000.*.rpm) label="openSUSE Leap 16.0" ;;
    *-160100.*.rpm) label="openSUSE Leap 16.1" ;;
    versions.json) label="Distribution versions" ;;
    SHA256SUMS) label="SHA256 checksums" ;;
  esac
  if [[ "$name" == netavark-source-* || "$name" == *.src.rpm ]]; then
    label="$label — source"
  elif [[ "$name" == *.deb ]]; then
    arch="${name##*_}"
    label="$label — ${arch%.deb}"
  elif [[ "$name" == *.rpm ]]; then
    arch="${name%.rpm}"
    label="$label — ${arch##*.}"
  fi
  gh release upload "$tag" "$asset#${label:-$name}" --repo "$repo"
done
gh release view "$tag" --repo "$repo" --json url,isDraft,tagName,assets \
  --jq '{url,isDraft,tagName,assets:[.assets[].name]}'
