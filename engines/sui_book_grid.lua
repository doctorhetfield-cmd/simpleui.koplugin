-- sui_book_grid.lua — Simple UI
-- Shared factory for "cover grid with progress" modules (1 row by
-- default, up to 3 rows x 4-5 columns when spec.grid = true).
--
-- Two API layers:
--   1. GridRenderer.build/getHeight/updateCovers/updateStats — low-level
--      primitives (used internally by makeModule; exposed for advanced
--      cases).
--   2. GridRenderer.makeModule(spec) — high-level factory: takes a
--      declarative table and returns a complete `M` module (build, getHeight,
--      updateCovers, updateStats, getMenuItems), ready to be exported by a
--      module_*.lua file and registered in moduleregistry.lua.
--
-- Consumers (via GridRenderer.makeModule):
--   • module_recent.lua      (Recent Books)
--   • module_new_books.lua   (New Books)
--   • module_tbr.lua         (TBR — data/API layer + row module in the same
--     file; spec.grid = true)
--   • module_feat_coll.lua   (Featured Collection, instantiable; spec.grid = true)
--   • module_library.lua     (Flat Library — recursive scan of the whole
--     library, not a curated subset; spec.grid = true)
--   • module_collections.lua (Collections — one cell per collection, via
--     spec.renderCell, instead of one cell per book; spec.grid = true)
--
-- Not a registry module (no top-level M.id / M.build) — a pure library.
--
-- Settings keys used (all prefixed by ctx.pfx .. id .. "_"):
--   progress_style, show_frame, solid_bg, grid_rows, grid_cols (only when
--   spec.grid = true — see makeModule), badge_pages, badge_series,
--   badge_new_mode, badge_scale, badge_color_<pages|series|new|progress>.
--   Legacy keys read once for migration, then superseded: show_progress,
--   show_text, show_overlay, badge_progress, badge_new (→ progress_style/
--   badge_new_mode — see _migrateProgressStyle/getBadgeNewMode).

local Blitbuffer      = require("ffi/blitbuffer")
local BD              = require("ui/bidi")
local T               = require("ffi/util").template
local Button          = require("ui/widget/button")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconWidget      = require("ui/widget/iconwidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _ = require("infra/sui_i18n").translate

local Bottombar   = require("screens/sui_bottombar")
local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local PAD    = UI.PAD
local Screen = require("device").screen

local CLR_TEXT_SUB    = UI.CLR_TEXT_SUB
local _BASE_RB_PCT_FS = SUIStyle.FS_DETAIL  -- 15: "XX% Read" label font size

local GridRenderer = {}

-- Every ctx[cache_key] name used by a row module's file-list cache (see
-- build() below), registered by makeModule() as each module is defined.
-- Backs GridRenderer.clearRowCaches(ctx).
GridRenderer._known_row_cache_keys = {}

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then _SH = m end
    end
    return _SH
end

-- Badge-drawing primitives (pentagon, rounded-rect, ribbon), shared with the
-- file-manager Library grid (sui_foldercovers.lua) so both grids render
-- badges identically.
local _CoverWidgets = nil
local function getCoverWidgets()
    if not _CoverWidgets then
        local ok, m = pcall(require, "features/library/sui_cover_widgets")
        if ok and m then _CoverWidgets = m end
    end
    return _CoverWidgets
end

-- FC (features/library/sui_foldercovers) is the source of truth for the
-- default badge COLOR (Library → Cover Settings → Overlays → Badges menu).
-- Book-grid modules fall back to the same getters instead of keeping a
-- parallel settings tree, unless overridden per module instance (see
-- GridRenderer.getBadgeColor). Badge SIZE is a separate, independent
-- per-module-instance setting — see GridRenderer.getBadgeScale below; it
-- does not read from FC. What to show (per module) is likewise a separate
-- concern — see showBadgePages/Series/getBadgeNewMode and
-- GridRenderer.getProgressStyle below.
local _FC = nil
local function getFC()
    if not _FC then
        local ok, m = pcall(require, "features/library/sui_foldercovers")
        if ok and m then _FC = m end
    end
    return _FC
end

-- Drops cached module references so the GC can collect them as soon as
-- package.loaded is cleared, instead of waiting on the upvalue. Called on
-- plugin teardown.
function GridRenderer.reset()
    _SH = nil
    _CoverWidgets = nil
    _FC = nil
    local ok, SH = pcall(require, "modules/module_books_shared")
    if ok and SH and SH.invalidateSeriesCache then SH.invalidateSeriesCache() end
end

-- ---------------------------------------------------------------------------
-- Settings accessors — generic, namespaced by opts.id
--
-- Toggles accept an optional "mode" (3rd parameter):
--   "on"  / "off"            — default value, user can change it
--   "locked_on"/"locked_off" — fixed, no settings read, no menu item
-- Omitting the mode is equivalent to "off".
-- ---------------------------------------------------------------------------
local function _toggleDefault(mode) return mode == "on" or mode == "locked_on" end
local function _toggleLocked(mode)  return mode == "locked_on" or mode == "locked_off" end

function GridRenderer.showFrame(pfx, id) return SUISettings:isTrue(pfx .. id .. "_show_frame") end
function GridRenderer.solidBg(pfx, id)
    local ok, WP = pcall(require, "features/sui_wallpaper")
    if ok and WP and WP.getModuleBackdropStrength then
        return WP.getModuleBackdropStrength(pfx, id) >= 100
    end
    return SUISettings:isTrue(pfx .. id .. "_solid_bg")
end

function GridRenderer.backdropStrength(pfx, id)
    local ok, WP = pcall(require, "features/sui_wallpaper")
    if ok and WP and WP.getModuleBackdropStrength then
        return WP.getModuleBackdropStrength(pfx, id)
    end
    return SUISettings:isTrue(pfx .. id .. "_solid_bg") and 100 or 0
end

-- ---------------------------------------------------------------------------
-- Progress style — single enum for how a cell shows reading progress.
--
-- Values: "none" | "bar" | "text" | "bar_text" | "overlay" | "badge"
--   bar      — progress bar below the cover
--   text     — "XX% Read" label below the cover
--   bar_text — both of the above
--   overlay  — round percentage overlay centered on the cover
--   badge    — Library-style pentagon badge, top-right corner
--
-- spec_cfg (module-level, from makeModule's spec.progress_style):
--   default  string?  used when nothing is stored yet, and as the fallback
--            when a stored value is invalid or not in `allowed`. Defaults
--            to "bar_text".
--   locked   string?  when set, the module always uses this exact style and
--            GridRenderer.makeModule's menu shows no picker at all.
--   allowed  { string, ... }?  narrows which styles the menu offers (e.g. a
--            module that never wants "overlay"). nil = all six. Ignored
--            when `locked` is set.
-- ---------------------------------------------------------------------------
GridRenderer.PROGRESS_STYLES = { "none", "bar", "text", "bar_text", "overlay", "badge" }
local _PROGRESS_STYLE_SET = {}
for _, v in ipairs(GridRenderer.PROGRESS_STYLES) do _PROGRESS_STYLE_SET[v] = true end

-- One-shot migration from the four legacy boolean keys (show_overlay,
-- badge_progress, show_progress, show_text) to the single progress_style
-- key. Returns nil when none of the legacy keys were ever written for this
-- pfx/id, so a fresh module instance falls through to spec_cfg.default
-- instead of getting "none" written into its settings. When more than one
-- legacy flag was on at once, priority is overlay > badge > bar/text.
local function _migrateProgressStyle(pfx, id)
    local show_overlay   = SUISettings:readSetting(pfx .. id .. "_show_overlay")
    local badge_progress = SUISettings:readSetting(pfx .. id .. "_badge_progress")
    local show_progress  = SUISettings:readSetting(pfx .. id .. "_show_progress")
    local show_text      = SUISettings:readSetting(pfx .. id .. "_show_text")
    if show_overlay == nil and badge_progress == nil and show_progress == nil and show_text == nil then
        return nil
    end
    if show_overlay == true then return "overlay" end
    if badge_progress == true then return "badge" end
    local p, t = show_progress == true, show_text == true
    if p and t then return "bar_text"
    elseif p then return "bar"
    elseif t then return "text"
    else return "none" end
end

function GridRenderer.getProgressStyle(pfx, id, spec_cfg)
    spec_cfg = spec_cfg or {}
    if spec_cfg.locked then return spec_cfg.locked end
    local default_style = spec_cfg.default or "bar_text"
    local key = pfx .. id .. "_progress_style"
    local v = SUISettings:readSetting(key)
    if v == nil then
        local migrated = _migrateProgressStyle(pfx, id)
        if migrated then
            SUISettings:saveSetting(key, migrated)
            return migrated
        end
        return default_style
    end
    if not _PROGRESS_STYLE_SET[v] then return default_style end
    if spec_cfg.allowed then
        local ok = false
        for _, a in ipairs(spec_cfg.allowed) do if a == v then ok = true; break end end
        if not ok then return default_style end
    end
    return v
end

function GridRenderer.setProgressStyle(pfx, id, style)
    if not _PROGRESS_STYLE_SET[style] then return end
    SUISettings:saveSetting(pfx .. id .. "_progress_style", style)
end

-- ---------------------------------------------------------------------------
-- Library-style corner badges: Pages, Series index, New book. (Progress is
-- one of the progress_style values above, not a separate badge toggle.)
-- Same "on"/"off"/"locked_on"/"locked_off" convention as elsewhere in this
-- file — opts.badges = { pages=mode, series=mode, new=mode } in makeModule's
-- spec, or per-call to GridRenderer.build().
-- ---------------------------------------------------------------------------
function GridRenderer.showBadgePages(pfx, id, mode)
    if _toggleLocked(mode) then return _toggleDefault(mode) end
    local v = SUISettings:readSetting(pfx .. id .. "_badge_pages")
    if v == nil then return _toggleDefault(mode) end
    return v == true
end
function GridRenderer.showBadgeSeries(pfx, id, mode)
    if _toggleLocked(mode) then return _toggleDefault(mode) end
    local v = SUISettings:readSetting(pfx .. id .. "_badge_series")
    if v == nil then return _toggleDefault(mode) end
    return v == true
end

-- "New" badge mode: "none" | "badge" (rounded rectangle) | "ribbon"
-- (diagonal corner ribbon) — same two visual styles as the Library's own
-- New badge Type picker (features/library/sui_foldercovers.lua,
-- FC.getNewMode()), reusing the same ribbon-drawing code
-- (features/library/sui_cover_widgets.lua's CoverWidgets.paintCornerRibbon
-- via CoverWidgets.buildCornerRibbonWidget).
--
-- `mode` here is still the module spec's "on"/"off"/"locked_on"/
-- "locked_off" convention (badges_cfg.new in makeModule's spec): it only
-- decides the DEFAULT/lock, same as showBadgePages/showBadgeSeries above.
-- locked_on/locked_off lock fully to "badge"/"none"; on/off just set which
-- style the per-instance Type picker defaults to.
GridRenderer.NEW_BADGE_MODES = { "none", "badge", "ribbon" }
local _NEW_BADGE_MODE_SET = {}
for _, v in ipairs(GridRenderer.NEW_BADGE_MODES) do _NEW_BADGE_MODE_SET[v] = true end

function GridRenderer.getBadgeNewMode(pfx, id, mode)
    if _toggleLocked(mode) then
        return _toggleDefault(mode) and "badge" or "none"
    end
    local key = pfx .. id .. "_badge_new_mode"
    local v = SUISettings:readSetting(key)
    if v == nil then
        -- One-shot migration from the legacy boolean _badge_new key, which
        -- only ever meant "badge".
        local legacy = SUISettings:readSetting(pfx .. id .. "_badge_new")
        if legacy ~= nil then
            local migrated = (legacy == true) and "badge" or "none"
            SUISettings:saveSetting(key, migrated)
            return migrated
        end
        return _toggleDefault(mode) and "badge" or "none"
    end
    if not _NEW_BADGE_MODE_SET[v] then return _toggleDefault(mode) and "badge" or "none" end
    return v
end

function GridRenderer.setBadgeNewMode(pfx, id, v)
    if not _NEW_BADGE_MODE_SET[v] then return end
    SUISettings:saveSetting(pfx .. id .. "_badge_new_mode", v)
end

-- ---------------------------------------------------------------------------
-- Per-badge color override — same idea as the Library's own per-badge Dark/
-- Light setting (features/library/sui_foldercovers.lua), but scoped to one
-- module instance instead of global. nil (never set, or cleared via
-- setBadgeColor(pfx, id, key, nil) — "Follow Library") falls back to the
-- shared Library color via `fc_getter`.
-- badge_key: "pages" | "series" | "new" | "progress"
-- ---------------------------------------------------------------------------
function GridRenderer.getBadgeColorOverride(pfx, id, badge_key)
    local v = SUISettings:readSetting(pfx .. id .. "_badge_color_" .. badge_key)
    if v == "dark" or v == "light" then return v end
    return nil
end
function GridRenderer.getBadgeColor(pfx, id, badge_key, fc_getter)
    return GridRenderer.getBadgeColorOverride(pfx, id, badge_key)
        or (fc_getter and fc_getter() or "light")
end
function GridRenderer.setBadgeColor(pfx, id, badge_key, v)
    if v ~= "dark" and v ~= "light" then v = nil end -- nil = clear override, follow Library
    SUISettings:saveSetting(pfx .. id .. "_badge_color_" .. badge_key, v)
end

-- ---------------------------------------------------------------------------
-- Book-grid badge SIZE — per-module-instance setting (pfx .. id .. "_badge_
-- scale"), independent from the Library grid's own "Badge Size"
-- (features/library/sui_foldercovers.lua's FC.getBadgeScale/setBadgeScale).
--
-- The user-facing default is 100%, matching the Library's own "Badge Size"
-- control. Module badges render 10% bigger than that baseline by default;
-- this boost is baked into _BG_BADGE_NATIVE_BOOST below and applied on top
-- of the percent, so "100%" always means "this control's own baseline".
-- See SUIStyle.BADGE_SIZE_ADJUST for the separate global size trim applied
-- on top of both this and the Library's own scale.
--
-- Each module instance keeps its own value (key pfx .. id .. "_badge_
-- scale"). Legacy installs that only had the shared key
-- "simpleui_bookgrid_badge_scale" are migrated once per module instance:
-- the first time a module's own key is read and found unset, the shared
-- percent is converted into the new 100%-baselined scale and copied in.
-- ---------------------------------------------------------------------------
local _BG_BADGE_SCALE_LEGACY_KEY = "simpleui_bookgrid_badge_scale"
local _BG_BADGE_NATIVE_BOOST = 1.1 -- default module-badge boost over the Library baseline
local _BG_BADGE_SCALE_MIN  = 50
local _BG_BADGE_SCALE_MAX  = 200
local _BG_BADGE_SCALE_DEF  = 100
local _BG_BADGE_SCALE_STEP = 10
GridRenderer.BADGE_SCALE_MIN  = _BG_BADGE_SCALE_MIN
GridRenderer.BADGE_SCALE_MAX  = _BG_BADGE_SCALE_MAX
GridRenderer.BADGE_SCALE_DEF  = _BG_BADGE_SCALE_DEF
GridRenderer.BADGE_SCALE_STEP = _BG_BADGE_SCALE_STEP

local function _clampBGBadgeScale(n)
    return math.max(_BG_BADGE_SCALE_MIN, math.min(_BG_BADGE_SCALE_MAX, math.floor(n)))
end

function GridRenderer.getBadgeScalePct(pfx, id)
    local key = pfx .. id .. "_badge_scale"
    local n = tonumber(SUISettings:readSetting(key))
    if n then return _clampBGBadgeScale(n) end

    -- One-shot migration from the shared legacy key — see doc comment
    -- above. Divide by the boost so the migrated value renders at the same
    -- size under the new formula (pct/100 * ADJUST * BOOST) as the legacy
    -- percent did under the old one (pct/100 * ADJUST).
    local legacy = tonumber(SUISettings:readSetting(_BG_BADGE_SCALE_LEGACY_KEY))
    if legacy then
        local migrated = _clampBGBadgeScale(legacy / _BG_BADGE_NATIVE_BOOST)
        SUISettings:saveSetting(key, migrated)
        return migrated
    end
    return _BG_BADGE_SCALE_DEF
end
function GridRenderer.getBadgeScale(pfx, id)
    return GridRenderer.getBadgeScalePct(pfx, id) / 100 * SUIStyle.BADGE_SIZE_ADJUST * _BG_BADGE_NATIVE_BOOST
end
function GridRenderer.setBadgeScale(pfx, id, pct)
    SUISettings:saveSetting(pfx .. id .. "_badge_scale", _clampBGBadgeScale(pct))
end

-- Fixed +20% base-size boost for the "corner badge" family (progress
-- pentagon, pages, series, new-as-rounded-rect) in module-grid renders,
-- applied on top of GridRenderer.getBadgeScale in GridRenderer.applyBadges
-- below. Module-only — the Library grid's own badges are untouched — and
-- excludes the New Book ribbon, which keeps using the plain, unboosted
-- badge_scale. Not user-adjustable: it multiplies on top of whatever
-- percent the user has chosen, so the relative +20% holds at every Badge
-- Size setting.
local _BG_CORNER_BADGE_BASE_BOOST = 1.2

-- ---------------------------------------------------------------------------
-- Grid rows/cols — opt-in via spec.grid (see makeModule below). Rows: 1-3.
-- Cols: 4-5. Defaults (1 row, spec.max_items or 5 cols) reproduce the
-- pre-grid single-row layout exactly, so consumers that don't set
-- spec.grid never see a behaviour change.
-- ---------------------------------------------------------------------------
GridRenderer.GRID_ROWS_MIN = 1
GridRenderer.GRID_ROWS_MAX = 3
GridRenderer.GRID_COLS_MIN = 4
GridRenderer.GRID_COLS_MAX = 5

local function _clampInt(n, lo, hi)
    n = math.floor(tonumber(n) or lo)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

-- Extra height reserved below the cover for the active progress bar/label,
-- counting only what's actually drawn. draw_progress/draw_text are
-- module-level settings (not per-book), so the same value applies to every
-- cell in the grid/row. Called identically in build() and getHeight() so
-- the two stay in sync.
local function cellExtraHeight(draw_progress, draw_text, gap1, bar_h, gap2, label_h)
    if not draw_progress and not draw_text then return 0 end
    local extra = gap1
    if draw_progress then extra = extra + bar_h end
    if draw_text then extra = extra + (draw_progress and gap2 or 0) + label_h end
    return extra
end

function GridRenderer.getGridRows(pfx, id, default_rows)
    local v = SUISettings:readSetting(pfx .. id .. "_grid_rows")
    if v == nil then return default_rows or 1 end
    return _clampInt(v, GridRenderer.GRID_ROWS_MIN, GridRenderer.GRID_ROWS_MAX)
end
function GridRenderer.getGridCols(pfx, id, default_cols)
    local v = SUISettings:readSetting(pfx .. id .. "_grid_cols")
    if v == nil then return _clampInt(default_cols or 5, GridRenderer.GRID_COLS_MIN, GridRenderer.GRID_COLS_MAX) end
    return _clampInt(v, GridRenderer.GRID_COLS_MIN, GridRenderer.GRID_COLS_MAX)
end
function GridRenderer.setGridRows(pfx, id, n)
    SUISettings:saveSetting(pfx .. id .. "_grid_rows", _clampInt(n, GridRenderer.GRID_ROWS_MIN, GridRenderer.GRID_ROWS_MAX))
end
function GridRenderer.setGridCols(pfx, id, n)
    SUISettings:saveSetting(pfx .. id .. "_grid_cols", _clampInt(n, GridRenderer.GRID_COLS_MIN, GridRenderer.GRID_COLS_MAX))
end

-- ---------------------------------------------------------------------------
-- applyBadges(cover_widget, bd, fp, cw, ch, badges_cfg, pfx, id, show_progress_badge) → widget
--
-- Wraps `cover_widget` (already sized cw × ch) with the same corner badges
-- as the file-manager Library grid (features/library/sui_cover_widgets.lua),
-- reusing its drawing primitives so both grids render badges identically.
-- Unlike the Library grid, badges here stay INSIDE the cover's rectangle
-- (the progress pentagon doesn't poke above the top edge), so cell_h stays
-- a plain function of cw/ch with no extra bookkeeping to keep in sync
-- between build() and getHeight().
--
-- Layout (mirrors the Library grid):
--   pages    → bottom-left    series → top-left
--   progress → top-right, OR new → top-right (mutually exclusive: a book
--              can't be both "in progress/finished" and "unread"). New has
--              two visual styles — badge (rounded rect) or ribbon (diagonal
--              corner band) — picked via GridRenderer.getBadgeNewMode,
--              mirroring the Library grid's own New badge Type picker.
--
-- show_progress_badge is passed in explicitly (rather than read from
-- badges_cfg, unlike pages/series/new) because it's derived from the
-- module's single progress_style setting ("badge").
--
-- Color defaults to the shared Library setting (features/library/
-- sui_foldercovers.lua's FC getters, the same ones the Library "Badges"
-- menu controls), but each badge can be overridden per module instance via
-- GridRenderer.getBadgeColor/setBadgeColor. Size is likewise per module
-- instance (GridRenderer.getBadgeScale(pfx, id)), independent from every
-- other module and from the Library grid's own badge size.
--
-- Returns cover_widget unchanged when no badge is enabled/applicable —
-- callers don't need to special-case the "nothing to draw" outcome.
-- ---------------------------------------------------------------------------
function GridRenderer.applyBadges(cover_widget, bd, fp, cw, ch, badges_cfg, pfx, id, show_progress_badge)
    if not badges_cfg then return cover_widget end
    local CW = getCoverWidgets()
    local fc = getFC()
    if not CW or not fc then return cover_widget end

    local show_pages    = GridRenderer.showBadgePages(pfx, id, badges_cfg.pages)
    local show_series   = GridRenderer.showBadgeSeries(pfx, id, badges_cfg.series)
    local new_mode      = GridRenderer.getBadgeNewMode(pfx, id, badges_cfg.new)
    local show_new      = new_mode ~= "none"
    local show_progress = show_progress_badge and true or false
    if not (show_pages or show_series or show_new or show_progress) then
        return cover_widget
    end

    -- Per-module-instance size, adjustable without touching any other
    -- module's badges or the Library grid's own "Badge Size".
    local badge_scale  = GridRenderer.getBadgeScale(pfx, id)
    -- Corner-badge family (progress pentagon, pages, series, new-as-badge)
    -- reads 20% bigger than the ribbon at the same badge_scale — see
    -- _BG_CORNER_BADGE_BASE_BOOST's doc comment. Not applied to the New
    -- Book ribbon, which keeps using the plain `badge_scale` below.
    local corner_badge_scale = badge_scale * _BG_CORNER_BADGE_BASE_BOOST
    local cell_min     = math.min(cw, ch)
    local margin       = math.max(1, math.floor(cell_min * 0.04))
    -- Lateral (left/right) inset — wider than the vertical `margin` so
    -- badges don't sit flush against the cover's side edges. `margin`
    -- still governs the top/bottom axis for every badge (Pages' bottom,
    -- Series/New's top) except Progress, which goes flush (0) at the top.
    local edge_margin  = math.max(1, math.floor(cell_min * 0.08))
    local badges_added = false
    local overlap = OverlapGroup:new{ dimen = Geom:new{ w = cw, h = ch }, cover_widget }

    -- Pages badge (bottom-left) — hidden for finished books, same rule as
    -- the Library grid (a finished book doesn't need its page count).
    if show_pages and bd.status ~= "complete" and bd.pages then
        local dark = GridRenderer.getBadgeColor(pfx, id, "pages", fc.getBadgeColorPages) == "dark"
        local wg = CW.buildRectBadgeWidget(bd.pages .. _(" p."), false, cell_min, dark, false, corner_badge_scale)
        if wg then
            wg.overlap_offset = { edge_margin, ch - wg.dimen.h - margin }
            overlap[#overlap + 1] = wg
            badges_added = true
        end
    end

    -- Series index badge (top-left). One extra lookup per cell — cheap for
    -- the small non-paged modules (Recent/New Books/Featured Collection,
    -- ≤5 items). SH.getBookSeries() is memoized per filepath.
    if show_series then
        local SH = getSH()
        local sd = SH and SH.getBookSeries(fp)
        if sd then
            local dark = GridRenderer.getBadgeColor(pfx, id, "series", fc.getBadgeColorSeries) == "dark"
            local wg = CW.buildRectBadgeWidget("#" .. sd.series_index, false, cell_min, dark, false, corner_badge_scale)
            if wg then
                wg.overlap_offset = { edge_margin, margin }
                overlap[#overlap + 1] = wg
                badges_added = true
            end
        end
    end

    -- Progress pentagon / New badge (top-right, mutually exclusive).
    -- Progress uses the shared builder so the pentagon matches single-cover
    -- modules (Currently Reading, Coverdeck) exactly.
    local has_progress = show_progress
        and ((bd.percent or 0) > 0 or bd.status == "complete" or bd.status == "abandoned")
    if has_progress then
        local color = GridRenderer.getBadgeColor(pfx, id, "progress", fc.getBadgeColorProgress)
        local eff_size = math.max(8, math.floor(cell_min * 0.14 * corner_badge_scale))
        local SH = getSH()
        local wg = SH and SH.buildProgressBadgeWidget and SH.buildProgressBadgeWidget(bd, eff_size, color)
        if wg then
            local sz = wg:getSize()
            -- Flush with the top edge (0, not margin); wider inset from
            -- the right edge (edge_margin).
            wg.overlap_offset = { cw - sz.w - edge_margin, 0 }
            overlap[#overlap + 1] = wg
            badges_added = true
        end
    elseif show_new and (bd.percent or 0) == 0 and bd.status == nil then
        -- "Unread" here means "0% and no status" — SH.getBookData() always
        -- defaults percent to 0, so the two aren't distinguishable from bd
        -- alone. Good enough for a homescreen glance badge.
        local dark = GridRenderer.getBadgeColor(pfx, id, "new", fc.getBadgeColorNew) == "dark"
        if new_mode == "ribbon" then
            -- Not boosted — the ribbon keeps its own size (badge_scale).
            local wg = CW.buildCornerRibbonWidget(cw, ch, dark, badge_scale)
            if wg then
                -- Full-size layer, no overlap_offset needed.
                overlap[#overlap + 1] = wg
                badges_added = true
            end
        else -- "badge"
            local wg = CW.buildRectBadgeWidget(_("New"), true, cell_min, dark, true, corner_badge_scale)
            if wg then
                wg.overlap_offset = { cw - wg.dimen.w - edge_margin, margin }
                overlap[#overlap + 1] = wg
                badges_added = true
            end
        end
    end

    if not badges_added then return cover_widget end
    return overlap
end

-- ---------------------------------------------------------------------------
-- computeAutoFitCell(inner_w, n_cols, cs) — auto-fit width of one column
-- in a grid of n_cols columns, plus the horizontal gap between columns.
-- cs = combined scale (module scale * thumb/cover scale), 1.0 = pure
-- auto-fit size (fills inner_w exactly).
--
-- Shared with any consumer of the engine that needs the same "100% = fills
-- the row, cs≠1.0 scales from what was already visible" behaviour (e.g.
-- module_collections.lua), instead of reimplementing the calculation.
--
-- Returns: cw (column width), gap (horizontal space between columns).
-- ---------------------------------------------------------------------------
function GridRenderer.computeAutoFitCell(inner_w, n_cols, cs)
    cs = cs or 1.0
    local autofit_cw = math.max(1, math.floor((inner_w - (n_cols - 1) * PAD) / n_cols))
    if cs == 1.0 then
        return autofit_cw, PAD
    end
    local cw  = math.max(1, math.floor(autofit_cw * cs))
    local gap = n_cols > 1 and math.floor((inner_w - n_cols * cw) / (n_cols - 1)) or 0
    return cw, gap
end

-- ---------------------------------------------------------------------------
-- turnPage(page, npages, delta) → new_page | nil
--
-- Clamped page-turn: page 1 has no "previous", page npages has no "next".
-- Returns nil when delta doesn't move anywhere (already at that edge), so a
-- caller can tell "nothing happened" apart from a real page change and skip
-- the repaint/refresh entirely.
-- ---------------------------------------------------------------------------
function GridRenderer.turnPage(page, npages, delta)
    local new_page = page + delta
    if new_page < 1 or new_page > npages then return nil end
    return new_page
end

-- Icon size for the page-nav chevrons, in the same base-pixel convention as
-- the rest of this file (scaled via Screen:scaleBySize at use time).
local _NAV_ICON_SIZE = 16

-- ---------------------------------------------------------------------------
-- buildPageNavButtons(page, npages, row_h, turnPageFn) → prev, next
--
-- Ready-to-insert chevron pair for a paginated row/grid's header, next to
-- the "page/npages" text. Returns nil, nil when there's nothing to page
-- through (npages <= 1), so the caller shows no controls at all rather
-- than a pair of permanently-disabled chevrons.
--
-- Built on KOReader's native Button (same building block as the
-- bottombar's chevron footer, see buildChevronFooter in
-- sui_screen_engine.lua). bordersize = 0 keeps it borderless;
-- padding_top/padding_bottom pad the small 16px icon up to a finger-sized
-- tap zone without growing the row's own height. Bottombar.patchDimmedIcon
-- gives the disabled edge the same dimmed look as the footer chevrons.
--
-- turnPageFn(delta) is called on tap; it owns clamping (via turnPage
-- above), persisting the new page, and repainting — this function only
-- decides whether each chevron is enabled for the CURRENT page/npages.
--
-- has_wallpaper (optional): when true, the chevrons are built inside
-- Bottombar.withWallpaperAlphaIcons so their icons are alpha-blended from
-- birth (see that function's doc comment for why it must happen at
-- construction time, not after), and Bottombar.patchWallpaperIcon makes
-- their button frame paint transparently too — together, the chevrons
-- paint over the Homescreen wallpaper instead of showing their default
-- opaque background.
-- ---------------------------------------------------------------------------
function GridRenderer.buildPageNavButtons(page, npages, row_h, turnPageFn, has_wallpaper)
    if npages <= 1 then return nil, nil end
    local icon_size = Screen:scaleBySize(_NAV_ICON_SIZE)
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
            callback        = function() turnPageFn(delta) end,
        }
        Bottombar.patchDimmedIcon(btn)
        if has_wallpaper then Bottombar.patchWallpaperIcon(btn) end
        return btn
    end
    local prev_btn, next_btn
    if has_wallpaper then
        Bottombar.withWallpaperAlphaIcons(function()
            prev_btn, next_btn = make("chevron.left",  page > 1,      -1),
                                  make("chevron.right", page < npages,  1)
        end)
    else
        prev_btn, next_btn = make("chevron.left",  page > 1,      -1),
                              make("chevron.right", page < npages,  1)
    end
    return prev_btn, next_btn
end

-- ---------------------------------------------------------------------------
-- build(w, ctx, opts) → widget | nil
--
-- opts:
--   id          string    settings namespace (e.g. "tbr" or inst_id)
--   getFileList function  () -> { fp, ... } (ordered list of files)
--   max_items   number?   max covers shown per page (default 5)
--   cache_key   string?   cache key in ctx (default "_row_fps_" .. id)
--   paged       bool?     if true and #fps > max_items, enables pagination via
--                         horizontal swipe (wraparound), with no visual
--                         indicator — the row always shows up to `max_items`
--                         covers, left-aligned. Requires the consuming
--                         module to have `is_book_mod = true` (see
--                         moduleregistry.lua) for the surgical repaint to
--                         work — without it the swipe is ignored. Page
--                         state is scoped to the session (ctx), it doesn't
--                         persist across restarts.
--   filterItem  function? (fp, ctx) -> bool — excludes items from the list
--                         (applied once, before caching in ctx)
--   labelForItem function? (bd) -> string — replaces the default "XX% Read"
--                         text (e.g. "New" for New Books)
--   progress_style  table?  { default=style, locked=style, allowed={...} } —
--                         see GridRenderer.getProgressStyle's doc comment.
--   badges      table?   { pages=mode, series=mode, new=mode }, mode being
--                         "on"|"off"|"locked_on"|"locked_off" (omitted =
--                         "off"). Library-style corner badges (see
--                         GridRenderer.applyBadges) — skipped whenever
--                         progress_style="overlay" is active.
--   grid_rows   number?  1-3 (default 1). When >1, the "row" becomes a
--                         multi-row grid — see getGridRows/Cols. When
--                         grid_rows/grid_cols are passed, the effective
--                         page size is grid_rows * grid_cols, not max_items.
--   grid_cols   number?  4-5 (default max_items or 5).
-- ---------------------------------------------------------------------------

-- Filters a raw file list through opts.filterItem, if set. Shared by
-- build()'s cold-cache path and updateStats()'s re-derivation so both
-- filter identically.
local function _filterFileList(fps, opts, ctx)
    if not opts.filterItem then return fps end
    local filtered = {}
    for _, fp in ipairs(fps) do
        if opts.filterItem(fp, ctx) then filtered[#filtered + 1] = fp end
    end
    return filtered
end

-- Resolves the current page number and slices it out of `fps` for a grid
-- of `max_items` items per page. Shared by build() and updateStats() so
-- both always agree on which page is on screen. `persist`, when true,
-- clamps an out-of-range stored page back into ctx (build()'s behaviour);
-- updateStats() reads without persisting, since a stats-only refresh must
-- not move the page as a side effect.
local function _resolveCurrentPage(fps, ctx, id, max_items, want_paged, persist)
    local npages = 1
    local page   = 1
    if want_paged and #fps > max_items then
        local page_key = "_row_page_" .. id
        npages = math.ceil(#fps / max_items)
        page   = ctx[page_key] or 1
        if page < 1 or page > npages then page = 1 end
        if persist then ctx[page_key] = page end
    end
    local page_start = (page - 1) * max_items + 1
    local page_fps = {}
    for i = page_start, math.min(page_start + max_items - 1, #fps) do
        page_fps[#page_fps + 1] = fps[i]
    end
    return page, npages, page_fps
end

function GridRenderer.build(w, ctx, opts)
    local id          = opts.id
    local grid_rows   = opts.grid_rows or 1
    local grid_cols   = opts.grid_cols or opts.max_items or 5
    -- `max_items` is the number of items per page throughout the rest of
    -- this function (pagination, swipe, eraser): a "page" holds up to
    -- rows*cols books, not just cols, so grid mode reuses the same logic.
    local max_items   = grid_rows * grid_cols
    local cache_key    = opts.cache_key or ("_row_fps_" .. id)
    local progress_style_cfg = opts.progress_style or {}

    local fps = ctx[cache_key]
    if not fps then
        fps = _filterFileList(opts.getFileList() or {}, opts, ctx)
        ctx[cache_key] = fps
    end
    local npages_key = "_row_npages_" .. id
    if #fps == 0 then
        ctx[npages_key] = 1
        return nil
    end

    local page, npages, page_fps = _resolveCurrentPage(fps, ctx, id, max_items, opts.paged, true)
    local paged = opts.paged and #fps > max_items
    ctx[npages_key] = npages

    local _clr_blk        = SUIStyle.COLOR.text_primary
    local _clr_sub        = CLR_TEXT_SUB

    local SH          = getSH()
    local pfx         = ctx.pfx
    local lf          = ctx.landscape_factor or 1
    local scale       = Config.getModuleScale(id, pfx) * lf
    local thumb_scale = Config.getThumbScale(id, pfx) * lf
    local lbl_scale   = Config.getItemLabelScale(id, pfx) * lf
    local D           = SH.getDims(scale, thumb_scale)
    local pct_fs      = math.max(8, math.floor(_BASE_RB_PCT_FS * scale * lbl_scale))

    -- Frame border / solid background — same optional box every other
    -- homescreen module offers (module_currently.lua, module_heatmap.lua,
    -- module_reading_goals.lua). Computed up front so inner_w below already
    -- reserves room for the border, keeping the box's real outer width
    -- equal to `w`.
    -- Module chrome (frame/background) is applied by the homescreen wrapper.
    local box = { inset_h = 0, inset_v = 0 }
    local inner_w = w

    -- Cover size: base is the auto-fit size (grid_cols covers + gaps filling
    -- inner_w). Width uses grid_cols, not the item count on this page, so a
    -- partial last row keeps the same cell width as full rows above.
    --
    -- cs = scale * thumb_scale multiplies that base: 100% fills the row.
    --
    -- Uses the RAW getters: `w` (this column's width) is already narrowed
    -- for landscape upstream, so multiplying cs by landscape_factor too
    -- would narrow it twice.
    local raw_scale       = Config.getModuleScaleRaw(id, pfx)
    local raw_thumb_scale = Config.getThumbScaleRaw(id, pfx)
    local cs = raw_scale * raw_thumb_scale
    local cw, gap = GridRenderer.computeAutoFitCell(inner_w, grid_cols, cs)
    local ch = math.max(1, math.floor(cw * (D.RECENT_H / D.RECENT_W)))
    -- Vertical spacing between grid rows (grid_rows>1): half the
    -- horizontal `gap`. The full horizontal gap has to accommodate the
    -- visual frame of each cover on both sides; between rows, that full
    -- distance reads as too loose, making the two rows look like one block.
    local row_gap = math.max(0, math.floor(gap / 2))
    local pct_face = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)

    local progress_style     = GridRenderer.getProgressStyle(pfx, id, progress_style_cfg)
    local draw_progress      = progress_style == "bar"  or progress_style == "bar_text"
    local draw_text          = progress_style == "text" or progress_style == "bar_text"
    local use_overlay        = progress_style == "overlay"
    local use_progress_badge = progress_style == "badge"

    -- Real line height for pct_face, measured via freetype
    -- (face.ftsize:getHeightAndAscender(), the same API TextWidget:
    -- updateSize() uses) rather than a fixed constant, so the row always
    -- reserves at least as much height as the label actually needs.
    local ok_h, face_height = pcall(function() return pct_face.ftsize:getHeightAndAscender() end)
    local label_h = (ok_h and face_height and math.ceil(face_height)) or math.ceil(pct_fs * 1.8)

    local badge_r = math.floor(cw * 0.28)
    -- draw_progress/draw_text (computed above, once, same for the whole
    -- row/grid) decide how much extra height is reserved — see
    -- cellExtraHeight above and the mirrored logic in getHeight().
    --
    -- opts.getCellHeight(cw, pfx): hook for consumers whose cell doesn't
    -- follow the "cover + bar + text" format (e.g. module_collections.lua,
    -- whose cell is cover+accent-bar+badge+collection-name). Must return
    -- exactly the same value as the equivalent opts.getCellHeight passed
    -- to GridRenderer.getHeight(), or the reserved height diverges from
    -- the real content.
    local cell_h
    if opts.getCellHeight then
        cell_h = opts.getCellHeight(cw, pfx)
    else
        cell_h = use_overlay and (ch + badge_r)
                               or (ch + cellExtraHeight(draw_progress, draw_text, D.RB_GAP1, D.RB_BAR_H, D.RB_GAP2, label_h))
    end

    -- `row` always ends up as a VerticalGroup of 1..grid_rows
    -- HorizontalGroups — even for a single row — so the rest of this
    -- function (pagination/swipe/eraser, all operating only on
    -- `row:getSize()`) doesn't need to know whether it's in grid mode. A
    -- VerticalGroup with a single child has the same size as that child,
    -- so this changes nothing visually when grid_rows==1.
    local row = VerticalGroup:new{ align = "left" }
    local cover_slots = {}
    -- Per-cell in-place-update closures, indexed the same 1..#page_fps
    -- ordinal as page_fps itself — see GridRenderer.updateStats below,
    -- which calls row_update_funcs[i](bd) with freshly-fetched book data
    -- for page_fps[i], patching only the percent bar/text of that cell
    -- without rebuilding it. Left at index i as a plain nil (table with
    -- holes) for opts.renderCell cells and any cell where neither
    -- draw_progress nor draw_text is active — updateStats treats a missing
    -- entry as "nothing to patch for this cell", not an error.
    local row_update_funcs = {}
    local i = 0
    for r = 1, grid_rows do
        if i >= #page_fps then break end
        local hrow = HorizontalGroup:new{ align = "top" }
        if r > 1 then row[#row + 1] = VerticalSpan:new{ width = row_gap } end
        row[#row + 1] = hrow
        for c = 1, grid_cols do
        i = i + 1
        if i > #page_fps then break end
        local fp    = page_fps[i]
        local cell_widget

        -- ── opts.renderCell: fully custom cell ──────────────
        -- When present, replaces the entire "book cover + progress/text +
        -- tap-to-open" cell built below. `fp` (whatever opts.getFileList()
        -- returned, not necessarily a filepath) and `cell_h` are already
        -- computed by this function; renderCell must return a ready widget
        -- (with its own tap handling, if needed) of size cw × cell_h, and
        -- optionally a list of cover slots to merge into `cover_slots`
        -- (same { container, idx, fp, w, h } format used below, so
        -- GridRenderer.updateCovers keeps working unchanged).
        if opts.renderCell then
            local extra_slots
            cell_widget, extra_slots = opts.renderCell(fp, cw, cell_h, ctx)
            if extra_slots then
                for _, s in ipairs(extra_slots) do cover_slots[#cover_slots + 1] = s end
            end
        else

        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

        local cover_widget
        if use_overlay then
            local pct_int = math.floor((bd.percent or 0) * 100 + 0.5)
            local badge_d = badge_r * 2
            local border_sz = SUIStyle.BADGE_BORDER_SZ
            local border_color = SUIStyle.BADGE_BORDER_CLR
            local badge = FrameContainer:new{
                bordersize  = border_sz,
                color       = border_color,
                background  = SUIStyle.COLOR.track,
                padding     = 0,
                dimen       = Geom:new{ w = badge_d, h = badge_d },
                radius      = badge_r,
                CenterContainer:new{
                    dimen = Geom:new{ w = badge_d - 2 * border_sz, h = badge_d - 2 * border_sz },
                    UI.makeColoredText{
                        text    = string.format(_("%d%%"), pct_int),
                        face    = pct_face,
                        bold    = true,
                        fgcolor = _clr_blk,
                    },
                },
            }
            badge.overlap_offset = {
                math.floor((cw - badge_d) / 2),
                ch - badge_r,
            }
            cover_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = ch + badge_r },
                cover,
                badge,
            }
        else
            cover_widget = cover
        end

        -- Library-style corner badges (pages/series/new/progress) — skipped
        -- while the round percent-overlay is active; otherwise cover_widget
        -- is still exactly cw × ch here, so no extra height bookkeeping is
        -- needed.
        if not use_overlay and opts.badges then
            cover_widget = GridRenderer.applyBadges(cover_widget, bd, fp, cw, ch, opts.badges, pfx, id, use_progress_badge)
        end

        local cell = VerticalGroup:new{ align = "center", cover_widget }

        -- Captured below (when applicable) and merged into a single
        -- row_update_funcs[i] closure after this cell's elements are
        -- built — see the doc comment on row_update_funcs above and on
        -- GridRenderer.updateStats below for what bar/text patching covers.
        local _update_bar, _update_text

        if draw_progress then
            cell[#cell+1] = SH.vspan(D.RB_GAP1, ctx.vspan_pool)
            -- Wrapped in a single-slot OverlapGroup so a later refresh can
            -- just replace bar_container[1] with a freshly-built progress
            -- bar instead of rebuilding this whole cell.
            local _bar_w = cw
            local _bar_h = D.RB_BAR_H
            local _init_bar = UI.progressBar(_bar_w, bd.percent, _bar_h)
            local bar_container = OverlapGroup:new{
                dimen = _init_bar:getSize(),
                _init_bar,
            }
            cell[#cell+1] = bar_container
            _update_bar = function(nd)
                bar_container[1] = UI.progressBar(_bar_w, (nd and nd.percent or 0), _bar_h)
            end
        end

        if draw_text then
            cell[#cell+1] = SH.vspan(draw_progress and D.RB_GAP2 or D.RB_GAP1, ctx.vspan_pool)
            local _pct_fg = _clr_sub
            local pct_w = UI.makeColoredText{
                text      = opts.labelForItem and opts.labelForItem(bd)
                            or string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face      = pct_face,
                bold      = true,
                fgcolor   = _pct_fg,
                max_width = cw,
                truncate_with_ellipsis = true,
                alignment = "center",
            }
            cell[#cell+1] = pct_w
            _update_text = function(nd)
                UI.updateColoredText(pct_w,
                    opts.labelForItem and opts.labelForItem(nd)
                    or string.format(_("%d%% Read"), math.floor((nd and nd.percent or 0) * 100 + 0.5)),
                    _pct_fg)
            end
        end

        if _update_bar or _update_text then
            row_update_funcs[i] = function(nd)
                if _update_bar then _update_bar(nd) end
                if _update_text then _update_text(nd) end
            end
        end

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = cell_h },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
            _hold_fn = (opts.hold_mode == "book_dialog") and ctx.hold_fn or nil,
            _mod_id  = opts.id,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end
        -- Only registered when this module's "Long press on cover" is set
        -- to "book_dialog" (see Config.getCoverHoldMode / makeModule.build
        -- above). When it isn't, no Hold/HoldRelease events are registered
        -- here at all, so the gesture is never consumed at this level and
        -- propagates naturally to the module wrapper's HoldMod/
        -- HoldModRelease in sui_homescreen.lua, which opens the module's
        -- settings exactly as before — i.e. this is purely additive.
        if tappable._hold_fn then
            tappable.ges_events.HoldBook = {
                GestureRange:new{
                    ges   = "hold",
                    range = function() return tappable.dimen end,
                },
            }
            tappable.ges_events.HoldBookRelease = {
                GestureRange:new{
                    ges   = "hold_release",
                    range = function() return tappable.dimen end,
                },
            }
            function tappable:onHoldBook()
                -- Swallow the initial "hold" gesture so an ancestor's Hold
                -- handler doesn't also see it; the action fires on
                -- hold_release, mirroring ScreenWidget:_makeModWrapper's
                -- HoldMod/HoldModRelease pair.
                return true
            end
            function tappable:onHoldBookRelease()
                if self._hold_fn then self._hold_fn(self._fp, self._mod_id) end
                return true
            end
        end

        -- align/stretch fields dropped: SH.getBookCover is stretch-only now
        -- (infra/sui_cover_cache.lua), there's no crop alignment or elastic
        -- tolerance left to carry through to updateCovers below.
        if use_overlay then
            cover_slots[#cover_slots+1] = { container = cover_widget, idx = 1, fp = fp, w = cw, h = ch }
        else
            cover_slots[#cover_slots+1] = { container = cell, idx = 1, fp = fp, w = cw, h = ch }
        end

        cell_widget = tappable
        end -- opts.renderCell

        if ctx.kb_recent_focus_idx == i then
            local bw = Screen:scaleBySize(3)
            cell_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = cell_h },
                tappable,
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = SUIStyle.COLOR.text_primary },
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = SUIStyle.COLOR.text_primary, overlap_offset = {0, cell_h - bw} },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = SUIStyle.COLOR.text_primary },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = SUIStyle.COLOR.text_primary, overlap_offset = {cw - bw, 0} },
            }
        end

        if c > 1 then hrow[#hrow + 1] = HorizontalSpan:new{ width = gap } end
        hrow[#hrow + 1] = cell_widget
        end
    end

    -- ── Swipe between pages (wraparound), no visual indicator ───────────
    -- No chevron or bar: the row always shows up to `max_items` covers,
    -- left-aligned (HorizontalGroup starts at x=0 by default); the
    -- swipe is the only way to navigate when there are more items than
    -- fit in one row.
    local content = row
    if paged and npages > 1 then
        local screen = ctx._screen_widget
    -- Fixed height = full grid_rows, NOT row:getSize().h (which reflects
    -- only the rows actually occupied on this page). The last page may
    -- have fewer rows than an earlier page (e.g. 3x5 grid, 12 books →
    -- page 1 has 3 rows, page 2 has only 1) — sizing the eraser/swipe_area
    -- to the current page would leave a stale strip of the previous page
    -- uncleared, the same class of issue described below for the
    -- horizontal case (cols < max_items).
        local row_h = grid_rows * cell_h + math.max(0, grid_rows - 1) * row_gap
        -- Eraser: when the current page has fewer items than the previous
        -- one (cols < max_items), `row` only paints `cols` cells — the
        -- area to the right, where the previous page had more
        -- covers/labels/progress bars, is not touched by this paintTo().
        -- _refreshBookModSlot requests a partial e-ink refresh of that
        -- dimen (which always covers inner_w, a constant width — see
        -- swipe_area.dimen below), but a partial refresh only reflects
        -- what's in the framebuffer; without something repainting that
        -- area, the previous page's pixels stay there.
        -- Erase the row rect before painting content so partial rebuilds
        -- (pagination / swipe) do not leave stale pixels. With a wallpaper
        -- this restores the image sub-rect; without it, paints surface.
        local content_row = row
        do
            -- Built as a WidgetContainer instance, not a plain table, so it
            -- inherits the full widget contract (handleEvent/propagateEvent,
            -- free, ...) that OverlapGroup expects from every child it holds
            -- — same pattern as sui_quickactions_render.lua's
            -- _buildRoundedBackdrop. getSize/paintTo are overridden for this
            -- widget's custom (non-child-based) appearance.
            local eraser = WidgetContainer:new{}
            eraser.dimen = Geom:new{ w = inner_w, h = row_h }
            function eraser:getSize() return self.dimen end
            function eraser:paintTo(bb, x, y)
                local ok_wp, WP = pcall(require, "features/sui_wallpaper")
                if ok_wp and WP and WP.paintEraser then
                    WP.paintEraser(bb, x, y, self.dimen.w, self.dimen.h)
                else
                    bb:paintRect(x, y, self.dimen.w, self.dimen.h, SUIStyle.COLOR.surface)
                end
            end
            content_row = OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = row_h },
                eraser,
                row,
            }
        end
        local swipe_area = InputContainer:new{
            dimen = Geom:new{ w = inner_w, h = row_h },
            [1]   = content_row,
        }
        swipe_area.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = function() return swipe_area.dimen end } },
        }
        function swipe_area:onSwipe(_, ges)
            local dir = ges.direction
            if BD.mirroredUILayout() then
                if dir == "west" then dir = "east" elseif dir == "east" then dir = "west" end
            end
            local delta
            if dir == "west" then
                delta = 1    -- next page
            elseif dir == "east" then
                delta = -1   -- previous page
            else
                return false
            end
            -- _turnBookModPage (screen engine) owns clamping, persisting the
            -- new page in ctx, and the surgical repaint of both this row/grid
            -- and its header's "page/npages" indicator + chevrons — the same
            -- single path the chevrons themselves use. It no-ops (and this
            -- gesture is simply absorbed) when already at that edge.
            if screen and screen._turnBookModPage then
                screen:_turnBookModPage(id, delta)
            end
            return true
        end
        content = swipe_area
    end

    local result = content
    -- Seed dimen so paintTo can fill absolute x/y in place. Needed for
    -- swipe hit-testing and partial refreshes when this widget is the
    -- direct body child (no menu wrapper).
    local sz = result:getSize()
    result.dimen = Geom:new{ w = sz.w, h = sz.h }
    result._cover_slots = cover_slots
    -- Snapshot for GridRenderer.updateStats (below): the exact file list
    -- this widget was built with (already sliced to the current page), the
    -- per-cell patch closures, and the progress_style it was built with —
    -- updateStats bails to a full rebuild if any of these no longer match
    -- what's live. opts.renderCell cells never populate row_update_funcs,
    -- so a renderCell-based module (e.g. Collections) naturally ends up
    -- with an empty table here.
    result._row_fps             = page_fps
    result._row_update_funcs    = row_update_funcs
    result._row_progress_style  = progress_style
    result._row_uses_render_cell = opts.renderCell and true or false
    return result
end

-- ---------------------------------------------------------------------------
-- updateCovers(widget, ctx) — patches every cover slot recorded by build()
-- in place, calling SH.getBookCover for each. Returns true once every slot
-- either has its final cover or is confirmed missing.
-- ---------------------------------------------------------------------------
function GridRenderer.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- ---------------------------------------------------------------------------
-- updateStats(widget, ctx, opts) — in-place stats refresh for a widget
-- previously returned by build(), mirroring module_currently.updateStats/
-- module_coverdeck.updateStats. Patches only each cell's progress bar/text
-- via the closures build() captured into widget._row_update_funcs; never
-- touches cover images, corner badges, or the round percent-overlay — the
-- guards below fall back to a full rebuild for any of those. Returns true
-- if the patch was applied, false if the caller must fall back to a full
-- mod.build() instead (identity mismatch, or a style/cell kind this
-- function can't patch) — same true/false contract as
-- module_currently.updateStats.
--
-- Does not trust ctx[cache_key] to already hold the right list — callers
-- (see sui_screen_engine.lua's debounced post-reader-return refresh) may
-- run GridRenderer.clearRowCaches(ctx) first, so the full-rebuild fallback
-- stays correct for modules without their own updateStats. This function
-- re-derives the filtered file list from opts.getFileList()/opts.filterItem
-- itself, exactly like build()'s own cold-cache path, and only once
-- everything else checks out writes the result back into ctx[cache_key].
--
-- Also keeps ctx[npages_key] current even on the true-returning path: the
-- displayed page's own slice can stay identical while the total item count
-- crosses a page boundary elsewhere in the list, so npages must be
-- refreshed independently of the identity check below. The caller is
-- expected to re-sync the section-label header (page indicator + chevrons)
-- off the back of this, via ScreenWidget:_syncBookModLabel — see that
-- function's doc comment.
-- ---------------------------------------------------------------------------
function GridRenderer.updateStats(widget, ctx, opts)
    if not widget or not widget._row_update_funcs then return false end
    -- Defensive: row_opts.getFileList is only populated once M.build has
    -- run at least once for this module (see makeModule). In practice a
    -- widget can't exist yet without that having happened already (build()
    -- is what creates the slot this widget came from), but this keeps the
    -- fallback graceful instead of erroring if that assumption is ever
    -- violated by a future caller.
    if not opts.getFileList then return false end

    -- Custom cells (module_collections.lua's renderCell) have arbitrary
    -- internal structure this generic mechanism knows nothing about —
    -- row_update_funcs is always empty for them, so patching would
    -- silently do nothing while still reporting success. Fall back to a
    -- full rebuild instead.
    if widget._row_uses_render_cell then return false end

    local id  = opts.id
    local pfx = ctx.pfx

    -- Style must be both patchable and unchanged since this widget was
    -- built (mirrors build()'s draw_progress/draw_text/use_overlay/
    -- use_progress_badge derivation).
    local progress_style = GridRenderer.getProgressStyle(pfx, id, opts.progress_style or {})
    if progress_style ~= widget._row_progress_style then return false end
    if progress_style == "overlay" or progress_style == "badge" then return false end

    -- Corner badges whose content depends on percent/status (Pages hides
    -- once a book is finished; New disappears once a book is opened at
    -- all) would go stale under a text/bar-only patch — bail to a full
    -- rebuild. Series doesn't depend on percent/status, so its presence
    -- alone doesn't block the fast path.
    if opts.badges then
        local show_pages = GridRenderer.showBadgePages(pfx, id, opts.badges.pages)
        local new_mode    = GridRenderer.getBadgeNewMode(pfx, id, opts.badges.new)
        if show_pages or new_mode ~= "none" then return false end
    end

    -- Re-derive the filtered file list exactly like build()'s cold-cache
    -- path.
    local cache_key = opts.cache_key or ("_row_fps_" .. id)
    local fps = ctx[cache_key] or _filterFileList(opts.getFileList() or {}, opts, ctx)

    -- Re-derive which page/slice is on screen right now, same math as
    -- build(). grid_rows/grid_cols come from `opts` (kept current by
    -- makeModule's M.build on every call, same table this function
    -- receives), not re-read from settings here, so this always agrees
    -- with what build() last actually used. persist=false: a stats-only
    -- refresh must not move the page as a side effect (never clamps the
    -- stored page). npages, unlike page, isn't a user-facing selection —
    -- it's a plain fact derived from the current file count — so it's
    -- written back into ctx unconditionally below, same as build() already
    -- does at its own call site, keeping the section-label's "x/y"
    -- indicator and chevrons (sui_screen_engine.lua's pageIndicatorFor/
    -- pageNavFor, both reading ctx) accurate even when this fast path
    -- succeeds instead of falling back to a full build().
    local grid_rows = opts.grid_rows or 1
    local grid_cols = opts.grid_cols or opts.max_items or 5
    local max_items = grid_rows * grid_cols
    local _, npages, page_fps = _resolveCurrentPage(fps, ctx, id, max_items, opts.paged, false)
    ctx["_row_npages_" .. id] = npages

    -- Identity check: same files, same order, same count as what this
    -- widget was actually built with. Any difference means the row's
    -- membership/position genuinely changed (e.g. a book was just
    -- finished and dropped out, or jumped to the front of Recent) — real
    -- content the patch closures can't express, so fall back.
    local prev = widget._row_fps
    if not prev or #prev ~= #page_fps then return false end
    for i = 1, #page_fps do
        if prev[i] ~= page_fps[i] then return false end
    end

    -- Everything still matches: persist the (re)computed list so a later
    -- build() on this same ctx doesn't redo this work, then patch every
    -- cell in place.
    ctx[cache_key] = fps

    local SH = getSH()
    if not SH then return false end
    for i, fp in ipairs(page_fps) do
        local fn = widget._row_update_funcs[i]
        if fn then
            local bd = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
            fn(bd)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- getHeight(ctx, opts) — opts:
--   id, progress_style?  (see GridRenderer.build)
--   max_items?       replicates build()'s cover sizing: the base is
--                     always the auto-fit size, and Scale/Cover Size is a
--                     multiplier on top of that base. Since this function
--                     doesn't receive the real column width, it uses
--                     ctx.col_w/ctx.inner_w when available, or an estimate
--                     from the screen in their absence (e.g. layout editor
--                     preview).
--   grid_rows/grid_cols  number?  see build() — must reflect the same
--                     values passed to build(), or the reserved height
--                     diverges from the actual drawn height.
-- ---------------------------------------------------------------------------
function GridRenderer.getHeight(_ctx, opts)
    local id  = opts.id
    local progress_style_cfg = opts.progress_style or {}
    local pfx = _ctx and _ctx.pfx or ""
    local lf = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local scale       = Config.getModuleScale(id, pfx) * lf
    local thumb_scale = Config.getThumbScale(id, pfx) * lf
    local lbl_scale   = Config.getItemLabelScale(id, pfx) * lf
    local SH  = getSH()
    local D   = SH.getDims(scale, thumb_scale)

    -- Mirrors build(): grid_cols decides the cell width, not
    -- grid_rows*grid_cols.
    local grid_rows = opts.grid_rows or 1
    local grid_cols = opts.grid_cols or opts.max_items or 5
    local w = (_ctx and (_ctx.col_w or _ctx.inner_w))
              or (Screen:getWidth() - UI.SIDE_PAD * 2)
    -- Frame border / solid background — computed up front so inner_w below
    -- mirrors build()'s own corrected value exactly (see build()'s comment
    -- on why the border must be reserved here too, not just the padding).
    local box = { inset_h = 0, inset_v = 0 }
    local inner_w = w

    -- cs uses the raw getters — mirrors build()'s cs above.
    local cs = Config.getModuleScaleRaw(id, pfx) * Config.getThumbScaleRaw(id, pfx)
    local cw, gap_for_row = GridRenderer.computeAutoFitCell(inner_w, grid_cols, cs)
    local rh = math.max(1, math.floor(cw * (D.RECENT_H / D.RECENT_W)))
    -- Same vertical gap used in build() — half the horizontal gap.
    local row_gap = math.max(0, math.floor(gap_for_row / 2))

    -- Must exactly mirror GridRenderer.build's `cell_h` — same reading of
    -- progress_style, and the same cellExtraHeight() — or the reserved
    -- height diverges from the real content. progress_style is a
    -- module-level setting (pfx+id), not per-book, so it applies equally
    -- to the whole grid, just like in build(). "badge" style is absent
    -- from this derivation — corner badges stay inside the cw×ch cell (see
    -- applyBadges' doc comment), so they never add extra height.
    --
    -- label_h: measured via the same face used in build()
    -- (face.ftsize:getHeightAndAscender(), the real freetype/KOReader API)
    -- so it always matches the actual glyph height, not a fixed constant.
    local progress_style = GridRenderer.getProgressStyle(pfx, id, progress_style_cfg)
    local draw_progress  = progress_style == "bar"  or progress_style == "bar_text"
    local draw_text      = progress_style == "text" or progress_style == "bar_text"
    local use_overlay    = progress_style == "overlay"
    local pct_fs   = math.max(8, math.floor(_BASE_RB_PCT_FS * scale * lbl_scale))
    local pct_face = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)
    local ok_h, face_height = pcall(function() return pct_face.ftsize:getHeightAndAscender() end)
    local label_h  = (ok_h and face_height and math.ceil(face_height)) or math.ceil(pct_fs * 1.8)
    -- opts.getCellHeight: see the twin note in build() — must return
    -- exactly the same value for the same cw, or the height reserved here
    -- diverges from the actual drawn content.
    local cell_h
    if opts.getCellHeight then
        cell_h = opts.getCellHeight(cw, pfx)
    else
        cell_h = rh
        if use_overlay then
            local badge_r = math.floor(cw * 0.28)
            cell_h = cell_h + badge_r
        else
            cell_h = cell_h + cellExtraHeight(draw_progress, draw_text, D.RB_GAP1, D.RB_BAR_H, D.RB_GAP2, label_h)
        end
    end
    -- grid_rows rows of cell_h + (grid_rows-1) vertical gaps between them —
    -- frame/border/padding (below) belong to the whole grid, not per row,
    -- so they stay outside this multiplication.
    local h = grid_rows * cell_h + math.max(0, grid_rows - 1) * row_gap

    -- box.inset_v already folds in the border (FrameContainer draws it
    -- outside the padding — see computeBox's doc comment), so no separate
    -- border_sz*2 addition is needed here.
    h = h + box.inset_v
    return Config.getScaledLabelH() + h
end

-- ---------------------------------------------------------------------------
-- getBookTitle(fp) — short title for arrangement lists (Arrange).
-- ---------------------------------------------------------------------------
function GridRenderer.getBookTitle(fp)
    local title = fp:match("([^/]+)%.[^%.]+$") or fp
    pcall(function()
        local DS = require("docsettings")
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            local rp = ds:readSetting("doc_props") or {}
            if rp.title and rp.title ~= "" then title = rp.title end
            pcall(function() ds:close() end)
        end
    end)
    if #title > 48 then title = title:sub(1, 45) .. "…" end
    return title
end

-- ---------------------------------------------------------------------------
-- listAllCollectionNames(exclude_names) → { name, ... }
--
-- All collections known to ReadCollection, with "favorites" first (if it
-- exists), sorted alphabetically after that.
-- exclude_names: optional { [name] = true, ... } — collections to omit
-- (e.g. the TBR collection, which already has its own module).
-- ---------------------------------------------------------------------------
function GridRenderer.listAllCollectionNames(exclude_names)
    local ok_rc, rc = pcall(require, "readcollection")
    local all = {}
    if not (ok_rc and rc) then return all end
    -- Not calling rc:_read() — it destructively reloads rc.coll/rc.coll_settings
    -- from disk and can wipe an in-memory-only collection the native
    -- Collections UI hasn't flushed to disk yet. The singleton is already
    -- live in-process.
    local fav = rc.default_collection_name or "favorites"
    local coll_set = {}
    if rc.coll then for n in pairs(rc.coll) do coll_set[n] = true end end
    if rc.coll_folders then for n in pairs(rc.coll_folders) do coll_set[n] = true end end
    if exclude_names then
        for n in pairs(exclude_names) do coll_set[n] = nil end
    end
    if coll_set[fav] then
        all[#all + 1] = fav
        coll_set[fav] = nil
    end
    local others = {}
    for name in pairs(coll_set) do others[#others + 1] = name end
    table.sort(others, function(a, b) return a:lower() < b:lower() end)
    for _, n in ipairs(others) do all[#all + 1] = n end
    return all
end

-- ---------------------------------------------------------------------------
-- getCollectionFileList(coll_name) → { fp, ... } sorted by RC "order"
--
-- Same read logic as module_tbr.getTBRList(), but for any
-- collection. Filters out entries whose file no longer exists on disk.
-- ---------------------------------------------------------------------------
function GridRenderer.getCollectionFileList(coll_name)
    if not coll_name then return {} end
    local ok_rc, rc = pcall(require, "readcollection")
    if not (ok_rc and rc) then return {} end
    -- Not calling rc:_read() — see note in listAllCollectionNames() above.
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    local lfs = require("libs/libkoreader-lfs")
    local items = {}
    for _, item in pairs(coll) do
        if lfs.attributes(item.file, "mode") == "file" then
            items[#items + 1] = item
        end
    end
    table.sort(items, function(a, b) return (a.order or 0) < (b.order or 0) end)
    local fps = {}
    for _, item in ipairs(items) do fps[#fps + 1] = item.file end
    return fps
end

-- ---------------------------------------------------------------------------
-- sortCollection(coll_name, mode) → bool (success)
--
-- Recomputes and persists a collection's order via RC:updateCollectionOrder,
-- exactly like manual "Arrange" — i.e. this is a one-shot
-- action: after sorting, the user can still reorder by hand
-- on top of the result.
--
-- mode:
--   "title_asc" | "title_desc"     — by title (GridRenderer.getBookTitle)
--   "author_asc"                   — by author (SH.getBookData(fp).authors)
--   "percent_asc" | "percent_desc" — by reading progress
--   "shuffle"                      — random order
-- ---------------------------------------------------------------------------
function GridRenderer.sortCollection(coll_name, mode)
    if not coll_name then return false end
    local ok_rc, rc = pcall(require, "readcollection")
    if not (ok_rc and rc) then return false end
    -- Not calling rc:_read() — see note in listAllCollectionNames() above.
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return false end

    local fps = GridRenderer.getCollectionFileList(coll_name)
    if #fps < 2 then return false end

    local SH = getSH()
    if mode == "title_asc" or mode == "title_desc" then
        local titles = {}
        for _, fp in ipairs(fps) do titles[fp] = GridRenderer.getBookTitle(fp):lower() end
        table.sort(fps, function(a, b)
            if mode == "title_asc" then return titles[a] < titles[b] else return titles[a] > titles[b] end
        end)
    elseif mode == "author_asc" then
        local authors = {}
        for _, fp in ipairs(fps) do
            local bd = SH.getBookData(fp)
            authors[fp] = (bd.authors or ""):lower()
        end
        table.sort(fps, function(a, b) return authors[a] < authors[b] end)
    elseif mode == "percent_asc" or mode == "percent_desc" then
        local pct = {}
        for _, fp in ipairs(fps) do
            local bd = SH.getBookData(fp)
            pct[fp] = bd.percent or 0
        end
        table.sort(fps, function(a, b)
            if mode == "percent_asc" then return pct[a] < pct[b] else return pct[a] > pct[b] end
        end)
    elseif mode == "shuffle" then
        for i = #fps, 2, -1 do
            local j = math.random(i)
            fps[i], fps[j] = fps[j], fps[i]
        end
    else
        return false
    end

    local ordered = {}
    for _, fp in ipairs(fps) do
        local entry = coll[fp]
        if entry then ordered[#ordered + 1] = entry end
    end
    rc:updateCollectionOrder(coll_name, ordered)
    rc:write({ [coll_name] = true })
    return true
end

-- ---------------------------------------------------------------------------
-- clearRowCaches(ctx) — invalidates every row module's cached file list
-- (ctx[cache_key], populated lazily on a row module's first build() call
-- within a given ctx and never invalidated again for that ctx's lifetime),
-- plus the section-label header cache (page/npages indicator + chevrons)
-- that any paginated row module keeps in sync with that same file list.
--
-- Needed because a "kept-alive" ctx (sui_screen_engine.lua's
-- _refreshImmediate with keep_cache=true, used after book-hold-dialog
-- actions like status changes, collection membership, or TBR add/remove —
-- full rebuilds are avoided there since cover prefetch and config gathering
-- are expensive) otherwise keeps serving each row's pre-action file list
-- forever: e.g. a book just removed from TBR still shows in the TBR row
-- until the whole screen is rebuilt. Per-row lists are cheap to recompute
-- (a ReadCollection/settings lookup, not the I/O keep_cache protects), so
-- clearing them on every refresh — even a "kept-alive" one — is cheap
-- insurance.
--
-- The label-cache invalidation lives here (rather than at each call site)
-- because it is the SAME underlying condition every clearRowCaches() caller
-- already has: a paginated row's file list is changing, which can shift
-- its page/npages. sui_screen_engine.lua's sectionLabel() memoizes each
-- row's header (text + chevrons) by "mod_id|page|npages", not by the
-- ScreenWidget instance the chevrons' tap handler closes over — so if the
-- recomputed page/npages happens to match a combination already cached
-- under a since-replaced instance (rotation, tab switch, a Custom Screen
-- reopen, ...), the row would keep showing a header wired to a dead
-- closure: no error, the chevrons would just silently do nothing.
-- Invalidating unconditionally here, alongside the file-list clear that
-- already has to happen at the same moment, means every current and future
-- clearRowCaches() caller is covered automatically, instead of relying on
-- each one to separately remember to also invalidate the label cache.
-- engines/sui_screen_engine.lua is required lazily (pcall, same pattern
-- that file already uses in the other direction for sui_book_grid.lua) to
-- avoid a load-order dependency between the two engines.
-- ---------------------------------------------------------------------------
function GridRenderer.clearRowCaches(ctx)
    if not ctx then return end
    for key in pairs(GridRenderer._known_row_cache_keys) do
        ctx[key] = nil
    end
    local ok_se, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if ok_se and ScreenEngine and ScreenEngine.invalidateLabelCache then
        ScreenEngine.invalidateLabelCache()
    end
end

-- ---------------------------------------------------------------------------
-- makeModule(spec) → M
--
-- High-level factory: generates a complete module (build/getHeight/
-- updateCovers/getMenuItems) from a declarative table. Reduces each
-- concrete "cover row" module to just its actual differences.
--
-- spec:
--   id            string   (required) — settings namespace + M.id
--   name          string   (required) — M.name (name shown in "Add Module")
--   label         string?  — default section label text
--   label_fn      function? (pfx) -> string — dynamic label (overrides label)
--   default_on    bool?    (default false)
--   is_book_mod   bool?    (default false) — see moduleregistry.lua
--   max_items     number?  (default 5)
--   paged         bool?    (default false) — see GridRenderer.build
--   getFileList   function (ctx) -> { fp, ... }  (required)
--   cache_key     string?
--   filterItem    function? (fp, ctx) -> bool
--   labelForItem  function? (bd) -> string
--   progress_style  table?  { default=style, locked=style, allowed={style,...} }
--       — see GridRenderer.getProgressStyle's doc comment for the full
--       field reference and the values a style can take.
--   badges        table?   { pages=mode, series=mode, new=mode }
--       — Library-style corner badges (see GridRenderer.applyBadges). Size
--       comes from the shared Library "Badges" settings, not from here;
--       color defaults there too but can be overridden per module instance
--       (see badge_colors below). The fourth Library badge, Progress, is
--       not here — it's progress_style="badge" above.
--   badge_colors  bool?    (default true) — when true, each enabled badge
--       (pages/series/new, and the progress corner badge) gets its own
--       "Color" submenu (Follow Library/Dark/Light) next to its toggle.
--       Set to false for a module that wants a shorter menu and is fine
--       always following the shared Library color.
--   extra_settings  { { key, label, default }, ... }?  — additional toggles
--       (settings key = pfx..id.."_"..key; appear in the menu after the
--       default toggles; the value read is accessible to getFileList/
--       filterItem via SUISettings, not passed automatically — each spec
--       reads what it needs from its own closure)
--   extra_menu_items_before  function? (ctx_menu) -> { item, ... }
--   extra_menu_items_after   function? (ctx_menu) -> { item, ... }
--   updateCovers  function? — replaces GridRenderer.updateCovers (e.g. for
--       a more sophisticated in-place patch optimization)
--   updateStats   function? — replaces GridRenderer.updateStats (the
--       in-place percent bar/text patch tried before a full build() on the
--       debounced post-reader-return refresh — see that function's own doc
--       comment for exactly what it patches and when it bails to a full
--       rebuild instead). Only needed if a module's cell layout isn't the
--       default "cover + bar + text" shape GridRenderer.build() produces
--       (e.g. it uses spec.renderCell) and still wants a working fast path;
--       renderCell-based modules (e.g. Collections) get a correct, safe
--       default of "always fall back to build()" without setting this.
--   reset         function? — exposed as M.reset (cleanup of the module's
--       internal caches; called on plugin teardown)
--   enabled_key   string?  (default id.."_enabled")
--   isEnabled     function? (pfx) -> bool — replaces enabled_key/default_on
--   grid          bool?    (default false) — when true, exposes "Rows"
--       (1-3) and "Columns" (4-5) in the menu, read/saved via
--       GridRenderer.getGridRows/getGridCols (settings pfx..id.."_grid_rows"/
--       "_grid_cols"). When false, the module stays a single row with
--       max_items columns.
--   cols_choice   bool?    (default false) — lightweight sibling of
--       spec.grid: exposes a single "Number of Books" choice (4 or 5) in
--       the menu, backed by the same GridRenderer.getGridCols/setGridCols
--       storage (settings pfx..id.."_grid_cols"), but never reads/writes
--       grid_rows — the module stays a single row, only the column count
--       changes. Ignored when spec.grid is true (that already covers
--       columns, with rows on top). Use for single-row "cover row" modules
--       that should let the user pick how many covers are shown without
--       gaining spec.grid's multi-row/pagination behaviour.
--   default_rows  number?  (default 1) — only relevant with spec.grid = true
--   default_cols  number?  (default max_items or 5) — relevant with
--       spec.grid = true or spec.cols_choice = true
-- ---------------------------------------------------------------------------
function GridRenderer.makeModule(spec)
    assert(spec.id, "makeModule: spec.id is required")
    assert(spec.getFileList, "makeModule: spec.getFileList is required")

    local id             = spec.id
    local progress_style = spec.progress_style or {}
    local badges         = spec.badges or {}

    local M = {}
    M.id          = id
    M.name        = spec.name or id
    M.label       = spec.label
    M.enabled_key = spec.enabled_key or (id .. "_enabled")
    M.default_on  = spec.default_on or false
    M.has_covers  = true
    if spec.is_book_mod then M.is_book_mod = true end
    if spec.isEnabled    then M.isEnabled    = spec.isEnabled end
    if spec.reset         then M.reset         = spec.reset end

    local row_opts = {
        id            = id,
        max_items     = spec.max_items or 5,
        cache_key     = spec.cache_key,
        paged         = spec.paged,
        filterItem    = spec.filterItem,
        labelForItem  = spec.labelForItem,
        progress_style = progress_style,
        -- renderCell/getCellHeight: see the notes in GridRenderer.build/
        -- getHeight. Allow a spec to fully replace the "book cover" cell
        -- with its own (e.g. module_collections.lua).
        renderCell    = spec.renderCell,
        getCellHeight = spec.getCellHeight,
        -- Library-style corner badges — opt-in per module, see
        -- GridRenderer.applyBadges. { pages=mode, series=mode, new=mode },
        -- same "on"/"off"/"locked_*" convention as elsewhere in this file.
        -- (Progress is not here — it's one of the progress_style values
        -- above; see GridRenderer.getProgressStyle's doc comment.)
        badges        = spec.badges,
    }
    GridRenderer._known_row_cache_keys[spec.cache_key or ("_row_fps_" .. id)] = true

    -- Read from settings on every call (not once in makeModule), since the
    -- user can change them at runtime via the "Rows"/"Columns" menu below.
    --
    -- spec.cols_choice is the lightweight sibling of spec.grid: it reuses
    -- the same GRID_COLS_MIN/MAX (4-5) + getGridCols/setGridCols storage,
    -- but never touches grid_rows, so build()/getHeight() fall back to
    -- their own "grid_rows or 1" default — the module stays a single row,
    -- only the column count is user-editable. Use this instead of
    -- spec.grid whenever a module is a single "cover row" that should not
    -- gain pagination/multi-row layout.
    local function _gridDims(pfx)
        if spec.grid then
            return GridRenderer.getGridRows(pfx, id, spec.default_rows),
                   GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items)
        end
        if spec.cols_choice then
            return nil, GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items)
        end
        return nil, nil
    end

    function M.build(w, ctx)
        local lbl = spec.label_fn and spec.label_fn(ctx.pfx) or spec.label
        if lbl then Config.applyLabelToggle(M, lbl) end
        row_opts.getFileList = function() return spec.getFileList(ctx) end
        row_opts.grid_rows, row_opts.grid_cols = _gridDims(ctx.pfx)
        -- Read at build time (not once in makeModule) so a change made in
        -- the "Long press on cover" submenu takes effect on the next repaint.
        row_opts.hold_mode = Config.getCoverHoldMode(id, ctx.pfx)
        return GridRenderer.build(w, ctx, row_opts)
    end

    function M.getHeight(ctx)
        local grid_rows, grid_cols = _gridDims(ctx and ctx.pfx)
        return GridRenderer.getHeight(ctx, {
            id             = id,
            progress_style = progress_style,
            max_items      = spec.max_items or 5,
            grid_rows      = grid_rows,
            grid_cols      = grid_cols,
            getCellHeight  = spec.getCellHeight,
        })
    end

    function M.updateCovers(widget, ctx)
        if spec.updateCovers then return spec.updateCovers(widget, ctx) end
        return GridRenderer.updateCovers(widget, ctx)
    end

    -- In-place stats refresh (percent bar/text only — see
    -- GridRenderer.updateStats' doc comment for exactly what is and isn't
    -- patched). Reuses the same row_opts table M.build keeps current on
    -- every call, so grid_rows/grid_cols/getFileList/filterItem/etc. here
    -- always agree with what M.build most recently used.
    function M.updateStats(widget, ctx)
        if spec.updateStats then return spec.updateStats(widget, ctx) end
        return GridRenderer.updateStats(widget, ctx, row_opts)
    end

    function M.getMenuItems(ctx_menu)
        local _lc    = ctx_menu._
        local refresh = ctx_menu.refresh
        local pfx    = ctx_menu.pfx
        local items  = {}

        if spec.extra_menu_items_before then
            for _, it in ipairs(spec.extra_menu_items_before(ctx_menu)) do
                items[#items + 1] = it
            end
        end

        -- Size / Appearance / Progress and Badges are grouped into their
        -- own submenus instead of sitting as ~13 flat sibling rows.
        local size_group = {}

        size_group[#size_group + 1] = Config.makeScaleItem{
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct(id, pfx) end,
            set          = function(v) Config.setModuleScale(v, id, pfx) end,
            refresh      = refresh,
        }
        size_group[#size_group + 1] = Config.makeScaleItem{
            text_func = function() return _lc("Text Size") end,
            title     = _lc("Text Size"),
            info      = _lc("Scale for the percentage read text.\n100% is the default size."),
            get       = function() return Config.getItemLabelScalePct(id, pfx) end,
            set       = function(v) Config.setItemLabelScale(v, id, pfx) end,
            refresh   = refresh,
        }
        size_group[#size_group + 1] = Config.makeScaleItem{
            text_func = function() return _lc("Cover Size") end,
            separator = (spec.grid or spec.cols_choice) and true or false,
            title     = _lc("Cover Size"),
            info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct(id, pfx) end,
            set       = function(v) Config.setThumbScale(v, id, pfx) end,
            refresh   = refresh,
        }

        if spec.cols_choice then
            -- Lightweight sibling of the "Grid size" double-stepper below:
            -- same SpinWidget-backed single-value stepper
            -- (Config.makeStepperItem) for a consistent widget/feel across
            -- the whole "Size" submenu, but only Columns (4-5) — no Rows —
            -- reusing the same GRID_COLS_MIN/MAX-backed storage. See
            -- _gridDims' doc comment above for why this doesn't also
            -- expose Rows.
            size_group[#size_group + 1] = Config.makeStepperItem{
                text_func     = function() return _lc("Number of Books") end,
                title         = _lc("Number of Books"),
                get           = function() return GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items) end,
                set           = function(v) GridRenderer.setGridCols(pfx, id, v) end,
                value_min     = GridRenderer.GRID_COLS_MIN,
                value_max     = GridRenderer.GRID_COLS_MAX,
                default_value = spec.default_cols or spec.max_items or 5,
                refresh       = refresh,
            }
        end

        if spec.grid then
            -- Same widget/convention that native KOReader uses in "Items
            -- per page in mosaic mode": Columns + Rows in the same dialog,
            -- one Apply — instead of two separate SpinWidgets.
            size_group[#size_group + 1] = Config.makeDoubleStepperItem{
                text_func = function() return _lc("Grid size") end,
                value_func = function()
                    return T(_lc("%1 × %2"),
                              GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items),
                              GridRenderer.getGridRows(pfx, id, spec.default_rows))
                end,
                mandatory_func = function()
                    return T(_lc("%1 × %2"),
                              GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items),
                              GridRenderer.getGridRows(pfx, id, spec.default_rows))
                end,
                title     = _lc("Grid size"),
                left = {
                    text          = _lc("Columns"),
                    get           = function() return GridRenderer.getGridCols(pfx, id, spec.default_cols or spec.max_items) end,
                    set           = function(v) GridRenderer.setGridCols(pfx, id, v) end,
                    value_min     = GridRenderer.GRID_COLS_MIN,
                    value_max     = GridRenderer.GRID_COLS_MAX,
                    default_value = spec.default_cols or spec.max_items or 5,
                },
                right = {
                    text          = _lc("Rows"),
                    get           = function() return GridRenderer.getGridRows(pfx, id, spec.default_rows) end,
                    set           = function(v) GridRenderer.setGridRows(pfx, id, v) end,
                    value_min     = GridRenderer.GRID_ROWS_MIN,
                    value_max     = GridRenderer.GRID_ROWS_MAX,
                    default_value = spec.default_rows or 1,
                },
                refresh = refresh,
            }
        end

        items[#items + 1] = {
            text_func      = function() return _lc("Size") end,
            sub_item_table = size_group,
        }

        -- Appearance: label visibility + static visual chrome (frame,
        -- solid background). Grouped separately from Size since these are
        -- checkboxes rather than value pickers, and touched far less often.
        local appearance_group = {}

        local lbl = spec.label_fn and spec.label_fn(pfx) or spec.label
        if lbl then
            appearance_group[#appearance_group + 1] = Config.makeLabelToggleItem(id, lbl, refresh, _lc)
        end

        if #appearance_group > 0 then
            items[#items + 1] = {
                text_func      = function() return _lc("Appearance") end,
                separator      = true,
                sub_item_table = appearance_group,
            }
        end

        -- Long Press stays a top-level row (unchanged) — it's already a
        -- single compact row with its own submenu, so nesting it one level
        -- deeper would gain nothing.
        items[#items + 1] = Config.makeCoverHoldModeItem{
            mod_id            = id,
            pfx               = pfx,
            refresh           = refresh,
            _lc               = _lc,
            book_dialog_label = spec.hold_dialog_label,
        }

        if not spec.renderCell then
            local pb_group = {}
            local badge_colors_on = spec.badge_colors ~= false

            -- "Follow Library" (nil) / Dark / Light — same 3-way choice for
            -- every badge; factored out to avoid repeating the option list
            -- four times below.
            local function _colorOptions()
                return {
                    { value = nil,     label = _lc("Follow Library") },
                    { value = "dark",  label = _lc("Dark") },
                    { value = "light", label = _lc("Light") },
                }
            end
            local function _colorItem(text, badge_key, enabled_func)
                return Config.makeRadioSubmenuItem{
                    text         = text,
                    enabled_func = enabled_func,
                    options      = _colorOptions(),
                    get          = function() return GridRenderer.getBadgeColorOverride(pfx, id, badge_key) end,
                    set          = function(v) GridRenderer.setBadgeColor(pfx, id, badge_key, v) end,
                    refresh      = refresh,
                }
            end

            -- Each badge's settings (style/toggle + color) are grouped
            -- into one named submenu instead of sitting as flat sibling
            -- rows — "Progress Indicator" for progress, and likewise for
            -- the other three badges below.

            -- Progress Style is one picker covering all six visual states
            -- (see GridRenderer.getProgressStyle's doc comment).
            if not progress_style.locked then
                local all_styles = {
                    { value = "none",     label = _lc("None") },
                    { value = "bar",      label = _lc("Bar") },
                    { value = "text",     label = _lc("Text") },
                    { value = "bar_text", label = _lc("Bar + Text") },
                    { value = "overlay",  label = _lc("Round Overlay") },
                    { value = "badge",    label = _lc("Corner Badge") },
                }
                local style_options = all_styles
                if progress_style.allowed then
                    local allowed_set = {}
                    for _, a in ipairs(progress_style.allowed) do allowed_set[a] = true end
                    style_options = {}
                    for _, o in ipairs(all_styles) do
                        if allowed_set[o.value] then style_options[#style_options + 1] = o end
                    end
                end
                local progress_group = {
                    Config.makeRadioSubmenuItem{
                        text    = _lc("Progress Style"),
                        options = style_options,
                        get     = function() return GridRenderer.getProgressStyle(pfx, id, progress_style) end,
                        set     = function(v) GridRenderer.setProgressStyle(pfx, id, v) end,
                        refresh = refresh,
                    },
                }
                if badge_colors_on then
                    progress_group[#progress_group + 1] = _colorItem(_lc("Progress Badge Color"), "progress", function()
                        return GridRenderer.getProgressStyle(pfx, id, progress_style) == "badge"
                    end)
                end
                pb_group[#pb_group + 1] = {
                    text_func  = function() return _lc("Progress Indicator") end,
                    value_func = function()
                        local style = GridRenderer.getProgressStyle(pfx, id, progress_style)
                        for _, o in ipairs(style_options) do
                            if o.value == style then return o.label end
                        end
                        return ""
                    end,
                    sub_item_table = progress_group,
                }
            end

            -- Library-style corner badges — only shown for modules that opt
            -- in via spec.badges (not every book-grid module needs all
            -- three; e.g. "New"/"Series" are redundant on the New Books
            -- module itself). Color and size are both per-module here —
            -- color falls back to the shared Library color when left on
            -- "Follow Library"; size (below) is independent from every
            -- other module and from the Library grid's own badge size —
            -- see GridRenderer.getBadgeScale's doc comment for why.
            pb_group[#pb_group + 1] = Config.makeScaleItem{
                text_func     = function() return _lc("Badge Size") end,
                separator     = true,
                title         = _lc("Badge Size"),
                info          = _lc("Scale for this module's corner badges (progress, pages, series, new book)."),
                get           = function() return GridRenderer.getBadgeScalePct(pfx, id) end,
                set           = function(v) GridRenderer.setBadgeScale(pfx, id, v) end,
                value_min     = GridRenderer.BADGE_SCALE_MIN,
                value_max     = GridRenderer.BADGE_SCALE_MAX,
                value_step    = GridRenderer.BADGE_SCALE_STEP,
                default_value = GridRenderer.BADGE_SCALE_DEF,
                refresh       = refresh,
            }
            if not _toggleLocked(badges.pages) then
                local pages_group = {
                    {
                        text           = _lc("Pages Badge"),
                        checked_func   = function() return GridRenderer.showBadgePages(pfx, id, badges.pages) end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:saveSetting(pfx .. id .. "_badge_pages",
                                not GridRenderer.showBadgePages(pfx, id, badges.pages))
                            refresh()
                        end,
                    },
                }
                if badge_colors_on then
                    pages_group[#pages_group + 1] = _colorItem(_lc("Pages Badge Color"), "pages", function()
                        return GridRenderer.showBadgePages(pfx, id, badges.pages)
                    end)
                end
                pb_group[#pb_group + 1] = {
                    text_func  = function() return _lc("Pages Badge") end,
                    value_func = function()
                        return GridRenderer.showBadgePages(pfx, id, badges.pages) and _lc("On") or _lc("Off")
                    end,
                    sub_item_table = pages_group,
                }
            end
            if not _toggleLocked(badges.series) then
                local series_group = {
                    {
                        text           = _lc("Series Badge"),
                        checked_func   = function() return GridRenderer.showBadgeSeries(pfx, id, badges.series) end,
                        keep_menu_open = true,
                        callback       = function()
                            SUISettings:saveSetting(pfx .. id .. "_badge_series",
                                not GridRenderer.showBadgeSeries(pfx, id, badges.series))
                            refresh()
                        end,
                    },
                }
                if badge_colors_on then
                    series_group[#series_group + 1] = _colorItem(_lc("Series Badge Color"), "series", function()
                        return GridRenderer.showBadgeSeries(pfx, id, badges.series)
                    end)
                end
                pb_group[#pb_group + 1] = {
                    text_func  = function() return _lc("Series Badge") end,
                    value_func = function()
                        return GridRenderer.showBadgeSeries(pfx, id, badges.series) and _lc("On") or _lc("Off")
                    end,
                    sub_item_table = series_group,
                }
            end
            if not _toggleLocked(badges.new) then
                local new_options = {
                    { value = "none",   label = _lc("None") },
                    { value = "badge",  label = _lc("Badge") },
                    { value = "ribbon", label = _lc("Ribbon") },
                }
                local new_group = {
                    Config.makeRadioSubmenuItem{
                        text    = _lc("New Book Badge"),
                        options = new_options,
                        get     = function() return GridRenderer.getBadgeNewMode(pfx, id, badges.new) end,
                        set     = function(v) GridRenderer.setBadgeNewMode(pfx, id, v) end,
                        refresh = refresh,
                    },
                }
                if badge_colors_on then
                    new_group[#new_group + 1] = _colorItem(_lc("New Badge Color"), "new", function()
                        return GridRenderer.getBadgeNewMode(pfx, id, badges.new) ~= "none"
                    end)
                end
                pb_group[#pb_group + 1] = {
                    text_func  = function() return _lc("New Book Badge") end,
                    value_func = function()
                        local mode = GridRenderer.getBadgeNewMode(pfx, id, badges.new)
                        for _, o in ipairs(new_options) do
                            if o.value == mode then return o.label end
                        end
                        return ""
                    end,
                    sub_item_table = new_group,
                }
            end

            if #pb_group > 0 then
                items[#items + 1] = {
                    text_func      = function() return _lc("Progress and Badges") end,
                    sub_item_table = pb_group,
                }
            end
        end

        for _, es in ipairs(spec.extra_settings or {}) do
            local skey = pfx .. id .. "_" .. es.key
            items[#items + 1] = {
                text           = es.label,
                checked_func   = function() return SUISettings:readSetting(skey) == true
                                              or (SUISettings:readSetting(skey) == nil and es.default) end,
                keep_menu_open = true,
                callback       = function()
                    local cur = SUISettings:readSetting(skey)
                    if cur == nil then cur = es.default end
                    SUISettings:saveSetting(skey, not cur)
                    refresh()
                end,
            }
        end

        if spec.extra_menu_items_after then
            for _, it in ipairs(spec.extra_menu_items_after(ctx_menu)) do
                items[#items + 1] = it
            end
        end

        return items
    end

    return M
end

return GridRenderer
