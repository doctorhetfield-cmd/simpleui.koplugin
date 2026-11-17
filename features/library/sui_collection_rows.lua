-- sui_collection_rows.lua — Simple UI
-- Rows of the collections list in the style of the folder rows of the detailed
-- list: name over an info line (markers and book count), with a chevron, or a
-- checkbox in select mode.
--
-- Public API:
--   CollectionRows.infoText(marker, count)   -- "★ · 12 books", "12 books"
--   CollectionRows.isActive()                -- true while the Library list rows are SimpleUI's
--   CollectionRows.getPerPage() / setPerPage(n) -- portrait rows per page of the list; redraws an open list
--   CollectionRows.PER_PAGE_DEFAULT          -- portrait rows per page the list starts with
--   CollectionRows.perPage(menu)             -- rows per page, as the detailed list gets
--   CollectionRows.updateItems(menu, ...)    -- Menu.updateItems, then restyles the rows

local _ = require("infra/sui_i18n").translate
local T = require("ffi/util").template
local ListRows = require("features/library/sui_list_rows")

local M = {}

function M.infoText(marker, count)
    local text = ListRows.countText(count, 0)
    return marker and T(_("%1 · %2"), marker, text) or text
end

function M.isActive()
    local FolderCovers = package.loaded["features/library/sui_foldercovers"]
    return FolderCovers ~= nil and FolderCovers.isEnabled()
end

-- Range of the native portrait list setting.
M.PER_PAGE_MIN, M.PER_PAGE_MAX = 4, 20
M.PER_PAGE_DEFAULT = 7
local PER_PAGE_KEY = "simpleui_lib_per_page_collections"

function M.getPerPage()
    local n = tonumber(require("infra/sui_store"):readSetting(PER_PAGE_KEY))
    if n and n >= M.PER_PAGE_MIN and n <= M.PER_PAGE_MAX then return math.floor(n) end
    return M.PER_PAGE_DEFAULT
end

-- Redraws the collections list of every open file manager or reader that
-- uses these rows.
local function _refreshOpen()
    for _i, name in ipairs{ "apps/filemanager/filemanager", "apps/reader/readerui" } do
        local app = package.loaded[name]
        local manager = app and app.instance and app.instance.collections
        local list = manager and manager.coll_list
        if list and rawget(list, "updateItems") == M.updateItems then list:updateItems(1) end
    end
end

-- The default value is not stored.
function M.setPerPage(n)
    local SUISettings = require("infra/sui_store")
    if n and n ~= M.PER_PAGE_DEFAULT then
        SUISettings:saveSetting(PER_PAGE_KEY, n)
    else
        SUISettings:delSetting(PER_PAGE_KEY)
    end
    _refreshOpen()
end

-- The list's items per page in portrait, adjusted in landscape so the rows
-- keep the portrait height, as the detailed list does.
function M.perPage(menu)
    local Math   = require("optmath")
    local Screen = require("device").screen
    local Size   = require("ui/size")
    local avail  = menu.available_height
    local per_page = M.getPerPage()
    if Screen:getWidth() > Screen:getHeight() then
        local others = menu.inner_dimen.h - avail
        local portrait_avail = Screen:getWidth() - others - Size.line.thin
        local portrait_h = math.floor(portrait_avail / per_page) - Size.line.thin
        per_page = Math.round(avail / portrait_h)
    end
    return math.max(1, per_page)
end

-- Hides the resting line of a row; a focused row keeps its focus underline.
function M.hideLine(item, uc, hidden, focus_color)
    item.line_color = hidden
    if not (uc.color == focus_color) then uc.color = hidden end
end

-- Replaces the content of every row of the page with the list folder row.
-- A row without the expected layout keeps the native look.
local function decorate(menu)
    local Blitbuffer  = require("ffi/blitbuffer")
    local Geom        = require("ui/geometry")
    local Size        = require("ui/size")
    local BD          = require("ui/bidi")
    local util        = require("util")
    local SUIStyle    = require("features/sui_style")
    local FMColl      = require("apps/filemanager/filemanagercollection")
    local ReadCollection = require("readcollection")

    local manager = menu._manager
    local selecting = manager and manager.selected_collections ~= nil
    local group = menu.item_group
    local last = #group
    for i, item in ipairs(group) do
        local uc, entry = item._underline_container, item.entry
        if uc and entry and entry.name then
            local info = M.infoText(FMColl.getCollMarker(entry.name),
                util.tableSize(ReadCollection.coll[entry.name] or {}))
            local glyph = selecting
                and SUIStyle.selectionIcon(false, entry.mandatory == manager.checkmark)
                or SUIStyle.icon("chevron")
            uc.linesize = Size.line.thin
            item.underline_h = 0
            local dimen = Geom:new{ w = uc.dimen.w, h = item.dimen.h - uc.linesize }
            ListRows.setContent(item, ListRows.trailingRow(dimen, glyph, function(main_w)
                return ListRows.lines(BD.auto(entry.text), info, dimen, main_w)
            end))
            -- The line under the last row is hidden: lines only divide rows.
            if i == last then
                M.hideLine(item, uc, SUIStyle.COLOR.surface, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

function M.updateItems(menu, ...)
    local Menu = require("ui/widget/menu")
    if not menu.available_height then menu:_recalculateDimen() end
    menu.items_per_page = M.perPage(menu)
    local result = Menu.updateItems(menu, ...)
    decorate(menu)
    return result
end

return M
