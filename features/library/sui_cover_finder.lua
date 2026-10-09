-- sui_cover_finder.lua — Simple UI
-- On-disk discovery of "what cover should represent this folder": either an
-- explicit `.cover.*` file, or a collage of the folder's book covers (this
-- one recurses into subfolders when "recursive cover" is enabled).
--
-- This is deliberately separate from sui_metadata_source: it answers "what
-- image files/cached cover blitbuffers exist under this real directory",
-- not "which books match this filter trail". A plain folder without any
-- bookinfo DB entries yet (freshly copied, never opened) still works here.
--
-- Folder listings are summarised once per directory and cached (validated by
-- the directory mtime), and folders whose covers are not extracted yet are
-- remembered until the book-info database or the directory changes, so
-- repainting a page never re-lists the folders it shows.
--
-- Public API
-- ----------
--   CoverFinder.findDotCover(dir_path) -> filepath | nil
--   CoverFinder.getDirSummary(menu, dir_path) -> { books = {path, ...}, dirs = {path, ...} }
--   CoverFinder.entriesWithNoFilter(menu, dir_path) -> entries | nil
--   CoverFinder.findFirstCover(menu, dir_path, BookInfoManager) -> {data,w,h} | nil, summary
--   CoverFinder.collectCovers(menu, dir_path, max_count, BookInfoManager, recursive_enabled) -> { {data,w,h}, ... }
--   CoverFinder.findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager) -> {data,w,h} | nil
--   CoverFinder.listingSignature(fc) / CoverFinder.statusFilterSignature(fc)
--       -- strings identifying the chooser state a listing depends on
--   CoverFinder.clearListings()  -- drops cached folder listings only
--   CoverFinder.clearCache()     -- call from M.invalidateCache()

local lfs          = require("libs/libkoreader-lfs")
local FileChooser  = require("ui/widget/filechooser")
local BimStamp     = require("features/library/sui_bim_stamp")

local CoverFinder = {}

-- ---------------------------------------------------------------------------
-- Caches
-- ---------------------------------------------------------------------------

-- Two-generation LRU: generation A is the active table; B is the previous
-- one. On overflow B = A, A = {}, counter reset. Effective capacity ~2×max.
-- Stores any value, `false` included.
local function newLru(max)
    local active, previous, count = {}, {}, 0
    local lru = {}
    function lru.get(key)
        local value = active[key]
        if value == nil then value = previous[key] end
        return value
    end
    function lru.set(key, value)
        if count >= max then previous, active, count = active, {}, 0 end
        active[key] = value
        count = count + 1
    end
    function lru.clear() active, previous, count = {}, {}, 0 end
    return lru
end

local _DIR_CACHE_MAX = 300
local _dot_covers = newLru(_DIR_CACHE_MAX) -- [dir] = { mtime=, file= }
local _summaries  = newLru(64)             -- [dir] = { key=, books=, dirs= }
local _misses     = newLru(_DIR_CACHE_MAX) -- [dir .. "\0" .. tag] = stamp

function CoverFinder.clearListings()
    _summaries.clear()
end

function CoverFinder.clearCache()
    _dot_covers.clear()
    _summaries.clear()
    _misses.clear()
end

-- ---------------------------------------------------------------------------
-- Chooser state signatures
-- ---------------------------------------------------------------------------

-- Settings that decide the order and content of a folder listing.
function CoverFinder.listingSignature(fc)
    return table.concat({
        G_reader_settings:readSetting("collate") or "strcoll",
        tostring(G_reader_settings:isTrue("collate_mixed")),
        tostring(G_reader_settings:isTrue("reverse_collate")),
        tostring(fc.show_hidden or false),
    }, "\0")
end

-- The book-status filter currently applied by the chooser.
function CoverFinder.statusFilterSignature(fc)
    local raw = fc.show_filter and fc.show_filter.status
    if type(raw) ~= "table" then return tostring(raw or "") end
    local parts = {}
    for status, enabled in pairs(raw) do
        if enabled then parts[#parts + 1] = tostring(status) end
    end
    table.sort(parts)
    return table.concat(parts, "\1")
end

-- ---------------------------------------------------------------------------
-- Dot cover
-- ---------------------------------------------------------------------------

local _COVER_EXTS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }

-- Returns the path to a .cover.* file in dir_path, or nil.
function CoverFinder.findDotCover(dir_path)
    local mtime  = lfs.attributes(dir_path, "modification")
    local cached = _dot_covers.get(dir_path)
    if cached and cached.mtime == mtime then return cached.file or nil end

    local base, found = dir_path .. "/.cover", false
    for i = 1, #_COVER_EXTS do
        local fname = base .. _COVER_EXTS[i]
        if lfs.attributes(fname, "mode") == "file" then
            found = fname
            break
        end
    end
    _dot_covers.set(dir_path, { mtime = mtime, file = found })
    return found or nil
end

-- ---------------------------------------------------------------------------
-- Folder listing
-- ---------------------------------------------------------------------------

-- Runs FileChooser:genItemTableFromPath with the status filter suppressed,
-- so books hidden by "show only new/reading" can still supply cover art.
-- Deliberately mutates the FileChooser *class* attribute (not the instance)
-- for the duration of the call — genItemTableFromPath reads it off the
-- class, and this runs synchronously with nothing else able to observe the
-- momentary change (Lua has no concurrency here).
local _EMPTY_FILTER = {}
function CoverFinder.entriesWithNoFilter(menu, dir_path)
    local saved = FileChooser.show_filter
    FileChooser.show_filter = _EMPTY_FILTER
    menu._dummy = true
    local ok, entries = pcall(menu.genItemTableFromPath, menu, dir_path)
    menu._dummy = false
    FileChooser.show_filter = saved
    if not ok then error(entries, 0) end
    return entries
end

local function buildSummary(menu, dir_path)
    local books, dirs = {}, {}
    for _, entry in ipairs(CoverFinder.entriesWithNoFilter(menu, dir_path)) do
        if entry.is_file or entry.file then
            books[#books + 1] = entry.path
        elseif not entry.is_go_up then
            dirs[#dirs + 1] = entry.path
        end
    end
    return { books = books, dirs = dirs }
end

-- Book and subfolder paths of dir_path, in chooser order, books never hidden
-- by the status filter. Cached per directory and validated by its mtime;
-- paths with no mtime (virtual folders) and access-time ordering, which
-- changes without touching the mtime, are listed afresh every call.
-- The returned tables are shared — callers must not mutate them.
function CoverFinder.getDirSummary(menu, dir_path)
    local mtime = lfs.attributes(dir_path, "modification")
    if not mtime or G_reader_settings:readSetting("collate") == "access" then
        return buildSummary(menu, dir_path)
    end
    local key    = mtime .. "\0" .. CoverFinder.listingSignature(menu)
    local cached = _summaries.get(dir_path)
    if cached and cached.key == key then return cached end

    local summary = buildSummary(menu, dir_path)
    summary.key = key
    _summaries.set(dir_path, summary)
    return summary
end

-- ---------------------------------------------------------------------------
-- Cover lookup
-- ---------------------------------------------------------------------------

-- The cached cover of the book at `path` as { data, w, h }, or nil when it is
-- not extracted (or, when cover_specs is given, no longer valid for them).
local function cachedCover(BookInfoManager, path, cover_specs)
    local bi = BookInfoManager:getBookInfo(path, true)
    if bi and bi.cover_bb and bi.has_cover and bi.cover_fetched
            and not bi.ignore_cover
            and not (cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs))
    then
        return { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }
    end
end

-- A lookup that found nothing is remembered per (directory, kind of lookup)
-- and skipped until the book-info database or the directory changes —
-- covers can only appear through one of those. Virtual folders have no
-- mtime to validate against and are never remembered.
local function missStamp(dir_path)
    local mtime = lfs.attributes(dir_path, "modification")
    return mtime and (mtime .. "\0" .. (BimStamp.get() or ""))
end

local function isKnownMiss(dir_path, kind)
    local stamp = missStamp(dir_path)
    return stamp ~= nil and _misses.get(dir_path .. "\0" .. kind) == stamp
end

local function recordMiss(dir_path, kind)
    local stamp = missStamp(dir_path)
    if stamp then _misses.set(dir_path .. "\0" .. kind, stamp) end
end

-- First cached cover among the books of dir_path itself. Also returns the
-- folder summary so callers can tell an empty folder from one whose covers
-- are not extracted yet.
function CoverFinder.findFirstCover(menu, dir_path, BookInfoManager)
    local summary = CoverFinder.getDirSummary(menu, dir_path)
    if isKnownMiss(dir_path, "first") then return nil, summary end
    for _, path in ipairs(summary.books) do
        local cover = cachedCover(BookInfoManager, path, menu.cover_specs)
        if cover then return cover, summary end
    end
    if #summary.books > 0 then recordMiss(dir_path, "first") end
    return nil, summary
end

-- Collect up to `needed` cached covers from dir_path recursively (files
-- first, then subdirs). Returns an array that may be shorter than needed.
local function collectCoversRecursive(menu, dir_path, depth, max_depth, needed, BookInfoManager)
    if depth > max_depth or needed <= 0 then return {} end
    local summary = CoverFinder.getDirSummary(menu, dir_path)
    local covers  = {}
    for _, path in ipairs(summary.books) do
        local cover = cachedCover(BookInfoManager, path, menu.cover_specs)
        if cover then
            covers[#covers + 1] = cover
            if #covers >= needed then return covers end
        end
    end
    for _, sub_path in ipairs(summary.dirs) do
        if #covers >= needed then break end
        local sub = collectCoversRecursive(
            menu, sub_path, depth + 1, max_depth, needed - #covers, BookInfoManager)
        for _, c in ipairs(sub) do
            covers[#covers + 1] = c
            if #covers >= needed then break end
        end
    end
    return covers
end
CoverFinder._collectCoversRecursive = collectCoversRecursive -- exposed for style resolution (quad vs single)

-- Find exactly one cover recursively (used on the bookless-folder path).
function CoverFinder.findCoverRecursive(menu, dir_path, depth, max_depth, BookInfoManager)
    if isKnownMiss(dir_path, "recursive") then return nil end
    local cover = collectCoversRecursive(menu, dir_path, depth, max_depth, 1, BookInfoManager)[1]
    if not cover then recordMiss(dir_path, "recursive") end
    return cover
end

-- Collect up to `max_count` covers from dir_path, including subfolders when
-- `recursive_enabled` is true (kept as an explicit arg — this module has no
-- opinion on where that setting lives; sui_foldercovers passes it in).
function CoverFinder.collectCovers(menu, dir_path, max_count, BookInfoManager, recursive_enabled)
    local kind = recursive_enabled and "collage-recursive" or "collage"
    if isKnownMiss(dir_path, kind) then return {} end

    local covers  = {}
    local summary = CoverFinder.getDirSummary(menu, dir_path)
    for _, path in ipairs(summary.books) do
        if #covers >= max_count then break end
        local cover = cachedCover(BookInfoManager, path)
        if cover then covers[#covers + 1] = cover end
    end
    if #covers < max_count and recursive_enabled then
        for _, sub_path in ipairs(summary.dirs) do
            if #covers >= max_count then break end
            local sub = collectCoversRecursive(
                menu, sub_path, 1, 3, max_count - #covers, BookInfoManager)
            for _, c in ipairs(sub) do
                covers[#covers + 1] = c
                if #covers >= max_count then break end
            end
        end
    end
    if #covers == 0 then recordMiss(dir_path, kind) end
    return covers
end

return CoverFinder
