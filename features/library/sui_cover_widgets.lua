-- sui_cover_widgets.lua — Simple UI
-- Pure rendering code for folder/book cover decoration: the progress
-- pentagon, the "New" corner ribbon, rounded-rectangle badges (pages,
-- series index, "New"), the book pile and classic spine, the folder-name
-- label overlay, the book-count circle badge, and 2×2 quad-cover assembly.
--
-- Nothing here touches FileChooser/MosaicMenuItem, and the only settings read
-- are the cover-shadow flags and the stack style (through SUIStyle) — every other
-- value arrives as a parameter. sui_foldercovers.lua reads its settings once
-- per update()/paintTo() cycle and passes them in. This means every function
-- below can be exercised and reasoned about in isolation from the settings
-- system and the monkeypatch machinery.
--
-- Cached state kept here: the raster cache (AA pentagon, checkmark, rotated
-- ribbon and shadow strips, built once per shape and blitted on every paint)
-- and the label line-height memo. Both are cleared via the public clear*Cache()
-- functions, which sui_foldercovers.lua calls from M.invalidateCache().
--
-- Public API
-- ----------
--   CoverWidgets.buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
--   CoverWidgets.drawProgressBadge(bb, ox, oy, desc)
--   CoverWidgets.buildProgressBadgeWidget(desc)
--       -- Widget wrapper (getSize/paintTo) around drawProgressBadge, for
--       -- consumers that need it embedded in an OverlapGroup rather than
--       -- painted directly onto a Blitbuffer — see engines/sui_book_grid.lua.
--   CoverWidgets.paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
--                                  span, band_thick, label, font_sz, dark)
--   CoverWidgets.buildCornerRibbonWidget(cw, ch, dark, badge_scale, label)
--       -- Widget wrapper (getSize/paintTo) around paintCornerRibbon, for the
--       -- same reason buildProgressBadgeWidget exists — see
--       -- engines/sui_book_grid.lua's "New" badge, mode = "ribbon".
--   CoverWidgets.buildRectBadgeWidget(text, bold, cell_min, dark, new_badge, badge_scale)
--   CoverWidgets.pileInset(scale)
--       -- Total px a cover gives up on the right and bottom for its pile
--       -- (layer steps plus the front cover's shadow).
--   CoverWidgets.buildPile(cover_w, cover_h, inset)
--       -- Two shaded layers peeking out behind a cover of cover_w × cover_h.
--   CoverWidgets.paintShadow(bb, x, y, w, h, offset)
--       -- Soft shadow around a w × h card at (x, y), cast down and to the right.
--   CoverWidgets.buildShadow(card_w, card_h, offset)
--       -- Widget wrapper around paintShadow (nil when `offset` is 0).
--   CoverWidgets.buildSpine(cover_h, inset)
--       -- Classic spine: two vertical edge lines left of a cover.
--   CoverWidgets.backingInset(scope, hide_stack, scale)
--       -- { kind, left, right, bottom }: what is drawn behind a cover and the
--       -- px it takes. The pile or the classic spine, per the stack style
--       -- setting, or just the shadow when the stack is hidden.
--   CoverWidgets.buildBacking(cover_w, cover_h, inset)
--       -- The widget for that backing (nil when there is nothing to draw).
--   CoverWidgets.buildFolderNameWidget(item, available_w, font_size, fgcolor, bgcolor)
--   CoverWidgets.buildLabel(item, size, border, display)
--       -- display: { label_mode, show_name, label_opacity, label_layout, label_pos, label_color, label_scale }
--   CoverWidgets.buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen, opts)
--       -- opts: { hidden, scale, dark, position }  ("bottom" | anything else = top)
--   CoverWidgets.computeCellGeometry(item, hide_stack)
--   CoverWidgets.assembleCoverWidget(item, content_widget, size, border, backing, display)
--   CoverWidgets.buildQuadGrid(img_list, w, h, border)
--       -- Pure 2×2 cover collage, no pile/label/badge/assembly — reusable
--       -- outside the library's mosaic context (e.g. module_collections.lua).
--   CoverWidgets.buildQuadCover(item, img_list, border, backing, max_img_w, max_img_h, display)
--       -- Wraps buildQuadGrid with assembleCoverWidget (mosaic's pile/label/badge).
--   CoverWidgets.installWidget(item, widget, complete)
--   CoverWidgets.clearLabelMetricsCache()

local _  = require("infra/sui_i18n").translate
local BD = require("ui/bidi")

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Screen          = require("device").screen
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local RenderText     = require("ui/rendertext")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local SUIStyle        = require("features/sui_style")
local UI              = require("infra/sui_core")
local AAPaint         = require("infra/sui_aa_paint")
local RasterCache     = require("infra/sui_raster_cache")
local Backdrop        = require("infra/sui_backdrop")

local CoverWidgets = {}

-- ---------------------------------------------------------------------------
-- Shared geometry constants
-- ---------------------------------------------------------------------------

local _BASE_COVER_H = math.floor(Screen:scaleBySize(96))
local _BASE_DIR_FS  = SUIStyle.FS_DETAIL -- 15: folder-name label font size at 100% label scale

local _LATERAL_PAD        = Screen:scaleBySize(10)
local _VERTICAL_PAD        = Screen:scaleBySize(4)
local _BADGE_MARGIN_BASE   = Screen:scaleBySize(8)
local _BADGE_MARGIN_R_BASE = Screen:scaleBySize(4)

-- Folder-name label band: at most two lines, never thinner than this
-- fraction of the cover, and (at the bottom) lifted off the cover edge.
local _LABEL_MAX_LINES  = 2
local _LABEL_MIN_H_FRAC = 0.18
local _LABEL_GAP_FRAC   = 0.07

-- Label shapes (both framed like the cover):
--   band     — strap across the full cover width, flush with the top edge.
--   floating — square-cornered box inset from both sides and kept clear of
--              every edge.
-- inset_frac is the side margin as a fraction of the cover width.
local _LABEL_LAYOUTS = {
    band     = { inset_frac = 0,    lift_top = false },
    floating = { inset_frac = 0.05, lift_top = true  },
}
local _DEFAULT_LABEL_LAYOUT = "floating"

-- ── Progress pentagon badge ──────────────────────────────────────────────────
-- Shape: downward-pointing pentagon (rectangle body + triangular tip).
-- States: "complete" → checkmark; percent_finished set → "42%"; otherwise bare.
--
-- Edges are coverage-AA'd via infra/sui_aa_paint into an 8-bit mask, built once
-- per size (see the raster cache) and composited with colorblitFromRGB32.
-- Uncovered mask pixels stay transparent, so cover art shows through the
-- triangular tip.

local function buildPentagonMask(w, h)
    return { bb = AAPaint.buildMask(w, h, function(mask)
        AAPaint.paintDownPentagonFill(mask, 0, 0, w, h, 0, 0, w - 1, h - 1)
    end) }
end

-- Paints a filled AA pentagon of size (bw × bh) in `color` at (bx, by) on `bb`.
local function pentagonPaintRect(bb, bx, by, bw, bh, color)
    if bw <= 0 or bh <= 0 then return end
    local mask = RasterCache.get("pentagon", bw * 4096 + bh, buildPentagonMask, bw, bh).bb
    bb:colorblitFromRGB32(mask, bx, by, 0, 0, bw, bh, color)
end

-- AA checkmark of a sq × sq box via capsule strokes (same primitive as the
-- analogue clock hands). The mask overhangs the box by the stroke caps, so the
-- entry also holds its offset (dx, dy) from the box's top-left corner.
local function buildCheckMask(sq)
    local tk = math.max(2, math.floor(sq / 8))
    local lx0, ly0 = sq * 0.08, sq * 0.62
    local lx1, ly1 = sq * 0.30, sq * 0.82
    local rx1, ry1 = sq * 0.82, sq * 0.18
    local pad  = math.ceil(tk / 2) + 1
    local minx = math.floor(math.min(lx0, lx1, rx1) - pad)
    local maxx = math.ceil (math.max(lx0, lx1, rx1) + pad)
    local miny = math.floor(math.min(ly0, ly1, ry1) - pad)
    local maxy = math.ceil (math.max(ly0, ly1, ry1) + pad)
    local mw, mh = maxx - minx + 1, maxy - miny + 1
    local mask = AAPaint.buildMask(mw, mh, function(bb)
        AAPaint.paintCapsule(bb, lx0 - minx, ly0 - miny, lx1 - minx, ly1 - miny, tk, 0, 0, mw - 1, mh - 1)
        AAPaint.paintCapsule(bb, lx1 - minx, ly1 - miny, rx1 - minx, ry1 - miny, tk, 0, 0, mw - 1, mh - 1)
    end)
    return { bb = mask, dx = minx, dy = miny }
end

-- Paints the checkmark of the sq × sq box at (bx, by) in `color` on `bb`.
local function pentagonPaintCheck(bb, bx, by, sq, color)
    if sq <= 0 then return end
    local check = RasterCache.get("check", sq, buildCheckMask, sq)
    local mask  = check.bb
    bb:colorblitFromRGB32(mask, bx + check.dx, by + check.dy,
        0, 0, mask:getWidth(), mask:getHeight(), color)
end

-- Largest font size, at most `start_sz` and at least 7, at which `text` fits
-- in `max_w`. Measured with RenderText (TextWidget:getSize can under-report
-- bold widths); the entry is cached per (text, face, size, bold, width).
local function fitFontSize(text, face_name, start_sz, bold, max_w)
    local font_sz = math.max(7, start_sz)
    -- TextWidget bold uses FreeType embolden, which widens glyphs beyond the
    -- regular-face advance reported by sizeUtf8Text, so the measured width is
    -- scaled up to account for it.
    local bold_scale = bold and 1.10 or 1.0
    local screen_w = require("device").screen:getWidth()
    while font_sz > 7 do
        local face = Font:getFace(face_name, font_sz)
        -- sizeUtf8Text(x, width, face, text, kerning, bold)
        local measured = RenderText:sizeUtf8Text(0, screen_w, face, text, true, bold)
        if (measured and measured.x or 0) * bold_scale <= max_w then break end
        font_sz = font_sz - 1
    end
    return { size = font_sz }
end

-- Returns a descriptor table for the progress badge, or nil when too small.
-- No Blitbuffer is allocated here — drawing is deferred to paintTo().
function CoverWidgets.buildProgressBadgeDesc(eff_size, status, percent_finished, border, dark)
    local bw = math.floor(eff_size * 1.3)
    local bh = math.floor(eff_size * 1.4)
    if bw < 4 or bh < 4 then return nil end

    local text_color  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local text_widget = nil
    -- Cap label width at 95% of the banner body so "100%" and wide icons
    -- stay inside the pentagon on small covers.
    local max_text_w  = math.max(1, math.floor(bw * 0.95))

    local function fitTextWidget(text, face_name, start_sz, bold)
        local key = string.format("%s|%d|%s|%d|%s", face_name, start_sz, tostring(bold), max_text_w, text)
        local fit = RasterCache.get("badge_font", key, fitFontSize, text, face_name, start_sz, bold, max_text_w)
        return TextWidget:new{
            text    = text,
            face    = Font:getFace(face_name, fit.size),
            bold    = bold,
            fgcolor = text_color,
            padding = 0,
        }
    end

    local start_sz = math.max(7, math.floor(eff_size * 0.26))
    if status == "abandoned" then
        text_widget = fitTextWidget("\u{EAE3}", SUIStyle.FACE_ICONS, start_sz, false)
    elseif percent_finished ~= nil and status ~= "complete" then
        local pct = math.floor(percent_finished * 100 + 0.5)
        text_widget = fitTextWidget(pct .. "%", SUIStyle.FACE_REGULAR, start_sz, true)
    end

    return {
        bw               = bw,
        bh               = bh,
        border           = border or SUIStyle.BADGE_BORDER_SZ,
        status           = status,
        percent_finished = percent_finished,
        eff_size         = eff_size,
        dark             = dark ~= false,
        text_widget      = text_widget,
    }
end

-- Draw the progress badge described by `desc` directly onto `bb` at (ox, oy).
-- Border uses text_primary so the top edge matches the cover border it sits on.
function CoverWidgets.drawProgressBadge(bb, ox, oy, desc)
    local bw         = desc.bw
    local bh         = desc.bh
    local fr         = desc.border
    local fill_color = desc.dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local text_color = desc.dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local brd_color  = SUIStyle.COLOR.text_primary

    pentagonPaintRect(bb, ox,      oy,      bw + 2 * fr, bh + 2 * fr, brd_color)
    pentagonPaintRect(bb, ox + fr, oy + fr, bw,          bh,          fill_color)

    local rect_h     = math.floor(bh * 30 / 42)
    local pad_x      = math.floor(bw * 0.12)
    local pad_y      = math.floor(rect_h * 0.25)
    local icon_x     = ox + fr + pad_x
    local icon_y     = oy + fr + pad_y
    local icon_w     = bw - 2 * pad_x
    local icon_h     = rect_h - 2 * pad_y
    -- Shift content downward for visual balance with the triangular tip below.
    local text_y_offset = math.floor(rect_h * 0.15)

    if desc.status == "complete" then
        local sq   = math.min(icon_w, icon_h)
        local sq_x = icon_x + math.floor((icon_w - sq) / 2)
        local sq_y = oy + fr + math.floor((rect_h - sq) / 2) + text_y_offset
        pentagonPaintCheck(bb, sq_x, sq_y, sq, text_color)
    elseif desc.status == "abandoned" then
        if desc.text_widget then
            local aw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - aw_sz.w) / 2),
                oy + fr + math.floor((rect_h - aw_sz.h) / 2) + text_y_offset)
        end
    elseif desc.percent_finished ~= nil then
        if desc.text_widget then
            local tw_sz = desc.text_widget:getSize()
            desc.text_widget:paintTo(bb,
                ox + fr + math.floor((bw     - tw_sz.w) / 2),
                oy + fr + math.floor((rect_h - tw_sz.h) / 2) + text_y_offset)
        end
    end
    -- "not started": bare pentagon, no content drawn.
end

-- Widget wrapper around buildProgressBadgeDesc/drawProgressBadge, for
-- consumers that build a widget tree (OverlapGroup) instead of overriding
-- MosaicMenuItem:paintTo() directly (e.g. engines/sui_book_grid.lua's
-- GridRenderer cells). getSize()/paintTo() are enough to be laid out and
-- painted by a Group/OverlapGroup — the actual drawing still goes through
-- drawProgressBadge, so there is exactly one place that knows how to paint
-- the pentagon — but a no-op handleEvent() is also required below, since
-- this can end up nested inside an interactive (tappable) tree, not just a
-- passive one.
-- Returns nil when desc is nil (mirrors buildProgressBadgeDesc's own
-- "too small" guard).
local ProgressBadgeWidget = {}
ProgressBadgeWidget.__index = ProgressBadgeWidget

function ProgressBadgeWidget:getSize()
    local fr = self.desc.border
    return Geom:new{ w = self.desc.bw + 2 * fr, h = self.desc.bh + 2 * fr }
end

function ProgressBadgeWidget:paintTo(bb, x, y)
    CoverWidgets.drawProgressBadge(bb, x, y, self.desc)
end

-- getSize()/paintTo() are enough for a Group/OverlapGroup to lay this out
-- and paint it, but this badge can also end up nested inside an
-- interactive tree (sui_book_grid.lua wraps the cover -- badges included --
-- in a tappable InputContainer). WidgetContainer:propagateEvent() calls
-- `child:handleEvent(event)` unconditionally on every child while walking
-- down to find a gesture handler, with no existence check first, so a bare
-- table without this method crashes with "attempt to call method
-- 'handleEvent' (a nil value)" the moment a gesture is routed through it.
-- This badge never wants to consume events itself, so just decline and let
-- propagation continue elsewhere.
function ProgressBadgeWidget:handleEvent()
    return false
end

function CoverWidgets.buildProgressBadgeWidget(desc)
    if not desc then return nil end
    return setmetatable({ desc = desc }, ProgressBadgeWidget)
end

-- ── Corner ribbon ("New" style) ───────────────────────────────────────────
-- A diagonal band across the cover's top-right corner at 45°, with the label
-- rotated inside it.
--
-- The band is rendered upright once, then rotated into a sprite: a pixel copy
-- of the part of the ribbon that lies inside the cover's top-right corner,
-- found by a destination-driven inverse-map. The sprite is cached per
-- (size, label, colours, buffer type), so painting a ribbon is one blit per
-- row, clipped to the cover.

local _COS_45 = 0.70711  -- cos 45° = sin 45°

-- Upright band of tw × th px: bordered long edges, filled interior, centred label.
local function renderRibbonBand(tw, th, bb_type, label, font_sz, dark)
    local bg  = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local brd = SUIStyle.BADGE_BORDER_CLR
    local bw  = SUIStyle.BADGE_BORDER_SZ

    local band = Blitbuffer.new(tw, th, bb_type)
    band:paintRect(0, 0, tw, th, brd)
    if bw * 2 < th then
        band:paintRect(0, bw, tw, th - bw * 2, bg)
    end

    -- Step the font down 1pt at a time until the label fits, min 6pt.
    local inner_h = math.max(1, th - bw * 2)
    local max_w   = math.floor(tw * 0.82)
    local lbl, lsz
    local fs = font_sz
    repeat
        if lbl then lbl:free() end
        lbl = TextWidget:new{
            text    = label,
            face    = Font:getFace(SUIStyle.FACE_REGULAR, fs),
            bold    = true,
            fgcolor = fg,
            padding = 0,
        }
        lsz = lbl:getSize()
        if lsz.w <= max_w and lsz.h <= inner_h then break end
        fs = fs - 1
    until fs < 6
    lbl:paintTo(band, math.max(0, math.floor((tw - lsz.w) / 2)),
                      math.max(0, math.floor((th - lsz.h) / 2)))
    lbl:free()
    return band
end

-- Entry: { bb = sprite, w, h, first, last }. Sprite column i is i - w px from
-- the cover's right edge, row j is j px below its top edge. first[j] and
-- last[j] bound the ribbon's pixels in row j (nil when the row has none).
local function buildRibbonSprite(bb_type, span, band_thick, label, font_sz, dark)
    -- The ends protrude past both cover edges; cover clipping hides the cuts.
    local tw = math.ceil((span + band_thick * 2) * 1.41422)
    local th = band_thick
    local band = renderRibbonBand(tw, th, bb_type, label, font_sz, dark)

    local reach    = math.floor(span / 2)  -- band centre's distance from the corner
    local half_box = math.ceil((tw + th) * _COS_45 / 2) + 1
    local w, h     = reach + half_box, reach + half_box + 1
    local sprite   = Blitbuffer.new(w, h, bb_type)
    local first, last = {}, {}
    local tw_half, th_half = tw / 2, th / 2
    for j = 0, h - 1 do
        local dy_rel = j - reach
        for i = 0, w - 1 do
            local dx_rel = i - half_box
            -- Inverse of the +45° rotation (top-right "\" band).
            local sx = math.floor(tw_half + (dx_rel + dy_rel) * _COS_45)
            local sy = math.floor(th_half + (dy_rel - dx_rel) * _COS_45)
            if sx >= 0 and sx < tw and sy >= 0 and sy < th then
                sprite:setPixel(i, j, band:getPixel(sx, sy))
                first[j] = first[j] or i
                last[j]  = i
            end
        end
    end
    band:free()
    return { bb = sprite, w = w, h = h, first = first, last = last }
end

function CoverWidgets.paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
                                        span, band_thick, label, font_sz, dark)
    if span <= 0 or band_thick <= 0 then return end
    local key = string.format("%d|%d|%d|%s|%d|%d|%s|%s", bb:getType(), span, band_thick, label,
        font_sz, dark and 1 or 0, tostring(SUIStyle.BADGE_BORDER_SZ), tostring(SUIStyle.BADGE_BORDER_CLR))
    local ribbon = RasterCache.get("ribbon", key, buildRibbonSprite,
        bb:getType(), span, band_thick, label, font_sz, dark)

    local sprite_x = cover_right - ribbon.w
    local min_col  = math.max(0, cover_left - sprite_x)
    for j = 0, math.min(ribbon.h, cover_h) - 1 do
        local x0 = ribbon.first[j]
        if x0 then
            x0 = math.max(x0, min_col)
            local x1 = ribbon.last[j]
            if x1 >= x0 then
                bb:blitFrom(ribbon.bb, sprite_x + x0, cover_top + j, x0, j, x1 - x0 + 1, 1)
            end
        end
    end
end

-- Widget wrapper around paintCornerRibbon, for the same reason
-- ProgressBadgeWidget exists above: engines/sui_book_grid.lua builds a
-- widget tree (OverlapGroup) instead of overriding MosaicMenuItem:paintTo()
-- directly like sui_foldercovers.lua does, so the ribbon needs a
-- getSize()/paintTo()/handleEvent() shell rather than being painted
-- straight onto an already-known bb/x/y/fw/fh.
--
-- Unlike the rounded-rect badges (which are a small widget placed at a
-- corner offset via overlap_offset), the ribbon has no bounding box of its
-- own — it's a diagonal band drawn across the cover's top-right corner
-- REGION. So this widget's getSize() reports the *entire* cover size
-- (cw × ch) and it must be the OverlapGroup's full-size layer, not offset —
-- callers add it to the overlap group directly, without an overlap_offset,
-- same as cover_widget itself.
--
-- This intentionally skips the Library grid's "repaint the border edges
-- over the ribbon" step (see sui_foldercovers.lua) — that step exists to
-- restore the Library thumbnail's own persistent 1px frame where the ribbon
-- crosses it, but book-grid covers here (engines/sui_book_grid.lua) aren't
-- bordered the same way, so there is no border to restore.
local CornerRibbonWidget = {}
CornerRibbonWidget.__index = CornerRibbonWidget

function CornerRibbonWidget:getSize()
    return Geom:new{ w = self.cw, h = self.ch }
end

function CornerRibbonWidget:paintTo(bb, x, y)
    CoverWidgets.paintCornerRibbon(bb, x, x + self.cw, y, self.ch,
        self.span, self.band_thick, self.label, self.font_sz, self.dark)
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function CornerRibbonWidget:handleEvent()
    return false
end

-- cw/ch: full cover size, NOT an offset/inset — see the class doc comment
-- above for why. span/band_thick/font_sz derivation copied verbatim from
-- sui_foldercovers.lua's ribbon call site so both grids draw an
-- identically-proportioned ribbon for the same cover size.
function CoverWidgets.buildCornerRibbonWidget(cw, ch, dark, badge_scale, label)
    if cw < 4 or ch < 4 then return nil end
    local cell_min   = math.min(cw, ch)
    local eff_size   = math.max(8, math.floor(cell_min * 0.1694 * (badge_scale or 1.0)))
    local span       = math.floor(eff_size * 2.5)
    local band_thick = math.floor(span * 0.40)
    local font_sz    = math.max(7, math.floor(eff_size * 0.26))
    return setmetatable({
        cw = cw, ch = ch, dark = dark,
        span = span, band_thick = band_thick,
        font_sz = font_sz, label = label or _("New"),
    }, CornerRibbonWidget)
end

function CoverWidgets.buildRectBadgeWidget(text, bold, cell_min, dark, new_badge, badge_scale)
    badge_scale = badge_scale or 1.0
    local eff_size = math.max(8, math.floor((cell_min or 40) * 0.15 * badge_scale))
    local font_sz  = math.max(7, math.floor(eff_size * 0.24))
    local pad_h    = math.max(1, math.floor(eff_size * 0.10))
    local pad_v    = math.max(1, math.floor(eff_size * 0.06))
    local corner   = math.max(1, math.floor(eff_size * 0.08))
    local border   = SUIStyle.BADGE_BORDER_SZ

    local bg = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local border_color = SUIStyle.BADGE_BORDER_CLR

    local tw = TextWidget:new{
        text    = text,
        face    = Font:getFace(SUIStyle.FACE_REGULAR, font_sz),
        bold    = bold or false,
        fgcolor = fg,
        padding = 0,
    }
    local tsz    = tw:getSize()
    local lateral = pad_h * 4
    local inner_h = tsz.h + pad_v * 2
    -- Enforce a square minimum so short labels like "#1" are not tiny slivers.
    local inner_w = math.max(tsz.w + lateral, inner_h)
    local w = inner_w + border * 2
    local h = inner_h + border * 2
    if w < 4 or h < 4 then tw:free(); return nil end

    return FrameContainer:new{
        dimen      = Geom:new{ w = w, h = h },
        bordersize = border,
        color      = border_color,
        background = bg,
        radius     = corner,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            tw,
        },
    }
end

-- ── Book pile ─────────────────────────────────────────────────────────────────

-- The pile is a staircase of cards behind the front cover, each one offset
-- down-right by `step`. The visible strip of each card is its body, shaded
-- grey and outlined; the last card also casts the same soft shadow as a single
-- cover (see paintShadow). The shadow is `step` minus the outline, so outline
-- and shadow tile the staircase without gaps. Body and outline fade with
-- depth, so the pile recedes.

-- Fade factors by depth, where depth 1 is the layer touching the front cover.
-- A factor of 1 gives the full colour, 0 gives none. The outline table sets the
-- layer count.
local _PILE_BODY_FADE   = { 1.0, 0.58 }
local _PILE_BORDER_FADE = { 0.80, 0.44 }

local _PILE_LAYERS = #_PILE_BORDER_FADE
local _PILE_STEP   = Screen:scaleBySize(5)

-- Body blackness before fading. Night mode inverts the frame after painting,
-- so the night base is lower to keep the body dark on screen.
local _PILE_BODY_BASE       = 0.5
local _PILE_BODY_BASE_NIGHT = 0.15

-- Interpolates two colours in painted space: t = 1 gives `a`, t = 0 gives `b`.
local function blend8(a, b, t)
    local av, bv = a:getColor8().a, b:getColor8().a
    return Blitbuffer.Color8(math.floor(bv + (av - bv) * t + 0.5))
end

local function pileBodyColor(depth)
    local base = Screen.night_mode and _PILE_BODY_BASE_NIGHT or _PILE_BODY_BASE
    return Blitbuffer.gray(base * _PILE_BODY_FADE[depth])
end

-- The cover's own outline colour, faded towards the page colour.
local function pileBorderColor(depth)
    return blend8(SUIStyle.COLOR.text_primary, SUIStyle.COLOR.surface, _PILE_BORDER_FADE[depth])
end

-- Offset between consecutive cards. Always wider than the outline, so the
-- shadow strip has at least one pixel.
local function pileStep(scale)
    return math.max(SUIStyle.BADGE_BORDER_SZ + 1, math.floor(_PILE_STEP * (scale or 1)))
end

local PileWidget = {}
PileWidget.__index = PileWidget

function PileWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

-- The last card's shadow is painted first, then the cards farthest first so
-- nearer ones cover them. Each card is its body, then its outline; the front
-- cover itself is added on top by the caller.
function PileWidget:paintTo(bb, x, y)
    local step   = self.step
    local stroke = SUIStyle.BADGE_BORDER_SZ
    local last   = _PILE_LAYERS * step
    CoverWidgets.paintShadow(bb, x + last, y + last, self.card_w, self.card_h, self.shadow)
    for depth = _PILE_LAYERS, 1, -1 do
        local lx, ly = x + depth * step, y + depth * step
        bb:paintRect(lx, ly, self.card_w, self.card_h, pileBodyColor(depth))
        bb:paintBorder(lx, ly, self.card_w, self.card_h, stroke, pileBorderColor(depth))
    end
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function PileWidget:handleEvent()
    return false
end

-- Total pixels a cover gives up on its right and bottom edges for the pile:
-- one step per layer plus the front cover's shadow.
-- `scale` follows the cover's own scale (1 when omitted).
function CoverWidgets.pileInset(scale)
    return (_PILE_LAYERS + 1) * pileStep(scale) - SUIStyle.BADGE_BORDER_SZ
end

-- Cards behind a cover of cover_w × cover_h. `inset` comes from pileInset();
-- the widget is (cover_w + inset) × (cover_h + inset) and the caller draws
-- the cover at its top-left corner.
function CoverWidgets.buildPile(cover_w, cover_h, inset)
    local stroke = SUIStyle.BADGE_BORDER_SZ
    local step   = math.floor((inset + stroke) / (_PILE_LAYERS + 1))
    if step <= stroke then return nil end
    return setmetatable({
        w = cover_w + inset, h = cover_h + inset,
        card_w = cover_w,    card_h = cover_h,
        step = step,         shadow = step - stroke,
    }, PileWidget)
end

-- ── Classic spine ─────────────────────────────────────────────────────────────

-- Two vertical edge lines to the left of the cover, the outer one shorter.
-- Line heights are fractions of the cover's, outermost first, centred on it.
local _SPINE_LINE_H  = { 0.94, 0.97 }
local _SPINE_THICK   = Screen:scaleBySize(3)
local _SPINE_GAP     = Screen:scaleBySize(1)

local SpineWidget = {}
SpineWidget.__index = SpineWidget

function SpineWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function SpineWidget:paintTo(bb, x, y)
    local color = SUIStyle.COLOR.gray
    local step  = self.thick + self.gap
    for i, frac in ipairs(_SPINE_LINE_H) do
        local line_h = math.floor(self.h * frac)
        bb:paintRect(x + (i - 1) * step, y + math.floor((self.h - line_h) / 2),
            self.thick, line_h, color)
    end
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function SpineWidget:handleEvent()
    return false
end

-- Backing descriptor of the classic spine: it takes room on the left only.
-- `scale` follows the cover's own scale (1 when omitted).
local function spineInset(scale)
    scale = scale or 1
    local thick = math.max(1, math.floor(_SPINE_THICK * scale))
    local gap   = math.max(1, math.floor(_SPINE_GAP   * scale))
    return {
        kind = "spine", left = 2 * (thick + gap), right = 0, bottom = 0,
        thick = thick, gap = gap,
    }
end

-- Spine widget for a cover `cover_h` tall; `inset` is a spine descriptor.
-- The cover is drawn to the right of the widget.
function CoverWidgets.buildSpine(cover_h, inset)
    return setmetatable({
        w = inset.left, h = cover_h,
        thick = inset.thick, gap = inset.gap,
    }, SpineWidget)
end

-- ── Cover shadow ──────────────────────────────────────────────────────────────

-- A shadow is built from one-pixel bands that fade with their distance from
-- the card, which approximates a blurred edge. The bands are coverage masks
-- blended in black, which shades what is already painted instead of laying a
-- fixed grey, so the shadow reads on any background.
local _SHADOW_PEAK         = 0.22   -- shading of the band touching the card
local _SHADOW_MIN_STRENGTH = 0.02   -- fainter bands are not visible: skipped

-- Shading of the band `d` px away from the card (0 = touching it) in a shadow
-- `reach` px deep: a smoothstep from the peak down to nothing.
local function shadowBandStrength(d, reach)
    local t = 1 - d / reach
    return _SHADOW_PEAK * t * t * (3 - 2 * t)
end

-- Coverage masks of a shadow's right and bottom strips, cached by card size
-- and depth. The strips never overlap: right band `d` is the column `d` px
-- past the card, bottom band `d` the row `d` px below it, and the corner
-- belongs to whichever band is farther along its own axis.
local function buildShadowMasks(w, h, offset)
    local right  = Blitbuffer.new(offset, h, Blitbuffer.TYPE_BB8)
    local bottom = Blitbuffer.new(w, offset, Blitbuffer.TYPE_BB8)
    right:fill(Blitbuffer.Color8(0))
    bottom:fill(Blitbuffer.Color8(0))
    for d = 0, offset - 1 do
        local strength = shadowBandStrength(d, offset)
        if strength < _SHADOW_MIN_STRENGTH then break end
        local coverage = Blitbuffer.Color8(math.floor(strength * 255 + 0.5))
        right:paintRect(d, 0, 1, h - offset + d, coverage)
        bottom:paintRect(0, d, w - offset + d + 1, 1, coverage)
    end
    return { right = right, bottom = bottom }
end

-- Paints the part of a soft shadow that shows around a w × h card at (x, y),
-- `offset` px deep. The shadow is the card's rectangle shifted down-right by
-- `offset`, minus the card itself. Night frames are inverted after painting,
-- so blending towards white is what darkens the shadow on screen.
function CoverWidgets.paintShadow(bb, x, y, w, h, offset)
    if offset <= 0 then return end
    local masks = RasterCache.get("shadow", (w * 4096 + h) * 64 + offset, buildShadowMasks, w, h, offset)
    local color = Screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:colorblitFromRGB32(masks.right,  x + w,      y + offset, 0, 0, offset, h,      color)
    bb:colorblitFromRGB32(masks.bottom, x + offset, y + h,      0, 0, w,      offset, color)
end

local ShadowWidget = {}
ShadowWidget.__index = ShadowWidget

function ShadowWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function ShadowWidget:paintTo(bb, x, y)
    CoverWidgets.paintShadow(bb, x, y, self.card_w, self.card_h, self.offset)
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function ShadowWidget:handleEvent()
    return false
end

-- Widget casting the shadow of a card_w × card_h card, `offset` px deep; nil
-- when `offset` is 0. The card sits at the widget's top-left corner and the
-- shadow falls down-right.
function CoverWidgets.buildShadow(card_w, card_h, offset)
    if offset <= 0 then return nil end
    return setmetatable({
        w = card_w + offset, h = card_h + offset,
        card_w = card_w,     card_h = card_h,
        offset = offset,
    }, ShadowWidget)
end

-- What sits behind a cover and the room it takes, as
-- { kind, left, right, bottom } in px: the stack in the configured style, or
-- only the shadow of `scope` when the stack is hidden. The classic spine
-- replaces the shadow, so it is drawn alone. `scale` follows the cover's own
-- scale (1 when omitted).
function CoverWidgets.backingInset(scope, hide_stack, scale)
    if hide_stack then
        local shadow = SUIStyle.coverShadowOffset(scope, scale)
        return { kind = "shadow", left = 0, right = shadow, bottom = shadow }
    end
    if SUIStyle.getFolderStackStyle() == SUIStyle.FOLDER_STACK_CLASSIC then
        return spineInset(scale)
    end
    local pile = CoverWidgets.pileInset(scale)
    return { kind = "pile", left = 0, right = pile, bottom = pile }
end

-- Widget drawn behind a cover of cover_w × cover_h; `inset` comes from
-- backingInset(). The widget starts at the top-left corner of the group the
-- cover is drawn in, `inset.left` px to the left of the cover.
function CoverWidgets.buildBacking(cover_w, cover_h, inset)
    if inset.kind == "spine" then return CoverWidgets.buildSpine(cover_h, inset) end
    if inset.kind == "pile"  then return CoverWidgets.buildPile(cover_w, cover_h, inset.bottom) end
    return CoverWidgets.buildShadow(cover_w, cover_h, inset.bottom)
end

-- ── Folder-name label overlay ─────────────────────────────────────────────────

-- Rendered line height per font size, memoised: measuring costs a full text
-- layout pass.
local _line_h_memo = {}

function CoverWidgets.clearLabelMetricsCache()
    _line_h_memo = {}
end

local function labelLineHeight(face, font_size)
    local h = _line_h_memo[font_size]
    if not h then
        local probe = TextBoxWidget:new{
            text  = "Mg",
            face  = face,
            width = Screen:getWidth(),
            bold  = true,
        }
        h = probe:getLineHeight()
        probe:free(true)
        _line_h_memo[font_size] = h
    end
    return h
end

-- Folder name as centred bold text at a fixed `font_size`, capitalised per
-- word. Names longer than _LABEL_MAX_LINES lines are cut with an ellipsis.
-- Without a `bgcolor` the text is drawn over whatever is already painted;
-- with one it sits on that opaque background.
-- `item` needs only `.text` and a writable `._fc_display_text` cache slot
-- (any table works — sui_foldercovers.lua passes the MosaicMenuItem instance
-- so the capitalised/bidi-wrapped text is computed once per item, not once
-- per render).
function CoverWidgets.buildFolderNameWidget(item, available_w, font_size, fgcolor, bgcolor)
    if not item._fc_display_text then
        local text = item.text
        if text:match("/$") then text = text:sub(1, -2) end
        text = text:gsub("(%S+)", function(w) return w:sub(1,1):upper() .. w:sub(2) end)
        item._fc_display_text = BD.directory(text)
    end
    local face   = Font:getFace(SUIStyle.FACE_REGULAR, font_size)
    local opts   = {
        text      = item._fc_display_text,
        face      = face,
        width     = available_w,
        alignment = "center",
        bold      = true,
        fgcolor   = fgcolor or SUIStyle.COLOR.text_primary,
        bgcolor   = bgcolor,
    }
    local function build()
        if bgcolor then return TextBoxWidget:new(opts) end
        return UI.makeAlphaTextBox(opts)
    end
    local max_h = _LABEL_MAX_LINES * labelLineHeight(face, font_size)
    local name  = build()
    if name:getSize().h <= max_h then return name end

    name:free(true)
    opts.height                        = max_h
    opts.height_adjust                 = true
    opts.height_overflow_show_ellipsis = true
    return build()
end

-- Returns the label laid over the cover (offset to its position), or nil when
-- disabled. The name is centred in a box that is never thinner than
-- _LABEL_MIN_H_FRAC of the cover; its shape follows the layout (see
-- _LABEL_LAYOUTS). At the bottom it is lifted off the edge so it reads as a
-- strap around the book.
-- `display` is the pre-read settings table:
--   { label_mode, show_name, label_opacity, label_layout, label_pos, label_color, label_scale }
function CoverWidgets.buildLabel(item, size, border, display)
    if display.label_mode ~= "overlay" then return nil end
    if not display.show_name            then return nil end
    local layout   = _LABEL_LAYOUTS[display.label_layout] or _LABEL_LAYOUTS[_DEFAULT_LABEL_LAYOUT]
    local dark     = display.label_color == "dark"
    local bg_color = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary

    local cover_w  = size.w + border * 2
    local cover_h  = size.h + border * 2
    local inset    = math.floor(cover_w * layout.inset_frac)
    local band_w   = cover_w - inset * 2
    local inner_w  = band_w - border * 2
    local strength = display.label_opacity

    -- Text stays solid while only the background takes the opacity; a fully
    -- opaque background lets the text paint its own.
    local font_size = math.max(8, math.floor(_BASE_DIR_FS * (display.label_scale or 1.0)))
    local name      = CoverWidgets.buildFolderNameWidget(item, inner_w - _LATERAL_PAD * 2,
        font_size, fg_color, strength >= 100 and bg_color or nil)

    local band_h  = math.max(name:getSize().h + (_VERTICAL_PAD + border) * 2,
                             math.floor(cover_h * _LABEL_MIN_H_FRAC))
    local inner_h = band_h - border * 2
    local label = FrameContainer:new{
        width      = band_w,
        height     = band_h,
        padding    = 0,
        bordersize = border,
        OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            Backdrop.BackdropFill:new{
                width = inner_w, height = inner_h, strength = strength, color = bg_color,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                name,
            },
        },
    }
    if inset > 0 then
        label = FrameContainer:new{ padding = 0, bordersize = 0, padding_left = inset, label }
    end

    local gap = math.max(Screen:scaleBySize(3), math.floor(cover_h * _LABEL_GAP_FRAC))
    local y
    if display.label_pos == "top" then
        y = layout.lift_top and gap or 0
    elseif display.label_pos == "center" then
        y = math.floor((cover_h - band_h) / 2)
    else
        y = cover_h - band_h - gap
    end
    label.overlap_offset = { 0, math.max(0, y) }
    return label
end

-- ── Folder book-count badge (circle) ─────────────────────────────────────────

-- `cell_dimen` is the full mosaic cell (used for sizing); when absent,
-- cover_dimen is used instead (produces a smaller badge).
-- `opts`: { hidden, scale, dark, position }  (position: "bottom" | top-default)
-- The badge is anchored to the top-left of its parent group and sized to the
-- cover alone; assembleCoverWidget offsets it past a backing on the left.
function CoverWidgets.buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen, opts)
    opts = opts or {}
    if opts.hidden then return nil end
    local nb_text = mandatory and mandatory:match("(%d+) \u{F016}") or ""
    if nb_text == "" or nb_text == "0" then return nil end

    local badge_scale    = opts.scale or 1.0
    local nb_count       = tonumber(nb_text)
    local size_dimen     = cell_dimen or cover_dimen
    local cell_min       = math.min(size_dimen.w, size_dimen.h)
    local nb_size        = math.max(8, math.floor(cell_min * 0.13 * badge_scale))
    local nb_font_size   = math.max(7, math.floor(nb_size * 0.28))
    local badge_margin   = math.max(1, math.floor(_BADGE_MARGIN_BASE   * cv_scale))
    local badge_margin_r = math.max(1, math.floor(_BADGE_MARGIN_R_BASE * cv_scale))
    local dark           = opts.dark
    local bg_color       = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color       = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local border_color   = SUIStyle.BADGE_BORDER_CLR

    local badge = FrameContainer:new{
        padding    = 0,
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = border_color,
        background = bg_color,
        radius     = math.floor(nb_size / 2),
        dimen      = Geom:new{ w = nb_size, h = nb_size },
        CenterContainer:new{
            dimen = Geom:new{ w = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ, h = nb_size - 2 * SUIStyle.BADGE_BORDER_SZ },
            (function()
                local tw = TextWidget:new{
                    text    = tostring(math.min(nb_count, 99)),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, nb_font_size),
                    fgcolor = fg_color,
                    bold    = true,
                }
                local _orig_pt = tw.paintTo
                tw.paintTo = function(self, bb, x, y)
                    _orig_pt(self, bb, x, y + 1) -- HACK: Change this +1 to the required value
                end
                return tw
            end)(),
        },
    }

    local inner = RightContainer:new{
        dimen = Geom:new{ w = cover_dimen.w, h = nb_size + badge_margin },
        FrameContainer:new{
            padding       = 0,
            padding_right = badge_margin_r,
            bordersize    = 0,
            badge,
        },
    }

    if opts.position == "bottom" then
        return BottomContainer:new{
            dimen          = cover_dimen,
            padding_bottom = badge_margin,
            inner,
        }
    else
        return TopContainer:new{
            dimen         = cover_dimen,
            padding_top   = badge_margin,
            inner,
        }
    end
end

-- ── Shared geometry helper ────────────────────────────────────────────────────

-- Computes the four values every cover-building function needs: the cover's
-- border, the backing inset (see backingInset; zero-sized when there is
-- neither a stack nor a shadow) and the largest cover that still leaves room
-- for both. self.height is already reduced by _STRIP_H in
-- sui_foldercovers.lua's update() wrapper before this is called, so it must
-- NOT be subtracted again.
function CoverWidgets.computeCellGeometry(item, hide_stack)
    local border  = SUIStyle.BADGE_BORDER_SZ
    local backing = CoverWidgets.backingInset(SUIStyle.SHADOW_LIBRARY, hide_stack)
    return border, backing,
        item.width  - backing.left - backing.right - border * 2,
        item.height - backing.bottom - border * 2
end

-- ── Cover assembly helper ─────────────────────────────────────────────────────

-- Places `widget` at `x` inside an OverlapGroup, keeping its vertical offset.
local function shiftRight(widget, x)
    local offset = widget.overlap_offset
    widget.overlap_offset = { x, offset and offset[2] or 0 }
end

-- Wraps any pre-built content_widget with the backing (pile, spine or shadow),
-- overlays the folder-name label and item-count badge, and centres the whole
-- in the mosaic cell. The cover, label and badge sit `backing.left` px into
-- the group; a left-hand backing hangs out of the cover, which stays centred
-- as long as the cell has room for both.
-- cv_scale is derived from cover_h here so callers don't have to compute it.
-- Must be defined before buildQuadCover, which calls it.
function CoverWidgets.assembleCoverWidget(item, content_widget, size, border, backing, display)
    local cover_dimen = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }
    local group_dimen = Geom:new{
        w = cover_dimen.w + backing.left + backing.right,
        h = cover_dimen.h + backing.bottom,
    }
    local cell_dimen  = Geom:new{ w = item.width, h = item.height }
    local cv_scale    = math.max(0.1, math.floor((cover_dimen.h / _BASE_COVER_H) * 10) / 10)

    local overlap = OverlapGroup:new{ dimen = group_dimen }
    local behind  = CoverWidgets.buildBacking(cover_dimen.w, cover_dimen.h, backing)
    if behind then overlap[#overlap + 1] = behind end
    shiftRight(content_widget, backing.left)
    overlap[#overlap + 1] = content_widget

    local label = CoverWidgets.buildLabel(item, size, border, display)
    if label then
        shiftRight(label, backing.left)
        overlap[#overlap + 1] = label
    end
    local badge = CoverWidgets.buildBadge(item.mandatory, cover_dimen, cv_scale, cell_dimen, display.badge)
    if badge then
        shiftRight(badge, backing.left)
        overlap[#overlap + 1] = badge
    end

    overlap.overlap_offset = {
        math.max(0, math.floor((item.width - group_dimen.w) / 2) - math.floor(backing.left / 2)),
        math.floor((item.height - group_dimen.h) / 2),
    }
    return OverlapGroup:new{ dimen = cell_dimen, overlap }
end

-- Free the previous widget and assign the new one. A cell is processed once
-- its cover is `complete` (the default); an incomplete one stays in the menu's
-- periodic update pass, which only drops items reporting their info as found.
function CoverWidgets.installWidget(item, widget, complete)
    complete = complete ~= false
    item._foldercover_processed = complete
    item.bookinfo_found = complete
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = widget
end

-- ── 2×2 quad cover ───────────────────────────────────────────────────────────

-- Pure 2×2 grid geometry: dimensions of the 4 quadrants (the 2nd/4th can
-- be 1px larger than the 1st/3rd when w-sep or h-sep is odd) and the
-- separator's thickness. Extracted so that anyone who needs to preload a cover
-- already at the exact size of each quadrant (e.g. Config.getCoverBB) can do so
-- without duplicating this calculation — see module_collections.lua ("Cover Style: Quad").
function CoverWidgets.computeQuadCellSizes(w, h)
    local sep = math.max(1, Screen:scaleBySize(1))
    local half_w  = math.floor((w - sep) / 2)
    local half_w2 = w - sep - half_w
    local half_h  = math.floor((h - sep) / 2)
    local half_h2 = h - sep - half_h
    return half_w, half_h, half_w2, half_h2, sep
end

-- Pure 2×2 cover collage: 4 images (or empty-fill placeholders) separated by
-- thin lines, wrapped in a bordered FrameContainer of w×h plus `border` on
-- every side. No pile, no label, no badge, no dependency on a mosaic
-- `item`/`display` — safe to call from any context that just wants a
-- quad-cover thumbnail of a given size (e.g. module_collections.lua's
-- "Cover Style: Quad").
--
-- img_list: up to 4 entries, each { file = <path> } or { data = <blitbuffer> }.
--           Missing/nil entries render as an empty (white) slot so the
--           separator lines stay visible instead of the grid collapsing.
-- Returns:
--   1. FrameContainer widget, sized w×h (including border).
--   2. cells: array of the 4 CenterContainer quadrants (each cells[i][1] is
--      the current ImageWidget/placeholder) — callers that need to swap a
--      cover in later (async cache poll) can assign cells[i][1] directly.
function CoverWidgets.buildQuadGrid(img_list, w, h, border)
    local half_w, half_h, half_w2, half_h2, sep = CoverWidgets.computeQuadCellSizes(w, h)

    local cells = {}
    for i = 1, 4 do
        local c  = img_list[i]
        local cw = (i == 1 or i == 3) and half_w or half_w2
        local ch = (i == 1 or i == 2) and half_h or half_h2
        if c then
            local img_opts = { width = cw, height = ch }
            if c.file  then img_opts.file  = c.file  end
            -- c.data is a bitmap owned by Config's cover cache (already
            -- pre-scaled to exactly cw×ch by Config.getCoverBB, so
            -- ImageWidget won't need to re-render it and will otherwise
            -- free the cache's own buffer on widget teardown — see
            -- module_collections.lua's getBookCover for the same guard).
            if c.data  then
                img_opts.image            = c.data
                img_opts.image_disposable = false
            end
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                ImageWidget:new(img_opts),
            }
        else
            -- Empty slot: white fill keeps separator lines visible.
            -- A child widget is required so FrameContainer:getSize() doesn't crash.
            cells[i] = CenterContainer:new{
                dimen = Geom:new{ w = cw, h = ch },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local sep_color = SUIStyle.COLOR.gray_soft
    local grid = FrameContainer:new{
        padding    = 0,
        bordersize = border,
        VerticalGroup:new{
            HorizontalGroup:new{
                cells[1],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h } },
                cells[2],
            },
            LineWidget:new{ background = sep_color, dimen = Geom:new{ w = w, h = sep } },
            HorizontalGroup:new{
                cells[3],
                LineWidget:new{ background = sep_color, dimen = Geom:new{ w = sep, h = half_h2 } },
                cells[4],
            },
        },
    }
    return grid, cells
end

-- Returns the OverlapGroup widget for the 2×2 grid assembled into a mosaic
-- cell (pile + folder-name label + item-count badge), or nil when no covers
-- are available. Defined after assembleCoverWidget (which it calls).
function CoverWidgets.buildQuadCover(item, img_list, border, backing, max_img_w, max_img_h, display)
    local ratio = 2 / 3
    local img_w, img_h
    if max_img_w / max_img_h > ratio then
        img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
    else
        img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
    end

    local grid = CoverWidgets.buildQuadGrid(img_list, img_w, img_h, border)

    local size = Geom:new{ w = img_w, h = img_h }
    return CoverWidgets.assembleCoverWidget(item, grid, size, border, backing, display)
end

return CoverWidgets
