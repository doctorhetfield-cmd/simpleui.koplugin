-- sui_facet_groups.lua — Simple UI
-- The groups of books a metadata dimension (author, series, tags) splits the
-- library into, for surfaces that show them as folders outside the library
-- browser.
--
-- Only catalogued books take part: a book with no value for the dimension
-- belongs to no group, and a group counts only the books whose file still
-- exists. Groups and their covers are those of the library browser, resolved
-- over the whole library, so a group opens to the same books it counts.
--
-- Public API
-- ----------
--   FacetGroups.baseDir()              -> directory the groups are resolved in
--   FacetGroups.list(dimension)        -> { group, ... } sorted by name
--       group = { dimension, value, name, count, covers = { fp, ... } }
--       `covers` are the first books of the group.
--   FacetGroups.leafPath(group)        -> virtual folder of the group, which
--       doubles as its cover override key
--   FacetGroups.books(group)           -> { { path, title }, ... } every book of
--       the group, in reading order
--   FacetGroups.open(group)
--       Opens the group in the library browser. Going back from it returns to
--       the screen it was opened from, when there is one.
--   FacetGroups.describe(group)        -> group description of a group cell
--       (see engines/sui_group_cell.lua)

local lfs = require("libs/libkoreader-lfs")
local _   = require("infra/sui_i18n").translate

local FilterState    = require("features/library/sui_filter_state")
local GroupActions   = require("features/library/sui_group_actions")
local LibraryScan    = require("engines/sui_library_scan")
local MetadataSource = require("features/library/sui_metadata_source")
local RuleCollections = require("features/library/sui_rule_collections")
local ScreenNav      = require("infra/sui_screen_nav")
local VirtualPath    = require("features/library/sui_virtual_path")

local FacetGroups = {}

-- Name of the book filter below, for the metadata caches: the outcome depends
-- on file existence only.
local EXISTS_VARIANT = "exists"

local function fileExists(row)
    return lfs.attributes(row[1], "mode") == "file"
end

local function bookInfoManager()
    local ok, bim = pcall(require, "bookinfomanager")
    return ok and bim or nil
end

local function isBlank(text)
    return text == nil or not text:find("%S")
end

function FacetGroups.baseDir()
    return LibraryScan.resolveHomeDir()
end

function FacetGroups.list(dimension)
    local bim = bookInfoManager()
    if not (bim and FilterState.isDimension(dimension)) then return {} end

    local base_dir = FacetGroups.baseDir()
    -- The books without a value for the dimension are not listed.
    local values = MetadataSource.getFacetValues(bim, base_dir, dimension, nil, false)
    local counts, firsts = MetadataSource.getValidFacetCounts(
        bim, base_dir, dimension, nil, EXISTS_VARIANT, fileExists)

    local groups = {}
    for _i, entry in ipairs(values) do
        local value, count = entry[1], counts[entry.key]
        if count and count > 0 and not isBlank(value) then
            groups[#groups + 1] = {
                dimension = dimension,
                value     = value,
                name      = value,
                count     = count,
                covers    = firsts[entry.key] or {},
            }
        end
    end
    return groups
end

function FacetGroups.leafPath(group)
    return VirtualPath.buildLeaf(FacetGroups.baseDir(), nil, group.dimension, group.value)
end

function FacetGroups.books(group)
    local bim = bookInfoManager()
    if not bim then return {} end

    local base_dir = FacetGroups.baseDir()
    local filter = FilterState.new(base_dir)
    FilterState.addFilter(filter, group.dimension, group.value)

    -- The valid rows are cached and shared: sort a copy.
    local rows = {}
    for i, row in ipairs(MetadataSource.getValidRows(bim, base_dir, filter, EXISTS_VARIANT, fileExists)) do
        rows[i] = row
    end
    MetadataSource.sortFiles(rows, group.dimension)

    local books = {}
    for i, row in ipairs(rows) do books[i] = { path = row[1], title = row.title } end
    return books
end

function FacetGroups.open(group)
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    if not fm then return end
    local browse = require("features/library/sui_library_browse")

    local screen_id = ScreenNav.close()
    browse.navigateToLeaf(fm, group.dimension, group.value, {
        base_dir  = FacetGroups.baseDir(),
        return_fn = screen_id and function() ScreenNav.reopen(screen_id) end,
    })
end

function FacetGroups.describe(group)
    return {
        name          = group.name,
        paths         = group.covers,
        count         = group.count,
        cover_key     = FacetGroups.leafPath(group),
        open          = function() FacetGroups.open(group) end,
        books         = function() return FacetGroups.books(group) end,
        extra_actions = function()
            return {{
                text     = _("Create collection"),
                sui_icon = "collections",
                callback = function(sheet)
                    GroupActions.createCollection{
                        parent         = sheet,
                        suggested_name = group.name,
                        connect_rule   = RuleCollections.new(FacetGroups.baseDir(),
                            { { dimension = group.dimension, value = group.value } }, true),
                    }
                end,
            }}
        end,
    }
end

return FacetGroups
