-- sui_folder_hold_dialog.lua — Simple UI
--
-- Action sheet for a folder of the file browser, drawn like the book sheet
-- (features/library/sui_book_hold_dialog.lua). Virtual folders (series
-- groups, author/series/tag leaves) have their own sheets.
--
-- Layout (see engines/sui_action_sheet.lua)
--   clipboard tiles → grid (two columns) → list of further rows
--
-- The grid holds "Delete" beside "Rename" and "Set as HOME folder" beside the
-- folder shortcut toggle. The list holds "Show all books here" and the rows
-- registered through FileManager:addFileDialogButtons. The clipboard tiles
-- and the first grid row only appear when the sheet is opened from the file
-- browser; without them "Delete" joins the list.
--
-- Public API
--   FolderHoldDialog.show(folder, opts) -> window
--   FolderHoldDialog.canHandle(file_chooser, item) -> boolean
--   FolderHoldDialog.showFromFileChooser(file_chooser, item) -> window
--
-- opts: see features/library/sui_hold_rows.lua.

local BD       = require("ui/bidi")
local ffiUtil  = require("ffi/util")
local _        = require("infra/sui_i18n").translate

local Rows        = require("features/library/sui_hold_rows")
local VirtualPath = require("features/library/sui_virtual_path")

local M = {}

local SHEET_NAME = "sui_win_folder_actions"

local function setHomeItem(ctx, folder)
    return {
        text     = _("Set as HOME folder"),
        sui_icon = "home_set",
        callback = function()
            ctx.close()
            ctx.file_manager:setHome(folder)
        end,
    }
end

local function shortcutItem(ctx, folder)
    local shortcuts = ctx.file_manager.folder_shortcuts
    if not shortcuts then return nil end
    return Rows.tag(
        shortcuts:genAddRemoveShortcutButton(folder, ctx.close, ctx.refresh), "shortcut")
end

-- Rows of the grid: the folder's own delete and rename, then the HOME folder
-- and shortcut actions.
local function gridRows(ctx)
    local rows   = {}
    local folder = ffiUtil.realpath(ctx.path)

    local manage = Rows.manageRow(ctx, false)
    if manage then Rows.appendRow(rows, manage) end
    if ctx.file_manager and folder then
        Rows.pushRow(rows, setHomeItem(ctx, folder), shortcutItem(ctx, folder))
    end
    return rows
end

-- Row that lists every book under the folder, without folders. Nil for the
-- parent-folder entry and when browsing is off (the flat view needs it).
local function showAllBooksItem(ctx)
    local BrowseMeta = require("features/library/sui_library_browse")
    if not (ctx.file_manager and BrowseMeta.isEnabled()) or (ctx.item and ctx.item.is_go_up) then
        return nil
    end
    local folder = ffiUtil.realpath(ctx.path)
    if not folder then return nil end
    return {
        text     = _("Show all books here"),
        sui_icon = "folder",
        callback = function()
            ctx.close()
            BrowseMeta.navigateToFlat(ctx.file_manager, folder, { entry = false })
        end,
    }
end

-- Rows of the list below the grid. `has_operations` tells that "Delete" is
-- already offered by the grid.
local function listRows(ctx, has_operations)
    local rows = {}
    if ctx.file_manager and not has_operations then
        Rows.pushRow(rows, Rows.deleteItem(ctx, not (ctx.item and ctx.item.is_go_up)))
    end
    local all_books = showAllBooksItem(ctx)
    if all_books then Rows.pushRow(rows, all_books) end
    Rows.appendRegisteredRows(ctx, rows, false)
    return rows
end

function M.show(folder, opts)
    opts = opts or {}
    local ctx = Rows.newContext(folder, opts)

    local sections = {}
    local clipboard = Rows.clipboardItems(ctx, false)
    if #clipboard > 0 then
        sections[#sections + 1] = { type = "tiles", items = clipboard }
    end
    local grid = gridRows(ctx)
    if #grid > 0 then
        sections[#sections + 1] = { type = "rows", rows = grid }
    end
    local list = listRows(ctx, #clipboard > 0)
    if #list > 0 then
        sections[#sections + 1] = { type = "rows", rows = list }
    end

    return Rows.show(ctx, {
        name     = SHEET_NAME,
        title    = opts.title or BD.directory(folder:match("([^/]+)$") or folder),
        icon     = "folder",
        sections = sections,
    })
end

--- True when a long press on `item` in the file browser opens this sheet,
--- i.e. the item is a real folder (or the parent-folder entry).
function M.canHandle(file_chooser, item)
    return Rows.isBrowserItem(file_chooser, item)
        and not item.is_file
        and not item.is_series_group
        and not item.is_virtual_meta_leaf
        and not VirtualPath.isVirtual(item.path)
end

function M.showFromFileChooser(file_chooser, item)
    return M.show(item.path, { file_chooser = file_chooser, item = item })
end

return M
