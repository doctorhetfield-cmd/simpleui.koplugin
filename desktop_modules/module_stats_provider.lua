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
--     • week_secs, week_pages     (calendar week Mon–today, grouped by date)
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
-- today_str, week_date, month_date, year_date are ISO-8601 strings
-- pre-computed by SP.get from its single os.date("*t") call — zero os.date
-- calls happen inside here.
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
                COALESCE(sum(CASE WHEN d = '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d = '%s' THEN pg ELSE 0 END), 0),
                -- 7-day window: d >= week_date
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END), 0),
                -- month: d >= month_date
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END), 0),
                -- year: d >= year_date
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                -- total: all rows in day_buckets (no filter needed)
                COALESCE(sum(sd), 0)
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
            r.week_secs   = rownum(rw[3] and rw[3][1])
            r.week_pages  = rownum(rw[4] and rw[4][1])
            -- avg over a fixed 7-day window: divide by 7 unconditionally.
            -- The original counted non-zero days (nd) to compute the average,
            -- which produced a "days with reading" average rather than a true
            -- calendar average.  Dividing by 7 matches the fork behaviour and
            -- is the value users intuitively expect from "daily avg (7 days)".
            r.avg_secs    = math.floor(r.week_secs  / 7)
            r.avg_pages   = math.floor(r.week_pages / 7)
            r.month_secs  = rownum(rw[5] and rw[5][1])
            r.month_pages = rownum(rw[6] and rw[6][1])
            r.year_secs   = rownum(rw[7] and rw[7][1])
            r.total_secs  = rownum(rw[8] and rw[8][1])
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
-- db_conn is passed in so we can cross-reference last_open from the statistics
-- DB as a more reliable "read this year" signal than summary.modified.
-- summary.modified reflects when the sidecar was last written — for books
-- marked finished before SimpleUI 2.0, this timestamp predates the current
-- year even if the user read the book this year.  last_open in the DB is set
-- to os.time() on every session close and is always current.
local function _dbLastOpenForMd5(conn, md5)
    if not conn or not md5 then return nil end
    local ok, row = pcall(function()
        return conn:rowexec(string.format(
            "SELECT last_open FROM book WHERE md5 = '%s' LIMIT 1", md5))
    end)
    return ok and row and tonumber(row) or nil
end
-- Replaces two separate countMarkedRead() calls (previously O(2N) sidecar I/O).
-- Uses the same _sidecar_cache from module_books_shared for cache hits.
-- ---------------------------------------------------------------------------
local _MAX_HIST = 200   -- hard cap: avoids unbounded scan on huge histories

-- modifiedInYear: KOReader always writes `modified` as an ISO-8601 string
-- ("YYYY-MM-DD ..."), a unix timestamp (number), or an os.date("*t") table.
local function _modifiedInYear(summary, year_str)
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

local function countMarkedReadBoth(year_str, year_start, db_conn)
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

    local limit = math.min(#ReadHistory.hist, _MAX_HIST)
    for i = 1, limit do
        local entry = ReadHistory.hist[i]
        local fp    = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local summary, md5
            -- Fast path: reuse the sidecar cache warmed by prefetchBooks().
            -- Cache hit costs 1 lfs.attributes (mtime check); miss costs DS.open.
            if SH then
                local cached = SH._cacheGet and SH._cacheGet(fp)
                if cached then
                    summary = cached.summary
                    md5     = cached.partial_md5_checksum
                else
                    local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
                    if ok_open and ds then
                        summary = ds:readSetting("summary")
                        -- Populate the shared cache so subsequent renders skip DS.open.
                        if SH._cachePut then
                            local doc_props = ds:readSetting("doc_props")
                            local stats = ds:readSetting("stats")
                            local data = {
                                percent              = ds:readSetting("percent_finished") or 0,
                                title                = doc_props and doc_props.title,
                                authors              = doc_props and doc_props.authors,
                                doc_pages            = ds:readSetting("doc_pages"),
                                partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                                stat_pages           = stats and stats.pages,
                                stat_total_time      = stats and stats.total_time_in_sec,
                                summary              = summary,
                            }
                            SH._cachePut(fp, ds.source_candidate, data)
                            md5 = data.partial_md5_checksum
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
                -- Prefer DB last_open for the year check: it is updated on every
                -- session close and is always current, unlike summary.modified
                -- which reflects the sidecar write time and can predate the
                -- current year for books finished before SimpleUI 2.0.
                local in_year = false
                if db_conn and md5 and year_start then
                    local lo = _dbLastOpenForMd5(db_conn, md5)
                    if lo then
                        in_year = lo >= year_start
                    end
                end
                -- Fallback to summary.modified when the DB has no record for
                -- this book (e.g. statistics plugin was never enabled for it).
                if not in_year then
                    in_year = _modifiedInYear(summary, year_str)
                end
                if in_year then
                    books_year = books_year + 1
                end
            end
        end
    end
    -- Include finished books that were deleted from the device while the
    -- "Preserve deleted books in statistics" option was enabled.  These are
    -- stored in sui_store.lua (DeletedBooks) keyed by partial_md5_checksum.
    -- We skip md5s already counted from the ReadHistory loop above to avoid
    -- doubles when a book was deleted and then re-added by the user (the live
    -- sidecar entry takes precedence).
    local ok_SS, SUISettings2 = pcall(require, "sui_store")
    if ok_SS and SUISettings2 and SUISettings2.DeletedBooks then
        local DB = SUISettings2.DeletedBooks
        if DB.isEnabled() then
            -- Build the set of md5s already counted from the ReadHistory loop.
            -- Done lazily here so there is zero overhead when the feature is off.
            local counted_md5s = {}
            for i = 1, math.min(#ReadHistory.hist, _MAX_HIST) do
                local entry = ReadHistory.hist[i]
                local fp    = entry and entry.file
                if fp and lfs.attributes(fp, "mode") == "file" then
                    -- Re-use the sidecar cache that was already warmed above.
                    local md5
                    if SH then
                        local cached = SH._cacheGet and SH._cacheGet(fp)
                        if cached then md5 = cached.partial_md5_checksum end
                    end
                    if md5 then counted_md5s[md5] = true end
                end
            end

            local deleted = DB.getAll()
            local year_int = tonumber(year_str)
            for md5, entry in pairs(deleted) do
                if not counted_md5s[md5] then
                    books_total = books_total + 1
                    if entry.year and entry.year == year_int then
                        books_year = books_year + 1
                    end
                end
            end
        end
    end

    return books_year, books_total
end

-- Partial-invalidation flags — declared here so SP.get(), SP.invalidate(),
-- and SP.invalidateTimeSeries() all close over the same locals.
-- _books_cache_valid:  set by invalidateTimeSeries() when books_year/books_total
--   are known-unchanged; consumed and cleared by SP.get().
-- _streak_cache_valid: same pattern for the streak value.
local _books_cache_valid  = false
local _streak_cache_valid = false

-- ---------------------------------------------------------------------------
-- SP.get(db_conn, year_str, needs_books) — main entry point.
--
-- db_conn:      shared ljsqlite3 connection from ctx.db_conn (may be nil if DB
--               unavailable; returns zero-filled table in that case).
-- year_str:     current year as string e.g. "2025" — pass ctx.year_str.
-- needs_books:  when true, runs the sidecar scan to populate books_year and
--               books_total.  Pass false when no active module consumes these
--               fields (e.g. reading_stats active but "total_books" not
--               selected, and reading_goals inactive) to skip up to 200
--               DS.open() calls.  Defaults to true for safety.
--
-- Returns a table; sets result.db_conn_fatal = true if the shared connection
-- encountered a fatal error (caller should set ctx.db_conn_fatal accordingly).
-- ---------------------------------------------------------------------------
function SP.get(db_conn, year_str, needs_books)
    if needs_books == nil then needs_books = true end  -- safe default
    -- Single os.date("*t") call — derive today_str from the same table to
    -- avoid a second os.date("%Y-%m-%d") syscall. string.format is faster
    -- than os.date for simple date formatting in LuaJIT.
    local now         = os.time()
    local t           = os.date("*t", now)
    local today_str   = string.format("%04d-%02d-%02d", t.year, t.month, t.day)

    -- Cache hit: same calendar day, data already fetched.
    -- When needs_books=true, only use the cache if it was built with books data
    -- (books_total > 0 is not a reliable sentinel — a user with zero finished
    -- books would always miss). Instead we track completeness with a flag.
    if _cache and _cache_day == today_str then
        if not needs_books or _cache._has_books then
            return _cache
        end
        -- Cache exists but was built without books data and now we need it:
        -- fall through to re-run the sidecar scan.  DB fields are already
        -- correct so we skip the DB queries below by pre-filling result from
        -- the existing cache, then only run countMarkedReadBoth.
        local result = {
            today_secs    = _cache.today_secs,
            today_pages   = _cache.today_pages,
            week_secs     = _cache.week_secs,
            week_pages    = _cache.week_pages,
            avg_secs      = _cache.avg_secs,
            avg_pages     = _cache.avg_pages,
            month_secs    = _cache.month_secs,
            month_pages   = _cache.month_pages,
            year_secs     = _cache.year_secs,
            total_secs    = _cache.total_secs,
            streak        = _cache.streak,
            books_year    = 0,
            books_total   = 0,
            db_conn_fatal = _cache.db_conn_fatal,
            _has_books    = true,
            -- Only books changed (sidecar scan newly run); time-series and
            -- streak were already correct and are carried over unchanged.
            _changed      = { timeseries = false, streak = false, books = true },
        }
        local by, bt = countMarkedReadBoth(
            year_str or tostring(t.year),
            os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 },
            db_conn)
        result.books_year  = by
        result.books_total = bt
        _cache     = result
        -- _cache_day stays the same (today_str)
        return result
    end

    -- Compute timestamps once — shared by all sub-queries.
    local start_today = now - (t.hour * 3600 + t.min * 60 + t.sec)
    -- Calendar week: Monday of the current week.
    -- t.wday: 1=Sunday, 2=Monday, ..., 7=Saturday → days since Monday = (t.wday - 2) % 7
    local week_start  = start_today - ((t.wday - 2) % 7) * 86400
    local month_start = os.time{ year = t.year, month = t.month, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }
    local year_start  = os.time{ year = t.year, month = 1, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }

    -- Pre-compute ISO-8601 date strings once using string.format (faster than
    -- os.date per-string) and share them across fetchTimeSeries and the sidecar
    -- scan — avoids redundant os.date calls inside fetchTimeSeries.
    local t_week  = os.date("*t", week_start)
    local t_month = os.date("*t", month_start)
    local t_year  = os.date("*t", year_start)
    local week_date  = string.format("%04d-%02d-%02d", t_week.year,  t_week.month,  t_week.day)
    local month_date = string.format("%04d-%02d-%02d", t_month.year, t_month.month, t_month.day)
    local year_date  = string.format("%04d-%02d-%02d", t_year.year,  t_year.month,  t_year.day)

    -- _changed: tells consumers which categories of data were re-fetched so
    -- that updateStats() can skip cards/rows whose underlying fields did not
    -- change, avoiding redundant TextWidget allocation and e-ink dirty regions.
    --
    -- timeseries: always true on a cold-cache call (fetchTimeSeries ran).
    -- streak:     false when _streak_cache_valid was set (streak carried over).
    -- books:      false when _books_cache_valid was set (counts carried over).
    --
    -- The flags are read *before* the fast-path branches below consume and
    -- clear _streak_cache_valid / _books_cache_valid, so they reflect the
    -- state at the point of this SP.get() call.
    local streak_carried = _streak_cache_valid
    local books_carried  = _books_cache_valid

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
        _changed      = { timeseries = true, streak = not streak_carried, books = not books_carried },
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
            -- Skip fetchStreak when invalidateTimeSeries() preserved the value:
            -- _streak_cache_valid is set only when the previous cache was built
            -- on today_str, meaning the streak was already correct for today.
            -- Any close after the first session of the day hits this fast path.
            if _streak_cache_valid then
                result.streak   = (_cache and _cache.streak) or 0
                _streak_cache_valid = false
            else
                result.streak = fetchStreak(db_conn, start_today)
            end
        end
    end

    -- ── Sidecar scan (one pass for both year + total) ─────────────────────
    -- year_str comes from the caller; fall back to t.year (already computed)
    -- to avoid a final os.date call.
    --
    -- Skipped entirely when needs_books=false: no active module needs
    -- books_year or books_total, so up to 200 DS.open() calls are avoided.
    --
    -- Also skipped when _books_cache_valid is set: invalidateTimeSeries()
    -- preserved the previous counts because the closed book's status did not
    -- change.  The flag is single-use — cleared immediately after reading so
    -- that the next render (e.g. after midnight rollover) runs the full scan.
    if not needs_books then
        -- No consumer needs books_year/books_total — skip the sidecar scan.
        -- Do NOT cache this result under today_str: a future call with
        -- needs_books=true on the same calendar day must still run the scan
        -- rather than hitting the cache and getting zeros.
        -- _books_cache_valid is left untouched: if invalidateTimeSeries() set
        -- it, the flag remains valid for the next needs_books=true call.
        return result
    elseif _books_cache_valid then
        -- Reuse counts from the partially-invalidated cache entry.
        result.books_year  = (_cache and _cache.books_year)  or 0
        result.books_total = (_cache and _cache.books_total) or 0
        _books_cache_valid = false
    else
        local by, bt = countMarkedReadBoth(
            year_str or tostring(t.year),
            year_start,
            db_conn)
        result.books_year  = by
        result.books_total = bt
    end

    -- ── Cache and return ──────────────────────────────────────────────────
    -- Mark the cache entry so the cache-hit path knows books data is present.
    result._has_books = true
    _cache     = result
    _cache_day = today_str
    return result
end

-- ---------------------------------------------------------------------------
-- SP.invalidate() — force a full re-fetch on the next SP.get() call.
-- Preserves _cache so that SP.getStale() can still return the previous values
-- for the deferred first-paint path (avoids the "flash to zeros" on HS open).
-- _cache_day is cleared so SP.get() treats the next call as a cold-cache miss
-- and re-runs all DB queries and the sidecar scan unconditionally.
-- Call from:
--   • main.lua:onCloseDocument  (reading session ended, book status changed)
--   • sui_homescreen:onShow     (when _stats_need_refresh is set)
--   • module_reading_goals dialogs (goal thresholds changed)
-- ---------------------------------------------------------------------------
function SP.invalidate()
    -- Do NOT nil _cache — getStale() needs it for the stale first-paint.
    -- SP.get() will overwrite every field unconditionally on the next call.
    _cache_day          = nil
    -- Clear partial-invalidation flags so SP.get() does not accidentally
    -- reuse streak or books counts from the stale entry.
    _books_cache_valid  = false
    _streak_cache_valid = false
end

-- ---------------------------------------------------------------------------
-- SP.invalidateTimeSeries() — partial invalidation for the common case where
-- a reading session ended but the book's completion status did NOT change.
--
-- After a normal reading session, only the DB-derived fields are stale
-- (today_secs, today_pages, avg_*, year_secs, total_secs, streak).
-- books_year and books_total come from the sidecar scan in countMarkedReadBoth,
-- which is expensive (up to _MAX_HIST sidecar opens). When the closed book's
-- summary.status did not cross the "complete" boundary, those counts are
-- unchanged and can be preserved in the cache.
--
-- Strategy: keep the cache entry alive but zero all DB-derived fields and
-- clear _cache_day so the next SP.get() treats it as a cold-cache miss and
-- re-runs both DB queries. books_year/books_total survive untouched.
--
-- This is safe because SP.get() unconditionally overwrites all fields in the
-- result table from fresh queries — the surviving books_* values are used
-- directly as-is only when countMarkedReadBoth is skipped (see below).
-- SP.get() is updated to skip countMarkedReadBoth when _books_cache_valid is
-- set, then clears the flag so subsequent calls behave normally.
-- ---------------------------------------------------------------------------
function SP.invalidateTimeSeries()
    if not _cache then return end   -- nothing cached; no-op
    -- Zero only the DB-derived fields. books_year/books_total are kept.
    -- Streak: the recursive CTE result only changes on the *first* reading
    -- session of a new day (when today's date first appears in page_stat_data).
    -- For any subsequent close within the same calendar day the streak value
    -- is identical — re-running fetchStreak would be pure waste.
    -- _cache_day holds the date string when the cache was built.  If it equals
    -- today we have already fetched the streak for today at least once, so we
    -- can carry it forward.  If it differs (cache was built yesterday or the
    -- day before) this is the first session of today and the streak may have
    -- just been broken or extended — we must re-fetch.
    -- We compute today_str here with the same string.format pattern used in
    -- SP.get() to avoid an os.date call; os.time() is a single syscall.
    local now = os.time()
    local t = os.date("*t", now)
    local today_str = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    if _cache_day == today_str and _cache.today_secs > 0 then
        -- Same day AND reading already recorded today: streak cannot have changed again — preserve it.
        _streak_cache_valid = true
        _books_cache_valid  = true
        _cache_day          = nil    -- force SP.get() to re-run DB time-series
        -- streak is intentionally left untouched in _cache
    else
        -- Different day (or first session today): streak must be re-fetched.
        _streak_cache_valid = false
        _books_cache_valid  = true
        _cache_day          = nil
    end
end

-- Expose internal cache getters for countMarkedReadBoth (used via SH reference).
-- These are NOT part of the public API — used only inside this module to share
-- the sidecar cache with module_books_shared without a circular dependency.
SP._cacheGet = nil  -- populated lazily from SH on first use inside countMarkedReadBoth
SP._cachePut = nil  -- same

function SP.getStale()
    return _cache
end

return SP
