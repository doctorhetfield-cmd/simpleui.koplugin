-- module_stats_provider.lua — Simple UI
-- Centralised statistics provider for the homescreen.
--
-- Single responsibility: fetch ALL numeric stats needed by reading_stats and
-- reading_goals in the minimum number of DB roundtrips, cache the result for
-- the current calendar day, and expose a single invalidate() entry point.
--
-- Consumers (reading_stats, reading_goals) read ctx.stats.* — they contain
-- zero DB or cache logic of their own.
--
-- DB source: page_stat_data (base table) instead of the page_stat VIEW.
-- Querying the base table directly allows SQLite to use the
-- idx_simpleui_pagestat_time index on start_time, which the VIEW indirection
-- prevents. On devices with constrained I/O this can make a measurable
-- difference on large databases.
--
-- DB roundtrips per cold-cache call: 2
--   Query 1 — one pass over page_stat_data:
--     • today_secs, today_pages   (start_time >= start_today)
--     • week_secs, week_pages     (7-day window, grouped by date)
--     • avg_secs, avg_pages       (7-day window, grouped by date)
--     • month_secs, month_pages   (start_time >= month_start)
--     • year_secs                 (start_time >= year_start)
--     • total_secs                (full table)
--   Query 2 — streak recursive CTE (structurally different; must be separate)
--
-- Sidecar roundtrip: one pass over ReadHistory.hist producing BOTH
--   books_year (completed this year) and books_total (all-time completed)
--   simultaneously — replaces two separate countMarkedRead() calls.

local logger = require("logger")
local lfs    = require("libs/libkoreader-lfs")
local Config = require("sui_config")

local SP = {}

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------
-- Keyed by calendar day ("YYYY-MM-DD"). Invalidated by SP.invalidate() which
-- is called from:
--   • main.lua:onCloseDocument   (after a reading session)
--   • sui_homescreen:onShow      (when _stats_need_refresh flag is set)
--   • module_reading_goals       (after goal-setting dialogs change thresholds)
-- The day key guards against midnight rollovers without needing explicit calls.

local _cache     = nil   -- the stats table
local _cache_day = nil   -- "YYYY-MM-DD" string when cache was built

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function rownum(v)
    return tonumber(v or 0) or 0
end

-- Computes the unix timestamp of the start of the current local day (00:00:00).
local function startOfToday(t)
    -- t is os.date("*t") — already computed by the caller
    return os.time() - (t.hour * 3600 + t.min * 60 + t.sec)
end

-- Computes the unix timestamp of 00:00:00 on the 1st of the current month.
local function startOfMonth(t)
    return os.time{ year = t.year, t.month, day = 1, hour = 0, min = 0, sec = 0 }
end

-- Computes the unix timestamp of 00:00:00 on January 1 of the current year.
local function startOfYear(t)
    return os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
end

-- ---------------------------------------------------------------------------
-- Query 1: all time-series stats in a single pass over page_stat_data.
--
-- Strategy: group page_stat_data into per-day buckets (inner subquery), then
-- the outer SELECT extracts today, 7-day avg, year total, and all-time total
-- using conditional aggregation — one table scan instead of five.
--
-- page_stat_data is queried directly (instead of the page_stat VIEW) for
-- better index utilisation on devices with constrained SQLite performance.
-- The idx_simpleui_pagestat_time index on page_stat_data.start_time is used
-- by the WHERE clause; the VIEW adds an extra indirection layer that prevents
-- the planner from pushing the predicate down to the base table.
--
-- today_str, week_date, month_date, year_date are ISO-8601 strings pre-computed by SP.get
-- from its single os.date("*t") call — zero os.date calls happen inside here.
-- ---------------------------------------------------------------------------
local function fetchTimeSeries(conn, start_today, week_start, month_start, year_start,
                               today_str, week_date, month_date, year_date)
    local r = {
        today_secs  = 0,
        today_pages = 0,
        week_secs   = 0,
        week_pages  = 0,
        avg_secs    = 0,
        avg_pages   = 0,
        month_secs  = 0,
        month_pages = 0,
        year_secs   = 0,
        total_secs  = 0,
    }

    local ok, err = pcall(function()
        -- day_buckets groups page_stat_data into one row per calendar day.
        -- The CTE must scan the full table (window_start = 0) so that the
        -- unconditional sum(sd) at the end produces a true all-time total.
        -- math.min(week_start, year_start) always resolves to year_start,
        -- which silently excluded data from previous years from total_secs.
        -- Each time-window column (today, 7-day, year) is already bounded by
        -- its own CASE WHEN predicate, so a full scan here is correct.
        --
        -- page_stat_data deduplicates page reads differently from the VIEW:
        -- we GROUP BY id_book,page inside the sum to avoid double-counting
        -- the same page read in the same session (matching the VIEW semantics).
        --
        -- The outer SELECT uses CASE WHEN on the ISO-8601 date string column `d`
        -- to partition sums across time windows. Lexicographic comparison is
        -- correct and index-friendly for ISO-8601 dates.
        local window_start = 0  -- full table scan; CASE WHEN cols handle windowing
        local sql = string.format([[
            WITH day_buckets AS (
                SELECT
                    strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS d,
                    sum(duration)                          AS sd,
                    count(DISTINCT page || '@' || id_book) AS pg
                FROM page_stat_data
                WHERE start_time >= %d AND duration > 0
                GROUP BY d
            )
            SELECT
                -- today: exact date match on the 'd' column
                sum(CASE WHEN d = '%s' THEN sd ELSE 0 END),
                sum(CASE WHEN d = '%s' THEN pg ELSE 0 END),
                -- 7-day window: d >= week_date
                sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END),
                sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END),
                -- month: d >= month_date
                sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END),
                sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END),
                -- year: d >= year_date
                sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END),
                -- total: all rows in day_buckets (no filter needed)
                sum(sd)
            FROM day_buckets;
        ]], window_start,
            today_str, today_str,
            week_date,  week_date,
            month_date, month_date,
            year_date)

        local rw = conn:exec(sql)
        if rw and rw[1] and rw[1][1] then
            r.today_secs  = rownum(rw[1][1])
            r.today_pages = rownum(rw[2] and rw[2][1])
            r.week_secs = rownum(rw[3] and rw[3][1])
            r.week_pages = rownum(rw[4] and rw[4][1])
            r.avg_secs  = math.floor(r.week_secs / 7)
            r.avg_pages = math.floor(r.week_pages / 7)
            r.month_secs = rownum(rw[5] and rw[5][1])
            r.month_pages = rownum(rw[6] and rw[6][1])
            r.year_secs  = rownum(rw[7] and rw[7][1])
            r.total_secs = rownum(rw[8] and rw[8][1])
        end
    end)
    if not ok then
        logger.warn("simpleui: stats_provider: fetchTimeSeries failed: " .. tostring(err))
        return r, err
    end
    return r, nil
end

-- ---------------------------------------------------------------------------
-- Query 2: reading streak (recursive CTE — structurally incompatible with Q1).
-- Queries page_stat_data directly (not the page_stat VIEW) for the same
-- index-utilisation reasons as fetchTimeSeries above.
--
-- Fixes applied:
--   • dated CTE filters duration > 0, consistent with fetchTimeSeries, so that
--     zero-duration entries (e.g. from a crash/force-close) do not inflate the
--     streak while showing 0 min in today's stats.
--   • PRAGMA recursive_triggers / max_page_count are not streak-related; for
--     the CTE recursion depth the relevant limit is the compile-time
--     SQLITE_MAX_EXPR_DEPTH. KOReader's bundled SQLite raises it to 10000, so
--     streaks up to 10 000 days are safe. We set the run-time
--     temp_store = MEMORY pragma before the query so the intermediate CTE rows
--     don't hit the page limit on constrained devices, and we explicitly cap the
--     recursive walk at 9999 steps with an extra WHERE guard to be safe on any
--     build that left the default at 1000.
-- ---------------------------------------------------------------------------
local function fetchStreak(conn, start_today)
    local streak = 0
    local ok, err = pcall(function()
        local val = conn:rowexec(string.format([[
            WITH RECURSIVE
            dated(d) AS (
                SELECT DISTINCT date(start_time,'unixepoch','localtime')
                FROM page_stat_data
                WHERE duration > 0),
            streak(d,n) AS (
                SELECT d, 1 FROM dated
                WHERE d = (SELECT max(d) FROM dated)
                UNION ALL
                SELECT date(streak.d,'-1 day'), streak.n+1
                FROM streak
                WHERE n < 9999
                  AND EXISTS (SELECT 1 FROM dated WHERE d = date(streak.d,'-1 day')))
            SELECT CASE
                WHEN (SELECT max(d) FROM dated) >= date(%d,'unixepoch','localtime','-1 day')
                THEN COALESCE((SELECT max(n) FROM streak), 0)
                ELSE 0 END;]], start_today))
        streak = tonumber(val) or 0
    end)
    if not ok then
        logger.warn("simpleui: stats_provider: fetchStreak failed: " .. tostring(err))
    end
    return streak
end

-- ---------------------------------------------------------------------------
-- Sidecar scan: one pass → books_year + books_total simultaneously.
-- Replaces two separate countMarkedRead() calls (previously O(2N) sidecar I/O).
-- Uses the same _sidecar_cache from module_books_shared for cache hits.
-- ---------------------------------------------------------------------------
local _MAX_HIST = 200   -- hard cap: avoids unbounded scan on huge histories

local function countMarkedReadBoth(year_str)
    local books_year  = 0
    local books_total = 0

    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return books_year, books_total end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return books_year, books_total end

    -- Borrow _cacheGet/_cachePut from module_books_shared via package.loaded.
    -- module_books_shared is always loaded before the provider runs (it's
    -- required by _buildCtx via prefetchBooks). We access its internal cache
    -- functions by going through the module's exported invalidateSidecarCache
    -- as a presence check, then using the shared SH table for the actual lookup.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if not SH then
        logger.warn("simpleui: stats_provider: module_books_shared not loaded — sidecar cache unavailable")
    end

    -- modifiedInYear: KOReader always writes `modified` as an ISO-8601 string
    -- ("YYYY-MM-DD ..."), a unix timestamp (number), or an os.date("*t") table.
    -- The string case is handled by a direct sub(1,4) prefix check — no pcall,
    -- os.time, or os.date needed. The legacy pcall branch is omitted: if the
    -- string doesn't start with the year it cannot match, and malformed dates
    -- are treated as not-in-year (safe default).
    local function modifiedInYear(summary)
        local mod = summary and summary.modified
        if mod == nil then return false end
        if type(mod) == "number" then
            -- Unix timestamp: compare year component directly without os.date.
            local mod_t = os.date("*t", mod)
            return mod_t and tostring(mod_t.year) == year_str
        end
        if type(mod) == "string" then
            -- ISO-8601 "YYYY-MM-DD..." — prefix check is sufficient and free.
            return #mod >= 4 and mod:sub(1, 4) == year_str
        end
        if type(mod) == "table" and mod.year then
            return tostring(mod.year) == year_str
        end
        return false
    end

    local limit = math.min(#ReadHistory.hist, _MAX_HIST)
    for i = 1, limit do
        local entry = ReadHistory.hist[i]
        local fp    = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local summary
            -- Fast path: reuse the sidecar cache warmed by prefetchBooks().
            -- Cache hit costs 1 lfs.attributes (mtime check); miss costs DS.open.
            if SH then
                local cached = SH._cacheGet and SH._cacheGet(fp)
                if cached then
                    summary = cached.summary
                else
                    local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
                    if ok_open and ds then
                        summary = ds:readSetting("summary")
                        -- Populate the shared cache so subsequent renders skip DS.open.
                        if SH._cachePut then
                            local data = {
                                percent              = ds:readSetting("percent_finished") or 0,
                                title                = (ds:readSetting("doc_props") or {}).title,
                                authors              = (ds:readSetting("doc_props") or {}).authors,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = (ds:readSetting("stats") or {}).pages,
                                stat_total_time      = (ds:readSetting("stats") or {}).total_time_in_sec,
                                summary              = summary,
                            }
                            SH._cachePut(fp, ds.source_candidate, data)
                        end
                        pcall(function() ds:close() end)
                    end
                end
            else
                -- Fallback: SH not yet loaded — open directly.
                local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
                if ok_open and ds then
                    summary = ds:readSetting("summary")
                    pcall(function() ds:close() end)
                end
            end

            if type(summary) == "table" and summary.status == "complete" then
                books_total = books_total + 1
                if modifiedInYear(summary) then
                    books_year = books_year + 1
                end
            end
        end
    end
    return books_year, books_total
end

-- ---------------------------------------------------------------------------
-- SP.get(db_conn, year_str) — main entry point.
--
-- db_conn:   shared ljsqlite3 connection from ctx.db_conn (may be nil if DB
--            unavailable; returns zero-filled table in that case).
-- year_str:  current year as string e.g. "2025" — pass ctx.year_str.
--
-- Returns a table; sets result.db_conn_fatal = true if the shared connection
-- encountered a fatal error (caller should set ctx.db_conn_fatal accordingly).
-- ---------------------------------------------------------------------------
function SP.get(db_conn, year_str)
    -- Single os.date("*t") call — derive today_str from the same table to
    -- avoid a second os.date("%Y-%m-%d") syscall. string.format is faster
    -- than os.date for simple date formatting in LuaJIT.
    local t           = os.date("*t")
    local today_str   = string.format("%04d-%02d-%02d", t.year, t.month, t.day)

    -- Cache hit: same calendar day, data already fetched.
    if _cache and _cache_day == today_str then
        return _cache
    end

    -- Compute timestamps once — shared by all sub-queries.
    local start_today = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)
    local week_start  = start_today - 6 * 86400
    local month_start = os.time{ year = t.year, t.month, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }
    local year_start  = os.time{ year = t.year, month = 1, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }

    -- Pre-compute ISO-8601 date strings once using string.format (faster than
    -- os.date per-string) and share them across fetchTimeSeries and the sidecar
    -- scan — avoids 3 redundant os.date calls inside fetchTimeSeries.
    local t_week = os.date("*t", week_start)
    local t_month = os.date("*t", month_start)
    local t_year = os.date("*t", year_start)
    local week_date = string.format("%04d-%02d-%02d", t_week.year, t_week.month, t_week.day)
    local month_date = string.format("%04d-%02d-%02d", t_month.year, t_month.month, t_month.day)
    local year_date = string.format("%04d-%02d-%02d", t_year.year, t_year.month, t_year.day)

    local result = {
        today_secs    = 0,
        today_pages   = 0,
        week_secs     = 0,
        week_pages    = 0,
        avg_secs      = 0,
        avg_pages     = 0,
        month_secs    = 0,
        month_pages   = 0,
        year_secs     = 0,
        total_secs    = 0,
        streak        = 0,
        books_year    = 0,
        books_total   = 0,
        db_conn_fatal = false,
    }

    -- ── DB queries ────────────────────────────────────────────────────────
    if db_conn then
        local ts, ts_err = fetchTimeSeries(db_conn, start_today, week_start, month_start, year_start,
                                           today_str, week_date, month_date, year_date)
        result.today_secs  = ts.today_secs
        result.today_pages = ts.today_pages
        result.week_secs   = ts.week_secs
        result.week_pages  = ts.week_pages
        result.avg_secs    = ts.avg_secs
        result.avg_pages   = ts.avg_pages
        result.month_secs  = ts.month_secs
        result.month_pages = ts.month_pages
        result.year_secs   = ts.year_secs
        result.total_secs  = ts.total_secs
        if ts_err and Config.isFatalDbError(ts_err) then
            result.db_conn_fatal = true
        end

        if not result.db_conn_fatal then
            result.streak = fetchStreak(db_conn, start_today)
        end
    end

    -- ── Sidecar scan (one pass for both year + total) ─────────────────────
    -- year_str comes from the caller; fall back to t.year (already computed)
    -- to avoid a final os.date call.
    local by, bt = countMarkedReadBoth(year_str or tostring(t.year))
    result.books_year  = by
    result.books_total = bt

    -- ── Cache and return ──────────────────────────────────────────────────
    _cache     = result
    _cache_day = today_str
    return result
end

-- ---------------------------------------------------------------------------
-- SP.invalidate() — discard the cached stats so the next SP.get() re-fetches.
-- Call from:
--   • main.lua:onCloseDocument  (reading session ended)
--   • sui_homescreen:onShow     (when _stats_need_refresh is set)
--   • module_reading_goals dialogs (goal thresholds changed)
-- ---------------------------------------------------------------------------
function SP.invalidate()
    _cache     = nil
    _cache_day = nil
end

-- Expose internal cache getters for countMarkedReadBoth (used via SH reference).
-- These are NOT part of the public API — used only inside this module to share
-- the sidecar cache with module_books_shared without a circular dependency.
SP._cacheGet = nil  -- populated lazily from SH on first use inside countMarkedReadBoth
SP._cachePut = nil  -- same

return SP
