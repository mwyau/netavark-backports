# Netavark backports

**Unofficial, distribution-native Netavark packages for a published-port isolation bug.**

- **Problem:** [Netavark issue #709](https://github.com/containers/netavark/issues/709) — a container on one isolated Podman bridge cannot reach another container through its **published host port**.
- **Upstream fix:** [Netavark PR #1483](https://github.com/containers/netavark/pull/1483) — marks connections handled by DNAT and accepts them before the inter-bridge isolation chain. The fix is included in newer upstream Netavark releases.

This repository backports **only PR #1483** for distribution versions that do not yet contain the fix. It does not fork Netavark, replace Podman, enable unrestricted bridge-to-bridge access, or incorporate the separate upstream PR #1522.

> **Not a production-ready package repository.** Build and networking tests must pass for each distribution and architecture before installing or publishing anything.

## How it works

1. Download the distribution's own Netavark source package: `apt-get source` for Debian/Ubuntu or an official Fedora SRPM.
2. Apply the small, version-specific patch using Debian **quilt** or the Fedora **RPM SPEC**. Preserve each distribution's build flags, packaging and dependencies.
3. Rebuild native `.deb` or `.rpm` packages, then test rootful Podman networking on disposable CI hosts.
4. Upload **one uncompressed package per passing CI job**. Public publication is a separate, manual decision.

The base source is selected from current native repositories, including security updates. If an update changes the supported Netavark code or packaging, the build fails rather than silently using an incompatible patch.

## Supported targets

| Distribution | Native source family | CI status |
| --- | --- | --- |
| Debian 13 (Trixie) | 1.14 | Patched `.deb` build and runtime tests |
| Debian Forky, Sid | 1.17 | Patched `.deb` build and runtime tests |
| Ubuntu 26.04 (Resolute) | 1.16 | Patched `.deb` build and runtime tests |
| Ubuntu 26.10 (Stonking) | 1.17 | Patched `.deb` build and runtime tests |
| Fedora 43, 44 | 1.17 | Patched `.rpm` build and runtime tests |
| openSUSE Leap 16.0, 16.1 | Distribution-native | **Stock-network checks only**; no patched RPM yet |
| Debian Experimental | 2.0 | **Experimental build only**; not eligible for release |

All matrix targets use native **AMD64/x86-64** and **ARM64/AArch64** runners. Ubuntu 24.04 Noble ships Netavark 1.4 without the relevant nftables driver, so it is not a patched target. Older Ubuntu releases, Debian Bookworm, Arch and openSUSE Tumbleweed are outside the required package matrix.

## Why there are several patches

The patches live in `patches/{1.14,1.16,1.17,2.0}/`.

The underlying logic comes from upstream PR #1483: write `DNAT_MASK` (0x1000) to conntrack state when a published host-port DNAT rule matches, then accept that marked traffic in `FORWARD` before checking bridge isolation. **Direct connections between isolated bridges remain blocked.**

- **1.14:** older Rust nftables schema with `Vec`, boxed expressions, and owned strings.
- **1.16, 1.17 and 2.0:** newer schema using `Cow` and borrowed expressions. The patch bodies are nearly identical, apart from upstream source locations.
- **Live upgrades:** unlike the original upstream change, these backports also insert the accept rule *before an already-existing isolation jump*. Appending the rule at the end of a populated `FORWARD` chain would leave running Podman networks broken. That is the only intentional behavioral addition beyond the upstream fix.

Patch headers link back to [issue #709](https://github.com/containers/netavark/issues/709) and [merged PR #1483](https://github.com/containers/netavark/pull/1483). The original upstream Rust comments are kept inside the patches.

## What CI verifies

The [GitHub Actions workflow](.github/workflows/build.yml) uses two matrices: **`deb`** for Debian/Ubuntu and **`rpm`** for Fedora/openSUSE. Each candidate builds and tests on the same runner; the implementation is in `scripts/ci-*.sh`, not duplicated in the workflow YAML.

The crucial regression launches **two persistent Podman Compose services on separate isolated, dual-stack bridges**:

- Before installing the patch, connections from one container to the other's **published IPv4 and IPv6 host ports must fail**, while the host can reach those ports.
- After an in-place Netavark upgrade, with the networks already present, **both published ports must work**.
- Direct IPv4/IPv6 connections between the isolated bridges must still fail. Fresh patched-network tests and ordinary DNS/connectivity checks must also pass.

A successful compilation is not a substitute for these tests. The openSUSE jobs currently validate only stock behavior; they do **not** prove that a patched openSUSE RPM works.

Passing jobs upload the original individual `.deb` or `.rpm` with `actions/upload-artifact@v7` and `archive: false`, without wrapping it in a ZIP. Experimental builds are not release candidates.

## Package versions and release process

The committed [`release/revision.txt`](release/revision.txt) starts at **1**. GitHub Actions run numbers do **not** change the package version. Increment this number only in a reviewed package-update PR:

- Debian/Ubuntu: `<native-source-version>+xddd1~<suite>`
- Fedora: `<native-RPM-release>.xddd1.fcXX`

For example, a new Debian security source `1.14.0-2+deb13u1` is rebased into `1.14.0-2+deb13u1+xddd1~trixie`. Because custom versions can delay automatic native security upgrades, review security updates and rebuild promptly.

Merging an approved PR runs validation but **does not publish** packages. A **manual workflow dispatch on protected `main`** rebuilds and verifies the candidates, attaches 10 Debian/Ubuntu `.deb` and 4 Fedora `.rpm` packages directly to one **draft** GitHub Release, and generates `SHA256SUMS`. The unified tag is `nv1483-r1-g<commit>`. Publication remains manual. Ubuntu PPA source uploads and a signed Debian APT repository are separate steps described in [PUBLISHING.md](PUBLISHING.md).

## Build locally

On an AMD64 Linux Docker host, for example:

```sh
docker run --rm --pull=always 
  -v "$PWD:/work" -w /work 
  -e SUITE=trixie -e EXPECTED_ARCH=amd64 -e REVISION=1 
  debian:trixie bash scripts/build.sh
```

The resulting binary and source files appear under `dist/trixie/amd64/`. Use the matching architecture, distro image and suite for other targets. These scripts only build packages; they do not install Netavark on the host.

See [PUBLISHING.md](PUBLISHING.md) for release checks, signing, rollback and native PPA/APT packaging details.
