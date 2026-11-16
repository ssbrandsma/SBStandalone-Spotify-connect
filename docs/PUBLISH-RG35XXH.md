# PUBLISH-RG35XXH.md — Release and publication procedure

Live publication needs the repository host credentials, which are an
owner action. Everything below that point is scripted and tested.

## Cut the release (host)

1. Bump `VERSION` (semver) and update the `$Changes` release notes in
   `build/package.ps1` (shared across all three entries).
2. Build both runtimes:
   ```powershell
   ./build/build-native.ps1 -Hardware all       # baby+fab4 (WSL)
   ```
   ```bash
   ./build/build-native-rg35xxh.sh              # rg35xxh (rootless)
   ```
3. Package both (order matters: each run regenerates the merged XML):
   ```powershell
   ./build/package.ps1                          # shared ZIP + baby/fab4 entries
   ./build/package.ps1 -Hardware rg35xxh        # rg35xxh ZIP + merged 3-entry XML
   ```
4. Verify: `python -m pytest tests -q` (64 tests), `shellcheck -S
   warning build/*.sh applet/spotify-metadata-event`, reproducibility
   check (clean rebuild, same `SOURCE_DATE_EPOCH` → identical SHA256).
5. Collect from `dist/` and `build/out/`:
   `SpotifyConnect-<ver>.zip`, `SpotifyConnect-<ver>-rg35xxh.zip`,
   `extensions.xml`, `extensions.xml.sha1`, both `.sha256` sidecars,
   `rg35xxh-build.json`, `rg35xxh-toolchain.json`, `rg35xxh-sbom.json`.

## Publish (owner)

1. Upload `extensions.xml` + both ZIPs (+ `.sha1`/`.sha256` sidecars) to
   the `sbspotifyconnect` web directory (default
   `http://49.12.198.91/sbspotifyconnect`; override with `-BaseUrl`).
   Keep the previous version's files during rollout; keep `.bak`
   timestamped backups of overwritten metadata (existing convention).
2. Confirm plain-HTTP fetch works (stock firmware has no TLS here):
   download `extensions.xml`, verify its `.sha1`, download each ZIP,
   verify its `<sha>` and `.sha256`.
3. On an LMS hosting this repo as an Additional Repository, confirm the
   `rg35xxh` entry is served to `jiveapplets target:rg35xxh` queries.
4. On the device (exclusive hardware lock): run Installer discovery →
   install → pair → playback → remove, per `SPOTIFY-CONNECT-TESTS.md`
   stages 2–7. Record hardware evidence with the release.

## Rollback

Republish the previous `extensions.xml` + ZIP set. Devices reinstall the
older version; credentials and settings survive (see
`UPGRADE-RG35XXH.md`).
