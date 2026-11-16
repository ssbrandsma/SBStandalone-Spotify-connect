#!/usr/bin/env python3
"""gen-rg35xxh-sbom.py — dependency/license inventory for the rg35xxh build.

Reads native/librespot/Cargo.lock plus the local cargo registry cache for
per-crate licenses, the applet file list, and the build/toolchain manifests.
Writes build/out/rg35xxh-sbom.json. Pure stdlib (tomllib needs 3.11+).
"""
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).parents[1]
OUT = ROOT / "build/out"
FEATURES = "rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only"


def crate_license(name, version):
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    for registry in (cargo_home / "registry/src").glob("*"):
        manifest = registry / f"{name}-{version}" / "Cargo.toml"
        if manifest.is_file():
            try:
                data = tomllib.loads(manifest.read_text())
                lic = data["package"].get("license")
                if lic:
                    return lic
                lic_file = data["package"].get("license-file")
                if lic_file:
                    return f"license-file:{lic_file} (see crate)"
            except (tomllib.TOMLDecodeError, KeyError):
                pass
    return "unknown (see crate registry)"


def compiled_closure():
    """name@version set in the binary for our exact feature set (None if unknown)."""
    try:
        out = subprocess.run(
            ["cargo", "tree", "--manifest-path", str(ROOT / "native/librespot/Cargo.toml"),
             "--locked", "--target", "aarch64-unknown-linux-gnu",
             "--no-default-features", "--features", FEATURES,
             "--prefix", "none", "--edges", "normal,build"],
            capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    closure = set()
    for line in out.stdout.splitlines():
        parts = line.strip().split(" ")
        if len(parts) >= 2 and parts[1].startswith("v"):
            closure.add(f"{parts[0]}@{parts[1][1:]}")
    return closure


def main():
    lock = tomllib.loads((ROOT / "native/librespot/Cargo.lock").read_bytes().decode())
    closure = compiled_closure()
    crates = []
    for package in lock["package"]:
        source = package.get("source", "")
        if source.startswith("registry"):
            license_ = crate_license(package["name"], package["version"])
        else:
            license_ = "MIT (workspace, see native/librespot/LICENSE)"
        key = f"{package['name']}@{package['version']}"
        crates.append({"name": package["name"], "version": package["version"],
                       "source": source or "path (vendored)", "license": license_,
                       "compiled": None if closure is None else key in closure})
    crates.sort(key=lambda c: (c["name"], c["version"]))
    build, toolchain = {}, {}
    if (OUT / "rg35xxh-build.json").is_file():
        build = json.loads((OUT / "rg35xxh-build.json").read_text())
    if (OUT / "rg35xxh-toolchain.json").is_file():
        toolchain = json.loads((OUT / "rg35xxh-toolchain.json").read_text())
    sbom = {
        "package": "SpotifyConnect",
        "target": "rg35xxh",
        "version": (ROOT / "VERSION").read_text().strip(),
        "appletLicense": "MIT (see LICENSE)",
        "librespotBase": "a1b66d3c8a14e55a9572a9e17467150dca618c9a (see native/librespot/VENDORED.md)",
        "systemLibraries": [
            {"name": "libc.so.6", "license": "LGPL-2.1-or-later (device system library, dynamically linked, not bundled)"},
            {"name": "libgcc_s.so.1", "license": "GPL-3.0-with-GCC-exception (device system library, dynamically linked, not bundled)"},
        ],
        "notes": [
            "TLS via rustls (static); no OpenSSL dependency.",
            "mDNS via with-libmdns (pure Rust); no Avahi dependency.",
            "No ALSA linkage: pipe backend only; audio decodes in stock SqueezePlay.",
        ],
        "crates": crates,
        "rustc": build.get("rustc"),
        "cargo": build.get("cargo"),
        "binaries": build.get("binaries"),
        "toolchainDebs": toolchain.get("toolchainDebs"),
        "sysrootSuite": toolchain.get("sysrootSuite"),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "rg35xxh-sbom.json").write_text(json.dumps(sbom, indent=2) + "\n")
    print(f"wrote {OUT / 'rg35xxh-sbom.json'} ({len(crates)} crates)")


if __name__ == "__main__":
    if sys.version_info < (3, 11):
        print("gen-rg35xxh-sbom.py needs python3.11+ (tomllib)", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
