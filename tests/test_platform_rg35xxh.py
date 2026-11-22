"""RG35XX H platform registration (Phase 1).

Seeds the real SpotifyPlatform module into package.loaded so the
applet/service/meta requires resolve deterministically regardless of
pytest's working directory. Baby/fab4 assertions pin byte-identical
legacy behaviour; rg35xxh assertions pin the SqueezeboxGo overrides.
"""
from pathlib import Path

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).parents[1]
PLATFORM_SRC = (ROOT / "applet/SpotifyPlatform.lua").read_text()
SERVICE_SRC = (ROOT / "applet/SpotifyService.lua").read_text()
META_SRC = (ROOT / "applet/SpotifyConnectMeta.lua").read_text()

SYSTEM_ROOT = "/usr/share/jive/applets/SpotifyConnect"
SYSTEM_USER = "/etc/squeezeplay/userpath/SpotifyConnect"
RUNTIME = "/dev/spotify-connect-runtime"
GO_HOME = "/mnt/sd/config"
GO_ROOT = GO_HOME + "/userpath/applets/SpotifyConnect"
GO_USER = GO_HOME + "/userpath/SpotifyConnect"


def seed_platform(lua, machine=None, env=None, files=None):
    lua.execute("package.loaded['loop.simple'] = {class=function() end}")
    if machine is not None:
        lua.globals().test_machine = machine
        lua.execute("package.loaded['jive.System'] = {getMachine=function() return test_machine end}")
    lua.globals().test_env = lua.table_from(dict(env or {}))
    lua.execute("package.loaded['os'] = {execute=function() return 0 end, "
                "getenv=function(name) return test_env[name] end}")
    lua.globals().test_files = lua.table_from(dict(files or {}))
    lua.execute("package.loaded['io'] = {open=function(path) "
                "local value = test_files[path] "
                "if value == nil then return nil end "
                "return {read=function() return value end, close=function() end} end}")
    lua.globals()._platform_under_test = lua.execute(PLATFORM_SRC, "platform_test")
    lua.execute("package.loaded['applets.SpotifyConnect.SpotifyPlatform'] = _platform_under_test")
    return lua.globals().package.loaded['applets.SpotifyConnect.SpotifyPlatform']


def test_model_names_cover_all_machines():
    for machine, expected in [(None, "Squeezebox Radio"), ("baby", "Squeezebox Radio"),
                              ("fab4", "Squeezebox Touch"), ("rg35xxh", "SqueezeboxGo"),
                              ("squeezeplay", "Squeezebox Radio"), ("", "Squeezebox Radio")]:
        lua = LuaRuntime(unpack_returned_tuples=True)
        platform = seed_platform(lua, machine=machine)
        assert platform.modelName() == expected, machine
        assert platform.modelName(machine) == expected, machine
        assert platform.isRg35xxh() == (machine == "rg35xxh"), machine


def test_baby_fab4_paths_are_historical_even_with_go_env_set():
    for machine in (None, "baby", "fab4"):
        lua = LuaRuntime(unpack_returned_tuples=True)
        platform = seed_platform(lua, machine=machine, env={"SQUEEZEPLAY_HOME": GO_HOME, "HOME": "/root"},
                                 files={GO_ROOT + "/librespot": "binary"})
        assert platform.appletRoot() == SYSTEM_ROOT, machine
        assert platform.userDir() == SYSTEM_USER, machine
        assert platform.stateDir(None, RUNTIME) == SYSTEM_USER, machine


def test_rg35xxh_resolves_squeezeboxgo_paths():
    lua = LuaRuntime(unpack_returned_tuples=True)
    platform = seed_platform(lua, machine="rg35xxh", env={"SQUEEZEPLAY_HOME": GO_HOME},
                             files={GO_ROOT + "/librespot": "binary"})
    assert platform.appletRoot() == GO_ROOT
    assert platform.userDir() == GO_USER
    assert platform.stateDir(None, RUNTIME) == RUNTIME


def test_rg35xxh_root_falls_back_to_system_dir_when_unprobed():
    lua = LuaRuntime(unpack_returned_tuples=True)
    platform = seed_platform(lua, machine="rg35xxh", env={"SQUEEZEPLAY_HOME": GO_HOME})
    assert platform.appletRoot() == SYSTEM_ROOT


def test_rg35xxh_user_dir_falls_back_to_home_then_tmp():
    lua = LuaRuntime(unpack_returned_tuples=True)
    platform = seed_platform(lua, machine="rg35xxh", env={"HOME": "/root"})
    assert platform.userDir() == "/root/userpath/SpotifyConnect"
    lua = LuaRuntime(unpack_returned_tuples=True)
    platform = seed_platform(lua, machine="rg35xxh")
    assert platform.userDir() == "/tmp/SpotifyConnect"


def service_with_platform(machine, env, files, device_name):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.loaded['jive.utils.log'] = {logger=function() return {isDebug=function() return false end} end}")
    lua.execute("commands = {}")
    lua.execute("package.loaded['loop.simple'] = {class=function() end}")
    lua.execute("package.loaded['jive.ui.Timer'] = function() return {start=function() end, stop=function() end} end")
    lua.globals().test_machine = machine
    lua.execute("package.loaded['jive.System'] = {getMachine=function() return test_machine end}")
    lua.globals().test_env = lua.table_from(dict(env))
    lua.execute("package.loaded['os'] = {execute=function(command) table.insert(commands, command) "
                "if string.find(command, 'credentials.json') then return 1 end return 0 end, "
                "getenv=function(name) return test_env[name] end}")
    lua.globals().test_files = lua.table_from(dict(files))
    lua.execute("package.loaded['io'] = {open=function(path) "
                "local value = test_files[path] "
                "if value == nil then return nil end "
                "return {read=function() return value end, close=function() end} end}")
    lua.execute("package.loaded['json'] = {decode=function() return {} end}")
    lua.globals()._platform_under_test = lua.execute(PLATFORM_SRC, "platform_service_test")
    lua.execute("package.loaded['applets.SpotifyConnect.SpotifyPlatform'] = _platform_under_test")
    service = lua.execute(SERVICE_SRC, "service_platform_test")
    service.init(service, lua.table_from({"_settings": lua.table_from(
        {"serviceMode": "manual", "deviceName": device_name, "enabled": True})}))
    return lua, service


def test_service_start_uses_rg35xxh_paths():
    lua, service = service_with_platform("rg35xxh", {"SQUEEZEPLAY_HOME": GO_HOME},
                                         {GO_ROOT + "/librespot": "binary"}, "SqueezeboxGo")
    assert service.start(service, False) is True
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    assert any("cp '" + GO_ROOT + "'/$f '" + RUNTIME + "'/$f" in c for c in commands)
    assert any("mkdir -p '" + GO_USER + "'" in c for c in commands)
    assert any("mkdir -p '" + RUNTIME + "'" in c for c in commands)
    assert any("mkfifo '" + RUNTIME + "/audio.fifo'" in c for c in commands)
    assert any("--device '" + RUNTIME + "/audio.fifo'" in c for c in commands)
    assert any("--system-cache '" + GO_USER + "'" in c for c in commands)
    assert any("--name 'SqueezeboxGo'" in c for c in commands)
    assert not any(SYSTEM_USER in c for c in commands)


def test_service_baby_paths_unchanged_with_platform_loaded():
    lua, service = service_with_platform("baby", {"SQUEEZEPLAY_HOME": GO_HOME},
                                         {GO_ROOT + "/librespot": "binary"}, "Squeezebox Radio")
    assert service.start(service, False) is True
    commands = [lua.globals().commands[i] for i in range(1, len(lua.globals().commands) + 1)]
    assert any("cp '" + SYSTEM_ROOT + "'/$f '" + RUNTIME + "'/$f" in c for c in commands)
    assert any("--device '" + SYSTEM_USER + "/audio.fifo'" in c for c in commands)
    assert any("--system-cache '" + SYSTEM_USER + "'" in c for c in commands)
    assert not any(GO_HOME in c for c in commands)


def meta_with_platform(machine):
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
      package.loaded['os']={getenv=function() return nil end}
      package.loaded['io']={open=function() return nil end}
      jive={ui={EVENT_WINDOW_POP=1}}; jiveMain={}; appletManager={}
    ''')
    lua.globals().test_machine = machine
    lua.execute("package.loaded['jive.System'] = {getMachine=function() return test_machine end}")
    lua.globals()._platform_under_test = lua.execute(PLATFORM_SRC, "platform_meta_test")
    lua.execute("package.loaded['applets.SpotifyConnect.SpotifyPlatform'] = _platform_under_test")
    return lua.execute(META_SRC, "meta_platform_test")


def test_meta_default_device_name_matches_machine():
    assert meta_with_platform("rg35xxh").defaultSettings().deviceName == "SqueezeboxGo"
    assert meta_with_platform("fab4").defaultSettings().deviceName == "Squeezebox Touch"
    assert meta_with_platform("baby").defaultSettings().deviceName == "Squeezebox Radio"


def test_all_applet_lua_files_compile_under_lua51():
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = sorted((ROOT / "applet").glob("*.lua"))
    assert len(sources) >= 10
    for path in sources:
        lua.globals().chunk = path.read_text()
        assert lua.eval("loadstring(chunk) ~= nil"), path.name
