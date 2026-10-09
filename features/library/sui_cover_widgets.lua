-- sui_cover_widgets.lua — Simple UI
-- Pure rendering code for folder/book cover decoration: the progress
-- pentagon, the "New" corner ribbon, rounded-rectangle badges (pages,
-- series index, "New"), the book pile, the folder-name label overlay,
-- the book-count circle badge, and 2×2 quad-cover assembly.
--
-- Nothing here touches FileChooser/MosaicMenuItem, and the only setting read
-- are the cover-shadow flags (through SUIStyle.coverShadowOffset) — every other
-- value arrives as a parameter. sui_foldercovers.lua reads its settings once
-- per update()/paintTo() cycle and passes them in. This means every function
-- below can be exercised and reasoned about in isolation from the settings
-- system and the monkeypatch machinery.
--
-- Cached state kept here: the rendered-ribbon Blitbuffer cache (rotating
-- text pixel-by-pixel is expensive, keyed by dimensions+label+colors), the
-- label line-height memo, and a reusable 8-bit mask for progress-pentagon AA
-- paints. All are cleared via the public clear*Cache() functions, which
-- sui_foldercovers.lua calls from M.invalidateCache().
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
--       -- Three shaded layers peeking out behind a cover of cover_w × cover_h.
--   CoverWidgets.paintShadow(bb, x, y, w, h, offset)
--       -- Drop shadow around a w × h card at (x, y), cast down and to the right.
--   CoverWidgets.backingInset(scope, hide_pile, scale)
--       -- Px a cover gives up on the right and bottom for whatever is drawn
--       -- behind it: the pile, or just the shadow when the pile is hidden.
--   CoverWidgets.buildBacking(cover_w, cover_h, inset, hide_pile)
--       -- The widget for that backing (nil when there is nothing to draw).
--   CoverWidgets.buildFolderNameWidget(item, available_w, font_size, fgcolor, bgcolor)
--   CoverWidgets.buildLabel(item, size, border, display)
--       -- display: { label_mode, show_name, label_style, label_pos, label_color, label_scale }
--   CoverWidgets.buildBadge(mandatory, cover_dimen, cv_scale, cell_dimen, opts)
--       -- opts: { hidden, scale, dark, position }  ("bottom" | anything else = top)
--   CoverWidgets.computeCellGeometry(item, hide_pile)
--   CoverWidgets.assembleCoverWidget(item, content_widget, size, border, pile, display)
--   CoverWidgets.buildQuadGrid(img_list, w, h, border)
--       -- Pure 2×2 cover collage, no pile/label/badge/assembly — reusable
--       -- outside the library's mosaic context (e.g. module_collections.lua).
--   CoverWidgets.buildQuadCover(item, img_list, border, pile, max_img_w, max_img_h, display)
--       -- Wraps buildQuadGrid with assembleCoverWidget (mosaic's pile/label/badge).
--   CoverWidgets.installWidget(item, widget)
--   CoverWidgets.clearRibbonCache()
--   CoverWidgets.clearLabelMetricsCache()
--   CoverWidgets.clearPentagonMaskCache()

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
local AlphaContainer  = require("ui/widget/container/alphacontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local SUIStyle        = require("features/sui_style")
local AAPaint         = require("infra/sui_aa_paint")

local CoverWidgets = {}

-- Scratch 8-bit mask reused across progress-badge paints (border, fill, check).
-- Resized when a larger badge appears; freed by clearPentagonMaskCache().
local _pentagon_mask_bb

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
local _LABEL_ALPHA      = 0.75
local _LABEL_MAX_LINES  = 2
local _LABEL_MIN_H_FRAC = 0.18
local _LABEL_GAP_FRAC   = 0.07

-- ── Progress pentagon badge ──────────────────────────────────────────────────
-- Shape: downward-pointing pentagon (rectangle body + triangular tip).
-- States: "complete" → checkmark; percent_finished set → "42%"; otherwise bare.
--
-- Edges are coverage-AA'd via infra/sui_aa_paint into a scratch 8-bit mask,
-- then composited with colorblitFromRGB32. Uncovered mask pixels stay
-- transparent, so cover art shows through the triangular tip.

local function _ensurePentagonMask(w, h)
    if _pentagon_mask_bb
            and _pentagon_mask_bb:getWidth() >= w
            and _pentagon_mask_bb:getHeight() >= h then
        return _pentagon_mask_bb
    end
    if _pentagon_mask_bb then _pentagon_mask_bb:free() end
    _pentagon_mask_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    return _pentagon_mask_bb
end

function CoverWidgets.clearPentagonMaskCache()
    if _pentagon_mask_bb then
        _pentagon_mask_bb:free()
        _pentagon_mask_bb = nil
    end
end

-- Paints a filled AA pentagon of size (bw × bh) in `color` at (bx, by) on `bb`.
local function pentagonPaintRect(bb, bx, by, bw, bh, color)
    if bw <= 0 or bh <= 0 then return end
    local mask = _ensurePentagonMask(bw, bh)
    mask:fill(SUIStyle.COLOR.surface)
    AAPaint.paintDownPentagonFill(mask, 0, 0, bw, bh, 0, 0, bw - 1, bh - 1)
    mask:invertRect(0, 0, bw, bh)
    bb:colorblitFromRGB32(mask, bx, by, 0, 0, bw, bh, color)
end

-- AA checkmark via capsule strokes (same primitive as the analogue clock hands).
local function pentagonPaintCheck(bb, bx, by, bw, bh, color)
    local tk = math.max(2, math.floor(math.min(bw, bh) / 8))
    local lx0 = bx + bw * 0.08; local ly0 = by + bh * 0.62
    local lx1 = bx + bw * 0.30; local ly1 = by + bh * 0.82
    local rx1 = bx + bw * 0.82; local ry1 = by + bh * 0.18
    local pad = math.ceil(tk / 2) + 1
    local minx = math.floor(math.min(lx0, lx1, rx1) - pad)
    local maxx = math.ceil (math.max(lx0, lx1, rx1) + pad)
    local miny = math.floor(math.min(ly0, ly1, ry1) - pad)
    local maxy = math.ceil (math.max(ly0, ly1, ry1) + pad)
    local mw = maxx - minx + 1
    local mh = maxy - miny + 1
    if mw <= 0 or mh <= 0 then return end
    local mask = _ensurePentagonMask(mw, mh)
    mask:fill(SUIStyle.COLOR.surface)
    local x1c, y1c = mw - 1, mh - 1
    AAPaint.paintCapsule(mask, lx0 - minx, ly0 - miny, lx1 - minx, ly1 - miny, tk, 0, 0, x1c, y1c)
    AAPaint.paintCapsule(mask, lx1 - minx, ly1 - miny, rx1 - minx, ry1 - miny, tk, 0, 0, x1c, y1c)
    mask:invertRect(0, 0, mw, mh)
    bb:colorblitFromRGB32(mask, minx, miny, 0, 0, mw, mh, color)
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
    -- stay inside the pentagon on small covers. Measure with RenderText
    -- (TextWidget:getSize can under-report bold widths) and shrink the
    -- font until the glyph advance fits.
    local max_text_w  = math.max(1, math.floor(bw * 0.95))

    local function fitTextWidget(text, face_name, start_sz, bold)
        local font_sz = math.max(7, start_sz)
        -- TextWidget bold uses FreeType embolden, which widens glyphs beyond
        -- the regular-face advance reported by sizeUtf8Text. Scale the
        -- measured width up so the fit accounts for that.
        local bold_scale = bold and 1.10 or 1.0
        local Screen = require("device").screen
        while font_sz > 7 do
            local face = Font:getFace(face_name, font_sz)
            -- sizeUtf8Text(x, width, face, text, kerning, bold) — 6 args.
            local measured = RenderText:sizeUtf8Text(
                0, Screen:getWidth(), face, text, true, bold
            )
            local w = measured and measured.x or 0
            if w * bold_scale <= max_text_w then
                break
            end
            font_sz = font_sz - 1
        end
        return TextWidget:new{
            text    = text,
            face    = Font:getFace(face_name, font_sz),
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
        pentagonPaintCheck(bb, sq_x, sq_y, sq, sq, text_color)
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
-- Paints a diagonal band across the top-right corner of the cover Blitbuffer
-- at 45°, with the label text rotated inside it.
--
-- Strategy: build a temp Blitbuffer (tw × band_thick) in axis-aligned space,
-- render border + fill + text into it once, then use a destination-driven
-- inverse-map loop to blit each screen pixel from the rotated source.
-- The result is cached by (dimensions, label, colors) so the per-pixel loop
-- only runs once per unique configuration, not once per cover.

local _ribbon_bb_cache = {}

function CoverWidgets.clearRibbonCache()
    for k, buf in pairs(_ribbon_bb_cache) do
        if buf and buf.free then buf:free() end
        _ribbon_bb_cache[k] = nil
    end
end

function CoverWidgets.paintCornerRibbon(bb, cover_left, cover_right, cover_top, cover_h,
                                        span, band_thick, label, font_sz, dark)
    local C = 0.70711  -- cos 45° = sin 45°

    -- Buffer width: (span + 2*band) * √2 so the ribbon ends protrude past both
    -- cover edges; the cover-bounds clipping hides the end-cuts cleanly.
    local tw = math.ceil((span + band_thick * 2) * 1.41422)
    local th = band_thick
    if tw <= 0 or th <= 0 then return end

    local bg  = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary
    local brd = SUIStyle.BADGE_BORDER_CLR

    local cache_key = string.format("%d|%d|%d|%s|%d|%d|%s|%s",
        tw, th, bb:getType(), label, font_sz, dark and 1 or 0, tostring(SUIStyle.BADGE_BORDER_SZ), tostring(brd))
    local tmp = _ribbon_bb_cache[cache_key]

    if not tmp then
        tmp = Blitbuffer.new(tw, th, bb:getType())
        if not tmp then return end

        -- 1-px border on long edges, bg interior.
        local bw = SUIStyle.BADGE_BORDER_SZ
        tmp:paintRect(0, 0, tw, th, brd)
        if bw * 2 < th then
            tmp:paintRect(0, bw, tw, th - bw * 2, bg)
        end

        -- Render label; step font down 1pt at a time until it fits, min 6pt.
        local inner_h = math.max(1, th - bw * 2)
        local max_w   = math.floor(tw * 0.82)
        local lbl, lsz
        local fs = font_sz
        repeat
            if lbl and lbl.free then lbl:free() end
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
        local lx = math.max(0, math.floor((tw - lsz.w) / 2))
        local ly = math.max(0, math.floor((th - lsz.h) / 2))
        lbl:paintTo(tmp, lx, ly)
        if lbl.free then lbl:free() end

        _ribbon_bb_cache[cache_key] = tmp
    end

    -- Destination-driven inverse-map: for each screen pixel in the ribbon's
    -- bounding box, reverse-rotate 45° to find the source pixel in tmp.
    local cx       = cover_right - math.floor(span / 2)
    local cy       = cover_top   + math.floor(span / 2)
    local half_box = math.ceil((tw + th) * C / 2) + 1
    local bb_w     = bb:getWidth()
    local bb_h     = bb:getHeight()
    local tw_half  = tw / 2
    local th_half  = th / 2
    for dy = cy - half_box, cy + half_box do
        if dy >= cover_top and dy < cover_top + cover_h and dy >= 0 and dy < bb_h then
            local dy_rel = dy - cy
            for dx = cx - half_box, cx + half_box do
                if dx >= cover_left and dx < cover_right and dx >= 0 and dx < bb_w then
                    local dx_rel = dx - cx
                    -- Inverse of +45° rotation (top-right "\" band).
                    local sx = math.floor(tw_half + (dx_rel + dy_rel) * C)
                    local sy = math.floor(th_half + (dy_rel - dx_rel) * C)
                    if sx >= 0 and sx < tw and sy >= 0 and sy < th then
                        bb:setPixel(dx, dy, tmp:getPixel(sx, sy))
                    end
                end
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
-- down-right by `step` and casting its own drop shadow in the same direction.
-- The shadow is `step` minus the outline, so outline and shadow strips tile
-- the staircase without gaps. Shadow and outline fade with depth, so the pile
-- recedes.

-- Fade factors by depth. Depth 0 is the front cover's own shadow; depth 1 is
-- the layer touching it. A factor of 1 gives the full colour, 0 gives none.
-- The outline table sets the layer count.
local _PILE_SHADOW_FADE = { [0] = 1.0, 0.58, 0.34, 0.20 }
local _PILE_BORDER_FADE = { 0.80, 0.60, 0.44 }

local _PILE_LAYERS = #_PILE_BORDER_FADE
local _PILE_STEP   = Screen:scaleBySize(5)

-- Shadow blackness before fading. Night mode inverts the frame after painting,
-- so the night base is lower to keep the shadow dark on screen.
local _PILE_SHADOW_BASE       = 0.5
local _PILE_SHADOW_BASE_NIGHT = 0.15

-- Interpolates two colours in painted space: t = 1 gives `a`, t = 0 gives `b`.
local function blend8(a, b, t)
    local av, bv = a:getColor8().a, b:getColor8().a
    return Blitbuffer.Color8(math.floor(bv + (av - bv) * t + 0.5))
end

local function pileShadowColor(depth)
    local base = Screen.night_mode and _PILE_SHADOW_BASE_NIGHT or _PILE_SHADOW_BASE
    return Blitbuffer.gray(base * _PILE_SHADOW_FADE[depth])
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

-- Cards are painted farthest first so nearer ones cover them, ending with the
-- front cover's shadow (depth 0); the front cover itself is added on top by
-- the caller. Each card is a shadow offset down-right, then its body, then its
-- outline. The body takes the shadow colour of the card in front, so it blends
-- into the strip that covers it.
function PileWidget:paintTo(bb, x, y)
    local step, shadow = self.step, self.shadow
    local stroke = SUIStyle.BADGE_BORDER_SZ
    for depth = _PILE_LAYERS, 0, -1 do
        local lx, ly = x + depth * step, y + depth * step
        bb:paintRect(lx + shadow, ly + shadow, self.card_w, self.card_h, pileShadowColor(depth))
        if depth > 0 then
            bb:paintRect(lx, ly, self.card_w, self.card_h, pileShadowColor(depth - 1))
            bb:paintBorder(lx, ly, self.card_w, self.card_h, stroke, pileBorderColor(depth))
        end
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

-- ── Cover shadow ──────────────────────────────────────────────────────────────

-- How strongly the shadow shades what lies under it: the third lightest grey
-- of the pile's shadow layers (the lightest is the deepest layer).
local _SHADOW_STRENGTH = _PILE_SHADOW_BASE * _PILE_SHADOW_FADE[_PILE_LAYERS - 2]

-- Paints the part of a drop shadow that shows around a w × h card at (x, y):
-- the card's rectangle shifted down-right by `offset`, minus the card itself.
-- The two strips never overlap. The shadow shades what is already painted
-- instead of laying a fixed grey, so it reads on any background. Night frames
-- are inverted after painting, so lightening is what darkens the shadow on
-- screen.
function CoverWidgets.paintShadow(bb, x, y, w, h, offset)
    if offset <= 0 then return end
    local shade = Screen.night_mode and bb.lightenRect or bb.darkenRect
    shade(bb, x + w,      y + offset, offset,     h,      _SHADOW_STRENGTH)
    shade(bb, x + offset, y + h,      w - offset, offset, _SHADOW_STRENGTH)
end

-- Parts of rect `r` that lie outside rect `c`, as a list of rects.
local function subtractRect(r, c)
    local rx2, ry2, cx2, cy2 = r.x + r.w, r.y + r.h, c.x + c.w, c.y + c.h
    if c.x >= rx2 or cx2 <= r.x or c.y >= ry2 or cy2 <= r.y then return { r } end
    local pieces = {}
    local mid_y1, mid_y2 = math.max(r.y, c.y), math.min(ry2, cy2)
    if c.y > r.y then pieces[#pieces + 1] = { x = r.x, y = r.y, w = r.w, h = c.y - r.y } end
    if cy2 < ry2 then pieces[#pieces + 1] = { x = r.x, y = cy2, w = r.w, h = ry2 - cy2 } end
    if c.x > r.x then pieces[#pieces + 1] = { x = r.x, y = mid_y1, w = c.x - r.x, h = mid_y2 - mid_y1 } end
    if cx2 < rx2 then pieces[#pieces + 1] = { x = cx2, y = mid_y1, w = rx2 - cx2, h = mid_y2 - mid_y1 } end
    return pieces
end

-- Paints the drop shadows of several cards (rects relative to (x, y)) as one
-- shape: shading accumulates, so a pixel under two shadows is shaded once.
function CoverWidgets.paintShadows(bb, x, y, cards, offset)
    if offset <= 0 then return end
    local shade = Screen.night_mode and bb.lightenRect or bb.darkenRect
    local painted = {}
    for _, c in ipairs(cards) do
        local strips = {
            { x = c.x + c.w,      y = c.y + offset, w = offset,       h = c.h },
            { x = c.x + offset,   y = c.y + c.h,    w = c.w - offset, h = offset },
        }
        for _, strip in ipairs(strips) do
            local pieces = { strip }
            for _, done in ipairs(painted) do
                local rest = {}
                for _, piece in ipairs(pieces) do
                    for _, part in ipairs(subtractRect(piece, done)) do rest[#rest + 1] = part end
                end
                pieces = rest
            end
            for _, p in ipairs(pieces) do
                if p.w > 0 and p.h > 0 then
                    shade(bb, x + p.x, y + p.y, p.w, p.h, _SHADOW_STRENGTH)
                end
            end
            painted[#painted + 1] = strip
        end
    end
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

local ShadowLayerWidget = {}
ShadowLayerWidget.__index = ShadowLayerWidget

function ShadowLayerWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function ShadowLayerWidget:paintTo(bb, x, y)
    CoverWidgets.paintShadows(bb, x, y, self.cards, self.offset)
end

-- See ProgressBadgeWidget:handleEvent() above for why this is required —
-- same crash, same fix, same reasoning.
function ShadowLayerWidget:handleEvent()
    return false
end

-- Widget of w × h casting the shadows of `cards` (rects relative to its
-- top-left corner) as one shape; nil when `offset` is 0.
function CoverWidgets.buildShadowLayer(w, h, cards, offset)
    if offset <= 0 then return nil end
    return setmetatable({ w = w, h = h, cards = cards, offset = offset }, ShadowLayerWidget)
end

-- Px a cover gives up on its right and bottom edges for what sits behind it:
-- the pile, or only the shadow of `scope` when the pile is hidden. `scale`
-- follows the cover's own scale (1 when omitted).
function CoverWidgets.backingInset(scope, hide_pile, scale)
    if hide_pile then return SUIStyle.coverShadowOffset(scope, scale) end
    return CoverWidgets.pileInset(scale)
end

-- Widget drawn behind a cover of cover_w × cover_h; `inset` comes from
-- backingInset(). The widget is (cover_w + inset) × (cover_h + inset) and the
-- caller draws the cover at its top-left corner.
function CoverWidgets.buildBacking(cover_w, cover_h, inset, hide_pile)
    if not hide_pile then return CoverWidgets.buildPile(cover_w, cover_h, inset) end
    if inset <= 0 then return nil end
    return setmetatable({
        w = cover_w + inset, h = cover_h + inset,
        card_w = cover_w,    card_h = cover_h,
        offset = inset,
    }, ShadowWidget)
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
        bgcolor   = bgcolor or SUIStyle.COLOR.surface,
    }
    local max_h = _LABEL_MAX_LINES * labelLineHeight(face, font_size)
    local name  = TextBoxWidget:new(opts)
    if name:getSize().h <= max_h then return name end

    name:free(true)
    opts.height                        = max_h
    opts.height_adjust                 = true
    opts.height_overflow_show_ellipsis = true
    return TextBoxWidget:new(opts)
end

-- Returns the label band laid over the cover (offset to its position), or nil
-- when disabled. The band spans the cover's width, centres the name in it and
-- is never thinner than _LABEL_MIN_H_FRAC of the cover; at the bottom it is
-- lifted off the edge so it reads as a strap around the book.
-- `display` is the pre-read settings table:
--   { label_mode, show_name, label_style, label_pos, label_color, label_scale }
function CoverWidgets.buildLabel(item, size, border, display)
    if display.label_mode ~= "overlay" then return nil end
    if not display.show_name            then return nil end
    local dark     = display.label_color == "dark"
    local bg_color = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary

    local font_size = math.max(8, math.floor(_BASE_DIR_FS * (display.label_scale or 1.0)))
    local name      = CoverWidgets.buildFolderNameWidget(item, size.w - _LATERAL_PAD * 2,
        font_size, fg_color, bg_color)

    local cover_w = size.w + border * 2
    local cover_h = size.h + border * 2
    local band_h  = math.max(name:getSize().h + (_VERTICAL_PAD + border) * 2,
                             math.floor(cover_h * _LABEL_MIN_H_FRAC))
    local band = FrameContainer:new{
        width      = cover_w,
        height     = band_h,
        padding    = 0,
        bordersize = border,
        background = bg_color,
        CenterContainer:new{
            dimen = Geom:new{ w = cover_w - border * 2, h = band_h - border * 2 },
            name,
        },
    }
    if display.label_style == "alpha" then
        band = AlphaContainer:new{ alpha = _LABEL_ALPHA, band }
    end

    local y
    if display.label_pos == "top" then
        y = 0
    elseif display.label_pos == "center" then
        y = math.floor((cover_h - band_h) / 2)
    else
        local gap = math.max(Screen:scaleBySize(3), math.floor(cover_h * _LABEL_GAP_FRAC))
        y = cover_h - band_h - gap
    end
    band.overlap_offset = { 0, math.max(0, y) }
    return band
end

-- ── Folder book-count badge (circle) ─────────────────────────────────────────

-- `cell_dimen` is the full mosaic cell (used for sizing); when absent,
-- cover_dimen is used instead (produces a smaller badge).
-- `opts`: { hidden, scale, dark, position }  (position: "bottom" | top-default)
-- The badge is anchored to the top-left of its parent group, where the cover
-- sits, so a pile extending right and below the cover does not move it.
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
-- border, the backing inset (the pile, or just the shadow when the pile is
-- hidden; 0 when there is neither) and the largest cover that still leaves
-- room for both. self.height is already reduced by _STRIP_H in
-- sui_foldercovers.lua's update() wrapper before this is called, so it must
-- NOT be subtracted again.
function CoverWidgets.computeCellGeometry(item, hide_pile)
    local border = SUIStyle.BADGE_BORDER_SZ
    local pile   = CoverWidgets.backingInset(SUIStyle.SHADOW_LIBRARY, hide_pile)
    return border, pile,
        item.width  - pile - border * 2,
        item.height - pile - border * 2
end

-- ── Cover assembly helper ─────────────────────────────────────────────────────

-- Wraps any pre-built content_widget with the backing (pile or shadow), overlays the folder-name
-- label and item-count badge, and centres the whole in the mosaic cell.
-- cv_scale is derived from cover_h here so callers don't have to compute it.
-- Must be defined before buildQuadCover, which calls it.
function CoverWidgets.assembleCoverWidget(item, content_widget, size, border, pile, display)
    local cover_dimen = Geom:new{ w = size.w + border * 2, h = size.h + border * 2 }
    local group_dimen = Geom:new{ w = cover_dimen.w + pile, h = cover_dimen.h + pile }
    local cell_dimen  = Geom:new{ w = item.width, h = item.height }
    local cv_scale    = math.max(0.1, math.floor((cover_dimen.h / _BASE_COVER_H) * 10) / 10)

    local overlap = OverlapGroup:new{ dimen = group_dimen }
    local backing = CoverWidgets.buildBacking(cover_dimen.w, cover_dimen.h, pile, display.hide_pile)
    if backing then overlap[#overlap + 1] = backing end
    overlap[#overlap + 1] = content_widget

    local label = CoverWidgets.buildLabel(item, size, border, display)
    if label then overlap[#overlap + 1] = label end
    local badge = CoverWidgets.buildBadge(item.mandatory, cover_dimen, cv_scale, cell_dimen, display.badge)
    if badge then overlap[#overlap + 1] = badge end

    overlap.overlap_offset = {
        math.floor((item.width  - group_dimen.w) / 2),
        math.floor((item.height - group_dimen.h) / 2),
    }
    return OverlapGroup:new{ dimen = cell_dimen, overlap }
end

-- Mark the cell as processed, free the previous widget, and assign the new one.
function CoverWidgets.installWidget(item, widget)
    item._foldercover_processed = true
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
function CoverWidgets.buildQuadCover(item, img_list, border, pile, max_img_w, max_img_h, display)
    local ratio = 2 / 3
    local img_w, img_h
    if max_img_w / max_img_h > ratio then
        img_h = max_img_h; img_w = math.floor(max_img_h * ratio)
    else
        img_w = max_img_w; img_h = math.floor(max_img_w / ratio)
    end

    local grid = CoverWidgets.buildQuadGrid(img_list, img_w, img_h, border)

    local size = Geom:new{ w = img_w, h = img_h }
    return CoverWidgets.assembleCoverWidget(item, grid, size, border, pile, display)
end

return CoverWidgets
