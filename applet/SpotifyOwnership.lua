local Binding=require("applets.StandaloneBase.OwnershipBinding")
local M={}
function M.new(o)
    if not o or not o.playback or not o.service then return nil end
    return Binding.new(o,{owner="spotify",
        attach=function(gate) return o.playback:configureOwnership(gate) end,
        fence=function() return o.service:ownershipFence() end,
        stopProducer=function(done) o.service:ownershipStop(done) end,
        releaseHooks=function(done)
            -- Spotify installs no Playback wrappers. Drop the old reference;
            -- the shared decoder observer retains its independently captured one.
            o.playback.playback=nil;o.playback.paused=false;done(true)
        end,
        grant=function() o.service:ownershipGranted() end})
end
return M
