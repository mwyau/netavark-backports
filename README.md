# Netavark Debian published-port backport (unofficial)

Rebuilds **Debian's native Netavark source package** with the nftables parts of
[netavark PR #1483](https://github.com/containers/netavark/pull/1483).
Source and packaging come from Debian; this repository stores only the patching
logic, build scripts, and CI. It does **not** replace Podman or Aardvark DNS.

**Experimental, not validated in a container network regression test. Do not
install on production DNS solely because CI builds.**

## CI targets

| Debian suite | Source revision (pinned) | Netavark family | Architectures | Status |
|---|---|---|---|---|
| trixie | 1.14.0-2 | 1.14 | amd64 / arm64 | Candidate |
| forky | 1.17.2-3 | 1.17 | amd64 / arm64 | Candidate |
| sid | 1.17.2-3 | 1.17 | amd64 / arm64 | Candidate |
| experimental | 2.0.0-1 | 2.0 | amd64 / arm64 | Experimental (allowed failure in CI) |

The script **fails closed** if the Debian source version changes or the source
code no longer matches the expected patch anchors. Bookworm is intentionally
unsupported. Experimental uses Sid as a base with Debian experimental enabled;
**Netavark 2.x requires Podman 6.x** and is not appropriate for Podman 5.4.2.

### Versioning

Outputs follow `<Debian-version>+0xddd1~<suite>`, for example
`1.14.0-2+0xddd1~trixie`. They supersede the packaged base version but generally
sort before a later Debian security revision such as `+deb13u1`. **An official
update can replace this patch**, so monitor Debian uploads.

### Native build

In an amd64 or arm64 Linux environment with Docker:

```sh
docker run --rm --pull=always -v "$PWD:/work" -w /work \
  -e SUITE=trixie -e EXPECTED_ARCH=arm64 -e REVISION=1 \
  debian:trixie bash scripts/build.sh
```

`EXPECTED_ARCH` must match the actual container architecture. For x86-64, use
`amd64`; for experimental, use `debian:sid` and `SUITE=experimental`.
Artifacts appear under `dist/<suite>/<arch>/` with `.deb`, `.dsc`, Debian
source components, build records, and checksums. Building does not touch host
networking or replace installed packages.

### Release policy

This initial workflow **does not publish releases or install packages**.
Build success is necessary but insufficient; validate patched nftables behavior
with Podman bridges, dual-stack DNAT and isolated-network traffic before a
production deployment. Verify native binary architecture, `lintian`, and
rollback to Debian's original package. Deployment may require safely regenerating
Netavark's existing nftables rules during a maintenance window.

The `xddd` suffix is a downstream package marker; no Debian or Netavark
upstream affiliation is claimed.