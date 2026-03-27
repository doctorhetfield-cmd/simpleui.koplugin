-- module_reading_stats.lua — Simple UI
-- Reading Stats module: row of stat cards (today, averages, totals, streak).

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _               = require("gettext")
local logger          = require("logger")
local Config          = require("sui_config")

local UI      = require("sui_core")
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local PAD     = UI.PAD
local MOD_GAP = UI.MOD_GAP
local LABEL_H = UI.LABEL_H

local _CLR_TEXT_BLK  = Blitbuffer.COLOR_BLACK
local _CLR_CARD_BDR  = Blitbuffer.gray(0.72)

local _BASE_RS_CORNER_R = Screen:scaleBySize(12)
local _BASE_RS_GAP      = Screen:scaleBySize(12)
local _BASE_RS_CARD_H   = Screen:scaleBySize(96)
local _BASE_RS_VAL_FS   = Screen:scaleBySize(14)
local _BASE_RS_LBL_FS   = Screen:scaleBySize(8)
local _BASE_RS_SEP_W    = Screen:scaleBySize(1)
local _BASE_RS_PH_FS    = Screen:scaleBySize(11)  -- placeholder "No stats" text

local RS_N_COLS    = 3  -- max columns — not a dimension, no scaling needed

local SETTING_TYPE = "reading_stats_type"   -- suffix: pfx .. "reading_stats_type"

local function getType(pfx)
    return G_reader_settings:readSetting(pfx .. SETTING_TYPE) or "cards"
end

-- ---------------------------------------------------------------------------
-- Stat map
-- ---------------------------------------------------------------------------
local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600); local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

local STAT_MAP = {
    today_time  = { display_label = _("Today — Time"),      value = function(s) return fmtTime(s.today_secs) end,   label = _("of reading today") },
    today_pages = { display_label = _("Today — Pages"),     value = function(s) return tostring(s.today_pages) end, label = _("pages read today") },
    avg_time    = { display_label = _("Daily avg — Time"),  value = function(s) return fmtTime(s.avg_secs) end,     label = _("daily avg (7 days)") },
    avg_pages   = { display_label = _("Daily avg — Pages"), value = function(s) return tostring(s.avg_pages) end,   label = _("pages/day (7 days)") },
    total_time  = { display_label = _("All time — Time"),   value = function(s) return fmtTime(s.total_secs) end,   label = _("of reading, all time") },
    total_books = { display_label = _("All time — Books"),  value = function(s) return tostring(s.total_books) end, label = _("books finished") },
    streak      = { display_label = _("Streak"),            value = function(s) return tostring(s.streak) end,
                    label_fn = function(s) return s.streak == 1 and _("day streak") or _("days streak") end },
}

local STAT_POOL = { "today_time","today_pages","avg_time","avg_pages","total_time","total_books","streak" }

-- Pre-sort the pool alphabetically by display label — done once at module load,
-- not on every menu open.
local _sorted_pool = {}
for _, sid in ipairs(STAT_POOL) do
    _sorted_pool[#_sorted_pool+1] = { id = sid, label = STAT_MAP[sid].display_label }
end
table.sort(_sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)

-- ---------------------------------------------------------------------------
-- Sidecar status helpers
-- ---------------------------------------------------------------------------
-- DB fetch
-- ---------------------------------------------------------------------------
local _stats_cache     = nil
local _stats_cache_day = nil

-- shared_conn is optional. When provided (from ctx.db_conn in homescreen),
-- the connection is used directly and NOT closed here — the caller owns it.
-- When nil, a private connection is opened and closed within this function.
local function fetchAllStats(shared_conn)
    local r = { today_secs=0,today_pages=0,avg_secs=0,avg_pages=0,total_secs=0,total_books=0,streak=0 }
    local conn     = shared_conn or Config.openStatsDB()
    local own_conn = not shared_conn
    if not conn then return r end
    local ok, err = pcall(function()
        local t           = os.date("*t")
        local start_today = os.time() - (t.hour*3600 + t.min*60 + t.sec)
        local week_start  = start_today - 6*86400

        r.today_secs = tonumber(conn:rowexec(string.format(
            "SELECT sum(s) FROM (SELECT sum(duration) AS s FROM page_stat WHERE start_time>=%d GROUP BY id_book,page);",
            start_today))) or 0

        -- Use '@' as separator — avoids the integer ambiguity of '-'
        -- (page=10, id_book=1 vs page=1, id_book=01 both collapse to "10-1").
        r.today_pages = tonumber(conn:rowexec(string.format(
            "SELECT count(DISTINCT page||'@'||id_book) FROM page_stat WHERE start_time>=%d AND duration>0;",
            start_today))) or 0

        -- Aggregate per-day first (inner GROUP BY dates), then average across days
        -- in a single outer aggregate — no outer GROUP BY.
        -- Previous version had `GROUP BY dates` on the outer query which produced
        -- one row per day; count(DISTINCT dates) was always 1 per group and the
        -- inner GROUP BY id_book,page,dates inflated page counts for books read
        -- across multiple days.
        local rw = conn:exec(string.format([[
            SELECT count(*) AS nd, sum(sd) AS tt, sum(pg) AS tp
            FROM (SELECT strftime('%%Y-%%m-%%d',start_time,'unixepoch','localtime') AS dates,
                         sum(duration) AS sd,
                         count(DISTINCT page||'@'||id_book) AS pg
                  FROM page_stat WHERE start_time>=%d AND duration>0
                  GROUP BY dates);]], week_start))
        if rw and rw[1] and rw[1][1] then
            local nd = tonumber(rw[1][1]) or 0
            local tt = tonumber(rw[2] and rw[2][1]) or 0
            local tp = tonumber(rw[3] and rw[3][1]) or 0
            if nd > 0 then r.avg_secs=math.floor(tt/nd); r.avg_pages=math.floor(tp/nd) end
        end

        r.total_secs  = tonumber(conn:rowexec("SELECT sum(duration) FROM page_stat;")) or 0

        -- Streak query rewritten to avoid LIMIT inside a CTE — not supported by
        -- the SQLite version bundled in older KOReader builds.
        -- Strategy: use a non-recursive CTE for the distinct dates, then a
        -- recursive CTE that walks backwards one day at a time and stops when
        -- there is no matching date row (WHERE clause instead of LIMIT).
        -- The outer SELECT checks that the most recent reading day is today or
        -- yesterday before returning the count; otherwise streak = 0.
        local streak_val = conn:rowexec(string.format([[
            WITH RECURSIVE
            dated(d) AS (
                SELECT DISTINCT date(start_time,'unixepoch','localtime')
                FROM page_stat),
            streak(d,n) AS (
                SELECT d, 1 FROM dated
                WHERE d = (SELECT max(d) FROM dated)
                UNION ALL
                SELECT date(streak.d,'-1 day'), streak.n+1
                FROM streak
                WHERE EXISTS (SELECT 1 FROM dated WHERE d = date(streak.d,'-1 day')))
            SELECT CASE
                WHEN (SELECT max(d) FROM dated) >= date(%d,'unixepoch','localtime','-1 day')
                THEN COALESCE((SELECT max(n) FROM streak), 0)
                ELSE 0 END;]], start_today))
        r.streak = tonumber(streak_val) or 0
    end)
    if not ok then logger.warn("simpleui: reading_stats: fetchAllStats failed: " .. tostring(err)) end
    if own_conn then pcall(function() conn:close() end) end

    -- Count finished books via sidecar status — uses the shared DocSettings
    -- implementation (all-time, no year filter).
    local SH = require("desktop_modules/module_books_shared")
    r.total_books = SH.countMarkedRead()

    return r
end

-- shared_conn is optional. Only used when the cache is cold (first render of
-- the day). On cache hits the connection is never touched.
-- Pass force=true to bypass the date-based cache — used after returning from
-- a reading session so today's stats reflect the just-completed session.
local function getStats(shared_conn, force)
    local today_s = os.date("%Y-%m-%d")
    if not force and _stats_cache_day == today_s and _stats_cache ~= nil then
        return _stats_cache
    end
    local result     = fetchAllStats(shared_conn)
    _stats_cache     = result
    _stats_cache_day = today_s
    return result
end

-- ---------------------------------------------------------------------------
-- Stat widget builders
-- ---------------------------------------------------------------------------

-- Cards mode: rounded border, content centred inside the card.
-- `d` is the scaled-dims table produced once per M.build() call.
local function buildStatCardWidget(card_w, stat_id, stats, d)
    local entry = STAT_MAP[stat_id]
    if not entry then return nil end
    local val_str = entry.value(stats)
    local lbl_str = entry.label_fn and entry.label_fn(stats) or entry.label
    return FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = d.card_h },
        bordersize = 1,
        color      = _CLR_CARD_BDR,
        background = Blitbuffer.COLOR_WHITE,
        radius     = d.corner_r,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = d.card_h },
            VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text    = val_str,
                    face    = Font:getFace("smallinfofont", d.val_fs),
                    bold    = true,
                    fgcolor = _CLR_TEXT_BLK,
                },
                TextWidget:new{
                    text    = lbl_str,
                    face    = Font:getFace("cfont", d.lbl_fs),
                    fgcolor = CLR_TEXT_SUB,
                },
            },
        },
    }
end

-- Flat mode: no border, tinted background, content centred.
local _CLR_FLAT_BG = Blitbuffer.gray(0.08)
local function buildStatFlatWidget(card_w, stat_id, stats, d)
    local entry = STAT_MAP[stat_id]
    if not entry then return nil end
    local val_str = entry.value(stats)
    local lbl_str = entry.label_fn and entry.label_fn(stats) or entry.label
    return FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = d.card_h },
        bordersize = 0,
        background = _CLR_FLAT_BG,
        radius     = d.corner_r,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = d.card_h },
            VerticalGroup:new{ align = "center",
                TextWidget:new{
                    text    = val_str,
                    face    = Font:getFace("smallinfofont", d.val_fs),
                    bold    = true,
                    fgcolor = _CLR_TEXT_BLK,
                },
                TextWidget:new{
                    text    = lbl_str,
                    face    = Font:getFace("cfont", d.lbl_fs),
                    fgcolor = CLR_TEXT_SUB,
                },
            },
        },
    }
end
local function buildStatListCell(cell_w, stat_id, stats, show_sep, d)
    local entry = STAT_MAP[stat_id]
    if not entry then return nil end
    local val_str = entry.value(stats)
    local lbl_str = entry.label_fn and entry.label_fn(stats) or entry.label

    local card = FrameContainer:new{
        dimen      = Geom:new{ w = cell_w, h = d.card_h },
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = d.card_h },
            VerticalGroup:new{ align = "left",
                TextWidget:new{
                    text    = val_str,
                    face    = Font:getFace("smallinfofont", d.val_fs),
                    bold    = true,
                    fgcolor = _CLR_TEXT_BLK,
                },
                TextWidget:new{
                    text    = lbl_str,
                    face    = Font:getFace("cfont", d.lbl_fs),
                    fgcolor = CLR_TEXT_SUB,
                },
            },
        },
    }

    local og = OverlapGroup:new{
        dimen = Geom:new{ w = cell_w, h = d.card_h },
        card,
    }
    if show_sep then
        local sep = LineWidget:new{
            dimen      = Geom:new{ w = d.sep_w, h = d.card_h },
            background = _CLR_CARD_BDR,
        }
        sep.overlap_offset = { cell_w - d.sep_w, 0 }
        og[#og+1] = sep
    end
    return og
end

local function openReaderProgress()
    UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
local M = {}

M.id         = "reading_stats"
M.name       = _("Reading Stats")
M.label      = nil   -- no section label; uses own top-padding
M.default_on = false
M.MAX_ITEMS  = RS_N_COLS   -- public field instead of getMaxItems() function

function M.isEnabled(pfx)
    return G_reader_settings:readSetting(pfx .. "reading_stats_enabled") == true
end

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. "reading_stats_enabled", on)
end

function M.getCountLabel(pfx)
    local n      = #(G_reader_settings:readSetting(pfx .. "reading_stats_items") or {})
    local max_rs = M.MAX_ITEMS
    local rem    = max_rs - n
    if n == 0   then return nil end
    if rem <= 0 then return string.format("(%d/%d — at limit)", n, max_rs) end
    return string.format("(%d/%d — %d left)", n, max_rs, rem)
end

function M.getStatLabel(id)
    return STAT_MAP[id] and STAT_MAP[id].display_label or id
end

function M.getCardHeight()
    return math.floor(_BASE_RS_CARD_H * Config.getModuleScale())
end

M.STAT_POOL = STAT_POOL

function M.invalidateCache()
    _stats_cache     = nil
    _stats_cache_day = nil  -- force re-fetch even within the same day
end

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end
    local stat_ids = G_reader_settings:readSetting(ctx.pfx .. "reading_stats_items") or {}

    -- Compute all scaled dims once for this render pass.
    local scale     = Config.getModuleScale("reading_stats", ctx and ctx.pfx)
    local text_scale = scale * (Config.getRSTextScalePct() / 100)
    local d = {
        card_h   = math.floor(_BASE_RS_CARD_H   * scale),
        gap      = math.max(2, math.floor(_BASE_RS_GAP      * scale)),
        corner_r = math.floor(_BASE_RS_CORNER_R  * scale),
        val_fs   = math.max(8, math.floor(_BASE_RS_VAL_FS   * text_scale)),
        lbl_fs   = math.max(6, math.floor(_BASE_RS_LBL_FS   * text_scale)),
        sep_w    = math.max(1, math.floor(_BASE_RS_SEP_W    * scale)),
        ph_fs    = math.max(8, math.floor(_BASE_RS_PH_FS    * scale)),
    }

    -- Show a placeholder when enabled but no stats have been selected yet.
    if #stat_ids == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            TextWidget:new{
                text    = _("No stats selected"),
                face    = Font:getFace("smallinfofont", d.ph_fs),
                fgcolor = CLR_TEXT_SUB,
                width   = w - PAD * 2,
            },
        }
    end

    local n      = math.min(#stat_ids, RS_N_COLS)
    local stats  = getStats(ctx.db_conn)
    local mode   = getType(ctx.pfx)
    local row    = HorizontalGroup:new{ align = "center" }

    if mode == "list" then
        local cell_w = math.floor(w / n)
        for i = 1, n do
            local cell = buildStatListCell(cell_w, stat_ids[i], stats, i < n, d)
                      or OverlapGroup:new{
                             dimen = Geom:new{ w = cell_w, h = d.card_h },
                         }
            local tappable = InputContainer:new{
                dimen = Geom:new{ w = cell_w, h = d.card_h },
                [1]   = cell,
            }
            tappable.ges_events = {
                TapStatCard = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
            }
            function tappable:onTapStatCard() openReaderProgress(); return true end
            row[#row+1] = tappable
        end

        return FrameContainer:new{
            dimen      = Geom:new{ w = w, h = d.card_h },
            bordersize = 0, padding = 0,
            row,
        }
    else
        -- Cards / Flat mode: rounded cards with gaps between them.
        -- "flat" = no border, tinted background; "cards" = bordered white.
        local avail_w = w - PAD * 2
        local card_w  = math.floor((avail_w - d.gap * (n - 1)) / n)
        for i = 1, n do
            local card
            if mode == "flat" then
                card = buildStatFlatWidget(card_w, stat_ids[i], stats, d)
            else
                card = buildStatCardWidget(card_w, stat_ids[i], stats, d)
            end
            card = card or FrameContainer:new{
                dimen = Geom:new{ w = card_w, h = d.card_h },
                bordersize = 0, padding = 0,
            }
            local tappable = InputContainer:new{
                dimen = Geom:new{ w = card_w, h = d.card_h },
                [1]   = card,
            }
            tappable.ges_events = {
                TapStatCard = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
            }
            function tappable:onTapStatCard() openReaderProgress(); return true end
            if i > 1 then row[#row+1] = HorizontalSpan:new{ width = d.gap } end
            row[#row+1] = tappable
        end

        return FrameContainer:new{
            dimen      = Geom:new{ w = w, h = d.card_h },
            bordersize = 0, padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = d.card_h },
                row,
            },
        }
    end
end

function M.getHeight(_ctx)
    local card_h = math.floor(_BASE_RS_CARD_H * Config.getModuleScale("reading_stats", _ctx and _ctx.pfx))
    return card_h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("reading_stats", pfx) end,
        set          = function(v) Config.setModuleScale(v, "reading_stats", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end
function M.getMenuItems(ctx_menu)
    local pfx         = ctx_menu.pfx
    local _UIManager  = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage
    local SortWidget  = ctx_menu.SortWidget
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._
    local items_key   = pfx .. "reading_stats_items"
    local MAX_RS      = M.MAX_ITEMS

    local function getItems() return G_reader_settings:readSetting(items_key) or {} end
    local function isSelected(id)
        for _, v in ipairs(getItems()) do if v == id then return true end end; return false
    end
    local function toggleItem(id)
        local cur = getItems(); local new_items = {}; local found = false
        for _, v in ipairs(cur) do if v == id then found = true else new_items[#new_items+1] = v end end
        if not found then
            if #cur >= MAX_RS then
                _UIManager:show(InfoMessage:new{
                    text = string.format(_lc("Maximum %d stats per row. Remove one first."), MAX_RS), timeout = 2 })
                return
            end
            new_items[#new_items+1] = id
        end
        G_reader_settings:saveSetting(items_key, new_items); refresh()
    end

    local items = {
        {
            text           = _lc("Type"),
            sub_item_table = {
                {
                    text           = _lc("Cards"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "cards" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_TYPE, "cards")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Flat"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "flat" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_TYPE, "flat")
                        refresh()
                    end,
                },
                {
                    text           = _lc("List"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "list" end,
                    callback       = function()
                        G_reader_settings:saveSetting(pfx .. SETTING_TYPE, "list")
                        refresh()
                    end,
                },
            },
        },
        _makeScaleItem(ctx_menu),
        Config.makeScaleItem({
            text_func     = function()
                local pct = Config.getRSTextScalePct()
                return pct == Config.RS_TEXT_SCALE_DEF
                    and _lc("Text Size")
                    or  string.format(_lc("Text Size — %d%%"), pct)
            end,
            title         = _lc("Text Size"),
            info          = _lc("Size of the text inside the stat cards.\nDoes not affect card size or padding.\n100% is the default size."),
            get           = function() return Config.getRSTextScalePct() end,
            set           = function(pct) Config.setRSTextScalePct(pct) end,
            refresh       = ctx_menu.refresh,
            value_min     = Config.RS_TEXT_SCALE_MIN,
            value_max     = Config.RS_TEXT_SCALE_MAX,
            value_step    = Config.RS_TEXT_SCALE_STEP,
            default_value = Config.RS_TEXT_SCALE_DEF,
        }),
        { text = _lc("Arrange"), keep_menu_open = true, separator = true, callback = function()
            local rs_ids = getItems()
            if #rs_ids < 2 then
                _UIManager:show(InfoMessage:new{ text = _lc("Add at least 2 stats to arrange."), timeout = 2 }); return
            end
            local sort_items = {}
            for _, id in ipairs(rs_ids) do
                sort_items[#sort_items+1] = { text = M.getStatLabel(id), orig_item = id }
            end
            _UIManager:show(SortWidget:new{ title = _lc("Arrange Reading Stats"), covers_fullscreen = true,
                item_table = sort_items, callback = function()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                    G_reader_settings:saveSetting(items_key, new_order); refresh()
                end })
        end },
    }

    -- Use pre-sorted pool (sorted once at module load, not per menu open).
    for _, entry in ipairs(_sorted_pool) do
        local _sid = entry.id; local _lbl = entry.label
        items[#items+1] = {
            text_func = function()
                if isSelected(_sid) then return _lbl end
                local rem = MAX_RS - #getItems()
                if rem <= 0 then return _lbl .. "  (0 left)" end
                if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                return _lbl
            end,
            checked_func   = function() return isSelected(_sid) end,
            keep_menu_open = true,
            callback       = function() toggleItem(_sid) end,
        }
    end
    return items
end

return M