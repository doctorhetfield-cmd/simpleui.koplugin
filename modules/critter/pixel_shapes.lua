-- pixel_shapes.lua — Simple UI
-- Pixel-art geometry of the Critter module: the speech box with stepped
-- corners, its staircase tail, small glyphs and the placement of a panel under
-- (or above) a box. Everything is a list of rectangles { x, y, w, h } in pixels,
-- relative to the top-left corner of the shape, built from square cells of one
-- `unit`. The module is pure: it draws nothing.

local Shapes = {}

-- Fewest cells a box needs on each side so its corners do not meet.
local MIN_CELLS = 6

-- Rectangles of `unit` px covering the cells (col, row) of a cols x rows grid
-- that `has` accepts, with the contiguous cells of a row joined.
local function rectsOf(cols, rows, unit, has)
    local rects = {}
    for row = 0, rows - 1 do
        local start
        for col = 0, cols do
            local on = col < cols and has(col, row)
            if on and not start then start = col end
            if not on and start then
                rects[#rects + 1] = { x = start * unit, y = row * unit, w = (col - start) * unit, h = unit }
                start = nil
            end
        end
    end
    return rects
end

--- Box of about w x h px with stepped corners: its size snaps down to whole
--- units. `border` is the 1-unit contour and `fill` the inside; nil when a side
--- is under 6 units or `unit` is under 1.
function Shapes.box(w, h, unit)
    if unit < 1 then return nil end
    local cols, rows = math.floor(w / unit), math.floor(h / unit)
    if cols < MIN_CELLS or rows < MIN_CELLS then return nil end

    -- Steps from the nearest corner: a cell is cut when they add up to 1 or
    -- less, and the next diagonal is part of the contour.
    local function corner(col, row)
        return math.min(col, cols - 1 - col) + math.min(row, rows - 1 - row)
    end
    local function ring(col, row)
        return col == 0 or row == 0 or col == cols - 1 or row == rows - 1
    end
    local function isBorder(col, row)
        local steps = corner(col, row)
        if steps <= 1 then return false end
        return ring(col, row) or steps == 2
    end
    local function isFill(col, row)
        return corner(col, row) > 1 and not isBorder(col, row)
    end
    return {
        w      = cols * unit,
        h      = rows * unit,
        border = rectsOf(cols, rows, unit, isBorder),
        fill   = rectsOf(cols, rows, unit, isFill),
    }
end

--- Hooked tail of `steps` columns and `steps` rows (2 or more). The top edge
--- slants down to the tip, which sits one row above the bottom; the bottom
--- edge is flat. The tip is on the `side` ("left" | "right") and the base
--- column, which joins the box, on the other and is filled whole, so the tail
--- opens into the box. `border` is the whole silhouette; `fill` the base column
--- and the cells whose neighbours towards the tip, above and below are in it.
function Shapes.tail(steps, unit, side)
    local base = steps - 1
    -- Cell (col, row) of the silhouette pointing left.
    local function inside(col, row)
        if row < 0 or row >= steps or col < 0 or col >= steps then return false end
        return col == base or (row >= base - 1 - col and row <= base - 1 + col)
    end
    local function flip(col) return side == "right" and base - col or col end
    local function isBorder(col, row) return inside(flip(col), row) end
    local function isFill(col, row)
        local c = flip(col)
        if c == base then return true end
        return inside(c, row) and inside(c - 1, row) and inside(c, row - 1) and inside(c, row + 1)
    end
    return {
        w      = steps * unit,
        h      = steps * unit,
        border = rectsOf(steps, steps, unit, isBorder),
        fill   = rectsOf(steps, steps, unit, isFill),
    }
end

-- Bitmaps of the glyphs, one string per row.
local BITMAPS = {
    arrow    = { "X..", "XX.", "XXX", "XX.", "X.." },
    question = { ".XXX.", "X...X", "....X", "..XX.", "..X..", ".....", "..X.." },
}

--- Glyph `name` ("arrow" or "question") of `unit`-px cells:
--- { w, h, rects }.
function Shapes.glyph(name, unit)
    local bitmap = BITMAPS[name]
    local cols, rows = #bitmap[1], #bitmap
    return {
        w     = cols * unit,
        h     = rows * unit,
        rects = rectsOf(cols, rows, unit, function(col, row)
            return bitmap[row + 1]:sub(col + 1, col + 1) == "X"
        end),
    }
end

--- Steps and top (from the top of a box `box_h` px tall) of the tail of that box,
--- for a tail `reach` px long, nil when the box is too short for one. The box shape
--- snaps to whole units and sits in the middle of `box_h`; the tail stays on the
--- straight part of its edge and is centred on it.
function Shapes.tailRows(box_h, reach, unit)
    local rows = math.floor(box_h / unit)
    local steps = math.min(reach / unit + 1, rows - 4)
    if steps < 2 then return nil end
    local shape_top = math.floor((box_h - rows * unit) / 2)
    return steps, shape_top + math.floor((rows - steps) / 2) * unit
end

--- Top of a panel of `panel_h` px next to an anchor spanning anchor_y ..
--- anchor_y + anchor_h on a screen of `screen_h`: below it (`gap` apart) when it
--- fits above the bottom margin, else above it. A panel that fits on the screen
--- but on neither side leans on the edge where it covers the anchor least, and
--- one taller than the screen starts at the top margin. Returns the top and
--- whether the panel is above the anchor.
function Shapes.stack(anchor_y, anchor_h, panel_h, screen_h, margin, gap)
    local below = anchor_y + anchor_h + gap
    if below + panel_h <= screen_h - margin then return below, false end
    local above = anchor_y - gap - panel_h
    if above >= margin then return above, true end
    if panel_h > screen_h - 2 * margin then return margin, true end
    local low = screen_h - margin - panel_h
    if anchor_y + anchor_h - low < margin + panel_h - anchor_y then return low, false end
    return margin, true
end

return Shapes
