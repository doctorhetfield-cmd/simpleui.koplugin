-- Reading Goals module: annual and daily progress bars with tap-to-set dialogs.
-- Supports two layouts: Default (bar + detail on separate lines) and Compact (single inline row).

local Blitbuffer      = require("ffi/blitbuffer")
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
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local N_              = _.ngettext
local logger          = require("logger")
local Config          = require("sui_config")

local UI           = require("sui_core")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Colours
local _CLR_BAR_BG   = Blitbuffer.gray(0.15)
local _CLR_BAR_FG   = Blitbuffer.gray(0.75)
local _CLR_TEXT_LBL = Blitbuffer.COLOR_BLACK
local _CLR_TEXT_PCT = Blitbuffer.COLOR_BLACK

-- Default layout base dimensions (scaled at render time via _scaledDims)
local _BASE_ROW_FS  = Screen:scaleBySize(11)
local _BASE_SUB_FS  = Screen:scaleBySize(10)
local _BASE_ROW_H   = Screen:scaleBySize(16)
local _BASE_SUB_H   = Screen:scaleBySize(16)
local _BASE_SUB_GAP = Screen:scaleBySize(2)
local _BASE_ROW_GAP = Screen:scaleBySize(18)
local _BASE_BAR_H   = Screen:scaleBySize(7)
local _BASE_LBL_W   = Screen:scaleBySize(44)
local _BASE_COL_GAP = Screen:scaleBySize(8)
local _BASE_BOT_PAD = Screen:scaleBySize(18)

-- Compact layout fixed dimensions (not user-scalable)
local _COMPACT_ROW_FS  = Screen:scaleBySize(11)
local _COMPACT_SUB_FS  = Screen:scaleBySize(10)
local _COMPACT_ROW_H   = Screen:scaleBySize(20)
local _COMPACT_ROW_GAP = Screen:scaleBySize(8)
local _COMPACT_BAR_H   = Screen:scaleBySize(7)
local _COMPACT_LBL_W   = Screen:scaleBySize(44)
local _COMPACT_COL_GAP = Screen:scaleBySize(8)

-- Pre-resolved compact font faces — computed once at module load since
-- _COMPACT_ROW_FS / _COMPACT_SUB_FS are fixed constants, not user-scalable.
-- Avoids Font:getFace calls inside buildCompactGoalRow on every render.
local _COMPACT_FACE_ROW -- forward-declared; resolved lazily on first use
local _COMPACT_FACE_SUB -- so Font is available at resolution time
local function _getCompactFaces()
    if not _COMPACT_FACE_ROW then
        local Font = require("ui/font")
        _COMPACT_FACE_ROW = Font:getFace("smallinfofont", _COMPACT_ROW_FS)
        _COMPACT_FACE_SUB = Font:getFace("cfont",         _COMPACT_SUB_FS)
    end
    return _COMPACT_FACE_ROW, _COMPACT_FACE_SUB
end

local function _getYearStr() return os.date("%Y") end

-- Settings keys
local SHOW_ANNUAL = "navbar_reading_goals_show_annual"
local SHOW_DAILY  = "navbar_reading_goals_show_daily"
local LAYOUT_KEY  = "navbar_reading_goals_layout"  -- "default" | "compact"

local function isCompact()    return G_reader_settings:readSetting(LAYOUT_KEY) == "compact" end
local function showAnnual()   return G_reader_settings:readSetting(SHOW_ANNUAL) ~= false end
local function showDaily()    return G_reader_settings:readSetting(SHOW_DAILY)  ~= false end

local function getAnnualGoal()     return G_reader_settings:readSetting("navbar_reading_goal") or 0 end
local function getAnnualPhysical() return G_reader_settings:readSetting("navbar_reading_goal_physical") or 0 end
local function getDailyGoalSecs()  return G_reader_settings:readSetting("navbar_daily_reading_goal_secs") or 0 end

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

-- Stats cache and per-module fetch logic have been moved to
-- desktop_modules/module_stats_provider.lua (SP). The provider runs one
-- consolidated DB query covering today, 7-day avg, year total, and all-time
-- total, plus a single sidecar scan for books_year + books_total together.
-- build() reads ctx.stats.* — no DB or cache logic here.

-- _lbl_w_cache is kept here because it depends on font size, not on stats data.
-- Declared before _invalidateLblCache so the upvalue is properly in scope.
-- Cleared by M.invalidateCache() and M.reset(); the font-size key is the real
-- invalidation guard — a different font_size produces a different key so stale
-- entries from a previous scale are simply never hit.
local _lbl_w_cache = {}
local function _invalidateLblCache()
    _lbl_w_cache = {}
end


-- Computes all layout metrics for the default layout at the given scale factor.
-- Pre-resolves font faces so buildGoalRow doesn't call Font:getFace on every render.
local function _scaledDims(scale)
    scale = scale or 1.0
    local row_h   = math.max(8,  math.floor(_BASE_ROW_H   * scale))
    local sub_h   = math.max(8,  math.floor(_BASE_SUB_H   * scale))
    local sub_gap = math.max(1,  math.floor(_BASE_SUB_GAP * scale))
    local bot_pad = math.max(4,  math.floor(_BASE_BOT_PAD * scale))
    local row_fs  = math.max(7,  math.floor(_BASE_ROW_FS  * scale))
    local sub_fs  = math.max(6,  math.floor(_BASE_SUB_FS  * scale))
    return {
        row_fs     = row_fs,
        sub_fs     = sub_fs,
        face_row   = Font:getFace("smallinfofont", row_fs),
        face_sub   = Font:getFace("cfont",         sub_fs),
        row_h      = row_h,
        sub_h      = sub_h,
        sub_gap    = sub_gap,
        row_gap    = math.max(4,  math.floor(_BASE_ROW_GAP * scale)),
        bar_h      = math.max(1,  math.floor(_BASE_BAR_H   * scale)),
        lbl_w      = math.max(20, math.floor(_BASE_LBL_W   * scale)),
        col_gap    = math.max(2,  math.floor(_BASE_COL_GAP * scale)),
        bot_pad    = bot_pad,
        pct_w      = math.max(16, math.floor(Screen:scaleBySize(32) * scale)),
        min_bar_w  = math.max(20, math.floor(Screen:scaleBySize(40) * scale)),
        goal_row_h = row_h + sub_gap + sub_h + bot_pad,
    }
end

-- Returns total pixel height for n compact rows including inter-row gap
local function _compactRowsHeight(n)
    return n * _COMPACT_ROW_H + (n == 2 and _COMPACT_ROW_GAP or 0)
end

-- Renders a filled/empty progress bar of the given width and percentage
local function buildProgressBar(w, pct, bar_h)
    local fw = math.max(0, math.floor(w * math.min(pct, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bar_h }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bar_h },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bar_h }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bar_h }, background = _CLR_BAR_FG },
    }
end

-- Measures the rendered width of each active label using the given face and
-- returns the smallest lbl_w that fits all of them, with a minimum floor.
-- Called once per M.build so both rows share the same column width.
local function _measureLblW(labels, face, floor_w)
    local max_w = 0
    local fs    = face.size  -- integer; unique per font/size combination
    for _, lbl in ipairs(labels) do
        local key    = lbl .. "|" .. fs
        local cached = _lbl_w_cache[key]
        if not cached then
            local tw = TextWidget:new{ text = lbl, face = face, bold = true }
            cached   = tw:getSize().w
            tw:free()
            _lbl_w_cache[key] = cached
        end
        if cached > max_w then max_w = cached end
    end
    return math.max(max_w, floor_w)
end

-- Builds a single inline row: Label [bar] XX%  detail
-- Used by the Compact layout. All elements are horizontally laid out and vertically centred.
-- lbl_w is pre-computed by _measureLblW so both rows share the same column width.
local function buildCompactGoalRow(inner_w, lbl_w, pct_w, label_str, pct, pct_str, detail_str, on_tap, face_row, face_sub)
    local LeftContainer  = require("ui/widget/container/leftcontainer")
    local RightContainer = require("ui/widget/container/rightcontainer")

    local ROW_H       = _COMPACT_ROW_H
    local LBL_BAR_GAP = _COMPACT_COL_GAP
    local BAR_PCT_GAP    = _COMPACT_COL_GAP
    local PCT_DETAIL_GAP = _COMPACT_COL_GAP
    -- right_w must be at least pct_w + gap + a minimum detail column.
    local MIN_DETAIL_W = Screen:scaleBySize(32)
    local right_w = math.max(
        math.floor(inner_w * 0.28),
        pct_w + PCT_DETAIL_GAP + MIN_DETAIL_W)
    local available = inner_w - lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - right_w
    if available < Screen:scaleBySize(40) then
        -- lbl_w grew — shrink right_w before the bar goes below minimum
        available = Screen:scaleBySize(40)
        right_w = math.max(0, inner_w - lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - available)
    end
    local bar_w    = available
    local PCT_W    = pct_w
    local DETAIL_W = math.max(0, right_w - PCT_W - PCT_DETAIL_GAP)

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
            face    = face_row,
            bold    = true,
            fgcolor = _CLR_TEXT_LBL,
            width   = lbl_w,
        }, lbl_w),
        HorizontalSpan:new{ width = LBL_BAR_GAP },
        vcenter_left(buildProgressBar(bar_w, pct, _COMPACT_BAR_H), bar_w),
        HorizontalSpan:new{ width = BAR_PCT_GAP },
        vcenter_left(TextWidget:new{
            text    = pct_str,
            face    = face_row,
            bold    = true,
            fgcolor = _CLR_TEXT_PCT,
            width   = PCT_W,
        }, PCT_W),
        HorizontalSpan:new{ width = PCT_DETAIL_GAP },
        vcenter_right(TextWidget:new{
            text      = detail_str,
            face      = face_sub,
            fgcolor   = CLR_TEXT_SUB,
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
    local LBL_BAR_GAP = d.col_gap
    local BAR_PCT_GAP = d.col_gap
    local available   = inner_w - d.lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - PCT_W
    if available < d.min_bar_w then
        available = d.min_bar_w
        PCT_W = math.max(0, inner_w - d.lbl_w - LBL_BAR_GAP - BAR_PCT_GAP - available)
    end
    local bar_w = available

    local block = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            TextWidget:new{
                text    = label_str,
                face    = d.face_row,
                bold    = true,
                fgcolor = _CLR_TEXT_LBL,
                width   = d.lbl_w,
            },
            HorizontalSpan:new{ width = LBL_BAR_GAP },
            buildProgressBar(bar_w, pct, d.bar_h),
            HorizontalSpan:new{ width = BAR_PCT_GAP },
            TextWidget:new{
                text      = pct_str,
                face      = d.face_row,
                bold      = true,
                fgcolor   = _CLR_TEXT_PCT,
                width     = PCT_W,
                alignment = "right",
            },
        },
        VerticalSpan:new{ width = d.sub_gap },
        TextWidget:new{
            text    = detail_str,
            face    = d.face_sub,
            fgcolor = CLR_TEXT_SUB,
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

-- Triggers a homescreen refresh after a goal change.
-- Invalidates StatsProvider so _buildCtx re-fetches with updated ctx.stats.
local function _refreshHS()
    local SP = package.loaded["desktop_modules/module_stats_provider"]
    if SP then SP.invalidate() end
    local HS = package.loaded["sui_homescreen"]
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
            G_reader_settings:saveSetting("navbar_reading_goal", math.floor(spin.value))
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
            G_reader_settings:saveSetting("navbar_reading_goal_physical", math.floor(spin.value))
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
            G_reader_settings:saveSetting("navbar_daily_reading_goal_secs",
                math.floor(spin.value) * 60)
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
    logger.dbg("simpleui reading_goals: annual bar — goal=", goal,
        "books_read=", books_read, "physical=", getAnnualPhysical(),
        "read=", read, "pct=", pct, "pct_str=", pct_str)
    local detail = (goal > 0)
        and string.format(N_("%d/%d book", "%d/%d books", goal), read, goal)
        or  string.format(N_("%d book", "%d books", read), read)
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

-- Delegate cache invalidation to StatsProvider (shared with reading_stats).
function M.invalidateCache()
    local SP = package.loaded["desktop_modules/module_stats_provider"]
    if SP then SP.invalidate() end
    _invalidateLblCache()
end

-- Called on plugin reset (hot update). Clears label width cache too since
-- font metrics may change after a restart.
function M.reset()
    local SP = package.loaded["desktop_modules/module_stats_provider"]
    if SP then SP.invalidate() end
    _invalidateLblCache()
end

-- Builds the widget. Branches on layout mode: compact (single inline row) or default (two lines).
function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Reading Goals"))
    local show_ann = showAnnual()
    local show_day = showDaily()
    if not show_ann and not show_day then return nil end

    local inner_w = w - PAD * 2
    -- Stats pre-fetched by StatsProvider and passed via ctx.stats.
    local sp         = ctx.stats or {}
    local books_read = sp.books_year  or 0
    local year_secs  = sp.year_secs   or 0
    local today_secs = sp.today_secs  or 0
    if sp.db_conn_fatal and ctx then ctx.db_conn_fatal = true end
    local rows    = VerticalGroup:new{ align = "left" }
    local compact = isCompact()

    if compact then
        -- Resolve faces once; pass to buildCompactGoalRow to avoid Font:getFace per row.
        local _face_row, _face_sub = _getCompactFaces()
        -- Capture year string once — avoids repeated os.date calls.
        local year_str = _getYearStr()
        -- Pre-compute data for both rows so we can measure pct_w across both
        -- and use the same column width, preventing overlap when pct >= 100%.
        local ann_pct, ann_pct_str, ann_detail
        local day_pct, day_pct_str, day_detail
        if show_ann then ann_pct, ann_pct_str, ann_detail = _annualData(books_read) end
        if show_day then day_pct, day_pct_str, day_detail = _dailyData(today_secs) end
        -- Measure pct column width from both rows so they share the same width.
        local pct_strs = {}
        if show_ann and ann_pct_str ~= "" then pct_strs[#pct_strs+1] = ann_pct_str end
        if show_day and day_pct_str ~= "" then pct_strs[#pct_strs+1] = day_pct_str end
        local pct_w = _measureLblW(pct_strs, _face_row, Screen:scaleBySize(28))
        if show_ann then
            local lbl_w = _measureLblW({ year_str }, _face_row, _COMPACT_LBL_W)
            rows[#rows+1] = buildCompactGoalRow(
                inner_w, lbl_w, pct_w, year_str, ann_pct, ann_pct_str, ann_detail,
                function() showAnnualGoalDialog() end, _face_row, _face_sub)
        end
        if show_ann and show_day then
            rows[#rows+1] = VerticalSpan:new{ width = _COMPACT_ROW_GAP }
        end
        if show_day then
            local lbl_w = _measureLblW({ _("Today") }, _face_row, _COMPACT_LBL_W)
            rows[#rows+1] = buildCompactGoalRow(
                inner_w, lbl_w, pct_w, _("Today"), day_pct, day_pct_str, day_detail,
                function() showDailySettingsDialog() end, _face_row, _face_sub)
        end
    else
        local scale    = Config.getModuleScale("reading_goals", ctx.pfx)
        local d        = _scaledDims(scale)
        -- Capture year string once — avoids repeated os.date calls.
        local year_str = _getYearStr()
        if show_ann then
            local pct, pct_str, detail = _annualData(books_read)
            -- Measure the label width and store directly in d (single shared table).
            -- Each row gets a different lbl_w, so we restore after the second row.
            local ann_lbl_w = _measureLblW({ year_str }, d.face_row, d.lbl_w)
            d.lbl_w = ann_lbl_w
            rows[#rows+1] = buildGoalRow(
                inner_w, year_str, pct, pct_str, detail,
                function() showAnnualGoalDialog() end, d)
        end
        if show_ann and show_day then
            rows[#rows+1] = VerticalSpan:new{ width = d.row_gap }
        end
        if show_day then
            local pct, pct_str, detail = _dailyData(today_secs)
            local day_lbl_w = _measureLblW({ _("Today") }, d.face_row, d.lbl_w)
            d.lbl_w = day_lbl_w
            rows[#rows+1] = buildGoalRow(
                inner_w, _("Today"), pct, pct_str, detail,
                function() showDailySettingsDialog() end, d)
        end
    end

    return FrameContainer:new{
        bordersize    = 0, padding = 0,
        padding_left  = PAD, padding_right = PAD,
        rows,
    }
end

-- Returns the pixel height of the module including the section label
function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    if n == 0 then return 0 end
    local label_h = require("sui_config").getScaledLabelH()
    if isCompact() then
        return label_h + _compactRowsHeight(n)
    end
    local d = _scaledDims(Config.getModuleScale("reading_goals", _ctx and _ctx.pfx))
    return label_h + n * d.goal_row_h + (n == 2 and d.row_gap or 0)
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
    local N_lc    = _lc.ngettext
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
        Config.makeLabelToggleItem("reading_goals", _("Reading Goals"), refresh, _lc),
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
                  and string.format(N_lc("  Set Goal  (%d book in %s)", "  Set Goal  (%d books in %s)", g), g, _getYearStr())
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