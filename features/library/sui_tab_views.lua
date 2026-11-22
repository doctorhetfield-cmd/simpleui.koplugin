-- sui_tab_views.lua — Simple UI
-- View and sort of each metadata tab (Authors / Series / Tags) of the library.
--
-- Every tab keeps its own view and sort for its root list. The books inside a
-- group follow the Library tab, i.e. KOReader's own settings.
--
--   TabViews.getView(mode) / setView(mode, view)      a CoverBrowser display mode id of VIEWS
--   TabViews.getSort(mode) / setSort(mode, id)        a collate id of SORTS
--   TabViews.isReverse(mode) / setReverse(mode, on)
--   TabViews.getPerPage(mode) / setPerPage(mode, n)   portrait items per page of a tab listed as a list
--   TabViews.defaultPerPage(mode)                     items per page a tab starts with
--   TabViews.isListView(view)                         whether a view is a list
--   TabViews.pagePerPage(path)                        items per page a tab root forces, else nil
--   TabViews.cbMode(view)                             CoverBrowser display mode of a view (the view itself)
--   TabViews.rootMode(path)                           tab whose root list `path` is, else nil
--   TabViews.isCoverRoot(path)                        whether `path` is a tab root listed with covers
--   TabViews.dirSorter(fc, mode)                      sort function of a tab's root list
--   TabViews.libraryMode()                            display mode the Library tab uses
--   TabViews.effectiveMode(path)                      display mode `path` is shown in
--   TabViews.apply(fc, path)                          switch the file browser to that mode
--   TabViews.install() / uninstall()                  apply it before every refresh of the list

local Config      = require("infra/sui_config")
local SUISettings = require("infra/sui_store")

local M = {}

M.META_MODES = { "author", "series", "tags" }
M.VIEWS      = { "mosaic_image", "mosaic_text", "list_image_meta", "list_only_meta", "list_image_filename" }
M.SORTS      = { "strcoll", "natural", "sui_count" }

local DEFAULT_VIEW = { author = "list_only_meta", series = "list_image_meta", tags = "list_only_meta" }

-- Views saved when they were named after their look.
local LEGACY_VIEW = { mosaic = "mosaic_image", list = "list_only_meta", list_covers = "list_image_meta" }

local function _key(kind, mode) return "simpleui_lib_" .. kind .. "_" .. mode end

function M.getView(mode)
    local stored = SUISettings:readSetting(_key("view", mode))
    return Config.resolveChoice(LEGACY_VIEW[stored] or stored, M.VIEWS, DEFAULT_VIEW[mode] or "list_only_meta")
end

function M.setView(mode, view)
    SUISettings:saveSetting(_key("view", mode), view)
end

-- Without a saved choice a tab starts from the file browser's collate, when it
-- can order metadata folders.
function M.getSort(mode)
    local SortSheet = require("features/library/sui_sort_sheet")
    local global    = G_reader_settings:readSetting("collate")
    local default   = SortSheet.sortsFacetFolders(global) and global or "strcoll"
    return Config.readChoice(_key("sort", mode), M.SORTS, default)
end

function M.setSort(mode, id)
    SUISettings:saveSetting(_key("sort", mode), id)
end

function M.isReverse(mode)
    local stored = SUISettings:readSetting(_key("reverse", mode))
    if stored == nil then return G_reader_settings:isTrue("reverse_collate") end
    return stored == true
end

function M.setReverse(mode, on)
    SUISettings:saveSetting(_key("reverse", mode), on and true or false)
end

-- Range of items per page of a tab listed as a list; a stored value above it is capped.
M.PER_PAGE_MIN, M.PER_PAGE_MAX = 4, 12
local PER_PAGE_DEFAULTS = { author = 6, series = 6, tags = 6 }

function M.isListView(view)
    return view:sub(1, 5) == "list_"
end

function M.defaultPerPage(mode)
    return PER_PAGE_DEFAULTS[mode]
end

function M.getPerPage(mode)
    local n = tonumber(SUISettings:readSetting(_key("per_page", mode)))
    if n and n >= M.PER_PAGE_MIN then return math.min(math.floor(n), M.PER_PAGE_MAX) end
    return PER_PAGE_DEFAULTS[mode]
end

-- The default value is not stored.
function M.setPerPage(mode, n)
    if n and n ~= PER_PAGE_DEFAULTS[mode] then
        SUISettings:saveSetting(_key("per_page", mode), n)
    else
        SUISettings:delSetting(_key("per_page", mode))
    end
end

function M.cbMode(view)
    return view
end

-- The tab (`author`/`series`/`tags`) whose top-level list `path` is. A list
-- narrowed by an earlier filter is not a tab root.
function M.rootMode(path)
    local _base, state, dimension, level = require("features/library/sui_virtual_path").parse(path)
    if level ~= "dim_list" or not (state and #state.trail == 0) then return nil end
    for _i, mode in ipairs(M.META_MODES) do
        if mode == dimension then return mode end
    end
    return nil
end

function M.isCoverRoot(path)
    local mode = M.rootMode(path)
    return mode ~= nil and M.getView(mode) == "list_image_meta"
end

function M.pagePerPage(path)
    local mode = M.rootMode(path)
    if mode and M.isListView(M.getView(mode)) then return M.getPerPage(mode) end
    return nil
end

function M.dirSorter(fc, mode)
    return fc:getSortingFunction(fc.collates[M.getSort(mode)] or fc.collates.strcoll, M.isReverse(mode))
end

-- ---------------------------------------------------------------------------
-- Display mode per path
-- ---------------------------------------------------------------------------

-- The file browser has one display mode at a time, set on the CoverBrowser. A
-- tab root switches it without saving it, so the saved mode stays the
-- Library's and every other path shows that one.
local _applied            -- mode the CoverBrowser is in
local _seen_library = false -- saved mode at the last apply; false before the first

local function _bookInfo()
    local ok, bim = pcall(require, "bookinfomanager")
    return ok and bim or nil
end

-- The CoverBrowser of the chooser's file manager, which exists before
-- FileManager.instance does when a new file manager lists its first folder.
local function _coverBrowser(fc)
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    local cb = fc and fc.ui and fc.ui.coverbrowser or fm and fm.coverbrowser
    return cb, fm
end

function M.libraryMode()
    local bim = _bookInfo()
    return bim and bim:getSetting("filemanager_display_mode") or nil
end

function M.effectiveMode(path)
    local mode = M.rootMode(path)
    if mode then return M.cbMode(M.getView(mode)) end
    return M.libraryMode()
end

-- Sets the CoverBrowser's mode without saving it and without its own refresh.
local function _switch(cb, mode)
    local bim = _bookInfo()
    if not (cb and bim) then return false end
    local orig_save    = bim.saveSetting
    local own_refresh  = rawget(cb, "refreshFileManagerInstance")
    bim.saveSetting = function(self, key, value)
        if key == "filemanager_display_mode" then return end
        return orig_save(self, key, value)
    end
    cb.refreshFileManagerInstance = function() end
    local ok = pcall(cb.setupFileManagerDisplayMode, cb, mode)
    bim.saveSetting = orig_save
    cb.refreshFileManagerInstance = own_refresh
    return ok
end

-- A mode saved since the last call was chosen in the native menu, which puts
-- the CoverBrowser in it.
local function _sync()
    local library = M.libraryMode()
    if library ~= _seen_library then
        _seen_library = library
        _applied = library
    end
    return library
end

-- The display mode chosen in the CoverBrowser's menu is the Library's. The
-- CoverBrowser ignores a choice equal to the mode it is in, which at a tab root
-- is the tab's; so it is put back in the Library's mode first. At a tab root
-- the list is then redrawn once, in the tab's view.
local _wrapped_cb

local function _wrapSetDisplayMode(cb)
    if rawget(cb, "setDisplayMode") then return end
    local orig = cb.setDisplayMode
    cb.setDisplayMode = function(self, mode)
        local fc = self.ui and self.ui.file_chooser
        local library = _sync()
        if _applied ~= library and _switch(self, library) then _applied = library end
        if not (fc and M.rootMode(fc.path)) then return orig(self, mode) end
        local own_refresh = rawget(self, "refreshFileManagerInstance")
        self.refreshFileManagerInstance = function() end
        local ok, err = pcall(orig, self, mode)
        self.refreshFileManagerInstance = own_refresh
        if not ok then error(err, 0) end
        fc:refreshPath()
    end
    _wrapped_cb = cb
end

-- A tab root with items per page of its own lends them to the chooser only
-- while its dimensions are computed, so every setting keeps reading the
-- Library's. The chooser's own instance layout, if any, still runs.
local function _recalcWithPerPage(self, ...)
    local own = rawget(self, "files_per_page")
    self.files_per_page = self._sui_tv_per_page
    local layout = self._sui_tv_own_recalc or require("ui/widget/filechooser")._recalculateDimen
    local ok, err = pcall(layout, self, ...)
    self.files_per_page = own
    if not ok then error(err, 0) end
end

-- Returns true when the items per page of `fc` changed. The instance layout
-- the chooser had is kept aside while lent and put back after.
local function _setPerPage(fc, n)
    if fc._sui_tv_per_page == n then return false end
    if n and not fc._sui_tv_per_page then
        fc._sui_tv_own_recalc = rawget(fc, "_recalculateDimen")
        fc._recalculateDimen = _recalcWithPerPage
    elseif not n then
        fc._recalculateDimen = fc._sui_tv_own_recalc
        fc._sui_tv_own_recalc = nil
    end
    fc._sui_tv_per_page = n
    return true
end

function M.apply(fc, path)
    _sync()
    local cb = _coverBrowser(fc)
    if cb then _wrapSetDisplayMode(cb) end
    local resized = fc and _setPerPage(fc, M.pagePerPage(path))
    local want = M.effectiveMode(path)
    local switched = want ~= _applied and _switch(cb, want)
    if switched then _applied = want end
    if (switched or resized) and fc and fc._recalculateDimen then fc:_recalculateDimen() end
end

function M.install()
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._sui_tv_orig_refreshPath then return end
    local orig = FileChooser.refreshPath
    FileChooser._sui_tv_orig_refreshPath = orig
    FileChooser.refreshPath = function(fc, ...)
        if fc.name == "filemanager" then M.apply(fc, fc.path) end
        return orig(fc, ...)
    end
end

function M.uninstall()
    local FileChooser = require("ui/widget/filechooser")
    local orig = FileChooser._sui_tv_orig_refreshPath
    if orig then
        FileChooser.refreshPath = orig
        FileChooser._sui_tv_orig_refreshPath = nil
    end
    local known = _wrapped_cb
    if known then
        known.setDisplayMode = nil
        _wrapped_cb = nil
    end
    local live, fm = _coverBrowser()
    local cb = known or live
    local library = _sync()
    local fc = fm and fm.file_chooser
    local resized = fc and _setPerPage(fc, nil)
    local switched = _applied ~= library and _switch(cb, library)
    if (switched or resized) and fc and fc._recalculateDimen then fc:_recalculateDimen() end
    _applied, _seen_library = nil, false
end

return M
