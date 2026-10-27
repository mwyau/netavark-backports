#!/usr/bin/env bash
# Disposable, privileged Podman regression test for Debian and Ubuntu.
# NETAVARK_TEST_MODE=baseline checks the distribution package's basic networking.
# NETAVARK_TEST_MODE=patched also checks the host-published cross-bridge fix.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NETAVARK_FW=nftables
MODE="${NETAVARK_TEST_MODE:-patched}"
[[ "$MODE" == baseline || "$MODE" == patched ]] || { echo "Invalid test mode: $MODE" >&2; exit 2; }
ARCH="$(dpkg --print-architecture)"

apt-get update
apt-get install -y --no-install-recommends podman aardvark-dns curl jq nftables iproute2 ca-certificates
if [[ "$MODE" == patched ]]; then
  shopt -s nullglob
  DEBS=(/packages/netavark_*_"$ARCH".deb)
  [[ "${#DEBS[@]}" == 1 ]] || { echo "Expected one netavark package for $ARCH, found ${#DEBS[@]}" >&2; exit 1; }
  apt-get install -y "${DEBS[0]}"
fi

echo "=== OS / packages / Podman backend / mode=$MODE ==="
cat /etc/os-release
dpkg-query -W netavark podman aardvark-dns
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark

# Avoid overlay-on-overlay in outer Docker. Nested cgroup controllers are not delegated.
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

cleanup() {
  podman rm -f nv_server >/dev/null 2>&1 || true
  podman network rm nv_source nv_target >/dev/null 2>&1 || true
}
diagnostics() {
  echo "=== Podman diagnostic state ===" >&2
  podman ps -a >&2 || true
  podman inspect nv_server --format 'status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' >&2 || true
  podman logs nv_server >&2 || true
  ip -4 addr >&2 || true
  nft -a list table inet netavark >&2 || true
}
trap cleanup EXIT
trap 'rc=$?; if (( rc != 0 )); then diagnostics; fi' ERR

podman network create --subnet 10.241.21.0/24 --opt isolate=true nv_source
podman network create --subnet 10.241.22.0/24 --opt isolate=true nv_target

podman run --cgroups=disabled -d --name nv_server --network nv_target \
  -p 0.0.0.0:18081:8080 docker.io/library/python:3.12-alpine \
  sh -c 'set -eu; mkdir -p /www; echo PUBLISHED_PORT_OK >/www/index.html; exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /www'

# A running container is NOT proof its HTTP server is ready.
ready=false
for attempt in $(seq 1 30); do
  if podman exec nv_server wget -q -T 2 -O- http://127.0.0.1:8080/ 2>/dev/null \
       | grep -qx 'PUBLISHED_PORT_OK'; then
    ready=true
    break
  fi
  if [[ "$(podman inspect nv_server --format '{{.State.Running}}')" != true ]]; then
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "FAIL: HTTP service did not become ready in nv_server" >&2
  diagnostics
  exit 1
fi
echo "PASS: server reachable on loopback in its own network namespace"

client_get() {
  local network="$1" url="$2"
  podman run --cgroups=disabled --rm --network "$network" \
    docker.io/library/alpine:3.20 wget -q -T 5 -O- "$url"
}

# Preserve ordinary same-bridge traffic and DNS (baseline and candidate).
if ! client_get nv_target http://nv_server:8080/ | grep -qx 'PUBLISHED_PORT_OK'; then
  echo "FAIL: same-bridge container connectivity or DNS broke" >&2
  exit 1
fi
echo "PASS: same-bridge TCP and Aardvark DNS"

HOST_IP="$(ip -4 -o addr show dev eth0 | awk '{split($4, a, "/"); print a[1]; exit}')"
[[ -n "$HOST_IP" ]] || { echo "FAIL: missing guest eth0 address" >&2; exit 1; }
if ! curl -fsS --connect-timeout 5 --max-time 10 "http://$HOST_IP:18081/" \
     | grep -qx 'PUBLISHED_PORT_OK'; then
  echo "FAIL: host namespace cannot reach published TCP port" >&2
  exit 1
fi
echo "PASS: host namespace reaches published TCP port"

# Direct container-to-container access across isolated bridges must remain denied.
SERVER_IP="$(podman inspect nv_server | jq -r '.[0].NetworkSettings.Networks.nv_target.IPAddress')"
[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "FAIL: could not inspect server IPv4 address" >&2
  exit 1
}
if client_get nv_source "http://$SERVER_IP:8080/" | grep -qx 'PUBLISHED_PORT_OK'; then
  echo "FAIL: direct traffic bypassed bridge isolation" >&2
  exit 1
fi
echo "PASS: direct cross-bridge connection blocked by isolation"

if [[ "$MODE" == baseline ]]; then
  echo "PASS: baseline distribution package preserves ordinary Podman networking"
  exit 0
fi

forward_rules="$(nft list chain inet netavark FORWARD)"
printf '%s\n' "$forward_rules"
mark_line="$(printf '%s\n' "$forward_rules" | grep -nE 'ct mark.*0x00001000.*accept' | head -n1 | cut -d: -f1)"
isolation_line="$(printf '%s\n' "$forward_rules" | grep -n 'jump NETAVARK-ISOLATION-1' | head -n1 | cut -d: -f1)"
[[ -n "$mark_line" && -n "$isolation_line" && "$mark_line" -lt "$isolation_line" ]] || {
  echo "FAIL: published-port accept must precede bridge isolation" >&2
  exit 1
}
nft list ruleset | grep -E 'ct mark set.*0x00001000.*dnat'

success=false
for attempt in 1 2 3 4 5; do
  if client_get nv_source "http://$HOST_IP:18081/" | grep -qx 'PUBLISHED_PORT_OK'; then
    success=true
    break
  fi
  sleep 1
done
[[ "$success" == true ]] || { echo "FAIL: cross-bridge published host port blocked" >&2; exit 1; }
echo "PASS: patched isolated source bridge reaches target's published host port"
