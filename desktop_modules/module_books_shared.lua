-- module_books_shared.lua — Simple UI
-- Helpers partilhados pelos módulos Currently Reading e Recent Books:
-- cover loading, book data, progress bar, prefetch, formatTimeLeft.
-- Não é um módulo — não tem id nem build(). Apenas utilitários partilhados.

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Font        = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom        = require("ui/geometry")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen      = Device.screen
local lfs         = require("libs/libkoreader-lfs")
local Config      = require("sui_config")

local SH = {}

-- ---------------------------------------------------------------------------
-- Base dimensions — computed once at load time from device DPI.
-- These are the 100%-scale reference values; never modify them at runtime.
-- ---------------------------------------------------------------------------
local _BASE_COVER_W  = Screen:scaleBySize(122)
local _BASE_COVER_H  = Screen:scaleBySize(184)
local _BASE_RECENT_W = Screen:scaleBySize(75)
local _BASE_RECENT_H = Screen:scaleBySize(112)
local _BASE_RB_GAP1    = Screen:scaleBySize(4)
local _BASE_RB_BAR_H   = Screen:scaleBySize(5)
local _BASE_RB_GAP2    = Screen:scaleBySize(3)
local _BASE_RB_LABEL_H = Screen:scaleBySize(14)

-- Flat aliases kept for any call-site that reads SH.COVER_W etc. directly
-- without going through getDims(). These always reflect 100% scale and are
-- present only for backward-compat — new code should use getDims().
SH.COVER_W       = _BASE_COVER_W
SH.COVER_H       = _BASE_COVER_H
SH.RECENT_W      = _BASE_RECENT_W
SH.RECENT_H      = _BASE_RECENT_H
SH.RB_GAP1       = _BASE_RB_GAP1
SH.RB_BAR_H      = _BASE_RB_BAR_H
SH.RB_GAP2       = _BASE_RB_GAP2
SH.RECENT_CELL_H = _BASE_RECENT_H + _BASE_RB_GAP1 + _BASE_RB_BAR_H
                   + _BASE_RB_GAP2 + _BASE_RB_LABEL_H

-- ---------------------------------------------------------------------------
-- getDims(scale) — returns a table of scaled dimensions for one render pass.
-- Called at the top of build() / getHeight() in module_currently and
-- module_recent.  Keeps all math in one place; modules stay declarative.
--
-- scale: float from Config.getModuleScale() — e.g. 0.75, 1.0, 1.25.
-- Returns a plain table (no metatable overhead); keys mirror SH flat names.
-- ---------------------------------------------------------------------------
-- getDims(scale, thumb_scale)
-- scale:       overall module scale (affects everything)
-- thumb_scale: independent cover/thumbnail scale multiplier (affects cover dims only).
--              Text, progress bar and gaps follow only `scale`.
--              Pass nil or 1.0 to apply no thumb adjustment.
function SH.getDims(scale, thumb_scale)
    scale       = scale       or 1.0
    thumb_scale = thumb_scale or 1.0
    -- Combined scale applied to cover dimensions only.
    local cs = scale * thumb_scale
    if scale == 1.0 and thumb_scale == 1.0 then
        -- Fast path: return the pre-computed base values without any math.
        return {
            COVER_W       = _BASE_COVER_W,
            COVER_H       = _BASE_COVER_H,
            RECENT_W      = _BASE_RECENT_W,
            RECENT_H      = _BASE_RECENT_H,
            RB_GAP1       = _BASE_RB_GAP1,
            RB_BAR_H      = _BASE_RB_BAR_H,
            RB_GAP2       = _BASE_RB_GAP2,
            RB_LABEL_H    = _BASE_RB_LABEL_H,
            RECENT_CELL_H = SH.RECENT_CELL_H,
        }
    end
    -- Text/bar/gap dims scale with `scale` only — unaffected by thumb_scale.
    local g1  = math.max(1, math.floor(_BASE_RB_GAP1    * scale))
    local bh  = math.max(1, math.floor(_BASE_RB_BAR_H   * scale))
    local g2  = math.max(1, math.floor(_BASE_RB_GAP2    * scale))
    local lh  = math.max(1, math.floor(_BASE_RB_LABEL_H * scale))
    -- Cover dims scale with the combined scale (scale × thumb_scale).
    local rh  = math.floor(_BASE_RECENT_H * cs)
    -- RECENT_CELL_H = cover height + bar + gaps + label — each part scaled independently.
    return {
        COVER_W       = math.floor(_BASE_COVER_W  * cs),
        COVER_H       = math.floor(_BASE_COVER_H  * cs),
        RECENT_W      = math.floor(_BASE_RECENT_W * cs),
        RECENT_H      = rh,
        RB_GAP1       = g1,
        RB_BAR_H      = bh,
        RB_GAP2       = g2,
        RB_LABEL_H    = lh,
        RECENT_CELL_H = rh + g1 + bh + g2 + lh,
    }
end

local _CLR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)
local _CLR_BAR_BG       = Blitbuffer.gray(0.15)
local _CLR_BAR_FG       = Blitbuffer.gray(0.75)

-- ---------------------------------------------------------------------------
-- vspan pool helper
-- ---------------------------------------------------------------------------
function SH.vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

-- ---------------------------------------------------------------------------
-- progressBar
-- ---------------------------------------------------------------------------
function SH.progressBar(w, pct, bh)
    bh = bh or Screen:scaleBySize(4)
    local fw = math.max(0, math.floor(w * math.min(pct or 0, 1.0)))
    local LineWidget = require("ui/widget/linewidget")
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bh }, background = _CLR_BAR_BG }
    end
    local OverlapGroup = require("ui/widget/overlapgroup")
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bh }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bh }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- coverPlaceholder
-- ---------------------------------------------------------------------------
-- Helper function to safely extract first n UTF-8 characters for placeholder text
local function safeFirstChars(s, n)
    if not s or n <= 0 then return "" end
    local chars = {}
    local i = 1
    local count = 0
    while i <= #s and count < n do
        local byte = s:byte(i)
        -- Calculate the byte length of the current UTF-8 character
        local charLen = 1
        if byte >= 240 then
            charLen = 4
        elseif byte >= 224 then
            charLen = 3
        elseif byte >= 192 then
            charLen = 2
        end
        chars[#chars + 1] = s:sub(i, i + charLen - 1)
        count = count + 1
        i = i + charLen
    end
    return table.concat(chars)
end

function SH.coverPlaceholder(title, w, h)
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        background = _CLR_COVER_BG, padding = 0,
        dimen      = Geom:new{ w = w, h = h },
        require("ui/widget/container/centercontainer"):new{
            dimen = Geom:new{ w = w, h = h },
            require("ui/widget/textwidget"):new{
                text = safeFirstChars(title or "?", 2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
                bold = true,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- getBookCover
-- ---------------------------------------------------------------------------
function SH.getBookCover(filepath, w, h)
    local bb = Config.getCoverBB(filepath, w, h)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image        = bb,
            width        = w,
            height       = h,
            -- bb is already scaled to exactly w×h by getCoverBB.
            scale_factor = 1,
        }
    end)
    if not (ok and img) then return nil end
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

-- ---------------------------------------------------------------------------
-- formatTimeLeft
-- ---------------------------------------------------------------------------
function SH.formatTimeLeft(pct, pages, avg_time)
    if not avg_time or avg_time <= 0 or not pct or pct < 0 or not pages then return nil end
    local remaining = math.floor(pages * (1.0 - pct))
    if remaining <= 0 then return nil end
    local secs = math.floor(remaining * avg_time)
    if secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- getBookData
-- ---------------------------------------------------------------------------
local _DocSettings = nil
local function getDocSettings()
    if not _DocSettings then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DocSettings = ds end
    end
    return _DocSettings
end

function SH.getBookData(filepath, prefetched, shared_conn)
    local meta = {}
    local percent, pages, md5, stat_pages, stat_total_time = 0, nil, nil, nil, nil

    if prefetched then
        -- Fast path: use data already extracted by prefetchBooks.
        percent         = prefetched.percent or 0
        pages           = prefetched.doc_pages
        md5             = prefetched.partial_md5_checksum
        stat_pages      = prefetched.stat_pages
        stat_total_time = prefetched.stat_total_time
        meta.title      = prefetched.title
        meta.authors    = prefetched.authors
    elseif prefetched ~= false then
        -- prefetched==nil means prefetchBooks was not called (e.g. direct call).
        -- prefetched==false means prefetchBooks tried but DS.open failed — skip
        -- the lfs.attributes syscall and DS.open retry; fall through with defaults.
        local DS = getDocSettings()
        if DS and lfs.attributes(filepath, "mode") == "file" then
            local ok2, ds = pcall(DS.open, DS, filepath)
            if ok2 and ds then
                percent         = ds:readSetting("percent_finished") or 0
                pages           = ds:readSetting("doc_pages")
                md5             = ds:readSetting("partial_md5_checksum")
                local rp        = ds:readSetting("doc_props") or {}
                local rs        = ds:readSetting("stats") or {}
                meta.title      = rp.title
                meta.authors    = rp.authors
                stat_pages      = rs.pages
                stat_total_time = rs.total_time_in_sec
            end
        end
    end

    if not meta.title then
        meta.title = filepath:match("([^/]+)%.[^%.]+$") or "?"
    end

    local avg_time
    -- Source 1: live ReaderUI session — most accurate when a book is open.
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        if ReaderUI and ReaderUI.instance then
            local stats = ReaderUI.instance.statistics
            if stats and stats.avg_time and stats.avg_time > 0 then
                -- Only use if this is the same book currently being read.
                local rui_fp = ReaderUI.instance.document
                    and ReaderUI.instance.document.file
                if rui_fp == filepath then
                    avg_time = stats.avg_time
                end
            end
        end
    end)
    -- Source 2: statistics SQLite DB (covers past sessions).
    if not avg_time and md5 and shared_conn then
        pcall(function()
            if not shared_conn._stmt_avg then
                shared_conn._stmt_avg = shared_conn:prepare([[
                    SELECT count(DISTINCT page_stat.page), sum(page_stat.duration)
                    FROM   page_stat
                    JOIN   book ON book.id = page_stat.id_book
                    WHERE  book.md5 = ?;
                ]])
            end
            local r  = shared_conn._stmt_avg:reset():bind(md5):step()
            local rp = tonumber(r and r[1]) or 0
            local tt = tonumber(r and r[2]) or 0
            if rp > 0 and tt > 0 then avg_time = tt / rp end
        end)
    end
    -- Source 3: doc settings stats (written by Statistics plugin on close).
    if not avg_time and stat_pages and stat_pages > 0
            and stat_total_time and stat_total_time > 0 then
        avg_time = stat_total_time / stat_pages
    end

    return {
        percent  = percent,
        title    = meta.title,
        authors  = meta.authors or "",
        pages    = pages,
        avg_time = avg_time,
    }
end

-- ---------------------------------------------------------------------------
-- prefetchBooks — reads history, pre-extracts book metadata.
-- Called once per Homescreen render; result cached per open instance.
-- ---------------------------------------------------------------------------
-- NOTE: _cover_extraction_pending was removed from SH.
-- Use Config.cover_extraction_pending (the single source of truth) instead.

function SH.prefetchBooks(show_currently, show_recent)
    local state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
    if not show_currently and not show_recent then return state end

    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return state end
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        pcall(function() ReadHistory:reload() end)
    end

    local DS = getDocSettings()
    -- hist[1] is the most recently read book.
    -- • show_currently=true  → claim it as current_fp; never add to recent_fps.
    -- • show_currently=false → treat it like any other entry for recent_fps.
    -- Always start at index 1 so hist[1] is never silently dropped.
    for i = 1, #(ReadHistory.hist or {}) do
        local entry = ReadHistory.hist[i]
        local fp = entry and entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            if i == 1 and show_currently then
                -- Claim as currently-reading book.
                state.current_fp = fp
                if DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        local rp = ds:readSetting("doc_props") or {}
                        local rs = ds:readSetting("stats") or {}
                        state.prefetched_data[fp] = {
                            percent              = ds:readSetting("percent_finished") or 0,
                            title                = rp.title,
                            authors              = rp.authors,
                            doc_pages            = ds:readSetting("doc_pages"),
                            partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                            stat_pages           = rs.pages,
                            stat_total_time      = rs.total_time_in_sec,
                        }
                        pcall(function() ds:close() end)
                    else
                        -- Signal that DS.open was attempted but failed — getBookData
                        -- will skip the lfs.attributes syscall and DS.open retry.
                        state.prefetched_data[fp] = false
                    end
                end
            elseif show_recent and #state.recent_fps < 5 then
                -- i==1 only reaches here when show_currently==false, so hist[1]
                -- is correctly included in recent rather than being skipped.
                local pct = 0
                if DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        pct    = ds:readSetting("percent_finished") or 0
                        local rp = ds:readSetting("doc_props") or {}
                        local rs = ds:readSetting("stats") or {}
                        state.prefetched_data[fp] = {
                            percent              = pct,
                            title                = rp.title,
                            authors              = rp.authors,
                            doc_pages            = ds:readSetting("doc_pages"),
                            partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                            stat_pages           = rs.pages,
                            stat_total_time      = rs.total_time_in_sec,
                        }
                        pcall(function() ds:close() end)
                    else
                        state.prefetched_data[fp] = false
                    end
                end
                if pct < 1.0 then state.recent_fps[#state.recent_fps + 1] = fp end
            end
        end
        if not show_recent and state.current_fp then break end
        if state.current_fp and #state.recent_fps >= 5 then break end
    end
    return state
end


-- ---------------------------------------------------------------------------
-- Sidecar helpers
-- ---------------------------------------------------------------------------

-- Counts books the user explicitly marked as read (summary.status = "complete")
-- by iterating ReadHistory and loading each sidecar via DocSettings.
-- Optional year_str (e.g. "2025") filters by summary.modified; pass nil for
-- an all-time count. Handles modified stored as unix timestamp (number),
-- ISO-8601 string, or os.date("*t") table.
function SH.countMarkedRead(year_str)
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return 0 end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return 0 end

    local function modifiedInYear(summary)
        if not year_str then return true end
        local mod = summary and summary.modified
        if mod == nil then return false end
        if type(mod) == "number" then
            return os.date("%Y", mod) == year_str
        end
        if type(mod) == "string" then
            if #mod >= 4 and mod:sub(1, 4) == year_str then return true end
            local ok_t, t = pcall(function()
                return os.time({
                    year  = tonumber(mod:sub(1, 4)),
                    month = tonumber(mod:sub(6, 7)) or 1,
                    day   = tonumber(mod:sub(9, 10)) or 1,
                    hour  = 12,
                })
            end)
            if ok_t and t and os.date("%Y", t) == year_str then return true end
            return false
        end
        if type(mod) == "table" and mod.year then
            return tostring(mod.year) == year_str
        end
        return false
    end

    local count = 0
    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local ok_open, doc_settings = pcall(function() return DocSettings:open(fp) end)
            if ok_open and doc_settings then
                local ok_sum, summary = pcall(function() return doc_settings:readSetting("summary") end)
                if ok_sum and type(summary) == "table" and summary.status == "complete"
                    and modifiedInYear(summary) then
                    count = count + 1
                end
                pcall(function() doc_settings:close() end)
            end
        end
    end
    return count
end

return SH