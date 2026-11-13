local oo = require("loop.simple")
local Applet = require("jive.Applet")
local Framework = require("jive.ui.Framework")
local SimpleMenu = require("jive.ui.SimpleMenu")
local Window = require("jive.ui.Window")
local Popup = require("jive.ui.Popup")
local Group = require("jive.ui.Group")
local Icon = require("jive.ui.Icon")
local Label = require("jive.ui.Label")
local Slider = require("jive.ui.Slider")
local SpotifyService = require("applets.SpotifyConnect.SpotifyService")
local SpotifyPlayback = require("applets.SpotifyConnect.SpotifyPlayback")
local SpotifyStandaloneNowPlaying = require("applets.SpotifyConnect.SpotifyStandaloneNowPlaying")
local SpotifyNativeNowPlaying = require("applets.SpotifyConnect.SpotifyNativeNowPlaying")
local Player = require("jive.slim.Player")
local Timer = require("jive.ui.Timer")
local math = require("math")
local os = require("os")
local Log = require("jive.utils.log")
local state = require("applets.SpotifyConnect.SpotifyConnectState")
local pcall, tostring = pcall, tostring
local appletManager = appletManager

module(..., Framework.constants)
oo.class(_M, Applet)

-- Standalone Radio and Spotify share the stock SqueezePlay decoder. Radio's
-- StreamPlayer intentionally retains its last desired station for local
-- resume, but that also lets its installed disconnect hook schedule a
-- reconnect after another source has taken the decoder. Explicit Spotify
-- activation must therefore stop Radio before opening the Spotify stream and
-- clear only the active desire; lastStation remains available to Radio.
local function deactivateStandaloneRadio()
    if not appletManager or not appletManager.getAppletInstance then return false end
    local ok, radio = pcall(function() return appletManager:getAppletInstance("StandaloneRadio") end)
    local streamPlayer = ok and radio and radio.streamPlayer
    if not streamPlayer or not (streamPlayer.ownsPlayback or streamPlayer.desiredStation
        or streamPlayer.pendingStation or streamPlayer.reconnectTimer) then return false end
    streamPlayer:stop()
    streamPlayer.desiredStation = nil
    return true
end

local function showRemoteVolume(self, percent)
    if not self._volumePopup then
        local popup = Popup("slider_popup")
        popup:setAutoHide(false)
        popup:setAlwaysOnTop(true)
        self._volumeTitle = Label("heading", "")
        self._volumeIcon = Icon("icon_popup_volume")
        self._volumeSlider = Slider("volume_slider", -1, 100, percent, function() end)
        popup:addWidget(self._volumeTitle)
        popup:addWidget(self._volumeIcon)
        popup:addWidget(Group("slider_group", { slider = self._volumeSlider }))
        popup:focusWidget(nil)
        self._volumePopup = popup
    end
    self._volumeTitle:setValue(percent == 0 and "Muted" or tostring(percent))
    self._volumeIcon:setStyle(percent == 0 and "icon_popup_mute" or "icon_popup_volume")
    self._volumeSlider:setValue(percent)
    local popup = self._volumePopup
    popup:showBriefly(1800, function()
        if self._volumePopup == popup then
            self._volumePopup, self._volumeTitle = nil, nil
            self._volumeIcon, self._volumeSlider = nil, nil
        end
    end, Window.transitionNone, Window.transitionNone)
end

function init(self)
    os.execute("chmod 755 /usr/share/jive/applets/SpotifyConnect/librespot /usr/share/jive/applets/SpotifyConnect/ogg-http-bridge /usr/share/jive/applets/SpotifyConnect/spotify-metadata /usr/share/jive/applets/SpotifyConnect/spotify-metadata-event /usr/share/jive/applets/SpotifyConnect/spotify-supervisor 2>/dev/null")
    self._settings = self._settings or { enabled = false, deviceName = "Squeezebox Radio" }
    state.applet = self
    self.service = SpotifyService()
    self.service:init(self)
    self.playback = SpotifyPlayback()
    self.playback:init(self)
    local logger = Log.logger("SpotifyConnect")
    self._activationGeneration = 0
    self.standaloneNowPlaying = SpotifyStandaloneNowPlaying.new({
        log = logger,
        isPlaybackOwner = function()
            return self._lastPlaybackState == "playing" or self._lastPlaybackState == "paused"
        end,
    })
    self.nativeNowPlaying = SpotifyNativeNowPlaying.new({
        appletManager = appletManager, framework = Framework, timerFactory = Timer,
        transition = Window.transitionPushLeft, log = logger,
        getGeneration = function() return self._activationGeneration end,
    })
    self._lastLoadingTrack = nil
    self._lastStreamMarker = nil
    self._lastPlaybackState = nil
    self._lastRemoteVolume = nil
    self._lastPositionEvent = nil
    self._trackWatcher = Timer(250, function()
        if not self.service:isRunning() then return end
        local d = self.service:eventData()
        if self.playback.ownership and not self.playback.ownership:canStart() then
            self._lastStreamMarker=d.stream or self._lastStreamMarker
            self._lastPlaybackState=d.playback_state or self._lastPlaybackState
            return
        end
        if d.loading and d.loading ~= self._lastLoadingTrack then
            Log.logger("SpotifyConnect"):info("track loading: ", d.loading)
            if deactivateStandaloneRadio() then
                Log.logger("SpotifyConnect"):info("stopped Standalone Radio for Spotify activation")
            end
        end
        self._lastLoadingTrack = d.loading or self._lastLoadingTrack
        local streamChanged = d.stream and d.stream ~= self._lastStreamMarker
        -- A token belongs to this playback only while both stream markers
        -- agree. Never acknowledge an old generation after a manual skip.
        self.playback.drainingToken = d.drain
        if d.drain and d.eos and d.eos == d.stream and not streamChanged
            and d.drain:match(":(%d+)$") == d.stream:match(":(%d+)$")
            and d.playback_state ~= "paused" and self.playback:hasDrained() then
            if self.service:acknowledgeDrain(d.drain) then
                Log.logger("SpotifyConnect"):info("audio output drained; acknowledged ", d.drain)
            end
        end
        local stateChanged = d.playback_state and d.playback_state ~= self._lastPlaybackState
        if d.playback_state and d.playback_state ~= self._lastPlaybackState then
            if d.playback_state == "paused" then
                Log.logger("SpotifyConnect"):info("remote playback state: ", d.playback_state)
                self.playback:pause()
            elseif d.playback_state == "stopped" then
                Log.logger("SpotifyConnect"):info("remote playback state: stopped")
                self.playback:stop()
            elseif d.playback_state == "playing" and self._lastPlaybackState == "paused" and not streamChanged then
                Log.logger("SpotifyConnect"):info("remote playback resumed")
                if not self.playback:resume() then
                    self.playback:start("127.0.0.1", 17880, "/spotify.ogg")
                end
            end
        end
        self._lastPlaybackState = d.playback_state or self._lastPlaybackState
        if streamChanged then
            Log.logger("SpotifyConnect"):info("stream ready: ", d.stream, "; starting local playback")
            deactivateStandaloneRadio()
            self.playback:start("127.0.0.1", 17880, "/spotify.ogg")
            self._activationGeneration = self._activationGeneration + 1
            local snapshot = self.service:statusData()
            self.standaloneNowPlaying:activate(snapshot, self._activationGeneration)
            self.nativeNowPlaying:request(self._activationGeneration)
        end
        self._lastStreamMarker = d.stream or self._lastStreamMarker
        if d.volume and d.volume ~= self._lastRemoteVolume then
            local percent = math.floor((d.volume * 100 / 65535) + 0.5)
            percent = math.max(0, math.min(100, percent))
            local applied = self.playback:setRemoteVolume(percent)
            Log.logger("SpotifyConnect"):info("remote volume: ", percent, " applied=", applied)
            if applied then showRemoteVolume(self, percent) end
            self._lastRemoteVolume = d.volume
        end
        local positionChanged = d.position and d.position ~= self._lastPositionEvent
        local metadataChanged = d.metadata and d.metadata ~= self._lastMetadataEvent
        if self._activationGeneration > 0 and (stateChanged or positionChanged or streamChanged or metadataChanged) then
            self.standaloneNowPlaying:update(self.service:statusData(), self._activationGeneration)
        end
        self._lastPositionEvent = d.position or self._lastPositionEvent
        self._lastMetadataEvent = d.metadata or self._lastMetadataEvent
        if stateChanged and d.playback_state == "stopped" then
            self.standaloneNowPlaying:release()
            self.nativeNowPlaying:cancel()
        end
    end)
    self._trackWatcher:start()
    state.service = self.service
    local settings = self._settings
    if self.service:getMode() == "always_on" and settings.enabled and self.service:credentialsExist() then
        local ownershipAtSchedule=self.playback.ownership
        local ownershipEpoch=ownershipAtSchedule and ownershipAtSchedule.epoch
        local function stillCurrent()
            local current=self.playback.ownership
            return not current or (current==ownershipAtSchedule and current.epoch==ownershipEpoch and current:canStart())
        end
        Timer(2500, function()
            if not stillCurrent() then return end
            self.service:start(false)
            Timer(1500, function() if not stillCurrent() then return end;self.playback:start("127.0.0.1", 17880, "/spotify.ogg") end, true):start()
        end, true):start()
    end
end

function free(self)
    if self._trackWatcher then self._trackWatcher:stop() end
    if self.nativeNowPlaying then self.nativeNowPlaying:shutdown() end
    if self.standaloneNowPlaying then self.standaloneNowPlaying:shutdown() end
    if self.service then self.service:shutdown() end
end

local function statusText(self)
    return self.service:isRunning() and self:string("STATUS_RUNNING") or self:string("STATUS_STOPPED")
end

function menu(self)
    local window = Window("text_list", self:string("SPOTIFY_CONNECT"))
    local menu = SimpleMenu("menu")
    window:addWidget(menu)
    menu:addItem({text = self:string("START_TEST_STREAM"), sound = "WINDOW_OPEN", callback = function() self.service:start() end})
    menu:addItem({text = self:string("STOP"), callback = function() self.service:stop() end})
    menu:addItem({text = self:string("STATUS"), callback = function() log:info("SpotifyConnect: ", statusText(self)) end})
    menu:addItem({text = self:string("RESTART_SERVICE"), callback = function() self.service:restart() end})
    self:tieAndShowWindow(window)
end

-- Keep the public name used by older menu registrations as an alias.
showMenu = menu

-- Explicit exports keep the methods visible on older Lua module loaders.
_M.menu = menu
_M.showMenu = menu
return _M
