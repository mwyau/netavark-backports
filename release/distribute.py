#!/usr/bin/env python3
"""Verify published release assets and select changed distribution packages."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release import verify

TARGETS = {
    "ppa": ("ubuntu/resolute", "ubuntu/stonking"),
    "copr": ("fedora/43", "fedora/44"),
    "obs": ("opensuse/16.0", "opensuse/16.1"),
}
TAG_RE = re.compile(r"netavark-\d{8}\.[1-9]\d*")
SHA_RE = re.compile(r"[0-9a-f]{40}")


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def gh(*args: str) -> str:
    return output("gh", *args)


def release_info(tag: str, repo: str) -> str:
    if not TAG_RE.fullmatch(tag):
        sys.exit(f"Invalid release tag: {tag}")
    data = json.loads(gh("release", "view", tag, "--repo", repo,
                         "--json", "tagName,isDraft,isPrerelease,targetCommitish,publishedAt"))
    sha = data["targetCommitish"]
    if (data["tagName"] != tag or data["isDraft"] or data["isPrerelease"]
            or not data["publishedAt"] or not SHA_RE.fullmatch(sha)):
        sys.exit(f"Release {tag} is not a published, validated release")
    if output("git", "rev-parse", f"refs/tags/{tag}^{{commit}}") != sha:
        sys.exit(f"Release tag {tag} does not match its reviewed commit")
    subprocess.run(["git", "merge-base", "--is-ancestor", sha, "HEAD"], check=True)
    return sha


def reviewed_manifest(sha: str) -> dict:
    return json.loads(output("git", "show", f"{sha}:release/versions.json"))


def download_verified(tag: str, repo: str, sha: str, destination: Path) -> None:
    gh("release", "download", tag, "--repo", repo, "--dir", str(destination))
    with tempfile.TemporaryDirectory() as tmp:
        reviewed = Path(tmp) / "versions.json"
        reviewed.write_text(output("git", "show", f"{sha}:release/versions.json") + "\n")
        verify(destination, reviewed)


def latest_published(repo: str) -> str:
    releases = json.loads(gh("release", "list", "--repo", repo, "--limit", "1000",
                             "--exclude-drafts", "--exclude-pre-releases",
                             "--json", "tagName"))
    names = [item["tagName"] for item in releases
             if TAG_RE.fullmatch(item["tagName"])]
    return max(names, key=lambda tag: tuple(map(int, tag.removeprefix("netavark-").split(".")))) if names else ""


def last_distributed(repo: str, destination: str) -> str | None:
    """Use the last successful environment deployment, not the last GitHub tag."""
    endpoint = f"repos/{repo}/deployments?environment={destination}&per_page=100"
    deployments = json.loads(gh("api", endpoint))
    prefix = f"https://github.com/{repo}/releases/tag/"
    for deployment in deployments:
        statuses = json.loads(gh("api", f"repos/{repo}/deployments/{deployment['id']}/statuses?per_page=100"))
        if not statuses or statuses[0]["state"] not in ("success", "inactive"):
            continue
        url = next((status.get("environment_url") for status in statuses
                    if status.get("environment_url")), "")
        if not url.startswith(prefix) or not TAG_RE.fullmatch(url[len(prefix):]):
            sys.exit(f"{destination}: successful deployment has no recognizable release tag")
        return url[len(prefix):]
    return None


def changed_targets(current: dict, previous: dict | None, destination: str) -> list[str]:
    result = []
    for key in TARGETS[destination]:
        family, name = key.split("/", 1)
        if previous is None or current[family][name] != previous[family][name]:
            result.append(key)
    return result


def plan(tag: str, repo: str) -> dict:
    sha = release_info(tag, repo)
    if tag != latest_published(repo):
        sys.exit(f"Refusing superseded release {tag}")
    with tempfile.TemporaryDirectory() as temp:
        download_verified(tag, repo, sha, Path(temp))
    current = reviewed_manifest(sha)
    result = {"url": f"https://github.com/{repo}/releases/tag/{tag}"}
    for destination in TARGETS:
        prior_tag = last_distributed(repo, destination)
        previous = reviewed_manifest(release_info(prior_tag, repo)) if prior_tag else None
        selected = changed_targets(current, previous, destination)
        result[destination] = str(bool(selected)).lower()
        result[destination + "_targets"] = json.dumps(selected, separators=(",", ":"))
        print(f"{destination}: prior={prior_tag or 'none'}, changed={selected}")
    return result


def main() -> None:
    if sys.argv[1:] != ["plan"]:
        sys.exit("usage: distribute.py plan (TAG and GITHUB_REPOSITORY from environment)")
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        sys.exit("Distribution must run from main")
    repo = os.environ["GITHUB_REPOSITORY"]
    tag = os.environ["RELEASE_TAG"]
    result = plan(tag, repo)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as file:
        for key, value in result.items():
            file.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
