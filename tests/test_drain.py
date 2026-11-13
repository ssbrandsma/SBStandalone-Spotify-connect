from pathlib import Path

from lupa.lua51 import LuaRuntime
from test_service_runtime import make_watcher

ROOT = Path(__file__).parents[1]


def test_watcher_waits_for_output_and_manual_skip_starts_without_ack():
    lua, applet = make_watcher()
    lua.execute('''
        drained, acknowledgements = false, {}
    ''')
    applet.playback.hasDrained = lua.eval('function() return drained end')
    applet.service.acknowledgeDrain = lua.eval('''function(_, token)
        table.insert(acknowledgements, token); return true end''')
    data = lua.globals().data
    tick = applet._trackWatcher.callback
    data.stream = '1:22'
    tick()
    assert lua.globals().starts == 1
    data.drain = '123:0:1:22'
    tick()  # Producer EOF, but EOS still in the FIFO.
    assert len(lua.globals().acknowledgements) == 0
    data.eos = '1:22'
    tick()  # EOS forwarded, but output still contains audio.
    assert len(lua.globals().acknowledgements) == 0
    lua.globals().drained = True
    data.playback_state = 'paused'
    tick()
    assert len(lua.globals().acknowledgements) == 0
    data.playback_state = 'playing'
    tick()
    assert lua.globals().acknowledgements[1] == '123:0:1:22'

    # A manual skip is allowed while output has NOT drained.
    lua.globals().drained = False
    data.drain = None
    data.loading = 'next:2'
    data.eos = None
    tick()
    data.stream = '2:33'
    tick()
    assert lua.globals().starts == 2
    assert len(lua.globals().acknowledgements) == 1
    # Late markers from the old track cannot complete this new playback.
    lua.globals().drained = True
    data.drain = '123:0:1:22'
    data.eos = '2:33'
    tick()
    assert len(lua.globals().acknowledgements) == 1


def test_playback_completion_requires_audio_drain_and_current_owner():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
        package.loaded['loop.simple'] = {class=function() end}
        package.loaded['squeezeplay.stream'] = {}
        package.loaded['squeezeplay.decode'] = {resumeAudio=function() end}
        forwarded=0
        pb = {stream={}, sentDecoderUnderrunEvent=true,
              sendStatus=function() forwarded=forwarded+1; return true end}
        player = {playback=pb}
        package.loaded['jive.slim.Player'] = {getLocalPlayer=function() return player end}
    ''')
    lua.execute((ROOT / 'applet/SpotifyPlayback.lua').read_text(), 'drain_playback')
    playback = lua.globals().package.loaded['drain_playback']
    playback.init(playback, lua.table())
    playback.playback = lua.globals().pb
    playback._watchDrain(playback)
    assert playback.hasDrained(playback) is False
    lua.globals().pb.stream = None
    assert playback.hasDrained(playback) is False  # Decoder EOF alone is insufficient.
    lua.globals().pb.sendStatus(lua.globals().pb, lua.table(), 'STMd')
    assert playback.hasDrained(playback) is False
    old_hook = lua.globals().pb.sendStatus
    lua.globals().pb.sendStatus(lua.globals().pb, lua.table(), 'STMu')
    # The firmware flag can reset before the next applet poll. The event
    # must remain latched until this playback is replaced or stopped.
    lua.globals().pb.sentAudioUnderrunEvent = False
    assert playback.hasDrained(playback) is True
    assert lua.globals().forwarded == 2
    playback.paused = True
    assert playback.hasDrained(playback) is False
    playback.drainingToken = '123:0:1:22'
    assert playback.resume(playback) is True  # Resume the tail after HTTP EOF.
    playback.paused = False
    playback.ownership = lua.eval('{canStart=function() return false end}')
    assert playback.hasDrained(playback) is False
    playback.ownership = None
    playback._watchDrain(playback)  # A new activation fences late old events.
    old_hook(lua.globals().pb, lua.table(), 'STMu')
    assert playback.hasDrained(playback) is False
    lua.globals().pb.sendStatus(lua.globals().pb, lua.table(), 'STMu')
    assert playback.hasDrained(playback) is True
    lua.globals().player.playback = lua.table()
    assert playback.hasDrained(playback) is False


def test_drain_ack_is_atomic_and_rejects_cancelled_token(tmp_path):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
        package.loaded['loop.simple'] = {class=function() end}
        package.loaded['jive.ui.Timer'] = {}
    ''')
    # Redirect only the applet's filesystem root; execute its real I/O methods.
    source = (ROOT / 'applet/SpotifyService.lua').read_text().replace(
        '/etc/squeezeplay/userpath/SpotifyConnect', tmp_path.as_posix())
    service = lua.execute(source, 'drain_service')
    request = tmp_path / 'output.drain'
    request.write_text('current')
    assert service.acknowledgeDrain(service, 'old') is False
    assert not request.with_name('output.drain.ack').exists()
    assert service.acknowledgeDrain(service, 'current') is True
    assert request.with_name('output.drain.ack').read_text() == 'current'
    request.unlink()
    assert service.acknowledgeDrain(service, 'current') is False
