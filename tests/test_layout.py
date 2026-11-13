from pathlib import Path

ROOT = Path(__file__).parents[1]

def test_required_sources_exist():
    for name in ("SpotifyConnectMeta.lua", "SpotifyConnectApplet.lua", "SpotifyService.lua", "SpotifyPlayback.lua",
                 "SpotifyStandaloneNowPlaying.lua", "SpotifyNativeNowPlaying.lua", "SpotifyUrlTransport.lua", "strings.txt"):
        assert (ROOT / "applet" / name).is_file()

def test_custom_now_playing_is_not_referenced():
    assert "SpotifyNowPlaying" not in (ROOT / "applet/SpotifyConnectApplet.lua").read_text()
    assert 'text = "Now Playing"' not in (ROOT / "applet/SpotifyConnectMeta.lua").read_text()

def test_meta_localizes_globals_used_after_module_environment_switch():
    source = (ROOT / "applet" / "SpotifyConnectMeta.lua").read_text()
    assert "local pcall, ipairs = pcall, ipairs" in source

def test_no_research_tree_is_embedded():
    assert not (ROOT / "evidence").exists()
    assert not (ROOT / "phase1").exists()

def test_bridge_uses_blocking_accepted_socket():
    bridge = (ROOT / "native" / "bridge" / "bridge.rs").read_text()
    accept_http = bridge.split("fn accept_http", 1)[1].split("fn write_marker", 1)[0]
    assert "s.set_nonblocking(false)?;" in accept_http
    assert "s.set_read_timeout(Some(Duration::from_secs(HTTP_REQUEST_TIMEOUT_SECS)))?;" in accept_http
    assert "const HTTP_REQUEST_TIMEOUT_SECS: u64 = 15;" in bridge

def test_streaming_player_coalesces_duplicate_loads():
    player = (ROOT / "native" / "librespot" / "playback" / "src" / "player.rs").read_text()
    assert "Coalescing duplicate load for streaming-only track" in player
    assert "*current_play_request_id = play_request_id;" in player
