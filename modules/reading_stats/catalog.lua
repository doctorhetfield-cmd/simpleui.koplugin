-- catalog.lua — Simple UI (Reading Stats)
-- Pure catalog of the Reading Stats module: no UI, no strings, no settings.
--
--   Catalog.GROUPS                     ordered { { key=, ids= }, ... }
--   Catalog.CHART                      stat id -> chart kind drawn on detailed cards
--   Catalog.ids()                      every stat id, in group order
--   Catalog.usesCharts(stat_id, mode)  true when the stat reads the chart data
--   Catalog.usesYear(stat_id, mode)    true when the stat reads the year data
--   Catalog.migrateItems(items, spans) -> items', spans' | nil
--   Catalog.items(saved, spans)        -> items, spans' | nil: the stats a stored
--                                         list stands for
--   Catalog.highlightTone(stored, card_tone, on_screen) -> tone of a highlighted card
--
-- `mode` is the card style ("cards", "detailed" or "list"). Inputs are never
-- mutated.

local Catalog = {}

Catalog.GROUPS = {
    { key = "time",   ids = { "today_time", "week_time", "month_time", "year_time", "avg_time", "total_time" } },
    { key = "pages",  ids = { "today_pages", "week_pages", "month_pages", "avg_pages", "pages_total" } },
    { key = "books",  ids = { "total_books", "status_reading", "status_unread", "status_abandoned" } },
    { key = "habits", ids = { "streak", "activity_map", "hours_chart", "peak_weekday", "day_parts",
                              "week_compare", "sessions", "session_longest", "session_avg",
                              "pages_per_hour" } },
}

Catalog.CHART = {
    week_time   = "week",
    month_time  = "month",
    hours_chart = "hours",
    peak_weekday = "weekdays",
    year_time   = "year",
    streak      = "streak_dots",
    activity_map = "heatmap",
    week_compare = "week_vs",
    pages_total = "odometer",
    day_parts   = "dayparts",
}

-- Stats whose value is drawn from the chart data in every card style.
local CHART_VALUE = {
    hours_chart = true, peak_weekday = true, activity_map = true, week_compare = true, day_parts = true,
}

function Catalog.ids()
    local ids = {}
    for _, group in ipairs(Catalog.GROUPS) do
        for _, id in ipairs(group.ids) do ids[#ids + 1] = id end
    end
    return ids
end

-- The stats of CHART_VALUE draw text from the chart data in every style; the
-- week and month bars only exist on detailed cards.
function Catalog.usesCharts(stat_id, mode)
    if CHART_VALUE[stat_id] then return true end
    return (stat_id == "week_time" or stat_id == "month_time") and mode == "detailed"
end

-- The monthly bars of the year are the only reader of the year data.
function Catalog.usesYear(stat_id, mode)
    return stat_id == "year_time" and mode == "detailed"
end

-- Stat removed from the catalog -> the one that replaced it.
local RENAMED = { week_chart = "week_time" }

-- Moves a removed stat id to its replacement, in `items` and `spans`. Returns
-- nil when `items` has no removed id.
function Catalog.migrateItems(items, spans)
    local found = false
    for _, id in ipairs(items) do
        if RENAMED[id] then found = true end
    end
    if not found then return nil end

    local out, seen = {}, {}
    for _, id in ipairs(items) do
        id = RENAMED[id] or id
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end

    local out_spans = {}
    for id, span in pairs(spans or {}) do out_spans[id] = span end
    for old, new in pairs(RENAMED) do
        local span = out_spans[old]
        out_spans[old] = nil
        if span then out_spans[new] = math.max(span, out_spans[new] or 1) end
    end
    return out, out_spans
end

-- Stats of a fresh install.
local DEFAULT_ITEMS = { "total_books", "today_time", "streak" }

-- The stats a stored list `saved` stands for: the defaults when nothing was
-- stored, the list itself otherwise (an empty list stays empty), migrated when
-- it holds a removed stat. The migrated spans come second, nil when nothing was
-- migrated.
function Catalog.items(saved, spans)
    if type(saved) ~= "table" then
        local items = {}
        for i, id in ipairs(DEFAULT_ITEMS) do items[i] = id end
        return items
    end
    local items, migrated_spans = Catalog.migrateItems(saved, spans)
    if items then return items, migrated_spans end
    local copy = {}
    for i, id in ipairs(saved) do copy[i] = id end
    return copy
end

-- Tone of a highlighted card: black, gray, or a palette colour. `stored` is the
-- chosen tone (nil: none), `card_tone` the tone of the card fill and `on_screen`
-- tells which palette tones are set ({ accent = bool, secondary = bool }). Without
-- a usable choice the accent is taken when set, else black. A tone equal to the
-- card fill gives black, which no card fill can be.
function Catalog.highlightTone(stored, card_tone, on_screen)
    local usable = stored == "black" or stored == "gray" or on_screen[stored] == true
    local tone = usable and stored or (on_screen.accent and "accent" or "black")
    if tone == card_tone then return "black" end
    return tone
end

return Catalog
