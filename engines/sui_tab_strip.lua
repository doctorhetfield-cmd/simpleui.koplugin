-- sui_tab_strip.lua — Simple UI
-- Compact horizontal tab strip with two styles:
--   "underline" (default)  one text cell per tab, underline on the active one
--   "pill"                 tabs inside a rounded box, the active one drawn as
--                          an inverted pill
-- Both can show a sliding window of `visible_count` tabs with chevrons to
-- move it.
-- The strip can also show a single static label in place of the tabs (used
-- when the tabs do not apply to the current view).
--
-- Usage:
--   local strip = TabStrip.new{
--       width     = px,
--       height    = px,
--       face      = Font face used for every label,
--       tabs      = { { id = "a", label = "A" }, ... },  -- optional; omit for a label-only strip
--                   -- { id = "x", spacer_w = px } reserves a blank cell for an
--                   -- external widget; it is never selectable (underline style only)
--       on_select = function(id) end,
--       on_hold   = optional function(id) end, called on a long press of a tab
--                   (or a hold key while it has the D-pad focus)
--       fgcolor   = optional color (defaults to the primary text color),
--       ink_fn    = optional function returning the text colour (nil: the
--                   plain one), read on every render; replaces fgcolor and
--                   draws the active underline in that colour,
--       indicator = optional { color, fg }: colour of the active indicator and
--                   of the label on it (default: the accent),
--       style     = "underline" | "pill" (default "underline"),
--       visible_count = tabs shown at once (default: all). Chevrons appear
--                       only when there are more tabs than that, and each
--                       one only while the window can move in its direction;
--                       a missing chevron leaves its space to the tabs
--       on_scroll     = function(first) end, called when a chevron asks for the
--                       window to start at tab index `first`; the owner
--                       rebuilds the strip with that `first`. Required when
--                       the tabs do not all fit
--       first         = index of the leftmost visible tab, to resume a window
--                       position received through on_scroll
--       active        = initially active tab id (default: the first tab)
--       -- pill style only:
--       radius        = corner radius of the box in px (default: fully
--                       rounded); the active pill follows it concentrically
--       surface       = resolved surface of the box (see sui_backdrop.lua):
--                       strength, color and frame thickness border_sz. A
--                       strip with neither frame nor backdrop (the default)
--                       has no box: its pills span the full height instead
--                       of sitting inset
--   }
--   strip:setActive(id, keep_window)
--                          -- highlight a tab, scrolling the window to show it
--                          -- unless `keep_window`; returns true when the view
--                          -- changed
--   TabStrip.height(style, face, surface)
--                          -- minimum strip height of a style; `surface` is the
--                          -- pill option of TabStrip.new
--   strip:setLabel(text)   -- show a static label; nil restores the tabs
--   strip:refresh()        -- rebuild the tabs or label on display after the
--                          -- colours changed; returns true when they changed
--   strip:setSpan(x, w)    -- move/resize the strip; the next setActive/setLabel
--                          -- call rebuilds the content for the new width
--   strip:getCellX(id)     -- offset where the content of a tab or spacer cell starts;
--                          -- nil while a label is shown or the tab is outside the
--                          -- window. Valid after setActive/setLabel
--   strip:getStops()       -- D-pad focus stops of the content on display, left
--                          -- to right: { id, widget, x } for each tab and each
--                          -- window chevron (id "prev" / "next"), x being the
--                          -- offset from the strip's left edge. Empty while a
--                          -- label is shown. Valid after setActive/setLabel
--
-- In the underline style the first tab has no leading padding, so its text
-- starts exactly at the strip's left edge (right after the chevron while one
-- is shown). Content swaps never change the
-- strip's geometry; only setSpan does.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Backdrop        = require("infra/sui_backdrop")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = require("device").screen

local Accent    = require("infra/sui_accent")
local SUIStyle  = require("features/sui_style")
local TabWindow = require("engines/sui_tab_window")

-- Metrics (base pixels, scaled at use time). Each chevron button fills its
-- arrow cell, so the whole cell is its tap zone.
local PILL_GAP      = 3   -- space between the box and the active pill
local PILL_TEXT_PAD = 6   -- minimum space between a label and its pill edge
local PILL_V_PAD    = 4   -- space above and below a label inside its pill
local ARROW_PAD     = 10  -- horizontal space around each chevron

-- Surface of a strip without a box: no fill and no frame.
local NO_SURFACE = { strength = 0, border_sz = 0 }

local TabStrip = WidgetContainer:extend{
    width         = nil,
    height        = nil,
    face          = nil,
    tabs          = nil,
    on_select     = nil,
    on_hold       = nil,
    fgcolor       = nil,
    ink_fn        = nil,
    indicator     = nil,
    style         = "underline",
    visible_count = nil,
    on_scroll     = nil,
    radius        = nil,
    surface       = NO_SURFACE,
    _first        = 1,
    _view_key     = nil,
    _stops        = nil,
}

-- Tap container shared with the other SimpleUI tab/cell renderers.
local function _tapContainer(content, w, h, id, on_tap, on_hold)
    local QARenderer = require("engines/sui_quickactions_render")
    return QARenderer.buildTapContainer(content, w, h, id,
        { on_tap_fn = on_tap, on_hold_fn = on_hold, tap_event_name = "TapSUITab", focusable = true }, "TapSUITab")
end

-- Builds the label widget for one tab. The widest of the regular and bold
-- variants fixes the cell width, so selecting a tab never moves its neighbours.
local function _measureLabel(self, label, max_w)
    local fg      = self.fgcolor
    local regular = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0 }
    local bold    = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0, bold = true }
    return regular, bold, math.max(regular:getWidth(), bold:getWidth())
end

-- Records a D-pad focus stop of the content being built.
function TabStrip:_addStop(id, widget, x)
    local stops = self._stops
    stops[#stops + 1] = { id = id, widget = widget, x = x }
end

-- Records the window chevrons around the tab stops already recorded; `lead`
-- and `trail` are the chevron cells of `_openWindow`, each holding its button.
function TabStrip:_addChevronStops(lead, trail)
    local stops = self._stops
    if lead  then table.insert(stops, 1, { id = "prev", widget = lead[1], x = 0 }) end
    if trail then stops[#stops + 1] = { id = "next", widget = trail[1], x = self.width } end
end

-- Builds the cell of one text tab: the label plus, for the active tab, an underline.
function TabStrip:_buildTextCell(e, lead_pad, cell_w)
    local active = e.tab.id == self._active
    local text   = active and e.bold or e.regular
    local unused = active and e.regular or e.bold
    unused:free()

    local cell_dim = Geom:new{ w = cell_w, h = self.height }
    local cell = OverlapGroup:new{
        allow_mirroring = false,
        dimen           = cell_dim,
        LeftContainer:new{
            dimen = cell_dim,
            HorizontalGroup:new{ HorizontalSpan:new{ width = lead_pad }, text },
        },
    }
    if active then
        local underline_h = Screen:scaleBySize(2)
        local underline = require("infra/sui_core").solidBar(e.w, underline_h, (self:_indicator()))
        underline.overlap_offset = { lead_pad, self.height - underline_h }
        cell[#cell + 1] = underline
    end
    return _tapContainer(cell, cell_w, self.height, e.tab.id, self.on_select, self.on_hold)
end

function TabStrip:_buildUnderlineTabs()
    local nominal_pad = Screen:scaleBySize(14)
    local tabs, lead, trail, lead_w, tabs_w = self:_openWindow(self.height, self.width, true)

    local text_count, spacer_total = 0, 0
    for _i, tab in ipairs(tabs) do
        if tab.spacer_w then
            spacer_total = spacer_total + tab.spacer_w
        else
            text_count = text_count + 1
        end
    end
    local max_text_w = math.floor((tabs_w - spacer_total) / math.max(1, text_count))

    local entries, content_total = {}, spacer_total
    for _i, tab in ipairs(tabs) do
        if tab.spacer_w then
            entries[#entries + 1] = { tab = tab, w = tab.spacer_w }
        else
            local regular, bold, w = _measureLabel(self, tab.label, max_text_w)
            entries[#entries + 1] = { tab = tab, regular = regular, bold = bold, w = w }
            content_total = content_total + w
        end
    end

    -- Shrink the horizontal padding evenly when the content does not fit.
    local cells = math.max(1, #entries)
    local pad   = math.min(nominal_pad, math.max(0, math.floor((tabs_w - content_total) / (2 * cells))))

    self._cell_x = {}

    local row, x = HorizontalGroup:new{ allow_mirroring = false }, lead_w
    if lead then row[#row + 1] = lead end
    for i, e in ipairs(entries) do
        local lead_pad = i == 1 and 0 or pad
        local cell_w   = lead_pad + e.w + pad
        self._cell_x[e.tab.id] = x + lead_pad
        if e.tab.spacer_w then
            row[#row + 1] = HorizontalSpan:new{ width = cell_w }
        else
            local cell = self:_buildTextCell(e, lead_pad, cell_w)
            self:_addStop(e.tab.id, cell, x)
            row[#row + 1] = cell
        end
        x = x + cell_w
    end
    if trail then
        -- The trailing chevron sits at the strip's right edge.
        row[#row + 1] = HorizontalSpan:new{ width = math.max(0, lead_w + tabs_w - x) }
        row[#row + 1] = trail
    end
    self:_addChevronStops(lead, trail)
    return row
end

-- Number of tabs shown at once.
function TabStrip:_visibleCount()
    local total = #self.tabs
    return math.max(1, math.min(self.visible_count or total, total))
end

function TabStrip:_indexOf(id)
    for i, tab in ipairs(self.tabs) do
        if tab.id == id then return i end
    end
end

-- Opens the visible window of the tabs. When the tabs do not all fit, a
-- chevron cell sits at each end where the window can still move; an end
-- without one gives its space to the tabs. `cell_h` is the height of the cells
-- and `avail_w` the width they share. With `flush` the chevron icons meet the
-- outer edges of the strip: the padding that widens each tap zone overflows
-- outwards instead of taking space. Returns the tabs in view, the leading
-- and trailing chevron cells (nil when absent), the width of the leading one
-- and the width left for the tabs.
function TabStrip:_openWindow(cell_h, avail_w, flush)
    local PageNav = require("engines/sui_page_nav")

    local total   = #self.tabs
    local visible = self:_visibleCount()
    local first   = TabWindow.clamp(self._first, total, visible)
    self._first   = first

    local lead, trail
    local arrow_w = 0
    if total > visible then
        local arrow_pad = Screen:scaleBySize(ARROW_PAD)
        arrow_w = Screen:scaleBySize(PageNav.ICON_SIZE) + (flush and 1 or 2) * arrow_pad
        local prev_btn, next_btn = PageNav.buildButtons(first, TabWindow.maxFirst(total, visible), cell_h,
            function(delta) self:_scroll(delta) end, {
                h_pad         = arrow_pad,
                hide_disabled = true,
                focusable     = true,
            })
        local function arrowCell(button, Container)
            return button and Container:new{ dimen = Geom:new{ w = arrow_w, h = cell_h }, button }
        end
        local lead_container, trail_container = CenterContainer, CenterContainer
        if flush then lead_container, trail_container = RightContainer, LeftContainer end
        lead, trail = arrowCell(prev_btn, lead_container), arrowCell(next_btn, trail_container)
    end
    local lead_w  = lead and arrow_w or 0
    local trail_w = trail and arrow_w or 0

    local tabs = {}
    for i = 1, math.min(visible, total) do tabs[i] = self.tabs[first + i - 1] end
    return tabs, lead, trail, lead_w, avail_w - lead_w - trail_w
end

-- Frame thickness and space between the frame and the active pill. A pill
-- strip with neither frame nor backdrop has no box, so its pill spans the full
-- height.
local function pillInsets(surface)
    if surface.strength <= 0 and surface.border_sz <= 0 then return 0, 0 end
    return surface.border_sz, Screen:scaleBySize(PILL_GAP)
end

-- Builds the cell of one pill tab: the label centred in the cell, on an
-- inverted pill when active.
function TabStrip:_buildPillCell(tab, cell_w, cell_h, gap, pill_radius)
    local active   = tab.id == self._active
    local text_pad = Screen:scaleBySize(PILL_TEXT_PAD)
    local pill_dim = Geom:new{ w = cell_w - 2 * gap, h = cell_h - 2 * gap }

    local label = TextWidget:new{
        text                   = tab.label,
        face                   = self.face,
        bold                   = active,
        fgcolor                = active and select(2, self:_indicator()) or self.fgcolor,
        max_width              = pill_dim.w - 2 * text_pad,
        truncate_with_ellipsis = true,
        padding                = 0,
    }
    local content = label
    if active then
        -- Anti-aliased fill, so the rounded edges match the box frame.
        content = OverlapGroup:new{
            allow_mirroring = false,
            dimen           = pill_dim,
            Backdrop.BackdropFill:new{
                width    = pill_dim.w,
                height   = pill_dim.h,
                strength = Backdrop.STRENGTH_MAX,
                radius   = pill_radius,
                color    = (self:_indicator()),
                dimen    = pill_dim,
            },
            CenterContainer:new{ dimen = pill_dim, label },
        }
    end
    local cell_dim = Geom:new{ w = cell_w, h = cell_h }
    return _tapContainer(CenterContainer:new{ dimen = cell_dim, content },
        cell_w, cell_h, tab.id, self.on_select, self.on_hold)
end

-- Builds the pill style: a rounded box holding the visible window of tabs.
function TabStrip:_buildPillTabs()
    local border, gap = pillInsets(self.surface)
    local inner_h = self.height - 2 * border
    local radius  = math.min(self.radius or self.height, math.floor(self.height / 2))
    local pill_radius = math.max(0, math.min(radius - border - gap,
        math.floor((inner_h - 2 * gap) / 2)))

    local tabs, lead, trail, lead_w, tabs_w = self:_openWindow(inner_h, self.width - 2 * border)
    local widths = TabWindow.cellWidths(tabs_w, #tabs)

    local row = HorizontalGroup:new{ allow_mirroring = false }
    if lead then row[#row + 1] = lead end

    self._cell_x = {}
    local x = border + lead_w
    for i, tab in ipairs(tabs) do
        self._cell_x[tab.id] = x
        local cell = self:_buildPillCell(tab, widths[i], inner_h, gap, pill_radius)
        self:_addStop(tab.id, cell, x)
        row[#row + 1] = cell
        x = x + widths[i]
    end
    if trail then row[#row + 1] = trail end
    self:_addChevronStops(lead, trail)

    local dimen = Geom:new{ w = self.width, h = self.height }
    local box = OverlapGroup:new{ allow_mirroring = false, dimen = dimen }
    if gap > 0 then
        box[#box + 1] = Backdrop.BackdropFill:new{
            width   = self.width,
            height  = self.height,
            surface = self.surface,
            radius  = radius,
            dimen   = dimen,
        }
    end
    box[#box + 1] = FrameContainer:new{ bordersize = 0, margin = 0, padding = border, row }
    return box
end

function TabStrip:_buildTabs()
    if self.style == "pill" then return self:_buildPillTabs() end
    return self:_buildUnderlineTabs()
end

function TabStrip:_buildLabel(text)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        TextWidget:new{
            text      = text,
            face      = self.face,
            fgcolor   = self.fgcolor,
            bold      = true,
            max_width = self.width,
            padding   = 0,
        },
    }
end

-- Colour of the active tab's indicator (the underline, or the pill) and of the
-- label on the pill. The accent unless the owner gave `indicator`
-- ({ color, fg }), as it does over a fill the accent would blend into.
function TabStrip:_indicator()
    local indicator = self.indicator
    if indicator then return indicator.color, indicator.fg end
    return SUIStyle.accent(self.fgcolor), SUIStyle.accentFg(Blitbuffer.COLOR_WHITE)
end

-- Takes the text colour from `ink_fn` (nil: the plain colour) so a strip over
-- a fill that changes follows it; the underline then uses that colour too.
-- Returns a key that changes with it.
function TabStrip:_resolveInk()
    if not self.ink_fn then return "" end
    local ink = self.ink_fn()
    self.fgcolor   = ink or SUIStyle.COLOR.text_primary
    self.indicator = ink and { color = ink, fg = SUIStyle.COLOR.surface } or nil
    return ink and tostring(ink:getColor8().a) or "-"
end

-- Replaces the content when the requested view differs from the current one.
function TabStrip:_render(view_key, build)
    if self._view_key == view_key then return false end
    self._view_key = view_key
    self._stops    = {}
    if self[1] then self[1]:free() end
    self[1] = build()
    return true
end

function TabStrip:_renderTabs()
    local key = "tab:" .. tostring(self._active) .. ":" .. self._first .. ":" .. Accent.stamp()
        .. ":" .. self:_resolveInk()
    return self:_render(key, function() return self:_buildTabs() end)
end

-- Asks the owner to move the window by `delta` tabs, leaving the active tab
-- unchanged. Nothing happens at either end of the list.
function TabStrip:_scroll(delta)
    local first = TabWindow.shift(self._first, delta, #self.tabs, self:_visibleCount())
    if first ~= self._first and self.on_scroll then self.on_scroll(first) end
end

function TabStrip:setSpan(x, width)
    self.overlap_offset = { x, 0 }
    if width == self.width then return end
    self.width      = width
    self.dimen.w    = width
    self._view_key  = nil
end

function TabStrip:setActive(id, keep_window)
    self._active = id
    self._label  = nil
    local index = self:_indexOf(id)
    if index and not keep_window then
        self._first = TabWindow.reveal(self._first, index, #self.tabs, self:_visibleCount())
    end
    return self:_renderTabs()
end

function TabStrip:getStops()
    return self._stops or {}
end

function TabStrip:getCellX(id)
    if self._label or not self._cell_x then return nil end
    return self._cell_x[id]
end

-- Rebuilds the tabs or label on display when the colours they are painted in
-- have changed. Returns true when the content changed.
function TabStrip:refresh()
    if self._label then return self:setLabel(self._label) end
    if #self.tabs == 0 then return false end
    return self:_renderTabs()
end

function TabStrip:setLabel(text)
    if not text then return self:setActive(self._active) end
    self._label = text
    return self:_render("label:" .. text .. ":" .. self:_resolveInk(), function() return self:_buildLabel(text) end)
end

local M = {}

-- Height a strip of `style` needs for labels drawn with `face`. `surface` is
-- the pill option of M.new.
function M.height(style, face, surface)
    local border, gap = 0, 0
    if style == "pill" then
        border, gap = pillInsets(surface or NO_SURFACE)
    end
    return SUIStyle.faceHeight(face) + 2 * (border + gap + Screen:scaleBySize(PILL_V_PAD))
end

function M.new(opts)
    local strip = TabStrip:new{
        width         = opts.width,
        height        = opts.height,
        face          = opts.face,
        tabs          = opts.tabs or {},
        on_select     = opts.on_select,
        on_hold       = opts.on_hold,
        fgcolor       = opts.fgcolor or SUIStyle.COLOR.text_primary,
        ink_fn        = opts.ink_fn,
        indicator     = opts.indicator,
        style         = opts.style,
        visible_count = opts.visible_count,
        on_scroll     = opts.on_scroll,
        radius        = opts.radius,
        surface       = opts.surface,
        dimen         = Geom:new{ w = opts.width, h = opts.height },
        _first        = opts.first or 1,
    }
    local active = opts.active
    if active == nil and strip.tabs[1] then active = strip.tabs[1].id end
    if active ~= nil then strip:setActive(active, opts.first ~= nil) end
    return strip
end

return M
