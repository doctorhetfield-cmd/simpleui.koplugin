-- sui_metadata_source.lua — Simple UI
-- Fast, cacheable access to book metadata for library browsing/filtering.
--
-- Two data sources are combined into one resolved row per book:
--   1. CoverBrowser's bookinfo_cache.sqlite3 (via BookInfoManager) — the
--      primary source, populated as the user opens/scans books.
--   2. Calibre's metadata.calibre (when present under base_dir) — the
--      curated source for series (name and index are taken together); for
--      every other field it only fills gaps in the bookinfo row, and it
--      contributes books the bookinfo DB does not know about yet.
--
-- Rows are resolved once per base_dir and cached. A FilterState trail then
-- filters those resolved rows in memory, so a dimension value means the same
-- thing to the facet lists, their counts and the leaf listings (see
-- FilterState.matcher and FilterState.eachFacetValue).
--
-- Every query covers the whole subtree under base_dir. Caches are dropped
-- automatically when the book-info database changes (see sui_bim_stamp);
-- call MetadataSource.clearCache(base_dir) when files change on disk
-- (book added/removed/moved) for that subtree.
--
-- Public API
-- ----------
--   MetadataSource.getMatchingFiles(bim, base_dir, filter_state)
--       -> { {fullpath, filename, title=, authors=, series=, series_key=,
--             series_index=, keywords=}, ... }  sorted by directory, filename
--   MetadataSource.getFacetValues(bim, base_dir, dimension, filter_state)
--       -> { {value, count, key=, _first=row}, ... } sorted for display
--   MetadataSource.getValidRows(bim, base_dir, filter_state, variant, accept)
--       -> rows matching the trail for which accept(row) is true (cached,
--          read-only; `variant` identifies what accept depends on)
--   MetadataSource.getValidFacetCounts(bim, base_dir, dimension, filter_state, variant, accept)
--       -> counts, reprs: per facet key, the number of accepted rows and the
--          path of the first one (cached, read-only)
--   MetadataSource.getFolderSeries(bim, dir)
--       -> { [filename] = {series=, series_index=}, ... } | nil
--   MetadataSource.sortFiles(files, active_dimension)  -- mutates in place
--   MetadataSource.clearCache(base_dir)  -- base_dir == nil clears everything

local logger      = require("logger")
local ffiUtil     = require("ffi/util")
local FilterState = require("features/library/sui_filter_state")
local BimStamp    = require("features/library/sui_bim_stamp")

local MetadataSource = {}

-- ---------------------------------------------------------------------------
-- Caches
-- ---------------------------------------------------------------------------

local _scope_rows_cache     = {} -- [base_dir]  = resolved rows for the whole subtree
local _matching_files_cache = {} -- [cache_key] = rows matching a trail
local _facet_values_cache   = {} -- [cache_key .. "\31" .. dimension] = { {value, count, key=, _first=row}, ... }
local _calibre_index_cache  = {} -- [base_dir]  = index table | false
local _valid_rows_cache     = {} -- [cache_key .. "\29" .. variant] = rows accepted by the caller
local _valid_facets_cache   = {} -- [cache_key .. "\31" .. dimension .. "\29" .. variant] = { counts, reprs }

local function normalizeBaseDir(dir)
    while #dir > 1 and dir:sub(-1) == "/" do dir = dir:sub(1, -2) end
    return dir
end

local function serializeTrail(filter_state)
    local parts = {}
    for _, entry in ipairs(filter_state and filter_state.trail or {}) do
        parts[#parts + 1] = entry.dimension
        parts[#parts + 1] = (entry.value == false) and "\0" or tostring(entry.value)
    end
    return table.concat(parts, "\31")
end

-- Every cache key starts with its base_dir, terminated by "\30" when a trail
-- or dimension follows.
local function cacheKey(base_dir, filter_state)
    return normalizeBaseDir(base_dir) .. "\30" .. serializeTrail(filter_state)
end

local function isWithin(base_dir, prefix)
    return base_dir == prefix or base_dir:sub(1, #prefix + 1) == prefix .. "/"
end

-- Drops every entry of `cache` whose base_dir is `prefix` or below it.
local function evictWithin(cache, prefix)
    for key in pairs(cache) do
        if isWithin(key:match("^[^\30]*"), prefix) then cache[key] = nil end
    end
end

-- Clears every cache entry whose base_dir is `base_dir` or a subdirectory
-- of it (so invalidating a parent also invalidates narrower queries below
-- it). base_dir == nil clears everything.
function MetadataSource.clearCache(base_dir)
    if not base_dir then
        for _, cache in ipairs({ _scope_rows_cache, _matching_files_cache,
                                 _facet_values_cache, _valid_rows_cache,
                                 _valid_facets_cache, _calibre_index_cache }) do
            for key in pairs(cache) do cache[key] = nil end
        end
        return
    end
    local prefix = normalizeBaseDir(base_dir)
    evictWithin(_scope_rows_cache, prefix)
    evictWithin(_matching_files_cache, prefix)
    evictWithin(_facet_values_cache, prefix)
    evictWithin(_valid_rows_cache, prefix)
    evictWithin(_valid_facets_cache, prefix)
    _calibre_index_cache[prefix] = nil
end

-- Stamp of the book-info database the caches were filled from.
local _cache_stamp = nil

-- Drops every cache when the book-info database changed since the last query.
local function syncWithDatabase()
    local stamp = BimStamp.get() or ""
    if stamp ~= _cache_stamp then
        if _cache_stamp ~= nil then MetadataSource.clearCache() end
        _cache_stamp = stamp
    end
end

-- ---------------------------------------------------------------------------
-- Calibre metadata.calibre backfill
-- ---------------------------------------------------------------------------

-- Loads metadata.calibre reachable from `dir` and returns a lookup table
-- keyed by the book's absolute path: { [fullpath] = {title, authors,
-- series, series_index, keywords}, ... }. Returns false when none exists.
-- Cached for the session (per base_dir actually queried).
local function loadCalibreIndex(dir)
    local cached = _calibre_index_cache[dir]
    if cached ~= nil then return cached end

    local ok_cm, CalibreMetadata = pcall(require, "metadata")
    if not ok_cm or not CalibreMetadata or type(CalibreMetadata.loadBookList) ~= "function" then
        _calibre_index_cache[dir] = false
        return false
    end

    local cm = setmetatable({}, { __index = CalibreMetadata })
    cm.drive = {}
    cm.books = {}

    local ok_init, result = pcall(function() return cm:init(dir, true) end)
    if not ok_init or not result then
        cm:clean()
        _calibre_index_cache[dir] = false
        return false
    end

    local index = {}
    for _, book in ipairs(cm.books) do
        local lpath = book.lpath
        if lpath and type(lpath) == "string" then
            local fullpath = dir .. "/" .. lpath

            local authors_str
            if type(book.authors) == "table" and #book.authors > 0 then
                authors_str = table.concat(book.authors, "\n")
            end
            local keywords_str
            if type(book.tags) == "table" and #book.tags > 0 then
                keywords_str = table.concat(book.tags, "\n")
            end
            local series = (type(book.series) == "string") and book.series or nil
            local series_index = (type(book.series_index) == "number") and book.series_index or nil
            local title = (type(book.title) == "string") and book.title or nil

            index[fullpath] = {
                title = title, authors = authors_str, series = series,
                series_index = series_index, keywords = keywords_str,
            }
        end
    end
    cm:clean()

    if next(index) then
        _calibre_index_cache[dir] = index
        return index
    end
    _calibre_index_cache[dir] = false
    return false
end

-- ---------------------------------------------------------------------------
-- Row resolution
-- ---------------------------------------------------------------------------

local function nonEmpty(value)
    if value ~= nil and value ~= "" then return value end
end

-- Resolves a bookinfo row in place, optionally against its Calibre record.
-- The Calibre series wins as a name/index pair; the bookinfo index only
-- survives when both sources name the same series. Series names are
-- normalized (see FilterState.parseSeries) and get a comparison key.
local function resolveRow(row, cal)
    local name, suffix_index = FilterState.parseSeries(row.series)
    local index = row.series_index or suffix_index

    if cal then
        local cal_name, cal_suffix = FilterState.parseSeries(cal.series)
        if cal_name then
            local same = name ~= nil and FilterState.seriesKey(name) == FilterState.seriesKey(cal_name)
            name, index = cal_name, cal.series_index or cal_suffix or (same and index) or nil
        end
        row.title    = nonEmpty(row.title)    or cal.title
        row.authors  = nonEmpty(row.authors)  or cal.authors
        row.keywords = nonEmpty(row.keywords) or cal.keywords
    end

    row.authors, row.keywords = nonEmpty(row.authors), nonEmpty(row.keywords)
    row.series, row.series_index = name, index
    row.series_key = name and FilterState.seriesKey(name)
end

-- ---------------------------------------------------------------------------
-- Scope query
-- ---------------------------------------------------------------------------

local _SQL_SCOPE = "SELECT directory, filename, title, authors, series, series_index, keywords"
                .. " FROM bookinfo WHERE directory GLOB ?"
                .. " ORDER BY directory ASC, filename ASC"

-- Runs `sql` with one bound parameter and passes every result row to
-- `on_row`. Returns false when the query fails.
local function eachRow(bim, sql, param, on_row)
    local stmt
    local ok, err = pcall(function()
        bim:openDbConnection()
        stmt = bim.db_conn:prepare(sql)
        stmt:bind(param)
        while true do
            local row = stmt:step()
            if not row then break end
            on_row(row)
        end
    end)
    if stmt then pcall(function() stmt:finalize() end) end
    if not ok then logger.warn("sui_metadata_source: SQL error:", tostring(err)) end
    return ok
end

local function queryBookInfo(bim, base_dir)
    local rows = {}
    local ok = eachRow(bim, _SQL_SCOPE, base_dir .. "/*", function(row)
        -- The `directory` column always stores a trailing slash, so the
        -- full path is a plain concatenation.
        rows[#rows + 1] = {
            row[1] .. row[2], row[2],
            title = row[3], authors = row[4], series = row[5],
            series_index = tonumber(row[6]), keywords = row[7],
        }
    end)
    return ok and rows or nil
end

local _SQL_FOLDER_SERIES = "SELECT filename, series, series_index FROM bookinfo WHERE directory = ?"

-- Series name and index of every book the database holds for the folder
-- `dir` (trailing slash included, subfolders excluded), in a single query.
-- Returns nil when the query fails.
function MetadataSource.getFolderSeries(bim, dir)
    local props = {}
    local ok = eachRow(bim, _SQL_FOLDER_SERIES, dir, function(row)
        props[row[1]] = { series = row[2], series_index = tonumber(row[3]) }
    end)
    return ok and props or nil
end

-- Resolved rows for every book under base_dir: bookinfo rows in
-- (directory, filename) order, then Calibre-only books in path order.
local function fetchScopeRows(bim, base_dir)
    local rows = queryBookInfo(bim, base_dir)
    if not rows then return {} end

    local cal_index = loadCalibreIndex(base_dir)
    local seen = {}
    for _, row in ipairs(rows) do
        seen[row[1]] = true
        resolveRow(row, cal_index and cal_index[row[1]])
    end

    if cal_index then
        local extra = {}
        for fullpath in pairs(cal_index) do
            if not seen[fullpath] then extra[#extra + 1] = fullpath end
        end
        table.sort(extra)
        for _, fullpath in ipairs(extra) do
            local fname = fullpath:match("([^/]+)$")
            if fname then
                local cal = cal_index[fullpath]
                local row = {
                    fullpath, fname,
                    title = cal.title, authors = cal.authors, series = cal.series,
                    series_index = cal.series_index, keywords = cal.keywords,
                }
                resolveRow(row)
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

local function getScopeRows(bim, base_dir)
    base_dir = normalizeBaseDir(base_dir)
    local rows = _scope_rows_cache[base_dir]
    if not rows then
        rows = fetchScopeRows(bim, base_dir)
        _scope_rows_cache[base_dir] = rows
    end
    return rows
end

local function copyArray(array)
    local copy = {}
    for i, value in ipairs(array) do copy[i] = value end
    return copy
end

-- The cached rows matching the trail. Internal: the array is shared, so
-- callers must not mutate it.
local function matchingRows(bim, base_dir, filter_state)
    local key = cacheKey(base_dir, filter_state)
    local cached = _matching_files_cache[key]
    if cached then return cached end

    local rows = getScopeRows(bim, base_dir)
    local trail = filter_state and filter_state.trail
    if trail and #trail > 0 then
        local matches = FilterState.matcher(trail)
        local filtered = {}
        for _, row in ipairs(rows) do
            if matches(row) then filtered[#filtered + 1] = row end
        end
        rows = filtered
    end
    _matching_files_cache[key] = rows
    return rows
end

-- Returns a COPY of the (internally cached) matching-files array. Callers
-- are free to sort or otherwise mutate the array they receive — the cache
-- itself is never touched here, so a caller sorting by one active_dimension
-- can never corrupt the result another caller expects in a different order.
function MetadataSource.getMatchingFiles(bim, base_dir, filter_state)
    if not bim or not base_dir then return {} end
    syncWithDatabase()
    return copyArray(matchingRows(bim, base_dir, filter_state))
end

-- ---------------------------------------------------------------------------
-- Collation
-- ---------------------------------------------------------------------------

local function strcollSafe(a, b)
    if a == b then return false end
    if not a then return false end
    if not b then return true end
    return ffiUtil.strcoll(a, b)
end

-- ---------------------------------------------------------------------------
-- Facet values (grouping + counts)
-- ---------------------------------------------------------------------------

-- The grouping pass + strcoll sort below is the expensive part of this
-- function (O(#matching files) to group, O(n log n) strcoll comparisons to
-- sort) — cheap for a single call, but this function is called on every
-- author/series/tags tab switch, so without memoization it re-pays that
-- cost every time even when the matching rows are a cache hit. Cached under
-- the same key scheme as _matching_files_cache, with the dimension appended,
-- and invalidated by the same MetadataSource.clearCache(base_dir).
--
-- Values are grouped by their comparison key; the entry displays the
-- spelling of the first row that contributed to it.
local function computeFacetValues(rows, definition)
    local groups, out = {}, {}
    local current
    local function add(key, value)
        local entry = groups[key]
        if not entry then
            entry = { value, 0, key = key, _first = current }
            groups[key] = entry
            out[#out + 1] = entry
        end
        entry[2] = entry[2] + 1
    end

    for _, row in ipairs(rows) do
        current = row
        FilterState.eachFacetValue(row, definition, add)
    end

    table.sort(out, function(a, b) return strcollSafe(a[1], b[1]) end)
    return out
end

function MetadataSource.getFacetValues(bim, base_dir, dimension, filter_state)
    if not FilterState.isDimension(dimension) then return {} end
    syncWithDatabase()

    local key = cacheKey(base_dir, filter_state) .. "\31" .. dimension
    local cached = _facet_values_cache[key]
    if not cached then
        cached = computeFacetValues(matchingRows(bim, base_dir, filter_state),
                                    FilterState.DIMENSIONS[dimension])
        _facet_values_cache[key] = cached
    end
    -- Return a shallow copy: cheap (copies entry refs, not rows), and keeps
    -- callers free to sort/mutate what they receive without corrupting the
    -- cache — same contract as getMatchingFiles.
    return copyArray(cached)
end

-- ---------------------------------------------------------------------------
-- Validated rows (rows the caller's predicate accepts)
-- ---------------------------------------------------------------------------

-- `accept(row)` is typically a filesystem check (file exists, file chooser
-- shows it), which costs a syscall per row. The outcome is cached under
-- `variant`, a string naming the state accept depends on: callers must use
-- the same variant only for predicates that behave identically. Returned
-- arrays are shared — callers must not mutate them.
function MetadataSource.getValidRows(bim, base_dir, filter_state, variant, accept)
    if not bim or not base_dir then return {} end
    syncWithDatabase()

    local key = cacheKey(base_dir, filter_state) .. "\29" .. variant
    local valid = _valid_rows_cache[key]
    if not valid then
        valid = {}
        for _, row in ipairs(matchingRows(bim, base_dir, filter_state)) do
            if accept(row) then valid[#valid + 1] = row end
        end
        _valid_rows_cache[key] = valid
    end
    return valid
end

-- Per facet key (entry.key of getFacetValues): the number of accepted rows
-- and the path of the first one. Same caching contract as getValidRows.
function MetadataSource.getValidFacetCounts(bim, base_dir, dimension, filter_state, variant, accept)
    if not FilterState.isDimension(dimension) then return {}, {} end

    local rows = MetadataSource.getValidRows(bim, base_dir, filter_state, variant, accept)
    local key = cacheKey(base_dir, filter_state) .. "\31" .. dimension .. "\29" .. variant
    local cached = _valid_facets_cache[key]
    if not cached then
        local counts, reprs = {}, {}
        local current_path
        local function count(facet_key)
            counts[facet_key] = (counts[facet_key] or 0) + 1
            if not reprs[facet_key] then reprs[facet_key] = current_path end
        end
        local definition = FilterState.DIMENSIONS[dimension]
        for _, row in ipairs(rows) do
            current_path = row[1]
            FilterState.eachFacetValue(row, definition, count)
        end
        cached = { counts, reprs }
        _valid_facets_cache[key] = cached
    end
    return cached[1], cached[2]
end

-- ---------------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------------

-- Sort by: series (author dimension only), series_index, title, filename.
function MetadataSource.sortFiles(files, active_dimension)
    local is_author = (active_dimension == "author")
    table.sort(files, function(a, b)
        if is_author then
            local as, bs = a.series_key, b.series_key
            if as ~= bs then return strcollSafe(as, bs) end
        end
        local ai, bi = a.series_index, b.series_index
        if ai ~= bi then
            if not ai then return false end
            if not bi then return true end
            return ai < bi
        end
        local at = a.title or a[2]
        local bt = b.title or b[2]
        if at ~= bt then return strcollSafe(at, bt) end
        return strcollSafe(a[2], b[2])
    end)
end

return MetadataSource
