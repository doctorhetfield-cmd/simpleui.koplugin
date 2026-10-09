-- module_library.lua — Simple UI
-- Module: Flat Library — same "cover row/grid with progress" presentation
-- as Recent/New Books/TBR/Featured Collection (built on top of
-- GridRenderer.makeModule, engines/sui_book_grid.lua), but the file list
-- is every book found in the library (recursive scan from home_dir),
-- not a curated subset. "Flat" because folder structure is ignored —
-- every book everywhere under home_dir lands in a single grid.
-- Add Module list shows "Flat Library" (spec.name); the on-screen header
-- above the grid shows "Books" (spec.label) — id stays "flat_library"
-- internally either way, for backward compatibility with existing
-- per-instance settings.
--
-- Two things this module needs that Recent/New Books don't:
--   1. A scanner that can cheaply serve possibly the whole library on every
--      homescreen build, not just a capped top-N — see
--      engines/sui_library_scan.lua (directory-mtime cache, not a blind
--      TTL).
--   2. A user-facing sort order, since "whatever order the filesystem walk
--      happened to visit files in" is meaningless to a reader. There is no
--      ReadCollection to persist an order onto — this module sorts its
--      own getFileList() output on every call, driven by a persisted
--      "flat_library_sort_mode" setting (see sortRaw below).

local lfs    = require("libs/libkoreader-lfs")
local _ = require("infra/sui_i18n").translate

local SUISettings  = require("infra/sui_store")
local GridRenderer = require("engines/sui_book_grid")
local LibraryScan  = require("engines/sui_library_scan")

local MAX_ITEMS = 5  -- default_cols for the grid — same convention as Collections/Featured Collection

local SORT_KEY    = "flat_library_sort_mode"    -- pfx .. SORT_KEY
local SHUFFLE_KEY = "flat_library_shuffle_order" -- pfx .. SHUFFLE_KEY

local DEFAULT_SORT = "title_asc"

-- Unlike Recent/New Books (where hiding finished books by default keeps the
-- "what should I pick up next" list short), the whole point of the flat
-- Library is to be the complete catalogue, so finished books are shown by
-- default here; the toggle just lets the person narrow it down.
local SHOW_FINISHED_DEFAULT = true

-- ---------------------------------------------------------------------------
-- Sort setting accessors (namespaced by pfx, like every other per-instance
-- setting in this codebase).
-- ---------------------------------------------------------------------------
local function getSortMode(pfx)
    return SUISettings:readSetting(pfx .. SORT_KEY) or DEFAULT_SORT
end
local function saveSortMode(pfx, mode)
    SUISettings:saveSetting(pfx .. SORT_KEY, mode)
end
local function getShuffleOrder(pfx)
    return SUISettings:readSetting(pfx .. SHUFFLE_KEY) or {}
end
local function saveShuffleOrder(pfx, fps)
    SUISettings:saveSetting(pfx .. SHUFFLE_KEY, fps)
end

-- ---------------------------------------------------------------------------
-- Title/author lookup cache — first checks LibraryScan.getBatchTextMeta()
-- (one SQL query against BIM's bookinfo table, see sui_library_scan.lua),
-- falling back to a per-file DocSettings/getBookData read only for a book
-- BIM hasn't extracted yet. Resolved values are memoized here regardless
-- of which path found them, keyed by filepath — invalidated together with
-- LibraryScan's own caches (see resetCaches() below; a book being replaced
-- in place with different metadata is the same rare case LibraryScan
-- itself doesn't specially detect either).
-- ---------------------------------------------------------------------------
local _title_cache  = {}
local _author_cache = {}

local function getSH()
    local ok, m = pcall(require, "modules/module_books_shared")
    return ok and m or nil
end

local function cachedTitle(fp)
    local t = _title_cache[fp]
    if t then return t end
    local row = LibraryScan.getBatchTextMeta()[fp]
    if row and row.title and row.title ~= "" then
        t = row.title
    else
        t = GridRenderer.getBookTitle(fp)
    end
    _title_cache[fp] = t
    return t
end

local function cachedAuthor(fp)
    local a = _author_cache[fp]
    if a then return a end
    local row = LibraryScan.getBatchTextMeta()[fp]
    if row and row.authors and row.authors ~= "" then
        a = row.authors
    else
        local SH = getSH()
        a = (SH and SH.getBookData(fp).authors) or ""
    end
    _author_cache[fp] = a
    return a
end

local function resetCaches()
    LibraryScan.invalidate()
    LibraryScan.invalidateTextMeta()
    _title_cache  = {}
    _author_cache = {}
end

-- ---------------------------------------------------------------------------
-- Shuffle order — persisted so the grid doesn't visibly re-shuffle itself
-- on every homescreen repaint. Reconciled against the current raw scan on
-- each read: entries no longer present are dropped, newly-seen entries are
-- appended in scan order (they'll land wherever the next explicit shuffle
-- puts them).
-- ---------------------------------------------------------------------------
local function generateShuffleOrder(pfx, raw)
    local fps = {}
    for i, r in ipairs(raw) do fps[i] = r.fp end
    for i = #fps, 2, -1 do
        local j = math.random(i)
        fps[i], fps[j] = fps[j], fps[i]
    end
    saveShuffleOrder(pfx, fps)
    return fps
end

local function applyShuffleOrder(pfx, raw)
    local present = {}
    for _, r in ipairs(raw) do present[r.fp] = true end

    local stored = getShuffleOrder(pfx)
    if #stored == 0 then return generateShuffleOrder(pfx, raw) end

    local ordered, seen = {}, {}
    for _, fp in ipairs(stored) do
        if present[fp] and not seen[fp] then
            ordered[#ordered + 1] = fp
            seen[fp] = true
        end
    end
    for _, r in ipairs(raw) do
        if not seen[r.fp] then
            ordered[#ordered + 1] = r.fp
            seen[r.fp] = true
        end
    end
    return ordered
end

-- ---------------------------------------------------------------------------
-- sortRaw(raw, mode, pfx) -> { fp, ... }
--
-- mode: "title_asc" (default) | "title_desc" | "author_asc" |
--       "date_desc" | "date_asc" | "size_desc" | "size_asc" | "shuffle"
-- ---------------------------------------------------------------------------
local function sortRaw(raw, mode, pfx)
    if mode == "shuffle" then return applyShuffleOrder(pfx, raw) end

    local fps = {}
    for i, r in ipairs(raw) do fps[i] = r.fp end

    if mode == "date_desc" or mode == "date_asc" then
        local mtimes = {}
        for _, r in ipairs(raw) do mtimes[r.fp] = r.mtime end
        table.sort(fps, function(a, b)
            if mode == "date_desc" then return mtimes[a] > mtimes[b] else return mtimes[a] < mtimes[b] end
        end)
    elseif mode == "size_desc" or mode == "size_asc" then
        local sizes = {}
        for _, r in ipairs(raw) do sizes[r.fp] = r.size end
        table.sort(fps, function(a, b)
            if mode == "size_desc" then return sizes[a] > sizes[b] else return sizes[a] < sizes[b] end
        end)
    elseif mode == "author_asc" then
        table.sort(fps, function(a, b) return cachedAuthor(a):lower() < cachedAuthor(b):lower() end)
    else -- "title_asc" / "title_desc" / unrecognized -> default
        local desc = (mode == "title_desc")
        table.sort(fps, function(a, b)
            local ta, tb = cachedTitle(a):lower(), cachedTitle(b):lower()
            if desc then return ta > tb else return ta < tb end
        end)
    end
    return fps
end

-- ---------------------------------------------------------------------------
-- getFileList — home_dir resolution via LibraryScan.resolveHomeDir(),
-- shared with module_new_books.lua and module_stats_provider.lua.
-- ---------------------------------------------------------------------------
local function getFileList(ctx)
    local pfx  = (ctx and ctx.pfx) or ""
    local home = LibraryScan.resolveHomeDir()
    if not home then return {} end

    local raw = LibraryScan.getRaw(home)
    return sortRaw(raw, getSortMode(pfx), pfx)
end

-- ---------------------------------------------------------------------------
-- "Sort" menu — a persisted live mode (radio sub-items), since there is no
-- collection to write the order back onto.
-- ---------------------------------------------------------------------------
local SORT_LABELS = {
    title_asc   = _("Title (A–Z)"),
    title_desc  = _("Title (Z–A)"),
    author_asc  = _("Author (A–Z)"),
    date_desc   = _("Date added (newest)"),
    date_asc    = _("Date added (oldest)"),
    size_desc   = _("File size (largest)"),
    size_asc    = _("File size (smallest)"),
    shuffle     = _("Random"),
}
local SORT_ORDER = {
    "title_asc", "title_desc", "author_asc",
    "date_desc", "date_asc", "size_desc", "size_asc", "shuffle",
}

local function extraMenuItemsBefore(ctx_menu)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx

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
            return SORT_LABELS[getSortMode(pfx)] or SORT_LABELS[DEFAULT_SORT]
        end,
        sub_item_table_func = function()
            local sub = {}
            for _, mode in ipairs(SORT_ORDER) do
                local _m = mode
                sub[#sub + 1] = {
                    text           = SORT_LABELS[_m],
                    radio          = true,
                    checked_func   = function() return getSortMode(pfx) == _m end,
                    keep_menu_open = true,
                    callback       = function()
                        saveSortMode(pfx, _m)
                        -- Picking "Random" for the first time (or switching
                        -- back to it) rolls a fresh order right away, rather
                        -- than silently reusing whatever was last persisted.
                        if _m == "shuffle" then
                            local home = LibraryScan.resolveHomeDir()
                            if home then generateShuffleOrder(pfx, LibraryScan.getRaw(home)) end
                        end
                        refresh()
                    end,
                }
            end
            return sub
        end,
    }

    -- One-off action, only meaningful (and shown as enabled) while "Random"
    -- is the active mode — re-rolls the persisted order without having to
    -- leave and re-enter the Random mode.
    items[#items + 1] = {
        text           = _lc("Shuffle now"),
        separator      = true,
        enabled_func   = function() return getSortMode(pfx) == "shuffle" end,
        keep_menu_open = true,
        callback       = function()
            local home = LibraryScan.resolveHomeDir()
            if home then generateShuffleOrder(pfx, LibraryScan.getRaw(home)) end
            refresh()
        end,
    }

    return items
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local mod = GridRenderer.makeModule{
    id          = "flat_library",
    name        = _("Flat Library"),
    label       = _("Books"),
    default_on  = false,
    is_book_mod = true,   -- surgical repaint on swipe between pages; suppresses the generic empty-state
    max_items   = MAX_ITEMS,
    paged       = true,   -- the whole library, almost certainly more than one page

    getFileList = function(ctx) return getFileList(ctx) end,

    -- Excludes (unless the user opts in via "Show finished books") anything
    -- already marked 100%/complete — same logic as module_recent.lua, minus
    -- its currently-open-book exclusion: unlike Recent (a "what to pick up
    -- next" list, where the book you're already reading is redundant), Flat
    -- Library is meant to be the complete catalogue, so the open book stays
    -- visible here like any other in-progress book.
    filterItem = function(fp, ctx)
        local pfx = (ctx and ctx.pfx) or ""
        local show_finished_setting = SUISettings:readSetting(pfx .. "flat_library_show_finished")
        local show_finished = show_finished_setting
        if show_finished == nil then show_finished = SHOW_FINISHED_DEFAULT end
        if show_finished then return true end
        local pct, is_complete = 0, false
        local pre = ctx.prefetched and ctx.prefetched[fp]
        if pre and pre ~= false then
            pct = pre.percent or 0
            is_complete = type(pre.summary) == "table" and pre.summary.status == "complete"
        else
            local ok, DS = pcall(require, "docsettings")
            if ok and DS then
                local ok2, ds = pcall(DS.open, DS, fp)
                if ok2 and ds then
                    pct = ds:readSetting("percent_finished") or 0
                    local summary = ds:readSetting("summary")
                    is_complete = type(summary) == "table" and summary.status == "complete"
                    pcall(function() ds:close() end)
                end
            end
        end
        return pct < 1.0 and not is_complete
    end,

    -- Same defaults as Recent Books: progress bar + "% Read" label, no overlay.
    progress_style = { default = "bar_text" },

    -- Library-style corner badges (see engines/sui_book_grid.lua's
    -- GridRenderer.applyBadges). Flat Library is the pilot module for this:
    -- it's the closest in spirit to the file-manager Library grid, but
    -- "Pages"/"Series"/"New" all default off now — every corner badge is
    -- user-editable, never locked, but purely opt-in and consistent across
    -- every book-grid module (nothing pre-enabled by default).
    badges = { pages = "off", series = "off", new = "off" },

    extra_settings = {
        { key = "show_finished", label = _("Show finished books"), default = SHOW_FINISHED_DEFAULT },
    },

    extra_menu_items_before = extraMenuItemsBefore,

    -- Configurable grid (Rows 1-3 × Columns 4-5) + swipe pagination —
    -- the whole library rarely fits on a single row.
    grid          = true,
    default_rows  = 1,
    default_cols  = MAX_ITEMS,

    reset = function()
        GridRenderer.reset()
        resetCaches()
    end,
}

-- Exposed for completeness/tests — not called internally by this file.
function mod.invalidateCache() resetCaches() end

return mod
