-- sui_native_arrange.lua — Simple UI
-- Opens the reorder lists of the collections manager as Arrange windows.
--
-- The manager shows a sort widget over the item table of its collections list
-- (arranging the collections) or of its book list (arranging the books of one
-- collection). The sort widget reorders that table in place and its callback
-- saves the order. The window does the same on every move, so the order is
-- saved as it changes.
--
-- Public API
--   NativeArrange.interceptShow(widget) -> boolean   show step (consumes the call)

local ButtonDialog = require("ui/widget/buttondialog")
local logger       = require("logger")
local SortWidget   = require("ui/widget/sortwidget")
local UIManager    = require("ui/uimanager")
local _            = require("gettext")

local SUIWindow = require("engines/sui_window")

local NativeArrange = {}

-- True when `item_table` is one of the tables the collections manager of the
-- file manager lists.
local function isManagerTable(item_table)
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    local manager = file_manager and file_manager.instance and file_manager.instance.collections
    if not manager then return false end

    local collections, books = manager.coll_list, manager.booklist_menu
    return (collections ~= nil and collections.item_table == item_table)
        or (books ~= nil and books.item_table == item_table)
end

local SORT_CHOICES = {
    { _("Sort A to Z"),             "strcoll", false },
    { _("Sort Z to A"),             "strcoll", true  },
    { _("Sort A to Z (natural)"),   "natural", false },
    { _("Sort Z to A (natural)"),   "natural", true  },
}

-- Sorts `items` in place by `text` with the file chooser collate `collate_id`.
local function sortItems(items, collate_id, reverse)
    local FileChooser = require("ui/widget/filechooser")
    table.sort(items, FileChooser:getSortingFunction(FileChooser.collates[collate_id], reverse))
end

local function present(sort_widget)
    local source = sort_widget.item_table
    local items  = {}
    for _i, entry in ipairs(source) do
        items[#items + 1] = { text = entry.text, orig_item = entry }
    end

    local function applyChange(arranged)
        for i, item in ipairs(arranged) do source[i] = item.orig_item end
        sort_widget.callback()
    end

    SUIWindow.showArrange{
        title     = sort_widget.title,
        items     = items,
        footer    = {
            text   = _("Sort"),
            on_tap = function(ctx)
                local dialog
                local buttons = {}
                for _i, choice in ipairs(SORT_CHOICES) do
                    buttons[#buttons + 1] = {{
                        text     = choice[1],
                        align    = "left",
                        callback = function()
                            UIManager:close(dialog)
                            sortItems(items, choice[2], choice[3])
                            applyChange(items)
                            ctx.repaint()
                        end,
                    }}
                end
                dialog = ButtonDialog:new{ shrink_unneeded_width = true, buttons = buttons }
                UIManager:show(dialog)
            end,
        },
        on_change = applyChange,
    }
end

--- Show step: replaces a sort widget of the collections manager with an
--- Arrange window. Returns true when the widget was consumed.
function NativeArrange.interceptShow(widget)
    if widget == nil or getmetatable(widget) ~= SortWidget then return false end
    if not isManagerTable(widget.item_table) then return false end

    local ok, err = pcall(present, widget)
    if ok then return true end
    logger.warn("simpleui/native_arrange: window failed, showing the sort widget:", tostring(err))
    return false
end

return NativeArrange
