#!/usr/bin/env bash
# Native-package network regression for Arch and openSUSE. No custom packages.
# Platform provided via TEST_PLATFORM=arch|tumbleweed|leap16|leap161|fedora43|fedora44
set -Eeuo pipefail
export NETAVARK_FW=nftables
platform="${TEST_PLATFORM:?Set arch, tumbleweed, leap16, leap161, fedora43, or fedora44}"
case "$platform" in
  arch)
    pacman -Syu --noconfirm --needed podman netavark aardvark-dns nftables iproute2 curl jq crun
    ;;
  tumbleweed)
    zypper --non-interactive --gpg-auto-import-keys refresh
    zypper --non-interactive install --no-recommends \
      podman netavark aardvark-dns nftables iproute2 curl jq crun
    ;;
  leap16|leap161)
    # Leap 16.0 repositories do not provide crun; use the native runc package.
    zypper --non-interactive --gpg-auto-import-keys refresh
    zypper --non-interactive install --no-recommends \
      podman netavark aardvark-dns nftables iproute2 curl jq runc
    ;;
  fedora43|fedora44)
    dnf -y --setopt=install_weak_deps=False install \
      podman netavark aardvark-dns nftables iproute curl jq crun
    ;;
  *) echo "Unknown test platform: $platform" >&2; exit 2 ;;
esac
cat /etc/os-release
echo "Native Netavark:"
if [[ "$platform" == arch ]]; then
  netavark_bin="$(find -L /usr -type f -name netavark -perm /111 -print -quit 2>/dev/null || true)"
else
  # Use exact files from native RPM metadata, not find's symlink treatment.
  rpm -ql netavark
  netavark_bin="$(rpm -ql netavark | grep -F '/podman/netavark' | head -n1)"
fi
[[ -n "$netavark_bin" && -x "$netavark_bin" ]] || {
  echo "FAIL: native Netavark binary is not executable: $netavark_bin" >&2
  exit 1
}
printf 'Netavark executable: %s\n' "$netavark_bin"
ls -l "$netavark_bin"
"$netavark_bin" --version || { ldd "$netavark_bin" || :; exit 1; }
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
# Explicitly force the nested container storage configuration: some native
# package defaults otherwise select overlay inside the outer Docker overlayfs.
export CONTAINERS_STORAGE_CONF=/etc/containers/storage.conf
PODMAN_GLOBAL=(--storage-driver=vfs)
RUNTIME=crun
CGROUPS=disabled
if [[ "$platform" == leap16 || "$platform" == leap161 ]]; then
  PODMAN_GLOBAL+=(--cgroup-manager=cgroupfs)
  RUNTIME=runc
  CGROUPS=enabled
fi
podman() { command podman "${PODMAN_GLOBAL[@]}" "$@"; }
# Initialize only after selecting vfs so libpod cannot record overlay.
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark
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
podman run --runtime "$RUNTIME" --cgroups="$CGROUPS" -d --name nv_native_server --network nv_native_target \
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
  podman run --runtime "$RUNTIME" --cgroups="$CGROUPS" --rm --network "$1" \
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

if [[ "$platform" == leap16 || "$platform" == leap161 || "$platform" == fedora43 || "$platform" == fedora44 ]]; then
  # These releases ship pre-PR1483 Netavark. Confirm the stock bug rather than claiming
  # success when no candidate RPM has been installed.
  if client_get nv_native_source "http://$HOST_IP:18091/" | grep -qx NATIVE_PORT_OK; then
    echo "FAIL: expected stock $platform IPv4 published-port isolation defect not reproduced" >&2
    exit 1
  fi
  echo "PASS: stock $platform reproduces IPv4 cross-bridge published-port denial"
  echo "NOTE: Fedora/Leap candidate RPM must be built and tested separately"
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
