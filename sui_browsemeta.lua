-- sui_browsemeta.lua — Simple UI
-- Virtual author/series browser.
--
-- Adds two browse modes to the FM file chooser:
--   • Browse by Author  — groups all books under a base folder by author
--   • Browse by Series  — groups all books under a base folder by series
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

local lfs     = require("libs/libkoreader-lfs")
local util    = require("util")
local ffiUtil = require("ffi/util")
local logger  = require("logger")
local _ = require("sui_i18n").translate

-- ---------------------------------------------------------------------------
-- Virtual path constants
-- ---------------------------------------------------------------------------

local VROOT     = "\u{E257}"
local VROOT_SEP = "/" .. VROOT   -- pre-built; avoids alloc on every _findVroot

local SYM_AUTHOR = "\u{F2C0}"
local SYM_SERIES = "\u{ECD7}"
local NULL_MARKER = "\u{2205}"

local DIMS = {
    author = { symbol = SYM_AUTHOR, db_column = "authors", label = _("Authors") },
    series = { symbol = SYM_SERIES, db_column = "series",  label = _("Series")  },
}

local SYM_TO_DIM = {}
for k, v in pairs(DIMS) do SYM_TO_DIM[v.symbol] = k end

local DIMS_ORDER = { "author", "series" }

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local M = {}

local _FC_COVERS_KEY = "simpleui_fc_covers"

local _meta_values_cache    = {}
local _matching_files_cache = {}
local _repr_file_cache      = {}
local _cache_base_dir       = nil

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
            filter_value = parts[2]
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
    local v_enc = (value == false or value == nil) and NULL_MARKER or value
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
-- Database access
-- ---------------------------------------------------------------------------

-- Constant SQL base — never allocated at runtime.
local _SQL_BASE = "SELECT directory, filename, title, authors, series, series_index"
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
        elseif col == "authors" then
            sql = sql .. " AND '\n'||authors||'\n' GLOB ?"
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
            }
        end
    end)
    -- Always finalize — prevents SQLite statement leaks on error paths.
    if stmt then pcall(function() stmt:finalize() end) end
    if not ok then
        logger.warn("sui_browsemeta: SQL error:", tostring(err))
        return {}
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
        if dim_key == "author" then
            local authors = row.authors
            if authors and authors:find("\n", 1, true) then
                for author in util.gsplit(authors, "\n") do
                    if author ~= "" then
                        if not grouped[author] then
                            grouped[author] = 0
                            first[author]   = row
                        end
                        grouped[author] = grouped[author] + 1
                    end
                end
            else
                local key = authors or false
                if not grouped[key] then
                    grouped[key] = 0
                    first[key]   = row
                end
                grouped[key] = grouped[key] + 1
            end
        else
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

    local overrides   = G_reader_settings:readSetting(_FC_COVERS_KEY) or {}
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
        local overrides = G_reader_settings:readSetting(_FC_COVERS_KEY) or {}
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
        for _, row in ipairs(cached) do
            local fullpath = row[1]
            local fname    = row[2]
            -- lfs.attributes() is needed here: FC requires the attr table to
            -- build each list item, and it doubles as a stale-entry filter.
            local attr = lfs.attributes(fullpath)
            if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
                files[#files + 1] = fc:getListItem(path, fname, fullpath, attr, collate)
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
    return G_reader_settings:nilOrTrue(_BM_KEY)
end

function M.setEnabled(v)
    G_reader_settings:saveSetting(_BM_KEY, v)
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
    return G_reader_settings:readSetting(_MODE_KEY) or "normal"
end

function M.setSavedMode(mode)
    G_reader_settings:saveSetting(_MODE_KEY, mode)
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
    -- genItemTable has already set _simpleui_has_go_up, but the titlebar
    -- onGotoPage handler must run once more to pick it up when
    -- lock_home_folder is active (same pattern as series grouping).
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
    return G_reader_settings:readSetting(_FC_COVERS_KEY) or {}
end

local function _saveCoverOverride(vpath, book_path)
    local t = _getCoverOverrides()
    t[vpath] = book_path
    G_reader_settings:saveSetting(_FC_COVERS_KEY, t)
end

local function _clearCoverOverride(vpath)
    local t = _getCoverOverrides()
    t[vpath] = nil
    G_reader_settings:saveSetting(_FC_COVERS_KEY, t)
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

    picker = ButtonDialog:new{ title = _("Virtual folder cover"), buttons = buttons }
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
            -- Notify the SimpleUI titlebar system whether a go-up exists,
            -- so the back button is shown even when lock_home_folder is active
            -- (mirrors the same pattern used by the series-grouping feature).
            fc._simpleui_has_go_up = not hide_up and path ~= "/"

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
            -- Intercept long-press on any virtual meta leaf (dim_list author/
            -- series entries) and open the cover picker directly.  file_list
            -- items (individual books inside a leaf) are also intercepted so
            -- the cover picker is reachable there too.
            if item and item.path and item.is_virtual_meta_leaf then
                _openVirtualCoverPicker(item.path, fc)
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
