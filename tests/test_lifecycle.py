from pathlib import Path
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).parents[1]


def service_runtime(mode="manual", machine=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(r'''
      commands, timers = {}, {}
      processes = {supervisor=false, bridge=false, child=false}
      package.loaded["jive.utils.log"] = {logger=function() return {isDebug=function() return debugLogging == true end} end}
      package.loaded['loop.simple'] = {class=function() end}
      package.loaded['jive.ui.Timer'] = function(ms, callback, once)
        local timer={ms=ms,callback=callback,once=once,started=false,stopped=false,
          start=function(self) self.started=true end, stop=function(self) self.stopped=true end}
        table.insert(timers,timer); return timer
      end
      package.loaded['io'] = {open=function(path)
        local root='/etc/squeezeplay/userpath/SpotifyConnect/'
        local values={
          [root..'supervisor.pid']=processes.supervisor and '101' or nil,
          [root..'bridge.pid']=processes.bridge and '102' or nil,
          [root..'librespot.pid']=processes.child and '103' or nil,
          ['/proc/101/cmdline']=processes.supervisor and '/dev/spotify-connect-runtime/spotify-supervisor\0--status\0x\0' or nil,
          ['/proc/102/cmdline']=processes.bridge and '/dev/spotify-connect-runtime/ogg-http-bridge\0' or nil,
          ['/proc/103/cmdline']=processes.child and '/dev/spotify-connect-runtime/librespot\0' or nil,
        }
        local value=values[path]; if not value then return nil end
        return {read=function() return value end,close=function() end}
      end}
      package.loaded['json'] = {decode=function() return {} end}
      package.loaded['os'] = {execute=function(command)
        table.insert(commands,command)
        if string.find(command, "test %-s '/etc/squeezeplay/userpath/SpotifyConnect/credentials.json'") then return 0 end
        if string.find(command, 'kill %-TERM') then
          if string.find(command, 'spotify%-supervisor') then processes.supervisor=false; processes.child=false end
          if string.find(command, 'ogg%-http%-bridge') then processes.bridge=false end
          if string.find(command, '/librespot') then processes.child=false end
          return 0
        end
        if string.find(command, 'exec.*/ogg%-http%-bridge') then processes.bridge=true; return 0 end
        if string.find(command, 'exec.*/spotify%-supervisor') then processes.supervisor=true; processes.child=true; return 0 end
        return 0
      end}
    ''')
    if machine:
        lua.globals().test_machine = machine
        lua.execute("package.loaded['jive.System'] = {getMachine=function() return test_machine end}")
    service = lua.execute((ROOT / "applet/SpotifyService.lua").read_text(), "lifecycle_test")
    settings = lua.table_from({"serviceMode": mode, "deviceName": "Test Radio", "enabled": True})
    applet = lua.table_from({"_settings": settings})
    service.init(service, applet)
    return lua, service, settings


def test_process_validation_reads_proc_without_shell_and_rejects_reused_pid():
    lua, service, _ = service_runtime()
    lua.execute(r'''
      files={}
      package.loaded['io'].open=function(path)
        local value=files[path]; if not value then return nil end
        return {read=function() return value end,close=function() end}
      end
    ''')
    files = lua.globals().files
    pidfile = '/etc/squeezeplay/userpath/SpotifyConnect/supervisor.pid'
    cmdfile = '/proc/101/cmdline'
    expected = '/dev/spotify-connect-runtime/spotify-supervisor'
    assert service.isRunning(service) is False
    files[pidfile] = '101\n'
    assert service.isRunning(service) is False
    files[cmdfile] = expected + '\0--status\0file\0'
    for _ in range(100):
        assert service.isRunning(service) is True
    files[cmdfile] = '/bin/sh\0' + expected + '\0'
    assert service.isRunning(service) is False
    files[cmdfile] = expected + '-other\0'
    assert service.isRunning(service) is False
    for invalid in ['0', '-101', '101;echo invalid', '../101']:
        files[pidfile] = invalid
        assert service.isRunning(service) is False
    assert len(lua.globals().commands) == 0


def test_manual_start_stop_are_idempotent_and_owned():
    lua, service, _ = service_runtime()
    assert service.getStatus(service) == "stopped"
    assert service.start(service, False) is True
    assert service.getStatus(service) == "running"
    command_count = len(lua.globals().commands)
    assert service.start(service, False) is True
    assert len(lua.globals().commands) == command_count  # ownership checks must not spawn shells
    assert service.stop(service, False) is True
    assert service.getStatus(service) == "stopped"
    assert service.stop(service, False) is True
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    assert any("/proc/$p/cmdline" in c and "spotify-supervisor" in c and "kill -TERM" in c for c in commands)
    assert not any("pidof" in c or "killall" in c or "pkill" in c for c in commands)


def test_native_logs_use_syslog_and_debug_category_at_each_start():
    lua, service, _ = service_runtime()
    for debug in (False, True, False):
        lua.globals().debugLogging = debug
        lua.execute('commands = {}')
        assert service.start(service, False) is True
        commands = list(lua.globals().commands.values())
        assert any('command -v logger' in c for c in commands)
        assert any('exec logger -t SpotifyConnect -p user.info' in c for c in commands)
        launches = [c for c in commands if 'exec ' in c and ('--stream-marker' in c or '--child-pid' in c)]
        assert len(launches) == 2
        assert all(">'/dev/spotify-connect-runtime/syslog.fifo'" in c for c in launches)
        engine = next(c for c in launches if '--child-pid' in c)
        assert ('librespot=debug' if debug else 'librespot=info') in engine
        assert 'RUST_LOG_STYLE=never' in engine
        assert not any('engine.log' in c for c in commands)
        assert service.stop(service, False) is True


def test_logging_setup_failure_does_not_start_native_services():
    lua, service, _ = service_runtime()
    lua.execute('''
        local execute = package.loaded.os.execute
        package.loaded.os.execute = function(command)
            if string.find(command, 'command %-v logger') then return 1 end
            return execute(command)
        end
    ''')
    assert service.start(service, False) is False
    assert service.getLastError(service) == 'Could not prepare syslog logging'
    assert lua.globals().processes.bridge is False
    assert lua.globals().processes.supervisor is False


def test_disabled_rejects_start_and_preserves_credentials():
    lua, service, _ = service_runtime("disabled")
    assert service.start(service, True) is False
    assert service.getMode(service) == "disabled"
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    assert not any("rm -f '/etc/squeezeplay/userpath/SpotifyConnect/credentials.json'" in c for c in commands)


def test_always_on_requires_mode_change_before_stop():
    lua, service, settings = service_runtime("always_on")
    assert service.start(service, False) is True
    assert service.stop(service, False) is False
    assert service.isRunning(service) is True
    assert service.setMode(service, "manual") is True
    assert settings.serviceMode == "manual" and settings.serviceModeExplicit is True
    assert service.stop(service, False) is True


def test_mode_transitions_have_deterministic_desired_state():
    _, service, settings = service_runtime("manual")
    assert service.setMode(service, "always_on") is True
    assert service.isRunning(service) is True
    assert service.setMode(service, "disabled") is True
    assert service.isRunning(service) is False
    assert settings.serviceMode == "disabled"
    assert service.setMode(service, "manual") is True
    assert service.isRunning(service) is False


def meta_module():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(r'''
      package.loaded['loop.simple']={class=function() end}
      package.loaded['jive.AppletMeta']={}
      package.loaded['jive.ui.Window']={}
      package.loaded['jive.ui.SimpleMenu']={}
      package.loaded['jive.ui.Icon']={}
      package.loaded['jive.ui.Label']={}
      package.loaded['jive.ui.Surface']={}
      package.loaded['jive.ui.Timer']={}
      package.loaded['applets.SpotifyConnect.qrencode']={}
      package.loaded['applets.SpotifyConnect.SpotifyConnectState']={}
      jive={ui={EVENT_WINDOW_POP=1}}; jiveMain={}; appletManager={}
    ''')
    return lua, lua.execute((ROOT / "applet/SpotifyConnectMeta.lua").read_text(), "meta_lifecycle_test")


def test_fresh_install_defaults_to_manual():
    _, meta = meta_module(); settings = meta.defaultSettings()
    assert settings.serviceMode == "manual"
    assert settings.serviceModeExplicit is True
    assert settings.enabled is False


def test_legacy_enabled_install_migrates_to_always_on():
    lua, meta = meta_module()
    enabled = meta.upgradeSettings(meta, lua.table_from({"enabled": True, "deviceName": "Radio"}))
    disabled = meta.upgradeSettings(meta, lua.table_from({"enabled": False, "deviceName": "Radio"}))
    assert enabled.serviceMode == "always_on" and enabled.serviceModeExplicit is False
    assert disabled.serviceMode == "manual" and disabled.serviceModeExplicit is False


def test_explicit_mode_survives_upgrade():
    lua, meta = meta_module()
    settings = meta.upgradeSettings(meta, lua.table_from({"enabled": True, "serviceMode": "disabled",
                                                           "serviceModeExplicit": True}))
    assert settings.serviceMode == "disabled" and settings.serviceModeExplicit is True


def test_supervisor_has_backoff_child_pid_and_signal_shutdown():
    source = (ROOT / "native/supervisor/main.rs").read_text()
    assert "--child-pid" in source
    assert "let delays = [1u64, 2, 5, 10, 30]" in source
    assert "STOP.load" in source and "SIGTERM" in source
    assert "stop_child(&mut child)" in source


def test_bridge_uses_lower_frequency_idle_waits():
    source = (ROOT / "native/bridge/bridge.rs").read_text()
    assert "last_marker_poll.elapsed() >= Duration::from_millis(250)" in source
    assert "rx.recv_timeout(Duration::from_millis(250))" in source


def test_default_spotify_name_matches_hardware_and_preserves_custom_names():
    for machine, expected in [("baby", "Squeezebox Radio"), ("fab4", "Squeezebox Touch")]:
        lua, service, settings = service_runtime(machine=machine)
        settings.deviceName = "Squeezebox Radio"  # Legacy default also migrates on Touch.
        assert service.start(service, False)
        commands = list(lua.globals().commands.values())
        assert any("--name '" + expected + "'" in command for command in commands)
        service.stop(service, False)
        settings.deviceName = "Kitchen"
        assert service.start(service, False)
        assert any("--name 'Kitchen'" in command for command in lua.globals().commands.values())
