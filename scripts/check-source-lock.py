#!/usr/bin/env python3
"""Check selected native source versions against reviewed versions."""
import json
import pathlib
import sys
if len(sys.argv) != 4 or sys.argv[1] not in ("deb", "fedora", "opensuse"):
    sys.exit("usage: check-source-lock.py deb|fedora|opensuse target version")
family, target, version = sys.argv[1:]
path = pathlib.Path("/work/release/sources.lock.json")
if not path.exists():
    path = pathlib.Path(__file__).resolve().parent.parent / "release/sources.lock.json"
expected = json.loads(path.read_text())[family].get(target)
if version != expected:
    sys.exit(f"Native {family}/{target} source changed: reviewed={expected}, available={version}; update sources.lock.json and revision.txt after review")
print(f"Locked source: {family}/{target} {version}")
