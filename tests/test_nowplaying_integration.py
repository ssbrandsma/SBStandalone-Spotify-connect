from pathlib import Path
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).parents[1]


def lua_module(path, name, prelude=""):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(prelude)
    return lua, lua.execute(path.read_text(), name)


def test_artwork_proxy_preserves_url_and_rejects_bad_values():
    lua, mod = lua_module(ROOT / "applet/SpotifyUrlTransport.lua", "url_test")
    assert mod.artworkUrl("https://i.scdn.co/image/a%20b?x=1&y=2") == \
        "http://127.0.0.1:8765/https/i.scdn.co/image/a%20b?x=1&y=2"
    proxied = "http://127.0.0.1:8765/https/i.scdn.co/a.jpg"
    assert mod.artworkUrl(proxied) == proxied
    assert mod.artworkUrl("http://example.com/a.jpg") == "http://example.com/a.jpg"
    assert mod.artworkUrl("https://user:pass@example.com/a") is None
    assert mod.artworkUrl("file:///tmp/a") is None


def client_runtime():
    prelude = r'''
      timers = {}
      package.loaded['jive.net.RequestHttp'] = {}
      package.loaded['jive.net.SocketHttp'] = {}
      package.loaded['jive.ui.Timer'] = function(ms, callback, once)
        local t={ms=ms,callback=callback,once=once,started=false,stopped=false,
          start=function(self) self.started=true end, stop=function(self) self.stopped=true end}
        table.insert(timers,t); return t
      end
      package.loaded['ltn12'] = {}
      package.loaded['json'] = {decode=function(s)
        if string.find(s, 'session_id') then return {success=true,active=true,session_id='secret',generation=7} end
        if string.find(s, 'api_version') then return {api_version=1,active=string.find(s, '"active":true') ~= nil} end
        if string.find(s, 'success') then return {success=true} end
        return {}
      end,encode=function() return '{}' end}
      package.loaded['applets.SpotifyConnect.SpotifyUrlTransport'] = dofile('applet/SpotifyUrlTransport.lua')
    '''
    return lua_module(ROOT / "applet/SpotifyStandaloneNowPlaying.lua", "np_test", prelude)


def test_claim_metadata_state_position_seek_heartbeat_takeover_and_release():
    lua, mod = client_runtime()
    requests = []

    def request(method, path, payload, callback):
        requests.append((method, path, payload, callback))

    options = lua.table_from({"request": request, "timerFactory": lua.globals().package.loaded['jive.ui.Timer'],
                              "isPlaybackOwner": lambda: True})
    client = mod.new(options)
    data = lua.table_from({"track_id": "abc", "title": "Track", "artist": "A, B", "album": "Album",
                           "duration_ms": "200000", "position_ms": 42000, "playback_state": "playing",
                           "artwork_url": "https://i.scdn.co/cover.jpg"})
    client.activate(client, data, 1)
    assert requests[0][1] == "/api/nowplaying/claim"
    caps = requests[0][2].capabilities
    assert not any((caps.play, caps.pause, caps.stop, caps.next, caps.previous, caps.seek, caps.volume))
    requests.pop(0)[3](201, '{"success":true,"active":true,"session_id":"secret","generation":7}', None)
    assert requests[0][1] == "/api/nowplaying/update"
    update = requests[0][2]
    assert update.track.id == "spotify:track:abc"
    assert update.track.artist == "A, B"
    assert update.position_ms == 42000 and update.track.duration_ms == 200000
    assert update.track.artwork_url.startswith("http://127.0.0.1:8765/https/")
    requests.pop(0)[3](200, '{"success":true}', None)

    paused = lua.table_from({"track_id": "abc", "title": "Track", "artist": "A, B", "album": "Album",
                             "duration_ms": "200000", "position_ms": 90000, "playback_state": "paused",
                             "artwork_url": "https://i.scdn.co/cover.jpg"})
    client.update(client, paused, 1)
    assert requests[0][2].position_ms == 90000 and requests[0][2].state == "paused"
    requests.pop(0)[3](409, '{"error":"invalid_session"}', None)
    assert requests[0][1] == "/api/nowplaying"
    requests.pop(0)[3](200, '{"api_version":1,"active":true,"source":"radio"}', None)
    assert client.status(client).activeIntent is False


def test_stale_generation_and_shutdown_are_safe():
    lua, mod = client_runtime(); requests = []
    client = mod.new(lua.table_from({"request": lambda m,p,b,c: requests.append((m,p,b,c)),
                                    "timerFactory": lua.globals().package.loaded['jive.ui.Timer']}))
    first = lua.table_from({"track_id":"one","playback_state":"playing","position_ms":1})
    client.activate(client, first, 2)
    client.update(client, lua.table_from({"track_id":"stale","playback_state":"playing"}), 1)
    assert client.status(client).revision == 1
    client.shutdown(client)
    assert client.status(client).activeIntent is False


def test_song_change_queued_during_heartbeat_is_published_on_completion():
    lua, mod = client_runtime(); requests = []
    client = mod.new(lua.table_from({"request": lambda m,p,b,c: requests.append((m,p,b,c)),
                                    "timerFactory": lua.globals().package.loaded['jive.ui.Timer']}))
    client.activate(client, lua.table_from({"track_id":"first", "playback_state":"playing"}), 1)
    requests.pop(0)[3](201, '{"success":true,"active":true,"session_id":"secret","generation":7}', None)
    requests.pop(0)[3](200, '{"success":true}', None)
    client._heartbeat(client)
    heartbeat = requests.pop(0)
    assert heartbeat[1] == '/api/nowplaying/heartbeat'
    client.activate(client, lua.table_from({"track_id":"second", "playback_state":"playing",
                                           "artwork_url":"https://i.scdn.co/second"}), 2)
    assert not requests
    heartbeat[3](200, '{"success":true}', None)
    assert requests[0][1] == '/api/nowplaying/update'
    assert requests[0][2].track.id == 'spotify:track:second'
    assert requests[0][2].track.artwork_url.endswith('/second')


def test_metadata_arriving_after_stream_ready_updates_without_restarting_audio():
    from test_service_runtime import make_watcher
    lua, applet = make_watcher()
    lua.execute('metadataUpdates=0')
    applet.standaloneNowPlaying.update = lua.eval('function() metadataUpdates=metadataUpdates+1 end')
    data = lua.globals().data
    data.stream = '1:22'
    applet._trackWatcher.callback()
    before = lua.globals().metadataUpdates
    data.metadata = '{"track_id":"second","artwork_url":"new-cover"}'
    applet._trackWatcher.callback()
    assert lua.globals().metadataUpdates == before + 1
    assert lua.globals().starts == 1
    applet._trackWatcher.callback()
    assert lua.globals().metadataUpdates == before + 1


def test_rapid_manual_selections_publish_latest_song_and_cover_after_pending_update():
    lua, mod = client_runtime(); requests = []
    client = mod.new(lua.table_from({"request": lambda m,p,b,c: requests.append((m,p,b,c)),
                                    "timerFactory": lua.globals().package.loaded['jive.ui.Timer']}))
    def song(track):
        return lua.table_from({"track_id":track, "playback_state":"playing",
                               "title":track, "artwork_url":"https://i.scdn.co/" + track})
    client.activate(client, song('first'), 1)
    requests.pop(0)[3](201, '{"success":true,"active":true,"session_id":"secret","generation":7}', None)
    initial = requests.pop(0)
    assert initial[2].track.id == 'spotify:track:first'
    client.activate(client, song('second'), 2)
    client.activate(client, song('third'), 3)
    assert not requests
    initial[3](200, '{"success":true}', None)
    assert requests[0][2].track.id == 'spotify:track:third'
    assert requests[0][2].track.artwork_url.endswith('/third')


def test_quality_is_optional_and_identical_snapshots_do_not_notify():
    lua, mod = client_runtime()
    client = mod.new(lua.table_from({"request": lambda *args: None}))
    data = lua.table_from({"track_id": "one", "playback_state": "playing"})
    client.activate(client, data, 1)
    snapshot = client._snapshot(client)
    assert snapshot.track.audio is None and snapshot.track.transport is None
    audio = {"codec": "vorbis", "bitrate_kbps": 320}
    data = lua.table_from({"track_id": "one", "playback_state": "playing",
                           "audio": lua.table_from(audio)})
    assert client.update(client, data, 1)
    revision = client.status(client).revision
    clone = lua.table_from({"track_id": "one", "playback_state": "playing",
                            "audio": lua.table_from(audio)})
    assert not client.update(client, clone, 1)
    assert client.status(client).revision == revision
    assert client._snapshot(client).track.audio.codec == "vorbis"


def test_native_navigation_coalesces_and_rejects_stale_retry():
    prelude = r'''
      timers={}; calls=0; current=false; service=true; player=true
      function timerFactory(ms,cb,once)
        local t={callback=cb,start=function() end,stop=function(self) self.stopped=true end}
        table.insert(timers,t); return t
      end
      manager={hasService=function() return service end,
        callService=function(_,name) if name=='getCurrentPlayer' then return player end calls=calls+1 end,
        getAppletInstance=function() return {window={}} end}
      framework={isCurrentWindow=function() return current end}
    '''
    lua, mod = lua_module(ROOT / "applet/SpotifyNativeNowPlaying.lua", "nav_test", prelude)
    generation = {"value": 1}
    nav = mod.new(lua.table_from({"appletManager":lua.globals().manager,"framework":lua.globals().framework,
        "timerFactory":lua.globals().timerFactory,"getGeneration":lambda: generation["value"]}))
    nav.request(nav, 1); lua.globals().timers[1].callback(); assert lua.globals().calls == 1
    lua.globals().current = True
    nav.request(nav, 1); lua.globals().timers[2].callback(); assert lua.globals().calls == 1
    nav.request(nav, 1); generation["value"] = 2; lua.globals().timers[3].callback(); assert lua.globals().calls == 1
