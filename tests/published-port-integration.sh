#!/usr/bin/env bash
# Smoke + integration regression for Netavark PR #1483.
# Designed for a disposable, privileged Debian Docker container in GitHub Actions.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NETAVARK_FW=nftables
ARCH="$(dpkg --print-architecture)"
apt-get update
apt-get install -y --no-install-recommends podman aardvark-dns curl jq nftables iproute2 ca-certificates
shopt -s nullglob
DEBS=(/packages/netavark_*_"$ARCH".deb)
[[ "${#DEBS[@]}" == 1 ]] || { echo "Expected one netavark package for $ARCH, found ${#DEBS[@]}" >&2; exit 1; }
apt-get install -y "${DEBS[0]}"
dpkg-query -W netavark podman aardvark-dns
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark

# Avoid overlay-on-overlay inside a Docker runner.
# Inner Podman containers use --cgroups=disabled because GitHub's Docker
# cgroup namespace does not delegate the pids/cpuset controllers to crun.
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

cleanup() {
  podman rm -f nv_server nv_client >/dev/null 2>&1 || true
  podman network rm nv_source nv_target >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Distinct isolated networks: direct cross-network traffic should remain isolated,
# but a container's host-published port must be reachable.
podman network create --subnet 10.241.21.0/24 --opt isolate=true nv_source
podman network create --subnet 10.241.22.0/24 --opt isolate=true nv_target
podman run --cgroups=disabled -d --name nv_server --network nv_target \
  -p 0.0.0.0:18081:8080 docker.io/library/alpine:3.20 \
  sh -c 'mkdir -p /www; echo PUBLISHED_PORT_OK >/www/index.html; busybox httpd -f -p 8080 -h /www'

# Check that both halves of the patch are present, and that the accept rule
# precedes isolation. Merely finding the mark rule is insufficient.
forward_rules="$(nft list chain inet netavark FORWARD)"
printf '%s\n' "$forward_rules"
mark_line="$(printf '%s\n' "$forward_rules" | grep -nE 'ct mark.*0x00001000.*accept' | head -n1 | cut -d: -f1)"
isolation_line="$(printf '%s\n' "$forward_rules" | grep -n 'jump NETAVARK-ISOLATION-1' | head -n1 | cut -d: -f1)"
[[ -n "$mark_line" && -n "$isolation_line" && "$mark_line" -lt "$isolation_line" ]] || {
  echo "FAIL: published-port accept must precede bridge isolation" >&2
  exit 1
}
nft list ruleset | grep -E 'ct mark set.*0x00001000.*dnat'

# Use the host's non-loopback address, as on a LAN client. The bridge gateway
# itself can follow a different host-input path and is not a reliable DNAT test.
HOST_IP="$(ip -4 -o addr show dev eth0 | awk '{split($4, a, "/"); print a[1]; exit}')"
[[ -n "$HOST_IP" ]] || { echo "Missing host eth0 IPv4 address" >&2; exit 1; }
echo "Testing published host port at $HOST_IP:18081"
podman exec nv_server wget -q -T 5 -O- http://127.0.0.1:8080/ | grep -q '^PUBLISHED_PORT_OK
# Print the NAT chains so a failure can distinguish missing DNAT from isolation.
nft list chain inet netavark PREROUTING
nft list chain inet netavark NETAVARK-HOSTPORT-DNAT

for attempt in 1 2 3 4 5; do
  if podman run --cgroups=disabled --rm --network nv_source docker.io/library/alpine:3.20 \
      wget -q -T 5 -O- "http://$HOST_IP:18081/" | grep -q '^PUBLISHED_PORT_OK
    echo "PASS: isolated source bridge reached target published host port"
    exit 0
  fi
  sleep 2
done
echo "FAIL: published-port cross-bridge connection was not established" >&2
nft -a list table inet netavark
exit 1


# Print the NAT chains so a failure can distinguish missing DNAT from isolation.
nft list chain inet netavark PREROUTING
nft list chain inet netavark NETAVARK-HOSTPORT-DNAT

for attempt in 1 2 3 4 5; do
  if podman run --cgroups=disabled --rm --network nv_source docker.io/library/alpine:3.20 \
      wget -q -T 5 -O- "http://$HOST_IP:18081/" | grep -q '^PUBLISHED_PORT_OK; then
    echo "PASS: isolated source bridge reached target published host port"
    exit 0
  fi
  sleep 2
done
echo "FAIL: published-port cross-bridge connection was not established" >&2
nft -a list table inet netavark
exit 1
; then
    echo "PASS: isolated source bridge reached target published host port"
    exit 0
  fi
  sleep 2
done
echo "FAIL: published-port cross-bridge connection was not established" >&2
nft -a list table inet netavark
exit 1


# Print the NAT chains so a failure can distinguish missing DNAT from isolation.
nft list chain inet netavark PREROUTING
nft list chain inet netavark NETAVARK-HOSTPORT-DNAT

for attempt in 1 2 3 4 5; do
  if podman run --cgroups=disabled --rm --network nv_source docker.io/library/alpine:3.20 \
      wget -q -T 5 -O- "http://$HOST_IP:18081/" | grep -q '^PUBLISHED_PORT_OK; then
    echo "PASS: isolated source bridge reached target published host port"
    exit 0
  fi
  sleep 2
done
echo "FAIL: published-port cross-bridge connection was not established" >&2
nft -a list table inet netavark
exit 1
