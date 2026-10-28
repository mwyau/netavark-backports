#!/usr/bin/env python3
"""Check automation syntax, package versions, CI planning and releases."""

import json
import os
import sys
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check_scripts() -> None:
    for directory in ("release", "scripts"):
        for path in sorted((ROOT / directory).glob("*.py")):
            compile(path.read_bytes(), str(path), "exec")
    for path in sorted((ROOT / "scripts/build").glob("*.sh")):
        subprocess.run(["bash", "-n", str(path)], check=True)


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
    required = {
        f"{family}/{target}"
        for family in ("debian", "ubuntu", "fedora", "opensuse")
        for target, item in manifest[family].items()
        if item["source"].split("-", 1)[0].startswith("1.17.")
    }
    assert plan(manifest, manifest, {"patches/1.17/change.patch"}, "pull_request")[0] == required
    try:
        plan(manifest, manifest, {"patches/1.17/change.patch"}, "push")
    except ValueError:
        pass
    else:
        raise AssertionError("A changed patch must increment affected revisions")
    assert not plan(manifest, manifest, {"scripts/check.py"}, "pull_request")[0]
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
        candidate = manifest["debian"]["trixie"]["source"] + "+discovery1"
        env = os.environ | {
            "SOURCE_DISCOVERY_ONLY": "1",
            "SOURCE_DISCOVERY_FILE": str(found),
        }
        subprocess.run(
            [sys.executable, "release/versions.py",
             "debian", "trixie", candidate],
            env=env, check=True, capture_output=True, text=True,
        )
        assert found.read_text() == candidate + "\n"
        assert manifest["debian"]["trixie"]["source"] != candidate

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


def check_merge() -> None:
    from unittest.mock import patch

    module = runpy.run_path("scripts/updates.py")
    merge = module["merge"]
    branch, sha = "bot/update-debian-trixie", "a" * 40
    repo = "mwyau/netavark-backports"
    calls = []

    def fake_output(*args: str) -> str:
        if args[1:3] == ("pr", "list"):
            return '[{"number":1}]'
        if args[1:3] == ("pr", "view"):
            return json.dumps({
                "headRefOid": sha, "headRefName": branch,
                "baseRefName": "main", "isCrossRepository": False,
            })
        if args[1:3] == ("pr", "diff"):
            return "release/versions.json"
        raise AssertionError(args)

    with patch.dict(merge.__globals__, {
        "output": fake_output, "command": lambda *args: calls.append(args),
    }):
        merge(repo, branch, sha)
        assert [args[1:3] for args in calls] == [
            ("pr", "merge"), ("workflow", "run"),
        ]
        calls.clear()
        try:
            merge(repo, "bot/not-an-update", sha)
        except SystemExit:
            pass
        else:
            raise AssertionError("Invalid update branch accepted")
        assert not calls


def check_distribution() -> None:
    from unittest.mock import patch

    module = runpy.run_path("release/distribute.py")
    manifest = json.loads(Path("release/versions.json").read_text())
    select = module["changed_targets"]
    assert select(manifest, None, "ppa") == ["ubuntu/resolute", "ubuntu/stonking"]
    assert not select(manifest, manifest, "ppa")
    previous = json.loads(json.dumps(manifest))
    previous["fedora"]["44"]["revision"] += 1
    assert select(manifest, previous, "copr") == ["fedora/44"]
    assert not select(manifest, previous, "obs")

    last = module["last_distributed"]
    repo, tag = "mwyau/netavark-backports", "netavark-20261028.1"

    def fake_gh(*args: str) -> str:
        if args[0] != "api":
            raise AssertionError(args)
        if args[1].startswith("repos/" + repo + "/deployments?"):
            return '[{"id":3},{"id":2}]'
        if "/deployments/3/statuses?" in args[1]:
            return '[{"state":"failure"}]'
        if "/deployments/2/statuses?" in args[1]:
            return json.dumps([{
                "state": "success",
                "environment_url": f"https://github.com/{repo}/releases/tag/{tag}",
            }])
        raise AssertionError(args)

    with patch.dict(last.__globals__, {"gh": fake_gh}):
        assert last(repo, "ppa") == tag

if __name__ == "__main__":
    os.chdir(ROOT)
    check_scripts()
    current = json.loads(Path("release/versions.json").read_text())
    check_versions()
    check_discovery(current)
    check_plan(current)
    check_release(current)
    check_merge()
    check_distribution()
    print("PASS: script syntax, version discovery and ordering, CI planning, merges, releases")
