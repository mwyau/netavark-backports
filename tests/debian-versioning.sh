#!/usr/bin/env bash
# Debian ordering and native revision inheritance regression.
set -Eeuo pipefail
source "$(dirname "$0")/../scripts/deb-version.sh"
for data in \
  '1.14.0-2 trixie 1.14.0-2localxddd1 1.14' \
  '1.14.0-2+deb13u1 trixie 1.14.0-2+deb13u1localxddd1 1.14' \
  '1.14.0-2+deb13u2 trixie 1.14.0-2+deb13u2localxddd1 1.14' \
  '1.16.1-3.1 resolute 1.16.1-3.1localxddd1 1.16' \
  '1.17.2-2 stonking 1.17.2-2localxddd1 1.17' \
  '2.0.0-1 experimental 2.0.0-1localxddd1 2.0'; do
  read -r base suite expect family <<<"$data"
  [[ "$(netavark_downstream_version "$base" 1)" == "$expect" ]]
  [[ "$(netavark_source_family "$base")" == "$family" ]]
  dpkg --compare-versions "$base" lt "$expect"
done
dpkg --compare-versions '1.14.0-2+deb13u2' gt \
  '1.14.0-2+deb13u1localxddd1'
# Security updates must supersede an older backport even before we rebuild it.
dpkg --compare-versions '1.14.0-2+deb13u1' gt '1.14.0-2localxddd1'
dpkg --compare-versions '1.14.0-2+deb13u1localxddd1' gt '1.14.0-2+deb13u1'
dpkg --compare-versions '1.14.0-2+deb13u1localxddd1' gt '1.14.0-2localxddd1'
dpkg --compare-versions '1.16.1-3.1ubuntu1' gt '1.16.1-3.1localxddd1'
# A rebuilt downstream revision also advances in-place without a native update.
dpkg --compare-versions '1.14.0-2localxddd2' gt '1.14.0-2localxddd1'
dpkg --compare-versions '1.14.0-2+deb13u1localxddd1' gt '1.14.0-2localxddd2'
dpkg --compare-versions '1.16.1-3.1ubuntu1localxddd1' gt '1.16.1-3.1ubuntu1'
if netavark_source_family '1.18.0-1'; then
  echo 'FAIL: unsupported family must not silently reuse an older patch' >&2
  exit 1
fi
# New native source versions reset the independent downstream revision to xddd1.
dpkg --compare-versions '1.14.0-2+deb13u1localxddd1' gt '1.14.0-2localxddd9'
dpkg --compare-versions '1.14.0-2+deb13u2' gt '1.14.0-2+deb13u1localxddd9'
python3 - <<'PY'
import runpy

select = runpy.run_path("scripts/ci/plan.py")["plan"]
old = {"schema": 1, "debian": {"trixie": {"source": "1.14.0-2", "revision": 4}}}
new = {"schema": 1, "debian": {"trixie": {"source": "1.14.0-2+deb13u1", "revision": 1}}}
targets, versions = select(old, new, set(), "push")
assert targets == versions == {"debian/trixie"}
new["debian"]["trixie"]["revision"] = 2
try:
    select(old, new, set(), "push")
except ValueError:
    pass
else:
    raise AssertionError("A new native source must reset revision to 1")
new["debian"]["trixie"] = {"source": "1.14.0-2", "revision": 5}
assert select(old, new, set(), "push")[1] == {"debian/trixie"}
PY
echo "PASS: localxddd version sorting and security upgrade ordering"
