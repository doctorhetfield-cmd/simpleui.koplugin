-- sui_stats_ledger.lua — Simple UI
-- Per-day ledger of the statistics database, shared by the Reading Insights,
-- Streak and Reading Heatmap windows (and any other reader of daily history).
--
-- One entry per local calendar day with any reading: seconds read, first and
-- last start time, and the first start time of a row with reading time. Days
-- before today never change, so they live in memory and in a file of their own,
-- and every read validates them against the database with one index-only
-- query (row count and oldest/newest start_time before today). A mismatch (rows
-- deleted, imported or backdated) rebuilds the ledger; a day completed since the
-- last read is appended with one query bounded on the start_time index. Today is
-- always read from the database, so every figure is current.
--
-- A day keeps the label it got when it was recorded, so a later change of the
-- UTC offset moves neither the day nor the streaks built on it. Days labelled
-- again by a rebuild use the current offset: the offset in effect back then is
-- not recorded.
--
-- page_stat_data (the base table) is read, not the page_stat view, so the
-- start_time index bounds every scan.

local logger = require("logger")
local Config = require("infra/sui_config")

local Ledger = {}

local FORMAT = 1

-- state: { through, count, min_t, max_t, days = {entry...}, by_day = {}, pages = {} }
--   through  local midnight; the state holds every day that started before it
--   count / min_t / max_t  signature of the rows with start_time < through
--   pages    year -> { n, books }: distinct pages of a completed year
local _state
local _loaded = false
local _path_override

--- Points the ledger file somewhere else and drops the in-memory state.
function Ledger.setPath(path)
    _path_override = path
    _state, _loaded = nil, false
end

local function storePath()
    if _path_override then return _path_override end
    return require("datastorage"):getSettingsDir() .. "/simpleui/sui_stats_ledger.lua"
end

local function openStore()
    return require("luasettings"):open(storePath())
end

local function loadState()
    _loaded = true
    local ok, data = pcall(function() return openStore():readSetting("ledger") end)
    if not ok or type(data) ~= "table" or data.format ~= FORMAT or type(data.days) ~= "table"
       or type(data.through) ~= "number" or type(data.count) ~= "number"
       or type(data.min_t) ~= "number" or type(data.max_t) ~= "number" then
        return nil
    end
    local state = {
        through = data.through, count = data.count, min_t = data.min_t, max_t = data.max_t,
        days = {}, by_day = {}, pages = type(data.pages) == "table" and data.pages or {},
    }
    for i, row in ipairs(data.days) do
        local entry = {
            day = row[1], secs = row[2], first = row[3], last = row[4],
            first_active = row[5] > 0 and row[5] or nil,
        }
        state.days[i] = entry
        state.by_day[entry.day] = entry
    end
    return state
end

local function saveState(state)
    local rows = {}
    for i, e in ipairs(state.days) do
        rows[i] = { e.day, e.secs, e.first, e.last, e.first_active or 0 }
    end
    local ok, err = pcall(function()
        local store = openStore()
        store:saveSetting("ledger", {
            format = FORMAT, through = state.through, count = state.count,
            min_t = state.min_t, max_t = state.max_t, days = rows, pages = state.pages,
        })
        store:flush()
    end)
    if not ok then logger.warn("simpleui: stats_ledger: save failed: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
local function query(conn, sql, row_fn)
    local stmt = conn:prepare(sql)
    for row in stmt:rows() do row_fn(row) end
    stmt:close()
end

-- Local midnight of today.
local function todayStart()
    local t = os.date("*t")
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
end

-- Row count and oldest/newest start_time of the rows before `before`.
local function prefixSignature(conn, before)
    local count, min_t, max_t = 0, 0, 0
    query(conn, string.format([[
        SELECT COUNT(*), COALESCE(MIN(start_time), 0), COALESCE(MAX(start_time), 0)
        FROM page_stat_data WHERE start_time < %d
    ]], before), function(row)
        count, min_t, max_t = tonumber(row[1]) or 0, tonumber(row[2]) or 0, tonumber(row[3]) or 0
    end)
    return count, min_t, max_t
end

-- Entries (with their row count in `n`) of the days of the rows from `lo` on,
-- up to `hi` (exclusive) when given, oldest first.
local function fetchDays(conn, lo, hi)
    local days = {}
    query(conn, string.format([[
        SELECT date(start_time, 'unixepoch', 'localtime') AS d,
               SUM(duration), MIN(start_time), MAX(start_time),
               MIN(CASE WHEN duration > 0 THEN start_time END), COUNT(*)
        FROM page_stat_data
        WHERE start_time >= %d%s
        GROUP BY d ORDER BY d
    ]], lo, hi and string.format(" AND start_time < %d", hi) or ""), function(row)
        days[#days + 1] = {
            day = row[1], secs = tonumber(row[2]) or 0,
            first = tonumber(row[3]), last = tonumber(row[4]),
            first_active = tonumber(row[5]), n = tonumber(row[6]) or 0,
        }
    end)
    return days
end

-- Adds the reading of `e` to the entry `into` of the same day.
local function mergeEntry(into, e)
    into.secs = into.secs + e.secs
    into.first = math.min(into.first, e.first)
    into.last = math.max(into.last, e.last)
    if e.first_active and (not into.first_active or e.first_active < into.first_active) then
        into.first_active = e.first_active
    end
end

-- Brings the state up to today's midnight, validating what it already holds.
-- A state past today's midnight but not past now comes from a UTC offset that
-- moved forward, and is kept as labelled; one past now is discarded.
local function sync(conn, today_start)
    if not _loaded then _state = loadState() end
    local state = _state
    if state and state.through > os.time() then state = nil end
    if state then
        local count, min_t, max_t = prefixSignature(conn, state.through)
        if count ~= state.count or min_t ~= state.min_t or max_t ~= state.max_t then state = nil end
    end
    if state and state.through >= today_start then return state end

    state = state or { through = 0, count = 0, min_t = 0, max_t = 0, days = {}, by_day = {}, pages = {} }
    for _, e in ipairs(fetchDays(conn, state.through, today_start)) do
        state.count = state.count + e.n
        if state.min_t == 0 or e.first < state.min_t then state.min_t = e.first end
        if e.last > state.max_t then state.max_t = e.last end
        e.n = nil
        -- After an offset moved back, the first new rows may share the last day.
        local prev = state.by_day[e.day]
        if prev then
            mergeEntry(prev, e)
        else
            state.days[#state.days + 1] = e
            state.by_day[e.day] = e
        end
    end
    state.through = today_start
    _state = state
    saveState(state)
    return state
end

-- Runs fn(conn) on `conn`, or on a short-lived connection when it is nil.
-- Returns fn's result, or nil plus the error.
local function withConn(conn, fn)
    local own
    if not conn then
        conn = Config.openStatsDB()
        if not conn then return nil, "no_db" end
        own = true
    end
    local ok, result = pcall(fn, conn)
    if own then pcall(conn.close, conn) end
    if not ok then
        logger.warn("simpleui: stats_ledger: " .. tostring(result))
        return nil, result
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------
local Snapshot = {}
Snapshot.__index = Snapshot

local _current_pages   -- memo of the pages of the current year

--- Snapshot of the ledger: every completed day plus today as the database holds
--- them now. Uses `conn` when given, otherwise opens its own. Returns nil plus
--- the error when the database cannot be read.
---   snapshot.list   entries, oldest first: { day, secs, first, last, first_active }
---   snapshot.token  changes whenever any reading is added, removed or changed
function Ledger.get(conn)
    return withConn(conn, function(c)
        local state = sync(c, todayStart())
        local live = fetchDays(c, state.through)
        local list = {}
        for i, e in ipairs(state.days) do list[i] = e end
        local live_n, live_max = 0, 0
        for i, e in ipairs(live) do
            live_n = live_n + e.n
            live_max = math.max(live_max, e.last)
            local prev = list[#list]
            if prev and prev.day == e.day then
                -- The offset moved since the last completed day was recorded:
                -- combine both parts of the day without touching the state.
                local merged = { day = prev.day, secs = prev.secs, first = prev.first,
                                 last = prev.last, first_active = prev.first_active }
                mergeEntry(merged, e)
                live[i], list[#list] = merged, merged
            else
                list[#list + 1] = e
            end
        end
        return setmetatable({
            list = list, state = state, live = live,
            token = string.format("%d:%d:%d|%d:%d", state.count, state.min_t, state.max_t, live_n, live_max),
        }, Snapshot)
    end)
end

--- The entry of "YYYY-MM-DD", or nil when there was no reading that day.
function Snapshot:entry(day)
    for _, e in ipairs(self.live) do
        if e.day == day then return e end
    end
    return self.state.by_day[day]
end

--- First and last year with reading, nil without any.
function Snapshot:yearRange()
    local list = self.list
    if #list == 0 then return nil end
    return tonumber(list[1].day:sub(1, 4)), tonumber(list[#list].day:sub(1, 4))
end

--- { ["YYYY-MM-DD"] = seconds } for the days from `from_day` to `to_day`
--- (inclusive) that have any reading.
function Snapshot:dailySeconds(from_day, to_day)
    local out, list = {}, self.list
    for i = #list, 1, -1 do
        local e = list[i]
        if e.day < from_day then break end
        if e.day <= to_day then out[e.day] = e.secs end
    end
    return out
end

--- Days with reading and seconds read in `year`.
function Snapshot:yearTotals(year)
    local prefix, days, secs = string.format("%04d-", year), 0, 0
    for _, e in ipairs(self.list) do
        if e.day:sub(1, 5) == prefix then days, secs = days + 1, secs + e.secs end
    end
    return days, secs
end

--- { [1..12] = { days, secs } } for the months of `year`.
function Snapshot:monthTotals(year)
    local months = {}
    for m = 1, 12 do months[m] = { days = 0, secs = 0 } end
    for _, e in ipairs(self.list) do
        if tonumber(e.day:sub(1, 4)) == year then
            local month = months[tonumber(e.day:sub(6, 7))]
            month.days, month.secs = month.days + 1, month.secs + e.secs
        end
    end
    return months
end

--- Seconds read in all of history.
function Snapshot:totalSeconds()
    local secs = 0
    for _, e in ipairs(self.list) do secs = secs + e.secs end
    return secs
end

--- Days with reading time, newest first: { { day, first_start_time }, ... }.
function Snapshot:activeDates()
    local dates, list = {}, self.list
    for i = #list, 1, -1 do
        if list[i].first_active then dates[#dates + 1] = { list[i].day, list[i].first_active } end
    end
    return dates
end

--- ISO weeks with reading, newest first: { { first_start_time, last_start_time }, ... }.
function Snapshot:weeks()
    local weeks, key = {}, nil
    for _, e in ipairs(self.list) do
        local k = os.date("%G-%V", e.first)
        if k == key then
            local week = weeks[#weeks]
            week[2] = math.max(week[2], e.last)
        else
            weeks[#weeks + 1] = { e.first, e.last }
            key = k
        end
    end
    local newest_first = {}
    for i = #weeks, 1, -1 do newest_first[#newest_first + 1] = weeks[i] end
    return newest_first
end

--- Set { ["YYYY-MM-DD"] = true } of the days of a month with reading time.
function Snapshot:activeSet(year, month)
    local set = {}
    for d = 1, 31 do
        local day = string.format("%04d-%02d-%02d", year, month, d)
        local e = self:entry(day)
        if e and e.first_active then set[day] = true end
    end
    return set
end

-- Count and total pages of the books: the page_stat view rescales to them.
local function booksSignature(conn)
    local sig = "0:0"
    query(conn, "SELECT COUNT(*), COALESCE(SUM(pages), 0) FROM book", function(row)
        sig = string.format("%d:%d", tonumber(row[1]) or 0, tonumber(row[2]) or 0)
    end)
    return sig
end

-- Distinct pages read in `year`, counted on the page_stat view (pages rescaled
-- to the books' current page counts). The rows are pre-selected through the
-- start_time index, as in the heatmap queries.
local function countPages(conn, year)
    local lo = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local hi = os.time{ year = year + 1, month = 1, day = 1, hour = 0 }
    local n = 0
    query(conn, string.format([[
        SELECT COUNT(*) FROM (
            SELECT 1 FROM page_stat
            WHERE start_time IN (SELECT start_time FROM page_stat_data
                                 WHERE start_time >= %d AND start_time < %d)
            GROUP BY id_book, page
        )
    ]], lo, hi), function(row) n = tonumber(row[1]) or 0 end)
    return n
end

--- Distinct pages read in `year`. A completed year is counted once and kept with
--- the ledger until the books' page counts change; the current year is counted
--- again whenever any reading changes. `conn` is optional, as in Ledger.get.
--- Returns nil plus the error when the count fails.
function Snapshot:pagesInYear(year, conn)
    return withConn(conn, function(c)
        local books = booksSignature(c)
        if year < tonumber(os.date("%Y")) then
            local hit = self.state.pages[year]
            if hit and hit.books == books then return hit.n end
            local n = countPages(c, year)
            self.state.pages[year] = { n = n, books = books }
            saveState(self.state)
            return n
        end
        local key = self.token .. "|" .. books
        if _current_pages and _current_pages.year == year and _current_pages.key == key then
            return _current_pages.n
        end
        local n = countPages(c, year)
        _current_pages = { year = year, key = key, n = n }
        return n
    end)
end

return Ledger
