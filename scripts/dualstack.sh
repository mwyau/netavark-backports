#!/usr/bin/env bash
# Dual-stack, two-container Podman networking regression on disposable CI.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NETAVARK_FW=nftables
MODE="${NETAVARK_DUALSTACK_MODE:-fresh}"
[[ "$MODE" == fresh || "$MODE" == upgrade ]] || exit 2
if [[ -f /etc/fedora-release ]]; then
  DISTRO=fedora
  FEDORA_RELEASE="$(rpm --eval '%{fedora}')"
  [[ "$FEDORA_RELEASE" == 43 || "$FEDORA_RELEASE" == 44 ]] || { echo "Unsupported Fedora release" >&2; exit 1; }
  ARCH="$(rpm --eval '%{_arch}')"
  dnf -y install podman netavark aardvark-dns \
    crun curl jq nftables iproute
elif grep -Eq '^ID="?opensuse-leap"?' /etc/os-release; then
  DISTRO=opensuse
  ARCH="$(rpm --eval '%{_arch}')"
  zypper --non-interactive --gpg-auto-import-keys refresh
  zypper --non-interactive install --no-recommends \
    podman netavark aardvark-dns runc curl jq nftables iproute2
  # Leap ships runc, which cannot run with NoCgroups inside GitHub's
  # nested Docker environment. Use an upstream, checksum-pinned crun only
  # for these CI networking tests; the native Leap RPM is not modified.
  case "$ARCH" in
    x86_64)
      CRUN_ARCH=amd64
      CRUN_SHA256=e7b059390e27d0f283e1debbe89d9c5847870f3d8325f31ccd954533fdd6ea78
      ;;
    aarch64)
      CRUN_ARCH=arm64
      CRUN_SHA256=6ac05ea41343cf91b12832c69f9a2a8c6dc5380032f4c0e02a46cc6aba8804f5
      ;;
    *) echo "Unsupported Leap architecture: $ARCH" >&2; exit 2 ;;
  esac
  curl --fail --location --retry 3 --retry-all-errors \
    "https://github.com/containers/crun/releases/download/1.30.1/crun-1.30.1-linux-${CRUN_ARCH}-disable-systemd" \
    --output /usr/local/bin/crun
  printf '%s  %s\n' "$CRUN_SHA256" /usr/local/bin/crun | sha256sum --check
  chmod 0755 /usr/local/bin/crun
  /usr/local/bin/crun --version
else
  DISTRO=deb
  ARCH="$(dpkg --print-architecture)"
  apt-get update
  apt-get install -y --no-install-recommends podman netavark \
    aardvark-dns crun curl jq nftables iproute2 ca-certificates
fi
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
if [[ "$DISTRO" == opensuse ]]; then
  # The Docker-hosted CI container has no delegated cgroup controllers.
  # Test rootful Netavark with runc, but without nested container cgroups.
  cat >/etc/containers/containers.conf <<'EOF'
[containers]
cgroups = "disabled"
[engine]
runtime = "crun"
cgroup_manager = "cgroupfs"
[engine.runtimes]
crun = ["/usr/local/bin/crun"]
EOF
else
  cat >/etc/containers/containers.conf <<'EOF'
[containers]
cgroups = "disabled"
[engine]
runtime = "crun"
EOF
fi
cat /etc/os-release
if [[ "$DISTRO" == opensuse ]]; then
  rpm -q podman netavark runc
elif [[ "$DISTRO" == fedora ]]; then
  rpm -q podman netavark
else
  dpkg-query -W podman netavark
fi
podman info --format '{{.Host.NetworkBackend}}' | grep -Fx netavark
# The OCI runtime setting is exercised by podman run; its reported name differs
# across Podman versions and is not itself a networking regression.
if [[ "$DISTRO" == opensuse ]]; then
  podman info --format '{{.Host.OCIRuntime.Name}}'
fi
RUN_OPTS=(--cgroups=disabled)
if [[ "$DISTRO" == opensuse ]]; then
  RUN_OPTS+=(--runtime=/usr/local/bin/crun)
fi
shopt -s nullglob
if [[ "$DISTRO" == fedora || "$DISTRO" == opensuse ]]; then
  RPMS=(/packages/netavark-[0-9]*.xddd"${REVISION:?CI revision required}"*."$ARCH".rpm)
  [[ "${#RPMS[@]}" == 1 ]] || { echo "FAIL: missing patched $DISTRO candidate RPM for $ARCH" >&2; exit 1; }
  install_candidate() {
    if [[ "$DISTRO" == fedora ]]; then
      dnf -y install "${RPMS[0]}"
    else
      zypper --non-interactive install --allow-unsigned-rpm "${RPMS[0]}"
    fi
    rpm -q netavark
  }
else
  DEBS=(/packages/netavark_*_"$ARCH".deb)
  [[ "${#DEBS[@]}" == 1 ]] || { echo "FAIL: missing patched Debian/Ubuntu .deb" >&2; exit 1; }
  install_candidate() { apt-get install -y "${DEBS[0]}"; dpkg-query -W netavark; }
fi
if [[ "$MODE" == fresh ]]; then install_candidate; fi

# The two isolated dual-stack bridges are created directly by Podman.
podman network create --ipv6 --subnet 10.243.71.0/24 --subnet fd71:243:71::/64 \
  --opt isolate=true nv_dual_source
podman network create --ipv6 --subnet 10.243.72.0/24 --subnet fd71:243:72::/64 \
  --opt isolate=true nv_dual_target
WORK="$(mktemp -d)"
cleanup() {
  podman rm -f nv_dual_source nv_dual_target >/dev/null 2>&1 || :
  podman network rm nv_dual_source nv_dual_target >/dev/null 2>&1 || :
  rm -rf "$WORK"
}
diagnostics() {
  echo "=== Podman networking diagnostics ===" >&2
  podman ps -a >&2 || :
  podman logs nv_dual_target >&2 || :
  nft -a list table inet netavark >&2 || :
}
trap cleanup EXIT
trap 'rc=$?; (( rc == 0 )) || diagnostics' ERR

# These containers stay on their original isolated networks across the
# in-place package upgrade. There is no Compose provider or Podman pod.
podman run "${RUN_OPTS[@]}" -d --name nv_dual_target --network nv_dual_target \
  -p 0.0.0.0:18111:8080 -p '[::]:18112:8080' \
  docker.io/library/python:3.12-alpine \
  sh -c 'mkdir -p /www; echo PODMAN_DUALSTACK_OK >/www/index.html; exec python3 -m http.server 8080 --bind :: --directory /www'
podman run "${RUN_OPTS[@]}" -d --name nv_dual_source --network nv_dual_source \
  docker.io/library/alpine:3.20 sh -c 'sleep 3600'
[[ "$(podman inspect nv_dual_source --format '{{.State.Running}}')" == true ]]
[[ "$(podman inspect nv_dual_target --format '{{.State.Running}}')" == true ]]
ready() {
  for attempt in $(seq 1 30); do
    if podman exec nv_dual_target wget -q -T 2 -O- http://127.0.0.1:8080/ 2>/dev/null \
      | grep -qx PODMAN_DUALSTACK_OK; then return 0; fi
    sleep 1
  done
  echo "FAIL: Compose target not ready" >&2
  return 1
}
ready
v4_gw="$(podman network inspect nv_dual_source | jq -er '.[0].subnets[] | select(.subnet | contains(".")) | .gateway')"
v6_gw="$(podman network inspect nv_dual_source | jq -er '.[0].subnets[] | select(.subnet | contains(":")) | .gateway')"
v4_target="$(podman inspect nv_dual_target | jq -er '.[0].NetworkSettings.Networks.nv_dual_target.IPAddress')"
v6_target="$(podman inspect nv_dual_target | jq -er '.[0].NetworkSettings.Networks.nv_dual_target.GlobalIPv6Address')"
[[ "$v6_target" == *:* && "$v6_gw" == *:* ]]
echo "IPv4 gateway $v4_gw target $v4_target; IPv6 gateway $v6_gw target $v6_target"

same_bridge="$(podman run "${RUN_OPTS[@]}" --rm --network nv_dual_target \
  docker.io/library/alpine:3.20 wget -q -T 5 -O- http://nv_dual_target:8080/)"
[[ "$same_bridge" == PODMAN_DUALSTACK_OK ]] || {
  echo "FAIL: same-bridge DNS/HTTP" >&2; exit 1;
}
echo "PASS: same-bridge DNS/HTTP"
source_get() { podman exec nv_dual_source wget -q -T 5 -O- "$1"; }
blocked() {
  if source_get "$1" | grep -qx PODMAN_DUALSTACK_OK; then
    echo "FAIL: direct bridge isolation bypassed for $1" >&2; exit 1;
  fi
}
check_isolation() {
  blocked "http://$v4_target:8080/"
  blocked "http://[$v6_target]:8080/"
  echo "PASS: direct IPv4/IPv6 bridge isolation"
}
published() {
  source_get "http://$v4_gw:18111/" | grep -qx PODMAN_DUALSTACK_OK || {
    echo "FAIL: IPv4 cross-bridge published port" >&2; exit 1; }
  source_get "http://[$v6_gw]:18112/" | grep -qx PODMAN_DUALSTACK_OK || {
    echo "FAIL: IPv6 cross-bridge published port" >&2; exit 1; }
  echo "PASS: IPv4/IPv6 host-published ports across isolated Podman bridges"
}
check_isolation
if [[ "$MODE" == upgrade ]]; then
  echo "=== NEGATIVE CONTROL: stock Netavark before candidate upgrade ==="
  # Verify the published ports work from the host itself, otherwise failure
  # from the source container could mean a broken HTTP service, not isolation.
  curl --noproxy '*' -fsS -g --connect-timeout 3 --max-time 8     "http://$v4_gw:18111/" | grep -qx PODMAN_DUALSTACK_OK || {
      echo "FAIL: stock IPv4 published port is unreachable from host"; exit 1; }
  curl --noproxy '*' -fsS -g --connect-timeout 3 --max-time 8     "http://[$v6_gw]:18112/" | grep -qx PODMAN_DUALSTACK_OK || {
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
    echo "PASS: before patch, $proto source container CANNOT reach target published port"
  done
  echo "=== Install patched package with two existing containers ==="
  install_candidate
  podman restart nv_dual_target
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
echo "PASS: two containers in $MODE mode, including IPv6"
