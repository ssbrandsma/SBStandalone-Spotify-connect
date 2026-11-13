local oo = require("loop.simple")
local AppletMeta = require("jive.AppletMeta")
local Window = require("jive.ui.Window")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Icon = require("jive.ui.Icon")
local Label = require("jive.ui.Label")
local Surface = require("jive.ui.Surface")
local qrencode = require("applets.SpotifyConnect.qrencode")
local pcall, ipairs = pcall, ipairs
local Timer = require("jive.ui.Timer")
local jiveMain = jiveMain
local appletManager = appletManager
local EVENT_WINDOW_POP = jive.ui.EVENT_WINDOW_POP
local state = require("applets.SpotifyConnect.SpotifyConnectState")
local okSystem, System = pcall(require, "jive.System")
local modelName = "Squeezebox Radio"
if okSystem then
    local okMachine, machine = pcall(function() return System:getMachine() end)
    if okMachine and machine == "fab4" then modelName = "Squeezebox Touch" end
end
module(...)
oo.class(_M, AppletMeta)
function jiveVersion() return 1, 1 end

local function makeQrSurface(value)
    local called, success, matrix = pcall(qrencode.qrcode, value)
    if not called or not success or not matrix then return nil end
    local modules, quiet, scale = #matrix, 4, 3
    local side = (modules + quiet * 2) * scale
    local surface = Surface:newRGB(side, side)
    surface:filledRectangle(0, 0, side - 1, side - 1, 0xffffffff)
    for x = 1, modules do
        for y = 1, modules do
            if matrix[x][y] and matrix[x][y] > 0 then
                local x0, y0 = (x - 1 + quiet) * scale, (y - 1 + quiet) * scale
                surface:filledRectangle(x0, y0, x0 + scale - 1, y0 + scale - 1, 0x000000ff)
            end
        end
    end
    return surface
end

local function showPairing(self, applet)
    local window = Window("text_list", "Connect Spotify")
    local label = Label("text", "Starting...\n")
    local qr = Icon("icon")
    local qrUrl
    window:addWidget(qr); window:addWidget(label); window:show()
    local timer
    timer = Timer(1000, function()
        local d = applet.service:statusData()
        if d.state == "pairing" and d.url and d.url ~= qrUrl then
            qrUrl = d.url
            local surface = makeQrSurface(d.url)
            if surface then qr:setValue(surface) end
        end
        label:setValue(d.state == "pairing" and ("Scan QR or open this address:\n" .. (d.url or "waiting") .. "\n\nWaiting for approval...") or (d.state == "connected" and ("Connected\n\nSelect " .. modelName .. " in Spotify.") or (d.state == "error" and ("Connection failed\n\n" .. (d.message or "Unknown error") .. "\n\nPress Back and try Connect again.") or "Waiting for Spotify...")))
        if d.state == "connected" then
            local settings = applet._settings; settings.enabled = true
            self:storeSettings()
            Timer(1200, function() applet.playback:start("127.0.0.1", 17880, "/spotify.ogg") end, true):start()
            timer:stop()
        elseif d.state == "error" then timer:stop() end
    end); timer:start()
    return window
end

function registerApplet(self)
    -- This applet owns a background service, so instantiate it during boot.
    -- Merely registering the menu leaves saved enabled accounts offline until
    -- the user opens the menu for the first time.
    appletManager:loadApplet("SpotifyConnect")
    jiveMain:addItem(self:menuItem("spotifyConnect", "home", "SPOTIFY_CONNECT", function()
        local applet = state.applet
        local service = state.service
        if not applet or not service then return end
        local window = Window("text_list", "Spotify Connect")
        local menu = SimpleMenu("menu"); window:addWidget(menu)
        local modeNames = {disabled="Disabled", manual="Manual", always_on="Always On"}
        local function selectMode()
            local modeWindow=Window("text_list","Operating Mode"); local modeMenu=SimpleMenu("menu"); modeWindow:addWidget(modeMenu)
            for _,mode in ipairs({"disabled","manual","always_on"}) do
                local selected=mode
                modeMenu:addItem({text=modeNames[selected] .. (service:getMode()==selected and " *" or ""),callback=function()
                    service:setMode(selected); self:storeSettings(); modeWindow:hide()
                end})
            end
            modeWindow:show()
        end
        local modeItem={text="Operating Mode: " .. modeNames[service:getMode()],callback=selectMode}; menu:addItem(modeItem)
        local statusItem={text="State: " .. service:getStatus(),callback=function() showPairing(self,applet) end}; menu:addItem(statusItem)
        local mode=service:getMode()
        if mode~="disabled" and not service:credentialsExist() then menu:addItem({text="Connect account",callback=function() if service:start(true) then showPairing(self,applet) end end}) end
        if mode=="manual" and not service:isRunning() then menu:addItem({text="Start Spotify Connect",callback=function() service:start(false) end}) end
        if mode=="manual" and service:isRunning() then menu:addItem({text="Stop Spotify Connect",callback=function() service:stop(false) end}) end
        if mode~="disabled" and service:isRunning() then menu:addItem({text="Restart Spotify Connect",callback=function() service:restart() end}) end
        menu:addItem({text="Device: " .. ((applet._settings and applet._settings.deviceName) or modelName)})
        if service:getLastError() then menu:addItem({text="Last error: " .. service:getLastError()}) end
        menu:addItem({text="Disconnect account",callback=function() service:disconnect(); self:storeSettings() end})
        local statusTimer=Timer(2000,function()
            menu:setText(statusItem,"State: " .. service:getStatus())
            menu:setText(modeItem,"Operating Mode: " .. modeNames[service:getMode()])
        end); statusTimer:start(); window:addListener(EVENT_WINDOW_POP,function() statusTimer:stop() end)
        window:show()
    end, 1))
end
function defaultSettings() return {enabled=false,deviceName=modelName,serviceMode="manual",serviceModeExplicit=true} end
function upgradeSettings(_, settings)
    settings=settings or {}; if settings.deviceName==nil then settings.deviceName=modelName end
    if settings.enabled==nil then settings.enabled=false end
    if settings.serviceMode==nil then settings.serviceMode=settings.enabled and "always_on" or "manual"; settings.serviceModeExplicit=false end
    return settings
end
function configureApplet() end
return _M
