#!/usr/bin/env python3
"""Assemble a complete snapshot from tested changes and verified previous assets."""

import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location('verify_release', Path(__file__).with_name('verify-release.py'))
assert spec is not None and spec.loader is not None
verify = module_from_spec(spec)
spec.loader.exec_module(verify)
assets_by_target = verify.assets_by_target
expected_assets = verify.expected_assets


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


def main() -> None:
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: snapshot.py INCOMING OUTPUT [PREVIOUS_RELEASE_DIR]")
    incoming, output = map(Path, sys.argv[1:3])
    previous = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    current = json.loads(Path("release/versions.json").read_text())
    old = json.loads((previous / "versions.json").read_text()) if previous else {}
    old_targets = assets_by_target(old) if old else {}
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


if __name__ == "__main__":
    main()
