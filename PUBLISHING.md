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

### Native base revisions and version ordering

The source package is selected **fresh from the distro's native release,
updates and security source indexes**, not pinned to `1.14.0-2` forever.
A changed Netavark source family or changed quilt patch anchors fails closed
for review. The build also rejects a newer native binary candidate if its
matching source index is missing, so a security update cannot be silently
ignored.

CI run `N` produces `<native-source-version>+xdddN~<suite>`. For example,
`1.14.0-2+xddd78~trixie` becomes
`1.14.0-2+deb13u1+xddd79~trixie` when Debian issues an updated native
source. This preserves the fix while incorporating native security patches.
The `+xddd` suffix intentionally outranks some official updates, so a user
could remain on the old custom build until our next rebuild; **monitor native
security advisories and stop/promote releases only after rebase testing**.
Do not rely on suffix order as a security-update mechanism.

The Fedora RPM builder similarly inherits the native SRPM `Release` and
appends `.xdddN` before `.fc43`/`.fc44`. Never reset a newer official
RPM release to `1.xdddN`. Debian `0xddd` was never publicly released
from this project and is no longer used.

### Patch inputs

- `patches/1.14/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/1.16/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/1.17/0001-allow-published-ports-across-isolated-bridges.patch`
- `patches/2.0/0001-allow-published-ports-across-isolated-bridges.patch`

The build copies the matching patch into `debian/patches`, adds it to the
`series` file, and applies it with `quilt push`. Patch failure fails the job.

### Verification

All twelve Debian/Ubuntu suite/architecture combinations build distribution-native packages and validate
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

### Two self-contained build matrices, uncompressed Actions artifacts and draft Releases

`.github/workflows/build.yml` contains two matrices: `deb` (Trixie,
Forky, Sid, Resolute, Stonking and experimental build-only), and `rpm`
(Fedora 43/44 patched builds plus Leap 16.0/16.1 stock-network tests).
Each candidate builds and exercises its own same-runner Podman regressions.
Implementation lives in reusable `scripts/ci-*.sh`; no separate artifact
download job is needed for the runtime tests.

Each successful eligible matrix job also uses **`actions/upload-artifact@v7`
with `archive: false`**, uploading the original individual `.deb` or
`.rpm` as a directly downloadable uncompressed Actions artifact. This
works for pull requests too, with normal artifact retention; it does not
publish a package to a repository. In a protected-main run, passing jobs
also attach their raw binaries to a **draft GitHub Release** with
`gh release upload` (also uncompressed). The final release job verifies
**10 .deb and 4 Fedora .rpm** assets and attaches `SHA256SUMS`. The release
stays draft for manual review; no automatic public publishing occurs.
For later multi-job downloads of uncompressed Actions artifacts, use
`actions/download-artifact@v8`.

The run number `N` is the unique downstream revision in Debian
`+xdddN~suite`, Fedora `<native-release>.xdddN.fcXX`, and tag
`nv1483-rN-g<first-12-SHA>`. No force-replacement of an existing release
asset or tag. PPA source rebuild/signing and openSUSE OBS builds remain
separate and are not represented by raw CI binary release assets.

See [PUBLISHING.md](PUBLISHING.md) for the proposed Ubuntu PPA (`xddd` if
available), the signed Debian APT archive at `https://apt.xddd.org`, and release
gates. No package is installed on a production system. Do not promote a draft until
the cross-bridge regression, dual-stack checks, package policy review,
and rollback strategy are validated. Deployment may require safely regenerating
Netavark's existing nftables rules during a maintenance window.

The `xddd` suffix is a downstream package marker; no Debian or Netavark
upstream affiliation is claimed.
### Fedora 43 and Leap 16.1 (2026-10-27)

Fedora 43 and 44 are both built from their native Netavark 1.17.2 SRPMs
with the PR #1483 patch. Both have AMD64/ARM64 source-RPM build and the
same two-container Podman Compose IPv4/IPv6 pre-patch failure versus
post-patch success regression. Fedora 43 is maintained only until EOL.

Leap 16.1 joins Leap 16.0 for AMD64/ARM64 **stock** Podman network
regression against `opensuse/leap:16.1`. Leap 16.1 uses Netavark 1.17.2,
while 16.0 uses 1.14.1. The stock tests are not candidate RPM builds;
a release-native openSUSE source RPM/OBS package and dual-stack A/B
integration validation remain required. Upstream PR #1522 is excluded.
