#!/usr/bin/env python3
"""Propose upstream source updates and merge validated update PRs."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "")
MANIFEST = Path("release/versions.json")
BODY = ("Discovered from the native source repository. CI validates native package "
        "builds, networking regressions and patch applicability before automatic "
        "merge. The downstream revision resets to 1; publishing remains manual.")


def command(*args: str) -> None:
    subprocess.run(args, check=True)


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def propose(path: Path) -> None:
    family, target = path.stem.split("-", 1)
    version = path.read_text().strip()
    branch = f"bot/update-{family}-{target}"
    command("git", "switch", "-C", branch, "origin/main")
    command(sys.executable, "release/versions.py", "--update", family, target, version)
    if subprocess.run(["git", "diff", "--quiet", "--", str(MANIFEST)]).returncode == 0:
        print(f"No change: {family}/{target}")
        return
    subprocess.run(["git", "fetch", "origin",
                    f"refs/heads/{branch}:refs/remotes/origin/{branch}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    existing = subprocess.run(
        ["git", "show", f"origin/{branch}:{MANIFEST}"], capture_output=True)
    if existing.returncode == 0 and existing.stdout == MANIFEST.read_bytes():
        print(f"Existing proposal is up to date: {branch}")
        return
    command("git", "add", str(MANIFEST))
    command("git", "commit", "-m", f"build: update native {family}/{target} source to {version}")
    command("git", "push", "--force-with-lease", "origin", f"HEAD:refs/heads/{branch}")
    prs = json.loads(output("gh", "pr", "list", "--repo", REPO, "--head", branch,
                            "--state", "open", "--json", "number"))
    if not prs:
        command("gh", "pr", "create", "--repo", REPO, "--base", "main",
                "--head", branch, "--title",
                f"Update {family}/{target} Netavark source to {version}",
                "--body", BODY)
    # GITHUB_TOKEN-created PRs do not start pull_request workflows.
    command("gh", "workflow", "run", "ci.yml", "--repo", REPO, "--ref", branch)



def merge(repo: str, branch: str, expected_sha: str) -> None:
    """Merge the exact update PR commit that passed the native package matrix."""
    if not re.fullmatch(r"bot/update-(debian|ubuntu|fedora|opensuse)-[A-Za-z0-9.]+", branch):
        sys.exit(f"Not a source-update branch: {branch}")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_sha):
        sys.exit("Missing expected tested commit SHA")
    prs = json.loads(output("gh", "pr", "list", "--repo", repo, "--head", branch,
                            "--state", "open", "--json", "number"))
    if len(prs) != 1:
        sys.exit(f"Expected one open bot PR for {branch}; found {len(prs)}")
    number = str(prs[0]["number"])
    info = json.loads(output("gh", "pr", "view", number, "--repo", repo,
                             "--json",
                             "headRefOid,headRefName,baseRefName,isCrossRepository"))
    if (info["headRefOid"] != expected_sha or info["headRefName"] != branch
            or info["baseRefName"] != "main" or info["isCrossRepository"]):
        sys.exit("Bot PR changed or does not target this repository's main branch")
    files = output("gh", "pr", "diff", number, "--repo", repo, "--name-only").splitlines()
    if files != [str(MANIFEST)]:
        sys.exit(f"Unexpected bot PR files: {files}")
    command("gh", "pr", "merge", number, "--repo", repo, "--squash", "--delete-branch")
    # GITHUB_TOKEN merges do not start push workflows; validate main explicitly.
    command("gh", "workflow", "run", "ci.yml", "--repo", repo, "--ref", "main")


def main() -> None:
    if not os.environ.get("GH_TOKEN") or not REPO:
        sys.exit("GH_TOKEN and GITHUB_REPOSITORY are required")
    if sys.argv[1:] == ["propose"]:
        command("git", "config", "user.name", "github-actions[bot]")
        command("git", "config", "user.email",
                "41898282+github-actions[bot]@users.noreply.github.com")
        for discovered in sorted(Path("discovered").glob("*.txt")):
            propose(discovered)
    elif sys.argv[1:] == ["merge"]:
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            sys.exit("Automatic merge requires dispatched CI")
        branch = os.environ.get("BRANCH", "")
        if os.environ.get("GITHUB_REF_NAME") != branch:
            sys.exit("Workflow branch does not match requested merge")
        merge(REPO, branch, os.environ.get("EXPECTED_SHA", ""))
    else:
        sys.exit("usage: updates.py propose|merge")


if __name__ == "__main__":
    main()
