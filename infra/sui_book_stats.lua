-- sui_book_stats.lua — Simple UI
-- Per-book reading statistics read from the statistics database.
--
-- PUBLIC API
--   BookStats.fetch(md5, shared_conn, ctx, force) → { days, total_secs, avg_time } | nil
--       days        distinct days the book was read
--       total_secs  total reading time
--       avg_time    average seconds per page (nil when unknown)
--       Cached by md5; `force` skips the cache. A `shared_conn` is reused
--       instead of opening a connection; when it fails with a fatal error,
--       ctx.db_conn_fatal is set so the owner can discard it.
--   BookStats.invalidate(md5)
--       Drops the cached entry of one book, or every entry when md5 is nil.
--   BookStats.formatDuration(secs) → "Xh Ym" | "Xh" | "Ym"
--   BookStats.secondsLeft(stats, data) → seconds left in the book | nil
--       `stats` is a fetch() result, `data` the book's sidecar data
--       ({ percent, pages, avg_time }). Prefers the capped average from `stats`.
--
-- STATISTICS TEXT
--   Every surface that shows book statistics builds its text here, so the
--   wording is the same everywhere.
--   BookStats.STAT_IDS            statistic ids, in default order
--   BookStats.statLabel(id)       menu label of a statistic
--   BookStats.text.<kind>(...)    short display text: page, percent, days,
--                                 read, left
--   BookStats.textFor(id, stats, data) → text | nil
--   BookStats.line(order, is_visible, text_of) → the visible statistics of
--       `order` joined into one line ("" when none has anything to show)

local logger = require("logger")
local Config = require("infra/sui_config")
local I18n   = require("infra/sui_i18n")
local _      = I18n.translate
local N_     = I18n.ngettext
local Text   = require("infra/sui_text")

local BookStats = {}

local MAX_SEC_PER_PAGE = 120  -- matches KOReader statistics query cap
local CACHE_MAX        = 20   -- md5 entries kept in the cache

-- LRU cache: the entry with the oldest `tick` is evicted when full.
local entries, count, tick = {}, 0, 0

local function touch(entry)
    tick = tick + 1
    entry.tick = tick
end

local function cacheGet(md5)
    local entry = entries[md5]
    if not entry then return nil end
    touch(entry)
    return entry.value
end

local function cacheRemove(md5)
    if entries[md5] then
        entries[md5] = nil
        count = count - 1
    end
end

local function cachePut(md5, value)
    if not entries[md5] then
        if count >= CACHE_MAX then
            local oldest_md5, oldest_tick
            for key, entry in pairs(entries) do
                if not oldest_tick or entry.tick < oldest_tick then
                    oldest_md5, oldest_tick = key, entry.tick
                end
            end
            cacheRemove(oldest_md5)
        end
        entries[md5] = {}
        count = count + 1
    end
    entries[md5].value = value
    touch(entries[md5])
end

function BookStats.fetch(md5, shared_conn, ctx, force)
    if not md5 then return nil end
    if not force then
        local cached = cacheGet(md5)
        if cached then return cached end
    end

    local conn = shared_conn or Config.openStatsDB()
    if not conn then return nil end

    local result
    local ok, err = pcall(function()
        -- ps_agg accumulates per-page totals; the outer SELECT aggregates them.
        -- Relies on idx_simpleui_book_md5 (created by openStatsDB()) for the
        -- md5 lookup and on page_stat_data's (id_book, page, start_time) index
        -- for the per-book scan.
        local row = conn:exec(string.format([[
            WITH b AS (
                %s
            ),
            ps_agg AS (
                SELECT ps.page,
                       sum(ps.duration)   AS page_dur,
                       min(ps.start_time) AS first_start
                FROM page_stat ps
                WHERE ps.id_book = (SELECT id FROM b)
                GROUP BY ps.page
            )
            SELECT
                count(DISTINCT date(first_start, 'unixepoch', 'localtime')),
                sum(page_dur),
                count(*),
                sum(min(page_dur, %d))
            FROM ps_agg;
        ]], string.format(Config.BOOK_ID_BY_MD5_SQL, md5), MAX_SEC_PER_PAGE))

        if row and row[1] and row[1][1] then
            local pages  = tonumber(row[3] and row[3][1]) or 0
            local capped = tonumber(row[4] and row[4][1]) or 0
            result = {
                days       = tonumber(row[1][1]) or 0,
                total_secs = tonumber(row[2] and row[2][1]) or 0,
                avg_time   = (pages > 0 and capped > 0) and (capped / pages) or nil,
            }
        end
    end)

    if not ok then
        logger.warn("simpleui/book_stats: fetch failed: " .. tostring(err))
        if shared_conn and ctx and Config.isFatalDbError(err) then
            ctx.db_conn_fatal = true
        end
    end
    if not shared_conn then pcall(function() conn:close() end) end
    if result then cachePut(md5, result) end
    return result
end

function BookStats.invalidate(md5)
    if md5 then
        cacheRemove(md5)
    else
        entries, count = {}, 0
    end
end

function BookStats.secondsLeft(stats, data)
    local avg_time = stats and stats.avg_time
    if not (avg_time and avg_time > 0) then avg_time = data and data.avg_time end
    if not (avg_time and avg_time > 0 and data and data.pages and data.pages > 0) then
        return nil
    end
    local secs = math.floor(avg_time * data.pages * (1 - (data.percent or 0)))
    return secs > 0 and secs or nil
end

function BookStats.formatDuration(secs)
    return Text.formatDuration(secs)
end

-- ---------------------------------------------------------------------------
-- Statistics text
-- ---------------------------------------------------------------------------

BookStats.STAT_IDS = { "page", "percent", "book_days", "book_time", "book_remaining" }
BookStats.SEPARATOR = " · "

local STAT_LABELS = {
    page           = function() return _("Page") end,
    percent        = function() return _("Percentage read") end,
    book_days      = function() return _("Days of reading") end,
    book_time      = function() return _("Time read") end,
    book_remaining = function() return _("Time remaining") end,
}

function BookStats.statLabel(id)
    return STAT_LABELS[id]()
end

-- Short display texts. Durations are passed already formatted.
BookStats.text = {
    page    = function(page, pages) return string.format(_("Page %s/%s"), page, pages) end,
    percent = function(fraction) return string.format("%d%%", math.floor(fraction * 100 + 0.5)) end,
    days    = function(days) return string.format(N_("%d day", "%d days", days), days) end,
    read    = function(duration) return string.format(_("%s read"), duration) end,
    left    = function(duration) return string.format(_("%s left"), duration) end,
}

function BookStats.textFor(id, stats, data)
    local text = BookStats.text
    if id == "percent" then
        return data and text.percent(data.percent or 0) or nil
    elseif id == "book_days" then
        return stats and stats.days > 0 and text.days(stats.days) or nil
    elseif id == "book_time" then
        return stats and stats.total_secs > 0 and text.read(BookStats.formatDuration(stats.total_secs)) or nil
    elseif id == "book_remaining" then
        local secs = BookStats.secondsLeft(stats, data)
        return secs and text.left(BookStats.formatDuration(secs)) or nil
    end
end

function BookStats.line(order, is_visible, text_of)
    local parts = {}
    for _i, id in ipairs(order) do
        local text = is_visible(id) and text_of(id)
        if text then parts[#parts + 1] = text end
    end
    return table.concat(parts, BookStats.SEPARATOR)
end

return BookStats
