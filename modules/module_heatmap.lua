-- module_heatmap.lua — Simple UI
-- Homescreen card for the reading heatmap: either the calendar grid (one
-- cell per day, last N weeks) or the time-of-day grid (one cell per
-- weekday x hour-of-day), picked via the "Type" menu item — a card only
-- has room for one grid at a time, unlike the full-screen popup. Tapping
-- the card opens the full-screen popup (screens/sui_heatmap_popup.lua),
-- which shows both grids together and lets the user page back through
-- earlier blocks.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer  = require("ui/widget/container/centercontainer")
local Device           = require("device")
local Font             = require("ui/font")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local InputContainer   = require("ui/widget/container/inputcontainer")
local TextWidget       = require("ui/widget/textwidget")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local Screen           = Device.screen
local _ = require("infra/sui_i18n").translate
local T = require("ffi/util").template

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local HD          = require("engines/sui_heatmap_data")
local HW          = require("engines/sui_heatmap_widgets")
local PAD         = UI.PAD

local SETTING_WEEKS          = "heatmap_weeks"
local DEFAULT_WEEKS          = 24
local MIN_WEEKS, MAX_WEEKS   = 6, 26

local SETTING_MODE  = "heatmap_view_mode"
local MODE_CALENDAR = "calendar"
local MODE_DAYPART  = "time_of_day"
local DEFAULT_MODE  = MODE_CALENDAR

local SETTING_SHOW_LEGEND  = "heatmap_show_legend"
local SHOW_LEGEND_DEFAULT  = true

local function getWeeks(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_WEEKS))
    if not v then return DEFAULT_WEEKS end
    return math.max(MIN_WEEKS, math.min(MAX_WEEKS, math.floor(v)))
end

local function setWeeks(pfx, weeks)
    SUISettings:saveSetting(pfx .. SETTING_WEEKS, math.max(MIN_WEEKS, math.min(MAX_WEEKS, math.floor(weeks))))
end

-- Which grid the card shows: the calendar heatmap (one cell per day) or
-- the time-of-day heatmap (one cell per weekday x hour-of-day) — the same
-- two grids the full-screen popup shows together, offered here as
-- alternate single-grid card views since a card doesn't have room for both.
local function getMode(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_MODE)
    if v == MODE_DAYPART then return MODE_DAYPART end
    return DEFAULT_MODE
end

local function setMode(pfx, mode)
    SUISettings:saveSetting(pfx .. SETTING_MODE, mode)
end

-- "Less [ ][ ][ ][ ][ ] More" legend row below the grid — purely
-- decorative once a person already knows the shading convention, so it's
-- optional like the section label, not tied to Type/Weeks/Scale.
local function getShowLegend(pfx)
    local v = SUISettings:readSetting(pfx .. SETTING_SHOW_LEGEND)
    if v == nil then return SHOW_LEGEND_DEFAULT end
    return v == true
end

local function setShowLegend(pfx, show)
    SUISettings:saveSetting(pfx .. SETTING_SHOW_LEGEND, show)
end

-- Shared geometry, used by both build() (which additionally reads the DB)
-- and getHeight() (which must not — see moduleregistry.lua's contract:
-- getHeight(ctx) gets no width of its own and no chance to touch ctx.db_conn
-- outside the normal build() pass). num_cols only depends on `weeks` and
-- today's date, so it's cheap to compute without querying anything by
-- running the grid layout over an empty data table.
--
-- weeks is always exactly "Weeks shown" — Scale never changes it. Instead
-- Scale multiplies the cell size directly, the same "autofit base × scale"
-- convention GridRenderer.computeAutoFitCell (engines/sui_book_grid.lua)
-- uses for every book-grid module: the autofit size is whatever exactly
-- fills grid_w for num_cols columns at 100%, and raw_scale scales that base
-- up or down without touching num_cols. Below 100% the grid no longer fills
-- the full column width; the CenterContainer around the whole card body
-- already centers it, same as an under-filled book-grid row would.
--
-- The pixel bases below (cell floor / legend / gaps / font) are deliberately
-- small, so the module's default footprint stays compact on e-ink screens.
local function computeLayout(w, ctx)
    local pfx    = (ctx and ctx.pfx) or "simpleui_hs_"
    local weeks  = getWeeks(pfx)
    local lf     = (ctx and ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    -- RAW (not multiplied by lf) on purpose: `w` here (ctx.col_w) is
    -- already landscape-narrowed, so folding lf into the cell scale too
    -- would shrink the grid twice. Same reasoning module_currently.lua
    -- applies to its own thumb_scale calculation.
    --
    -- Capped at 100%: num_cols is fixed (up to 60 for the calendar grid),
    -- unlike a book-grid row's handful of columns, so there's no gap left
    -- to absorb growth past the autofit size — going higher would either
    -- overflow the card or force cells to overlap. Reads from both the
    -- per-module setting and the global "Link Scale" value, so the cap
    -- applies regardless of which one set it.
    local raw_scale = math.min(1.0, Config.getModuleScaleRaw("heatmap", pfx))
    local scale     = raw_scale * lf

    -- Frame border / solid background — same optional box every other
    -- homescreen module offers (module_currently.lua, module_reading_goals.lua):
    -- a border, a filled background, or both, each adding PAD to every edge.
    -- Computed up front so avail_w below already reserves room for the
    -- border, keeping the box's real outer width equal to `w`.
    -- Chrome applied by ModuleChrome on the homescreen.
    local box = { inset_h = 0, inset_v = 0, outer_margin = 0 }

    -- Layout font: only used to size the weekday-label column and, from
    -- that, the grid's own cell size (below) — kept at its original tiny,
    -- scale-linked size so the calendar cells stay the size they've
    -- always been, independent of the display font's size (next).
    local layout_fs    = math.max(6, math.floor(6 * scale))
    local layout_fonts = { small = Font:getFace(SUIStyle.FACE_REGULAR, layout_fs) }

    -- Display font: what the weekday/month labels and the legend text
    -- actually render in. Matches the full-screen popup's own caption
    -- size (screens/sui_heatmap_popup.lua) rather than scaling with this
    -- module's own Scale setting, so card and popup read the same.
    local display_fonts = { small = Font:getFace(SUIStyle.FACE_REGULAR, UI.SZ(SUIStyle.FS_CAPTION)) }

    local avail_w = w - box.inset_h
    local start_t, end_t = HD.getWeekBlockRange(weeks, 0)

    local mode = getMode(pfx)
    local num_cols
    if mode == MODE_DAYPART then
        num_cols = 24
    else
        local _cols, cal_cols = HW.buildRangeGrid({}, start_t, end_t)
        num_cols = cal_cols
    end

    local gap        = Screen:scaleBySize(2)
    -- Size the weekday column with the same face used to paint it (display
    -- fonts). Using the tiny layout face here made cells overflow avail_w
    -- once the wider display labels were drawn.
    local wd_label_w = HW.getWeekdayLabelWidth(display_fonts)
    local grid_w     = avail_w - wd_label_w - gap
    -- Half of the original 8px target floor; the hard 2px (half of the
    -- original 4px) underneath it is a legibility backstop, not a
    -- "default size" — it only bites at the very bottom of the Scale range.
    local min_cell      = math.max(Screen:scaleBySize(2), math.floor(Screen:scaleBySize(4) * scale))
    local autofit_cell  = math.max(1, math.floor((grid_w - (num_cols - 1) * gap) / num_cols))
    -- Never exceed autofit: a min_cell larger than the fitted size would
    -- make the grid wider than avail_w and break label alignment.
    local cell_size     = math.min(autofit_cell, math.max(min_cell, math.floor(autofit_cell * raw_scale)))

    -- Row heights below are estimated off the display font, since that's
    -- what's actually rendered for the labels and the legend text.
    local sample = TextWidget:new{ text = "Xxx", face = display_fonts.small }
    local label_h = sample:getSize().h
    sample:free()

    -- Legend cell size now matches the popup's own default (see
    -- sui_heatmap_widgets.lua's HW.buildLegend), not a scale-linked size.
    -- Only sized in when the legend is actually shown (see
    -- SETTING_SHOW_LEGEND) — hidden, it contributes neither height nor gap.
    local show_legend   = getShowLegend(pfx)
    local legend_cell   = Screen:scaleBySize(11)
    local legend_h, gap_v = 0, 0
    if show_legend then
        local legend_sample = TextWidget:new{ text = _("Less"), face = display_fonts.small }
        legend_h = math.max(legend_cell, legend_sample:getSize().h)
        legend_sample:free()
        -- Half of the original 8px gap above the legend.
        gap_v = math.floor(Screen:scaleBySize(4) * scale)
    end

    local body_h = label_h + Screen:scaleBySize(6)
                 + 7 * cell_size + 6 * Screen:scaleBySize(2)
                 + gap_v + legend_h

    body_h = body_h + box.inset_v

    return {
        pfx = pfx, weeks = weeks, mode = mode, fonts = display_fonts,
        avail_w = avail_w, start_t = start_t, end_t = end_t,
        cell_size = cell_size, body_h = body_h, gap_v = gap_v,
        legend_h = legend_h, legend_cell = legend_cell, show_legend = show_legend,
        box = box,
    }
end

local function openPopup()
    local ok, Popup = pcall(require, "screens/sui_heatmap_popup")
    if ok and Popup then Popup.show() end
end

local M = {}

M.id          = "heatmap"
M.name        = _("Reading Heatmap")
M.label       = _("Reading Heatmap")
M.enabled_key = "heatmap_enabled"
M.default_on  = false

-- Right-aligned indicator of the selected Type on the section label row —
-- the weeks count in Calendar mode, or "Time of day" in that mode — so the
-- card's title row reflects which grid it's currently showing, and at what
-- range. Rendered via sui_screen_engine.lua's sectionLabel right_text slot,
-- the same one the page indicator uses, so it shares its font/color/right
-- alignment.
function M.label_right_func(ctx)
    local pfx  = (ctx and ctx.pfx) or "simpleui_hs_"
    local mode = getMode(pfx)
    return (mode == MODE_DAYPART)
        and _("Time of day")
        or  T(_("%1 weeks"), getWeeks(pfx))
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Reading Heatmap"))
    local L = computeLayout(w, ctx)

    local grid_widget
    if L.mode == MODE_DAYPART then
        local wd_hour_map, fatal = HD.getWeekdayHourReadingData(L.start_t, L.end_t, ctx and ctx.db_conn)
        if fatal and ctx then ctx.db_conn_fatal = true end
        local is_12h = G_reader_settings:isTrue("twelve_hour_clock")
        grid_widget = HW.buildDayPartHeatmap(wd_hour_map, L.fonts, L.avail_w, is_12h, { cell_size = L.cell_size })
    else
        local daily_map, fatal = HD.getDailyReadingData(L.start_t, L.end_t, ctx and ctx.db_conn)
        if fatal and ctx then ctx.db_conn_fatal = true end
        grid_widget = HW.buildRangeHeatmap(daily_map, L.start_t, L.end_t, L.fonts, L.avail_w, { cell_size = L.cell_size })
    end

    -- Wrapped the same way as the legend below: below 100% Scale the grid's
    -- own intrinsic width (wd_label_w + num_cols*cell_size + gaps) is
    -- narrower than avail_w, and body's "align = left" would otherwise pin
    -- it to the left edge instead of centering it under a full-width card.
    local grid_box = CenterContainer:new{
        dimen = Geom:new{ w = L.avail_w, h = grid_widget:getSize().h },
        grid_widget,
    }

    local body = VerticalGroup:new{ align = "left", grid_box }
    if L.show_legend then
        local legend = HW.buildLegend(L.fonts, L.legend_cell)
        table.insert(body, VerticalSpan:new{ width = L.gap_v })
        table.insert(body, CenterContainer:new{ dimen = Geom:new{ w = L.avail_w, h = legend:getSize().h }, legend })
    end

    -- Content sits at avail_w (w minus the box's own insets); the box below
    -- supplies the left/right gutter via padding rather than by centering
    -- inside a full-w wrapper, so its real outer width — content + 2*padding
    -- + 2*bordersize — lands on exactly `w`, matching the section label.
    local box = body

    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = box:getSize().h },
        [1]   = box,
    }
    tappable.ges_events = {
        TapHeatmap = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapHeatmap()
        openPopup()
        return true
    end

    return tappable
end

function M.getHeight(ctx)
    -- Match chrome contentWidth: full column minus label-aligned outer margins.
    local col_w = (ctx and (ctx.col_w or ctx.inner_w)) or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local content_w = math.max(1, col_w - UI.PAD * 2)
    local L = computeLayout(content_w, ctx)
    return L.body_h
end

function M.invalidateCache()
    HD.invalidate()
end

local function _makeWeeksItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeStepperItem{
        text_func  = function() return _lc("Weeks shown") end,
        unit       = "",
        get        = function() return getWeeks(pfx) end,
        set        = function(v) setWeeks(pfx, v) end,
        title      = _lc("Weeks shown"),
        info       = _lc("How many weeks of history to include, and (in Calendar view) how many weeks the grid shows — this count is unaffected by Scale, which only resizes the cells. In Time of day view, this only changes how much history feeds the shading — the grid itself always has one column per hour."),
        value_min  = MIN_WEEKS,
        value_max  = MAX_WEEKS,
        value_step = 1,
        default_value = DEFAULT_WEEKS,
        refresh    = ctx_menu.refresh,
    }
end

local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem{
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size. Capped at 100% here: the grid always has as many columns as \"Weeks shown\" (or, in Time of day view, 24), so there's no room to grow the cells past their autofit size without the grid overflowing the card."),
        get          = function() return Config.getModuleScalePct("heatmap", pfx) end,
        set          = function(v) Config.setModuleScale(v, "heatmap", pfx) end,
        value_max    = 100,
        refresh      = ctx_menu.refresh,
    }
end

-- Builds one radio-button item for the view-mode setting — mirrors the
-- _makeStyleRadioItem helper module_currently.lua uses for its own
-- persisted-string-setting radio choices.
local function _makeViewModeRadioItem(text, pfx, mode, refresh)
    return {
        text           = text,
        radio          = true,
        keep_menu_open = true,
        checked_func   = function() return getMode(pfx) == mode end,
        callback       = function()
            setMode(pfx, mode)
            refresh()
        end,
    }
end

local function _makeViewItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        text           = _lc("Type"),
        sub_item_table = {
            _makeViewModeRadioItem(_lc("Calendar"), pfx, MODE_CALENDAR, ctx_menu.refresh),
            _makeViewModeRadioItem(_lc("Time of day"), pfx, MODE_DAYPART, ctx_menu.refresh),
        },
    }
end

local function _makeAppearanceItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        text_func      = function() return _lc("Appearance") end,
        sub_item_table = {
            Config.makeLabelToggleItem("heatmap", _("Reading Heatmap"), ctx_menu.refresh, _lc),
            {
                text           = _lc("Show legend"),
                checked_func   = function() return getShowLegend(pfx) end,
                keep_menu_open = true,
                callback       = function()
                    setShowLegend(pfx, not getShowLegend(pfx))
                    ctx_menu.refresh()
                end,
            },
                                },
    }
end

function M.getMenuItems(ctx_menu)
    return {
        _makeViewItem(ctx_menu),
        _makeWeeksItem(ctx_menu),
        _makeScaleItem(ctx_menu),
        _makeAppearanceItem(ctx_menu),
    }
end

return M
