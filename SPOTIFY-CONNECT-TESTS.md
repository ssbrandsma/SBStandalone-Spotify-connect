# SPOTIFY-CONNECT-TESTS.md — Test plan and status

## Host suite (runs here, no device, no Spotify account)

```bash
uv venv && uv pip install pytest lupa   # once
.venv/bin/python -m pytest tests -q
```

63 tests, all passing. Coverage by file:

| File | What it pins |
|---|---|
| `test_lifecycle.py` | daemon modes/PID validation, Meta settings migration, supervisor/bridge markers |
| `test_service_runtime.py` | status/event readers, RAM staging, watcher track+volume, firmware gain/mute |
| `test_drain.py` | EOS/output-drain gating, STMu latch, atomic ack |
| `test_nowplaying_integration.py` | artwork proxy, claim/update/heartbeat/409-takeover/release, native push |
| `test_layout.py` | required sources, no custom NP, bridge/player markers |
| `test_platform_rg35xxh.py` | machine→model map, historical baby/fab4 paths, SqueezeboxGo paths + fallbacks, service start per platform, Meta names, Lua 5.1 syntax gate |
| `test_build_rg35xxh.py` | build-contract pins, ABI gates on artifacts, ELF/SysV checks, manifest match, qemu librespot + bridge drain |
| `test_packaging_rg35xxh.py` | per-target staging/packaging scripts, live pwsh package + ZIP/XML round-trip, legacy entry shape |
| `test_integration_rg35xxh.py` | orphan reap (rg35xxh-only), pipe-only audio, u16 boundaries, NP outage+recovery, shutdown cleanup |
| `native_bridge_drain.py` | helper: synthetic-Ogg bridge pacing/EOS/skip integration |

Environment-gated tests report **NOT RUN** (visible skip) instead of
passing silently when artifacts are absent: build `build/out/rg35xxh`
via `./build/build-native-rg35xxh.sh`, install `qemu-aarch64` / `pwsh`
to enable them.

Also run: `shellcheck -S warning build/*.sh applet/spotify-metadata-event`
(clean) and the reproducibility check (two clean builds, same
`SOURCE_DATE_EPOCH` → identical SHA256; verified for all four binaries).

## Fixture repository (local Installer testing)

```bash
~/.local/pwsh/pwsh -NoProfile -File ./build/package.ps1 -Hardware rg35xxh \
  -OutputDirectory /tmp/rg35xxh-repo -BaseUrl http://<host>:8080/rg35xxh
cd /tmp/rg35xxh-repo && python3 -m http.server 8080
```

Point an LMS **Additional Repositories** entry at the served
`extensions.xml`, or use Method B manual install. Fixture results never
imply live availability.

## Device acceptance (Phase 6 — all NOT RUN until the hardware lock)

Requires exclusive `rg35xxh` access per the shared lock protocol.

| Stage | Checks |
|---|---|
| 1 runtime | isolated deploy, deps, start/stop, ALSA compat, bounded logs |
| 2 discovery | Installer flow, device appears/disappears with correct name |
| 3 playback | real audio (speakers+headphones), stereo, no XRUNs, sane levels |
| 4 control | play/pause/next/prev/volume from Spotify + physical buttons |
| 5 Now Playing | artist/title/album/art/state/position/duration/volume/source |
| 6 switching | Spotify ↔ Radio ↔ native ↔ Qobuz, no ALSA fights or stale NP |
| 7 lifecycle | exit→no orphans/mDNS/ALSA residue; relaunch+reboot recovery |
| 8 stability | soak: CPU/RAM/XRUNs/reconnects/SD writes/crashes/transitions |

Results are recorded per stage as PASS/FAIL/BLOCKED/NOT RUN with
observations; BLOCKED where a backend (e.g. Qobuz) is not installed.
