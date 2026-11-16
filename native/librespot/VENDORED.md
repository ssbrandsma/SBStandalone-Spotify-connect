# Vendored librespot provenance

- Upstream: `librespot-org/librespot`, post-0.8.0 development branch.
- Base commit: `a1b66d3c8a14e55a9572a9e17467150dca618c9a`
  (verified 2026-11-17: this tree differs from that commit only by the
  patch set below; `Cargo.lock` is identical).
- This is NOT the v0.8.0 tag (`d36f9f19`): the base carries upstream
  post-release changes, which is why `CHANGELOG.md` shows
  `[Unreleased]` above `[0.8.0]`.

## Local patch set (16 files)

| File(s) | Purpose |
|---|---|
| `Cargo.toml`, `audio/Cargo.toml`, `playback/Cargo.toml` | `streaming-only` feature plumbing |
| `audio/src/fetch/streaming.rs` (new), `audio/src/fetch/mod.rs` | sequential 64 KiB CDN ranges, bounded queue, Ogg-prefix handling |
| `playback/src/drain.rs` (new), `playback/src/player.rs`, `playback/src/lib.rs` | output-drain gate (`SBSPOTIFY_DRAIN_PATH` token protocol) |
| `playback/src/decoder/passthrough_decoder.rs` | raw Ogg packet passthrough tweaks |
| `playback/src/audio_backend/phase5_fifo.rs` (new), `playback/src/audio_backend/pipe.rs` | FIFO producer guards |
| `src/player_event_handler.rs` | `PLAYER_EVENT` environment for the metadata hook |
| `connect/src/model.rs` | mobile empty-URI/UID selection fix (+ unit test) |
| `connect/src/state.rs` | connect-state update timeout |
| `core/src/dealer/manager.rs`, `core/src/dealer/mod.rs` | prompt dealer ack on slow CPUs |

Regenerate the full diff:

```bash
curl -sSL -o /tmp/lp-base.tar.gz \
  https://github.com/librespot-org/librespot/archive/a1b66d3c8a14e55a9572a9e17467150dca618c9a.tar.gz
mkdir -p /tmp/lp-base && tar -xzf /tmp/lp-base.tar.gz -C /tmp/lp-base
diff -ru /tmp/lp-base/librespot-a1b66d3c8a14e55a9572a9e17467150dca618c9a \
  native/librespot --exclude=target --exclude=.git
```

Do not re-vendor or rebase this tree for the rg35xxh port: all targets
build these exact sources; only the toolchain/target/features-selection
differs (see `BUILD-RG35XXH.md`).
