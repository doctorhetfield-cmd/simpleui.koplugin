-- bottombar.lua — Simple UI
-- Bottom tab bar: dimensions, widget construction, touch zones, navigation, rebuild helpers.

-- Widget classes — required lazily on first use so that require("sui_bottombar")
-- at plugin load time does not force all these modules off disk.
-- Each accessor caches its result in a module-local upvalue; subsequent calls
-- are a single nil-check + table field read, with zero I/O.
local _FrameContainer, _CenterContainer, _HorizontalGroup, _VerticalGroup
local _VerticalSpan, _LineWidget, _OverlapGroup, _TextWidget, _ImageWidget
local _Geom, _Font
local function FrameContainer()  _FrameContainer  = _FrameContainer  or require("ui/widget/container/framecontainer");  return _FrameContainer  end
local function CenterContainer() _CenterContainer = _CenterContainer or require("ui/widget/container/centercontainer"); return _CenterContainer end
local function HorizontalGroup() _HorizontalGroup = _HorizontalGroup or require("ui/widget/horizontalgroup");           return _HorizontalGroup end
local function VerticalGroup()   _VerticalGroup   = _VerticalGroup   or require("ui/widget/verticalgroup");             return _VerticalGroup   end
local function VerticalSpan()    _VerticalSpan    = _VerticalSpan    or require("ui/widget/verticalspan");              return _VerticalSpan    end
local function LineWidget()      _LineWidget      = _LineWidget      or require("ui/widget/linewidget");                return _LineWidget      end
local function OverlapGroup()    _OverlapGroup    = _OverlapGroup    or require("ui/widget/overlapgroup");              return _OverlapGroup    end
local function TextWidget()      _TextWidget      = _TextWidget      or require("ui/widget/textwidget");                return _TextWidget      end
local function ImageWidget()     _ImageWidget     = _ImageWidget     or require("ui/widget/imagewidget");               return _ImageWidget     end
local function Geom()            _Geom            = _Geom            or require("ui/geometry");                         return _Geom            end
local function Font()            _Font            = _Font            or require("ui/font");                             return _Font            end
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local _InfoMessage
local function InfoMessage() _InfoMessage = _InfoMessage or require("ui/widget/infomessage"); return _InfoMessage end
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")
local _ = require("sui_i18n").translate

local Config = require("sui_config")

-- Lazy reference to sui_quickactions — single source of truth for QA resolution
-- and execution.  Loaded on first use to avoid a circular require at startup.
local function _QA()
    return package.loaded["sui_quickactions"] or require("sui_quickactions")
end

-- Lazy reference to sui_browsemeta — avoids loading the module at startup when
-- the Browse by Authors/Series feature may not be in use.
local function _BM()
    return package.loaded["sui_browsemeta"] or require("sui_browsemeta")
end

-- Action-only tabs: these fire a dialog/toggle without becoming the active tab.
-- Used by onTabTap (early-return guard) AND setActiveAndRefreshFM (write guard).
-- Keeping the list in one place makes it impossible for the two sites to drift.
local _ACTION_ONLY = {
    bookmark_browser = true,
    wifi_toggle      = true,
    frontlight       = true,
    power            = true,
}

local M = {}

-- Bar colors.
M.COLOR_INACTIVE_TEXT = Blitbuffer.gray(0.55)
M.COLOR_SEPARATOR     = Blitbuffer.gray(0.7)

-- Returns the separator colour: transparent when the user has hidden it.
local function _sepColor()
    if G_reader_settings:isTrue("navbar_hide_separator") then
        return Blitbuffer.COLOR_WHITE
    end
    return M.COLOR_SEPARATOR
end
-- Public accessor used by sui_core.lua to draw the full-width separator line.
function M.sepColor() return _sepColor() end

-- ---------------------------------------------------------------------------
-- Dimension cache — computed once, invalidated on screen resize or size change.
-- ---------------------------------------------------------------------------

local _dim = {}

-- ---------------------------------------------------------------------------
-- Dimension cache helpers — _cached and all functions that call it must be
-- declared before any function that references them (Lua local scoping).
-- ---------------------------------------------------------------------------

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

-- Reads the current navbar size setting and returns a scale factor.
-- Cached inside _dim so getBarSizePct() (a readSetting call) is only paid once
-- per invalidation cycle, regardless of how many dimension functions call it.
local function _getNavbarScale()
    return _cached("nav_scale", function() return Config.getBarSizePct() / 100 end)
end

-- Icon/label scale and bottom-margin pct are also cached inside _dim so each
-- G_reader_settings lookup (+ tonumber + clamp) is paid only once per
-- invalidation cycle, no matter how many dimension functions reference them.
local function _getIconScalePct()
    return _cached("icon_scale_pct", function() return Config.getIconScalePct() end)
end
local function _getLabelScalePct()
    return _cached("label_scale_pct", function() return Config.getLabelScalePct() end)
end
local function _getBottomMarginPct()
    return _cached("bot_margin_pct", function() return Config.getBottomMarginPct() end)
end

-- VerticalSpan and LineWidget singletons — created once per layout, reused
-- across all tab cell renders. Declared before invalidateDimCache and
-- buildTabCell so all references resolve correctly.
local _vspan_icon_top = nil
local _vspan_icon_txt = nil
function M.invalidateDimCache()
    _dim             = {}
    _vspan_icon_top  = nil
    _vspan_icon_txt  = nil
    _old_touch_zones = nil
end

function M.BAR_H()       return _cached("bar_h",   function() return math.floor(Screen:scaleBySize(96) * _getNavbarScale()) end) end
function M.ICON_SZ()     return _cached("icon_sz", function() return math.floor(Screen:scaleBySize(44) * _getNavbarScale() * (_getIconScalePct()  / 100)) end) end
function M.ICON_TOP_SP() return _cached("it_sp",   function() return math.floor(Screen:scaleBySize(10) * _getNavbarScale()) end) end
function M.ICON_TXT_SP() return _cached("itxt_sp", function() return math.floor(Screen:scaleBySize(4)  * _getNavbarScale()) end) end
function M.LABEL_FS()    return _cached("lbl_fs",  function() return math.floor(Screen:scaleBySize(9)  * _getNavbarScale() * (_getLabelScalePct() / 100)) end) end
function M.INDIC_H()     return _cached("indic_h", function() return math.floor(Screen:scaleBySize(3)  * _getNavbarScale()) end) end

-- Structural dimensions — not affected by the size setting.
function M.TOP_SP()      return _cached("top_sp",  function() return Screen:scaleBySize(2)  end) end
function M.BOT_SP()      return _cached("bot_sp",  function() return math.floor(Screen:scaleBySize(12) * _getBottomMarginPct() / 100) end) end
function M.SIDE_M()      return _cached("side_m",  function() return Screen:scaleBySize(24) end) end
function M.SEP_H()       return _cached("sep_h",   function() return Screen:scaleBySize(1)  end) end

function M.TOTAL_H()
    if not G_reader_settings:nilOrTrue("navbar_enabled") then return 0 end
    return M.BAR_H() + M.TOP_SP() + M.BOT_SP()
end

-- ---------------------------------------------------------------------------
-- Pagination bar helpers
-- ---------------------------------------------------------------------------

-- Returns the raw pagination size key ("xs" | "s" | "l").
-- Cached inside _dim alongside all other dimension values so that the single
-- G_reader_settings lookup is shared by getPaginationIconSize AND
-- getPaginationFontSize when both are called in the same render pass.
local function _getPaginationKey()
    return _cached("pag_key", function()
        return G_reader_settings:readSetting("navbar_pagination_size") or "s"
    end)
end

function M.getPaginationIconSize()
    local key = _getPaginationKey()
    if key == "xs" then return Screen:scaleBySize(20)
    elseif key == "s" then return Screen:scaleBySize(28)
    else return Screen:scaleBySize(36) end
end

function M.getPaginationFontSize()
    local key = _getPaginationKey()
    if key == "xs" then return 11
    elseif key == "s" then return 14
    else return 20 end
end

-- Button field names used by resizePaginationButtons — defined once at module level (P8).
local _PAGINATION_BTN_NAMES = {
    "page_info_left_chev", "page_info_right_chev",
    "page_info_first_chev", "page_info_last_chev",
}

function M.resizePaginationButtons(widget, icon_size)
    pcall(function()
        for _i, name in ipairs(_PAGINATION_BTN_NAMES) do
            local btn = widget[name]
            if btn then
                btn.icon_width  = icon_size
                btn.icon_height = icon_size
                btn:init()
            end
        end
        local txt = widget.page_info_text
        if txt then
            txt.text_font_size = M.getPaginationFontSize()
            txt:init()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Visual construction
-- ---------------------------------------------------------------------------

-- Reused table for tab widths — avoids per-render allocation.
-- Returns a table of pixel widths for each tab, last tab absorbs rounding remainder.
local _tab_widths_cache = {}

function M.getTabWidths(num_tabs, usable_w)
    local base_w = math.floor(usable_w / num_tabs)
    for i = 1, num_tabs do
        _tab_widths_cache[i] = (i == num_tabs) and (usable_w - base_w * (num_tabs - 1)) or base_w
    end
    for i = num_tabs + 1, #_tab_widths_cache do _tab_widths_cache[i] = nil end
    return _tab_widths_cache
end

-- Builds one tab cell: active indicator (pinned to top) + icon and/or label.
-- The visible separator line is drawn full-width in wrapWithNavbar (sui_core.lua).
function M.buildTabCell(action_id, active, tab_w, mode)
    local action = Config.getActionById(action_id)
    local vg     = VerticalGroup():new{ align = "center" }

    if not _vspan_icon_top then _vspan_icon_top = VerticalSpan():new{ width = M.ICON_TOP_SP() } end
    vg[#vg + 1] = _vspan_icon_top

    if mode == "icons" or mode == "both" then
        local nerd_char = Config.nerdIconChar(action.icon)
        if nerd_char then
            local icon_sz = M.ICON_SZ()
            -- Use tab_w as the outer width so the nerd glyph is centred
            -- in exactly the same horizontal space as an SVG ImageWidget().
            vg[#vg + 1] = CenterContainer():new{
                dimen = Geom():new{ w = tab_w, h = icon_sz },
                TextWidget():new{
                    text    = nerd_char,
                    face    = Font():getFace("symbols", math.floor(icon_sz * 0.6)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    padding = 0,
                },
            }
        else
            vg[#vg + 1] = ImageWidget():new{
                file    = action.icon,
                width   = M.ICON_SZ(),
                height  = M.ICON_SZ(),
                is_icon = true,
                alpha   = true,
            }
        end
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            if not _vspan_icon_txt then _vspan_icon_txt = VerticalSpan():new{ width = M.ICON_TXT_SP() } end
            vg[#vg + 1] = _vspan_icon_txt
        end
        vg[#vg + 1] = TextWidget():new{
            text    = action.label,
            face    = Font():getFace("cfont", M.LABEL_FS()),
            fgcolor = active and Blitbuffer.COLOR_BLACK or M.COLOR_INACTIVE_TEXT,
        }
    end

    if mode == "icons" then
        vg[#vg + 1] = VerticalSpan():new{ width = M.ICON_TOP_SP() + M.ICON_TXT_SP() }
    end

    -- The content (icon/label) is centred inside BAR_H.
    local content = CenterContainer():new{
        dimen = Geom():new{ w = tab_w, h = M.BAR_H() },
        vg,
    }

    -- The active indicator is pinned to the very top of the cell via OverlapGroup,
    -- independent of the vertical centering of the content.
    local indic_color = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local indic = LineWidget():new{
        dimen      = Geom():new{ w = tab_w, h = M.INDIC_H() },
        background = indic_color,
        overlap_offset = { 0, 0 },
    }

    return OverlapGroup():new{
        allow_mirroring = false,
        dimen           = Geom():new{ w = tab_w, h = M.BAR_H() },
        content,
        indic,
    }
end

-- Builds a navpager arrow cell (Prev or Next).
-- `enabled`  — false → dimmed (no prev/next page exists).
-- `is_prev`  — true → left arrow, false → right arrow.
local _NAVPAGER_COLOR_ACTIVE  = Blitbuffer.COLOR_BLACK
local _NAVPAGER_COLOR_DIMMED  = nil  -- initialised lazily (grey(0.75))

local function _navpagerColor()
    if not _NAVPAGER_COLOR_DIMMED then
        _NAVPAGER_COLOR_DIMMED = Blitbuffer.gray(0.75)
    end
    return _NAVPAGER_COLOR_DIMMED
end

function M.buildNavpagerArrowCell(is_prev, enabled, tab_w, mode)
    local icon_file = is_prev and Config.ICON.nav_prev or Config.ICON.nav_next
    local label     = is_prev and _("Prev") or _("Next")
    local color     = enabled and _NAVPAGER_COLOR_ACTIVE or _navpagerColor()

    local vg = VerticalGroup():new{ align = "center" }

    if not _vspan_icon_top then _vspan_icon_top = VerticalSpan():new{ width = M.ICON_TOP_SP() } end
    vg[#vg + 1] = _vspan_icon_top

    -- References to mutable widgets stored on the OverlapGroup so
    -- updateNavpagerArrows can mutate them in-place without tree traversal.
    local iw, tw

    if mode == "icons" or mode == "both" then
        -- dim is read at paintTo time — set directly, no paintTo override needed.
        iw = ImageWidget():new{
            file    = icon_file,
            width   = M.ICON_SZ(),
            height  = M.ICON_SZ(),
            is_icon = true,
            alpha   = true,
            dim     = not enabled or nil,
        }
        vg[#vg + 1] = iw
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            if not _vspan_icon_txt then _vspan_icon_txt = VerticalSpan():new{ width = M.ICON_TXT_SP() } end
            vg[#vg + 1] = _vspan_icon_txt
        end
        tw = TextWidget():new{
            text    = label,
            face    = Font():getFace("cfont", M.LABEL_FS()),
            fgcolor = color,
        }
        vg[#vg + 1] = tw
    end

    if mode == "icons" then
        vg[#vg + 1] = VerticalSpan():new{ width = M.ICON_TOP_SP() + M.ICON_TXT_SP() }
    end

    local content = CenterContainer():new{
        dimen = Geom():new{ w = tab_w, h = M.BAR_H() },
        vg,
    }

    -- Arrow cells never have an active indicator; pin a white (invisible)
    -- LineWidget to the top for visual consistency with buildTabCell.
    local indic = LineWidget():new{
        dimen          = Geom():new{ w = tab_w, h = M.INDIC_H() },
        background     = Blitbuffer.COLOR_WHITE,
        overlap_offset = { 0, 0 },
    }

    local og = OverlapGroup():new{
        allow_mirroring = false,
        dimen           = Geom():new{ w = tab_w, h = M.BAR_H() },
        content,
        indic,
    }
    -- Annotate with mutable-widget handles and current enabled state.
    -- updateNavpagerArrows reads these directly — O(1), no tree traversal.
    og._arrow_image   = iw
    og._arrow_text    = tw
    og._arrow_enabled = enabled
    return og
end

-- Updates the Prev/Next arrow cells of an existing navpager bar in-place.
-- Mutates only ImageWidget().dim and TextWidget().fgcolor on the two arrow cells
-- rather than rebuilding the entire bar (~37 widget allocations per rebuild).
-- Returns true when the update was applied, false when the bar structure is
-- missing or unrecognised (caller must fall back to a full replaceBar).
function M.updateNavpagerArrows(widget, has_prev, has_next)
    local bar = widget._navbar_bar
    if not bar then return false end

    -- Arrows are always visible when navpager is enabled.
    if not bar._navpager_has_arrows then return false end

    local hg = bar[1]   -- HorizontalGroup inside the FrameContainer
    if not hg then return false end
    local prev_cc = hg[1]     -- slot 1 = Prev arrow CenterContainer
    local next_cc = hg[#hg]   -- last slot = Next arrow CenterContainer
    -- Verify these are annotated arrow cells (built by buildNavpagerArrowCell).
    if not (prev_cc and prev_cc._arrow_enabled ~= nil
        and next_cc and next_cc._arrow_enabled ~= nil) then
        return false
    end
    -- Skip all work when the visible state has not changed.
    if prev_cc._arrow_enabled == has_prev and next_cc._arrow_enabled == has_next then
        return true
    end
    local dimmed = _navpagerColor()
    local function _apply(cc, enabled)
        if cc._arrow_enabled == enabled then return end
        cc._arrow_enabled = enabled
        if cc._arrow_image then
            cc._arrow_image.dim = not enabled or nil
        end
        if cc._arrow_text then
            cc._arrow_text.fgcolor = enabled and _NAVPAGER_COLOR_ACTIVE or dimmed
        end
    end
    _apply(prev_cc, has_prev)
    _apply(next_cc, has_next)
    return true
end

-- Assembles the full bottom bar FrameContainer from all tab cells.
-- In navpager mode, calls getNavpagerState() internally.
function M.buildBarWidget(active_action_id, tab_config, num_tabs, mode)
    num_tabs    = num_tabs or Config.getNumTabs()
    mode        = mode     or Config.getNavbarMode()
    local screen_w = Screen:getWidth()
    local side_m   = M.SIDE_M()
    local usable_w = screen_w - side_m * 2
    local hg_args  = { align = "top" }

    if Config.isNavpagerEnabled() then
        local has_prev, has_next = Config.getNavpagerState()
        return M.buildBarWidgetWithArrows(
            active_action_id, tab_config, mode,
            has_prev, has_next)
    end

    local widths = M.getTabWidths(num_tabs, usable_w)
    for i = 1, num_tabs do
        local action_id = tab_config[i]
        hg_args[#hg_args + 1] = M.buildTabCell(action_id, action_id == active_action_id, widths[i], mode)
    end

    return FrameContainer():new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_m,
        padding_right = side_m,
        margin        = 0,
        background    = Blitbuffer.COLOR_WHITE,
        HorizontalGroup():new(hg_args),
    }
end

-- Navpager-mode bar with explicit has_prev / has_next flags.
-- Called both from buildBarWidget (which resolves flags via getNavpagerState)
-- and from the updatePageInfo hook (which passes pre-snapshotted values).
function M.buildBarWidgetWithArrows(active_action_id, tab_config, mode, has_prev, has_next)
    local HorizontalSpan = require("ui/widget/horizontalspan")
    mode = mode or Config.getNavbarMode()
    local screen_w  = Screen:getWidth()
    local side_m    = M.SIDE_M()
    local usable_w  = screen_w - side_m * 2
    local center_n  = #tab_config
    local hg_args   = { align = "top" }

    -- Arrows are always shown when navpager is enabled.
    local total_n = center_n + 2
    local widths  = M.getTabWidths(total_n, usable_w)

    -- Prev arrow
    hg_args[#hg_args + 1] = M.buildNavpagerArrowCell(true, has_prev, widths[1], mode)

    -- Centre tabs
    for i = 1, center_n do
        local action_id = tab_config[i]
        local w = widths[i + 1]
        if action_id then
            hg_args[#hg_args + 1] = M.buildTabCell(action_id, action_id == active_action_id, w, mode)
        else
            hg_args[#hg_args + 1] = HorizontalSpan:new{ width = w }
        end
    end

    -- Next arrow
    hg_args[#hg_args + 1] = M.buildNavpagerArrowCell(false, has_next, widths[total_n], mode)

    -- Tag so updateNavpagerArrows knows whether this bar has arrows.
    local fc = FrameContainer():new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_m,
        padding_right = side_m,
        margin        = 0,
        background    = Blitbuffer.COLOR_WHITE,
        HorizontalGroup():new(hg_args),
    }
    fc._navpager_has_arrows = true
    return fc
end

-- Builds a bottom bar identical to buildBarWidget but with a keyboard-focus
-- rectangle rendered over the tab at kbfocus_idx (1-based).
-- Used by the navbar keyboard navigation mode.
-- Falls back to plain buildBarWidget when navpager is active or kbfocus_idx is nil.
function M.buildBarWidgetWithKeyFocus(active_action_id, tab_config, kbfocus_idx, num_tabs, mode)
	if not kbfocus_idx or Config.isNavpagerEnabled() then
		return M.buildBarWidget(active_action_id, tab_config, num_tabs, mode)
	end
	num_tabs = num_tabs or Config.getNumTabs()
	mode     = mode     or Config.getNavbarMode()
	local screen_w = Screen:getWidth()
	local side_m   = M.SIDE_M()
	local usable_w = screen_w - side_m * 2
	local widths   = M.getTabWidths(num_tabs, usable_w)
	local hg_args  = { align = "top" }
	local bw       = Screen:scaleBySize(3)
	for i = 1, num_tabs do
		local action_id = tab_config[i]
		local cell = M.buildTabCell(action_id, action_id == active_action_id, widths[i], mode)
		if i == kbfocus_idx then
			local tw    = widths[i]
			local tab_h = M.BAR_H()
			cell = OverlapGroup():new{
				dimen = Geom():new{ w = tw, h = tab_h },
				cell,
				LineWidget():new{ dimen = Geom():new{ w = tw, h = bw },    background = Blitbuffer.COLOR_BLACK },
				LineWidget():new{ dimen = Geom():new{ w = tw, h = bw },    background = Blitbuffer.COLOR_BLACK, overlap_offset = {0, tab_h - bw} },
				LineWidget():new{ dimen = Geom():new{ w = bw, h = tab_h }, background = Blitbuffer.COLOR_BLACK },
				LineWidget():new{ dimen = Geom():new{ w = bw, h = tab_h }, background = Blitbuffer.COLOR_BLACK, overlap_offset = {tw - bw, 0} },
			}
		end
		hg_args[#hg_args + 1] = cell
	end
	return FrameContainer():new{
		bordersize    = 0,
		padding       = 0,
		padding_left  = side_m,
		padding_right = side_m,
		margin        = 0,
		background    = Blitbuffer.COLOR_WHITE,
		HorizontalGroup():new(hg_args),
	}
end

-- Swaps the bar widget inside an already-wrapped widget, preserving overlap_offset.
function M.replaceBar(widget, new_bar, tabs)
    if not G_reader_settings:nilOrTrue("navbar_enabled") then
        if widget and tabs then widget._navbar_tabs = tabs end
        return
    end
    local container = widget._navbar_container
    if not container then return end
    local idx = widget._navbar_bar_idx
    if not idx then
        logger.err("simpleui: replaceBar called without _navbar_bar_idx — widget not initialised.")
        return
    end
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    if widget._navbar_bar_idx_topbar_on ~= nil and widget._navbar_bar_idx_topbar_on ~= topbar_on then
        logger.warn("simpleui: replaceBar — bar_idx out of sync, skipping.")
        return
    end
    local old_bar = container[idx]
    if old_bar and old_bar.overlap_offset then
        new_bar.overlap_offset = old_bar.overlap_offset
    end
    container[idx]     = new_bar
    widget._navbar_bar = new_bar
    if tabs then widget._navbar_tabs = tabs end
end

-- ---------------------------------------------------------------------------
-- Touch zones
-- ---------------------------------------------------------------------------

function M.registerTouchZones(plugin, fm_self)
    local num_tabs  = Config.getNumTabs()
    -- Load tab config once at registration time — captured as an upvalue by all
    -- handler closures below.  This avoids a loadTabConfig() (+ readSetting)
    -- call on every single tap.  The zones are re-registered whenever the tab
    -- config changes (rebuildAllNavbars → registerTouchZones), so the captured
    -- snapshot is always current at the moment of registration.
    local tabs_snap = Config.loadTabConfig()
    local screen_w  = Screen:getWidth()
    local screen_h  = Screen:getHeight()
    local navbar_on = G_reader_settings:nilOrTrue("navbar_enabled")
    -- Full navbar strip height (separator + bar + bottom padding) — must match
    -- wrapWithNavbar / TOTAL_H so touch targets cover the entire bottom region.
    -- Using BAR_H() alone leaves the top separator and bottom safe-area bands
    -- where underlying scroll/content can still win hit-testing.
    local nav_h     = navbar_on and M.TOTAL_H() or 0
    local side_m    = M.SIDE_M()
    local usable_w  = screen_w - side_m * 2
    local bar_y     = navbar_on and (screen_h - nav_h) or screen_h
    local navpager  = Config.isNavpagerEnabled()

    local center_n    = num_tabs
    local arrows_active = navpager
    local total_slots = arrows_active and (num_tabs + 2) or num_tabs
    local widths      = M.getTabWidths(total_slots, usable_w)

    logger.dbg("simpleui tz: registerTouchZones on=", tostring(fm_self and fm_self.name),
        "navpager=", tostring(navpager),
        "num_tabs=", tostring(num_tabs))

    -- Unregister all possible zone ids from any previous registration.
    if fm_self.unregisterTouchZones then
        local old_zones = {}
        for i = 1, Config.MAX_TABS do
            old_zones[#old_zones + 1] = { id = "navbar_pos_" .. i }
        end
        for _, id in ipairs({ "navbar_pos_prev", "navbar_pos_next",
                               "navbar_hold_start", "navbar_hold_settings" }) do
            old_zones[#old_zones + 1] = { id = id }
        end
        fm_self:unregisterTouchZones(old_zones)
    end

    local zones = {}
    local _OVERRIDES = {
        "tap_left_bottom_corner", "tap_right_bottom_corner",
        "TapBook", "TapColl", "TapQA", "TapGoal", "TapSelect", "TapStatCard",
        -- Homescreen footer zone covers the same strip; navbar tabs must win.
        "simpleui_hs_footer_tap",
    }

    -- Helper: find and call a page-navigation method on the topmost pageable widget.
    local UI_mod = require("sui_core")
    local function _callPageFn(fn_name)
        local stack  = UI_mod.getWindowStack()
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w then
                if type(w[fn_name]) == "function" and type(w.page_num) == "number" then
                    pcall(function() w[fn_name](w) end); return
                end
                local fc = w.file_chooser
                if fc and type(fc[fn_name]) == "function" and type(fc.page_num) == "number" then
                    pcall(function() fc[fn_name](fc) end); return
                end
            end
        end
        -- Fallback: FM file_chooser (not always on stack).
        local fm_mod = package.loaded["apps/filemanager/filemanager"]
        local fm_inst = fm_mod and fm_mod.instance
        if fm_inst and fm_inst.file_chooser then
            pcall(function() fm_inst.file_chooser[fn_name](fm_inst.file_chooser) end)
        end
    end

    -- Helper: jump to a specific page on the topmost pageable widget.
    -- Pass page=1 for first page, page=nil to jump to the last page (page_num).
    local function _callGotoPage(page)
        local stack = UI_mod.getWindowStack()
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w then
                local target, fn
                if type(w.onGotoPage) == "function" and type(w.page_num) == "number" then
                    target = page or w.page_num
                    fn     = function() w:onGotoPage(target) end
                else
                    local fc = w.file_chooser
                    if fc and type(fc.onGotoPage) == "function" and type(fc.page_num) == "number" then
                        target = page or fc.page_num
                        fn     = function() fc:onGotoPage(target) end
                    end
                end
                if fn then pcall(fn); return end
            end
        end
        -- Fallback: FM file_chooser.
        local fm_mod  = package.loaded["apps/filemanager/filemanager"]
        local fm_inst = fm_mod and fm_mod.instance
        if fm_inst and fm_inst.file_chooser then
            local fc = fm_inst.file_chooser
            if type(fc.onGotoPage) == "function" and type(fc.page_num) == "number" then
                local target = page or fc.page_num
                pcall(function() fc:onGotoPage(target) end)
            end
        end
    end

    -- Arrow boundary x-coordinates in screen pixels — used both by the tap
    -- zones and by the hold_release handler to determine which area was held.
    -- Defined here (in scope for the whole function) so the hold_settings
    -- handler can read them without capturing a stale local from a nested block.
    local prev_end_x = arrows_active and (side_m + widths[1])                      or 0
    local next_x     = arrows_active and (side_m + usable_w - widths[total_slots]) or screen_w

    if arrows_active then
        -- ── Prev arrow (slot 1) ──────────────────────────────────────────────
        zones[#zones + 1] = {
            id          = "navbar_pos_prev",
            ges         = "tap",
            overrides   = _OVERRIDES,
            screen_zone = {
                ratio_x = side_m    / screen_w,
                ratio_y = bar_y     / screen_h,
                ratio_w = widths[1] / screen_w,
                ratio_h = nav_h     / screen_h,
            },
            handler = function(_ges)
                local has_prev, _ = Config.getNavpagerState()
                logger.dbg("simpleui tz: navbar_pos_prev fired has_prev=", tostring(has_prev))
                if has_prev then _callPageFn("onPrevPage") end
                return true
            end,
        }

        -- ── Centre tab slots (slots 2 … center_n+1) ─────────────────────────
        local cumulative = widths[1]
        for i = 1, center_n do
            local pos        = i
            local x_start    = side_m + cumulative
            local this_tab_w = widths[i + 1]
            cumulative       = cumulative + this_tab_w
            zones[#zones + 1] = {
                id          = "navbar_pos_" .. i,
                ges         = "tap",
                overrides   = _OVERRIDES,
                screen_zone = {
                    ratio_x = x_start    / screen_w,
                    ratio_y = bar_y      / screen_h,
                    ratio_w = this_tab_w / screen_w,
                    ratio_h = nav_h      / screen_h,
                },
                handler = function(_ges)
                    local action_id = tabs_snap[pos]
                    logger.dbg("simpleui tz: navbar_pos_", pos, "fired action=", tostring(action_id))
                    if not action_id then return true end
                    plugin:_onTabTap(action_id, fm_self)
                    return true
                end,
            }
        end

        -- Pad any unused MAX_TABS slots off-screen (cleanup from standard mode).
        for i = center_n + 1, Config.MAX_TABS do
            zones[#zones + 1] = {
                id          = "navbar_pos_" .. i,
                ges         = "tap",
                screen_zone = { ratio_x = 2, ratio_y = 0, ratio_w = 0.01, ratio_h = 0.01 },
                handler     = function() return false end,
            }
        end

        -- ── Next arrow (last slot) ───────────────────────────────────────────
        zones[#zones + 1] = {
            id          = "navbar_pos_next",
            ges         = "tap",
            overrides   = _OVERRIDES,
            screen_zone = {
                ratio_x = next_x              / screen_w,
                ratio_y = bar_y               / screen_h,
                ratio_w = widths[total_slots] / screen_w,
                ratio_h = nav_h               / screen_h,
            },
            handler = function(_ges)
                local _, has_next = Config.getNavpagerState()
                if has_next then _callPageFn("onNextPage") end
                return true
            end,
        }

    else
        -- ── Standard mode (original behaviour) ──────────────────────────────
        local cumulative_offset = 0
        for i = 1, Config.MAX_TABS do
            local pos    = i
            local active = (i <= num_tabs)
            local x_start, this_tab_w
            if active then
                x_start           = side_m + cumulative_offset
                this_tab_w        = widths[i]
                cumulative_offset = cumulative_offset + widths[i]
            else
                x_start    = screen_w + 1
                this_tab_w = 1
            end
            zones[#zones + 1] = {
                id          = "navbar_pos_" .. i,
                ges         = "tap",
                overrides   = _OVERRIDES,
                screen_zone = {
                    ratio_x = x_start    / screen_w,
                    ratio_y = bar_y      / screen_h,
                    ratio_w = this_tab_w / screen_w,
                    ratio_h = nav_h      / screen_h,
                },
                handler = function(_ges)
                    if not active then return false end
                    if pos > Config.getNumTabs() then return false end
                    local action_id = tabs_snap[pos]
                    if not action_id then return true end
                    plugin:_onTabTap(action_id, fm_self)
                    return true
                end,
            }
        end

        -- Navpager slots moved off-screen (cleanup from a previous navpager session).
        for _, id in ipairs({ "navbar_pos_prev", "navbar_pos_next" }) do
            zones[#zones + 1] = {
                id          = id,
                ges         = "tap",
                screen_zone = { ratio_x = 2, ratio_y = 0, ratio_w = 0.01, ratio_h = 0.01 },
                handler     = function() return false end,
            }
        end
    end

    -- Hold anywhere on the bar → open settings menu.
    local bar_screen_zone = {
        ratio_x = 0,
        ratio_y = bar_y / screen_h,
        ratio_w = 1,
        ratio_h = nav_h / screen_h,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_start",
        ges         = "hold",
        overrides   = { "tap_left_bottom_corner", "tap_right_bottom_corner",
                        "TapBook", "TapColl", "TapQA", "TapGoal", "TapSelect" },
        screen_zone = bar_screen_zone,
        handler     = function(_ges) return true end,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_settings",
        ges         = "hold_release",
        screen_zone = bar_screen_zone,
        handler = function(ges)
            -- When navpager is active, a hold on the Prev or Next arrow jumps
            -- to the first or last page instead of opening the settings menu.
            if arrows_active then
                local x = ges and ges.pos and ges.pos.x or -1
                if x >= 0 and x < prev_end_x then
                    -- Held on Prev arrow → jump to first page.
                    local has_prev, _ = Config.getNavpagerState()
                    if has_prev then _callGotoPage(1) end
                    return true
                end
                if x >= next_x then
                    -- Held on Next arrow → jump to last page.
                    local _, has_next = Config.getNavpagerState()
                    if has_next then _callGotoPage(nil) end
                    return true
                end
            end
            -- Held anywhere else on the bar → open settings menu.
			if not G_reader_settings:nilOrTrue("navbar_bottombar_settings_on_hold") then
				return true
			end
			if not plugin._makeNavbarMenu then plugin:addToMainMenu({}) end
            local UI_mod     = require("sui_core")
            local topbar_on  = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
            local top_offset = topbar_on and require("sui_topbar").TOTAL_TOP_H() or 0
            UI_mod.showSettingsMenu(_("Bottom Bar"), plugin._makeNavbarMenu,
                top_offset, screen_h, M.TOTAL_H())
            return true
        end,
    }

    fm_self:registerTouchZones(zones)

    -- When fm_self is an injected widget (homescreen, collections…) the zones
    -- live on that widget and are consulted while it is on top.  But the FM
    -- underneath also needs the zones so they are active when the FM is the
    -- topmost fullscreen widget.  When fm_self IS the FM this is a no-op.
    local fm_mod  = package.loaded["apps/filemanager/filemanager"]
    local fm_inst = fm_mod and fm_mod.instance
    if fm_inst and fm_inst ~= fm_self and fm_inst.registerTouchZones then
        -- Pass a shallow copy so each widget holds an independent reference.
        -- Both tables point at the same zone-definition sub-tables (handlers,
        -- screen_zone), which is intentional — only the outer list is copied.
        local zones_copy = {}
        for i = 1, #zones do zones_copy[i] = zones[i] end
        fm_inst:registerTouchZones(zones_copy)
    end
end

-- ---------------------------------------------------------------------------
-- Tab tap handler
-- ---------------------------------------------------------------------------

function M.onTabTap(plugin, action_id, fm_self)
    -- Action-only tabs: open their dialog/action without changing the active tab.
    -- The indicator stays on whatever tab was active before the tap.
    -- _ACTION_ONLY is the single authoritative list — same one used by
    -- setActiveAndRefreshFM so the two sites can never drift.
    if _ACTION_ONLY[action_id] then
        if     action_id == "power"            then M.showPowerDialog(plugin)
        elseif action_id == "wifi_toggle"      then M.doWifiToggle(plugin)
        elseif action_id == "frontlight"       then M.showFrontlightDialog()
        elseif action_id == "bookmark_browser" then M.showBookmarkBrowserSourceDialog(plugin.ui)
        end
        return
    end

    -- Load tabs once — navigate reuses this table instead of reloading.
    local tabs = Config.loadTabConfig()

    -- Track whether this tab was already active before the tap.
    local already_active = (plugin.active_action == action_id)

    plugin.active_action = action_id
    -- Skip the eager replaceBar when the homescreen is open: navigate() will
    -- close the HS and call replaceBar+setDirty itself, so doing it here too
    -- produces a redundant buildBarWidget call and extra repaint flushes.
    -- Also skip for "homescreen": UIManager.show calls setActiveAndRefreshFM
    -- when the HS widget is shown, covering the bar update at that point.
    -- Also skip when already_active: the indicator is already correct and
    -- rebuilding the bar would allocate all widgets for an identical result.
    -- Also skip when fm_self is an injected widget (Collections, History, etc.):
    -- navigate() will close it and then call replaceBar on the real FM, so
    -- painting the bar on the about-to-close widget is wasted work.
    local hs_open = (function()
        local HS = package.loaded["sui_homescreen"]
        return HS and HS._instance ~= nil
    end)()
    local injected_open = fm_self ~= plugin.ui and fm_self._navbar_injected
    if fm_self._navbar_container and action_id ~= "homescreen" and not hs_open
            and not already_active and not injected_open then
        M.replaceBar(fm_self, M.buildBarWidget(action_id, tabs), tabs)
        -- setDirty(fm_self) covers the full screen and recurses into navbar_container.
        -- The previous double-dirty (navbar_container + fm_self) queued two e-ink cycles.
        UIManager:setDirty(fm_self, "ui")
    end
    pcall(function() plugin:_updateFMHomeIcon() end)
    plugin:_navigate(action_id, fm_self, tabs, already_active)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

local function showUnavailable(msg)
    UIManager:show(InfoMessage():new{ text = msg, timeout = 3 })
end

local function setActiveAndRefreshFM(plugin, action_id, tabs)
    -- Never mark an action-only tab (bookmark_browser, wifi, etc.) as the
    -- active navigation tab — doing so would light up its indicator even
    -- though the user never "navigated" to it.
    if not _ACTION_ONLY[action_id] then
        plugin.active_action = action_id
    end
    local fm = plugin.ui
    if fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
        UIManager:setDirty(fm, "ui")
    end
    return action_id
end
-- Exported so patches.lua can delegate to it instead of duplicating the body (#3).
M.setActiveAndRefreshFM = setActiveAndRefreshFM

-- ---------------------------------------------------------------------------
-- classify_action: returns true when the action is "in-place" (executes
-- without opening a new fullscreen view) and must NOT close the homescreen.
-- Returns false for navigation actions that open a different screen.
-- ---------------------------------------------------------------------------
local function _isInPlaceAction(action_id)
    if action_id == "wifi_toggle"      then return true end
    if action_id == "frontlight"       then return true end
    if action_id == "power"            then return true end
    if action_id == "stats_calendar"   then return true end
    if action_id == "bookmark_browser" then return true end
    if action_id:match("^custom_qa_%d+$") then
        -- Delegate to sui_quickactions — single source of truth for QA config.
        return _QA().isInPlaceCustomQA(action_id)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- showBookmarkBrowserSourceDialog
-- Shared helper: shows the source-selection ButtonDialog for the bookmark
-- browser. Used by both _executeInPlace (HS open, dialog floats on top) and
-- navigate (HS closed, normal open). Extracted to avoid duplication.
-- `bb_ui`  — the widget context to pass to BookmarkBrowser:show().
-- ---------------------------------------------------------------------------
function M.showBookmarkBrowserSourceDialog(bb_ui)
    local ok_bb, BookmarkBrowser = pcall(require, "ui/widget/bookmarkbrowser")
    if not ok_bb then
        showUnavailable(_("Bookmark browser not available."))
        return
    end
    -- Remember whether the HS was open at call time.
    -- HS lifecycle managed here:
    --   • Cancel  → HS stays open, repaint to clear any dirty region.
    --   • Source chosen → BB opens on top of the HS (no intermediate close).
    --     When the BB closes, the HS is closed intentionally so the user
    --     returns to the bare FM (no _doShowHS re-open loop).
    --
    -- The InfoMessage “Fetching bookmarks…” is marked _navbar_closing_intentionally
    -- so its close does not trigger patchUIManagerClose's "Start with HS" logic.
    local HS = package.loaded["sui_homescreen"]
    local hs_was_open = HS and HS._instance ~= nil
    local home_dir = G_reader_settings:readSetting("home_dir")
    local source_dialog
    local function open_with_source(fetch_fn, subfolders)
        UIManager:close(source_dialog)
        -- Do NOT close the HS here — the BB opens directly on top of it,
        -- avoiding the FM flash that occurred in earlier versions when the
        -- HS was torn down before the nextTick ran.
        local info_msg = require("ui/widget/infomessage"):new{
            text    = _("Fetching bookmarks\xe2\x80\xa6"),
            timeout = 0.1,
            _navbar_closing_intentionally = true,
        }
        UIManager:show(info_msg)
        UIManager:nextTick(function()
            local books = {}
            if type(fetch_fn) == "function" then
                fetch_fn(books)
            else
                local util             = require("util")
                local DocumentRegistry = require("document/documentregistry")
                util.findFiles(fetch_fn, function(file)
                    books[file] = DocumentRegistry:hasProvider(file) or nil
                end, subfolders)
            end
            BookmarkBrowser:show(books, bb_ui)
            -- After BookmarkBrowser:show() its Menu widget is on the stack
            -- on top of the HS. Intercept onCloseWidget so that when the
            -- user dismisses the BB, the HS is closed intentionally (no
            -- _doShowHS loop) and the user returns to the bare FM.
            if hs_was_open then
                local UI_mod = require("sui_core")
                local stack  = UI_mod.getWindowStack()
                for i = #stack, 1, -1 do
                    local w = stack[i] and stack[i].widget
                    if w and w.covers_fullscreen and w.name ~= "homescreen" then
                        local orig_cw = w.onCloseWidget
                        w.onCloseWidget = function(self_w)
                            local hs_inst2 = HS and HS._instance
                            if hs_inst2 then
                                hs_inst2._navbar_closing_intentionally = true
                                UIManager:close(hs_inst2)
                            end
                            self_w._navbar_closing_intentionally = true
                            self_w.onCloseWidget = orig_cw
                            if orig_cw then return orig_cw(self_w) end
                        end
                        break
                    end
                end
            end
        end)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    source_dialog = ButtonDialog:new{
        title           = _("Bookmark browser"),
        title_align     = "center",
        width_factor    = 0.8,
        buttons = {
            {{ text = _("History"), callback = function()
                open_with_source(function(books)
                    for _, v in ipairs(require("readhistory").hist) do
                        books[v.file] = v.select_enabled or nil
                    end
                end)
            end }},
            {{ text = _("Collections"), callback = function()
                open_with_source(function(books)
                    local rc = require("readcollection")
                    if rc.coll then
                        for _, coll in pairs(rc.coll) do
                            for file in pairs(coll) do books[file] = true end
                        end
                    end
                end)
            end }},
            {{ text = _("Home folder"), enabled = home_dir ~= nil,
               callback = function() open_with_source(home_dir, false) end }},
            {{ text = _("Home folder + subfolders"), enabled = home_dir ~= nil,
               callback = function() open_with_source(home_dir, true) end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(source_dialog)
                -- Repaint the HS to clear any dirty region left by the dialog.
                if hs_was_open then
                    local hs_inst = HS and HS._instance
                    if hs_inst then
                        UIManager:setDirty(hs_inst, "full")
                    end
                end
            end }},
        },
    }
    UIManager:show(source_dialog)
end

-- ---------------------------------------------------------------------------
-- _executeInPlace: runs an in-place action while keeping the HS open.
-- The HS is temporarily moved to the bottom of the window stack so that
-- Dispatcher:sendEvent and broadcastEvent reach FM plugins correctly.
-- After execution the HS is restored to the top and repainted.
-- ---------------------------------------------------------------------------
local function _executeInPlace(action_id, plugin, fm)
    local HS      = package.loaded["sui_homescreen"]
    local hs_inst = HS and HS._instance
    local UI_mod  = require("sui_core")
    local stack   = UI_mod.getWindowStack()
    local hs_idx  = nil

    -- bookmark_browser and power open asynchronous widgets (ButtonDialog →
    -- BookmarkBrowser, or PowerDialog) that outlive this function call.
    -- Sinking the HS now and restoring it immediately after would restore the
    -- stack before the user interacts with those widgets, breaking the paint
    -- order when they close (FM appears instead of HS, or BookmarkBrowser
    -- closes back to HS instead of staying open). Skip the sink/restore for
    -- these actions — their dialogs float on top of the HS naturally.
    local needs_stack_sink = action_id ~= "bookmark_browser"
                          and action_id ~= "power"

    -- Sink the HS to position 1 so FM plugins receive events normally.
    -- Only needed for synchronous in-place actions (wifi, frontlight, etc.).
    if needs_stack_sink and hs_inst then
        for i, entry in ipairs(stack) do
            if entry.widget == hs_inst then hs_idx = i; break end
        end
        if hs_idx and hs_idx > 1 then
            local entry = table.remove(stack, hs_idx)
            table.insert(stack, 1, entry)
        end
    end

    if action_id == "wifi_toggle" then
        M.doWifiToggle(plugin)

    elseif action_id == "frontlight" then
        M.showFrontlightDialog()

    elseif action_id == "power" then
        M.showPowerDialog(plugin)

    elseif action_id == "stats_calendar" then
        local ok, err = pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("ShowCalendarView"))
        end)
        if not ok then showUnavailable(_("Statistics plugin not available.")) end

    elseif action_id == "bookmark_browser" then
        -- Show the source-selection ButtonDialog floating above the homescreen.
        -- The HS is not sunk (see needs_stack_sink above) so the dialog appears
        -- on top of the HS and BookmarkBrowser:show() also opens above the HS.
        -- When the user cancels, closing the dialog reveals the HS correctly.
        local _bb_ui = fm
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_rui and ReaderUI and ReaderUI.instance then
            _bb_ui = ReaderUI.instance
        end
        M.showBookmarkBrowserSourceDialog(_bb_ui)

    elseif action_id:match("^custom_qa_%d+$") then
        -- Delegate to sui_quickactions — single source of truth for QA execution.
        _QA().executeCustomQA(action_id, fm, showUnavailable)
    end

    -- Restore HS to its original position and repaint to reflect any changes
    -- from the action (e.g. nightmode inversion, frontlight level update).
    -- Only restore when we actually sank the HS earlier.
    if needs_stack_sink and hs_inst and hs_idx and hs_idx > 1 then
        for i, entry in ipairs(stack) do
            if entry.widget == hs_inst then
                local e = table.remove(stack, i)
                table.insert(stack, hs_idx, e)
                break
            end
        end
    end
    UIManager:setDirty(hs_inst or fm, "ui")
end

function M.navigate(plugin, action_id, fm_self, tabs, force)
    local fm = plugin.ui
    -- "force" doubles as the already_active flag passed from onTabTap.
    local already_active = force

    -- When the FM has been torn down and recreated (e.g. after returning from
    -- the reader), plugin.ui on the *old* plugin instance no longer has
    -- _navbar_container. Fall back to the live FileManager instance so that
    -- replaceBar and _goHome operate on the real widget.
    if not (fm and fm._navbar_container) then
        local FM2 = package.loaded["apps/filemanager/filemanager"]
        local live = FM2 and FM2.instance
        if live and live._navbar_container then
            fm = live
            -- Also sync active_action to the live plugin so the indicator is
            -- updated on the correct plugin instance.
            local live_plugin = live._simpleui_plugin
            if live_plugin and live_plugin ~= plugin then
                live_plugin.active_action = plugin.active_action
                plugin = live_plugin
            end
        end
    end

    -- Detect if the homescreen is currently open (fm_self is the FM but the
    -- HS is on top — the tap came through the HS's injected bottombar).
    local HS = package.loaded["sui_homescreen"]
    local hs_open = HS and HS._instance ~= nil

    logger.dbg("simpleui navigate: action=", action_id, "hs_open=", hs_open)

    -- In-place actions (toggle nightmode, frontlight, wifi, dispatcher, etc.)
    -- must NOT close the homescreen. Execute them directly and return.
    if hs_open and _isInPlaceAction(action_id) then
        _executeInPlace(action_id, plugin, fm)
        return
    end

    -- Replicates FileChooser:goHome() behaviour:
    --   1. Falls back to Device.home_dir if home_dir is unset or the folder is gone.
    --   2. If the FM is already at the home path: page-reset + content refresh.
    --   3. Otherwise: navigate to the home path.
    -- The suppress flag prevents onPathChanged from firing a redundant bar rebuild
    -- (the caller already handles the bar before or after invoking this helper).
    -- Returns true when a home directory was resolved and acted upon, false otherwise.
    local function _goHome(target_fm)
        local fc = target_fm and target_fm.file_chooser
        if not fc then return false end
        local home = G_reader_settings:readSetting("home_dir")
        local lfs  = require("libs/libkoreader-lfs")
        if not home or lfs.attributes(home, "mode") ~= "directory" then
            home = Device.home_dir
        end
        if not home then return false end
        -- If we are inside a virtual series folder, exit it first.
        -- Virtual folders keep fc.path pointing at the real parent directory,
        -- so the fc.path == home check below would incorrectly treat a virtual
        -- folder whose parent is the home dir as "already at home" and call
        -- refreshPath(), which re-enters the virtual folder instead of closing it.
        local in_virtual = fc.item_table and fc.item_table._sg_is_series_view
        if in_virtual then
            -- Clear the virtual-folder flag so changeToPath (and the patched
            -- refreshPath) won't try to restore the series view.
            -- The patched changeToPath in sui_foldercovers will take the
            -- "else" branch (normal filesystem navigation) and clear
            -- _sg_current automatically, since _sg_is_series_view is now false.
            fc.item_table._sg_is_series_view = false
            -- Clear the back-button flag used by the title bar.
            fc._simpleui_has_go_up = false
        end
        if fc.path == home and not in_virtual then
            -- Already at home (and not in a virtual folder). Always go to
            -- page 1 and refresh — this mirrors the "Go to HOME folder" button
            -- behaviour: if the user is on a sub-page of the library, tapping
            -- the tab again scrolls back to the top. Suppress onPathChanged in
            -- both cases (re-tap and cross-tab) because the bar was already
            -- rebuilt by onTabTap.
            -- No refreshPath here: the item_table is already correct in memory
            -- and nothing changed while the overlay was open, so a filesystem
            -- scan would be redundant.
            target_fm._navbar_suppress_path_change = true
            pcall(function() fc:onGotoPage(1) end)
            target_fm._navbar_suppress_path_change = nil
        else
            target_fm._navbar_suppress_path_change = true
            fc:changeToPath(home)
            target_fm._navbar_suppress_path_change = nil
        end
        if target_fm.updateTitleBarPath then
            pcall(function()
                target_fm:updateTitleBarPath(home, true)
            end)
        end
        return true
    end

    if hs_open then
        -- Close the HS first — the FM is invisible underneath so there is no
        -- benefit to navigating it before the close. Doing navigation after
        -- avoids a redundant FM repaint while it is still covered by the HS.
        local hs_inst = HS._instance
        -- When the user taps the homescreen tab while already on the homescreen
        -- (already_active), reset to page 1 NOW — before close — so that
        -- onCloseWidget (which runs deferred) preserves the correct value (1)
        -- via the _navbar_closing_intentionally path, instead of overwriting it
        -- with the stale current page afterwards.
        if already_active and action_id == "homescreen" then
            hs_inst._current_page = 1
        end
        hs_inst._navbar_closing_intentionally = true
        pcall(function() UIManager:close(hs_inst) end)
        hs_inst._navbar_closing_intentionally = nil
        -- Update the FM bar.
        if fm._navbar_container then
            M.replaceBar(fm, M.buildBarWidget(action_id, tabs), tabs)
            UIManager:setDirty(fm, "ui")
        end
        -- For "home": navigate the FM to home_dir now that the HS is gone.
        -- A single setDirty from replaceBar above covers the repaint.
        if action_id == "home" then
            if fm.file_chooser then
                _goHome(fm)
            else
                -- file_chooser not yet created — schedule for next event cycle.
                UIManager:scheduleIn(0, function()
                    _goHome(plugin.ui)
                end)
            end
            return
        end
        -- For other actions, fall through with fm_self = fm.
        fm_self = fm
    end

    -- Close any open sub-window before navigating (non-HS case).
    if fm_self ~= fm then
        fm_self._navbar_closing_intentionally = true
        -- Tell the FM's onCloseAllMenus handler that this close is driven by a
        -- tab-navigation: it must skip its own replaceBar/setDirty because
        -- navigate() will rebuild the bar immediately afterwards.
        -- Without this flag, onCloseAllMenus fires a redundant buildBarWidget +
        -- setDirty, causing a double (sometimes triple) bar rebuild per tap.
        fm._navbar_tab_nav_in_progress = true
        -- Suppress the widget's close_callback for the duration of the
        -- programmatic close. KOReader's booklist/coll_list menus carry a
        -- close_callback that calls UIManager:close(self) again — executing it
        -- here would cause a second close() on the same widget, producing
        -- duplicate log entries and a redundant restore pass.
        local saved_cb = fm_self.close_callback
        fm_self.close_callback = nil
        pcall(function()
            if fm_self.onCloseAllMenus then fm_self:onCloseAllMenus()
            elseif fm_self.onClose     then fm_self:onClose() end
        end)
        fm_self.close_callback = saved_cb
        fm_self._navbar_closing_intentionally = nil
        fm._navbar_tab_nav_in_progress = nil
    end

    if fm_self ~= fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, tabs), tabs)
        UIManager:setDirty(fm, "ui")
    end

    if action_id == "home" then
        local live_fm = plugin.ui or fm
        if not _goHome(live_fm) then
            -- No valid home directory found — repaint whatever is showing.
            if live_fm.file_chooser then
                UIManager:setDirty(live_fm, "partial")
            end
        end

    elseif action_id == "collections" then
        if fm.collections then fm.collections:onShowCollList()
        else showUnavailable(_("Collections not available.")) end

    elseif action_id == "history" then
        local ok = pcall(function() fm.history:onShowHist() end)
        if not ok then showUnavailable(_("History not available.")) end

    elseif action_id == "homescreen" then
        local ok_hs, HS = pcall(require, "sui_homescreen")
        if ok_hs and HS and type(HS.show) == "function" then
            -- QA taps from the homescreen must NOT go through _onTabTap:
            -- _onTabTap calls replaceBar(fm) which schedules a full FM repaint,
            -- and that repaint fires after the homescreen closes and interferes
            -- with dispatcher_action widgets that try to open on top of the FM.
            -- Call navigate directly with fm as the target — no bar replacement.
            -- plugin.ui and loadTabConfig() are resolved at tap time, not at open
            -- time, so FM reinits or tab config changes while the HS is open are
            -- always picked up correctly.
            --
            -- Page-restore logic:
            --   • If _current_page is set and > 1, the HS was closed because the
            --     user navigated into a collection or folder from a module (the
            --     patchUIManagerShow close path sets _navbar_closing_intentionally
            --     so onCloseWidget preserves the page). In this case restore the
            --     saved page so the user lands back on the same HS page.
            --   • If already_active is true the user tapped the home tab while
            --     already on the homescreen (i.e. they are on page 2+ of the HS
            --     itself) → go to page 1 as a "go home" gesture.
            --   • Otherwise (fresh open from another tab, no saved page) → page 1.
            local saved_page = HS._current_page or 1
            logger.dbg("simpleui navigate: homescreen saved_page=", saved_page, "already_active=", already_active)
            if already_active then
                -- User is on a non-home page of the HS and tapped the tab again → page 1.
                HS._current_page = 1
            elseif saved_page > 1 then
                -- Returning from a collection/folder opened via a module → restore page.
                -- Leave HS._current_page as-is; the widget will pick it up in show().
            else
                HS._current_page = 1
            end
            local on_qa_tap = function(aid)
                plugin:_navigate(aid, plugin.ui, Config.loadTabConfig(), false)
            end
            local on_goal_tap = plugin._goalTapCallback or nil
            HS.show(on_qa_tap, on_goal_tap)
        else
            showUnavailable(_("Homescreen not available."))
        end

    elseif action_id == "favorites" then
        if fm.collections then fm.collections:onShowColl()
        else showUnavailable(_("Favorites not available.")) end

    elseif action_id == "bookmark_browser" then
        -- Show the source-selection ButtonDialog floating on top of whatever
        -- is currently visible. Delegates to the shared helper.
        local _bb_ui = fm
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_rui and ReaderUI and ReaderUI.instance then
            _bb_ui = ReaderUI.instance
        end
        M.showBookmarkBrowserSourceDialog(_bb_ui)

    elseif action_id == "continue" then
        local RH = package.loaded["readhistory"] or require("readhistory")
        local fp = RH and RH.hist and RH.hist[1] and RH.hist[1].file
        if fp then
            -- ReaderUI is always present — use package.loaded fast path to
            -- avoid pcall overhead. require() itself is cached after first load.
            local ReaderUI = package.loaded["apps/reader/readerui"]
                or require("apps/reader/readerui")
            ReaderUI:showReader(fp)
        else
            showUnavailable(_("No book in history."))
        end

    elseif action_id == "stats_calendar" then
        -- broadcastEvent reaches all widgets on the stack (including fm.statistics
        -- which is a registered FM plugin) regardless of which widget is on top.
        -- This works from the bottom bar, from QA in the Homescreen, and from
        -- any injected fullscreen widget. Using broadcastEvent directly avoids
        -- the Dispatcher's context checks which can silently no-op when the
        -- Homescreen is the top widget.
        local ok, err = pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("ShowCalendarView"))
        end)
        if not ok then showUnavailable(_("Statistics plugin not available.")) end
        return

    elseif action_id == "wifi_toggle" then
        M.doWifiToggle(plugin); return

    elseif action_id == "browse_authors" or action_id == "browse_series" then
        local bm_mode = (action_id == "browse_authors") and "author" or "series"
        local ok_bm, BM = pcall(_BM)
        if not (ok_bm and BM) then
            showUnavailable(_("Browse by Authors/Series not available."))
            return
        end
        if not BM.isEnabled() then
            showUnavailable(_("Enable 'Browse by Author / Series' in the library menu first."))
            return
        end
        local live_fm = plugin.ui or fm
        local fc = live_fm and live_fm.file_chooser
        if not fc then return end
        if already_active then
            -- Re-tap: return to the virtual root (top of Authors/Series list,
            -- page 1, up button hidden) without leaving the virtual tree.
            BM.navigateToRoot(fc, live_fm, bm_mode)
        else
            BM.navigateTo(live_fm, bm_mode)
        end
        return

    else
        if action_id:match("^custom_qa_%d+$") then
            -- dispatcher_action and plugin_method are handled by _executeInPlace
            -- when the HS is open (caught by _isInPlaceAction above). This branch
            -- only runs when the HS is already closed (e.g. tap from the FM bar).
            -- Delegate to sui_quickactions — single source of truth for QA execution.
            _QA().executeCustomQA(action_id, fm, showUnavailable)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Simple device actions
-- ---------------------------------------------------------------------------

function M.doWifiToggle(plugin)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        UIManager:show(InfoMessage():new{ text = _("WiFi not available on this device."), timeout = 2 })
        return
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        UIManager:show(InfoMessage():new{ text = _("Network manager unavailable."), timeout = 2 })
        return
    end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        UIManager:show(InfoMessage():new{ text = _("Wi-Fi off"), timeout = 1 })
    else
        Config.wifi_optimistic = true
        local ok_on, err = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok_on then
            logger.warn("simpleui: Wi-Fi turn-on error:", tostring(err))
            Config.wifi_optimistic = nil
        end
    end

    -- Immediately refresh ALL wifi indicators with the optimistic state.
    -- This must happen BEFORE broadcastEvent, which triggers
    -- onNetworkConnected/Disconnected and clears wifi_optimistic.
    if plugin then
        -- 1. Bottom bar tabs.
        plugin:_rebuildAllNavbars()

        -- 2. Topbar wifi icon — call refresh() directly (synchronous) instead
        --    of scheduleRefresh(0) which defers to the next event-loop tick,
        --    by which time wifi_optimistic will already be nil.
        local Topbar = require("sui_topbar")
        local cfg    = Config.getTopbarConfig()
        if (cfg.side["wifi"] or "hidden") ~= "hidden" then
            pcall(function() Topbar.refresh(plugin) end)
        end

        -- 3. Quick Actions icons and any other homescreen modules — these are
        --    baked into ImageWidgets at build time, so a setDirty alone is not
        --    enough. refreshImmediate rebuilds the full page synchronously.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            pcall(function() HS.refreshImmediate(false) end)
        end
    end

    -- Broadcast network events so other listeners (e.g. KOReader's own network
    -- status bar) are notified. Set a flag first so onNetworkConnected/Disconnected
    -- knows this event came from us (optimistic state already applied) and should
    -- rebuild the HS without resetting wifi_optimistic.
    Config.wifi_broadcast_self = true
    if wifi_on then
        pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("NetworkDisconnected"))
        end)
    else
        pcall(function()
            UIManager:broadcastEvent(require("ui/event"):new("NetworkConnected"))
        end)
    end
    Config.wifi_broadcast_self = nil

end

function M.refreshWifiIcon(plugin)
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    plugin:_rebuildAllNavbars()
    plugin:_refreshCurrentView()
end

function M.showFrontlightDialog()
    local ok_f, has_fl = pcall(function() return Device:hasFrontlight() end)
    if not ok_f or not has_fl then
        UIManager:show(InfoMessage():new{
            text = _("Frontlight not available on this device."), timeout = 2,
        })
        return
    end
    UIManager:show(require("ui/widget/frontlightwidget"):new{})
end

-- ---------------------------------------------------------------------------
-- Bar rebuild helpers
-- ---------------------------------------------------------------------------

function M.rebuildAllNavbars(plugin)
    if plugin and plugin._simpleui_suspended then return end
    local UI        = require("sui_core")
    local Topbar    = require("sui_topbar")
    M.invalidateDimCache()
    -- Read config once; these values are shared across every widget in the loop.
    local tabs      = Config.loadTabConfig()
    local num_tabs  = Config.getNumTabs()
    local mode      = Config.getNavbarMode()
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local stack     = UI.getWindowStack()  -- read once for the entire operation

    -- Build topbar once and reuse across all widgets — it is identical for all.
    local new_topbar = topbar_on and Topbar.buildTopbarWidget() or nil
    local seen      = {}

    local function rebuildWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(plugin.active_action, tabs, num_tabs, mode), tabs)
        if new_topbar then
            UI.replaceTopbar(w, new_topbar)
        end
        plugin:_registerTouchZones(w)
        UIManager:setDirty(w, "ui")  -- single setDirty — container is a child of w
    end

    rebuildWidget(plugin.ui)
    local ok_icon, err_icon = pcall(function() plugin:_updateFMHomeIcon() end)
    if not ok_icon then logger.warn("simpleui: _updateFMHomeIcon failed:", tostring(err_icon)) end
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(rebuildWidget, entry.widget)
        if not ok then logger.warn("simpleui: rebuildWidget failed:", tostring(err)) end
    end
end

function M.setPowerTabActive(plugin, active, prev_action)
    local tabs    = Config.loadTabConfig()
    local mode    = Config.getNavbarMode()
    local show_id = active and "power" or (prev_action or tabs[1] or "home")
    local seen    = {}

    if not active then plugin.active_action = show_id end

    local function updateWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(show_id, tabs, nil, mode), tabs)
        UIManager:setDirty(w._navbar_container, "partial")
    end

    local UI    = require("sui_core")
    local stack = UI.getWindowStack()
    updateWidget(plugin.ui)
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(updateWidget, entry.widget)
        if not ok then logger.warn("simpleui: setPowerTabActive updateWidget failed:", tostring(err)) end
    end
end

function M.rewrapAllWidgets(plugin)
    local UI        = require("sui_core")
    local tabs      = Config.loadTabConfig()
    local stack     = UI.getWindowStack()  -- read once for the entire operation
    local seen      = {}
    local content_h = UI.getContentHeight()
    local content_y = UI.getContentTop()

    local function rewrapWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        local inner = w._navbar_inner
        if not inner then return end
        -- wrapWithNavbar already builds bar AND topbar internally.
        -- We apply the returned topbar directly via applyNavbarState — no
        -- second buildTopbarWidget() call needed.
        local new_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner, plugin.active_action or tabs[1] or "home", tabs)
        UI.applyNavbarState(w, new_container, bar, topbar, bar_idx, topbar_on2, topbar_idx, tabs)
        w[1] = wrapped

        -- ── Resize the actual content widget to the new content area ──
        -- wrapWithNavbar sets inner.dimen.h but many widgets also carry a
        -- separate .height field (FileChooser, Menu) and a _navbar_height_reduced
        -- guard that blocks re-reduction in patches.lua.  We must reset both so
        -- the widget redraws at the correct size.

        -- 1. inner.dimen is already set by wrapWithNavbar; also update .height/.y
        --    for widgets that use those fields directly (FileChooser, Menu).
        if inner.height ~= nil then
            inner.height = content_h
        end
        if inner.y ~= nil then
            inner.y = content_y
        end
        -- Allow patches.lua injection hook to re-apply on the next show.
        inner._navbar_height_reduced = nil

        -- 2. FileChooser inside the FM widget (plugin.ui / fm).
        local fc = w.file_chooser
        if fc then
            fc.height = content_h
            fc.y      = content_y
            -- Trigger a full relayout so item rows are recalculated.
            local ok_rc = pcall(function() fc:_recalculateDimen() end)
            if not ok_rc then
                -- Fallback: just update dimen directly.
                if fc.dimen then fc.dimen.h = content_h; fc.dimen.y = content_y end
            end
        end

        -- 3. Injected widgets (History, Collections, etc.) that set
        --    .dimen on themselves and their first child.
        if w._navbar_injected then
            w._navbar_height_reduced = nil
            if w.dimen then w.dimen.h = content_h; w.dimen.y = content_y end
            if w[1] and w[1].dimen then w[1].dimen.h = content_h; w[1].dimen.y = content_y end
            -- Recalculate item layout if the widget supports it.
            local ok_rc = pcall(function() w:_recalculateDimen() end)
            if not ok_rc then
                pcall(function()
                    if w[1] then w[1]:_recalculateDimen() end
                end)
            end
        end

        plugin:_registerTouchZones(w)
        -- Resize the pagination chevrons to match Simple UI settings.
        -- This is needed after rotation since onShow does not fire again.
        M.resizePaginationButtons(w.file_chooser or w, M.getPaginationIconSize())
        UIManager:setDirty(w, "ui")  -- single setDirty — container is a child of w
    end

    rewrapWidget(plugin.ui)
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(rewrapWidget, entry.widget)
        if not ok then logger.warn("simpleui: rewrapWidget failed:", tostring(err)) end
    end
end

function M.restoreTabInFM(plugin, tabs, prev_action)
    local fm = plugin.ui
    if not (fm and fm._navbar_container) then return end
    local should_skip = false
    local UI = require("sui_core")
    pcall(function()
        for _i, entry in ipairs(UI.getWindowStack()) do
            if entry.widget and entry.widget._navbar_injected and entry.widget ~= fm then
                should_skip = true; return
            end
        end
    end)
    if should_skip then return end
    -- Always load tabs fresh: the `tabs` argument was captured at widget-open time
    -- and may be stale if the user changed tab config while the widget was open.
    local t = Config.loadTabConfig()
    local Patches = require("sui_patches")
    local restored = (fm.file_chooser and Patches._resolveTabForPath(fm.file_chooser.path, t))
                  or prev_action or (t[1])
    plugin.active_action = restored
    M.replaceBar(fm, M.buildBarWidget(restored, t), t)
    UIManager:setDirty(fm, "ui")
end

-- ---------------------------------------------------------------------------
-- Power dialog
-- ---------------------------------------------------------------------------

function M.showPowerDialog(plugin)
    if plugin._power_dialog then return end  -- guard: ignore double-tap
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog_w = math.floor(Screen:getWidth() * 0.42)
    -- Capture the active tab before opening the dialog so Cancel/close can
    -- restore the bar indicator to the correct state.
    local prev_action = plugin.active_action

    -- _clear is the single point of cleanup for plugin._power_dialog.
    -- It is called from onCloseWidget (fires on every close path, including
    -- programmatic UIManager:close() calls) so the guard is always released
    -- regardless of how the dialog disappears.
    -- _quitting is set by the Restart/Quit/Sleep callbacks so _clear skips
    -- the bar restore on those paths (the app is about to exit or suspend).
    local _quitting = false
    local function _clear()
        plugin._power_dialog = nil
        if _quitting then return end
        -- Restore the bar to whichever tab was active before the dialog opened.
        -- This covers Cancel, tapping outside, and the Back key — all paths
        -- that do not quit/restart/sleep and therefore need the indicator restored.
        M.setPowerTabActive(plugin, false, prev_action)
    end

    -- Build the button list dynamically based on what this device supports.
    -- Each entry is a single-button row: { { text, callback } }.
    local buttons = {}

    if Device:canRestart() then
        buttons[#buttons + 1] = {{ text = _("Restart"), callback = function()
            _quitting = true
            local d = plugin._power_dialog
            plugin._power_dialog = nil
            UIManager:close(d)
            UIManager:flushSettings()
            UIManager:restartKOReader()
        end }}
    end

    if Device:canSuspend() then
        buttons[#buttons + 1] = {{ text = _("Sleep"), callback = function()
            _quitting = true
            local d = plugin._power_dialog
            plugin._power_dialog = nil
            UIManager:close(d)
            UIManager:flushSettings()
            UIManager:suspend()
        end }}
    end

    buttons[#buttons + 1] = {{ text = _("Quit"), callback = function()
        _quitting = true
        local d = plugin._power_dialog
        plugin._power_dialog = nil
        UIManager:close(d)
        UIManager:flushSettings()
        UIManager:quit(0)
    end }}

    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
        local d = plugin._power_dialog
        plugin._power_dialog = nil
        UIManager:close(d)
        -- Bar restore is handled by onCloseWidget → _clear().
    end }}

    plugin._power_dialog = ButtonDialog:new{
        width = dialog_w,
        -- tap_close_callback covers taps outside the dialog and the physical
        -- Back key via ButtonDialog:onClose. onCloseWidget below covers all
        -- remaining paths (programmatic close, stack teardown, etc.).
        tap_close_callback = _clear,
        onCloseWidget      = _clear,
        buttons            = buttons,
    }
    UIManager:show(plugin._power_dialog)
end

return M
