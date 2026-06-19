-- sui_browsemeta.lua — Simple UI
-- Virtual author/series browser.
--
-- Adds two browse modes to the FM file chooser:
--   • Browse by Author  — groups all books under a base folder by author
--   • Browse by Series  — groups all books under a base folder by series
--
-- This module supersedes the former sui_metabrowser.lua (an overlay-based
-- FileChooser subclass that used a slow file-scan fallback).  All behaviour
-- from that module has been absorbed here:
--   • doc_props (title/authors/series/series_index) are now forwarded on
--     every file_list item so CoverBrowser renderers display correct metadata.
--   • mandatory text is contextual: author-mode shows series+index per book;
--     series-mode shows the author name (trimmed to "First et al." for multi).
--   • Series ordering uses numeric series_index via _sortFiles (unchanged).
--
-- Implementation overview
-- -----------------------
-- Virtual paths encode the browse state in a fake filesystem path that the
-- real OS never sees.  A Unicode "root marker" character (VROOT) separates
-- the real base directory from the virtual segment:
--
--   /real/books/󰉗/󰰗/Ursula K. Le Guin   ← author leaf
--   /real/books/󰉗/󰿷/Hainish Cycle        ← series leaf
--
-- FileChooser is patched to intercept these paths before any disk I/O and
-- serve synthetic item tables built from a direct SQL query against the
-- CoverBrowser's bookinfo_cache.sqlite3.  ffiUtil.realpath is patched so
-- KOReader never tries to resolve these paths on disk.
--
-- All patches are fully reversible via M.uninstall().
--
-- Settings key: "simpleui_browsemeta_mode"
--   "normal"  (default) — standard filesystem browsing
--   "author"            — browse by author
--   "series"            — browse by series
--
-- Public API
-- ----------
--   M.install()               — apply FileChooser + ffiUtil patches
--   M.uninstall()             — remove all patches
--   M.getCurrentMode(fc)      — "normal"|"author"|"series" from fc.path
--   M.navigateTo(fm, mode)    — navigate FM to the requested mode
--   M.getSavedMode()          — read persisted mode setting
--   M.setSavedMode(mode)      — persist mode setting
--   M.openVirtualCoverPicker(vpath, fc) — open cover-picker for a dim_list leaf
--   M.getAuthorBookCount(fc, author)    — count books by author in current base_dir (cached)
--   M.navigateToAuthorLeaf(fm, author)  — navigate FM directly to author virtual leaf

local lfs     = require("libs/libkoreader-lfs")
local util    = require("util")
local ffiUtil = require("ffi/util")
local logger  = require("logger")
local _ = require("sui_i18n").translate
local SUISettings = require("sui_store")

-- ---------------------------------------------------------------------------
-- Virtual path constants
-- ---------------------------------------------------------------------------

local VROOT     = "\u{E257}"
local VROOT_SEP = "/" .. VROOT   -- pre-built; avoids alloc on every _findVroot

-- Slashes inside tag/series/author values would be misread as path separators.
-- We encode them as U+2215 DIVISION SLASH (∕) — visually identical, never a
-- real path separator — and decode on the way out.
local PATH_SEP_ESC = "\u{2215}"
local function _encVal(v) return v:gsub("/", PATH_SEP_ESC) end
local function _decVal(v) return v:gsub(PATH_SEP_ESC, "/") end

local SYM_AUTHOR = "\u{F2C0}"
local SYM_SERIES = "\u{ECD7}"
local SYM_TAGS   = "\u{F02B}"
local NULL_MARKER = "\u{2205}"

local DIMS = {
    author = { symbol = SYM_AUTHOR, db_column = "authors",  label = _("Authors"), multi_value = true  },
    series = { symbol = SYM_SERIES, db_column = "series",   label = _("Series"),  multi_value = false },
    tags   = { symbol = SYM_TAGS,   db_column = "keywords", label = _("Tags"),    multi_value = true  },
}

local SYM_TO_DIM = {}
for k, v in pairs(DIMS) do SYM_TO_DIM[v.symbol] = k end

local DIMS_ORDER = { "author", "series", "tags" }

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local M = {}

local _FC_COVERS_KEY = "simpleui_fc_covers"

local _meta_values_cache    = {}
local _matching_files_cache = {}
local _repr_file_cache      = {}
local _author_count_cache   = {}  -- { [base_dir] = { [author_name] = count } }
local _cache_base_dir       = nil

-- Calibre metadata index: { [base_dir] = { [fullpath] = {title,authors,series,...} } }
-- Populated lazily on first _getMatchingFiles call for a given base_dir.
-- false means we already tried and found no metadata.calibre (avoid re-trying).
local _calibre_index_cache  = {}  -- { [base_dir] = table | false }

-- Lazy module references — cached on first use, cleared on uninstall.
local _bim_cache = nil
local _FM_cache  = nil
local _SP_cache  = nil
local _SP_tried  = false

-- Resolved once at install time (require("ffi") is heavy to call every nav).
local _is_windows = nil

-- ---------------------------------------------------------------------------
-- Cache management
-- ---------------------------------------------------------------------------

local function _clearCaches()
    -- Clear in-place to reuse tables and avoid GC pressure.
    for k in pairs(_meta_values_cache)    do _meta_values_cache[k]    = nil end
    for k in pairs(_matching_files_cache) do _matching_files_cache[k] = nil end
    for k in pairs(_repr_file_cache)      do _repr_file_cache[k]      = nil end
    for k in pairs(_author_count_cache)   do _author_count_cache[k]   = nil end
    for k in pairs(_calibre_index_cache)  do _calibre_index_cache[k]  = nil end
end

local function _ensureCacheBaseDir(base_dir)
    if _cache_base_dir ~= base_dir then
        _clearCaches()
        _cache_base_dir = base_dir
    end
end

-- ---------------------------------------------------------------------------
-- Virtual path helpers
-- ---------------------------------------------------------------------------

local function _findVroot(path)
    if not path then return nil end
    return path:find(VROOT_SEP, 1, true)
end

local function _isVirtual(path)
    return _findVroot(path) ~= nil
end

-- Returns base_dir, dim_key, filter_value, level.
-- Combines what was previously _parseVirtualPath + _pathLevel into one pass
-- to avoid scanning the same string twice.
local function _parseVirtualPath(path)
    local root_s, root_e = _findVroot(path)
    if not root_s then return nil end

    local base_dir = path:sub(1, root_s - 1)
    local tail     = path:sub(root_e + 1)

    local parts = {}
    for part in util.gsplit(tail, "/") do
        if part ~= "" then parts[#parts + 1] = part end
    end

    local nparts       = #parts
    local dim_key      = nparts >= 1 and SYM_TO_DIM[parts[1]] or nil
    local filter_value = nil
    if nparts >= 2 then
        -- NOTE: do NOT use the `cond and false or x` ternary here.
        -- When the intended result is the boolean `false`, that pattern
        -- falls through to `x` because `false` is falsy — a Lua gotcha.
        if parts[2] == NULL_MARKER then
            filter_value = false
        else
            filter_value = _decVal(parts[2])
        end
    end

    local level
    if nparts == 0 then
        level = "root"
    elseif nparts == 1 and dim_key then
        level = "dim_list"
    else
        level = "file_list"
    end

    return base_dir, dim_key, filter_value, level
end

-- Thin wrapper returning only the level (nil when not virtual).
local function _pathLevel(path)
    if not _findVroot(path) then return nil end
    local _, _, _, level = _parseVirtualPath(path)
    return level
end

local function _baseDir(path)
    if not path then return path end
    local s = _findVroot(path)
    if s then return path:sub(1, s - 1) end
    return path
end

local function _dimPath(base_dir, dim_key)
    return base_dir .. VROOT_SEP .. "/" .. DIMS[dim_key].symbol
end

local function _leafPath(base_dir, dim_key, value)
    local v_enc = (value == false or value == nil) and NULL_MARKER or _encVal(value)
    return base_dir .. VROOT_SEP .. "/" .. DIMS[dim_key].symbol .. "/" .. v_enc
end

-- ---------------------------------------------------------------------------
-- Lazy module loaders
-- ---------------------------------------------------------------------------

local function _getBookInfoManager()
    if _bim_cache then return _bim_cache end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim then
        _bim_cache = bim
        return bim
    end
    logger.warn("sui_browsemeta: could not load BookInfoManager")
    return nil
end

local function _getFileManager()
    if _FM_cache then return _FM_cache end
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    if ok and FM then _FM_cache = FM end
    return _FM_cache
end

local function _getSuiPatches()
    if _SP_tried then return _SP_cache end
    _SP_tried = true
    local ok, SP = pcall(require, "sui_patches")
    if ok and SP then _SP_cache = SP end
    return _SP_cache
end

-- ---------------------------------------------------------------------------
-- Calibre metadata index
-- ---------------------------------------------------------------------------

-- Loads metadata.calibre from *dir* (read-only / search mode) and returns a
-- lookup table keyed by the book's absolute path on disk:
--
--   { ["/sdcard/Books/Comics/Batman/issue1.cbz"] = {
--       title        = "Batman #1",
--       authors      = "Grant Morrison\nDave McKean",   ← newline-delimited
--       series       = "Arkham Asylum",
--       series_index = 1,
--       keywords     = "DC Comics\nSuperhero",          ← newline-delimited
--     }, ... }
--
-- Returns false when no metadata.calibre exists under *dir*.
-- Result is cached in _calibre_index_cache for the session.
local function _loadCalibreIndex(dir)
    local cached = _calibre_index_cache[dir]
    if cached ~= nil then return cached end  -- false = already tried, nothing found

    -- "metadata" is reachable because KOReader's PluginLoader appends every enabled
    -- plugin directory to package.path at startup (pluginloader.lua loadPlugins()).
    -- package.loaded["metadata"] is set on first require; subsequent calls are free.
    local ok_cm, CalibreMetadata = pcall(require, "metadata")
    -- Guard: make sure we got CalibreMetadata, not some unrelated "metadata" module.
    if not ok_cm or not CalibreMetadata or type(CalibreMetadata.loadBookList) ~= "function" then
        _calibre_index_cache[dir] = false
        return false
    end

    -- Create a fresh instance so we never mutate the shared singleton that
    -- the Calibre plugin itself may be using.
    local cm = setmetatable({}, { __index = CalibreMetadata })
    cm.drive = {}
    cm.books = {}

    local ok_init, result = pcall(function() return cm:init(dir, true) end)
    if not ok_init or not result then
        cm:clean()
        _calibre_index_cache[dir] = false
        return false
    end

    -- Build the index: absolute path → metadata row.
    local index = {}
    for _, book in ipairs(cm.books) do
        local lpath = book.lpath
        -- lpath is nil/null for corrupted entries; guard before concat.
        if lpath and type(lpath) == "string" then
            local fullpath = dir .. "/" .. lpath

            -- authors: JSON array {"Author One", "Author Two"} → newline string.
            local authors_str
            local raw_authors = book.authors
            if raw_authors and type(raw_authors) == "table" and #raw_authors > 0 then
                authors_str = table.concat(raw_authors, "\n")
            end

            -- tags: JSON array → newline string (stored in bookinfo as "keywords").
            local keywords_str
            local raw_tags = book.tags
            if raw_tags and type(raw_tags) == "table" and #raw_tags > 0 then
                keywords_str = table.concat(raw_tags, "\n")
            end

            -- series / series_index: null is stored as rapidjson.null (light userdata).
            local series = book.series
            if type(series) ~= "string" then series = nil end
            local series_index = book.series_index
            if type(series_index) ~= "number" then series_index = nil end

            local title = book.title
            if type(title) ~= "string" then title = nil end

            index[fullpath] = {
                title        = title,
                authors      = authors_str,
                series       = series,
                series_index = series_index,
                keywords     = keywords_str,
            }
        end
    end
    cm:clean()

    if next(index) then
        _calibre_index_cache[dir] = index
        local n = 0; for _ in pairs(index) do n = n + 1 end
        logger.dbg("sui_browsemeta: calibre index loaded for", dir, "(", n, "entries)")
        return index
    else
        _calibre_index_cache[dir] = false
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Database access
-- ---------------------------------------------------------------------------

-- Constant SQL base — never allocated at runtime.
local _SQL_BASE = "SELECT directory, filename, title, authors, series, series_index, keywords"
               .. " FROM bookinfo WHERE directory GLOB ?"

-- Returns { {fullpath, filename, title=, authors=, series=, series_index=}, ... }
-- lfs.attributes() is NOT called here; validation happens in the render loop
-- where the attr table is needed anyway, keeping this function to pure SQL.
local function _getMatchingFiles(base_dir, filters)
    local bim = _getBookInfoManager()
    if not bim then return {} end

    local vars = { base_dir .. "/*" }
    local sql  = _SQL_BASE

    for _, f in ipairs(filters or {}) do
        local col, val = f[1], f[2]
        if val == false then
            sql = sql .. " AND " .. col .. " IS NULL"
        elseif col == "authors" or col == "keywords" then
            -- Multi-value fields: newline-delimited, match exact token.
            sql = sql .. " AND '\n'||" .. col .. "||'\n' GLOB ?"
            vars[#vars + 1] = "*\n" .. val .. "\n*"
        else
            sql = sql .. " AND " .. col .. "=?"
            vars[#vars + 1] = val
        end
    end
    sql = sql .. " ORDER BY directory ASC, filename ASC"

    local results = {}
    local stmt
    local ok, err = pcall(function()
        bim:openDbConnection()
        stmt = bim.db_conn:prepare(sql)
        stmt:bind(table.unpack(vars))
        while true do
            local row = stmt:step()
            if not row then break end
            -- Concatenate in Lua; avoids SQLite per-row string concat.
            results[#results + 1] = {
                row[1] .. row[2], row[2],
                title        = row[3],
                authors      = row[4],
                series       = row[5],
                series_index = tonumber(row[6]),
                keywords     = row[7],
            }
        end
    end)
    -- Always finalize — prevents SQLite statement leaks on error paths.
    if stmt then pcall(function() stmt:finalize() end) end
    if not ok then
        logger.warn("sui_browsemeta: SQL error:", tostring(err))
        return {}
    end
    -- Enrich rows that the bookinfo DB does not yet know about (e.g. CBZ files
    -- that have never been opened and therefore were never scanned by CoverBrowser)
    -- using data from Calibre's metadata.calibre JSON file when it exists.
    --
    -- Strategy:
    --   1. Build a set of fullpaths already present in the SQL results.
    --   2. Load the calibre index for base_dir (cached after first call).
    --   3. For each calibre entry under base_dir, if the file is not in the
    --      SQL results AND it exists on disk, append a synthetic row.
    --   4. For SQL rows that have no authors/series, backfill from calibre
    --      so the browse grouping works even before the first document open.
    --
    -- bookinfo values always take priority — custom metadata edits are preserved.

    local cal_index = _loadCalibreIndex(base_dir)
    if cal_index then
        -- Pass 1: backfill missing fields in existing SQL rows.
        for _, row in ipairs(results) do
            local cal = cal_index[row[1]]
            if cal then
                if not row.authors      then row.authors      = cal.authors      end
                if not row.series       then row.series       = cal.series       end
                if not row.series_index then row.series_index = cal.series_index end
                if not row.title        then row.title        = cal.title        end
                if not row.keywords     then row.keywords     = cal.keywords     end
            end
        end

        -- Pass 2: append calibre-only entries (files never scanned by bookinfo).
        -- Build a fast-lookup set of paths already in results.
        local seen = {}
        for _, row in ipairs(results) do seen[row[1]] = true end

        -- Apply any filters that were passed to _getMatchingFiles.
        local function _calibreRowMatchesFilters(cal_row)
            for _, f in ipairs(filters or {}) do
                local col, val = f[1], f[2]
                -- Map bookinfo column names to calibre index field names.
                local field_map = {
                    authors  = "authors",
                    series   = "series",
                    keywords = "keywords",
                }
                local field = field_map[col] or col
                local fval  = cal_row[field]
                if val == false then
                    if fval ~= nil then return false end
                elseif col == "authors" or col == "keywords" then
                    -- Multi-value: newline-delimited token match.
                    if not fval then return false end
                    local token = val
                    if not ("\n" .. fval .. "\n"):find("\n" .. token .. "\n", 1, true) then
                        return false
                    end
                else
                    if fval ~= val then return false end
                end
            end
            return true
        end

        for fullpath, cal in pairs(cal_index) do
            if not seen[fullpath] and _calibreRowMatchesFilters(cal) then
                local fname = fullpath:match("([^/]+)$")
                if fname then
                    results[#results + 1] = {
                        fullpath, fname,
                        title        = cal.title,
                        authors      = cal.authors,
                        series       = cal.series,
                        series_index = cal.series_index,
                        keywords     = cal.keywords,
                    }
                end
            end
        end
    end

    return results
end

-- ---------------------------------------------------------------------------
-- Metadata grouping
-- ---------------------------------------------------------------------------

-- Returns { {value, count, _first=row}, ... } for dim_key under base_dir.
-- _first carries the first file row so _getVirtualList can seed
-- _repr_file_cache without an additional SQL query per item.
local function _getMetadataValues(base_dir, dim_key)
    local files   = _getMatchingFiles(base_dir, {})
    local grouped = {}
    local first   = {}

    for _, row in ipairs(files) do
        if dim_key == "author" or dim_key == "tags" then
            -- Multi-value dimension: one book can appear under several entries.
            local raw = (dim_key == "author") and row.authors or row.keywords
            if raw and raw:find("\n", 1, true) then
                for token in util.gsplit(raw, "\n") do
                    if token ~= "" then
                        if not grouped[token] then
                            grouped[token] = 0
                            first[token]   = row
                        end
                        grouped[token] = grouped[token] + 1
                    end
                end
            else
                local key = raw or false
                if not grouped[key] then
                    grouped[key] = 0
                    first[key]   = row
                end
                grouped[key] = grouped[key] + 1
            end
        else
            -- Single-value dimension (series).
            local key = row.series or false
            if not grouped[key] then
                grouped[key] = 0
                first[key]   = row
            end
            grouped[key] = grouped[key] + 1
        end
    end

    local out = {}
    for value, count in pairs(grouped) do
        out[#out + 1] = { value, count, _first = first[value] }
    end

    table.sort(out, function(a, b)
        local av, bv = a[1], b[1]
        if av == bv then return false end
        if not av or av == false or av == "" then return false end
        if not bv or bv == false or bv == "" then return true  end
        return ffiUtil.strcoll(av, bv)
    end)

    return out
end

-- ---------------------------------------------------------------------------
-- Sort helpers for file lists
-- ---------------------------------------------------------------------------

local function _strcollSafe(a, b)
    if a == b              then return false end
    if not a or a == false then return false end
    if not b or b == false then return true  end
    return ffiUtil.strcoll(a, b)
end

-- Sort by: series name (author dim only), series_index, title, filename.
-- Comparator is a strict weak order — series equality test is explicit.
local function _sortFiles(files, dim_key)
    local is_author = (dim_key == "author")
    table.sort(files, function(a, b)
        if is_author then
            -- In author mode group books by series, then by index within series.
            local as, bs = a.series, b.series
            if as ~= bs then return _strcollSafe(as, bs) end
        end
        local ai, bi = a.series_index, b.series_index
        if ai ~= bi then
            if not ai then return false end
            if not bi then return true  end
            return ai < bi
        end
        local at = a.title or a[2]
        local bt = b.title or b[2]
        if at ~= bt then return _strcollSafe(at, bt) end
        return _strcollSafe(a[2], b[2])
    end)
end

-- ---------------------------------------------------------------------------
-- Representative file
-- ---------------------------------------------------------------------------

local function _getRepresentativeFile(base_dir, dim_key, filter_value)
    local leaf_path = _leafPath(base_dir, dim_key, filter_value)

    local overrides   = SUISettings:readSetting(_FC_COVERS_KEY) or {}
    local override_fp = overrides[leaf_path]
    if override_fp and lfs.attributes(override_fp, "mode") == "file" then
        _repr_file_cache[leaf_path] = override_fp
        return override_fp
    end

    if _repr_file_cache[leaf_path] ~= nil then
        return _repr_file_cache[leaf_path] or nil
    end
    _ensureCacheBaseDir(base_dir)
    local files = _matching_files_cache[leaf_path]
    if not files then
        local col = DIMS[dim_key].db_column
        files = _getMatchingFiles(base_dir, { { col, filter_value } })
        _sortFiles(files, dim_key)
        _matching_files_cache[leaf_path] = files
    end
    local fp = files[1] and files[1][1] or false
    _repr_file_cache[leaf_path] = fp
    return fp or nil
end

-- ---------------------------------------------------------------------------
-- Fake attributes — single shared instance for virtual directory entries.
-- ---------------------------------------------------------------------------

local _FAKE_DIR_ATTR = {
    mode = "directory", modification = 0, access = 0, change = 0, size = 0,
}

local function _fakeAttr(size)
    _FAKE_DIR_ATTR.size = size or 0
    return _FAKE_DIR_ATTR
end

-- ---------------------------------------------------------------------------
-- Virtual list builder
-- ---------------------------------------------------------------------------

local function _getVirtualList(fc, path, collate)
    local base_dir, dim_key, filter_value, level = _parseVirtualPath(path)
    if not level then return {}, {} end

    local dirs, files = {}, {}

    if level == "root" then
        for i, dk in ipairs(DIMS_ORDER) do
            local dim   = DIMS[dk]
            local text  = dim.symbol .. "  " .. (_("Browse by") .. " " .. dim.label)
            local vpath = _dimPath(base_dir, dk)
            if collate then
                local item = fc:getListItem(nil, text, vpath, _fakeAttr(i), collate)
                item.mandatory = nil
                dirs[#dirs + 1] = item
            else
                dirs[#dirs + 1] = true
            end
        end
        return dirs, files
    end

    if not base_dir or not dim_key then return dirs, files end
    _ensureCacheBaseDir(base_dir)

    if level == "dim_list" then
        local values = _meta_values_cache[path]
        if not values then
            values = _getMetadataValues(base_dir, dim_key)
            _meta_values_cache[path] = values
        end
        local overrides = SUISettings:readSetting(_FC_COVERS_KEY) or {}
        for i, v in ipairs(values) do
            local val   = v[1]
            local label = (val == false or val == nil) and NULL_MARKER or val
            local vpath = _leafPath(base_dir, dim_key, val)
            if collate then
                -- Compute the real count by applying the same filters that
                -- file_list uses when rendering: lfs.attributes (existence on
                -- disk) and fc:show_file (extension/hidden-file filters).
                -- The SQL count in v[2] may be higher when the bookinfo DB
                -- contains stale entries for deleted files, or when fc's
                -- show_file filter hides certain extensions.
                local col = DIMS[dim_key].db_column
                local raw_rows = _getMatchingFiles(base_dir, { { col, val } })
                local real_count = 0
                local real_repr  = nil
                for _, row in ipairs(raw_rows) do
                    local fullpath = row[1]
                    local fname    = row[2]
                    local attr = lfs.attributes(fullpath)
                    if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
                        real_count = real_count + 1
                        if not real_repr then real_repr = fullpath end
                    end
                end

                -- Skip virtual folders whose every book has been deleted from disk.
                -- The bookinfo DB may still hold stale metadata for those files,
                -- but showing an empty virtual folder would confuse the user.
                if real_count == 0 then
                    _repr_file_cache[vpath] = nil  -- evict any stale repr entry
                    -- fall through to else branch: add a plain 'true' placeholder
                    -- so the parent count (dirs) stays consistent for non-collate callers.
                else

                local item = fc:getListItem(nil, label, vpath, _fakeAttr(i), collate)
                item.nb_sub_files = real_count
                item.mandatory    = tostring(real_count) .. " \u{F016}"

                -- Populate repr cache from the metadata scan to avoid per-item
                -- SQL queries. User override takes priority.
                local repr
                local override_fp = overrides[vpath]
                if override_fp and lfs.attributes(override_fp, "mode") == "file" then
                    repr = override_fp
                    _repr_file_cache[vpath] = repr
                elseif real_repr then
                    -- real_repr comes from the current scan and is verified on disk;
                    -- always prefer it over a potentially stale cached value.
                    repr = real_repr
                    _repr_file_cache[vpath] = repr
                elseif _repr_file_cache[vpath] ~= nil then
                    repr = _repr_file_cache[vpath] or nil
                elseif v._first then
                    repr = v._first[1]
                    _repr_file_cache[vpath] = repr
                end

                -- Always mark as a virtual meta leaf so the folder decoration
                -- (stacked-cover lines + badge) is rendered even when no
                -- representative cover is available (e.g. the ∅ no-author/
                -- no-series bucket whose books have no cached covers yet).
                item.is_virtual_meta_leaf = true
                item.virtual_leaf_count   = real_count
                if repr then
                    item.representative_filepath = repr
                end
                dirs[#dirs + 1] = item
                end -- real_count > 0
            else
                dirs[#dirs + 1] = true
            end
        end
        return dirs, files
    end

    if level == "file_list" then
        local col    = DIMS[dim_key].db_column
        local cached = _matching_files_cache[path]
        if not cached then
            cached = _getMatchingFiles(base_dir, { { col, filter_value } })
            _sortFiles(cached, dim_key)
            _matching_files_cache[path] = cached
        end
        local is_author_dim = (dim_key == "author")  -- tags + series share the "else" path
        for _, row in ipairs(cached) do
            local fullpath = row[1]
            local fname    = row[2]
            -- lfs.attributes() is needed here: FC requires the attr table to
            -- build each list item, and it doubles as a stale-entry filter.
            local attr = lfs.attributes(fullpath)
            if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
                local item = fc:getListItem(path, fname, fullpath, attr, collate)
                -- Forward metadata from the SQL row so CoverBrowser and list-view
                -- renderers can display title/author/series without re-reading
                -- the sidecar. Mirrors what sui_metabrowser did via _buildBookItems.
                if row.title or row.authors or row.series then
                    item.doc_props = {
                        display_title = row.title,
                        authors       = row.authors,
                        series        = row.series,
                        series_index  = row.series_index,
                    }
                end
                -- Contextual mandatory text:
                --   author mode  → series + index (gives reading-order context)
                --   series mode  → first author name
                --   tags mode    → first author name (same as series mode)
                if collate then
                    if is_author_dim then
                        if row.series and row.series ~= "" then
                            local m = row.series
                            if row.series_index then
                                m = m .. " #" .. tostring(row.series_index)
                            end
                            item.mandatory = m
                        end
                    else
                        -- series and tags modes: show first author
                        if row.authors and row.authors ~= "" then
                            item.mandatory = row.authors:gsub("\n.*", " et al.")
                        end
                    end
                end
                files[#files + 1] = item
            end
        end
        return dirs, files
    end

    return dirs, files
end

-- ---------------------------------------------------------------------------
-- Enabled / disabled setting
-- ---------------------------------------------------------------------------

local _BM_KEY = "simpleui_browsemeta_enabled"

function M.isEnabled()
    return SUISettings:nilOrTrue(_BM_KEY)
end

function M.setEnabled(v)
    SUISettings:saveSetting(_BM_KEY, v)
end

-- ---------------------------------------------------------------------------
-- Public path helpers
-- ---------------------------------------------------------------------------

function M.getPathLevel(path)
    return _pathLevel(path)
end

function M.getCurrentMode(fc)
    local path = fc and fc.path
    if not path or not _isVirtual(path) then return "normal" end
    local _, dim_key = _parseVirtualPath(path)
    return dim_key or "normal"
end

-- ---------------------------------------------------------------------------
-- Persisted mode setting
-- ---------------------------------------------------------------------------

local _MODE_KEY = "simpleui_browsemeta_mode"

function M.getSavedMode()
    return SUISettings:readSetting(_MODE_KEY) or "normal"
end

function M.setSavedMode(mode)
    SUISettings:saveSetting(_MODE_KEY, mode)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function M.exitToNormal(fc, fm)
    if not fc then return end
    local base = _baseDir(fc.path)
    -- Persist "normal" BEFORE changeToPath so that if changeToPath errors out
    -- (caught upstream by a pcall), the next session never tries to restore a
    -- virtual path with the BM patches absent.
    M.setSavedMode("normal")
    fc._browse_by_meta_entry_path = nil
    if fm then fm._navbar_suppress_path_change = true end
    fc:changeToPath(base)
    if fm then fm._navbar_suppress_path_change = nil end
    if fm and fm.updateTitleBarPath then
        pcall(function() fm:updateTitleBarPath(base) end)
    end
end

function M.navigateTo(fm, mode)
    local fc = fm and fm.file_chooser
    if not fc then return end

    local base = _baseDir(fc.path)

    if mode == "normal" then
        M.exitToNormal(fc, fm)
        return
    end

    local target = _dimPath(base, mode)
    -- Always mark the dim_list root as the entry point so the up button is
    -- never shown when the user is at the top-level Authors/Series list.
    fc._browse_by_meta_entry_path = target
    fm._navbar_suppress_path_change = true
    fc:changeToPath(target)
    fm._navbar_suppress_path_change = nil
    if fm.updateTitleBarPath then
        pcall(function() fm:updateTitleBarPath(target) end)
    end
    -- Force the titlebar to re-evaluate the back-button state for page 1.
    -- onGotoPage triggers _resolveIsSub which re-checks the path-based state,
    -- ensuring the back button is correct when lock_home_folder is active.
    if fc.onGotoPage then
        pcall(function() fc:onGotoPage(1) end)
    end
    M.setSavedMode(mode)
end

-- navigateToRoot(fc, fm, mode)
-- Re-navigates to the top-level dim_list (Authors or Series) without exiting
-- to the normal filesystem.  Called when the user taps an already-active
-- browse_authors / browse_series tab in the bottom bar — the expected UX is
-- to jump back to the root of that virtual folder (page 1, no up button),
-- analogous to tapping the Library tab going back to home_dir page 1.
function M.navigateToRoot(fc, fm, mode)
    if not fc or not mode then return end
    local base   = _baseDir(fc.path)
    local target = _dimPath(base, mode)
    -- Re-set the entry path so the up button stays hidden at this level.
    fc._browse_by_meta_entry_path = target
    -- If we are already at the dim_list root, just go to page 1 + refresh.
    if fc.path == target then
        if fm then fm._navbar_suppress_path_change = true end
        pcall(function() fc:onGotoPage(1) end)
        pcall(function() fc:refreshPath() end)
        if fm then fm._navbar_suppress_path_change = nil end
    else
        -- Navigate from a sub-folder back up to the dim_list root.
        if fm then fm._navbar_suppress_path_change = true end
        fc:changeToPath(target)
        if fm then fm._navbar_suppress_path_change = nil end
        if fm and fm.updateTitleBarPath then
            pcall(function() fm:updateTitleBarPath(target) end)
        end
        if fc.onGotoPage then
            pcall(function() fc:onGotoPage(1) end)
        end
    end
end

-- isAtVirtualRoot(fc, mode)
-- Returns true when the file chooser is currently showing the dim_list root
-- for the given mode ("author" or "series").  Used by the bottom bar to
-- decide whether a re-tap should go to page 1 in place, or navigate up.
function M.isAtVirtualRoot(fc, mode)
    if not fc or not mode then return false end
    local base   = _baseDir(fc.path)
    local target = _dimPath(base, mode)
    return fc.path == target
end

-- ---------------------------------------------------------------------------
-- Author-dialog helpers
-- ---------------------------------------------------------------------------

-- Returns the number of books by *author_name* under the current FM base_dir.
-- Result is cached for the lifetime of the session / until M.reset().
-- Returns 0 when BM is unavailable or author is empty.
function M.getAuthorBookCount(fc, author_name)
    if not fc or not author_name or author_name == "" then return 0 end
    local base = _baseDir(fc.path)
    if not base then return 0 end

    -- Check session cache first to avoid repeated SQL on every dialog open.
    _author_count_cache[base] = _author_count_cache[base] or {}
    local cached = _author_count_cache[base][author_name]
    if cached ~= nil then return cached end

    local files = _getMatchingFiles(base, { { "authors", author_name } })
    local count = 0
    for _, row in ipairs(files) do
        local fullpath = row[1]
        local fname    = row[2]
        local attr = lfs.attributes(fullpath)
        if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
            count = count + 1
        end
    end
    _author_count_cache[base][author_name] = count
    return count
end

-- Navigates the FM directly to the virtual leaf for *author_name*, bypassing
-- the top-level Authors list.  The up-button / back-button will land on the
-- Authors root (not the real filesystem), matching the expected UX.
--
-- origin_file (optional): the book file that triggered this navigation.
--   When provided, pressing back from the virtual leaf returns directly to the
--   real folder where the book lives, with the list scrolled to that book.
--   Without it, back lands on the Authors root (normal BrowseMeta behaviour).
--
-- Preconditions: BM must be installed (M.install() called).
function M.navigateToAuthorLeaf(fm, author_name, origin_file)
    if not fm or not author_name or author_name == "" then return end
    local fc = fm.file_chooser
    if not fc then return end

    local base   = _baseDir(fc.path)
    local target = _leafPath(base, "author", author_name)

    -- Save the origin so onFolderUp can return to exactly the right place.
    -- Stored on fc (not a module upvalue) so it survives across module reloads.
    if origin_file then
        -- real_path is the actual folder the file lives in.
        local real_path = fc.path
        if _isVirtual(real_path) then real_path = base end
        fc._sui_author_dialog_origin = { path = real_path, file = origin_file }
    else
        fc._sui_author_dialog_origin = nil
    end

    -- Set the entry path to the Authors root so the up-button hierarchy is
    -- correct when the user did NOT come from the dialog (normal BM flow).
    fc._browse_by_meta_entry_path = _dimPath(base, "author")
    fm._navbar_suppress_path_change = true
    fc:changeToPath(target)
    fm._navbar_suppress_path_change = nil
    if fm.updateTitleBarPath then
        pcall(function() fm:updateTitleBarPath(target) end)
    end
    if fc.onGotoPage then
        pcall(function() fc:onGotoPage(1) end)
    end
    -- Persist "author" mode so the next session restores the virtual tree.
    M.setSavedMode("author")
end

-- ---------------------------------------------------------------------------
-- FileChooser patches
-- ---------------------------------------------------------------------------

local _patched_genitp     = false
local _patched_genit      = false
local _patched_refresh    = false
local _patched_menusel    = false
local _patched_menuhold   = false
local _patched_mandatory  = false
local _patched_realpath   = false
local _patched_showdialog = false

local _orig_genItemTableFromPath = nil
local _orig_genItemTable         = nil
local _orig_refreshPath          = nil
local _orig_onMenuSelect         = nil
local _orig_onMenuHold           = nil
local _orig_getMenuItemMandatory = nil
local _orig_realpath             = nil
local _orig_showFileDialog       = nil

local function _getCoverOverrides()
    return SUISettings:readSetting(_FC_COVERS_KEY) or {}
end

local function _saveCoverOverride(vpath, book_path)
    local t = _getCoverOverrides()
    t[vpath] = book_path
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

local function _clearCoverOverride(vpath)
    local t = _getCoverOverrides()
    t[vpath] = nil
    SUISettings:saveSetting(_FC_COVERS_KEY, t)
end

local function _invalidateVirtualItem(menu, vpath)
    if not menu or not menu.layout then return end
    for _, row in ipairs(menu.layout) do
        for _, item in ipairs(row) do
            if item._foldercover_processed
                and item.entry and item.entry.path == vpath then
                item._foldercover_processed = false
            end
        end
    end
    menu:updateItems(1, true)
end

-- ---------------------------------------------------------------------------
-- _createCollectionFromVirtualFolder(vpath, fc)
--
-- Called from the onMenuHold / showFileDialog interceptors when the user
-- long-presses a virtual meta leaf and selects "Create collection".
--
-- Behaviour:
--   • Pre-fills the InputDialog with the leaf's filter value (author name,
--     series name, or tag).  The user can edit it before confirming.
--   • Calls ReadCollection:addCollection + addItem for every matching book,
--     then writes the collection file once.
--   • Shows an InfoMessage with the final count.
--   • filter_value == false means the "no metadata" bucket (∅) — the name
--     field is left empty so the user must type one.
-- ---------------------------------------------------------------------------
local function _createCollectionFromVirtualFolder(vpath, fc)  -- luacheck: ignore fc
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local T           = require("ffi/util").template

    local base_dir, dim_key, filter_value = _parseVirtualPath(vpath)
    if not base_dir or not dim_key or filter_value == nil then return end
    -- "No value" virtual folders (filter_value == false) have no meaningful
    -- name and produce a collection without a clear identity.
    if filter_value == false then return end

    local suggested = (filter_value ~= false) and filter_value or ""

    local RC = require("readcollection")

    local input_dialog
    input_dialog = InputDialog:new{
        title   = _("New collection name"),
        input   = suggested,
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function()
                    UIManager:close(input_dialog)
                end,
            },
            {
                text = _("Create"),
                callback = function()
                    local name = input_dialog:getInputText()
                    if name == "" then return end
                    UIManager:close(input_dialog)

                    if RC.coll[name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Collection already exists: %1"), name),
                        })
                        return
                    end

                    -- Fetch all books matching this virtual folder's filter.
                    local col     = DIMS[dim_key].db_column
                    local filters = (filter_value ~= false)
                        and { { col, filter_value } }
                        or  { { col, false } }
                    local books = _getMatchingFiles(base_dir, filters)

                    RC:addCollection(name)
                    local count = 0
                    for _, row in ipairs(books) do
                        local fp = row[1]
                        -- coll[name] is a fresh empty table, but guard anyway.
                        if not RC.coll[name][fp] then
                            RC:addItem(fp, name)
                            count = count + 1
                        end
                    end
                    RC:write({ [name] = true })

                    UIManager:show(InfoMessage:new{
                        text    = T(_("Collection \"%1\" created with %2 books."),
                                    name, count),
                        timeout = 3,
                    })
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function _openVirtualCoverPicker(vpath, fc)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")

    local base_dir, dim_key, filter_value = _parseVirtualPath(vpath)
    if not base_dir or not dim_key then return end

    local col   = DIMS[dim_key].db_column
    local books = _getMatchingFiles(base_dir, { { col, filter_value } })
    _sortFiles(books, dim_key)

    if #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found."), timeout = 2 })
        return
    end

    local bim          = _getBookInfoManager()
    local overrides    = _getCoverOverrides()
    local cur_override = overrides[vpath]
    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "\u{2713} " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            _clearCoverOverride(vpath)
            _repr_file_cache[vpath] = nil
            _invalidateVirtualItem(fc, vpath)
        end,
    }}

    for _, row in ipairs(books) do
        local fp    = row[1]
        local title = row.title
        if not title or title == "" then
            title = fp:match("([^/]+)%.[^%.]+$") or fp
        end
        if bim then
            local bi = bim:getBookInfo(fp, false)
            if bi and bi.title and bi.title ~= "" then title = bi.title end
        end
        local _fp = fp
        buttons[#buttons + 1] = {{
            text = ((cur_override == _fp) and "\u{2713} " or "  ") .. title,
            callback = function()
                UIManager:close(picker)
                _saveCoverOverride(vpath, _fp)
                _repr_file_cache[vpath] = _fp
                _invalidateVirtualItem(fc, vpath)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{ title = _("Folder cover"), title_align = "center", buttons = buttons }
    UIManager:show(picker)
end

local function _installPatches()
    local FileChooser = require("ui/widget/filechooser")
    local BD          = require("ui/bidi")

    -- Resolve once; avoids require("ffi") on every folder navigation.
    _is_windows = (require("ffi").os == "Windows")

    if not _patched_genitp then
        _patched_genitp = true
        _orig_genItemTableFromPath = FileChooser.genItemTableFromPath
        local orig = _orig_genItemTableFromPath
        FileChooser.genItemTableFromPath = function(fc, path)
            if _isVirtual(path) then
                local collate = fc:getCollate()
                local dirs, fls = _getVirtualList(fc, path, collate)
                return fc:genItemTable(dirs, fls, path)
            end
            return orig(fc, path)
        end
    end

    if not _patched_genit then
        _patched_genit = true
        _orig_genItemTable = FileChooser.genItemTable
        local orig = _orig_genItemTable
        FileChooser.genItemTable = function(fc, dirs, fls, path)
            if path == nil then
                return orig(fc, dirs, fls, path)
            end
            if not _isVirtual(path) then
                local t = orig(fc, dirs, fls, path)
                if t[1] and t[1].path and t[1].path:find("/..$") then
                    t[1].path = path .. "/.."
                end
                return t
            end

            local item_table = {}
            for _, d in ipairs(dirs) do item_table[#item_table + 1] = d end
            for _, f in ipairs(fls)  do item_table[#item_table + 1] = f end

            local up_path = path:gsub("(/[^/]+)$", "")
            local hide_up = fc._browse_by_meta_entry_path == path
            if not hide_up and path ~= "/" then
                table.insert(item_table, 1, {
                    text     = BD.mirroredUILayout() and BD.ltr("../ \u{2B06}") or "\u{2B06} ../",
                    path     = up_path,
                    is_go_up = true,
                })
            end

            if _is_windows then
                for _, v in ipairs(item_table) do
                    if v.text then
                        v.text = ffiUtil.multiByteToUTF8(v.text) or ""
                    end
                end
            end

            return item_table
        end
    end

    if not _patched_refresh then
        _patched_refresh = true
        _orig_refreshPath = FileChooser.refreshPath
        local orig = _orig_refreshPath
        FileChooser.refreshPath = function(fc)
            if _isVirtual(fc.path) then _clearCaches() end
            return orig(fc)
        end
    end

    if not _patched_menusel then
        _patched_menusel = true
        _orig_onMenuSelect = FileChooser.onMenuSelect
        local orig = _orig_onMenuSelect
        FileChooser.onMenuSelect = function(fc, item)
            if item and item.path and _isVirtual(item.path) then
                if item.is_go_up and _pathLevel(fc.path) == "dim_list" then
                    local FM = _getFileManager()
                    M.exitToNormal(fc, FM and FM.instance)
                    return true
                end
                fc:changeToPath(item.path, item.is_go_up and fc.path)
                -- Re-evaluate the back-button after entering a virtual sub-folder,
                -- so lock_home_folder does not suppress it incorrectly.
                if fc.onGotoPage then
                    pcall(function() fc:onGotoPage(1) end)
                end
                return true
            end
            return orig(fc, item)
        end
    end

    if not _patched_mandatory then
        _patched_mandatory = true
        _orig_getMenuItemMandatory = FileChooser.getMenuItemMandatory
        local orig = _orig_getMenuItemMandatory
        local T    = ffiUtil.template
        FileChooser.getMenuItemMandatory = function(fc, item, collate)
            if item.nb_sub_files then
                return T("%1 \u{F016}", item.nb_sub_files)
            end
            return orig(fc, item, collate)
        end
    end

    if not _patched_realpath then
        _patched_realpath = true
        _orig_realpath = ffiUtil.realpath
        local orig = _orig_realpath
        ffiUtil.realpath = function(path)
            if path and path ~= "/" and path:sub(-1) == "/" then
                path = path:sub(1, -2)
            end
            if path and _isVirtual(path) then
                if path:sub(-3) == "/.." then
                    return path:gsub("/[^/]+/..$", "")
                end
                return path
            end
            return orig(path)
        end
    end

    if not _patched_showdialog then
        _patched_showdialog = true
        _orig_showFileDialog = FileChooser.showFileDialog
        local orig = _orig_showFileDialog
        FileChooser.showFileDialog = function(fc, item)
            if item and item.path and _isVirtual(item.path) then
                fc.book_props = nil
                -- In mosaic/grid mode (display_mode_type == "mosaic") the
                -- cover picker makes no sense, so leaf long-press only offers
                -- "Create collection".  In list mode the full context menu
                -- (_patched_menuhold) fires first and showFileDialog is never
                -- reached for leaf items; this branch handles the mosaic path.
                if item.is_virtual_meta_leaf then
                    -- NULL_MARKER leaf (∅ / no metadata): long-press disabled.
                    local _bd, _dk, fv = _parseVirtualPath(item.path)
                    if fv == false then return true end
                    _createCollectionFromVirtualFolder(item.path, fc)
                end
                -- Non-leaf virtual items (dim-root folders such as "Authors")
                -- still return true silently — no sensible action to offer.
                return true
            end
            return orig(fc, item)
        end
    end

    if not _patched_menuhold then
        _patched_menuhold = true
        _orig_onMenuHold = FileChooser.onMenuHold
        local orig = _orig_onMenuHold
        FileChooser.onMenuHold = function(fc, item)
            -- Intercept long-press on any virtual meta leaf in list/list-image
            -- modes.  In mosaic/grid mode this handler is not reached for
            -- folder items — the CoverBrowser routes those through
            -- showFileDialog instead (handled in _patched_showdialog above).
            if item and item.path and item.is_virtual_meta_leaf then
                local UIManager    = require("ui/uimanager")
                local ButtonDialog = require("ui/widget/buttondialog")
                local BD           = require("ui/bidi")
                local dialog
                local folder_name  = (item.text or item.path:match("([^/]+)$") or ""):gsub("/$", "")
                local _bd, _dk, fv = _parseVirtualPath(item.path)
                -- NULL_MARKER leaf (∅ / no metadata): long-press disabled.
                if fv == false then return true end
                dialog = ButtonDialog:new{
                    title       = folder_name,
                    title_align = "center",
                    buttons = (function()
                        local btns = {}
                        -- Hide the cover picker in quad mosaic mode (the quad
                        -- grid always auto-selects covers; single-cover override
                        -- is not applicable in that mode).
                        local in_list_view = fc and fc.display_mode_type == "list"
                        local ok_fc_mod, FC = pcall(require, "sui_foldercovers")
                        local effective_style = (ok_fc_mod and FC and FC.resolveStyle)
                            and FC.resolveStyle(fc, item.path, item) or "single"
                        if effective_style ~= "quad" or in_list_view then
                            btns[#btns + 1] = {{
                                text     = _("Set folder cover"),
                                callback = function()
                                    UIManager:close(dialog)
                                    _openVirtualCoverPicker(item.path, fc)
                                end,
                            }}
                        end
                        if fv ~= false then
                            btns[#btns + 1] = {{
                                text     = _("Create collection"),
                                callback = function()
                                    UIManager:close(dialog)
                                    _createCollectionFromVirtualFolder(item.path, fc)
                                end,
                            }}
                        end
                        btns[#btns + 1] = {{
                            text     = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        }}
                        return btns
                    end)(),
                }
                UIManager:show(dialog)
                return true
            end
            return orig(fc, item)
        end
    end
end

local function _removePatches()
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok_fc or not FileChooser then return end

    if _patched_genitp and _orig_genItemTableFromPath then
        FileChooser.genItemTableFromPath = _orig_genItemTableFromPath
        _orig_genItemTableFromPath = nil ; _patched_genitp = false
    end
    if _patched_genit and _orig_genItemTable then
        FileChooser.genItemTable = _orig_genItemTable
        _orig_genItemTable = nil ; _patched_genit = false
    end
    if _patched_refresh and _orig_refreshPath then
        FileChooser.refreshPath = _orig_refreshPath
        _orig_refreshPath = nil ; _patched_refresh = false
    end
    if _patched_menusel and _orig_onMenuSelect then
        FileChooser.onMenuSelect = _orig_onMenuSelect
        _orig_onMenuSelect = nil ; _patched_menusel = false
    end
    if _patched_menuhold and _orig_onMenuHold then
        FileChooser.onMenuHold = _orig_onMenuHold
        _orig_onMenuHold = nil ; _patched_menuhold = false
    end
    if _patched_mandatory and _orig_getMenuItemMandatory then
        FileChooser.getMenuItemMandatory = _orig_getMenuItemMandatory
        _orig_getMenuItemMandatory = nil ; _patched_mandatory = false
    end
    if _patched_realpath and _orig_realpath then
        ffiUtil.realpath = _orig_realpath
        _orig_realpath = nil ; _patched_realpath = false
    end
    if _patched_showdialog and _orig_showFileDialog then
        FileChooser.showFileDialog = _orig_showFileDialog
        _orig_showFileDialog = nil ; _patched_showdialog = false
    end
end

-- ---------------------------------------------------------------------------
-- FileManager safety patches
-- ---------------------------------------------------------------------------

local _orig_createFolder = nil
local _orig_setHome      = nil
local _patched_fm_safety = false

local function _installFMSafetyPatches()
    if _patched_fm_safety then return end
    local FM = _getFileManager()
    if not FM then return end
    _patched_fm_safety = true

    _orig_createFolder = FM.createFolder
    FM.createFolder = function(fm)
        if fm.file_chooser and _isVirtual(fm.file_chooser.path) then return end
        _orig_createFolder(fm)
    end

    _orig_setHome = FM.setHome
    FM.setHome = function(fm, path)
        if fm.file_chooser and _isVirtual(fm.file_chooser.path) then return end
        _orig_setHome(fm, path)
    end
end

local function _removeFMSafetyPatches()
    if not _patched_fm_safety then return end
    local FM = _getFileManager()
    if FM then
        if _orig_createFolder then FM.createFolder = _orig_createFolder end
        if _orig_setHome      then FM.setHome      = _orig_setHome      end
    end
    _orig_createFolder = nil
    _orig_setHome      = nil
    _patched_fm_safety = false
end

-- ---------------------------------------------------------------------------
-- FileManager.updateTitleBarPath patch
-- ---------------------------------------------------------------------------

local _orig_updateTitleBarPath = nil
local _patched_tb_path = false

local function _getVirtualSubtitle(path)
    if not _isVirtual(path) then return nil end
    local _, dim_key, filter_value = _parseVirtualPath(path)
    if filter_value ~= nil then
        return (filter_value == false) and NULL_MARKER or filter_value
    end
    if dim_key then return DIMS[dim_key].label end
    return nil
end

local function _installTitleBarPathPatch()
    if _patched_tb_path then return end
    local FM = _getFileManager()
    if not FM then return end
    _patched_tb_path = true

    _orig_updateTitleBarPath = FM.updateTitleBarPath
    local orig = _orig_updateTitleBarPath
    FM.updateTitleBarPath = function(fm, path)
        local sub = _getVirtualSubtitle(path)
        if sub then
            orig(fm, _baseDir(path))
            local SP = _getSuiPatches()
            if SP and SP.setFMPathBase then
                SP.setFMPathBase(sub, fm)
            elseif fm.title_bar and fm.title_bar.setSubTitle then
                fm.title_bar:setSubTitle(sub)
            end
            return
        end
        return orig(fm, path)
    end
    FM.onPathChanged = FM.updateTitleBarPath
end

local function _removeTitleBarPathPatch()
    if not _patched_tb_path then return end
    local FM = _getFileManager()
    if FM and _orig_updateTitleBarPath then
        FM.updateTitleBarPath = _orig_updateTitleBarPath
        FM.onPathChanged      = _orig_updateTitleBarPath
    end
    _orig_updateTitleBarPath = nil
    _patched_tb_path = false
end

-- ---------------------------------------------------------------------------
-- Public install / uninstall / reset
-- ---------------------------------------------------------------------------

function M.openVirtualCoverPicker(vpath, fc)
    _openVirtualCoverPicker(vpath, fc)
end

function M.install()
    local ok, err = pcall(function()
        _installPatches()
        _installFMSafetyPatches()
        _installTitleBarPathPatch()
    end)
    if not ok then
        logger.warn("sui_browsemeta: install error:", tostring(err))
    end
end

function M.uninstall()
    pcall(_removePatches)
    pcall(_removeFMSafetyPatches)
    pcall(_removeTitleBarPathPatch)
    _clearCaches()
    _cache_base_dir = nil
    _bim_cache  = nil
    _FM_cache   = nil
    _SP_cache   = nil
    _SP_tried   = false
    _is_windows = nil
end

function M.reset()
    _clearCaches()
    _cache_base_dir = nil
end

return M
