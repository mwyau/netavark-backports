#!/usr/bin/env python3
"""Verify that a draft contains only the tested package/source set and valid hashes."""
import hashlib
import json
from pathlib import Path
import sys


def expected_assets(versions: dict) -> set[str]:
    files = {"versions.json"}
    for family, targets in (("debian", ("trixie", "forky", "sid")),
                            ("ubuntu", ("resolute", "stonking"))):
        for suite in targets:
            item = versions[family][suite]
            version = f'{item["source"]}a~xddd{item["revision"]}~{suite}'
            for arch in ("amd64", "arm64"):
                files.add(f"netavark_{version}_{arch}.deb")
            files.add(f'netavark-source-{suite}-xddd{item["revision"]}.tar.gz')
    for family, targets in (("fedora", ("43", "44")),
                            ("opensuse", ("16.0", "16.1"))):
        for release in targets:
            item = versions[family][release]
            source = item["source"]
            revision = item["revision"]
            if family == "fedora":
                suffix = f".fc{release}"
                if not source.endswith(suffix):
                    raise ValueError(f"Invalid Fedora source release: {source}")
                stem = source[:-len(suffix)]
                package_version = f"{stem}.xddd{revision}{suffix}"
            else:
                package_version = f"{source}.xddd{revision}"
            for arch in ("x86_64", "aarch64"):
                files.add(f"netavark-{package_version}.{arch}.rpm")
            files.add(f"netavark-{package_version}.src.rpm")
    return files


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
