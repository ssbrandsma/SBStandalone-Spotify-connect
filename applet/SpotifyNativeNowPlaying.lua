local pcall, setmetatable = pcall, setmetatable
module(...)

local Navigation = {}; Navigation.__index = Navigation
local RETRY_DELAYS = { 50, 250, 500 }

function new(options)
    return setmetatable(options or {}, Navigation)
end

function Navigation:_cancel()
    local timer = self.timer; self.timer = nil
    if timer and timer.stop then timer:stop() end
end

function Navigation:_current(generation)
    return self.generation == generation and (not self.getGeneration or self.getGeneration() == generation)
end

function Navigation:_schedule(generation, attempt)
    if not self:_current(generation) or not RETRY_DELAYS[attempt] then return end
    self:_cancel()
    self.timer = self.timerFactory(RETRY_DELAYS[attempt], function()
        self.timer = nil; self:_open(generation, attempt)
    end, true)
    self.timer:start()
end

function Navigation:_open(generation, attempt)
    if not self:_current(generation) then return end
    local manager = self.appletManager
    if not manager or not manager:hasService("goNowPlaying")
        or not manager:callService("getCurrentPlayer") then
        self:_schedule(generation, attempt + 1); return
    end
    local okApplet, applet = pcall(function() return manager:getAppletInstance("NowPlaying") end)
    if okApplet and applet and applet.window and self.framework:isCurrentWindow(applet.window) then self.presented=true;return end
    local ok, result = pcall(function() return manager:callService("goNowPlaying", self.transition) end)
    if not ok or result == false then self:_schedule(generation, attempt + 1) else self.presented=true end
end

function Navigation:request(generation)
    if not generation then return false end
    self.generation = generation
    -- Track epochs change within one Connect session. Once opened, metadata
    -- must not pull the user back from the original playlist or another menu.
    if self.presented then self:_cancel();return true end
    self:_schedule(generation, 1); return true
end

function Navigation:cancel() self.generation = nil;self.presented=false;self:_cancel() end
Navigation.shutdown = Navigation.cancel
return _M
