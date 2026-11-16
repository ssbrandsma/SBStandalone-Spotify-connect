-- SpotifyConnect platform description.
--
-- Centralises machine-specific behaviour so common code stays
-- platform-independent: baby (Squeezebox Radio) and fab4 (Squeezebox Touch)
-- resolve to the historical values, while rg35xxh (Anbernic RG35XX H running
-- SqueezeboxGo) overrides only the model name and filesystem paths.
local pcall, type = pcall, type
local okSystem, System = pcall(require, "jive.System")
local okOs, os = pcall(require, "os")
if not okOs then os = nil end
local okIo, io = pcall(require, "io")
if not okIo then io = nil end

local Platform = {}

local MODELS = { fab4 = "Squeezebox Touch", rg35xxh = "SqueezeboxGo" }
local DEFAULT_MODEL = "Squeezebox Radio"

local SYSTEM_ROOT = "/usr/share/jive/applets/SpotifyConnect"
local SYSTEM_USER = "/etc/squeezeplay/userpath/SpotifyConnect"

function Platform.machine()
    if not okSystem then return nil end
    local ok, machine = pcall(function() return System:getMachine() end)
    if not ok or type(machine) ~= "string" or machine == "" then return nil end
    return machine
end

function Platform.modelName(machine)
    if machine == nil then machine = Platform.machine() end
    return MODELS[machine] or DEFAULT_MODEL
end

function Platform.isRg35xxh(machine)
    if machine == nil then machine = Platform.machine() end
    return machine == "rg35xxh"
end

local function getenv(name)
    if os and os.getenv then
        local ok, value = pcall(os.getenv, name)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function fileExists(path)
    if not io or not io.open then return false end
    local file = io.open(path, "r")
    if not file then return false end
    file:close()
    return true
end

-- Install location of this applet (native binaries ship at its root).
-- SqueezeboxGo installs user applets under $SQUEEZEPLAY_HOME/userpath/applets.
function Platform.appletRoot(machine)
    if Platform.isRg35xxh(machine) then
        local home = getenv("SQUEEZEPLAY_HOME")
        if home then
            local candidate = home .. "/userpath/applets/SpotifyConnect"
            if fileExists(candidate .. "/librespot") then return candidate end
        end
    end
    return SYSTEM_ROOT
end

-- Persistent per-user state (credentials, cached identity). Everything else
-- must be volatile (see stateDir) to spare the SD card on rg35xxh.
function Platform.userDir(machine)
    if Platform.isRg35xxh(machine) then
        local home = getenv("SQUEEZEPLAY_HOME") or getenv("HOME")
        if home then return home .. "/userpath/SpotifyConnect" end
        return "/tmp/SpotifyConnect"
    end
    return SYSTEM_USER
end

-- Volatile runtime state (FIFO, pidfiles, status, metadata, markers, log).
-- Baby/fab4 keep the historical single-directory layout; rg35xxh reuses the
-- RAM-backed runtime dir so only credentials touch persistent storage.
function Platform.stateDir(machine, runtime)
    if Platform.isRg35xxh(machine) then return runtime end
    return Platform.userDir(machine)
end

return Platform
