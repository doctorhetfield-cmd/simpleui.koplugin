-- sui_section_label.lua — Simple UI
-- Single owner of a module's section label (the title row above a module):
--   • descriptor — what the label shows: text, right-aligned text, page state
--   • PageState  — per-module pagination state stored in the screen ctx
--   • rendering  — label widget construction and a per-screen widget cache
--   • height     — vertical space the label reserves
--
-- Descriptor: { text, right_text, page, npages }. A module supplies it through
-- an optional M.getLabel(ctx); without one it is derived from M.label and
-- M.label_right_func (see M.describe). A nil descriptor means "no label"
-- (the module declares none, or the user hid it).
--
-- Widgets reference nothing but the descriptor and the callbacks handed to
-- M.get, so a cache owned by one screen instance never outlives the callbacks
-- it holds.

local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Screen          = require("device").screen

local Bottombar = require("screens/sui_bottombar")
local Config    = require("infra/sui_config")
local SUIStyle  = require("features/sui_style")
local UI        = require("infra/sui_core")

local PAD = UI.PAD

local M = {}

-- ---------------------------------------------------------------------------
-- Pagination state
-- ---------------------------------------------------------------------------

-- Page and page count per module id, stored in the screen ctx so it lives as
-- long as that ctx does. A module that was never paged reads as 1 of 1.
local PageState = {}
M.PageState = PageState

local function pageEntry(ctx, id)
    local pages = ctx._pages
    if not pages then
        pages = {}
        ctx._pages = pages
    end
    local entry = pages[id]
    if not entry then
        entry = { page = 1, npages = 1 }
        pages[id] = entry
    end
    return entry
end

-- Returns page, npages.
function PageState.get(ctx, id)
    local entry = ctx and ctx._pages and ctx._pages[id]
    if not entry then return 1, 1 end
    return entry.page, entry.npages
end

function PageState.setPage(ctx, id, page)
    pageEntry(ctx, id).page = page
end

function PageState.setCount(ctx, id, npages)
    pageEntry(ctx, id).npages = npages
end

-- ---------------------------------------------------------------------------
-- Descriptor
-- ---------------------------------------------------------------------------

-- Builds the descriptor for module `id`. Returns nil when `text` is nil or
-- the user hid the label. `right_text` defaults to the "page/npages"
-- indicator when the module has more than one page.
function M.makeDescriptor(id, text, ctx, right_text)
    if not text or Config.isLabelHidden(id) then return nil end
    local page, npages = PageState.get(ctx, id)
    if not right_text and npages > 1 then
        right_text = string.format("%d/%d", page, npages)
    end
    return { text = text, right_text = right_text, page = page, npages = npages }
end

-- Descriptor for `mod`: its own getLabel(ctx) when defined, otherwise derived
-- from the declared M.label and optional M.label_right_func(ctx).
function M.describe(mod, ctx)
    if type(mod.getLabel) == "function" then return mod.getLabel(ctx) end
    local right_text = type(mod.label_right_func) == "function" and mod.label_right_func(ctx) or nil
    return M.makeDescriptor(mod.id, mod.label, ctx, right_text)
end

-- ---------------------------------------------------------------------------
-- Height
-- ---------------------------------------------------------------------------

-- Vertical space reserved for the label of module `id`: 0 when hidden.
function M.height(id, landscape_factor)
    if Config.isLabelHidden(id) then return 0 end
    return Config.getScaledLabelH(landscape_factor)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Icon size for the page-nav chevrons (base pixels, scaled at use time).
local NAV_ICON_SIZE = 16

-- Chevron pair flanking the page indicator. Each button is padded
-- vertically up to a finger-sized tap zone without growing the row height,
-- and the one at the page boundary is dimmed and disabled. With
-- `has_wallpaper` the icons are alpha-blended at construction time and the
-- button frame paints transparently over the wallpaper.
-- turn_page(delta) is called on tap.
local function buildPageNavButtons(page, npages, row_h, turn_page, has_wallpaper)
    local icon_size = Screen:scaleBySize(NAV_ICON_SIZE)
    local v_pad = math.max(0, math.floor((row_h - icon_size) / 2))
    local function make(icon, enabled, delta)
        local btn = Button:new{
            icon            = icon,
            icon_width      = icon_size,
            icon_height     = icon_size,
            bordersize      = 0,
            margin          = 0,
            padding_top     = v_pad,
            padding_bottom  = v_pad,
            padding_left    = 0,
            padding_right   = 0,
            enabled         = enabled,
            callback        = function() turn_page(delta) end,
        }
        Bottombar.patchDimmedIcon(btn)
        if has_wallpaper then Bottombar.patchWallpaperIcon(btn) end
        return btn
    end
    local function makePair()
        return make("chevron.left", page > 1, -1), make("chevron.right", page < npages, 1)
    end
    if not has_wallpaper then return makePair() end
    local prev_btn, next_btn
    Bottombar.withWallpaperAlphaIcons(function()
        prev_btn, next_btn = makePair()
    end)
    return prev_btn, next_btn
end

-- Title row with the right-aligned text and, when `turn_page` is given,
-- chevrons on both sides of it. All three share one row height so they
-- centre on a single line.
local function buildTitleRow(desc, avail_w, face, scale, turn_page, has_wallpaper)
    local face_right = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, math.floor(SUIStyle.FS_DETAIL * scale)))
    local right_widget = UI.makeColoredText{ text = desc.right_text, face = face_right, bold = false }
    local title_widget = UI.makeColoredText{ text = desc.text, face = face, bold = true }
    local right_w = right_widget:getSize().w
    local row_h   = math.max(title_widget:getSize().h, right_widget:getSize().h)
    local gap     = PAD

    local prev_button, next_button
    local nav_w = 0
    if turn_page then
        prev_button, next_button = buildPageNavButtons(desc.page, desc.npages, row_h, turn_page, has_wallpaper)
        nav_w = prev_button:getSize().w + next_button:getSize().w + gap * 2
    end

    -- The title gets a real-width slot so the right text stays at the row's
    -- right edge (a TextWidget only reports its glyph width).
    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = LeftContainer:new{
        dimen = Geom:new{ w = math.max(1, avail_w - right_w - nav_w - gap), h = row_h },
        title_widget,
    }
    row[#row + 1] = HorizontalSpan:new{ width = gap }
    if prev_button then
        row[#row + 1] = prev_button
        row[#row + 1] = HorizontalSpan:new{ width = gap }
    end
    row[#row + 1] = CenterContainer:new{
        dimen = Geom:new{ w = right_w, h = row_h },
        right_widget,
    }
    if next_button then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = next_button
    end
    return row
end

local function buildWidget(desc, w, scale, turn_page, has_wallpaper)
    local face    = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, math.floor(SUIStyle.FS_BODY * scale)))
    local avail_w = w - PAD * 2
    local content
    if desc.right_text then
        content = buildTitleRow(desc, avail_w, face, scale,
            desc.npages > 1 and turn_page or nil, has_wallpaper)
    else
        content = UI.makeColoredText{ text = desc.text, face = face, bold = true, width = avail_w }
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        padding_left = PAD, padding_right = PAD,
        padding_bottom = UI.LABEL_PAD_BOT,
        content,
    }
end

-- Returns the label widget for module `id`, reusing the one in `cache` while
-- everything it shows is unchanged (same widget identity = nothing to
-- repaint). `cache` is a table owned by one screen instance.
--   desc             descriptor (see M.describe)
--   w                column width the label spans
--   landscape_factor label scale multiplier (default 1)
--   has_wallpaper    chevrons paint transparently over the wallpaper
--   turn_page        function(id, delta) invoked by the chevrons
function M.get(cache, id, desc, w, landscape_factor, has_wallpaper, turn_page)
    local scale  = Config.getLabelScale() * (landscape_factor or 1)
    local paged  = desc.right_text ~= nil and desc.npages > 1
    local key = table.concat({
        desc.text, w, scale, desc.right_text or "",
        paged and desc.page or 0, paged and desc.npages or 0,
        paged and tostring(has_wallpaper) or "",
    }, "|")

    local entry = cache[id]
    if entry and entry.key == key then return entry.widget end

    local nav = paged and turn_page and function(delta) turn_page(id, delta) end or nil
    local widget = buildWidget(desc, w, scale, nav, has_wallpaper)
    cache[id] = { key = key, widget = widget }
    return widget
end

return M
