-- sui_cover_finder.lua — Simple UI
-- On-disk discovery of "what cover should represent this folder": either an
-- explicit `.cover.*` file, or the covers of the books the cell shows (the
-- search recurses into subfolders up to a caller-given depth).
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
--   CoverFinder.listCandidates(paths, lead) / .dirCandidates(menu, dir_path, max_depth, lead)
--       -- iterators over the books a cover may be taken from, in cover order
--   CoverFinder.countBooks(menu, dir_path, max_depth, limit) -> n
--   CoverFinder.plan(nextCandidate, slots, BookInfoManager, cover_specs)
--       -> { covers = {{data,w,h}...}, requests = {path...}, complete, seen }
--   CoverFinder.planDir(menu, dir_path, slots, max_depth, BookInfoManager, lead) -> plan
--   CoverFinder.listingSignature(fc) / CoverFinder.statusFilterSignature(fc)
--       -- strings identifying the chooser state a listing depends on
--   CoverFinder.clearListings()  -- drops cached folder listings and the misses derived from them
--   CoverFinder.clearCache()     -- call from M.invalidateCache()

local lfs          = require("libs/libkoreader-lfs")
local FileChooser  = require("ui/widget/filechooser")
local BimStamp     = require("features/library/sui_bim_stamp")
local Finished     = require("features/library/sui_finished_books")

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
    _misses.clear()
end

function CoverFinder.clearCache()
    _dot_covers.clear()
    _summaries.clear()
    _misses.clear()
end

-- ---------------------------------------------------------------------------
-- Chooser state signatures
-- ---------------------------------------------------------------------------

-- Key fragment for anything whose content depends on whether finished books
-- are left out of listings.
local function finishedKey()
    return tostring(Finished.isHidden())
end

-- Settings that decide the order and content of a folder listing.
function CoverFinder.listingSignature(fc)
    return table.concat({
        G_reader_settings:readSetting("collate") or "strcoll",
        tostring(G_reader_settings:isTrue("collate_mixed")),
        tostring(G_reader_settings:isTrue("reverse_collate")),
        tostring(fc.show_hidden or false),
    }, "\0")
end

-- The book-status filter currently applied by the chooser: the selected
-- statuses plus whether finished books are hidden.
function CoverFinder.statusFilterSignature(fc)
    local raw = fc.show_filter and fc.show_filter.status
    local selection
    if type(raw) == "table" then
        local parts = {}
        for status, enabled in pairs(raw) do
            if enabled then parts[#parts + 1] = tostring(status) end
        end
        table.sort(parts)
        selection = table.concat(parts, "\1")
    else
        selection = tostring(raw or "")
    end
    return selection .. "\0" .. finishedKey()
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
-- by the status filter (finished books left out by the library mode are not
-- listed). Cached per directory and validated by its mtime;
-- paths with no mtime (virtual folders) and access-time ordering, which
-- changes without touching the mtime, are listed afresh every call.
-- The returned tables are shared — callers must not mutate them.
function CoverFinder.getDirSummary(menu, dir_path)
    local mtime = lfs.attributes(dir_path, "modification")
    if not mtime or G_reader_settings:readSetting("collate") == "access" then
        return buildSummary(menu, dir_path)
    end
    local key    = mtime .. "\0" .. CoverFinder.listingSignature(menu)
        .. "\0" .. finishedKey()
    local cached = _summaries.get(dir_path)
    if cached and cached.key == key then return cached end

    local summary = buildSummary(menu, dir_path)
    summary.key = key
    _summaries.set(dir_path, summary)
    return summary
end

-- ---------------------------------------------------------------------------
-- Cover state
-- ---------------------------------------------------------------------------

-- State of the cover of the book at `path`: the cached cover as
-- { data, w, h }, or nil plus whether the book still has to be extracted
-- before its cover can be shown (no cached row yet, cover not fetched, or the
-- cached thumbnail no longer fits cover_specs). Books without cover art never
-- wait.
local function coverState(BookInfoManager, path, cover_specs)
    local bi = BookInfoManager:getBookInfo(path, true)
    if not (bi and bi.cover_fetched) then return nil, true end
    if not bi.has_cover or bi.ignore_cover then return nil, false end
    if cover_specs and BookInfoManager.isCachedCoverInvalid(bi, cover_specs) == true then
        return nil, true
    end
    if bi.cover_bb then
        return { data = bi.cover_bb, w = bi.cover_w, h = bi.cover_h }, false
    end
    return nil, false
end

-- ---------------------------------------------------------------------------
-- Candidates
-- ---------------------------------------------------------------------------

-- A candidate source is an iterator returning the next book path, in cover
-- order, or nil when exhausted. `lead` (optional) is tried before the rest.
local function withLead(lead, nextPath)
    if not lead then return nextPath end
    return function()
        local path = lead
        lead = nil
        return path or nextPath()
    end
end

-- Candidates taken from an explicit array of book paths.
function CoverFinder.listCandidates(paths, lead)
    local index = 0
    return withLead(lead, function()
        index = index + 1
        return paths[index]
    end)
end

-- Candidates of a real directory: its own books first, then, down to
-- `max_depth` levels, the books of its subfolders (depth-first). Listings are
-- read lazily, so a consumer that stops early never lists the rest.
function CoverFinder.dirCandidates(menu, dir_path, max_depth, lead)
    local stack = {}
    local function enter(path, depth)
        stack[#stack + 1] = {
            summary = CoverFinder.getDirSummary(menu, path),
            depth = depth, book = 0, dir = 0,
        }
    end
    enter(dir_path, 0)

    return withLead(lead, function()
        while #stack > 0 do
            local frame = stack[#stack]
            local summary = frame.summary
            if frame.book < #summary.books then
                frame.book = frame.book + 1
                return summary.books[frame.book]
            end
            if frame.depth < max_depth and frame.dir < #summary.dirs then
                frame.dir = frame.dir + 1
                enter(summary.dirs[frame.dir], frame.depth + 1)
            else
                stack[#stack] = nil
            end
        end
    end)
end

-- Number of books reachable through dirCandidates, counted up to `limit`.
function CoverFinder.countBooks(menu, dir_path, max_depth, limit)
    local count = 0
    for _ in CoverFinder.dirCandidates(menu, dir_path, max_depth) do
        count = count + 1
        if count >= limit then break end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Cover plan
-- ---------------------------------------------------------------------------

-- Candidates inspected past the cover window while it still waits for
-- extraction, so a book that turns out to have no cover art is already
-- covered by a pending request.
local _LOOKAHEAD = 2

-- Resolves the cover a cell shows. The window is the first `slots` candidates
-- that have, or may still get, cover art; each one is either ready or pending.
--   covers   ready covers { data, w, h }, in window order
--   requests books to extract: the pending window plus the lookahead
--   complete true when no window book is pending
--   seen     candidates inspected (0 = nothing to take a cover from)
function CoverFinder.plan(nextCandidate, slots, BookInfoManager, cover_specs)
    local plan = { covers = {}, requests = {}, complete = true, seen = 0 }
    local window, ahead = 0, 0
    for path in nextCandidate do
        plan.seen = plan.seen + 1
        local cover, waits = coverState(BookInfoManager, path, cover_specs)
        if window < slots then
            if cover then
                plan.covers[#plan.covers + 1] = cover
                window = window + 1
            elseif waits then
                plan.requests[#plan.requests + 1] = path
                plan.complete = false
                window = window + 1
            end
        else
            if plan.complete then break end
            if waits then plan.requests[#plan.requests + 1] = path end
            ahead = ahead + 1
            if ahead >= _LOOKAHEAD then break end
        end
    end
    return plan
end

-- A plan that found no cover anywhere is remembered per (directory, depth) and
-- skipped until the book-info database, the directory or the finished-books
-- mode changes, or the listings are cleared — covers can only appear through
-- one of those. Virtual folders have no mtime to validate against and are
-- never remembered.
local function missStamp(dir_path)
    local mtime = lfs.attributes(dir_path, "modification")
    return mtime and (mtime .. "\0" .. (BimStamp.get() or "") .. "\0" .. finishedKey())
end

local function emptyKey(dir_path, max_depth)
    return dir_path .. "\0" .. max_depth
end

local function knownEmpty(dir_path, max_depth)
    local stamp = missStamp(dir_path)
    local known = stamp and _misses.get(emptyKey(dir_path, max_depth))
    if known and known.stamp == stamp then return known end
end

local function recordEmpty(dir_path, max_depth, seen)
    local stamp = missStamp(dir_path)
    if stamp then
        _misses.set(emptyKey(dir_path, max_depth), { stamp = stamp, seen = seen })
    end
end

-- Plan for a real directory. `lead` (a book path) is tried first and, being
-- user-chosen, bypasses the remembered-empty shortcut.
function CoverFinder.planDir(menu, dir_path, slots, max_depth, BookInfoManager, lead)
    if not lead then
        local known = knownEmpty(dir_path, max_depth)
        if known then
            return { covers = {}, requests = {}, complete = true, seen = known.seen }
        end
    end
    local plan = CoverFinder.plan(
        CoverFinder.dirCandidates(menu, dir_path, max_depth, lead),
        slots, BookInfoManager, menu.cover_specs)
    if not lead and plan.complete and #plan.covers == 0 then
        recordEmpty(dir_path, max_depth, plan.seen)
    end
    return plan
end

return CoverFinder
