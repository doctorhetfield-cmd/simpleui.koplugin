-- module_coverdeck.lua
-- Displays recent or TBR books as a cover carousel.
--
-- The covers beside the centre one are laid out by a carousel style (see
-- CAROUSEL_STYLES): "classic" shows the outer slice of each neighbouring
-- cover, "flow" shows each whole cover tilted in perspective.

local Blitbuffer       = require("ffi/blitbuffer")
local BD               = require("ui/bidi")
local Device           = require("device")
local util             = require("util")
local Font             = require("ui/font")
local CenterContainer  = require("ui/widget/container/centercontainer")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local InputContainer   = require("ui/widget/container/inputcontainer")
local OverlapGroup     = require("ui/widget/overlapgroup")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local CoverPlaceholder = require("engines/sui_cover_placeholder")
local CoverShadow      = require("engines/sui_cover_shadow")
local CoverWarp        = require("engines/sui_cover_warp")
local CoverWidgets     = require("features/library/sui_cover_widgets")
local Screen           = Device.screen
local _ = require("infra/sui_i18n").translate
local logger         = require("logger")

local Config       = require("infra/sui_config")
local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local BookStats    = require("infra/sui_book_stats")
local Text         = require("infra/sui_text")
local LRU          = require("infra/sui_lru")
local Memory       = require("infra/sui_memory")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local Chrome       = require("features/sui_module_chrome")

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local MAX_RECENT_FPS   = 10
local TILT_CACHE_MAX   = 16   -- max tilted covers kept: visible slots plus those of both neighbours
local WARMUP_DELAY     = 0.3  -- s from a build to the first warm-up step, once its repaint is under way
local WARMUP_TICK      = 0.05 -- s between warm-up steps, leaving the event loop free for input
local SWIPE_DELTAS     = { 1, -1 }  -- carousel steps a swipe can take, likeliest first
local COVER_ASPECT     = 3 / 2  -- cover height over width, shared by every cover consumer

-- ---------------------------------------------------------------------------
-- Base carousel size, expressed as a percentage of inner_w rather than a
-- fixed pixel size: 100% = fitted to a reference full-width single column,
-- so narrower columns (multi-column Custom Screens, landscape spread)
-- scale down proportionally.
-- ---------------------------------------------------------------------------
local _REF_INNER_W   = UI.getInnerW() - PAD * 2
local _CENTER_W_PCT  = Screen:scaleBySize(168) / _REF_INNER_W
local _CENTER_W_MIN  = Screen:scaleBySize(60)  -- floor so covers never collapse to unreadable size

-- ---------------------------------------------------------------------------
-- Carousel label truncation
-- ---------------------------------------------------------------------------
-- Title/author text is constrained to covers_block_w (full carousel
-- footprint including side peeks). Stats use a separate budget (95% of
-- the module page width) so the line can run wider than the covers.
-- build() reruns on every carousel swipe (see
-- ScreenWidget:_refreshBookModSlot), so this truncates by an estimated
-- character budget rather than TextWidget's max_width +
-- truncate_with_ellipsis, which remeasures glyph-by-glyph against the
-- font on every call.
local _AVG_CHAR_WIDTH_RATIO = 0.55  -- rough glyph-advance-to-font-size ratio

local function truncateToWidth(s, face, max_px)
    return Text.truncate(s, math.floor(max_px / (face.size * _AVG_CHAR_WIDTH_RATIO)))
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_SOURCE        = "coverdeck_source"          -- pfx .. this; "recent"|"tbr"
local SETTING_STYLE         = "coverdeck_style"           -- pfx .. this; "classic"|"flow"
local SETTING_SHOW_FINISHED = "coverdeck_show_finished"   -- pfx .. this; default OFF
local STATS_ORDER_KEY       = "coverdeck_stats_order"     -- pfx .. this
local MAIN_ORDER_KEY        = "coverdeck_main_order"      -- pfx .. this

-- Progress badge (pentagon overlay on the centre cover, same drawing
-- primitive as the book-grid modules' progress badge) — off by default,
-- unlike the coverdeck_show_* elements above. Color follows the same
-- "Follow Style / Dark / Light" 3-way choice as the book-grid modules'
-- own per-badge color override (see engines/sui_book_grid.lua's
-- GridRenderer.getBadgeColorOverride) — nil means "Follow Style". Named
-- "Progress Badge" throughout, matching the book-grid/Library terminology
-- for the same badge_key ("progress").
local SETTING_SHOW_PROGRESS_BADGE  = "coverdeck_show_progress_badge"   -- pfx .. this; default OFF
local SETTING_PROGRESS_BADGE_COLOR = "coverdeck_progress_badge_color"  -- pfx .. this; nil|"dark"|"light"|"accent"|"secondary"
-- When progress badge is on: also paint it on right-hand peeks (true) or
-- only on the centre cover (nil/false). Default off, same opt-in
-- convention as SETTING_SHOW_PROGRESS_BADGE.
local SETTING_PROGRESS_BADGE_ON_PEEKS = "coverdeck_progress_badge_on_peeks"

-- Source values of the form COLLECTION_PREFIX .. collection_name select a
-- user collection as the book source.
local COLLECTION_PREFIX = "collection:"

-- Collection name encoded in `source`, or nil when it is not a collection source.
local function collectionNameOf(source)
    if source:sub(1, #COLLECTION_PREFIX) == COLLECTION_PREFIX then
        return source:sub(#COLLECTION_PREFIX + 1)
    end
end

-- Statistics of the stats line, in default order.
local STAT_IDS = { "percent", "book_days", "book_time", "book_remaining" }

-- Top-level items, in default order. "covers" is the carousel itself: a fixed
-- anchor that can be moved but never hidden.
local MAIN_IDS     = { "covers", "title", "author", "progress", "stats" }
local MAIN_ANCHORS = { covers = true }

local function mainLabel(id)
    if id == "covers"   then return _("Covers") end
    if id == "title"    then return _("Title") end
    if id == "author"   then return _("Author") end
    if id == "progress" then return _("Progress bar") end
    return _("Statistics")
end

-- ---------------------------------------------------------------------------
-- Carousel styles
-- ---------------------------------------------------------------------------
-- A style is pure data describing the covers beside the centre one.
-- levels[d] is the pair of covers d steps away from the centre. Sizes are
-- fractions of the centre cover; `offset` is the distance from the centre
-- cover's edge to the outer edge of the slot.
--   kind       "crop": the outer slice of each cover.
--              "tilt": the whole cover in perspective; `tilt` is the ratio of
--              its inner edge height to its outer edge height.
local DEFAULT_STYLE = "flow"
local STYLE_ORDER   = { "classic", "flow" }
local CAROUSEL_STYLES = {
    classic = {
        kind      = "crop",
        levels    = {
            { w = 0.45, h = 0.85, offset = 0.35 },
            { w = 0.35, h = 0.75, offset = 0.60 },
        },
    },
    flow = {
        kind      = "tilt",
        tilt      = 0.75,
        -- Both levels share the same size so a single warped buffer per
        -- (book, side) hits the tilt cache across swipes; depth is conveyed
        -- only by offset.
        levels    = {
            { w = 0.55, h = 0.92, offset = 0.30 },
            { w = 0.55, h = 0.92, offset = 0.60 },
        },
    },
}
local SIDES = { "left", "right" }

-- ---------------------------------------------------------------------------
-- Settings accessors
-- ---------------------------------------------------------------------------

local function getSource(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SOURCE) or "recent"
end

-- bundle (ctx.cfg.coverdeck), when given, supplies the style from the
-- pre-read settings snapshot; otherwise it is read live.
local function getStyleId(pfx, bundle)
    local stored = bundle and bundle.style
    if not bundle then stored = SUISettings:readSetting(pfx .. SETTING_STYLE) end
    return Config.resolveChoice(stored, STYLE_ORDER, DEFAULT_STYLE)
end

local function getStyle(pfx, bundle)
    return CAROUSEL_STYLES[getStyleId(pfx, bundle)]
end

local function showFinished(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_FINISHED) == true
end

-- Same "unset == off" convention as showFinished above — the progress
-- badge is opt-in, unlike the coverdeck_show_* elements below (which
-- default on).
local function showProgressBadge(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE) == true
end

-- Right-hand peeks also show the progress badge (default off). Only
-- meaningful when showProgressBadge is on.
local function showProgressBadgeOnPeeks(pfx)
    return SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_ON_PEEKS) == true
end

-- nil ("Follow Style") / "dark" / "light" / "accent" / "secondary" — mirrors
-- GridRenderer.getBadgeColorOverride/setBadgeColor's shape, scoped by pfx
-- only since coverdeck is a single-instance module (no per-instance id).
local function getProgressBadgeColorOverride(pfx)
    return SUIStyle.badgeChoice(SUISettings:readSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR))
end
local function setProgressBadgeColor(pfx, v)
    SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_COLOR, SUIStyle.badgeChoice(v)) -- nil = clear override, follow Library
end

-- Every coverdeck_show_* key defaults to ON (an unset key reads as true),
-- except SETTING_SHOW_FINISHED above, which is read with `== true` so an
-- unset key defaults to OFF instead.
local function _showElem(pfx, key)
    return SUISettings:nilOrTrue(pfx .. "coverdeck_show_" .. key)
end

-- Items show/hide/reorder: rebuild every known screen from fresh settings.
local function _invalidateCfgCache(_pfx)
    local ok, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if ok and ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
        ScreenEngine.invalidateAllCfgAndRefresh()
    end
end

local function _setElemVisible(pfx, key, visible)
    SUISettings:saveSetting(pfx .. "coverdeck_show_" .. key, visible)
end

-- bundle (ctx.cfg.coverdeck), when given, supplies the saved orders from the
-- pre-read settings snapshot instead of a fresh SUISettings read.
local function _getStatsOrder(pfx, bundle)
    local saved = bundle and bundle.elem_order
    if not bundle then saved = SUISettings:readSetting(pfx .. STATS_ORDER_KEY) end
    return Config.mergeOrder(saved, STAT_IDS)
end

local function _getMainOrder(pfx, bundle)
    local saved = bundle and bundle.main_order
    if not bundle then saved = SUISettings:readSetting(pfx .. MAIN_ORDER_KEY) end
    return Config.mergeOrder(saved, MAIN_IDS)
end

-- Resolves a single element's visibility from the pre-read bundle when
-- given, falling back to a live settings read otherwise.
local function _showElemFrom(bundle, pfx, key)
    if bundle and bundle.show and bundle.show[key] ~= nil then
        return bundle.show[key]
    end
    return _showElem(pfx, key)
end

-- ---------------------------------------------------------------------------
-- getVisibleElements — single source of truth for what is visible.
-- Returns a plain table consumed by build() and getHeight() so that any
-- visibility change only needs to be made in one place. bundle is optional
-- (ctx.cfg.coverdeck); when omitted, everything is read live from settings.
-- ---------------------------------------------------------------------------
local function getVisibleElements(pfx, bundle)
    local stats_order = _getStatsOrder(pfx, bundle)
    local has_stat     = false
    for _i, key in ipairs(stats_order) do
        if _showElemFrom(bundle, pfx, key) then has_stat = true; break end
    end
    return {
        main_order  = _getMainOrder(pfx, bundle),
        show_title  = _showElemFrom(bundle, pfx, "title"),
        show_author = _showElemFrom(bundle, pfx, "author"),
        progress    = _showElemFrom(bundle, pfx, "progress"),
        show_stats  = _showElemFrom(bundle, pfx, "stats"),
        has_stat    = has_stat,
        stats_order = stats_order,
    }
end

-- ---------------------------------------------------------------------------
-- Shared module (lazy-loaded)
-- ---------------------------------------------------------------------------

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then
            _SH = m
        else
            logger.warn("coverdeck: cannot load module_books_shared: " .. tostring(m))
        end
    end
    return _SH
end

-- ---------------------------------------------------------------------------
-- Progress badge (pentagon) — delegated to the shared helper so the
-- drawing primitive matches every other progress badge in the app. Color
-- and size come from the module's own settings.
-- ---------------------------------------------------------------------------

-- Size and colour of a slot's progress badge, from the module's settings and
-- the centre cover size that keeps the badge uniform on narrower covers.
local function progressBadgeOpts(slot, pfx)
    return {
        color     = getProgressBadgeColorOverride(pfx),
        ref_w     = slot.ref_w,
        ref_h     = slot.ref_h,
        scale_pct = Config.getBadgeScalePct("coverdeck", pfx),
    }
end

-- Badge laid as a widget over a flat cover. Side covers are laid out in
-- logical coordinates, so their badge keeps its position in RTL layouts.
local function applyProgressBadge(cover_widget, bd, slot, pfx)
    local SH = getSH()
    if not SH or not SH.applyProgressBadge then return cover_widget end
    local opts = progressBadgeOpts(slot, pfx)
    opts.allow_mirroring = slot.align == nil
    return SH.applyProgressBadge(cover_widget, bd, slot.w, slot.h, opts)
end

local fetchBookStats = BookStats.fetch

-- Resolves a book's partial_md5_checksum: prefers the prefetched entry,
-- falling back to opening its docsettings sidecar.
local function _resolveMd5(fp, prefetched_entry)
    local md5 = prefetched_entry and prefetched_entry.partial_md5_checksum
    if md5 then return md5 end
    local DS = require("docsettings")
    local ok_ds, ds = pcall(DS.open, DS, fp)
    if ok_ds and ds then
        md5 = ds:readSetting("partial_md5_checksum")
        pcall(function() ds:close() end)
    end
    return md5
end

-- ---------------------------------------------------------------------------
-- Carousel geometry helpers
-- ---------------------------------------------------------------------------

local function carouselIdx(curIdx, offset, count)
    return (curIdx + offset - 1 + count * 2) % count + 1
end

local function yTopOf(centerY, h)
    return math.floor(centerY - h / 2)
end

-- Width of the centre cover in a module `inner_w` wide; `cs` is the raw
-- module scale times the cover scale. Shared by build() and getHeight().
local function centerWidth(inner_w, cs)
    return math.max(_CENTER_W_MIN, math.floor(inner_w * _CENTER_W_PCT * cs))
end

-- Distance from the centre cover's edge to the outer edge of a level's slot.
local function levelOffset(level, center_w)
    return math.floor(center_w * level.offset)
end

-- Whether the side cover `depth` steps away on `side` shows a book that no
-- other visible cover shows. With two books the other one sits on the left.
local function hasPeek(count, depth, side)
    if depth == 1 and side == "left" then return count >= 2 end
    return count >= 2 * depth + 1
end

-- Slots of `style` for a carousel of `count` books, farthest first and the
-- centre cover last, so painting them in order stacks nearer covers on top.
-- g: { center_w, center_h, centerX, centerY }.
-- Every slot has its position in the carousel (rel: steps from the centre),
-- its box (x, y, w, h) and its kind. Side slots add the side they hang on
-- (align) and the style's tilt, plus the width of the flat cover the warp
-- narrows to the slot; right-hand ones also carry the centre cover size, which
-- scales their progress badge.
local function layoutSlots(style, count, g)
    local half_cw = math.floor(g.center_w / 2)
    local slots = {}
    for depth = #style.levels, 1, -1 do
        local level  = style.levels[depth]
        local w      = math.floor(g.center_w * level.w)
        local h      = math.floor(g.center_h * level.h)
        local offset = levelOffset(level, g.center_w)
        for _i, side in ipairs(SIDES) do
            if hasPeek(count, depth, side) then
                local left = side == "left"
                slots[#slots + 1] = {
                    rel   = left and -depth or depth,
                    kind  = style.kind,
                    align = side,
                    tilt  = style.tilt,
                    flat_w = style.kind == "tilt" and math.ceil(h / COVER_ASPECT) or nil,
                    x     = left and (g.centerX - half_cw - offset)
                                  or (g.centerX + half_cw + offset - w),
                    y     = yTopOf(g.centerY, h),
                    w     = w,
                    h     = h,
                    ref_w = (not left) and g.center_w or nil,
                    ref_h = (not left) and g.center_h or nil,
                }
            end
        end
    end
    slots[#slots + 1] = {
        rel  = 0,
        kind = "center",
        x    = g.centerX - half_cw,
        y    = yTopOf(g.centerY, g.center_h),
        w    = g.center_w,
        h    = g.center_h,
    }
    return slots
end

-- Points every slot at the book it shows when the book `cur` of `fps` is in
-- the centre.
local function assignBooks(slots, fps, cur)
    local count = #fps
    for _i, slot in ipairs(slots) do
        slot.fp = fps[carouselIdx(cur, slot.rel, count)]
    end
end

-- ---------------------------------------------------------------------------
-- Tilted covers
-- ---------------------------------------------------------------------------
-- Perspective warp lives in engines/sui_cover_warp. This section owns the
-- widget, the LRU of warped buffers, and the glue to the cover cache.

-- Widget painting a warped cover. The buffer is shared between the tilt cache
-- and the widgets showing it: whichever lets go last releases it. allow_mirroring
-- is off so OverlapGroup does not flip the trapezoid orientation in RTL — side
-- and align are resolved by the module in logical coordinates.
local TiltedCover = {
    allow_mirroring = false,
}
TiltedCover.__index = TiltedCover

function TiltedCover:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function TiltedCover:paintTo(bb, x, y)
    local entry = self.entry
    local tops, heights = entry.tops, entry.heights
    -- Night mode inverts the screen, so the cover is inverted back to its own colors.
    local blit = Screen.night_mode and "invertblitFrom" or "blitFrom"
    local col = 0
    while col < self.w do
        local top = tops[col + 1]
        local col_h = heights[col + 1]
        if not col_h or col_h <= 0 then
            col = col + 1
        else
            -- Merge consecutive columns that share the same vertical span
            -- into a single blitFrom to cut FFI call volume.
            local run = 1
            while col + run < self.w
                    and tops[col + run + 1] == top
                    and heights[col + run + 1] == col_h do
                run = run + 1
            end
            bb[blit](bb, entry.bb, x + col, y + top, col, top, run, col_h)
            col = col + run
        end
    end
end

function TiltedCover:handleEvent()
    return false
end

-- Warped covers keyed by book, side and size, bounded by count and bytes.
-- Evicted or replaced entries are only dereferenced: a widget on screen may
-- still be painting one, and its buffer is reclaimed by the Blitbuffer
-- finalizer once the last widget drops it. An entry made from a cover bitmap
-- records the cover's revision and is rebuilt once another cover replaces it;
-- enlarging the same cover keeps it.
local _tilt_cache = LRU.new{ max_entries = TILT_CACHE_MAX, max_bytes = Memory.budgets().tilt }

-- Warped entry of `slot` stored under `key`. `source` is a cover-cache bitmap
-- (must not be freed here) and `revision` identifies the cover it holds. When
-- `source` is nil, `render` returns a newly allocated bitmap that this
-- function frees after warping.
local function tiltEntry(slot, key, source, revision, render)
    local entry = _tilt_cache:get(key)
    if entry and entry.revision == revision then return entry end

    local w, h = math.floor(slot.w), math.floor(slot.h)
    if w < 2 or h < 2 then return nil end
    local flat_w = slot.flat_w

    local src = source
    local own_src = false
    if not src then
        if not render then return nil end
        src = render()
        if not src then return nil end
        own_src = true
    end

    -- Private buffer so the cover cache can replace the original without
    -- invalidating the warp. stretchBBToSize copies before scaling. The cover
    -- stays in its flat shape; the warp narrows it to the slot.
    local ok_sc, working = pcall(Config.stretchBBToSize, src, flat_w, h)
    if own_src then
        pcall(src.free, src)
        src = nil
    end
    if not (ok_sc and working) then return nil end

    -- Guard against stretch returning a shared buffer unchanged.
    local owned = working
    if source and working == source then
        local ok_cp, clone = pcall(Blitbuffer.new, working:getWidth(), working:getHeight(), working:getType())
        if not (ok_cp and clone) then return nil end
        pcall(clone.blitFrom, clone, working, 0, 0, 0, 0, working:getWidth(), working:getHeight())
        owned = clone
    end

    -- Reject size mismatches from a failed stretch path that returned the
    -- original raw buffer at a different size.
    if owned:getWidth() ~= flat_w or owned:getHeight() ~= h then
        if owned ~= source then pcall(owned.free, owned) end
        return nil
    end

    -- The badge is part of the flat cover, so the warp squeezes and tilts it
    -- along with the artwork.
    local badge = slot.badge
    if badge then CoverWidgets.drawProgressBadge(owned, badge.x, badge.y, badge.desc) end

    local ok, warped = pcall(CoverWarp.warp, owned, w, h, slot.tilt, slot.align == "left")
    if owned ~= source then pcall(owned.free, owned) end

    if not (ok and warped) then
        logger.warn("coverdeck: tilted cover unavailable: " .. tostring(warped))
        return nil
    end

    -- The inverted blit of night mode only accepts buffers of the screen's type.
    local screen_type = Screen.bb and Screen.bb:getType()
    if screen_type and warped.bb:getType() ~= screen_type then
        local ok_nt, native = pcall(Blitbuffer.new, w, h, screen_type)
        if not (ok_nt and native) then
            pcall(warped.bb.free, warped.bb)
            return nil
        end
        native:blitFrom(warped.bb, 0, 0, 0, 0, w, h)
        pcall(warped.bb.free, warped.bb)
        warped.bb = native
    end

    warped.revision = revision
    _tilt_cache:put(key, warped, Memory.bbBytes(warped.bb))
    return warped
end

-- Cache key is independent of carousel depth: both flow levels share size, so
-- a book keeps the same warped buffer as it moves between levels on swipe. It
-- includes the badge, which is drawn into the buffer.
local function tiltedKey(slot, variant)
    return table.concat({ slot.fp, variant, slot.w, slot.h, slot.align, slot.tilt,
        slot.badge and slot.badge.key or "" }, "|")
end

local function newTiltedCover(slot, entry)
    return setmetatable({ w = slot.w, h = slot.h, entry = entry }, TiltedCover)
end

-- Tilted cover of the slot's book; nil while its image is not available yet.
-- The source is the whole cover in the shared 3:2 shape, as tall as the slot,
-- which the cover store serves from the bitmap of the centre cover; the warp
-- narrows it to the slot width.
local function tiltedCover(slot)
    local w, h = math.floor(slot.w), math.floor(slot.h)
    if w < 2 or h < 2 then return nil end
    local src = Config.getStretchedCoverBB(slot.fp, slot.flat_w, h)
    if not src then return nil end
    local entry = tiltEntry(slot, tiltedKey(slot, "cover"), src, Config.getCoverRevision(slot.fp))
    return entry and newTiltedCover(slot, entry)
end

-- Tilted generated cover for a book without an image; nil when it cannot be built.
local function tiltedPlaceholder(slot, bd)
    local w, h = math.floor(slot.w), math.floor(slot.h)
    if w < 2 or h < 2 then return nil end
    local entry = tiltEntry(slot, tiltedKey(slot, "generated"), nil, nil, function()
        return CoverPlaceholder.render(slot.flat_w, h, bd.title, bd.authors)
    end)
    return entry and newTiltedCover(slot, entry)
end

-- ---------------------------------------------------------------------------
-- Slot covers
-- ---------------------------------------------------------------------------

-- Cover widget of a slot's book; nil while its image is not available yet.
local function loadSlotCover(SH, slot)
    if slot.kind == "tilt" then return tiltedCover(slot) end
    if slot.kind == "crop" then
        return SH.getCroppedBookCover(slot.fp, slot.w, slot.h, slot.align, true)
    end
    return SH.getBookCover(slot.fp, slot.w, slot.h, true)
end

-- Generated cover standing in until the slot's image is available.
local function placeholderCover(SH, slot, bd)
    local cover = slot.kind == "tilt" and tiltedPlaceholder(slot, bd)
    if cover then return cover end
    return SH.coverPlaceholder(bd.title, bd.authors, slot.w, slot.h, true,
        slot.kind ~= "center" and slot.align or nil)
end

-- Shadow of a slot's cover, placed at the slot; nil while shadows are off.
-- A tilted slot casts the shadow of its trapezoid, which depends on the slot
-- geometry alone, so it stays right while the cover or its placeholder loads.
local function slotShadow(SH, slot)
    local profile = slot.kind == "tilt"
        and CoverWarp.profile(slot.w, slot.h, slot.tilt, slot.align == "left", slot.flat_w)
    if not profile then return SH.buildOverlapShadow(slot.x, slot.y, slot.w, slot.h) end
    local shadow = CoverShadow.buildWidget(profile.w, profile.h,
        SUIStyle.coverShadowOffset(SUIStyle.SHADOW_MODULES), profile)
    if shadow then shadow.overlap_offset = { slot.x, slot.y } end
    return shadow
end

-- Whether the progress badge is painted on a slot: always on the centre cover,
-- and on right-hand side covers when enabled for them, which show the outer
-- edge the badge sits on. Left-hand side covers show their inner edge, so they
-- never carry it.
local function slotWantsBadge(slot, show_badge, on_peeks)
    if not show_badge then return false end
    return slot.kind == "center" or (on_peeks and slot.align == "right")
end

-- Flat covers carry their badge as a widget over the cover; tilted covers
-- carry it in their own pixels (tiltBadge).
local function slotWantsBadgeWidget(slot, show_badge, on_peeks)
    return slot.kind ~= "tilt" and slotWantsBadge(slot, show_badge, on_peeks)
end

-- Badge of a tilted slot, placed in the top-right corner of the flat cover
-- (slot.flat_w wide): { desc, x, y, key }, or nil when the slot carries none.
-- Painted into the cover before the warp, it is squeezed and tilted with the
-- artwork, text included.
local function tiltBadge(SH, slot, bd, pfx, show_badge, on_peeks)
    if slot.kind ~= "tilt" or not slotWantsBadge(slot, show_badge, on_peeks) then return nil end
    local desc, margin = SH.coverBadgeDesc(bd, slot.flat_w, slot.h, progressBadgeOpts(slot, pfx))
    if not desc then return nil end
    local badge_w = CoverWidgets.progressBadgeSize(desc)
    return {
        desc = desc,
        x    = math.max(0, slot.flat_w - badge_w - margin),
        y    = 0,
        key  = CoverWidgets.progressBadgeKey(desc),
    }
end

-- ---------------------------------------------------------------------------
-- Idle warm-up
-- ---------------------------------------------------------------------------
-- A swipe rebuilds the module synchronously, so every cover it shows that is
-- not cached yet costs time right then. After a build, the covers that a swipe
-- to either neighbour would show are therefore made one per scheduler tick,
-- nearest first. A newer build or a reset drops what is still queued.

local _warmup_step = nil   -- the pending scheduler callback

local function cancelWarmup()
    if _warmup_step then
        UIManager:unschedule(_warmup_step)
        _warmup_step = nil
    end
end

-- Makes the cover `slot` shows, ready in its cache. `deck` is the build's
-- context: { SH, pfx, bookData, show_badge, on_peeks, ... }.
local function warmSlot(deck, slot)
    if slot.kind == "center" then
        Config.getStretchedCoverBB(slot.fp, slot.w, slot.h)
        return
    end
    local bd = deck.bookData(slot.fp)
    slot.badge = tiltBadge(deck.SH, slot, bd, deck.pfx, deck.show_badge, deck.on_peeks)
    if not tiltedCover(slot) and Config.isCoverMissing(slot.fp) then
        tiltedPlaceholder(slot, bd)
    end
end

-- Queues the covers shown after a swipe from the centre book `cur`, and works
-- through them while `alive()` holds. Slots that are neither the centre nor
-- tilted draw from caches that need no warming.
local function scheduleWarmup(deck, cur, alive)
    cancelWarmup()
    local queue, queued = {}, {}
    for _i, delta in ipairs(SWIPE_DELTAS) do
        local target = (cur - 1 + delta) % deck.count + 1
        if not queued[target] then
            queued[target] = true
            local slots = layoutSlots(deck.style, deck.count, deck.geometry)
            assignBooks(slots, deck.fps, target)
            for i = #slots, 1, -1 do
                local kind = slots[i].kind
                if kind == "center" or kind == "tilt" then queue[#queue + 1] = slots[i] end
            end
        end
    end

    local n = 0
    local function step()
        n = n + 1
        local slot = queue[n]
        if not (slot and alive()) then
            _warmup_step = nil
            return
        end
        warmSlot(deck, slot)
        UIManager:scheduleIn(WARMUP_TICK, step)
    end
    _warmup_step = step
    UIManager:scheduleIn(WARMUP_DELAY, step)
end

-- ---------------------------------------------------------------------------
-- File list builders
-- ---------------------------------------------------------------------------

-- A book counts as finished when its cached percent has reached 100%, or
-- its cached summary status is explicitly "complete" (a source may report
-- completion without percent ever reaching exactly 1.0).
local function _isBookDone(ctx, fp)
    local pd  = ctx.prefetched and ctx.prefetched[fp]
    local pct = pd and pd.percent or 0
    return (pct >= 1.0) or
        (type(pd) == "table" and type(pd.summary) == "table" and pd.summary.status == "complete")
end

-- Moves current_fp to the front of fps if present, otherwise returns fps
-- unchanged. Only reorders the coverdeck's own display list, not the
-- underlying source list (recent history, TBR, collection).
local function _prioritizeCurrent(fps, current_fp)
    if not (current_fp and fps and #fps > 0) then return fps end
    local found = false
    for _i, fp in ipairs(fps) do
        if fp == current_fp then found = true; break end
    end
    if not found then return fps end
    local result = { current_fp }
    for _i, fp in ipairs(fps) do
        if fp ~= current_fp then result[#result+1] = fp end
    end
    return result
end

local function buildRecentFps(ctx)
    local fps      = {}
    local show_fin = showFinished(ctx.pfx or "")
    if ctx.current_fp then
        fps[1] = ctx.current_fp
    end
    if ctx.recent_fps then
        local seen = {}
        if ctx.current_fp then seen[ctx.current_fp] = true end
        for _i, fp in ipairs(ctx.recent_fps) do
            if not seen[fp] and (show_fin or not _isBookDone(ctx, fp)) then
                fps[#fps+1] = fp
                seen[fp]    = true
                if #fps >= MAX_RECENT_FPS then break end
            end
        end
    end
    return fps
end

local function buildTBRFps(ctx)
    if not ctx._tbr_fps then
        local tbr = require("modules/module_tbr")
        ctx._tbr_fps = tbr.getTBRList()
    end
    return _prioritizeCurrent(ctx._tbr_fps, ctx.current_fp)
end

local function buildCollectionFps(coll_name, ctx)
    local ok_rc, rc = pcall(require, "readcollection")
    if not (ok_rc and rc) then return {} end
    -- Read the in-process singleton directly, without rc:_read(): that call
    -- reloads collections from disk and can wipe in-memory-only changes the
    -- native Collections UI hasn't flushed yet.
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end

    local show_fin = showFinished(ctx.pfx or "")
    local list = {}
    local lfs = require("libs/libkoreader-lfs")
    for fp, info in pairs(coll) do
        local ok_attr, attr = pcall(lfs.attributes, fp, "mode")
        local exists = ok_attr and attr == "file"
        if exists and (show_fin or not _isBookDone(ctx, fp)) then
            list[#list + 1] = {
                filepath = fp,
                order = (type(info) == "table" and info.order) or 9999
            }
        end
    end
    table.sort(list, function(a, b) return (a.order or 9999) < (b.order or 9999) end)

    local raw_fps = {}
    for i = 1, #list do
        raw_fps[i] = list[i].filepath
    end
    return _prioritizeCurrent(raw_fps, ctx.current_fp)
end

local function buildFavoritesFps(ctx)
    local ok_rc, rc = pcall(require, "readcollection")
    local fav_name = (ok_rc and rc and rc.default_collection_name) or "favorites"
    return buildCollectionFps(fav_name, ctx)
end

local function getFps(source, ctx)
    local fps
    if source == "tbr" then
        fps = buildTBRFps(ctx)
    elseif source == "favorites" then
        fps = buildFavoritesFps(ctx)
    elseif collectionNameOf(source) then
        fps = buildCollectionFps(collectionNameOf(source), ctx)
    else
        fps = buildRecentFps(ctx)
    end
    -- Fallback: if chosen source is empty, cascade through the others.
    if not fps or #fps == 0 then
        if source ~= "recent" then
            fps = buildRecentFps(ctx)
        end
        if (not fps or #fps == 0) and source ~= "tbr" then
            fps = buildTBRFps(ctx)
        end
        if (not fps or #fps == 0) and source ~= "favorites" then
            fps = buildFavoritesFps(ctx)
        end
    end
    return fps
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id          = "coverdeck"
M.name        = _("Cover Deck")
M.category    = "books"
M.label       = nil
M.enabled_key = "coverdeck_enabled"
M.default_on  = false
M.has_covers  = true   -- activates e-ink dithering and cover poll
M.is_book_mod = true   -- suppresses empty-state when active
M.needs       = require("engines/sui_book_sources").get("recent").needs

-- Text elements with a user-selectable font family and size.
M.text_elems  = { "title", "author", "info" }

-- The title is bold until the user picks another variant.
Config.declareTextVariants(M.id, { title = "bold" })

function M.reset()
    cancelWarmup()
    _SH = nil
    BookStats.invalidate()
    _tilt_cache:clear()
end

-- No-op: called from main.lua:onCloseDocument as a fallback when the closed
-- book's md5 could not be resolved (the normal path is
-- invalidateCacheForMd5, below). A full flush isn't needed here — every
-- other book's cached stats are still valid, and the centre book's own
-- entry gets a forced refetch on the very next stats-only refresh via
-- M.updateStats' fetchBookStats(..., true) call. Wiping the whole cache
-- would only force every carousel entry back to SQLite on the next swipe
-- for no correctness gain.
function M.invalidateCache()
end

-- Removes only the cache entry for the given md5, leaving all other books
-- intact. Called after closing a document so the centre cover's stats are
-- fresh without discarding stats cached for every other book.
function M.invalidateCacheForMd5(md5)
    if md5 then BookStats.invalidate(md5) end
end

-- Exposed for pre-computation from outside the module (see _buildCtx).
-- Same as the local fetchBookStats; does not set ctx.db_conn_fatal since
-- there is no ctx here.
function M.fetchBookStatsForCtx(md5, db_conn, force)
    return fetchBookStats(md5, db_conn, nil, force)
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------

-- Empty placeholder when the chosen source has no books (same pattern as
-- Quick Actions / Featured Collection / Collections).
-- Uses a wrapping text box rather than the single-line TextWidget behind
-- makeColoredText, since this message is long enough to need multiple lines
-- at the module's own width.
local function _emptyPlaceholder(w, h, text_alpha, ink)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local line_h = math.floor(1.3 * face.size + 0.5)
    local args = {
        text      = _("No books to show yet — open a book to see it here."),
        face      = face,
        width     = w - PAD * 2,
        height    = math.max(line_h, h - PAD * 2),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor   = (ink or Chrome.PLAIN_INK).sub,
    }

    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        UI.makeTextBox(args, text_alpha),
    }
end

-- Font sizes of the title, author and info text: layout scale × per-element
-- text style scale. Shared by build() and getHeight().
local function fontSizes(scale, _lbl_scale, styles)
    local function fs(base, min_fs, style)
        return math.max(min_fs, math.floor(base * scale * (style and style.scale or 1)))
    end
    return fs(SUIStyle.FS_TITLE,    8, styles.title),
           fs(SUIStyle.FS_SUBTITLE, 8, styles.author),
           fs(SUIStyle.FS_DETAIL,   7, styles.info)
end

function M.build(w, ctx)
    local pfx    = ctx.pfx

    -- Use pre-read settings bundle from ctx when available (normal HS path).
    local c = ctx.cfg and ctx.cfg.coverdeck
    local source = c and c.source or getSource(pfx)

    logger.dbg("coverdeck: build source=" .. tostring(source)
        .. " current_fp=" .. tostring(ctx.current_fp)
        .. " recent_fps=" .. tostring(ctx.recent_fps and #ctx.recent_fps or "nil"))

    local fps = getFps(source, ctx)
    if not fps or #fps == 0 then
        logger.dbg(string.format("coverdeck: no books found (source=%s)", tostring(source)))
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.text_alpha, ctx.ink)
    end

    local SH = getSH()
    if not SH then
        return _emptyPlaceholder(w, M.getHeight(ctx), ctx.text_alpha, ctx.ink)
    end

    -- Content colours over the module fill.
    local ink              = ctx.ink or Chrome.PLAIN_INK
    local CLR_TEXT_EFF     = ink.blk
    local CLR_TEXT_SUB_EFF = ink.sub

    -- Scales: c.scale/c.thumb_scale/c.lbl_scale (from ctx.cfg) are raw
    -- values; ctx.landscape_factor is applied on top here.
    local lf          = ctx.landscape_factor or 1
    local scale       = (c and c.scale       or Config.getModuleScale("coverdeck", pfx)) * lf
    local thumb_scale = (c and c.thumb_scale or Config.getThumbScale("coverdeck", pfx)) * lf
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("coverdeck", pfx)) * lf

    -- Carousel geometry (center_w below) is a percentage of inner_w, which
    -- is already narrowed for landscape upstream. Applying `lf` on top of
    -- that would narrow it twice, so this uses the raw scale instead.
    -- scale/thumb_scale above (with lf) remain for fixed-pixel elements
    -- (fonts, bar height) that aren't width-derived.
    local raw_scale       = c and c.scale       or Config.getModuleScaleRaw("coverdeck", pfx)
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScaleRaw("coverdeck", pfx)
    local cs              = raw_scale * raw_thumb_scale

    -- Visibility flags: uses the pre-read bundle when available, otherwise
    -- reads settings directly.
    local vis = getVisibleElements(pfx, c)
    local main_order      = vis.main_order
    local show_title      = vis.show_title
    local show_author     = vis.show_author
    local show_progress   = vis.progress
    local show_stats      = vis.show_stats
    local stats_order     = vis.stats_order
    local show_progress_badge         = showProgressBadge(pfx)
    local show_progress_badge_on_peeks = showProgressBadgeOnPeeks(pfx)

    -- Carousel dimensions: center_w is a percentage of inner_w (see
    -- _CENTER_W_PCT above), scaled by cs (raw scale * thumb_scale) on top.
    local style    = getStyle(pfx, c)
    local inner_w  = w - PAD * 2
    local center_w = centerWidth(inner_w, cs)
    local center_h = math.floor(center_w * COVER_ASPECT)

    local centerX = math.floor(inner_w / 2)
    local half_cw = math.floor(center_w / 2)
    -- Full carousel footprint (left outer edge to right outer edge), clamped to
    -- the overlap group width. Title/author max_width uses this so those
    -- lines stay within the cover block including the side covers.
    local covers_block_w = math.min(inner_w,
        center_w + 2 * levelOffset(style.levels[#style.levels], center_w))
    -- Stats may run wider than the covers; truncate only past 95% of the
    -- module page width.
    local stats_max_w = math.floor(w * 0.95)
    local TOP_CLEAR   = 2
    local centerY     = math.floor(center_h / 2) + TOP_CLEAR

    local count  = #fps
    -- The centre is always fps[1] by default. Swipe navigation is
    -- session-scoped: stored in ctx, not persisted across sessions.
    local curIdx = ctx.coverdeck_cur_idx or 1
    if curIdx > count then curIdx = 1 end
    ctx.coverdeck_cur_idx = curIdx

    -- Book data is resolved once per book per build: the centre book is read
    -- by its cover and again for the text block below.
    local book_data = {}
    local function bookData(fp)
        local bd = book_data[fp]
        if not bd then
            bd = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
            book_data[fp] = bd
        end
        return bd
    end

    -- Tappable carousel container. Each cover is preceded by its own shadow
    -- so it falls on the covers behind it along the edge where they touch.
    -- allow_mirroring is off: side layout and tilt orientation are resolved
    -- in logical coordinates; RTL navigation is handled in the gesture code.
    local geometry = { center_w = center_w, center_h = center_h, centerX = centerX, centerY = centerY }
    local slots    = layoutSlots(style, count, geometry)
    assignBooks(slots, fps, curIdx)
    local group_h = center_h + TOP_CLEAR
    local overlap = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = group_h },
        allow_mirroring = false,
    }
    for _i, slot in ipairs(slots) do
        local bd = bookData(slot.fp)
        slot.badge = tiltBadge(SH, slot, bd, pfx, show_progress_badge, show_progress_badge_on_peeks)
        local cover = loadSlotCover(SH, slot) or placeholderCover(SH, slot, bd)
        if slotWantsBadgeWidget(slot, show_progress_badge, show_progress_badge_on_peeks) then
            cover = applyProgressBadge(cover, bd, slot, pfx)
        end
        -- Fresh table per cover so OverlapGroup mutations never corrupt the
        -- slot's base coordinates used by updateCovers.
        slot.base_x, slot.base_y = slot.x, slot.y
        cover.overlap_offset = { slot.x, slot.y }

        local shadow = slotShadow(SH, slot)
        if shadow then
            shadow.allow_mirroring = false
            overlap[#overlap + 1] = shadow
        end
        overlap[#overlap + 1] = cover
        slot.container = overlap
        slot.idx       = #overlap
    end

    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = inner_w, h = group_h },
        [1]      = overlap,
        _screen  = ctx._screen_widget,
        _open_fn = ctx.open_fn,
        _fps     = fps,
        _cur     = curIdx,
        _count   = count,
        _mid     = math.floor(inner_w / 2),
        _half_cw = half_cw,
    }

    -- Repaints only this coverdeck widget's screen region after tap/swipe
    -- navigation, instead of a full-page rebuild + whole-screen redraw.
    -- Falls back to a full refresh when the surgical path is unavailable.
    local function _navigateRefresh(screen)
        if screen._refreshBookModSlot then
            local ok = screen:_refreshBookModSlot("coverdeck")
            if ok then return end
        end
        screen:_refreshImmediate(true)
    end

    -- Moves self._cur by `delta` covers (positive: forward) and repaints.
    local function _navigateBy(self, delta)
        self._cur = (self._cur - 1 + delta) % self._count + 1
        if self._screen then
            self._screen:_setCoverdeckIdx(self._cur)
            _navigateRefresh(self._screen)
        end
    end

    function tappable:onTap(_, ges)
        local x        = ges.pos.x - self.dimen.x
        local mirrored = BD.mirroredUILayout()
        local side
        if x < self._mid - self._half_cw then
            side = -1   -- left: previous in LTR, next in RTL
        elseif x > self._mid + self._half_cw then
            side = 1    -- right: next in LTR, previous in RTL
        elseif self._open_fn then
            self._open_fn(self._fps[self._cur])
        end
        if side then _navigateBy(self, mirrored and -side or side) end
        return true
    end

    function tappable:onSwipe(_, ges)
        local dir = ges.direction
        if BD.mirroredUILayout() then
            if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
        end
        if dir == "east" then
            _navigateBy(self, -1)
            return true
        elseif dir == "west" then
            _navigateBy(self, 1)
            return true
        end
        return false
    end

    tappable.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = function() return tappable.dimen end } },
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } },
    }

    -- Long-press on the centre cover opens the per-book dialog only when
    -- enabled via "Long press on cover". Holding on a side cover, or with
    -- the setting left at "settings", falls back to the module wrapper's
    -- own hold handling (settings screen).
    if Config.getCoverHoldMode("coverdeck", ctx.pfx) == "book_dialog" then
        tappable.ges_events.HoldDeck = {
            GestureRange:new{ ges = "hold", range = function() return tappable.dimen end },
        }
        tappable.ges_events.HoldDeckRelease = {
            GestureRange:new{ ges = "hold_release", range = function() return tappable.dimen end },
        }
        function tappable:onHoldDeck(_, ges)
            local x = ges.pos.x - self.dimen.x
            self._hold_on_center = (x >= self._mid - self._half_cw and x <= self._mid + self._half_cw)
            -- Only swallow the gesture (and thus block the settings-menu
            -- fallback) when it actually lands on the centre cover.
            return self._hold_on_center or nil
        end
        function tappable:onHoldDeckRelease()
            if self._hold_on_center and ctx.hold_fn then
                ctx.hold_fn(self._fps[self._cur], "coverdeck")
            end
            return self._hold_on_center or nil
        end
    end

    -- Book data for centre cover
    local bd        = bookData(fps[curIdx])
    local styles    = Config.resolveTextStyles(ctx, M.id, M.text_elems)
    local title_fs, author_fs, info_fs = fontSizes(scale, lbl_scale, styles)
    local bar_h     = math.max(1, math.floor(SUIStyle.PROGRESS_BAR_H * scale))
    local face_title, bold_title = SUIStyle.getTextFace(styles.title, title_fs)
    local face_info,  bold_info  = SUIStyle.getTextFace(styles.info,  info_fs)

    -- Title widget (capped to full cover block including side peeks)
    local title_widget
    if show_title then
        title_widget  = UI.makeColoredText{
            text      = truncateToWidth(bd.title, face_title, covers_block_w),
            face      = face_title,
            bold      = bold_title,
            fgcolor   = CLR_TEXT_EFF,
            width     = covers_block_w,
            alignment = "center",
        }
    end

    -- Author widget (hidden when no usable name, same as description)
    local author_widget
    if show_author then
        local author_text = Text.formatAuthors(bd.authors)
        if author_text then
            local face_author, bold_author = SUIStyle.getTextFace(styles.author, author_fs)
            author_widget = UI.makeColoredText{
                text      = truncateToWidth(author_text, face_author, covers_block_w),
                face      = face_author,
                bold      = bold_author,
                fgcolor   = CLR_TEXT_SUB_EFF,
                width     = covers_block_w,
                alignment = "center",
            }
        end
    end

    -- Closures used by updateStats for in-place refresh.
    -- _cd_update_funcs: DB-backed stats text (needs bstats).
    -- _cd_bd_only_funcs: progress bar (needs only book data).
    local _cd_update_funcs  = {}
    local _cd_bd_only_funcs = {}
    local function _updateColoredText(wgt, txt, fg)
        if wgt._inner and wgt._inner.setText then
            wgt._inner:setText(txt)
            wgt._fg = fg
            wgt.dimen = wgt._inner:getSize()
        elseif wgt.setText then
            wgt:setText(txt)
            wgt.fgcolor = fg
        end
    end

    -- Progress bar: wrapped in a single-child container so updateStats can
    -- replace the bar without touching the surrounding VerticalGroup.
    local progress_widget
    if show_progress then
        local _bar_w = center_w
        local _bar_h = bar_h
        local _init_bar = UI.progressBar(_bar_w, bd.percent, _bar_h, ink.bar_fg, ink.bar_bg)
        local bar_container = OverlapGroup:new{
            dimen = _init_bar:getSize(),
            _init_bar,
        }
        local function _update_bar(_nb, nd)
            bar_container[1] = UI.progressBar(_bar_w, (nd and nd.percent or 0), _bar_h, ink.bar_fg, ink.bar_bg)
        end
        table.insert(_cd_bd_only_funcs, _update_bar)
        progress_widget = bar_container
    end

    -- Stats: single compact line rebuilt from the arranged stats order.
    local stats_widget
    local has_any_stats = show_stats and vis.has_stat

    if has_any_stats then
        local bstats
        if vis.has_stat then
            -- Fast path: stats pre-computed by _buildCtx() for this centre book.
            local pre = ctx.coverdeck_center_stats
            if pre and pre.fp == fps[curIdx] then
                bstats = pre.stats
            else
                -- Slow path: query once; result lands in the stats cache for
                -- subsequent carousel navigations.
                local prefetched_entry = ctx.prefetched and ctx.prefetched[fps[curIdx]]
                local md5 = _resolveMd5(fps[curIdx], prefetched_entry)
                if md5 then
                    bstats = fetchBookStats(md5, ctx.db_conn, ctx)
                end
            end
        end

        local stats_w = UI.makeColoredText{
            text      = "",
            face      = face_info,
            bold      = bold_info,
            fgcolor   = CLR_TEXT_SUB_EFF,
            width     = stats_max_w,
            alignment = "center",
        }
        local function _update(nb, nd)
            local line = BookStats.line(stats_order,
                function(key) return _showElemFrom(c, pfx, key) end,
                function(key) return BookStats.textFor(key, nb, nd) end)
            _updateColoredText(stats_w, truncateToWidth(line, face_info, stats_max_w), CLR_TEXT_SUB_EFF)
        end
        _update(bstats, bd)
        table.insert(_cd_update_funcs, _update)
        stats_widget = stats_w
    end

    -- Final layout assembly — render each visible main-list element in the
    -- user's chosen order ("covers" is the carousel itself; the rest are
    -- optional widgets). A PAD2 vspan separates any two adjacent elements.
    local final_vg = VerticalGroup:new{ align = "center" }
    local _first_elem = true
    local function _appendElem(widget)
        if not widget then return end
        if not _first_elem then final_vg[#final_vg+1] = SH.vspan(PAD2, ctx.vspan_pool) end
        final_vg[#final_vg+1] = widget
        _first_elem = false
    end
    for _i, key in ipairs(main_order) do
        if key == "covers" then
            _appendElem(tappable)
        elseif key == "title" then
            _appendElem(title_widget)
        elseif key == "author" then
            _appendElem(author_widget)
        elseif key == "progress" then
            _appendElem(progress_widget)
        elseif key == "stats" then
            _appendElem(stats_widget)
        end
    end

    if count > 1 then
        local screen = ctx._screen_widget
        scheduleWarmup({
            SH = SH, pfx = pfx, style = style, geometry = geometry, fps = fps, count = count,
            bookData   = bookData,
            show_badge = show_progress_badge,
            on_peeks   = show_progress_badge_on_peeks,
        }, curIdx, function() return screen ~= nil and screen:isActive() end)
    end

    local result = FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = PAD, padding_bottom = 0,
        final_vg,
    }
    result._cover_slots     = slots
    result._cd_update_funcs = _cd_update_funcs
    result._cd_bd_only_funcs = _cd_bd_only_funcs
    result._center_fp       = fps[curIdx]
    return result
end

-- Patches in the covers that arrived since build(). Returns all_done (every
-- slot resolved) and changed (a cover was patched in by this call).
function M.updateCovers(widget, ctx)
    if not widget or not widget._cover_slots then return true, false end
    local SH = getSH()
    if not SH then return true, false end
    local pfx = (ctx and ctx.pfx) or ""
    local show_badge = showProgressBadge(pfx)
    local on_peeks   = showProgressBadgeOnPeeks(pfx)
    local all_done, changed = true, false
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = not slot.done and loadSlotCover(SH, slot)
        if new_cover then
            -- Re-apply the progress badge after a late cover load (build()
            -- already did this where it applies; the poll would otherwise
            -- strip it). A tilted cover brings its badge (slot.badge) along.
            if slotWantsBadgeWidget(slot, show_badge, on_peeks) then
                local bd = SH.getBookData(slot.fp, ctx and ctx.prefetched and ctx.prefetched[slot.fp])
                new_cover = applyProgressBadge(new_cover, bd, slot, pfx)
            end
            -- Fresh offset from the slot's base coordinates so a previous
            -- OverlapGroup paint cannot leave a mirrored value behind.
            new_cover.overlap_offset = { slot.base_x, slot.base_y }
            slot.container[slot.idx] = new_cover
            slot.done, changed = true, true
        elseif not slot.done and not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done, changed
end

function M.updateStats(widget, ctx)
    local actual_widget = (widget._cd_update_funcs or widget._cd_bd_only_funcs) and widget
                          or (widget[1] and (widget[1]._cd_update_funcs or widget[1]._cd_bd_only_funcs) and widget[1])
    if not actual_widget then return false end
    if not actual_widget._cd_update_funcs and not actual_widget._cd_bd_only_funcs then
        return false
    end

    local fp = actual_widget._center_fp
    if not fp then return false end

    -- Widget is bound to the centre book at build time. Recompute the centre
    -- fp build() would produce and bail on mismatch so we never patch the
    -- wrong book's numbers (list/order can change between renders).
    do
        local c        = ctx.cfg and ctx.cfg.coverdeck
        local source   = c and c.source or getSource(ctx.pfx)
        local fps      = getFps(source, ctx)
        local count    = fps and #fps or 0
        local cur_idx  = ctx.coverdeck_cur_idx or 1
        if count > 0 and cur_idx > count then cur_idx = 1 end
        local expected_center_fp = count > 0 and fps[cur_idx] or nil
        if expected_center_fp ~= fp then return false end
    end

    -- Progress badge is composited into the cover widget tree at build time.
    -- Percent/status changes on the badge require a full rebuild — same
    -- contract as GridRenderer.updateStats for progress_style "badge".
    local pfx = (ctx and ctx.pfx) or ""
    if showProgressBadge(pfx) then return false end

    local bstats
    local pre = ctx.coverdeck_center_stats
    if pre and pre.fp == fp then
        bstats = pre.stats
    end

    local prefetched_entry = ctx.prefetched and ctx.prefetched[fp]
    if not bstats then
        local md5 = _resolveMd5(fp, prefetched_entry)
        if md5 then
            bstats = fetchBookStats(md5, ctx.db_conn, ctx, true)
        end
    end

    local SH = getSH()
    if not SH then return true end
    local bd = SH.getBookData(fp, prefetched_entry)

    if bstats and actual_widget._cd_update_funcs then
        for _, fn in ipairs(actual_widget._cd_update_funcs) do
            fn(bstats, bd)
        end
    end
    -- Progress bar only needs bd; update even when there is no SQLite history.
    if actual_widget._cd_bd_only_funcs then
        for _, fn in ipairs(actual_widget._cd_bd_only_funcs) do
            fn(nil, bd)
        end
    end
    return true
end

function M.getHeight(ctx)
    local pfx = ctx and ctx.pfx or ""
    -- Uses the pre-read settings bundle from ctx when available. c.scale
    -- is raw; ctx.landscape_factor is applied on top here.
    local c           = ctx and ctx.cfg and ctx.cfg.coverdeck
    local lf          = (ctx and ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local scale       = (c and c.scale       or Config.getModuleScale("coverdeck", pfx)) * lf
    local lbl_scale   = (c and c.lbl_scale   or Config.getItemLabelScale("coverdeck", pfx)) * lf

    -- center_w mirrors build(): a percentage of inner_w, using the raw
    -- scale (no `lf`) since ctx.col_w is already narrowed for landscape.
    -- getHeight has no real widget width to work with, so estimate one.
    local raw_scale       = c and c.scale       or Config.getModuleScaleRaw("coverdeck", pfx)
    local raw_thumb_scale = c and c.thumb_scale or Config.getThumbScaleRaw("coverdeck", pfx)
    local w_estimate       = (ctx and (ctx.col_w or ctx.inner_w)) or UI.getInnerW()
    local inner_w_estimate = w_estimate - PAD * 2

    -- Visibility flags: uses the pre-read bundle when available, mirroring build().
    local vis = getVisibleElements(pfx, c)
    local show_title  = vis.show_title
    local show_author = vis.show_author

    local center_w = centerWidth(inner_w_estimate, raw_scale * raw_thumb_scale)
    local center_h = math.floor(center_w * COVER_ASPECT)
    local h        = center_h + 2  -- TOP_CLEAR

    -- Must mirror the face sizes used in build(), or the reserved height
    -- undershoots the rendered text and it gets clipped by the module's frame.
    local styles = Config.resolveTextStyles(ctx, M.id, M.text_elems)
    local title_fs, author_fs, info_fs = fontSizes(scale, lbl_scale, styles)

    if show_title then
        h = h + SUIStyle.lineReserve(styles.title, title_fs, title_fs) + PAD2
    end

    if show_author then
        h = h + SUIStyle.lineReserve(styles.author, author_fs, author_fs) + PAD2
    end

    local has_meta = false
    if vis.progress then
        has_meta = true
        h = h + math.floor(SUIStyle.PROGRESS_BAR_H * scale)   -- matches bar_h in build()
    end

    if vis.has_stat and vis.show_stats ~= false then
        if has_meta then h = h + PAD2 end
        h        = h + SUIStyle.lineReserve(styles.info, info_fs,
            math.floor(Screen:scaleBySize(14) * scale * lbl_scale))
        has_meta = true
    end

    if has_meta then h = h + PAD2 end

    return h + PAD
end

-- ---------------------------------------------------------------------------
-- getMenuItems
-- ---------------------------------------------------------------------------

function M.getMenuItems(ctx_menu)
    local pfx        = ctx_menu.pfx
    local refresh    = ctx_menu.refresh
    local _lc        = ctx_menu._

    local scale_items = {
        Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module."),
            get          = function() return Config.getModuleScalePct("coverdeck", pfx) end,
            set          = function(v) Config.setModuleScale(v, "coverdeck", pfx) end,
            refresh      = refresh,
        }),
        Config.makeScaleItem({
            text_func = function() return _lc("Cover Size") end,
            title     = _lc("Cover Size"),
            info      = _lc("Scale for the cover thumbnails only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct("coverdeck", pfx) end,
            set       = function(v) Config.setThumbScale(v, "coverdeck", pfx) end,
            refresh   = refresh,
        }),
    }

    local style_item = Config.makeRadioSubmenuItem{
        text    = _lc("Style"),
        options = {
            { value = "classic", label = _lc("Classic") },
            { value = "flow",    label = _lc("Flow") },
        },
        get     = function() return getStyleId(pfx) end,
        set     = function(value) SUISettings:saveSetting(pfx .. SETTING_STYLE, value) end,
        refresh = refresh,
    }

    local fixed_sources = {
        { value = "recent",    label = _lc("Recent Books") },
        { value = "tbr",       label = _lc("To Be Read") },
        { value = "favorites", label = _lc("Favorites") },
    }

    local function getSourceValue() return getSource(pfx) end
    local function setSource(value) SUISettings:saveSetting(pfx .. SETTING_SOURCE, value) end

    -- One option per collection, excluding favorites and TBR (they have
    -- dedicated top-level options).
    local function collectionSourceOptions()
        local options = {}
        local ok_rc, rc = pcall(require, "readcollection")
        if not (ok_rc and rc) then return options end

        -- Not calling rc:_read(): it can wipe uncommitted collection changes
        -- made via the native Collections UI.
        local coll_set = {}
        if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
        if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end
        coll_set[rc.default_collection_name or "favorites"] = nil
        local TBR = package.loaded["modules/module_tbr"]
        coll_set[TBR and TBR.TBR_COLL_NAME or "To Be Read"] = nil

        local coll_names = {}
        for name in pairs(coll_set) do
            coll_names[#coll_names + 1] = name
        end
        table.sort(coll_names, function(a, b) return util.stringLower(a) < util.stringLower(b) end)

        for _i, name in ipairs(coll_names) do
            options[#options + 1] = { value = COLLECTION_PREFIX .. name, label = name }
        end
        return options
    end

    local source_item = Config.makeRadioSubmenuItem{
        text    = _lc("Source"),
        options = function()
            local options = {}
            for _i, option in ipairs(fixed_sources) do
                options[#options + 1] = option
            end
            if pcall(require, "readcollection") then
                options[#options + 1] = {
                    label    = _lc("Collections"),
                    selected = function(source) return collectionNameOf(source) ~= nil end,
                    sub_item_table_func = function()
                        return Config.appendRadioItems({}, {
                            options    = collectionSourceOptions,
                            empty_text = _lc("No collections found"),
                            get        = getSourceValue,
                            set        = setSource,
                            refresh    = refresh,
                        })
                    end,
                }
            end
            return options
        end,
        current_label = function()
            local source = getSource(pfx)
            local coll_name = collectionNameOf(source)
            if coll_name then return coll_name end
            for _i, option in ipairs(fixed_sources) do
                if option.value == source then return option.label end
            end
            return source
        end,
        get     = getSourceValue,
        set     = setSource,
        refresh = refresh,
    }

    -- Items and statistics share one visibility and order model. Changes also
    -- drop the settings snapshot the screens build from.
    local function refreshItems()
        _invalidateCfgCache(pfx)
        refresh()
    end
    local function itemList(opts)
        opts.ctx         = ctx_menu
        opts.refresh     = refreshItems
        opts.is_visible  = function(key) return _showElem(pfx, key) end
        opts.set_visible = function(key, visible) _setElemVisible(pfx, key, visible) end
        return Config.makeOrderedItems(opts)
    end
    local stats_list = itemList{
        ids        = STAT_IDS,
        order_key  = pfx .. STATS_ORDER_KEY,
        label      = BookStats.statLabel,
        title      = _lc("Statistics"),
        text       = _lc("Arrange Statistics"),
        empty_text = _lc("No statistics selected."),
    }
    local main_list = itemList{
        ids       = MAIN_IDS,
        anchors   = MAIN_ANCHORS,
        order_key = pfx .. MAIN_ORDER_KEY,
        label     = mainLabel,
        title     = _lc("Items"),
        text      = _lc("Arrange Items"),
        nested    = { stats = stats_list },
    }

    -- The SUI menu reaches the statistics from the Items screen; the classic
    -- menu lists them in a submenu of their own.
    local rows = main_list.rows()
    local items_item = rows[1]
    if not ctx_menu.is_sui then
        rows[1].separator = true
        rows[#rows + 1] = { text = _lc("Statistics"), sub_item_table = stats_list.rows() }
        items_item = { text = _lc("Items"), sub_item_table = rows }
    end

    local text_opts = {
        mod_id  = M.id,
        elems   = M.text_elems,
        labels  = { title = _lc("Title"), author = _lc("Author"), info = _lc("Statistics") },
        info    = _lc("Size of this text.\n100% is the default size."),
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }
    local progress_badge_group = {
        Config.makeBadgeSizeItem{
            info         = _lc("Scale for the progress badge."),
            enabled_func = function() return showProgressBadge(pfx) end,
            get          = function() return Config.getBadgeScalePct("coverdeck", pfx) end,
            set          = function(v) Config.setBadgeScale(v, "coverdeck", pfx) end,
            refresh      = refresh,
            _lc          = _lc,
            separator    = true,
        },
        {
            text           = _lc("Progress Badge"),
            checked_func   = function() return showProgressBadge(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_SHOW_PROGRESS_BADGE, not showProgressBadge(pfx))
                refresh()
            end,
        },
        {
            text           = _lc("On side covers too"),
            enabled_func   = function() return showProgressBadge(pfx) end,
            checked_func   = function() return showProgressBadgeOnPeeks(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_PROGRESS_BADGE_ON_PEEKS,
                    not showProgressBadgeOnPeeks(pfx))
                refresh()
            end,
        },
        Config.makeRadioSubmenuItem{
            text         = _lc("Progress Badge Color"),
            enabled_func = function() return showProgressBadge(pfx) end,
            options      = SUIStyle.badgeColorOptions(_lc, _lc("Follow Style")),
            get          = function() return SUIStyle.badgeChoiceShown(getProgressBadgeColorOverride(pfx)) end,
            set          = function(v) setProgressBadgeColor(pfx, v) end,
            refresh      = refresh,
        },
    }
    return Config.buildModuleMenu({
        items   = { items_item },
        content = {
            source_item,
            {
                text           = _lc("Show finished books"),
                checked_func   = function() return showFinished(pfx) end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(pfx .. SETTING_SHOW_FINISHED, not showFinished(pfx))
                    refresh()
                end,
            },
        },
        appearance = {
            size  = scale_items,
            text  = text_opts,
            extra = {
                style_item,
                Config.makeCoverHoldModeItem{
                    mod_id  = "coverdeck",
                    pfx     = pfx,
                    refresh = refresh,
                    _lc     = _lc,
                },
            },
        },
        badges = {
            {
                text_func  = function() return _lc("Progress Badge") end,
                value_func = function()
                    return showProgressBadge(pfx) and _lc("On") or _lc("Off")
                end,
                sub_item_table = progress_badge_group,
            },
        },
        behaviour = {
            {
                text           = _lc("Update Stats Now"),
                separator      = true,
                keep_menu_open = true,
                callback       = function()
                    local SP = package.loaded["modules/module_stats_provider"]
                    if SP and SP.rescanBooks then SP.rescanBooks() end
                    local SH = package.loaded["modules/module_books_shared"]
                    if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end
                    local MC = package.loaded["modules/module_currently"]
                    if MC and MC.invalidateCache then MC.invalidateCache() end
                    local MCD = package.loaded["modules/module_coverdeck"]
                    if MCD and MCD.invalidateCache then MCD.invalidateCache() end
                    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                    if ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
                        ScreenEngine.invalidateAllCfgAndRefresh(true)
                    end
                    if ctx_menu and type(ctx_menu.refresh) == "function" then ctx_menu.refresh() elseif refresh then refresh() end
                    UI.Notify.toast(_lc("Stats updated successfully."), 2)
                end,
            },
        },
    }, ctx_menu)
end

Memory.onReset(M.reset)

return M
