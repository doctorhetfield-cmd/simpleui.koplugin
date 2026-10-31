-- sui_stats_windows.lua — Simple UI
-- Aggregates various statistics windows.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local RoundedFrame    = require("infra/sui_backdrop").RoundedFrame
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
local _               = require("infra/sui_i18n").translate
local N_              = require("infra/sui_i18n").ngettext
local logger          = require("logger")
local Config          = require("infra/sui_config")
local SUIStyle        = require("features/sui_style")
local UI              = require("infra/sui_core")
local SUIStreak       = require("infra/sui_streak")
local Ledger          = require("infra/sui_stats_ledger")
local DateNames       = require("infra/sui_datenames")
local Charts          = require("engines/sui_stats_charts")
local Frames          = require("screens/insights/sui_insights_frames")
local InsightsCharts  = require("screens/insights/sui_insights_charts")

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
-- themselves screen builders (_makeDateCard, _riMonthlyChart) take SZ as an explicit trailing
-- parameter from their caller's ctx.SZ, falling back to UI.SZ if ever called
-- without one.
local function SZ(n) return UI.SZ(n) end

local StatsWindows = {}

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
            return conn:rowexec(string.format(Config.BOOK_ID_BY_MD5_SQL, md5))
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
        if fp and type(book.date_started) == "string" then
            -- Sidecar value takes priority; store as string so _fmtDateRange
            -- can handle it (it accepts both unix timestamps and YYYY-MM-DD).
            start_dates[fp] = book.date_started
        elseif fp then
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

-- Formats a "YYYY-MM-DD" stamp as a short date, and a "YYYY" stamp as is.
local function _fmtStamp(stamp)
    local date = _parseDate(stamp)
    if not date then return stamp end
    return string.format("%02d %s %d", date.d, _monthAbbr()[date.m] or "?", date.y)
end

-- Date range of a finished book for the list: a manually entered book may
-- carry either stamp, or only a year.
local function _fmtBookRange(book, start_dates)
    if book.manual then
        if book.date_started and book.date_finished then
            return _fmtStamp(book.date_started) .. " \xe2\x80\x93 " .. _fmtStamp(book.date_finished)
        end
        if book.date_finished then return _fmtStamp(book.date_finished) end
        return _fmtStamp(book.date_started) .. " \xe2\x80\x93"
    end
    -- Preserved books have no file to read dates from; show the year only.
    if not book.filepath then return book.year and tostring(book.year) end
    return _fmtDateRange(start_dates[book.filepath], book.date_finished)
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
    local _year, month = require("modules/module_stats_provider").parseStamp(s)
    return month ~= nil
end

-- Applies `mutate(summary)` to the sidecar summary of `filepath` and flushes
-- it, unless `mutate` returns false (nothing to change). The stats provider
-- is then told the book changed, so the counts, the ledger and the screens
-- follow the edit.
local function _updateSummary(filepath, mutate)
    if not filepath then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, filepath)
    if not ok_open or not ds then return false end

    local summary = ds:readSetting("summary") or {}
    if mutate(summary) ~= false then
        ds:saveSetting("summary", summary)
        ds:flush()
    end

    local SP = package.loaded["modules/module_stats_provider"]
    if SP and SP.bookChanged then SP.bookChanged(filepath) end
    return true
end

-- Sets the completion date and marks the book complete.
local function _writeSummaryModified(filepath, date_str)
    if not _isValidDateStr(date_str) then return false end
    return _updateSummary(filepath, function(summary)
        summary.modified      = date_str
        summary.date_finished = date_str
        summary.status        = "complete"
    end)
end

-- Sets the start date. SimpleUI-only field; KOReader ignores unknown sidecar keys.
local function _writeSummaryStarted(filepath, date_str)
    if not _isValidDateStr(date_str) then return false end
    return _updateSummary(filepath, function(summary)
        summary.date_started = date_str
    end)
end

local function _writeSummaryExclude(filepath, excluded)
    return _updateSummary(filepath, function(summary)
        summary.exclude_from_goals = excluded and true or nil
    end)
end

-- Removes keys from the summary (used by the Reset button to revert to the
-- DB-derived fallback).
local function _deleteSummaryFields(filepath, ...)
    local keys = { ... }
    return _updateSummary(filepath, function(summary)
        local changed = false
        for _, key in ipairs(keys) do
            if summary[key] ~= nil then
                summary[key] = nil
                changed      = true
            end
        end
        return changed
    end)
end

-- Builds a date range card with independently tappable start/end halves.
--
-- Parameters:
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
-- InputContainer.  Tapping opens the text prompt with Cancel / Reset / Save.
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
    local CLR_BLACK  = SUIStyle.COLOR.text_primary
    local ARROW      = SUIStyle.icon("arrow_right")
    local date_inner = inner_w - 2 * PAD_H
    local date_third = math.floor(date_inner / 3)
    local date_row_h = SZ(Screen:scaleBySize(24))

    -- Helper: open a prompt for a single date field.
    -- delete_fn  – called with filepath on Reset to remove the sidecar field
    -- original   – the DB fallback value passed to on_saved after a reset
    -- has_custom – true when the displayed value came from the sidecar (not DB)
    local function openDateDialog(title, current, write_fn, delete_fn,
                                  original, has_custom, on_saved)
        local format_error = _("Please enter a date in YYYY-MM-DD format.")
        require("features/dialogs/sui_dialogs").prompt{
            title       = title,
            value       = current or os.date("%Y-%m-%d"),
            hint        = "YYYY-MM-DD",
            ok_text     = _("Save"),
            empty_error = format_error,
            validate    = function(text)
                if not _isValidDateStr(text) then return format_error end
            end,
            on_submit   = function(text)
                if write_fn(filepath, text) then
                    on_saved(text)
                end
            end,
            buttons     = {
                {
                    text     = _("Reset"),
                    enabled  = has_custom,
                    callback = function()
                        delete_fn(filepath)
                        on_saved(original)
                    end,
                },
            },
        }
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
        function(fp) _deleteSummaryFields(fp, "date_started") end,
        original_start_str,
        on_start_saved)

    local end_widget = makeSideTappable(
        date_end_str, _("Date finished"),
        _writeSummaryModified,
        function(fp) _deleteSummaryFields(fp, "date_finished", "modified") end,
        original_end_str,
        on_end_saved)

    return RoundedFrame:new{
        bordersize     = 0,
        radius         = SZ(Screen:scaleBySize(12)),
        background     = SUIStyle.COLOR.surface_flat,
        padding_top    = SZ(Screen:scaleBySize(14)),
        padding_bottom = SZ(Screen:scaleBySize(14)),
        padding_left   = PAD_H,
        padding_right  = PAD_H,
        HorizontalGroup:new{
            align = "center",
            start_widget,
            _CenterContainer:new{
                dimen = Geom:new{ w = date_inner - 2 * date_third, h = date_row_h },
                UI.makeAccentText({ text = ARROW, face = face_arrow }, CLR_BLACK),
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
    local Dialogs = require("features/dialogs/sui_dialogs")
    local BD        = require("ui/bidi")
    Dialogs.confirm{
        text        = _("Open this file?") .. "\n\n"
                      .. BD.filename(filepath:match("([^/]+)$")),
        ok_text     = _("Open"),
        cancel_text = _("Cancel"),
        ok_callback = doOpen,
    }
end

-- Year-dropdown options covering min_year..max_year, newest first.
local function _yearOptions(min_year, max_year)
    local options = {}
    for year = max_year, min_year, -1 do
        options[#options + 1] = { value = year, text = tostring(year) }
    end
    return options
end

--- Lists finished books one year at a time, with a year selector.
--- opts: { initial_year = number (default: current year), on_back = function }
function StatsWindows.showFinishedBooksDialog(opts)
    opts = opts or {}
    _lazyLoad()
    local SUIWindow   = require("engines/sui_window")
    local SP          = require("modules/module_stats_provider")
    local ManualBooks = require("features/sui_manual_books")

    local selected_year = opts.initial_year or tonumber(os.date("%Y"))
    local min_year, max_year, books_by_year, start_dates, book_date_range

    -- Reads the finished books and derives everything the list shows from
    -- them. Returns how many there are.
    local function loadBooks()
        local all_books = SP.getFinishedBooks()
        min_year, max_year = SP.getFinishedYears()
        selected_year = math.max(min_year, math.min(selected_year, max_year))

        -- Books per completion year; each list keeps the provider's newest-first order.
        books_by_year = {}
        for _i, book in ipairs(all_books) do
            if book.year then
                local list = books_by_year[book.year] or {}
                list[#list + 1] = book
                books_by_year[book.year] = list
            end
        end

        start_dates     = _getStartDatesForBooks(all_books)
        book_date_range = {}
        for _i, book in ipairs(all_books) do
            book_date_range[book.key] = _fmtBookRange(book, start_dates)
        end
        return #all_books
    end

    if loadBooks() == 0 then
        UI.Notify.toast(_("No books finished"))
        return
    end

    local face_stat_title  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
    local face_stat_author = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_cell_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local face_cell_val    = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_TITLE))
    local CLR_BLACK = SUIStyle.COLOR.text_primary

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

    -- Returns a callback that re-reads the books and repaints `ctx`'s screen.
    local function reloaderFor(ctx)
        return function()
            loadBooks()
            ctx.repaint()
        end
    end

    -- Returns a callback that re-reads the books and returns to the screen
    -- below the current one.
    local function reloaderAndPopFor(ctx)
        return function()
            loadBooks()
            ctx.pop()
        end
    end

    local function openAddBookMenu(ctx)
        ctx.push("nested_menu", {
            title = ManualBooks.menuTitle(),
            items = ManualBooks.makeEntryItems(reloaderAndPopFor(ctx)),
        })
    end

    local function buildListScreen(ctx)
        local inner_w = ctx.inner_w
        local rows = {}
        local reload = reloaderFor(ctx)
        for _i, book in ipairs(books_by_year[selected_year] or {}) do
            local date_range = book_date_range[book.key] or "\xe2\x80\x93"
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

            local row = {
                inner_w      = inner_w,
                title        = book.title,
                subtitle     = sub_text,
                right_value  = date_range,
                dim_only     = book.exclude_from_goals,
                show_chevron = book.filepath ~= nil or book.manual,
                separator    = true,
            }
            if book.count then
                -- Books entered as a plain number: one row standing for all of them.
                row.title       = _("Manual Yearly Count")
                row.right_value = string.format(N_("%d book", "%d books", book.count), book.count)
                row.on_tap      = function() ManualBooks.showCountDialog(book.year, reload) end
            elseif book.manual then
                row.on_tap = function() ManualBooks.showBookDialog(book, reload) end
            elseif book.filepath then
                row.on_tap = function()
                    local d, err = _fetchBookStatsData(book)
                    if not d then
                        UI.Notify.toast(err or _("Unknown error."))
                        return
                    end
                    ctx.push("book_stats", { book = book, stats = d })
                end
            end
            rows[#rows + 1] = SUIWindow.ListRow(row)
        end
        if #rows == 0 then
            rows[1] = SUIWindow.ListRow{
                inner_w  = inner_w,
                title    = string.format(_("No books finished in %s"), tostring(selected_year)),
                dim_only = true,
            }
        end
        return rows
    end

    -- Year selector and the add-book button, fixed above the list on every page.
    local function buildListHeader(ctx)
        return SUIWindow.ToolbarRow{
            inner_w = ctx.inner_w,
            left    = SUIWindow.PeriodDropdown{
                compact   = true,
                options   = _yearOptions(min_year, max_year),
                selected  = selected_year,
                on_select = function(year)
                    selected_year = year
                    ctx.repaint()
                end,
            },
            right   = SUIWindow.SquareButton{
                glyph  = SUIStyle.icon("add_book"),
                on_tap = function() openAddBookMenu(ctx) end,
            },
        }
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

        local CLR_BORDER = SUIStyle.COLOR.gray
        local CLR_BLACK  = SUIStyle.COLOR.text_primary
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

            return RoundedFrame:new{
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

            local icon_widget = UI.makeAccentText({ text = icon_glyph, face = icon_face }, CLR_BLACK)

            local row_content = HorizontalGroup:new{
                align = "center",
                _CenterContainer:new{
                    dimen = Geom:new{ w = ICON_W, h = ROW_H },
                    icon_widget,
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
                        UI.makeAccentText({ text = icon_glyph, face = icon_face }, CLR_BLACK),
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

        local rows_block = RoundedFrame:new{
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
                    SUIStyle.selectionIcon(false, book.exclude_from_goals),
                    _("Exclude from goals"),
                    book.exclude_from_goals and _("Yes") or _("No"),
                    function()
                        local next_val = not book.exclude_from_goals
                        book.exclude_from_goals = next_val and true or nil
                        _writeSummaryExclude(fp, book.exclude_from_goals)
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

    local function titleFn()
        local count = SP.countFinished(books_by_year[selected_year] or {})
        return string.format(N_("%d book read", "%d books read", count), count)
    end

    local screens = SUIWindow.makeSettingsScreens(buildListScreen)
    screens.book_stats = buildStatsScreen

    local win = SUIWindow:new{
        name           = "sui_win_reading_history",
        icon           = "chart",
        on_back        = opts.on_back,
        title          = titleFn,
        screen_titles  = {
            nested_menu = function(ctx) return ctx.current().params.title end,
        },
        -- Matches the Settings window's height (SUIWindow's own default,
        -- 23/30 of portrait height), same as Reading Insights/Streak.
        height         = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position       = "bottom",
        navpager_mode  = require("infra/sui_config").isNavpagerEnabled(),
        screens        = screens,
        screen_headers = {
            __root__   = buildListHeader,
        },
    }
    win:show()
end

-- ===========================================================================
-- showReadingInsightsWindow
-- ===========================================================================
-- A SUIWindow that surfaces historical reading insights drawn from the
-- statistics SQLite database.
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
-- _ledger: the stats ledger snapshot (infra/sui_stats_ledger) the Reading
-- Insights and Streak windows read their daily history from, taken once per
-- window session.
local _ri_cache   = {}
local _ri_activity = {}   -- year -> books and pages per month (SP.getYearActivity), false when unreadable
local _ri_streaks = nil
local _ledger     = nil

-- The ledger snapshot of this window session, nil when the database cannot be
-- read.
local function _getLedger()
    if not _ledger then _ledger = Ledger.get() end
    return _ledger
end

-- ---------------------------------------------------------------------------
-- Reading-insights data fetchers
-- ---------------------------------------------------------------------------

-- Returns { min_year, max_year } of the recorded reading.
local function _riGetYearRange()
    local current_year = tonumber(os.date("%Y"))
    local ledger = _getLedger()
    local min_year, max_year = ledger and ledger:yearRange()
    return { min_year = min_year or current_year, max_year = max_year or current_year }
end

-- Returns { days, pages, duration } for a given year.
local function _riGetYearlyStats(year)
    local ledger = _getLedger()
    if not ledger then return { days = 0, pages = 0, duration = 0 } end
    local days, duration = ledger:yearTotals(year)
    return { days = days, pages = ledger:pagesInYear(year) or 0, duration = duration }
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
    local ledger = _getLedger()
    local totals = ledger and ledger:monthTotals(year)
    local result = {}
    for m = 1, 12 do
        local h = totals and totals[m].secs / 3600 or 0
        if h >= 1 then h = math.floor(h)
        elseif h > 0 then h = math.floor(h * 10) / 10 end
        result[m] = {
            month      = string.format("%04d-%02d", year, m),
            days       = totals and totals[m].days or 0,
            hours      = h,
            label      = _MONTH_SHORT[m],
            label_full = _MONTH_FULL[m],
            month_num  = m,
        }
    end
    return result
end

-- Returns { days={current,best,best_start,best_end},
--           weeks={current,best,best_start,best_end} } all-time streaks.
-- Uses the same algorithm as the patch's calculateStreaks().
local function _riGetStreaks()
    local zero_streak = { current=0, best=0, best_start=0, best_end=0 }
    local default = { days = zero_streak, weeks = zero_streak }
    local ledger = _getLedger()
    if not ledger then return default end
    do
        -- ── Day streaks ──────────────────────────────────────────────────
        -- The ledger's active dates are the days with reading time (rows with
        -- duration > 0, so a crash/force-close leaves no gap), exactly like
        -- module_stats_provider.lua's fetchStreak — needed so the two "current
        -- streak" sources this window and the homescreen card both ultimately
        -- feed into sui_streak.computeCurrentDayStreak() actually agree on the
        -- same set of "active" dates, not just share the same walk function.
        local dates = ledger:activeDates()

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
        local weeks = ledger:weeks()

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
    end
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
-- Pages are the sum of the distinct pages of each year.
local function _riGetAllTimeStats()
    if _ri_cache["alltime"] then return _ri_cache["alltime"] end
    local r = { hours = 0, pages = 0, book_count = 0 }

    local ledger = _getLedger()
    if ledger then
        r.hours = math.floor(ledger:totalSeconds() / 3600)
        local year_range = _riGetYearRange()
        for y = year_range.min_year, year_range.max_year do
            r.pages = r.pages + (ledger:pagesInYear(y) or 0)
        end
    end

    local ok_sp, SP = pcall(require, "modules/module_stats_provider")
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
local function _riMonthlyChart(inner_w, monthly_data, value_key, selected_year, avail_h, SZ)
    SZ = SZ or UI.SZ
    if not monthly_data or #monthly_data == 0 then return VerticalGroup:new{} end

    local current_year  = tonumber(os.date("%Y"))
    local current_month = os.date("%Y-%m")

    local peak = 1
    for _, m in ipairs(monthly_data) do
        peak = math.max(peak, tonumber(m[value_key]) or 0)
    end

    -- A single row of twelve months; bar_h follows the available height, clamped for legibility.
    local bar_h    = math.max(SZ(Screen:scaleBySize(40)),
                        math.min(SZ(Screen:scaleBySize(90)),
                            math.floor(avail_h * 0.14)))
    local bar_w, bar_gap = Charts.fitBars(#monthly_data, inner_w, SZ(Screen:scaleBySize(40)))
    if not bar_w then return VerticalGroup:new{} end
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION - 2))
    local lbl_h    = face_lbl.size + SZ(Screen:scaleBySize(2))

    -- The current month of the current year is dark; every other bar is light.
    local values, value_labels, labels, highlight = {}, {}, {}, 0
    for i, m in ipairs(monthly_data) do
        local val = tonumber(m[value_key]) or 0
        values[i]       = val
        value_labels[i] = val > 0 and tostring(val) or ""
        labels[i]       = m.label:lower()
        if selected_year == current_year and m.month == current_month then highlight = i end
    end
    local bars = Charts.bars{
        values = values, peak = peak, bar_w = bar_w, gap = bar_gap,
        max_h = bar_h + lbl_h, avail_h = bar_h + 3 * lbl_h,
        color = SUIStyle.accent(SUIStyle.COLOR.text_primary), highlight = highlight,
        labels = labels, value_labels = value_labels,
        label_face = face_lbl, label_color = SUIStyle.COLOR.text_primary,
    }
    if not bars then return VerticalGroup:new{} end
    return _CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = bars:getSize().h }, bars }
end

-- ---------------------------------------------------------------------------
-- Page 2 — "Today, Last Week & All-Time" deep-stats screen
-- ---------------------------------------------------------------------------

-- SZ threaded in by the caller (ctx.SZ); falls back to UI.SZ if ever called
-- without one (identical value during a synchronous window build).
-- ---------------------------------------------------------------------------
-- _riStreakCategories — the "Day streak" and "Week streak" categories (current
-- and best streak in one card of rows each), shared by the Reading Insights and
-- Streak windows.
-- ---------------------------------------------------------------------------
local function _riStreakCategories(card_w, SZ, streaks)
    local function bestDates(streak)
        if streak.best > 1 and streak.best_start > 0 then
            return _riFmtDate(streak.best_start) .. " \xe2\x80\x93 " .. _riFmtDate(streak.best_end)
        end
    end
    local function category(title, streak, count)
        local items = {
            { icon = "streak", label = _("Current streak"), value = count(streak.current) },
            { icon = "trophy", label = _("Best streak"), sub = bestDates(streak), value = count(streak.best) },
        }
        return { title = title, children = { Frames.rows{ w = card_w, SZ = SZ, items = items } } }
    end
    return {
        category(_("Day streak"), streaks.days, function(n)
            return string.format(N_("%d day", "%d days", n), n)
        end),
        category(_("Week streak"), streaks.weeks, function(n)
            return string.format(N_("%d week", "%d weeks", n), n)
        end),
    }
end

-- Figures of the periods the Reading Insights window shows besides today and
-- the year: the last 7 days, this week, this month and all time.
local function _riGetPeriodStats()
    return {
        lastweek = _riGetLastWeekStats(),
        thisweek = _riGetThisWeekStats(),
        month    = _riGetThisMonthStats(),
        alltime  = _riGetAllTimeStats(),
    }
end

-- (cache declarations moved above data fetchers)

local function _riClearCache()
    _ri_cache   = {}
    _ri_activity = {}
    _ri_streaks = nil
    _ledger     = nil
end

-- Books finished and pages read per month of `year`, nil when the statistics
-- cannot be read.
local function _riGetActivity(year)
    if _ri_activity[year] == nil then
        _ri_activity[year] = _withStatsDb(nil, function(conn)
            return require("modules/module_stats_provider").getYearActivity(conn, year)
        end) or false
    end
    return _ri_activity[year] or nil
end

-- Years the books and pages picker offers: those of the recorded reading and
-- those books were finished in.
local function _riGetActivityYears(year_range)
    local first, last = require("modules/module_stats_provider").getFinishedYears()
    return math.min(year_range.min_year, first), math.max(year_range.max_year, last)
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

--- Opens the Reading Insights window.
--- opts: { on_close = function, on_back = function }
function StatsWindows.showReadingInsightsWindow(opts)
    opts = opts or {}
    _lazyLoad()
    local SUIWindow = require("engines/sui_window")

    -- Every opening starts from fresh data: a previous window that never
    -- reached on_close leaves nothing behind.
    _riClearCache()

    -- Pre-flight: load streaks once; they span all years.
    _ri_streaks = _riGetStreaks()

    local year_range = _riGetYearRange()
    -- Start at the most recent year with data.
    local selected_year = year_range.max_year
    -- The year of the books and pages chart, picked apart from the one above.
    local activity_year = selected_year
    local activity_min, activity_max = _riGetActivityYears(year_range)

    -- Pre-load the initial year's data before opening so there is no blank
    -- flash on first render.
    _riGetOrFetchYear(selected_year)

    -- The chart data of the recent weeks (cached by the stats provider), the
    -- same for every year shown.
    local chart_data = _withStatsDb(nil, function(conn)
        return require("modules/module_stats_provider").getChartData(conn)
    end)

    -- -------------------------------------------------------------------
    -- The window uses a single __root__ screen whose content is rebuilt
    -- each time the year or mode changes via ctx.repaint().
    -- State is held in upvalues (selected_year, _ri_mode_key) so it
    -- survives across repaints without needing the nav stack.
    -- -------------------------------------------------------------------
    local win_ref  -- filled after SUIWindow:new so callbacks can call repaint

    local function buildRootScreen(ctx)
        local inner_w = ctx.inner_w
        local SZ      = ctx.SZ
        local entry   = _riGetOrFetchYear(selected_year)
        local yearly  = entry.yearly_stats
        local streaks = _ri_streaks
        local today   = _riGetTodayStats()
        local period  = _riGetPeriodStats()

        -- Tallest content one page holds: the frames and charts size to it.
        local avail_h = ctx.page_h

        local card_w    = Frames.cardWidth(inner_w)
        local content_w = Frames.contentWidth(inner_w, SZ)

        local function timeStr(secs)
            return secs < 60 and "0m" or _riFmtHours(secs)
        end

        local function setYear(year)
            selected_year = year
            _riGetOrFetchYear(year)
            ctx.repaint()
        end

        local function toggleMode()
            _ri_mode_key = (_ri_mode_key == "hours") and "days" or "hours"
            ctx.repaint()
        end

        local recent = InsightsCharts.sections{
            inner_w = content_w, avail_h = avail_h, SZ = SZ, charts = chart_data, fmt_time = _riFmtHours,
        }

        -- Categories flow page by page: Frames.flow packs their children in order.
        local categories = {}
        local function category(title, children)
            categories[#categories + 1] = { title = title, children = children }
        end
        local function tiles(list)
            return Frames.tiles{ w = card_w, SZ = SZ, items = list }
        end
        -- A chart section the data or the width cannot draw is left out.
        local function addChart(children, chart_section)
            if chart_section then
                children[#children + 1] = Frames.card{
                    w = card_w, SZ = SZ, title = chart_section.title, icon = chart_section.icon,
                    content = chart_section.content,
                }
            end
        end

        category(_("Today"), { tiles{
            { icon = "clock", label = _("Total time"), value = timeStr(today.seconds) },
            { icon = "page",  label = _("Pages read"), value = _riFmtCount(today.pages) },
        } })

        for _i, streak_category in ipairs(_riStreakCategories(card_w, SZ, streaks)) do
            category(streak_category.title, streak_category.children)
        end

        local week = {
            tiles{
                { icon = "clock", label = _("Total time"), value = timeStr(period.thisweek.seconds) },
                { icon = "page",  label = _("Pages read"), value = _riFmtCount(period.thisweek.pages) },
            },
            tiles{
                { icon = "clock", label = _("Average per day"), sub = _("Last 7 days"),
                  value = timeStr(period.lastweek.avg_seconds) },
                { icon = "page",  label = _("Pages per day"), sub = _("Last 7 days"),
                  value = _riFmtCount(math.floor(period.lastweek.avg_pages + 0.5)) },
            },
        }
        addChart(week, recent.week)
        category(_("This week"), week)

        local month = { tiles{
            { icon = "clock", label = _("Total time"), value = timeStr(period.month.seconds) },
            { icon = "page",  label = _("Pages read"), value = _riFmtCount(period.month.pages) },
        } }
        addChart(month, recent.month)
        addChart(month, recent.activity)
        category(_("This month"), month)

        local habits = {}
        addChart(habits, recent.hours)
        addChart(habits, recent.weekdays)
        addChart(habits, recent.dayparts)
        if #habits > 0 then category(_("When you read"), habits) end

        category(_("All time"), { tiles{
            { icon = "clock", label = _("Hours read"),     value = _riFmtCount(period.alltime.hours) },
            { icon = "page",  label = _("Pages read"),     value = _riFmtCount(period.alltime.pages) },
            { icon = "book",  label = _("Books finished"), value = _riFmtCount(period.alltime.book_count) },
        } })

        local year_left
        if _ri_mode_key == "hours" then
            year_left = { icon = "clock", label = _("Hours read"), value = timeStr(yearly.duration) }
        else
            year_left = {
                icon = "calendar_select", value = _riFmtCount(yearly.days),
                label = N_("Day read", "Days read", yearly.days),
            }
        end
        year_left.on_tap = toggleMode
        local year = {
            SUIWindow.PeriodDropdown{
                inner_w   = card_w,
                options   = _yearOptions(year_range.min_year, year_range.max_year),
                selected  = selected_year,
                on_select = setYear,
            },
            tiles{
                year_left,
                { icon = "page", label = N_("Page read", "Pages read", yearly.pages), value = _riFmtCount(yearly.pages) },
            },
        }
        local value_key = _ri_mode_key == "hours" and "hours" or "days"
        local months = _riMonthlyChart(content_w, entry.monthly_data, value_key, selected_year, avail_h, SZ)
        if months:getSize().h > 0 then
            year[#year + 1] = Frames.card{
                w = card_w, SZ = SZ, title = _("By month"), icon = "chart", content = months,
            }
        end
        -- The dropdown picks the year of the tiles and the chart: they stay on one page.
        category(_("By year"), { Frames.stack{ SZ = SZ, children = year } })

        -- Its own year dropdown, kept on a page with the card.
        local activity = InsightsCharts.yearActivity{
            inner_w = content_w, avail_h = avail_h, SZ = SZ, activity = _riGetActivity(activity_year),
        }
        category(_("Books and pages"), { Frames.stack{ SZ = SZ, children = {
            SUIWindow.PeriodDropdown{
                inner_w   = card_w,
                options   = _yearOptions(activity_min, activity_max),
                selected  = activity_year,
                on_select = function(year)
                    activity_year = year
                    ctx.repaint()
                end,
            },
            Frames.card{
                w = card_w, SZ = SZ, title = activity.title, icon = activity.icon, content = activity.content,
            },
        } } })

        return Frames.flow{ inner_w = inner_w, SZ = SZ, max_h = avail_h, categories = categories }
    end

    local function titleFn(ctx)
        return _("Reading Insights")
    end

    local win = SUIWindow:new{
        name          = "sui_win_reading_insights",
        icon          = "chart",
        on_back       = opts.on_back,
        title         = titleFn,
        height        = SUIWindow.defaultHeight(),
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens       = {
            __root__ = buildRootScreen,
        },
        on_close = function()
            _riClearCache()
            if opts.on_close then opts.on_close() end
        end,
    }
    win_ref = win
    win:show()
end

-- ===========================================================================
-- showStreakManagerWindow
-- ===========================================================================
-- Opens the Streak Manager window, laid out like Reading Insights (categories
-- of frames, paged by Frames.flow). Page 1 is the "Calendar" category alone: a
-- Sunday-first month calendar badging every day that counts toward the streak
-- (real activity or, in freeze mode, a frozen day). The next pages hold the last
-- days, the day and week streaks and, in freeze mode, the freezes.
-- ===========================================================================

-- Frozen-day badge glyph: nf-fa-snowflake-o (U+F2DC), rendered in place of
-- the streak flame on days covered by a spent freeze rather than real
-- activity, so the two are always visually distinguishable at a glance.
local _SM_STREAK_ICON = SUIStyle.icon("streak")
local _SM_FROZEN_ICON = SUIStyle.icon("freeze")

-- Days shown in the recent-days strip below the calendar.
local SM_RECENT_DAYS = 14

-- Calendar page sizing: the most week rows a month can span, and the
-- smallest day-cell height (before scaling) the grid may be squeezed to.
local CAL_MAX_WEEKS  = 6
local CAL_MIN_CELL_H = 24

-- Day-cell circle fill colours (see _smDayCell): a dark dot for
-- unread/future/filler days, and a light fill for every day that
-- counts toward the streak — whether that's a lone active day (plain
-- circle, no icon) or a day within a run of 2+ (streak-fire or frozen-
-- snowflake icon on the same light circle).

-- ---------------------------------------------------------------------------
-- Data fetchers
-- ---------------------------------------------------------------------------

-- Whether date_str ("YYYY-MM-DD") has real reading activity (reading time
-- recorded). Used by the freeze-spend eligibility check, which needs it
-- regardless of which month the calendar currently has selected.
local function _smGetRealActivityFor(date_str)
    local ledger = _getLedger()
    local entry = ledger and ledger:entry(date_str)
    return entry ~= nil and entry.first_active ~= nil
end

-- Set of "YYYY-MM-DD" → true for real-activity days (reading time recorded) in
-- the given calendar month.
local function _smGetMonthActiveDates(year, month)
    local ledger = _getLedger()
    return ledger and ledger:activeSet(year, month) or {}
end

-- Reading state of each of the last `count` days, oldest first: "read" (real
-- activity), "frozen" (a spent freeze; none when the freeze mechanic is off)
-- or "none".
local function _smRecentDayStates(count)
    local t = os.date("*t")
    local dates = {}
    for i = count - 1, 0, -1 do
        dates[#dates + 1] = os.date("%Y-%m-%d", os.time{ year = t.year, month = t.month, day = t.day - i, hour = 12 })
    end
    local frozen = {}
    for _, d in ipairs(SUIStreak.getFrozenDatesInRange(dates[1], dates[#dates])) do frozen[d] = true end
    local states = {}
    for i, d in ipairs(dates) do
        local active = _smGetMonthActiveDates(tonumber(d:sub(1, 4)), tonumber(d:sub(6, 7)))
        states[i] = active[d] and "read" or (frozen[d] and "frozen" or "none")
    end
    return states
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
        -- With an accent set the unread dot is a faint shade of it, as in the heatmap.
        local accent = require("infra/sui_accent").color()
        if accent then
            return _CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = cell_h },
                Charts.weekDots{ states = { "none" }, size = diameter, gap = 0, color = accent },
            }
        end
        bg = SUIStyle.COLOR.track
    else
        bg = SUIStyle.accent(SUIStyle.COLOR.gray_strong)
        if is_frozen or is_run then
            local icon_char = is_frozen and _SM_FROZEN_ICON or _SM_STREAK_ICON
            local icon_clr  = SUIStyle.accentFg(SUIStyle.COLOR.surface)
            content = UI.makeColoredText{
                text    = icon_char,
                face    = face_icon,
                fgcolor = icon_clr,
            }
        end
    end

    local dot = RoundedFrame:new{
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
--- opts: { on_back = function }
function StatsWindows.showStreakManagerWindow(opts)
    opts = opts or {}
    _lazyLoad()
    local SUIWindow = require("engines/sui_window")

    -- Loaded once per window session. `streaks` (day- and week-streak data) is a
    -- mutable upvalue because using a freeze changes the day streak: the next
    -- repaint must show it.
    local streaks
    local function refreshStreaks()
        streaks = _riGetStreaks()
    end
    _ledger = nil
    refreshStreaks()

    local freeze_mode_on = SUIStreak.isFreezeModeEnabled()

    local now_t = os.date("*t")
    local selected_year  = now_t.year
    local selected_month = now_t.month
    -- Earliest year the month selector offers: the first year with any
    -- recorded reading.
    local first_year = math.min(_riGetYearRange().min_year, now_t.year)

    local function buildRootScreen(ctx)
        local inner_w    = ctx.inner_w
        local SZ         = ctx.SZ
        local CLR_BLACK  = SUIStyle.COLOR.text_primary
        local card_w     = Frames.cardWidth(inner_w)
        local cal_w      = Frames.contentWidth(inner_w, SZ)
        local calendar_title = _("Calendar")

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
            if SUIStreak.spendFreezeForYesterday() then
                refreshStreaks()
                local ScreenEngine = package.loaded["engines/sui_screen_engine"]
                if ScreenEngine then ScreenEngine.refreshAllLiveStats() end
            end
            ctx.repaint()
        end

        -- Tap handler for every OTHER day cell (i.e. not yesterday): the
        -- freeze mechanic can never be spent on an arbitrary past day, so
        -- there's nothing to confirm here — just an InfoMessage explaining
        -- why, so tapping any cell always does *something* instead of
        -- silently nothing.
        local function explainFreezeMechanic()
            UI.Notify.toast(_("Freezes can only cover a single missed day, and only right after an active one. Tap yesterday's cell to use one, when eligible."))
        end

        -- Tap handler for the yesterday cell: shows a confirmation dialog
        -- when a freeze can actually be spent, or an explanatory
        -- InfoMessage otherwise (no freezes banked, or yesterday doesn't
        -- qualify as a gap to bridge) — never silently does nothing.
        local function promptUseFreezeForYesterday()
            if freezes_available <= 0 then
                UI.Notify.toast(_("You don't have any freezes available yet."))
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
                UI.Notify.toast(msg)
                return
            end
            local Dialogs = require("features/dialogs/sui_dialogs")
            Dialogs.confirm{
                text = string.format(_("You have %d freeze(s) available.\nUse one to cover %s?"),
                           freezes_available, _riFmtDate(os.time() - 86400)),
                ok_text     = _("Use freeze"),
                ok_callback = useFreeze,
            }
        end

        -- ── Month calendar ───────────────────────────────────────────────
        -- Page 1 holds the "Calendar" category alone: the month dropdown above
        -- a panel with the grid, sized so the tallest month still fits the page.
        local month_header = SUIWindow.MonthDropdown{
            inner_w   = card_w,
            selected  = { year = selected_year, month = selected_month },
            first     = { year = first_year,    month = 1 },
            last      = { year = now_t.year,    month = now_t.month },
            on_select = function(year, month)
                selected_year, selected_month = year, month
                ctx.repaint()
            end,
        }

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
        for i, name in ipairs(DateNames.weekdayShort()) do
            weekday_row[#weekday_row + 1] = _CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = wd_h },
                TextWidget:new{ text = name, face = face_wd, fgcolor = SUIStyle.COLOR.text_primary, bold = true },
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

        -- Cell height: the natural size, capped so that the tallest month
        -- (CAL_MAX_WEEKS rows) still fits on the calendar page together
        -- with everything above and around the grid. The cap is the same
        -- for every month, so the dots keep one size while browsing; the
        -- window itself still shrinks to the rows the month actually has.
        local panel_pad = 2 * (SUIStyle.BORDER_SZ + SZ(Screen:scaleBySize(12)))
        local calendar_chrome_h = Frames.headerHeight{ SZ = SZ, inner_w = inner_w, title = calendar_title }
            + month_header:getSize().h
            + SZ(Screen:scaleBySize(8))                          -- gap under the dropdown
            + panel_pad                                           -- panel border and padding
            + wd_h + span_full                                    -- weekday row
        local max_cell_h = math.floor((ctx.page_h - calendar_chrome_h
            - (CAL_MAX_WEEKS - 1) * span_full) / CAL_MAX_WEEKS)
        local cell_h = math.max(ctx.SZ(Screen:scaleBySize(CAL_MIN_CELL_H)),
            math.min(math.floor(cell_h_full * CAL_SCALE), max_cell_h))

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

        local calendar = Frames.stack{ SZ = SZ, children = {
            month_header,
            Frames.panel{ w = card_w, SZ = SZ, content = grid_box },
        } }

        -- ── Last days strip ──────────────────────────────────────────────
        -- One dot per day, oldest first: filled for reading, ring for a
        -- frozen day. Left out when the width cannot fit them.
        local function lastDays()
            local d = SZ(Screen:scaleBySize(16))
            local dot_size, dot_gap = Charts.fitDots(SM_RECENT_DAYS, cal_w, d, d)
            if not dot_size then return end
            return {
                title = string.format(_("Last %d days"), SM_RECENT_DAYS),
                children = { Frames.panel{ w = card_w, SZ = SZ, content = _CenterContainer:new{
                    dimen = Geom:new{ w = cal_w, h = dot_size },
                    Charts.weekDots{ states = _smRecentDayStates(SM_RECENT_DAYS), size = dot_size,
                        gap = dot_gap, color = CLR_BLACK },
                } } },
            }
        end

        -- Progress toward the next day-based freeze: streaks.days.current % interval
        -- is exact without the watermark (a streak of 7 with a freeze granted at 5
        -- shows 2/5; one that just hit 10 shows 0/5). Using a freeze happens by
        -- tapping yesterday's cell, so this card only displays the count.
        local function freezes()
            local day_progress = streaks.days.current % SUIStreak.FREEZE_DAY_INTERVAL
            local time_min = math.floor(SUIStreak.getFreezeTimeProgress() / 60)
            local time_target_min = math.floor(SUIStreak.FREEZE_TIME_THRESHOLD_SECS / 60)
            return {
                title = _("Freezes"),
                children = { Frames.rows{ w = card_w, SZ = SZ, items = { {
                    icon  = "freeze",
                    label = N_("Freeze available", "Freezes available", freezes_available),
                    sub   = string.format(_("%d/%d days · %d/%d min to next freeze"),
                        day_progress, SUIStreak.FREEZE_DAY_INTERVAL, time_min, time_target_min),
                    value = tostring(freezes_available),
                } } } },
            }
        end

        -- Everything after the calendar should share page 2: try the full layout,
        -- then without the last days; the last attempt stands even if it still
        -- overflows. The streaks stay as rows, like in Reading Insights.
        local function restBlocks(with_last_days)
            local categories = {}
            local last_days = with_last_days and lastDays()
            if last_days then categories[#categories + 1] = last_days end
            for _i, streak_category in ipairs(_riStreakCategories(card_w, SZ, streaks)) do
                categories[#categories + 1] = streak_category
            end
            if freeze_mode_on then categories[#categories + 1] = freezes() end
            return Frames.flow{ inner_w = inner_w, SZ = SZ, max_h = ctx.page_h, categories = categories }
        end
        local function onOnePage(blocks)
            for i = 2, #blocks do
                if blocks[i].force_new_page then return false end
            end
            return true
        end
        local rest = restBlocks(true)
        if not onOnePage(rest) then rest = restBlocks(false) end

        -- Page 1 is the calendar alone: the rest starts a new page whatever room is left.
        local pages = Frames.flow{ inner_w = inner_w, SZ = SZ, max_h = ctx.page_h,
            categories = { { title = calendar_title, children = { calendar } } } }
        rest[1].force_new_page = true
        for _i, block in ipairs(rest) do pages[#pages + 1] = block end
        return pages
    end

    local win = SUIWindow:new{
        name          = "sui_win_streak_manager",
        icon          = "streak",
        on_back       = opts.on_back,
        title         = function() return _("Streak") end,
        height        = SUIWindow.defaultHeight(),
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens       = {
            __root__ = buildRootScreen,
        },
        on_close = function()
            _ledger = nil
        end,
    }
    win:show()
end


-- Opens a standalone SUIWindow showing the per-book statistics screen for the
-- book at opts.filepath. This is the same "book_stats" screen rendered inside
-- showFinishedBooksDialog, but surfaced directly from the library long-press
-- dialog without requiring the user to navigate through the history list.
-- opts: { filepath = string, on_back = function }
-- ===========================================================================
function StatsWindows.showBookStatsFromFile(opts)
    opts = opts or {}
    local filepath = opts.filepath
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
        UI.Notify.toast(err or _("No statistics found for this book."))
        return
    end

    local SUIWindow = require("engines/sui_window")

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

        local CLR_BORDER = SUIStyle.COLOR.gray
        local CLR_BLACK  = SUIStyle.COLOR.text_primary
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
            return RoundedFrame:new{
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
                    UI.makeAccentText({ text = icon_glyph, face = icon_face }, CLR_BLACK),
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
                        UI.makeAccentText({ text = icon_glyph, face = icon_face }, CLR_BLACK),
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

        local rows_block = RoundedFrame:new{
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
        icon     = "chart",
        on_back  = opts.on_back,
        title    = _("Book Statistics"),
        -- Matches the Settings window's height (SUIWindow's own default,
        -- 23/30 of portrait height), same as the other stats windows.
        height   = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position = "bottom",
        navpager_mode = require("infra/sui_config").isNavpagerEnabled(),
        screens  = { __root__ = buildStatsScreen },
    }
    win:show()
end

return StatsWindows
