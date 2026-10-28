#!/usr/bin/env python3
"""Verify that a draft contains only the tested package/source set and valid hashes."""
import hashlib
import json
from pathlib import Path
import sys


def assets_by_target(versions: dict) -> dict[str, set[str]]:
    """Expected native binaries and sources for every published target."""
    targets = {}
    for family, names in (("debian", ("trixie", "forky", "sid")),
                          ("ubuntu", ("resolute", "stonking"))):
        for suite in names:
            item = versions[family][suite]
            version = f'{item["source"]}localxddd{item["revision"]}'
            files = {
                f"netavark_{version}_{arch}.deb"
                for arch in ("amd64", "arm64")
            }
            files.add(f'netavark-source-{suite}-xddd{item["revision"]}.tar.gz')
            targets[f"{family}/{suite}"] = files
    for family, names in (("fedora", ("43", "44")),
                          ("opensuse", ("16.0", "16.1"))):
        for release in names:
            item = versions[family][release]
            source = item["source"]
            revision = item["revision"]
            if family == "fedora":
                suffix = f".fc{release}"
                if not source.endswith(suffix):
                    raise ValueError(f"Invalid Fedora source release: {source}")
                version = f"{source[:-len(suffix)]}.xddd{revision}{suffix}"
            else:
                version = f"{source}.xddd{revision}"
            files = {
                f"netavark-{version}.{arch}.rpm"
                for arch in ("x86_64", "aarch64")
            }
            files.add(f"netavark-{version}.src.rpm")
            targets[f"{family}/{release}"] = files
    return targets


def expected_assets(versions: dict) -> set[str]:
    return {"versions.json"} | set().union(*assets_by_target(versions).values())


def main() -> None:
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: verify-release.py RELEASE_DIR [REVIEWED_VERSIONS_JSON]")
    directory = Path(sys.argv[1])
    manifest = directory / "versions.json"
    versions = json.loads(manifest.read_text())
    reviewed = Path(sys.argv[2]) if len(sys.argv) == 3 else Path("release/versions.json")
    if manifest.read_bytes() != reviewed.read_bytes():
        sys.exit("Release manifest differs from validated commit")
    expected = expected_assets(versions)
    actual = {file.name for file in directory.iterdir() if file.is_file()}
    if actual != expected | {"SHA256SUMS"}:
        sys.exit(f"Release asset mismatch: missing={sorted(expected - actual)}, "
                 f"unexpected={sorted(actual - expected - {'SHA256SUMS'})}")
    checksums: dict[str, str] = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        digest, separator, name = line.partition("  ")
        if not separator or name in checksums:
            sys.exit(f"Invalid or duplicate checksum entry: {line}")
        checksums[name] = digest
    if set(checksums) != expected:
        sys.exit("SHA256SUMS entries do not match the complete release asset set")
    for name in sorted(expected):
        digest = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if digest != checksums[name]:
            sys.exit(f"Checksum mismatch: {name}")
    print(f"Verified {len(expected)} hashed assets and SHA256SUMS")


if __name__ == "__main__":
    main()
