# StandaloneBase Now Playing integration

## Architecture and lifecycle

Librespot remains the Spotify Connect authority and continues to handle remote
play, pause, next, previous, seek, volume, transfer, and queue operations. The
existing Ogg bridge and stock decoder remain unchanged. The Lua adapter is only
a presentation integration: it claims StandaloneBase when a new Spotify stream
is ready, publishes a complete snapshot, renews the 120-second lease every 45
seconds, and releases after `stopped` or applet shutdown.

Requests are asynchronous, limited to one in flight, bounded to 16 KiB and a
15-second timeout, and retried after 2, 5, 10, then 30 seconds. New desired state
coalesces while a request is active. HTTP 409 invalidates the token and probes
public status. An empty server is reclaimed only while Spotify still owns local
playback; an active radio or other source is left alone until a genuine new
Spotify activation. Tokens are kept in RAM and never logged.

## Metadata and position

Each update uses `live:false`, a stable `spotify:track:<id>`, title, comma-joined
artists, album, duration in milliseconds, playback state, and the position from
librespot's play/pause/seek/position-correction events. StandaloneBase advances
playing position monotonically, so no high-frequency position timer is needed.
Track changes publish a complete snapshot and empty values clear prior metadata.

The first Spotify cover URL is forwarded directly. HTTP remains unchanged;
HTTPS becomes `http://127.0.0.1:8765/https/<host>/<path>`, preserving query
parameters and percent encoding. Already-proxied URLs are unchanged. Invalid,
credential-bearing, whitespace-containing, or oversized URLs become an empty
artwork value. No cover is downloaded or cached for this path.

## Native navigation and controls

On a new ready stream, the applet calls firmware 7.7.3's `goNowPlaying` service
with `Window.transitionPushLeft`. A short bounded retry handles startup races;
the stock window is not duplicated when already current. Generation checks
cancel stale callbacks. Metadata, artwork, heartbeat, recovery, and background
connection updates never navigate.

Spotify and Standalone Radio share the single stock SqueezePlay decoder. On a
genuine Spotify loading/stream-ready event, Spotify calls Radio's existing
`StreamPlayer:stop()` before opening its loopback Ogg stream, then clears the
stale active `desiredStation` while retaining Radio's `lastStation`. This
cancels Radio reconnect generations and prevents its installed disconnect hook
from reclaiming the decoder. Selecting a radio station later starts Radio
normally and its StandaloneBase claim supersedes Spotify's session.

StandaloneBase currently routes play, pause, stop, next and previous commands,
but this Spotify build has no reliable Lua-to-librespot command IPC. All local
capabilities are therefore advertised as false. Seek and volume are also not
routed by StandaloneBase API v1. Physical playback buttons through native Now
Playing are a known limitation; Spotify app remote control and hardware volume
behavior remain unchanged. No command acknowledgement is attempted for an
operation the backend cannot accept.

## Physical-device validation

These steps require a Radio and are not covered by host mocks:

1. Start playback on a phone and transfer it to the Squeezebox Radio.
2. Confirm the stock Logitech Now Playing screen opens once.
3. Verify title, artist, album, cover, duration, and progressing position.
4. Pause and resume from Spotify; verify state and frozen/resumed position.
5. Skip next/previous and seek from Spotify; verify track and position updates.
6. Change Spotify volume and verify existing device-volume behavior.
7. Navigate away and confirm metadata/artwork/heartbeat updates do not steal focus.
8. Select a Standalone Radio preset and confirm radio takes ownership without
   Spotify reclaiming in the background.
9. Transfer playback back to Spotify and confirm Spotify metadata returns and
   only one native Now Playing window exists.
10. Stop StandaloneBase temporarily and confirm audio continues; restart it and
    verify a complete snapshot is republished when no other source owns it.
11. Confirm physical playback commands are not offered as supported; document
    actual firmware button behavior separately if later backend IPC is added.
