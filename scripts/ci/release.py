#!/usr/bin/env python3
"""Assemble and verify complete, native-package GitHub Release snapshots."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from versions import deb_version


def assets_by_target(versions: dict) -> dict[str, set[str]]:
    """Expected native binaries and sources for every published target."""
    targets = {}
    for family, names in (("debian", ("trixie", "forky", "sid")),
                          ("ubuntu", ("resolute", "stonking"))):
        for suite in names:
            item = versions[family][suite]
            suffix = "ppaxddd" if family == "ubuntu" else "xddd"
            version = deb_version(item["source"], item["revision"], suite)
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




def gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True).strip()


def repository() -> str:
    repo = os.environ.get("GITHUB_REPOSITORY") or os.environ.get("GH_REPO")
    if not repo:
        sys.exit("GITHUB_REPOSITORY must be set")
    return repo


def release_tags(repo: str) -> list[str]:
    releases = json.loads(gh("release", "list", "--repo", repo, "--limit", "1000",
                            "--json", "tagName"))
    return [item["tagName"] for item in releases
            if re.fullmatch(r"netavark-\d{8}\.[1-9]\d*", item["tagName"])]


def latest_tag(repo: str) -> str:
    tags = release_tags(repo)
    return max(tags, key=lambda value: tuple(map(int, value.removeprefix("netavark-").split(".")))) if tags else ""


def prepare(incoming: Path, candidate: Path) -> None:
    base = os.environ.get("BASE_TAG", "")
    if base:
        if not re.fullmatch(r"netavark-\d{8}\.[1-9]\d*", base):
            sys.exit("Invalid BASE_TAG")
        with tempfile.TemporaryDirectory() as temp:
            previous = Path(temp)
            gh("release", "download", base, "--repo", repository(),
               "--dir", str(previous))
            verify(previous, previous / "versions.json")
            assemble(incoming, candidate, previous)
    else:
        assemble(incoming, candidate, None)
    verify(candidate, Path("release/versions.json"))
    print(f"Validated release snapshot: {candidate}")


def asset_label(name: str, versions: dict) -> str:
    if name == "versions.json":
        return "Distribution versions"
    if name == "SHA256SUMS":
        return "SHA256 checksums"
    labels = {"debian": "Debian", "ubuntu": "Ubuntu",
              "fedora": "Fedora", "opensuse": "openSUSE Leap"}
    for target, files in assets_by_target(versions).items():
        if name in files:
            family, release = target.split("/")
            label = f"{labels[family]} {release.title() if family in ('debian', 'ubuntu') else release}"
            if name.endswith((".tar.gz", ".src.rpm")):
                arch = "source"
            elif name.endswith(".deb"):
                arch = name.rsplit("_", 1)[-1].removesuffix(".deb")
            else:
                arch = name.rsplit(".", 2)[-2]
            return f"{label} — {arch}"
    sys.exit(f"Unrecognized asset: {name}")


def draft(candidate: Path) -> None:
    if (os.environ.get("GITHUB_REF") != "refs/heads/main" or
        os.environ.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch")):
        sys.exit("Draft creation requires validated main-branch CI")
    repo = repository()
    sha = os.environ["GITHUB_SHA"]
    verify(candidate, Path("release/versions.json"))
    base = os.environ.get("BASE_TAG", "")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    seq = max((int(tag.split(".")[-1]) for tag in release_tags(repo)
               if tag.startswith(f"netavark-{stamp}.")), default=0) + 1
    tag = f"netavark-{stamp}.{seq}"
    gh("release", "create", tag, "--repo", repo, "--target", sha,
       "--draft", "--prerelease", "--title", f"Netavark backports {tag}",
       "--notes", f"Validated snapshot from {sha}. Unchanged artifacts are carried from "
                  f"{base or 'the first build'}. Review versions.json and SHA256SUMS "
                  "before publication.")
    versions = json.loads((candidate / "versions.json").read_text())
    for path in sorted(candidate.iterdir()):
        gh("release", "upload", tag, f"{path}#{asset_label(path.name, versions)}",
           "--repo", repo)
    print(gh("release", "view", tag, "--repo", repo, "--json", "url,isDraft,tagName,assets"))


def publish(tag: str) -> None:
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        sys.exit("Publication requires the protected main branch")
    repo = repository()
    if not re.fullmatch(r"netavark-\d{8}\.[1-9]\d*", tag) or tag != latest_tag(repo):
        sys.exit(f"Refusing superseded or invalid release: {tag}")
    metadata = json.loads(gh("release", "view", tag, "--repo", repo,
                             "--json", "isDraft,isPrerelease,targetCommitish"))
    if not metadata["isDraft"] or not metadata["isPrerelease"]:
        sys.exit("Only validated draft prereleases may be published")
    target = metadata["targetCommitish"]
    if not re.fullmatch(r"[0-9a-f]{40}", target):
        sys.exit("Draft must point to a commit SHA")
    subprocess.run(["git", "merge-base", "--is-ancestor", target, "HEAD"], check=True)
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        gh("release", "download", tag, "--repo", repo, "--dir", str(directory))
        reviewed = subprocess.check_output(
            ["git", "show", f"{target}:release/versions.json"])
        # Keep the reviewed manifest outside the asset directory being verified.
        with tempfile.TemporaryDirectory() as manifest_dir:
            reviewed_path = Path(manifest_dir) / "versions.json"
            reviewed_path.write_bytes(reviewed)
            verify(directory, reviewed_path)
    gh("release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease=false")
    print(f"Published {tag}")


def main() -> None:
    args = sys.argv[1:]
    if args == ["latest"]:
        print(latest_tag(repository()))
    elif len(args) == 3 and args[0] == "prepare":
        prepare(Path(args[1]), Path(args[2]))
    elif len(args) == 2 and args[0] == "verify":
        verify(Path(args[1]), Path("release/versions.json"))
    elif len(args) == 3 and args[0] == "verify":
        verify(Path(args[1]), Path(args[2]))
    elif len(args) == 2 and args[0] == "draft":
        draft(Path(args[1]))
    elif len(args) == 2 and args[0] == "publish":
        publish(args[1])
    else:
        sys.exit("usage: release.py latest | prepare INCOMING CANDIDATE | "
                 "verify DIRECTORY [MANIFEST] | draft CANDIDATE | publish TAG")


if __name__ == "__main__":
    main()
