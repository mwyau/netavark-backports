# Netavark Backports

Distribution-native packages carrying the fix for published ports across isolated Podman networks.

[Issue #709](https://github.com/containers/netavark/issues/709) describes the problem: traffic between isolated bridges is blocked even when a service is reached through a published host port. [PR #1483](https://github.com/containers/netavark/pull/1483) fixes it. This project applies that change to distributions shipping older Netavark versions and tests both new networks and upgrades of running Podman containers.

## Distributions

| Distribution | Version family | Package |
| --- | --- | --- |
| Debian Trixie | 1.14 | DEB |
| Debian Forky, Sid | 1.17 | DEB |
| Ubuntu Resolute, Stonking | 1.16, 1.17 | DEB |
| Fedora 43, 44 | 1.17 | RPM |
| openSUSE Leap 16.0, 16.1 | 1.14, 1.17 | RPM (under development) |
| Debian Experimental | 2.0 | Build experiment |

AMD64/x86-64 and ARM64/AArch64 are tested in GitHub Actions. Both Leap releases passed the native build and dual-stack networking matrix and are included in validated release candidates.

## Building

The scripts fetch each distribution's Netavark source, apply the matching patch from [`patches/`](patches/) and build with the distribution's own Debian or RPM tooling.

For Debian Trixie on an AMD64 Docker host:

```sh
docker run --rm --pull=always \
  -v "$PWD:/work" -w /work \
  -e SUITE=trixie -e EXPECTED_ARCH=amd64 -e REVISION=1 \
  debian:trixie bash scripts/build/deb.sh
```

The resulting packages and source files are saved in `dist/`. Fedora and openSUSE builds use their corresponding scripts under `scripts/build/`.

## Downloads and development

[GitHub Actions](.github/workflows/build.yml) builds and tests candidate binaries with Podman on isolated IPv4/IPv6 networks. Passing jobs attach their original DEB/RPM files and distribution source packages as workflow artifacts.

After a release change is merged and the main-branch tests pass, CI prepares a **draft GitHub Release**. Native source versions and independent per-distribution downstream revisions are recorded in [`release/versions.json`](release/versions.json). Publication to [GitHub Releases](../../releases), an Ubuntu PPA, Fedora COPR or a Debian APT repository is separate.

See [release instructions](release/README.md) for package versioning, source artifacts and publication.
