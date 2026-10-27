# Upstream PR #1522 backport — tracked separately from PR #1483

**Status:** design and compatibility review, not yet implemented or validated. Do
not publish a package described as including PR #1522 on the strength of this
document. This stacked branch is based on draft PR #1 and does not alter `main`.

## Sources and ownership

- Upstream merged fix: https://github.com/containers/netavark/pull/1522
- Root cause/reproduction: https://github.com/containers/netavark/issues/1515
- Upstream fix commit: `5d969595efeaf20b30ddaa135f43bbc7c95d3a19`
- Original upstream authorship and comments must be retained.
- Downstream backporter: **Albert Yau <albert@xddd.org>**.

The upstream fix on October 16, 2026 corrects IPv6 forwarding from/to
**internal networks without DNS** that previously skipped firewall setup
entirely. In Linux the per-interface IPv6 forwarding sysctl cannot guarantee
isolation while global IPv6 forwarding is enabled. This is **not** the
published-port DNAT problem in upstream PR #1483.

## Required independent quilt patch per supported source family

Patch `0002-fix-internal-network-ipv6-isolation.patch` must be created as a
separate upstream-faithful patch for Netavark 1.14, 1.16, 1.17 and 2.0.
Backport against the actual Debian/Ubuntu source, not against a 2.1 binary;
older upstream tags have significant structural differences:

1. `src/network/bridge.rs`: internal managed networks must call firewall
   setup and teardown; construct a `SetupNetwork` with `internal` and
   `dns_enabled`. The 1.14 path also uses a distinct sysctl branch.
2. `src/network/internal_types.rs` and `src/firewall/state.rs`: serialize
   the two flags; preserve backwards compatibility with previously persisted
   state, using upstream's `dns_enabled` default-true migration behavior.
3. `src/firewall/nft.rs`: add symmetric drop rules to
   `NETAVARK-ISOLATION-1` for ingress and egress of an internal bridge,
   before normal bridge isolation handling; suppress unnecessary DNS INPUT
   accept rules and firewalld trust on DNS-disabled internal networks; avoid
   allowing their subnet through general FORWARD accept rules.
4. Preserve upstream patch descriptions and comments; adapt only the API
   types of the target Netavark version. Review interaction with PR #1483:
   DNAT-mark accept in FORWARD is before the isolation jump. Neither patch
   may inadvertently make `--internal` traffic routable.

## Required regression tests before publishing

Use two long-lived Podman Compose services, one on a regular IPv4/IPv6 bridge
and the second on an **internal**, `--disable-dns`, strict-isolated IPv4/IPv6
bridge. Enable global IPv6 forwarding in the disposable privileged CI guest to
reproduce issue #1515. Test that:

- The external client cannot directly reach the internal container using
  either IPv4 or IPv6 (e.g. ICMP and TCP), even on a restart/reload.
- The internal container cannot forward IPv4/IPv6 to the external network.
- The internal network can still reach its own gateway and same-bridge peers.
- With DNS disabled, no unintended DNS INPUT accept or firewalld trusted-zone
  access is added.
- A network existing before upgrade gains the necessary isolation rules after
  controlled network reconfiguration; teardown removes them cleanly.
- Existing PR #1483 published-port tests on **non-internal** networks remain
  green over IPv4/IPv6 and no direct cross-bridge traffic is accepted.
- Record the kernel nftables rules, run the tests for each supported
  distribution/architecture, and fail CI if any required result is missing.

Do not add a placeholder empty patch to Debian quilt series or claim this
security fix exists in binaries until source, compile and runtime tests pass.

## Distribution choices as of 2026-10-27

- Fedora **44** (Netavark 1.17.2) is worth supporting while its release stays
  supported, around June 2027. Fedora 43 (December 2026 EOL) is not worth
  initiating a new downstream RPM maintenance program.
- Fedora 45 / Arch / Tumbleweed provide 2.1.0, which predates the 2026-10-16
  merger of PR #1522. **Do not assume Netavark 2.1.0 includes PR #1522.**
  Check for a distribution backport or version upgrade and test stock packages.
- For 1.14/1.16/1.17/2.0 distribution packages, check for downstream
  cherry-picks; do not infer the presence or absence of this fix from the
  numeric version alone.
- Use Fedora Copr (Fedora 44) and openSUSE OBS (Leap 16.0), each with its own
  native source RPM and signed repository, only after a proven patch.

