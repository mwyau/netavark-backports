#!/usr/bin/env bash
# Native-package network regression for Arch and openSUSE. No custom packages.
# Platform provided via TEST_PLATFORM=arch|tumbleweed|leap16
set -Eeuo pipefail
export NETAVARK_FW=nftables
platform="${TEST_PLATFORM:?Set arch, tumbleweed or leap16}"
case "$platform" in
  arch)
    pacman -Syu --noconfirm --needed podman netavark aardvark-dns nftables iproute2 curl jq
    ;;
  tumbleweed|leap16)
    zypper --non-interactive --gpg-auto-import-keys refresh
    zypper --non-interactive install --no-recommends \
      podman netavark aardvark-dns nftables iproute2 curl jq
    ;;
  *) echo "Unknown test platform: $platform" >&2; exit 2 ;;
esac
cat /etc/os-release
echo "Native Netavark:"; /usr/libexec/podman/netavark --version || netavark --version
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
cleanup() {
  podman rm -f nv_native_server >/dev/null 2>&1 || :
  podman network rm nv_native_source nv_native_target >/dev/null 2>&1 || :
}
diagnostics() {
  podman ps -a >&2 || :
  podman logs nv_native_server >&2 || :
  nft list ruleset >&2 || :
}
trap cleanup EXIT
trap 'rc=$?; (( rc == 0 )) || diagnostics' ERR

podman network create --subnet 10.242.31.0/24 --opt isolate=true nv_native_source
podman network create --subnet 10.242.32.0/24 --opt isolate=true nv_native_target
podman run --cgroups=disabled -d --name nv_native_server --network nv_native_target \
  -p 0.0.0.0:18091:8080 docker.io/library/python:3.12-alpine \
  sh -c 'set -eu; mkdir -p /www; echo NATIVE_PORT_OK >/www/index.html; exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /www'

ready=false
for attempt in $(seq 1 30); do
  if podman exec nv_native_server wget -q -T 2 -O- http://127.0.0.1:8080/ 2>/dev/null \
       | grep -qx NATIVE_PORT_OK; then
    ready=true
    break
  fi
  if [[ "$(podman inspect nv_native_server --format '{{.State.Running}}')" != true ]]; then break; fi
  sleep 1
done
[[ "$ready" == true ]] || { echo "FAIL: server not ready" >&2; exit 1; }
echo "PASS: HTTP service ready"

client_get() {
  podman run --cgroups=disabled --rm --network "$1" \
    docker.io/library/alpine:3.20 wget -q -T 5 -O- "$2"
}
client_get nv_native_target http://nv_native_server:8080/ | grep -qx NATIVE_PORT_OK || {
  echo "FAIL: same-bridge TCP/DNS"; exit 1;
}
echo "PASS: same-bridge TCP/DNS"
HOST_IP="$(ip -4 -o addr show dev eth0 | awk '{split($4,a,"/"); print a[1]; exit}')"
[[ -n "$HOST_IP" ]] || { echo "FAIL: no host-facing IP" >&2; exit 1; }
curl -fsS --connect-timeout 5 --max-time 10 "http://$HOST_IP:18091/" | grep -qx NATIVE_PORT_OK || {
  echo "FAIL: host published TCP"; exit 1;
}
echo "PASS: host published TCP"

SERVER_IP="$(podman inspect nv_native_server | jq -r '.[0].NetworkSettings.Networks.nv_native_target.IPAddress')"
[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "FAIL: invalid target address" >&2; exit 1;
}
if client_get nv_native_source "http://$SERVER_IP:8080/" | grep -qx NATIVE_PORT_OK; then
  echo "FAIL: direct bridge isolation bypassed" >&2; exit 1;
fi
echo "PASS: direct bridge isolation"

if [[ "$platform" == leap16 ]]; then
  echo "SKIP: expected pre-2.1 Leap 16.0 published-port defect; patched RPM requires separate OBS build"
  exit 0
fi
success=false
for attempt in 1 2 3 4 5; do
  if client_get nv_native_source "http://$HOST_IP:18091/" | grep -qx NATIVE_PORT_OK; then
    success=true
    break
  fi
  sleep 1
done
[[ "$success" == true ]] || { echo "FAIL: upstream fixed cross-bridge published port not reachable" >&2; exit 1; }
echo "PASS: fixed published host port is accessible across isolated bridges"
