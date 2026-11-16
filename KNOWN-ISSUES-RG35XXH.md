# KNOWN-ISSUES-RG35XXH.md

Last updated: Phase 5 (host work complete; device validation pending).

## Open (need device or sibling project)

1. **No on-device validation yet.** Stages 1–8 in
   `SPOTIFY-CONNECT-TESTS.md` are NOT RUN. Nothing here is claimed
   working on hardware until Phase 6 observes it.
2. **Standalone Base contract (O2).** The applet publishes Now Playing
   over the existing HTTP API (`127.0.0.1:9000`) and degrades silently
   without it. Which contract the RG35XX H Standalone Base port will
   expose (HTTP vs `/run/squeezebox/nowplaying.json`) is unknown; verify
   on device and add a second sink only if that port requires it.
3. **Installer transport.** The Jive installer queries LMS
   (`jiveapplets target:rg35xxh`), so until the on-device LMS ships, a
   reachable (possibly temporary) LMS must host the repo for Method A.
   Playback never needs LMS. Method B (manual unzip) needs no LMS at all.
4. **`SQUEEZEPLAY_HOME` visibility (O3).** Path resolution assumes Jive
   Lua inherits `SQUEEZEPLAY_HOME` from `launch.sh` (with `$HOME`, then
   `/tmp`, fallbacks). Confirm on device; wrong root fails loudly with
   `Required runtime files are unavailable`.
5. **Vendored librespot base (R5).** Exact upstream base (a1b66d3c vs
   d36f9f19) plus local patch diff is unpinned; pin during release.

## By design (not bugs)

6. **No direct-ALSA fork.** The port reuses the pipe+FIFO+bridge+Tremor
   path, so SqueezePlay stays the sole ALSA holder — no second audio
   ownership mechanism, no new arbitration. The reference standalone
   librespot service (direct ALSA) is a parallel effort: do NOT run both
   at once (two Spotify devices, two audio paths).
7. **Discovery stays off.** `--disable-discovery` as on baby/fab4: the
   device appears via Spotify cloud after pairing, never via mDNS. No
   mDNS advertisement can leak after exit; cloud presence clears on
   graceful disconnect (supervisor SIGTERM) with Spotify-side timeout.
8. **Physical next/previous** act on the stock stream (same as
   Radio/Touch): there is no Lua→librespot command channel, so track
   skipping from device buttons is limited to stock behavior. Remote
   (Spotify app) commands work fully. Play/pause/volume stay consistent
   through the single firmware gain stage.
9. **Artwork proxy** (`127.0.0.1:8765`) is provided by Standalone Base;
   without it, artwork loads fail silently (bounded, no retries storm).
10. **Premium required.** Spotify Connect mandates a Premium account.
11. **Session-bounded log.** `engine.log` lives in RAM and is cleared on
    every stop; within one long session it is append-only (no rotation).
12. **Suspend.** StockOS idle-suspend stops Wi-Fi/CPU; music cannot play
    through true suspend. Verify in Phase 6 that playback holds the
    device awake per SqueezeboxGo's existing policy and that stock power
    behavior restores on exit.

## Pre-existing (not introduced by this port)

13. fab4 on-device pairing/playback was never exercised upstream.
14. Applet Installer removal ordering vs `free()/shutdown()` is inferred
    from the Jive lifecycle, not coded; same on all targets.
