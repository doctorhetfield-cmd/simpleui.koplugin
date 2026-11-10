-- sui_sort_sheet.lua — Simple UI
-- Sort options of a library tab, shown on a long press of the tab.
--
-- The sheet reads and writes KOReader's own sort settings (collate,
-- reverse_collate, collate_mixed) through the file manager's handlers, so the
-- file browser and every library tab share one sort order.
--
-- It also registers the "number of books" collate in FileChooser.collates:
-- metadata folders (Authors/Series/Tags) are sorted by the number of books
-- they hold; everything else falls back to the name.
--
--   SortSheet.install() / SortSheet.uninstall()  — register / remove the collate
--   SortSheet.show(fm, mode)                     — show the sheet for a browse mode
--   SortSheet.sortsFacetFolders(id)              — whether a collate orders metadata folders

local ffiUtil     = require("ffi/util")
local T           = ffiUtil.template
local _           = require("infra/sui_i18n").translate
local ActionSheet = require("engines/sui_action_sheet")

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
local function _groups(fc, mode)
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

function M.show(fm, mode)
    local fc = fm and fm.file_chooser
    if not fc then return end

    local win

    local function title()
        local collate = fc:getCollate()
        return T(_("Sort by: %1"), collate.text)
    end

    local function buildSections()
        local collate, current = fc:getCollate()
        local sections = {}
        for _i, group in ipairs(_groups(fc, mode)) do
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
                        if id ~= current then fm:onSetSortBy(id) end
                        win:update{ title = title(), sections = buildSections() }
                    end,
                }
            end
        end

        local reverse = G_reader_settings:isTrue("reverse_collate")
        local toggles = { {
            text     = _("Reverse sorting"),
            toggle   = reverse,
            callback = function()
                fm:onSetReverseSorting(not reverse)
                win:update{ sections = buildSections() }
            end,
        } }
        if mode == "normal" then
            local mixed = G_reader_settings:isTrue("collate_mixed")
            toggles[#toggles + 1] = {
                text     = _("Folders and files mixed"),
                enabled  = collate.can_collate_mixed or false,
                toggle   = collate.can_collate_mixed and mixed or false,
                callback = function()
                    fm:onSetMixedSorting(not mixed)
                    win:update{ sections = buildSections() }
                end,
            }
        end

        sections[#sections + 1] = ActionSheet.list(toggles)
        return sections
    end

    win = ActionSheet.show{
        name     = "sui_win_sort",
        title    = title(),
        icon     = "sort",
        sections = buildSections(),
    }
end

return M
