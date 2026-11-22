# SBSpotifyConnect

Clean Spotify Connect applet project for the Logitech Squeezebox Radio (`baby`) and Touch (`fab4`).

The `0.7.0` release packages a Jive applet, the pinned Phase 7
streaming-only librespot engine, an owned local Ogg bridge, and a status
supervisor. First use shows Spotify's device-authorization pairing URL; the
supported librespot credential cache then allows automatic reconnect after
restart and reboot.

The production path is compressed audio throughout:

`Spotify → stream-only librespot → Vorbis passthrough → bounded HTTP Ogg bridge → stock SqueezePlay/Tremor → jive_alsa → speaker`

Both hardware targets use a shared static ARMv5TE soft-float runtime with Linux
2.6 compatibility wrappers. The Radio is ARM926EJ-S/ARMv5TEJ; the Touch
also supports this instruction baseline. PCM decoding in
librespot, direct ALSA, shared memory, effects FIFOs, and stock Playback patches
are excluded because the research repository proved they are the wrong boundary.

See [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md),
and [docs/packaging.md](docs/packaging.md).

The Applet Installer repository is published over plain HTTP for compatibility
with the stock Radio firmware:
`http://49.12.198.91/sbspotifyconnect/extensions.xml`.

Spotify playback uses the original Logitech Now Playing screen through
StandaloneBase's loopback Now Playing API. Librespot remains authoritative for
Spotify Connect and audio; the applet publishes its event-driven metadata,
state, duration and position without polling the network. HTTPS cover URLs are
passed through SBHttpsProxy. See [docs/standalonebase-now-playing.md](docs/standalonebase-now-playing.md)
for lifecycle, source switching, limitations and device validation.

Spotify services support Disabled, Manual, and Always On operating modes.
Fresh installations default to Manual so librespot, its supervisor, and the
Ogg bridge consume no resources until requested. See
[docs/service-lifecycle.md](docs/service-lifecycle.md).

Native engine, supervisor, and bridge output goes through syslog with the
`SpotifyConnect` tag and appears in Standalone Base's system log viewer
(`/var/log/messages`). The logging pipe lives in RAM; the applet no longer
appends to `userpath/SpotifyConnect/engine.log`. Existing copies of that old
log are left untouched.

Set the SqueezePlay `SpotifyConnect` logging category to DEBUG, then restart
the Spotify Connect service to enable librespot debug output. Return the
category to INFO and restart the service to restore normal verbosity.
Logging changes are applied on service start so changing a category does
not interrupt a playing track. Syslog records use `user.info`; librespot's
original severity remains in the message text.

Release 0.7.0 fixes natural track-end draining, manual list selection, and native Now Playing metadata updates. The UI watcher validates processes directly through `/proc` without spawning shell commands. Artwork is handled by StandaloneBase; the obsolete custom artwork and Now Playing implementations have been removed.
