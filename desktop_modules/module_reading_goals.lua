-- Reading Goals module: annual and daily progress bars with tap-to-set dialogs.
-- Supports two layouts: Default (bar + detail on separate lines) and Compact (single inline row).

local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local logger          = require("logger")
local Config          = require("folio_config")
local SH              = require("desktop_modules/module_books_shared")
local FolioTheme        = require("folio_theme")
local Theme           = FolioTheme.Theme

local UI           = require("folio_core")
local PAD          = UI.PAD

-- Default layout base dimensions (scaled at render time via _scaledDims)
local _BASE_ROW_FS  = Screen:scaleBySize(11)
local _BASE_SUB_FS  = Screen:scaleBySize(10)
local _BASE_ROW_H   = Screen:scaleBySize(16)
local _BASE_SUB_H   = Screen:scaleBySize(16)
local _BASE_SUB_GAP = Screen:scaleBySize(2)
local _BASE_ROW_GAP = Screen:scaleBySize(18)
local _BASE_BAR_H   = Screen:scaleBySize(12)
local _BASE_LBL_W   = Screen:scaleBySize(44)
local _BASE_COL_GAP = Screen:scaleBySize(8)
local _BASE_BOT_PAD = Screen:scaleBySize(18)

-- Compact layout fixed dimensions (not user-scalable)
local _COMPACT_ROW_FS  = Screen:scaleBySize(11)
local _COMPACT_SUB_FS  = Screen:scaleBySize(10)
local _COMPACT_ROW_H   = Screen:scaleBySize(20)
local _COMPACT_ROW_GAP = Screen:scaleBySize(8)
local _COMPACT_BAR_H   = Screen:scaleBySize(12)
local _COMPACT_LBL_W   = Screen:scaleBySize(44)
local _COMPACT_COL_GAP = Screen:scaleBySize(8)

local function _getYearStr() return os.date("%Y") end

-- Settings keys
local SHOW_ANNUAL = "folio_navbar_reading_goals_show_annual"
local SHOW_DAILY  = "folio_navbar_reading_goals_show_daily"
local LAYOUT_KEY  = "folio_navbar_reading_goals_layout"  -- "default" | "compact"

local function isCompact()    return G_reader_settings:readSetting(LAYOUT_KEY) == "compact" end
local function showAnnual()   return G_reader_settings:readSetting(SHOW_ANNUAL) ~= false end
local function showDaily()    return G_reader_settings:readSetting(SHOW_DAILY)  ~= false end

local function getAnnualGoal()     return G_reader_settings:readSetting("folio_navbar_reading_goal") or 0 end
local function getAnnualPhysical() return G_reader_settings:readSetting("folio_navbar_reading_goal_physical") or 0 end
local function getDailyGoalSecs()  return G_reader_settings:readSetting("folio_navbar_daily_reading_goal_secs") or 0 end

-- Formats seconds as "Xh Ym" / "Xh" / "Ym"
local function formatDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- Stats cache keyed by calendar date
local _stats_cache     = nil
local _stats_cache_day = nil

local function invalidateStatsCache()
    _stats_cache     = nil
    _stats_cache_day = nil
end

-- Counts books marked as read (summary.status = "complete") using DocSettings,
-- matching KOReader's own metadata format. Optional year_str filters by
-- summary.modified (string, unix time, or *t table). Result is cached per day.
local function _countMarkedRead(year_str)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return 0 end
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return 0 end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return 0 end

    local function modifiedInYear(summary)
        if not year_str then return true end
        local mod = summary and summary.modified
        if mod == nil then return false end
        if type(mod) == "number" then
            return os.date("%Y", mod) == year_str
        end
        if type(mod) == "string" then
            if #mod >= 4 and mod:sub(1, 4) == year_str then return true end
            local ok_t, t = pcall(function()
                return os.time({
                    year  = tonumber(mod:sub(1, 4)),
                    month = tonumber(mod:sub(6, 7)) or 1,
                    day   = tonumber(mod:sub(9, 10)) or 1,
                    hour  = 12,
                })
            end)
            if ok_t and t and os.date("%Y", t) == year_str then return true end
            return false
        end
        if type(mod) == "table" and mod.year then
            return tostring(mod.year) == year_str
        end
        return false
    end

    local count = 0
    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local ok_open, doc_settings = pcall(function() return DocSettings:open(fp) end)
            if ok_open and doc_settings then
                local ok_sum, summary = pcall(function() return doc_settings:readSetting("summary") end)
                if ok_sum and type(summary) == "table" and summary.status == "complete"
                    and modifiedInYear(summary) then
                    count = count + 1
                end
                pcall(function() doc_settings:close() end)
            end
        end
    end
    return count
end

-- Returns books_read, year_secs, today_secs. Uses shared DB connection if provided.
-- Caches results for the current calendar day.
local function getGoalStats(shared_conn)
    local today_key = os.date("%Y-%m-%d")
    if _stats_cache and _stats_cache_day == today_key then
        return _stats_cache[1], _stats_cache[2], _stats_cache[3]
    end

    local year_secs, today_secs = 0, 0
    local conn = shared_conn or Config.openStatsDB()
    if conn then
        local own_conn = not shared_conn
        local ok, err = pcall(function()
            local t           = os.date("*t")
            local year_start  = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
            local today_start = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)
            local stmt = conn:prepare([[
                SELECT
                    (SELECT sum(s) FROM (
                        SELECT sum(duration) AS s FROM page_stat
                        WHERE start_time >= ? GROUP BY id_book, page)),
                    (SELECT sum(s) FROM (
                        SELECT sum(duration) AS s FROM page_stat
                        WHERE start_time >= ? GROUP BY id_book, page));]])
            if stmt then
                local row = stmt:bind(year_start, today_start):step()
                year_secs  = tonumber(row and row[1]) or 0
                today_secs = tonumber(row and row[2]) or 0
                stmt:reset()
            end
        end)
        if not ok then logger.warn("folio: reading_goals: getGoalStats failed: " .. tostring(err)) end
        if own_conn then pcall(function() conn:close() end) end
    end

    local books_read = _countMarkedRead(os.date("%Y"))
    _stats_cache     = { books_read, year_secs, today_secs }
    _stats_cache_day = today_key
    return books_read, year_secs, today_secs
end

-- Computes all layout metrics for the default layout at the given scale factor.
-- Pre-resolves font faces (folio_theme) so buildGoalRow does not resolve fonts per render.
local function _scaledDims(scale)
    scale = scale or 1.0
    local row_h   = math.max(8,  math.floor(_BASE_ROW_H   * scale))
    local sub_h   = math.max(8,  math.floor(_BASE_SUB_H   * scale))
    local sub_gap = math.max(1,  math.floor(_BASE_SUB_GAP * scale))
    local bot_pad = math.max(4,  math.floor(_BASE_BOT_PAD * scale))
    local row_fs  = math.max(7,  math.floor(_BASE_ROW_FS  * scale))
    local sub_fs  = math.max(6,  math.floor(_BASE_SUB_FS  * scale))
    local bar_h   = math.max(8,  math.floor(_BASE_BAR_H   * scale))
    return {
        row_fs     = row_fs,
        sub_fs     = sub_fs,
        face_label = FolioTheme.faceUI(row_fs),
        face_pct   = FolioTheme.faceUI(row_fs),
        face_sub   = FolioTheme.faceUI(sub_fs),
        row_h      = row_h,
        sub_h      = sub_h,
        sub_gap    = sub_gap,
        row_gap    = math.max(4,  math.floor(_BASE_ROW_GAP * scale)),
        bar_h      = bar_h,
        lbl_w      = math.max(20, math.floor(_BASE_LBL_W   * scale)),
        col_gap    = math.max(2,  math.floor(_BASE_COL_GAP * scale)),
        bot_pad    = bot_pad,
        pct_w      = math.max(16, math.floor(Screen:scaleBySize(32) * scale)),
        min_bar_w  = math.max(20, math.floor(Screen:scaleBySize(40) * scale)),
        goal_row_h = row_h + sub_gap + sub_h + bot_pad,
    }
end

-- Compact layout faces + bar height (fixed pixel sizes, same as legacy compact mode).
local function _compactFaces()
    local row_fs = math.max(10, math.floor(_COMPACT_ROW_FS))
    local sub_fs = math.max(9, math.floor(_COMPACT_SUB_FS))
    local bar_h  = math.max(8, math.floor(_COMPACT_BAR_H))
    return {
        face_label = FolioTheme.faceUI(row_fs),
        face_pct   = FolioTheme.faceUI(row_fs),
        face_sub   = FolioTheme.faceUI(sub_fs),
        bar_h      = bar_h,
    }
end

local function buildThemedProgressBar(w, pct, bar_h)
    return SH.progressBar(w, pct, bar_h, Theme.SURFACE_HIGH, Theme.PRIMARY)
end

-- Returns total pixel height for n compact rows including inter-row gap
local function _compactRowsHeight(n)
    return n * _COMPACT_ROW_H + (n == 2 and _COMPACT_ROW_GAP or 0)
end

-- Builds a single inline row: Label [bar] XX%  detail
-- Used by the Compact layout. All elements are horizontally laid out and vertically centred.
local function buildCompactGoalRow(inner_w, label_str, pct, pct_str, detail_str, on_tap, fc)
    local LeftContainer  = require("ui/widget/container/leftcontainer")
    local RightContainer = require("ui/widget/container/rightcontainer")

    local ROW_H       = _COMPACT_ROW_H
    local LBL_BAR_GAP = _COMPACT_COL_GAP * 3
    local right_w        = math.floor(inner_w * 0.28)
    local PCT_W          = math.floor(right_w * 0.30)
    local PCT_DETAIL_GAP = math.floor(right_w * 0.15)
    local DETAIL_W       = right_w - PCT_W - PCT_DETAIL_GAP
    local BAR_PCT_GAP    = _COMPACT_COL_GAP
    local bar_w          = math.max(Screen:scaleBySize(40),
                               inner_w - _COMPACT_LBL_W - LBL_BAR_GAP - BAR_PCT_GAP - right_w)

    local function vcenter_left(child, col_w)
        return LeftContainer:new{ dimen = Geom:new{ w = col_w, h = ROW_H }, child }
    end
    local function vcenter_right(child, col_w)
        return RightContainer:new{ dimen = Geom:new{ w = col_w, h = ROW_H }, child }
    end

    local row = HorizontalGroup:new{
        align = "center",
        vcenter_left(TextWidget:new{
            text    = label_str,
            face    = fc.face_label,
            bold    = false,
            fgcolor = Theme.TEXT,
            width   = _COMPACT_LBL_W,
        }, _COMPACT_LBL_W),
        HorizontalSpan:new{ width = LBL_BAR_GAP },
        vcenter_left(buildThemedProgressBar(bar_w, pct, fc.bar_h), bar_w),
        HorizontalSpan:new{ width = BAR_PCT_GAP },
        vcenter_left(TextWidget:new{
            text    = pct_str,
            face    = fc.face_pct,
            bold    = true,
            fgcolor = Theme.TEXT,
            width   = PCT_W,
        }, PCT_W),
        HorizontalSpan:new{ width = PCT_DETAIL_GAP },
        vcenter_right(TextWidget:new{
            text      = detail_str,
            face      = fc.face_sub,
            fgcolor   = Theme.TEXT_MUTED,
            width     = DETAIL_W,
            alignment = "right",
        }, DETAIL_W),
    }

    local frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = inner_w, h = ROW_H },
        row,
    }

    if not on_tap then return frame end

    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = inner_w, h = ROW_H },
        [1]     = frame,
        _on_tap = on_tap,
    }
    tappable.ges_events = {
        TapGoalC = {
            GestureRange:new{ ges = "tap", range = function() return tappable.dimen end },
        },
    }
    function tappable:onTapGoalC()
        if self._on_tap then self._on_tap() end
        return true
    end
    return tappable
end

-- Builds a two-line goal row: label + bar + pct on the first line, detail text below.
-- Used by the Default layout. Accepts a pre-computed dims table from _scaledDims.
local function buildGoalRow(inner_w, label_str, pct, pct_str, detail_str, on_tap, d)
    local PCT_W       = d.pct_w
    local BAR_PCT_GAP = d.col_gap
    local bar_w       = math.max(d.min_bar_w,
                            inner_w - d.lbl_w - d.col_gap - BAR_PCT_GAP - PCT_W)

    local block = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            TextWidget:new{
                text    = label_str,
                face    = d.face_label,
                bold    = false,
                fgcolor = Theme.TEXT,
                width   = d.lbl_w,
            },
            HorizontalSpan:new{ width = d.col_gap },
            buildThemedProgressBar(bar_w, pct, d.bar_h),
            HorizontalSpan:new{ width = BAR_PCT_GAP },
            TextWidget:new{
                text      = pct_str,
                face      = d.face_pct,
                bold      = true,
                fgcolor   = Theme.TEXT,
                width     = PCT_W,
                alignment = "right",
            },
        },
        VerticalSpan:new{ width = d.sub_gap },
        TextWidget:new{
            text    = detail_str,
            face    = d.face_sub,
            fgcolor = Theme.TEXT_MUTED,
            width   = inner_w,
        },
    }

    local frame = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_bottom = d.bot_pad,
        block,
    }

    if not on_tap then return frame end

    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = inner_w, h = d.goal_row_h },
        [1]     = frame,
        _on_tap = on_tap,
    }
    tappable.ges_events = {
        TapGoal = {
            GestureRange:new{ ges = "tap", range = function() return tappable.dimen end },
        },
    }
    function tappable:onTapGoal()
        if self._on_tap then self._on_tap() end
        return true
    end
    return tappable
end

-- Triggers a homescreen refresh
local function _refreshHS()
    local HS = package.loaded["folio_homescreen"]
    if HS then HS.refresh(false) end
end

-- Dialog: set the annual book goal
local function showAnnualGoalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %s:"), _getYearStr()),
        value       = (function() local g = getAnnualGoal(); return g > 0 and g or 12 end)(),
        value_min   = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("folio_navbar_reading_goal", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Dialog: set the count of physical books read this year
local function showAnnualPhysicalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = string.format(_("Physical Books — %s"), _getYearStr()),
        info_text   = _("Physical books read this year:"),
        value       = getAnnualPhysical(), value_min = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("folio_navbar_reading_goal_physical", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Dialog: set the daily reading goal in minutes
local function showDailySettingsDialog(on_confirm)
    local SpinWidget  = require("ui/widget/spinwidget")
    local cur_minutes = math.floor(getDailyGoalSecs() / 60)
    UIManager:show(SpinWidget:new{
        title_text  = _("Daily Reading Goal"),
        info_text   = _("Minutes per day:"),
        value       = cur_minutes, value_min = 0, value_max = 720, value_step = 5,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("folio_navbar_daily_reading_goal_secs",
                math.floor(spin.value) * 60)
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- Returns pct, pct_str, detail for the annual goal row
local function _annualData(books_read)
    local goal = getAnnualGoal()
    local read = books_read + getAnnualPhysical()
    local pct, pct_str
    if goal > 0 then
        pct     = read / goal
        pct_str = string.format("%d%%", math.floor(pct * 100))
    else
        pct     = 1.0
        pct_str = ""
    end
    logger.dbg("folio reading_goals: annual bar — goal=", goal,
        "books_read=", books_read, "physical=", getAnnualPhysical(),
        "read=", read, "pct=", pct, "pct_str=", pct_str)
    local detail = (goal > 0)
        and string.format(_("%d/%d books"), read, goal)
        or  string.format(_("%d books"), read)
    return pct, pct_str, detail
end

-- Returns pct, pct_str, detail for the daily goal row
local function _dailyData(today_secs)
    local goal_secs = getDailyGoalSecs()
    local pct, pct_str
    if goal_secs > 0 then
        pct     = today_secs / goal_secs
        pct_str = string.format("%d%%", math.floor(pct * 100))
    else
        pct     = 1.0
        pct_str = ""
    end
    local detail = (goal_secs <= 0)
        and string.format(_("%s read"), formatDuration(today_secs))
        or  string.format("%s/%s", formatDuration(today_secs), formatDuration(goal_secs))
    return pct, pct_str, detail
end

-- Module API
local M = {}

M.id          = "reading_goals"
M.name        = _("Reading Goals")
M.label       = _("Reading Goals")
M.enabled_key = "reading_goals"
M.default_on  = true

M.showAnnualGoalDialog     = showAnnualGoalDialog
M.showAnnualPhysicalDialog = showAnnualPhysicalDialog
M.showDailySettingsDialog  = showDailySettingsDialog
M.invalidateCache          = invalidateStatsCache

-- Clears the stats cache on plugin reset or midnight rollover
function M.reset() invalidateStatsCache() end

-- Builds the widget. Branches on layout mode: compact (single inline row) or default (two lines).
function M.build(w, ctx)
    local show_ann = showAnnual()
    local show_day = showDaily()
    if not show_ann and not show_day then return nil end

    local inner_w = w - PAD * 2
    local books_read, year_secs, today_secs = getGoalStats(ctx.db_conn)
    local rows = VerticalGroup:new{ align = "left" }

    if isCompact() then
        local fc = _compactFaces()
        if show_ann then
            local pct, pct_str, detail = _annualData(books_read)
            rows[#rows+1] = buildCompactGoalRow(
                inner_w, _getYearStr(), pct, pct_str, detail,
                function() showAnnualGoalDialog() end, fc)
        end
        if show_ann and show_day then
            rows[#rows+1] = VerticalSpan:new{ width = _COMPACT_ROW_GAP }
        end
        if show_day then
            local pct, pct_str, detail = _dailyData(today_secs)
            rows[#rows+1] = buildCompactGoalRow(
                inner_w, _("Today"), pct, pct_str, detail,
                function() showDailySettingsDialog() end, fc)
        end
    else
        local scale = Config.getModuleScale("reading_goals", ctx.pfx)
        local d     = _scaledDims(scale)
        if show_ann then
            local pct, pct_str, detail = _annualData(books_read)
            rows[#rows+1] = buildGoalRow(
                inner_w, _getYearStr(), pct, pct_str, detail,
                function() showAnnualGoalDialog() end, d)
        end
        if show_ann and show_day then
            rows[#rows+1] = VerticalSpan:new{ width = d.row_gap }
        end
        if show_day then
            local pct, pct_str, detail = _dailyData(today_secs)
            rows[#rows+1] = buildGoalRow(
                inner_w, _("Today"), pct, pct_str, detail,
                function() showDailySettingsDialog() end, d)
        end
    end

    local band_pad = FolioTheme.scaled(FolioTheme.Spacing.SM)
    return FrameContainer:new{
        bordersize     = 0,
        background     = Theme.SURFACE_LOW,
        padding_left   = PAD,
        padding_right  = PAD,
        padding_bottom = band_pad,
        rows,
    }
end

-- Returns the pixel height of the module including the section label
function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    if n == 0 then return 0 end
    local label_h = require("folio_config").getScaledLabelH()
    if isCompact() then
        local band_pad = FolioTheme.scaled(FolioTheme.Spacing.SM)
        return label_h + _compactRowsHeight(n) + band_pad
    end
    local d = _scaledDims(Config.getModuleScale("reading_goals", _ctx and _ctx.pfx))
    local band_pad = FolioTheme.scaled(FolioTheme.Spacing.SM)
    return label_h + n * d.goal_row_h + (n == 2 and d.row_gap or 0) + band_pad
end

-- Builds the scale menu item for the settings menu
local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("reading_goals", pfx) end,
        set          = function(v) Config.setModuleScale(v, "reading_goals", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

-- Returns the settings menu items for this module
function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local scale_item = _makeScaleItem(ctx_menu)
    scale_item.separator = true
    return {
        { text = _lc("Type"),
          sub_item_table = {
              { text         = _lc("Default"),
                radio        = true,
                checked_func = function() return not isCompact() end,
                keep_menu_open = true,
                callback = function()
                    G_reader_settings:saveSetting(LAYOUT_KEY, "default")
                    refresh()
                end },
              { text         = _lc("Compact"),
                radio        = true,
                checked_func = function() return isCompact() end,
                keep_menu_open = true,
                callback = function()
                    G_reader_settings:saveSetting(LAYOUT_KEY, "compact")
                    refresh()
                end },
          },
          separator = true,
        },
        scale_item,
        { text         = _lc("Annual Goal"),
          checked_func = function() return showAnnual() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_ANNUAL, not showAnnual())
              refresh()
          end },
        { text_func = function()
              local g = getAnnualGoal()
              return g > 0
                  and string.format(_lc("  Set Goal  (%d books in %s)"), g, _getYearStr())
                  or  string.format(_lc("  Set Goal  (%s)"), _getYearStr())
          end,
          keep_menu_open = true,
          callback = function() showAnnualGoalDialog(refresh) end },
        { text_func = function()
              local p = getAnnualPhysical()
              return string.format(_lc("  Physical Books  (%d in %s)"), p, _getYearStr())
          end,
          keep_menu_open = true,
          callback = function() showAnnualPhysicalDialog(refresh) end },
        { text         = _lc("Daily Goal"),
          checked_func = function() return showDaily() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_DAILY, not showDaily())
              refresh()
          end },
        { text_func = function()
              local secs = getDailyGoalSecs()
              local m    = math.floor(secs / 60)
              if secs <= 0 then return _lc("  Set Goal  (disabled)")
              else              return string.format(_lc("  Set Goal  (%d min/day)"), m) end
          end,
          keep_menu_open = true,
          callback = function() showDailySettingsDialog(refresh) end },
    }
end

return M
