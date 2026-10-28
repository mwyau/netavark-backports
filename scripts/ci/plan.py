#!/usr/bin/env python3
"""Select affected native builds from a single reviewed versions.json."""

import json
import os
import re
import subprocess
from pathlib import Path

DEB = {
    "debian/trixie": ("debian", "trixie"),
    "debian/forky": ("debian", "forky"),
    "debian/sid": ("debian", "sid"),
    "debian/experimental": ("debian", "experimental"),
    "ubuntu/resolute": ("ubuntu", "resolute"),
    "ubuntu/stonking": ("ubuntu", "stonking"),
}
RPM = {
    "fedora/43": ("fedora43", "fedora-43", "fedora:43"),
    "fedora/44": ("fedora44", "fedora-44", "fedora:44"),
    "opensuse/16.0": ("leap16", "opensuse-leap-16.0", "opensuse/leap:16.0"),
    "opensuse/16.1": ("leap161", "opensuse-leap-16.1", "opensuse/leap:16.1"),
}
ALL = set(DEB) | set(RPM)
RELEASE = ALL - {"debian/experimental"}
PATCHES = {
    "1.14": {"debian/trixie", "opensuse/16.0"},
    "1.16": {"ubuntu/resolute"},
    "1.17": {"debian/forky", "debian/sid", "ubuntu/stonking",
             "fedora/43", "fedora/44", "opensuse/16.1"},
    "2.0": {"debian/experimental"},
}


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def manifest(ref: str) -> dict:
    if not ref:
        return {}
    try:
        return json.loads(git("show", f"{ref}:release/versions.json"))
    except (subprocess.CalledProcessError, ValueError):
        return {}


def entries(data: dict) -> dict:
    return {
        f"{family}/{suite}": item
        for family, targets in data.items() if family != "schema"
        for suite, item in targets.items()
    }


def plan(old: dict, new: dict, paths: set[str], event: str) -> tuple[set[str], set[str]]:
    previous, current = entries(old), entries(new)
    version_changes = {key for key in ALL if previous.get(key) != current.get(key)}
    # The first release of this repository builds every release target.
    if not previous:
        return set(ALL), version_changes
    changed = set(version_changes)
    if event != "push":
        for path in paths:
            match = re.fullmatch(r"patches/([^/]+)/.*", path)
            if match:
                changed |= PATCHES.get(match.group(1), ALL)
            elif path in {"scripts/build/deb.sh", "scripts/deb-version.sh",
                          "scripts/ci/deb.sh"}:
                changed |= set(DEB)
            elif path == "scripts/build/fedora.sh":
                changed |= {key for key in RPM if key.startswith("fedora/")}
            elif path == "scripts/build/opensuse.sh":
                changed |= {key for key in RPM if key.startswith("opensuse/")}
            elif path == "scripts/ci/rpm.sh":
                changed |= set(RPM)
            elif (path.startswith("tests/") or path in {
                  "scripts/ci/common.sh", "scripts/ci/plan.py",
                  "scripts/check-source-version.py", ".github/workflows/build.yml"}):
                changed |= ALL
    for key in version_changes:
        before, after = previous.get(key), current.get(key)
        if not before or not after:
            raise ValueError(f"{key}: distribution targets cannot be added/removed silently")
        if after["source"] == before["source"]:
            if after["revision"] <= before["revision"]:
                raise ValueError(f"{key}: unchanged source requires a higher revision")
        elif after["revision"] != 1:
            raise ValueError(f"{key}: new native source must reset revision to 1")
    return changed, version_changes


def matrices(targets: set[str]) -> tuple[list[dict], list[dict]]:
    deb, rpm = [], []
    for key, (family, suite) in DEB.items():
        if key not in targets:
            continue
        for arch in ("amd64", "arm64"):
            deb.append({
                "os": family, "suite": suite, "arch": arch,
                "runner": ("ubuntu-26.04" if family == "ubuntu" else "ubuntu-24.04")
                + ("-arm" if arch == "arm64" else ""),
            })
    for key, (platform, label, image) in RPM.items():
        if key not in targets:
            continue
        for arch in ("x86_64", "aarch64"):
            rpm.append({
                "platform": platform, "label": label, "image": image,
                "arch": arch, "runner": "ubuntu-24.04-arm"
                if arch == "aarch64" else "ubuntu-24.04",
            })
    return deb, rpm


def main() -> None:
    before = os.environ.get("BASE_REF", "")
    current = json.loads(Path("release/versions.json").read_text())
    old = manifest(before)
    paths = set(git("diff", "--name-only", before, "HEAD").splitlines()) if before else set()
    changed, versions = plan(old, current, paths, os.environ.get("EVENT_NAME", "pull_request"))
    deb, rpm = matrices(changed)
    release = bool(versions & RELEASE)
    output = {
        "deb": json.dumps({"include": deb}, separators=(",", ":")),
        "rpm": json.dumps({"include": rpm}, separators=(",", ":")),
        "has_deb": str(bool(deb)).lower(),
        "has_rpm": str(bool(rpm)).lower(),
        "has_builds": str(bool(changed)).lower(),
        "release": str(release).lower(),
    }
    print(f"Build targets: {sorted(changed)}")
    print(f"Version changes: {sorted(versions)}")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
        for key, value in output.items():
            stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
