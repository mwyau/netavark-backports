#!/usr/bin/env python3
"""Fast CI checks for version ordering, build selection and release assets."""

import json
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
    assert plan(manifest, manifest, {"scripts/ports.sh"}, "pull_request")[0] == {
        "debian/trixie", "debian/forky", "debian/sid",
        "ubuntu/resolute", "ubuntu/stonking",
    }


def check_release(manifest: dict) -> None:
    targets = release["assets_by_target"](manifest)
    assert len(release["expected_assets"](manifest)) == 28
    assert "netavark_1.17.2-3xddd1~forky_amd64.deb" in targets["debian/forky"]
    assert "netavark_1.16.1-3.1ppaxddd1~resolute_arm64.deb" in targets["ubuntu/resolute"]
    assert release["asset_label"]("netavark-1.17.2-1.xddd1.fc43.x86_64.rpm",
                                  manifest) == "Fedora 43 — x86_64"
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


if __name__ == "__main__":
    current = json.loads(Path("release/versions.json").read_text())
    check_versions()
    check_plan(current)
    check_release(current)
    print("PASS: version ordering, change selection and release verification")
