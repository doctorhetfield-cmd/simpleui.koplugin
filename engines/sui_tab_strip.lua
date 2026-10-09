-- sui_tab_strip.lua — Simple UI
-- Compact horizontal tab strip: one text cell per tab with an underline on the
-- active one. The strip can also show a single static label in place of the
-- tabs (used when the tabs do not apply to the current view).
--
-- Usage:
--   local strip = TabStrip.new{
--       width     = px,
--       height    = px,
--       face      = Font face used for every label,
--       tabs      = { { id = "a", label = "A" }, ... },  -- optional; omit for a label-only strip
--                   -- { id = "x", spacer_w = px } reserves a blank cell for an
--                   -- external widget; it is never selectable
--       on_select = function(id) end,
--       fgcolor   = optional color (defaults to the primary text color),
--   }
--   strip:setActive(id)    -- highlight a tab; returns true when the view changed
--   strip:setLabel(text)   -- show a static label; nil restores the tabs
--   strip:setSpan(x, w)    -- move/resize the strip; the next setActive/setLabel
--                          -- call rebuilds the content for the new width
--   strip:getCellX(id)     -- offset where the content of a tab or spacer cell starts;
--                          -- nil while a label is shown. Valid after setActive/setLabel
--
-- The first tab has no leading padding, so its text starts exactly at the
-- strip's left edge. Content swaps never change the strip's geometry; only
-- setSpan does.

local Geom            = require("ui/geometry")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup    = require("ui/widget/overlapgroup")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = require("device").screen

local SUIStyle = require("features/sui_style")

local TabStrip = WidgetContainer:extend{
    width     = nil,
    height    = nil,
    face      = nil,
    tabs      = nil,
    on_select = nil,
    fgcolor   = nil,
    _view_key = nil,
    path_label = nil,
}

-- Tap container shared with the other SimpleUI tab/cell renderers.
local function _tapContainer(content, w, h, id, on_tap)
    local QARenderer = require("engines/sui_quickactions_render")
    return QARenderer.buildTapContainer(content, w, h, id,
        { on_tap_fn = on_tap, tap_event_name = "TapSUITab" }, "TapSUITab")
end

-- Builds the label widget for one tab. The widest of the regular and bold
-- variants fixes the cell width, so selecting a tab never moves its neighbours.
local function _measureLabel(self, label, max_w)
    local fg      = self.fgcolor
    local regular = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0 }
    local bold    = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0, bold = true }
    return regular, bold, math.max(regular:getWidth(), bold:getWidth())
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
        cell[#cell + 1] = LineWidget:new{
            dimen          = Geom:new{ w = e.w, h = underline_h },
            background     = self.fgcolor,
            overlap_offset = { lead_pad, self.height - underline_h },
        }
    end
    local on_tap = e.tab._no_tap and nil or self.on_select
    return _tapContainer(cell, cell_w, self.height, e.tab.id, on_tap)
end

function TabStrip:_buildTabs()
    local nominal_pad = Screen:scaleBySize(14)

    -- 组装渲染源：路径项（若有）在最前，然后是普通 tabs。
    -- 路径项是一个普通 text cell，id 固定 "__path__"，可被 setActive 高亮。
    local source = {}
    if self.path_label and self.path_label ~= "" then
        source[#source + 1] = { id = "__path__", label = self.path_label, _no_tap = true}
    end
    for _i, tab in ipairs(self.tabs) do source[#source + 1] = tab end

    local text_count, spacer_total = 0, 0
    for _i, tab in ipairs(source) do
        if tab.spacer_w then
            spacer_total = spacer_total + tab.spacer_w
        else
            text_count = text_count + 1
        end
    end
    local max_text_w = math.floor((self.width - spacer_total) / math.max(1, text_count))

    local entries, content_total = {}, spacer_total
    for _i, tab in ipairs(source) do
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
    local pad   = math.min(nominal_pad, math.max(0, math.floor((self.width - content_total) / (2 * cells))))

    self._cell_x = {}

    local row, x = HorizontalGroup:new{ allow_mirroring = false }, 0
    for i, e in ipairs(entries) do
        local lead_pad = i == 1 and 0 or pad
        local cell_w   = lead_pad + e.w + pad
        self._cell_x[e.tab.id] = x + lead_pad
        x = x + cell_w
        row[#row + 1] = e.tab.spacer_w and HorizontalSpan:new{ width = cell_w }
            or self:_buildTextCell(e, lead_pad, cell_w)
    end
    return row
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

-- Replaces the content when the requested view differs from the current one.
function TabStrip:_render(view_key, build)
    if self._view_key == view_key then return false end
    self._view_key = view_key
    if self[1] then self[1]:free() end
    self[1] = build()
    return true
end

function TabStrip:setSpan(x, width)
    self.overlap_offset = { x, 0 }
    if width == self.width then return end
    self.width      = width
    self.dimen.w    = width
    self._view_key  = nil
end

function TabStrip:setActive(id)
    self._active = id
    self._label  = nil
    return self:_render("tab:" .. tostring(id), function() return self:_buildTabs() end)
end

function TabStrip:getCellX(id)
    if self._label or not self._cell_x then return nil end
    return self._cell_x[id]
end

-- 设置/清除前置路径项。text 为 nil 或 "" 时移除。
-- 只存字段并让下次 setActive 重建，不直接 render。
function TabStrip:setPathLabel(text)
    text = text or nil
    if self.path_label == text then return false end
    self.path_label = text
    self._view_key  = nil          -- 强制下次 setActive/setLabel 重建
    return true
end

function TabStrip:setLabel(text)
    if not text then return self:setActive(self._active) end
    self._label = text
    return self:_render("label:" .. text, function() return self:_buildLabel(text) end)
end

local M = {}

function M.new(opts)
    local strip = TabStrip:new{
        width     = opts.width,
        height    = opts.height,
        face      = opts.face,
        tabs      = opts.tabs or {},
        on_select = opts.on_select,
        fgcolor   = opts.fgcolor or SUIStyle.COLOR.text_primary,
        dimen     = Geom:new{ w = opts.width, h = opts.height },
    }
    if strip.tabs[1] then strip:setActive(strip.tabs[1].id) end
    return strip
end

return M
