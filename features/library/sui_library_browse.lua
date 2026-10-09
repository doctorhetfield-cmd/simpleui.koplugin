-- sui_library_browse.lua — Simple UI
-- Virtual author/series/tags browser. Replaces sui_browsemeta.lua.
--
-- Adds browse modes to the FM file chooser:
--   • Browse by Author
--   • Browse by Series
--   • Browse by Tags
--
-- All metadata access goes through sui_metadata_source (bookinfo + Calibre
-- rows, cached per filter trail) and all path encode/decode goes
-- through sui_virtual_path (plain-text segments — see that file's header
-- for the encoding). Cover-picker, create-collection, and cover-override
-- storage go through sui_group_actions / sui_cover_overrides, shared with
-- sui_series_grouping.lua rather than duplicated.
--
-- Because sui_virtual_path now encodes a full filter TRAIL rather than a
-- single (dimension, value) pair, the data layer already supports stacked
-- filters (e.g. author → then narrow by tag within that author). Nothing
-- in this file's UI currently exposes a "narrow further" action from a
-- file_list, so today's behaviour is unchanged — but the path grammar,
-- the row filtering, and the facet-count computation are all trail-aware, so
-- adding that affordance later is a UI-only change, not a data-layer one.
--
-- Settings key: "simpleui_browsemeta_mode"
--   "normal"  (default) — standard filesystem browsing
--   "author" / "series" / "tags" — browse mode
--
-- Public API
-- ----------
--   M.install()               — apply FileChooser + ffiUtil patches
--   M.uninstall()             — remove all patches
--   M.getCurrentMode(fc)      — "normal"|"author"|"series"|"tags" from fc.path
--   M.getPathMode(path)       — same, from an explicit path
--   M.navigateTo(fm, mode)    — navigate FM to the requested mode
--   M.navigateToRoot(fc, fm, mode)
--   M.activateMode(fm, mode, already_active) — single entry point for mode switchers
--   M.MODES / M.getModeLabel(mode)           — ordered mode ids and their display labels
--   M.getPathLabel(path)                     — display name of the innermost virtual level
--   M.isAtVirtualRoot(fc, mode)
--   M.getSavedMode() / M.setSavedMode(mode)
--   M.openVirtualCoverPicker(vpath, fc)
--   M.getAuthorBookCount(fc, author)    — count books by author in current base_dir (cached)
--   M.navigateToAuthorLeaf(fm, author)  — navigate FM directly to author virtual leaf

local lfs     = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local logger  = require("logger")
local _ = require("infra/sui_i18n").translate
local SUISettings = require("infra/sui_store")

local FilterState     = require("features/library/sui_filter_state")
local VirtualPath      = require("features/library/sui_virtual_path")
local MetadataSource   = require("features/library/sui_metadata_source")
local CoverOverrides   = require("features/library/sui_cover_overrides")
local GroupActions     = require("features/library/sui_group_actions")
local CoverFinder      = require("features/library/sui_cover_finder")

local M = {}

-- Display labels — a presentation concern, deliberately not part of
-- FilterState.DIMENSIONS (which only knows about row fields).
local DIM_LABELS = {
    author = _("Authors"),
    series = _("Series"),
    tags   = _("Tags"),
}

-- Ordered browse modes: the filesystem view followed by every metadata dimension.
M.MODES = { "normal", "author", "series", "tags" }

function M.getModeLabel(mode)
    if mode == "normal" then return _("Library") end
    return DIM_LABELS[mode]
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

local _last_base_dir = nil -- bounds cache memory: see _ensureCacheBaseDir()

-- Lazy module references — cached on first use, cleared on uninstall.
local _FM_cache  = nil
local _SP_cache  = nil
local _SP_tried  = false
local _is_windows = nil

-- ---------------------------------------------------------------------------
-- Cache memory bound
-- ---------------------------------------------------------------------------

-- sui_metadata_source caches per exact (base_dir, trail) key with no upper
-- bound of its own. A user re-entering "Browse by Author" from many
-- different real folders over a long session would otherwise accumulate
-- one cache entry per distinct entry-folder forever. Mirror the original
-- single-slot policy: whenever the real base_dir changes, drop everything
-- and start fresh — e-reader memory is scarce and one base_dir's worth of
-- cached metadata is normally all that is ever needed at once.
local function _ensureCacheBaseDir(base_dir)
    if _last_base_dir ~= base_dir then
        MetadataSource.clearCache()
        _last_base_dir = base_dir
    end
end

-- ---------------------------------------------------------------------------
-- Lazy module loaders
-- ---------------------------------------------------------------------------

local function _getFileManager()
    if _FM_cache then return _FM_cache end
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    if ok and FM then _FM_cache = FM end
    return _FM_cache
end

local function _getSuiPatches()
    if _SP_tried then return _SP_cache end
    _SP_tried = true
    local ok, SP = pcall(require, "infra/sui_patches")
    if ok and SP then _SP_cache = SP end
    return _SP_cache
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
    local _b, _s, _d, level = VirtualPath.parse(path)
    return level
end

function M.getPathMode(path)
    if not VirtualPath.isVirtual(path) then return "normal" end
    local _base, _state, active_dimension = VirtualPath.parse(path)
    return active_dimension or "normal"
end

function M.getCurrentMode(fc)
    return M.getPathMode(fc and fc.path)
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
    local base = VirtualPath.getBaseDir(fc.path)
    -- Persist "normal" BEFORE changeToPath so that if changeToPath errors out
    -- (caught upstream by a pcall), the next session never tries to restore a
    -- virtual path with the patches absent.
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

    local base = VirtualPath.getBaseDir(fc.path)

    if mode == "normal" then
        M.exitToNormal(fc, fm)
        return
    end

    local target = VirtualPath.buildDimList(base, nil, mode)
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
-- Re-navigates to the top-level dim_list (Authors/Series/Tags) without
-- exiting to the normal filesystem. Called when the user taps an already-
-- active browse tab in the bottom bar — the expected UX is to jump back to
-- the root of that virtual folder (page 1, no up button), analogous to
-- tapping the Library tab going back to home_dir page 1.
function M.navigateToRoot(fc, fm, mode)
    if not fc or not mode then return end
    local base   = VirtualPath.getBaseDir(fc.path)
    local target = VirtualPath.buildDimList(base, nil, mode)
    -- Re-set the entry path so the up button stays hidden at this level.
    fc._browse_by_meta_entry_path = target
    if fc.path == target then
        if fm then fm._navbar_suppress_path_change = true end
        pcall(function() fc:onGotoPage(1) end)
        pcall(function() fc:refreshPath() end)
        if fm then fm._navbar_suppress_path_change = nil end
    else
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

-- activateMode(fm, mode, already_active)
-- Single entry point for every control that switches browse mode (quick
-- actions, title-bar tabs). Selecting the active mode returns to its root:
-- page 1 for the filesystem view, the top-level list for a metadata mode.
-- `already_active` defaults to "the file chooser is currently in this mode".
function M.activateMode(fm, mode, already_active)
    local fc = fm and fm.file_chooser
    if not (fc and mode) then return end
    if already_active == nil then
        already_active = M.getCurrentMode(fc) == mode
    end
    if mode == "normal" then
        if already_active then
            pcall(fc.onGotoPage, fc, 1)
        else
            M.exitToNormal(fc, fm)
        end
    elseif already_active then
        M.navigateToRoot(fc, fm, mode)
    else
        M.navigateTo(fm, mode)
    end
end

-- isAtVirtualRoot(fc, mode)
-- Returns true when the file chooser is currently showing the dim_list root
-- for the given mode. Used by the bottom bar to decide whether a re-tap
-- should go to page 1 in place, or navigate up.
function M.isAtVirtualRoot(fc, mode)
    if not fc or not mode then return false end
    local base   = VirtualPath.getBaseDir(fc.path)
    local target = VirtualPath.buildDimList(base, nil, mode)
    return fc.path == target
end

-- ---------------------------------------------------------------------------
-- Author-dialog helpers
-- ---------------------------------------------------------------------------

-- A virtual folder lists a book only when its file still exists and the
-- chooser would show it. Returns the predicate and a `variant` naming the
-- chooser state it depends on, so MetadataSource can cache the outcome.
local function _listingFilter(fc)
    local variant = table.concat({
        tostring(fc.name),
        CoverFinder.statusFilterSignature(fc),
        tostring(fc.show_unsupported or false),
    }, "\0")
    local function accept(row)
        return lfs.attributes(row[1], "mode") == "file" and fc:show_file(row[2], row[1])
    end
    return variant, accept
end

-- Returns the number of books by *author_name* under the current FM base_dir.
function M.getAuthorBookCount(fc, author_name)
    if not fc or not author_name or author_name == "" then return 0 end
    local base = VirtualPath.getBaseDir(fc.path)
    if not base then return 0 end
    _ensureCacheBaseDir(base)

    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not ok_bim or not bim then return 0 end

    local fs = FilterState.new(base)
    FilterState.addFilter(fs, "author", author_name)
    local variant, accept = _listingFilter(fc)
    return #MetadataSource.getValidRows(bim, base, fs, variant, accept)
end

-- Navigates the FM directly to the virtual leaf for *author_name*, bypassing
-- the top-level Authors list. The up-button / back-button will land on the
-- Authors root (not the real filesystem), matching the expected UX.
--
-- origin_file (optional): the book file that triggered this navigation.
--   When provided, pressing back from the virtual leaf returns directly to
--   the real folder where the book lives, with the list scrolled to that
--   book. Without it, back lands on the Authors root.
--
-- Preconditions: browse mode must be installed (M.install() called).
function M.navigateToAuthorLeaf(fm, author_name, origin_file)
    if not fm or not author_name or author_name == "" then return end
    local fc = fm.file_chooser
    if not fc then return end

    local base   = VirtualPath.getBaseDir(fc.path)
    local target = VirtualPath.buildLeaf(base, nil, "author", author_name)

    -- Save the origin so onFolderUp can return to exactly the right place.
    -- Stored on fc (not a module upvalue) so it survives across module reloads.
    if origin_file then
        local real_path = fc.path
        if VirtualPath.isVirtual(real_path) then real_path = base end
        fc._sui_author_dialog_origin = { path = real_path, file = origin_file }
    else
        fc._sui_author_dialog_origin = nil
    end

    -- Set the entry path to the Authors root so the up-button hierarchy is
    -- correct when the user did NOT come from the dialog (normal flow).
    fc._browse_by_meta_entry_path = VirtualPath.buildDimList(base, nil, "author")
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
-- Cover picker / create collection — thin wrappers over the shared modules
-- ---------------------------------------------------------------------------

-- Resolves the book list for a virtual leaf, honouring the SAME filters
-- that render the file_list (existence on disk + fc:show_file), so the
-- picker/collection never offer a book the list itself would hide.
local function _resolveLeafBooks(fc, base_dir, filter_state)
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not ok_bim or not bim then return {} end
    local variant, accept = _listingFilter(fc)
    local out = {}
    for _, row in ipairs(MetadataSource.getValidRows(bim, base_dir, filter_state, variant, accept)) do
        out[#out + 1] = { path = row[1], title = row.title }
    end
    return out
end

function M.openVirtualCoverPicker(vpath, fc)
    local base_dir, filter_state, _dim, level = VirtualPath.parse(vpath)
    if level ~= "file_list" then return end

    local ok_bim, bim = pcall(require, "bookinfomanager")
    local books = _resolveLeafBooks(fc, base_dir, filter_state)

    -- Attach nicer titles from BookInfoManager when available, same as the
    -- original picker did (a per-book cache hit, not a fresh scan).
    if ok_bim and bim then
        for _, item in ipairs(books) do
            local bi = bim:getBookInfo(item.path, false)
            if bi and bi.title and bi.title ~= "" then item.title = bi.title end
        end
    end

    GroupActions.openCoverPicker{
        title        = _("Folder cover"),
        override_key = vpath,
        items        = books,
        menu         = fc,
        empty_message = _("No books found."),
    }
end

local function _createCollectionFromVirtualFolder(vpath, fc)
    local base_dir, filter_state, _dim, level = VirtualPath.parse(vpath)
    if level ~= "file_list" then return end

    local trail = filter_state.trail
    local last  = trail[#trail]
    -- "No value" virtual folders (e.g. the "no author" bucket) have no
    -- meaningful name and would produce a collection without a clear
    -- identity — same guard the original had.
    if not last or last.value == false then return end

    local books = _resolveLeafBooks(fc, base_dir, filter_state)
    local paths = {}
    for _, item in ipairs(books) do paths[#paths + 1] = item.path end

    GroupActions.createCollection{
        suggested_name = last.value,
        paths          = paths,
        empty_message  = _("No books found."),
    }
end

-- ---------------------------------------------------------------------------
-- Virtual list builder
-- ---------------------------------------------------------------------------

local _FAKE_DIR_ATTR = {
    mode = "directory", modification = 0, access = 0, change = 0, size = 0,
}
local function _fakeAttr(size)
    _FAKE_DIR_ATTR.size = size or 0
    return _FAKE_DIR_ATTR
end

local function _getVirtualList(fc, path, collate)
    local base_dir, filter_state, active_dimension, level = VirtualPath.parse(path)
    if not level then return {}, {} end

    local dirs, files = {}, {}

    if level == "root" then
        for i, dimension in ipairs(FilterState.ORDERED_DIMENSIONS) do
            local text  = _("Browse by") .. " " .. DIM_LABELS[dimension]
            local vpath = VirtualPath.buildDimList(base_dir, nil, dimension)
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

    -- active_dimension is only ever set at the "dim_list" level (see
    -- VirtualPath.parse's docstring) — at "file_list" it is nil BY DESIGN,
    -- because the trail is already fully resolved. Requiring it here for
    -- every level used to make every author/series/tags leaf folder come
    -- back empty, since this guard ran before the file_list branch below
    -- ever got a chance to query anything.
    if not base_dir then return dirs, files end
    if level == "dim_list" and not active_dimension then return dirs, files end
    _ensureCacheBaseDir(base_dir)

    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not ok_bim or not bim then return dirs, files end

    if level == "dim_list" then
        local values = MetadataSource.getFacetValues(bim, base_dir, active_dimension, filter_state)
        local overrides = SUISettings:readSetting("simpleui_fc_covers") or {}

        -- Real (validated) per-group counts and a representative file. A row
        -- only counts when its file exists on disk and passes fc:show_file:
        -- the facet counts may include stale bookinfo entries or files the
        -- chooser hides. Groups are matched by entry.key.
        --
        -- Only built when collate is truthy: a falsy collate means the caller
        -- only wants a cheap item COUNT (mirrors FileChooser:getList's own
        -- "collate == nil count only" path in KOReader core).
        local real_counts, real_reprs = {}, {}
        if collate then
            local variant, accept = _listingFilter(fc)
            real_counts, real_reprs = MetadataSource.getValidFacetCounts(
                bim, base_dir, active_dimension, filter_state, variant, accept)
        end

        for i, entry in ipairs(values) do
            local val   = entry[1]
            local label = VirtualPath.displayValue(val)
            local vpath = VirtualPath.buildLeaf(base_dir, filter_state, active_dimension, val)

            if collate then
                local real_count = real_counts[entry.key] or 0
                local real_repr  = real_reprs[entry.key]

                -- Skip virtual folders whose every book has been deleted from
                -- disk — showing an empty virtual folder would confuse the
                -- user, even though the bookinfo DB may still hold stale rows.
                if real_count > 0 then
                    local item = fc:getListItem(nil, label, vpath, _fakeAttr(i), collate)
                    item.nb_sub_files = real_count
                    item.mandatory    = tostring(real_count) .. " \u{F016}"

                    local repr
                    local override_fp = overrides[vpath]
                    if override_fp and lfs.attributes(override_fp, "mode") == "file" then
                        repr = override_fp
                    elseif real_repr then
                        repr = real_repr
                    elseif entry._first then
                        repr = entry._first[1]
                    end

                    -- Always mark as a virtual meta leaf so the folder
                    -- decoration (stacked-cover lines + badge) is rendered
                    -- even when no representative cover is available (e.g.
                    -- the "no author"/"no series" bucket whose books have no
                    -- cached covers yet).
                    item.is_virtual_meta_leaf = true
                    item.virtual_leaf_count   = real_count
                    if repr then item.representative_filepath = repr end
                    dirs[#dirs + 1] = item
                end
            else
                dirs[#dirs + 1] = true
            end
        end
        return dirs, files
    end

    if level == "file_list" then
        local rows = MetadataSource.getMatchingFiles(bim, base_dir, filter_state)
        -- active_dimension is nil here (see the comment above) — the
        -- dimension actually being browsed is the last one resolved into
        -- the trail, e.g. browsing Author > "Terry Pratchett" leaves
        -- trail = { {dimension="author", value="Terry Pratchett"} }.
        local trail = filter_state and filter_state.trail or {}
        local leaf_dimension = trail[#trail] and trail[#trail].dimension
        MetadataSource.sortFiles(rows, leaf_dimension)
        local is_author_dim = (leaf_dimension == "author") -- tags + series share the "else" path

        for _, row in ipairs(rows) do
            local fullpath, fname = row[1], row[2]
            -- lfs.attributes() is needed here: FC requires the attr table to
            -- build each list item, and it doubles as a stale-entry filter.
            local attr = lfs.attributes(fullpath)
            if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
                local item = fc:getListItem(path, fname, fullpath, attr, collate)
                -- Forward metadata from the resolved row so CoverBrowser and
                -- list-view renderers can display title/author/series
                -- without re-reading the sidecar.
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
            if VirtualPath.isVirtual(path) then
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
            if not VirtualPath.isVirtual(path) then
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
            -- Listing the path already shown picks up library changes, so the
            -- cached metadata is dropped; moving to another path keeps it.
            if fc._sui_listed_path == fc.path then MetadataSource.clearCache() end
            fc._sui_listed_path = fc.path
            return orig(fc)
        end
    end

    if not _patched_menusel then
        _patched_menusel = true
        _orig_onMenuSelect = FileChooser.onMenuSelect
        local orig = _orig_onMenuSelect
        FileChooser.onMenuSelect = function(fc, item)
            if item and item.path and VirtualPath.isVirtual(item.path) then
                if item.is_go_up and M.getPathLevel(fc.path) == "dim_list" then
                    local FM = _getFileManager()
                    M.exitToNormal(fc, FM and FM.instance)
                    return true
                end
                fc:changeToPath(item.path, item.is_go_up and fc.path)
                -- Re-evaluate the back-button after entering a virtual
                -- sub-folder, so lock_home_folder does not suppress it
                -- incorrectly.
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
            if path and VirtualPath.isVirtual(path) then
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
            if item and item.path and VirtualPath.isVirtual(item.path) then
                fc.book_props = nil
                -- In mosaic/grid mode (display_mode_type == "mosaic") the
                -- cover picker makes no sense, so leaf long-press only offers
                -- "Create collection". In list mode the full context menu
                -- (onMenuHold below) fires first and showFileDialog is never
                -- reached for leaf items; this branch handles the mosaic path.
                if item.is_virtual_meta_leaf then
                    local _b, filter_state = VirtualPath.parse(item.path)
                    local trail = filter_state.trail
                    local last  = trail[#trail]
                    -- "no value" leaf: long-press disabled (no meaningful name).
                    if not last or last.value == false then return true end
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
            -- modes. In mosaic/grid mode this handler is not reached for
            -- folder items — CoverBrowser routes those through showFileDialog
            -- instead (handled above).
            if item and item.path and item.is_virtual_meta_leaf then
                local UIManager    = require("ui/uimanager")
                local ButtonDialog = require("ui/widget/buttondialog")
                local dialog
                local folder_name = (item.text or item.path:match("([^/]+)$") or ""):gsub("/$", "")
                local _b, filter_state = VirtualPath.parse(item.path)
                local trail = filter_state.trail
                local last  = trail[#trail]
                -- "no value" leaf: long-press disabled (no meaningful name).
                if not last or last.value == false then return true end

                dialog = ButtonDialog:new{
                    title       = folder_name,
                    title_align = "center",
                    buttons = (function()
                        local btns = {}
                        -- Hide the cover picker in quad mosaic mode (the quad
                        -- grid always auto-selects covers; single-cover
                        -- override is not applicable in that mode).
                        local in_list_view = fc and fc.display_mode_type == "list"
                        local ok_fc_mod, FC = pcall(require, "features/library/sui_foldercovers")
                        local effective_style = (ok_fc_mod and FC and FC.resolveStyle)
                            and FC.resolveStyle(fc, item.path, item) or "single"
                        if effective_style ~= "quad" or in_list_view then
                            btns[#btns + 1] = {{
                                text     = _("Set folder cover"),
                                callback = function()
                                    UIManager:close(dialog)
                                    M.openVirtualCoverPicker(item.path, fc)
                                end,
                            }}
                        end
                        btns[#btns + 1] = {{
                            text     = _("Create collection"),
                            callback = function()
                                UIManager:close(dialog)
                                _createCollectionFromVirtualFolder(item.path, fc)
                            end,
                        }}
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
        if fm.file_chooser and VirtualPath.isVirtual(fm.file_chooser.path) then return end
        _orig_createFolder(fm)
    end

    _orig_setHome = FM.setHome
    FM.setHome = function(fm, path)
        if fm.file_chooser and VirtualPath.isVirtual(fm.file_chooser.path) then return end
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
    if not VirtualPath.isVirtual(path) then return nil end
    local _b, filter_state, active_dimension = VirtualPath.parse(path)
    local trail = filter_state.trail
    local last  = trail[#trail]
    if last then
        return VirtualPath.displayValue(last.value)
    end
    if active_dimension then return DIM_LABELS[active_dimension] end
    return nil
end

-- Display name of the innermost level of a virtual path; nil for real paths.
function M.getPathLabel(path)
    return _getVirtualSubtitle(path)
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
            orig(fm, VirtualPath.getBaseDir(path))
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

function M.install()
    local ok, err = pcall(function()
        _installPatches()
        _installFMSafetyPatches()
        _installTitleBarPathPatch()
    end)
    if not ok then
        logger.warn("sui_library_browse: install error:", tostring(err))
    end
end

function M.uninstall()
    pcall(_removePatches)
    pcall(_removeFMSafetyPatches)
    pcall(_removeTitleBarPathPatch)
    MetadataSource.clearCache()
    _last_base_dir = nil
    _FM_cache   = nil
    _SP_cache   = nil
    _SP_tried   = false
    _is_windows = nil
end

function M.reset()
    MetadataSource.clearCache()
    _last_base_dir = nil
end

return M
