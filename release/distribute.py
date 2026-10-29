#!/usr/bin/env python3
"""Verify published release assets and select changed distribution packages."""

import json
import os
from pathlib import Path
import re
import shlex
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



def check_environments(repo: str) -> None:
    """Fail closed if destination approval protections are not configured."""
    for name in TARGETS:
        settings = json.loads(gh("api", f"repos/{repo}/environments/{name}"))
        rules = settings.get("protection_rules") or []
        reviewers = [rule for rule in rules if rule.get("type") == "required_reviewers"
                     and rule.get("reviewers")]
        if not reviewers:
            sys.exit(f"{name}: required environment reviewers must be configured")
        policy = settings.get("deployment_branch_policy") or {}
        if not (policy.get("protected_branches") or policy.get("custom_branch_policies")):
            sys.exit(f"{name}: restrict deployments to the protected main branch")

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




def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        sys.exit(f"Missing distribution configuration: {name}")
    return value


def run(*args: str, **kwargs: object) -> None:
    subprocess.run(args, check=True, **kwargs)


def submit_ppa(assets: Path, manifest: dict, targets: list[str]) -> None:
    import tarfile

    ppa = required("PPA_TARGET")
    fingerprint = required("PPA_GPG_FINGERPRINT")
    secret_key = required("PPA_GPG_PRIVATE_KEY")
    passphrase = required("PPA_GPG_PASSPHRASE")
    if not re.fullmatch(r"ppa:[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]+", ppa):
        sys.exit("Invalid PPA destination")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", fingerprint):
        sys.exit("PPA key must be specified by its full fingerprint")
    with tempfile.TemporaryDirectory() as scratch:
        gnupg = Path(scratch) / "gnupg"
        gnupg.mkdir(mode=0o700)
        env = {key: value for key, value in os.environ.items()
               if key not in ("PPA_GPG_PRIVATE_KEY", "PPA_GPG_PASSPHRASE")} | {
                   "GNUPGHOME": str(gnupg), "GPG_TTY": ""}
        passphrase_file = Path(scratch) / "passphrase"
        passphrase_file.write_text(passphrase + "\n")
        passphrase_file.chmod(0o600)
        wrapper = Path(scratch) / "gpg-loopback"
        wrapper.write_text(
            "#!/bin/sh\nexec /usr/bin/gpg --batch --no-tty --pinentry-mode loopback "
            "--passphrase-file " + shlex.quote(str(passphrase_file)) + ' "$@"\n'
        )
        wrapper.chmod(0o700)
        subprocess.run(["gpg", "--batch", "--import"], input=secret_key,
                       text=True, check=True, env=env,
                       stdout=subprocess.DEVNULL)
        run("gpg", "--batch", "--list-secret-keys", fingerprint, env=env,
            stdout=subprocess.DEVNULL)
        for target in targets:
            suite = target.split("/")[1]
            item = manifest["ubuntu"][suite]
            archive = assets / f"netavark-source-{suite}-ppaxddd{item['revision']}.tar.gz"
            directory = Path(scratch) / suite
            directory.mkdir()
            with tarfile.open(archive) as tar:
                members = tar.getmembers()
                if (not members or len({m.name for m in members}) != len(members)
                        or any(not m.isfile() or Path(m.name).name != m.name
                               for m in members)):
                    sys.exit(f"Unsafe source archive: {archive.name}")
                for member in members:
                    data = tar.extractfile(member)
                    if data is None:
                        sys.exit("Missing archive member data")
                    with (directory / member.name).open("wb") as stream:
                        stream.write(data.read())
            changes = list(directory.glob("*_source.changes"))
            if len(changes) != 1 or len(list(directory.glob("*.dsc"))) != 1:
                sys.exit(f"Incomplete PPA source: {suite}")
            run("debsign", "--re-sign", "-p", str(wrapper), f"-k{fingerprint}", str(changes[0]), env=env)
            run("dput", ppa, str(changes[0]), env=env)


def submit_copr(assets: Path, manifest: dict, targets: list[str]) -> None:
    project = required("COPR_PROJECT")
    config = required("COPR_CONFIG")
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]+", project):
        sys.exit("COPR_PROJECT must be owner/project")
    with tempfile.TemporaryDirectory() as home:
        settings = Path(home) / ".config"
        settings.mkdir()
        config_file = settings / "copr"
        config_file.write_text(config)
        config_file.chmod(0o600)
        for target in targets:
            fedora = target.split("/")[1]
            native = manifest["fedora"][fedora]
            suffix = f".fc{fedora}"
            if not native["source"].endswith(suffix):
                sys.exit(f"Invalid Fedora source suffix for {fedora}")
            version = f"{native['source'][:-len(suffix)]}.xddd{native['revision']}{suffix}"
            source = assets / f"netavark-{version}.src.rpm"
            if not source.is_file():
                sys.exit(f"Missing Fedora {fedora} source RPM")
            # The COPR client runs in a Fedora image; no host tools are installed.
            run("docker", "run", "--rm", "--pull=always",
                "--security-opt", "no-new-privileges", "-v", f"{home}:/home:ro",
                "-v", f"{assets.resolve()}:/assets:ro", "-e", "HOME=/home",
                "fedora:44", "bash", "-ec",
                'dnf -y install copr-cli >/dev/null; exec copr-cli "$@"',
                "_", "build", "--chroot", f"fedora-{fedora}-x86_64",
                "--chroot", f"fedora-{fedora}-aarch64", project,
                f"/assets/{source.name}")


def submit_obs(assets: Path, targets: list[str]) -> None:
    config = required("OBS_CONFIG")
    projects = {
        leap: required("OBS_PROJECT_" + leap.replace(".", "_"))
        for leap in {target.split("/")[1] for target in targets}
    }
    with tempfile.TemporaryDirectory() as home:
        config_dir = Path(home) / ".config" / "osc"
        config_dir.mkdir(parents=True)
        config_file = config_dir / "oscrc"
        config_file.write_text(config)
        config_file.chmod(0o600)
        env = {key: value for key, value in os.environ.items()
               if key != "OBS_CONFIG"} | {
                   "HOME": home, "XDG_CONFIG_HOME": str(Path(home) / ".config")}
        for target in targets:
            leap = target.split("/")[1]
            source = json.loads((assets / "versions.json").read_text())["opensuse"][leap]
            filename = f"netavark-{source['source']}.xddd{source['revision']}.src.rpm"
            entry = assets / filename
            # Match exact expected filenames rather than guessing an RPM glob.
            if not entry.is_file():
                sys.exit(f"Missing openSUSE {leap} source RPM")
            with tempfile.TemporaryDirectory() as work:
                run("osc", "importsrcpkg", "--commit", "--delete-old-files",
                    "--project", projects[leap], "--name", "netavark",
                    str(entry), cwd=work, env=env)


def submit(destination: str, tag: str, repo: str, requested: list[str]) -> None:
    if destination not in TARGETS or not requested or len(requested) != len(set(requested)):
        sys.exit("Invalid distribution targets")
    if any(key not in TARGETS[destination] for key in requested):
        sys.exit("Distribution includes unsupported targets")
    sha = release_info(tag, repo)
    if tag != latest_published(repo):
        sys.exit(f"Refusing superseded release {tag}")
    current = reviewed_manifest(sha)
    with tempfile.TemporaryDirectory() as tmp:
        assets = Path(tmp)
        download_verified(tag, repo, sha, assets)
        previous_tag = last_distributed(repo, destination)
        previous = reviewed_manifest(release_info(previous_tag, repo)) if previous_tag else None
        actual = changed_targets(current, previous, destination)
        if requested != actual:
            sys.exit(f"Distribution plan changed during approval: {requested} != {actual}")
        if destination == "ppa":
            submit_ppa(assets, current, requested)
        elif destination == "copr":
            submit_copr(assets, current, requested)
        else:
            submit_obs(assets, requested)

def main() -> None:
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        sys.exit("Distribution must run from main")
    repo = os.environ["GITHUB_REPOSITORY"]
    tag = os.environ["RELEASE_TAG"]
    if sys.argv[1:] == ["plan"]:
        if os.environ.get("DISTRIBUTION_ENABLED") == "true":
            check_environments(repo)
        result = plan(tag, repo)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as file:
            for key, value in result.items():
                file.write(f"{key}={value}\n")
    elif len(sys.argv) == 3 and sys.argv[1] == "submit":
        destination = sys.argv[2]
        requested = json.loads(required("DISTRIBUTION_TARGETS"))
        if not isinstance(requested, list):
            sys.exit("Invalid distribution target list")
        submit(destination, tag, repo, requested)
    else:
        sys.exit("usage: distribute.py plan | submit ppa|copr|obs")


if __name__ == "__main__":
    main()
