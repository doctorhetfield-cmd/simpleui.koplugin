-- sui_heatmap_data.lua — Simple UI
-- Reading-heatmap data layer: daily seconds (from the stats ledger,
-- infra/sui_stats_ledger) and weekday x hour-of-day seconds (one aggregate
-- over page_stat_data), plus the day arithmetic needed to slice that data into
-- "N-week blocks" for paging back through history. No widgets here — this file
-- only knows about numbers and timestamps; engines/sui_heatmap_widgets.lua
-- turns them into pixels.
--
-- The base table is read, not the page_stat view, so the start_time index
-- bounds every scan; durations are the recorded ones, as on the homescreen.

local Config = require("infra/sui_config")
local Ledger = require("infra/sui_stats_ledger")

local HD = {}

-- ---------------------------------------------------------------------------
-- DB access
-- ---------------------------------------------------------------------------
-- Runs `sql`, calling row_fn(row) for every returned row. Uses shared_conn
-- when given (the homescreen's own ctx.db_conn — no new connection opened);
-- otherwise opens and closes a short-lived one via Config.openStatsDB(),
-- same as the standalone stats windows in screens/sui_stats_windows.lua.
-- Returns true/false plus the pcall error (for Config.isFatalDbError) on
-- failure.
local function runQuery(shared_conn, sql, row_fn)
    local function exec(conn)
        local stmt = conn:prepare(sql)
        for row in stmt:rows() do row_fn(row) end
        stmt:close()
    end
    if shared_conn then
        local ok, err = pcall(exec, shared_conn)
        return ok, err
    end
    local conn = Config.openStatsDB()
    if not conn then return false, "no_db" end
    local ok, err = pcall(exec, conn)
    pcall(conn.close, conn)
    return ok, err
end

-- Epoch bounds [lo, hi) of the local days start_t..end_t.
local function dayBounds(start_t, end_t)
    local s, e = os.date("*t", start_t), os.date("*t", end_t)
    local lo = os.time{ year = s.year, month = s.month, day = s.day, hour = 0 }
    local hi = os.time{ year = e.year, month = e.month, day = e.day + 1, hour = 0 }
    return lo, hi
end

-- ---------------------------------------------------------------------------
-- Cache — the weekday x hour map per exact [start,end] range, valid for one day
-- and while the statistics database is unchanged. (The daily seconds need none:
-- the ledger keeps and validates them.)
-- ---------------------------------------------------------------------------
local _cache = { weekday_hour = {} }

function HD.invalidate()
    _cache.weekday_hour = {}
end

-- ---------------------------------------------------------------------------
-- Range arithmetic
-- ---------------------------------------------------------------------------
-- Inclusive [start_t, end_t] (both at noon, clear of DST edge cases) for the
-- block of `weeks` weeks that is `blocks_back` blocks before the current
-- one: block 0 ends today and starts (weeks*7 - 1) days earlier; block 1
-- covers the same span immediately before block 0, and so on. Relies on
-- os.time's normalisation of out-of-range day values, the same trick used
-- for month arithmetic elsewhere in this codebase's date handling.
function HD.getWeekBlockRange(weeks, blocks_back)
    weeks       = weeks or 12
    blocks_back = blocks_back or 0
    local today = os.date("*t")
    local end_t = os.time({
        year = today.year, month = today.month,
        day  = today.day - (weeks * 7) * blocks_back,
        hour = 12,
    })
    local start_t = os.time({
        year = today.year, month = today.month,
        day  = today.day - (weeks * 7) * (blocks_back + 1) + 1,
        hour = 12,
    })
    return start_t, end_t
end

-- How many blocks back from the current one (0) still reach into a period
-- with recorded reading (earliest_t, from HD.getEarliestStartTime). Small
-- loop rather than closed-form maths, to stay in lockstep with
-- HD.getWeekBlockRange's own definition of a block boundary.
function HD.maxBlocksBack(weeks, earliest_t)
    if not earliest_t or earliest_t <= 0 then return 0 end
    local blocks_back = 0
    while blocks_back < 500 do
        local _, block_end = HD.getWeekBlockRange(weeks, blocks_back + 1)
        if block_end < earliest_t then break end
        blocks_back = blocks_back + 1
    end
    return blocks_back
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------
-- Returns { ["YYYY-MM-DD"] = seconds_read } for every day with any reading
-- in the inclusive [start_t, end_t] range.
function HD.getDailyReadingData(start_t, end_t, shared_conn)
    local ledger, err = Ledger.get(shared_conn)
    if not ledger then return {}, Config.isFatalDbError(err) end
    return ledger:dailySeconds(os.date("%Y-%m-%d", start_t), os.date("%Y-%m-%d", end_t)), false
end

-- Returns { [1..7] = { [0..23] = seconds_read } }, 1 = Monday, for the
-- inclusive [start_t, end_t] range.
function HD.getWeekdayHourReadingData(start_t, end_t, shared_conn)
    local start_str = os.date("%Y-%m-%d", start_t)
    local end_str   = os.date("%Y-%m-%d", end_t)
    local today     = os.date("%Y-%m-%d")
    local cache_key = start_str .. ".." .. end_str
    local stamp     = Config.getStatsDbStamp()
    local lo, hi    = dayBounds(start_t, end_t)

    local hit = _cache.weekday_hour[cache_key]
    if hit and hit.day == today and stamp and hit.stamp == stamp then return hit.data end

    local sql = string.format([[
        SELECT strftime('%%w', start_time, 'unixepoch', 'localtime') AS dow,
               CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER) AS hour,
               SUM(duration)
        FROM page_stat_data
        WHERE start_time >= %d AND start_time < %d
        GROUP BY dow, hour
    ]], lo, hi)

    local data = {}
    for wd = 1, 7 do
        data[wd] = {}
        for h = 0, 23 do data[wd][h] = 0 end
    end

    local ok, err = runQuery(shared_conn, sql, function(row)
        local dow_sun0 = tonumber(row[1]) or 0   -- 0=Sun..6=Sat
        local wd       = ((dow_sun0 + 6) % 7) + 1  -- 1=Mon..7=Sun
        local hour     = tonumber(row[2]) or 0
        data[wd][hour] = tonumber(row[3]) or 0
    end)
    if not ok then
        return data, Config.isFatalDbError(err)
    end

    if stamp then _cache.weekday_hour[cache_key] = { day = today, stamp = stamp, data = data } end
    return data, false
end

-- Weeks of history behind the hour-of-day chart and its peak hour.
HD.HOUR_CHART_WEEKS = 13

-- Weeks of daily history behind the calendar heatmap and the week and month bars.
HD.HEAT_WEEKS = 26

-- Sums a weekday x hour map (as returned above) over the weekdays. Returns
-- { [1..24] = seconds_read } (hour 0 first) and the hour (0-23) with the most
-- reading, nil when there is none.
function HD.hourTotals(weekday_hour_map)
    local hours, peak_hour, peak_secs = {}, nil, 0
    for h = 0, 23 do
        local secs = 0
        for wd = 1, 7 do
            secs = secs + (weekday_hour_map[wd] and weekday_hour_map[wd][h] or 0)
        end
        hours[h + 1] = secs
        if secs > peak_secs then peak_hour, peak_secs = h, secs end
    end
    return hours, peak_hour
end

-- Sums a weekday x hour map (as returned above) over the hours. Returns
-- { [1..7] = seconds_read } (1 = Monday) and the weekday (1-7) with the most
-- reading, the first on a tie, nil when there is none.
function HD.weekdayTotals(weekday_hour_map)
    local days, peak_day, peak_secs = {}, nil, 0
    for wd = 1, 7 do
        local secs = 0
        local hours = weekday_hour_map[wd]
        if hours then
            for h = 0, 23 do secs = secs + (hours[h] or 0) end
        end
        days[wd] = secs
        if secs > peak_secs then peak_day, peak_secs = wd, secs end
    end
    return days, peak_day
end

-- Sums a { ["YYYY-MM-DD"] = seconds_read } map (as returned by
-- getDailyReadingData) per month of `year`. Returns { [1..12] = seconds_read };
-- days of other years and malformed keys are ignored.
function HD.monthTotals(daily, year)
    local months = {}
    for m = 1, 12 do months[m] = 0 end
    for day, secs in pairs(daily) do
        local y, m = day:match("^(%d+)-(%d+)-%d+$")
        if tonumber(y) == year and months[tonumber(m)] then
            months[tonumber(m)] = months[tonumber(m)] + secs
        end
    end
    return months
end

-- Hours (0-23) of each part of the day, in display order.
HD.PART_HOURS = { { 6, 11 }, { 12, 17 }, { 18, 23 }, { 0, 5 } }

-- Sums an hours array (as returned by hourTotals) per part of the day. Returns
-- { [1..4] = seconds_read } (morning, afternoon, evening, night) and the part
-- with the most reading, the first on a tie, nil when there is none.
function HD.dayPartTotals(hours)
    local parts, peak_part, peak_secs = {}, nil, 0
    for i, range in ipairs(HD.PART_HOURS) do
        local secs = 0
        for h = range[1], range[2] do secs = secs + (hours[h + 1] or 0) end
        parts[i] = secs
        if secs > peak_secs then peak_part, peak_secs = i, secs end
    end
    return parts, peak_part
end

-- Noon-anchored time `offset` days from `base_t` (clear of DST edges).
local function dayAt(base_t, offset)
    local t = os.date("*t", base_t)
    return os.time{ year = t.year, month = t.month, day = t.day + offset, hour = 12 }
end

-- Row of a time in a Monday-first week (1 = Monday).
local function weekdayRow(t)
    return (os.date("*t", t).wday - 2) % 7 + 1
end

-- Seconds read per day of the week that is `week_offset` weeks from the one
-- holding `now_t` (0 = this one, -1 = the one before). Returns { [1..7] },
-- Monday first.
function HD.weekValues(daily, now_t, week_offset)
    local monday = dayAt(now_t, 7 * (week_offset or 0) - (weekdayRow(now_t) - 1))
    local values = {}
    for i = 1, 7 do values[i] = daily[os.date("%Y-%m-%d", dayAt(monday, i - 1))] or 0 end
    return values
end

-- Seconds read on each of the `n` days ending with the day of `now_t`, oldest
-- first.
function HD.lastDays(daily, n, now_t)
    local values = {}
    for i = 1, n do values[i] = daily[os.date("%Y-%m-%d", dayAt(now_t, i - n))] or 0 end
    return values
end

-- Seconds read on each day of a month, { [1..days in the month] }.
function HD.monthDays(daily, year, month)
    local count = os.date("*t", os.time{ year = year, month = month + 1, day = 0, hour = 12 }).day
    local values = {}
    for d = 1, count do values[d] = daily[string.format("%04d-%02d-%02d", year, month, d)] or 0 end
    return values
end

-- Intensity of each value: 0 for none, 1-4 by the quartile of the non-zero
-- values it falls in. Returns an array parallel to `values`.
function HD.levels(values)
    local sorted = {}
    for _, v in ipairs(values) do
        if v > 0 then sorted[#sorted + 1] = v end
    end
    table.sort(sorted)
    local function quartile(p) return sorted[math.max(1, math.ceil(#sorted * p))] or 0 end
    local q1, q2, q3 = quartile(0.25), quartile(0.5), quartile(0.75)
    local levels = {}
    for i, v in ipairs(values) do
        if v <= 0 then levels[i] = 0
        elseif v <= q1 then levels[i] = 1
        elseif v <= q2 then levels[i] = 2
        elseif v <= q3 then levels[i] = 3
        else levels[i] = 4 end
    end
    return levels
end

-- Calendar grid of the last `cols` weeks up to the week of `now_t`: returns
-- { levels = { [col][row] = 0-4, or false after today }, today_col, today_row,
-- days_read }. Columns are weeks (oldest first), rows weekdays (Monday first).
function HD.heatGrid(daily, cols, now_t)
    local today_row = weekdayRow(now_t)
    local flat, slots = {}, {}
    for col = 1, cols do
        for row = 1, 7 do
            local offset = -((cols - col) * 7 + (today_row - row))
            if offset <= 0 then
                flat[#flat + 1] = daily[os.date("%Y-%m-%d", dayAt(now_t, offset))] or 0
                slots[#slots + 1] = { col, row }
            end
        end
    end
    local levels = HD.levels(flat)
    local grid = { levels = {}, today_col = cols, today_row = today_row, days_read = 0 }
    for col = 1, cols do
        grid.levels[col] = {}
        for row = 1, 7 do grid.levels[col][row] = false end
    end
    for i, slot in ipairs(slots) do
        grid.levels[slot[1]][slot[2]] = levels[i]
        if flat[i] > 0 then grid.days_read = grid.days_read + 1 end
    end
    return grid
end

-- Change of the first `upto` days of `current` against the same days of
-- `previous`, in whole percent. Nil when `previous` has no reading there.
function HD.weekDelta(current, previous, upto)
    local cur, prev = 0, 0
    for i = 1, upto do
        cur, prev = cur + (current[i] or 0), prev + (previous[i] or 0)
    end
    if prev <= 0 then return nil end
    return math.floor((cur - prev) / prev * 100 + 0.5)
end

-- Cheap "did anything change" probe (single MAX(start_time) read) for
-- callers that want to skip a re-query when nothing new was read.
function HD.getMaxStartTime(shared_conn)
    local max_t = 0
    runQuery(shared_conn, "SELECT MAX(start_time) FROM page_stat_data", function(row)
        max_t = tonumber(row[1]) or 0
    end)
    return max_t
end

-- Epoch seconds of the very first reading row, or 0 if none.
function HD.getEarliestStartTime(shared_conn)
    local t = 0
    runQuery(shared_conn, "SELECT MIN(start_time) FROM page_stat_data", function(row)
        t = tonumber(row[1]) or 0
    end)
    return t
end

return HD
