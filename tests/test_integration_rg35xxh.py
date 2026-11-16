"""Service lifecycle, audio, volume, Now Playing integration (Phase 4).

Pins the SqueezeboxGo app-lifecycle hardening (boot-time orphan reap),
the pipe-only single-gain-stage audio path, volume boundaries, and Now
Playing outage survival. Imports harnesses from the platform/np suites.
"""
from pathlib import Path

import pytest
from lupa.lua51 import LuaRuntime

from test_platform_rg35xxh import (GO_HOME, GO_ROOT, GO_USER, RUNTIME, SYSTEM_USER,
                                   service_with_platform)
from test_nowplaying_integration import client_runtime

RUNTIME_PREFIX = RUNTIME + "/"


def init_commands(machine):
    files = {GO_ROOT + "/librespot": "binary"} if machine == "rg35xxh" else {}
    lua, _ = service_with_platform(machine, {"SQUEEZEPLAY_HOME": GO_HOME}, files, "x")
    return [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]


def test_init_reaps_orphans_on_rg35xxh_only():
    go = init_commands("rg35xxh")
    reap = [c for c in go if "/proc/[0-9]*" in c]
    assert len(reap) == 1
    sweep = reap[0]
    assert "'" + RUNTIME_PREFIX + "'" in sweep
    assert "kill -TERM" in sweep and "kill -KILL" in sweep
    assert "sleep 1" in sweep
    assert any("rm -rf '" + RUNTIME + "'" in c for c in go)
    baby = init_commands("baby")
    assert not any("/proc/[0-9]*" in c for c in baby)


def test_reap_scan_skips_its_own_shell():
    go = init_commands("rg35xxh")
    reap = next(c for c in go if "/proc/[0-9]*" in c)
    assert '[ "$p" != "$$" ]' in reap


def test_rg35xxh_audio_stays_pipe_only_with_firmware_gain():
    lua, service = service_with_platform("rg35xxh", {"SQUEEZEPLAY_HOME": GO_HOME},
                                         {GO_ROOT + "/librespot": "binary"}, "SqueezeboxGo")
    assert service.start(service, False) is True
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    launch = next(c for c in commands if "librespot" in c and "--backend" in c)
    assert "--backend pipe" in launch and "--passthrough" in launch
    assert "--mixer" not in launch and "plughw" not in launch and '"hw:' not in launch
    # Exactly one gain stage exists: the firmware curve in setRemoteVolume.
    # The receiver only reports softvol; it never scales pipe output.


def test_watcher_maps_u16_boundaries_to_percent():
    from test_service_runtime import make_watcher
    lua, applet = make_watcher()
    watcher = applet._trackWatcher
    lua.globals().data.volume = 65535
    watcher.callback()
    assert lua.globals().volumes[1] == 100
    lua.globals().data.volume = 1
    watcher.callback()
    assert lua.globals().volumes[2] == 0


def test_nowplaying_survives_total_api_outage_and_recovers():
    lua, mod = client_runtime()
    calls = []
    timers = lua.eval("""(function()
        local made = {}
        local factory = function(ms, callback, once)
            local t = {ms=ms, start=function() end, stop=function() end}
            table.insert(made, t); return t
        end
        return {factory=factory, made=made}
    end)()""")
    failing = {"fail": True}

    def request(method, path, payload, callback):
        calls.append(path)
        if failing["fail"]:
            callback(None, None, "unreachable")
        else:
            callback(200, '{"success":true}', None)

    options = lua.table_from({"request": request, "timerFactory": timers.factory,
                              "isPlaybackOwner": lambda: True})
    client = mod.new(options)
    data = lua.table_from({"track_id": "abc", "title": "T", "artist": "A",
                           "playback_state": "playing"})
    client.activate(client, data, 1)  # must not raise without a server
    client.update(client, data, 1)
    client.release(client)
    assert len(timers.made) >= 1  # backoff scheduled, audio path untouched
    failing["fail"] = False
    client.activate(client, data, 2)
    assert calls[-1] == "/api/nowplaying/claim"


def test_shutdown_leaves_no_desired_state_on_rg35xxh():
    lua, service = service_with_platform("rg35xxh", {"SQUEEZEPLAY_HOME": GO_HOME},
                                         {GO_ROOT + "/librespot": "binary"}, "SqueezeboxGo")
    service.start(service, False)
    service.shutdown(service)
    assert service.getStatus(service) == "stopped"
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    assert any("rm -rf '" + RUNTIME + "'" in c for c in commands)
