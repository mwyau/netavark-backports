#!/usr/bin/env python3
"""Build native packages and exercise their Podman networking regressions."""

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(os.environ.get("GITHUB_WORKSPACE", Path(__file__).resolve().parents[1]))


def required(*names: str) -> list[str]:
    values = [os.environ.get(name, "") for name in names]
    if not all(values):
        sys.exit(f"Missing environment: {', '.join(n for n, v in zip(names, values) if not v)}")
    return values


def command(*args: str) -> None:
    subprocess.run(args, check=True)


def docker(image: str, script: str, *, runtime: bool = False,
           volumes: tuple[str, ...] = (), **env: str) -> None:
    args = ["docker", "run", "--rm", "--pull=always", "-v", f"{ROOT}:/work", "-w", "/work"]
    if runtime:
        args += ["--privileged", "--security-opt", "seccomp=unconfined"]
    for volume in volumes:
        args += ["-v", volume]
    for key, value in env.items():
        args += ["-e", f"{key}={value}"]
    command(*args, image, "bash", script)


def revision(family: str, target: str) -> str:
    return subprocess.check_output(
        [sys.executable, str(ROOT / "release/versions.py"), "--revision", family, target],
        text=True,
    ).strip()


def one_package(output: Path, pattern: str) -> Path:
    packages = list(output.glob(pattern))
    if len(packages) != 1:
        sys.exit(f"Expected one {pattern} in {output}; found {len(packages)}")
    return packages[0]


def test(image: str, output: Path, script: str, variable: str,
         modes: tuple[str, ...], rev: str | None = None) -> None:
    volumes = (f"{output}:/packages:ro",)
    for mode in modes:
        env = {variable: mode}
        if rev is not None:
            env["REVISION"] = rev
        docker(image, f"/work/scripts/{script}", runtime=True, volumes=volumes, **env)


def deb() -> None:
    suite, arch = required("SUITE", "EXPECTED_ARCH")
    if suite in ("resolute", "stonking"):
        family, image = "ubuntu", f"ubuntu:{suite}"
    elif suite in ("trixie", "forky", "sid", "experimental"):
        family = "debian"
        image = "debian:sid" if suite == "experimental" else f"debian:{suite}"
    else:
        sys.exit(f"Unsupported suite: {suite}")
    rev = revision(family, suite)
    docker(image, "/work/scripts/deb.sh",
           SUITE=suite, EXPECTED_ARCH=arch, REVISION=rev)
    output = ROOT / "dist" / suite / arch
    package = one_package(output, f"netavark_*_{arch}.deb")
    name = subprocess.check_output(["dpkg-deb", "--field", str(package), "Package"],
                                   text=True).strip()
    if name != "netavark":
        sys.exit(f"Unexpected Debian package: {name}")
    if suite == "experimental":
        print("Build-only Netavark 2.x: excluded from release")
        return
    test(image, output, "ports.sh", "NETAVARK_TEST_MODE",
         ("upgrade",))
    test(image, output, "dualstack.sh", "NETAVARK_DUALSTACK_MODE",
         ("fresh", "upgrade"))
    if not list((output / "source").glob("*.dsc")):
        sys.exit("Missing native Debian source package")
    print(f"PASS: {suite} / {arch} build and IPv4+IPv6 integration")


def rpm() -> None:
    platform, image, arch = required("RPM_PLATFORM", "RPM_IMAGE", "RPM_ARCH")
    if platform in ("fedora43", "fedora44"):
        family, target, script, variable = (
            "fedora", platform.removeprefix("fedora"), "fedora.sh", "FEDORA_RELEASE")
    elif platform in ("leap16", "leap161"):
        family, target, script, variable = (
            "opensuse", "16.0" if platform == "leap16" else "16.1",
            "opensuse.sh", "LEAP_VERSION")
    else:
        sys.exit(f"Unsupported RPM platform: {platform}")
    rev = revision(family, target)
    docker(image, f"/work/scripts/{script}",
           **{variable: target, "EXPECTED_ARCH": arch, "REVISION": rev})
    output = ROOT / "dist" / platform / arch
    one_package(output, "netavark-*.rpm")
    test(image, output, "dualstack.sh", "NETAVARK_DUALSTACK_MODE",
         ("fresh", "upgrade"), rev)
    if family == "fedora" and not list((output / "source").glob("*.src.rpm")):
        sys.exit("Missing native Fedora source RPM")
    print(f"PASS: {family} {target} / {arch} build and IPv4+IPv6 integration")


if __name__ == "__main__":
    if not (ROOT / "scripts").is_dir():
        sys.exit(f"Missing native scripts in {ROOT}")
    if sys.argv[1:] == ["deb"]:
        deb()
    elif sys.argv[1:] == ["rpm"]:
        rpm()
    else:
        sys.exit("usage: run.py deb|rpm")
