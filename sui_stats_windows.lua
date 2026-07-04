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
    local function modifiedInYear(summary)
        local mod = summary and summary.modified
        if mod == nil then return false end
        if type(mod) == "number" then
            local t = os.date("*t", mod)
            return t and tostring(t.year) == year_str
        end
        if type(mod) == "string" then
            return #mod >= 4 and mod:sub(1, 4) == year_str
        end
        if type(mod) == "table" and mod.year then
            return tostring(mod.year) == year_str
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
                    date_finished = (type(summary.modified)    == "string" and summary.modified)    or nil,
                    date_started  = (type(summary.date_started) == "string" and summary.date_started) or nil,
                    md5           = md5_checksum,
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
local function _makeDateCard(inner_w, PAD_H,
                             date_start_str, date_end_str,
                             original_start_str, original_end_str,
                             filepath,
                             on_start_saved, on_end_saved)
    local face_date  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local face_arrow = Font:getFace(SUIStyle.FACE_ICONS,   SUIStyle.FS_BODY)
    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local ARROW      = SUIStyle.icon("arrow_right")
    local date_inner = inner_w - 2 * PAD_H
    local date_third = math.floor(date_inner / 3)
    local date_row_h = Screen:scaleBySize(24)

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
        function(fp) _deleteSummaryField(fp, "modified") end,
        original_end_str,
        on_end_saved)

    return FrameContainer:new{
        bordersize     = 0,
        radius         = Screen:scaleBySize(12),
        background     = Blitbuffer.gray(0.08),
        padding_top    = Screen:scaleBySize(14),
        padding_bottom = Screen:scaleBySize(14),
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

    local face_stat_title  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
    local face_stat_author = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local face_cell_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
    local face_cell_val    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
    local CLR_BLACK = Blitbuffer.COLOR_BLACK

    local _cell_geo
    local function _buildCellGeo(inner_w)
        if _cell_geo and _cell_geo.inner_w == inner_w then return _cell_geo end
        local sep_w      = SUIStyle.BORDER_SZ
        local cell_w     = math.floor((inner_w - 2 * sep_w) / 3)
        local cell_v_pad = Screen:scaleBySize(16)
        local lbl_h      = math.floor(face_cell_lbl.size * 2.2)
        local val_h      = face_cell_val.size + Screen:scaleBySize(2)
        local cell_h     = cell_v_pad * 2 + val_h + Screen:scaleBySize(2) + lbl_h
        local row_gap    = Screen:scaleBySize(4)
        local header_v   = Screen:scaleBySize(14)
        local header_bot = Screen:scaleBySize(20)
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
            rows[#rows + 1] = SUIWindow.ListRow{
                inner_w      = inner_w,
                title        = book.title,
                subtitle     = (book.authors and book.authors ~= "") and book.authors or nil,
                right_value  = date_range,
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
        local ICON_FS    = SUIStyle.FS_BODY
        local ROW_H      = Screen:scaleBySize(52)

        -- ── 1. Top card: title/author + 3-col metrics ──

        local fp = book and book.filepath

        local meta_w      = inner_w
        local text_max_w  = inner_w - 2 * PAD_H
        local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
        local face_author = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local face_val    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
        local face_lbl    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)

        -- 3-col metrics — widths derived from the right meta column
        local card_gap = Screen:scaleBySize(10)
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
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{
                    text      = label,
                    face      = face_lbl,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
            }

            return FrameContainer:new{
            bordersize     = SUIStyle.BORDER_SZ, color = CLR_BORDER,
                radius         = Screen:scaleBySize(12),
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
            VerticalSpan:new{ width = Screen:scaleBySize(24) },
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
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            TextWidget:new{
                text      = d.authors or "",
                face      = face_author,
                fgcolor   = CLR_BLACK,
                max_width = text_max_w,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
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
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
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
        local lbl_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local val_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local ICON_W     = Screen:scaleBySize(36)
        local row_inner  = inner_w - 2 * PAD_H

        local function makeIconRow(icon_glyph, label, value_str, on_tap)
            local val_w = Screen:scaleBySize(160)
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

        local rows_block = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ,
            color      = CLR_BORDER,
            radius     = Screen:scaleBySize(12),
            padding    = 0,
            VerticalGroup:new{
                align = "left",
                makeIconRow(SUIStyle.icon("clock"),                _("Average per day"),  _fmtDuration(d.avg_time_per_day)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("page"),                 _("Average per page"), _fmtDuration(d.avg_time_per_page)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("highlights"), _("Highlights"),     tostring(d.highlights), on_tap_highlights),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("notes"),      _("Notes"),          tostring(d.notes),      on_tap_notes),
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
            end
        )

        local block_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }

        return {
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            top_card,
            block_gap,
            rows_block,
            block_gap,
            date_widget,
        }
    end

    local function titleFn(ctx)
        return string.format(
            N_("%d book read in %s", "%d books read in %s", #books),
            #books, year_str)
    end

    local win = SUIWindow:new{
        name           = "sui_win_reading_history",
        title          = titleFn,
        height         = math.floor(Screen:getHeight() * 0.75),
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
    "Jan","Feb","Mar","Apr","May","Jun",
    "Jul","Aug","Sep","Oct","Nov","Dec",
}
local _MONTH_FULL = {
    "January","February","March","April","May","June",
    "July","August","September","October","November","December",
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
        local dates = {}
        _withStmt(conn, [[
            SELECT date(start_time, 'unixepoch', 'localtime') AS d,
                   min(start_time)
            FROM page_stat GROUP BY d ORDER BY d DESC
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



local function _riYearHeader(inner_w, year, year_range, on_prev, on_next)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
    local face_chev = Font:getFace(SUIStyle.FACE_ICONS, math.floor(SUIStyle.FS_TITLE * 1.8))
    local CLR_BLACK = Blitbuffer.COLOR_BLACK

    local prev_enabled = year > year_range.min_year
    local next_enabled = year < year_range.max_year

    local gap = Screen:scaleBySize(16)
    local btn_w = Screen:scaleBySize(60)

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
local function _riYearlyRow(inner_w, yearly_stats, mode_key, on_toggle_mode, avail_h)
    local CLR_BLACK = Blitbuffer.COLOR_BLACK
    local face_val  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
    local face_lbl  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)

    local sep_w  = SUIStyle.BORDER_SZ
    local col_w  = math.floor((inner_w - sep_w) / 2)
    local cell_h = math.max(Screen:scaleBySize(48),
                       math.min(Screen:scaleBySize(90),
                           math.floor(avail_h * 0.12)))

    local function makeCell(val_str, lbl_str, on_tap)
        local content = VerticalGroup:new{ align = "center",
            TextWidget:new{ text = val_str, face = face_val,
                            fgcolor = CLR_BLACK, bold = true },
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
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
            dimen      = Geom:new{ w = sep_w, h = cell_h - Screen:scaleBySize(24) },
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



local function _riMonthlyChart(inner_w, monthly_data, value_key, selected_year, avail_h)
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
    local bar_h    = math.max(Screen:scaleBySize(20),
                        math.min(Screen:scaleBySize(60),
                            math.floor(avail_h * 0.12)))
    local bar_w    = math.floor(chart_w / 6) - Screen:scaleBySize(8)
    local bar_gap  = math.floor((chart_w - bar_w * 6) / 5)
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION - 2)
    local lbl_h    = face_lbl.size + Screen:scaleBySize(2)

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
                dimen      = Geom:new{ w = bar_w, h = Screen:scaleBySize(2) },
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
            VerticalSpan:new{ width = Screen:scaleBySize(2) },
            lbls,
        }
    end

    local chart = VerticalGroup:new{ align = "center" }
    -- Row 1: Jan–Jun (indices 1–6), Row 2: Jul–Dec (indices 7–12)
    local row1, row2 = {}, {}
    for i = 1,  6 do table.insert(row1, monthly_data[i]) end
    for i = 7, 12 do table.insert(row2, monthly_data[i]) end
    table.insert(chart, makeBarRow(row1))
    table.insert(chart, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    table.insert(chart, makeBarRow(row2))
    return chart
end

-- ---------------------------------------------------------------------------
-- Page 2 — "Today, Last Week & All-Time" deep-stats screen
-- ---------------------------------------------------------------------------

local function _buildInsightsPage2(inner_w, avail_h, streaks)
    _lazyLoad()      -- ensure _CenterContainer, _LeftContainer, etc. are loaded
    local Size    = require("ui/size")
    local sec_gap = math.max(Screen:scaleBySize(6), math.floor(avail_h * 0.025))

    local CLR_BLACK  = Blitbuffer.COLOR_BLACK
    local CLR_BORDER = Blitbuffer.gray(0.72)

    local face_val  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
    local face_lbl  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
    local face_sub  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)

    local lastweek = _riGetLastWeekStats()
    local thisweek_stats = _riGetThisWeekStats()
    local month_stats = _riGetThisMonthStats()
    local alltime  = _riGetAllTimeStats()

    local face_c3_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
    local face_c3_val = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)

    local col_gap3    = Screen:scaleBySize(8)
    local cell_w3     = math.floor((inner_w - 2 * col_gap3) / 3)
    local cell_vpad3  = Screen:scaleBySize(16)
    local icon_h3     = Screen:scaleBySize(26)
    local lbl_h3      = face_c3_lbl.size + Screen:scaleBySize(2)
    local val_h3      = face_c3_val.size + Screen:scaleBySize(2)
    local cell_h3     = cell_vpad3 * 2 + icon_h3 + Screen:scaleBySize(6) + val_h3 + Screen:scaleBySize(2) + lbl_h3

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
                        face      = Font:getFace(SUIStyle.FACE_ICONS, SUIStyle.FS_TITLE),
                        fgcolor   = CLR_BLACK,
                        width     = cell_w3,
                        alignment = "center",
                    },
                },
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
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
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
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
                LineWidget:new{ dimen = Geom:new{ w = sep_w, h = cell_h3 - Screen:scaleBySize(32) }, background = CLR_BORDER }
            },
            _CenterContainer:new{ dimen = Geom:new{ w = cw, h = cell_h3 }, c2 },
            _CenterContainer:new{
                dimen = Geom:new{ w = sep_w, h = cell_h3 },
                LineWidget:new{ dimen = Geom:new{ w = sep_w, h = cell_h3 - Screen:scaleBySize(32) }, background = CLR_BORDER }
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
        radius     = Screen:scaleBySize(12),
        padding    = 0, margin = 0,
        alltime_row,
    }

    local avg_secs      = lastweek.avg_seconds
    local avg_time_str  = _riFmtHours(avg_secs)
    if avg_secs < 60 then avg_time_str = "0m" end
    local avg_pages_val = math.floor(lastweek.avg_pages + 0.5)
    local avg_pages_str = _riFmtCount(avg_pages_val)

    local face_icon_row = Font:getFace(SUIStyle.FACE_ICONS, SUIStyle.FS_BODY)
    local face_lbl_row  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local face_val_row  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local ROW_H         = Screen:scaleBySize(52)
    local PAD_H         = Size.padding.large
    local ICON_W        = Screen:scaleBySize(36)
    local row_inner     = inner_w - 2 * PAD_H

    local function makeIconRow(icon_glyph, label, value_str, sub_label)
        local val_w = Screen:scaleBySize(160)
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
        radius     = Screen:scaleBySize(12),
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
        radius     = Screen:scaleBySize(12),
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
        radius     = Screen:scaleBySize(12),
        padding    = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("clock"), _("Total time"), month_time_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("page"), _("Pages read"), month_pages_str),
        },
    }

    local cur_streak_val = streaks.days.current
    local cur_streak_str = string.format(N_("%d day", "%d days", cur_streak_val), cur_streak_val)

    local best_streak_val = streaks.days.best
    local best_streak_str = string.format(N_("%d day", "%d days", best_streak_val), best_streak_val)
    local best_dates = nil
    if best_streak_val > 1 and streaks.days.best_start > 0 then
        best_dates = _riFmtDate(streaks.days.best_start) .. " \xe2\x80\x93 " .. _riFmtDate(streaks.days.best_end)
    end

    local streak_row = FrameContainer:new{
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = Screen:scaleBySize(12),
        padding    = 0, margin = 0,
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
        bordersize = SUIStyle.BORDER_SZ,
        color      = CLR_BORDER,
        radius     = Screen:scaleBySize(12),
        padding    = 0, margin = 0,
        VerticalGroup:new{
            align = "left",
            makeIconRow(SUIStyle.icon("calendar"), _("Current streak"), cur_wstreak_str),
            makeRowSep(),
            makeIconRow(SUIStyle.icon("trophy"), _("Best streak"), best_wstreak_str, best_w_dates),
        },
    }

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
        local modal_h    = math.floor(Screen:getHeight() * 0.75)
        local border     = Size.border.window
        local pad_v      = Size.padding.large
        local title_h    = Screen:scaleBySize(50)  -- conservative TitleBar estimate
        local dot_h      = Screen:scaleBySize(28) + Screen:scaleBySize(18)
        local avail_h    = modal_h - 2 * border - pad_v - title_h - dot_h

        -- Spacing between sections: 2% of avail_h, min 6px.
        local sec_gap = math.max(Screen:scaleBySize(6), math.floor(avail_h * 0.02))

        local CLR_BLACK  = Blitbuffer.COLOR_BLACK
        local CLR_BORDER = Blitbuffer.gray(0.72)

        local face_sec    = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)

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

        local today_gap = Screen:scaleBySize(12)
        local today_card_w = math.floor((inner_w - today_gap) / 2)
        local cell_h2 = math.max(Screen:scaleBySize(70), math.min(Screen:scaleBySize(110), math.floor(avail_h * 0.16)))
        local today_card_h = cell_h2 + Screen:scaleBySize(24)

        local function makeTodayCard(icon_char, value, label)
            local face_today_val = Font:getFace(SUIStyle.FACE_REGULAR, math.floor(SUIStyle.FS_TITLE * 1.6))
            local face_lbl       = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)

            local icon_w = TextWidget:new{
                text    = icon_char,
                face    = Font:getFace(SUIStyle.FACE_ICONS, math.floor(SUIStyle.FS_TITLE * 1.6)),
                fgcolor = CLR_BLACK,
            }

            local text_vg = VerticalGroup:new{ align = "left",
                TextWidget:new{
                    text    = value,
                    face    = face_today_val,
                    fgcolor = CLR_BLACK,
                    bold    = true,
                },
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{
                    text    = label,
                    face    = face_lbl,
                    fgcolor = CLR_BLACK,
                }
            }

            local hg = HorizontalGroup:new{ align = "center",
                icon_w,
                HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                text_vg
            }

            return FrameContainer:new{
                bordersize = SUIStyle.BORDER_SZ,
                color      = CLR_BORDER,
                radius     = Screen:scaleBySize(12),
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
                                          year_range, goPrev, goNext)

        local function toggleMode()
            _ri_mode_key = (_ri_mode_key == "hours") and "days" or "hours"
            ctx.repaint()
        end

        local yearly_row = _riYearlyRow(inner_w, yearly, _ri_mode_key, toggleMode, avail_h)

        -- ── Section 3: monthly chart ──────────────────────────────────
        local value_key = _ri_mode_key == "hours" and "hours" or "days"
        local chart     = _riMonthlyChart(inner_w, monthly, value_key, selected_year, avail_h)

        -- ── Assemble into a single VerticalGroup ─────────────────────────
        -- Returning one widget prevents SUIWindow._buildPages from splitting
        -- the content across multiple pages.
        local alltime_block, week_row, thisweek_row, month_row, streak_row, wstreak_row = _buildInsightsPage2(inner_w, avail_h, streaks)

        local all1 = VerticalGroup:new{ align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(16) },
            sectionLabel(_("TODAY'S SUMMARY")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            today_row,
            VerticalSpan:new{ width = sec_gap },
            sectionLabel(_("DAY STREAK")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            streak_row,
            VerticalSpan:new{ width = sec_gap },
            sectionLabel(_("WEEK STREAK")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            wstreak_row,
            VerticalSpan:new{ width = sec_gap },
        }
        
        local all2 = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
            sectionLabel(_("LAST 7 DAYS")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            week_row,
            VerticalSpan:new{ width = sec_gap },
            sectionLabel(_("THIS WEEK")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            thisweek_row,
            VerticalSpan:new{ width = sec_gap },
            sectionLabel(_("THIS MONTH")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            month_row,
            VerticalSpan:new{ width = sec_gap },
        }

        local all3 = VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
            sectionLabel(_("ALL TIME")),
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            alltime_block,
            VerticalSpan:new{ width = sec_gap + Screen:scaleBySize(24) },
            year_header,
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            yearly_row,
            VerticalSpan:new{ width = sec_gap + Screen:scaleBySize(16) },
            chart,
            VerticalSpan:new{ width = sec_gap },
        }

        local page1 = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ w = inner_w, h = avail_h },
            all1,
        }
        local page2 = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ w = inner_w, h = avail_h },
            all2,
        }
        local page3 = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ w = inner_w, h = avail_h },
            all3,
        }
        return { page1, page2, page3 }
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
        height        = math.floor(Screen:getHeight() * 0.75),
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
-- showBookStatsFromFile
-- ===========================================================================
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
            -- Read date_finished (summary.modified) and date_started so the
            -- date card shows the user-visible dates rather than raw DB timestamps.
            local summary = ds:readSetting("summary")
            if type(summary) == "table" then
                if summary.status == "complete" and type(summary.modified) == "string" then
                    book.date_finished = summary.modified
                end
                if type(summary.date_started) == "string" then
                    book.date_started = summary.date_started
                end
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
        local ICON_FS    = SUIStyle.FS_BODY
        local ROW_H      = Screen:scaleBySize(52)

        -- ── cell geometry (3-col top metrics) ──────────────────────────
        local sep_w      = SUIStyle.BORDER_SZ
        local col_w      = math.floor((inner_w - 2 * (Screen:scaleBySize(10))) / 3)
        local cell_v_pad = Screen:scaleBySize(16)
        local face_val   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE)
        local face_lbl   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
        local lbl_h      = math.floor(face_lbl.size * 2.2)
        local val_h      = face_val.size + Screen:scaleBySize(2)
        local cell_h     = cell_v_pad * 2 + val_h + Screen:scaleBySize(2) + lbl_h
        local card_gap   = Screen:scaleBySize(10)
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
                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                TextWidget:new{
                    text      = label,
                    face      = face_lbl,
                    fgcolor   = CLR_BLACK,
                    alignment = "center",
                },
            }
            return FrameContainer:new{
                bordersize = SUIStyle.BORDER_SZ, color = CLR_BORDER,
                radius     = Screen:scaleBySize(12),
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

        local face_title  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_SUBTITLE)
        local face_author = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)

        local title_author_group = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Screen:scaleBySize(24) },
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
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            TextWidget:new{
                text      = d.authors or "",
                face      = face_author,
                fgcolor   = CLR_BLACK,
                max_width = text_max_w,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
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
                VerticalSpan:new{ width = Screen:scaleBySize(16) },
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
        local lbl_face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local val_face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
        local ICON_W    = Screen:scaleBySize(36)
        local row_inner = inner_w - 2 * PAD_H

        local function makeIconRow(icon_glyph, label, value_str, on_tap)
            local val_w = Screen:scaleBySize(160)
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

        local rows_block = FrameContainer:new{
            bordersize = SUIStyle.BORDER_SZ,
            color      = CLR_BORDER,
            radius     = Screen:scaleBySize(12),
            padding    = 0,
            VerticalGroup:new{
                align = "left",
                makeIconRow(SUIStyle.icon("clock"),      _("Average per day"),  _fmtDuration(d.avg_time_per_day)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("page"),       _("Average per page"), _fmtDuration(d.avg_time_per_page)),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("highlights"), _("Highlights"),       tostring(d.highlights), on_tap_highlights),
                makeRowSep(),
                makeIconRow(SUIStyle.icon("notes"),      _("Notes"),            tostring(d.notes),      on_tap_notes),
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
            end
        )

        local block_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }
        return {
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
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
        height   = math.floor(Screen:getHeight() * 0.75),
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