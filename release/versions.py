#!/usr/bin/env python3
"""Read the reviewed native source version and downstream package revision."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

manifest = Path(__file__).with_name("versions.json")
versions = json.loads(manifest.read_text())



DEBIAN_SUITES = {"trixie", "forky", "sid", "experimental"}
UBUNTU_SUITES = {"resolute", "stonking"}


def source_family(version: str) -> str:
    for family in ("1.14", "1.16", "1.17", "2.0"):
        if version.startswith(family + ".") and "-" in version:
            return family
    sys.exit(f"Unsupported native Netavark source version: {version}")


def deb_version(base: str, revision: int, suite: str) -> str:
    if revision < 1 or suite not in DEBIAN_SUITES | UBUNTU_SUITES:
        sys.exit("Invalid downstream revision or suite")
    suffix = "ppaxddd" if suite in UBUNTU_SUITES else "xddd"
    version = f"{base}{suffix}{revision}~{suite}"
    subprocess.run(["dpkg", "--validate-version", base], check=True)
    subprocess.run(["dpkg", "--validate-version", version], check=True)
    if subprocess.run(["dpkg", "--compare-versions", version, "gt", base]).returncode:
        sys.exit("Downstream package must supersede the native source")
    return version

def entry(family: str, target: str) -> dict:
    try:
        item = versions[family][target]
    except KeyError:
        sys.exit(f"Unknown distribution: {family}/{target}")
    if not isinstance(item, dict) or not isinstance(item.get("source"), str):
        sys.exit(f"Invalid reviewed source: {family}/{target}")
    revision = item.get("revision")
    if type(revision) is not int or revision < 1:
        sys.exit(f"Invalid downstream revision: {family}/{target}")
    return item


def validate() -> None:
    if versions.get("schema") != 1:
        sys.exit("Unsupported versions.json schema")
    targets = {
        "debian": {"trixie", "forky", "sid", "experimental"},
        "ubuntu": {"resolute", "stonking"},
        "fedora": {"43", "44"},
        "opensuse": {"16.0", "16.1"},
    }
    for family, expected in targets.items():
        if set(versions[family]) != expected:
            sys.exit(f"Unexpected targets in {family}")
        for target in expected:
            entry(family, target)



def validate_source(family: str, target: str, source: str) -> None:
    """Validate a source version discovered from the requested distribution."""
    entry(family, target)
    if not source or source != source.strip() or any(char.isspace() for char in source):
        sys.exit(f"Invalid {family}/{target} source version: {source!r}")
    if family in ("debian", "ubuntu"):
        subprocess.run(["dpkg", "--validate-version", source], check=True)
    else:
        if not re.fullmatch(r"[0-9][A-Za-z0-9.+_~]*-[0-9][A-Za-z0-9.+_~]*", source):
            sys.exit(f"Invalid RPM source version: {source!r}")
        native_release = source.rsplit("-", 1)[1]
        if family == "fedora" and not native_release.endswith(f".fc{target}"):
            sys.exit(f"Fedora source release does not match fc{target}: {source}")
        if family == "opensuse":
            major, minor = map(int, target.split("."))
            prefix = str(major * 10000 + minor * 100)
            if not native_release.startswith(prefix + "."):
                sys.exit(f"Leap source release does not match {target}: {source}")

def main() -> None:
    validate()
    if sys.argv[1:] == ["--validate"]:
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--family":
        print(source_family(sys.argv[2]))
        return
    if len(sys.argv) == 5 and sys.argv[1] == "--deb-version":
        try:
            revision = int(sys.argv[3])
        except ValueError:
            sys.exit("Invalid downstream revision")
        print(deb_version(sys.argv[2], revision, sys.argv[4]))
        return
    if len(sys.argv) == 5 and sys.argv[1] == "--check":
        family, target, source = sys.argv[2:]
        validate_source(family, target, source)
        expected = entry(family, target)["source"]
        status = "unchanged" if source == expected else f"new (reviewed: {expected})"
        print(f"{family}/{target}: {source} ({status})")
        return
    if len(sys.argv) == 5 and sys.argv[1] == "--update":
        family, target, source = sys.argv[2:]
        validate_source(family, target, source)
        item = entry(family, target)
        if item["source"] != source:
            old = item["source"]
            item["source"] = source
            item["revision"] = 1
            manifest.write_text(json.dumps(versions, indent=2) + "\n")
            print(f"{family}/{target}: {old} -> {source}, reset revision to 1")
        return
    if len(sys.argv) == 4 and sys.argv[1] in ("--revision", "--source"):
        item = entry(sys.argv[2], sys.argv[3])
        print(item["revision" if sys.argv[1] == "--revision" else "source"])
        return
    if len(sys.argv) == 4:
        family, target, actual = sys.argv[1:]
        validate_source(family, target, actual)
        expected = entry(family, target)["source"]
        discovered = os.environ.get("SOURCE_DISCOVERY_FILE")
        if discovered:
            output = Path(discovered)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(actual + "\n")
        if os.environ.get("SOURCE_DISCOVERY_ONLY") == "1":
            print(f"Discovered native source: {family}/{target} {actual}")
            return
        if actual != expected:
            sys.exit(
                f"Native source update for {family}/{target}: reviewed={expected}, "
                f"available={actual}. Review the patch and update release/versions.json "
                "in a pull request."
            )
        print(f"Native source unchanged: {family}/{target} {actual}")
        return
    sys.exit("usage: versions.py [--validate|--family VERSION|--deb-version BASE REVISION SUITE|\n             --update FAMILY TARGET VERSION|--check FAMILY TARGET VERSION|\n             --source FAMILY TARGET|"
             "--revision FAMILY TARGET|FAMILY TARGET ACTUAL]")


if __name__ == "__main__":
    main()
