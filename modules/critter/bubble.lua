-- bubble.lua — Simple UI
-- Speech bubble of the Critter module: a rounded box of fixed size holding a
-- bold main line (at most two lines) and a smaller secondary line (at most two),
-- with a triangular tail pointing at the critter. The size does not depend on
-- the text: the width is the one it is given and the height that of the
-- fullest text, which is centred vertically.
--
-- The bubble paints its own surface, so its ink does not depend on the module
-- background. In the "smooth" style the outline, the corners and the tail are
-- anti-aliased; in the "pixel" style (see pixel_shapes.lua) they are stepped
-- blocks of one `unit`, painted as plain rectangles. A bubble too small for its
-- unit is built smooth. The pixel style also casts a one-unit shadow of ink to
-- the bottom right, inside the size it is given. It is laid out physically (left stays left in
-- right-to-left interfaces), because the tail has to face the critter.

local Device         = require("device")
local Geom           = require("ui/geometry")
local OverlapGroup   = require("ui/widget/overlapgroup")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local Widget         = require("ui/widget/widget")

local AAPaint     = require("infra/sui_aa_paint")
local RasterCache = require("infra/sui_raster_cache")
local SUIStyle    = require("features/sui_style")
local UI          = require("infra/sui_core")
local Shapes      = require("modules/critter/pixel_shapes")

local Screen = Device.screen

-- Metrics at 100% scale, in dp.
local BORDER_DP   = 1.5
local PAD_DP      = 8
local LINE_GAP_DP = 2
local RADIUS_DP   = 10
local TAIL_DP     = 10
local MIN_TEXT_DP = 40

local Bubble = {}

-- Rounded box with an anti-aliased fill and outline around one widget.
local Body = Widget:extend{
    content = nil, border = 1, pad = 0, radius = 0, border_color = nil, fill_color = nil,
    box_w = nil, box_h = nil,   -- outer size; the content size plus the frame when nil
}

function Body:init()
    local size  = self.content:getSize()
    local extra = 2 * (self.border + self.pad)
    self.dimen  = Geom:new{ w = self.box_w or size.w + extra, h = self.box_h or size.h + extra }
end

function Body:getSize() return self.dimen end

function Body:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if not AAPaint.fillRoundedRect(bb, x, y, w, h, self.radius, self.fill_color, 255) then
        bb:paintRect(x, y, w, h, self.fill_color)
    end
    if not AAPaint.strokeRoundedRect(bb, x, y, w, h, self.radius, self.border, self.border_color) then
        bb:paintBorder(x, y, w, h, self.border, self.border_color)
    end
    local inset  = self.border + self.pad
    local spare  = h - 2 * inset - self.content:getSize().h
    self.content:paintTo(bb, x + inset, y + inset + math.max(0, math.floor(spare / 2)))
end

function Body:free() self.content:free() end

-- Coverage mask of the tail: the outline triangle, or with `fill` the same
-- triangle inset by the border. The inset one also runs across the bubble
-- border (the last `border` columns of the mask), so the border opens along
-- the inner edge of the tail and the stroke turns into the tail without a
-- seam. The tip is on the left of the mask when `tip_left`.
local function tailMask(w, h, o, fill)
    local slope = o.half / o.reach
    local norm  = math.sqrt(1 + slope * slope)
    local inset = fill and o.border or 0
    return { bb = AAPaint.buildMask(w, h, function(mask)
        for px = 0, w - 1 do
            local cx = (o.tip_left and px or w - 1 - px) + 0.5
            if fill or cx < o.reach then
                for py = 0, h - 1 do
                    local dy = math.abs(py + 0.5 - o.mid)
                    local cov = (slope * cx - dy) / norm - inset + 0.5
                    AAPaint.blendPixel(mask, px, py, cov, 0, 0, w - 1, h - 1)
                end
            end
        end
    end) }
end

-- Triangle joining the bubble to the critter. It is `reach` wide plus the
-- border width, so it also covers the bubble border at the junction.
local Tail = Widget:extend{
    reach = 0, border = 1, half = 0, mid = 0,
    tip_left = true, border_color = nil, fill_color = nil,
}

-- Cache key of the tail's masks: the geometry never changes.
function Tail:init()
    self.key = table.concat({ self.reach, self.border, self.half, self.mid, self.dimen.w, self.dimen.h,
                              self.tip_left and "l" or "r" }, "|")
end

function Tail:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, key = self.dimen.w, self.dimen.h, self.key
    local outline = RasterCache.get("critter_tail", key .. "|o", tailMask, w, h, self, false).bb
    bb:colorblitFromRGB32(outline, x, y, 0, 0, w, h, self.border_color)
    local fill = RasterCache.get("critter_tail", key .. "|f", tailMask, w, h, self, true).bb
    bb:colorblitFromRGB32(fill, x, y, 0, 0, w, h, self.fill_color)
end

-- Paints `rects` (relative to x, y) in `color`.
local function paintRects(bb, rects, x, y, color)
    for _i, r in ipairs(rects) do bb:paintRect(x + r.x, y + r.y, r.w, r.h, color) end
end

Bubble.paintRects = paintRects

-- Box with stepped corners (a Shapes.box `shape`) around one widget. The shape
-- is snapped to whole units and, with its `shadow`, centred in the box_w x box_h
-- it stands for.
local PixelBody = Widget:extend{
    content = nil, pad = 0, unit = 1, shape = nil, box_w = 0, box_h = 0, shadow = 0,
    border_color = nil, fill_color = nil,
}

function PixelBody:init()
    self.dimen = Geom:new{ w = self.box_w, h = self.box_h }
    self.off_x = math.floor((self.box_w - self.shape.w - self.shadow) / 2)
    self.off_y = math.floor((self.box_h - self.shape.h - self.shadow) / 2)
end

function PixelBody:getSize() return self.dimen end

function PixelBody:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local sx, sy = x + self.off_x, y + self.off_y
    if self.shadow > 0 then
        paintRects(bb, self.shape.fill, sx + self.shadow, sy + self.shadow, self.border_color)
        paintRects(bb, self.shape.border, sx + self.shadow, sy + self.shadow, self.border_color)
    end
    paintRects(bb, self.shape.fill, sx, sy, self.fill_color)
    paintRects(bb, self.shape.border, sx, sy, self.border_color)
    local inset = self.unit + self.pad
    local spare = self.shape.h - 2 * inset - self.content:getSize().h
    self.content:paintTo(bb, sx + inset, sy + inset + math.max(0, math.floor(spare / 2)))
end

function PixelBody:free() self.content:free() end

-- Staircase tail (a Shapes.tail `shape`); its base column covers the border of
-- the box it is joined to.
local PixelTail = Widget:extend{ shape = nil, border_color = nil, fill_color = nil }

function PixelTail:init()
    self.dimen = Geom:new{ w = self.shape.w, h = self.shape.h }
end

function PixelTail:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    paintRects(bb, self.shape.border, x, y, self.border_color)
    paintRects(bb, self.shape.fill, x, y, self.fill_color)
end

-- Line height by face (held weakly) and boldness.
local _line_heights = setmetatable({}, { __mode = "k" })

-- Height of one line of text in `face`; it does not depend on the width.
local function lineHeight(face, bold, width)
    local by_bold = _line_heights[face]
    if not by_bold then
        by_bold = {}
        _line_heights[face] = by_bold
    end
    local key = bold and "bold" or "regular"
    if not by_bold[key] then
        local probe = UI.makeTextBox({ text = "Xg", face = face, bold = bold, width = width })
        by_bold[key] = probe:getSize().h
        probe:free()
    end
    return by_bold[key]
end

-- Text box of at most `lines` lines, ellipsized when the text needs more;
-- `alpha` draws it without a background.
local function textBox(text, face, bold, width, lines, color, alpha)
    local args = { text = text, face = face, bold = bold, width = width, fgcolor = color, alignment = "left" }
    local box = UI.makeTextBox(args, alpha)
    local line_h = lineHeight(face, bold, width)
    if box:getSize().h <= lines * line_h then return box end
    box:free()
    args.height = lines * line_h
    args.height_overflow_show_ellipsis = true
    return UI.makeTextBox(args, alpha)
end

Bubble.textBox = textBox

-- Whether a bubble of `style` and `unit` is drawn in blocks.
local function isPixel(style, unit)
    return style == "pixel" and unit ~= nil and unit >= 1
end

-- Border, padding, tail reach and frame (border and padding, both sides) of a
-- bubble at `scale`. In the pixel style the border is one unit and the reach a
-- whole number of units.
local function metrics(scale, with_tail, style, unit)
    local pad = math.floor(Screen:scaleBySize(PAD_DP) * scale)
    if isPixel(style, unit) then
        local cells = with_tail and math.max(1, math.floor(Screen:scaleBySize(TAIL_DP) * scale / unit + 0.5)) or 0
        return unit, pad, cells * unit, 2 * (unit + pad)
    end
    local border = math.max(1, Screen:scaleBySize(BORDER_DP))
    local reach  = with_tail and math.floor(Screen:scaleBySize(TAIL_DP) * scale) or 0
    return border, pad, reach, 2 * (border + pad)
end

--- Border width, padding, tail reach and frame (border and padding, both sides)
--- of a bubble at `scale`, in px; `with_tail` tells whether it has a tail.
Bubble.metrics = metrics

--- Corner radius of a smooth bubble at `scale`, in px.
function Bubble.radius(scale)
    return math.floor(Screen:scaleBySize(RADIUS_DP) * scale)
end

--- Narrowest width a bubble can be built at: the tail (when `with_tail`), the
--- frame and the least room the text needs. `style` and `unit` are those of
--- Bubble.build.
function Bubble.minWidth(scale, with_tail, style, unit)
    local _border, _pad, reach, frame = metrics(scale, with_tail, style, unit)
    return reach + frame + (isPixel(style, unit) and unit or 0) + Screen:scaleBySize(MIN_TEXT_DP)
end

-- Smooth tail for a bubble `height` tall (not counting its tail), or nil when
-- the straight part of the edge is too short for it. The tail points to `side`.
local function smoothTail(height, reach, border, radius, side)
    -- The tail base stays on the straight part of the edge.
    local half = math.min(reach, math.floor((height - 2 * radius) / 2))
    if half < border + 1 then return nil end
    return Tail:new{
        dimen        = Geom:new{ w = reach + border, h = height },
        reach        = reach,
        border       = border,
        half         = half,
        mid          = height / 2,
        tip_left     = side == "left",
        border_color = SUIStyle.COLOR.text_primary,
        fill_color   = SUIStyle.COLOR.surface,
    }
end

--- Smooth tail of a bubble `height` tall (see Bubble.build), nil when it has none.
Bubble.smoothTail = smoothTail

-- Group of a pixel `body` and its staircase tail, which points at the critter.
local function pixelGroup(body, shape, o, reach, size)
    local unit = o.unit
    local steps, tail_y = Shapes.tailRows(size.h - body.shadow, reach, unit)
    if not steps then return body end

    local tail = PixelTail:new{
        shape        = Shapes.tail(steps, unit, o.side == "left" and "left" or "right"),
        border_color = SUIStyle.COLOR.text_primary,
        fill_color   = SUIStyle.COLOR.surface,
    }
    local tail_left = o.side == "left"
    body.overlap_offset = { tail_left and reach or 0, 0 }
    if tail_left then
        tail.overlap_offset = { reach + body.off_x - (steps - 1) * unit, tail_y }
    else
        tail.overlap_offset = { body.off_x + shape.w - unit, tail_y }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = size.w + reach, h = size.h },
        allow_mirroring = false,
        body,
        tail,
    }
end

--- Builds a bubble of o.w wide, tail included, and as tall as the fullest text
--- needs, at most o.h; returns nil when not even the main line fits.
---   o.message, o.detail     main and secondary text (detail may be nil)
---   o.msg_face, o.msg_bold  face of the main line and whether it is emboldened
---   o.det_face, o.det_bold  same for the secondary line
---   o.side                  "left" | "right": where the critter is, i.e. the
---                           side the tail points to; nil draws no tail
---   o.scale                 size factor of the module
---   o.style                 "pixel" | "smooth" (default)
---   o.unit                  pixel size of the pixel style, in px
function Bubble.build(o)
    local ink    = SUIStyle.COLOR.text_primary
    local pixel  = isPixel(o.style, o.unit)
    local border, pad, reach, frame = metrics(o.scale, o.side ~= nil, o.style, o.unit)
    local gap    = math.floor(Screen:scaleBySize(LINE_GAP_DP) * o.scale)
    local radius = math.floor(Screen:scaleBySize(RADIUS_DP) * o.scale)

    local shadow = pixel and o.unit or 0
    local text_w = o.w - reach - frame - shadow
    if text_w < Screen:scaleBySize(MIN_TEXT_DP) then return nil end

    -- Two lines of the main text and two of the secondary text.
    local full_h = 2 * lineHeight(o.msg_face, o.msg_bold, text_w) + gap
                 + 2 * lineHeight(o.det_face, o.det_bold, text_w)
    local box_h  = math.min(o.h, full_h + frame + shadow)

    -- Text blocks from the fullest to the barest as { main lines, secondary
    -- lines }, the first that fits wins.
    local variants = {}
    if o.detail then
        variants[#variants + 1] = { 2, 2 }
        variants[#variants + 1] = { 2, 1 }
    end
    variants[#variants + 1] = { 2, 0 }
    variants[#variants + 1] = { 1, 0 }

    local content
    for _i, variant in ipairs(variants) do
        local lines, detail_lines = variant[1], variant[2]
        local group = VerticalGroup:new{
            align = "left",
            textBox(o.message, o.msg_face, o.msg_bold, text_w, lines, ink),
        }
        if detail_lines > 0 then
            group[#group + 1] = VerticalSpan:new{ width = gap }
            group[#group + 1] = textBox(o.detail, o.det_face, o.det_bold, text_w, detail_lines, UI.CLR_TEXT_SUB)
        end
        if group:getSize().h + frame + shadow <= o.h then
            content = group
            break
        end
        group:free()
    end
    if not content then return nil end

    -- A bubble too small for its unit is built smooth.
    local shape = pixel and Shapes.box(o.w - reach - shadow, box_h - shadow, o.unit) or nil
    if pixel and not shape then
        content:free()
        local smooth = {}
        for k, v in pairs(o) do smooth[k] = v end
        smooth.style = "smooth"
        return Bubble.build(smooth)
    end

    local body
    if shape then
        body = PixelBody:new{
            content      = content,
            box_w        = o.w - reach,
            box_h        = box_h,
            pad          = pad,
            unit         = o.unit,
            shadow       = shadow,
            shape        = shape,
            border_color = ink,
            fill_color   = SUIStyle.COLOR.surface,
        }
    else
        body = Body:new{
            content      = content,
            box_w        = o.w - reach,
            box_h        = box_h,
            radius       = radius,
            border       = border,
            pad          = pad,
            border_color = ink,
            fill_color   = SUIStyle.COLOR.surface,
        }
    end
    if reach == 0 then return body end

    local size = body:getSize()
    if shape then return pixelGroup(body, shape, o, reach, size) end

    local tail = smoothTail(size.h, reach, border, radius, o.side)
    if not tail then return body end
    local tail_left = o.side == "left"
    body.overlap_offset = { tail_left and reach or 0, 0 }
    tail.overlap_offset = { tail_left and 0 or size.w - border, 0 }
    return OverlapGroup:new{
        dimen = Geom:new{ w = size.w + reach, h = size.h },
        allow_mirroring = false,
        body,
        tail,
    }
end

return Bubble
