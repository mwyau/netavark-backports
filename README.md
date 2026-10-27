# Netavark backports

Some versions of [Netavark](https://github.com/containers/netavark) block a connection that should work: a container on one isolated Podman network cannot reach a service on another isolated network **through its published host port**.

This repository builds distribution-native packages with the upstream fix for that problem:

- [Issue #709](https://github.com/containers/netavark/issues/709) describes the published-port failure.
- [PR #1483](https://github.com/containers/netavark/pull/1483) fixes it by marking port-forwarded connections so they can pass the isolation rules.

These packages are intended for distribution versions that do not yet contain the fix. Direct connections between isolated networks remain blocked. This is a packaging and testing project, **not a fork of Netavark**.

## Packages

| Distribution | Package | Coverage |
| --- | --- | --- |
| Debian 13 (Trixie) | .deb, Netavark 1.14 family | Build and network tests |
| Debian Forky and Sid | .deb, 1.17 family | Build and network tests |
| Ubuntu 26.04 (Resolute) | .deb, 1.16 family | Build and network tests |
| Ubuntu 26.10 (Stonking) | .deb, 1.17 family | Build and network tests |
| Fedora 43 and 44 | .rpm, 1.17 family | Build and network tests |
| openSUSE Leap 16.0 and 16.1 | No patched RPM yet | Tests of the distribution package only |
| Debian Experimental | .deb, 2.0 family | Build-only experiment; not released |

Builds run on both AMD64/x86-64 and ARM64/AArch64. Ubuntu 24.04 is not a backport target because its older Netavark version does not have the relevant nftables driver.

## How the backport works

Rather than maintaining our own Netavark source tree, the build scripts download each distribution's original source package, apply the patch and use its existing packaging tools:

- **Debian and Ubuntu:** `apt-get source`, quilt and `dpkg-buildpackage`.
- **Fedora:** native source RPM, the distribution's SPEC file and `rpmbuild`.

The patches are under [`patches/`](patches/), with a version for Netavark 1.14, 1.16, 1.17 and 2.0. The 1.14 patch uses older Rust nftables types; the newer versions use `Cow` and borrowed expressions. All implement the same upstream fix.

There is one small addition for **existing Podman networks**. The upstream change adds a forwarding rule when setting up a network. During an in-place package upgrade, the isolation rules may already exist, so the backport inserts the new accept rule *before* the existing isolation jump. Otherwise the patch could work for newly created networks while leaving older ones broken.

The builds pick up current distribution source revisions, including security updates, and stop if the source no longer matches the reviewed patch. A new package build still needs testing before publication.

## What the tests cover

[GitHub Actions](.github/workflows/build.yml) builds native packages and checks Podman networking for each supported distribution and architecture.

The main regression uses two running Podman Compose services on separate isolated IPv4/IPv6 networks. It checks that published host ports are unreachable from the other network with the original package, become reachable after installing the backport **without recreating those networks**, and that direct cross-network connections remain blocked. Fresh network setup and ordinary connectivity are also tested.

Every successful package job makes its original `.deb` or `.rpm` available as a **single, uncompressed Actions artifact**. These are test builds, not packages installed or published by a distribution repository.

## Build a package locally

On an AMD64 Linux machine with Docker, from the repository root:

```bash
docker run --rm --pull=always \
  -v "$PWD:/work" -w /work \
  -e SUITE=trixie -e EXPECTED_ARCH=amd64 -e REVISION=1 \
  debian:trixie bash scripts/build.sh
```

The output is saved in `dist/trixie/amd64/`. Choose the corresponding image, suite and architecture for another target. The build does not install Netavark on your host.

## Releases

The first downstream package revision is **`xddd1`**, recorded in [`release/revision.txt`](release/revision.txt). CI run numbers do not change the package version. Debian and Ubuntu keep the original source version with a `+xddd1~suite` suffix; Fedora adds `.xddd1` to its native RPM release.

An approved PR runs CI when merged. Publishing is a separate step: a manually started release workflow builds the packages again and collects them in a **draft GitHub Release**. The draft is reviewed before it is made public.

Ubuntu packages are intended for a Launchpad PPA, Fedora packages for COPR and Debian packages for a signed APT repository. **Those publishing destinations are not configured by this repository's current workflow.** openSUSE packaging through OBS is future work.

See [PUBLISHING.md](PUBLISHING.md) for the maintainer's release procedure, source uploads and repository setup.
