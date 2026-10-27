# Publishing Netavark backports

This guide is for maintainers preparing a release. GitHub Actions builds and tests candidate packages; publishing to an APT repository, Launchpad PPA or RPM build service is a separate step.

The backport addresses [Netavark issue #709](https://github.com/containers/netavark/issues/709) using the change from [merged PR #1483](https://github.com/containers/netavark/pull/1483).

## Before a release

1. **Review the source.** Confirm that each package is based on the intended distribution release and includes any newer distribution security patches. If the upstream fix is already present, retire that backport rather than applying it twice.
2. **Run the network tests.** The required builds must pass both fresh-install and in-place-upgrade checks. In particular, published IPv4 and IPv6 ports must work across isolated bridges without permitting direct connections between them.
3. **Confirm the package revision.** [`release/revision.txt`](release/revision.txt) contains the downstream revision, initially `1`. Increase it in a reviewed PR when publishing changed package contents; never tie it to the GitHub Actions run number.
4. **Keep a way back.** Have the distribution's original package available and test a downgrade on a disposable machine before recommending the new package to others.

A successful build alone does not prove that the package works on an existing Podman installation.

## GitHub release candidates

Merge the approved change to `main`, then manually start [`build.yml`](.github/workflows/build.yml) using **Run workflow** with the `main` branch selected. Ordinary pushes and pull requests perform CI but do not create a release.

The manually started run creates an **unpublished draft** with a unified tag such as `nv1483-r1-g<commit>`. Passing jobs upload their original binary packages individually:

- 10 Debian/Ubuntu `.deb` packages for the five supported suites and two architectures.
- 4 Fedora `.rpm` packages for Fedora 43/44 on x86-64 and AArch64.
- A `SHA256SUMS` file after the required packages are present.

openSUSE currently has stock-network tests but no patched RPM. Debian Experimental builds are not included in the release.

Review the draft's package versions, checksums and test results. GitHub does not publish the draft automatically, and the draft assets do not themselves populate a PPA, COPR project or APT repository.

## Ubuntu: Launchpad PPA

**Launchpad builds the binaries.** Upload the modified **source package**, not the `.deb` file produced by GitHub Actions.

The Ubuntu branch of [`scripts/build.sh`](scripts/build.sh) already runs `dpkg-buildpackage -S -sa -us -uc` after adding the quilt patch and downstream changelog entry. It produces unsigned source metadata and the source components needed for upload:

- `netavark_<version>_source.changes`
- `netavark_<version>.dsc`
- The accompanying Debian packaging and original source tarballs

To publish:

1. Create a Launchpad PPA (proposed name: `ppa:xddd/netavark`), register an OpenPGP upload key and enable the intended architectures, including ARM64 if available to the PPA.
2. Obtain the **exact approved source build**, including every file listed in `_source.changes`. The present workflow does not automatically submit these files to Launchpad.
3. On a trusted signing machine, sign the source package and upload it:

   ```bash
   debsign -k YOUR_GPG_KEY_ID netavark_<version>_source.changes
   dput ppa:xddd/netavark netavark_<version>_source.changes
   ```

4. Submit separate source packages for Resolute and Stonking. Wait for Launchpad to build its own AMD64/ARM64 binaries, inspect its logs and test the **PPA-built** packages before announcing them.

The source version must be unique for each new upload. If the contents change after publication, prepare a new downstream revision. Do not put your personal signing key in the repository or expose it to pull-request workflows.

Launchpad documentation: [Uploading packages to a PPA](https://ubuntu.com/docs/launchpad/user/how-to/packaging/ppa-package-upload/).

## Fedora: COPR

**COPR builds the binaries from a modified source RPM.** Do not use a Fedora 43 source RPM as a replacement for Fedora 44's native packaging.

[`scripts/build-fedora.sh`](scripts/build-fedora.sh) downloads the native Fedora source RPM, adds the patch to its SPEC and runs `rpmbuild -ba`. That produces a patched `.src.rpm` in the container's `/root/rpmbuild/SRPMS/`, as well as a binary RPM.

**The current script saves only the binary RPM to `dist/`.** Before automating COPR submission, save the patched source RPM as a CI artifact too. Then:

1. Create a COPR project and enable the relevant Fedora 43/44 x86-64 and AArch64 build environments.
2. Submit the matching patched source RPM with `copr-cli build` or the COPR API. Limit each build to its intended Fedora targets.
3. Wait for COPR's own build to finish, check its logs, and test the package installed from the COPR repository.

Submitting a source RPM can trigger public repository publication if the COPR project is enabled. Treat this as a release action, not an ordinary CI step.

COPR: [copr.fedorainfracloud.org](https://copr.fedorainfracloud.org/).

## openSUSE: OBS (not yet ready)

The openSUSE Leap 16.0 and 16.1 CI jobs currently exercise their **unmodified distribution packages**. They do not produce a patched RPM.

Before publishing through the [Open Build Service](https://build.opensuse.org/), prepare a Leap-native SPEC/source package, add the reviewed patch, and run the same IPv4/IPv6 fresh-install and in-place-upgrade tests. Then submit those source files through `osc` or the OBS API and verify the OBS-built packages. Reusing Fedora's binary RPM is not a substitute for a native openSUSE build.

## Debian: signed APT repository (planned)

The proposed address is **`https://apt.xddd.org`**. It is not configured by this repository.

A separate repository can publish the tested Debian binaries using `reprepro` or `aptly`. It needs a signing key, `dists/` metadata and a `pool/` directory. Publish the archive's **public** key and fingerprint so users can verify their APT source configuration; keep the private signing key out of the static website and source repository.

For each Debian suite, publish only packages whose source version, architecture and checksums match the approved candidate. Test `apt update`, package selection, installation and rollback from the publicly served repository before documenting installation commands for end users.

Reference: [Debian repository setup](https://wiki.debian.org/DebianRepository/SetupWithReprepro).

## After publishing

Packages built by Launchpad, COPR or OBS are **not byte-for-byte the same** as the GitHub CI binaries. Check the final hosted versions and repeat the networking regression against those packages. Record where each package was published, its source revision and how to return to the distribution package if necessary.

Until a publishing destination has been configured and its packages checked, keep that destination listed as **planned**, not available.
