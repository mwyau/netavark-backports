# Publishing Ubuntu and Debian Netavark packages

**Status: experimental. Do not publish/install until rootful Podman network regressions pass.** The GitHub Actions matrix must validate the stock distribution package, an in-place upgrade while existing containers are running, and the patched binary on fresh networks. Inspect failures instead of treating a successful package build as proof of runtime correctness.

The native patched package versions currently targeted are Debian Trixie 1.14.0-2, Ubuntu Resolute (26.04 LTS) 1.16.1-3.1, and Ubuntu Stonking (26.10 interim) 1.17.2-2. Ubuntu Noble (24.04 LTS) ships Netavark 1.4.0-4, which predates the nftables driver, so only its native Podman networking is tested. Ubuntu Jammy (22.04 LTS) is explicitly excluded from this downstream packaging/testing project. Older Ubuntu Pro/ESM releases are also out of scope.

## Ubuntu PPA (Launchpad)

Proposed owner: `xddd`, if the Launchpad name is available. Email: `albert@xddd.org`. PPA name: `netavark`. The resulting identifier would be `ppa:xddd/netavark`. Account availability must be checked interactively, and the user must register/verify their email.

1. Log into https://launchpad.net and create or activate the public PPA. Register a source-upload OpenPGP signing key at https://launchpad.net/~/+editpgpkeys; never store the private key in GitHub Actions secrets or in the Git repository merely to automate publishing.
2. Check that the **release-specific Ubuntu source** build has passed CI and includes `netavark_<version>_source.changes`, its `.dsc`, original tarball, and Debian quilt tarball. Launchpad accepts source uploads only, not prebuilt `.deb` files.
3. Download the Ubuntu **source** artifact from the passing CI run on a trusted local Ubuntu system, verify the artifact SHA256SUMS, and unpack in one local directory.
4. Set `DEBFULLNAME='Albert Yau'`, `DEBEMAIL='albert@xddd.org'`. Sign the exact `netavark_*_source.changes` file and the corresponding source metadata with `debsign -k albert@xddd.org <exact-source.changes>`. Verify the signature.
5. Upload with `dput ppa:xddd/netavark <exact-source.changes>`. Wait for Launchpad to build each intended architecture and inspect its logs. Do not assume an Ubuntu source build succeeded merely because Debian builds succeeded.
6. Publish a separate signed source upload for each validated Ubuntu suite (currently Resolute and Stonking), after all corresponding builds and runtime tests pass. Do not copy binaries between releases. After publishing and independent testing on disposable Ubuntu systems, document `sudo add-apt-repository ppa:xddd/netavark`, `sudo apt update`, `apt-cache policy netavark`, and an explicit tested Netavark version.

See https://ubuntu.com/docs/launchpad/user/how-to/packaging/ppa-package-upload/ and https://ubuntu.com/docs/launchpad/user/reference/packaging/ppas/ppa/.

## Debian repository at https://apt.xddd.org

Prefer a **separate public GitHub repository** named `mwyau/apt.xddd.org` so signed APT metadata/binary artifacts are not mixed with Rust source/build logic. The GitHub repository and `apt.xddd.org` DNS/Pages settings must be created by the domain owner; neither is set up by this source repository.

1. In the new GitHub repository, choose Settings → Pages → Deploy from `main` / `docs`; configure custom domain `apt.xddd.org` **before** adding the DNS record. Add a DNS `CNAME` with host `apt` and target `mwyau.github.io`; enable HTTPS.
2. Generate a **separate dedicated archive-signing GPG key** whose UID includes `albert@xddd.org`. Keep its private component offline or securely in trusted operator storage. The public fingerprint must be available independently for verification.
3. Install `reprepro` locally. Place in `docs/conf/distributions`:

       Origin: xddd
       Label: xddd Netavark Backports
       Codename: trixie
       Suite: trixie
       Architectures: amd64 arm64
       Components: main
       Description: Unofficial tested Netavark backports
       SignWith: REPLACE_WITH_FULL_SIGNING_KEY_FINGERPRINT

4. Import only validated Trixie .deb files from the **same passing CI SHA**, after comparing checksums and package metadata, with `reprepro -b docs includedeb trixie <file.deb>` for each architecture. Run `reprepro -b docs export`, confirm the resulting `docs/dists/trixie/InRelease` and `docs/pool` contents are correct, and export the public key to `docs/xddd-archive-key.asc`. Add `docs/.nojekyll`; publish the static `docs` directory.
5. Before announcing, use a **disposable** Debian Trixie VM to fetch the public key, verify its fingerprint independently, configure the APT `Signed-By` scope, execute `apt update`, and verify `apt-cache policy netavark` reports the intended version. Test installation, same-network traffic, host publishing, isolation, cross-network published-port access, and rollback.

Example Debian Trixie deb822 source file (`/etc/apt/sources.list.d/xddd.sources`):

    Types: deb
    URIs: https://apt.xddd.org
    Suites: trixie
    Components: main
    Signed-By: /etc/apt/keyrings/xddd.asc

Do not use `apt-key` or disable APT signature checks. Do not place the private repository signing key in the Pages repository. Publish only suites actually validated on disposable runtime machines. Existing Forky, Sid, and Experimental outputs remain research artifacts until separately verified. See https://wiki.debian.org/DebianRepository/SetupWithReprepro and https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site.

## Rollback and release gate

Never publish solely on the strength of successful compilation or static nftables-rule checks. Existing Podman networks and running containers must remain usable across an in-place package upgrade. Keep the official distribution package accessible for downgrade, and record a maintenance-window procedure for safely recreating network rules without cutting off SSH or other host access. No force-pushes and no automatic production deployment.

## Upstream patch provenance

Every quilt patch preserves the Netavark [PR #1483](https://github.com/containers/netavark/pull/1483) DNAT marking and FORWARD acceptance implementation and upstream comments ("Match on any rule that matches against DNAT_MASK" and "Ensure we allow the DNAT packets before we consult the isolation chains"). Netavark's API differs between 1.14 and newer releases; the patches adapt only those API forms and avoid incidental upstream refactoring. A necessary downstream addition detects an existing `NETAVARK-ISOLATION-1` jump and **inserts** the accept rule before that jump instead of appending at the end of an already initialized FORWARD chain. Without this exception, upgrades with existing bridges silently fail even though freshly-created networks may pass. Original patch origin and issue references are retained; downstream backport credited to Albert Yau <albert@xddd.org>.
