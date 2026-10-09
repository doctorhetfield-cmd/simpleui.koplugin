-- sui_filter_state.lua — Simple UI
-- Composable filter trail for library browsing (author / series / tags).
--
-- This is the single source of truth for what a "dimension" is: its SQL
-- column in the bookinfo table, whether a book can have several values for
-- it (authors, tags) or only one (series), and how repeated selections of
-- the same dimension behave (stack with AND, or replace the previous pick).
--
-- A FilterState is a small, cheap-to-clone value object:
--   {
--     base_dir  = "/sdcard/Books",
--     trail     = { {dimension="author", value="Ursula K. Le Guin"}, ... },
--     selected  = { author = { ["Ursula K. Le Guin"] = true }, ... },
--   }
--
-- `trail` is ordered (it *is* the browse path) and drives both the SQL
-- query built by sui_metadata_source and the virtual path encoded by
-- sui_virtual_path. `selected` is a fast lookup used to render checkmarks
-- in facet dropdowns without scanning the trail.
--
-- Public API
-- ----------
--   FilterState.DIMENSIONS          -- canonical per-dimension definitions
--   FilterState.ORDERED_DIMENSIONS  -- display order: author, series, tags
--   FilterState.isDimension(key)
--   FilterState.new(base_dir)
--   FilterState.clone(state)
--   FilterState.addFilter(state, dimension, value)   -- mutates + returns state
--   FilterState.withoutDimension(state, dimension)   -- returns a new state
--   FilterState.isEmpty(state)
--   FilterState.parseSeries(raw)                     -- name, suffix index
--   FilterState.seriesKey(name)                      -- comparison key
--   FilterState.matcher(trail)                       -- row predicate
--   FilterState.eachFacetValue(row, definition, fn)  -- fn(key, value)

local FilterState = {}

local util = require("util")

-- ---------------------------------------------------------------------------
-- Series names
-- ---------------------------------------------------------------------------

-- Engine placeholder that sorts books without a series last.
local NO_SERIES_PLACEHOLDER = "\u{FFFF}"

-- Splits a raw series string into a normalized name and the index carried by
-- a trailing " #n" suffix. Whitespace is trimmed and collapsed; an empty
-- name (or the placeholder) means "no series" and returns nil.
function FilterState.parseSeries(raw)
    if type(raw) ~= "string" or raw == NO_SERIES_PLACEHOLDER then return nil end
    raw = raw:gsub("\u{00A0}", " ")
    local name, suffix = raw:match("^(.-)%s+#(%d+)%s*$")
    name = (name or raw):gsub("%s+", " ")
    name = name:match("^ *(.-) *$")
    if name == "" then return nil end
    return name, tonumber(suffix)
end

-- Unicode-aware lowercasing: the core helper when available, otherwise the
-- utf8 library wrapper, otherwise plain Lua lowercasing.
local function _resolveLower()
    if type(util.stringLower) == "function" then return util.stringLower end
    local ok, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok and type(Utf8Proc.lowercase) == "function" then return Utf8Proc.lowercase end
    return string.lower
end
local _lower = _resolveLower()

-- Comparison key: two names denote the same series when their keys match.
function FilterState.seriesKey(name)
    return name and _lower(name)
end

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

-- Dimension fields:
--   column      the bookinfo column, and the field name on resolved rows.
--   multi_value one row can carry several "\n"-separated values.
--   repeat_mode how repeated picks combine (see FilterState.addFilter).
--   key_column  (optional) row field holding the comparison key of the
--               value; values are matched and grouped by key, and the
--               displayed spelling is the first one seen.
--   key         (optional) function producing that key from a value.
--
-- value == false means "no value for this dimension" (e.g. books with no
-- series). It is a valid, filterable state — not "no filter".
FilterState.DIMENSIONS = {
    author = {
        column      = "authors",
        multi_value = true,
        -- "and": picking a second author narrows further (co-authored books).
        repeat_mode = "and",
    },
    series = {
        column      = "series",
        multi_value = false,
        -- "once": a book has exactly one series; a new pick replaces the old one.
        repeat_mode = "once",
        key_column  = "series_key",
        key         = FilterState.seriesKey,
    },
    tags = {
        column      = "keywords",
        multi_value = true,
        repeat_mode = "and",
    },
}

FilterState.ORDERED_DIMENSIONS = { "author", "series", "tags" }

function FilterState.isDimension(dimension)
    return FilterState.DIMENSIONS[dimension] ~= nil
end

function FilterState.new(base_dir)
    return {
        base_dir = base_dir,
        trail    = {},
        selected = {},
    }
end

function FilterState.clone(state)
    local clone = FilterState.new(state and state.base_dir)
    if not state then return clone end

    for i, entry in ipairs(state.trail or {}) do
        clone.trail[i] = { dimension = entry.dimension, value = entry.value }
    end
    for dimension, values in pairs(state.selected or {}) do
        local copy = {}
        for value, is_selected in pairs(values) do copy[value] = is_selected end
        clone.selected[dimension] = copy
    end
    return clone
end

function FilterState.isEmpty(state)
    return not state or #state.trail == 0
end

-- Adds `value` under `dimension`, honouring repeat_mode:
--   "once"  — replaces any existing selection for this dimension.
--   "and"   — stacks with previous selections (duplicate values are no-ops).
-- Mutates and returns `state` for convenient chaining.
function FilterState.addFilter(state, dimension, value)
    if not state or not FilterState.isDimension(dimension) then
        return state
    end

    local definition = FilterState.DIMENSIONS[dimension]

    if definition.repeat_mode == "once" then
        local next_trail = {}
        for _, entry in ipairs(state.trail) do
            if entry.dimension ~= dimension then
                next_trail[#next_trail + 1] = entry
            end
        end
        state.trail = next_trail
        state.selected[dimension] = nil
    end

    local selected = state.selected[dimension]
    if not selected then
        selected = {}
        state.selected[dimension] = selected
    end
    if selected[value] then
        return state -- already filtering on this exact value
    end

    state.trail[#state.trail + 1] = { dimension = dimension, value = value }
    selected[value] = true
    return state
end

-- Returns a NEW state with every trail entry for `dimension` removed.
-- Used when re-opening a facet dropdown to compute "what would the counts
-- be if I hadn't already filtered on this dimension" (so the dropdown can
-- show every value, not just the ones compatible with the current pick).
function FilterState.withoutDimension(state, dimension)
    local clone = FilterState.new(state and state.base_dir)
    if not state then return clone end

    for _, entry in ipairs(state.trail or {}) do
        if entry.dimension ~= dimension then
            FilterState.addFilter(clone, entry.dimension, entry.value)
        end
    end
    return clone
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

local function buildTest(definition, value)
    local column = definition.column
    if value == false then
        return function(row) return row[column] == nil end
    end
    if definition.multi_value then
        local needle = "\n" .. value .. "\n"
        return function(row)
            local raw = row[column]
            return raw ~= nil and ("\n" .. raw .. "\n"):find(needle, 1, true) ~= nil
        end
    end
    local key_column = definition.key_column or column
    local target = definition.key and definition.key(value) or value
    return function(row) return row[key_column] == target end
end

-- Returns a predicate telling whether a resolved row satisfies every entry
-- of `trail`.
function FilterState.matcher(trail)
    local tests = {}
    for _, entry in ipairs(trail or {}) do
        tests[#tests + 1] = buildTest(FilterState.DIMENSIONS[entry.dimension], entry.value)
    end
    return function(row)
        for i = 1, #tests do
            if not tests[i](row) then return false end
        end
        return true
    end
end

-- Calls fn(key, value) once per facet value `row` contributes to
-- `definition`: every token of a multi-value field, the single value
-- otherwise, or (false, false) when the row has none. `key` identifies the
-- group the value belongs to; `value` is how it is spelled on this row.
function FilterState.eachFacetValue(row, definition, fn)
    local raw = row[definition.column]
    if raw == nil then
        fn(false, false)
    elseif definition.multi_value then
        for token in raw:gmatch("[^\n]+") do fn(token, token) end
    else
        fn(row[definition.key_column or definition.column], raw)
    end
end

return FilterState
