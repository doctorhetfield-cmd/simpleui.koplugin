-- sui_rule_collections.lua — Simple UI
-- Collections connected to a metadata rule instead of a real folder: the
-- books under a base folder that match an author/series/tags trail (a
-- virtual library leaf, a facet group or an in-folder series group).
--
-- The rule lives in the collection settings, next to KOReader's connected
-- folders, and is rescanned whenever KOReader rescans those folders. A rescan
-- mirrors the rule: matching books are added (honouring the collection's
-- "add" filter) and books that no longer match are removed, except books
-- that belong to a real folder connected to the same collection.
--
-- Rule (coll_settings[name][RuleCollections.KEY]):
--   base_dir      folder whose books are matched
--   trail         { {dimension=, value=}, ... }, as in FilterState
--   subfolders    match the whole subtree (true) or base_dir only (false)
--   scan_on_show  rescan when the collection is opened
--
-- Public API
-- ----------
--   RuleCollections.KEY
--   RuleCollections.new(base_dir, trail, subfolders) -> rule
--   RuleCollections.get(coll_name)                   -> rule | nil
--   RuleCollections.sync(rc, coll_name, is_showing)  -> added, removed
--   RuleCollections.syncAll(rc)                      -- rescans and saves every rule
--   RuleCollections.label(rule)                      -> text for folder lists
--   RuleCollections.flags(rule)                      -> subfolders/scan markers | nil
--   RuleCollections.open(rule, ui)                   -- shows the rule's books

local ffiUtil = require("ffi/util")
local lfs     = require("libs/libkoreader-lfs")
local util    = require("util")

local Config         = require("infra/sui_config")
local FilterState    = require("features/library/sui_filter_state")
local MetadataSource = require("features/library/sui_metadata_source")
local VirtualPath    = require("features/library/sui_virtual_path")

local RuleCollections = {}

RuleCollections.KEY = "simpleui_rule"

local function stripSlash(path)
    return (path:gsub("(.)/+$", "%1"))
end

function RuleCollections.new(base_dir, trail, subfolders)
    local copy = {}
    for i, entry in ipairs(trail) do
        copy[i] = { dimension = entry.dimension, value = entry.value }
    end
    return {
        base_dir     = stripSlash(base_dir),
        trail        = copy,
        subfolders   = subfolders and true or false,
        scan_on_show = true,
    }
end

function RuleCollections.get(coll_name)
    local settings = require("readcollection").coll_settings[coll_name]
    return settings and settings[RuleCollections.KEY]
end

-- File types and statuses of the collection's "add" filter.
local function addFilter(settings)
    local filter = util.tableGetValue(settings, "filter", "add")
    if not filter then return nil, nil end
    local types
    if filter.filetype then
        types = {}
        for filetype in util.gsplit(filter.filetype, ",") do
            types[util.trim(filetype)] = true
        end
    end
    return types, filter.status
end

local function passesAddFilter(file, filename, types, statuses)
    if filename:sub(1, 2) == "._" then return false end
    if types then
        local _name, ext = require("apps/filemanager/filemanagerutil").splitFileNameType(filename)
        if not types[ext] then return false end
    elseif not require("document/documentregistry"):hasProvider(filename) then
        return false
    end
    if statuses then
        return statuses[require("ui/widget/booklist").getBookStatus(file)] and true or false
    end
    return true
end

-- True when `file` lies in a real folder connected to the collection.
local function inConnectedFolder(file, folders)
    if not folders then return false end
    for folder, folder_settings in pairs(folders) do
        local prefix = stripSlash(ffiUtil.realpath(folder) or folder) .. "/"
        if file:sub(1, #prefix) == prefix
                and (folder_settings.subfolders or not file:find("/", #prefix + 1, true)) then
            return true
        end
    end
    return false
end

-- Books matching the rule, in display order, as { {file, filename}, ... }
-- keyed by real path too. nil when the rule cannot be evaluated (folder
-- missing, metadata unavailable or not indexed): the collection is then left
-- untouched rather than emptied.
local function matchedBooks(rule)
    local base_dir = rule.base_dir
    if not (base_dir and lfs.attributes(base_dir, "mode") == "directory") then return nil end
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not (ok_bim and bim) then return nil end
    if #MetadataSource.getMatchingFiles(bim, base_dir, nil) == 0 then return nil end

    local state = FilterState.new(base_dir)
    for _i, entry in ipairs(rule.trail) do
        FilterState.addFilter(state, entry.dimension, entry.value)
    end
    local rows = MetadataSource.getMatchingFiles(bim, base_dir, state)
    local last = rule.trail[#rule.trail]
    MetadataSource.sortFiles(rows, last and last.dimension)

    local books = {}
    for _i, row in ipairs(rows) do
        local path = row[1]
        if (rule.subfolders or path:match("^(.*)/[^/]+$") == base_dir)
                and lfs.attributes(path, "mode") == "file" then
            local file = ffiUtil.realpath(path) or path
            if not books[file] then
                books[file] = true
                books[#books + 1] = { file, row[2] }
            end
        end
    end
    return books
end

-- Rescans the rule of `coll_name` into rc.coll, without saving.
function RuleCollections.sync(rc, coll_name, is_showing)
    local settings = rc.coll_settings[coll_name]
    local rule = settings and settings[RuleCollections.KEY]
    local coll = rc.coll[coll_name]
    if not (rule and coll) or (is_showing and not rule.scan_on_show) then return 0, 0 end
    local books = matchedBooks(rule)
    if not books then return 0, 0 end

    local types, statuses = addFilter(settings)
    local added, removed = 0, 0
    for _i, book in ipairs(books) do
        local file = book[1]
        if not coll[file] and passesAddFilter(file, book[2], types, statuses) then
            rc:addItem(file, coll_name)
            added = added + 1
        end
    end
    for file in pairs(coll) do
        if not books[file] and not inConnectedFolder(file, settings.folders) then
            rc:removeItem(file, coll_name, true)
            removed = removed + 1
        end
    end
    return added, removed
end

function RuleCollections.syncAll(rc)
    local changed
    for coll_name, settings in pairs(rc.coll_settings) do
        if settings[RuleCollections.KEY] then
            local added, removed = RuleCollections.sync(rc, coll_name)
            if added + removed > 0 then
                changed = changed or {}
                changed[coll_name] = true
            end
        end
    end
    if changed then rc:write(changed) end
end

function RuleCollections.label(rule)
    local Browse = require("features/library/sui_library_browse")
    local parts = { rule.base_dir }
    for _i, entry in ipairs(rule.trail) do
        parts[#parts + 1] = Browse.getModeLabel(entry.dimension) or entry.dimension
        parts[#parts + 1] = VirtualPath.displayValue(entry.value)
    end
    return table.concat(parts, " › ")
end

-- Same markers KOReader shows for connected folders.
function RuleCollections.flags(rule)
    local marks = {}
    if rule.scan_on_show then marks[#marks + 1] = Config.nerdIconChar("nerd:F441") end
    if rule.subfolders then marks[#marks + 1] = Config.nerdIconChar("nerd:F114") end
    return marks[1] and table.concat(marks, " ") or nil
end

-- Opens the rule's books: the library leaf when the library browser is on,
-- otherwise the base folder.
function RuleCollections.open(rule, ui)
    local fc = ui and ui.file_chooser
    if not fc then
        ui:onClose()
        ui:showFileManager(rule.base_dir .. "/")
        return
    end
    local Browse = require("features/library/sui_library_browse")
    local last = rule.trail[#rule.trail]
    if rule.subfolders and last and last.value ~= false and Browse.isEnabled() then
        local prefix = FilterState.new(rule.base_dir)
        for i = 1, #rule.trail - 1 do
            FilterState.addFilter(prefix, rule.trail[i].dimension, rule.trail[i].value)
        end
        Browse.navigateToLeaf(ui, last.dimension, last.value, {
            base_dir     = rule.base_dir,
            filter_state = prefix,
        })
    else
        fc:changeToPath(rule.base_dir)
    end
end

return RuleCollections
