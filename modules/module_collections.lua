-- module_collections.lua — Simple UI
-- Module: Collections.
-- Replaces collectionswidget.lua — contains all of the widget code.
--
-- Rewritten on top of engines/sui_book_grid.lua (GridRenderer.makeModule), just
-- like module_recent.lua / module_new_books.lua / module_tbr.lua /
-- module_feat_coll.lua — but with a different cell unit: instead of
-- "1 collection → N books" (Featured Collection), here it's "N collections → 1
-- cell per collection" (representative cover + count badge + name).
--
-- This is possible thanks to two additive GridRenderer hooks, introduced
-- specifically for this module (see the notes in sui_book_grid.lua):
--   opts.renderCell(item, cw, cell_h, ctx)  — replaces the "book
--       cover" cell with our own (single or quad — see buildCollectionCell).
--   opts.getCellHeight(cw, pfx)             — replaces the "cover + bar +
--       text" height calculation with the coll_cell_h formula (see getDims).
-- Without these two fields, GridRenderer.build/getHeight behave
-- exactly as they did before this change (Recent/New Books/TBR/Featured
-- Collection don't pass renderCell/getCellHeight, so they aren't affected).
--
-- With this, Collections gets for free (via makeModule, spec.grid
-- + spec.paged = true, just like Featured Collection):
--   • Configurable grid (Rows 1-3 × Columns 4-5) instead of always 1 row.
--   • Swipe pagination when there are more collections than fit on one page.
--   • No limit on selectable collections (the limit of 5 only existed to
--     fit on a single row without pagination — no longer makes sense).
--
-- "Cover Style: Single | 4-Cover Grid | Auto" — Single shows the first
-- book's cover; 4-Cover Grid shows up to 4 covers from the collection in a
-- 2×2 grid, reusing CoverWidgets.buildQuadGrid — the same function
-- (extracted from buildQuadCover) used by the library's folder mosaic in
-- sui_foldercovers.lua/sui_cover_widgets.lua. Auto resolves to Single for
-- collections with up to 3 books and 4-Cover Grid from 4 books upward, per
-- collection — same threshold and naming convention ("Auto (X ↔ Y)") as
-- the library's Folder Cover Type "Auto" option (see
-- _resolveCoverStyleForCount below and sui_foldercovers.lua's _resolveStyle).
--
-- The book pile behind the cover (CoverWidgets.buildPile) is a separate
-- toggle ("Hide Book Stack", see getHidePile) independent of Cover Style —
-- applies the same way to Single and 4-Cover Grid, mirroring the library's
-- own decoupling of Folder Cover Type from Hide Folder Book Stack. This is
-- what keeps Auto visually uniform: every cell either has the pile or none
-- does, regardless of which style it individually resolves to.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local Config          = require("infra/sui_config")

local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local GridRenderer = require("engines/sui_book_grid")
local CoverWidgets  = require("features/library/sui_cover_widgets")
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local PAD     = UI.PAD
local PAD2    = UI.PAD2
local MOD_GAP = UI.MOD_GAP

-- Aspect ratio of the collection cover. Deliberately the same exact 3:2
-- portrait ratio used everywhere else a single book cover is shown (Recent/
-- New Books/TBR/Library via module_books_shared.lua's _BASE_COVER_H, and
-- CoverDeck's hero cover) rather than its own close-but-not-quite value.
-- Sharing one exact ratio across every non-Quad consumer lets
-- Config.getStretchedCoverBB() stretch a cover ONCE per book at that ratio,
-- to the largest size any consumer has asked for this session, and reuse it
-- (pure downscale, no re-stretch) for all of them — see
-- infra/sui_cover_cache.lua. Quad mode is the one deliberate exception (its
-- quadrants are ~1:1, not 3:2 — see CoverWidgets.computeQuadCellSizes) and
-- keeps its own crop-to-fill path (Config.getCroppedCoverBB), because crop is
-- a framing decision tied to that specific shape and can't share an entry
-- with the stretch-only group.
local _BASE_COLL_ASPECT = 3 / 2
local _BASE_ACCENT_H     = Screen:scaleBySize(4)
local _BASE_LABEL_LINE_H = Screen:scaleBySize(14)
local _BASE_LABEL_GAP    = Screen:scaleBySize(4)   -- gap between cover and label
local _BASE_BADGE_SZ       = Screen:scaleBySize(16)
local _BASE_BADGE_MARGIN_T = Screen:scaleBySize(8)  -- top margin
local _BASE_PH_COVER_FS  = SUIStyle.FS_TITLE    -- 22: placeholder initials font
local _BASE_COLL_LBL_FS  = SUIStyle.FS_DETAIL   -- 15: collection name label font
local _BASE_BADGE_FS     = 8   -- badge font (~0.375 x badge_sz) — proportional overlay, bypasses type scale
local _BASE_EMPTY_H      = Screen:scaleBySize(36)
local _BASE_EMPTY_FS     = SUIStyle.FS_BODY     -- 18: empty state


local LABEL_H = UI.LABEL_H  -- kept for any external callers; getHeight() uses getScaledLabelH()

local MAX_ITEMS = 5  -- default_cols for the grid (Featured Collection uses the same value)

-- ---------------------------------------------------------------------------
-- getDims(scale, thumb_scale, lbl_scale, cw, hide_pile, badge_scale) — cell
-- geometry.
--
-- cw is the column width already computed by the engine (GridRenderer.build via
-- GridRenderer.computeAutoFitCell). The book pile (see
-- CoverWidgets.buildPile) is independent of Cover Style (Single/Quad/Auto) —
-- same decoupling as the library's "Hide Folder Book Stack" toggle, which
-- applies to both its Single and 4-Cover Grid folder covers. When shown,
-- the cover/grid gives up `pile` px on its right and bottom for the layers
-- behind it; when hidden, `pile` is only the room the cover shadow takes
-- (0 while the shadow is off).
-- coll_w + pile == cw always — the cell always occupies exactly the width
-- the engine reserved, only "pile" (0 or the layers' total inset) changes
-- how much of it the cover/grid takes.
--
-- Because pile does not depend on Cover Style, coll_w/coll_h/coll_cell_h
-- are identical for Single and Quad given the same hide_pile setting —
-- this is what lets Auto mode mix styles per collection without any
-- per-style height reconciliation (see collectionsCellHeight).
--
-- This replaces this file's old computeSlotWidth()/NUM_SLOTS=5 —
-- the engine already handles the auto-fit (cw/gap) according to grid_cols (4-5,
-- configurable), just like for any other grid module.
-- ---------------------------------------------------------------------------
local function getDims(scale, thumb_scale, lbl_scale, cw, hide_pile, badge_scale)
    scale       = scale       or 1.0
    thumb_scale = thumb_scale or 1.0
    lbl_scale   = lbl_scale   or 1.0
    badge_scale = badge_scale or 1.0
    -- Combined scale for cover-related dimensions only.
    local cs = scale * thumb_scale
    local accent_h     = math.max(1, math.floor(_BASE_ACCENT_H     * cs))
    -- badge_scale is independent of `cs` (this module's own Badge Size
    -- setting — see getBadgeScale above), multiplied in on top so the count
    -- badge can be resized without touching the cover/thumbnail scale.
    local badge_sz       = math.max(6, math.floor(_BASE_BADGE_SZ       * cs * badge_scale))
    local badge_margin_t = math.max(1, math.floor(_BASE_BADGE_MARGIN_T * cs))
    -- Label text and gaps scale only with `scale`, not thumb_scale.
    local label_gap    = math.max(1, math.floor(_BASE_LABEL_GAP    * scale))
    -- Font size for collection label — reserved height uses a single-line
    -- estimate matching TextWidget metrics (same idea as GridRenderer labels).
    local coll_lbl_fs  = math.max(6, math.floor(_BASE_COLL_LBL_FS * scale * lbl_scale))
    local label_h      = math.max(1, math.floor(1.3 * coll_lbl_fs + 0.5))

    local pile   = CoverWidgets.backingInset(SUIStyle.SHADOW_MODULES, hide_pile, cs)
    local border = SUIStyle.BADGE_BORDER_SZ
    local coll_w = math.max(1, cw - pile)
    local coll_h = math.max(1, math.floor(coll_w * _BASE_COLL_ASPECT))
    -- coll_w × coll_h is the cover's outer size, border included; the image
    -- (or grid) inside it is smaller by the border on each side.
    local img_w  = math.max(1, coll_w - 2 * border)
    local img_h  = math.max(1, coll_h - 2 * border)
    -- Lateral (right) badge margin — same formula as the pages/series/new/
    -- progress corner badges drawn by GridRenderer.applyBadges
    -- (engines/sui_book_grid.lua), 8% of the cover's shorter side, so the
    -- count badge here sits the same visual distance from the cover edge
    -- as every other badge in the plugin instead of a fixed pixel value.
    local badge_margin = math.max(1, math.floor(math.min(coll_w, coll_h) * 0.08))

    return {
        coll_w       = coll_w,
        coll_h       = coll_h,
        img_w        = img_w,
        img_h        = img_h,
        border       = border,
        accent_h     = accent_h,
        label_h      = label_h,
        label_gap    = label_gap,
        badge_sz       = badge_sz,
        badge_margin   = badge_margin,
        badge_margin_t = badge_margin_t,
        pile         = pile,
        hide_pile    = hide_pile,
        cell_w       = coll_w + pile,   -- == cw, always
        cell_h       = coll_h + accent_h + pile,
        coll_cell_h  = coll_h + accent_h + pile + label_gap + label_h,
        ph_cover_fs  = math.max(7, math.floor(_BASE_PH_COVER_FS * cs)),
        coll_lbl_fs  = coll_lbl_fs,
        badge_fs     = math.floor(badge_sz * (_BASE_BADGE_FS / _BASE_BADGE_SZ)),
        empty_h      = math.max(16, math.floor(_BASE_EMPTY_H    * scale)),
        empty_fs     = math.max(7,  math.floor(_BASE_EMPTY_FS   * scale)),
    }
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------
local SETTINGS_KEY       = "simpleui_coll_list"
-- Below, SETTINGS_KEY is reused as the manual-arrangement order (see
-- getManualOrder/saveManualOrder) — its meaning changed with the opt-out
-- model (see the block after getRC()/listAllCollectionNames() below), but
-- the key itself stays the same for backward-compatible migration.
local EXCLUDED_KEY       = "simpleui_coll_excluded"
local SORT_KEY           = "simpleui_coll_sort_mode"
local COVER_OVERRIDE_KEY = "simpleui_coll_covers"
local BADGE_POSITION_KEY = "simpleui_coll_badge_position"
local BADGE_COLOR_KEY    = "simpleui_coll_badge_color"
local BADGE_HIDDEN_KEY   = "simpleui_coll_badge_hidden"
local BADGE_SCALE_KEY    = "simpleui_coll_badge_scale"
local COVER_STYLE_KEY    = "simpleui_coll_cover_style"
local HIDE_PILE_KEY      = "simpleui_coll_hide_spine"

local function getBadgePosition()
    return SUISettings:readSetting(BADGE_POSITION_KEY) or "top"
end
local function saveBadgePosition(v)
    SUISettings:saveSetting(BADGE_POSITION_KEY, v)
end

-- "dark"  = black background, white text, gray border.
-- "light" = white background, black text, gray border.
local function getBadgeColor()
    return SUISettings:readSetting(BADGE_COLOR_KEY) or "dark"
end
local function saveBadgeColor(v)
    SUISettings:saveSetting(BADGE_COLOR_KEY, v)
end

local function getBadgeHidden()
    return SUISettings:readSetting(BADGE_HIDDEN_KEY) or false
end
local function saveBadgeHidden(v)
    SUISettings:saveSetting(BADGE_HIDDEN_KEY, v)
end

-- Count badge SIZE — independent from this module's own Scale/Cover Size
-- (which also affect the badge via `cs` in getDims, see below) and from
-- every other module's badge size. It has its own key because the count
-- badge isn't part of the pages/series/new/progress family that
-- GridRenderer.getBadgeScale governs (see SUIStyle.BADGE_SIZE_ADJUST's doc
-- comment).
local function getBadgeScalePct() return Config.getScalePctByKey(BADGE_SCALE_KEY) end
-- Fixed +20% base-size boost, same idea and same value as
-- engines/sui_book_grid.lua's _BG_CORNER_BADGE_BASE_BOOST — not
-- user-adjustable, multiplies on top of whatever percent the user has
-- chosen in Badge Size above.
local _COLL_BADGE_BASE_BOOST = 1.2
local function getBadgeScale() return getBadgeScalePct() / 100 * _COLL_BADGE_BASE_BOOST end
local function saveBadgeScale(pct) Config.setScaleByKey(pct, BADGE_SCALE_KEY) end

-- "single" (default) = single cover of the first book — see getHidePile
--                       below, the book pile is an independent toggle, not
--                       tied to this style.
-- "quad"             = 2×2 grid with up to 4 covers from the collection.
-- "auto"             = resolved per collection below (see
--                       _resolveCoverStyleForCount): "single" up to 3 books,
--                       "quad" from 4 books upward — same threshold and
--                       naming convention as the library's Folder Cover Type
--                       "Auto" option (sui_foldercovers.lua's _resolveStyle).
local function getCoverStyle()
    local style = SUISettings:readSetting(COVER_STYLE_KEY)
    -- Persisted legacy id for "single".
    if style == "stack" then
        style = "single"
        SUISettings:saveSetting(COVER_STYLE_KEY, style)
    end
    return style or "single"
end
local function saveCoverStyle(v)
    SUISettings:saveSetting(COVER_STYLE_KEY, v)
end

-- Book pile (layers peeking out behind the cover/grid), shown by default.
-- Independent of Cover Style — applies the same way whether a given cell
-- resolves to "single" or "quad" (4-cover grid), mirroring the
-- library's own decoupling of "Folder Cover Type" from "Hide Folder Book
-- Stack" (sui_foldercovers.lua's getHidePile/setHidePile). This is what
-- lets Cover Style = Auto keep a uniform look — every cell either has the
-- pile or none does, regardless of which style it individually resolves to.
local function getHidePile()
    return SUISettings:readSetting(HIDE_PILE_KEY) or false
end
local function saveHidePile(v)
    SUISettings:saveSetting(HIDE_PILE_KEY, v)
end

-- Resolve the effective cover style for a collection with `count` books,
-- given the raw setting `raw_style`. Only "auto" needs resolving — "single"/
-- "quad" pass through unchanged. Mirrors the library's Folder Cover Type
-- "Auto" behaviour (quad from 4 books, single below that).
local function _resolveCoverStyleForCount(raw_style, count)
    if raw_style ~= "auto" then return raw_style end
    if count and count >= 4 then return "quad" end
    return "single"
end

local function getCoverOverrides()
    return SUISettings:readSetting(COVER_OVERRIDE_KEY) or {}
end
local function saveCoverOverrides(t)
    SUISettings:saveSetting(COVER_OVERRIDE_KEY, t)
end

-- ---------------------------------------------------------------------------
-- openCollectionCoverPicker — "Set cover" dialog for a single collection,
-- letting the person pick which book's cover represents it in Single style
-- (mirrors KOReader's own "set folder cover" long-press action for a
-- series). Shared by:
--   • extraMenuItemsAfter's collection checklist (long-press a row there)
--   • buildCollectionCell's homescreen long-press dialog, when "Long press
--     on cover" is set to "book_dialog" for this module (see
--     Config.getCoverHoldMode)
-- refresh_fn is called after a pick/reset so the caller can repaint
-- whatever it's showing (settings list or homescreen).
-- ---------------------------------------------------------------------------
local function openCollectionCoverPicker(coll_name, refresh_fn)
    local ok_rc, rc = pcall(require, "readcollection")
    if not (ok_rc and rc) then return end
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then
        UI.Notify.toast(_("Collection is empty."), 2); return
    end
    local fps = {}
    for fp in pairs(coll) do fps[#fps + 1] = fp end
    table.sort(fps)
    if #fps == 0 then
        UI.Notify.toast(_("Collection is empty."), 2); return
    end
    local overrides     = getCoverOverrides()
    local ButtonDialog  = require("ui/widget/buttondialog")
    local cover_buttons = {}
    local dlg
    cover_buttons[#cover_buttons + 1] = {{
        text     = (not overrides[coll_name] and "✓ " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(dlg)
            local t = getCoverOverrides(); t[coll_name] = nil; saveCoverOverrides(t)
            if refresh_fn then refresh_fn() end
        end,
    }}
    for _, fp in ipairs(fps) do
        local _fp   = fp
        local fname = fp:match("([^/]+)%.[^%.]+$") or fp
        local title = fname
        local ok_ds, ds = pcall(function() return require("docsettings"):open(_fp) end)
        if ok_ds and ds then
            local meta = ds:readSetting("doc_props") or {}
            title = meta.title or fname
        end
        cover_buttons[#cover_buttons + 1] = {{
            text     = ((overrides[coll_name] == _fp) and "✓ " or "  ") .. title,
            callback = function()
                UIManager:close(dlg)
                local t = getCoverOverrides(); t[coll_name] = _fp; saveCoverOverrides(t)
                if refresh_fn then refresh_fn() end
            end,
        }}
    end
    cover_buttons[#cover_buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(dlg) end,
    }}
    dlg = ButtonDialog:new{
        title   = string.format(_("Cover for \"%s\""), coll_name),
        buttons = cover_buttons,
    }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------------------
-- ReadCollection helpers
-- ---------------------------------------------------------------------------
local function getRC()
    local ok_rc, rc_or_err = pcall(require, "readcollection")
    if ok_rc and rc_or_err then return rc_or_err end
    return nil
end

-- listAllCollectionNames() -> { name, ... }
--
-- Every collection that currently exists: the "favorites"/default
-- collection first (if present), then the rest alphabetically, with an
-- empty TBR collection excluded. Single source of truth for "what
-- collections exist" — previously this exact listing logic was
-- duplicated almost verbatim in extraMenuItemsBefore and
-- extraMenuItemsAfter (both now call this instead); also used below by
-- getVisibleCollections (opt-out filtering) and the excluded-set migration.
local function listAllCollectionNames()
    local rc = getRC()
    local all_colls = {}
    if rc then
        local fav = rc.default_collection_name or "favorites"
        local coll_set = {}
        if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
        if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end
        if coll_set[fav] then
            all_colls[#all_colls + 1] = fav
            coll_set[fav] = nil
        end
        local others = {}
        for name in pairs(coll_set) do others[#others + 1] = name end
        table.sort(others, function(a, b) return a:lower() < b:lower() end)
        for _, n in ipairs(others) do all_colls[#all_colls + 1] = n end
    end
    local TBR = package.loaded["modules/module_tbr"]
    if TBR then
        local filtered = {}
        for _, n in ipairs(all_colls) do
            if n == TBR.TBR_COLL_NAME then
                if TBR.getTBRCount() > 0 then filtered[#filtered + 1] = n end
            else
                filtered[#filtered + 1] = n
            end
        end
        all_colls = filtered
    end
    return all_colls
end

local function displayNameFor(coll_name)
    local TBR = package.loaded["modules/module_tbr"]
    if TBR and coll_name == TBR.TBR_COLL_NAME then return TBR.getDisplayName() end
    return coll_name
end

-- ---------------------------------------------------------------------------
-- Collection selection — opt-OUT model.
--
-- Every collection that exists is shown by default, including ones
-- created after the module was first set up; the person removes what they
-- don't want ("Delete" on an item, in the Arrange screen or the classic
-- checklist) rather than hand-picking what to add. Three independent
-- pieces:
--   EXCLUDED_KEY — the set of collection names the person has explicitly
--                  hidden. This is the only thing that makes a collection
--                  NOT show up.
--   SETTINGS_KEY — reused as the MANUAL arrangement order (its meaning
--                  before this change was "the selected list" — see the
--                  migration in getExcludedCollections below). Only
--                  consulted when SORT_KEY == "manual".
--   SORT_KEY     — "manual" (default, drag-to-arrange order) |
--                  "alpha_asc" | "alpha_desc" (by display name).
-- ---------------------------------------------------------------------------
local function saveExcludedCollections(list)
    SUISettings:saveSetting(EXCLUDED_KEY, list)
end

-- getExcludedCollections() — see the model note above for the one-time
-- migration performed here the first time this is ever read.
local function getExcludedCollections()
    local raw = SUISettings:readSetting(EXCLUDED_KEY)
    if raw ~= nil then return raw end

    local legacy_selection = SUISettings:readSetting(SETTINGS_KEY)
    if legacy_selection == nil then
        -- Brand-new module instance: nothing hidden yet, everything shows.
        saveExcludedCollections({})
        return {}
    end

    -- Upgrading from the old "selected list" model (hand-picked by the
    -- person, or auto-seeded by an earlier version of this module):
    -- anything NOT already in that list becomes excluded, so upgrading
    -- doesn't silently change what's currently shown. legacy_selection is
    -- left untouched in SETTINGS_KEY and doubles from here on as the
    -- initial manual arrangement order (getManualOrder) — it's already a
    -- valid order for exactly those collections.
    local all = listAllCollectionNames()
    if #all == 0 and not getRC() then
        -- ReadCollection isn't available yet (queried before KOReader's
        -- own collections subsystem finished loading) — don't lock in a
        -- migration derived from an empty list; retry on the next call.
        return {}
    end
    local selected_set = {}
    for _, n in ipairs(legacy_selection) do selected_set[n] = true end
    local excluded = {}
    for _, n in ipairs(all) do
        if not selected_set[n] then excluded[#excluded + 1] = n end
    end
    saveExcludedCollections(excluded)
    return excluded
end

local function hideCollection(coll_name)
    local excluded = getExcludedCollections()
    for _, n in ipairs(excluded) do if n == coll_name then return end end
    excluded[#excluded + 1] = coll_name
    saveExcludedCollections(excluded)
end

local function unhideCollection(coll_name)
    local excluded = getExcludedCollections()
    local new_excluded = {}
    for _, n in ipairs(excluded) do
        if n ~= coll_name then new_excluded[#new_excluded + 1] = n end
    end
    saveExcludedCollections(new_excluded)
end

local function getManualOrder()
    return SUISettings:readSetting(SETTINGS_KEY) or {}
end
local function saveManualOrder(list)
    SUISettings:saveSetting(SETTINGS_KEY, list)
end

local DEFAULT_SORT_MODE = "manual"
local function getSortMode()
    return SUISettings:readSetting(SORT_KEY) or DEFAULT_SORT_MODE
end
local function saveSortMode(mode)
    SUISettings:saveSetting(SORT_KEY, mode)
end

-- Labels for the "Sort" menu (extraMenuItemsAfter) — "Manual order" makes
-- the persisted drag-arrangement (getManualOrder) take effect; the two
-- alphabetical modes ignore it entirely (see getVisibleCollections).
local SORT_MODE_LABELS = {
    manual     = _("Manual order"),
    alpha_asc  = _("Name (A–Z)"),
    alpha_desc = _("Name (Z–A)"),
}
local SORT_MODE_ORDER = { "manual", "alpha_asc", "alpha_desc" }

-- _orderCollections(names) — applies the current sort mode to an arbitrary
-- list of collection names. Shared by getVisibleCollections (excluded ones
-- filtered out first) and getAllCollectionsOrdered (nothing filtered, used
-- by the Arrange screen so hidden collections keep a stable position
-- instead of jumping around as they're toggled).
local function _orderCollections(names)
    local mode = getSortMode()
    if mode == "alpha_asc" or mode == "alpha_desc" then
        local sorted = {}
        for _, n in ipairs(names) do sorted[#sorted + 1] = n end
        table.sort(sorted, function(a, b)
            local da, db = displayNameFor(a):lower(), displayNameFor(b):lower()
            if mode == "alpha_desc" then return da > db end
            return da < db
        end)
        return sorted
    end

    -- "manual": known items in their persisted arrangement order; anything
    -- not yet in that order (freshly created collections, or the very
    -- first read before any manual drag) appended in `names`'s natural
    -- order (favorites-first, then alphabetical by internal name).
    local order = getManualOrder()
    local pos = {}
    for i, n in ipairs(order) do pos[n] = i end
    local known, new_ones = {}, {}
    for _, n in ipairs(names) do
        if pos[n] then known[#known + 1] = n else new_ones[#new_ones + 1] = n end
    end
    table.sort(known, function(a, b) return pos[a] < pos[b] end)
    local ordered = {}
    for _, n in ipairs(known)    do ordered[#ordered + 1] = n end
    for _, n in ipairs(new_ones) do ordered[#ordered + 1] = n end
    return ordered
end

-- getVisibleCollections() — every existing collection minus the excluded
-- ones, ordered according to the current sort mode. This is what the grid
-- (getFileList) and the classic checklist read.
local function getVisibleCollections()
    local all = listAllCollectionNames()
    local excluded_set = {}
    for _, n in ipairs(getExcludedCollections()) do excluded_set[n] = true end
    local visible = {}
    for _, n in ipairs(all) do
        if not excluded_set[n] then visible[#visible + 1] = n end
    end
    return _orderCollections(visible)
end

-- getAllCollectionsOrdered() — every existing collection, hidden ones
-- included, in the same order getVisibleCollections would use if nothing
-- were excluded. Used by the SUI Arrange screen, which shows hidden
-- collections dimmed in place rather than dropping them from the list.
local function getAllCollectionsOrdered()
    return _orderCollections(listAllCollectionNames())
end

local function getCollectionFilesFromRC(rc, coll_name)
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    local entries = {}
    local i = 1
    for fp, info in pairs(coll) do
        entries[i] = { filepath = fp, order = (type(info) == "table" and info.order) or 9999 }
        i = i + 1
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    local files = {}
    for j = 1, #entries do files[j] = entries[j].filepath end
    return files
end

-- Convenience wrapper for call sites that only have the collection name, not
-- an already-fetched file list (e.g. the checklist's hold_callback below).
-- buildCollectionCell fetches its own file list anyway, so it calls
-- _resolveCoverStyleForCount directly instead of going through this.
local function _resolveCoverStyleFor(coll_name)
    local raw_style = getCoverStyle()
    if raw_style ~= "auto" then return raw_style end
    local rc    = getRC()
    local files = rc and getCollectionFilesFromRC(rc, coll_name) or {}
    return _resolveCoverStyleForCount(raw_style, #files)
end

-- ---------------------------------------------------------------------------
-- Cover loading — Single style only (fixed 3:2, stretch, no crop).
-- Quad style has its own loader further down (buildQuadCell), backed by
-- Config.getCroppedCoverBB instead: Quad crops to ~1:1 by design (2x2 collage,
-- every quadrant must fill its box with no gaps), so it can't share this
-- cache — see infra/sui_cover_cache.lua's header comment for why the two
-- shapes can't collapse into one.
-- ---------------------------------------------------------------------------
local function getSingleBookCover(filepath, w, h)
    local bb = Config.getStretchedCoverBB(filepath, w, h)
    if not bb then return nil end
    local ok, img = pcall(function()
        return ImageWidget:new{
            image            = bb,
            image_disposable = false,  -- bb is owned by the cover cache; must not be freed here
            width            = w,
            height           = h,
            -- bb may be larger than w x h (shared, session-max-sized cache
            -- entry) — no scale_factor, so ImageWidget downscales to w x h
            -- at paint time. Same reasoning as SH.getBookCover in
            -- modules/module_books_shared.lua.
        }
    end)
    return ok and img or nil
end

-- ---------------------------------------------------------------------------
-- Cover card + book pile + count badge — shared between Single and Quad.
-- `content` is the cover/grid widget (outer size coll_w × coll_h), without accent or
-- badge. The accent bar joins it to form the front card; the pile sits
-- behind that card and the badge floats over it. Returns the final widget
-- (cell_w × cell_h) ready to carry only the label underneath.
-- ---------------------------------------------------------------------------
local function wrapAccentAndBadge(content, count, d, accent_color)
    local accent = LineWidget:new{
        background = accent_color or SUIStyle.COLOR.text_primary,
        dimen      = Geom:new{ w = d.coll_w, h = d.accent_h },
    }
    local card_h = d.coll_h + d.accent_h

    local group = OverlapGroup:new{ dimen = Geom:new{ w = d.cell_w, h = d.cell_h } }
    local backing = CoverWidgets.buildBacking(d.coll_w, card_h, d.pile, d.hide_pile)
    if backing then group[#group + 1] = backing end
    group[#group + 1] = VerticalGroup:new{ align = "left", content, accent }

    if getBadgeHidden() then return group end

    local dark      = getBadgeColor() == "dark"
    local bg_color  = dark and SUIStyle.COLOR.text_primary or SUIStyle.COLOR.surface
    local fg_color  = dark and SUIStyle.COLOR.surface or SUIStyle.COLOR.text_primary

    local badge_tw = UI.makeColoredText{
        text    = tostring(math.min(count, 99)),
        face    = Font:getFace(SUIStyle.FACE_REGULAR, d.badge_fs),
        fgcolor = fg_color,
        bold    = true,
    }
    local _orig_pt = badge_tw.paintTo
    badge_tw.paintTo = function(self, bb, x, y)
        _orig_pt(self, bb, x, y + 1) -- HACK: change this +1 to +2 or +3 depending on your font
    end

    local badge_inner = CenterContainer:new{
        dimen = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        badge_tw,
    }
    local badge = FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ,
        color      = SUIStyle.BADGE_BORDER_CLR,
        background = bg_color,
        radius     = math.floor(d.badge_sz / 2),
        padding    = 0,
        dimen      = Geom:new{ w = d.badge_sz, h = d.badge_sz },
        badge_inner,
    }
    badge.overlap_offset = {
        d.coll_w - d.badge_sz - d.badge_margin,
        getBadgePosition() == "bottom"
            and (card_h - d.badge_sz - d.badge_margin_t)
            or  d.badge_margin_t,
    }
    group[#group + 1] = badge
    return group
end

-- ---------------------------------------------------------------------------
-- Cover cell — Single (one cover, optional pile — see wrapAccentAndBadge)
-- ---------------------------------------------------------------------------
local function buildSingleCell(files, cover_override, coll_name, count, d, accent_color)
    local front_fp = cover_override
    if front_fp and lfs.attributes(front_fp, "mode") ~= "file" then front_fp = nil end
    if not front_fp and #files > 0 then front_fp = files[1] end

    -- Main cover (or placeholder).
    local cover
    if front_fp and lfs.attributes(front_fp, "mode") == "file" then
        local raw = getSingleBookCover(front_fp, d.img_w, d.img_h)
        if raw then
            cover = FrameContainer:new{
                bordersize = d.border, color = SUIStyle.COLOR.text_primary,
                padding    = 0, margin = 0,
                raw,
            }
        end
    end
    if not cover then
        cover = FrameContainer:new{
            bordersize = d.border, color = SUIStyle.COLOR.text_primary,
            background = SUIStyle.COLOR.gray_strong, padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = d.img_w, h = d.img_h },
                TextWidget:new{
                    text = (coll_name or "?"):sub(1, 2):upper(),
                    face = Font:getFace(SUIStyle.FACE_REGULAR, d.ph_cover_fs),
                },
            },
        }
    end

    -- Single-slot container: updateCovers swaps the loaded cover in at idx 1.
    local content = HorizontalGroup:new{ align = "top", cover }

    local widget = wrapAccentAndBadge(content, count, d, accent_color)

    -- cover_slots for updateCovers. Only registered if there is a real fp
    -- to reload.
    local cover_slots = nil
    if front_fp then
        cover_slots = {
            { kind = "single", container = content, idx = 1, fp = front_fp, w = d.img_w, h = d.img_h },
        }
    end

    return widget, cover_slots
end

-- ---------------------------------------------------------------------------
-- Cover cell — Quad (2×2 grid with up to 4 covers, optional pile — see
-- wrapAccentAndBadge)
-- ---------------------------------------------------------------------------
local function buildQuadCell(files, count, d, accent_color)
    local half_w, half_h, half_w2, half_h2 = CoverWidgets.computeQuadCellSizes(d.img_w, d.img_h)
    local sizes = { { half_w, half_h }, { half_w2, half_h }, { half_w, half_h2 }, { half_w2, half_h2 } }

    local img_list = {}
    for i = 1, 4 do
        local fp = files[i]
        if fp then
            local bb = Config.getCroppedCoverBB(fp, sizes[i][1], sizes[i][2])
            if bb then img_list[i] = { data = bb } end
        end
    end

    local grid, cells = CoverWidgets.buildQuadGrid(img_list, d.img_w, d.img_h, d.border)

    local widget = wrapAccentAndBadge(grid, count, d, accent_color)

    -- cover_slots: only for quadrants that FAILED to load immediately
    -- (fp present but Config.getCroppedCoverBB returned nil — extraction still
    -- pending). Quadrants already loaded successfully are not re-registered:
    -- the reference cache backing getCroppedCoverBB (see infra/sui_config.lua)
    -- is global and byte-budgeted, shared across every Quad collection —
    -- Quad already uses up to 4 entries per collection (vs 1 in Single), so
    -- reducing redundant requests per updateCovers poll relieves that
    -- pressure quite a bit.
    local cover_slots = {}
    for i = 1, 4 do
        local fp = files[i]
        if fp and not img_list[i] then
            cover_slots[#cover_slots + 1] = {
                kind = "quad", container = cells[i], idx = 1,
                fp = fp, w = sizes[i][1], h = sizes[i][2],
            }
        end
    end
    if #cover_slots == 0 then cover_slots = nil end

    return widget, cover_slots
end

-- ---------------------------------------------------------------------------
-- openCollection
-- ---------------------------------------------------------------------------

-- Returns the topmost live ScreenWidget instance on the UIManager window
-- stack, whichever screen it actually is: the built-in Homescreen or a
-- Custom Screen. Every ScreenWidget instance shares name == "homescreen"
-- (see engines/sui_screen_engine.lua's ScreenWidget:init()) regardless of
-- its underlying self._id, which is exactly the same "read the identity off
-- the widget itself" pattern _bottombarActionIdFor() uses in that file. Generic
-- replacement for looking the built-in Homescreen up by its flat
-- ScreenEngine._instance field, which is only ever populated for id == "hs"
-- and silently misses every Custom Screen.
local function _liveScreenWidget()
    local stack = UI.getWindowStack()
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.name == "homescreen" then return w end
    end
    return nil
end

-- Reopens whichever screen `id` refers to. screens/sui_homescreen.lua
-- mutates the same table returned by engines/sui_screen_engine.lua (see
-- that file's header), so a single require exposes both .show() (built-in
-- Homescreen) and .showCustomScreen(id) (Custom Screens).
local function _reopenScreen(id)
    local ok, ScreenEngine = pcall(require, "screens/sui_homescreen")
    if not ok or not ScreenEngine then return end
    if id == "hs" then
        ScreenEngine.show()
    elseif ScreenEngine.showCustomScreen then
        ScreenEngine.showCustomScreen(id)
    end
end

local function openCollection(coll_name)
    -- patchUIManagerShow (patches.lua) automatically closes any homescreen widget
    -- when a covers_fullscreen widget is shown — so we must NOT call close_fn here.
    -- Calling it would produce a double-close and run onCloseWidget twice.
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FM or not FM.instance then return end
    local fm = FM.instance

    -- Preserve the current screen's current page across that auto-close —
    -- built-in Homescreen or a Custom Screen, whichever is actually open.
    -- Without this, ScreenWidget:onCloseWidget treats it as an unexpected
    -- close and discards its cached state — the same "intentional close"
    -- idiom used for tab navigation (see sui_bottombar.lua).
    local screen_inst = _liveScreenWidget()
    local screen_id    = screen_inst and screen_inst._id
    if screen_inst then screen_inst._navbar_closing_intentionally = true end

    if fm.collections and type(fm.collections.onShowColl) == "function" then
        pcall(function() fm.collections:onShowColl(coll_name) end)
    elseif fm.collections and type(fm.collections.onShowCollList) == "function" then
        pcall(function() fm.collections:onShowCollList() end)
    end

    if screen_inst then screen_inst._navbar_closing_intentionally = nil end

    -- Back button: KOReader's own onShowColl wires "back" (onReturn) to
    -- self:onShowCollList() — the list of ALL collections. That makes sense
    -- when entering from FM's own Collections icon (there was no screen
    -- page to return to), but not from here: the person came from a
    -- specific screen page — built-in Homescreen or a Custom Screen — and
    -- expects "back" to land them right back on it. Override it on THIS
    -- booklist_menu instance only — collections opened any other way keep
    -- the native behaviour untouched.
    local bm = fm.collections and fm.collections.booklist_menu
    if bm and screen_id then
        bm.onReturn = function()
            bm.close_callback()
            _reopenScreen(screen_id)
        end
    end
end

-- ---------------------------------------------------------------------------
-- getFileList(ctx) — visible collections, per the opt-out model above.
--
-- No self-heal/stale-name filtering needed here anymore: getVisibleCollections()
-- is already built from listAllCollectionNames(), which reads rc.coll/
-- rc.coll_folders directly — a renamed or deleted collection simply can't
-- appear in it, and an empty TBR is already excluded there too. Called
-- once per build() (GridRenderer caches the result in ctx), same as for
-- the other grid modules.
-- ---------------------------------------------------------------------------
local function getFileList(_ctx)
    return getVisibleCollections()
end

-- ---------------------------------------------------------------------------
-- getCellHeight(cw, pfx) — mirrors coll_cell_h. Must return exactly
-- the same value that buildCollectionCell uses to size the widget it
-- returns (see the twin note in sui_book_grid.lua).
--
-- Under "auto", different collections on the same screen can resolve to
-- different Cover Styles (some "single", some "quad") depending on their own
-- book count, but the grid still needs one uniform row height. Since the
-- pile is independent of Cover Style (see getDims/getHidePile), coll_cell_h
-- does not depend on the resolved style at all — only on hide_pile, which
-- is the same for every cell on the screen — so a single getDims call is
-- always correct here, "auto" or not.
-- ---------------------------------------------------------------------------
local function collectionsCellHeight(cw, pfx)
    -- No ctx here (see opts.getCellHeight's contract in sui_book_grid.lua),
    -- so the landscape factor is computed directly.
    local lf          = UI.isLandscape() and UI.getLandscapeFactor() or 1
    local scale       = Config.getModuleScale("collections", pfx) * lf
    local thumb_scale = Config.getThumbScale("collections", pfx) * lf
    local styles      = Config.resolveTextStyles({ pfx = pfx }, "collections", { "label" })
    local lbl_scale   = (styles.label and styles.label.scale) or 1
    local d = getDims(scale, thumb_scale, lbl_scale, cw, getHidePile())
    return d.coll_cell_h
end

-- ---------------------------------------------------------------------------
-- renderCell(coll_name, cw, cell_h, ctx) — complete cell (cover+accent+
-- badge+label+tap), passed to GridRenderer via spec.renderCell.
-- ---------------------------------------------------------------------------
local function buildCollectionCell(coll_name, cw, cell_h, ctx)
    local pfx         = ctx.pfx
    local lf          = ctx.landscape_factor or 1
    local scale       = Config.getModuleScale("collections", pfx) * lf
    local thumb_scale = Config.getThumbScale("collections", pfx) * lf
    local styles      = Config.resolveTextStyles({ pfx = pfx }, "collections", { "label" })
    local lbl_scale   = (styles.label and styles.label.scale) or 1
    local rc      = getRC()
    local files    = rc and getCollectionFilesFromRC(rc, coll_name) or {}
    local count    = #files
    local overrides = getCoverOverrides()

    -- Resolve "auto" per collection now that its book count is known — see
    -- _resolveCoverStyleForCount. "single"/"quad" pass through unchanged.
    -- The pile is independent of style (see getDims/getHidePile) — passed
    -- separately so it stays uniform across every cell on screen.
    local style = _resolveCoverStyleForCount(getCoverStyle(), count)
    local d     = getDims(scale, thumb_scale, lbl_scale, cw, getHidePile(), getBadgeScale())

    local CLR_TEXT_SUB_EFF = CLR_TEXT_SUB
    local CLR_ACCENT_EFF   = SUIStyle.COLOR.text_primary

    local cover_widget, cover_slots
    if style == "quad" then
        cover_widget, cover_slots = buildQuadCell(files, count, d, CLR_ACCENT_EFF)
    else
        cover_widget, cover_slots = buildSingleCell(files, overrides[coll_name], coll_name, count, d, CLR_ACCENT_EFF)
    end

    local display_name = coll_name
    local TBR = package.loaded["modules/module_tbr"]
    if TBR and coll_name == TBR.TBR_COLL_NAME then
        display_name = TBR.getDisplayName()
    end

    -- Single-line label capped to cover width (same truncation pattern as
    -- GridRenderer / Recent progress labels).
    local label_face, label_bold = SUIStyle.getTextFace(styles.label, d.coll_lbl_fs)
    local label_w = UI.makeColoredText{
        text                   = display_name,
        face                   = label_face,
        bold                   = label_bold,
        fgcolor                = CLR_TEXT_SUB_EFF,
        max_width              = d.coll_w,
        truncate_with_ellipsis = true,
        alignment              = "center",
    }

    -- Centered under the front card, not under cell_w, which also
    -- includes the pile: a trailing span of the pile's width offsets it.
    local label_aligned = HorizontalGroup:new{
        label_w,
        HorizontalSpan:new{ width = d.pile },
    }

    local cell_vg = VerticalGroup:new{
        align = "center",
        cover_widget,
        VerticalSpan:new{ width = d.label_gap },
        label_aligned,
    }

    local tappable = InputContainer:new{
        dimen      = Geom:new{ w = d.cell_w, h = cell_h },
        [1]        = cell_vg,
        _coll_name = coll_name,
    }
    tappable.ges_events = {
        TapColl = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapColl()
        openCollection(self._coll_name)
        return true
    end

    -- Long-press → collection-level actions, NOT the per-book dialog: a
    -- collection cell represents many books, so "hold on the cover" mirrors
    -- KOReader's own long-press on a series folder (pick which book's cover
    -- represents it) rather than opening a single book's actions. In Single
    -- style that's exactly openCollectionCoverPicker (same dialog already
    -- used from the module's own "Manage collections" settings list); Quad
    -- style has no single front cover to reassign, so only "Open Module
    -- Settings" is offered there. Gated the same way as every other
    -- cover-bearing module (Config.getCoverHoldMode) — this now runs by
    -- default; picking "Module Settings" instead is what leaves this
    -- untouched (falls through to the module wrapper's HoldMod/HoldModRelease).
    if Config.getCoverHoldMode("collections", pfx) == "book_dialog" then
        tappable.ges_events.HoldColl = {
            GestureRange:new{ ges = "hold", range = function() return tappable.dimen end },
        }
        tappable.ges_events.HoldCollRelease = {
            GestureRange:new{ ges = "hold_release", range = function() return tappable.dimen end },
        }
        function tappable:onHoldColl() return true end
        function tappable:onHoldCollRelease()
            local ButtonDialog = require("ui/widget/buttondialog")
            local menu_dialog
            local menu_buttons = {}
            if style == "single" then
                menu_buttons[#menu_buttons + 1] = {{
                    text     = _("Set collection cover"),
                    callback = function()
                        UIManager:close(menu_dialog)
                        openCollectionCoverPicker(coll_name, ctx.refresh_fn)
                    end,
                }}
            end
            menu_buttons[#menu_buttons + 1] = {{
                text     = _("Open Module Settings"),
                callback = function()
                    UIManager:close(menu_dialog)
                    if ctx.open_settings_fn then ctx.open_settings_fn("collections") end
                end,
            }}
            menu_dialog = ButtonDialog:new{
                title       = coll_name,
                title_align = "center",
                buttons     = menu_buttons,
                dismissable = true,
            }
            UIManager:show(menu_dialog)
            return true
        end
    end

    return tappable, cover_slots
end

-- ---------------------------------------------------------------------------
-- updateCovers — handles the two cover_slots types (single/quad). Passed to
-- GridRenderer via spec.updateCovers (replaces the generic
-- GridRenderer.updateCovers because Quad mode needs ImageWidgets with no
-- border of their own, unlike the bordered FrameContainer that SH.getBookCover returns).
-- ---------------------------------------------------------------------------
local function collectionsUpdateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        -- Dispatch to the matching cache by shape family: single slots are
        -- fixed 3:2 stretch-only (infra/sui_cover_cache.lua), quad slots
        -- crop to ~1:1 (see infra/sui_config.lua's getCroppedCoverBB) — same
        -- split as buildSingleCell/buildQuadCell above.
        local bb = (slot.kind == "quad")
            and Config.getCroppedCoverBB(slot.fp, slot.w, slot.h)
            or Config.getStretchedCoverBB(slot.fp, slot.w, slot.h)
        if bb then
            local ok, img = pcall(function()
                return ImageWidget:new{
                    image            = bb,
                    image_disposable = false,
                    width            = slot.w,
                    height           = slot.h,
                    -- Quad's bb is always already exactly slot.w x slot.h
                    -- (getCroppedCoverBB's contract, unchanged). Single's bb
                    -- may be larger (shared, session-max-sized entry) — no
                    -- scale_factor for either case: a no-op blit when
                    -- sizes already match, a plain downscale otherwise.
                }
            end)
            if ok and img then
                if slot.kind == "quad" then
                    slot.container[slot.idx] = img
                else
                    slot.container[slot.idx] = FrameContainer:new{
                        bordersize = SUIStyle.BADGE_BORDER_SZ, color = SUIStyle.COLOR.text_primary,
                        padding    = 0, margin = 0,
                        img,
                    }
                end
            end
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- ---------------------------------------------------------------------------
-- extra_menu_items_before — the "Collections" row (selection + arrangement, no
-- item limit) and, in SUI mode, the Arrange screen it opens, which lists
-- every collection (hidden ones dimmed, with a show/hide eye toggle).
-- ---------------------------------------------------------------------------
local function extraMenuItemsBefore(ctx_menu)
    local _UIManager  = ctx_menu.UIManager
    local SortWidget  = ctx_menu.SortWidget
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._

    local items = {}
    items[#items + 1] = {
        text = _lc("Collections"), keep_menu_open = true,
        callback = function()
            local cur_sel = getVisibleCollections()
            if #cur_sel < 2 then
                UI.Notify.toast(_lc("Select at least 2 collections to arrange."), 2)
                return
            end
            local sort_items = {}
            for _loop_, n in ipairs(cur_sel) do
                sort_items[#sort_items + 1] = { text = displayNameFor(n), orig_item = n }
            end
            local function on_save()
                local new_order = {}
                for _loop_, item in ipairs(sort_items) do
                    new_order[#new_order + 1] = item.orig_item
                end
                saveManualOrder(new_order); refresh()
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Collections"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = on_save,
            })
        end,
        sui_build = ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("engines/sui_window")
            return SUIWindow.ListRow{
                title        = _lc("Collections"),
                subtitle     = function()
                    local cur_sel = getVisibleCollections()
                    if #cur_sel == 0 then return _lc("No items selected.") end
                    local names = {}
                    for _, n in ipairs(cur_sel) do names[#names + 1] = displayNameFor(n) end
                    return table.concat(names, "  ·  ")
                end,
                inner_w      = ctx.inner_w,
                item_count   = function() return #getVisibleCollections() end,
                show_chevron = true,
                on_tap       = function()
                    -- Every collection is listed here, hidden ones included.
                    -- A hidden row stays in place, dimmed, with a "show" eye
                    -- icon; a visible row shows the "hide" eye icon. Tapping
                    -- the icon toggles excluded/included without touching
                    -- the row's position. Drag-arranging still reorders
                    -- everyone, hidden or not — keeping a hidden collection
                    -- in the persisted order is harmless, since
                    -- getVisibleCollections filters it out regardless of
                    -- its position (see the model note above hideCollection).
                    local excluded_set = {}
                    for _, n in ipairs(getExcludedCollections()) do excluded_set[n] = true end

                    local sort_items = {}
                    for _, n in ipairs(getAllCollectionsOrdered()) do
                        local _n   = n
                        local item = {
                            text        = displayNameFor(_n),
                            orig_item   = _n,
                            dim_row     = excluded_set[_n] or nil,
                            -- The eye glyph reflects current state, not the
                            -- tap action: open eye ("show") while visible,
                            -- eye-off ("hide") once excluded.
                            toggle_icon = excluded_set[_n] and "hide" or "show",
                        }
                        item.on_toggle = function()
                            if excluded_set[_n] then
                                unhideCollection(_n)
                                excluded_set[_n] = nil
                            else
                                hideCollection(_n)
                                excluded_set[_n] = true
                            end
                            item.dim_row     = excluded_set[_n] or nil
                            item.toggle_icon = excluded_set[_n] and "hide" or "show"
                            refresh()
                            ctx.repaint()
                        end
                        sort_items[#sort_items + 1] = item
                    end

                    ctx.push("arrange", {
                        title      = _lc("Collections"),
                        items      = sort_items,
                        empty_text = _lc("No collections found."),
                        on_change  = function(items_to_save)
                            local new_order = {}
                            for _, it in ipairs(items_to_save) do new_order[#new_order + 1] = it.orig_item end
                            saveManualOrder(new_order)
                            refresh()
                        end,
                    })
                end
            }
        end or nil,
    }
    return items
end

-- ---------------------------------------------------------------------------
-- extra_menu_items_after — Cover Style, Badge, and the checklist of available
-- collections (no limit).
-- ---------------------------------------------------------------------------
local function extraMenuItemsAfter(ctx_menu)
    local _UIManager  = ctx_menu.UIManager
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._
    local N_lc        = ctx_menu.N_

    local all_colls = listAllCollectionNames()

    local function openCoverPicker(coll_name)
        openCollectionCoverPicker(coll_name, refresh)
    end

    local items = {}

    items[#items + 1] = {
        -- Title stays static — the chosen mode is surfaced only via
        -- mandatory_func (native Menu's right-side value) / SUIWindow's
        -- automatic right_value inference from the checked radio child
        -- below (see the "Row title vs. right-side value" note in
        -- engines/sui_window.lua's SUIWindow.MenuTable doc block). It must
        -- never be baked into the row's own text/text_func.
        text_func = function() return _lc("Sort") end,
        mandatory_func = function()
            return SORT_MODE_LABELS[getSortMode()] or SORT_MODE_LABELS[DEFAULT_SORT_MODE]
        end,
        separator      = true,
        sub_item_table_func = function()
            local sub = {}
            for _, mode in ipairs(SORT_MODE_ORDER) do
                local _m = mode
                sub[#sub + 1] = {
                    text           = SORT_MODE_LABELS[_m],
                    radio          = true,
                    checked_func   = function() return getSortMode() == _m end,
                    keep_menu_open = true,
                    callback       = function() saveSortMode(_m); refresh() end,
                }
            end
            return sub
        end,
    }

    items[#items + 1] = {
        text         = _lc("Cover Style"),
        sub_item_table = {
            {
                -- Same text as the library's Folder Cover Type "Single Cover".
                text           = _lc("Single Cover"),
                radio          = true,
                checked_func   = function() return getCoverStyle() == "single" end,
                keep_menu_open = true,
                callback       = function() saveCoverStyle("single"); refresh() end,
            },
            {
                -- Same text as the library's Folder Cover Type "4-Cover Grid
                -- (Mosaic View Only)", minus the Mosaic-only caveat — Collections
                -- has no separate List view, so it doesn't apply here.
                text           = _lc("4-Cover Grid"),
                radio          = true,
                checked_func   = function() return getCoverStyle() == "quad" end,
                keep_menu_open = true,
                callback       = function() saveCoverStyle("quad"); refresh() end,
            },
            {
                -- Same naming convention as the library's Folder Cover Type
                -- "Auto (Single ↔ 4-Cover Grid)" — see sui_menu.lua.
                text           = _lc("Auto (Single ↔ 4-Cover Grid)"),
                radio          = true,
                checked_func   = function() return getCoverStyle() == "auto" end,
                keep_menu_open = true,
                callback       = function() saveCoverStyle("auto"); refresh() end,
            },
        },
    }

    items[#items + 1] = {
        -- Independent of Cover Style — see getHidePile. Same text/behaviour
        -- as the library's "Hide Folder Book Stack" (sui_menu.lua), applied
        -- here to whichever style each collection resolves to (Single or
        -- 4-Cover Grid), so Auto stays visually uniform across cells.
        text           = _lc("Hide Book Stack"),
        separator      = true,
        checked_func   = function() return getHidePile() end,
        keep_menu_open = true,
        callback       = function() saveHidePile(not getHidePile()); refresh() end,
    }

    items[#items + 1] = {
        text         = _lc("Badge"),
        sub_item_table = {
            {
                text           = _lc("Hidden"),
                checked_func   = function() return getBadgeHidden() end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    saveBadgeHidden(not getBadgeHidden())
                    refresh()
                end,
            },
            {
                text           = _lc("Top"),
                radio          = true,
                checked_func   = function() return not getBadgeHidden() and getBadgePosition() == "top" end,
                enabled_func   = function() return not getBadgeHidden() end,
                keep_menu_open = true,
                callback       = function() saveBadgePosition("top"); refresh() end,
            },
            {
                text           = _lc("Bottom"),
                radio          = true,
                checked_func   = function() return not getBadgeHidden() and getBadgePosition() == "bottom" end,
                enabled_func   = function() return not getBadgeHidden() end,
                keep_menu_open = true,
                separator      = true,
                callback       = function() saveBadgePosition("bottom"); refresh() end,
            },
            {
                text           = _lc("Dark"),
                radio          = true,
                checked_func   = function() return getBadgeColor() == "dark" end,
                keep_menu_open = true,
                callback       = function() saveBadgeColor("dark"); refresh() end,
            },
            {
                text           = _lc("Light"),
                radio          = true,
                checked_func   = function() return getBadgeColor() == "light" end,
                keep_menu_open = true,
                callback       = function() saveBadgeColor("light"); refresh() end,
            },
            Config.makeBadgeSizeItem{
                separator    = true,
                enabled_func = function() return not getBadgeHidden() end,
                info         = _lc("Scale for the collection count badge."),
                get          = getBadgeScalePct,
                set          = saveBadgeScale,
                refresh      = refresh,
                _lc          = _lc,
            },
        },
    }

    if #all_colls == 0 then
        items[#items + 1] = { text = _lc("No collections found."), enabled = false }
    else
        for _loop_, coll_name in ipairs(all_colls) do
            local _n = coll_name
            local _display_n = displayNameFor(_n)
            items[#items + 1] = {
                text = _display_n,
                checked_func = function()
                    for _loop_, n in ipairs(getExcludedCollections()) do
                        if n == _n then return false end
                    end
                    return true
                end,
                keep_menu_open = true,
                callback       = function()
                    local is_hidden = false
                    for _loop_, n in ipairs(getExcludedCollections()) do
                        if n == _n then is_hidden = true break end
                    end
                    if is_hidden then unhideCollection(_n) else hideCollection(_n) end
                    refresh()
                end,
                hold_callback = (_resolveCoverStyleFor(_n) == "single") and function() openCoverPicker(_n) end or nil,
                sui_hidden = ctx_menu.is_sui or nil,
            }
        end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Module — built via GridRenderer.makeModule, just like Recent/New
-- Books/TBR/Featured Collection. See the notes at the top of the file about the
-- renderCell/getCellHeight hooks that make this possible for a cell
-- that isn't a "book cover".
-- ---------------------------------------------------------------------------
local mod = GridRenderer.makeModule{
    id          = "collections",
    name        = _("Collections"),
    label       = _("Collections"),
    text_label  = _("Label"),
    default_on  = false,
    is_book_mod = true,   -- needed for the surgical repaint of the swipe between pages
    max_items   = MAX_ITEMS,
    paged       = true,   -- no limit on selectable collections — paginates like Featured Collection
    -- Each cell is a COLLECTION, not a book — "Long press on cover" here
    -- opens "set collection cover" + "module settings", not the
    -- book-actions dialog (see hold handling in buildCollectionCell).
    hold_dialog_label = _("Collection Menu"),

    getFileList = function(ctx) return getFileList(ctx) end,

    renderCell    = buildCollectionCell,
    getCellHeight = collectionsCellHeight,
    updateCovers  = collectionsUpdateCovers,

    -- Progress/Text/Overlay/Badges don't make sense for a collection cell
    -- (there's no "% read" for a collection). engines/sui_book_grid.lua's
    -- getMenuItems already skips the whole Progress Style/Badges section
    -- for any module with a custom renderCell like this one — this lock is
    -- just belt-and-suspenders for GridRenderer.getHeight, which still
    -- reads progress_style even when renderCell/getCellHeight replace the
    -- rest of the cell (see the note there for why they must stay in sync).
    progress_style = { locked = "none" },

    -- Configurable grid (Rows 1-3 × Columns 4-5) + swipe pagination,
    -- just like Featured Collection.
    grid          = true,
    default_rows  = 1,
    default_cols  = MAX_ITEMS,

    extra_menu_items_before = extraMenuItemsBefore,
    extra_menu_items_after  = extraMenuItemsAfter,
}

-- "Not configured yet" notice when no collections are selected — same
-- pattern as module_feat_coll.lua: GridRenderer.build returns nil when the
-- list is empty, we replace it with a centered message the size of
-- mod.getHeight(ctx).
local orig_build = mod.build
function mod.build(w, ctx)
    local widget = orig_build(w, ctx)
    if widget then return widget end

    local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
    local ph_text = hold_on and _("No collections selected  —  long press to configure")
                             or _("No collections selected")
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = mod.getHeight(ctx) },
        UI.makeColoredText{
            text    = ph_text,
            face    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY),
            width   = w - PAD * 2,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Additional Settings API (used externally, e.g. by the Add Module list).
-- ---------------------------------------------------------------------------
function mod.getSelected() return getVisibleCollections() end
function mod.saveSelected(list)
    -- Full override, for backward compatibility: whatever is NOT in
    -- `list` becomes excluded, and `list` itself becomes the new manual
    -- order — same end result external callers got from the old
    -- positive-selection model.
    saveManualOrder(list)
    local keep = {}
    for _, n in ipairs(list) do keep[n] = true end
    local excluded = {}
    for _, n in ipairs(listAllCollectionNames()) do
        if not keep[n] then excluded[#excluded + 1] = n end
    end
    saveExcludedCollections(excluded)
end
function mod.getCoverOverrides() return getCoverOverrides() end
function mod.saveCoverOverrides(t) saveCoverOverrides(t) end
function mod.saveCoverOverride(coll_name, filepath)
    local t = getCoverOverrides(); t[coll_name] = filepath; saveCoverOverrides(t)
end
function mod.getBadgePosition()      return getBadgePosition() end
function mod.saveBadgePosition(v)    saveBadgePosition(v) end
function mod.getBadgeColor()         return getBadgeColor() end
function mod.saveBadgeColor(v)       saveBadgeColor(v) end
function mod.getBadgeHidden()        return getBadgeHidden() end
function mod.saveBadgeHidden(v)      saveBadgeHidden(v) end
function mod.getBadgeScalePct()      return getBadgeScalePct() end
function mod.saveBadgeScale(v)       saveBadgeScale(v) end
function mod.getCoverStyle()         return getCoverStyle() end
function mod.saveCoverStyle(v)       saveCoverStyle(v) end
function mod.getHidePile()          return getHidePile() end
function mod.saveHidePile(v)        saveHidePile(v) end

-- No limit on collections now — shows only the count (no "x/5").
function mod.getCountLabel(_pfx)
    local n = #mod.getSelected()
    if n == 0 then return nil end
    return string.format(N_("(%d collection)", "(%d collections)", n), n)
end

return mod
