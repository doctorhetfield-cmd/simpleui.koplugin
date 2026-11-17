-- sui_folder_fan.lua — Simple UI
-- Fan of member covers on a folder row of the list with covers.
--
-- Public API:
--   FolderFan.MAX, FolderFan.STEP, FolderFan.ART_SHARE -- cards in a fan, card offset (fraction of a card), max row share
--   FolderFan.getMode() / setMode(v)       -- "fan" (default) or "single"
--   FolderFan.geometry(row_w, row_h, o)    -- card size and offsets, or nil when the row is too short
--   FolderFan.width(g, n)                  -- width of a fan of n cards
--   FolderFan.build(cards, g)              -- the fan widget; cards[1] is the front card

local M = {}

M.MAX       = 4
M.STEP      = 0.28
M.ART_SHARE = 0.5

local MODE_KEY = "simpleui_fc_list_folder_covers"

function M.getMode()
    return require("infra/sui_config").readChoice(MODE_KEY, { "fan", "single" }, "fan")
end

-- The default mode is not stored.
function M.setMode(v)
    local SUISettings = require("infra/sui_store")
    if v == "fan" then
        SUISettings:delSetting(MODE_KEY)
    else
        SUISettings:saveSetting(MODE_KEY, v)
    end
end

-- Card geometry for a row of row_w × row_h. `o`: margin (above and below the
-- fan), shadow (px a card gives up on its right and bottom), border, min_h
-- (smallest card height), uniform (covers fill a 2:3 card). The card is the same for any number of covers; the
-- fan of MAX cards takes at most ART_SHARE of the row. Nil below min_h.
function M.geometry(row_w, row_h, o)
    local box_h  = row_h - 2 * o.margin
    local card_h = box_h - o.shadow
    local card_w = math.floor(card_h / 1.5)
    local span   = 1 + (M.MAX - 1) * M.STEP
    local budget = math.floor(row_w * M.ART_SHARE)
    if card_w * span + o.shadow > budget then
        card_w = math.floor((budget - o.shadow) / span)
        card_h = math.floor(card_w * 1.5)
    end
    if card_h < o.min_h then return nil end
    return {
        card_w = card_w,
        card_h = card_h,
        step   = math.max(1, 2 * o.shadow, math.floor(card_w * M.STEP)),
        shadow = o.shadow,
        border = o.border,
        uniform = o.uniform,
        top    = o.margin + math.floor((box_h - o.shadow - card_h) / 2),
    }
end

function M.width(g, n)
    n = math.max(1, math.min(n, M.MAX))
    return g.card_w + (n - 1) * g.step + g.shadow
end

-- Framed card of one cover: `card.bb` (cover buffer of card.w × card.h;
-- `card.shared` marks one that belongs to BookInfoManager and must outlive the
-- widget) or the generated cover for `card.title`.
local function _card(card, g)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local max_w, max_h = g.card_w - 2 * g.border, g.card_h - 2 * g.border
    local inner, inner_w, inner_h
    if card.bb then
        inner = require("features/library/sui_cover_widgets").fitCover(
            card.bb, card.w, card.h, max_w, max_h, g.uniform, not card.shared)
        local size = inner:getSize()
        inner_w, inner_h = size.w, size.h
    else
        local Placeholder = require("engines/sui_cover_placeholder")
        inner_w, inner_h = Placeholder.fitSize(max_w, max_h)
        inner = Placeholder.build(inner_w, inner_h, card.title)
    end
    return FrameContainer:new{
        width      = inner_w + 2 * g.border,
        height     = inner_h + 2 * g.border,
        margin     = 0,
        padding    = 0,
        bordersize = g.border,
        inner,
    }
end

-- Outline of the cards together, as columns (see engines/sui_cover_shadow):
-- every card stands on the fan's bottom edge.
local function _outline(frames, g)
    local w = 0
    for _i, f in ipairs(frames) do w = math.max(w, f.x + f.w) end
    local tops, heights, key = {}, {}, { "fan" }
    for x = 1, w do tops[x], heights[x] = g.card_h, 0 end
    for _i, f in ipairs(frames) do
        local top = g.card_h - f.h
        for x = f.x + 1, f.x + f.w do
            if top < tops[x] then tops[x], heights[x] = top, f.h end
        end
        key[#key + 1] = f.x .. "," .. f.w .. "," .. f.h
    end
    return { key = table.concat(key, "|"), w = w, tops = tops, heights = heights }
end

-- Cards from the back to the front, each a step to the right of the one in
-- front, over one shadow cast by the whole fan.
function M.build(cards, g)
    local Geom         = require("ui/geometry")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local Shadow       = require("engines/sui_cover_shadow")
    local n = math.min(#cards, M.MAX)
    local frames = {}
    for i = 1, n do
        local frame = _card(cards[i], g)
        local size = frame:getSize()
        frames[i] = { widget = frame, x = (i - 1) * g.step, w = size.w, h = size.h }
    end
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = M.width(g, n), h = g.card_h + g.shadow },
        allow_mirroring = false,
    }
    local outline = _outline(frames, g)
    local shadow = Shadow.buildWidget(outline.w, g.card_h, g.shadow, outline)
    if shadow then
        shadow.overlap_offset = { 0, 0 }
        group[1] = shadow
    end
    for i = n, 1, -1 do
        local f = frames[i]
        f.widget.overlap_offset = { f.x, g.card_h - f.h }
        group[#group + 1] = f.widget
    end
    return group
end

return M
