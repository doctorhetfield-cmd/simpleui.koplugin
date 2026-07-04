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
local BD = require("ui/bidi")

local Config = require("sui_config")
local SUISettings = require("sui_store")

-- Lazy reference to sui_style — used by _safeIconFile() to validate icon paths
-- before passing them to ImageWidget. Loaded on first use to avoid a circular
-- require at startup (sui_style requires sui_store, not sui_bottombar).
local function _SUIStyle()
    return package.loaded["sui_style"] or require("sui_style")
end

-- Guard helper: validates an icon file path before it reaches ImageWidget.
-- Returns `path` when valid, `fallback` otherwise (nil = no icon rendered).
-- When `fallback` is nil and the path is bad, the caller must handle the nil
-- return (e.g. skip ImageWidget construction entirely).
local function _safeIconFile(path, fallback)
    local ok, style = pcall(_SUIStyle)
    if ok and style and style.safeIconPath then
        return style.safeIconPath(path, fallback)
    end
    -- sui_style unavailable: minimal inline check (extension only, no lfs).
    if type(path) ~= "string" or path == "" then return fallback end
    local ext = path:match("%.([^.]+)$")
    local supported = { png = true, svg = true, jpg = true, jpeg = true }
    if not ext or not supported[ext:lower()] then
        logger.warn("simpleui/bottombar: unsupported icon format in: " .. path)
        return fallback
    end
    return path
end

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
-- Used by onTabTap (early-return guard), setActiveAndRefreshFM (write guard),
-- and navigate() (active_action write guard).
--
-- This used to be a hand-maintained static table here, separate from
-- QA.isInPlace() ("single authority replacing _isInPlaceAction in bottombar").
-- That duplication had already drifted: night_mode and stats_calendar are
-- valid tab-bar entries (see Config.ALL_ACTIONS) with is_in_place = true in
-- their QA descriptors, but were missing from the static table — so placing
-- either on the bottom bar let it "stick" as the active tab on tap, even
-- though tapping it never navigates anywhere. Custom QAs with a
-- dispatcher_action or plugin_key (not just qa_folder groups) had the same
-- problem. Delegating to QA.isInPlace() closes both gaps for free and
-- removes the second list to keep in sync.
local function _isActionOnly(action_id)
    return _QA().isInPlace(action_id)
end

-- Returns the tab ID that should receive the active indicator when
-- action_id is a browse action (browse_authors/browse_series/browse_tags).
-- Priority: (1) the action's own tab if it is in the tab bar, (2) the
-- "home" (Library) tab if it is in the tab bar, (3) action_id as-is.
-- For non-browse actions returns action_id unchanged so all existing call
-- sites are unaffected. Browse-ness is read from QA.getBrowseMode() (backed
-- by the `browsemeta_mode` field already on the browse_* descriptors)
-- instead of a separate hardcoded id list.
local function _resolveActiveTab(action_id, tabs)
    if not _QA().getBrowseMode(action_id) then return action_id end
    -- Prefer the action's own tab if the user has placed it on the bar.
    for _, tid in ipairs(tabs) do
        if tid == action_id then return action_id end
    end
    -- Fall back to the Library tab.
    for _, tid in ipairs(tabs) do
        if tid == "home" then return "home" end
    end
    -- No suitable tab found — return as-is (bar will show no indicator).
    return action_id
end

local M = {}

-- Bar colors — static defaults used when no theme override is set.
M.COLOR_INACTIVE_TEXT = Blitbuffer.gray(0.55)
M.COLOR_SEPARATOR     = Blitbuffer.gray(0.7)

-- Returns the separator colour: respects the theme "separator" role, then
-- transparent when the user has hidden it, then the default grey.
local function _sepColor()
    local ok, style = pcall(_SUIStyle)
    if ok and style then
        local c = style.getThemeColor("separator")
        if c then return c end
    end
    return M.COLOR_SEPARATOR
end
-- Public accessor used by sui_core.lua to draw the full-width separator line.
function M.sepColor() return _sepColor() end

-- ---------------------------------------------------------------------------
-- Theme color helpers
-- Priority: transparent > bottombar_bg/fg role > bg/fg fallback > default.
-- The "bottombar_bg/fg" roles fall back to "bg/fg" automatically inside
-- SUIStyle.getThemeColor() via the _FALLBACKS chain.
-- ---------------------------------------------------------------------------
local function _getBarBg()
    if M.getBarStyle() == "bare" or SUISettings:isTrue("simpleui_navbar_transparent") then return nil end
    local ok, style = pcall(_SUIStyle)
    if ok and style then
        local c = style.getThemeColor("bottombar_bg")
        if c then return c end
    end
    return Blitbuffer.COLOR_WHITE
end

local function _getBarFg()
    local ok, style = pcall(_SUIStyle)
    if ok and style then
        local c = style.getThemeColor("bottombar_fg")
        if c then return c end
    end
    return Blitbuffer.COLOR_BLACK
end

-- Returns the color for inactive/dim nav items, respecting the theme
-- "text_secondary" role and falling back to the static default.
local function _getInactiveColor()
    local ok, style = pcall(_SUIStyle)
    if ok and style then
        local c = style.getThemeColor("text_secondary")
        if c then return c end
    end
    return M.COLOR_INACTIVE_TEXT
end

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
    return _cached("label_scale_pct", function() return Config.getNavbarLabelScalePct() end)
end
local function _getBottomMarginPct()
    return _cached("bot_margin_pct", function() return Config.getBottomMarginPct() end)
end

function M.getBarStyle()
    return SUISettings:readSetting("simpleui_bar_style") or "default"
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
end

function M.BAR_H()       return _cached("bar_h",   function() return math.floor(Screen:scaleBySize(96) * _getNavbarScale()) end) end
function M.ICON_SZ()     return _cached("icon_sz", function() return math.floor(Screen:scaleBySize(44) * _getNavbarScale() * (_getIconScalePct()  / 100)) end) end
function M.ICON_TOP_SP() return _cached("it_sp",   function() return math.floor(Screen:scaleBySize(10) * _getNavbarScale()) end) end
function M.ICON_TXT_SP() return _cached("itxt_sp", function() return math.floor(Screen:scaleBySize(4)  * _getNavbarScale()) end) end
function M.LABEL_FS()    return _cached("lbl_fs",  function()
    local ok, ss = pcall(_SUIStyle)
    local base = (ok and ss and ss.FS_DETAIL) or 15  -- FS_DETAIL (15)
    return math.floor(base * _getNavbarScale() * (_getLabelScalePct() / 100))
end) end
function M.INDIC_H()     return _cached("indic_h", function() return math.floor(Screen:scaleBySize(3)  * _getNavbarScale()) end) end

-- Structural dimensions — not affected by the size setting.
function M.TOP_SP()      return _cached("top_sp",  function() return Screen:scaleBySize(2)  end) end
function M.BOT_SP()      return _cached("bot_sp",  function() return math.floor(Screen:scaleBySize(12) * _getBottomMarginPct() / 100) end) end
function M.SIDE_M()      return _cached("side_m",  function() return Screen:scaleBySize(24) end) end
function M.SEP_H()
    return _cached("sep_h", function()
        local style = M.getBarStyle()
        if style == "framed" or style == "bare" then
            return 0
        end
        return Screen:scaleBySize(1)
    end)
end

function M.TOTAL_H()
    if not SUISettings:nilOrTrue("simpleui_bar_enabled") then return 0 end
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
        return SUISettings:readSetting("simpleui_bar_pagination_size") or "s"
    end)
end

function M.getPaginationIconSize()
    local key = _getPaginationKey()
    if key == "xs" then return Screen:scaleBySize(20)
    elseif key == "s" then return Screen:scaleBySize(28)
    else return Screen:scaleBySize(36) end
end

function M.getPaginationFontSize()
    local ok, ss = pcall(_SUIStyle)
    local key = _getPaginationKey()
    if key == "xs" then return (ok and ss and ss.FS_CAPTION)  or 12  -- FS_CAPTION (12)
    elseif key == "s" then return (ok and ss and ss.FS_DETAIL)  or 15  -- FS_DETAIL (15)
    else return (ok and ss and ss.FS_SUBTITLE) or 20 end               -- FS_SUBTITLE (20)
end

-- Button field names used by resizePaginationButtons — defined once at module level (P8).
local _PAGINATION_BTN_NAMES = {
    "page_info_left_chev", "page_info_right_chev",
    "page_info_first_chev", "page_info_last_chev",
}

function M.patchDimmedIcon(btn)
    if not btn then return end
    local lw = btn.label_widget or btn.image
    if not lw or lw._sui_dim_patched then return end
    lw._sui_dim_patched = true
    local orig_lw_pt = lw.paintTo
    local Blitbuffer = require("ffi/blitbuffer")
    local UI_core    = require("sui_core")
    lw.paintTo = function(self_lw, bb, x, y)
        if not btn.enabled then
            local sz = self_lw:getSize()
            local w, h = sz.w, sz.h
            if w > 0 and h > 0 then
                if not self_lw._sui_tmp_bb or self_lw._sui_tmp_bb:getWidth() ~= w or self_lw._sui_tmp_bb:getHeight() ~= h then
                    if self_lw._sui_tmp_bb then self_lw._sui_tmp_bb:free() end
                    self_lw._sui_tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
                end
                local saved_dim = self_lw.dim
                local saved_orig_nm = self_lw.original_in_nightmode
                self_lw.dim = nil
                self_lw.original_in_nightmode = true
                
                local fg = _getInactiveColor()
                UI_core.paintWithAlphaMask(self_lw, bb, x, y, w, h, fg, orig_lw_pt, self_lw._sui_tmp_bb)

                self_lw.dim = saved_dim
                self_lw.original_in_nightmode = saved_orig_nm
                return
            end
        end
        orig_lw_pt(self_lw, bb, x, y)
    end
    local orig_lw_free = lw.free
    lw.free = function(self_lw)
        if self_lw._sui_tmp_bb then self_lw._sui_tmp_bb:free(); self_lw._sui_tmp_bb = nil end
        if orig_lw_free then orig_lw_free(self_lw) end
    end
end

function M.resizePaginationButtons(widget, icon_size)
    pcall(function()
        for _i, name in ipairs(_PAGINATION_BTN_NAMES) do
            local btn = widget[name]
            if btn then
                btn.icon_width  = icon_size
                btn.icon_height = icon_size
                btn:init()
                M.patchDimmedIcon(btn)
            end
        end
        local txt = widget.page_info_text
        if txt then
            txt.text_font_size = M.getPaginationFontSize()
            txt:init()
        end
    end)
    -- Apply any user-defined icon overrides for the pagination chevrons.
    -- This is called at every layout/rotation so overrides survive rebuilds.
    pcall(function()
        local ok_ss, style = pcall(_SUIStyle)
        if ok_ss and style and style.applyPaginationIcons then
            style.applyPaginationIcons(widget)
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

local function _makeColoredIcon(file, size, fgcolor)
    local Config = require("sui_config")
    if Config.isNerdIcon(file) then
        local nerd_char = Config.nerdIconChar(file)
        local widget = require("ui/widget/container/widgetcontainer"):new{}
        widget.dimen = Geom():new{ w = size, h = size }
        widget._fg = fgcolor
        local SUIStyle = _SUIStyle()
        local tw = TextWidget():new{
            text = nerd_char,
            face = Font():getFace(SUIStyle and SUIStyle.FACE_ICONS or "symbols", math.floor(size * 0.75)),
            fgcolor = fgcolor,
            padding = 0,
        }
        widget._inner = tw
        function widget:getSize() return self.dimen end
        function widget:paintTo(bb, x, y)
            self.dimen.x, self.dimen.y = x, y
            local w, h = self.dimen.w, self.dimen.h
            if w <= 0 or h <= 0 then return end
            self._inner.fgcolor = self._fg or Blitbuffer.COLOR_BLACK
            local t_sz = self._inner:getSize()
            local ox = x + math.floor((size - t_sz.w) / 2)
            local oy = y + math.floor((size - t_sz.h) / 2)
            self._inner:paintTo(bb, ox, oy)
        end
        function widget:free()
            if self._inner then self._inner:free(); self._inner = nil end
        end
        function widget:onToggleNightMode() require("ui/uimanager"):setDirty(self) end
        function widget:onSetNightMode()    require("ui/uimanager"):setDirty(self) end
        function widget:onApplyTheme()      require("ui/uimanager"):setDirty(self) end
        return widget
    end

    local safe_file = _safeIconFile(file, nil)
    if not safe_file then
        logger.warn("simpleui/bottombar: _makeColoredIcon skipped, invalid file: " .. tostring(file))
        -- Return a transparent placeholder widget of the correct size so
        -- the layout does not collapse when an icon is missing.
        local placeholder = require("ui/widget/container/widgetcontainer"):new{}
        placeholder.dimen = Geom():new{ w = size, h = size }
        function placeholder:getSize() return self.dimen end
        function placeholder:paintTo() end
        return placeholder
    end
    local inner = ImageWidget():new{
        file    = safe_file,
        width   = size,
        height  = size,
        is_icon = true,
        alpha   = true,
        original_in_nightmode = true, -- previne a inversão nativa do ImageWidget
    }
    local widget = require("ui/widget/container/widgetcontainer"):new{}
    widget.dimen = Geom():new{ w = size, h = size }
    widget._inner = inner
    widget._fg = fgcolor

    local UI_core = require("sui_core")
    function widget:getSize() return self.dimen end
    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local w, h = self.dimen.w, self.dimen.h
        if w <= 0 or h <= 0 then return end
        
        if not self._tmp_bb or self._tmp_bb:getWidth() ~= w or self._tmp_bb:getHeight() ~= h then
            if self._tmp_bb then self._tmp_bb:free() end
            self._tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        end
        UI_core.paintWithAlphaMask(self._inner, bb, x, y, w, h, self._fg, nil, self._tmp_bb)
    end
    function widget:free()
        if self._inner then self._inner:free(); self._inner = nil end
        if self._tmp_bb then self._tmp_bb:free(); self._tmp_bb = nil end
    end
    function widget:onToggleNightMode() require("ui/uimanager"):setDirty(self) end
    function widget:onSetNightMode()    require("ui/uimanager"):setDirty(self) end
    function widget:onApplyTheme()      require("ui/uimanager"):setDirty(self) end

    return widget
end

-- Builds one tab cell: active indicator (pinned to top) + icon and/or label.
-- The visible separator line is drawn full-width in wrapWithNavbar (sui_core.lua).
function M.buildTabCell(action_id, active, tab_w, mode)
    local action   = Config.getActionById(action_id)
    local vg       = VerticalGroup():new{ align = "center" }
    local fg       = _getBarFg()
    local SUIStyle = _SUIStyle()
    
    local bar_style = M.getBarStyle()
    local item_fg = fg

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
                    face    = Font():getFace(SUIStyle.FACE_ICONS, math.floor(icon_sz * 0.6)),
                    fgcolor = item_fg,
                    padding = 0,
                },
            }
        else
            local safe_file = _safeIconFile(action.icon, nil)
            if safe_file then
                if bar_style == "framed" then
                    vg[#vg + 1] = _makeColoredIcon(safe_file, M.ICON_SZ(), item_fg)
                else
                    local iw = ImageWidget():new{
                        file    = safe_file,
                        width   = M.ICON_SZ(),
                        height  = M.ICON_SZ(),
                        is_icon = true,
                        alpha   = true,
                    }
                    local ok_render = pcall(function() iw:_render() end)
                    if ok_render then
                        vg[#vg + 1] = iw
                    else
                        iw:free()
                        logger.warn("simpleui/bottombar: buildTabCell ignorou imagem corrompida:", safe_file)
                    end
                end
            end
        end
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            if not _vspan_icon_txt then _vspan_icon_txt = VerticalSpan():new{ width = M.ICON_TXT_SP() } end
            vg[#vg + 1] = _vspan_icon_txt
        end
        vg[#vg + 1] = TextWidget():new{
            text    = action.label,
            face    = Font():getFace(SUIStyle.FACE_REGULAR, M.LABEL_FS()),
            fgcolor = item_fg,
            bold    = active or false,
        }
    end

    -- The content (icon/label) is centred inside BAR_H.
    local content = CenterContainer():new{
        dimen = Geom():new{ w = tab_w, h = M.BAR_H() },
        vg,
    }

-- The active indicator is pinned to the very top of the cell via OverlapGroup,
    -- independent of the vertical centering of the content.
    local og = OverlapGroup():new{
        allow_mirroring = false,
        dimen           = Geom():new{ w = tab_w, h = M.BAR_H() },
        content,
    }

    if bar_style == "default" then
        if active then
            og[#og + 1] = LineWidget():new{
                dimen          = Geom():new{ w = tab_w, h = M.INDIC_H() },
                background     = fg,   -- active underline tracks fg
                overlap_offset = { 0, 0 },
            }
        elseif not SUISettings:isTrue("simpleui_navbar_transparent") then
            og[#og + 1] = LineWidget():new{
                dimen          = Geom():new{ w = tab_w, h = M.INDIC_H() },
                background     = _getBarBg() or Blitbuffer.COLOR_WHITE,
                overlap_offset = { 0, 0 },
            }
        end
    end

    return og
end

-- Builds a navpager arrow cell (Prev or Next).
-- `enabled`  — false → dimmed (no prev/next page exists).
-- `is_prev`  — true → left arrow, false → right arrow.
-- Active navpager arrow color: reads theme "accent" (or bottombar_fg fallback)
-- at call-time so live updates work.
local function _navpagerColorActive()
    local ok, style = pcall(_SUIStyle)
    if ok and style then
        local c = style.getThemeColor("accent")
        if c then return c end
    end
    return _getBarFg()
end

-- Dimmed navpager arrow: respects "text_secondary" theme role.
local function _navpagerColor()
    return _getInactiveColor()
end

function M.buildNavpagerArrowCell(is_prev, enabled, tab_w, mode)
    local icon_file = is_prev and Config.ICON.nav_prev or Config.ICON.nav_next
    local label     = is_prev and _("Prev") or _("Next")
    local color     = enabled and _navpagerColorActive() or _navpagerColor()
    local SUIStyle  = _SUIStyle()

    if SUIStyle then
        local override = SUIStyle.getIcon(is_prev and "sui_navpager_prev" or "sui_navpager_next")
        if override then icon_file = override end
    end

    local vg = VerticalGroup():new{ align = "center" }

    -- References to mutable widgets stored on the OverlapGroup so
    -- updateNavpagerArrows can mutate them in-place without tree traversal.
    local iw, tw

    if mode == "icons" or mode == "both" then
        iw = _makeColoredIcon(icon_file, M.ICON_SZ(), color)
        vg[#vg + 1] = iw
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            if not _vspan_icon_txt then _vspan_icon_txt = VerticalSpan():new{ width = M.ICON_TXT_SP() } end
            vg[#vg + 1] = _vspan_icon_txt
        end
        tw = TextWidget():new{
            text    = label,
            face    = Font():getFace(SUIStyle.FACE_REGULAR, M.LABEL_FS()),
            fgcolor = color,
        }
        vg[#vg + 1] = tw
    end

    local content = CenterContainer():new{
        dimen = Geom():new{ w = tab_w, h = M.BAR_H() },
        vg,
    }

-- Arrow cells never have an active indicator; pin a white (invisible)
    -- LineWidget to the top for visual consistency with buildTabCell.
    -- (Omitted when simpleui_bars_transparent is true to reveal the wallpaper).
    local og = OverlapGroup():new{
        allow_mirroring = false,
        dimen           = Geom():new{ w = tab_w, h = M.BAR_H() },
        content,
    }

    local bar_style = M.getBarStyle()
    if bar_style == "default" and not SUISettings:isTrue("simpleui_navbar_transparent") then
        og[#og + 1] = LineWidget():new{
            dimen          = Geom():new{ w = tab_w, h = M.INDIC_H() },
            background     = _getBarBg() or Blitbuffer.COLOR_WHITE,
            overlap_offset = { 0, 0 },
        }
    end

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

    local hg = bar._navpager_hg or bar[1]
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
        local color = enabled and _navpagerColorActive() or dimmed
        if cc._arrow_image then
            cc._arrow_image._fg = color
        end
        if cc._arrow_text then
            cc._arrow_text.fgcolor = color
        end
    end
    _apply(prev_cc, has_prev)
    _apply(next_cc, has_next)
    return true
end

-- Shared helper to assemble the final FrameContainer for all bottom bar variants.
local function _buildBarContainer(hg_args, is_navpager)
    local style = M.getBarStyle()
    if style == "framed" then
        local radius = math.floor(Screen:scaleBySize(12) * _getNavbarScale())
        local ok, SUIStyle = pcall(_SUIStyle)
        local border_color = (ok and SUIStyle and SUIStyle.getThemeColor("separator")) or Blitbuffer.gray(0.72)
        local inner_bg = _getBarBg()
        

        local border_sz = require("sui_style").BORDER_SZ
        local hg = HorizontalGroup():new(hg_args)
        local fc = FrameContainer():new{
                bordersize = border_sz,
            color      = border_color,
            background = inner_bg,
            radius     = radius,
            padding    = 0, margin = 0,
            hg,
        }

        local wrapper = FrameContainer():new{
            bordersize     = 0, padding = 0, margin = 0,
            padding_left   = M.SIDE_M(),
            padding_right  = M.SIDE_M(),
            padding_top    = M.TOP_SP(),
            padding_bottom = M.BOT_SP(),
            background     = nil,
            fc,
        }
        
        if is_navpager then 
            wrapper._navpager_has_arrows = true
            wrapper._navpager_hg = hg
        end
        return wrapper
    end

    local hg = HorizontalGroup():new(hg_args)
    local fc = FrameContainer():new{
        bordersize      = 0,
        padding         = 0,
        padding_left    = M.SIDE_M(),
        padding_right   = M.SIDE_M(),
        padding_bottom  = M.BOT_SP(),
        margin          = 0,
        background      = _getBarBg(),
        hg,
    }

    local top_vg = VerticalGroup():new{ align = "center" }
    local sep_h = M.SEP_H()
    
    if style == "default" and sep_h > 0 then
        local sep_bg = SUISettings:isTrue("simpleui_navbar_transparent") and nil or M.sepColor()
        local pad_above = M.TOP_SP() - sep_h
        if pad_above > 0 then
            top_vg[#top_vg + 1] = VerticalSpan():new{ width = pad_above }
        end
        top_vg[#top_vg + 1] = LineWidget():new{
            dimen      = Geom():new{ w = Screen:getWidth() - M.SIDE_M() * 2, h = sep_h },
            background = sep_bg,
        }
    else
        top_vg[#top_vg + 1] = VerticalSpan():new{ width = M.TOP_SP() }
    end

    local top_fc = FrameContainer():new{
        bordersize = 0, padding = 0, margin = 0,
        padding_left  = M.SIDE_M(),
        padding_right = M.SIDE_M(),
        background = nil,
        top_vg,
    }

    local wrapper = VerticalGroup():new{
        align = "center",
        top_fc,
        fc,
    }

    if is_navpager then 
        wrapper._navpager_has_arrows = true 
        wrapper._navpager_hg = hg
    end
    
    return wrapper
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

    return _buildBarContainer(hg_args, false)
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

    return _buildBarContainer(hg_args, true)
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
            local kbfg  = _getBarFg()
            cell = OverlapGroup():new{
                dimen = Geom():new{ w = tw, h = tab_h },
                cell,
                LineWidget():new{ dimen = Geom():new{ w = tw, h = bw },    background = kbfg },
                LineWidget():new{ dimen = Geom():new{ w = tw, h = bw },    background = kbfg, overlap_offset = {0, tab_h - bw} },
                LineWidget():new{ dimen = Geom():new{ w = bw, h = tab_h }, background = kbfg },
                LineWidget():new{ dimen = Geom():new{ w = bw, h = tab_h }, background = kbfg, overlap_offset = {tw - bw, 0} },
            }
        end
        hg_args[#hg_args + 1] = cell
    end

    return _buildBarContainer(hg_args, false)
end

local function _showNavbarSettingsWindow(plugin)
    local SUIWindow = require("sui_window")

    local function buildRoot(ctx)
        if not plugin._makeNavbarMenu then plugin:addToMainMenu({}) end
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = plugin._makeNavbarMenu(ctx_menu),
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
            push_stack     = function(id, params)
                if type(id) == "string" then ctx.push(id, params) else ctx.push("nested_menu", params) end
            end,
            on_close       = function() end,
        }
    end

    local function titleFn(ctx)
        local cur = ctx.current()
        local id  = cur and cur.id or "__root__"
        if id == "nested_menu" then return cur.params.title or "" end
        if id == "arrange"     then return cur.params.title or _("Arrange Items") end
        return _("Bottom Bar")
    end

    local win = SUIWindow:new{
        name           = "sui_win_context",
        title          = titleFn,
        screens        = SUIWindow.makeSettingsScreens(buildRoot),
        navpager_mode  = Config.isNavpagerEnabled(),
        position       = "bottom",
        has_settings_btn = true,
    }
    win:show()
end

-- Swaps the bar widget inside an already-wrapped widget, preserving overlap_offset.
function M.replaceBar(widget, new_bar, tabs)
    if not SUISettings:nilOrTrue("simpleui_bar_enabled") then
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
    local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
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
    local navbar_on = SUISettings:nilOrTrue("simpleui_bar_enabled")
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
                    -- In RTL the HorizontalGroup visually reverses the tabs,
                    -- so physical slot i maps to the mirrored tab index.
                    local tab_pos = BD.mirroredUILayout() and (center_n - pos + 1) or pos
                    local action_id = tabs_snap[tab_pos]
                    logger.dbg("simpleui tz: navbar_pos_", pos, "fired action=", tostring(action_id),
                        "(tab_pos=", tab_pos, "rtl=", tostring(BD.mirroredUILayout()), ")")
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
                    -- In RTL the HorizontalGroup visually reverses the tabs,
                    -- so physical slot i maps to the mirrored tab index.
                    local cur_n = Config.getNumTabs()
                    local tab_pos = BD.mirroredUILayout() and (cur_n - pos + 1) or pos
                    local action_id = tabs_snap[tab_pos]
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
            if not SUISettings:nilOrTrue("simpleui_bar_settings_on_hold") then
                return true
            end
            _showNavbarSettingsWindow(plugin)
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
    -- Action-only tabs: fire their action without changing the active tab.
    -- Delegated entirely to QA.execute — no action-specific knowledge needed here.
    if _isActionOnly(action_id) then
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0, function()
            _QA().execute(action_id, { plugin = plugin, fm = fm_self })
        end)
        return
    end

    -- Load tabs once — navigate reuses this table instead of reloading.
    local tabs = Config.loadTabConfig()

    -- Track whether this tab was already active before the tap.
    local already_active = (plugin.active_action == action_id)

    -- For browse actions (authors/series/tags), the indicator tab may differ
    -- from the action_id itself (own tab if present, else Library).
    local indicator_tab = _resolveActiveTab(action_id, tabs)
    plugin.active_action = indicator_tab
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
        M.replaceBar(fm_self, M.buildBarWidget(indicator_tab, tabs), tabs)
        -- setDirty(fm_self) covers the full screen and recurses into navbar_container.
        -- The previous double-dirty (navbar_container + fm_self) queued two e-ink cycles.
        UIManager:setDirty(fm_self, "ui")
    end
    -- When the homescreen is open, update its bar immediately so the active
    -- indicator reflects the new tab before navigate() closes the HS.
    -- Without this, the indicator only updates after the HS closes (via the
    -- FM replaceBar in navigate()), which means it never visually updates on
    -- the HS bar — noticeable when navpager is disabled.
    if hs_open and action_id ~= "homescreen" and not already_active then
        local HS = package.loaded["sui_homescreen"]
        local hs_inst = HS and HS._instance
        if hs_inst and hs_inst._navbar_container then
            M.replaceBar(hs_inst, M.buildBarWidget(indicator_tab, tabs), tabs)
            UIManager:setDirty(hs_inst, "ui")
        end
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
    if not _isActionOnly(action_id) then
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
-- _isInPlaceAction: fully delegated to QA.isInPlace — single authority.
-- ---------------------------------------------------------------------------
local function _isInPlaceAction(action_id)
    return _QA().isInPlace(action_id)
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

    -- bookmark_browser, power, and QA groups open asynchronous widgets that
    -- outlive this function call. Skip the HS sink/restore for those — their
    -- dialogs float on top of the HS naturally. All other synchronous in-place
    -- actions (wifi, frontlight, stats, dispatcher, plugin) need the sink so
    -- FM plugins receive events. QA.isInPlace already ensures only those
    -- reach this path.
    local needs_stack_sink = action_id ~= "bookmark_browser"
                          and action_id ~= "power"
                          and not _QA().isAsyncInPlaceCustomQA(action_id)

    if needs_stack_sink and hs_inst then
        for i, entry in ipairs(stack) do
            if entry.widget == hs_inst then hs_idx = i; break end
        end
        if hs_idx and hs_idx > 1 then
            local entry = table.remove(stack, hs_idx)
            table.insert(stack, 1, entry)
        end
    end

    -- Fully delegated to QA.execute — no action-specific knowledge here.
    _QA().execute(action_id, { plugin = plugin, fm = fm, show_unavailable = showUnavailable })

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
    -- When the HS tab is tapped from inside the reader, route through
    -- closeReaderToHomescreen so onClose(false) suppresses the reader's
    -- internal "full" refresh — same flash-free path as the gesture handler.
    -- via_gesture=false: a tab tap is not a gesture, so "gesture_only" notice
    -- mode must not fire for this path.
    if action_id == "homescreen" then
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then
            local ok_p, Patches = pcall(require, "sui_patches")
            if ok_p and Patches then
                Patches.closeReaderToHomescreen(plugin, false)
                return
            end
        end
    end

    local fm = plugin.ui
    -- "force" doubles as the already_active flag passed from onTabTap.
    local already_active = force

    -- tabs may not be loaded yet when navigate() is called directly (e.g.
    -- from on_qa_tap in the homescreen). Load them now if needed so that
    -- _resolveActiveTab has the real tab config to work with.
    tabs = tabs or Config.loadTabConfig()

    -- Resolve the indicator tab for browse actions (authors/series/tags):
    -- use the action's own tab if it is on the bar, otherwise Library.
    -- This must happen before the FM-fallback block so that the synced
    -- live_plugin.active_action already carries the correct value.
    local indicator_tab = _resolveActiveTab(action_id, tabs)
    if not _isActionOnly(action_id) then
        plugin.active_action = indicator_tab
    end

    -- When the FM has been torn down and recreated (e.g. after returning from
    -- the reader), plugin.ui on the *old* plugin instance no longer has
    -- _navbar_container. Fall back to the live FileManager instance so that
    -- replaceBar and QA.execute operate on the real widget.
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
        -- Update the FM bar. indicator_tab was resolved at the top of navigate()
        -- and already stored in plugin.active_action.
        if fm._navbar_container then
            M.replaceBar(fm, M.buildBarWidget(indicator_tab, tabs), tabs)
            UIManager:setDirty(fm, "ui")
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
        M.replaceBar(fm, M.buildBarWidget(_resolveActiveTab(action_id, tabs), tabs), tabs)
        UIManager:setDirty(fm, "ui")
    end

    -- Fully delegated to QA.execute.
    -- ctx carries everything the descriptor closures need:
    --   plugin, fm, show_unavailable, already_active.
    -- The homescreen descriptor handles its own page-restore logic internally.
    _QA().execute(action_id, {
        plugin         = plugin,
        fm             = fm,
        show_unavailable = showUnavailable,
        already_active = already_active,
    })
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
    local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")
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

function M.setTempTabActive(plugin, action_id, active, prev_action)
    local tabs    = Config.loadTabConfig()
    local mode    = Config.getNavbarMode()
    local show_id = active and action_id or (prev_action or tabs[1] or "home")
    local seen    = {}

    if not active then plugin.active_action = show_id end

    local function updateWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(show_id, tabs, nil, mode), tabs)
        -- setDirty(w) covers the full screen and recurses into navbar_container
        -- (see the identical note in onTabTap). Dirtying just the sub-container
        -- was the previous approach here and is unreliable once a dialog is
        -- about to be shown on top of w: the indicator update could silently
        -- get dropped instead of repainting alongside the dialog.
        UIManager:setDirty(w, "ui")
    end

    local UI    = require("sui_core")
    local stack = UI.getWindowStack()
    updateWidget(plugin.ui)
    for _i, entry in ipairs(stack) do
        local ok, err = pcall(updateWidget, entry.widget)
        if not ok then logger.warn("simpleui: setPowerTabActive updateWidget failed:", tostring(err)) end
    end
end

function M.setPowerTabActive(plugin, active, prev_action)
    M.setTempTabActive(plugin, "power", active, prev_action)
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

            local ok_p, Patches = pcall(require, "sui_patches")
            if ok_p and Patches and Patches.injectWallpaperIntoFullscreenWidget then
                pcall(Patches.injectWallpaperIntoFullscreenWidget, w)
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

return M
