-- module_stats_provider.lua — Simple UI
-- Centralised statistics provider for the homescreen.
--
-- Single responsibility: fetch all numeric stats needed by reading_stats and
-- reading_goals in the minimum number of DB roundtrips, cache the result for
-- the current calendar day, and expose a single invalidate() entry point.
-- Consumers read ctx.stats.* — they contain no DB or cache logic of their own.
--
-- DB source: page_stat_data (base table) instead of the page_stat VIEW, so
-- SQLite can use the start_time index to bound each scan to its window.
--
-- DB roundtrips per cold-cache call: 3
--   Query 1a — per-day buckets over the last ~month: today/week/rolling-7-day/
--     month, seconds and pages.
--   Query 1b — duration sums for the year and all-time windows.
--   Query 2  — streak (recent distinct active dates + freeze-aware walk).
-- Sidecar roundtrip: one pass over ReadHistory.hist producing books_year and
--   books_total together (single scan instead of two).

local logger = require("logger")
local lfs    = require("libs/libkoreader-lfs")
local Config = require("infra/sui_config")

local SP = {}

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------
-- Keyed by calendar day ("YYYY-MM-DD"). Invalidated by SP.invalidate(),
-- called from:
--   • main.lua:onCloseDocument   (after a reading session)
--   • sui_homescreen:onShow      (when _stats_need_refresh is set)
--   • module_reading_goals       (after goal thresholds change)
-- The day key handles midnight rollover without an explicit call.

local _cache     = nil   -- the stats table
local _cache_day = nil   -- "YYYY-MM-DD" when the cache was built

-- Cross-process persistence: _cache lives only for the current KOReader
-- process, so a genuine cold start would otherwise show a "no data yet"
-- placeholder for one frame. To avoid that, the last successful result is
-- also mirrored to disk via sui_store (same pattern as module_books_shared's
-- _last_books_state): writes go through SUISettings:setNoFlush() (in-memory
-- only, no I/O) on every SP.get() recompute, and the actual fsync piggybacks
-- on SimpleUIPlugin:onSuspend(). Worst case on power loss before a suspend:
-- the on-disk copy is simply absent or one session behind — SP.getStale()
-- falls back to nil exactly as it would without this mechanism.
-- The disk read itself happens at most once per process (lazy, on the first
-- SP.getStale() call while _cache is still nil).
local _disk_load_tried = false

local _STALE_STATS_SETTING_KEY = "simpleui_stale_stats_v1"

-- Lazy requires avoid load-order assumptions / circular deps.
local _SUIStore = nil
local function _getSUIStore()
    if not _SUIStore then
        local ok, m = pcall(require, "infra/sui_store")
        if ok then _SUIStore = m end
    end
    return _SUIStore
end

local _StreakFreeze = nil
local function _getStreakFreeze()
    if not _StreakFreeze then
        local ok, m = pcall(require, "infra/sui_streak")
        if ok then _StreakFreeze = m end
    end
    return _StreakFreeze
end

-- Persists a stale-safe snapshot of `state` to the in-memory settings table
-- only (see the cross-process persistence note above) — never touches disk
-- itself. Only final scalar fields are stored, not the whole `result` table:
-- `_changed`/`_has_books` describe a transition relative to in-memory state
-- that a fresh process has no baseline for, so they are not persisted.
local function _persistStaleStats(state)
    local SUIStore = _getSUIStore()
    if not SUIStore or not SUIStore.setNoFlush then return end
    local snapshot = {
        today_secs    = state.today_secs,
        today_pages   = state.today_pages,
        week_secs     = state.week_secs,
        week_pages    = state.week_pages,
        avg_secs      = state.avg_secs,
        avg_pages     = state.avg_pages,
        month_secs    = state.month_secs,
        month_pages   = state.month_pages,
        year_secs     = state.year_secs,
        total_secs    = state.total_secs,
        streak        = state.streak,
        books_year    = state.books_year,
        books_total   = state.books_total,
        db_conn_fatal = state.db_conn_fatal,
    }
    pcall(SUIStore.setNoFlush, SUIStore, _STALE_STATS_SETTING_KEY, snapshot)
end

-- Reads the on-disk mirror back, at most once per process. Returns nil
-- silently on any failure — the caller already treats nil as "no stale data".
local function _loadStaleStatsFromDisk()
    _disk_load_tried = true
    local SUIStore = _getSUIStore()
    if not SUIStore then return nil end
    local ok, v = pcall(SUIStore.readSetting, SUIStore, _STALE_STATS_SETTING_KEY)
    if not ok or type(v) ~= "table" then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function rownum(v)
    return tonumber(v or 0) or 0
end

-- ---------------------------------------------------------------------------
-- Query 1: time-series stats, split by how far back each window reaches.
--
-- Short windows (today / week / rolling 7 days / month) need per-day buckets
-- so pages are counted as DISTINCT per day. day_buckets groups the rows since
-- `window_since` into one row per calendar day; the outer SELECT uses CASE
-- WHEN on the ISO-8601 date column to partition sums across windows in one
-- scan. `window_since` is the earliest start of those windows minus a day of
-- slack, so the scan only touches roughly the last month of rows.
--
-- Long windows (year / all time) only need a duration sum, so a second query
-- skips the per-row date formatting and bucketing. The year bound is applied
-- to start_time (the indexed column) rather than to a formatted date.
--
-- page_stat_data is read directly (not the page_stat view) and duration > 0
-- excludes zero-duration rows, matching the page_stat VIEW's semantics.
-- Dates are pre-computed by SP.get() from a single os.date("*t") call, so
-- this function makes no os.date calls of its own.
--
-- Two distinct windows feed two different cards:
--   week_date     — Monday of the current calendar week ("This week" card).
--   rolling7_date — today minus 6 full days ("avg 7 days" card). Must stay a
--     true trailing window, independent of week_date, to match the Reading
--     Stats window's own rolling average.
-- ---------------------------------------------------------------------------
local function fetchTimeSeries(conn, window_since, year_start,
                               today_str, week_date, month_date, rolling7_date)
    local r = {
        today_secs     = 0,
        today_pages    = 0,
        week_secs      = 0,
        week_pages     = 0,
        rolling7_secs  = 0,
        rolling7_pages = 0,
        avg_secs       = 0,
        avg_pages      = 0,
        month_secs     = 0,
        month_pages    = 0,
        year_secs      = 0,
        total_secs     = 0,
    }

    local ok, err = pcall(function()
        local rw = conn:exec(string.format([[
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
                COALESCE(sum(CASE WHEN d = '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d = '%s' THEN pg ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN sd ELSE 0 END), 0),
                COALESCE(sum(CASE WHEN d >= '%s' THEN pg ELSE 0 END), 0)
            FROM day_buckets;
        ]], window_since,
            today_str,    today_str,
            week_date,    week_date,
            rolling7_date, rolling7_date,
            month_date,   month_date))
        if rw and rw[1] and rw[1][1] then
            r.today_secs     = rownum(rw[1][1])
            r.today_pages    = rownum(rw[2] and rw[2][1])
            r.week_secs      = rownum(rw[3] and rw[3][1])
            r.week_pages     = rownum(rw[4] and rw[4][1])
            r.rolling7_secs  = rownum(rw[5] and rw[5][1])
            r.rolling7_pages = rownum(rw[6] and rw[6][1])
            r.avg_secs       = math.floor(r.rolling7_secs  / 7)
            r.avg_pages      = math.floor(r.rolling7_pages / 7)
            r.month_secs     = rownum(rw[7] and rw[7][1])
            r.month_pages    = rownum(rw[8] and rw[8][1])
        end

        local rl = conn:exec(string.format([[
            SELECT
                COALESCE(sum(CASE WHEN start_time >= %d THEN duration ELSE 0 END), 0),
                COALESCE(sum(duration), 0)
            FROM page_stat_data
            WHERE duration > 0;
        ]], year_start))
        if rl and rl[1] and rl[1][1] then
            r.year_secs  = rownum(rl[1][1])
            r.total_secs = rownum(rl[2] and rl[2][1])
        end
    end)
    if not ok then
        logger.warn("simpleui: stats_provider: fetchTimeSeries failed: " .. tostring(err))
        return r, err
    end
    return r, nil
end

-- ---------------------------------------------------------------------------
-- Query 2: reading streak.
--
-- Only the trailing run of consecutive active days matters, so the distinct
-- active dates are fetched for a bounded recent window and merged with any
-- Streak Manager frozen dates before handing off to sui_streak's shared walk
-- (also used by sui_stats_windows' Reading Insights window) — frozen days
-- are never written into page_stat_data itself.
--
-- The window starts at STREAK_FIRST_WINDOW_DAYS and grows by
-- STREAK_WINDOW_GROWTH while the run reaches the window's oldest day (the
-- run may extend further back), until it ends inside the window or the whole
-- table is covered.
--
-- Queried against page_stat_data directly, bounded on the indexed start_time
-- column; duration > 0 excludes zero-duration rows (e.g. a crash/force-close).
-- today_str/yesterday_str are passed in, so this makes no os.date calls of
-- its own.
-- ---------------------------------------------------------------------------
local STREAK_FIRST_WINDOW_DAYS = 90
local STREAK_WINDOW_GROWTH     = 4

local function fetchStreak(conn, today_str, yesterday_str, start_today)
    local streak = 0
    local ok, err = pcall(function()
        local SF = _getStreakFreeze()
        if not (SF and SF.computeCurrentDayStreak) then return end
        local frozen = SF.getFrozenDatesInRange and SF.getFrozenDatesInRange(nil, nil) or {}

        local window_days = STREAK_FIRST_WINDOW_DAYS
        while true do
            local since = math.max(0, start_today - window_days * 86400)
            local rw = conn:exec(string.format([[
                SELECT DISTINCT date(start_time, 'unixepoch', 'localtime')
                FROM page_stat_data
                WHERE start_time >= %d AND duration > 0;
            ]], since))
            streak = SF.computeCurrentDayStreak(rw and rw[1] or {}, {
                frozen_dates = frozen,
                today        = today_str,
                yesterday    = yesterday_str,
            })
            -- Complete once the run ends at least a day inside the window
            -- (the slack absorbs day-length drift) or nothing older exists.
            if since == 0 or streak < window_days - 1 then break end
            window_days = window_days * STREAK_WINDOW_GROWTH
        end
    end)
    if not ok then
        logger.warn("simpleui: stats_provider: fetchStreak failed: " .. tostring(err))
    end
    return streak
end

-- ---------------------------------------------------------------------------
-- Sidecar reads
-- ---------------------------------------------------------------------------
-- Opens `fp`'s DocSettings sidecar, reads the fields modules across the
-- plugin need, and warms module_books_shared's cache with them so later
-- lookups hit the fast path instead of a second DS.open. Returns the
-- `summary` table (may be nil), `percent_finished`, and the partial md5
-- (only set when the shared cache is available and gets populated).
local function _openAndCacheSidecar(fp, DocSettings, SH)
    local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
    if not ok_open or not ds then return nil, 0, nil end
    local percent = ds:readSetting("percent_finished") or 0
    local summary = ds:readSetting("summary")
    local md5
    if SH and SH._cachePut then
        local doc_props = ds:readSetting("doc_props")
        local stats      = ds:readSetting("stats")
        md5 = ds:readSetting("partial_md5_checksum")
        SH._cachePut(fp, ds.source_candidate, {
            percent              = percent,
            title                = doc_props and doc_props.title,
            authors              = doc_props and doc_props.authors,
            doc_pages            = ds:readSetting("doc_pages"),
            partial_md5_checksum = md5,
            stat_pages           = stats and stats.pages,
            stat_total_time      = stats and stats.total_time_in_sec,
            summary              = summary,
        })
    end
    -- No ds:close() here on purpose: this DocSettings handle is only ever
    -- read from (readSetting), never written to, but close()/flush() in
    -- KOReader unconditionally rewrites the whole metadata.*.lua sidecar
    -- file regardless of whether anything actually changed (no
    -- dirty-tracking — see https://github.com/koreader/koreader/issues/2789).
    -- Closing here turns every sidecar scan (countMarkedReadBoth,
    -- getStatusCounts — both called from the homescreen's post-cold-open
    -- stats refresh) into a full disk write per book, stretching what
    -- should be an instant correction pass into a multi-second one and
    -- causing a visible homescreen reflow/blink. Same fix already applied
    -- in module_books_shared.lua's SH.prefetchBooks() — see the matching
    -- comment there. Not calling close() is safe for read-only use; the
    -- handle is simply garbage-collected.
    return summary, percent, md5
end

-- ---------------------------------------------------------------------------
-- Sidecar scan: one pass over ReadHistory -> books_year + books_total.
--
-- A book counts as completed when its sidecar summary.status == "complete".
-- Its completion year comes from summary.date_finished (SimpleUI-written
-- "YYYY-MM-DD") or, as a fallback, a STRING-typed summary.modified
-- (written by filemanagerutil.saveSummary on a manual status change).
-- A NUMERIC summary.modified is a KOReader session-close timestamp,
-- refreshed on every close regardless of completion — it is never used as a
-- completion date, or reopening an old finished book would inflate
-- books_year for the current year.
-- ---------------------------------------------------------------------------
local _MAX_HIST = 200   -- hard cap: avoids an unbounded scan on huge histories

local function _modifiedInYear(summary, year_str)
    local mod
    if summary then
        if summary.date_finished ~= nil then
            mod = summary.date_finished
        elseif type(summary.modified) == "string" then
            mod = summary.modified
        end
    end
    if mod == nil then return false end
    if type(mod) == "string" then
        return #mod >= 4 and mod:sub(1, 4) == year_str
    end
    return false
end

-- Also merges in finished books preserved after deletion (sui_store's
-- DeletedBooks, keyed by partial md5) when that option is enabled. Each
-- book's md5 is recorded while scanning ReadHistory so the merge can skip
-- any book already counted from a live sidecar (a book deleted and then
-- re-added takes the live entry, not the preserved one).
local function countMarkedReadBoth(year_str)
    local books_year, books_total = 0, 0

    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return books_year, books_total end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return books_year, books_total end

    -- Borrow the sidecar cache warmed by module_books_shared.prefetchBooks
    -- (always required before this provider runs) via package.loaded, to
    -- avoid a circular require.
    local SH = package.loaded["modules/module_books_shared"]
    if not SH then
        logger.warn("simpleui: stats_provider: module_books_shared not loaded — sidecar cache unavailable")
    end

    local ok_SS, SUIStore = pcall(require, "infra/sui_store")
    local DeletedBooks  = ok_SS and SUIStore and SUIStore.DeletedBooks
    local merge_deleted = DeletedBooks and DeletedBooks.isEnabled()
    local counted_md5s  = merge_deleted and {} or nil

    local limit = math.min(#ReadHistory.hist, _MAX_HIST)
    for i = 1, limit do
        local entry = ReadHistory.hist[i]
        local fp    = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local summary, md5
            local cached = SH and SH._cacheGet and SH._cacheGet(fp)
            if cached then
                summary = cached.summary
                md5     = cached.partial_md5_checksum
            else
                summary, _, md5 = _openAndCacheSidecar(fp, DocSettings, SH)
            end

            if counted_md5s and md5 then counted_md5s[md5] = true end

            if type(summary) == "table" and summary.status == "complete" and not summary.exclude_from_goals then
                books_total = books_total + 1
                if _modifiedInYear(summary, year_str) then
                    books_year = books_year + 1
                end
            end
        end
    end

    if merge_deleted then
        local deleted   = DeletedBooks.getAll()
        local year_int  = tonumber(year_str)
        for md5, entry in pairs(deleted) do
            if not counted_md5s[md5] then
                books_total = books_total + 1
                if entry.year and entry.year == year_int then
                    books_year = books_year + 1
                end
            end
        end
    end

    return books_year, books_total
end

-- ---------------------------------------------------------------------------
-- Status counts (unread / reading / complete / abandoned)
-- ---------------------------------------------------------------------------
-- Whole-library breakdown by reading status. reading_stats' status_* cards
-- only surface unread/reading/abandoned (a "Status — Finished" card would
-- near-duplicate total_books), but this returns all four so callers can
-- decide which to show.
--
-- Unlike countMarkedReadBoth() below, which only sees books present in
-- ReadHistory (i.e. opened at least once), this needs every book in the
-- library, so it walks sui_library_scan's file list — itself mtime-cached
-- per directory — and classifies each one from its sidecar percent/status,
-- reusing the same module_books_shared cache as countMarkedReadBoth().
-- Cached independently of the time-series `_cache` above and computed on
-- demand.

local _status_cache = nil  -- { unread=, reading=, complete=, abandoned= } | nil

-- Classifies one book from its sidecar percent/status pair, using the same
-- vocabulary as sui_book_grid.lua's badge logic.
-- Maps a book's sidecar percent/status to its status bucket name.
local function _statusBucket(percent, status)
    if status == "complete" then
        return "complete"
    elseif status == "abandoned" then
        return "abandoned"
    elseif (percent or 0) > 0 then
        return "reading"
    end
    return "unread"
end

local function _classifyStatusEntry(counts, percent, status)
    local bucket = _statusBucket(percent, status)
    counts[bucket] = counts[bucket] + 1
end

--- Whole-library book counts by reading status. Cached until
--- SP.invalidateStatusCounts() runs, so repeat calls in the same render
--- pass are free.
function SP.getStatusCounts()
    if _status_cache then return _status_cache end

    local counts = { unread = 0, reading = 0, complete = 0, abandoned = 0 }
    local ok_scan, LibraryScan = pcall(require, "engines/sui_library_scan")
    local ok_DS, DocSettings   = pcall(require, "docsettings")
    if not ok_scan or not LibraryScan or not ok_DS then
        _status_cache = counts
        return counts
    end
    local home = LibraryScan.resolveHomeDir()
    if not home then
        _status_cache = counts
        return counts
    end

    local SH = package.loaded["modules/module_books_shared"]

    local fps = LibraryScan.getFileList(home)
    for _, fp in ipairs(fps) do
        local percent, status
        local cached = SH and SH._cacheGet and SH._cacheGet(fp)
        if cached then
            percent = cached.percent or 0
            status  = type(cached.summary) == "table" and cached.summary.status or nil
        elseif lfs.attributes(fp, "mode") == "file" then
            local summary
            summary, percent = _openAndCacheSidecar(fp, DocSettings, SH)
            status = type(summary) == "table" and summary.status or nil
        end
        _classifyStatusEntry(counts, percent, status)
    end

    _status_cache = counts
    return counts
end

--- Moves one library book between status buckets in the cached counts, so a
--- single status change does not require recounting the whole library. No-op
--- when counts were never computed or the book is not part of the library.
--- The cached table is replaced rather than mutated: callers may still hold
--- the previous one.
function SP.applyStatusChange(fp, pre_percent, pre_status, post_percent, post_status)
    local from = _statusBucket(pre_percent, pre_status)
    local to   = _statusBucket(post_percent, post_status)
    if not _status_cache or from == to then return end

    local ok_scan, LibraryScan = pcall(require, "engines/sui_library_scan")
    local home = ok_scan and LibraryScan and LibraryScan.resolveHomeDir()
    if not home then return end

    for _, lib_fp in ipairs(LibraryScan.getFileList(home)) do
        if lib_fp == fp then
            local counts = {}
            for bucket, n in pairs(_status_cache) do counts[bucket] = n end
            counts[from] = math.max(0, counts[from] - 1)
            counts[to]   = counts[to] + 1
            _status_cache = counts
            return
        end
    end
end

--- Forces the next SP.getStatusCounts() call to recompute. Called from
--- SP.invalidate() so status counts share the same invalidation triggers as
--- the rest of this provider.
function SP.invalidateStatusCounts()
    _status_cache = nil
end

-- Partial-invalidation flags, declared here so SP.get(), SP.invalidate() and
-- SP.invalidateTimeSeries() all close over the same locals.
--   _books_cache_valid:  set by invalidateTimeSeries() when books_year/
--     books_total are known-unchanged; consumed and cleared by SP.get().
--   _streak_cache_valid: same pattern for the streak value.
local _books_cache_valid  = false
local _streak_cache_valid = false

-- ---------------------------------------------------------------------------
-- SP.get(db_conn, year_str, needs_books) — main entry point.
--
-- db_conn:     shared ljsqlite3 connection from ctx.db_conn (may be nil if
--              the DB is unavailable; returns a zero-filled table then).
-- year_str:    current year as a string, e.g. "2025" — pass ctx.year_str.
-- needs_books: when true, runs the sidecar scan for books_year/books_total.
--              Pass false when no active module consumes those fields, to
--              skip up to 200 DS.open() calls. Defaults to true.
--
-- Returns a table; sets result.db_conn_fatal = true on a fatal DB error
-- (caller should propagate to ctx.db_conn_fatal).
-- ---------------------------------------------------------------------------
function SP.get(db_conn, year_str, needs_books)
    if needs_books == nil then needs_books = true end
    local now         = os.time()
    local t           = os.date("*t", now)
    local today_str   = string.format("%04d-%02d-%02d", t.year, t.month, t.day)

    -- Cache hit: same calendar day. When needs_books=true, the cache must
    -- also carry books data — books_total > 0 isn't a reliable sentinel for
    -- a user with zero finished books, so completeness is tracked with the
    -- explicit `_has_books` flag instead.
    if _cache and _cache_day == today_str then
        if not needs_books or _cache._has_books then
            return _cache
        end
        -- DB fields are already correct; only the sidecar scan needs to run.
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
            _changed      = { timeseries = false, streak = false, books = true },
        }
        local by, bt = countMarkedReadBoth(year_str or tostring(t.year))
        result.books_year  = by
        result.books_total = bt
        _cache = result
        return result
    end

    -- Compute timestamps once, shared by all sub-queries.
    local start_today = now - (t.hour * 3600 + t.min * 60 + t.sec)
    -- t.wday: 1=Sunday, 2=Monday, ..., 7=Saturday -> days since Monday = (t.wday-2) % 7
    local week_start     = start_today - ((t.wday - 2) % 7) * 86400
    local rolling7_start = start_today - 6 * 86400
    local month_start = os.time{ year = t.year, month = t.month, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }
    local year_start  = os.time{ year = t.year, month = 1, day = 1,
                                  hour = 0,     min  = 0,  sec = 0 }

    local t_week     = os.date("*t", week_start)
    local t_rolling7 = os.date("*t", rolling7_start)
    local t_month    = os.date("*t", month_start)
    local week_date     = string.format("%04d-%02d-%02d", t_week.year,     t_week.month,     t_week.day)
    local rolling7_date = string.format("%04d-%02d-%02d", t_rolling7.year, t_rolling7.month, t_rolling7.day)
    local month_date    = string.format("%04d-%02d-%02d", t_month.year,    t_month.month,    t_month.day)
    -- Earliest start among the bucketed windows, minus a day of slack.
    local window_since  = math.min(week_start, rolling7_start, month_start) - 86400

    -- _changed tells consumers which categories were re-fetched this call, so
    -- updateStats() can skip rebuilding cards whose data is unchanged.
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
        local ts, ts_err = fetchTimeSeries(db_conn, window_since, year_start,
                                           today_str, week_date, month_date, rolling7_date)
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
            -- Streak Manager freeze mechanic (time-based earning hook):
            -- no-op when the freeze mechanic is disabled.
            local SF = _getStreakFreeze()
            if SF and SF.advanceFreezeTimeFromTotalSecs then
                pcall(SF.advanceFreezeTimeFromTotalSecs, result.total_secs)
            end

            if _streak_cache_valid then
                -- Streak only changes on the first session of a new day;
                -- for later sessions the same day, reuse the cached value.
                result.streak = (_cache and _cache.streak) or 0
                _streak_cache_valid = false
            else
                local yesterday_str = os.date("%Y-%m-%d", start_today - 86400)
                result.streak = fetchStreak(db_conn, today_str, yesterday_str, start_today)

                -- Streak Manager freeze mechanic (day-based earning hook):
                -- only reached when the streak was actually just
                -- recomputed, so this cannot double-grant within one day.
                if SF and SF.maybeGrantDayFreeze then
                    pcall(SF.maybeGrantDayFreeze, result.streak)
                end
            end
        end
    end

    -- ── Sidecar scan (one pass for both year + total) ─────────────────────
    if not needs_books then
        -- No consumer needs books_year/books_total: skip the sidecar scan.
        -- Not cached under today_str, so a later needs_books=true call on
        -- the same day still runs the scan instead of reading zeros.
        return result
    elseif _books_cache_valid then
        result.books_year  = (_cache and _cache.books_year)  or 0
        result.books_total = (_cache and _cache.books_total) or 0
        _books_cache_valid = false
    else
        local by, bt = countMarkedReadBoth(year_str or tostring(t.year))
        result.books_year  = by
        result.books_total = bt
    end

    result._has_books = true
    _cache     = result
    _cache_day = today_str
    _persistStaleStats(result)
    return result
end

-- ---------------------------------------------------------------------------
-- SP.invalidate() — force a full re-fetch on the next SP.get() call.
-- Preserves _cache (SP.getStale() needs it for the stale first-paint) but
-- clears _cache_day so the next call re-runs every DB query and the sidecar
-- scan unconditionally. Status counts are dropped too, unless the caller has
-- already adjusted them through SP.applyStatusChange (keep_status_counts).
-- Call from: main.lua:onCloseDocument, sui_homescreen:onShow (when
-- _stats_need_refresh is set), module_reading_goals dialogs.
-- ---------------------------------------------------------------------------
function SP.invalidate(keep_status_counts)
    _cache_day          = nil
    _books_cache_valid  = false
    _streak_cache_valid = false
    if not keep_status_counts then SP.invalidateStatusCounts() end
end

-- ---------------------------------------------------------------------------
-- SP.invalidateTimeSeries() — partial invalidation for the common case: a
-- reading session ended but the book's completion status did not change, so
-- books_year/books_total (expensive, up to _MAX_HIST sidecar opens) can be
-- preserved while the DB-derived fields are refetched.
--
-- Streak is preserved too, but only within the same calendar day the cache
-- was built on — the streak can only change on the first session of a new
-- day, so any later close that day is a safe no-op to skip.
-- ---------------------------------------------------------------------------
function SP.invalidateTimeSeries()
    if not _cache then return end
    local now = os.time()
    local t = os.date("*t", now)
    local today_str = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    if _cache_day == today_str and _cache.today_secs > 0 then
        -- Same day, reading already recorded today: streak cannot change again.
        _streak_cache_valid = true
        _books_cache_valid  = true
        _cache_day          = nil
    else
        -- Different day, or first session today: streak must be refetched.
        _streak_cache_valid = false
        _books_cache_valid  = true
        _cache_day          = nil
    end
end

-- ---------------------------------------------------------------------------
-- SP.invalidateStreak() — forces the next SP.get() to recount the streak.
-- For changes to the streak's inputs that do not come from reading activity
-- (freeze state), where the same-day carry-over of invalidateTimeSeries()
-- would keep serving the old value. books_year/books_total are preserved.
-- ---------------------------------------------------------------------------
function SP.invalidateStreak()
    if not _cache then return end
    _streak_cache_valid = false
    _books_cache_valid  = true
    _cache_day          = nil
end

-- Reserved for countMarkedReadBoth's shared-cache access via SH — not part
-- of the public API.
SP._cacheGet = nil
SP._cachePut = nil

--- Instant, zero-cost return of the last successful SP.get() result. See
--- the cross-process persistence note above the cache declaration: on cold
--- start, this lazily reads the on-disk mirror once so a fresh KOReader
--- launch also benefits from the previous run's stats, not just reader
--- returns within the same run. Returns nil if nothing is available yet;
--- callers fall back to an empty `{}` stub.
function SP.getStale()
    if not _cache and not _disk_load_tried then
        _cache = _loadStaleStatsFromDisk()
    end
    return _cache
end

return SP
