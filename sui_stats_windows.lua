-- sui_stats_windows.lua — Simple UI
-- Aggregates various statistics windows.

local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("sui_i18n").translate
local N_              = require("sui_i18n").ngettext
local logger          = require("logger")
local Config          = require("sui_config")
local SUIStyle        = require("sui_style")
local UI              = require("sui_core")
local SUIStreak       = require("sui_streak")

-- Landscape-aware size multiplier for the few call sites in this file that
-- run BEFORE any SUIWindow ctx exists — e.g. shared fonts computed once in
-- StatsWindows.showFinishedBooksDialog's setup, ahead of its buildListScreen/
-- buildStatsScreen closures. UI.SZ() is live (recomputed from screen
-- dimensions on every call, see sui_core.lua), so it's correct to call here
-- even before a window/ctx is built.
--
-- Every actual screen builder in this file (functions that receive ctx, and
-- anything nested inside them) uses ctx.SZ(n) instead — the same scale
-- SUIWindow's own chrome uses, handed in for free, no import needed. The
-- handful of standalone helpers that build screen content but aren't
-- themselves screen builders (_makeDateCard, _riYearHeader, _riYearlyRow,
-- _riMonthlyChart, _buildInsightsPage2) take SZ as an explicit trailing
-- parameter from their caller's ctx.SZ, falling back to UI.SZ if ever called
-- without one.
local function SZ(n) return UI.SZ(n) end

local StatsWindows = {}

local function _getYearStr() return os.date("%Y") end

-- Returns a list of {title, authors} for books marked "complete" this calendar year.
-- Reuses the sidecar cache warmed by module_stats_provider / module_books_shared,
-- so in the common case no extra DS.open() calls are needed.
local function _getFinishedBooksThisYear()
    local year_str = _getYearStr()
    local books    = {}

    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if not ok_rh or not ReadHistory or not ReadHistory.hist then return books end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return books end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return books end

    -- Borrow the shared sidecar cache from module_books_shared when available.
    local SH = package.loaded["desktop_modules/module_books_shared"]

    -- Mirrors _modifiedInYear from module_stats_provider — same logic, no dependency.
    -- Only summary.date_finished or a STRING summary.modified is accepted as a
    -- completion-year signal.  A numeric modified (KOReader unix timestamp) is
    -- rewritten on every reader session close and must NOT be used as a
    -- "completed this year" indicator — see module_stats_provider.lua for rationale.
    local function modifiedInYear(summary)
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

    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local summary, title, authors, md5_checksum

            -- Fast path: hit the shared sidecar cache.
            if SH and SH._cacheGet then
                local cached = SH._cacheGet(fp)
                if cached then
                    summary      = cached.summary
                    title        = cached.title
                    authors      = cached.authors
                    md5_checksum = cached.partial_md5_checksum
                end
            end

            -- Slow path: open the sidecar directly (first run or after invalidation).
            if summary == nil then
                local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
                if ok_open and ds then
                    summary         = ds:readSetting("summary")
                    local doc_props = ds:readSetting("doc_props")
                    if doc_props then
                        title   = doc_props.title
                        authors = doc_props.authors
                    end
                    md5_checksum = ds:readSetting("partial_md5_checksum")
                    -- Warm the shared cache so subsequent calls are free.
                    if SH and SH._cachePut and ds.source_candidate then
                        local stats = ds:readSetting("stats")
                        SH._cachePut(fp, ds.source_candidate, {
                            percent              = ds:readSetting("percent_finished") or 0,
                            title                = title,
                            authors              = authors,
                            doc_pages            = ds:readSetting("doc_pages"),
                            partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                            stat_pages           = stats and stats.pages,
                            stat_total_time      = stats and stats.total_time_in_sec,
                            summary              = summary,
                        })
                    end
                    pcall(function() ds:close() end)
                end
            end

            if type(summary) == "table"
               and summary.status == "complete"
               and modifiedInYear(summary) then
                table.insert(books, {
                    title         = title   or entry.text or fp,
                    authors       = authors or "",
                    filepath      = fp,
                    date_finished = (type(summary.date_finished) == "string" and summary.date_finished)
                                    or (type(summary.modified)   == "string" and summary.modified)
                                    or nil,
                    date_started  = (type(summary.date_started) == "string" and summary.date_started) or nil,
                    md5           = md5_checksum,
                    exclude_from_goals = summary.exclude_from_goals,
                })
            end
        end
    end
    return books
end

-- Fetches all statistics for a book from statistics.sqlite3.
-- Returns a data table on success, or nil + error string on failure.
local function _fetchBookStatsData(book, range_start, range_end)
    local fp = book and book.filepath
    if not fp then return nil, _("No filepath.") end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then
        return nil, _("Statistics database library not available.")
    end
    local db_path = Config.getStatsDbPath()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and not lfs.attributes(db_path, "mode") then
        return nil, _("No statistics found for this book.")
    end
    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then
        return nil, _("Could not open statistics database.")
    end

    -- Resolve md5 -> book id
    local md5
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.hasSidecarFile
       and DocSettings:hasSidecarFile(fp) then
        local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
        if ok_open and ds then
            md5 = ds:readSetting("partial_md5_checksum")
            pcall(function() ds:close() end)
        end
    end
    if not md5 then
        local ok_util, util = pcall(require, "util")
        if ok_util and util and util.partialMD5 then
            md5 = util.partialMD5(fp)
        end
    end

    local id_book
    if md5 then
        local ok_q, row = pcall(function()
            return conn:rowexec(string.format(
                "SELECT id FROM book WHERE md5 = '%s' LIMIT 1", md5))
        end)
        if ok_q then id_book = row and tonumber(row) or nil end
    end
    if not id_book then
        pcall(function() conn:close() end)
        return nil, _("No statistics found for this book.")
    end

    local title, authors, pages, last_open, highlights, notes
    pcall(function()
        title, authors, pages, last_open, highlights, notes = conn:rowexec(
            string.format([[
                SELECT title, authors, pages, last_open, highlights, notes
                FROM book WHERE id = %d
            ]], id_book))
    end)
    highlights = tonumber(highlights) or 0
    notes      = tonumber(notes)      or 0

    -- The DB highlights counter is updated incrementally (only counts
    -- highlights added during active sessions after the book was first
    -- registered).  For books with pre-existing annotations, or books
    -- finished before SimpleUI 2.0, the counter under-counts.
    -- Re-count directly from the sidecar bookmarks when fp is available,
    -- mirroring ReaderAnnotation:getNumberOfHighlightsAndNotes() logic:
    --   annotations with drawer ~= nil are highlights/notes;
    --   those that also have note are notes, the rest are highlights.
    if fp then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds then
            local ok_open, ds = pcall(function() return DocSettings:open(fp) end)
            if ok_open and ds then
                local bm = ds:readSetting("bookmarks")
                if type(bm) == "table" then
                    local hl_count, note_count = 0, 0
                    for _, item in ipairs(bm) do
                        if item.drawer then
                            if item.note then
                                note_count = note_count + 1
                            else
                                hl_count = hl_count + 1
                            end
                        end
                    end
                    -- Only override if the sidecar has any annotations; an
                    -- empty table means the book was never opened with the
                    -- annotation system active, so fall back to the DB value.
                    if hl_count + note_count > 0 or highlights + notes == 0 then
                        highlights = hl_count
                        notes      = note_count
                    end
                end
                pcall(function() ds:close() end)
            end
        end
    end

    local MAX_SEC = 120
    pcall(function()
        local v = G_reader_settings and G_reader_settings:readSetting("statistics_max_sec")
        if v and tonumber(v) then MAX_SEC = tonumber(v) end
    end)

    local total_days, total_time_book, total_read_pages, book_read_time
    pcall(function()
        -- Optional date-range filter: when the user has edited the start/end
        -- date on this book's stats card, only sessions that started within
        -- [range_start, range_end] count towards days/total time/avg per day
        -- etc. Left unfiltered (both nil) this reproduces the full-history
        -- query exactly as before.
        local range_clause = ""
        if range_start then range_clause = range_clause .. string.format(" AND start_time >= %d", range_start) end
        if range_end   then range_clause = range_clause .. string.format(" AND start_time <= %d", range_end) end
        total_days, total_time_book, total_read_pages, book_read_time = conn:rowexec(
            string.format([[
                WITH ps_agg AS (
                    SELECT page,
                           sum(duration) AS page_dur,
                           min(start_time) AS first_start
                    FROM page_stat
                    WHERE id_book = %d%s
                    GROUP BY page
                )
                SELECT
                    count(DISTINCT date(first_start, 'unixepoch', 'localtime')),
                    sum(page_dur),
                    count(*),
                    sum(min(page_dur, %d))
                FROM ps_agg
            ]], id_book, range_clause, MAX_SEC))
    end)

    local first_open, last_page
    pcall(function()
        first_open, last_page = conn:rowexec(
            string.format([[
                SELECT min(start_time),
                       (SELECT max(ps2.page) FROM page_stat AS ps2
                        WHERE ps2.id_book = %d AND ps2.start_time = max(page_stat.start_time))
                FROM page_stat WHERE id_book = %d
            ]], id_book, id_book))
    end)

    pcall(function() conn:close() end)

    local now_ts = os.time()
    total_days       = tonumber(total_days)       or 0
    total_time_book  = tonumber(total_time_book)  or 0
    total_read_pages = tonumber(total_read_pages) or 0
    local book_read_pages = total_read_pages
    book_read_time   = tonumber(book_read_time)   or 0
    first_open       = tonumber(first_open)        or now_ts
    last_open        = tonumber(last_open)         or now_ts
    last_page        = tonumber(last_page)         or 0
    pages            = tonumber(pages)
    if not pages or pages == 0 then pages = 1 end

    local avg_time_per_page = (book_read_pages > 0) and (book_read_time / book_read_pages) or 0
    local avg_time_per_day  = (total_days > 0)      and (book_read_time / total_days)      or 0

    return {
        title            = title   or book.title   or "",
        authors          = authors or book.authors or "",
        pages            = pages,
        last_open        = last_open,
        first_open       = first_open,
        last_page        = last_page,
        total_time_book  = total_time_book,
        book_read_time   = book_read_time,
        book_read_pages  = book_read_pages,
        total_read_pages = total_read_pages,
        total_days       = total_days,
        avg_time_per_page= avg_time_per_page,
        avg_time_per_day = avg_time_per_day,
        highlights       = highlights,
        notes            = notes,
    }
end

local function _getStartDatesForBooks(books)
    local start_dates = {}
    if not books or #books == 0 then return start_dates end

    -- Books that already have a sidecar date_started skip the DB entirely.
    local needs_db = {}
    local md5_map  = {}
    local md5_list_q = {}
    local util = require("util")

    for _, book in ipairs(books) do
        local fp = book.filepath
        if type(book.date_started) == "string" then
            -- Sidecar value takes priority; store as string so _fmtDateRange
            -- can handle it (it accepts both unix timestamps and YYYY-MM-DD).
            start_dates[fp] = book.date_started
        else
            table.insert(needs_db, book)
            local md5 = book.md5 or util.partialMD5(fp)
            if md5 then
                md5_map[md5] = fp
                table.insert(md5_list_q, string.format("'%s'", md5))
            end
        end
    end

    if #md5_list_q == 0 then return start_dates end

    -- Query DB once for all books that still need it.
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return start_dates end

    local db_path = Config.getStatsDbPath()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs.attributes(db_path, "mode")) then return start_dates end

    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not (ok_conn and conn) then return start_dates end

    local sql = string.format([[
        SELECT b.md5, MIN(ps.start_time)
        FROM page_stat ps JOIN book b ON ps.id_book = b.id
        WHERE b.md5 IN (%s)
        GROUP BY b.id
    ]], table.concat(md5_list_q, ","))

    local rw
    pcall(function() rw = conn:exec(sql) end)
    if rw and rw[1] and rw[2] then
        for i = 1, #rw[1] do
            local md5 = rw[1][i]
            local start_time = rw[2][i]
            local fp = md5_map[md5]
            if fp then
                start_dates[fp] = tonumber(start_time)
            end
        end
    end

    pcall(conn.close, conn)
    return start_dates
end

-- Lazy-loaded widget classes
local _CenterContainer, _LeftContainer, _RightContainer,
      _Size, _TextBoxWidget

local function _lazyLoad()
    if _CenterContainer then return end
    _CenterContainer = require("ui/widget/container/centercontainer")
    _LeftContainer   = require("ui/widget/container/leftcontainer")
    _RightContainer  = require("ui/widget/container/rightcontainer")
    _Size            = require("ui/size")
    _TextBoxWidget   = require("ui/widget/textboxwidget")
end

local _MONTH_ABBR
local function _monthAbbr()
    if not _MONTH_ABBR then
        _MONTH_ABBR = {
            _("jan"), _("feb"), _("mar"), _("apr"), _("may"), _("jun"),
            _("jul"), _("aug"), _("sep"), _("oct"), _("nov"), _("dec"),
        }
    end
    return _MONTH_ABBR
end

local function _parseDate(val)
    if not val then return nil end
    local y, m, d
    if type(val) == "string" then
        y, m, d = val:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
        y, m, d = tonumber(y), tonumber(m), tonumber(d)
    elseif type(val) == "number" then
        local t = os.date("*t", val)
        if t then y, m, d = t.year, t.month, t.day end
    end
    if y and m and d then return { y = y, m = m, d = d } end
    return nil
end

local function _fmtDateRange(start_ts, finish_str)
    local abbr = _monthAbbr()
    local sf   = _parseDate(finish_str)
    local ss   = _parseDate(start_ts)
    if not sf then return "\xe2\x80\x93" end
    local finish_part = string.format("%02d %s %d", sf.d, abbr[sf.m] or "?", sf.y)
    if not ss then return finish_part end
    if ss.y == sf.y then
        return string.format("%02d %s \xe2\x80\x93 %s", ss.d, abbr[ss.m] or "?", finish_part)
    else
        return string.format("%02d %s %d \xe2\x80\x93 %s",
            ss.d, abbr[ss.m] or "?", ss.y, finish_part)
    end
end

local function _fmtDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0s" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then
        return string.format("%dh %02dm", h, m)
    elseif m > 0 then
        return string.format("%dm %02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function _fmtDate(ts)
    return os.date("%Y-%m-%d", ts)
end

-- Converts a "YYYY-MM-DD" string to a unix timestamp: start of day (00:00:00)
-- by default, or end of day (23:59:59) when end_of_day is true. Used to turn
-- an edited date-range boundary into SQL-filterable timestamps.
local function _dateStrToTs(date_str, end_of_day)
    if type(date_str) ~= "string" then return nil end
    local y, m, d = date_str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    return os.time{
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = end_of_day and 23 or 0,
        min  = end_of_day and 59 or 0,
        sec  = end_of_day and 59 or 0,
    }
end

-- Validates a YYYY-MM-DD string; returns true if the date is well-formed.
local function _isValidDateStr(s)
    if type(s) ~= "string" then return false end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) then return false end
    if m < 1 or m > 12 then return false end
    if d < 1 or d > 31 then return false end
    return true
end

-- Writes summary.modified (and optionally sets status = "complete") to the
-- sidecar, then flushes it.  Invalidates the module_books_shared cache entry
-- so the next homescreen refresh picks up the new value.
local function _writeSummaryModified(filepath, date_str)
    if not filepath or not _isValidDateStr(date_str) then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok_open, ds = pcall(function() return DocSettings:open(filepath) end)
    if not ok_open or not ds then return false end
    local summary = ds:readSetting("summary") or {}
    summary.modified = date_str
    summary.date_finished = date_str
    if summary.status ~= "complete" then
        summary.status = "complete"
    end
    ds:saveSetting("summary", summary)
    pcall(function() ds:flush() end)
    pcall(function() ds:close() end)
    -- Invalidate shared sidecar cache if available.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH then
        if SH._cacheInvalidate then
            SH._cacheInvalidate(filepath)
        elseif SH._cache and filepath then
            SH._cache[filepath] = nil
        end
    end
    return true
end

-- Writes summary.date_started to the sidecar and flushes it.
-- This is a SimpleUI-only field; KOReader ignores unknown sidecar keys.
local function _writeSummaryStarted(filepath, date_str)
    if not filepath or not _isValidDateStr(date_str) then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok_open, ds = pcall(function() return DocSettings:open(filepath) end)
    if not ok_open or not ds then return false end
    local summary = ds:readSetting("summary") or {}
    summary.date_started = date_str
    ds:saveSetting("summary", summary)
    pcall(function() ds:flush() end)
    pcall(function() ds:close() end)
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH then
        if SH._cacheInvalidate then
            SH._cacheInvalidate(filepath)
        elseif SH._cache and filepath then
            SH._cache[filepath] = nil
        end
    end
    return true
end

-- Builds a date range card with independently tappable start/end halves.
--
-- Parameters:
-- Writes summary.exclude_from_goals to the sidecar and flushes it.
local function _writeSummaryExclude(filepath, val)
    if not filepath then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok_open, ds = pcall(function() return DocSettings:open(filepath) end)
    if not ok_open or not ds then return false end
    local summary = ds:readSetting("summary") or {}
    summary.exclude_from_goals = val and true or nil
    ds:saveSetting("summary", summary)
    pcall(function() ds:flush() end)
    pcall(function() ds:close() end)
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH then
        if SH._cacheInvalidate then
            SH._cacheInvalidate(filepath)
        elseif SH._cache and filepath then
            SH._cache[filepath] = nil
        end
    end
    return true
end

-- Removes a single key from summary in the sidecar (sets it to nil).
-- Used by the Reset button to revert to the DB-derived fallback.
local function _deleteSummaryField(filepath, key)
    if not filepath or not key then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok_open, ds = pcall(function() return DocSettings:open(filepath) end)
    if not ok_open or not ds then return false end
    local summary = ds:readSetting("summary")
    if type(summary) == "table" and summary[key] ~= nil then
        summary[key] = nil
        ds:saveSetting("summary", summary)
        pcall(function() ds:flush() end)
    end
    pcall(function() ds:close() end)
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH then
        if SH._cacheInvalidate then SH._cacheInvalidate(filepath)
        elseif SH._cache then SH._cache[filepath] = nil end
    end
    return true
end

--   inner_w           – full inner width
--   PAD_H             – horizontal padding (passed in to match caller's layout)
--   date_start_str    – string to display on the left  (YYYY-MM-DD or "–")
--   date_end_str      – string to display on the right (YYYY-MM-DD or "–")
--   original_start_str – DB-derived fallback for start (shown on Reset)
--   original_end_str   – DB-derived fallback for end   (shown on Reset)
--   filepath          – used for sidecar writes; if nil the card is read-only
--   on_start_saved    – function(new_date) called after a valid start edit or reset
--   on_end_saved      – function(new_date) called after a valid end edit or reset
--
-- Returns a FrameContainer with each date half wrapped in its own
-- InputContainer.  Tapping opens an InputDialog with Cancel / Reset / Save.
-- SZ is threaded in by the caller (ctx.SZ) since this is a standalone helper,
-- not itself a screen builder with ctx in scope; falls back to UI.SZ if ever
-- called without one (identical value during a synchronous window build).
local function _makeDateCard(inner_w, PAD_H,
                             date_start_str, date_end_str,
                             original_start_str, original_end_str,
                             filepath,
                             on_start_saved, on_end_saved, SZ)
    SZ = SZ or UI.SZ
    local face_date  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_arrow = Font:getFace(SUIStyle.FACE_ICONS,   SZ(SUIStyle.FS_BODY))
    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local ARROW      = SUIStyle.icon("arrow_right")
    local date_inner = inner_w - 2 * PAD_H
    local date_third = math.floor(date_inner / 3)
    local date_row_h = SZ(Screen:scaleBySize(24))

    -- Helper: open an InputDialog for a single date field.
    -- delete_fn  – called with filepath on Reset to remove the sidecar field
    -- original   – the DB fallback value passed to on_saved after a reset
    -- has_custom – true when the displayed value came from the sidecar (not DB)
    local function openDateDialog(title, current, write_fn, delete_fn,
                                  original, has_custom, on_saved)
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title      = title,
            input      = current or os.date("%Y-%m-%d"),
            input_hint = "YYYY-MM-DD",
            input_type = "string",
            buttons    = {{
                {
                    text     = _("Cancel"),
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text    = _("Reset"),
                    enabled = has_custom,
                    callback = function()
                        UIManager:close(dlg)
                        delete_fn(filepath)
                        on_saved(original)
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local val = dlg:getInputText()
                        if not _isValidDateStr(val) then
                            local InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(InfoMessage:new{
                                text = _("Please enter a date in YYYY-MM-DD format."),
                            })
                            return
                        end
                        UIManager:close(dlg)
                        if write_fn(filepath, val) then
                            on_saved(val)
                        end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
    end

    -- Build each of the three columns.  Start/end are tappable when filepath
    -- is set; the arrow column is always passive.
    local function makeSideTappable(display_str, title_str, write_fn,
                                    delete_fn, original_str, on_saved_cb)
        local tw = TextWidget:new{
            text    = display_str,
            face    = face_date,
            fgcolor = CLR_BLACK,
        }
        local cc = _CenterContainer:new{
            dimen = Geom:new{ w = date_third, h = date_row_h },
            tw,
        }
        if not filepath then return cc end
        local ic = InputContainer:new{
            dimen = Geom:new{ w = date_third, h = date_row_h },
            cc,
        }
        ic.ges_events = {
            Tap = { GestureRange:new{
                ges   = "tap",
                range = function() return ic.dimen end,
            }},
        }
        -- has_custom: the displayed value differs from the DB fallback, meaning
        -- a sidecar value is in effect and Reset makes sense.
        local has_custom = (display_str ~= original_str)
        function ic:onTap()
            openDateDialog(title_str, display_str, write_fn, delete_fn,
                           original_str, has_custom, on_saved_cb)
            return true
        end
        return ic
    end

    local start_widget = makeSideTappable(
        date_start_str, _("Date started"),
        _writeSummaryStarted,
        function(fp) _deleteSummaryField(fp, "date_started") end,
        original_start_str,
        on_start_saved)

    local end_widget = makeSideTappable(
        date_end_str, _("Date finished"),
        _writeSummaryModified,
        function(fp)
            _deleteSummaryField(fp, "date_finished")
            _deleteSummaryField(fp, "modified")
        end,
        original_end_str,
        on_end_saved)

    return FrameContainer:new{
        bordersize     = 0,
        radius         = SZ(Screen:scaleBySize(12)),
        background     = Blitbuffer.gray(0.08),
        padding_top    = SZ(Screen:scaleBySize(14)),
        padding_bottom = SZ(Screen:scaleBySize(14)),
        padding_left   = PAD_H,
        padding_right  = PAD_H,
        HorizontalGroup:new{
            align = "center",
            start_widget,
            _CenterContainer:new{
                dimen = Geom:new{ w = date_inner - 2 * date_third, h = date_row_h },
                TextWidget:new{
                    text    = ARROW,
                    face    = face_arrow,
                    fgcolor = CLR_BLACK,
                },
            },
            end_widget,
        },
    }
end

-- Opens a book from the stats detail screen.
-- Mirrors the openBook() logic in sui_homescreen.lua.
local function _openBookFromStats(filepath)
    if not filepath then return end
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
                      or require("apps/reader/readerui")
        ReaderUI:showReader(filepath)
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local BD        = require("ui/bidi")
    UIManager:show(ConfirmBox:new{
        text        = _("Open this file?") .. "\n\n"
                      .. BD.filename(filepath:match("([^/]+)$")),
        ok_text     = _("Open"),
        cancel_text = _("Cancel"),
        ok_callback = doOpen,
    })
end

function StatsWindows.showFinishedBooksDialog(initial_page)
    _lazyLoad()
    local SUIWindow = require("sui_window")
    local year_str  = _getYearStr()

    local books = _getFinishedBooksThisYear()

    if #books == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = string.format(_("No books finished in %s"), year_str),
        })
        return
    end

    local start_dates     = _getStartDatesForBooks(books)
    local book_date_range = {}
    for _, book in ipairs(books) do
        local fo = start_dates[book.filepath]
        book_date_range[book.filepath] = _fmtDateRange(fo, book.date_finished)
    end

    local face_stat_title  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
    local face_stat_author = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_cell_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local face_cell_val    = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_TITLE))
    local CLR_BLACK = Blitbuffer.COLOR_BLACK

    local _cell_geo
    local function _buildCellGeo(inner_w)
        if _cell_geo and _cell_geo.inner_w == inner_w then return _cell_geo end
        local sep_w      = SUIStyle.BORDER_SZ
        local cell_w     = math.floor((inner_w - 2 * sep_w) / 3)
        local cell_v_pad = SZ(Screen:scaleBySize(16))
        local lbl_h      = math.floor(face_cell_lbl.size * 2.2)
        local val_h      = face_cell_val.size + SZ(Screen:scaleBySize(2))
        local cell_h     = cell_v_pad * 2 + val_h + SZ(Screen:scaleBySize(2)) + lbl_h
        local row_gap    = SZ(Screen:scaleBySize(4))
        local header_v   = SZ(Screen:scaleBySize(14))
        local header_bot = SZ(Screen:scaleBySize(20))
        local text_w     = inner_w - 2 * _Size.padding.large
        _cell_geo = {
            inner_w    = inner_w,
            sep_w      = sep_w,
            cell_w     = cell_w,
            cell_h     = cell_h,
            cell_v_pad = cell_v_pad,
            lbl_h      = lbl_h,
            val_h      = val_h,
            row_gap    = row_gap,
            header_v   = header_v,
            header_bot = header_bot,
            text_w     = text_w,
        }
        return _cell_geo
    end

    local function buildListScreen(ctx)
        local inner_w = ctx.inner_w
        local rows = {}
        for i, book in ipairs(books) do
            local date_range = book_date_range[book.filepath] or "\xe2\x80\x93"
            local sub_text
            if book.authors and book.authors ~= "" then
                if book.exclude_from_goals then
                    sub_text = string.format("%s · %s", book.authors, _("Excluded"))
                else
                    sub_text = book.authors
                end
            else
                if book.exclude_from_goals then
                    sub_text = _("Excluded")
                end
            end
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w      = inner_w,
                title        = book.title,
                subtitle     = sub_text,
                right_value  = date_range,
                dim_only     = book.exclude_from_goals,
                show_chevron = true,
                separator    = true,
                on_tap       = book.filepath and function()
                    local d, err = _fetchBookStatsData(book)
                    if not d then
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new{
                            text = err or _("Unknown error."),
                        })
                        return
                    end
                    ctx.push("book_stats", { book = book, stats = d })
                end or nil,
            }
        end
        return rows
    end

    local function buildStatsScreen(ctx)
        local inner_w = ctx.inner_w
        local params  = ctx.current().params
        local book    = params.book
        -- Recompute the date-range-dependent aggregates (days, avg/day,
        -- avg/page, total time, pages read) whenever the user has edited the
        -- start/end date on this book. params.stats (the full-history fetch
        -- done at push time) is the fallback when no date has been edited —
        -- avoids re-querying the DB on every repaint for the common case.
        local d = params.stats
        if book and (type(book.date_started) == "string" or type(book.date_finished) == "string") then
            local start_ts = _dateStrToTs(book.date_started, false)
            local end_ts   = _dateStrToTs(book.date_finished, true)
            local filtered = _fetchBookStatsData(book, start_ts, end_ts)
            if filtered then d = filtered end
        end
        local cg      = _buildCellGeo(inner_w)

        local CLR_BORDER = Blitbuffer.gray(0.72)
        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local PAD_H      = _Size.padding.large
        local ICON_FS    = ctx.SZ(SUIStyle.FS_BODY)
        local ROW_H      = ctx.SZ(Screen:scaleBySize(52))

        -- ── 1. Top card: title/author + 3-col metrics ──

        local fp = book and book.filepath

        local meta_w      = inner_w
        local text_max_w  = inner_w - 2 * PAD_H
        local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_SUBTITLE))
        local face_author = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))
        local face_val    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE))
        local face_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

        -- 3-col metrics — widths derived from the right meta column
        local card_gap = ctx.SZ(Screen:scaleBySize(10))
        local col_w    = math.floor((meta_w - 2 * card_gap) / 3)

        local pages_read_str = string.format("%d (%d%%)",
            d.total_read_pages,
            math.floor(100 * d.total_read_pages / (d.pages > 0 and d.pages or 1) + 0.5))

        local function makeTopCell(value, label, w)
            local vg = VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text      = tostring(value),
                    face      = face_val,
                    bold      = true,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(2)) },
                TextWidget:new{
                    text      = label,
                    face      = face_lbl,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
            }

            return FrameContainer:new{
            bordersize     = SUIStyle.BORDER_SZ, color = CLR_BORDER,
                radius         = ctx.SZ(Screen:scaleBySize(12)),
                padding        = 0, margin = 0,
                _CenterContainer:new{
                    dimen = Geom:new{ w = w, h = cg.cell_h },
                    vg,
                },
            }
        end

        local metrics_row = HorizontalGroup:new{
            makeTopCell(_fmtDuration(d.total_time_book), _("Total"),   col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(tostring(d.total_days),           _("Days"),    col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(pages_read_str,                   _("Pages"),   col_w),
        }

        local title_author_group = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(24)) },
            _TextBoxWidget:new{
                text      = d.title,
                face      = face_title,
                bold      = true,
                fgcolor   = CLR_BLACK,
                width     = text_max_w,
                alignment = "center",
                height    = math.floor(1.3 * face_title.size + 0.5) * 1,
                height_adjust = true,
                max_lines = 1,
                height_overflow_show_ellipsis = true,
            },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
            TextWidget:new{
                text      = d.authors or "",
                face      = face_author,
                fgcolor   = CLR_BLACK,
                max_width = text_max_w,
            },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
        }

        local tappable_title
        if fp then
            local ta_h = title_author_group:getSize().h
            local ic = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = ta_h },
                title_author_group,
            }
            ic.ges_events = {
                Tap = { GestureRange:new{
                    ges   = "tap",
                    range = function() return ic.dimen end,
                }},
            }
            function ic:onTap()
                _openBookFromStats(fp)
                return true
            end
            tappable_title = ic
        else
            tappable_title = title_author_group
        end

        local meta_col = VerticalGroup:new{
            align = "center",
            tappable_title,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            metrics_row,
        }

        local top_card = FrameContainer:new{
            bordersize = 0,
            padding    = 0, margin = 0,
            meta_col,
        }

        -- ── 2. Icon rows ───────────────────────────────────────────────────

        -- Build tap callbacks for highlights and notes (BookmarkBrowser)
        local on_tap_highlights, on_tap_notes
        if fp and (d.highlights > 0 or d.notes > 0) then
            local ok_bb = pcall(require, "ui/widget/bookmarkbrowser")
            if ok_bb then
                local function openBrowser()
                    local BookmarkBrowser = require("ui/widget/bookmarkbrowser")
                    local ui = nil
                    local ok_ui, running = pcall(function()
                        return UIManager._running_widget
                    end)
                    if ok_ui and running and running.ui then
                        ui = running.ui
                    end
                    if not ui then
                        local ok_app, App = pcall(function()
                            return require("apps/filemanager/filemanager")
                        end)
                        if ok_app and App and App.instance then
                            ui = App.instance
                        end
                    end
                    BookmarkBrowser:show({ [fp] = true }, ui)
                end
                if d.highlights > 0 then on_tap_highlights = openBrowser end
                if d.notes      > 0 then on_tap_notes      = openBrowser end
            end
        end

        local icon_face  = Font:getFace(SUIStyle.FACE_ICONS,   ICON_FS)
        local lbl_face   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))
        local val_face   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))
        local ICON_W     = ctx.SZ(Screen:scaleBySize(36))
        local row_inner  = inner_w - 2 * PAD_H

        local function makeIconRow(icon_glyph, label, value_str, on_tap)
            local val_w = ctx.SZ(Screen:scaleBySize(160))
            local lbl_w = row_inner - ICON_W - val_w

            local row_content = HorizontalGroup:new{
                align = "center",
                _CenterContainer:new{
                    dimen = Geom:new{ w = ICON_W, h = ROW_H },
                    TextWidget:new{
                        text    = icon_glyph,
                        face    = icon_face,
                        fgcolor = CLR_BLACK,
                    },
                },
                _LeftContainer:new{
                    dimen = Geom:new{ w = lbl_w, h = ROW_H },
                    TextWidget:new{
                        text      = label,
                        face      = lbl_face,
                        fgcolor   = CLR_BLACK,
                        max_width = lbl_w,
                    },
                },
                _RightContainer:new{
                    dimen = Geom:new{ w = val_w, h = ROW_H },
                    TextWidget:new{
                        text      = tostring(value_str),
                        face      = val_face,
                        bold      = true,
                        fgcolor   = CLR_BLACK,
                        max_width = val_w,
                    },
                },
            }

            local padded = FrameContainer:new{
                bordersize    = 0, padding = 0,
                padding_left  = PAD_H,
                padding_right = PAD_H,
                dimen         = Geom:new{ w = inner_w, h = ROW_H },
                row_content,
            }

            if not on_tap then return padded end

            local ic = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = ROW_H },
                padded,
            }
            ic.ges_events = {
                Tap = { GestureRange:new{
                    ges   = "tap",
                    range = function() return ic.dimen end,
                }},
            }
            function ic:onTap() on_tap(); return true end
            return ic
        end

        local function makeRowSep()
            return FrameContainer:new{
                bordersize    = 0, padding = 0,
                padding_left  = PAD_H,
                padding_right = PAD_H,
                LineWidget:new{
                dimen      = Geom:new{ w = row_inner, h = SUIStyle.BORDER_SZ },
                    background = CLR_BORDER,
                },
            }
        end

        -- Two compact half-width cells sharing a single row, separated by a
        -- thin vertical divider (used for Highlights | Notes).
        local function makeDualIconRow(icon1, label1, value1, on_tap1,
                                        icon2, label2, value2, on_tap2)
            local sep_w   = SUIStyle.BORDER_SZ
            local sep_gap = ctx.SZ(Screen:scaleBySize(10))
            local half_w1 = math.floor((row_inner - sep_w - 2 * sep_gap) / 2)
            local half_w2 = row_inner - sep_w - 2 * sep_gap - half_w1
            local val_w   = ctx.SZ(Screen:scaleBySize(50))

            local function makeHalf(icon_glyph, label, value_str, w)
                local lbl_w = w - ICON_W - val_w
                return HorizontalGroup:new{
                    align = "center",
                    _CenterContainer:new{
                        dimen = Geom:new{ w = ICON_W, h = ROW_H },
                        TextWidget:new{ text = icon_glyph, face = icon_face, fgcolor = CLR_BLACK },
                    },
                    _LeftContainer:new{
                        dimen = Geom:new{ w = lbl_w, h = ROW_H },
                        TextWidget:new{ text = label, face = lbl_face, fgcolor = CLR_BLACK, max_width = lbl_w },
                    },
                    _RightContainer:new{
                        dimen = Geom:new{ w = val_w, h = ROW_H },
                        TextWidget:new{
                            text      = tostring(value_str),
                            face      = val_face,
                            bold      = true,
                            fgcolor   = CLR_BLACK,
                            max_width = val_w,
                        },
                    },
                }
            end

            local function wrapTap(widget, w, on_tap)
                if not on_tap then return widget end
                local ic = InputContainer:new{
                    dimen = Geom:new{ w = w, h = ROW_H },
                    widget,
                }
                ic.ges_events = {
                    Tap = { GestureRange:new{
                        ges   = "tap",
                        range = function() return ic.dimen end,
                    }},
                }
                function ic:onTap() on_tap(); return true end
                return ic
            end

            local half1 = wrapTap(makeHalf(icon1, label1, value1, half_w1), half_w1, on_tap1)
            local half2 = wrapTap(makeHalf(icon2, label2, value2, half_w2), half_w2, on_tap2)

            local separator = _CenterContainer:new{
                dimen = Geom:new{ w = sep_w, h = ROW_H },
                LineWidget:new{
                    dimen      = Geom:new{ w = sep_w, h = math.floor(ROW_H * 0.6) },
                    background = CLR_BORDER,
                },
            }

            local row_content = HorizontalGroup:new{
                align = "center",
                half1,
                HorizontalSpan:new{ width = sep_gap },
                separator,
                HorizontalSpan:new{ width = sep_gap },
                half2,
            }

            return FrameContainer:new{
                bordersize    = 0, padding = 0,
                padding_left  = PAD_H,
                padding_right = PAD_H,
                dimen         = Geom:new{ w = inner_w, h = ROW_H },
                row_content,
            }
        end

        local rows_block = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ,
            color      = CLR_BORDER,
            radius     = ctx.SZ(Screen:scaleBySize(12)),
            padding    = 0,
            VerticalGroup:new{
                align = "left",
                makeIconRow(SUIStyle.icon("clock"),                _("Average per day"),  _fmtDuration(d.avg_time_per_day)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("page"),                 _("Average per page"), _fmtDuration(d.avg_time_per_page)),
                makeRowSep(),
                makeDualIconRow(
                    SUIStyle.icon("highlights"), _("Highlights"), tostring(d.highlights), on_tap_highlights,
                    SUIStyle.icon("notes"),      _("Notes"),      tostring(d.notes),      on_tap_notes
                ),
                makeRowSep(),
                makeIconRow(
                    book.exclude_from_goals and SUIStyle.icon("check") or SUIStyle.icon("uncheck"),
                    _("Exclude from goals"),
                    book.exclude_from_goals and _("Yes") or _("No"),
                    function()
                        local next_val = not book.exclude_from_goals
                        book.exclude_from_goals = next_val and true or nil
                        _writeSummaryExclude(fp, book.exclude_from_goals)

                        -- Force full stats invalidation so homescreen widget / stats provider update
                        local SP = package.loaded["desktop_modules/module_stats_provider"]
                        if SP and SP.invalidate then SP.invalidate() end

                        ctx.repaint()
                    end
                ),
            },
        }

        -- ── 3. Date range card ─────────────────────────────────────────────

        -- DB-derived fallbacks (used for display and as Reset targets).
        local original_start_str = _fmtDate(d.first_open)
        local original_end_str   = (type(book.date_finished) == "string" and d.last_open and _fmtDate(d.last_open)) or "\xe2\x80\x93"

        -- Prefer sidecar dates over raw DB timestamps.
        local date_start_str = (type(book.date_started) == "string" and book.date_started)
                               or original_start_str
        local date_end_str   = (type(book.date_finished) == "string" and book.date_finished)
                               or original_end_str

        local date_widget = _makeDateCard(
            inner_w, PAD_H,
            date_start_str, date_end_str,
            original_start_str, original_end_str,
            fp,
            function(new_date)   -- on_start_saved / on_start_reset
                book.date_started   = (new_date ~= original_start_str) and new_date or nil
                start_dates[fp]     = new_date
                book_date_range[fp] = _fmtDateRange(new_date,
                    book.date_finished or date_end_str)
                ctx.repaint()
            end,
            function(new_date)   -- on_end_saved / on_end_reset
                book.date_finished  = (new_date ~= original_end_str) and new_date or nil
                book_date_range[fp] = _fmtDateRange(
                    book.date_started or start_dates[fp], new_date)
                ctx.repaint()
            end,
            ctx.SZ
        )

        local block_gap = VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(10)) }

        return {
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(6)) },
            top_card,
            block_gap,
            rows_block,
            block_gap,
            date_widget,
        }
    end

    local function titleFn(ctx)
        local count = 0
        for _, book in ipairs(books) do
            if not book.exclude_from_goals then
                count = count + 1
            end
        end
        return string.format(
            N_("%d book read in %s", "%d books read in %s", count),
            count, year_str)
    end

    local win = SUIWindow:new{
        name           = "sui_win_reading_history",
        title          = titleFn,
        -- Matches the Settings window's height (SUIWindow's own default,
        -- 23/30 of portrait height), same as Reading Insights/Streak.
        height         = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position       = "bottom",
        navpager_mode  = require("sui_config").isNavpagerEnabled(),
        screens        = {
            __root__   = buildListScreen,
            book_stats = buildStatsScreen,
        },
    }
    if initial_page and initial_page > 1 then
        local real_show = win.show
        function win:show()
            real_show(self)
            UIManager:nextTick(function()
                if self._total_pages and initial_page <= self._total_pages then
                    self._current_page = initial_page
                    self:_repaint()
                end
            end)
        end
    end

    win:show()
end

-- ===========================================================================
-- showReadingInsightsWindow
-- ===========================================================================
-- A SUIWindow that surfaces historical reading insights drawn from the
-- statistics SQLite database (the same source used by the
-- "reading-insights-popup" userpatch by quanganhdo / modified version).
-- ===========================================================================


-- Opens the statistics DB and calls fn(conn), returns fallback on any error.
local function _withStatsDb(fallback, fn)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return fallback end
    local db_path = Config.getStatsDbPath()
    if lfs.attributes(db_path, "mode") ~= "file" then return fallback end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return fallback end

    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then return fallback end

    local ok_fn, result = pcall(fn, conn)
    pcall(conn.close, conn)
    return ok_fn and result or fallback
end

-- Executes a prepared statement and calls fn(stmt), closes it on exit.
local function _withStmt(conn, sql, fn)
    local ok_prep, stmt = pcall(conn.prepare, conn, sql)
    if not ok_prep or not stmt then return end
    local ok_fn, result = pcall(fn, stmt)
    pcall(stmt.close, stmt)
    return ok_fn and result
end

-- ---------------------------------------------------------------------------
-- Module-level cache for insights window data
-- ---------------------------------------------------------------------------
-- Kept per-year; cleared when the window is closed.
-- _ri_cache[year] = { yearly_stats, monthly_data }
-- _ri_cache["lastweek"] / ["alltime"] / ["today"] for page-2 data.
-- _ri_streaks: loaded once per window session (all-time, not year-bound).
local _ri_cache   = {}
local _ri_streaks = nil

-- ---------------------------------------------------------------------------
-- Reading-insights data fetchers
-- ---------------------------------------------------------------------------

-- Returns { min_year, max_year } from page_stat.
local function _riGetYearRange()
    local current_year = tonumber(os.date("%Y"))
    local default = { min_year = current_year, max_year = current_year }
    return _withStatsDb(default, function(conn)
        local range = { min_year = current_year, max_year = current_year }
        _withStmt(conn, [[
            SELECT MIN(strftime('%Y', start_time, 'unixepoch', 'localtime')),
                   MAX(strftime('%Y', start_time, 'unixepoch', 'localtime'))
            FROM page_stat
        ]], function(stmt)
            for row in stmt:rows() do
                if row[1] then range.min_year = tonumber(row[1]) or current_year end
                if row[2] then range.max_year = tonumber(row[2]) or current_year end
            end
        end)
        return range
    end)
end

-- Returns { days, pages, duration } for a given year.
local function _riGetYearlyStats(year)
    local default = { days = 0, pages = 0, duration = 0 }
    return _withStatsDb(default, function(conn)
        local s = { days = 0, pages = 0, duration = 0 }
        local yr = tostring(year)
        _withStmt(conn, string.format([[
            SELECT COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime'))
            FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
        ]], yr), function(stmt)
            for row in stmt:rows() do s.days = tonumber(row[1]) or 0 end
        end)
        _withStmt(conn, string.format([[
            SELECT count(*) FROM (
                SELECT 1 FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page
            )
        ]], yr), function(stmt)
            for row in stmt:rows() do s.pages = tonumber(row[1]) or 0 end
        end)
        _withStmt(conn, string.format([[
            SELECT sum(duration) FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
        ]], yr), function(stmt)
            for row in stmt:rows() do s.duration = tonumber(row[1]) or 0 end
        end)
        return s
    end)
end

-- Returns an array[1..12] of { month="YYYY-MM", days=N, hours=H,
--   label="Jan", label_full="January", month_num=N } for a given year.
local _MONTH_SHORT = {
    _("jan"), _("feb"), _("mar"), _("apr"), _("may"), _("jun"),
    _("jul"), _("aug"), _("sep"), _("oct"), _("nov"), _("dec"),
}
local _MONTH_FULL = {
    _("january"), _("february"), _("march"), _("april"), _("may"), _("june"),    
    _("july"), _("august"), _("september"), _("october"), _("november"), _("december"),
}

local function _riGetMonthlyData(year)
    local default = {}
    for m = 1, 12 do
        default[m] = { month = string.format("%04d-%02d", year, m),
                       days = 0, hours = 0,
                       label = _MONTH_SHORT[m], label_full = _MONTH_FULL[m],
                       month_num = m }
    end
    return _withStatsDb(default, function(conn)
        local yr = tostring(year)
        -- Days read per month
        local days_by_month = {}
        _withStmt(conn, string.format([[
            SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS mo,
                   COUNT(DISTINCT date(start_time, 'unixepoch', 'localtime'))
            FROM page_stat
            WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
            GROUP BY mo ORDER BY mo ASC
        ]], yr), function(stmt)
            for row in stmt:rows() do
                days_by_month[row[1]] = tonumber(row[2]) or 0
            end
        end)
        -- Hours read per month (de-duplicate page reads like the patch does)
        local hours_by_month = {}
        _withStmt(conn, string.format([[
            SELECT dates, SUM(sum_duration) / 3600.0 FROM (
                SELECT strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') AS dates,
                       sum(duration) AS sum_duration
                FROM page_stat
                WHERE strftime('%%Y', start_time, 'unixepoch', 'localtime') = '%s'
                GROUP BY id_book, page, dates
            ) GROUP BY dates ORDER BY dates ASC
        ]], yr), function(stmt)
            for row in stmt:rows() do
                local h = tonumber(row[2]) or 0
                if h >= 1 then h = math.floor(h)
                elseif h > 0 then h = math.floor(h * 10) / 10 end
                hours_by_month[row[1]] = h
            end
        end)
        local result = {}
        for m = 1, 12 do
            local key = string.format("%04d-%02d", year, m)
            result[m] = {
                month      = key,
                days       = days_by_month[key]  or 0,
                hours      = hours_by_month[key] or 0,
                label      = _MONTH_SHORT[m],
                label_full = _MONTH_FULL[m],
                month_num  = m,
            }
        end
        return result
    end)
end

-- Returns { days={current,best,best_start,best_end},
--           weeks={current,best,best_start,best_end} } all-time streaks.
-- Uses the same algorithm as the patch's calculateStreaks().
local function _riGetStreaks()
    local zero_streak = { current=0, best=0, best_start=0, best_end=0 }
    local default = { days = zero_streak, weeks = zero_streak }
    return _withStatsDb(default, function(conn)
        -- ── Day streaks ──────────────────────────────────────────────────
        -- duration > 0 filters zero-duration rows (e.g. a crash/force-close)
        -- exactly like module_stats_provider.lua's fetchStreak does on
        -- page_stat_data — needed so the two "current streak" sources this
        -- window and the homescreen card both ultimately feed into
        -- sui_streak.computeCurrentDayStreak() actually agree on the
        -- same set of "active" dates, not just share the same walk function.
        local dates = {}
        _withStmt(conn, [[
            SELECT date(start_time, 'unixepoch', 'localtime') AS d,
                   min(start_time)
            FROM page_stat WHERE duration > 0 GROUP BY d ORDER BY d DESC
        ]], function(stmt)
            for row in stmt:rows() do
                table.insert(dates, { row[1], tonumber(row[2]) })
            end
        end)

        local function parseDateYMD(s)
            if not s then return end
            local y,m,d = tonumber(s:sub(1,4)), tonumber(s:sub(6,7)), tonumber(s:sub(9,10))
            if y and m and d then return y,m,d end
        end

        local function isConsecDay(prev, curr)
            local y,m,d = parseDateYMD(prev)
            if not y then return false end
            local expected = os.date("%Y-%m-%d", os.time{year=y,month=m,day=d} - 86400)
            return curr == expected
        end

        local function computeStreak(entries, isConsec, isCurrent)
            if #entries == 0 then return zero_streak end
            local current = 0
            if isCurrent(entries[1][1]) then
                current = 1
                for i = 2, #entries do
                    if isConsec(entries[i-1][1], entries[i][1]) then current = current + 1
                    else break end
                end
            end
            local best, run, best_s, best_e, best_e_tmp = 1, 1, 1, 1, 0
            for i = 2, #entries do
                if isConsec(entries[i-1][1], entries[i][1]) then
                    if run == 1 then best_e_tmp = i - 1 end
                    run = run + 1
                    if run > best then best=run; best_s=i; best_e=best_e_tmp end
                else run = 1 end
            end
            local ts_end   = entries[best_e]   and tonumber(entries[best_e][2])   or 0
            local ts_start = entries[best_s]   and tonumber(entries[best_s][2])   or 0
            return { current=current, best=best, best_start=ts_start, best_end=ts_end }
        end

        local today     = os.date("%Y-%m-%d")
        local yesterday = os.date("%Y-%m-%d", os.time() - 86400)

        local day_streaks = computeStreak(dates,
            isConsecDay,
            function(d) return d == today or d == yesterday end)

        -- The CURRENT streak specifically is recomputed via the shared
        -- sui_streak walk (Phase 2), merging in any frozen dates so
        -- this window agrees with the homescreen "Streak" card, which goes
        -- through the same shared function (module_stats_provider.lua's
        -- fetchStreak). `best`/`best_start`/`best_end` above are Reading
        -- Insights' own historical-max feature, out of scope for the freeze
        -- mechanic, and are left as computeStreak already calculated them
        -- from real activity only.
        local date_strs = {}
        for _, e in ipairs(dates) do date_strs[#date_strs + 1] = e[1] end
        local frozen = SUIStreak.getFrozenDatesInRange(nil, nil)
        day_streaks.current = SUIStreak.computeCurrentDayStreak(date_strs, {
            frozen_dates = frozen,
            today        = today,
            yesterday    = yesterday,
        })

        -- ── Week streaks ─────────────────────────────────────────────────
        local weeks = {}
        _withStmt(conn, [[
            SELECT strftime('%G-%V', start_time, 'unixepoch', 'localtime') AS wk,
                   MIN(start_time), MAX(start_time)
            FROM page_stat GROUP BY wk ORDER BY wk DESC
        ]], function(stmt)
            for row in stmt:rows() do
                table.insert(weeks, { tonumber(row[2]), tonumber(row[3]) })
            end
        end)

        local function parseWeekYear(ts)
            return tonumber(os.date("%G", ts)), tonumber(os.date("%V", ts))
        end

        local function getTotalWeeksInYear(y)
            return tonumber(os.date("%V", os.time{year=y,month=12,day=28}))
        end

        local function isConsecWeek(prev_ts, curr_ts)
            local py, pw = parseWeekYear(prev_ts)
            local cy, cw = parseWeekYear(curr_ts)
            if not py then return false end
            if cy == py and pw == cw + 1 then return true end
            if py == cy + 1 and pw == 1 and cw == getTotalWeeksInYear(cy) then return true end
            return false
        end

        local cur_wk  = os.date("%G-%V")
        local last_wk = os.date("%G-%V", os.time() - 7 * 86400)

        -- Week streak entries use {first_ts, last_ts}, so indices differ.
        -- Adapt computeStreak: entries[i][1]=first_ts for is_current, [2]=last_ts for best_end.
        local function computeWeekStreak(entries)
            if #entries == 0 then return zero_streak end
            local function isCurWk(first_ts)
                local wk = os.date("%G-%V", first_ts)
                return wk == cur_wk or wk == last_wk
            end
            local current = 0
            if isCurWk(entries[1][1]) then
                current = 1
                for i = 2, #entries do
                    if isConsecWeek(entries[i-1][1], entries[i][1]) then current = current + 1
                    else break end
                end
            end
            local best, run, best_s, best_e, best_e_tmp = 1, 1, 1, 1, 0
            for i = 2, #entries do
                if isConsecWeek(entries[i-1][1], entries[i][1]) then
                    if run == 1 then best_e_tmp = i - 1 end
                    run = run + 1
                    if run > best then best=run; best_s=i; best_e=best_e_tmp end
                else run = 1 end
            end
            local ts_end   = entries[best_e] and entries[best_e][2] or 0  -- last_ts of last week
            local ts_start = entries[best_s] and entries[best_s][1] or 0  -- first_ts of first week
            return { current=current, best=best, best_start=ts_start, best_end=ts_end }
        end

        return { days = day_streaks, weeks = computeWeekStreak(weeks) }
    end)
end

-- ---------------------------------------------------------------------------
-- Page-2 data fetchers  (today / last-week / all-time)
-- All three follow the same _withStatsDb / _withStmt pattern used above.
-- Results are stored in _ri_cache["today"], ["lastweek"], ["alltime"] so
-- they are cleared together with the rest of the per-session cache.
-- ---------------------------------------------------------------------------

-- Returns { seconds=N, pages=N } for the reading done since midnight today.
-- Re-fetched every time the page is built (cheap: two small aggregate queries).
local function _riGetTodayStats()
    local default = { seconds = 0, pages = 0 }
    return _withStatsDb(default, function(conn)
        local s = { seconds = 0, pages = 0 }
        local now_ts  = os.time()
        local now_t   = os.date("*t")
        local midnight = now_ts - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
        _withStmt(conn, string.format([[
                SELECT count(DISTINCT page || '@' || id_book), sum(duration)
                FROM page_stat_data
                WHERE start_time >= %d AND duration > 0
        ]], midnight), function(stmt)
            for row in stmt:rows() do
                s.pages   = tonumber(row[1]) or 0
                s.seconds = tonumber(row[2]) or 0
            end
        end)
        return s
    end)
end

-- Returns { seconds=N, pages=N } for the current calendar week (Monday start).
local function _riGetThisWeekStats()
    if _ri_cache["thisweek"] then return _ri_cache["thisweek"] end
    local default = { seconds = 0, pages = 0 }
    local r = _withStatsDb(default, function(conn)
        local s = { seconds = 0, pages = 0 }
        local now_ts  = os.time()
        local now_t   = os.date("*t", now_ts)
        local midnight  = now_ts - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
        local days_since_monday = (now_t.wday + 5) % 7
        local week_start = midnight - days_since_monday * 86400
        _withStmt(conn, string.format([[
            WITH day_buckets AS (
                SELECT sum(duration) AS sd, count(DISTINCT page || '@' || id_book) AS pg
                FROM page_stat_data WHERE start_time >= %d AND duration > 0
                GROUP BY date(start_time, 'unixepoch', 'localtime')
            )
            SELECT COALESCE(sum(sd), 0), COALESCE(sum(pg), 0) FROM day_buckets
        ]], week_start), function(stmt)
            for row in stmt:rows() do s.seconds = tonumber(row[1]) or 0; s.pages = tonumber(row[2]) or 0 end
        end)
        return s
    end)
    _ri_cache["thisweek"] = r
    return r
end

-- Returns { seconds=N, pages=N } for the current month.
local function _riGetThisMonthStats()
    if _ri_cache["thismonth"] then return _ri_cache["thismonth"] end
    local default = { seconds = 0, pages = 0 }
    local r = _withStatsDb(default, function(conn)
        local s = { seconds = 0, pages = 0 }
        local now_ts  = os.time()
        local now_t   = os.date("*t", now_ts)
        local month_start = os.time{year=now_t.year, month=now_t.month, day=1, hour=0, min=0, sec=0}
        _withStmt(conn, string.format([[
            WITH day_buckets AS (
                SELECT
                    sum(duration)                          AS sd,
                    count(DISTINCT page || '@' || id_book) AS pg
                FROM page_stat_data
                WHERE start_time >= %d AND duration > 0
                GROUP BY date(start_time, 'unixepoch', 'localtime')
            )
            SELECT COALESCE(sum(sd), 0), COALESCE(sum(pg), 0) FROM day_buckets
        ]], month_start), function(stmt)
            for row in stmt:rows() do
                s.seconds = tonumber(row[1]) or 0
                s.pages   = tonumber(row[2]) or 0
            end
        end)
        return s
    end)
    _ri_cache["thismonth"] = r
    return r
end

-- Returns { avg_seconds=N, avg_pages=N } — 7-day rolling averages.
-- Window: today's midnight minus 6 full days (= 7 calendar days including today).
local function _riGetLastWeekStats()
    if _ri_cache["lastweek"] then return _ri_cache["lastweek"] end
    local default = { total_seconds = 0, total_pages = 0, avg_seconds = 0, avg_pages = 0 }
    local r = _withStatsDb(default, function(conn)
        local res       = { total_seconds = 0, total_pages = 0, avg_seconds = 0, avg_pages = 0 }
        local now_ts    = os.time()
        local now_t     = os.date("*t")
        local midnight  = now_ts - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
        local week_start = midnight - 6 * 86400
        _withStmt(conn, string.format([[
                WITH day_buckets AS (
                    SELECT
                        sum(duration)                          AS sd,
                        count(DISTINCT page || '@' || id_book) AS pg
                    FROM page_stat_data
                    WHERE start_time >= %d AND duration > 0
                    GROUP BY date(start_time, 'unixepoch', 'localtime')
                )
                SELECT sum(sd), sum(pg) FROM day_buckets
        ]], week_start), function(stmt)
            for row in stmt:rows() do
                    res.total_seconds = tonumber(row[1]) or 0
                    res.total_pages   = tonumber(row[2]) or 0
                    res.avg_seconds = math.floor((tonumber(row[1]) or 0) / 7)
                    res.avg_pages   = math.floor((tonumber(row[2]) or 0) / 7)
            end
        end)
        return res
    end)
    _ri_cache["lastweek"] = r
    return r
end

-- Returns { hours=N, pages=N, book_count=N } across all recorded history.
-- Summing _ri_cache year entries avoids an extra DB connection when page 1
-- has already loaded all years; falls back to a direct DB query otherwise.
local function _riGetAllTimeStats()
    if _ri_cache["alltime"] then return _ri_cache["alltime"] end
    local r = { hours = 0, pages = 0, book_count = 0 }

    -- Fast path: sum already-cached yearly entries (no extra DB open needed).
    local year_range = _riGetYearRange()
    local all_cached = true
    for y = year_range.min_year, year_range.max_year do
        if not _ri_cache[y] then all_cached = false; break end
    end

    if all_cached then
        for y = year_range.min_year, year_range.max_year do
            local ys = _ri_cache[y].yearly_stats
            r.pages = r.pages + (ys.pages or 0)
            r.hours = r.hours + math.floor((ys.duration or 0) / 3600)
        end
    else
        -- Slow path: single DB connection for everything
        _withStatsDb(nil, function(conn)
            _withStmt(conn, [[
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM page_stat GROUP BY id_book, page
                )
            ]], function(stmt)
                for row in stmt:rows() do r.pages = tonumber(row[1]) or 0 end
            end)
            _withStmt(conn, [[
                SELECT SUM(sum_dur) FROM (
                    SELECT SUM(duration) AS sum_dur FROM page_stat
                    GROUP BY id_book, page,
                             date(start_time, 'unixepoch', 'localtime')
                )
            ]], function(stmt)
                for row in stmt:rows() do
                    r.hours = math.floor((tonumber(row[1]) or 0) / 3600)
                end
            end)
        end)
    end

    local ok_sp, SP = pcall(require, "desktop_modules/module_stats_provider")
    if ok_sp and SP and SP.get then
        local s = SP.get(nil, os.date("%Y"), true)
        r.book_count = s and s.books_total or 0
    end

    _ri_cache["alltime"] = r
    return r
end

-- ---------------------------------------------------------------------------
-- UI helpers (insights window)
-- ---------------------------------------------------------------------------

-- Returns a formatted string for a duration in seconds: "Xh Ym" / "Xm" / "0h"
local function _riFmtHours(secs)
    secs = math.floor(secs or 0)
    if secs < 60 then return "0h" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0          then return string.format("%dh", h)
    else                       return string.format("%dm", m) end
end

-- Formats a timestamp (unix) into a short locale-independent date string.
local function _riFmtDate(ts)
    if not ts or ts <= 0 then return "–" end
    return os.date("%d %b '%y", ts)
end

-- Formats a large integer with thousands separator (e.g. 1234 → "1,234").
local function _riFmtCount(n)
    n = math.floor(n or 0)
    local s = tostring(n)
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end



-- SZ threaded in by the caller (ctx.SZ); falls back to UI.SZ if ever called
-- without one (identical value during a synchronous window build).
local function _riYearHeader(inner_w, year, year_range, on_prev, on_next, SZ)
    SZ = SZ or UI.SZ
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
    local face_chev = Font:getFace(SUIStyle.FACE_ICONS, math.floor(SZ(SUIStyle.FS_TITLE * 1.8)))
    local CLR_BLACK = Blitbuffer.COLOR_BLACK

    local prev_enabled = year > year_range.min_year
    local next_enabled = year < year_range.max_year

    local gap = SZ(Screen:scaleBySize(16))
    local btn_w = SZ(Screen:scaleBySize(60))

    local year_lbl = TextWidget:new{
        text    = tostring(year),
        face    = face,
        fgcolor = CLR_BLACK,
        bold    = true,
        padding = 0,
    }

    local lbl_w = year_lbl:getSize().w
    local lbl_h = year_lbl:getSize().h

    local function navBtn(label, enabled, cb)
        local tw = TextWidget:new{
            text    = label,
            face    = face_chev,
            fgcolor = enabled and CLR_BLACK or Blitbuffer.gray(0.25),
            padding   = 0,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = btn_w, h = lbl_h },
            _CenterContainer:new{
                dimen = Geom:new{ w = btn_w, h = lbl_h },
                tw,
            }
        }
        if enabled then
            ic.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = function() return ic.dimen end } },
            }
            function ic:onTap() cb(); return true end
        end
        return ic
    end

    local prev_btn = navBtn("\u{E840}", prev_enabled, on_prev)
    local next_btn = navBtn("\u{E841}", next_enabled, on_next)

    local center_x = math.floor(inner_w / 2)
    local half_lbl = math.floor(lbl_w / 2)

    prev_btn.overlap_offset = { center_x - half_lbl - gap - btn_w, 0 }
    year_lbl.overlap_offset = { center_x - half_lbl, 0 }
    next_btn.overlap_offset = { center_x + half_lbl + gap, 0 }

    return OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = lbl_h },
        prev_btn,
        year_lbl,
        next_btn,
    }
end

-- Builds the two-column yearly stat row (days/hours | pages).
-- Returns a HorizontalGroup of two tappable cells.
-- SZ threaded in by the caller (ctx.SZ); falls back to UI.SZ if ever called
-- without one (identical value during a synchronous window build).
local function _riYearlyRow(inner_w, yearly_stats, mode_key, on_toggle_mode, avail_h, SZ)
    SZ = SZ or UI.SZ
    local CLR_BLACK = Blitbuffer.COLOR_BLACK
    local face_val  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_TITLE))
    local face_lbl  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))

    local sep_w  = SUIStyle.BORDER_SZ
    local col_w  = math.floor((inner_w - sep_w) / 2)
    local cell_h = math.max(SZ(Screen:scaleBySize(48)),
                       math.min(SZ(Screen:scaleBySize(90)),
                           math.floor(avail_h * 0.12)))

    local function makeCell(val_str, lbl_str, on_tap)
        local content = VerticalGroup:new{ align = "center",
            TextWidget:new{ text = val_str, face = face_val,
                            fgcolor = CLR_BLACK, bold = true },
            VerticalSpan:new{ width = SZ(Screen:scaleBySize(2)) },
            TextWidget:new{ text = lbl_str, face = face_lbl,
                            fgcolor = CLR_BLACK },
        }
        local cc = _CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = cell_h },
            content,
        }
        if on_tap then
            local ic = InputContainer:new{
                dimen = Geom:new{ w = col_w, h = cell_h },
                cc,
            }
            ic.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = function() return ic.dimen end } },
            }
            function ic:onTap() on_tap(); return true end
            return ic
        end
        return cc
    end

    local left_val, left_lbl
    if mode_key == "hours" then
        left_val = _riFmtHours(yearly_stats.duration)
        if yearly_stats.duration < 60 then left_val = "0m" end
        left_lbl = _("hours read")
    else
        left_val = _riFmtCount(yearly_stats.days)
        left_lbl = N_("day read", "days read", yearly_stats.days)
    end

    local sep = _CenterContainer:new{
        dimen = Geom:new{ w = sep_w, h = cell_h },
        LineWidget:new{
            dimen      = Geom:new{ w = sep_w, h = cell_h - SZ(Screen:scaleBySize(24)) },
            background = CLR_BLACK,
        }
    }

    return HorizontalGroup:new{ align = "center",
        makeCell(left_val, left_lbl, on_toggle_mode),
        sep,
        makeCell(_riFmtCount(yearly_stats.pages),
                 N_("page read", "pages read", yearly_stats.pages),
                 nil),
    }
end



-- SZ threaded in by the caller (ctx.SZ); falls back to UI.SZ if ever called
-- without one (identical value during a synchronous window build).
local function _riMonthlyChart(inner_w, monthly_data, value_key, selected_year, avail_h, SZ)
    SZ = SZ or UI.SZ
    if not monthly_data or #monthly_data == 0 then return VerticalGroup:new{} end

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    -- Compute the maximum value across all months for scaling.
    local max_val = 1
    for _, m in ipairs(monthly_data) do
        local v = tonumber(m[value_key]) or 0
        if v > max_val then max_val = v end
    end

    local chart_w  = inner_w
    -- bar_h is 12% of available height per row (2 rows); clamped for legibility.
    local bar_h    = math.max(SZ(Screen:scaleBySize(20)),
                        math.min(SZ(Screen:scaleBySize(60)),
                            math.floor(avail_h * 0.12)))
    local bar_w    = math.floor(chart_w / 6) - SZ(Screen:scaleBySize(8))
    local bar_gap  = math.floor((chart_w - bar_w * 6) / 5)
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION - 2))
    local lbl_h    = face_lbl.size + SZ(Screen:scaleBySize(2))

    local function makeBarRow(slice)
        local bars  = HorizontalGroup:new{ align = "bottom" }
        local lbls  = HorizontalGroup:new{ align = "top" }
        local total_h = bar_h + lbl_h

        for i, m in ipairs(slice) do
            local val   = tonumber(m[value_key]) or 0
            local ratio = max_val > 0 and (val / max_val) or 0
            local bh    = math.floor(ratio * bar_h + 0.5)
            if bh == 0 and val > 0 then bh = 1 end

            local is_cur = (selected_year == current_year)
                           and (m.month == current_month)
            local bar_color = is_cur and Blitbuffer.COLOR_BLACK
                                      or Blitbuffer.COLOR_GRAY_B

            -- Value label above the bar.
            local val_lbl = TextWidget:new{
                text    = val > 0 and tostring(val) or "",
                face    = face_lbl,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            local col = VerticalGroup:new{ align = "center" }
            table.insert(col, _CenterContainer:new{
                dimen = Geom:new{ w = bar_w, h = lbl_h },
                val_lbl,
            })
            if bh > 0 then
                table.insert(col, LineWidget:new{
                    dimen      = Geom:new{ w = bar_w, h = bh },
                    background = bar_color,
                })
            end
            table.insert(col, LineWidget:new{
                dimen      = Geom:new{ w = bar_w, h = SZ(Screen:scaleBySize(2)) },
                background = bar_color,
            })

            local bar_cont = BottomContainer:new{
                dimen = Geom:new{ w = bar_w, h = total_h },
                col,
            }

            table.insert(bars, bar_cont)
            table.insert(lbls, _CenterContainer:new{
                dimen = Geom:new{ w = bar_w, h = lbl_h },
                TextWidget:new{
                    text    = m.label:lower(),
                    face    = face_lbl,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            })
            if i < #slice then
                table.insert(bars, HorizontalSpan:new{ width = bar_gap })
                table.insert(lbls, HorizontalSpan:new{ width = bar_gap })
            end
        end

        return VerticalGroup:new{ align = "center",
            bars,
            VerticalSpan:new{ width = SZ(Screen:scaleBySize(2)) },
            lbls,
        }
    end

    local chart = VerticalGroup:new{ align = "center" }
    -- Row 1: Jan–Jun (indices 1–6), Row 2: Jul–Dec (indices 7–12)
    local row1, row2 = {}, {}
    for i = 1,  6 do table.insert(row1, monthly_data[i]) end
    for i = 7, 12 do table.insert(row2, monthly_data[i]) end
    table.insert(chart, makeBarRow(row1))
    table.insert(chart, VerticalSpan:new{ width = SZ(Screen:scaleBySize(8)) })
    table.insert(chart, makeBarRow(row2))
    return chart
end

-- ---------------------------------------------------------------------------
-- Page 2 — "Today, Last Week & All-Time" deep-stats screen
-- ---------------------------------------------------------------------------

-- SZ threaded in by the caller (ctx.SZ); falls back to UI.SZ if ever called
-- without one (identical value during a synchronous window build).
-- ---------------------------------------------------------------------------
-- _riBuildStreakBoxes — the "Current streak"/"Best streak" bordered boxes,
-- for both day and week streaks. Extracted out of _buildInsightsPage2 so the
-- Streak window (sui_stats_windows.lua's showStreakManagerWindow) can reuse
-- the exact same widget recipe without also paying for _buildInsightsPage2's
-- alltime/week/month queries, which it has no use for.
-- ---------------------------------------------------------------------------
local function _riBuildStreakBoxes(inner_w, streaks, SZ)
    SZ = SZ or UI.SZ
    _lazyLoad()
    local Size = require("ui/size")

    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local CLR_BORDER = Blitbuffer.gray(0.72)
    local face_lbl_row  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_val_row  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_sub      = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))
    local face_icon_row = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_BODY))

    local ROW_H     = SZ(Screen:scaleBySize(52))
    local PAD_H     = Size.padding.large
    local ICON_W    = SZ(Screen:scaleBySize(36))
    local row_inner = inner_w - 2 * PAD_H

    local function makeIconRow(icon_glyph, label, value_str, sub_label)
        local val_w = SZ(Screen:scaleBySize(160))
        local lbl_w = row_inner - ICON_W - val_w

        local lbl_widget
        if sub_label then
            lbl_widget = VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = label, face = face_lbl_row, fgcolor = CLR_BLACK, max_width = lbl_w },
                TextWidget:new{ text = sub_label, face = face_sub, fgcolor = CLR_BLACK, max_width = lbl_w },
            }
        else
            lbl_widget = TextWidget:new{ text = label, face = face_lbl_row, fgcolor = CLR_BLACK, max_width = lbl_w }
        end

        local row_content = HorizontalGroup:new{
            align = "center",
            _CenterContainer:new{
                dimen = Geom:new{ w = ICON_W, h = ROW_H },
                TextWidget:new{ text = icon_glyph, face = face_icon_row, fgcolor = CLR_BLACK },
            },
            _LeftContainer:new{ dimen = Geom:new{ w = lbl_w, h = ROW_H }, lbl_widget },
            _RightContainer:new{
                dimen = Geom:new{ w = val_w, h = ROW_H },
                TextWidget:new{
                    text = tostring(value_str), face = face_val_row, bold = true,
                    fgcolor = CLR_BLACK, max_width = val_w, alignment = "right",
                },
            },
        }

        return FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = PAD_H, padding_right = PAD_H,
            dimen = Geom:new{ w = inner_w, h = ROW_H },
            row_content,
        }
    end

    local function makeRowSep()
        return FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = PAD_H, padding_right = PAD_H,
            LineWidget:new{ dimen = Geom:new{ w = row_inner, h = SUIStyle.BORDER_SZ }, background = CLR_BORDER },
        }
    end

    local cur_streak_val = streaks.days.current
    local cur_streak_str = string.format(N_("%d day", "%d days", cur_streak_val), cur_streak_val)
    local best_streak_val = streaks.days.best
    local best_streak_str = string.format(N_("%d day", "%d days", best_streak_val), best_streak_val)
    local best_dates = nil
    if best_streak_val > 1 and streaks.days.best_start > 0 then
        best_dates = _riFmtDate(streaks.days.best_start) .. " \xe2\x80\x93 " .. _riFmtDate(streaks.days.best_end)
    end

    local streak_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER, radius = SZ(Screen:scaleBySize(12)),
        padding = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("calendar"), _("Current streak"), cur_streak_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("trophy"), _("Best streak"), best_streak_str, best_dates),
        },
    }

    local cur_wstreak_val = streaks.weeks.current
    local cur_wstreak_str = string.format(N_("%d week", "%d weeks", cur_wstreak_val), cur_wstreak_val)
    local best_wstreak_val = streaks.weeks.best
    local best_wstreak_str = string.format(N_("%d week", "%d weeks", best_wstreak_val), best_wstreak_val)
    local best_w_dates = nil
    if best_wstreak_val > 1 and streaks.weeks.best_start > 0 then
        best_w_dates = _riFmtDate(streaks.weeks.best_start) .. " \xe2\x80\x93 " .. _riFmtDate(streaks.weeks.best_end)
    end

    local wstreak_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER, radius = SZ(Screen:scaleBySize(12)),
        padding = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("calendar"), _("Current streak"), cur_wstreak_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("trophy"), _("Best streak"), best_wstreak_str, best_w_dates),
        },
    }

    return streak_row, wstreak_row
end

local function _buildInsightsPage2(inner_w, avail_h, streaks, SZ)
    SZ = SZ or UI.SZ
    _lazyLoad()      -- ensure _CenterContainer, _LeftContainer, etc. are loaded
    local Size    = require("ui/size")
    local sec_gap = math.max(SZ(Screen:scaleBySize(6)), math.floor(avail_h * 0.025))

    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local CLR_BORDER = Blitbuffer.gray(0.72)

    local face_val  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_TITLE))
    local face_lbl  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local face_sub  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))

    local lastweek = _riGetLastWeekStats()
    local thisweek_stats = _riGetThisWeekStats()
    local month_stats = _riGetThisMonthStats()
    local alltime  = _riGetAllTimeStats()

    local face_c3_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local face_c3_val = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_TITLE))

    local col_gap3    = SZ(Screen:scaleBySize(8))
    local cell_w3     = math.floor((inner_w - 2 * col_gap3) / 3)
    local cell_vpad3  = SZ(Screen:scaleBySize(16))
    local icon_h3     = SZ(Screen:scaleBySize(26))
    local lbl_h3      = face_c3_lbl.size + SZ(Screen:scaleBySize(2))
    local val_h3      = face_c3_val.size + SZ(Screen:scaleBySize(2))
    local cell_h3     = cell_vpad3 * 2 + icon_h3 + SZ(Screen:scaleBySize(6)) + val_h3 + SZ(Screen:scaleBySize(2)) + lbl_h3

    local function make3Cell(icon_char, value, label)
        return FrameContainer:new{
            bordersize     = 0, padding = 0,
            padding_top    = cell_vpad3,
            padding_bottom = cell_vpad3,
            dimen          = Geom:new{ w = cell_w3, h = cell_h3 },
            VerticalGroup:new{ align = "center",
                _CenterContainer:new{
                    dimen = Geom:new{ w = cell_w3, h = icon_h3 },
                    TextWidget:new{
                        text      = icon_char,
                        face      = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_TITLE)),
                        fgcolor   = CLR_BLACK,
                        width     = cell_w3,
                        alignment = "center",
                    },
                },
                VerticalSpan:new{ width = SZ(Screen:scaleBySize(6)) },
                _CenterContainer:new{
                    dimen = Geom:new{ w = cell_w3, h = val_h3 },
                    TextWidget:new{
                        text      = tostring(value),
                        face      = face_c3_val,
                        fgcolor   = CLR_BLACK,
                        bold      = true,
                        width     = cell_w3,
                        alignment = "center",
                    },
                },
                VerticalSpan:new{ width = SZ(Screen:scaleBySize(2)) },
                _CenterContainer:new{
                    dimen = Geom:new{ w = cell_w3, h = lbl_h3 },
                    TextWidget:new{
                        text      = label,
                        face      = face_c3_lbl,
                        fgcolor   = CLR_BLACK,
                        width     = cell_w3,
                        alignment = "center",
                    },
                },
            },
        }
    end

    local function make3ColRow(c1, c2, c3)
        local sep_w = SUIStyle.BORDER_SZ
        local cw = math.floor((inner_w - 2 * sep_w) / 3)
        return HorizontalGroup:new{
            _CenterContainer:new{ dimen = Geom:new{ w = cw, h = cell_h3 }, c1 },
            _CenterContainer:new{
                dimen = Geom:new{ w = sep_w, h = cell_h3 },
                LineWidget:new{ dimen = Geom:new{ w = sep_w, h = cell_h3 - SZ(Screen:scaleBySize(32)) }, background = CLR_BORDER }
            },
            _CenterContainer:new{ dimen = Geom:new{ w = cw, h = cell_h3 }, c2 },
            _CenterContainer:new{
                dimen = Geom:new{ w = sep_w, h = cell_h3 },
                LineWidget:new{ dimen = Geom:new{ w = sep_w, h = cell_h3 - SZ(Screen:scaleBySize(32)) }, background = CLR_BORDER }
            },
            _CenterContainer:new{ dimen = Geom:new{ w = cw, h = cell_h3 }, c3 },
        }
    end

    local alltime_row = make3ColRow(
        make3Cell(SUIStyle.icon("clock"), _riFmtCount(alltime.hours), _("hours read")),
        make3Cell(SUIStyle.icon("page"), _riFmtCount(alltime.pages), _("pages read")),
        make3Cell(SUIStyle.icon("book"), _riFmtCount(alltime.book_count), _("books finished")))

    local alltime_block = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = SZ(Screen:scaleBySize(12)),
        padding    = 0, margin = 0,
        alltime_row,
    }

    local avg_secs      = lastweek.avg_seconds
    local avg_time_str  = _riFmtHours(avg_secs)
    if avg_secs < 60 then avg_time_str = "0m" end
    local avg_pages_val = math.floor(lastweek.avg_pages + 0.5)
    local avg_pages_str = _riFmtCount(avg_pages_val)

    local face_icon_row = Font:getFace(SUIStyle.FACE_ICONS, SZ(SUIStyle.FS_BODY))
    local face_lbl_row  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_val_row  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local ROW_H         = SZ(Screen:scaleBySize(52))
    local PAD_H         = Size.padding.large
    local ICON_W        = SZ(Screen:scaleBySize(36))
    local row_inner     = inner_w - 2 * PAD_H

    local function makeIconRow(icon_glyph, label, value_str, sub_label)
        local val_w = SZ(Screen:scaleBySize(160))
        local lbl_w = row_inner - ICON_W - val_w

        local lbl_widget
        if sub_label then
            lbl_widget = VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text      = label,
                    face      = face_lbl_row,
                    fgcolor   = CLR_BLACK,
                    max_width = lbl_w,
                },
                TextWidget:new{
                    text      = sub_label,
                    face      = face_sub,
                    fgcolor   = CLR_BLACK,
                    max_width = lbl_w,
                }
            }
        else
            lbl_widget = TextWidget:new{
                text      = label,
                face      = face_lbl_row,
                fgcolor   = CLR_BLACK,
                max_width = lbl_w,
            }
        end

        local row_content = HorizontalGroup:new{
            align = "center",
            _CenterContainer:new{
                dimen = Geom:new{ w = ICON_W, h = ROW_H },
                TextWidget:new{
                    text    = icon_glyph,
                    face    = face_icon_row,
                    fgcolor = CLR_BLACK,
                },
            },
            _LeftContainer:new{
                dimen = Geom:new{ w = lbl_w, h = ROW_H },
                lbl_widget,
            },
            _RightContainer:new{
                dimen = Geom:new{ w = val_w, h = ROW_H },
                TextWidget:new{
                    text      = tostring(value_str),
                    face      = face_val_row,
                    bold      = true,
                    fgcolor   = CLR_BLACK,
                    max_width = val_w,
                    alignment = "right",
                },
            },
        }

        return FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = PAD_H,
            padding_right = PAD_H,
            dimen         = Geom:new{ w = inner_w, h = ROW_H },
            row_content,
        }
    end

    local function makeRowSep()
        return FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = PAD_H,
            padding_right = PAD_H,
            LineWidget:new{
                dimen      = Geom:new{ w = row_inner, h = SUIStyle.BORDER_SZ },
                background = CLR_BORDER,
            },
        }
    end

    local week_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = SZ(Screen:scaleBySize(12)),
        padding    = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("clock"), _("Average per day"), avg_time_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("page"), _("Pages per day"), avg_pages_str),
        },
    }

    local thisweek_time_str = _riFmtHours(thisweek_stats.seconds)
    if thisweek_stats.seconds < 60 then thisweek_time_str = "0m" end
    local thisweek_pages_str = _riFmtCount(thisweek_stats.pages)

    local thisweek_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = SZ(Screen:scaleBySize(12)),
        padding    = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("clock"), _("Total time"), thisweek_time_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("page"), _("Pages read"), thisweek_pages_str),
        },
    }

    local month_time_str = _riFmtHours(month_stats.seconds)
    local month_pages_str = _riFmtCount(month_stats.pages)

    local month_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = SZ(Screen:scaleBySize(12)),
        padding    = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("clock"), _("Total time"), month_time_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("page"), _("Pages read"), month_pages_str),
        },
    }

    local streak_row, wstreak_row = _riBuildStreakBoxes(inner_w, streaks, SZ)

    return alltime_block, week_row, thisweek_row, month_row, streak_row, wstreak_row
end

-- (cache declarations moved above data fetchers)

local function _riClearCache()
    _ri_cache   = {}
    _ri_streaks = nil
end

local function _riGetOrFetchYear(year)
    if _ri_cache[year] then return _ri_cache[year] end
    local entry = {
        yearly_stats = _riGetYearlyStats(year),
        monthly_data = _riGetMonthlyData(year),
    }
    _ri_cache[year] = entry
    return entry
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

-- mode_key persisted across window sessions so the user's last choice is
-- remembered, but is not written to LuaSettings (ephemeral preference).
local _ri_mode_key = "days"  -- "days" | "hours"

--- Shows a brief "Loading statistics…" toast and flushes it to the e-ink
--- screen immediately, so there is visible feedback before the (potentially
--- slow) SQLite queries run.
---
--- Controlled by the "simpleui_stats_loading_notice" setting (default on).
--- Callers must invoke this *before* any blocking work so the notice reaches
--- the screen while the homescreen/library dialog is still the background.
function StatsWindows.showLoadingNotice()
    local ok_ss, SUISettings = pcall(require, "sui_settings")
    if ok_ss and SUISettings and not SUISettings:nilOrTrue("simpleui_stats_loading_notice") then
        return nil
    end
    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not ok_im or not InfoMessage then return nil end
    local notice = InfoMessage:new{
        text    = _("Loading statistics\xe2\x80\xa6"),
        timeout = 0.0,
    }
    UIManager:show(notice)
    UIManager:forceRePaint()
    StatsWindows._loading_notice = notice
    return notice
end

--- Opens the Reading Insights window.
--- Can be called from module_reading_stats (streak card tap) or any other
--- SimpleUI touch-point.
function StatsWindows.showReadingInsightsWindow(on_close_extra)
    _lazyLoad()
    local SUIWindow = require("sui_window")

    -- Pre-flight: load streaks once; they span all years.
    if not _ri_streaks then
        _ri_streaks = _riGetStreaks()
    end

    local year_range = _riGetYearRange()
    -- Start at the most recent year with data.
    local selected_year = year_range.max_year

    -- Pre-load the initial year's data before opening so there is no blank
    -- flash on first render.
    _riGetOrFetchYear(selected_year)

    -- -------------------------------------------------------------------
    -- The window uses a single __root__ screen whose content is rebuilt
    -- each time the year or mode changes via ctx.repaint().
    -- State is held in upvalues (selected_year, _ri_mode_key) so it
    -- survives across repaints without needing the nav stack.
    -- -------------------------------------------------------------------
    local win_ref  -- filled after SUIWindow:new so callbacks can call repaint

    local function buildRootScreen(ctx)
        local inner_w = ctx.inner_w
        local entry   = _riGetOrFetchYear(selected_year)
        local yearly  = entry.yearly_stats
        local monthly = entry.monthly_data
        local streaks = _ri_streaks
        local today   = _riGetTodayStats()

        -- Estimate the available content height using the same formula as
        -- SUIWindow._rebuildFrame, so all sections can size themselves
        -- proportionally and the layout stays on one page on any screen.
        local Size       = require("ui/size")
        -- Mirrors showReadingInsightsWindow's actual height fraction below
        -- (23/30, matching the Settings window) — must stay in sync with
        -- that SUIWindow:new{ height = ... } value.
        local modal_h    = math.floor((select(2, UI.getPortraitDims())) * 23 / 30)
        local border     = Size.border.window
        local pad_v      = Size.padding.large
        local title_h    = ctx.SZ(Screen:scaleBySize(50))  -- conservative TitleBar estimate
        local dot_h      = ctx.SZ(Screen:scaleBySize(28)) + ctx.SZ(Screen:scaleBySize(18))
        local avail_h    = modal_h - 2 * border - pad_v - title_h - dot_h

        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local CLR_BORDER = Blitbuffer.gray(0.72)

        local face_sec    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

        local function sectionLabel(text)
            return TextWidget:new{
                text    = type(text) == "string" and text:upper() or text,
                face    = face_sec,
                fgcolor = CLR_BLACK,
                bold    = true,
            }
        end

        local today_time_str  = _riFmtHours(today.seconds)
        if today.seconds < 60 then today_time_str = "0m" end
        local today_pages_str = _riFmtCount(today.pages)

        local today_gap = ctx.SZ(Screen:scaleBySize(12))
        local today_card_w = math.floor((inner_w - today_gap) / 2)
        local cell_h2 = math.max(ctx.SZ(Screen:scaleBySize(70)), math.min(ctx.SZ(Screen:scaleBySize(110)), math.floor(avail_h * 0.16)))
        local today_card_h = cell_h2 + ctx.SZ(Screen:scaleBySize(24))

        local function makeTodayCard(icon_char, value, label)
            local face_today_val = Font:getFace(SUIStyle.FACE_REGULAR, math.floor(ctx.SZ(SUIStyle.FS_TITLE * 1.6)))
            local face_lbl       = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

            local icon_w = TextWidget:new{
                text    = icon_char,
                face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(ctx.SZ(SUIStyle.FS_TITLE * 1.6))),
                fgcolor = CLR_BLACK,
            }

            local text_vg = VerticalGroup:new{ align = "left",
                TextWidget:new{
                    text    = value,
                    face    = face_today_val,
                    fgcolor = CLR_BLACK,
                    bold    = true,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(2)) },
                TextWidget:new{
                    text    = label,
                    face    = face_lbl,
                    fgcolor = CLR_BLACK,
                }
            }

            local hg = HorizontalGroup:new{ align = "center",
                icon_w,
                HorizontalSpan:new{ width = ctx.SZ(Screen:scaleBySize(12)) },
                text_vg
            }

            return FrameContainer:new{
                bordersize = SUIStyle.BORDER_SZ,
                color      = CLR_BORDER,
                radius     = ctx.SZ(Screen:scaleBySize(12)),
                padding    = 0, margin = 0,
                _CenterContainer:new{
                    dimen = Geom:new{ w = today_card_w, h = today_card_h },
                    hg,
                }
            }
        end

        local today_row = HorizontalGroup:new{ align = "center",
            makeTodayCard(SUIStyle.icon("clock"), today_time_str, _("reading time")),
            HorizontalSpan:new{ width = today_gap },
            makeTodayCard(SUIStyle.icon("page"), today_pages_str, _("pages read")),
        }

        -- ── Section 2: year header + stats row ───────────────────────
        local function goPrev()
            if selected_year > year_range.min_year then
                selected_year = selected_year - 1
                _riGetOrFetchYear(selected_year)
                ctx.repaint()
            end
        end

        local function goNext()
            if selected_year < year_range.max_year then
                selected_year = selected_year + 1
                _riGetOrFetchYear(selected_year)
                ctx.repaint()
            end
        end

        local year_header = _riYearHeader(inner_w, selected_year,
                                          year_range, goPrev, goNext, ctx.SZ)

        local function toggleMode()
            _ri_mode_key = (_ri_mode_key == "hours") and "days" or "hours"
            ctx.repaint()
        end

        local yearly_row = _riYearlyRow(inner_w, yearly, _ri_mode_key, toggleMode, avail_h, ctx.SZ)

        -- ── Section 3: monthly chart ──────────────────────────────────
        local value_key = _ri_mode_key == "hours" and "hours" or "days"
        local chart     = _riMonthlyChart(inner_w, monthly, value_key, selected_year, avail_h, ctx.SZ)

        -- ── Assemble into independent per-section widgets ────────────────
        local alltime_block, week_row, thisweek_row, month_row, streak_row, wstreak_row = _buildInsightsPage2(inner_w, avail_h, streaks, ctx.SZ)

        -- Each section is its own top-level item in the returned array, so
        -- SUIWindow's real pagination (_buildPages in sui_window.lua)
        -- measures its TRUE rendered height and packs sections onto pages
        -- accordingly — starting a new page whenever the next section
        -- wouldn't fit, instead of a page's content silently overflowing
        -- past the modal's bounds.
        --
        -- NOTE: these blocks are deliberately NOT marked is_section. That
        -- flag exists in _buildPages for the *bare label* case (see
        -- SUIWindow.Section / MenuTable's is_title rows), where a lone
        -- section-header widget is followed by its content as a SEPARATE
        -- array item — on overflow, _buildPages pulls the already-placed
        -- header back out and re-pairs it with the incoming item so the
        -- header never sits orphaned at the bottom of a page.
        -- Here, title + content are already fused into one atomic widget
        -- (there is nothing to re-pair). Marking these is_section made
        -- _buildPages treat the PREVIOUS already-placed section as an
        -- orphan-prone header and glue it to the current (often much
        -- larger, e.g. the chart-containing alltime_and_year) block on the
        -- new page — so the new page ended up holding two full sections
        -- instead of one, still overflowing avail_h and getting clipped.
        -- Leaving is_section unset makes _buildPages fall back to its plain
        -- page-break path: whichever section doesn't fit starts a fresh
        -- page alone, with the full avail_h to itself.
        --
        -- Previously this screen hand-grouped sections into exactly three
        -- FrameContainers, each forced to report height = avail_h
        -- regardless of its child's actual size — so when the real content
        -- (translated strings, larger fonts, etc.) ran taller than the
        -- avail_h estimate, the excess simply painted past the frame
        -- instead of moving to a new page.
        local function section(title, content)
            return VerticalGroup:new{ align = "left",
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
                sectionLabel(title),
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
                content,
            }
        end

        local alltime_section = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            sectionLabel(_("ALL TIME")),
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            alltime_block,
        }

        -- year_header already renders its own year number + prev/next nav,
        -- so it doubles as this group's title — no separate sectionLabel
        -- needed. Split out from the old combined alltime_and_year block:
        -- that single item bundled ALL TIME + year nav + yearly row + the
        -- monthly chart into one ~5-widget block that, on any screen where
        -- it ran taller than avail_h (larger fonts, longer translated
        -- strings, landscape's reduced avail_h), had nowhere to go — a
        -- single oversized item can only be moved whole to a fresh page,
        -- never split further, so it kept clipping regardless of which
        -- page it landed on. Breaking it into alltime_section and
        -- year_chart_section gives _buildPages two much smaller atomic
        -- units instead of one large one, so each has a real chance of
        -- fitting standalone within avail_h, and they can land on separate
        -- pages if needed instead of being forced to move (and overflow)
        -- together.
        local year_chart_section = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            year_header,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
            yearly_row,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            chart,
        }

        return {
            section(_("TODAY'S SUMMARY"), today_row),
            section(_("DAY STREAK"), streak_row),
            section(_("WEEK STREAK"), wstreak_row),
            section(_("LAST 7 DAYS"), week_row),
            section(_("THIS WEEK"), thisweek_row),
            section(_("THIS MONTH"), month_row),
            alltime_section,
            year_chart_section,
        }
    end

    -- Swipe navigation: swipe left = next year, swipe right = prev year.
    -- Implemented via a screen_footer that is invisible but gesture-aware.
    -- (SUIWindow wraps content so we rely on the window's own onSwipe if
    --  the framework exposes it; otherwise we skip and rely on tap buttons.)

    local function titleFn(ctx)
        return _("Reading Insights")
    end

    local win = SUIWindow:new{
        name          = "sui_win_reading_insights",
        title         = titleFn,
        -- Matches the Settings window's height (SUIWindow's own default,
        -- 23/30 of portrait height, when no explicit height is passed),
        -- rather than the slightly shorter 0.75 used before.
        height        = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens       = {
            __root__ = buildRootScreen,
        },
        on_close = function()
            _riClearCache()
            if on_close_extra then on_close_extra() end
        end,
    }
    win_ref = win
    win:show()
end

-- ===========================================================================
-- showStreakManagerWindow
-- ===========================================================================
-- Opens the Streak Manager window: current streak header, last-read date,
-- and a Sunday-first month calendar badging every day that counts toward
-- the streak (real activity, or — when the freeze mechanic is enabled — a
-- frozen day too, visually distinguished). Phase 4 adds a freeze-management
-- section below the calendar, conditionally, when freeze mode is on; this
-- phase's window already works correctly on its own ("Real streak only"
-- mode simply never has that section to add).
--
-- Calendar layout ideas (day_width from inner_w/7, filler cells for
-- out-of-month padding, chevron month navigation, Sunday-first week) are
-- adapted from readingstreak.koplugin's readingstreak_calendarview.lua —
-- a different framework context (a standalone FocusManager fullscreen
-- widget, not a SUIWindow screen), so only the layout ideas are reused, not
-- the code itself.
-- ===========================================================================

-- Frozen-day badge glyph: nf-fa-snowflake-o (U+F2DC), rendered in place of
-- the flame glyph (module_reading_stats.lua's _STREAK_ICON, U+F490) on days
-- covered by a spent freeze rather than real activity, so the two are always
-- visually distinguishable at a glance. Keep this in sync with itself only —
-- there is no shared constant with module_reading_stats.lua on purpose (see
-- that module's own _STREAK_ICON comment for how to change ITS icon; this
-- one is independent).
local _SM_STREAK_ICON = "\u{F490}"  -- nf-fa-fire — same glyph/meaning as the homescreen card
local _SM_FROZEN_ICON = "\u{F2DC}"  -- nf-fa-snowflake-o — frozen-day badge
local _SM_STREAK_ICON_CLR = Blitbuffer.COLOR_WHITE
local _SM_FROZEN_ICON_CLR = Blitbuffer.COLOR_WHITE

-- Day-cell circle fill colours (see _smDayCell): a dark dot for
-- unread/future/filler days, and a light fill for every day that
-- counts toward the streak — whether that's a lone active day (plain
-- circle, no icon) or a day within a run of 2+ (streak-fire or frozen-
-- snowflake icon on the same light circle).
local _SM_CIRCLE_UNREAD = Blitbuffer.gray(0.15)
local _SM_CIRCLE_COUNTED = Blitbuffer.gray(0.85)

-- Sunday-first weekday abbreviations and full month names, translated via
-- this project's own _() i18n (mirrors the existing _monthAbbr() pattern in
-- this same file) rather than pulling locale tables from KOReader's
-- `datetime` module, so these strings land in simpleui.pot/pt_PT.po/pt_BR.po
-- like every other user-facing string in the plugin.
local _SM_WEEKDAY_ABBR
local function _smWeekdayAbbr()
    if not _SM_WEEKDAY_ABBR then
        _SM_WEEKDAY_ABBR = {
            _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"),
        }
    end
    return _SM_WEEKDAY_ABBR
end

local _SM_MONTH_FULL
local function _smMonthFull()
    if not _SM_MONTH_FULL then
        _SM_MONTH_FULL = {
            _("January"), _("February"), _("March"), _("April"),
            _("May"), _("June"), _("July"), _("August"),
            _("September"), _("October"), _("November"), _("December"),
        }
    end
    return _SM_MONTH_FULL
end

-- ---------------------------------------------------------------------------
-- Data fetchers
-- ---------------------------------------------------------------------------

-- Whether date_str ("YYYY-MM-DD") has real reading activity (duration > 0).
-- Used by the Phase 4 freeze-spend eligibility check — deliberately checks
-- page_stat directly rather than the month-activity cache, since it needs
-- to work regardless of which month the calendar currently has selected.
local function _smGetRealActivityFor(date_str)
    return _withStatsDb(false, function(conn)
        local found = false
        _withStmt(conn, string.format([[
            SELECT 1 FROM page_stat
            WHERE duration > 0 AND date(start_time,'unixepoch','localtime') = '%s'
            LIMIT 1
        ]], date_str), function(stmt)
            for row in stmt:rows() do found = true end
        end)
        return found
    end)
end

-- Per-window-session cache of month → activity set, so navigating back to
-- an already-visited month during the same window session (e.g. prev then
-- next) doesn't re-run the query. Cleared on window close, like _ri_cache.
local _sm_month_cache = {}

local function _smClearCache()
    _sm_month_cache = {}
end

-- Set of "YYYY-MM-DD" → true for real-activity days (duration > 0) in the
-- given calendar month.
local function _smGetMonthActiveDates(year, month)
    local key = string.format("%04d-%02d", year, month)
    if _sm_month_cache[key] then return _sm_month_cache[key] end

    local set = _withStatsDb({}, function(conn)
        local s = {}
        _withStmt(conn, string.format([[
            SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d
            FROM page_stat
            WHERE duration > 0
              AND strftime('%%Y-%%m', start_time, 'unixepoch', 'localtime') = '%s'
        ]], key), function(stmt)
            for row in stmt:rows() do s[row[1]] = true end
        end)
        return s
    end)

    _sm_month_cache[key] = set
    return set
end

-- ---------------------------------------------------------------------------
-- _smMonthHeader — month/year label with prev/next chevrons.
-- Mirrors _riYearHeader's exact OverlapGroup/navBtn construction (same
-- codepoints, same centring approach) so month navigation here looks and
-- behaves like year navigation in Reading Insights.
-- ---------------------------------------------------------------------------
local function _smMonthHeader(inner_w, year, month, prev_enabled, next_enabled, on_prev, on_next, SZ)
    SZ = SZ or UI.SZ
    local face      = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
    local face_chev = Font:getFace(SUIStyle.FACE_ICONS, math.floor(SZ(SUIStyle.FS_TITLE * 1.8)))
    local CLR_BLACK = Blitbuffer.COLOR_BLACK

    local gap   = SZ(Screen:scaleBySize(16))
    local btn_w = SZ(Screen:scaleBySize(60))

    local label_txt = _smMonthFull()[month] .. " " .. tostring(year)
    local label_w = TextWidget:new{
        text    = label_txt,
        face    = face,
        fgcolor = CLR_BLACK,
        bold    = true,
        padding = 0,
    }

    local lbl_w = label_w:getSize().w
    local lbl_h = label_w:getSize().h

    local function navBtn(label, enabled, cb)
        local tw = TextWidget:new{
            text    = label,
            face    = face_chev,
            fgcolor = enabled and CLR_BLACK or Blitbuffer.gray(0.25),
            padding = 0,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = btn_w, h = lbl_h },
            _CenterContainer:new{
                dimen = Geom:new{ w = btn_w, h = lbl_h },
                tw,
            }
        }
        if enabled then
            ic.ges_events = {
                Tap = { GestureRange:new{ ges = "tap",
                    range = function() return ic.dimen end } },
            }
            function ic:onTap() cb(); return true end
        end
        return ic
    end

    local prev_btn = navBtn("\u{E840}", prev_enabled, on_prev)
    local next_btn = navBtn("\u{E841}", next_enabled, on_next)

    local center_x = math.floor(inner_w / 2)
    local half_lbl = math.floor(lbl_w / 2)

    prev_btn.overlap_offset = { center_x - half_lbl - gap - btn_w, 0 }
    label_w.overlap_offset  = { center_x - half_lbl, 0 }
    next_btn.overlap_offset = { center_x + half_lbl + gap, 0 }

    return OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = lbl_h },
        prev_btn,
        label_w,
        next_btn,
    }
end

-- ---------------------------------------------------------------------------
-- _smBlankCell — a filler position outside the displayed month (before
-- day 1 or after the last day). No circle at all — only real days of the
-- month get a dot — just an empty cell of the same size, so the grid's
-- column alignment stays intact.
-- ---------------------------------------------------------------------------
local function _smBlankCell(SZ, cell_w, cell_h)
    return _CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        TextWidget:new{ text = "", face = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY)) },
    }
end

-- ---------------------------------------------------------------------------
-- _smDayCell — one calendar day cell for a real day of the displayed
-- month (filler positions outside it use _smBlankCell instead).
-- Numberless "dot" design: a dark dot for a day that simply wasn't read
-- (or is still in the future), a solid light dot for a lone active day,
-- and — once that day is part of a run of 2+ consecutive counted days
-- (real activity and/or frozen days both count, see is_counted/is_run
-- below) — the same light dot gains the streak-fire icon, or the
-- frozen-snowflake icon on the specific day(s) that are frozen. A frozen
-- day always shows the snowflake regardless of is_run: the freeze itself
-- is the thing worth surfacing, and its neighbours keep showing fire
-- precisely because the freeze kept their run unbroken.
-- ---------------------------------------------------------------------------
local function _smDayCell(SZ, cell_w, cell_h, is_counted, is_frozen, is_run)
    local diameter = math.floor(math.min(cell_w, cell_h) * 0.72)
    local face_icon = Font:getFace(SUIStyle.FACE_ICONS, SZ(math.floor(SUIStyle.FS_DETAIL)))

    local bg, content
    if not is_counted then
        bg = _SM_CIRCLE_UNREAD
    else
        bg = _SM_CIRCLE_COUNTED
        if is_frozen or is_run then
            local icon_char = is_frozen and _SM_FROZEN_ICON or _SM_STREAK_ICON
            local icon_clr  = is_frozen and _SM_FROZEN_ICON_CLR or _SM_STREAK_ICON_CLR
            content = UI.makeColoredText{
                text    = icon_char,
                face    = face_icon,
                fgcolor = icon_clr,
            }
        end
    end

    local dot = FrameContainer:new{
        bordersize = 0,
        radius     = math.floor(diameter / 2),
        background = bg,
        padding    = 0,
        margin     = 0,
        _CenterContainer:new{
            dimen = Geom:new{ w = diameter, h = diameter },
            content or TextWidget:new{ text = "", face = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY)) },
        },
    }

    return _CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        dot,
    }
end

--- Opens the Streak window.
--- Can be called from module_reading_stats (streak card tap) or any other
--- SimpleUI touch-point.
function StatsWindows.showStreakManagerWindow()
    _lazyLoad()
    local SUIWindow = require("sui_window")

    -- Loaded once per window session. `streaks` (the full _riGetStreaks()
    -- result — both day- and week-streak data) is a mutable upvalue, not a
    -- plain one-time local, because "Use a freeze" changes the day streak
    -- immediately: the top cards and the DAY STREAK box must reflect that
    -- on the very next repaint, not just on next window open.
    local streaks
    local function refreshStreaks()
        streaks = _riGetStreaks()
    end
    refreshStreaks()

    local freeze_mode_on = SUIStreak.isFreezeModeEnabled()

    local now_t = os.date("*t")
    local selected_year  = now_t.year
    local selected_month = now_t.month

    local function buildRootScreen(ctx)
        local inner_w    = ctx.inner_w
        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local CLR_BORDER = Blitbuffer.gray(0.72)
        local face_sub   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION))
        local face_section = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

        -- ── Freeze-spend eligibility (hoisted above the calendar build) ────
        -- Computed once per repaint, up here, because the calendar grid
        -- below needs to know *which single cell* (yesterday, if it's
        -- currently displayed) should become the tap target for using a
        -- freeze — the freeze mechanic only ever bridges the single real
        -- gap immediately before today (see sui_streak.spendFreezeForYesterday),
        -- never an arbitrary past day, so at most one cell in the whole
        -- calendar is ever tappable for this.
        local freezes_available   = freeze_mode_on and SUIStreak.getFreezesAvailable() or 0
        local yest_t              = freeze_mode_on and os.date("*t", os.time() - 86400) or nil
        local yest_str            = freeze_mode_on and os.date("%Y-%m-%d", os.time() - 86400) or nil
        local yest_active         = freeze_mode_on and _smGetRealActivityFor(yest_str) or false
        local day_before_active   = freeze_mode_on and _smGetRealActivityFor(os.date("%Y-%m-%d", os.time() - 2 * 86400)) or false
        local yest_already_frozen = freeze_mode_on and SUIStreak.isDateFrozen(yest_str) or false
        -- gap_eligible: is yesterday specifically the one missed day (real
        -- activity the day before yesterday, none yesterday, not already
        -- frozen)? Deliberately checks REAL activity only (not frozen
        -- dates) — freezing bridges a genuine gap, it doesn't extend an
        -- already-frozen day. promptUseFreezeForYesterday additionally
        -- requires freezes_available > 0 before it treats this as usable.
        local gap_eligible   = freeze_mode_on and (not yest_active) and (not yest_already_frozen) and day_before_active

        local function useFreeze()
            local spent = SUIStreak.spendFreezeForYesterday()
            if spent then refreshStreaks() end
            ctx.repaint()
        end

        -- Tap handler for every OTHER day cell (i.e. not yesterday): the
        -- freeze mechanic can never be spent on an arbitrary past day, so
        -- there's nothing to confirm here — just an InfoMessage explaining
        -- why, so tapping any cell always does *something* instead of
        -- silently nothing.
        local function explainFreezeMechanic()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Freezes can only cover a single missed day, and only right after an active one. Tap yesterday's cell to use one, when eligible."),
            })
        end

        -- Tap handler for the yesterday cell: shows a confirmation dialog
        -- when a freeze can actually be spent, or an explanatory
        -- InfoMessage otherwise (no freezes banked, or yesterday doesn't
        -- qualify as a gap to bridge) — never silently does nothing.
        local function promptUseFreezeForYesterday()
            local InfoMessage = require("ui/widget/infomessage")
            if freezes_available <= 0 then
                UIManager:show(InfoMessage:new{
                    text = _("You don't have any freezes available yet."),
                })
                return
            end
            if not gap_eligible then
                local msg
                if yest_active then
                    msg = _("You already read yesterday — there's nothing to freeze.")
                elseif yest_already_frozen then
                    msg = _("Yesterday is already covered by a freeze.")
                else
                    msg = _("A freeze can only bridge a single missed day right after an active one — yesterday doesn't qualify.")
                end
                UIManager:show(InfoMessage:new{ text = msg })
                return
            end
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = string.format(_("You have %d freeze(s) available.\nUse one to cover %s?"),
                           freezes_available, _riFmtDate(os.time() - 86400)),
                ok_text     = _("Use freeze"),
                ok_callback = useFreeze,
            })
        end

        -- First page: a "CALENDAR" section header (same style as "DAY
        -- STREAK" / "WEEK STREAK" / "FREEZES" further down) followed by
        -- the calendar itself in a rounded bordered frame — the same
        -- FrameContainer recipe (border color/size, 12px radius) used for
        -- those boxes, so all the sections in this window share one look.
        local top_spacer = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            TextWidget:new{ text = _("CALENDAR"), face = face_section, fgcolor = CLR_BLACK, bold = true },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
        }

        -- ── Month calendar ───────────────────────────────────────────────
        local function goPrevMonth()
            selected_month = selected_month - 1
            if selected_month < 1 then
                selected_month = 12
                selected_year  = selected_year - 1
            end
            ctx.repaint()
        end

        local function goNextMonth()
            -- Never browse past the current real month — there is nothing
            -- meaningful to show beyond it, and "future days dimmed" only
            -- needs to apply within the current month view.
            if selected_year < now_t.year
                    or (selected_year == now_t.year and selected_month < now_t.month) then
                selected_month = selected_month + 1
                if selected_month > 12 then
                    selected_month = 1
                    selected_year  = selected_year + 1
                end
                ctx.repaint()
            end
        end

        local next_enabled = selected_year < now_t.year
            or (selected_year == now_t.year and selected_month < now_t.month)

        -- The calendar now sits inside a rounded bordered frame (see
        -- calendar_frame below), so cal_w leaves room for that frame's
        -- own left/right padding instead of spanning the full inner_w.
        local cal_pad = ctx.SZ(Screen:scaleBySize(16))
        local cal_w   = inner_w - 2 * cal_pad

        local month_header = _smMonthHeader(cal_w, selected_year, selected_month,
            true, next_enabled, goPrevMonth, goNextMonth, ctx.SZ)

        -- Weekday header row (Sunday-first).
        --
        -- CAL_SCALE shrinks the day cells themselves 10% relative to their
        -- previous size (kept as-is — this only affects individual cell
        -- width/height). Unlike before, the grid is no longer
        -- shrunk-then-centered with leftover margin on both sides: cell_w
        -- and cell_h stay exactly the size they always were (same vertical
        -- footprint), but the *gap* between cells is widened (see gap
        -- below) so that 7 cells + 6 gaps together span the full cal_w —
        -- i.e. the calendar now fills the whole horizontal space inside
        -- the frame via wider spacing, not via bigger cells.
        local CAL_SCALE = 0.9

        local gap_full    = ctx.SZ(Screen:scaleBySize(2))
        local cell_w_full = math.floor((cal_w - 6 * gap_full) / 7)
        local wd_h_full   = ctx.SZ(Screen:scaleBySize(20))
        local cell_h_full = math.max(ctx.SZ(Screen:scaleBySize(36)), cell_w_full)
        local span_full   = ctx.SZ(Screen:scaleBySize(4))

        local cell_w = math.floor(cell_w_full * CAL_SCALE)
        local wd_h   = math.floor(wd_h_full * CAL_SCALE)
        -- Horizontal gap re-derived to consume all the width CAL_SCALE
        -- freed up on the sides: 7 * cell_w + 6 * gap == cal_w.
        local gap    = math.max(1, math.floor((cal_w - 7 * cell_w) / 6))

        local face_wd = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION))
        local weekday_row = HorizontalGroup:new{ align = "center" }
        for i, name in ipairs(_smWeekdayAbbr()) do
            weekday_row[#weekday_row + 1] = _CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = wd_h },
                TextWidget:new{ text = name, face = face_wd, fgcolor = Blitbuffer.gray(0.45), bold = true },
            }
            if i < 7 then weekday_row[#weekday_row + 1] = HorizontalSpan:new{ width = gap } end
        end

        -- Active dates for this month (real activity) + frozen dates
        -- overlapping this month (empty when freeze mode is off — see
        -- sui_streak.getFrozenDatesInRange's own mode gate).
        local active_set = _smGetMonthActiveDates(selected_year, selected_month)
        local month_start_str = string.format("%04d-%02d-01", selected_year, selected_month)
        local days_in_month = os.date("*t", os.time{ year = selected_year, month = selected_month + 1, day = 0 }).day
        local month_end_str = string.format("%04d-%02d-%02d", selected_year, selected_month, days_in_month)
        local frozen_list = SUIStreak.getFrozenDatesInRange(month_start_str, month_end_str)
        local frozen_set = {}
        for _, d in ipairs(frozen_list) do frozen_set[d] = true end

        local first_wday = os.date("*t", os.time{ year = selected_year, month = selected_month, day = 1 }).wday
        -- os.date's wday is already 1=Sunday..7=Saturday, matching the
        -- Sunday-first week this window uses — no remapping needed.
        local cell_h = math.floor(cell_h_full * CAL_SCALE)

        -- Precompute, for every real day in the month, whether it counts
        -- toward the streak (real activity or — in freeze mode — a spent
        -- freeze) and whether it's frozen specifically. is_run is then a
        -- simple neighbour check on that same table: a day is "in a run"
        -- once either the day before or the day after also counts, which
        -- is exactly what turns its dot into a streak-fire (or, if it's
        -- the frozen day itself, snowflake) icon instead of a plain dot.
        -- This only looks at neighbours within the same calendar month —
        -- a run that starts on the last day of the previous month won't
        -- show as continuing into day 1 here, a minor cosmetic trade-off
        -- against querying an extra month just for this view.
        local counted, frozen = {}, {}
        for day_num = 1, days_in_month do
            local day_str = string.format("%04d-%02d-%02d", selected_year, selected_month, day_num)
            frozen[day_num]  = frozen_set[day_str] == true
            counted[day_num] = active_set[day_str] == true or (freeze_mode_on and frozen[day_num])
        end

        -- Build one flat list of cell descriptors — leading filler, every
        -- real day, trailing filler — THEN chunk into rows of 7. Doing it
        -- this way (rather than filling the first/last row separately)
        -- means exactly one rule ("span before every cell except the first
        -- in its row") applies uniformly everywhere, with no special-casing
        -- at the boundary between filler and real days.
        local cell_descs = {}
        for _ = 1, first_wday - 1 do
            cell_descs[#cell_descs + 1] = false  -- filler
        end
        for day_num = 1, days_in_month do
            cell_descs[#cell_descs + 1] = day_num
        end
        while #cell_descs % 7 ~= 0 do
            cell_descs[#cell_descs + 1] = false  -- trailing filler
        end

        local weeks = {}
        for idx, desc in ipairs(cell_descs) do
            local col_in_row = (idx - 1) % 7 + 1
            if col_in_row == 1 then
                weeks[#weeks + 1] = HorizontalGroup:new{ align = "center" }
            end
            local cur_row = weeks[#weeks]
            if col_in_row > 1 then
                cur_row[#cur_row + 1] = HorizontalSpan:new{ width = gap }
            end

            if desc == false then
                cur_row[#cur_row + 1] = _smBlankCell(ctx.SZ, cell_w, cell_h)
            else
                local day_num = desc
                local is_run = counted[day_num]
                    and ((counted[day_num - 1] == true) or (counted[day_num + 1] == true))
                local cell_widget = _smDayCell(ctx.SZ, cell_w, cell_h, counted[day_num], frozen[day_num], is_run)

                -- Every real day cell is tappable when freeze mode is on —
                -- not just "yesterday" — so a tap never falls flat. Only
                -- yesterday's cell (and only when the month/year currently
                -- on screen is the one it actually falls in — it may be
                -- last month's last day when today is the 1st) can ever
                -- actually spend a freeze, via promptUseFreezeForYesterday
                -- above; every other cell routes to explainFreezeMechanic,
                -- which just explains why that day isn't tappable for
                -- spending one.
                if freeze_mode_on then
                    local is_yesterday_cell = yest_t
                        and selected_year == yest_t.year and selected_month == yest_t.month
                        and day_num == yest_t.day
                    local on_tap = is_yesterday_cell and promptUseFreezeForYesterday or explainFreezeMechanic

                    local tappable = InputContainer:new{
                        dimen = cell_widget:getSize(),
                        [1]   = cell_widget,
                    }
                    tappable.ges_events = {
                        Tap = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
                    }
                    function tappable:onTap() on_tap(); return true end
                    cell_widget = tappable
                end

                cur_row[#cur_row + 1] = cell_widget
            end
        end

        -- grid_box centers the (now 10% smaller) weekday-row + day-rows
        -- horizontally within grid_w_full (= cal_w, the same width the
        -- frame around the calendar has always used — see the CAL_SCALE
        -- comment above), while its height is exactly the grid's own
        -- content height (no extra row spans, see the loop below), so
        -- there's no gap left between the last day row and the frame.
        local grid_w_full = cal_w
        local grid_h = wd_h + span_full + #weeks * cell_h + (#weeks - 1) * span_full

        local grid = VerticalGroup:new{ align = "left" }
        grid[#grid + 1] = weekday_row
        grid[#grid + 1] = VerticalSpan:new{ width = span_full }
        for idx, week_row in ipairs(weeks) do
            grid[#grid + 1] = week_row
            if idx < #weeks then
                grid[#grid + 1] = VerticalSpan:new{ width = span_full }
            end
        end

        local grid_box = _CenterContainer:new{
            dimen = Geom:new{ w = grid_w_full, h = grid_h },
            grid,
        }

        local calendar_group = VerticalGroup:new{ align = "left" }
        calendar_group[#calendar_group + 1] = month_header
        calendar_group[#calendar_group + 1] = VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(12)) }
        calendar_group[#calendar_group + 1] = grid_box

        -- Rounded bordered frame around the whole calendar — same recipe
        -- (border size/color, 12px radius) as the DAY STREAK / WEEK STREAK
        -- boxes further down, so this window's sections share one look.
        -- cal_w already accounts for cal_pad, so the calendar content fits
        -- the frame's interior exactly with no extra centering needed.
        local calendar_group = FrameContainer:new{
            bordersize     = SUIStyle.BORDER_SZ,
            color          = CLR_BORDER,
            radius         = ctx.SZ(Screen:scaleBySize(12)),
            padding        = 0,
            padding_left   = cal_pad,
            padding_right  = cal_pad,
            padding_top    = cal_pad,
            padding_bottom = cal_pad,
            margin         = 0,
            calendar_group,
        }

        -- ── DAY STREAK / WEEK STREAK boxes ───────────────────────────────
        -- Exact same widget recipe as Reading Insights' own streak boxes
        -- (shared via _riBuildStreakBoxes) — this is deliberately the same
        -- box the rest of the app already uses for this data, not a new
        -- style invented for this window. Each section header is glued to
        -- its box in one VerticalGroup so SUIWindow's automatic pagination
        -- (see _buildPages) can never split a heading from its box across
        -- two physical pages — they are one atomic item as far as the
        -- window's own pagination is concerned.
        local streak_row, wstreak_row = _riBuildStreakBoxes(inner_w, streaks, ctx.SZ)

        -- day_section is deliberately the first widget on page 2: marking
        -- it force_new_page (read by SUIWindow:_buildPages) means page 1
        -- always ends right after the calendar, no matter how much room is
        -- left over — the calendar page and the streak-boxes page are kept
        -- visually separate rather than however much of DAY STREAK happens
        -- to fit in the leftover space.
        local day_section = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            TextWidget:new{ text = _("DAY STREAK"), face = face_section, fgcolor = CLR_BLACK, bold = true },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            streak_row,
        }
        day_section.force_new_page = true
        local week_section = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            TextWidget:new{ text = _("WEEK STREAK"), face = face_section, fgcolor = CLR_BLACK, bold = true },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            wstreak_row,
        }

        -- ── Freeze section (conditional) ─────────────────────────────────
        -- Entirely omitted, not just hidden, when freeze mode is off — the
        -- section variable simply stays nil and is never added to the
        -- returned items list below, so the window reflows with no gap in
        -- "Real streak only" mode.
        local freeze_section = nil
        if freeze_mode_on then
            -- Progress toward the next day-based freeze: streaks.days.current % 5
            -- is exactly right without needing the watermark here — e.g. a
            -- streak of 7 with a freeze already granted at 5 shows "2/5"; a
            -- streak that just hit 10 shows "0/5" (a fresh cycle just
            -- started, matching maybeGrantDayFreeze's watermark update).
            local day_progress = streaks.days.current % SUIStreak.FREEZE_DAY_INTERVAL

            local time_secs = SUIStreak.getFreezeTimeProgress()
            local time_min  = math.floor(time_secs / 60)
            local time_target_min = math.floor(SUIStreak.FREEZE_TIME_THRESHOLD_SECS / 60)

            -- freezes_available itself comes from the eligibility block
            -- hoisted above the calendar build; using a freeze is now done
            -- by tapping yesterday's cell in the calendar (see
            -- promptUseFreezeForYesterday), so this box is pure display.

            local face_freeze_icon   = Font:getFace(SUIStyle.FACE_ICONS, math.floor(ctx.SZ(SUIStyle.FS_TITLE * 1.3)))
            -- One step down from FS_TITLE in the type scale (SUBTITLE), and
            -- not bold — still clearly bigger than progress_caption's
            -- FS_CAPTION below it, just no longer shouting the count.
            local face_freeze_txt    = Font:getFace(SUIStyle.FACE_REGULAR, math.floor(ctx.SZ(SUIStyle.FS_SUBTITLE)))

            local pad_box   = ctx.SZ(Screen:scaleBySize(16))
            local icon_box  = ctx.SZ(Screen:scaleBySize(40))

            local snow_icon = _CenterContainer:new{
                dimen = Geom:new{ w = icon_box, h = icon_box },
                TextWidget:new{ text = _SM_FROZEN_ICON, face = face_freeze_icon, fgcolor = CLR_BLACK },
            }

            -- Single TextWidget, single face — the count and the label are
            -- one sentence ("3 freezes available"), so there's no mixed
            -- font-size row to baseline-align in the first place.
            local avail_text = TextWidget:new{
                text    = string.format(N_("%d freeze available", "%d freezes available", freezes_available),
                              freezes_available),
                face    = face_freeze_txt,
                fgcolor = CLR_BLACK,
            }

            -- Sits directly under avail_text now (see label_col below),
            -- same role/text it always had, just repositioned.
            local progress_caption = TextWidget:new{
                text    = string.format(_("%d/%d days · %d/%d min to next freeze"),
                              day_progress, SUIStreak.FREEZE_DAY_INTERVAL, time_min, time_target_min),
                face    = face_sub,
                fgcolor = CLR_BLACK,
            }

            -- label_col: avail_text ("X freezes available") with
            -- progress_caption ("…to next freeze") stacked directly under
            -- it — the same icon/label/sub-label recipe _riBuildStreakBoxes'
            -- makeIconRow uses for "Best streak".
            local gap = ctx.SZ(Screen:scaleBySize(10))
            local label_col = VerticalGroup:new{ align = "left",
                avail_text,
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                progress_caption,
            }

            local box_inner_w = inner_w - 2 * pad_box

            -- Icon + label, centered horizontally inside the full box
            -- width. No tap target here anymore — using a freeze now
            -- happens by tapping yesterday's cell in the calendar above,
            -- so this box is purely informational (count + progress).
            local content_natural = HorizontalGroup:new{ align = "center",
                snow_icon,
                HorizontalSpan:new{ width = gap },
                label_col,
            }
            local content_row = _CenterContainer:new{
                dimen = Geom:new{ w = box_inner_w, h = content_natural:getSize().h },
                content_natural,
            }

            local freeze_box = FrameContainer:new{
                bordersize     = 0,
                -- Same background as _makeDateCard's "date started / date
                -- finished" card in the Books Finished window, per request.
                background     = Blitbuffer.gray(0.08),
                radius         = ctx.SZ(Screen:scaleBySize(12)),
                padding        = 0,
                padding_left   = pad_box,
                padding_right  = pad_box,
                padding_top    = pad_box,
                padding_bottom = pad_box,
                dimen          = Geom:new{ w = inner_w, h = content_row:getSize().h + 2 * pad_box },
                content_row,
            }

            freeze_section = VerticalGroup:new{ align = "left",
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
                TextWidget:new{ text = _("FREEZES"), face = face_section, fgcolor = CLR_BLACK, bold = true },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
                freeze_box,
                -- Small breathing-room gap below the freeze box, matching
                -- after_calendar_spacer's role at the end of page 1 — page 2
                -- would otherwise end flush against freeze_box with no
                -- bottom margin at all.
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(12)) },
            }
        end

        -- Small breathing-room gap between the calendar and where page 2
        -- starts (day_section, force_new_page) — stays on page 1 since it's
        -- ordered before the widget that forces the break.
        local after_calendar_spacer = VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(12)) }

        local items = { top_spacer, calendar_group, after_calendar_spacer, day_section, week_section }
        if freeze_section then
            items[#items + 1] = freeze_section
        end
        return items
    end

    local win = SUIWindow:new{
        name          = "sui_win_streak_manager",
        title         = function() return _("Streak") end,
        -- height is now the max ceiling, not the fixed size: auto_height_per_page
        -- shrinks each page (calendar-only page 1, streak-boxes page 2) to its
        -- own content, clamped to this same 23/30-of-portrait-height value that
        -- used to be the fixed height — same reasoning as Reading Insights.
        height        = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        auto_height_per_page = true,
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens       = {
            __root__ = buildRootScreen,
        },
        on_close = function()
            _smClearCache()
        end,
    }
    win:show()
end


-- Opens a standalone SUIWindow showing the per-book statistics screen for the
-- book at `filepath`.  This is the same "book_stats" screen rendered inside
-- showFinishedBooksDialog, but surfaced directly from the library long-press
-- dialog without requiring the user to navigate through the history list.
--
-- Usage:
--   local ok, SW = pcall(require, "sui_stats_windows")
--   if ok and SW then SW.showBookStatsFromFile(filepath) end
-- ===========================================================================
function StatsWindows.showBookStatsFromFile(filepath)
    if not filepath then return end
    _lazyLoad()

    -- Build a minimal book descriptor expected by _fetchBookStatsData /
    -- buildStatsScreen.  Title and authors are best-effort from the sidecar;
    -- _fetchBookStatsData will overwrite them with DB values anyway.
    local book = { filepath = filepath }
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.hasSidecarFile
       and DocSettings:hasSidecarFile(filepath) then
        local ok_open, ds = pcall(function() return DocSettings:open(filepath) end)
        if ok_open and ds then
            local doc_props = ds:readSetting("doc_props")
            if doc_props then
                book.title   = doc_props.title
                book.authors = doc_props.authors
            end
            -- Read date_finished and date_started so the
            -- date card shows the user-visible dates rather than raw DB timestamps.
            local summary = ds:readSetting("summary")
            if type(summary) == "table" then
                if summary.status == "complete" then
                    book.date_finished = (type(summary.date_finished) == "string" and summary.date_finished)
                                         or (type(summary.modified)   == "string" and summary.modified)
                                         or nil
                end
                if type(summary.date_started) == "string" then
                    book.date_started = summary.date_started
                end
                book.exclude_from_goals = summary.exclude_from_goals
            end
            pcall(function() ds:close() end)
        end
    end
    if not book.title or book.title == "" then
        book.title = filepath:match("([^/]+)$") or filepath
    end

    -- Fetch statistics; bail with an InfoMessage if none exist.
    local d, err = _fetchBookStatsData(book)
    if not d then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = err or _("No statistics found for this book."),
        })
        return
    end

    local SUIWindow = require("sui_window")

    -- Reuse the same buildStatsScreen logic from showFinishedBooksDialog,
    -- reproduced here as a self-contained closure so the two call-sites stay
    -- independent and neither imposes load on the other.
    local function buildStatsScreen(ctx)
        local inner_w = ctx.inner_w
        -- ctx.current().params is set via ctx.push(); for a root screen we
        -- provide the data through the upvalues directly.
        local params  = ctx.current and ctx.current().params
        if params then
            d    = params.stats or d
            book = params.book  or book
        end
        -- Recompute the date-range-dependent aggregates whenever the user
        -- has edited the start/end date on this book (see the sibling
        -- buildStatsScreen in showFinishedBooksDialog for the full rationale).
        if book and (type(book.date_started) == "string" or type(book.date_finished) == "string") then
            local start_ts = _dateStrToTs(book.date_started, false)
            local end_ts   = _dateStrToTs(book.date_finished, true)
            local filtered = _fetchBookStatsData(book, start_ts, end_ts)
            if filtered then d = filtered end
        end

        local CLR_BORDER = Blitbuffer.gray(0.72)
        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local PAD_H      = _Size.padding.large
        local ICON_FS    = ctx.SZ(SUIStyle.FS_BODY)
        local ROW_H      = ctx.SZ(Screen:scaleBySize(52))

        -- ── cell geometry (3-col top metrics) ──────────────────────────
        local sep_w      = SUIStyle.BORDER_SZ
        local col_w      = math.floor((inner_w - 2 * (ctx.SZ(Screen:scaleBySize(10)))) / 3)
        local cell_v_pad = ctx.SZ(Screen:scaleBySize(16))
        local face_val   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE))
        local face_lbl   = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))
        local lbl_h      = math.floor(face_lbl.size * 2.2)
        local val_h      = face_val.size + ctx.SZ(Screen:scaleBySize(2))
        local cell_h     = cell_v_pad * 2 + val_h + ctx.SZ(Screen:scaleBySize(2)) + lbl_h
        local card_gap   = ctx.SZ(Screen:scaleBySize(10))
        local text_max_w = inner_w - 2 * PAD_H

        -- ── helpers ────────────────────────────────────────────────────
        local function makeTopCell(value, label, w)
            local vg = VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text      = tostring(value),
                    face      = face_val,
                    bold      = true,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(2)) },
                TextWidget:new{
                    text      = label,
                    face      = face_lbl,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
            }
            return FrameContainer:new{
                bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER,
                radius     = ctx.SZ(Screen:scaleBySize(12)),
                padding    = 0, margin = 0,
                _CenterContainer:new{
                    dimen = Geom:new{ w = w, h = cell_h },
                    vg,
                },
            }
        end

        local pages_read_str = string.format("%d (%d%%)",
            d.total_read_pages,
            math.floor(100 * d.total_read_pages / (d.pages > 0 and d.pages or 1) + 0.5))

        local metrics_row = HorizontalGroup:new{
            makeTopCell(_fmtDuration(d.total_time_book), _("Total"),  col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(tostring(d.total_days),           _("Days"),   col_w),
            HorizontalSpan:new{ width = card_gap },
            makeTopCell(pages_read_str,                   _("Pages"),  col_w),
        }

        local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_SUBTITLE))
        local face_author = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))

        local title_author_group = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(24)) },
            _TextBoxWidget:new{
                text      = d.title,
                face      = face_title,
                bold      = true,
                fgcolor   = CLR_BLACK,
                width     = text_max_w,
                alignment = "center",
                height    = math.floor(1.3 * face_title.size + 0.5) * 1,
                height_adjust = true,
                max_lines = 1,
                height_overflow_show_ellipsis = true,
            },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
            TextWidget:new{
                text      = d.authors or "",
                face      = face_author,
                fgcolor   = CLR_BLACK,
                max_width = text_max_w,
            },
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
        }

        local fp = book.filepath
        local tappable_title
        if fp then
            local ta_h = title_author_group:getSize().h
            local ic = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = ta_h },
                title_author_group,
            }
            ic.ges_events = {
                Tap = { GestureRange:new{
                    ges   = "tap",
                    range = function() return ic.dimen end,
                }},
            }
            function ic:onTap()
                _openBookFromStats(fp)
                return true
            end
            tappable_title = ic
        else
            tappable_title = title_author_group
        end

        local top_card = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            VerticalGroup:new{
                align = "center",
                tappable_title,
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
                metrics_row,
            },
        }

        -- ── icon rows ──────────────────────────────────────────────────
        local on_tap_highlights, on_tap_notes
        if fp and (d.highlights > 0 or d.notes > 0) then
            local ok_bb = pcall(require, "ui/widget/bookmarkbrowser")
            if ok_bb then
                local function openBrowser()
                    local BookmarkBrowser = require("ui/widget/bookmarkbrowser")
                    local ui = nil
                    local ok_app, App = pcall(function()
                        return require("apps/filemanager/filemanager")
                    end)
                    if ok_app and App and App.instance then ui = App.instance end
                    BookmarkBrowser:show({ [fp] = true }, ui)
                end
                if d.highlights > 0 then on_tap_highlights = openBrowser end
                if d.notes      > 0 then on_tap_notes      = openBrowser end
            end
        end

        local icon_face = Font:getFace(SUIStyle.FACE_ICONS,   ICON_FS)
        local lbl_face  = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))
        local val_face  = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY))
        local ICON_W    = ctx.SZ(Screen:scaleBySize(36))
        local row_inner = inner_w - 2 * PAD_H

        local function makeIconRow(icon_glyph, label, value_str, on_tap)
            local val_w = ctx.SZ(Screen:scaleBySize(160))
            local lbl_w = row_inner - ICON_W - val_w
            local row_content = HorizontalGroup:new{
                align = "center",
                _CenterContainer:new{
                    dimen = Geom:new{ w = ICON_W, h = ROW_H },
                    TextWidget:new{ text = icon_glyph, face = icon_face, fgcolor = CLR_BLACK },
                },
                _LeftContainer:new{
                    dimen = Geom:new{ w = lbl_w, h = ROW_H },
                    TextWidget:new{ text = label, face = lbl_face, fgcolor = CLR_BLACK, max_width = lbl_w },
                },
                _RightContainer:new{
                    dimen = Geom:new{ w = val_w, h = ROW_H },
                    TextWidget:new{
                        text      = tostring(value_str),
                        face      = val_face,
                        bold      = true,
                        fgcolor   = CLR_BLACK,
                        max_width = val_w,
                    },
                },
            }
            local padded = FrameContainer:new{
                bordersize = 0, padding = 0,
                padding_left = PAD_H, padding_right = PAD_H,
                dimen = Geom:new{ w = inner_w, h = ROW_H },
                row_content,
            }
            if not on_tap then return padded end
            local ic = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = ROW_H },
                padded,
            }
            ic.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = function() return ic.dimen end }},
            }
            function ic:onTap() on_tap(); return true end
            return ic
        end

        local function makeRowSep()
            return FrameContainer:new{
                bordersize = 0, padding = 0,
                padding_left = PAD_H, padding_right = PAD_H,
                LineWidget:new{
                    dimen      = Geom:new{ w = row_inner, h = SUIStyle.BORDER_SZ },
                    background = CLR_BORDER,
                },
            }
        end

        -- Two compact half-width cells sharing a single row, separated by a
        -- thin vertical divider (used for Highlights | Notes).
        local function makeDualIconRow(icon1, label1, value1, on_tap1,
                                        icon2, label2, value2, on_tap2)
            local sep_w   = SUIStyle.BORDER_SZ
            local sep_gap = ctx.SZ(Screen:scaleBySize(10))
            local half_w1 = math.floor((row_inner - sep_w - 2 * sep_gap) / 2)
            local half_w2 = row_inner - sep_w - 2 * sep_gap - half_w1
            local val_w   = ctx.SZ(Screen:scaleBySize(50))

            local function makeHalf(icon_glyph, label, value_str, w)
                local lbl_w = w - ICON_W - val_w
                return HorizontalGroup:new{
                    align = "center",
                    _CenterContainer:new{
                        dimen = Geom:new{ w = ICON_W, h = ROW_H },
                        TextWidget:new{ text = icon_glyph, face = icon_face, fgcolor = CLR_BLACK },
                    },
                    _LeftContainer:new{
                        dimen = Geom:new{ w = lbl_w, h = ROW_H },
                        TextWidget:new{ text = label, face = lbl_face, fgcolor = CLR_BLACK, max_width = lbl_w },
                    },
                    _RightContainer:new{
                        dimen = Geom:new{ w = val_w, h = ROW_H },
                        TextWidget:new{
                            text      = tostring(value_str),
                            face      = val_face,
                            bold      = true,
                            fgcolor   = CLR_BLACK,
                            max_width = val_w,
                        },
                    },
                }
            end

            local function wrapTap(widget, w, on_tap)
                if not on_tap then return widget end
                local ic = InputContainer:new{
                    dimen = Geom:new{ w = w, h = ROW_H },
                    widget,
                }
                ic.ges_events = {
                    Tap = { GestureRange:new{
                        ges   = "tap",
                        range = function() return ic.dimen end,
                    }},
                }
                function ic:onTap() on_tap(); return true end
                return ic
            end

            local half1 = wrapTap(makeHalf(icon1, label1, value1, half_w1), half_w1, on_tap1)
            local half2 = wrapTap(makeHalf(icon2, label2, value2, half_w2), half_w2, on_tap2)

            local separator = _CenterContainer:new{
                dimen = Geom:new{ w = sep_w, h = ROW_H },
                LineWidget:new{
                    dimen      = Geom:new{ w = sep_w, h = math.floor(ROW_H * 0.6) },
                    background = CLR_BORDER,
                },
            }

            local row_content = HorizontalGroup:new{
                align = "center",
                half1,
                HorizontalSpan:new{ width = sep_gap },
                separator,
                HorizontalSpan:new{ width = sep_gap },
                half2,
            }

            return FrameContainer:new{
                bordersize    = 0, padding = 0,
                padding_left  = PAD_H,
                padding_right = PAD_H,
                dimen         = Geom:new{ w = inner_w, h = ROW_H },
                row_content,
            }
        end

        local rows_block = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ,
            color      = CLR_BORDER,
            radius     = ctx.SZ(Screen:scaleBySize(12)),
            padding    = 0,
            VerticalGroup:new{
                align = "left",
                makeIconRow(SUIStyle.icon("clock"),      _("Average per day"),  _fmtDuration(d.avg_time_per_day)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("page"),       _("Average per page"), _fmtDuration(d.avg_time_per_page)),
                makeRowSep(),
                makeDualIconRow(
                    SUIStyle.icon("highlights"), _("Highlights"), tostring(d.highlights), on_tap_highlights,
                    SUIStyle.icon("notes"),      _("Notes"),      tostring(d.notes),      on_tap_notes
                ),
            },
        }

        -- ── date range card ────────────────────────────────────────────

        -- DB-derived fallbacks (used for display and as Reset targets).
        local original_start_str = _fmtDate(d.first_open)
        local original_end_str   = (type(book.date_finished) == "string" and d.last_open and _fmtDate(d.last_open)) or "\xe2\x80\x93"

        -- Prefer sidecar dates over raw DB timestamps.
        local date_start_str = (type(book.date_started) == "string" and book.date_started)
                               or original_start_str
        local date_end_str   = (type(book.date_finished) == "string" and book.date_finished)
                               or original_end_str

        local date_widget = _makeDateCard(
            inner_w, PAD_H,
            date_start_str, date_end_str,
            original_start_str, original_end_str,
            fp,
            function(new_date)   -- on_start_saved / on_start_reset
                book.date_started = (new_date ~= original_start_str) and new_date or nil
                ctx.repaint()
            end,
            function(new_date)   -- on_end_saved / on_end_reset
                book.date_finished = (new_date ~= original_end_str) and new_date or nil
                ctx.repaint()
            end,
            ctx.SZ
        )

        local block_gap = VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(10)) }
        return {
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(6)) },
            top_card,
            block_gap,
            rows_block,
            block_gap,
            date_widget,
        }
    end


    local win = SUIWindow:new{
        name     = "sui_win_book_stats_standalone",
        title    = _("Book Statistics"),
        -- Matches the Settings window's height (SUIWindow's own default,
        -- 23/30 of portrait height), same as the other stats windows.
        height   = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position = "bottom",
        navpager_mode = require("sui_config").isNavpagerEnabled(),
        screens  = { __root__ = buildStatsScreen },
    }
    if StatsWindows._loading_notice then
        UIManager:close(StatsWindows._loading_notice)
        StatsWindows._loading_notice = nil
    end
    win:show()
end

return StatsWindows