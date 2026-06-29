-- module_hardcover.lua — Simple UI
-- Hardcover.app reading goal widget.
--
-- Shows your active reading goal fetched live from hardcover.app.
-- Requires an API key: hardcover.app → Settings → Developer.
--
-- Settings keys:
--   simpleui_hc_api_key       — Hardcover API key (Bearer token)
--   simpleui_hc_cache_data    — cached goal as JSON string
--   simpleui_hc_cache_time    — Unix timestamp of last successful fetch
--   simpleui_hc_cache_ttl     — cache TTL in minutes (default 60)

local _        = require("gettext")
local logger   = require("logger")
local Screen   = require("device").screen
local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local UI     = require("sui_core")
local Config = require("sui_config")

local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local _BASE_H        = Screen:scaleBySize(82)   -- widget content height (no label)
local _BASE_TITLE_FS = Screen:scaleBySize(13)
local _BASE_BODY_FS  = Screen:scaleBySize(10)
local _BASE_SMALL_FS = Screen:scaleBySize(9)
local _BASE_BAR_H    = Screen:scaleBySize(6)
local _BASE_BAR_R    = Screen:scaleBySize(3)     -- bar corner radius
local _BASE_ROW_H    = Screen:scaleBySize(18)    -- row-mode height
local _BASE_ROW_FS   = Screen:scaleBySize(10)    -- row-mode font size

local _CLR_BAR_BG    = Blitbuffer.gray(0.15)
local _CLR_BAR_FG    = Blitbuffer.gray(0.80)
local _CLR_WARN      = Blitbuffer.COLOR_BLACK    -- bold black for behind-schedule
local _CLR_OK        = Blitbuffer.gray(0.50)     -- softer for on-track / ahead

local API_URL            = "https://api.hardcover.app/v1/graphql"
local CACHE_TTL_DEFAULT  = 60    -- minutes

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SK = {
    api_key    = "simpleui_hc_api_key",
    cache_data = "simpleui_hc_cache_data",
    cache_time = "simpleui_hc_cache_time",
    cache_ttl  = "simpleui_hc_cache_ttl",
    text_scale = "simpleui_hc_text_scale",
    layout     = "simpleui_hc_layout",
}

local _HC_TEXT_SCALE_MIN  = 50
local _HC_TEXT_SCALE_MAX  = 200
local _HC_TEXT_SCALE_STEP = 5
local _HC_TEXT_SCALE_DEF  = 100

local function _getApiKey()
    local k = G_reader_settings:readSetting(SK.api_key) or ""
    -- Strip common prefixes users might paste
    k = k:gsub("^%s+", ""):gsub("%s+$", "")
    k = k:gsub("^[Bb]earer%s+", "")
    k = k:gsub('^"(.*)"$', "%1")
    return k
end

local function _getCacheTtlMin()
    return G_reader_settings:readSetting(SK.cache_ttl) or CACHE_TTL_DEFAULT
end

local function _getTextScalePct()
    return tonumber(G_reader_settings:readSetting(SK.text_scale)) or _HC_TEXT_SCALE_DEF
end

local function _getLayout()
    return G_reader_settings:readSetting(SK.layout) or "card"
end

-- ---------------------------------------------------------------------------
-- JSON helper (tries rapidjson then cjson then json)
-- ---------------------------------------------------------------------------

local _json
local function _getJson()
    if _json then return _json end
    local ok, j
    ok, j = pcall(require, "rapidjson")
    if ok and j then _json = j; return j end
    ok, j = pcall(require, "cjson")
    if ok and j then _json = j; return j end
    ok, j = pcall(require, "json")
    if ok and j then _json = j; return j end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _getCached()
    local data_str = G_reader_settings:readSetting(SK.cache_data)
    if not data_str then return nil end
    local j = _getJson()
    if not j then return nil end
    local ok, data = pcall(j.decode, data_str)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function _saveCache(goal)
    local j = _getJson()
    if not j then return end
    local ok, str = pcall(j.encode, goal)
    if not ok then return end
    G_reader_settings:saveSetting(SK.cache_data, str)
    G_reader_settings:saveSetting(SK.cache_time, os.time())
end

local function _isCacheStale()
    local ts  = G_reader_settings:readSetting(SK.cache_time) or 0
    local ttl = _getCacheTtlMin() * 60
    return (os.time() - ts) > ttl
end

-- ---------------------------------------------------------------------------
-- HTTP fetch  (ssl.https → socket.https → curl fallback)
-- ---------------------------------------------------------------------------

local function _doPost(api_key, payload_str)
    local headers = {
        ["Content-Type"]   = "application/json",
        ["Authorization"]  = "Bearer " .. api_key,
        ["Content-Length"] = tostring(#payload_str),
    }

    -- ── Try ssl.https (luasec) ──────────────────────────────────────────────
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn,   ltn12 = pcall(require, "ltn12")
    if ok_https and ok_ltn and https and ltn12 then
        local resp = {}
        local ok2, b, code = pcall(function()
            return https.request({
                url     = API_URL,
                method  = "POST",
                headers = headers,
                source  = ltn12.source.string(payload_str),
                sink    = ltn12.sink.table(resp),
            })
        end)
        local body = table.concat(resp)
        if ok2 and body ~= "" then
            return body
        end
        logger.warn("simpleui hardcover: ssl.https failed (code=" .. tostring(code) .. ")")
    end

    -- ── Try http (plain) as last Lua resort (uncommon but some builds) ───────
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and ok_ltn and http and ltn12 then
        -- Hardcover forces HTTPS, skip plain HTTP attempt silently.
    end

    -- ── Fallback: curl ──────────────────────────────────────────────────────
    -- Sanitize key to safe subset (API tokens are hex/base64url).
    local safe_key = api_key:gsub("[^%w%-%_%.~%+%/=]", "")
    if safe_key == "" then return nil end

    local dir      = "/tmp/simpleui_hc"
    local p_file   = dir .. "/query.json"
    local out_file = dir .. "/resp.json"
    local err_file = dir .. "/err.txt"

    os.execute("mkdir -p '" .. dir .. "'")
    local fp = io.open(p_file, "w")
    if not fp then return nil end
    fp:write(payload_str)
    fp:close()

    -- Use inline -H with sanitized key; -H @file requires curl ≥ 7.55.
    local cmd = "curl -s -m 20 -X POST"
        .. " -H 'Content-Type: application/json'"
        .. " -H 'Authorization: Bearer " .. safe_key .. "'"
        .. " --data-binary @'" .. p_file .. "'"
        .. " -o '" .. out_file .. "'"
        .. " 2>'" .. err_file .. "'"
        .. " '" .. API_URL .. "'"

    local ret = os.execute(cmd)
    -- In LuaJIT/5.1 os.execute returns exit code (0 = success).
    -- In Lua 5.2+ it returns true/nil.  Accept both.
    local ok_curl = (ret == 0 or ret == true)
    if not ok_curl then
        local ef = io.open(err_file, "r")
        if ef then
            logger.warn("simpleui hardcover: curl failed: " .. ef:read("*a"):sub(1, 120))
            ef:close()
        else
            logger.warn("simpleui hardcover: curl failed with code " .. tostring(ret))
        end
        return nil
    end

    local g = io.open(out_file, "r")
    if not g then return nil end
    local body = g:read("*a")
    g:close()
    return body ~= "" and body or nil
end

-- ---------------------------------------------------------------------------
-- Goal parsing and selection
-- ---------------------------------------------------------------------------

-- Extract goal list from raw API response.
local function _parseGoals(resp_data)
    if not resp_data or not resp_data.data then return nil end
    local me = resp_data.data.me
    if not me then return nil end
    -- Hardcover returns me as an array in some schema versions
    local me_obj = (type(me) == "table" and me[1]) or me
    if not me_obj then return nil end
    local goals = me_obj.goals
    if not goals or (type(goals) == "table" and #goals == 0) then return nil end
    return goals
end

-- Choose the single most-relevant goal:
--   1) Active now (start_date ≤ today ≤ end_date)
--   2) Nearest future end_date
--   3) Most recently ended
local function _selectGoal(goals)
    if not goals or #goals == 0 then return nil end
    local today = os.date("%Y-%m-%d")

    for _, g in ipairs(goals) do
        if not g.archived then
            local s = g.start_date or ""
            local e = g.end_date   or ""
            if s <= today and today <= e then return g end
        end
    end

    local future = {}
    for _, g in ipairs(goals) do
        if not g.archived and (g.end_date or "") > today then
            future[#future + 1] = g
        end
    end
    if #future > 0 then
        table.sort(future, function(a, b)
            return (a.end_date or "") < (b.end_date or "")
        end)
        return future[1]
    end

    local rest = {}
    for _, g in ipairs(goals) do
        if not g.archived then rest[#rest + 1] = g end
    end
    if #rest == 0 then return nil end
    table.sort(rest, function(a, b)
        return (a.end_date or "") > (b.end_date or "")
    end)
    return rest[1]
end

-- Fetch from API, parse, select best goal, save to cache.
local function _fetchAndCache(api_key)
    local j = _getJson()
    if not j then
        logger.warn("simpleui hardcover: no JSON library available")
        return nil
    end
    local payload = '{"query":"{ me { goals { id goal metric start_date end_date progress description archived } } }"}'
    local body = _doPost(api_key, payload)
    if not body then
        logger.warn("simpleui hardcover: HTTP fetch failed")
        return nil
    end
    local ok, resp = pcall(j.decode, body)
    if not ok or type(resp) ~= "table" then
        logger.warn("simpleui hardcover: JSON parse failed: " .. tostring(body):sub(1, 120))
        return nil
    end
    local goals = _parseGoals(resp)
    if not goals then
        -- Log for debugging; first 200 chars of response
        logger.info("simpleui hardcover: no goals in response: " .. tostring(body):sub(1, 200))
        return nil
    end
    local goal = _selectGoal(goals)
    if not goal then return nil end
    _saveCache(goal)
    return goal
end

-- ---------------------------------------------------------------------------
-- Trigger homescreen refresh after background fetch
-- ---------------------------------------------------------------------------

local function _refreshHomescreen()
    local HS = package.loaded["sui_homescreen"]
    if HS and HS._instance then
        pcall(function() HS._instance:_refresh(false) end)
    end
end

-- ---------------------------------------------------------------------------
-- Date formatting helpers
-- ---------------------------------------------------------------------------

local _SV_MONTHS = {
    "jan.", "feb.", "mars", "apr.", "maj", "jun.",
    "jul.", "aug.", "sep.", "okt.", "nov.", "dec."
}

local function _parseYMD(s)
    if not s then return nil end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

local function _fmtDate(date_str)
    local y, m, d = _parseYMD(date_str)
    if not y then return date_str or "" end
    return string.format("%d %s %d", d, _SV_MONTHS[m] or "?", y)
end

-- Returns a Unix timestamp for the start of the given date (local noon,
-- which avoids DST boundary issues for day-level comparisons).
local function _dateTs(date_str)
    local y, m, d = _parseYMD(date_str)
    if not y then return nil end
    return os.time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
end

-- ---------------------------------------------------------------------------
-- Goal title (translates "YYYY Reading Goal" → "Läsmål för YYYY")
-- ---------------------------------------------------------------------------

local function _goalTitle(goal)
    if not goal then return "Hardcover" end
    local desc = goal.description or ""
    local year = desc:match("^(%d%d%d%d) Reading Goal$")
    if year then return string.format("Läsmål för %s", year) end
    year = desc:match("^Läsmål för (%d%d%d%d)$")
    if year then return desc end
    return desc ~= "" and desc or "Hardcover"
end

-- ---------------------------------------------------------------------------
-- "On schedule?" status line
-- ---------------------------------------------------------------------------

local function _statusText(goal)
    if not goal then return nil, false end
    local progress = goal.progress or 0
    local target   = goal.goal    or 0
    if target <= 0 then return nil, false end

    local metric = (goal.metric or "book"):lower()
    local today  = os.date("%Y-%m-%d")

    local function _unit(n)
        if metric == "page" then
            return n == 1 and "sida" or "sidor"
        else
            return n == 1 and "bok" or "böcker"
        end
    end

    -- Completed
    if progress >= target then
        return "🎉 Mål uppnått!", false
    end

    local end_date = goal.end_date or ""
    -- Goal has passed
    if today > end_date then
        local left = target - progress
        return string.format("Avslutad – %d %s kvar", left, _unit(left)), true
    end

    -- Compute fraction of goal period elapsed
    local ts_start = _dateTs(goal.start_date)
    local ts_end   = _dateTs(end_date)
    local ts_now   = os.time()

    if ts_start and ts_end and ts_end > ts_start then
        local frac     = math.max(0, math.min(1, (ts_now - ts_start) / (ts_end - ts_start)))
        local expected = math.floor(target * frac)
        local delta    = progress - expected

        if delta < -1 then
            local behind = -delta
            return string.format("%d %s efter schemat.", behind, _unit(behind)), true
        elseif delta > 1 then
            local ahead = delta
            return string.format("%d %s före schemat.", ahead, _unit(ahead)), false
        else
            return "I fas.", false
        end
    end

    return nil, false
end

-- ---------------------------------------------------------------------------
-- Progress bar (same pattern as module_reading_goals)
-- ---------------------------------------------------------------------------

local function _buildBar(w, h, pct)
    pct = math.max(0, math.min(1, pct or 0))
    local fill_w = math.max(0, math.floor(w * pct))
    if fill_w <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = h }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        LineWidget:new{ dimen = Geom:new{ w = w,       h = h }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fill_w,  h = h }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- Build the row widget (compact single-line layout)
-- Title · mini-bar · X% · X av Y böcker [· status]
-- ---------------------------------------------------------------------------

local function _buildRow(w, goal)
    local scale    = Config.getModuleScale("hardcover")
    local ts       = scale * (_getTextScalePct() / 100)
    local row_h    = math.max(14, math.floor(_BASE_ROW_H * scale))
    local fs       = math.max(7,  math.floor(_BASE_ROW_FS * ts))
    local bar_h    = math.max(2,  math.floor(_BASE_BAR_H  * scale))
    local face     = Font:getFace("cfont", fs)

    local progress = goal.progress or 0
    local target   = math.max(1, goal.goal or 1)
    local pct      = math.min(1.0, progress / target)
    local pct_str  = string.format("%d%%", math.floor(pct * 100))
    local metric   = (goal.metric or "book"):lower()
    local unit     = metric == "page" and "sidor" or "böcker"
    local title    = _goalTitle(goal)
    local status, is_warn = _statusText(goal)

    -- Build parts: title, bar, pct, count, optional status
    local BAR_W    = math.floor(w * 0.12)
    local SEP      = HorizontalSpan:new{ width = Screen:scaleBySize(5) }
    local DOT      = TextWidget:new{ text = " · ", face = face, fgcolor = CLR_TEXT_SUB }

    local title_w  = TextWidget:new{
        text      = title,
        face      = Font:getFace("cfont", math.max(7, math.floor(_BASE_ROW_FS * ts))),
        bold      = true,
        fgcolor   = Blitbuffer.COLOR_BLACK,
        max_width = math.floor(w * 0.35),
    }

    local count_str = string.format("%d / %d %s", progress, goal.goal or 0, unit)

    local row = HorizontalGroup:new{ align = "center" }
    row[#row+1] = title_w
    row[#row+1] = SEP
    row[#row+1] = _buildBar(BAR_W, bar_h, pct)
    row[#row+1] = HorizontalSpan:new{ width = Screen:scaleBySize(4) }
    row[#row+1] = TextWidget:new{ text = pct_str,   face = face, fgcolor = Blitbuffer.COLOR_BLACK }
    row[#row+1] = TextWidget:new{ text = " · ",     face = face, fgcolor = CLR_TEXT_SUB }
    row[#row+1] = TextWidget:new{ text = count_str, face = face, fgcolor = CLR_TEXT_SUB }
    if status then
        row[#row+1] = TextWidget:new{ text = " · ", face = face, fgcolor = CLR_TEXT_SUB }
        row[#row+1] = TextWidget:new{
            text    = status,
            face    = face,
            fgcolor = is_warn and Blitbuffer.COLOR_BLACK or CLR_TEXT_SUB,
        }
    end

    local CenterContainer = require("ui/widget/container/centercontainer")
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = w, h = row_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = row_h },
            row,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Build the card widget from a goal table
-- ---------------------------------------------------------------------------

local function _buildCard(w, goal)
    local scale      = Config.getModuleScale("hardcover")
    local text_scale = scale * (_getTextScalePct() / 100)
    local inner_w    = w - PAD * 2
    local face_title = Font:getFace("cfont", math.max(8, math.floor(_BASE_TITLE_FS * text_scale)))
    local face_body  = Font:getFace("cfont", math.max(7, math.floor(_BASE_BODY_FS  * text_scale)))
    local face_small = Font:getFace("cfont", math.max(6, math.floor(_BASE_SMALL_FS * text_scale)))
    local bar_h      = math.max(2, math.floor(_BASE_BAR_H * scale))

    local progress = goal.progress or 0
    local target   = math.max(1, goal.goal or 1)
    local pct      = math.min(1.0, progress / target)
    local pct_str  = string.format("%d%%", math.floor(pct * 100))
    local metric   = (goal.metric or "book"):lower()
    local unit     = metric == "page" and "sidor" or "böcker"
    local prog_str = string.format("%d av %d %s", progress, goal.goal or 0, unit)
    local title    = _goalTitle(goal)
    local status, is_warn = _statusText(goal)
    local date_str = _fmtDate(goal.start_date) .. " – " .. _fmtDate(goal.end_date)

    local rows = VerticalGroup:new{ align = "left" }

    -- ── Row 1: Title (left) + Percentage (right) ──────────────────────────
    local pct_widget   = TextWidget:new{ text = pct_str,  face = face_title }
    local pct_w        = pct_widget:getSize().w
    local title_widget = TextWidget:new{
        text      = title,
        face      = face_title,
        bold      = true,
        max_width = inner_w - pct_w - Screen:scaleBySize(4),
    }
    local filler_w = math.max(0, inner_w - title_widget:getSize().w - pct_w)
    local title_row = HorizontalGroup:new{
        align = "center",
        title_widget,
        HorizontalSpan:new{ width = filler_w },
        pct_widget,
    }
    rows[#rows + 1] = title_row
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(6) }

    -- ── Row 2: Progress bar ───────────────────────────────────────────────
    rows[#rows + 1] = _buildBar(inner_w, bar_h, pct)
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(5) }

    -- ── Row 3: "X av Y böcker" ────────────────────────────────────────────
    rows[#rows + 1] = TextWidget:new{
        text    = prog_str,
        face    = face_body,
        fgcolor = CLR_TEXT_SUB,
    }

    -- ── Row 4: Status (optional) ──────────────────────────────────────────
    if status then
        rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        rows[#rows + 1] = TextWidget:new{
            text    = status,
            face    = face_small,
            fgcolor = is_warn and _CLR_WARN or _CLR_OK,
        }
    end

    -- ── Row 5: Date range ─────────────────────────────────────────────────
    rows[#rows + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
    rows[#rows + 1] = TextWidget:new{
        text    = date_str,
        face    = face_small,
        fgcolor = CLR_TEXT_SUB,
    }

    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        rows,
    }
end

-- Placeholder shown when there is no data.
local function _buildPlaceholder(w, msg)
    local face = Font:getFace("cfont", _BASE_BODY_FS)
    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        TextWidget:new{
            text    = msg,
            face    = face,
            fgcolor = CLR_TEXT_SUB,
            max_width = w - PAD * 2,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _fetch_pending = false   -- guard against duplicate scheduled fetches
local _last_error    = nil     -- last fetch error message (string) or nil

-- ---------------------------------------------------------------------------
-- Module export
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "hardcover"
M.name        = _("Hardcover")
M.label       = _("Hardcover")
M.enabled_key = "hardcover"
M.default_on  = false
M._getCached  = _getCached   -- exposed for module_reading_stats

-- Called by module_reading_stats (and M.build) to trigger a background fetch
-- when the cache is stale. Safe to call from anywhere — returns immediately.
function M.ensureFresh()
    local api_key = _getApiKey()
    if api_key == "" or _fetch_pending or not _isCacheStale() then return end
    _fetch_pending = true
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(1.0, function()
        _fetch_pending = false
        if _getApiKey() == "" then return end
        local ok, result = pcall(_fetchAndCache, api_key)
        if ok and result then
            _last_error = nil
        else
            local retry_delay_secs = math.max(300, (_getCacheTtlMin() - 5) * 60)
            G_reader_settings:saveSetting(SK.cache_time,
                os.time() - (_getCacheTtlMin() * 60) + retry_delay_secs)
            _last_error = _("Hardcover: kunde inte hämta data. Kontrollera API-nyckeln och nätverket.")
        end
        _refreshHomescreen()
    end)
end

function M.build(w, ctx)
    local ok_build, result = pcall(_doBuild, w, ctx)
    if ok_build then
        return result
    else
        logger.warn("simpleui hardcover: M.build crashed: " .. tostring(result))
        local face = Font:getFace("cfont", _BASE_BODY_FS)
        return TextWidget:new{ text = "Hardcover: " .. tostring(result):sub(1, 80), face = face }
    end
end

function _doBuild(w, ctx)
    local api_key = _getApiKey()

    if api_key == "" then
        return _buildPlaceholder(w, _("Hardcover: ange API-nyckel i modulinställningarna."))
    end

    local cached = _getCached()
    local layout  = _getLayout()
    local widget

    if cached then
        if layout == "row" then
            widget = _buildRow(w, cached)
        else
            widget = _buildCard(w, cached)
        end
    elseif _last_error then
        widget = _buildPlaceholder(w, _last_error)
    else
        widget = _buildPlaceholder(w, _("Hardcover: hämtar data…"))
    end

    -- Update M.label so homescreen shows/hides the section title correctly
    local _hide_label_key = "simpleui_hide_label_hardcover"
    if G_reader_settings:readSetting(_hide_label_key) == true then
        M.label = nil
    else
        M.label = _("Hardcover")
    end

    M.ensureFresh()

    return widget
end

function M.getHeight(ctx)
    local _hide_label_key = "simpleui_hide_label_hardcover"
    local label_h = (G_reader_settings:readSetting(_hide_label_key) ~= true) and Config.getScaledLabelH() or 0
    local scale   = Config.getModuleScale("hardcover")
    if _getApiKey() == "" then
        return label_h + math.floor(_BASE_BODY_FS * scale) + PAD * 2
    end
    if _getLayout() == "row" then
        return label_h + math.max(14, math.floor(_BASE_ROW_H * scale))
    end
    return label_h + math.floor(_BASE_H * scale)
end

function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local items = {}

    -- ── Show label ────────────────────────────────────────────────────────
    local _hide_label_key = "simpleui_hide_label_hardcover"
    items[#items + 1] = {
        text           = _lc("Show label"),
        checked_func   = function() return G_reader_settings:readSetting(_hide_label_key) ~= true end,
        keep_menu_open = true,
        callback       = function()
            local hidden = G_reader_settings:readSetting(_hide_label_key) == true
            G_reader_settings:saveSetting(_hide_label_key, not hidden and true or nil)
            refresh()
        end,
    }

    -- ── Type (Card / Row) ────────────────────────────────────────────────────
    items[#items + 1] = {
        text           = _lc("Type"),
        sub_item_table = {
            {
                text           = _lc("Card"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return _getLayout() == "card" end,
                callback       = function()
                    G_reader_settings:saveSetting(SK.layout, "card")
                    refresh()
                end,
            },
            {
                text           = _lc("Row"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return _getLayout() == "row" end,
                callback       = function()
                    G_reader_settings:saveSetting(SK.layout, "row")
                    refresh()
                end,
            },
        },
        separator = true,
    }

    -- ── Scale ──────────────────────────────────────────────────────────────
    items[#items + 1] = Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("hardcover", ctx_menu.pfx) end,
        set          = function(v) Config.setModuleScale(v, "hardcover", ctx_menu.pfx) end,
        refresh      = refresh,
    })

    -- ── Text Size ─────────────────────────────────────────────────────────
    items[#items + 1] = Config.makeScaleItem({
        text_func     = function()
            local pct = _getTextScalePct()
            return pct == _HC_TEXT_SCALE_DEF
                and _lc("Text Size")
                or  string.format(_lc("Text Size — %d%%"), pct)
        end,
        title         = _lc("Text Size"),
        info          = _lc("Size of the text inside the Hardcover widget.\n100% is the default size."),
        get           = _getTextScalePct,
        set           = function(pct) G_reader_settings:saveSetting(SK.text_scale, pct) end,
        refresh       = refresh,
        value_min     = _HC_TEXT_SCALE_MIN,
        value_max     = _HC_TEXT_SCALE_MAX,
        value_step    = _HC_TEXT_SCALE_STEP,
        default_value = _HC_TEXT_SCALE_DEF,
        separator     = true,
    })

    -- ── API key ───────────────────────────────────────────────────────────
    items[#items + 1] = {
        text_func = function()
            local k = _getApiKey()
            if k == "" then
                return _lc("API-nyckel: (ej angiven)")
            else
                return _lc("API-nyckel: ****") .. k:sub(-4)
            end
        end,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager   = require("ui/uimanager")
            local dlg
            dlg = InputDialog:new{
                title       = _lc("Hardcover API-nyckel"),
                description = _lc("hardcover.app → Inställningar → Utvecklare"),
                input       = _getApiKey(),
                buttons = {{
                    {
                        text     = _lc("Avbryt"),
                        callback = function() UIManager:close(dlg) end,
                    },
                    {
                        text             = _lc("Spara"),
                        is_enter_default = true,
                        callback = function()
                            local raw = dlg:getInputText()
                            raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                            raw = raw:gsub("^[Bb]earer%s+", "")
                            raw = raw:gsub('^"(.*)"$', "%1")
                            G_reader_settings:saveSetting(SK.api_key, raw)
                            -- Invalidate cache so the next build fetches fresh data
                            G_reader_settings:saveSetting(SK.cache_time, 0)
                            UIManager:close(dlg)
                            if refresh then refresh() end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
        end,
        keep_menu_open = false,
    }

    -- ── Manual refresh ────────────────────────────────────────────────────
    items[#items + 1] = {
        text     = _lc("Uppdatera nu"),
        enabled_func = function() return _getApiKey() ~= "" end,
        callback = function()
            local api_key = _getApiKey()
            if api_key == "" then return end
            G_reader_settings:saveSetting(SK.cache_time, 0)
            if not _fetch_pending then
                _fetch_pending = true
                local UIManager = require("ui/uimanager")
                UIManager:scheduleIn(0.1, function()
                    _fetch_pending = false
                    local ok, result = pcall(_fetchAndCache, api_key)
                    if refresh then refresh() end
                end)
            end
        end,
        keep_menu_open = false,
    }

    -- ── Cache TTL ─────────────────────────────────────────────────────────
    items[#items + 1] = {
        text_func = function()
            return string.format(_lc("Uppdateringsintervall: %d min"), _getCacheTtlMin())
        end,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local UIManager   = require("ui/uimanager")
            local dlg
            dlg = InputDialog:new{
                title      = _lc("Uppdateringsintervall (minuter)"),
                input      = tostring(_getCacheTtlMin()),
                input_type = "number",
                buttons = {{
                    {
                        text     = _lc("Avbryt"),
                        callback = function() UIManager:close(dlg) end,
                    },
                    {
                        text             = _lc("OK"),
                        is_enter_default = true,
                        callback = function()
                            local val = math.max(5, math.min(1440,
                                tonumber(dlg:getInputText()) or CACHE_TTL_DEFAULT))
                            G_reader_settings:saveSetting(SK.cache_ttl, val)
                            UIManager:close(dlg)
                            if refresh then refresh() end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
        end,
        keep_menu_open = false,
    }

    return items
end

return M
