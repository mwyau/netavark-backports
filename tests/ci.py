#!/usr/bin/env python3
"""Fast CI checks for version ordering, build selection and release assets."""

import json
import os
import sys
from pathlib import Path
import runpy
import subprocess
import tempfile

versions = runpy.run_path("release/versions.py")
plan = runpy.run_path("scripts/plan.py")["plan"]
release = runpy.run_path("release/release.py")


def newer(left: str, right: str) -> None:
    subprocess.run(["dpkg", "--compare-versions", left, "gt", right], check=True)


def check_versions() -> None:
    for base, suite, expected, family in (
        ("1.14.0-2", "trixie", "1.14.0-2xddd1~trixie", "1.14"),
        ("1.14.0-2+deb13u1", "trixie", "1.14.0-2+deb13u1xddd1~trixie", "1.14"),
        ("1.17.2-3", "forky", "1.17.2-3xddd1~forky", "1.17"),
        ("1.16.1-3.1", "resolute", "1.16.1-3.1ppaxddd1~resolute", "1.16"),
        ("1.17.2-2", "stonking", "1.17.2-2ppaxddd1~stonking", "1.17"),
    ):
        assert versions["deb_version"](base, 1, suite) == expected
        assert versions["source_family"](base) == family
        newer(expected, base)
    assert versions["deb_version"]("1.17.2-3", 1, "forky") != \
        versions["deb_version"]("1.17.2-3", 1, "sid")
    newer("1.14.0-2+deb13u1", "1.14.0-2xddd9~trixie")
    newer("1.16.1-3.1ubuntu1", "1.16.1-3.1ppaxddd9~resolute")
    newer("1.14.0-2xddd2~trixie", "1.14.0-2xddd1~trixie")


def check_plan(manifest: dict) -> None:
    old = {"schema": 1, "debian": {"trixie": {"source": "1.14.0-2", "revision": 4}}}
    new = {"schema": 1, "debian": {"trixie": {"source": "1.14.0-2+deb13u1", "revision": 1}}}
    assert plan(old, new, set(), "push") == ({"debian/trixie"}, {"debian/trixie"})
    new["debian"]["trixie"]["revision"] = 2
    try:
        plan(old, new, set(), "push")
    except ValueError:
        pass
    else:
        raise AssertionError("A changed native version must reset its revision")
    required = {"debian/forky", "debian/sid", "ubuntu/stonking",
                "fedora/43", "fedora/44", "opensuse/16.1"}
    assert plan(manifest, manifest, {"patches/1.17/change.patch"}, "pull_request")[0] == required
    try:
        plan(manifest, manifest, {"patches/1.17/change.patch"}, "push")
    except ValueError:
        pass
    else:
        raise AssertionError("A changed patch must increment affected revisions")
    assert not plan(manifest, manifest, {"tests/ci.py"}, "pull_request")[0]
    assert plan(manifest, manifest, {"scripts/build/ports.sh"}, "pull_request")[0] == {
        "debian/trixie", "debian/forky", "debian/sid",
        "ubuntu/resolute", "ubuntu/stonking",
    }


def check_release(manifest: dict) -> None:
    targets = release["assets_by_target"](manifest)
    assert len(release["expected_assets"](manifest)) == 28
    for family, suite, arch in (("debian", "forky", "amd64"),
                                ("ubuntu", "resolute", "arm64")):
        entry = manifest[family][suite]
        version = versions["deb_version"](entry["source"], entry["revision"], suite)
        assert f"netavark_{version}_{arch}.deb" in targets[f"{family}/{suite}"]
    rpm = next(name for name in targets["fedora/43"] if name.endswith(".x86_64.rpm"))
    assert release["asset_label"](rpm, manifest) == "Fedora 43 — x86_64"
    with tempfile.TemporaryDirectory() as temp:
        incoming, candidate = Path(temp) / "incoming", Path(temp) / "candidate"
        for target, names in targets.items():
            for name in names:
                if name.endswith(".tar.gz"):
                    source = incoming / f"source-deb-{target.split('/')[1]}"
                    source.mkdir(parents=True, exist_ok=True)
                    (source / "netavark_dummy.dsc").write_text("dsc")
                    (source / "netavark_dummy_source.changes").write_text("changes")
                else:
                    incoming.mkdir(parents=True, exist_ok=True)
                    (incoming / name).write_bytes(name.encode())
        release["assemble"](incoming, candidate, None)
        release["verify"](candidate, Path("release/versions.json"))



def check_discovery(manifest: dict) -> None:
    # Every locked version must also satisfy the native source format.
    for family in ("debian", "ubuntu", "fedora", "opensuse"):
        for target, entry in manifest[family].items():
            versions["validate_source"](family, target, entry["source"])

    # A newly published source revision is discovered without rewriting the lock.
    with tempfile.TemporaryDirectory() as tmp:
        found = Path(tmp) / "debian-trixie.txt"
        env = os.environ | {
            "SOURCE_DISCOVERY_ONLY": "1",
            "SOURCE_DISCOVERY_FILE": str(found),
        }
        subprocess.run(
            [sys.executable, "release/versions.py",
             "debian", "trixie", "1.14.0-2+deb13u5"],
            env=env, check=True, capture_output=True, text=True,
        )
        assert found.read_text() == "1.14.0-2+deb13u5\n"
        assert manifest["debian"]["trixie"]["source"] != found.read_text().strip()

    for family, target, bad in (
        ("debian", "trixie", "invalid version"),
        ("ubuntu", "resolute", ""),
        ("fedora", "43", "1.17.2-2.fc44"),
        ("opensuse", "16.0", "1.14.1-160100.2.2"),
        ("opensuse", "16.1", "1.17.2-160000.2.2"),
    ):
        try:
            versions["validate_source"](family, target, bad)
        except (SystemExit, subprocess.CalledProcessError):
            pass
        else:
            raise AssertionError(f"Accepted invalid source: {family}/{target} {bad!r}")

if __name__ == "__main__":
    current = json.loads(Path("release/versions.json").read_text())
    check_versions()
    check_discovery(current)
    check_plan(current)
    check_release(current)
    print("PASS: version discovery, ordering, change selection and release verification")
