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
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext
local Config          = require("sui_config")

local UI      = require("sui_core")
local SUISettings = require("sui_store")
local SUIStyle    = require("sui_style")
local StreakFreeze = require("sui_streak")
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local PAD     = UI.PAD
local MOD_GAP = UI.MOD_GAP
local LABEL_H = UI.LABEL_H

local _CLR_TEXT_BLK  = Blitbuffer.COLOR_BLACK
local _CLR_CARD_BDR  = Blitbuffer.gray(0.72)

local _BASE_RS_CORNER_R = Screen:scaleBySize(12)
local _BASE_RS_GAP      = Screen:scaleBySize(12)
local _BASE_RS_CARD_H   = Screen:scaleBySize(96)
local _BASE_RS_VAL_FS   = SUIStyle.FS_TITLE     -- 22: stat value (large numeric)
local _BASE_RS_LBL_FS   = SUIStyle.FS_DETAIL    -- 15: stat label
local _BASE_RS_SEP_W    = Screen:scaleBySize(1)
local _BASE_RS_PH_FS    = SUIStyle.FS_BODY      -- 18: placeholder text

local RS_N_COLS    = 7  -- max columns — not a dimension, no scaling needed

local SETTING_TYPE  = "reading_stats_type"   -- suffix: pfx .. "reading_stats_type"
local SETTING_ALIGN = "reading_stats_align"  -- suffix: pfx .. "reading_stats_align"

local function getType(pfx)
    return SUISettings:readSetting(pfx .. SETTING_TYPE) or "cards"
end

local function getAlign(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_ALIGN)
    if v == "left" or v == "right" or v == "center" then return v end
    return "center"
end

local function _getItems(pfx)
    local saved = SUISettings:readSetting((pfx or "simpleui_hs_") .. "reading_stats_items")
    if type(saved) ~= "table" or #saved == 0 then return { "total_books", "today_time", "streak" } end
    return saved
end

local function alignLabel(align)
    if align == "left"  then return _("Left")  end
    if align == "right" then return _("Right") end
    return _("Center")
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
    week_time   = { display_label = _("This week — Time"),  value = function(s) return fmtTime(s.week_secs) end,    label = _("of reading this week") },
    week_pages  = { display_label = _("This week — Pages"), value = function(s) return tostring(s.week_pages) end,  label = _("pages read this week") },
    avg_time    = { display_label = _("Daily avg — Time"),  value = function(s) return fmtTime(s.avg_secs) end,     label = _("daily avg (7 days)") },
    avg_pages   = { display_label = _("Daily avg — Pages"), value = function(s) return tostring(s.avg_pages) end,   label = _("pages/day (7 days)") },
    month_time  = { display_label = _("This month — Time"), value = function(s) return fmtTime(s.month_secs) end,   label = _("of reading this month") },
    month_pages = { display_label = _("This month — Pages"),value = function(s) return tostring(s.month_pages) end, label = _("pages read this month") },
    total_time  = { display_label = _("All time — Time"),   value = function(s) return fmtTime(s.total_secs) end,   label = _("of reading, all time") },
    total_books = { display_label = _("All time — Books"),  value = function(s) return tostring(s.total_books) end, label = _("books finished") },
    streak      = { display_label = _("Streak"),            value = function(s) return s.streak > 0 and tostring(s.streak) or "—" end,
                    label_fn = function(s) return s.streak == 1 and _("day streak") or (s.streak == 0 and _("no streak") or _("days streak")) end },
}

local STAT_POOL = { "today_time","today_pages","week_time","week_pages","avg_time","avg_pages","month_time","month_pages","total_time","total_books","streak" }

-- Maps each stat_id to the _changed category it belongs to (from SP.get()).
-- Used by updateStats() to skip cards whose underlying data did not change.
--   timeseries: all time/page counters updated by fetchTimeSeries
--   streak:     streak value from fetchStreak (separate CTE)
--   books:      books_year / books_total from the sidecar scan
local STAT_CHANGED_CAT = {
    today_time  = "timeseries",
    today_pages = "timeseries",
    week_time   = "timeseries",
    week_pages  = "timeseries",
    avg_time    = "timeseries",
    avg_pages   = "timeseries",
    month_time  = "timeseries",
    month_pages = "timeseries",
    total_time  = "timeseries",
    streak      = "streak",
    total_books = "books",
}

-- Pre-sort the pool alphabetically by display label — done once at module load,
-- not on every menu open.
local _sorted_pool = {}
for _, sid in ipairs(STAT_POOL) do
    _sorted_pool[#_sorted_pool+1] = { id = sid, label = STAT_MAP[sid].display_label }
end
table.sort(_sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)

-- ---------------------------------------------------------------------------
-- Stat widget builders
-- ---------------------------------------------------------------------------

-- Streak value widget: icon (dark grey) + space + number (black), side by side.
-- To change icon colour: edit _STREAK_ICON_CLR.
-- To change spacing:     edit _STREAK_ICON_GAP.
local _STREAK_ICON     = ""            -- U+F490 Nerd Fonts flame
local _STREAK_ICON_CLR = Blitbuffer.gray(0.80)  -- dark grey; 0=black, 1=white
local _STREAK_ICON_GAP = 6                   -- pixels between icon and number

local function makeStreakValWidget(val_str, d, clr_blk)
    return HorizontalGroup:new{ align = "center",
        UI.makeColoredText{
            text    = _STREAK_ICON,
            face    = d.face_val,
            fgcolor = _STREAK_ICON_CLR,
        },
        HorizontalSpan:new{ width = _STREAK_ICON_GAP },
        UI.makeColoredText{
            text    = val_str,
            face    = d.face_val,
            bold    = true,
            fgcolor = clr_blk or _CLR_TEXT_BLK,
        },
    }
end

local function _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, max_w)
    local entry = STAT_MAP[stat_id]
    if not entry then return VerticalGroup:new{} end
    local val_str = entry.value(stats)
    local lbl_str = entry.label_fn and entry.label_fn(stats) or entry.label
    local actual_max_w = max_w and math.max(1, max_w - Screen:scaleBySize(8)) or nil
    return VerticalGroup:new{ align = align,
        stat_id == "streak" and stats.streak >= 5
            and makeStreakValWidget(val_str, d, clr_blk)
            or  UI.makeColoredText{ 
                    text = val_str, 
                    face = d.face_val, 
                    bold = true, 
                    fgcolor = clr_blk,
                    max_width = actual_max_w,
                    truncate_with_ellipsis = true
                },
        UI.makeColoredText{
            text    = lbl_str,
            face    = d.face_lbl,
            fgcolor = clr_sub,
            max_width = actual_max_w,
            truncate_with_ellipsis = true,
        },
    }
end

-- Cards mode: rounded border, content aligned inside the card.
-- `d` is the scaled-dims table produced once per M.build() call.

local function buildStatCardWidget(card_w, stat_id, stats, d, align, colors, transparent)
    local clr_blk = colors and colors.blk or _CLR_TEXT_BLK
    local clr_sub = colors and colors.sub or CLR_TEXT_SUB
    local cc = CenterContainer:new{
        dimen = Geom:new{ w = card_w, h = d.card_h },
        _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, card_w),
    }
    local fc = FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = d.card_h },
        bordersize = SUIStyle.BORDER_SZ,
        color      = _CLR_CARD_BDR,
        background = not transparent and Blitbuffer.COLOR_WHITE or nil,
        radius     = d.corner_r,
        padding    = 0,
        cc,
    }
    local update_fn = function(new_stats)
        cc[1] = _buildCardInner(stat_id, new_stats, d, align, clr_blk, clr_sub, card_w)
    end
    return fc, update_fn
end

-- Flat mode: no border, tinted background, content aligned.
local _CLR_FLAT_BG = Blitbuffer.gray(0.08)
local function buildStatFlatWidget(card_w, stat_id, stats, d, align, colors)
    local clr_blk = colors and colors.blk or _CLR_TEXT_BLK
    local clr_sub = colors and colors.sub or CLR_TEXT_SUB
    local cc = CenterContainer:new{
        dimen = Geom:new{ w = card_w, h = d.card_h },
        _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, card_w),
    }
    local fc = FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = d.card_h },
        bordersize = 0,
        background = _CLR_FLAT_BG,
        radius     = d.corner_r,
        padding    = 0,
        cc,
    }
    local update_fn = function(new_stats)
        cc[1] = _buildCardInner(stat_id, new_stats, d, align, clr_blk, clr_sub, card_w)
    end
    return fc, update_fn
end
local function buildStatListCell(cell_w, stat_id, stats, show_sep, d, align, colors)
    local clr_blk = colors and colors.blk or _CLR_TEXT_BLK
    local clr_sub = colors and colors.sub or CLR_TEXT_SUB

    local cc = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = d.card_h },
        _buildCardInner(stat_id, stats, d, align, clr_blk, clr_sub, cell_w),
    }
    local card = FrameContainer:new{
        dimen      = Geom:new{ w = cell_w, h = d.card_h },
        bordersize = 0,
        padding    = 0,
        cc,
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
    local update_fn = function(new_stats)
        cc[1] = _buildCardInner(stat_id, new_stats, d, align, clr_blk, clr_sub, cell_w)
    end
    return og, update_fn
end

local function openReadingInsights()
    local ok, SW = pcall(require, "sui_stats_windows")
    if ok and SW and SW.showReadingInsightsWindow then
        if SW.showLoadingNotice then SW.showLoadingNotice() end
        SW.showReadingInsightsWindow()
    else
        -- Fallback: open the built-in stats plugin if sui_stats_windows is unavailable.
        UIManager:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
    end
end

--- Opens the Streak Manager window (streak card tap). Returns true on
--- success so callers can fall through to openReadingInsights() as a
--- best-effort fallback if sui_stats_windows turns out to be unavailable —
--- mirrors the same fallback shape already used for the total_books ▸
--- showFinishedBooksDialog routing just above/below this function.
local function openStreakManager()
    local ok, SW = pcall(require, "sui_stats_windows")
    if ok and SW and SW.showStreakManagerWindow then
        if SW.showLoadingNotice then SW.showLoadingNotice() end
        SW.showStreakManagerWindow()
        return true
    end
    return false
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
    return SUISettings:readSetting(pfx .. "reading_stats_enabled") == true
end

function M.setEnabled(pfx, on)
    SUISettings:saveSetting(pfx .. "reading_stats_enabled", on)
end

-- Public accessor for the selected stat-card ids, applying the same
-- { "total_books", "today_time", "streak" } default used everywhere else in
-- this module. Callers outside this file (sui_homescreen's needs_books
-- check) must use this instead of reading "reading_stats_items" directly —
-- a raw read returns nil/empty on a fresh install (setting never saved yet),
-- which does NOT mean "no items", it means "the default three, including
-- total_books". See the fix for the "Books Finished" card only populating
-- when Reading Goals is also enabled.
M.getItems = _getItems

function M.getCountLabel(pfx)
    local n      = #_getItems(pfx)
    local max_rs = M.MAX_ITEMS
    local rem    = max_rs - n
    if n == 0   then return nil end
    if rem <= 0 then return string.format(_("(%d/%d — at limit)"), n, max_rs) end
    return string.format(N_("(%d/%d — %d left)", "(%d/%d — %d left)", rem), n, max_rs, rem)
end

function M.getStatLabel(id)
    return STAT_MAP[id] and STAT_MAP[id].display_label or id
end

function M.getCardHeight()
    return math.floor(_BASE_RS_CARD_H * Config.getModuleScale())
end

M.STAT_POOL = STAT_POOL

function M.invalidateCache()
    -- Delegate to the shared provider — it owns the cache now.
    local SP = package.loaded["desktop_modules/module_stats_provider"]
    if SP then SP.invalidate() end
end

function M.build(w, ctx)
    if not M.isEnabled(ctx.pfx) then return nil end
    local stat_ids = _getItems(ctx.pfx)

    -- Compute all scaled dims once for this render pass.
    local scale     = Config.getModuleScale("reading_stats", ctx and ctx.pfx)
    local text_scale = scale * (Config.getRSTextScalePct() / 100)
    local _val_fs = math.max(8, math.floor(_BASE_RS_VAL_FS * text_scale))
    local _lbl_fs = math.max(6, math.floor(_BASE_RS_LBL_FS * text_scale))
    local _ph_fs  = math.max(8, math.floor(_BASE_RS_PH_FS  * scale))
    local d = {
        card_h   = math.floor(_BASE_RS_CARD_H   * scale),
        gap      = math.max(2, math.floor(_BASE_RS_GAP      * scale)),
        corner_r = math.floor(_BASE_RS_CORNER_R  * scale),
        val_fs   = _val_fs,
        lbl_fs   = _lbl_fs,
        sep_w    = math.max(1, math.floor(_BASE_RS_SEP_W    * scale)),
        ph_fs    = _ph_fs,
        -- Pre-resolved font faces — shared by all card builders, avoids
        -- repeated Font:getFace calls inside the per-card build loop.
        face_val = Font:getFace(SUIStyle.FACE_REGULAR, _val_fs),
        face_lbl = Font:getFace(SUIStyle.FACE_REGULAR,         _lbl_fs),
        face_ph  = Font:getFace(SUIStyle.FACE_REGULAR, _ph_fs),
    }

    -- Theme: when fg is set use it for all text; otherwise fall back to module defaults.
    local ok_ss, SUIStyle  = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local _CLR_TEXT_BLK_EFF = _theme_fg or _CLR_TEXT_BLK
    local CLR_TEXT_SUB_EFF  = _theme_secondary or _theme_fg or CLR_TEXT_SUB

    -- Show a placeholder when enabled but no stats have been selected yet.
    if #stat_ids == 0 then
        local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
        local ph_text = hold_on and _("No stats selected  —  long press to configure")
                                 or _("No stats selected")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            UI.makeColoredText{
                text    = ph_text,
                face    = d.face_ph,
                fgcolor = CLR_TEXT_SUB_EFF,
                width   = w - PAD * 2,
            },
        }
    end

    local n    = math.min(#stat_ids, RS_N_COLS)
    -- Stats are pre-fetched by StatsProvider (via _buildCtx) and passed in
    -- ctx.stats — no DB access or cache logic here.
    local sp   = ctx.stats or {}
    local stats = {
        today_secs  = sp.today_secs  or 0,
        today_pages = sp.today_pages or 0,
        week_secs   = sp.week_secs   or 0,
        week_pages  = sp.week_pages  or 0,
        avg_secs    = sp.avg_secs    or 0,
        avg_pages   = sp.avg_pages   or 0,
        month_secs  = sp.month_secs  or 0,
        month_pages = sp.month_pages or 0,
        total_secs  = sp.total_secs  or 0,
        total_books = sp.books_total or 0,
        streak      = sp.streak      or 0,
    }
    if sp.db_conn_fatal and ctx then ctx.db_conn_fatal = true end
    local mode  = getType(ctx.pfx)
    local align = getAlign(ctx.pfx)
    local row    = HorizontalGroup:new{ align = "center" }

    local update_funcs = {}

    if mode == "list" then
        local cell_w = math.floor(w / n)
        local colors = { blk = _CLR_TEXT_BLK_EFF, sub = CLR_TEXT_SUB_EFF }
        for i = 1, n do
            local cell, update_fn = buildStatListCell(cell_w, stat_ids[i], stats, i < n, d, align, colors)
            if not cell then
                cell = OverlapGroup:new{ dimen = Geom:new{ w = cell_w, h = d.card_h } }
            end
            if update_fn then table.insert(update_funcs, { fn = update_fn, id = stat_ids[i] }) end
            row[#row+1] = cell
        end

        -- Single tappable over the whole row — all cards open the same screen,
        -- so one InputContainer + one GestureRange + one handler replaces N of each.
        local frame = FrameContainer:new{
            dimen      = Geom:new{ w = w, h = d.card_h },
            bordersize = 0, padding = 0,
            row,
        }
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            [1]   = frame,
        }
        tappable.ges_events = {
            TapStatCard = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
        }
        function tappable:onTapStatCard(_, ges)
            if ges and ges.pos and self.dimen then
                local idx = math.floor((ges.pos.x - self.dimen.x) / cell_w) + 1
                if idx >= 1 and idx <= n and stat_ids[idx] == "total_books" then
                    local ok, SW = pcall(require, "sui_stats_windows")
                    if ok and SW and SW.showFinishedBooksDialog then
                        SW.showFinishedBooksDialog()
                        return true
                    end
                    -- SW unavailable: fall through to insights as best-effort fallback
                elseif idx >= 1 and idx <= n and stat_ids[idx] == "streak" then
                    if openStreakManager() then return true end
                    -- SW unavailable: fall through to insights as best-effort fallback
                end
            end
            openReadingInsights()
            return true
        end
        tappable._rs_update_funcs = update_funcs
        return tappable
    else
        -- Cards / Flat mode: rounded cards with gaps between them.
        -- "flat" = no border, tinted background; "cards" = bordered white.
        local avail_w = w - PAD * 2
        local card_w  = math.floor((avail_w - d.gap * (n - 1)) / n)
        local row_w   = n * card_w + math.max(0, n - 1) * d.gap
        local offset_x = math.floor((w - row_w) / 2)
        local colors  = { blk = _CLR_TEXT_BLK_EFF, sub = CLR_TEXT_SUB_EFF }
        for i = 1, n do
            local card, update_fn
            if mode == "flat" then
                card, update_fn = buildStatFlatWidget(card_w, stat_ids[i], stats, d, align, colors)
            elseif mode == "cards_transparent" then
                card, update_fn = buildStatCardWidget(card_w, stat_ids[i], stats, d, align, colors, true)
            else
                card, update_fn = buildStatCardWidget(card_w, stat_ids[i], stats, d, align, colors, false)
            end
            card = card or FrameContainer:new{
                dimen = Geom:new{ w = card_w, h = d.card_h },
                bordersize = 0, padding = 0,
            }
            if update_fn then table.insert(update_funcs, { fn = update_fn, id = stat_ids[i] }) end
            if i > 1 then row[#row+1] = HorizontalSpan:new{ width = d.gap } end
            row[#row+1] = card
        end

        -- Single tappable over the whole row — one InputContainer + one
        -- GestureRange + one handler replaces N of each (N ≤ RS_N_COLS = 3).
        local inner = CenterContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            row,
        }
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = w, h = d.card_h },
            [1]   = FrameContainer:new{
                dimen      = Geom:new{ w = w, h = d.card_h },
                bordersize = 0, padding = 0,
                inner,
            },
        }
        tappable.ges_events = {
            TapStatCard = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
        }
        function tappable:onTapStatCard(_, ges)
            if ges and ges.pos and self.dimen then
                local dx = ges.pos.x - self.dimen.x - offset_x
                if dx >= 0 then
                    local step = card_w + d.gap
                    local idx = math.floor(dx / step) + 1
                    if idx >= 1 and idx <= n and (dx % step) <= card_w then
                        if stat_ids[idx] == "total_books" then
                            local ok, SW = pcall(require, "sui_stats_windows")
                            if ok and SW and SW.showFinishedBooksDialog then
                                SW.showFinishedBooksDialog()
                                return true
                            end
                            -- SW unavailable: fall through to insights as best-effort fallback
                        elseif stat_ids[idx] == "streak" then
                            if openStreakManager() then return true end
                            -- SW unavailable: fall through to insights as best-effort fallback
                        end
                    end
                end
            end
            openReadingInsights()
            return true
        end
        tappable._rs_update_funcs = update_funcs
        return tappable
    end
end

function M.updateStats(widget, ctx)
    if not widget or not widget._rs_update_funcs then return false end
    local sp = ctx.stats or {}
    -- _changed tells us which categories were actually re-fetched this cycle.
    -- When absent (e.g. older SP version or SP.invalidate() full reset), treat
    -- everything as changed so we don't silently skip any card.
    local changed = sp._changed  -- may be nil
    local stats = {
        today_secs  = sp.today_secs  or 0,
        today_pages = sp.today_pages or 0,
        week_secs   = sp.week_secs   or 0,
        week_pages  = sp.week_pages  or 0,
        avg_secs    = sp.avg_secs    or 0,
        avg_pages   = sp.avg_pages   or 0,
        month_secs  = sp.month_secs  or 0,
        month_pages = sp.month_pages or 0,
        total_secs  = sp.total_secs  or 0,
        total_books = sp.books_total or 0,
        streak      = sp.streak      or 0,
    }
    local any_updated = false
    for _, entry in ipairs(widget._rs_update_funcs) do
        -- Skip this card if we know its category did not change this cycle.
        if changed then
            local cat = STAT_CHANGED_CAT[entry.id]
            if cat and changed[cat] == false then
                -- This field was preserved from cache — value is identical,
                -- no need to rebuild the card's TextWidgets or mark it dirty.
                goto continue
            end
        end
        entry.fn(stats)
        any_updated = true
        ::continue::
    end
    -- Return true only if at least one card was actually updated, so the caller
    -- can skip setDirty entirely when nothing changed.
    return any_updated
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
    local N_lc        = ctx_menu.N_
    local items_key   = pfx .. "reading_stats_items"
    local MAX_RS      = M.MAX_ITEMS

    local function getItems() return _getItems(pfx) end
    local function isSelected(id)
        for _, v in ipairs(getItems()) do if v == id then return true end end; return false
    end
    local function toggleItem(id)
        local cur = getItems(); local new_items = {}; local found = false
        for _, v in ipairs(cur) do if v == id then found = true else new_items[#new_items+1] = v end end
        if not found then
            if #cur >= MAX_RS then
                _UIManager:show(InfoMessage:new{
                    text = string.format(N_lc("The maximum of %d stat per row has been reached. Remove one first.",
                           "The maximum of %d stats per row has been reached. Remove one first.", MAX_RS), MAX_RS), timeout = 2 })
                return
            end
            new_items[#new_items+1] = id
        end
        SUISettings:saveSetting(items_key, new_items); refresh()
    end

    local items = {
        {
            text = _lc("Items"), keep_menu_open = true, separator = true,
            callback = function()
                local rs_ids = getItems()
                if #rs_ids < 2 then
                    _UIManager:show(InfoMessage:new{ text = _lc("Add at least 2 stats to arrange."), timeout = 2 }); return
                end
                local sort_items = {}
                for _, id in ipairs(rs_ids) do
                    sort_items[#sort_items+1] = { text = M.getStatLabel(id), orig_item = id }
                end
                local function on_save()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                    SUISettings:saveSetting(items_key, new_order); refresh()
                end
                _UIManager:show(SortWidget:new{ title = _lc("Arrange Reading Stats"), covers_fullscreen = true,
                    item_table = sort_items, callback = on_save })
            end,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("sui_window")
                return SUIWindow.ListRow{
                    title        = _lc("Items"),
                    subtitle     = function()
                        local rs_ids = getItems()
                        if #rs_ids == 0 then return _lc("No items selected.") end
                        local names = {}
                        for _, id in ipairs(rs_ids) do
                            names[#names + 1] = M.getStatLabel(id)
                        end
                        return table.concat(names, "  ·  ")
                    end,
                    inner_w      = ctx.inner_w,
                    item_count   = function() return #getItems() end,
                    max_items    = M.MAX_ITEMS,
                    show_chevron = true,
                    on_tap       = function()
                    local rs_ids = getItems()
                    local sort_items = {}
                    for _, id in ipairs(rs_ids) do
                        sort_items[#sort_items+1] = { text = M.getStatLabel(id), orig_item = id }
                    end
                    
                    ctx.push("arrange", {
                            title = _lc("Items"),
                        items = sort_items,
                        empty_text = _lc("No items selected."),
                            item_count = function() return #getItems() end,
                            max_items  = M.MAX_ITEMS,
                        on_delete = function(item) end,
                        on_change = function(items_to_save)
                            local new_order = {}
                            for _, it in ipairs(items_to_save) do new_order[#new_order+1] = it.orig_item end
                            SUISettings:saveSetting(items_key, new_order)
                            refresh()
                        end,
                            footer_text = _lc("Add Item"),
                            footer_action = function(ctx2)
                                local picker_items = {}
                                for _, entry in ipairs(_sorted_pool) do
                                    if not isSelected(entry.id) then
                                        local _id = entry.id
                                        local _label = entry.label
                                        picker_items[#picker_items + 1] = {
                                            text   = _label,
                                            on_tap = function(picker_ctx)
                                                local cur = getItems()
                                                if #cur >= MAX_RS then
                                                    local InfoMessage = ctx_menu.InfoMessage or require("ui/widget/infomessage")
                                                    local uim = ctx_menu.UIManager or require("ui/uimanager")
                                                    local N_ = ctx_menu.N_ or require("sui_i18n").ngettext
                                                    uim:show(InfoMessage:new{
                                                        text = string.format(N_("The maximum of %d stat per row has been reached. Remove one first.",
                                                               "The maximum of %d stats per row has been reached. Remove one first.", MAX_RS), MAX_RS), timeout = 2,
                                                    })
                                                    return
                                                end
                                                cur[#cur + 1] = _id
                                                SUISettings:saveSetting(items_key, cur)
                                                table.insert(sort_items, { text = _label, orig_item = _id })
                                                refresh()
                                                picker_ctx.pop()
                                                ctx2.repaint()
                                            end,
                                        }
                                    end
                                end
                                ctx2.push("item_picker", {
                                    title = _lc("Add Item"),
                                    items = picker_items,
                                })
                            end
                        })
                    end
                }
            end or nil,
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
            refresh       = refresh,
            value_min     = Config.RS_TEXT_SCALE_MIN,
            value_max     = Config.RS_TEXT_SCALE_MAX,
            value_step    = Config.RS_TEXT_SCALE_STEP,
            default_value = Config.RS_TEXT_SCALE_DEF,
        }),
        {
            text           = _lc("Style"),
            sub_item_table = {
                {
                    text           = _lc("Cards"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "cards" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_TYPE, "cards")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Cards - Transparent"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "cards_transparent" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_TYPE, "cards_transparent")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Flat"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "flat" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_TYPE, "flat")
                        refresh()
                    end,
                },
                {
                    text           = _lc("List"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getType(pfx) == "list" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_TYPE, "list")
                        refresh()
                    end,
                },
            },
        },
        {
            text_func  = function() return _lc("Alignment") end,
            value_func = function() return alignLabel(getAlign(pfx)) end,
            sub_item_table = {
                {
                    text           = _lc("Left"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getAlign(pfx) == "left"   end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_ALIGN, "left")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Center"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getAlign(pfx) == "center" end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_ALIGN, "center")
                        refresh()
                    end,
                },
                {
                    text           = _lc("Right"),
                    radio          = true,
                    keep_menu_open = true,
                    checked_func   = function() return getAlign(pfx) == "right"  end,
                    callback       = function()
                        SUISettings:saveSetting(pfx .. SETTING_ALIGN, "right")
                        refresh()
                    end,
                },
            },
        },
    }

    for _, entry in ipairs(_sorted_pool) do
        local _sid = entry.id; local _lbl = entry.label
        items[#items+1] = {
            text_func = function()
                if isSelected(_sid) then return _lbl end
                local rem = MAX_RS - #getItems()
                if rem <= 2 then return _lbl .. string.format(N_lc("  (%d left)", "  (%d left)", rem), rem) end
                return _lbl
            end,
            checked_func   = function() return isSelected(_sid) end,
            keep_menu_open = true,
            callback       = function() toggleItem(_sid) end,
            sui_hidden     = ctx_menu.is_sui or nil,
        }
    end

    items[#items+1] = {
        text_func      = function() return _lc("Streak Mode") end,
        value_func     = function()
            return StreakFreeze.isFreezeModeEnabled()
                and _lc("Freezes")
                or  _lc("Real streak only")
        end,
        sub_item_table = {
            {
                text           = _lc("Freezes"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return StreakFreeze.getStreakMode() == "freezes" end,
                callback       = function()
                    StreakFreeze.setStreakMode("freezes")
                    refresh()
                end,
            },
            {
                text           = _lc("Real streak only"),
                radio          = true,
                keep_menu_open = true,
                checked_func   = function() return StreakFreeze.getStreakMode() == "real" end,
                callback       = function()
                    StreakFreeze.setStreakMode("real")
                    refresh()
                end,
            },
        },
    }

    items[#items+1] = {
        text           = _lc("Update Stats Now"),
        separator      = true,
        keep_menu_open = true,
        callback       = function()
            local SP = package.loaded["desktop_modules/module_stats_provider"]
            if SP and SP.invalidate then SP.invalidate() end
            local SH = package.loaded["desktop_modules/module_books_shared"]
            if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
            local MC = package.loaded["desktop_modules/module_currently"]
            if MC and MC.invalidateCache then MC.invalidateCache() end
            local MCD = package.loaded["desktop_modules/module_coverdeck"]
            if MCD and MCD.invalidateCache then MCD.invalidateCache() end
            
            local HS = package.loaded["sui_homescreen"]
            if HS then
                HS._cached_books_state = nil
                HS._cfg_cache = nil
                if HS._instance then
                    HS._instance:_refreshImmediate(false)
                end
            end
            if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
            local InfoMessage = ctx_menu and ctx_menu.InfoMessage or require("ui/widget/infomessage")
            local UIM = ctx_menu and ctx_menu.UIManager or require("ui/uimanager")
            UIM:show(InfoMessage:new{ text = _lc("Stats updated successfully."), timeout = 2 })
        end,
    }

    return items
end

return M