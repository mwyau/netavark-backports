#!/usr/bin/env bash
# Verify a full snapshot; create a draft only after a reviewed version change.
set -Eeuo pipefail
mode="${1:?verify or create}"
incoming="${2:?path to artifacts}"
[[ "$mode" == verify || "$mode" == create ]] || exit 2
repo="${GITHUB_REPOSITORY:?}"
base="${BASE_TAG:-}"

if [[ "$mode" == verify ]]; then
  [[ -d "$incoming" ]] || exit 1
  if [[ -n "$base" ]]; then
    previous="$(mktemp -d)"
    trap 'rm -rf "$previous"' EXIT
    gh release download "$base" --repo "$repo" --dir "$previous"
    python3 scripts/ci/release.py verify "$previous" "$previous/versions.json"
    python3 scripts/ci/release.py assemble "$incoming" candidate "$previous"
  else
    python3 scripts/ci/release.py assemble "$incoming" candidate
  fi
  python3 scripts/ci/release.py verify candidate
  echo "Verified complete snapshot in candidate/"
  exit 0
fi

[[ "$GITHUB_REF" == refs/heads/main ]] || exit 2
[[ "$GITHUB_EVENT_NAME" == push || "$GITHUB_EVENT_NAME" == workflow_dispatch ]] || exit 2
: "${GH_TOKEN:?}" "${GITHUB_SHA:?}"
python3 scripts/ci/release.py verify "$incoming"
tags="$(gh release list --repo "$repo" --limit 1000 --json tagName --jq '.[].tagName')"
stamp="$(date -u +%Y%m%d)"
last_seq="$(printf '%s\n' "$tags" |
  sed -nE "s/^netavark-${stamp}\.([1-9][0-9]*)$/\1/p" | sort -n | tail -n1)"
tag="netavark-${stamp}.$(( ${last_seq:-0} + 1 ))"
gh release create "$tag" --repo "$repo" --target "$GITHUB_SHA" \
  --draft --prerelease --title "Netavark backports $tag" \
  --notes "Validated snapshot from $GITHUB_SHA. Unchanged artifacts are carried from ${base:-the first build}. Review versions.json and SHA256SUMS before publication."
for asset in "$incoming"/*; do
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
