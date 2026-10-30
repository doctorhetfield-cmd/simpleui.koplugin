-- sui_stats_charts.lua — Simple UI
-- Small statistics glyphs and bar charts drawn straight onto the screen buffer
-- with anti-aliased shapes (no image buffers of their own: the corner masks
-- come from the shared raster cache). Colours are passed in by the caller, so the
-- glyphs follow the theme, the card surface and night mode.
--
-- Usage:
--   local size, gap = Charts.fitDots(7, avail_w, avail_h, max_size)
--   local row = size and Charts.weekDots{ states = {...}, size = size, gap = gap, color = c }
--
--   local bar_w, gap = Charts.fitBars(24, avail_w, max_bar_w)
--   local chart = bar_w and Charts.bars{ values = {...}, bar_w = bar_w, gap = gap,
--                                        avail_h = h, color = c, highlight = i }
--
--   local size, gap, cols, gap_x = Charts.fitGrid(7, 26, avail_w, avail_h, max_size, 12)
--   local grid = size and Charts.heatmap{ levels = {...}, size = size, gap = gap,
--                                         gap_x = gap_x, color = c, today = {col, row} }
--
--   local share = Charts.share{ values = {...}, w = avail_w, avail_h = h, bar_h = max_h, color = c }
--   local h = Charts.shareHeight(bar_h, label_h)   -- height of a share bar with labels
--
--   local drums = Charts.odometer{ digits = "001234", rolling = true, w = avail_w,
--                                  avail_h = h, max_w = bar_max, color = c, digit_color = d }
--
-- Dot states: "read" (filled), "frozen" (ring) and anything else (faint).
-- Heatmap levels: 0 (no reading) to 4, or false for a cell that does not exist.

local AAPaint         = require("infra/sui_aa_paint")
local Geom            = require("ui/geometry")
local SUIStyle        = require("features/sui_style")
local UI              = require("infra/sui_core")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Charts = {}

local MIN_DOT_SIZE = 5     -- px; smaller dots are not legible
local GAP_RATIO    = 0.7   -- gap between dots, relative to the dot size
local FAINT_ALPHA  = 70    -- 0-255 ink of a dot with no reading
local FULL_ALPHA   = 255

local MIN_BAR_W     = 3     -- px; narrower bars are not legible
local MIN_BAR_H     = 6     -- px; a chart area shorter than this is not legible
local MIN_VALUE_H   = 2     -- px; shortest bar drawn for a non-zero value
local BAR_GAP_RATIO = 0.5   -- gap between bars, relative to the bar width
local BAR_DIM_ALPHA = 110   -- 0-255 ink of the bars that are not highlighted
local BASE_ALPHA    = 70    -- 0-255 ink of the baseline
local BASE_H        = 1     -- baseline thickness (px)
local BAR_RADIUS    = 3     -- max corner radius of a bar (px)
local LABEL_GAP     = 2     -- space between the baseline and the axis labels (px)
local PAIR_GAP      = 1     -- space between the two bars of a pair (px)

local MIN_CELL        = 4     -- px; smaller heatmap cells are not legible
local CELL_GAP_RATIO  = 0.25  -- gap between heatmap cells, relative to the cell size
local CELL_RADIUS_PCT = 0.25  -- corner radius of a heatmap cell, relative to its size
local LEVEL_ALPHA     = { [0] = 55, 105, 150, 205, 255 }  -- 0-255 ink per heatmap level

local MIN_DRUM_W     = 8     -- px; narrower drums are not legible
local DRUM_RATIO     = 1.4   -- drum height, relative to its width
local DRUM_GAP_RATIO = 0.12  -- gap between drums, relative to the drum width
local DRUM_RADIUS_PCT = 0.22 -- corner radius of a drum, relative to its width
local DRUM_DIGIT_PCT = 0.62  -- digit size, relative to the drum height
local DRUM_PITCH_PCT = 0.8   -- distance between two digits on a turning drum, relative to its height
local DRUM_ROLL_PCT  = 0.3   -- how far the turning drum has moved to its next digit, relative to the pitch

local MIN_SEGMENT_W = 3     -- px; narrowest share segment drawn for a non-zero value
local SEGMENT_GAP   = 2     -- space between share segments (px)

local function gapFor(size)
    return math.max(1, math.floor(size * GAP_RATIO))
end

-- Largest dot size (and its gap) at which `count` dots fit in avail_w x
-- avail_h, capped at `max_size`. Returns nil when even the smallest legible
-- dots do not fit.
function Charts.fitDots(count, avail_w, avail_h, max_size)
    local size = math.min(max_size, avail_h)
    while size >= MIN_DOT_SIZE do
        local gap = gapFor(size)
        if count * size + (count - 1) * gap <= avail_w then return size, gap end
        size = size - 1
    end
end

local function paintDot(bb, x, y, size, state, color)
    if state == "read" then
        AAPaint.fillPill(bb, x, y, size, size, color, FULL_ALPHA)
    elseif state == "frozen" then
        local thickness = math.max(1, math.floor(size / 6))
        if not AAPaint.strokeRoundedRect(bb, x, y, size, size, size / 2, thickness, color) then
            bb:paintBorder(x, y, size, size, thickness, color)
        end
    else
        AAPaint.fillPill(bb, x, y, size, size, color, FAINT_ALPHA)
    end
end

-- One row of dots, one per entry of `opts.states` (oldest first).
-- opts: states, size (px), gap (px), color.
function Charts.weekDots(opts)
    local states, size, gap = opts.states, opts.size, opts.gap
    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = #states * size + (#states - 1) * gap, h = size }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        for i, state in ipairs(states) do
            paintDot(bb, x + (i - 1) * (size + gap), y, size, state, opts.color)
        end
    end

    return widget
end

-- Width of the slot of one bar, or of a pair of bars.
local function slotWidth(bar_w, paired)
    return paired and 2 * bar_w + PAIR_GAP or bar_w
end

-- Largest bar width (and its gap) at which `count` bars (or pairs of bars, when
-- `paired`) fit in avail_w, capped at `max_w`. Returns nil when even the
-- narrowest legible bars do not fit.
function Charts.fitBars(count, avail_w, max_w, paired)
    local w = max_w
    while w >= MIN_BAR_W do
        local gap = math.max(1, math.floor(w * BAR_GAP_RATIO))
        if count * slotWidth(w, paired) + (count - 1) * gap <= avail_w then return w, gap end
        w = w - 1
    end
end

-- Largest square cell (and its gap) at which `rows` rows of cells and at least
-- `min_cols` columns fit in avail_w x avail_h, capped at `max_size`. Returns the
-- cell size, the gap, the number of columns (up to `max_cols`) and the gap
-- between columns, widened to spread a full set of columns over avail_w. Returns
-- nil when no legible cell size does.
function Charts.fitGrid(rows, max_cols, avail_w, avail_h, max_size, min_cols)
    local size = max_size
    while size >= MIN_CELL do
        local gap = math.max(1, math.floor(size * CELL_GAP_RATIO))
        if rows * size + (rows - 1) * gap <= avail_h then
            local cols = math.min(max_cols, math.floor((avail_w + gap) / (size + gap)))
            if cols >= min_cols then
                local gap_x = gap
                if cols == max_cols and cols > 1 then
                    gap_x = math.max(gap, math.min(size, math.floor((avail_w - cols * size) / (cols - 1))))
                end
                return size, gap, cols, gap_x
            end
        end
        size = size - 1
    end
end

local function paintBar(bb, x, y, w, h, color, alpha)
    if not AAPaint.fillRoundedRect(bb, x, y, w, h, math.min(BAR_RADIUS, w / 2), color, alpha) then
        AAPaint.fillRect(bb, x, y, w, h, color, alpha)
    end
end

local function freeLabels(labels)
    for _, label in ipairs(labels or {}) do
        if label then label:free() end
    end
end

-- One coloured text widget per string (false for ""). Returns the widgets and
-- the widest and tallest sizes.
local function buildTexts(texts, face, color)
    local widgets, widest, tallest = {}, 0, 0
    for i, text in ipairs(texts) do
        if text ~= "" then
            widgets[i] = UI.makeColoredText{ text = text, face = face, fgcolor = color }
            local size = widgets[i]:getSize()
            widest, tallest = math.max(widest, size.w), math.max(tallest, size.h)
        else
            widgets[i] = false
        end
    end
    return widgets, widest, tallest
end

-- Axis labels, one per bar. Returns the labels and their row height, or nil
-- when they would overlap their neighbours.
local function buildLabels(opts)
    local widgets, widest, tallest = buildTexts(opts.labels, opts.label_face, opts.label_color)
    if widest <= slotWidth(opts.bar_w, opts.ghost) + opts.gap then return widgets, tallest + LABEL_GAP end
    freeLabels(widgets)
end

-- Bar chart: one bar per entry of `opts.values` (oldest first), scaled to the
-- largest value, standing on a faint baseline. The bar at `opts.highlight`
-- gets full ink and the others a lighter one; without a highlight all bars
-- get full ink (an index that matches no bar, such as 0, lightens them all).
-- Zero values draw no bar. With `opts.ghost` (one value per bar, same scale), each
-- bar gets a lighter twin on its left, e.g. the same day of the week before;
-- size the chart with fitBars(..., true).
-- opts: values, bar_w, gap (px), avail_h (px; the widget never exceeds it),
--       max_h (optional cap on the bars area, value labels included),
--       peak (optional value that gets the full bar height, to share one scale
--       between charts), color, highlight (optional index) and, for text:
--       labels (axis, one string per bar, "" for none), label_face,
--       label_color, value_labels (strings drawn above the bars, same face
--       and colour).
-- Returns nil when avail_h cannot hold a legible chart. The axis is left out
-- when it would not fit.
function Charts.bars(opts)
    local values, bar_w, gap, color = opts.values, opts.bar_w, opts.gap, opts.color
    local labels, label_h
    if opts.labels then labels, label_h = buildLabels(opts) end
    if labels and opts.avail_h - label_h < MIN_BAR_H then
        freeLabels(labels)
        labels = nil
    end
    label_h = labels and label_h or 0
    local area_h = math.min(opts.max_h or opts.avail_h, opts.avail_h - label_h)
    if area_h < MIN_BAR_H then return nil end

    local value_labels, value_h = nil, 0
    if opts.value_labels then
        local texts, _widest, tallest = buildTexts(opts.value_labels, opts.label_face, opts.label_color)
        value_labels, value_h = texts, tallest
    end
    if area_h - value_h < MIN_BAR_H then
        freeLabels(value_labels)
        value_labels, value_h = nil, 0
    end

    local ghost = opts.ghost
    local peak = opts.peak or 0
    if not opts.peak then
        for i, v in ipairs(values) do peak = math.max(peak, v, ghost and ghost[i] or 0) end
    end

    local slot_w = slotWidth(bar_w, ghost)
    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = #values * slot_w + (#values - 1) * gap, h = area_h + label_h }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local bars_h = area_h - BASE_H - value_h
        local base_y = y + value_h + bars_h
        AAPaint.fillRect(bb, x, base_y, self.dimen.w, BASE_H, color, BASE_ALPHA)
        for i, v in ipairs(values) do
            local sx = x + (i - 1) * (slot_w + gap)
            local bx = ghost and sx + bar_w + PAIR_GAP or sx
            if ghost and ghost[i] > 0 and peak > 0 then
                local gh = math.max(MIN_VALUE_H, math.floor(ghost[i] / peak * bars_h + 0.5))
                paintBar(bb, sx, base_y - gh, bar_w, gh, color, BAR_DIM_ALPHA)
            end
            if v > 0 and peak > 0 then
                local h = math.max(MIN_VALUE_H, math.floor(v / peak * bars_h + 0.5))
                local alpha = (not opts.highlight or i == opts.highlight) and FULL_ALPHA or BAR_DIM_ALPHA
                paintBar(bb, bx, base_y - h, bar_w, h, color, alpha)
                local value_label = value_labels and value_labels[i]
                if value_label then
                    value_label:paintTo(bb, bx + math.floor((bar_w - value_label:getSize().w) / 2),
                        base_y - h - value_h)
                end
            end
            local label = labels and labels[i]
            if label then
                label:paintTo(bb, sx + math.floor((slot_w - label:getSize().w) / 2), y + area_h + LABEL_GAP)
            end
        end
    end

    function widget:free()
        freeLabels(labels)
        freeLabels(value_labels)
    end

    return widget
end

-- Heatmap: a grid of rounded cells, one column per entry of `opts.levels` (oldest
-- first) and one row per entry of each column (top first); each cell's ink
-- follows its level. `opts.today` = { col, row } outlines the current cell.
-- opts: levels, size (px), gap (px between rows), gap_x (px between columns,
--       defaults to gap), color, today (optional).
function Charts.heatmap(opts)
    local levels, size, gap, color = opts.levels, opts.size, opts.gap, opts.color
    local gap_x = opts.gap_x or gap
    local cols, rows = #levels, #levels[1]
    local radius = math.max(1, math.floor(size * CELL_RADIUS_PCT))
    local outline = math.max(1, math.floor(size / 6))

    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = cols * size + (cols - 1) * gap_x, h = rows * size + (rows - 1) * gap }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        for col, column in ipairs(levels) do
            local cx = x + (col - 1) * (size + gap_x)
            for row, level in ipairs(column) do
                if level then
                    local cy = y + (row - 1) * (size + gap)
                    if not AAPaint.fillRoundedRect(bb, cx, cy, size, size, radius, color, LEVEL_ALPHA[level]) then
                        AAPaint.fillRect(bb, cx, cy, size, size, color, LEVEL_ALPHA[level])
                    end
                end
            end
        end
        local today = opts.today
        if today then
            local cx = x + (today[1] - 1) * (size + gap_x)
            local cy = y + (today[2] - 1) * (size + gap)
            if not AAPaint.strokeRoundedRect(bb, cx, cy, size, size, radius, outline, color) then
                bb:paintBorder(cx, cy, size, size, outline, color)
            end
        end
    end

    return widget
end

-- Height of a share bar `bar_h` thick with labels `text_h` tall under it.
function Charts.shareHeight(bar_h, text_h)
    return bar_h + text_h + LABEL_GAP
end

-- Width of each segment of a share bar: `total_w` split in proportion to
-- `values`, a non-zero value never narrower than MIN_SEGMENT_W. Zero values get
-- no width. Returns nil when every value is zero.
local function segmentWidths(values, total_w)
    local sum, count = 0, 0
    for _, v in ipairs(values) do
        sum = sum + v
        if v > 0 then count = count + 1 end
    end
    if sum <= 0 then return nil end
    local usable = total_w - (count - 1) * SEGMENT_GAP
    local widths, used, last = {}, 0, nil
    for i, v in ipairs(values) do
        widths[i] = v > 0 and math.max(MIN_SEGMENT_W, math.floor(v / sum * usable)) or 0
        used = used + widths[i]
        if v > 0 then last = i end
    end
    -- The last segment takes what rounding left over.
    widths[last] = math.max(MIN_SEGMENT_W, widths[last] + usable - used)
    return widths
end

-- Share bar: one horizontal bar split into a segment per entry of `opts.values`,
-- each as wide as its share of the total. The segment at `opts.highlight` gets
-- full ink and the others a lighter one. `opts.labels` (one string per segment)
-- go under the segments wide enough to hold them.
-- opts: values, w (px), avail_h (px; the widget never exceeds it), bar_h (px, the
--       thickness wanted), color, highlight (optional index) and, for text:
--       labels, label_face, label_color.
-- Returns nil when every value is zero or avail_h cannot hold a legible bar.
function Charts.share(opts)
    local widths = segmentWidths(opts.values, opts.w)
    if not widths then return nil end
    local labels, label_h = nil, 0
    if opts.labels then
        local texts, _widest, tallest = buildTexts(opts.labels, opts.label_face, opts.label_color)
        labels, label_h = texts, tallest + LABEL_GAP
    end
    if opts.avail_h - label_h < MIN_BAR_H then
        freeLabels(labels)
        labels, label_h = nil, 0
    end
    local bar_h = math.min(opts.bar_h, opts.avail_h - label_h)
    if bar_h < MIN_BAR_H then
        freeLabels(labels)
        return nil
    end

    local color = opts.color
    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = opts.w, h = bar_h + label_h }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local sx = x
        for i, w in ipairs(widths) do
            if w > 0 then
                local alpha = (not opts.highlight or i == opts.highlight) and FULL_ALPHA or BAR_DIM_ALPHA
                paintBar(bb, sx, y, w, bar_h, color, alpha)
                local label = labels and labels[i]
                if label and label:getSize().w <= w + SEGMENT_GAP then
                    label:paintTo(bb, sx + math.floor((w - label:getSize().w) / 2), y + bar_h + LABEL_GAP)
                end
                sx = sx + w + SEGMENT_GAP
            end
        end
    end

    function widget:free()
        freeLabels(labels)
    end

    return widget
end

-- Odometer: a row of drums, each holding one digit of `opts.digits`. The drums
-- are filled with `opts.color` and their digits drawn in `opts.digit_color`; the
-- last one is only outlined, and with `opts.rolling` it is caught between its
-- digit and the next one. Drums are as wide as `opts.w` allows, up to
-- `opts.max_w`, and keep their proportions within `opts.avail_h`.
-- opts: digits (string), rolling (optional), w, avail_h, max_w (px), color,
--       digit_color (the colour that reads on `color`).
-- Returns nil when `opts.w` or `opts.avail_h` cannot hold legible drums.
function Charts.odometer(opts)
    local digits, count = opts.digits, #opts.digits
    local drum_w = math.min(opts.max_w, math.floor(opts.w / (count + (count - 1) * DRUM_GAP_RATIO)))
    local drum_h = math.min(opts.avail_h, math.floor(drum_w * DRUM_RATIO))
    drum_w = math.min(drum_w, math.floor(drum_h / DRUM_RATIO))
    if drum_w < MIN_DRUM_W then return nil end
    local gap = math.max(1, math.floor(drum_w * DRUM_GAP_RATIO))
    local border = math.max(1, math.floor(drum_w / 12))
    local face = SUIStyle.pxFace(SUIStyle.FACE_BOLD, drum_h * DRUM_DIGIT_PCT)
    local pitch = math.floor(drum_h * DRUM_PITCH_PCT)
    local roll = opts.rolling and math.floor(pitch * DRUM_ROLL_PCT) or 0

    local color, digit_color = opts.color, opts.digit_color
    local radius = math.floor(drum_w * DRUM_RADIUS_PCT)
    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = count * drum_w + (count - 1) * gap, h = drum_h }
    -- Digit text widgets, built when first drawn: light ones for the filled
    -- drums, outline ones for the last drum.
    local filled_texts, outline_texts = {}, {}

    function widget:getSize()
        return self.dimen
    end

    local function digitText(cache, digit, ink)
        local text = cache[digit]
        if not text then
            text = UI.makeColoredText{ text = tostring(digit), face = face, fgcolor = ink, padding = 0 }
            cache[digit] = text
        end
        return text
    end

    -- Paints `digit` centred in the drum at `view`, `shift` px below centre.
    local function paintDigit(view, text, shift)
        local size = text:getSize()
        text:paintTo(view, math.floor((view:getWidth() - size.w) / 2),
            math.floor((view:getHeight() - size.h) / 2) + shift)
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        for i = 1, count do
            local dx = x + (i - 1) * (drum_w + gap)
            local last = i == count
            if last then
                if not AAPaint.strokeRoundedRect(bb, dx, y, drum_w, drum_h, radius, border, color) then
                    bb:paintBorder(dx, y, drum_w, drum_h, border, color)
                end
            elseif not AAPaint.fillRoundedRect(bb, dx, y, drum_w, drum_h, radius, color, FULL_ALPHA) then
                AAPaint.fillRect(bb, dx, y, drum_w, drum_h, color, FULL_ALPHA)
            end
            -- The digit is clipped to the drum by painting it into a view of its inside.
            local view = bb:viewport(dx + border, y + border, drum_w - 2 * border, drum_h - 2 * border)
            local digit = tonumber(digits:sub(i, i))
            if last then
                paintDigit(view, digitText(outline_texts, digit, color), -roll)
                if roll > 0 then
                    paintDigit(view, digitText(outline_texts, (digit + 1) % 10, color), pitch - roll)
                end
            else
                paintDigit(view, digitText(filled_texts, digit, digit_color), 0)
            end
        end
    end

    function widget:free()
        for _, cache in ipairs{ filled_texts, outline_texts } do
            for _, text in pairs(cache) do text:free() end
        end
        filled_texts, outline_texts = {}, {}
    end

    return widget
end

return Charts
