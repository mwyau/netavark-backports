#!/usr/bin/env python3
"""Read the reviewed native source version and downstream package revision."""
import json
from pathlib import Path
import sys

manifest = Path(__file__).resolve().parent.parent / "release/versions.json"
versions = json.loads(manifest.read_text())


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
    for family in ("debian", "ubuntu", "fedora", "opensuse"):
        for target in versions[family]:
            entry(family, target)


def main() -> None:
    validate()
    if sys.argv[1:] == ["--validate"]:
        return
    if len(sys.argv) == 4 and sys.argv[1] in ("--revision", "--source"):
        item = entry(sys.argv[2], sys.argv[3])
        print(item["revision" if sys.argv[1] == "--revision" else "source"])
        return
    if len(sys.argv) == 4:
        family, target, actual = sys.argv[1:]
        expected = entry(family, target)["source"]
        if actual != expected:
            sys.exit(
                f"Native source update for {family}/{target}: reviewed={expected}, "
                f"available={actual}. Review the patch and update release/versions.json "
                "in a pull request."
            )
        print(f"Native source unchanged: {family}/{target} {actual}")
        return
    sys.exit("usage: check-source-version.py [--validate|--source FAMILY TARGET|"
             "--revision FAMILY TARGET|FAMILY TARGET ACTUAL]")


if __name__ == "__main__":
    main()
