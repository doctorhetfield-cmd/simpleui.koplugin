-- sui_book_sources.lua — Simple UI
-- Registry of book sources: named, parameterised producers of an ordered list
-- of items, book file paths or groups of books. Grid modules bind to a source
-- instead of carrying their own listing and filtering logic.
--
-- Source contract
-- ---------------
--   id            string                        unique key
--   label         (params) -> string            display name
--   tab_label     (params) -> string            optional; compact name for
--                                               space-constrained surfaces such
--                                               as tab strips; defaults to label
--   getFileList   (ctx, params) -> { item, ... }  ordered candidates: book
--                                               file paths, or the groups of a
--                                               group source (see describe)
--   filterItem    (fp, ctx, params) -> bool     optional; drops candidates
--   labelForItem  (book_data) -> string?        optional; under-cover text,
--                                               nil falls back to the default
--   needs         { recent = n }                optional; ctx data the source
--                                               reads: n recent books
--                                               prefetched into ctx.recent_fps
--                                               (modules forward it as M.needs)
--   describe      (item, ctx, params) -> group  optional; marks a group
--                                               source: its items are groups,
--                                               shown as group cells. `group`
--                                               is a group description of
--                                               engines/sui_group_cell.lua
--   isAvailable   () -> bool                    optional; false while the
--                                               source cannot be used, which
--                                               hides it from the choices
--   invalidate    ()                            optional; drops cached results
--   choices       () -> { params, ... }         optional; marks a parameterised
--                                               source and lists the param sets
--                                               a user can pick from
--   inline_choices boolean                      optional; the choices are offered
--                                               directly, not grouped under the
--                                               source
--   options       { { key, label, default }, ... }
--                                               optional; boolean options of the
--                                               source (`label` is a function
--                                               returning the translated text).
--                                               A surface that binds the source
--                                               stores the values itself and
--                                               passes them in params under
--                                               `key` (see Sources.withOptions)
--   screen_params (pfx) -> params               optional; params that come from
--                                               screen-wide settings. Always
--                                               merged by Sources.bind, under
--                                               the params of the caller
--   menu_items    (ctx_menu) -> { item, ... }   optional; settings rows the source
--                                               needs beyond its options, for
--                                               behaviour that is not specific
--                                               to one surface
--   collection    table                         optional; marks a source backed
--                                               by an ordered book collection
--                                               and describes it for the sort
--                                               and arrange rows:
--                                                 name(params) -> string?
--                                                 list(params) -> { fp, ... }
--                                                 remove(fp, params)
--                                                 isMember(fp, params) -> bool?
--                                                 onReordered(list)?
--                                                 labels() -> { action, header,
--                                                               empty }
--
-- `params` is a plain table of source-specific values (never nil when a
-- source function runs). Only ids and values are stored in it, never
-- translated text.
--
-- Public API
-- ----------
--   Sources.register(source)           -> source
--   Sources.get(id)                    -> source
--   Sources.label(id, params?)         -> string
--   Sources.tabLabel(id, params?)      -> string
--       Compact display name for tabs; the label when the source has none.
--   Sources.bind(id, getParams?)       -> { getFileList, filterItem?, labelForItem? }
--       Adapts a source to the GridRenderer.makeModule spec fields.
--       `getParams(ctx)` supplies the source params for the current build.
--       Params the source gets are those of `getParams` over its
--       `screen_params`.
--   Sources.withOptions(id, params, getValue) -> params
--       `params` extended with the value of every option of the source, as
--       read through `getValue(key)` (nil falls back to the option default).
--       `params` itself when the source has no options.
--   Sources.invalidate(id)             -- drops a source's cached results
--   Sources.has(id)                    -> bool
--   Sources.isAvailable(id)            -> bool
--   Sources.describe(id, item, ctx, params) -> group
--       Group description of an item of a group source.
--   Sources.isGroupSource(id)          -> bool
--   Sources.list()                     -> { id, ... }
--       Registered source ids, in registration order.
--   Sources.choices(id)                -> { { params, label }, ... } | nil
--       The selectable param sets of a parameterised source with their
--       labels; nil for a source without parameters to pick.
--   Sources.hasInlineChoices(id)       -> bool
--   Sources.listCollectionNames()      -> { name, ... }
--       Collections selectable for the "collection" source.
--
-- Built-in sources
-- ----------------
--   recent       params: exclude_current (default true), show_finished;
--                option: show_finished (off); the Currently Reading book is
--                left out according to the screen-wide setting
--   new_books    most recently added books of the library
--   tbr          the To Be Read list; a collection source
--   collection   params: coll (collection name); a collection source
--   facet        group source; params: dim (author, series or tags). One group
--                per value of the dimension, for the catalogued books only

local _ = require("infra/sui_i18n").translate

local GridRenderer = require("engines/sui_book_grid")
local LibraryScan  = require("engines/sui_library_scan")
local FilterState  = require("features/library/sui_filter_state")
local SH           = require("modules/module_books_shared")

local Sources = {}

local _registry = {}
local _order    = {}
local NO_PARAMS = {}

function Sources.register(source)
    assert(source.id, "book source: id is required")
    assert(type(source.label) == "function", "book source: label function is required")
    assert(type(source.getFileList) == "function", "book source: getFileList function is required")
    assert(not _registry[source.id], "book source already registered: " .. source.id)
    _registry[source.id] = source
    _order[#_order + 1] = source.id
    return source
end

function Sources.get(id)
    return assert(_registry[id], "unknown book source: " .. tostring(id))
end

function Sources.has(id)
    return _registry[id] ~= nil
end

function Sources.isAvailable(id)
    local source = Sources.get(id)
    return source.isAvailable == nil or source.isAvailable()
end

function Sources.isGroupSource(id)
    return Sources.get(id).describe ~= nil
end

function Sources.describe(id, item, ctx, params)
    return Sources.get(id).describe(item, ctx, params or NO_PARAMS)
end

function Sources.list()
    local ids = {}
    for i, id in ipairs(_order) do ids[i] = id end
    return ids
end

function Sources.choices(id)
    local source = Sources.get(id)
    if not source.choices then return nil end
    local choices = {}
    for _i, params in ipairs(source.choices()) do
        choices[#choices + 1] = { params = params, label = source.label(params) }
    end
    return choices
end

function Sources.hasInlineChoices(id)
    return Sources.get(id).inline_choices == true
end

function Sources.label(id, params)
    return Sources.get(id).label(params or NO_PARAMS)
end

function Sources.tabLabel(id, params)
    local source = Sources.get(id)
    return (source.tab_label or source.label)(params or NO_PARAMS)
end

function Sources.bind(id, getParams)
    local source = Sources.get(id)
    local function paramsFor(ctx)
        local params = getParams and getParams(ctx) or NO_PARAMS
        if not source.screen_params then return params end
        local merged = source.screen_params(ctx.pfx or "")
        for key, value in pairs(params) do merged[key] = value end
        return merged
    end

    local bound = {
        getFileList  = function(ctx) return source.getFileList(ctx, paramsFor(ctx)) end,
        labelForItem = source.labelForItem,
    }
    if source.filterItem then
        bound.filterItem = function(fp, ctx)
            return source.filterItem(fp, ctx, paramsFor(ctx))
        end
    end
    return bound
end

function Sources.withOptions(id, params, getValue)
    local options = Sources.get(id).options
    if not options then return params or NO_PARAMS end
    local extended = {}
    for key, value in pairs(params or NO_PARAMS) do extended[key] = value end
    for _i, option in ipairs(options) do
        local value = getValue(option.key)
        if value == nil then value = option.default end
        extended[option.key] = value
    end
    return extended
end

function Sources.invalidate(id)
    local source = Sources.get(id)
    if source.invalidate then source.invalidate() end
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local function isUnfinished(fp, ctx)
    return not SH.isFinished(fp, ctx.prefetched)
end

-- The To Be Read list and its collection name are owned by the TBR module
-- (a data layer that is also a grid module), so it is resolved lazily to keep
-- this registry free of load-time dependencies on modules that bind to it.
local function tbrModule()
    return require("modules/module_tbr")
end

local function readCollection()
    local ok, rc = pcall(require, "readcollection")
    return ok and rc or nil
end

local function isMissingCollection(name)
    local rc = readCollection()
    if not rc then return false end
    return not (rc.coll and rc.coll[name])
end

-- The settings rows of a source are built by features/sui_source_menu, which
-- binds to this registry, so it loads on use.
local function sourceMenu()
    return require("features/sui_source_menu")
end

function Sources.listCollectionNames()
    return GridRenderer.listAllCollectionNames({ [tbrModule().TBR_COLL_NAME] = true })
end

-- ---------------------------------------------------------------------------
-- recent — reading history, as prefetched into ctx.recent_fps
-- ---------------------------------------------------------------------------

-- More recent books than any grid shows, so enough unfinished ones remain
-- after the finished-book filter.
local RECENT_CANDIDATES = 15

Sources.register{
    id        = "recent",
    label     = function() return _("Recent Books") end,
    tab_label = function() return _("Recent") end,
    needs = { recent = RECENT_CANDIDATES },

    options = {
        { key = "show_finished", label = function() return _("Show finished books") end, default = false },
    },

    screen_params = function(pfx)
        return { exclude_current = SH.isCurrentExcluded(pfx) }
    end,

    menu_items = function(ctx_menu)
        local items = sourceMenu().excludeCurrentItems(ctx_menu)
        for _i, item in ipairs(sourceMenu().hiddenHistoryItems(ctx_menu)) do
            items[#items + 1] = item
        end
        return items
    end,

    getFileList = function(ctx) return ctx.recent_fps or {} end,

    filterItem = function(fp, ctx, params)
        if params.exclude_current ~= false and ctx.current_fp and fp == ctx.current_fp then
            return false
        end
        return params.show_finished == true or isUnfinished(fp, ctx)
    end,
}

-- ---------------------------------------------------------------------------
-- new_books — newest files of the library by modification time
-- ---------------------------------------------------------------------------

-- More candidates than any grid shows, to compensate for the finished books
-- the filter drops.
local NEW_BOOKS_CANDIDATES = 15
local NEW_BOOKS_TTL        = 300  -- seconds between refreshes of the ranking

local _new_books_cache = nil      -- { fps = { fp, ... }, time = os.time() }

local function scanNewestBooks()
    local books = LibraryScan.getRaw(LibraryScan.resolveHomeDir())
    table.sort(books, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.fp < b.fp
    end)
    local fps = {}
    for i = 1, math.min(NEW_BOOKS_CANDIDATES, #books) do
        fps[i] = books[i].fp
    end
    return fps
end

Sources.register{
    id    = "new_books",
    label = function() return _("New Books") end,

    getFileList = function()
        local now = os.time()
        if not _new_books_cache or now - _new_books_cache.time >= NEW_BOOKS_TTL then
            _new_books_cache = { fps = scanNewestBooks(), time = now }
        end
        return _new_books_cache.fps
    end,

    -- Unlike recent, the open book is kept: this source ranks acquisition,
    -- not reading activity.
    filterItem = isUnfinished,

    labelForItem = function(bd)
        if (bd.percent or 0) < 0.01 then return _("New") end
    end,

    invalidate = function() _new_books_cache = nil end,
}

-- ---------------------------------------------------------------------------
-- tbr — the To Be Read list
-- ---------------------------------------------------------------------------

Sources.register{
    id          = "tbr",
    label       = function() return _("To Be Read") end,
    getFileList = function() return tbrModule().getTBRList() end,

    collection = {
        name        = function() return tbrModule().TBR_COLL_NAME end,
        list        = function() return tbrModule().getTBRList() end,
        remove      = function(fp) tbrModule().removeTBR(fp) end,
        isMember    = function(fp) return tbrModule().isTBR(fp) end,
        onReordered = function(list) tbrModule().syncSettings(list) end,
        labels      = function()
            return {
                action = _("Arrange To Be Read List"),
                header = _("To Be Read Books"),
                empty  = _("No books in To Be Read list."),
            }
        end,
    },

    menu_items = function(ctx_menu) return tbrModule().autoRemoveMenuItems(ctx_menu) end,
}

-- ---------------------------------------------------------------------------
-- collection — any ReadCollection, chosen through params.coll
-- ---------------------------------------------------------------------------

local function collectionBooks(params)
    return GridRenderer.getCollectionFileList(params.coll)
end

Sources.register{
    id    = "collection",
    label = function(params)
        local name = params.coll
        if not name then return _("Collection") end
        if isMissingCollection(name) then
            return name .. "  " .. _("(collection not found)")
        end
        return name
    end,

    getFileList = function(_ctx, params) return collectionBooks(params) end,

    collection = {
        name   = function(params) return params.coll end,
        list   = collectionBooks,
        remove = function(fp, params)
            local rc = readCollection()
            if rc then rc:removeItem(fp, params.coll) end
        end,
        labels = function()
            return {
                action = _("Arrange Collection"),
                header = _("Books"),
                empty  = _("No books in this collection."),
            }
        end,
    },

    choices = function()
        local choices = {}
        for _i, name in ipairs(Sources.listCollectionNames()) do
            choices[#choices + 1] = { coll = name }
        end
        return choices
    end,
}

-- ---------------------------------------------------------------------------
-- facet — the groups of an author, series or tags dimension, chosen through
-- params.dim
-- ---------------------------------------------------------------------------

-- The library browser and the facet groups load on use: they depend on
-- modules that bind to this registry.
local function libraryBrowse()
    return require("features/library/sui_library_browse")
end

local function facetGroups()
    return require("features/library/sui_facet_groups")
end

Sources.register{
    id    = "facet",
    label = function(params)
        return params.dim and libraryBrowse().getModeLabel(params.dim) or _("Browse by")
    end,

    inline_choices = true,

    -- A group opens in the library browser.
    isAvailable = function() return libraryBrowse().isEnabled() end,

    getFileList = function(_ctx, params) return facetGroups().list(params.dim) end,

    describe = function(group) return facetGroups().describe(group) end,

    choices = function()
        local choices = {}
        for _i, dimension in ipairs(FilterState.ORDERED_DIMENSIONS) do
            choices[#choices + 1] = { dim = dimension }
        end
        return choices
    end,
}

return Sources
