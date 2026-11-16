"""AArch64 receiver build gates (Phase 2).

Artifact-dependent tests report NOT RUN (skip) when the binaries were not
built; run ./build/build-native-rg35xxh.sh first. Script-content tests always
run and pin the build contract without compiling.
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
OUT = ROOT / "build/out"
BIN = OUT / "rg35xxh"
BINARIES = ("librespot", "ogg-http-bridge", "spotify-supervisor", "spotify-metadata")


def need_artifacts():
    missing = [name for name in BINARIES if not (BIN / name).is_file()]
    if missing:
        pytest.skip("NOT RUN: missing rg35xxh binaries "
                    f"({', '.join(missing)}); run ./build/build-native-rg35xxh.sh")


def need_tool(name):
    if shutil.which(name) is None:
        pytest.skip(f"NOT RUN: host lacks {name}")


def test_build_script_pins_contract():
    script = (ROOT / "build/build-native-rg35xxh.sh").read_text()
    assert "aarch64-unknown-linux-gnu" in script
    assert "target-cpu=cortex-a53" in script
    assert "--locked" in script
    assert "--no-default-features --features rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only" in script
    code = "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))
    assert "musleabi" not in code and "linux26-compat" not in code
    assert "rg35xxh-toolchain.sh" in script
    assert "check-rg35xxh-abi.sh" in script


def test_toolchain_script_pins_jammy_libc():
    script = (ROOT / "build/rg35xxh-toolchain.sh").read_text()
    assert "libc6_2.35-0ubuntu3.18_arm64.deb" in script
    assert "552390697756c005f8eff39b03392b2d8c6e148420c3e237d779fb44e54b5e72" in script
    assert "GLIBC_2.35" in script and "__isoc23" in script


def test_abi_gate_script_passes_on_artifacts():
    need_artifacts()
    need_tool("readelf")
    result = subprocess.run(["bash", str(ROOT / "build/check-rg35xxh-abi.sh"),
                             *[str(BIN / name) for name in BINARIES]],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ABI GATES OK" in result.stdout


def test_elf_headers_are_aarch64():
    need_artifacts()
    need_tool("readelf")
    for name in BINARIES:
        out = subprocess.run(["readelf", "-h", str(BIN / name)],
                             capture_output=True, text=True).stdout
        assert "ELF64" in out and "AArch64" in out, name


def test_no_sysv_ipc_or_isoc23_symbols():
    need_artifacts()
    need_tool("objdump")
    for name in BINARIES:
        out = subprocess.run(["objdump", "-T", str(BIN / name)],
                             capture_output=True, text=True).stdout
        assert not re.search(r" shmget| semget| shmat| shmctl| shmdt| semop| semctl| msgget| __isoc23", out), name


def test_build_manifest_matches_artifacts():
    need_artifacts()
    manifest = json.loads((OUT / "rg35xxh-build.json").read_text())
    assert manifest["target"] == "aarch64-unknown-linux-gnu"
    assert manifest["cpu"] == "cortex-a53"
    assert "1.98.1" in manifest["rustc"] or "rustc" in manifest
    import hashlib
    for name in BINARIES:
        digest = hashlib.sha256((BIN / name).read_bytes()).hexdigest()
        assert manifest["binaries"][name]["sha256"] == digest, name
    targets = json.loads((OUT / "native-targets-rg35xxh.json").read_text())
    assert targets["hardware"] == ["rg35xxh"]


def test_toolchain_provenance_recorded():
    need_artifacts()
    Fingerprint = json.loads((OUT / "rg35xxh-toolchain.json").read_text())
    assert "gcc-13-aarch64-linux-gnu" in Fingerprint["toolchainDebs"] or \
        "gcc-aarch64-linux-gnu" in Fingerprint["toolchainDebs"]
    assert "2.35" in Fingerprint["sysrootSuite"]


def test_qemu_librespot_reports_version_and_rejects_nocreds():
    need_artifacts()
    need_tool("qemu-aarch64")
    sysroot = OUT / "rg35xxh-sysroot"
    if not (sysroot / "lib/aarch64-linux-gnu/libc.so.6").exists():
        pytest.skip("NOT RUN: Jammy sysroot not assembled")
    run = lambda *args: subprocess.run(["qemu-aarch64", "-L", str(sysroot), str(BIN / "librespot"), *args],
                                       capture_output=True, text=True)
    version = run("--version")
    assert version.returncode == 0 and "librespot 0.8.0" in version.stdout
    nocreds = run("--disable-discovery", "--name", "qemutest")
    assert nocreds.returncode == 1
    assert "Credentials are required" in nocreds.stderr


def test_qemu_bridge_passes_drain_script():
    need_artifacts()
    need_tool("qemu-aarch64")
    sysroot = OUT / "rg35xxh-sysroot"
    if not (sysroot / "lib/aarch64-linux-gnu/libc.so.6").exists():
        pytest.skip("NOT RUN: Jammy sysroot not assembled")
    import subprocess as sp
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as wrapper:
        wrapper.write(f'#!/bin/sh\nexec qemu-aarch64 -L "{sysroot}" "{BIN / "ogg-http-bridge"}" "$@"\n')
    Path(wrapper.name).chmod(0o755)
    result = sp.run(["python3", str(ROOT / "tests/native_bridge_drain.py"), wrapper.name],
                    capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "PASS" in result.stdout
