-- sui_aa_paint.lua — Simple UI
-- Shared anti-aliasing primitives for widgets that paint curved shapes
-- (circles, rounded rects, capsule strokes, downward pentagons) directly
-- into an offscreen 8-bit buffer, in BLACK ink, ahead of compositing via
-- infra/sui_core.lua's UI.paintWithAlphaMask (the same role TextWidget:paintTo
-- plays for text) or an equivalent local colorblitFromRGB32 pass.
--
-- Coverage-based, not supersampled: for every candidate pixel, this computes
-- how far the pixel's centre sits from the shape's edge and blends ink into
-- it proportionally (see blendPixel below). This needs no supersampling —
-- Blitbuffer's own :scale() is nearest-neighbour, so drawing at a larger
-- size and scaling down would not actually smooth anything.
--
-- Also draws rounded fills and borders straight onto a target buffer
-- (fillRoundedRect / strokeRoundedRect), used by the shared backdrop painter.
--
-- Used by modules/module_clock.lua (analogue clock face),
-- modules/module_reading_goals.lua (goal progress rings),
-- engines/sui_quickactions_render.lua (quick-action tile background/border),
-- and features/library/sui_cover_widgets.lua (progress pentagon badge).

local Blitbuffer = require("ffi/blitbuffer")

local M = {}

-- Blends `cov` (coverage in [0,1], 1 = full ink) as black into pixel
-- (px,py) of `bb`, clipped to [x0,x1] x [y0,y1]. Over-composites onto
-- whatever grey value is already there, so overlapping shapes (e.g. a fill
-- and the stroke painted on top of it) compound correctly instead of one
-- overwriting the other.
function M.blendPixel(bb, px, py, cov, x0, y0, x1, y1)
    if cov <= 0 then return end
    if px < x0 or px > x1 or py < y0 or py > y1 then return end
    if cov > 1 then cov = 1 end
    local g = bb:getPixel(px, py):getColor8().a
    bb:setPixel(px, py, Blitbuffer.Color8(math.floor(g * (1 - cov) + 0.5)))
end

-- Paints an anti-aliased capsule (a straight stroke of full width `width`,
-- rounded at both ends) from (ax,ay) to (bx,by) onto `bb`. For every
-- candidate pixel, projects it onto the segment to find the nearest point
-- on the stroke's centre line, then blends by how far the pixel's centre
-- sits inside the stroke's half-width — pixels fully inside get full ink,
-- pixels straddling the edge get partial ink, giving a smooth edge at
-- whatever resolution `bb` actually is.
function M.paintCapsule(bb, ax, ay, bx, by, width, x0, y0, x1, y1)
    local half = width / 2
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local minx = math.floor(math.min(ax, bx) - half - 1)
    local maxx = math.floor(math.max(ax, bx) + half + 1)
    local miny = math.floor(math.min(ay, by) - half - 1)
    local maxy = math.floor(math.max(ay, by) + half + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local qx, qy = ax + t * dx, ay + t * dy
            local ddx, ddy = px - qx, py - qy
            local dist = math.sqrt(ddx * ddx + ddy * ddy)
            M.blendPixel(bb, px, py, half + 0.5 - dist, x0, y0, x1, y1)
        end
    end
end

-- Signed distance from point (px,py) to the edge of a rounded rectangle
-- centred at (cx,cy) with half-extents (hw,hh) and corner radius `radius`
-- (clamped to fit within the half-extents). Negative = inside the shape,
-- positive = outside, zero = exactly on the edge. A plain rectangle
-- (radius = 0) and a circle/stadium (radius = min(hw,hh)) both fall out of
-- this same formula, so callers never need a separate code path per shape.
local function _roundedRectSDF(px, py, cx, cy, hw, hh, radius)
    radius = math.min(radius, hw, hh)
    local qx = math.abs(px - cx) - hw + radius
    local qy = math.abs(py - cy) - hh + radius
    local ax, ay = math.max(qx, 0), math.max(qy, 0)
    return math.sqrt(ax * ax + ay * ay) + math.min(math.max(qx, qy), 0) - radius
end

-- Paints an anti-aliased, filled rounded rectangle (x,y,w,h,radius) onto
-- `bb`. Shares _roundedRectSDF with paintRoundedRectStroke below, so a
-- filled shape's corners always match its own border's corners exactly.
function M.paintRoundedRectFill(bb, x, y, w, h, radius, x0, y0, x1, y1)
    local cx, cy = x + w / 2, y + h / 2
    local hw, hh = w / 2, h / 2
    local minx = math.floor(x - 1)
    local maxx = math.floor(x + w + 1)
    local miny = math.floor(y - 1)
    local maxy = math.floor(y + h + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local d = _roundedRectSDF(px + 0.5, py + 0.5, cx, cy, hw, hh, radius)
            M.blendPixel(bb, px, py, 0.5 - d, x0, y0, x1, y1)
        end
    end
end

-- Paints an anti-aliased rounded-rectangle outline (stroke), `thickness`
-- wide, centred on the rounded rect (x,y,w,h,radius) — same centre-line
-- convention as paintCapsule. Callers wanting the stroke fully inside a
-- given outer rect (the usual "border" look) inset x/y/w/h by half the
-- thickness and shrink radius by the same amount before calling this.
function M.paintRoundedRectStroke(bb, x, y, w, h, radius, thickness, x0, y0, x1, y1)
    local cx, cy = x + w / 2, y + h / 2
    local hw, hh = w / 2, h / 2
    local half_t = thickness / 2
    local minx = math.floor(x - half_t - 1)
    local maxx = math.floor(x + w + half_t + 1)
    local miny = math.floor(y - half_t - 1)
    local maxy = math.floor(y + h + half_t + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local d = _roundedRectSDF(px + 0.5, py + 0.5, cx, cy, hw, hh, radius)
            M.blendPixel(bb, px, py, half_t + 0.5 - math.abs(d), x0, y0, x1, y1)
        end
    end
end

-- Paints a progress ring (hollow arc) centred at (cx, cy).
--
-- outer_r    : outer radius of the ring in pixels
-- thickness  : radial width of the band (outer_r - inner_r)
-- fraction   : progress in [0, 1]; 0 = empty track only, 1 = full ring
-- track_cov  : ink coverage for the unfilled track (0–1); default 0.32 so the
--              track reads lighter than the progress arc after alpha-mask
--              recolouring. Pass 0 to omit the track.
--
-- Angle convention matches bookends' radial bars and the analogue clock:
-- 0 at 12 o'clock, increasing clockwise. Progress fills from 12 o'clock.
--
-- Drawn in BLACK (or partial grey via track_cov) into an offscreen 8-bit
-- buffer for compositing via UI.paintWithAlphaMask — same pipeline as the
-- analogue clock face.
function M.paintRingProgress(bb, cx, cy, outer_r, thickness, fraction, x0, y0, x1, y1, track_cov)
    if outer_r < 1 or thickness < 1 then return end
    fraction = fraction or 0
    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    if track_cov == nil then track_cov = 0.32 end
    if track_cov < 0 then track_cov = 0 elseif track_cov > 1 then track_cov = 1 end

    local inner_r = outer_r - thickness
    if inner_r < 0 then inner_r = 0 end

    local two_pi = 2 * math.pi
    local minx = math.floor(cx - outer_r - 1)
    local maxx = math.floor(cx + outer_r + 1)
    local miny = math.floor(cy - outer_r - 1)
    local maxy = math.floor(cy + outer_r + 1)

    for py = miny, maxy do
        for px = minx, maxx do
            local dx = px + 0.5 - cx
            local dy = py + 0.5 - cy
            local dist = math.sqrt(dx * dx + dy * dy)
            -- Radial coverage: soft edge at outer and inner boundaries.
            local outer_cov = outer_r + 0.5 - dist
            local inner_cov = dist - (inner_r - 0.5)
            local radial = outer_cov
            if inner_cov < radial then radial = inner_cov end
            if radial <= 0 then goto continue end
            if radial > 1 then radial = 1 end

            -- Angle: 0 at 12 o'clock, clockwise (atan2(x, -y)).
            local angle = math.atan2(dx, -dy)
            if angle < 0 then angle = angle + two_pi end
            local pixel_frac = angle / two_pi

            if pixel_frac <= fraction then
                M.blendPixel(bb, px, py, radial, x0, y0, x1, y1)
            elseif track_cov > 0 then
                M.blendPixel(bb, px, py, radial * track_cov, x0, y0, x1, y1)
            end
            ::continue::
        end
    end

    -- Rounded caps on the progress arc (matches BetterStats-style rings).
    -- Cap centres sit on the ring midline; radius = half the stroke width.
    if fraction > 0 then
        local mid_r = (outer_r + inner_r) / 2
        local cap_r = thickness / 2
        local function paintCap(angle)
            local sn, co = math.sin(angle), math.cos(angle)
            local cpx = cx + mid_r * sn
            local cpy = cy - mid_r * co
            local cminx = math.floor(cpx - cap_r - 1)
            local cmaxx = math.floor(cpx + cap_r + 1)
            local cminy = math.floor(cpy - cap_r - 1)
            local cmaxy = math.floor(cpy + cap_r + 1)
            for py = cminy, cmaxy do
                for px = cminx, cmaxx do
                    local ddx = px + 0.5 - cpx
                    local ddy = py + 0.5 - cpy
                    local dist = math.sqrt(ddx * ddx + ddy * ddy)
                    M.blendPixel(bb, px, py, cap_r + 0.5 - dist, x0, y0, x1, y1)
                end
            end
        end
        paintCap(0)
        if fraction < 1 then
            paintCap(fraction * two_pi)
        end
    end
end

-- Signed distance from (px,py) to the edge of a downward-pointing pentagon
-- whose top-left is (0,0) and size is (w,h). Body is a rectangle of height
-- h * 30/42; the remaining height is a centred triangular tip. Negative =
-- inside, positive = outside. Convex, so SDF = max of outward half-plane
-- distances for the five edges.
local function _downPentagonSDF(px, py, w, h)
    local rect_h = h * (30 / 42)
    local hw = w * 0.5
    -- Outward signed distance for each edge (CCW vertices).
    -- Top:    (0,0) → (w,0)
    local d = -py
    -- Right:  (w,0) → (w,rect_h)
    local d_right = px - w
    if d_right > d then d = d_right end
    -- Right diagonal: (w,rect_h) → (hw,h)
    do
        local ex, ey = hw - w, h - rect_h
        local len = math.sqrt(ex * ex + ey * ey)
        if len > 0 then
            local nx, ny = ey / len, -ex / len
            local dd = (px - w) * nx + (py - rect_h) * ny
            if dd > d then d = dd end
        end
    end
    -- Left diagonal: (hw,h) → (0,rect_h)
    do
        local ex, ey = 0 - hw, rect_h - h
        local len = math.sqrt(ex * ex + ey * ey)
        if len > 0 then
            local nx, ny = ey / len, -ex / len
            local dd = (px - hw) * nx + (py - h) * ny
            if dd > d then d = dd end
        end
    end
    -- Left:   (0,rect_h) → (0,0)
    local d_left = -px
    if d_left > d then d = d_left end
    return d
end

-- Paints an anti-aliased filled downward-pointing pentagon (x,y,w,h) onto
-- `bb`. Geometry matches the library progress badge: rectangular body over
-- the top 30/42 of height, centred triangular tip below.
function M.paintDownPentagonFill(bb, x, y, w, h, x0, y0, x1, y1)
    if w <= 0 or h <= 0 then return end
    local minx = math.floor(x - 1)
    local maxx = math.floor(x + w + 1)
    local miny = math.floor(y - 1)
    local maxy = math.floor(y + h + 1)
    for py = miny, maxy do
        for px = minx, maxx do
            local d = _downPentagonSDF(px + 0.5 - x, py + 0.5 - y, w, h)
            M.blendPixel(bb, px, py, 0.5 - d, x0, y0, x1, y1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Direct-to-buffer rounded shapes
--
-- Only the four corners of a rounded rectangle need per-pixel coverage; the
-- interior and the straight edges are plain rectangles. Each shape is drawn
-- as native rectangle fills plus four corner quadrants blitted from a cached
-- (2r x 2r) coverage mask, so the cost depends on the radius only, never on
-- the size of the shape.
-- ---------------------------------------------------------------------------

local _CORNER_CACHE_MAX = 16
local _corner_cache     = {}
local _corner_cache_n   = 0

-- Cache keys: fill masks are keyed by (radius, alpha), stroke masks by
-- (radius, thickness); the low bit tells the two kinds apart.
local function _maskKey(is_stroke, radius, param)
    return (radius * 256 + param) * 2 + (is_stroke and 1 or 0)
end

local function _cachedMask(key, build)
    local mask = _corner_cache[key]
    if mask then return mask end
    if _corner_cache_n >= _CORNER_CACHE_MAX then
        for k, m in pairs(_corner_cache) do
            m:free()
            _corner_cache[k] = nil
        end
        _corner_cache_n = 0
    end
    mask = build()
    _corner_cache[key] = mask
    _corner_cache_n = _corner_cache_n + 1
    return mask
end

-- Returns a 2r x 2r coverage mask (grey = coverage) of a circle of radius r,
-- scaled by alpha/255.
local function _buildFillMask(radius, alpha)
    local size = radius * 2
    local mask = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    M.paintRoundedRectFill(mask, 0, 0, size, size, radius, 0, 0, size - 1, size - 1)
    mask:invertRect(0, 0, size, size)
    if alpha < 255 then
        local scale = alpha / 255
        for py = 0, size - 1 do
            for px = 0, size - 1 do
                local g = mask:getPixel(px, py):getColor8().a
                if g > 0 then
                    mask:setPixel(px, py, Blitbuffer.Color8(math.floor(g * scale + 0.5)))
                end
            end
        end
    end
    return mask
end

-- Returns a 2r x 2r coverage mask of a ring of outer radius r and the given
-- thickness.
local function _buildStrokeMask(radius, thickness)
    local size = radius * 2
    local half = thickness / 2
    local mask = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    M.paintRoundedRectStroke(mask, half, half, size - thickness, size - thickness,
        radius - half, thickness, 0, 0, size - 1, size - 1)
    mask:invertRect(0, 0, size, size)
    return mask
end

-- Blits the four r x r quadrants of `mask` onto the corners of (x, y, w, h).
-- Returns false, before drawing anything, when the buffer cannot colour-blit.
local function _blitCorners(bb, mask, x, y, w, h, r, color)
    local blit = bb.colorblitFromRGB32 or bb.colorblitFrom
    if not blit then return false end
    blit(bb, mask, x,         y,         0, 0, r, r, color)
    blit(bb, mask, x + w - r, y,         r, 0, r, r, color)
    blit(bb, mask, x,         y + h - r, 0, r, r, r, color)
    blit(bb, mask, x + w - r, y + h - r, r, r, r, r, color)
    return true
end

-- Corner radius that fits inside a w x h rectangle.
local function _fitRadius(radius, w, h)
    return math.min(math.floor(radius), math.floor(w / 2), math.floor(h / 2))
end

-- Fills a plain rectangle with `color` at `alpha` (0-255): a straight paint
-- when opaque, a native blend otherwise.
function M.fillRect(bb, x, y, w, h, color, alpha)
    if w <= 0 or h <= 0 then return end
    if alpha < 255 and bb.blendRectRGB32 then
        local rgb = color:getColorRGB32()
        bb:blendRectRGB32(x, y, w, h, Blitbuffer.ColorRGB32(rgb.r, rgb.g, rgb.b, alpha))
    elseif bb.paintRectRGB32 then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        bb:paintRect(x, y, w, h, color)
    end
end

-- Fills the rounded rectangle (x, y, w, h, radius) with `color` at `alpha`
-- (0-255) using anti-aliased corners. Returns false when the corners cannot
-- be drawn, leaving `bb` untouched.
function M.fillRoundedRect(bb, x, y, w, h, radius, color, alpha)
    local r = _fitRadius(radius, w, h)
    if r <= 0 then
        M.fillRect(bb, x, y, w, h, color, alpha)
        return true
    end
    local mask = _cachedMask(_maskKey(false, r, alpha), function()
        return _buildFillMask(r, alpha)
    end)
    if not _blitCorners(bb, mask, x, y, w, h, r, color) then return false end
    M.fillRect(bb, x + r, y,         w - 2 * r, r,         color, alpha)
    M.fillRect(bb, x + r, y + h - r, w - 2 * r, r,         color, alpha)
    M.fillRect(bb, x,     y + r,     w,         h - 2 * r, color, alpha)
    return true
end

-- Draws an opaque rounded border of `thickness` inside (x, y, w, h) with
-- anti-aliased corners. Returns false, leaving `bb` untouched, when the
-- radius is too small for the corner masks or the corners cannot be drawn.
function M.strokeRoundedRect(bb, x, y, w, h, radius, thickness, color)
    local r = _fitRadius(radius, w, h)
    if r <= thickness then return false end
    local mask = _cachedMask(_maskKey(true, r, thickness), function()
        return _buildStrokeMask(r, thickness)
    end)
    if not _blitCorners(bb, mask, x, y, w, h, r, color) then return false end
    local edge_w, edge_h = w - 2 * r, h - 2 * r
    M.fillRect(bb, x + r,             y,                 edge_w,    thickness, color, 255)
    M.fillRect(bb, x + r,             y + h - thickness, edge_w,    thickness, color, 255)
    M.fillRect(bb, x,                 y + r,             thickness, edge_h,    color, 255)
    M.fillRect(bb, x + w - thickness, y + r,             thickness, edge_h,    color, 255)
    return true
end

return M
