# Releasing Netavark Backports

Netavark backports [issue #709](https://github.com/containers/netavark/issues/709) using the fix from [PR #1483](https://github.com/containers/netavark/pull/1483). Each distribution is built from its own source package.

## Versions and CI

[`versions.json`](versions.json) records each distribution's upstream source and independent downstream revision. When the upstream source changes, reset its revision to `1`; for another build from the same source, increment the revision. Both architectures share a revision.

Debian packages append `xdddN~suite`; Ubuntu packages append `ppaxdddN~suite`; RPM builds use `.xdddN` in their release. These distinguish backports while allowing newer official distribution versions to supersede them.

[Upstream checks](../.github/workflows/upstream.yml) retrieve source versions for all ten targets. The daily run proposes updates through reviewed PRs; relevant PRs also verify source discovery. [CI](../.github/workflows/ci.yml) builds affected native packages on AMD64 and ARM64, tests Podman IPv4/IPv6 isolation and live upgrades, and uploads the original packages and source files. `scripts/check.py` validates script syntax, version ordering, build planning and release assembly.

## GitHub Release

Changes merged to `main` produce a **draft Release** after the required package jobs pass. It contains the complete verified snapshot: DEBs, RPMs, native source bundles/RPMs, `versions.json` and `SHA256SUMS`. Unchanged packages are reused from the previous release after verification; Debian Experimental is build-only.

Release tags use `netavark-YYYYMMDD.N`, independently of package revisions. The draft records the exact tested commit.

To publish, configure a GitHub environment named **`publishing`** with required reviewers and a deployment restriction to `main`. Set repository Actions variable `PUBLISHING_ENABLED=true`. Run [Publish release](../.github/workflows/publish.yml) from `main`, enter the draft tag and `PUBLISH`, then approve the environment deployment. The workflow verifies the draft and checksums before making the GitHub Release public.

## Downstream distribution

GitHub Release publication does **not** itself submit packages to distribution repositories. The recommended next step is a separately dispatched workflow with **three independently approved jobs**:

| Destination | Submission | Proposed environment |
| --- | --- | --- |
| Ubuntu PPA | Sign the Ubuntu `.dsc` and `_source.changes` with a Launchpad-registered OpenPGP key; upload each source package using `dput`. Launchpad builds the binaries. | `ppa` |
| Fedora COPR | Submit the Fedora 43 and 44 `.src.rpm` files using `copr-cli` and an API token from a dedicated account authorized for the intended COPR project. | `copr` |
| openSUSE OBS | Extract the Leap source RPMs and submit the SPEC, patches and source archives with `osc` to the appropriate OBS project. | `obs` |

Before any submission, verify the exact **published** tag, tested commit, artifact filenames and `SHA256SUMS`. Each job must use its own environment approval and credentials, and confirm the distribution's resulting builds before considering the destination complete. None of these uploads should run during PR CI.

Environment configuration: `ppa` uses variables `PPA_TARGET` and `PPA_GPG_FINGERPRINT`, and secret `PPA_GPG_PRIVATE_KEY` (a dedicated noninteractive upload key registered with Launchpad); `copr` uses `COPR_PROJECT` and secret `COPR_CONFIG`; `obs` uses `OBS_PROJECT_16_0`, `OBS_PROJECT_16_1` and secret `OBS_CONFIG`. These secrets are accessed only by their approved destination job. PPA uploads are signed source uploads; COPR waits for source RPM builds; OBS imports source RPMs. Verify completed destination builds separately.

For GitHub-hosted automation, store dedicated, limited-purpose credentials in their respective **environment secrets**, not in source files or repository-wide secrets. An environment approval delays access to secrets but does not make a signing key non-exportable. Prefer keeping a long-lived personal OpenPGP key offline; use a separate revocable PPA upload key if unattended signing is required. Restrict workflow edits and `main`, use ephemeral runners, and avoid printing credentials or importing keys into persistent storage.

The [distribution workflow](../.github/workflows/distribute.yml) is implemented but **disabled by default**. Configure the three environments with required reviewers and restrict deployments to `main`, then set repository variable `DISTRIBUTION_ENABLED=true`. An approved GitHub publication explicitly dispatches the distribution workflow. The workflow verifies the published tag, tested commit and every asset checksum before planning submissions. Each destination compares its package source/revision against its **last successful deployment**, not merely the previous GitHub Release. Only changed targets request approval; failed or skipped submissions remain eligible. Distribution success records submission, not completion of external repository builds.

See [Launchpad PPA uploads](https://ubuntu.com/docs/launchpad/user/how-to/packaging/ppa-package-upload/), [COPR CLI](https://docs.copr.fedorainfracloud.org/user_documentation.html) and [OBS `osc`](https://github.com/openSUSE/osc) for destination-specific setup.
