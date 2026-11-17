-- sui_text.lua — Simple UI
-- Text helpers shared by every surface that shows metadata or user text.
-- Lengths are counted in Unicode codepoints, so multi-byte scripts are never
-- split mid-character.
--
-- Public API
-- ----------
--   Text.cut(s, max_chars)           -> the first `max_chars` characters of `s`
--   Text.truncate(s, max_chars)      -> `s` limited to `max_chars` characters,
--       ending in an ellipsis when it was cut
--   Text.truncateStart(s, max_chars) -> same, keeping the end of `s` and
--       starting with the ellipsis (paths, identifiers)
--   Text.firstLine(s)                -> first non-blank line of a
--       newline-separated field, trimmed; nil when there is none
--   Text.formatAuthors(s)            -> nil when the field holds no name, the
--       name when it holds one, "Name et al." when it holds several
--   Text.formatDuration(secs, opts)  -> "3h 5m" / "3h" / "12m" / "0m"; with
--       opts.seconds, "3h 05m" / "1m 05s" / "45s" / "0s"
--
-- Nil and empty strings are returned unchanged by the length helpers.

local util = require("util")
local _    = require("infra/sui_i18n").translate

local Text = {}

local ELLIPSIS = "…"

-- Byte length of the UTF-8 sequence introduced by `lead_byte`.
local function sequenceLength(lead_byte)
    return lead_byte >= 240 and 4 or lead_byte >= 224 and 3 or lead_byte >= 192 and 2 or 1
end

-- UTF-8 continuation bytes (10xxxxxx) never start a character.
local function isContinuation(byte)
    return byte >= 128 and byte < 192
end

-- Byte offset of the end of the first `count` characters of `s`.
local function prefixEnd(s, count)
    local i = 1
    while i <= #s and count > 0 do
        i     = i + sequenceLength(s:byte(i))
        count = count - 1
    end
    return i - 1
end

-- Byte offset where the last `count` characters of `s` start.
local function suffixStart(s, count)
    local i = #s + 1
    while i > 1 and count > 0 do
        i = i - 1
        while i > 1 and isContinuation(s:byte(i)) do i = i - 1 end
        count = count - 1
    end
    return i
end

function Text.cut(s, max_chars)
    if not s or s == "" then return s end
    return s:sub(1, prefixEnd(s, max_chars))
end

function Text.truncate(s, max_chars)
    if not s or s == "" then return s end
    max_chars = math.max(1, max_chars)
    local stop = prefixEnd(s, max_chars)
    if stop >= #s then return s end
    return s:sub(1, prefixEnd(s, max_chars - 1)) .. ELLIPSIS
end

function Text.truncateStart(s, max_chars)
    if not s or s == "" then return s end
    max_chars = math.max(1, max_chars)
    local start = suffixStart(s, max_chars)
    if start <= 1 then return s end
    return ELLIPSIS .. s:sub(suffixStart(s, max_chars - 1))
end

-- Iterator over the trimmed, non-blank lines of `s`.
local function eachLine(s)
    local nextRaw = (s or ""):gmatch("[^\n]+")
    return function()
        for raw in nextRaw do
            local line = util.trim(raw)
            if line ~= "" then return line end
        end
    end
end

function Text.firstLine(s)
    return eachLine(s)()
end

function Text.formatAuthors(s)
    local nextName = eachLine(s)
    local first = nextName()
    if first and nextName() then return first .. _(" et al.") end
    return first
end

-- Formats with the translated pattern, or with the original one when the
-- translation does not match the arguments.
local function formatUnits(pattern, translated, ...)
    local ok, s = pcall(string.format, translated, ...)
    if ok then return s end
    return string.format(pattern, ...)
end

-- Nil, negative and NaN durations count as zero; fractions are dropped.
function Text.formatDuration(secs, opts)
    secs = tonumber(secs) or 0
    if secs ~= secs or secs < 0 then secs = 0 end
    secs = math.floor(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if opts and opts.seconds then
        if h > 0 then return formatUnits("%dh %02dm", _("%dh %02dm"), h, m) end
        if m > 0 then return formatUnits("%dm %02ds", _("%dm %02ds"), m, secs % 60) end
        return formatUnits("%ds", _("%ds"), secs)
    end
    if h > 0 and m > 0 then return formatUnits("%dh %dm", _("%dh %dm"), h, m) end
    if h > 0 then return formatUnits("%dh", _("%dh"), h) end
    return formatUnits("%dm", _("%dm"), m)
end

return Text
