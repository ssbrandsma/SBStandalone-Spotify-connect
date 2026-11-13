# Spotify Connect service lifecycle

## Architecture

`SpotifyService.lua` is the sole lifecycle authority. It owns the desired
state, validates the operating mode, stages executables in
`/dev/spotify-connect-runtime`, starts the bridge and supervisor, and performs
bounded asynchronous shutdown. The supervisor owns only its librespot child;
it records that child's PID, forwards status, handles TERM/INT, and restarts an
unexpected exit after 1, 2, 5, 10, then 30 seconds. A ten-second Lua health
check recovers a missing supervisor or bridge only while the in-memory desired
state is Running.

PID files are not trusted alone. Before TERM or KILL, the service verifies the
PID's `/proc/<pid>/cmdline` contains the expected executable under the owned RAM
runtime. No `pidof`, `killall`, or `pkill` operation is used. Stop records the
desired state first, stops local playback, releases Now Playing, sends TERM,
and checks completion every 250 ms. After three seconds it escalates only the
same verified owned PIDs. Credentials and persistent settings are preserved.

## Modes and persistence

- **Disabled:** cannot start, never recovers, and changing into this mode stops
  owned processes. Credentials remain intact.
- **Manual:** starts only from the menu and remains desired-running until Stop
  or SqueezePlay shutdown. Desired state is intentionally not persisted, so a
  reboot remains stopped.
- **Always On:** starts during applet initialization when saved credentials are
  available and recovers failures. Stop is rejected until the mode is changed
  to Manual. Restart remains available.

New settings use Manual. During upgrade, an installation with no
`serviceMode` migrates `enabled=true` to Always On, preserving the former boot
behavior; other legacy installations migrate to Manual. Selecting a mode sets
`serviceModeExplicit=true` and makes it authoritative. Existing users can open
**Spotify Connect > Operating Mode > Manual** and then use Start/Stop controls.

## UI and errors

The applet menu displays operating mode, normalized state, device name, and the
last lifecycle error. Controls are mode-sensitive: Disabled has no Start,
Always On has no Stop, and Manual exposes the applicable Start or Stop action.
Status refreshes every two seconds only while the menu is open. Start readiness
and stop completion use one-shot timers and never sleep in the Jive event loop.

SBWebserver has no authenticated applet-control contract that can safely call
this in-process Lua authority. Web control is therefore deliberately deferred;
no unauthenticated endpoint or second lifecycle manager was introduced.

## Resource behavior

When stopped, librespot, `spotify-supervisor`, and `ogg-http-bridge` are absent
and the RAM-staged runtime and transient markers are removed. This recovers the
processes' physical resident memory; VSZ should not be treated as RAM usage.
The bridge previously opened the loading marker and checked its nonblocking
listener every 100 ms while idle. Idle marker/socket waits are now 250 ms,
while active audio remains page-driven. Expected activation latency impact is
at most 150 ms compared with the old interval.

Measure on hardware with BusyBox-compatible commands:

```sh
ps | grep -E 'librespot|spotify-supervi|ogg-http' | grep -v grep
for p in `pidof librespot spotify-supervisor ogg-http-bridge 2>/dev/null`; do
  echo "PID $p"; grep -E '^(Name|State|VmSize|VmRSS):' /proc/$p/status
done
grep -E '^(MemTotal|MemFree|Buffers|Cached):' /proc/meminfo
top -b -n 1 | head -25
```

## Physical validation

Host tests simulate persistence, migration, duplicate operations, transitions,
owned-PID signaling, and recovery structure. They do not validate ARM process
behavior. On a Radio:

1. Upgrade an enabled 0.6.1 installation and confirm it migrates to Always On.
2. Change to Manual, stop, reboot, and confirm all three processes remain absent.
3. Start twice; confirm exactly one bridge, supervisor, and librespot exist.
4. Stop during playback; confirm audio and all three owned processes terminate.
5. Start again and kill only librespot; confirm supervisor backoff recovery.
6. Kill the supervisor or bridge; confirm the ten-second health check recovers it.
7. Select Disabled; confirm Start is unavailable and credentials remain present.
8. Exercise rapid Manual Start/Stop/Restart and verify the final requested state.
9. Return to Always On, reboot, and confirm automatic startup.
10. Compare `/proc/*/status`, `/proc/meminfo`, and idle CPU before and after Stop.

Rollback by reinstalling 0.6.1. Its existing settings ignore the new keys;
credentials are compatible and do not need removal.

For Qobuz, the reusable concepts are the three persisted modes, volatile
desired state, normalized status, verified PID ownership, asynchronous stop,
and conservative health timer. The Spotify-specific launch command, status
files, metadata, and supervisor remain local rather than forming a large shared
framework.
