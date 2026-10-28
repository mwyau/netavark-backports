# Releasing Netavark Backports

This guide covers source versions, CI artifacts, release drafts and publication. The packages carry the fix for [Netavark issue #709](https://github.com/containers/netavark/issues/709), merged upstream in [PR #1483](https://github.com/containers/netavark/pull/1483).

## Prepare a change

Each distro is built from its own source package, with the relevant patch from `patches/` applied through quilt or its RPM SPEC. Expected native source versions are recorded in [`versions.json`](versions.json). The file tracks Debian/Ubuntu source versions, Fedora/openSUSE version-release values, and an independent positive downstream revision for each distribution release. It does not pin source tarball checksums.

When the distribution publishes a new source revision, review its changes and update that entry in a pull request. Adjust the patch if needed. The scripts reject unexpected source versions rather than quietly rebuilding from a different base.

Each distribution release has an independent `revision` integer in [`versions.json`](versions.json), initially `1`. It produces `xddd1` in the native package version. Increase **only the affected distribution's** revision when rebuilding or changing its backport. Both architectures of one distribution release share this revision. A CI rerun or documentation change does not increase package revisions.

The [daily source check](../.github/workflows/check-upstream.yml) compares current native sources against reviewed `source` values without changing the manifest or publishing packages. Review upstream changes and adjust the patch before updating a locked source version. Ubuntu Stonking 1.17.2-2 needs two obsolete native prost/mozim downgrade patches excluded to build against the distribution's current Rust packages (Debian bug #1145651). This is separate from the nftables fix.

## Build and test

The main [workflow](../.github/workflows/build.yml) runs on pull requests and pushes to `main`. The Debian/Ubuntu and RPM matrices compile the native packages and run Podman networking regressions on their target architectures.

The key test checks two Podman containers on isolated IPv4/IPv6 bridges, first with the original package, then after upgrading Netavark while the networks remain in place. The published host ports must work after the upgrade, and direct cross-bridge traffic must remain isolated.

Each passing job uploads its original package binary as a single downloadable Actions artifact, without ZIP wrapping. CI also retains source inputs:

| Source | Actions artifact | Where it comes from |
| --- | --- | --- |
| Debian/Ubuntu | `source-deb-<suite>` (source files bundled together) | `dpkg-buildpackage -S -sa -us -uc` |
| Fedora | One native modified `.src.rpm` per Fedora version | `rpmbuild -ba` |
| openSUSE Leap | Modified `.src.rpm` | Native Leap SPEC and `rpmbuild -ba` |

Only one source artifact per distro release is uploaded, from the x86-64/AMD64 build; both architectures compile from the same reviewed native source version.

## Draft GitHub releases

Once all required checks pass on `main`, the workflow collects the artifacts **from that same CI run** and creates a draft GitHub Release for a new reviewed package revision. Pull requests run the same asset assembly and verification without creating a release.

The draft contains 10 Debian/Ubuntu DEBs, 4 Fedora RPMs and 4 Leap RPMs, their 9 native source bundles/RPMs, `versions.json` and `SHA256SUMS`. Debian Experimental remains build-only.

The tag is `netavark-g<commit-sha12>`, identifying the exact validated commit rather than a global package revision. No new draft is created when only documentation changes or the reviewed package revisions have not changed.

## Approve GitHub publication

Create an environment named **`publishing`** in the repository's **Settings → Environments**. Add a required reviewer and restrict deployments to the protected `main` branch. If you are the only reviewer, leave *Prevent self-review* off.

Create a repository Actions variable **`PUBLISHING_ENABLED`** with value `true` after protection is configured. Until then, [`publish.yml`](../.github/workflows/publish.yml) will not run its publishing job.

When the release draft and its checksums look correct, select **Actions → Publish approved GitHub Release → Run workflow**, enter its exact tag and type `PUBLISH`. Approve the waiting environment deployment. That publishes **only the GitHub Release**. It does not upload to Launchpad, COPR, OBS or a Debian repository.

## Ubuntu PPA

Launchpad accepts **source packages**, not CI-built `.deb` binaries. From the approved draft release, download the `netavark-source-resolute-*.tar.gz` or `netavark-source-stonking-*.tar.gz` bundle and extract it on a trusted signing machine.

Verify the `.dsc`, `_source.changes` and included tarballs, then sign the source changes with an OpenPGP key registered to your Launchpad account. Assuming the PPA is `ppa:xddd/netavark`:

```bash
debsign -k YOUR_GPG_KEY_ID netavark_*_source.changes
dput ppa:xddd/netavark netavark_*_source.changes
```

Upload each Ubuntu series separately, and check Launchpad's AMD64 and ARM64 builds. Test the **PPA-built** binaries; their hashes will generally differ from the GitHub test binaries.

A PPA upload initiates a public build and potentially publishes packages, so it is not part of ordinary PR or main CI. OpenPGP private keys do not belong in the source repository.

## Fedora COPR

Download the matching Fedora 43 or 44 `.src.rpm` from the approved draft Release. Submit each source RPM only to the appropriate COPR chroot:

```bash
copr-cli build netavark ./netavark-1.17.2-*.fc43.src.rpm
```

Select Fedora 43 x86-64/AArch64 for the Fedora 43 source package and Fedora 44 for its corresponding package. Check COPR's build logs and install the COPR-produced RPM for the networking tests before announcing it.

## openSUSE OBS

Leap 16.0 and 16.1 are validated release targets. Submit their native SPEC, source archives and patch to an OBS project after approval; OBS should build and host its own binaries. Fedora RPMs are not interchangeable with Leap RPMs.

## Debian APT repository

Debian distribution packages are intended for a signed repository at `https://apt.xddd.org`. That service is managed separately from this GitHub repository. Use `reprepro` or `aptly` to publish approved DEBs and signed APT indexes, keep the archive-signing private key offline or in protected operator storage, and publish the public key fingerprint for verification.

Verify installation, upgrade and rollback from the **hosted** APT repository on a disposable Debian system before announcing the repository.

## After publication

Record the release revision, the native distro sources used, distribution build results and package locations. Update the native source and only affected distribution revisions in the next reviewed package-update PR.
