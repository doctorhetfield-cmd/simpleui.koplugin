-- sui_cover_net.lua — Simple UI
-- Blocking HTTP GET helpers for the online cover search. Requests use
-- KOReader's socket timeouts and stop reading past a size cap, so a slow or
-- misbehaving server cannot hang the reader or fill its memory.
--
-- Public API
--   CoverNet.get(url)      -> body | nil, err
--   CoverNet.getJson(url)  -> table | nil
--   CoverNet.resetAnswered()
--   CoverNet.answered()    -> requests a server answered (any HTTP status)
--                             since resetAnswered(); 0 means none got through

local logger = require("logger")

local CoverNet = {}

-- Largest response body read into memory (a cover is well below this).
local MAX_BODY = 8 * 1024 * 1024

local answered = 0

function CoverNet.resetAnswered() answered = 0 end
function CoverNet.answered() return answered end

-- socketutil.table_sink that aborts once more than MAX_BODY bytes came in.
local function cappedSink(socketutil, chunks)
    local sink = socketutil.table_sink(chunks)
    local received = 0
    return function(chunk, err)
        if chunk then
            received = received + #chunk
            if received > MAX_BODY then return nil, "response too large" end
        end
        return sink(chunk, err)
    end
end

function CoverNet.get(url)
    local http       = require("socket.http")
    local socket     = require("socket")
    local socketutil = require("socketutil")
    local chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url      = url,
            method   = "GET",
            headers  = { ["User-Agent"] = socketutil.USER_AGENT },
            sink     = cappedSink(socketutil, chunks),
            redirect = true,
        })
    end)
    socketutil:reset_timeout()
    -- A numeric code is a server's answer; anything else failed on the way.
    if ok and type(code) == "number" then answered = answered + 1 end
    if not ok then
        logger.warn("SimpleUI cover search: request failed", url, code)
        return nil, tostring(code)
    end
    if code ~= 200 then
        logger.dbg("SimpleUI cover search: HTTP", code, url)
        return nil, "http " .. tostring(code)
    end
    return table.concat(chunks)
end

function CoverNet.getJson(url)
    local body = CoverNet.get(url)
    if not body then return nil end
    local ok, data = pcall(require("json").decode, body)
    if ok and type(data) == "table" then return data end
end

return CoverNet
