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
-- Finished books: books_year and books_total are counted from the persistent
--   FinishedBooks ledger, with no DB or sidecar access (see "Finished books").

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
-- Finished books
--
-- Every "books finished" figure and list comes from the FinishedBooks ledger
-- (infra/sui_store), keyed by partial md5. The ledger is kept current by
-- SP.bookChanged() and SP.syncBook(), called from every flow that changes a
-- book's state, and is reconciled against the sidecars of the books in the
-- reading history once a day, so that changes made outside the plugin are
-- picked up as well. Books outside the history are only recorded through
-- those flows.
--
-- Entry fields returned by SP.getFinishedBooks():
--   key                 unique id: the file path, or "md5:<md5>" when gone
--   filepath            nil when the file is gone
--   title, authors, md5
--   year                completion year (integer) or nil when unknown
--   date_started, date_finished   "YYYY-MM-DD" strings or nil
--   exclude_from_goals  true for books left out of the counts
--   preserved           true for books whose file is gone
--   manual              true for books entered by hand (no file)
--   count               number of books a manual entry stands for when it was
--                       entered as a plain number; nil for any other entry
-- ---------------------------------------------------------------------------
local _HISTORY_SCAN_LIMIT = 200   -- books reconciled per routine pass

local _reconciled_day = nil   -- "YYYY-MM-DD" of the last reconcile, nil when due
local _books_dirty    = false -- finished-book counts changed since _cache was built

local function _stringOrNil(value)
    return type(value) == "string" and value or nil
end

local function _finishedBooksStore()
    local SUIStore = _getSUIStore()
    return SUIStore and SUIStore.FinishedBooks
end

local function _booksModule()
    return package.loaded["modules/module_books_shared"]
end

--- Completion stamp of a sidecar summary. Taken from summary.date_finished or,
--- as a fallback, a STRING summary.modified (written on a manual status
--- change). A NUMERIC summary.modified is a session-close timestamp refreshed
--- on every close, so it never counts as a completion date.
local function _finishedStamp(summary)
    local stamp = _stringOrNil(summary.date_finished) or _stringOrNil(summary.modified)
    return stamp and #stamp >= 4 and stamp or nil
end

local function _yearOf(stamp)
    return stamp and tonumber(stamp:sub(1, 4)) or nil
end

--- Year a ledger entry belongs to: its completion year or, for a manual book
--- with no completion stamp, its start year.
local function _storedYear(stored)
    return _yearOf(stored.finished or stored.started)
end

--- Parses a stamp, "YYYY" or "YYYY-MM-DD". Returns the year, month and day as
--- numbers (month and day are nil for a year-only stamp), or nil when `stamp`
--- is not a valid stamp.
function SP.parseStamp(stamp)
    if type(stamp) ~= "string" then return nil end
    if stamp:match("^%d%d%d%d$") then return tonumber(stamp) end

    local y, m, d = stamp:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if y and m >= 1 and m <= 12 and d >= 1 and d <= 31 then return y, m, d end
    return nil
end

local function _isFullDate(stamp)
    return stamp ~= nil and stamp:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function _findByPath(books, fp)
    for md5, entry in pairs(books) do
        if entry.path == fp and not entry.gone then return md5, entry end
    end
end

-- The ledger entry of a book: by md5 when known, else by its file path.
local function _findEntry(books, fp, md5)
    if md5 and books[md5] then return md5, books[md5] end
    return _findByPath(books, fp)
end

--- Sidecar fields of a document that is open in the reader. Its settings
--- object is newer than the sidecar on disk, so status and md5 come from it;
--- title and authors come from the shared sidecar cache, which applies the
--- user's custom metadata.
local function _liveView(fp, doc_settings)
    local SH     = _booksModule()
    local cached = SH and SH.sidecarData and SH.sidecarData(fp, true) or {}
    local props  = doc_settings:readSetting("doc_props") or {}
    return {
        title                = cached.title or props.title,
        authors              = cached.authors or props.authors,
        partial_md5_checksum = doc_settings:readSetting("partial_md5_checksum")
                               or cached.partial_md5_checksum,
        summary              = doc_settings:readSetting("summary"),
    }
end

--- Ledger entry of a finished book, or nil when the sidecar is not "complete".
local function _finishedEntry(fp, view)
    local summary = view.summary
    if type(summary) ~= "table" or summary.status ~= "complete" then return nil end
    return {
        title    = view.title or fp:match("[^/]+$") or fp,
        authors  = view.authors or "",
        finished = _finishedStamp(summary),
        excluded = summary.exclude_from_goals and true or nil,
        path     = fp,
    }
end

local function _sameEntry(a, b)
    return a ~= nil
        and a.title == b.title and a.authors == b.authors
        and a.finished == b.finished and a.excluded == b.excluded
        and a.path == b.path and a.gone == b.gone
end

--- Applies the sidecar state of `fp` to the ledger: a finished book is
--- recorded, anything else is dropped. Returns true when the ledger changed.
local function _applyBook(ledger, fp, view)
    local books = ledger.books
    local entry = _finishedEntry(fp, view)
    if entry then
        local md5 = view.partial_md5_checksum or _findByPath(books, fp)
                    or require("util").partialMD5(fp)
        if not md5 or _sameEntry(books[md5], entry) then return false end
        books[md5] = entry
        return true
    end

    local changed = false
    local md5 = view.partial_md5_checksum
    if md5 and books[md5] then
        books[md5] = nil
        changed   = true
    end
    local path_md5 = _findByPath(books, fp)
    if path_md5 then
        books[path_md5] = nil
        changed         = true
    end
    return changed
end

--- Brings the ledger in line with the sidecars of the books in the reading
--- history (the most recent ones, up to _HISTORY_SCAN_LIMIT) and flags the
--- books whose file has disappeared. Returns whether it ran, and whether the
--- ledger changed.
local function _reconcile(ledger)
    local ReadHistory = package.loaded["readhistory"]
    local SH          = _booksModule()
    if not (ReadHistory and ReadHistory.hist and SH and SH.sidecarData) then
        logger.warn("simpleui: stats_provider: history or sidecar cache unavailable")
        return false, false
    end

    local changed = not ledger.initialised
    for i = 1, math.min(#ReadHistory.hist, _HISTORY_SCAN_LIMIT) do
        local fp   = ReadHistory.hist[i] and ReadHistory.hist[i].file
        local view = fp and SH.sidecarData(fp, true)
        if view then changed = _applyBook(ledger, fp, view) or changed end
    end
    for _, entry in pairs(ledger.books) do
        if not entry.gone and entry.path and lfs.attributes(entry.path, "mode") ~= "file" then
            entry.gone = true
            changed    = true
        end
    end

    ledger.initialised = true
    _reconciled_day    = os.date("%Y-%m-%d")
    return true, changed
end

--- The ledger, reconciled on first use.
local function _loadLedger()
    local store  = _finishedBooksStore()
    local ledger = store.load()
    if not ledger.initialised then
        local _, changed = _reconcile(ledger)
        if changed then store.save(ledger) end
    end
    return ledger
end

--- The ledger for counts and lists: additionally reconciled once per calendar
--- day.
local function _reconciledLedger()
    local ledger = _loadLedger()
    if _reconciled_day ~= os.date("%Y-%m-%d") then
        local _, changed = _reconcile(ledger)
        if changed then _finishedBooksStore().save(ledger) end
    end
    return ledger
end

-- A book is listed and counted unless its file is gone and gone books are
-- not being preserved; excluded books are listed but not counted.
local function _isListed(entry, preserve)
    return preserve or not entry.gone
end

local function _manualEntry(id, stored)
    return {
        key           = id,
        title         = stored.title,
        authors       = stored.authors,
        year          = _storedYear(stored),
        date_started  = stored.started,
        date_finished = stored.finished,
        manual        = true,
        count         = stored.count,
    }
end

-- `id` is the ledger key: a partial md5, or "manual:..." for a manual entry.
local function _bookEntry(id, stored)
    if stored.manual then return _manualEntry(id, stored) end

    local entry = {
        key                = "md5:" .. id,
        title              = stored.title,
        authors            = stored.authors,
        md5                = id,
        year               = _storedYear(stored),
        exclude_from_goals = stored.excluded,
        preserved          = stored.gone,
    }
    if stored.gone then return entry end

    local SH      = _booksModule()
    local data    = SH and SH.sidecarData and SH.sidecarData(stored.path, true)
    local summary = data and type(data.summary) == "table" and data.summary or {}
    entry.key           = stored.path
    entry.filepath      = stored.path
    entry.title         = data and data.title or stored.title
    entry.date_started  = _stringOrNil(summary.date_started)
    entry.date_finished = _stringOrNil(summary.date_finished) or _stringOrNil(summary.modified)
    return entry
end

-- Most recently finished first; a year-only entry follows the dated ones of
-- its year.
local function _newerFirst(a, b)
    local key_a = a.date_finished or tostring(a.year or "")
    local key_b = b.date_finished or tostring(b.year or "")
    if key_a ~= key_b then return key_a > key_b end
    if a.title ~= b.title then return (a.title or "") < (b.title or "") end
    return a.key < b.key
end

--- Finished books (see entry fields above), restricted to `year` (integer)
--- when given.
function SP.getFinishedBooks(year)
    local ledger   = _reconciledLedger()
    local preserve = _finishedBooksStore().preserveGone()
    local books    = {}
    for md5, stored in pairs(ledger.books) do
        if _isListed(stored, preserve) and (not year or _storedYear(stored) == year) then
            books[#books + 1] = _bookEntry(md5, stored)
        end
    end
    table.sort(books, _newerFirst)
    return books
end

--- Oldest and newest completion year among the listed finished books. The
--- newest is never earlier than the current year.
function SP.getFinishedYears()
    local ledger   = _reconciledLedger()
    local preserve = _finishedBooksStore().preserveGone()
    local current  = tonumber(os.date("%Y"))
    local min_year, max_year = current, current
    for _, stored in pairs(ledger.books) do
        local year = _isListed(stored, preserve) and _storedYear(stored)
        if year then
            min_year = math.min(min_year, year)
            max_year = math.max(max_year, year)
        end
    end
    return min_year, max_year
end

--- Number of books in `books` that count towards totals and goals.
function SP.countFinished(books)
    local count = 0
    for _, book in ipairs(books) do
        if not book.exclude_from_goals then count = count + (book.count or 1) end
    end
    return count
end

-- Returns the counts for `year_str` and for all time. Manual books always
-- count towards their year; they count towards all time only when enabled.
local function countFinishedBooks(year_str)
    local ledger     = _reconciledLedger()
    local store      = _finishedBooksStore()
    local preserve   = store.preserveGone()
    local manual_all = store.manualInAllTime()
    local year       = tonumber(year_str)
    local in_year, total = 0, 0
    for _, entry in pairs(ledger.books) do
        if not entry.excluded and _isListed(entry, preserve) then
            local count = entry.count or 1
            if manual_all or not entry.manual then total = total + count end
            if _storedYear(entry) == year then in_year = in_year + count end
        end
    end
    return in_year, total
end

--- Completion date a book's summary should carry. A book that is not
--- complete carries none. A complete book keeps its date; one without it gets
--- the date the ledger recorded for it, or today when the ledger has not seen
--- it finished. Nil when the date is unknown.
local function _expectedFinishedDate(ledger, fp, summary, md5)
    if summary.status ~= "complete" then return nil end
    if summary.date_finished then return summary.date_finished end
    if not ledger.initialised then return nil end

    local _, known = _findEntry(ledger.books, fp, md5)
    if not known then return os.date("%Y-%m-%d") end
    return _isFullDate(known.finished) and known.finished or nil
end

--- Aligns summary.date_finished with the book's status through the given
--- settings object and flushes it when it changed. KOReader rewrites
--- summary.modified on every status change, so without this date the
--- completion year would follow the last status change.
local function _syncFinishedDate(ledger, fp, doc_settings)
    local summary = doc_settings:readSetting("summary")
    if type(summary) ~= "table" then return end

    local date = _expectedFinishedDate(ledger, fp, summary,
        doc_settings:readSetting("partial_md5_checksum"))
    if date == summary.date_finished then return end
    summary.date_finished = date
    doc_settings:saveSetting("summary", summary)
    doc_settings:flush()
end

--- Sidecar fields of `fp`: from the settings object of a document open in the
--- reader (newer than the sidecar on disk), else from the shared sidecar cache.
local function _readView(fp, doc_settings)
    if doc_settings then return _liveView(fp, doc_settings) end
    local SH = _booksModule()
    return SH and SH.sidecarData and SH.sidecarData(fp, true)
end

--- Applies `view` to the ledger and persists it when it changed.
local function _record(fp, view)
    local ledger = _loadLedger()
    if not _applyBook(ledger, fp, view) then return false end
    _finishedBooksStore().save(ledger)
    return true
end

--- Records the current state of `fp` in the ledger. `doc_settings` is the
--- settings object of a document open in the reader, whose in-memory state is
--- newer than the sidecar on disk. Returns true when the ledger changed.
function SP.syncBook(fp, doc_settings)
    local view = _readView(fp, doc_settings)
    return view ~= nil and _record(fp, view)
end

--- Flags every screen for a rebuild the next time it is shown, so the new
--- counts and book states are painted.
local function _flagScreensStale()
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if ScreenEngine and ScreenEngine.markAllStale then ScreenEngine.markAllStale() end
end

local function _openDocSettings(fp)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return nil end
    local ok_open, doc_settings = pcall(DocSettings.open, DocSettings, fp)
    return ok_open and doc_settings or nil
end

--- Single entry point for every change to a book's completion state, dates
--- or goal exclusion: drops the shared sidecar cache entry, updates the
--- ledger, invalidates the counts and flags the screens.
--- Options:
---   doc_settings    settings object of a document open in the reader
---   status_changed  the book's status was just changed: its completion date
---                   is aligned with the new status first
--- Returns true when the book is finished.
function SP.bookChanged(fp, opts)
    opts = opts or {}
    local doc_settings = opts.doc_settings
    if opts.status_changed then
        local target = doc_settings or _openDocSettings(fp)
        if target then _syncFinishedDate(_loadLedger(), fp, target) end
    end

    local SH = _booksModule()
    if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache(fp) end
    local view = _readView(fp, doc_settings)
    if view then _record(fp, view) end

    SP.invalidateBooks()
    SP.invalidateStatusCounts()
    _flagScreensStale()
    return view ~= nil and type(view.summary) == "table" and view.summary.status == "complete"
end

local function _isUnderAny(path, roots)
    for _, root in ipairs(roots) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
    end
    return false
end

--- Flags the finished books at or under any of `paths` (files or folders) as
--- gone from the device.
function SP.markBooksGone(paths)
    local ledger  = _loadLedger()
    local changed = false
    for _, entry in pairs(ledger.books) do
        if not entry.gone and entry.path and _isUnderAny(entry.path, paths) then
            entry.gone = true
            changed    = true
        end
    end
    if not changed then return end
    _finishedBooksStore().save(ledger)
    SP.invalidateBooks()
    SP.invalidateStatusCounts()
    _flagScreensStale()
end

-- ---------------------------------------------------------------------------
-- Manual books
--
-- Books entered by hand live in the ledger as "manual:" entries (see
-- infra/sui_store). Every change goes through the functions below, which
-- persist the ledger, drop the cached counts and flag the screens.
-- ---------------------------------------------------------------------------

local function _commitManual(ledger)
    _finishedBooksStore().save(ledger)
    SP.invalidateBooks()
    _flagScreensStale()
end

local function _bulkKey(year)
    return string.format("manual:bulk:%04d", year)
end

local function _newManualKey(books)
    local key
    repeat
        key = string.format("manual:%x%03x", os.time(), math.random(0, 4095))
    until not books[key]
    return key
end

--- Number of books entered as a plain number for `year` (integer).
function SP.getManualCount(year)
    local entry = _loadLedger().books[_bulkKey(year)]
    return entry and entry.count or 0
end

--- Total number of books entered by hand, individually or as plain numbers.
function SP.getManualBookCount()
    local total = 0
    for _, stored in pairs(_loadLedger().books) do
        if stored.manual then total = total + (stored.count or 1) end
    end
    return total
end

--- Sets the number of books entered as a plain number for `year` (integer).
--- Zero removes the entry.
function SP.setManualCount(year, count)
    local ledger = _loadLedger()
    ledger.books[_bulkKey(year)] = count > 0
        and { manual = true, count = count, finished = string.format("%04d", year) }
        or nil
    _commitManual(ledger)
end

--- Creates a manual book, or replaces the one stored under `key`. `fields`:
--- title, authors, started, finished (stamps, either may be nil). Returns
--- the key of the entry.
function SP.saveManualBook(key, fields)
    local ledger = _loadLedger()
    key = key or _newManualKey(ledger.books)
    ledger.books[key] = {
        manual   = true,
        title    = fields.title,
        authors  = fields.authors or "",
        started  = fields.started,
        finished = fields.finished,
    }
    _commitManual(ledger)
    return key
end

--- Removes the manual entry stored under `key`; any other key is ignored.
function SP.removeManualBook(key)
    local ledger = _loadLedger()
    local entry  = ledger.books[key]
    if not (entry and entry.manual) then return end
    ledger.books[key] = nil
    _commitManual(ledger)
end

-- ---------------------------------------------------------------------------
-- Status counts (unread / reading / complete / abandoned)
-- ---------------------------------------------------------------------------
-- Whole-library breakdown by reading status. reading_stats' status_* cards
-- only surface unread/reading/abandoned (a "Status — Finished" card would
-- near-duplicate total_books), but this returns all four so callers can
-- decide which to show.
--
-- Unlike the finished-books scan above, which only sees books present in
-- ReadHistory (i.e. opened at least once), this needs every book in the
-- library, so it walks sui_library_scan's file list — itself mtime-cached
-- per directory — and classifies each one from its sidecar percent/status,
-- reusing the same module_books_shared cache as the finished-books scan.
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
    local home = ok_scan and LibraryScan and LibraryScan.resolveHomeDir()
    local SH   = package.loaded["modules/module_books_shared"]
    if not (home and SH and SH.sidecarData) then
        _status_cache = counts
        return counts
    end

    for _, fp in ipairs(LibraryScan.getFileList(home)) do
        local data    = SH.sidecarData(fp, true)
        local percent = data and data.percent
        local status  = data and type(data.summary) == "table" and data.summary.status or nil
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

--- Updates the ledger and the cached status counts for the book that was just
--- closed in the reader. The reader's live settings are newer than the sidecar
--- on disk and stay valid until the reader widget closes, so this must run
--- from the close handler.
function SP.syncClosedBook(fp)
    local ReaderUI     = package.loaded["apps/reader/readerui"]
    local ui           = ReaderUI and ReaderUI.instance
    local doc_settings = ui and type(ui.doc_settings) == "table" and ui.doc_settings or nil
    if doc_settings and SP.syncBook(fp, doc_settings) then SP.invalidateBooks() end

    -- The pre-session state comes from the sidecar cache; without an entry the
    -- bucket the book left is unknown, so the counts are recomputed instead.
    local SH     = _booksModule()
    local get    = SH and (SH._cacheGetRaw or SH._cacheGet)
    local cached = get and get(fp)
    if not cached then
        SP.invalidateStatusCounts()
        return
    end

    local pre_summary  = cached.summary
    local post_summary = doc_settings and doc_settings:readSetting("summary")
    local footer       = ui and ui.view and ui.view.footer
    local post_percent = footer and footer.percent_finished
        or doc_settings and doc_settings:readSetting("percent_finished")
    SP.applyStatusChange(fp,
        cached.percent, type(pre_summary) == "table" and pre_summary.status or nil,
        post_percent,   type(post_summary) == "table" and post_summary.status or nil)
end

--- Forces the next SP.getStatusCounts() call to recompute. Called from
--- SP.invalidate() so status counts share the same invalidation triggers as
--- the rest of this provider.
function SP.invalidateStatusCounts()
    _status_cache = nil
end

-- Partial-invalidation flag, declared here so SP.get(), SP.invalidate() and
-- SP.invalidateTimeSeries() all close over the same local.
--   _streak_cache_valid: set when the streak is known-unchanged; consumed and
--     cleared by SP.get(). (_books_dirty, declared with the finished-books
--     code, is the equivalent for the book counts.)
local _streak_cache_valid = false

-- ---------------------------------------------------------------------------
-- SP.get(db_conn, year_str, needs_books) — main entry point.
--
-- db_conn:     shared ljsqlite3 connection from ctx.db_conn (may be nil if
--              the DB is unavailable; returns a zero-filled table then).
-- year_str:    current year as a string, e.g. "2025" — pass ctx.year_str.
-- needs_books: when true, fills books_year/books_total from the finished-books
--              ledger. Pass false when no active module consumes those
--              fields. Defaults to true.
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
    -- also carry up-to-date books data — books_total > 0 isn't a reliable
    -- sentinel for a user with zero finished books, so completeness is
    -- tracked with the explicit `_has_books` flag instead.
    if _cache and _cache_day == today_str then
        if not needs_books or (_cache._has_books and not _books_dirty) then
            return _cache
        end
        -- DB fields are already correct; only the book counts need to run.
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
        local by, bt = countFinishedBooks(year_str or tostring(t.year))
        result.books_year  = by
        result.books_total = bt
        _books_dirty = false
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
        _changed      = { timeseries = true, streak = not streak_carried, books = true },
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

    -- ── Finished-book counts (year + total, from the ledger) ──────────────
    if not needs_books then
        -- No consumer needs books_year/books_total: leave them at zero.
        -- Not cached under today_str, so a later needs_books=true call on
        -- the same day still fills them instead of reading zeros.
        return result
    end
    local by, bt = countFinishedBooks(year_str or tostring(t.year))
    local previous = _cache
    result.books_year  = by
    result.books_total = bt
    result._changed.books = not (previous and previous._has_books
        and previous.books_year == by and previous.books_total == bt)
    _books_dirty = false

    result._has_books = true
    _cache     = result
    _cache_day = today_str
    _persistStaleStats(result)
    return result
end

-- ---------------------------------------------------------------------------
-- SP.invalidate() — force a full re-fetch on the next SP.get() call.
-- Preserves _cache (SP.getStale() needs it for the stale first-paint) but
-- clears _cache_day so the next call re-runs every DB query. Status counts are dropped too, unless the caller
-- has already adjusted them through SP.applyStatusChange (keep_status_counts).
-- Call from: main.lua:onCloseDocument, sui_homescreen:onShow (when
-- _stats_need_refresh is set), module_reading_goals dialogs.
-- ---------------------------------------------------------------------------
function SP.invalidate(keep_status_counts)
    _cache_day          = nil
    _streak_cache_valid = false
    if not keep_status_counts then SP.invalidateStatusCounts() end
end

-- ---------------------------------------------------------------------------
-- SP.invalidateTimeSeries() — partial invalidation for the common case: a
-- reading session ended, so the DB-derived fields are refetched while the
-- finished-book counts are only recomputed when SP.invalidateBooks() flagged
-- them.
--
-- Streak is preserved too, but only within the same calendar day the cache
-- was built on — the streak can only change on the first session of a new
-- day, so any later close that day is a safe no-op to skip.
-- ---------------------------------------------------------------------------
function SP.invalidateTimeSeries()
    if not _cache then return end
    _streak_cache_valid = _cache_day == os.date("%Y-%m-%d") and _cache.today_secs > 0
    _cache_day          = nil
end

-- ---------------------------------------------------------------------------
-- SP.invalidateStreak() — forces the next SP.get() to recount the streak.
-- For changes to the streak's inputs that do not come from reading activity
-- (freeze state), where the same-day carry-over of invalidateTimeSeries()
-- would keep serving the old value.
-- ---------------------------------------------------------------------------
function SP.invalidateStreak()
    if not _cache then return end
    _streak_cache_valid = false
    _cache_day          = nil
end

-- ---------------------------------------------------------------------------
-- SP.invalidateBooks() — forces the next SP.get() to recount the finished
-- books while the cached time series and streak stay valid. Called whenever
-- the ledger changed or the way gone books are counted did.
-- ---------------------------------------------------------------------------
function SP.invalidateBooks()
    _books_dirty = true
end

-- ---------------------------------------------------------------------------
-- SP.rescanBooks() — full refresh for the "Update Stats Now" actions: the next
-- SP.get() reconciles the finished-books ledger against the sidecars of the
-- reading history, picking up changes made outside the plugin, and recomputes
-- everything else as SP.invalidate() does.
-- ---------------------------------------------------------------------------
function SP.rescanBooks()
    _reconciled_day = nil
    SP.invalidate()
end

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
