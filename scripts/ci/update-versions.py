#!/usr/bin/env python3
"""Update one native source lock; reset its downstream rebuild revision."""
import json
from pathlib import Path
import sys

if len(sys.argv) != 4:
    sys.exit("usage: update-versions.py FAMILY TARGET NATIVE_VERSION")
family, target, source = sys.argv[1:]
path = Path("release/versions.json")
versions = json.loads(path.read_text())
item = versions[family][target]
if not source.strip() or any(c.isspace() for c in source):
    sys.exit("Invalid native source version")
if item["source"] != source:
    old = item["source"]
    item["source"] = source
    item["revision"] = 1
    path.write_text(json.dumps(versions, indent=2) + "\n")
    print(f"{family}/{target}: {old} -> {source}, reset xddd revision to 1")
