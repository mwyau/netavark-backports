#!/usr/bin/env bash
# Stock-Podman smoke test for Ubuntu Noble, where the nftables PR #1483
# backport cannot be used directly. Do not install newer Netavark binaries.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

cat /etc/os-release
. /etc/os-release
case "${VERSION_CODENAME:-}" in
  noble) ;;
  *) echo "Unsupported stock-compatibility suite: ${VERSION_CODENAME:-unknown}" >&2; exit 2 ;;
esac

apt-get update
apt-get install -y --no-install-recommends podman curl jq ca-certificates iproute2 iptables
apt-get install -y --no-install-recommends netavark aardvark-dns nftables
echo '=== Installed networking packages ==='
dpkg-query -W podman netavark 2>&1 || :
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

# Configure storage before any Podman command. Older Podman persists driver
# configuration on first use; calling podman info first can poison the database.
echo '=== Podman backend ==='
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark

cleanup() {
  podman rm -f nv_compat_server >/dev/null 2>&1 || true
  podman network rm nv_compat >/dev/null 2>&1 || true
}
diagnostics() {
  podman ps -a >&2 || :
  podman logs nv_compat_server >&2 || :
  ip -4 addr >&2 || :
}
trap cleanup EXIT
trap 'rc=$?; (( rc == 0 )) || diagnostics' ERR

podman network create --subnet 10.241.60.0/24 nv_compat
podman run --cgroups=disabled -d --name nv_compat_server --network nv_compat \
  -p 0.0.0.0:18082:8080 docker.io/library/python:3.12-alpine \
  sh -c 'mkdir -p /www; echo COMPAT_OK >/www/index.html; exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /www'

ready=false
for attempt in $(seq 1 30); do
  if podman exec nv_compat_server wget -q -T 2 -O- http://127.0.0.1:8080/ 2>/dev/null \
      | grep -qx 'COMPAT_OK'; then
    ready=true
    break
  fi
  if [[ "$(podman inspect nv_compat_server --format '{{.State.Running}}')" != true ]]; then
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "FAIL: legacy server did not become ready" >&2; exit 1; }
echo "PASS: service ready in its own namespace"

SERVER_IP="$(podman inspect nv_compat_server | jq -r '.[0].NetworkSettings.Networks.nv_compat.IPAddress')"
[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "FAIL: no server address in expected network" >&2; exit 1;
}
podman run --cgroups=disabled --rm --network nv_compat \
  docker.io/library/alpine:3.20 wget -q -T 5 -O- "http://$SERVER_IP:8080/" \
  | grep -qx 'COMPAT_OK' || { echo "FAIL: same-bridge connectivity" >&2; exit 1; }
echo "PASS: same-bridge TCP"

HOST_IP="$(ip -4 -o addr show dev eth0 | awk '{split($4, a, "/"); print a[1]; exit}')"
[[ -n "$HOST_IP" ]] || { echo "FAIL: no guest host-facing IPv4" >&2; exit 1; }
curl -fsS --connect-timeout 5 --max-time 10 "http://$HOST_IP:18082/" \
  | grep -qx 'COMPAT_OK' || { echo "FAIL: host-published TCP port" >&2; exit 1; }
echo "PASS: host-published TCP"

echo "PASS: stock Ubuntu $VERSION_CODENAME compatibility probe"
echo "NOTE: This suite does not publish a Netavark backport. PR #1483 targets a newer nftables backend."
