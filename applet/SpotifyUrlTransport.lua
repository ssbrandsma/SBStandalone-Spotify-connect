local tostring, type = tostring, type
local string = require("string")

local UrlTransport = {}
local PROXY_PREFIX = "http://127.0.0.1:8765/https/"
local MAX_ARTWORK_URL_BYTES = 383

local function trim(value)
    return tostring(value or ""):gsub("^%s*(.-)%s*$", "%1")
end

function UrlTransport.artworkUrl(url)
    if type(url) ~= "string" then return nil end
    url = trim(url)
    if url == "" or #url > MAX_ARTWORK_URL_BYTES or string.find(url, "[%s%z]") then return nil end
    if string.lower(string.sub(url, 1, #PROXY_PREFIX)) == PROXY_PREFIX then return url end
    local scheme, authority = string.match(url, "^(https?)://([^/%?#]+)")
    if not scheme or not authority or string.find(authority, "@", 1, true)
        or not string.match(authority, "^[%w%.%-]+:?%d*$") then return nil end
    if scheme == "https" then url = PROXY_PREFIX .. string.sub(url, 9) end
    if #url > MAX_ARTWORK_URL_BYTES then return nil end
    return url
end

function UrlTransport.proxyPrefix() return PROXY_PREFIX end
return UrlTransport
