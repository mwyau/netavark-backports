#!/usr/bin/env python3
"""Compare a native distribution source version with the reviewed version."""
import json
from pathlib import Path
import sys

if len(sys.argv) != 4 or sys.argv[1] not in ("debian", "ubuntu", "fedora", "opensuse"):
    sys.exit("usage: check-source-version.py debian|ubuntu|fedora|opensuse target version")

family, target, actual = sys.argv[1:]
version_file = Path(__file__).resolve().parent.parent / "release/source-versions.json"
versions = json.loads(version_file.read_text())
expected = versions[family].get(target)
if expected is None:
    sys.exit(f"No reviewed source version for {family}/{target}")
if actual != expected:
    sys.exit(
        f"Native source update for {family}/{target}: "
        f"reviewed={expected}, available={actual}. "
        "Review the package and patch; update release/source-versions.json "
        "and the downstream revision in a PR when preparing a new release."
    )
print(f"Native source unchanged: {family}/{target} {actual}")
