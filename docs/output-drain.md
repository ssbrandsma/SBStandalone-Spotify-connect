# Natural track completion

In the compressed passthrough pipeline, librespot can finish writing a track
while audio remains in the FIFO, HTTP connection, compressed decoder buffer,
and PCM output. Producer EOF therefore must not stop or replace local playback.

When `SBSPOTIFY_DRAIN_PATH` is configured, the streaming-only passthrough player
holds its normal `EndOfTrack` event after entering its existing end-of-track
state. It atomically publishes an output-drain request containing the process,
player, play-request, and Ogg stream serial IDs. A 100 ms asynchronous poll waits
for the exact token in the acknowledgement file; the command receiver stays
active. Queued commands are handled before acknowledging natural completion.
Load and Stop cancel the pending completion, so a manual next/previous/selection
retains the existing immediate discard/restart path. Pause and resume also work
while the tail is draining, including after the HTTP connection has closed.

The bridge forwards the complete Ogg EOS page, publishes `stream.ready.eos`
with the current generation/serial, and closes that HTTP response. Closing the
response lets stock SqueezePlay observe network EOF without flushing its audio.
The bridge itself and the producer FIFO remain alive for the next track.

The Lua watcher acknowledges only when the EOF marker matches the current
stream, the request serial matches that stream, and the current playback owner
reports `sentAudioUnderrunEvent` with no remaining network stream. Stock
SqueezePlay sets that flag on STMu, after decoder underrun AND output underrun.
Decoder completion (STMd) or an empty bridge queue alone is insufficient.
Paused playback and playback owned by another source cannot acknowledge it.

Only then does librespot emit `EndOfTrack` to Spotify's automatic-next handler.
The metadata helper does not translate natural completion into `stopped`;
explicit stop still retains that behavior. Loading markers include play-request
IDs so separate requests for the same track are distinguishable. Exhausted
streaming-only decoders are reopened on repeat because they cannot seek back.

No fixed audio-delay estimate is used. If the output acknowledgement is missing,
automatic advancement waits; manual selection/stop remains available. This is
not a gapless implementation: loading and starting the next track can introduce
a gap after the previous track finishes. Spotify position reporting still uses
the producer clock rather than the speaker clock.

Validation:

- `python -m pytest -q` exercises the Lua watcher, output ownership checks,
  pause/resume after network EOF, token cancellation and atomic acknowledgement.
- `rustc --edition 2021 --test native/librespot/playback/src/drain.rs -o /tmp/drain-test`
  followed by `/tmp/drain-test` checks matching/stale acknowledgements and
  cancellation using actual filesystem operations.
- On Linux, compile the bridge and run
  `python3 tests/native_bridge_drain.py build/out/ogg-http-bridge-host` to check
  complete EOS delivery, HTTP EOF, and reuse for the next stream.
- `build/build-native.ps1 -Hardware all` builds the shared Linux 2.6-compatible
  static ARMv5TE runtime for Radio and Touch.

These checks do not substitute for audible playback validation on both devices.

## Device deployment

Deployed the development build (still advertising applet version 0.6.3) to
`192.168.1.78` on 13 November 2026. Hardware reports Logitech MX25 Baby Board,
ARM926EJ-S, Linux 2.6.26.8-rt16. The applet directory is backed by the persistent
`sbdata` volume mounted at `/usr/share/jive/applets`.

All 20 staged files were read back and verified using SHA-256 before activation.
The native librespot executable ran successfully on the Radio. Existing Base
and Radio installer records were preserved; preceding installer settings are
backed up at `/mnt/sbdata/spotify-backup-20261113-211015/SetupAppletInstaller.lua`.
There was no preceding SpotifyConnect applet directory to back up.

The watchdog rebooted the Radio during the initial SqueezePlay restart. After
boot, SpotifyConnect registered successfully, Jive and jive_alsa were running,
installer settings retained all three applets, and native/Service file hashes
still matched. Pairing and audible natural-completion/manual-skip validation
were not performed. Public server packages and repository XML were not changed.
