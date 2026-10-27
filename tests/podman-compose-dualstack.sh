#!/usr/bin/env bash
# Dual-stack, two-service Podman Compose runtime regression on disposable CI.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NETAVARK_FW=nftables
export PODMAN_COMPOSE_PROVIDER=/usr/bin/podman-compose
MODE="${NETAVARK_COMPOSE_MODE:-fresh}"
[[ "$MODE" == fresh || "$MODE" == upgrade ]] || exit 2
if [[ -f /etc/fedora-release ]]; then
  DISTRO=fedora
  FEDORA_RELEASE="$(rpm --eval '%{fedora}')"
  [[ "$FEDORA_RELEASE" == 43 || "$FEDORA_RELEASE" == 44 ]] || { echo "Unsupported Fedora release" >&2; exit 1; }
  ARCH="$(rpm --eval '%{_arch}')"
  dnf -y install podman podman-compose netavark aardvark-dns \
    crun curl jq nftables iproute
else
  DISTRO=deb
  ARCH="$(dpkg --print-architecture)"
  apt-get update
  apt-get install -y --no-install-recommends podman podman-compose netavark \
    aardvark-dns crun curl jq nftables iproute2 ca-certificates
fi
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
cat >/etc/containers/containers.conf <<'EOF'
[containers]
cgroups = "disabled"
[engine]
runtime = "crun"
compose_providers = ["/usr/bin/podman-compose"]
EOF
cat /etc/os-release
if [[ "$DISTRO" == fedora ]]; then rpm -q podman netavark podman-compose; else dpkg-query -W podman netavark podman-compose; fi
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark
podman compose version
shopt -s nullglob
if [[ "$DISTRO" == fedora ]]; then
  RPMS=(/packages/netavark-1.17.2-1.xddd1.fc"$FEDORA_RELEASE"."$ARCH".rpm)
  [[ "${#RPMS[@]}" == 1 ]] || { echo "FAIL: missing patched Fedora $FEDORA_RELEASE RPM" >&2; exit 1; }
  install_candidate() { dnf -y install "${RPMS[0]}"; rpm -q netavark; }
else
  DEBS=(/packages/netavark_*_"$ARCH".deb)
  [[ "${#DEBS[@]}" == 1 ]] || { echo "FAIL: missing patched Debian/Ubuntu .deb" >&2; exit 1; }
  install_candidate() { apt-get install -y "${DEBS[0]}"; dpkg-query -W netavark; }
fi
if [[ "$MODE" == fresh ]]; then install_candidate; fi

# Compose operates both services; explicitly provision isolate=true networks to
# avoid relying on provider-specific driver_opts translations.
podman network create --ipv6 --subnet 10.243.71.0/24 --subnet fd71:243:71::/64 \
  --opt isolate=true nv_compose_source
podman network create --ipv6 --subnet 10.243.72.0/24 --subnet fd71:243:72::/64 \
  --opt isolate=true nv_compose_target
WORK="$(mktemp -d)"
cat >"$WORK/compose.yml" <<'EOF'
services:
  source:
    image: docker.io/library/alpine:3.20
    container_name: nv_compose_source
    command: ["sh", "-c", "sleep 3600"]
    networks: [source]
  target:
    image: docker.io/library/python:3.12-alpine
    container_name: nv_compose_target
    command: ["sh", "-c", "mkdir -p /www; echo COMPOSE_DUALSTACK_OK >/www/index.html; exec python3 -m http.server 8080 --bind :: --directory /www"]
    networks: [target]
    ports:
      - "0.0.0.0:18111:8080"
      - "[::]:18112:8080"
networks:
  source:
    external: true
    name: nv_compose_source
  target:
    external: true
    name: nv_compose_target
EOF
compose() { podman compose -p nvdual -f "$WORK/compose.yml" "$@"; }
cleanup() {
  compose down --remove-orphans >/dev/null 2>&1 || :
  podman rm -f nv_compose_source nv_compose_target >/dev/null 2>&1 || :
  podman network rm nv_compose_source nv_compose_target >/dev/null 2>&1 || :
  rm -rf "$WORK"
}
diagnostics() {
  echo "=== Podman Compose diagnostics ===" >&2
  compose ps >&2 || :
  podman ps -a >&2 || :
  podman logs nv_compose_target >&2 || :
  nft -a list table inet netavark >&2 || :
}
trap cleanup EXIT
trap 'rc=$?; (( rc == 0 )) || diagnostics' ERR

compose up -d
[[ "$(podman inspect nv_compose_source --format '{{.State.Running}}')" == true ]]
[[ "$(podman inspect nv_compose_target --format '{{.State.Running}}')" == true ]]
ready() {
  for attempt in $(seq 1 30); do
    if podman exec nv_compose_target wget -q -T 2 -O- http://127.0.0.1:8080/ 2>/dev/null \
      | grep -qx COMPOSE_DUALSTACK_OK; then return 0; fi
    sleep 1
  done
  echo "FAIL: Compose target not ready" >&2
  return 1
}
ready
v4_gw="$(podman network inspect nv_compose_source | jq -er '.[0].subnets[] | select(.subnet | contains(".")) | .gateway')"
v6_gw="$(podman network inspect nv_compose_source | jq -er '.[0].subnets[] | select(.subnet | contains(":")) | .gateway')"
v4_target="$(podman inspect nv_compose_target | jq -er '.[0].NetworkSettings.Networks.nv_compose_target.IPAddress')"
v6_target="$(podman inspect nv_compose_target | jq -er '.[0].NetworkSettings.Networks.nv_compose_target.GlobalIPv6Address')"
[[ "$v6_target" == *:* && "$v6_gw" == *:* ]]
echo "IPv4 gateway $v4_gw target $v4_target; IPv6 gateway $v6_gw target $v6_target"

same_bridge="$(podman run --rm --network nv_compose_target \
  docker.io/library/alpine:3.20 wget -q -T 5 -O- http://nv_compose_target:8080/)"
[[ "$same_bridge" == COMPOSE_DUALSTACK_OK ]] || {
  echo "FAIL: same-bridge DNS/HTTP" >&2; exit 1;
}
echo "PASS: same-bridge DNS/HTTP"
source_get() { podman exec nv_compose_source wget -q -T 5 -O- "$1"; }
blocked() {
  if source_get "$1" | grep -qx COMPOSE_DUALSTACK_OK; then
    echo "FAIL: direct bridge isolation bypassed for $1" >&2; exit 1;
  fi
}
check_isolation() {
  blocked "http://$v4_target:8080/"
  blocked "http://[$v6_target]:8080/"
  echo "PASS: direct IPv4/IPv6 bridge isolation"
}
published() {
  source_get "http://$v4_gw:18111/" | grep -qx COMPOSE_DUALSTACK_OK || {
    echo "FAIL: IPv4 cross-bridge published port" >&2; exit 1; }
  source_get "http://[$v6_gw]:18112/" | grep -qx COMPOSE_DUALSTACK_OK || {
    echo "FAIL: IPv6 cross-bridge published port" >&2; exit 1; }
  echo "PASS: IPv4/IPv6 host-published ports across isolated Compose bridges"
}
check_isolation
if [[ "$MODE" == upgrade ]]; then
  echo "=== NEGATIVE CONTROL: stock Netavark before candidate upgrade ==="
  # Verify the published ports work from the host itself, otherwise failure
  # from the source container could mean a broken HTTP service, not isolation.
  curl --noproxy '*' -fsS -g --connect-timeout 3 --max-time 8     "http://$v4_gw:18111/" | grep -qx COMPOSE_DUALSTACK_OK || {
      echo "FAIL: stock IPv4 published port is unreachable from host"; exit 1; }
  curl --noproxy '*' -fsS -g --connect-timeout 3 --max-time 8     "http://[$v6_gw]:18112/" | grep -qx COMPOSE_DUALSTACK_OK || {
      echo "FAIL: stock IPv6 published port is unreachable from host"; exit 1; }
  echo "PASS: stock host namespace can access both published ports"

  # EXPECTED FAILURE on unpatched Netavark, not merely absence of
  # post-upgrade failures. Reject a candidate if the stock baseline already
  # permits published-port access (the test then proves no improvement).
  for spec in "IPv4|http://$v4_gw:18111/" "IPv6|http://[$v6_gw]:18112/"; do
    proto="${spec%%|*}"
    url="${spec#*|}"
    if source_get "$url" >"$WORK/before-${proto}.out" 2>&1; then
      echo "FAIL: stock $proto already permits cross-isolated published port" >&2
      cat "$WORK/before-${proto}.out" >&2
      exit 1
    fi
    echo "PASS: before patch, $proto source Compose service CANNOT reach target published port"
  done
  echo "=== Install patched package with two existing Compose services ==="
  install_candidate
  compose restart target
  ready
  check_isolation
fi
rules="$(nft list chain inet netavark FORWARD)"
printf '%s\n' "$rules"
mark="$(printf '%s\n' "$rules" | grep -nE 'ct mark.*0x00001000.*accept' | head -n1 | cut -d: -f1)"
jump="$(printf '%s\n' "$rules" | grep -n 'jump NETAVARK-ISOLATION-1' | head -n1 | cut -d: -f1)"
[[ -n "$mark" && -n "$jump" && "$mark" -lt "$jump" ]] || {
  echo "FAIL: DNAT rule positioned after bridge isolation" >&2; exit 1;
}
published
if [[ "$MODE" == upgrade ]]; then
  echo "PASS: before-patch IPv4+IPv6 DENIED -> after-patch IPv4+IPv6 ALLOWED"
fi
echo "PASS: two Compose services in $MODE mode, including IPv6"
