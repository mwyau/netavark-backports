#!/usr/bin/env python3
"""Propose native source updates; merge only after dispatched CI passes."""

import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    if not os.environ.get("GH_TOKEN") or not REPO:
        sys.exit("GH_TOKEN and GITHUB_REPOSITORY are required")
    command("git", "config", "user.name", "github-actions[bot]")
    command("git", "config", "user.email",
            "41898282+github-actions[bot]@users.noreply.github.com")
    for discovered in sorted(Path("discovered").glob("*.txt")):
        propose(discovered)
