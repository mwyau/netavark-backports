#!/usr/bin/env bash
# Verify a complete same-run build before creating an immutable draft candidate.
set -Eeuo pipefail
shopt -s nullglob
mode="$1"
incoming="$2"
[[ "$mode" == verify || "$mode" == create ]] || {
  echo "usage: release.sh verify|create INCOMING_DIR" >&2; exit 2;
}
[[ -d "$incoming" ]] || { echo "Missing directory: $incoming" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

source_value() { python3 scripts/check-source-version.py --source "$1" "$2"; }
revision_value() { python3 scripts/check-source-version.py --revision "$1" "$2"; }
copy_exact() {
  local name="$1"
  local -a matches=()
  mapfile -d '' matches < <(find "$incoming" -type f -name "$name" -print0)
  [[ "${#matches[@]}" == 1 ]] || {
    echo "Expected exactly one input for $name, found ${#matches[@]}" >&2; exit 1;
  }
  cp "${matches[0]}" "$work/$name"
}

for suite in trixie forky sid resolute stonking; do
  family=debian
  [[ "$suite" == resolute || "$suite" == stonking ]] && family=ubuntu
  base="$(source_value "$family" "$suite")"
  rev="$(revision_value "$family" "$suite")"
  for arch in amd64 arm64; do
    copy_exact "netavark_$(printf '%s' "$base")a~xddd$rev~$suite"_"$arch.deb"
  done
  source_dir="$incoming/source-deb-$suite"
  [[ -d "$source_dir" ]] || { echo "Missing source bundle $suite" >&2; exit 1; }
  dsc=( "$source_dir"/*.dsc )
  changes=( "$source_dir"/*_source.changes )
  [[ "${#dsc[@]}" == 1 && "${#changes[@]}" == 1 ]] || {
    echo "Incomplete $suite source bundle" >&2; exit 1;
  }
  tar -czf "$work/netavark-source-$suite-xddd$rev.tar.gz" -C "$source_dir" .
done
for release in 43 44; do
  base="$(source_value fedora "$release")"
  rev="$(revision_value fedora "$release")"
  stem="$(printf '%s' "$base" | sed "s/\.fc$release\$//")"
  version="$stem.xddd$rev.fc$release"
  for arch in x86_64 aarch64; do
    copy_exact "netavark-$version.$arch.rpm"
  done
  copy_exact "netavark-$version.src.rpm"
done
for release in 16.0 16.1; do
  base="$(source_value opensuse "$release")"
  rev="$(revision_value opensuse "$release")"
  version="$base.xddd$rev"
  for arch in x86_64 aarch64; do
    copy_exact "netavark-$version.$arch.rpm"
  done
  copy_exact "netavark-$version.src.rpm"
done

cp release/versions.json "$work/versions.json"
(cd "$work"; sha256sum -- *.deb *.rpm *.tar.gz versions.json > SHA256SUMS)
python3 scripts/ci/verify-release.py "$work"

if [[ "$mode" == verify ]]; then
  echo "PR candidate asset assembly verified without creating a release"
  exit 0
fi

[[ "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF" == refs/heads/main ]] || {
  echo "Draft creation is restricted to the main-branch push workflow" >&2; exit 2;
}
: "$GH_TOKEN" "$GITHUB_REPOSITORY" "$GITHUB_SHA"
tag="netavark-g$(printf '%.12s' "$GITHUB_SHA")"
previous="$(gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 --json tagName \
  --jq '.[].tagName' | grep -E '^netavark-g[0-9a-f]{12}$' | head -n1 || true)"
if [[ -n "$previous" ]]; then
  previous_commit="$(gh release view "$previous" --repo "$GITHUB_REPOSITORY" \
    --json targetCommitish --jq '.targetCommitish')"
  [[ "$previous_commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Unverifiable previous draft target: $previous_commit" >&2; exit 1;
  }
  git cat-file -e "$previous_commit^{commit}"
  git show "$previous_commit:release/versions.json" > "$work/previous-versions.json"
  # Same-commit reruns and documentation updates do not create new drafts.
  if cmp -s release/versions.json "$work/previous-versions.json"; then
    changes="$(git diff --name-only "$previous_commit" "$GITHUB_SHA" -- patches scripts/build scripts/deb-version.sh)"
    if [[ -n "$changes" ]]; then
      echo "Packaging changed without changing per-distribution versions.json revisions:" >&2
      printf '%s\n' "$changes" >&2
      exit 1
    fi
    echo "No package revision changes since $previous; no new release"
    exit 0
  fi
  # Each changed source must also advance its own downstream revision.
  python3 - "$work/previous-versions.json" release/versions.json <<'PY'
import json
import sys
old, new = [json.load(open(p)) for p in sys.argv[1:]]
for family, targets in new.items():
    if family == "schema":
        continue
    for name, item in targets.items():
        before = old.get(family, {}).get(name)
        if before and (item["source"] != before["source"] or
                       item["revision"] != before["revision"]):
            if item["revision"] <= before["revision"]:
                sys.exit(f"Must increase {family}/{name} revision for a package update")
PY
fi

gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
  --draft --prerelease --title "Netavark backports $(printf '%.12s' "$GITHUB_SHA")" \
  --notes "Validated distribution-native Netavark backports. Review versions.json and SHA256SUMS before publication."
for file in "$work"/*; do
  [[ "$(basename "$file")" == previous-versions.json ]] && continue
  gh release upload "$tag" "$file" --repo "$GITHUB_REPOSITORY"
done
gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url,isDraft,tagName,assets \
  --jq '{url,isDraft,tagName,assets:[.assets[].name]}'
