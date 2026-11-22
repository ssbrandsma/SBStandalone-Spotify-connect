local ipairs, type = ipairs, type
local oo = require("loop.simple")
local Timer = require("jive.ui.Timer")
local Log = require("jive.utils.log")
local os, io = require("os"), require("io")
local pcall, type, tonumber, tostring = pcall, type, tonumber, tostring
local okJson, json = pcall(require, "json")
if not okJson then json = nil end
local okPlatform, Platform = pcall(require, "applets.SpotifyConnect.SpotifyPlatform")
if not okPlatform then Platform = nil end
local machine = Platform and Platform.machine()
local modelName = "Squeezebox Radio"
if Platform then
    modelName = Platform.modelName(machine)
else
    local okSystem, System = pcall(require, "jive.System")
    if okSystem then
        local okMachine, detected = pcall(function() return System:getMachine() end)
        if okMachine and detected == "fab4" then modelName = "Squeezebox Touch" end
    end
end
module(...)
oo.class(_M)

local ROOT = "/usr/share/jive/applets/SpotifyConnect"
local RUNTIME = "/dev/spotify-connect-runtime"
local USER = "/etc/squeezeplay/userpath/SpotifyConnect"
if Platform then
    ROOT = Platform.appletRoot(machine)
    USER = Platform.userDir(machine)
end
local STATE = USER
if Platform then STATE = Platform.stateDir(machine, RUNTIME) end
local FIFO, PID, BPID = STATE .. "/audio.fifo", STATE .. "/supervisor.pid", STATE .. "/bridge.pid"
local CPID, STATUS = STATE .. "/librespot.pid", STATE .. "/status.json"
local METADATA, STREAM_MARKER = STATE .. "/metadata.json", STATE .. "/stream.ready"
local LOG_PIPE = RUNTIME .. "/syslog.fifo"
local METADATA_STATE, METADATA_VOLUME = METADATA .. ".state", METADATA .. ".volume"
local METADATA_LOADING, METADATA_POSITION = METADATA .. ".loading", METADATA .. ".position"
local DRAIN = STATE .. "/output.drain"
local MODES = { disabled=true, manual=true, always_on=true }
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function readSmall(path)
    local f=io.open(path,"r"); if not f then return nil end
    local value=f:read("*a"); f:close(); if not value then return nil end
    return (value:gsub("%s+$",""))
end
local function owned(pidfile, executable)
    -- Called by the 250 ms UI watcher. Forking cat/tr/grep here can take
    -- longer than that interval on a Radio and starve HTTP/display tasks.
    local pid = readSmall(pidfile)
    if not pid or not pid:match("^[1-9]%d*$") then return false end
    local cmdline = readSmall("/proc/" .. pid .. "/cmdline")
    if not cmdline then return false end
    local command = cmdline:match("^([^%z]+)%z")
    return command == RUNTIME .. "/" .. executable
end
local function signalOwned(pidfile, executable, signal)
    os.execute("if test -s " .. q(pidfile) .. "; then p=`cat " .. q(pidfile) .. "`; " ..
        "if test -r /proc/$p/cmdline && tr '\\000' ' ' < /proc/$p/cmdline | grep -F -q " .. q(RUNTIME .. "/" .. executable) ..
        "; then kill -" .. signal .. " $p 2>/dev/null; fi; fi")
end
local function cleanupRuntime()
    os.execute("rm -rf " .. q(RUNTIME) .. "; rm -f " .. q(PID) .. " " .. q(BPID) .. " " .. q(CPID) .. " " .. q(FIFO) ..
        " " .. q(STATUS) .. " " .. q(METADATA) .. " " .. q(METADATA_STATE) .. " " .. q(METADATA_VOLUME) ..
        " " .. q(METADATA_LOADING) .. " " .. q(METADATA_POSITION) .. " " .. q(STREAM_MARKER) ..
        " " .. q(STREAM_MARKER .. ".eos") .. " " .. q(DRAIN) .. " " .. q(DRAIN .. ".ack"))
end
local function reapOrphans()
    -- SqueezeboxGo exits without rebooting: a crashed session can leave a
    -- supervised receiver behind in the RAM runtime dir. Reclaim it at boot
    -- so this Jive instance never adopts a stale session. TERM, grace, KILL.
    -- The scan skips its own shell: its cmdline contains this very pattern.
    local sweep = [[for d in /proc/[0-9]*; do p=${d#/proc/}; case $p in ''|*[!0-9]*) continue;; esac; if [ "$p" != "$$" ] && tr '\000' ' ' < $d/cmdline 2>/dev/null | grep -F -q %s; then kill -%s $p 2>/dev/null && reaped=1; fi; done]]
    local quoted = q(RUNTIME .. "/")
    os.execute("reaped=0; " .. sweep:format(quoted, "TERM") ..
        " if [ $reaped -eq 1 ]; then sleep 1; " .. sweep:format(quoted, "KILL") .. "; fi")
    cleanupRuntime()
end
local function prepareRuntime()
    local files="librespot ogg-http-bridge spotify-metadata spotify-metadata-event spotify-supervisor"
    local command="rm -rf " .. q(RUNTIME) .. "; mkdir -p " .. q(RUNTIME) ..
        " && for f in " .. files .. "; do test -x " .. q(ROOT) .. "/$f && cp " .. q(ROOT) .. "/$f " .. q(RUNTIME) .. "/$f || exit 1; done" ..
        " && chmod 755 " .. q(RUNTIME) .. "/*"
    return os.execute(command)==0
end
local function defaultName()
    local f=io.open("/sys/class/net/eth1/address","r") or io.open("/sys/class/net/wlan0/address","r") or io.open("/sys/class/net/eth0/address","r")
    if not f then return modelName end
    local mac=f:read("*a"); f:close(); mac=mac:gsub("%s","")
    return #mac>=2 and ((modelName .. "-") .. mac:sub(-2):upper()) or modelName
end

function init(self, applet)
    self.applet=applet; self.desiredRunning=false; self.lifecycleState="stopped"; self.lastError=nil; self.operation=0
    if Platform and Platform.isRg35xxh(machine) then reapOrphans() end
end
function getMode(self)
    local mode=self.applet and self.applet._settings and self.applet._settings.serviceMode
    return MODES[mode] and mode or "manual"
end
function setMode(self, mode)
    if not MODES[mode] then self.lastError="Invalid operating mode"; return false end
    local settings=self.applet._settings or {}; self.applet._settings=settings
    settings.serviceMode, settings.serviceModeExplicit = mode, true
    if self.applet.storeSettings then pcall(function() self.applet:storeSettings() end) end
    if mode=="disabled" then self:stop(true)
    elseif mode=="always_on" then self:start(false) end
    return true
end
function credentialsExist(self) return os.execute("test -s " .. q(USER .. "/credentials.json") .. " 2>/dev/null")==0 end
function isRunning(self) return owned(PID,"spotify-supervisor") end
function _bridgeRunning(self) return owned(BPID,"ogg-http-bridge") end
function getStatus(self)
    if self.lifecycleState=="starting" or self.lifecycleState=="stopping" then return self.lifecycleState end
    if self:isRunning() and self:_bridgeRunning() then
        local raw=readSmall(STATUS) or ""; local state=raw:match('"state":"([^"]+)"')
        if state=="error" then return "error" end
        if state=="starting" or state=="recovering" then return state end
        return "running"
    end
    return self.lastError and "error" or "stopped"
end
function getLastError(self) return self.lastError end
function status(self)
    local value=self:getStatus()
    if value=="stopped" then return "not_connected" end
    if value=="running" then
        local raw=readSmall(STATUS) or ""; return raw:match('"state":"([^"]+)"') or "starting"
    end
    return value
end
function statusData(self)
    local d={state=self:status()}; local s=readSmall(STATUS)
    if s then d.state=s:match('"state":"([^"]+)"') or d.state; d.url,d.message=s:match('"url":"([^"]+)"'),s:match('"message":"([^"]+)"') end
    local m=io.open(METADATA,"r")
    if m then
        local ms=m:read("*a"); m:close(); local ok,parsed=pcall(function() return json.decode(ms) end)
        if ok and type(parsed)=="table" then d.playback_state,d.track_id=parsed.playback_state,parsed.track_id; d.title,d.artist,d.album=parsed.title,parsed.artist,parsed.album; d.duration_ms,d.artwork_url=parsed.duration_ms,parsed.artwork_url
        else d.playback_state=ms:match('"playback_state":"([^"]*)"'); d.track_id=ms:match('"track_id":"([^"]*)"'); d.title=ms:match('"title":"([^"]*)"'); d.artist=ms:match('"artist":"([^"]*)"'); d.album=ms:match('"album":"([^"]*)"'); d.duration_ms=ms:match('"duration_ms":"([^"]*)"'); d.artwork_url=ms:match('"artwork_url":"([^"]*)"') end
    end
    d.playback_state=readSmall(METADATA_STATE) or d.playback_state; d.volume=tonumber(readSmall(METADATA_VOLUME))
    local value=readSmall(METADATA_POSITION); if value then local id,pos=value:match("([^\n]*)\n(%d+)"); if id==d.track_id then d.position_ms=tonumber(pos) end end
    return d
end
function eventData(self) return {loading=readSmall(METADATA_LOADING),stream=readSmall(STREAM_MARKER),playback_state=readSmall(METADATA_STATE),volume=tonumber(readSmall(METADATA_VOLUME)),position=readSmall(METADATA_POSITION),metadata=readSmall(METADATA),drain=readSmall(DRAIN),eos=readSmall(STREAM_MARKER .. ".eos")} end

function acknowledgeDrain(self, token)
    if not token or readSmall(DRAIN) ~= token then return false end
    local tmp = DRAIN .. ".ack.tmp"
    local f = io.open(tmp, "w"); if not f then return false end
    local written = f:write(token); f:close()
    if not written then return false end
    return os.rename(tmp, DRAIN .. ".ack") and true or false
end

function _verifyStart(self, operation, attempts)
    if operation~=self.operation or not self.desiredRunning then return end
    if self:isRunning() and self:_bridgeRunning() then self.lifecycleState="running"; self.lastError=nil; return end
    if attempts<=0 then self.lastError="Spotify services failed to start"; self.lifecycleState="error"; self:stop(true); return end
    self.startTimer=Timer(250,function() self.startTimer=nil; self:_verifyStart(operation,attempts-1) end,true); self.startTimer:start()
end
function _startHealthMonitor(self)
    if self.healthTimer then return end
    self.healthTimer=Timer(10000,function()
        if self.desiredRunning and self:getMode()~="disabled" and self.lifecycleState~="starting" and self.lifecycleState~="stopping"
            and (not self:isRunning() or not self:_bridgeRunning()) then
            self.lastError="Spotify service stopped unexpectedly; recovering"
            self:start(false)
        end
    end); self.healthTimer:start()
end
function start(self, pairing)
    if self.ownershipFenced then return false end
    if self:getMode()=="disabled" then self.lastError="Spotify Connect is disabled"; self.lifecycleState="stopped"; return false end
    self.desiredRunning=true; self:_startHealthMonitor(); self.operation=self.operation+1; local operation=self.operation
    if self:isRunning() and self:_bridgeRunning() then self.lifecycleState="running"; self.lastError=nil; return true end
    if self.lifecycleState=="stopping" then return true end
    if self:isRunning() or self:_bridgeRunning() or owned(CPID,"librespot") then
        self.lifecycleState="stopping"; signalOwned(PID,"spotify-supervisor","TERM"); signalOwned(CPID,"librespot","TERM"); signalOwned(BPID,"ogg-http-bridge","TERM"); self:_finishStop(operation,12); return true
    end
    if not prepareRuntime() then self.lastError="Required runtime files are unavailable"; self.lifecycleState="error"; return false end
    local stateInit = STATE ~= USER and ("; mkdir -p " .. q(STATE) .. "; chmod 700 " .. q(STATE)) or ""
    os.execute("mkdir -p " .. q(USER) .. "; chmod 700 " .. q(USER) .. stateInit .. "; rm -f " .. q(STATUS) .. " " .. q(METADATA) .. " " .. q(METADATA_STATE) .. " " .. q(METADATA_VOLUME) .. " " .. q(METADATA_LOADING) .. " " .. q(METADATA_POSITION) .. " " .. q(STREAM_MARKER) .. " " .. q(STREAM_MARKER .. ".eos") .. " " .. q(DRAIN) .. " " .. q(DRAIN .. ".ack") .. " " .. q(PID) .. " " .. q(BPID) .. " " .. q(CPID))
    if os.execute("test -p " .. q(FIFO) .. " || mkfifo " .. q(FIFO) .. "; chmod 600 " .. q(FIFO))~=0 then self.lastError="Could not create audio FIFO"; self.lifecycleState="error"; return false end
    -- Keep stdout/stderr out of persistent userpath. logger drains this RAM
    -- FIFO and exits at EOF once the bridge, supervisor and engine stop.
    -- Redirection preserves the exec'd process PIDs used by ownership checks.
    if os.execute("command -v logger >/dev/null 2>&1 && mkfifo " .. q(LOG_PIPE) .. " && chmod 600 " .. q(LOG_PIPE))~=0 then
        self.lastError="Could not prepare syslog logging"; self.lifecycleState="error"; return false
    end
    os.execute("( exec logger -t SpotifyConnect -p user.info <" .. q(LOG_PIPE) .. " >/dev/null 2>&1 ) &")
    os.execute("( exec 3<>" .. q(FIFO) .. "; exec " .. q(RUNTIME .. "/ogg-http-bridge") .. " 17880 --stream-marker " .. q(STREAM_MARKER) .. " --loading-marker " .. q(METADATA_LOADING) .. " <" .. q(FIFO) .. " >" .. q(LOG_PIPE) .. " 2>&1 ) & echo $! >" .. q(BPID))
    local auth=(pairing or not self:credentialsExist()) and " --enable-device-auth" or ""; local settings=self.applet._settings or {}; local name=settings.deviceName or modelName; if name==modelName or name=="Squeezebox Radio" then name=defaultName() end
    local metadataCommand=RUNTIME .. "/spotify-metadata " .. METADATA
    -- Match the Jive category at service start; never restart active playback
    -- just because the user changes a logging setting.
    local logger=Log.logger("SpotifyConnect")
    local rustLog=(logger:isDebug() and "librespot=debug" or "librespot=info") .. ",libmdns=info"
    local cmd="( export RUST_LOG=" .. q(rustLog) .. " RUST_LOG_STYLE=never SBSPOTIFY_DRAIN_PATH=" .. q(DRAIN) .. "; exec " .. q(RUNTIME .. "/spotify-supervisor") .. " --status " .. q(STATUS) .. " --child-pid " .. q(CPID) .. " -- " .. q(RUNTIME .. "/librespot") .. " --name " .. q(name) .. " --onevent " .. q(metadataCommand) .. " --backend pipe --device " .. q(FIFO) .. " --passthrough --disable-audio-cache --disable-discovery --system-cache " .. q(USER) .. " --bitrate 96" .. auth .. " >" .. q(LOG_PIPE) .. " 2>&1 ) & echo $! >" .. q(PID)
    if os.execute(cmd)~=0 then self.lastError="Could not launch Spotify supervisor"; self.lifecycleState="error"; self:stop(true); return false end
    self.lifecycleState="starting"; self.lastError=nil; self:_verifyStart(operation,20); return true
end
function _finishStop(self, operation, attempts)
    if operation~=self.operation then return end
    if not self:isRunning() and not self:_bridgeRunning() and not owned(CPID,"librespot") then
        cleanupRuntime(); self.lifecycleState="stopped"
        if self.desiredRunning then self:start(false) end
        return
    end
    if attempts<=0 then signalOwned(PID,"spotify-supervisor","KILL"); signalOwned(CPID,"librespot","KILL"); signalOwned(BPID,"ogg-http-bridge","KILL"); cleanupRuntime(); self.lifecycleState="stopped"; if self.desiredRunning then self:start(false) end; return end
    self.stopTimer=Timer(250,function() self.stopTimer=nil; self:_finishStop(operation,attempts-1) end,true); self.stopTimer:start()
end
function stop(self, force)
    if self:getMode()=="always_on" and not force then self.lastError="Change Operating Mode to Manual before stopping"; return false end
    self.desiredRunning=false; self.operation=self.operation+1; local operation=self.operation
    if self.startTimer then self.startTimer:stop(); self.startTimer=nil end
    if not self:isRunning() and not self:_bridgeRunning() and not owned(CPID,"librespot") then cleanupRuntime(); self.lifecycleState="stopped"; return true end
    self.lifecycleState="stopping"; if self.applet and self.applet.playback then self.applet.playback:stop() end; if self.applet and self.applet.standaloneNowPlaying then self.applet.standaloneNowPlaying:release() end
    signalOwned(PID,"spotify-supervisor","TERM"); signalOwned(CPID,"librespot","TERM"); signalOwned(BPID,"ogg-http-bridge","TERM"); self:_finishStop(operation,12); return true
end
function restart(self)
    if self.ownershipFenced then return false end
    if self:getMode()=="disabled" then self.lastError="Spotify Connect is disabled"; return false end
    local result=self:stop(true); self.desiredRunning=true
    if self.lifecycleState=="stopped" then return self:start(false) end
    return result
end
function disconnect(self)
    self:stop(true); os.execute("rm -f " .. q(USER .. "/credentials.json") .. " " .. q(USER .. "/volume")); if self.applet and self.applet._settings then self.applet._settings.enabled=false end
end
function shutdown(self) if self.healthTimer then self.healthTimer:stop(); self.healthTimer=nil end; self:stop(true) end

-- Requires a qualified asynchronous native supervisor/bridge driver. Existing
-- shell stop helpers are deliberately not called on the Jive ownership path.
function ownershipFence(self)
    self.ownershipFenced=true;self.operation=self.operation+1
    self.desiredRunning=false
    for _,key in ipairs({"healthTimer","startTimer","stopTimer"}) do
        if self[key] then self[key]:stop();self[key]=nil end
    end
    return true
end
function ownershipStop(self,done)
    local operation=self.operation
    if not self.ownershipDriver then done(false);return end
    self.ownershipDriver:stop(operation,function(result)
        if operation~=self.operation then return end
        done(type(result)=="table" and result.operation==operation and result.producer_stopped==true and result.restart_fenced==true)
    end)
end
function ownershipGranted(self) self.ownershipFenced=false end

return _M
