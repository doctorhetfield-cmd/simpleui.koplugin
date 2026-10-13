-- sui_virtual_path.lua — Simple UI
-- Encodes/decodes the fake filesystem path used to represent a library
-- browse state (which dimensions are filtered, on which values) inside
-- FileChooser's `path` field. The real OS never sees these paths — they
-- are intercepted before any disk I/O by sui_library_browse's patches.
--
--   /real/books/.simpleui-browse/author/=Ursula K. Le Guin/tags/=Hainish
--   \_________/\______________/\______/\__________________/\___/\_____/
--     base_dir     root marker  dim key      value (=-prefixed)  dim   value
--
-- Plain ASCII segments on purpose (no Unicode glyphs): easy to read in
-- logs, greppable, and there is exactly one rule to remember — a dimension
-- segment is a bare keyword ("author"/"series"/"tags"), a value segment
-- always starts with "=". That "=" prefix is what makes parsing
-- unambiguous: it's impossible for a real book's author/series/tag value
-- to be mistaken for the next dimension keyword, because dimension
-- keywords never start with "=" and encoded values always do — no matter
-- what the underlying value's raw text happens to be.
--
-- A path ending in a bare dimension segment (no value after it) means "the
-- user is choosing a value for this dimension" — the dim_list level,
-- rendered as a list of facet values with counts. A path ending in a value
-- segment is a leaf — rendered as a file list.
--
-- A path can encode several stacked dimensions (browse by author, then
-- narrow by tag within that author) — this is what makes multi-dimension
-- filtering possible, unlike the single-level scheme this replaces.
--
-- Public API
-- ----------
--   VirtualPath.ROOT_SEGMENT, .NULL_TOKEN         -- for logs/diagnostics
--   VirtualPath.isVirtual(path)
--   VirtualPath.getBaseDir(path)                -- real dir; base_dir itself if not virtual
--   VirtualPath.parse(path) -> base_dir, filter_state, active_dimension, level
--       level is "root" | "dim_list" | "file_list" | nil (not virtual)
--   VirtualPath.buildRoot(base_dir)
--   VirtualPath.buildDimList(base_dir, filter_state, dimension)
--   VirtualPath.buildLeaf(base_dir, filter_state, dimension, value)
--   VirtualPath.buildParent(base_dir, filter_state)   -- path one level up
--   VirtualPath.parentOf(path)                  -- path one level up, from any virtual path
--   VirtualPath.displayValue(value)             -- for titles/breadcrumbs

local util        = require("util")
local _           = require("infra/sui_i18n").translate
local FilterState  = require("features/library/sui_filter_state")

local VirtualPath = {}

-- Dot-prefixed so it reads like a hidden folder if it ever leaks into a UI
-- surface that doesn't know about it. Astronomically unlikely to collide
-- with a real directory name.
VirtualPath.ROOT_SEGMENT = ".simpleui-browse"

-- A value segment always starts with this sigil; dimension keywords never
-- do, which is what keeps parsing unambiguous (see file header).
local VALUE_PREFIX = "="
VirtualPath.NULL_TOKEN = VALUE_PREFIX -- "=" alone: the "no value" bucket

local VROOT_SEP = "/" .. VirtualPath.ROOT_SEGMENT -- pre-built; avoids alloc per lookup

-- Slashes inside a value (e.g. a tag literally containing "/") would be
-- misread as path separators. Encode as %2F (URL-encoding convention,
-- unambiguous, greppable) and decode on the way out.
local function encodeValue(value)
    if value == false or value == nil then return VALUE_PREFIX end
    return VALUE_PREFIX .. (tostring(value):gsub("/", "%%2F"))
end
local function decodeValue(fragment)
    local raw = fragment:sub(#VALUE_PREFIX + 1)
    if raw == "" then return false end
    return (raw:gsub("%%2F", "/"))
end

function VirtualPath.displayValue(value)
    if value == false or value == nil then return _("Uncategorized") end
    return tostring(value)
end

local function findRoot(path)
    if not path then return nil end
    return path:find(VROOT_SEP, 1, true)
end

function VirtualPath.isVirtual(path)
    return findRoot(path) ~= nil
end

function VirtualPath.getBaseDir(path)
    if not path then return path end
    local root_start = findRoot(path)
    if root_start then return path:sub(1, root_start - 1) end
    return path
end

-- Splits the path into its fragments after the root marker.
local function getTail(path)
    local root_start = findRoot(path)
    if not root_start then return nil end
    local tail = path:sub(root_start + 1 + #VirtualPath.ROOT_SEGMENT)
    local fragments = {}
    for part in util.gsplit(tail, "/") do
        if part ~= "" then fragments[#fragments + 1] = part end
    end
    return fragments
end

-- Parses a virtual path into (base_dir, filter_state, active_dimension, level).
-- `active_dimension` is set only at the dim_list level (the dimension whose
-- values are currently being listed). `filter_state.trail` never includes
-- it — only fully-resolved (dimension, value) pairs from earlier segments.
function VirtualPath.parse(path)
    if not findRoot(path) then return nil end

    local base_dir = VirtualPath.getBaseDir(path)
    local fragments = getTail(path) or {}
    local state = FilterState.new(base_dir)

    local pending_dimension = nil
    for _, fragment in ipairs(fragments) do
        if fragment:sub(1, #VALUE_PREFIX) == VALUE_PREFIX then
            if pending_dimension then
                FilterState.addFilter(state, pending_dimension, decodeValue(fragment))
                pending_dimension = nil
            end
            -- A value fragment with no pending dimension is malformed input
            -- (shouldn't happen for paths we generate) — ignored rather than
            -- erroring, keeping parsing forgiving.
        elseif FilterState.isDimension(fragment) then
            pending_dimension = fragment
        end
        -- Any other fragment is ignored — keeps parsing forgiving if a
        -- future version adds new segment kinds.
    end

    local level
    if #fragments == 0 then
        level = "root"
    elseif pending_dimension then
        level = "dim_list"
    else
        level = "file_list"
    end

    return base_dir, state, pending_dimension, level
end

function VirtualPath.buildRoot(base_dir)
    return base_dir .. VROOT_SEP
end

local function buildFromTrail(base_dir, filter_state, trailing_dimension)
    local parts = { base_dir, VirtualPath.ROOT_SEGMENT }
    for _, entry in ipairs(filter_state and filter_state.trail or {}) do
        parts[#parts + 1] = entry.dimension
        parts[#parts + 1] = encodeValue(entry.value)
    end
    if trailing_dimension then
        parts[#parts + 1] = trailing_dimension
    end
    return table.concat(parts, "/")
end

-- Path for "choose a value for `dimension`", given everything already
-- filtered so far in filter_state.
function VirtualPath.buildDimList(base_dir, filter_state, dimension)
    return buildFromTrail(base_dir, filter_state, dimension)
end

-- Path for the leaf reached by adding (dimension, value) to filter_state.
function VirtualPath.buildLeaf(base_dir, filter_state, dimension, value)
    local next_state = FilterState.clone(filter_state or FilterState.new(base_dir))
    FilterState.addFilter(next_state, dimension, value)
    return buildFromTrail(base_dir, next_state, nil)
end

-- Path one level up from the current filter_state (pops the last trail
-- entry). At the top of the trail this returns the dim_list for the first
-- dimension picked, matching the level the user came in through.
function VirtualPath.buildParent(base_dir, filter_state)
    local trail = filter_state and filter_state.trail or {}
    if #trail == 0 then
        return VirtualPath.buildRoot(base_dir)
    end
    if #trail == 1 then
        return VirtualPath.buildDimList(base_dir, nil, trail[1].dimension)
    end

    local parent_state = FilterState.new(base_dir)
    for i = 1, #trail - 1 do
        FilterState.addFilter(parent_state, trail[i].dimension, trail[i].value)
    end
    return buildFromTrail(base_dir, parent_state, nil)
end

-- Path one level up from any virtual path: the base directory above the
-- root, the root above a first-level dim_list, the last resolved leaf above
-- a dim_list within a trail, and buildParent's path above a leaf. nil for a
-- path that is not virtual.
function VirtualPath.parentOf(path)
    local base_dir, state, _dimension, level = VirtualPath.parse(path)
    if not level then return nil end
    if level == "root" then return base_dir end
    if level == "file_list" then return VirtualPath.buildParent(base_dir, state) end
    if #state.trail == 0 then return VirtualPath.buildRoot(base_dir) end
    return buildFromTrail(base_dir, state, nil)
end

return VirtualPath
