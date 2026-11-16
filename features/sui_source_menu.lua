-- sui_source_menu.lua — Simple UI
-- Settings rows of a book source (engines/sui_book_sources.lua). They are
-- built from what the source declares, so every surface that binds a source
-- (a module, a tab) offers the same options the same way.
--
--   SourceMenu.makeItems(ctx_menu, source_id, params, values)
--       Every row of the source: sort and arrange of its collection, its
--       options and its own rows, in that order.
--   SourceMenu.hasItems(source_id)   -> bool
--       Whether the source has any row to show.
--   SourceMenu.collectionItems(ctx_menu, source_id, params, opts)
--       Sort and Arrange rows of a collection source.
--         params  the source params, or a function returning them, read
--                 when a row is used
--         opts.sort       { get, set } of the sort state, a { mode, sig } table
--         opts.separator  optional; draws a separator below the Sort row
--   SourceMenu.optionItems(ctx_menu, source_id, values)
--       One checkable row per option of the source.
--         values  { get(key) -> value | nil, set(key, value) }; nil reads as
--                 the default of the option
--   SourceMenu.excludeCurrentItems(ctx_menu)
--       "Hide Currently Reading" row; empty while that module is not enabled
--       on the screen.
--   SourceMenu.hiddenHistoryItems(ctx_menu)
--       "Hidden books" submenu: one checkable row per book hidden from the
--       reading history; not shown while no book is hidden.
--   SourceMenu.keyedState(key)       -> { get, set }
--       Sort state stored under a settings key.

local GridRenderer      = require("engines/sui_book_grid")
local CollectionArrange = require("features/sui_collection_arrange")
local SH                = require("modules/module_books_shared")
local Sources           = require("engines/sui_book_sources")
local SUISettings       = require("infra/sui_store")
local VirtualPaths      = require("infra/sui_virtual_paths")

local SourceMenu = {}

-- Key of the sort state within the values store of makeItems.
local SORT_STATE = "sort_state"

local function resolve(value)
    if type(value) == "function" then return value() end
    return value
end

function SourceMenu.keyedState(key)
    return {
        get = function() return SUISettings:readSetting(key) end,
        set = function(state) SUISettings:saveSetting(key, state) end,
    }
end

function SourceMenu.collectionItems(ctx_menu, source_id, params, opts)
    local collection = Sources.get(source_id).collection
    if not collection then return {} end

    local function name() return collection.name(resolve(params)) end
    local function list() return collection.list(resolve(params)) end

    return {
        GridRenderer.makeSortMenuItem{
            _lc         = ctx_menu._,
            refresh     = ctx_menu.refresh,
            getState    = opts.sort.get,
            setState    = opts.sort.set,
            getCollName = name,
            getCount    = function() return #list() end,
            separator   = opts.separator,
            onSorted    = collection.onReordered and function() collection.onReordered(list()) end,
        },
        CollectionArrange.makeMenuItem{
            ctx_menu       = ctx_menu,
            labels         = collection.labels(),
            getCollName    = name,
            getList        = list,
            removeBook     = function(fp) collection.remove(fp, resolve(params)) end,
            isMember       = collection.isMember and function(fp)
                return collection.isMember(fp, resolve(params))
            end,
            onOrderChanged = collection.onReordered,
        },
    }
end

function SourceMenu.optionItems(ctx_menu, source_id, values)
    local items = {}
    for _i, option in ipairs(Sources.get(source_id).options or {}) do
        local function current()
            local value = values.get(option.key)
            if value == nil then value = option.default end
            return value == true
        end
        items[#items + 1] = {
            text           = option.label(),
            checked_func   = current,
            keep_menu_open = true,
            callback       = function()
                values.set(option.key, not current())
                ctx_menu.refresh()
            end,
        }
    end
    return items
end

function SourceMenu.excludeCurrentItems(ctx_menu)
    local pfx      = ctx_menu.pfx or ""
    local Registry = require("modules/moduleregistry")
    local currently = Registry.get("currently")
    if not (currently and Registry.isEnabled(currently, pfx)) then return {} end
    return {
        {
            text           = ctx_menu._("Hide Currently Reading book"),
            checked_func   = function() return SH.isCurrentExcluded(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SH.setCurrentExcluded(pfx, not SH.isCurrentExcluded(pfx))
                ctx_menu.refresh()
            end,
        },
    }
end

function SourceMenu.hiddenHistoryItems(ctx_menu)
    local _lc = ctx_menu._
    return {
        {
            text                = _lc("Hidden books"),
            enabled_func        = function() return #SH.hiddenEntries() > 0 end,
            sub_item_table_func = function()
                local items = {}
                for _i, entry in ipairs(SH.hiddenEntries()) do
                    local ok, data = pcall(SH.getBookData, VirtualPaths.toVirtual(entry.file))
                    local title = ok and data and data.title ~= "" and data.title or entry.text
                    items[#items + 1] = {
                        text           = title or entry.file,
                        checked_func   = function() return SH.isHiddenEntry(entry) end,
                        keep_menu_open = true,
                        callback       = function()
                            SH.setHidden(entry, not SH.isHiddenEntry(entry))
                            ctx_menu.refresh()
                        end,
                    }
                end
                return items
            end,
        },
    }
end

function SourceMenu.hasItems(source_id)
    local source = Sources.get(source_id)
    return source.collection ~= nil or source.options ~= nil or source.menu_items ~= nil
end

function SourceMenu.makeItems(ctx_menu, source_id, params, values)
    local source = Sources.get(source_id)
    local items  = SourceMenu.collectionItems(ctx_menu, source_id, params, {
        sort = {
            get = function() return values.get(SORT_STATE) end,
            set = function(state) values.set(SORT_STATE, state) end,
        },
    })
    for _i, item in ipairs(SourceMenu.optionItems(ctx_menu, source_id, values)) do
        items[#items + 1] = item
    end
    if source.menu_items then
        for _i, item in ipairs(source.menu_items(ctx_menu)) do items[#items + 1] = item end
    end
    return items
end

return SourceMenu
