-- sui_sort_sheet.lua — Simple UI
-- View and sort options of a library tab, shown on a long press of the tab.
--
-- The Library tab reads and writes KOReader's own settings (collate,
-- reverse_collate, collate_mixed) through the file manager's handlers, so the
-- file browser and the books of every group share one sort order, and the
-- CoverBrowser's display mode. Under the rows the sheet toggles the flat view
-- (Library) and the grouping of series books. The Authors / Series / Tags
-- tabs keep a view and a sort of their own for their list (see
-- sui_tab_views), and, listed as a list, their own items per page.
--
-- It also registers the "number of books" collate in FileChooser.collates:
-- metadata folders (Authors/Series/Tags) are sorted by the number of books
-- they hold; everything else falls back to the name.
--
--   SortSheet.install() / SortSheet.uninstall()  — register / remove the collate
--   SortSheet.show(fm, mode)                     — show the sheet for a browse mode
--   SortSheet.sortsFacetFolders(id)              — whether a collate orders metadata folders
--   SortSheet.viewOptions(fm, mode)              — { { id, text }, … } views a tab offers
--   SortSheet.getView / setView(fm, mode, id)    — current view of a tab and its change
--   SortSheet.sortGroups(fc, mode)               — groups of { id, label } collates a tab offers
--   SortSheet.getSort / setSort(fm, mode, id)    — current collate of a tab and its change
--   SortSheet.isReverse / setReverse(fm, mode, on)
--   SortSheet.getPerPage / setPerPage(fm, mode, n) — list items per page of a metadata tab and its change

local ffiUtil     = require("ffi/util")
local T           = ffiUtil.template
local _           = require("infra/sui_i18n").translate
local ActionSheet = require("engines/sui_action_sheet")
local TabViews    = require("features/library/sui_tab_views")

local M = {}

local COUNT_ID = "sui_count"

-- Collates that sort the metadata folders of the Authors/Series/Tags tabs.
local FACET_COLLATES = { "strcoll", "natural", COUNT_ID }

local COUNT_COLLATE = {
    text              = _("number of books"),
    menu_order        = 150,
    can_collate_mixed = true,
    init_sort_func    = function()
        return function(a, b)
            local ca, cb = a.nb_sub_files, b.nb_sub_files
            if ca ~= cb then
                if not ca then return false end
                if not cb then return true end
                return ca > cb
            end
            return ffiUtil.strcoll(a.text, b.text)
        end
    end,
}

function M.install()
    local FileChooser = require("ui/widget/filechooser")
    FileChooser.collates[COUNT_ID] = COUNT_COLLATE
end

-- A saved "sui_count" left behind falls back to the name in getCollate().
function M.uninstall()
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser.collates[COUNT_ID] == COUNT_COLLATE then
        FileChooser.collates[COUNT_ID] = nil
    end
end

-- True when the collate `id` can sort metadata folders: their attributes are
-- placeholders, so date, access and size collates would leave them unordered.
function M.sortsFacetFolders(id)
    for _i, facet_id in ipairs(FACET_COLLATES) do
        if facet_id == id then return true end
    end
    return false
end

-- Most buttons on one segments row; longer groups wrap onto further rows.
local ROW_MAX = 3

-- Groups of the file-browser collates, each with the short button label of
-- its collates. The sheet title shows the full name of the current one.
local function _libraryGroups()
    return {
        { title = _("Name"), collates = {
            { "strcoll", _("Alphabetical") }, { "natural", _("Natural") } } },
        { title = _("Date"), collates = {
            { "access", _("Last read") }, { "date", _("Modified") } } },
        { title = _("Progress"), collates = {
            { "percent_unopened_first", _("Unopened first") },
            { "percent_unopened_last",  _("Unopened last") },
            { "percent_natural",        _("Finished last") } } },
        { title = _("File"), collates = {
            { "size", _("Size") }, { "type", _("Type") } } },
        { title = _("Metadata"), collates = {
            { "title", _("Title") }, { "authors", _("Authors") }, { "series", _("Series") },
            { "keywords", _("Keywords") }, { "rating", _("Rating") } } },
    }
end

-- The collates of a metadata tab, as one untitled group.
local function _facetGroups()
    return { { collates = {
        { "strcoll", _("Alphabetical") }, { "natural", _("Natural") }, { COUNT_ID, _("Book count") } } } }
end

-- Groups offered for `mode`, keeping only the collates that exist. Collates
-- of the file browser that no group names are listed under "Other" with their
-- own name; the book count only orders metadata folders, so it is left out.
function M.sortGroups(fc, mode)
    local groups, out, named = mode == "normal" and _libraryGroups() or _facetGroups(), {}, {}
    for _i, group in ipairs(groups) do
        local present = {}
        for _j, c in ipairs(group.collates) do
            named[c[1]] = true
            if fc.collates[c[1]] then present[#present + 1] = c end
        end
        if #present > 0 then
            out[#out + 1] = { title = group.title, collates = present }
        end
    end
    if mode == "normal" then
        local other = {}
        for _i, id in ipairs((require("apps/filemanager/filemanager").getSortByActions())) do
            if not named[id] and id ~= COUNT_ID then
                other[#other + 1] = { id, fc.collates[id].text }
            end
        end
        if #other > 0 then out[#out + 1] = { title = _("Other"), collates = other } end
    end
    return out
end

-- Re-draws the list when `mode` is the tab on screen.
local function _refresh(fm, mode)
    local fc = fm.file_chooser
    if fc and TabViews.rootMode(fc.path) == mode then fc:refreshPath() end
end

-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------

local CLASSIC = "classic"

function M.viewOptions(fm, mode)
    local options = {}
    local cb = fm.coverbrowser
    for _i, entry in ipairs(cb and cb.modes or {}) do
        -- The classic view has no id; the tabs leave it out.
        if entry[2] or mode == "normal" then
            options[#options + 1] = { id = entry[2] or CLASSIC, text = entry[1] }
        end
    end
    return options
end

function M.getView(_fm, mode)
    if mode == "normal" then return TabViews.libraryMode() or CLASSIC end
    return TabViews.getView(mode)
end

function M.setView(fm, mode, id)
    if mode == "normal" then
        local cb = fm.coverbrowser
        if not cb then return end
        cb:setDisplayMode(id ~= CLASSIC and id or nil)
    else
        TabViews.setView(mode, id)
        _refresh(fm, mode)
    end
end

local function _viewLabel(fm, mode)
    local current = M.getView(fm, mode)
    for _i, option in ipairs(M.viewOptions(fm, mode)) do
        if option.id == current then return option.text end
    end
    return ""
end

-- Portrait items per page of a metadata tab listed as a list.
function M.getPerPage(_fm, mode)
    return TabViews.getPerPage(mode)
end

function M.setPerPage(fm, mode, n)
    TabViews.setPerPage(mode, n)
    _refresh(fm, mode)
end

-- ---------------------------------------------------------------------------
-- Library size: the file browser's own settings, shared with its menu
-- ---------------------------------------------------------------------------

M.GRID_MIN, M.GRID_MAX = 2, 8
M.LIST_PAGE_MIN, M.LIST_PAGE_MAX, M.LIST_PAGE_DEFAULT = 4, 20, 10
local GRID_DEFAULTS = {
    nb_cols_portrait = 3, nb_rows_portrait = 3,
    nb_cols_landscape = 4, nb_rows_landscape = 2,
}

-- "mosaic", "list", or nil for the classic view, of the Library on screen.
function M.libraryLayout(fm)
    local view = M.getView(fm, "normal")
    if view:sub(1, 7) == "mosaic_" then return "mosaic" end
    if TabViews.isListView(view) then return "list" end
    return nil
end

-- Stores size settings (key → value), in the file browser and in the settings
-- it reads at start, and redraws the list once.
local function _setLibrarySize(fc, values)
    local changed = false
    for key, n in pairs(values) do
        if fc[key] ~= n then
            changed = true
            fc[key] = n
            require("bookinfomanager"):saveSetting(key, n)
            require("ui/widget/filechooser")[key] = n
        end
    end
    if changed then fc:updateItems() end
end

local function _portrait()
    local Screen = require("device").screen
    return Screen:getWidth() <= Screen:getHeight()
end

-- `what` is "cols" or "rows"; the mosaic of the orientation on screen.
local function _gridKey(what)
    return "nb_" .. what .. (_portrait() and "_portrait" or "_landscape")
end

function M.getGrid(fm, what)
    local fc = fm.file_chooser
    return fc[_gridKey(what)] or GRID_DEFAULTS[_gridKey(what)]
end

function M.setGrid(fm, cols, rows)
    _setLibrarySize(fm.file_chooser, { [_gridKey("cols")] = cols, [_gridKey("rows")] = rows })
end

function M.getLibraryPerPage(fm)
    return fm.file_chooser.files_per_page or M.LIST_PAGE_DEFAULT
end

function M.setLibraryPerPage(fm, n)
    _setLibrarySize(fm.file_chooser, { files_per_page = n })
end

-- ---------------------------------------------------------------------------
-- Sort
-- ---------------------------------------------------------------------------

function M.getSort(fm, mode)
    if mode == "normal" then return (select(2, fm.file_chooser:getCollate())) end
    return TabViews.getSort(mode)
end

function M.setSort(fm, mode, id)
    if mode == "normal" then
        fm:onSetSortBy(id)
    else
        TabViews.setSort(mode, id)
        _refresh(fm, mode)
    end
end

function M.isReverse(_fm, mode)
    if mode == "normal" then return G_reader_settings:isTrue("reverse_collate") end
    return TabViews.isReverse(mode)
end

function M.setReverse(fm, mode, on)
    if mode == "normal" then
        fm:onSetReverseSorting(on)
    else
        TabViews.setReverse(mode, on)
        _refresh(fm, mode)
    end
end

local function _sortLabel(fm, mode)
    local fc = fm.file_chooser
    local collate = fc.collates[M.getSort(fm, mode)] or fc.collates.strcoll
    return collate.text
end

-- ---------------------------------------------------------------------------
-- Sheet
-- ---------------------------------------------------------------------------

function M.show(fm, mode)
    local fc = fm and fm.file_chooser
    if not fc then return end

    local win, rootSections

    -- Rows of the sheet; their values follow every change made on a page.
    local view_row     = { text = _("View"), chevron = true, keep_open = true }
    local per_page_row = { text = _("Items per page"), keep_open = true }
    local grid_row     = { text = _("Items per page"), keep_open = true }
    local sort_row     = { text = _("Sort"), chevron = true, keep_open = true }
    local function refreshRows()
        view_row.value = _viewLabel(fm, mode)
        if mode ~= "normal" then
            per_page_row.value = tostring(M.getPerPage(fm, mode))
        elseif M.libraryLayout(fm) == "mosaic" then
            grid_row.value = T(_("%1 × %2"), M.getGrid(fm, "cols"), M.getGrid(fm, "rows"))
        elseif M.libraryLayout(fm) == "list" then
            per_page_row.value = tostring(M.getLibraryPerPage(fm))
        end
        sort_row.value = _sortLabel(fm, mode)
    end

    -- Options of how the list is built, shown under the rows: the flat view
    -- (Library only) and the grouping of series books.
    local function viewToggles()
        local BM = require("features/library/sui_library_browse")
        local toggles = {}
        if mode == "normal" and BM.isEnabled() then
            local flat = BM.isFlatEnabled()
            toggles[#toggles + 1] = {
                text     = _("Flat view"),
                toggle   = flat,
                callback = function()
                    BM.setFlat(fm, not flat)
                    win:update{ sections = rootSections() }
                end,
            }
        end
        for _i, grouped_mode in ipairs(BM.SERIES_GROUPING_MODES) do
            if grouped_mode == mode then
                local FolderCovers = require("features/library/sui_foldercovers")
                local grouped = FolderCovers.getSeriesGrouping(mode)
                toggles[#toggles + 1] = {
                    text     = _("Group by Series"),
                    toggle   = grouped,
                    callback = function()
                        FolderCovers.setSeriesGrouping(mode, not grouped)
                        FolderCovers.invalidateCache()
                        fm._navbar_suppress_path_change = true
                        fc:refreshPath()
                        fm._navbar_suppress_path_change = nil
                        win:update{ sections = rootSections() }
                    end,
                }
            end
        end
        return toggles
    end

    -- The page size follows the view: the grid of a mosaic, the items
    -- per page of a list, nothing for the classic view.
    function rootSections()
        local rows = { view_row }
        if mode ~= "normal" then
            if TabViews.isListView(TabViews.getView(mode)) then rows[#rows + 1] = per_page_row end
        elseif M.libraryLayout(fm) == "mosaic" then
            rows[#rows + 1] = grid_row
        elseif M.libraryLayout(fm) == "list" then
            rows[#rows + 1] = per_page_row
        end
        rows[#rows + 1] = sort_row
        local sections = { ActionSheet.list(rows) }
        local toggles  = viewToggles()
        if #toggles > 0 then sections[#sections + 1] = ActionSheet.list(toggles) end
        return sections
    end

    local function sortSections()
        local sections = {}
        local current = M.getSort(fm, mode)
        for _i, group in ipairs(M.sortGroups(fc, mode)) do
            if group.title then
                sections[#sections + 1] = { type = "note", text = group.title }
            end
            local row
            for j, c in ipairs(group.collates) do
                if (j - 1) % ROW_MAX == 0 then
                    row = { type = "segments", items = {} }
                    sections[#sections + 1] = row
                end
                local id = c[1]
                row.items[#row.items + 1] = {
                    text     = c[2],
                    selected = id == current,
                    callback = function()
                        if id ~= current then M.setSort(fm, mode, id) end
                        refreshRows()
                        win:update{ title = T(_("Sort by: %1"), _sortLabel(fm, mode)), sections = sortSections() }
                    end,
                }
            end
        end

        local reverse = M.isReverse(fm, mode)
        local toggles = { {
            text     = _("Reverse sorting"),
            toggle   = reverse,
            callback = function()
                M.setReverse(fm, mode, not reverse)
                win:update{ sections = sortSections() }
            end,
        } }
        if mode == "normal" then
            local collate = fc:getCollate()
            local mixed = G_reader_settings:isTrue("collate_mixed")
            toggles[#toggles + 1] = {
                text     = _("Folders and files mixed"),
                enabled  = collate.can_collate_mixed or false,
                toggle   = collate.can_collate_mixed and mixed or false,
                callback = function()
                    fm:onSetMixedSorting(not mixed)
                    win:update{ sections = sortSections() }
                end,
            }
        end

        sections[#sections + 1] = ActionSheet.list(toggles)
        return sections
    end

    view_row.callback = function()
        local current, items = M.getView(fm, mode), {}
        for _i, option in ipairs(M.viewOptions(fm, mode)) do
            items[#items + 1] = {
                text     = option.text,
                checked  = option.id == current,
                callback = function()
                    if option.id ~= current then M.setView(fm, mode, option.id) end
                    refreshRows()
                    win:update{ sections = rootSections() }
                end,
            }
        end
        ActionSheet.pick{ parent = win, title = _("View"), icon = "list", items = items }
    end

    local function spin(opts)
        opts.on_apply = function(n)
            opts.apply(n)
            refreshRows()
            if win:isOpen() then win:update{} end
        end
        require("features/dialogs/sui_dialogs").spin(opts)
    end

    per_page_row.callback = function()
        if mode == "normal" then
            spin{
                title   = _("Items per page"),
                info    = _("Portrait list mode"),
                value   = M.getLibraryPerPage(fm),
                min     = M.LIST_PAGE_MIN,
                max     = M.LIST_PAGE_MAX,
                default = M.LIST_PAGE_DEFAULT,
                apply   = function(n) M.setLibraryPerPage(fm, n) end,
            }
            return
        end
        spin{
            title   = _("Items per page"),
            info    = _("Portrait list mode"),
            value   = M.getPerPage(fm, mode),
            min     = TabViews.PER_PAGE_MIN,
            max     = TabViews.PER_PAGE_MAX,
            default = TabViews.defaultPerPage(mode),
            apply   = function(n) M.setPerPage(fm, mode, n) end,
        }
    end

    grid_row.callback = function()
        local portrait = _portrait()
        local function axis(text, what, default)
            return { text = text, value = M.getGrid(fm, what), min = M.GRID_MIN, max = M.GRID_MAX,
                default = default }
        end
        require("features/dialogs/sui_dialogs").spin2{
            title    = portrait and _("Portrait mosaic mode") or _("Landscape mosaic mode"),
            left     = axis(_("Columns"), "cols", GRID_DEFAULTS[_gridKey("cols")]),
            right    = axis(_("Rows"), "rows", GRID_DEFAULTS[_gridKey("rows")]),
            on_apply = function(cols, rows)
                M.setGrid(fm, cols, rows)
                refreshRows()
                if win:isOpen() then win:update{} end
            end,
        }
    end

    sort_row.callback = function()
        win:showPage{
            title    = T(_("Sort by: %1"), _sortLabel(fm, mode)),
            icon     = "sort",
            sections = sortSections(),
        }
    end

    refreshRows()
    win = ActionSheet.show{
        name     = "sui_win_sort",
        title    = _("View and sort"),
        icon     = "sort",
        flow     = true,
        sections = rootSections(),
    }
end

return M
