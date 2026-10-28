#!/usr/bin/env python3
"""Assemble and verify complete, native-package GitHub Release snapshots."""
import hashlib
import json
from pathlib import Path
import sys
import shutil
import tarfile


def assets_by_target(versions: dict) -> dict[str, set[str]]:
    """Expected native binaries and sources for every published target."""
    targets = {}
    for family, names in (("debian", ("trixie", "forky", "sid")),
                          ("ubuntu", ("resolute", "stonking"))):
        for suite in names:
            item = versions[family][suite]
            suffix = "ppaxddd" if family == "ubuntu" else "xddd"
            version = f'{item["source"]}{suffix}{item["revision"]}~{suite}'
            files = {
                f"netavark_{version}_{arch}.deb"
                for arch in ("amd64", "arm64")
            }
            files.add(f'netavark-source-{suite}-{suffix}{item["revision"]}.tar.gz')
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


def input_file(incoming: Path, name: str) -> Path:
    matches = [p for p in incoming.rglob(name) if p.is_file() and p.name == name]
    if len(matches) != 1:
        sys.exit(f"Expected one tested artifact {name}; found {len(matches)}")
    return matches[0]


def source_archive(incoming: Path, target: str, destination: Path) -> None:
    suite = target.split("/", 1)[1]
    directories = [p for p in incoming.rglob(f"source-deb-{suite}") if p.is_dir()]
    if len(directories) != 1:
        sys.exit(f"Missing source bundle for {target}")
    sources = sorted(p for p in directories[0].iterdir() if p.is_file())
    if (sum(p.name.endswith(".dsc") for p in sources) != 1 or
        sum(p.name.endswith("_source.changes") for p in sources) != 1):
        sys.exit(f"Incomplete native source bundle for {target}")
    with tarfile.open(destination, "w:gz") as archive:
        for source in sources:
            archive.add(source, arcname=source.name)



def assemble(incoming: Path, output: Path, previous: Path | None) -> None:
    current = json.loads(Path("release/versions.json").read_text())
    old = json.loads((previous / "versions.json").read_text()) if previous else {}
    new_targets = assets_by_target(current)
    output.mkdir(parents=True, exist_ok=True)
    old_entries = {
        f"{family}/{target}": value
        for family, targets in old.items() if family != "schema"
        for target, value in targets.items()
    }
    for target, assets in new_targets.items():
        family, name = target.split("/", 1)
        item = current[family][name]
        unchanged = bool(previous and old_entries.get(target) == item)
        if previous and not unchanged and old_entries.get(target):
            prior = old_entries[target]
            if item["source"] == prior["source"]:
                if item["revision"] <= prior["revision"]:
                    sys.exit(f"{target}: unchanged source must increment revision")
            elif item["revision"] != 1:
                sys.exit(f"{target}: new native source must reset revision to 1")
        for name in sorted(assets):
            destination = output / name
            if unchanged:
                shutil.copyfile(previous / name, destination)
            elif name.endswith(".tar.gz"):
                source_archive(incoming, target, destination)
            else:
                shutil.copyfile(input_file(incoming, name), destination)
        print(f"{target}: {'reused verified release assets' if unchanged else 'new tested artifacts'}")
    shutil.copyfile("release/versions.json", output / "versions.json")
    names = sorted(expected_assets(current))
    with (output / "SHA256SUMS").open("w") as checksums:
        for name in names:
            digest = hashlib.sha256((output / name).read_bytes()).hexdigest()
            checksums.write(f"{digest}  {name}\n")


def verify(directory: Path, reviewed: Path) -> None:
    manifest = directory / "versions.json"
    versions = json.loads(manifest.read_text())
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
    if sys.argv[1:2] == ["assemble"] and len(sys.argv) in (4, 5):
        assemble(Path(sys.argv[2]), Path(sys.argv[3]),
                 Path(sys.argv[4]) if len(sys.argv) == 5 else None)
    elif sys.argv[1:2] == ["verify"] and len(sys.argv) in (3, 4):
        verify(Path(sys.argv[2]),
               Path(sys.argv[3]) if len(sys.argv) == 4
               else Path("release/versions.json"))
    else:
        sys.exit("usage: release.py assemble INCOMING OUTPUT [PREVIOUS] | "
                 "verify DIRECTORY [REVIEWED_VERSIONS]")
