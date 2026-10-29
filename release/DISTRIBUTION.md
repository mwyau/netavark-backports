# Configure PPA, COPR and OBS distribution

The repository already builds and verifies its release artifacts. External distribution requires destination accounts and **three protected GitHub environments**. No automatic upload is enabled until you set `DISTRIBUTION_ENABLED=true`.

## 1. Prepare GitHub

1. Keep the repository **public**, protect `main`, and restrict who can modify `.github/workflows/`, `release/`, and the CI scripts. Do not run secret-bearing jobs on untrusted pull requests.
2. In **Settings → Environments**, create `publishing`, `ppa`, `copr`, and `obs`. For each, configure a **required reviewer**, restrict deployments to protected `main`, and leave *Prevent self-review* off if you are the sole reviewer. The workflow refuses to distribute when the destination environments lack reviewer or branch protections.
3. Repository variables (Settings → Secrets and variables → Actions → Variables): set `PUBLISHING_ENABLED=true` only when `publishing` is protected. Leave `DISTRIBUTION_ENABLED` unset until the destination setup is complete.
4. Store destination credentials as **environment secrets**, not repository secrets. Environment variables may be ordinary nonsecret project names.

Each destination is individually approved; there is no all-destinations secret. GitHub Actions' environment approval only guards access to the secrets—it does not protect a private key against a compromised *approved* workflow.

## 2. Launchpad Ubuntu PPA

1. Create a [Launchpad account](https://launchpad.net/) and [PPA](https://launchpad.net/~/+activate-ppa), for example one named `netavark`. Confirm Ubuntu **Resolute** and **Stonking** are supported by your archive. Launchpad builds the `amd64` and `arm64` binaries from the submitted Ubuntu **source packages**.
2. On a trusted Linux machine, generate a **dedicated 4096-bit RSA signing key** with `gpg --full-generate-key`. Use an identity/email associated with your Launchpad account, a strong passphrase, and an expiration date. Do **not** upload your personal long-term private key to CI.
3. Obtain its full fingerprint with `gpg --fingerprint`. Publish its **public key** to the Ubuntu keyserver and register/confirm that fingerprint in Launchpad's **OpenPGP keys** settings. Launchpad must authorize that identity to upload to your PPA.
4. Back up the private key securely (e.g. Bitwarden and encrypted offline backup). Export **only this dedicated key** to an armored file using `gpg --armor --export-secret-keys FINGERPRINT > ppa-private.asc`. Remove the temporary plaintext file securely after transferring to GitHub.
5. In the GitHub **`ppa` environment**, add:
   - variable `PPA_TARGET`: `ppa:YOUR_LAUNCHPAD_ID/netavark`
   - variable `PPA_GPG_FINGERPRINT`: the 40-hex-digit key fingerprint
   - secret `PPA_GPG_PRIVATE_KEY`: the armored private-key export
   - secret `PPA_GPG_PASSPHRASE`: the key passphrase

The approved job uses a temporary GnuPG home, a temporary passphrase file with restrictive permissions, and GnuPG loopback signing to sign the `.dsc`/`_source.changes` pair using `debsign`; then it submits via `dput`. The upload can be accepted while binary builds are still in progress. Verify build results in Launchpad before relying on the package.

For an initial manual upload, you can test the same source bundle on your trusted machine:

```bash
tar -xzf netavark-source-resolute-ppaxddd1.tar.gz
debsign -kFINGERPRINT netavark_*_source.changes
dput ppa:YOUR_LAUNCHPAD_ID/netavark netavark_*_source.changes
```

Use an isolated scratch directory containing the extracted bundle, so `debsign` can find its matching `.dsc` and source tarballs. Never reuse a version already published in that PPA; increment the downstream revision for another build.

## 3. Fedora COPR

1. Sign in with a [Fedora Accounts](https://accounts.fedoraproject.org/) account at [COPR](https://copr.fedorainfracloud.org/). Create a project (for example `netavark`).
2. Enable all four build chroots: **Fedora 43 x86_64**, **Fedora 43 aarch64**, **Fedora 44 x86_64**, **Fedora 44 aarch64**. Confirm the project can build a native source RPM.
3. Open [COPR API](https://copr.fedorainfracloud.org/api/) and copy the entire `[copr-cli]` credentials configuration. Store that as secret `COPR_CONFIG` in GitHub environment **`copr`**; set environment variable `COPR_PROJECT` to `OWNER/netavark` (or the actual project path). Tokens expire; rotate them before their expiration.
4. The approved job submits the matching Fedora 43 and/or 44 `.src.rpm` to its exact pair of chroots. `copr-cli build` waits for completion unless configured otherwise. Check the resulting repository binaries.

For a manual first test on Fedora: `sudo dnf install copr-cli`, copy the API credentials to `~/.config/copr`, then run `copr-cli build OWNER/netavark path/to/netavark-*.fc43.src.rpm`.

## 4. openSUSE Build Service (OBS)

1. Sign in at [build.opensuse.org](https://build.opensuse.org/), create a **separate source project for Leap 16.0 and Leap 16.1** (such as `home:USER:netavark:16.0` and `home:USER:netavark:16.1`). Keeping the projects separate prevents one `netavark` source-version upload from replacing the other.
2. Configure the Leap 16.0 and 16.1 repositories, including **x86_64** and **aarch64**, in their respective projects. Give the service account permission to modify only the intended projects where feasible.
3. Install the `osc` CLI locally, authenticate against `https://api.opensuse.org`, and confirm `osc ls YOUR_PROJECT` works. Store your working `~/.config/osc/oscrc` contents as environment secret `OBS_CONFIG`. Treat it like a password. Prefer a dedicated OBS account/token if available.
4. In GitHub environment **`obs`**, set variables `OBS_PROJECT_16_0` and `OBS_PROJECT_16_1` to your two exact project names. The approved job imports the matching source RPM using `osc importsrcpkg --commit` and replaces stale source-file entries; the OBS project then schedules its configured builds.

The workflow submits source, **not** GitHub-built binary RPMs. Check `osc results` and the resulting build repositories before considering the package published. Never point both variables to the same project.

## 5. Release and activate

1. Merge a package-version or patch change. After all required native builds pass, CI creates a **draft GitHub Release**, tagged `netavark-YYYYMMDD.N`, containing the full verified snapshot.
2. In **Actions → Publish release**, dispatch on `main`, supply the exact draft tag and confirmation `PUBLISH`, and approve the **`publishing`** environment.
3. The publication workflow verifies the complete draft, publishes the GitHub Release, then dispatches **Distribute release**. You may also dispatch distribution manually for an already published tag.
4. Only after all three environments, accounts and secrets are ready, set repository variable **`DISTRIBUTION_ENABLED=true`**.
5. The distribution workflow re-verifies the tag and artifacts, compares each target against that destination's **last successful GitHub submission**, and requests environment approval only for changed source/revision pairs. Reject one destination without blocking the others.

**A successful upload is not the same as a successful external build or published repository.** The GitHub environment records a completed submission when the upload command succeeds. For PPA and OBS, inspect destination build results before declaring availability. A failed or partially completed upload may need manual reconciliation before rerunning; archive versions cannot always be reused.

Do not push secrets to Git, workflow logs, or GitHub Release assets. No destination credentials are created by this repository.
