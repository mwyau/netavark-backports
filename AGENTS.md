# Maintainer and agent instructions

This repository backports the nftables fix from [Netavark PR #1483](https://github.com/containers/netavark/pull/1483) for [issue #709](https://github.com/containers/netavark/issues/709). Do not add unrelated upstream patches.

## Scope and patch review

- Fetch and rebuild the distribution's **native source**; do not fork upstream Netavark or relabel a Debian binary for Ubuntu.
- Keep each patch as a conventional unified diff with DEP-3 metadata, link the issue and merged upstream PR, preserve original Rust comments and changes. Keep any distro-specific adjustments minimal.
- Netavark 1.14 uses older nftables Rust types than 1.16/1.17/2.0. Do not blindly copy an incompatible patch between families.
- Keep the extra in-place-upgrade rule insertion: a conntrack-marked accept rule must precede an isolation jump that is already installed on a running network.
- If a native source update changes patch anchors, APIs or dependencies, fail the build and review it. Do not silently fall back to an older source or overwrite distro security changes.

## Build and test

- Shared build entrypoints live under `scripts/build/`, CI under `scripts/ci/`, network tests under `tests/`.
- Build and test each distribution on its own native package manager and an appropriate native-architecture runner.
- Validate the original failure, a fresh patched installation and an upgrade with existing Compose services and networks. Both IPv4 and IPv6 published ports must work without allowing direct cross-bridge traffic.
- Keep openSUSE experimental until its native RPMs pass the same regressions on both architectures. Never count stock-network tests as patched-package tests.
- Build and source artifacts must be labeled with suite, architecture, source version and git revision. Preserve complete uploadable Ubuntu source components and native Fedora/openSUSE SRPMs.

## Revisions, releases and Git

- `release/revision.txt` is the common downstream xddd revision. A CI run, retry or documentation change does not increment it.
- `release/sources.lock.json` contains reviewed native source versions. Update the lock and bump the revision in the same reviewed change when package contents change for a new distribution release.
- PRs and pushes to main validate and upload CI artifacts. Only successful main-branch builds for a new revision may assemble an unpublished draft GitHub Release.
- Never upload directly to PPA, COPR, OBS, APT or make a GitHub Release public from a PR. Publication requires an explicit manual workflow and protected environment.
- Do not force-push, rewrite existing published tags, merge a draft PR, or publish binaries without permission.
