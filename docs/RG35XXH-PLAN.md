# RG35XX H Port — Architecture and Build Plan (Phase 0)

Target: Anbernic RG35XX H (`rg35xxh`) running SqueezeboxGo (SqueezePlay 9.0.0
r541, PUC Lua 5.1.5, StockOS Ubuntu 22.04 ARM64, glibc 2.35, kernel 4.9.170).
Basis: multi-agent inventory of this repo plus read-only inspection of
`~/projects/SqueezeboxRG35XXH`. All claims below were verified against file
bodies; see §8 for gaps.

## 1. Current architecture (baby / fab4)

Lua Jive applet + one shared native runtime:

- `applet/SpotifyConnectApplet.lua` — lifecycle, 250 ms track watcher,
  Standalone Radio deactivation, remote-volume popup.
- `applet/SpotifyConnectMeta.lua` — registration, settings
  (`enabled`/`deviceName`/`serviceMode`), pairing QR window.
- `applet/SpotifyService.lua` — daemon supervision (modes
  `disabled`/`manual`/`always_on`), RAM staging, FIFO, launch commands.
- `applet/SpotifyPlayback.lua` — stock SqueezePlay stream playback
  (HTTP GET from bridge, Tremor mode `o`, firmware volume curve).
- `applet/SpotifyStandaloneNowPlaying.lua` — Standalone Base HTTP API
  (`127.0.0.1:9000/api/nowplaying`, claim/update/heartbeat/release).
- `applet/SpotifyNativeNowPlaying.lua` — firmware `goNowPlaying` push.
- `applet/SpotifyUrlTransport.lua` — artwork URL proxy rewrite
  (`127.0.0.1:8765`).
- `applet/SpotifyOwnership.lua` — Standalone Base `OwnershipBinding`
  (`owner="spotify"`); nil-safe when Standalone Base is absent.

Native runtime (one `armv5te-unknown-linux-musleabi` static soft-float
build shared by baby and fab4):

- `native/librespot` (vendored 0.8.0, features
  `rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only`)
  invoked with `--backend pipe --device <FIFO> --passthrough
  --disable-audio-cache --disable-discovery --system-cache <USER>
  --bitrate 96`, plus `--enable-device-auth` when pairing.
- `native/bridge` — paced Ogg HTTP server on `127.0.0.1:17880`.
- `native/supervisor` — restart backoff, status.json, pairing/connected parsing.
- `native/metadata` — `PLAYER_EVENT` → metadata.json + sidecars.
- `native/linux26-compat` — Linux 2.6 syscall shims (bridge+librespot only).

Audio path: librespot pipe backend → `USER/audio.fifo` → bridge
→ `SpotifyPlayback` mode `o` → Tremor → stock `jive_alsa` → speakers.
**Librespot never touches ALSA.** Volume: librespot softvol u16 →
percent → `player:volumeLocal` + `decode:audioGain`.

Paths: `ROOT=/usr/share/jive/applets/SpotifyConnect`,
`RUNTIME=/dev/spotify-connect-runtime` (RAM), `USER=/etc/squeezeplay/
userpath/SpotifyConnect` (persistent creds + volatile state).

Packaging: `build/build-native.sh` (baby|fab4|all, one shared runtime) →
`build/build-applet.ps1` → `build/package.ps1` → versioned flat ZIP +
`dist/extensions.xml` (two entries, same ZIP/SHA) served over plain HTTP.

Tests: 32 pytest cases over real Lua 5.1 (lupa) + Rust/file assertions;
`python -m pytest tests` from a project `.venv` (see `docs/development.md`).

## 2. Key decisions for rg35xxh

### D1. Reuse the pipe+FIFO+bridge+stock-decoder backend (no ALSA fork)

The SqueezeboxGo reference builds librespot with `alsa-backend` driving
ALSA directly. That recipe is **not** reused for the applet port:

- The applet architecture already routes audio through the native
  SqueezePlay engine, which is exactly the interoperability §9 asks for
  (Jive volume, arbitration via decoder sharing, Now Playing, headphone
  switching — all free, all already tested).
- Direct ALSA would fork a second backend, a second Now Playing
  publisher, and a second audio-ownership mechanism, and would force
  arbitration between SqueezePlay and librespot for the same `plughw`
  device. The task forbids all three.
- With the reused path, the ALSA holder remains SqueezePlay (already
  proven on StockOS: `plughw:audiocodec` RUNNING), and Spotify decoder
  access keeps flowing through the existing `SpotifyOwnership` binding.
- mDNS/discovery stays off (`--disable-discovery`, cloud login after
  cached creds), identical to baby/fab4 — no new network surface, no
  orphaned advertisement risk beyond the supervised process itself.

Consequence: the AArch64 build compiles the **same Rust sources with the
same feature set**, retargeted to `aarch64-unknown-linux-gnu`, glibc ≤
2.35, `-C target-cpu=cortex-a53`, no musl/static, no `linux26-compat`.

### D2. Capability-based platform module, baby/fab4 byte-identical

New `applet/SpotifyPlatform.lua` (plain table module, pcall-guarded)
centralises machine → model mapping and path resolution. `baby`/`fab4`
resolve to the exact strings used today; only `rg35xxh` diverges:

| Item            | baby / fab4 (unchanged)                        | rg35xxh |
|---|---|---|
| Model name      | Squeezebox Radio / Touch                       | SqueezeboxGo |
| Applet root     | `/usr/share/jive/applets/SpotifyConnect`       | `$SQUEEZEPLAY_HOME/userpath/applets/SpotifyConnect` (probed, fallback to system dir) |
| Persistent dir  | `/etc/squeezeplay/userpath/SpotifyConnect`     | `$SQUEEZEPLAY_HOME/userpath/SpotifyConnect` (creds only) |
| Volatile state  | same as persistent (unchanged)                 | `/dev/spotify-connect-runtime` (RAM: FIFO, pids, status, metadata, log) |
| Runtime bins    | same `RUNTIME` (RAM staging)                   | same mechanism, AArch64 binaries |

Rationale for the split state dir: `metadata.json` + `.position` churn
at event rate; StockOS config lives on microSD, so high-churn files
move to RAM (§14). Baby/fab4 keep one dir (zero behaviour change).

### D3. Packaging: separate AArch64 ZIP, third extensions entry

`target=rg35xxh` gets its own ZIP (ARMv5 binaries cannot run on
AArch64). The RG35XX H installer already falls back `rg35xxh → baby`,
so a distinct entry is required to avoid serving the ARMv5 ZIP.

### D4. Contracts reused, none forked

- Now Playing: existing Standalone Base HTTP API + native push.
  The reference file contract (`/run/squeezebox/nowplaying.json`) belongs
  to shell-service backends; no second publisher is added unless the
  Standalone Base port requires it (open item O2).
- Audio ownership: existing `OwnershipBinding`; no new mechanism.
- Lifecycle: existing `free()/shutdown()` TERM→KILL + cleanup covers the
  SqueezeboxGo exit path; verified by tests, proven on device in Phase 6.

## 3. AArch64 build matrix (Phase 2)

- Sources: vendored `native/librespot` + bridge/supervisor/metadata as-is.
- Toolchain (pinned in Phase 2): Rust 1.85+ (match `rust-version`),
  `aarch64-unknown-linux-gnu` std, `gcc-aarch64-linux-gnu` ≥ 12,
  Jammy sysroot (glibc floor 2.35, assert max `GLIBC ≤ 2.35`, zero
  `__isoc23`), `libasound2-dev:arm64` only if an ALSA-gated helper needs
  it (expected: none — pipe backend needs no ALSA headers).
- Flags: `--locked --release --no-default-features --features
  rustls-tls-webpki-roots,with-libmdns,passthrough-decoder,streaming-only`,
  `RUSTFLAGS -C target-cpu=cortex-a53`, drop `musl`, `+crt-static`,
  `-no-pie`, `linux26-compat`, `--wrap`.
- Gates: `file`/`readelf -h/-d/--version-info`/`objdump -T`, NEEDED
  allowlist, no SysV IPC (`shmget`/`semget` — kernel returns ENOSYS),
  SHA256 manifest, `SOURCE_DATE_EPOCH` reproducibility check.
- Reference `/tmp/librespot-wp3` binary is **not** reused (glibc 2.39 >
  2.35 floor, direct-ALSA features, uncommitted, unhashed in git).

## 4. Phase plan

- P0 (this doc): inventory + decisions. Done.
- P1: `SpotifyPlatform.lua`, Meta/Service/Applet seams, `test_platform_
  rg35xxh.py`, Lua 5.1 syntax gate for all applet files. Baby/fab4 green.
- P2: `build/build-native-rg35xxh.sh` (+ps1 wrapper), pinned toolchain,
  ABI/kernel gates, `native-targets.json` multi-target.
- P3: separate rg35xxh ZIP, `extensions.xml` third entry, fixture repo,
  install/upgrade/uninstall tests.
- P4: lifecycle hardening (exit-path orphan check), volume-map test,
  Standalone Radio handover on rg35xxh, NP contract verification.
- P5: full suite + `BUILD/INSTALL/UPGRADE/UNINSTALL/SPOTIFY-CONNECT-
  TESTS/KNOWN-ISSUES-RG35XXH.md`.
- P6: exclusive-lock hardware validation (8 stages), iterate.
- P7: release artifacts (ZIP, SHA256, manifest, SBOM, provenance).

## 5. Risks

- R1 glibc floor: build host must not leak >2.35 symbols (gate it).
- R2 SqueezeboxGo applet/user paths assumed from `launch.sh`
  (`$SQUEEZEPLAY_HOME/userpath/...`); confirm on device in P6.
- R3 Standalone Base RG35XX H port API surface unknown (HTTP vs file
  NP, OwnershipBinding availability) — applet degrades gracefully
  either way; verify in P4/P6.
- R4 Coexistence: reference standalone librespot service + applet must
  not run together (documented in KNOWN-ISSUES).
- R5 Vendored librespot exact upstream base (a1b66d3c vs d36f9f19) +
  local patch diff unresolved — pin during P2.

## 6. Open items

- O1 installer removal ordering vs `free()/shutdown()` (inferred, not coded).
- O2 NP contract expected by the RG35XX H Standalone Base port.
- O3 `SQUEEZEPLAY_HOME` visibility inside Jive Lua (assumed; else parse
  `/proc/self/environ` — decide in P1, verify in P6).
- O4 fab4 on-device pairing/playback still unexercised (pre-existing gap).
