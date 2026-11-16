"""Applet packaging + repository metadata (Phase 3).

Static tests pin the release scripts without executing them. Live tests run
the real stage/package flow under pwsh and report NOT RUN when pwsh or the
rg35xxh binaries are absent.
"""
import hashlib
import os
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
OUT = ROOT / "build/out"


def pwsh():
    exe = shutil.which("pwsh") or os.path.expanduser("~/.local/pwsh/pwsh")
    if not Path(exe).is_file():
        pytest.skip("NOT RUN: pwsh unavailable")
    return exe


def need_rg35xxh_binaries():
    missing = [n for n in ("librespot", "ogg-http-bridge", "spotify-supervisor", "spotify-metadata")
               if not (OUT / "rg35xxh" / n).is_file()]
    if missing or not (OUT / "native-targets-rg35xxh.json").is_file():
        pytest.skip("NOT RUN: rg35xxh native runtime not built")


def test_native_script_delegates_rg35xxh():
    script = (ROOT / "build/build-native.sh").read_text()
    assert 'rg35xxh) exec "$ROOT/build/build-native-rg35xxh.sh"' in script
    assert "baby|fab4|rg35xxh|all" in script


def test_ps1_wrappers_accept_rg35xxh():
    for name in ("build-native.ps1", "build-applet.ps1", "package.ps1"):
        assert "'rg35xxh'" in (ROOT / f"build/{name}").read_text(), name


def test_staging_uses_per_target_dirs_and_fails_closed():
    script = (ROOT / "build/build-applet.ps1").read_text()
    assert "out/rg35xxh" in script
    assert "out/applet-rg35xxh/SpotifyConnect" in script
    assert "native-targets-rg35xxh.json" in script
    assert "Native binary is missing" in script


def test_package_builds_per_target_zips_and_merged_xml():
    script = (ROOT / "build/package.ps1").read_text()
    assert 'SpotifyConnect-$Version-rg35xxh.zip' in script
    assert "'rg35xxh'" in script
    assert "Anbernic RG35XX H running SqueezeboxGo" in script
    assert 'minTarget="7.7" maxTarget="*"' in script


def package(exe, tmp_path, hardware):
    result = subprocess.run(
        [exe, "-NoProfile", "-File", str(ROOT / "build/package.ps1"),
         "-Hardware", hardware, "-OutputDirectory", str(tmp_path),
         "-BaseUrl", "http://127.0.0.1:8080/testrepo"],
        capture_output=True, text=True, cwd=ROOT, timeout=300)
    assert result.returncode == 0, result.stdout + result.stderr
    return result


def test_live_rg35xxh_package_contents_and_metadata(tmp_path):
    need_rg35xxh_binaries()
    exe = pwsh()
    package(exe, tmp_path, "rg35xxh")
    version = (ROOT / "VERSION").read_text().strip()
    zippath = tmp_path / f"SpotifyConnect-{version}-rg35xxh.zip"
    assert zippath.is_file()
    with zipfile.ZipFile(zippath) as archive:
        names = sorted(i.filename for i in archive.infolist() if not i.is_dir())
    assert names == sorted([
        "librespot", "ogg-http-bridge", "spotify-supervisor", "spotify-metadata",
        "spotify-metadata-event", "spotify-logo.jpg", "qrencode.lua", "strings.txt",
        "SpotifyConnectApplet.lua", "SpotifyConnectMeta.lua", "SpotifyConnectState.lua",
        "SpotifyNativeNowPlaying.lua", "SpotifyStandaloneNowPlaying.lua",
        "SpotifyUrlTransport.lua", "SpotifyPlayback.lua", "SpotifyOwnership.lua",
        "SpotifyPlatform.lua", "SpotifyService.lua"])
    assert not any("/" in name for name in names)
    with zipfile.ZipFile(zippath) as archive:
        magic = archive.read("librespot")[:4]
        assert magic == b"\x7fELF"
    if shutil.which("file") is not None:
        member = tmp_path / "librespot-probe"
        with zipfile.ZipFile(zippath) as archive:
            member.write_bytes(archive.read("librespot"))
        out = subprocess.run(["file", "-b", str(member)], capture_output=True, text=True).stdout
        assert "ARM aarch64" in out
    xml = ET.parse(tmp_path / "extensions.xml")
    applets = xml.getroot().find("applets").findall("applet")
    go = [a for a in applets if a.get("target") == "rg35xxh"]
    assert len(go) == 1
    assert go[0].get("version") == version
    assert go[0].find("url").text == f"http://127.0.0.1:8080/testrepo/{zippath.name}"
    assert go[0].find("sha").text == hashlib.sha1(zippath.read_bytes()).hexdigest()
    assert (tmp_path / "extensions.xml.sha1").read_text().strip() == \
        hashlib.sha1((tmp_path / "extensions.xml").read_bytes()).hexdigest()


def test_live_shared_zip_entry_shape_matches_published_repo(tmp_path):
    need_rg35xxh_binaries()
    exe = pwsh()
    # Stand-in shared binaries: entry SHAPE is under test, not ARMv5 bytes.
    (OUT / "native-targets.json").write_text(
        '{"hardware":["baby","fab4"],"target":"armv5te-unknown-linux-musleabi"}')
    try:
        for name in ("librespot", "ogg-http-bridge", "spotify-supervisor", "spotify-metadata"):
            shutil.copy(OUT / "rg35xxh" / name, OUT / name)
        package(exe, tmp_path, "all")
    finally:
        (OUT / "native-targets.json").unlink(missing_ok=True)
        for name in ("librespot", "ogg-http-bridge", "spotify-supervisor", "spotify-metadata"):
            (OUT / name).unlink(missing_ok=True)
    published = ET.parse(ROOT / "dist/extensions.xml")
    fresh = ET.parse(tmp_path / "extensions.xml")
    for new, old in zip(fresh.getroot().find("applets"), published.getroot().find("applets")):
        assert new.get("target") == old.get("target")
        for tag in ("title", "desc", "changes", "creator"):
            assert new.find(tag).text == old.find(tag).text
