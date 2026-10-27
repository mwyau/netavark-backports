# Netavark Ubuntu and Debian published-port backport (unofficial)

Rebuilds **Ubuntu and Debian native Netavark source packages** with a version-specific Debian quilt backport of the nftables parts of
[netavark PR #1483](https://github.com/containers/netavark/pull/1483).
Source and packaging come from the target distribution; this repository stores version-specific
**unified diff quilt patches**, build scripts, tests, and CI. The build fetches
native distribution source directly; no upstream fork or source-rewriting helper is needed.
It does **not** replace Podman or Aardvark DNS.

**Experimental. A successful package build does not establish that Podman networking works.**
Release is gated on runtime regression tests, including in-place upgrades with active containers.

## CI targets

| Distribution / suite | Source revision (pinned) | Netavark family | Architectures | Status |
|---|---|---|---|---|
| Debian trixie | 1.14.0-2 | 1.14 | amd64 / arm64 | Candidate |
| Ubuntu resolute (26.04 LTS) | 1.16.1-3.1 | 1.16 | amd64 / arm64 | Candidate |
| Ubuntu stonking (26.10 interim) | 1.17.2-2 | 1.17 | amd64 / arm64 | Candidate |
| Ubuntu noble (24.04 LTS) | 1.4.0-4 | 1.4, no nftables driver | amd64 / arm64 | Stock-network compatibility tests; no PR #1483 patch |
| Debian forky | 1.17.2-3 | 1.17 | amd64 / arm64 | Candidate |
| Debian sid | 1.17.2-3 | 1.17 | amd64 / arm64 | Candidate |
| Debian experimental | 2.0.0-1 | 2.0 | amd64 / arm64 | Experimental (allowed failure in CI) |

The script **fails closed** if the distribution source version changes or the source
code no longer matches the expected patch anchors. Debian Bookworm remains unsupported. Ubuntu 22.04 Jammy is intentionally excluded from this downstream project; current Ubuntu targets are Noble 24.04 LTS, Resolute 26.04 LTS, and Stonking 26.10. Only Resolute and Stonking can directly use the nftables PR #1483 backport: Noble 1.4 predates Netavark's nftables driver. Noble compatibility testing is not equivalent to delivering a backport package. Ubuntu Pro/ESM releases are not included in this standard-support matrix. Experimental uses Sid as a base with Debian experimental enabled;
**Netavark 2.x requires Podman 6.x** and is not appropriate for Podman 5.4.2.

### Versioning

Outputs follow `<Debian-version>+0xddd1~<suite>`, for example
`1.14.0-2+0xddd1~trixie`. They supersede the packaged base version but generally
sort before a later Debian security revision such as `+deb13u1`. **An official
update can replace this patch**, so monitor Debian uploads.

### Patch inputs

- `patches/1.14/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/1.16/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/1.17/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/2.0/0001-allow-published-ports-across-isolated-bridges.patch`

The build copies the matching patch into `debian/patches`, adds it to the
`series` file, and applies it with `quilt push`. Patch failure fails the job.

### Verification

All twelve package-building suite/architecture combinations build distribution-native packages and validate
the resulting `.deb` metadata and packaged binary's `--version`. Privileged CI runtime checks on **Debian Trixie, Ubuntu Resolute and Stonking, amd64 and arm64**
exercise the stock distribution package, an **in-place upgrade with active
containers**, and a patched install on freshly created networks. They verify
same-bridge DNS/TCP, host port publishing, direct bridge isolation, and
cross-isolated-bridge access to published host ports.

**Separate real Compose tests** run two persistent `podman compose` services
on isolated, externally provisioned dual-stack bridges. On amd64 and arm64
Debian Trixie, Ubuntu Resolute and Stonking they check same-bridge DNS,
IPv4/IPv6 isolation (direct access must fail), IPv4/IPv6 published-port access
through the host gateway, fresh candidate installations, and candidate upgrades
while the Compose project and its networks already exist. Both Compose and
lower-level tests must pass before a draft release can be created. These
new Compose tests are not considered validated until GitHub Actions passes. These tests must pass before
creating a draft release. Separate privileged stock-Podman smoke tests run on Noble on both architectures. They never install an incompatible Netavark backport.

The Debian `dh_auto_test` step in the initial successful run invoked a Cargo
build, **not the Rust unit-test suite**; additional unit-test coverage is still
needed. Other Debian suites currently have package-build verification rather
than equivalent Podman integration coverage.

### Native build

In an amd64 or arm64 Linux environment with Docker:

```sh
docker run --rm --pull=always -v "$PWD:/work" -w /work \
  -e SUITE=trixie -e EXPECTED_ARCH=arm64 -e REVISION=1 \
  debian:trixie bash scripts/build.sh
```

`EXPECTED_ARCH` must match the actual container architecture. For x86-64, use
`amd64`; for experimental, use `debian:sid` and `SUITE=experimental`.
Ubuntu 26.04 and 26.10 use `ubuntu:resolute` or `ubuntu:stonking` with the
corresponding `SUITE`. Noble should not receive these newer Netavark builds.
Artifacts appear under `dist/<suite>/<arch>/` with `.deb`, `.dsc`, Debian/Ubuntu
source components, build records, and checksums. Building does not touch host
networking or replace installed packages.

### CI artifacts and draft releases

GitHub Actions artifacts are ZIP archives, even when an artifact contains a
single `.deb`. After every successful main-branch build matrix, a separate CI
job collects the twelve `.deb` files and attaches them **directly as raw release
assets**, plus `SHA256SUMS-release`, to a **draft prerelease**
tagged `ci-<commit>`. A draft is not published as a final release. Its notes
are created only when all required patched and legacy compatibility checks succeed.

Native Arch Linux and openSUSE Tumbleweed packages are checked by a separate
Podman regression suite, while openSUSE Leap 16.0 receives a stock-network
compatibility test. These checks do not produce replacement RPMs or pacman
packages; Leap 16.0's Netavark 1.14 family requires separate RPM packaging.

See [PUBLISHING.md](PUBLISHING.md) for the proposed Ubuntu PPA (`xddd` if
available), the signed Debian APT archive at `https://apt.xddd.org`, and release
gates. No package is installed on a production system. Do not promote a draft until
the cross-bridge regression, dual-stack checks, package policy review,
and rollback strategy are validated. Deployment may require safely regenerating
Netavark's existing nftables rules during a maintenance window.

The `xddd` suffix is a downstream package marker; no Debian or Netavark
upstream affiliation is claimed.