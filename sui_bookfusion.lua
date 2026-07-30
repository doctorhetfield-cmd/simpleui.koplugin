-- sui_bookfusion.lua — Simple UI / BookFusion tab
-- Native-feeling fullscreen widget that surfaces the user's BookFusion library
-- (Currently Reading carousel, Plan to Read & Favorites grid subpages, in-place
-- search) without duplicating logic from bookfusion.koplugin — it calls the
-- live BF plugin instance registered on the FileManager under `fm.bookfusion`.
--
-- File layout (sections marked with banners below):
--   1. Settings   — scale/count knobs read from sui_store.
--   2. Cache      — LuaSettings-backed persistence for the three lists.
--   3. Data       — thin shims over fm.bookfusion (api, settings, browser).
--   4. Covers     — in-memory + disk cache + async download of cover_urls.
--   5. Tile       — BookTile InputContainer (cover + title + optional pct).
--   6. Widget     — fullscreen landing + subpages; InputContainer-based.
--   7. Module API — entry point called from sui_quickactions.
--
-- The widget mirrors sui_homescreen's pattern: builds its own TitleBar +
-- content FrameContainer so a whole page fits one screen with no scrolling.
-- SUI's navbar is injected automatically via sui_patches' INJECT_NAMES match
-- on `name = "bookfusion"`.

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Size            = require("ui/size")
local logger          = require("logger")
local _               = require("sui_i18n").translate

local UI          = require("sui_core")
local SUISettings = require("sui_store")
local Screen      = Device.screen

-- Absolute path to this plugin's icons/ directory.  Needed because
-- IconWidget's search paths (koreader/resources/icons/...) don't cover
-- plugin-local SVGs, so we load custom icons via ImageWidget with an
-- explicit `file` path the way sui_config.lua resolves `_P`.
local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
local _ICON_DOWNLOAD = _PLUGIN_DIR and (_PLUGIN_DIR .. "/icons/download.svg")

-- Forward-declare so the widget class can reach `M._instance` in onCloseWidget.
local M = {}
M._instance = nil

-- ===========================================================================
-- 1. SETTINGS
-- ===========================================================================

local Settings = {}

local SETK_COVER_SCALE_CR    = "navbar_bookfusion_cover_scale_cr"    -- float, 0.5 .. 1.6  (carousel)
local SETK_TEXT_SCALE_CR     = "navbar_bookfusion_text_scale_cr"     -- float, 0.6 .. 1.6  (carousel)
local SETK_TEXT_SCALE_FOLDER = "navbar_bookfusion_text_scale_folder" -- float, 0.6 .. 1.6  (folder grid)
local SETK_LABEL_SCALE       = "navbar_bookfusion_label_scale"       -- float, 0.6 .. 1.6
local SETK_SHOW_CR_TITLE     = "navbar_bookfusion_show_cr_title"     -- bool  (carousel)
local SETK_SHOW_CR_PROGRESS  = "navbar_bookfusion_show_cr_progress"  -- bool  (carousel)
-- "bar" draws a LineWidget under the cover; "overlay" draws a round "XX %"
-- badge half-overlapping the cover's bottom edge. When "overlay" is active
-- the bar is skipped so the two don't stack.
local SETK_CR_PROGRESS_STYLE = "navbar_bookfusion_cr_progress_style" -- "bar" | "overlay"
local SETK_SHOW_CR_PAGER     = "navbar_bookfusion_show_cr_pager"     -- bool  (carousel)
local SETK_SHOW_FOLDER_TITLE = "navbar_bookfusion_show_folder_title" -- bool (folder grid)
local SETK_GRID_COLS         = "navbar_bookfusion_grid_cols"         -- int,   1 .. 7
local SETK_GRID_ROWS         = "navbar_bookfusion_grid_rows"         -- int,   1 .. 6
-- Hidden knob: actual fetch_size rounds up to the nearest multiple of the
-- display grid (grid_rows × grid_cols) so every fetch ends on a clean
-- display-page boundary.
local SETK_SEARCH_MIN_FETCH  = "navbar_bookfusion_search_min_fetch"  -- int,   8 .. 100
local SETK_UNIFORM_COVERS    = "navbar_bookfusion_uniform_covers"    -- bool
-- Two independent toggles for the "already downloaded" cloud badge — global
-- (landing + subpage grids) and search-specific, so the badge can be
-- suppressed in search without losing it elsewhere.
local SETK_DL_IND_GLOBAL     = "navbar_bookfusion_dl_ind"            -- bool
local SETK_DL_IND_SEARCH     = "navbar_bookfusion_dl_ind_search"     -- bool

local function _clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function _readNum(key, default, lo, hi)
    local v = SUISettings:readSetting(key)
    local n = tonumber(v)
    if not n then return default end
    return _clamp(n, lo, hi)
end

-- Cover scale for the Currently Reading carousel only.  Values above 1.0
-- yield bigger covers (and therefore fewer per row, since cr_cols is now
-- derived from the scale); values below 1.0 give smaller covers and more
-- per row.  Folder grids use the full tile width regardless — see
-- _buildSubpage.
function Settings.coverScaleCarousel() return _readNum(SETK_COVER_SCALE_CR, 1.0, 0.5, 1.6) end
function Settings.textScaleCarousel()  return _readNum(SETK_TEXT_SCALE_CR,     1.0, 0.6, 1.6) end
function Settings.textScaleFolder()    return _readNum(SETK_TEXT_SCALE_FOLDER, 1.0, 0.6, 1.6) end
function Settings.labelScale()         return _readNum(SETK_LABEL_SCALE,   1.0, 0.6, 1.6) end
function Settings.showCarouselTitle()    return SUISettings:nilOrTrue(SETK_SHOW_CR_TITLE) end
function Settings.showCarouselProgress() return SUISettings:nilOrTrue(SETK_SHOW_CR_PROGRESS) end
function Settings.progressStyleCarousel()
    local v = SUISettings:readSetting(SETK_CR_PROGRESS_STYLE)
    return v == "overlay" and "overlay" or "bar"
end
function Settings.showCarouselPager()    return SUISettings:nilOrTrue(SETK_SHOW_CR_PAGER) end
function Settings.showFolderTitle()      return SUISettings:nilOrTrue(SETK_SHOW_FOLDER_TITLE) end
function Settings.gridCols()       return math.floor(_readNum(SETK_GRID_COLS,        4,  1,   7)) end
function Settings.gridRows()       return math.floor(_readNum(SETK_GRID_ROWS,        2,  1,   6)) end
function Settings.searchMinFetch() return math.floor(_readNum(SETK_SEARCH_MIN_FETCH, 20, 8, 100)) end
function Settings.uniformCovers()         return SUISettings:nilOrTrue(SETK_UNIFORM_COVERS) end
function Settings.showDownloadIndicators()       return SUISettings:nilOrTrue(SETK_DL_IND_GLOBAL) end
function Settings.showDownloadIndicatorsSearch() return SUISettings:nilOrTrue(SETK_DL_IND_SEARCH) end

-- Key constants exported for sui_bookfusion_settings to write via saveSetting
-- without duplicating the navbar_bookfusion_* strings.
Settings.KEYS = {
    COVER_SCALE_CR      = SETK_COVER_SCALE_CR,
    TEXT_SCALE_CR       = SETK_TEXT_SCALE_CR,
    TEXT_SCALE_FOLDER   = SETK_TEXT_SCALE_FOLDER,
    LABEL_SCALE         = SETK_LABEL_SCALE,
    GRID_COLS           = SETK_GRID_COLS,
    GRID_ROWS           = SETK_GRID_ROWS,
    UNIFORM_COVERS      = SETK_UNIFORM_COVERS,
    SHOW_CR_TITLE       = SETK_SHOW_CR_TITLE,
    SHOW_CR_PROGRESS    = SETK_SHOW_CR_PROGRESS,
    CR_PROGRESS_STYLE   = SETK_CR_PROGRESS_STYLE,
    SHOW_CR_PAGER       = SETK_SHOW_CR_PAGER,
    SHOW_FOLDER_TITLE   = SETK_SHOW_FOLDER_TITLE,
    DL_IND_GLOBAL       = SETK_DL_IND_GLOBAL,
    DL_IND_SEARCH       = SETK_DL_IND_SEARCH,
}

-- Rounds searchMinFetch() up to the nearest multiple of the display grid so
-- every fetched chunk ends on a display-page boundary (never "last row has
-- 3 of 8 slots filled, tap › to get the rest").
function Settings.searchFetchSize(per_display_page)
    if not per_display_page or per_display_page < 1 then per_display_page = 1 end
    local min_fetch = Settings.searchMinFetch()
    return math.max(1, math.ceil(min_fetch / per_display_page)) * per_display_page
end

-- ===========================================================================
-- 2. CACHE — LuaSettings-backed persistence at
-- <SettingsDir>/simpleui/bookfusion_cache.lua. Book records are slimmed to
-- only the fields we render or need to delegate back to the BookFusion plugin.
-- The parent simpleui/ directory is created by main.lua's startup block.
-- ===========================================================================

local Cache = {}

local CACHE_SCHEMA_VERSION = 1
local CACHE_DEFAULT_TTL    = 15 * 60  -- 15 minutes

Cache.LIST_KEYS = { "currently_reading", "planned_to_read", "favorites" }

Cache.LIST_PARAMS = {
    currently_reading = { list = "currently_reading", sort = "last_read_at-desc" },
    planned_to_read   = { list = "planned_to_read" },
    favorites         = { list = "favorites" },
}

local _cache_store

local function _cachePath()
    return DataStorage:getSettingsDir() .. "/simpleui/bookfusion_cache.lua"
end

local function _cacheOpen()
    if _cache_store then return _cache_store end
    local ok, s = pcall(function() return LuaSettings:open(_cachePath()) end)
    if not ok or not s then
        logger.warn("simpleui-bf cache: open failed:", tostring(s))
        return nil
    end
    _cache_store = s
    if s:readSetting("version") ~= CACHE_SCHEMA_VERSION then
        s:saveSetting("version", CACHE_SCHEMA_VERSION)
    end
    return s
end

local function _cacheSlotKey(k) return "list_" .. k end

function Cache.get(k)
    local s = _cacheOpen()
    if not s then return nil end
    local slot = s:readSetting(_cacheSlotKey(k))
    return type(slot) == "table" and slot or nil
end

function Cache.put(k, books)
    local s = _cacheOpen()
    if not s then return end
    local slim = {}
    if type(books) == "table" then
        for i = 1, #books do
            local b = books[i]
            if type(b) == "table" and b.id then
                -- Raw API has `book.cover = { url, width, height }` — flatten
                -- so the widget doesn't re-traverse the nested table on paint.
                local cover = b.cover
                slim[#slim + 1] = {
                    id            = b.id,
                    title         = b.title,
                    authors       = b.authors,
                    cover_url     = cover and cover.url    or b.cover_url,
                    cover_w       = cover and cover.width  or b.cover_w,
                    cover_h       = cover and cover.height or b.cover_h,
                    percentage    = b.percentage,
                    format        = b.format,
                    -- bf_downloader.downloadBook needs this for the "13.0 MB"
                    -- subtitle and progress bar; without it the popup degrades
                    -- to a bare "Downloading…" line.
                    download_size = b.download_size,
                }
            end
        end
    end
    s:saveSetting(_cacheSlotKey(k), { books = slim, fetched_at = os.time() })
    pcall(function() s:flush() end)
end

function Cache.isStale(k, ttl)
    local slot = Cache.get(k)
    if not slot or not slot.fetched_at then return true end
    return (os.time() - slot.fetched_at) > (ttl or CACHE_DEFAULT_TTL)
end

-- ===========================================================================
-- 3. DATA BRIDGE — reaches the live bookfusion.koplugin instance registered
-- on the FM (or ReaderUI) as `.bookfusion`. Every call pcall-guards so a
-- missing plugin yields an empty state instead of a crash.
--
-- API contract (endpoints, request/response shapes, pagination, and traps
-- around nested `cover`, polymorphic `authors`, 4-decimal `percentage`) is
-- in ../BOOKFUSION_API.md — read that before changing any Data.* helper or
-- the Cache.put flattener above.
-- ===========================================================================

local Data = {}

function Data.getPlugin()
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.bookfusion then return FM.instance.bookfusion end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.bookfusion then return RUI.instance.bookfusion end
    return nil
end

function Data.isAvailable() return Data.getPlugin() ~= nil end

function Data.isLinked()
    local p = Data.getPlugin()
    if not p or not p.bf_settings then return false end
    local ok, yes = pcall(function() return p.bf_settings:isLoggedIn() end)
    return ok and yes or false
end

function Data.api() local p = Data.getPlugin(); return p and p.api or nil end

-- Mirrors bf_browser's "is this book already on disk?" probe. Uses the BF
-- plugin's own settings object when available so the user's custom download
-- dir is honored.
function Data.isDownloaded(book)
    if not book or not book.id then return false end
    local ok_dl, Downloader = pcall(require, "bf_downloader")
    if not ok_dl or not Downloader then return false end
    local p = Data.getPlugin()
    local settings = p and p.bf_settings or nil
    local dir = Downloader.getDownloadDir(settings)
    if not dir then return false end
    local filename = Downloader.buildFilename(book)
    if not filename or filename == "" then return false end
    return Downloader.fileExists(dir .. "/" .. filename) or false
end

function Data.startLink()
    local p = Data.getPlugin()
    if not p or type(p.onLinkDevice) ~= "function" then return false end
    local ok, err = pcall(function() p:onLinkDevice() end)
    if not ok then logger.warn("simpleui-bf: startLink failed:", tostring(err)) end
    return ok
end

-- We hold the Browser on a module upvalue instead of letting onSearchBooks
-- build a local one: when launched from inside the BookFusionTab callback,
-- a function-local Browser is GC'd before its menu can paint. Stays alive
-- until the next open (or tab close) overwrites the reference.
local _bf_browser_instance = nil
function Data.openBrowser()
    local p = Data.getPlugin()
    if not p or not p.api or not p.bf_settings then return false end
    local ok_req, Browser = pcall(require, "bf_browser")
    if not ok_req or not Browser then
        logger.warn("simpleui-bf: bf_browser not reachable")
        return false
    end
    -- Deferred by one UI tick so the button's flash/unhighlight refresh
    -- finishes before the popup's setDirty lands in the queue.
    UIManager:scheduleIn(0, function()
        local ok, err = pcall(function()
            _bf_browser_instance = Browser:new(p.api, p.bf_settings)
            _bf_browser_instance:show()
        end)
        if not ok then
            logger.warn("simpleui-bf: openBrowser failed:", tostring(err))
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("BookFusion browse error:") .. "\n" .. tostring(err),
                timeout = 5,
            })
        end
    end)
    return true
end

-- Run bf_browser's onSelectBook (download-or-open) without owning a visible
-- Menu. The on_change hook fires after a filesystem-mutating op (successful
-- download OR confirmed "Remove from device") so the caller can repaint
-- — implemented by setting `_view = "books"` and stubbing `refreshBookList`
-- on a throwaway Browser, which lets us piggyback on the plugin's own
-- "did the disk state change?" guard logic without reimplementing the
-- dialog flow.
function Data.selectBook(book, on_change)
    local p = Data.getPlugin()
    if not p or not book then return false end
    local ok_req, Browser = pcall(require, "bf_browser")
    if not ok_req or not Browser then
        logger.warn("simpleui-bf: bf_browser not reachable")
        return false
    end
    local ok, err = pcall(function()
        local browser = Browser:new(p.api, p.bf_settings)
        browser._view = "books"  -- unlocks the plugin's own refresh calls
        browser.refreshBookList = function()
            if on_change then pcall(on_change) end
        end
        browser:onSelectBook(book)
    end)
    if not ok then logger.warn("simpleui-bf: selectBook failed:", tostring(err)) end
    return ok
end

-- Paginate through api:searchBooks until every page is collected, then invoke
-- cb(ok, books) on the main thread.  per_page bigger than bf_browser's 20 to
-- cut round-trips; 200-page safety belt just in case.
local FETCH_PER_PAGE = 50

function Data.fetchListAll(params, cb, opts)
    local api = Data.api()
    if not api then if cb then cb(false, "api_unavailable") end; return end
    UIManager:scheduleIn(0, function()
        local all, page = {}, 1
        while true do
            local q = { page = page, per_page = FETCH_PER_PAGE }
            for k, v in pairs(params or {}) do q[k] = v end
            local ok, books, pagination = api:searchBooks(q)
            if not ok or type(books) ~= "table" then
                if cb then cb(false, books) end; return
            end
            for i = 1, #books do all[#all + 1] = books[i] end
            local total = pagination and pagination.total
            if #books < FETCH_PER_PAGE then break end
            if total and #all >= total then break end
            page = page + 1
            if page > 200 then break end
        end

        -- /books/search returns metadata only — no reading progress. When
        -- the caller asks for it, follow up with one getReadingPosition per
        -- book and attach `.percentage` as a 0..1 fraction (server sends
        -- 0..100.0000). 404 means "no remote position yet" → leave nil.
        -- N serial GETs — only enable for short lists like Currently Reading.
        if opts and opts.with_progress then
            for i = 1, #all do
                local b = all[i]
                if b and b.id then
                    local ok_p, pos = pcall(function()
                        local ok_r, data = api:getReadingPosition(b.id)
                        return ok_r and data or nil
                    end)
                    if ok_p and type(pos) == "table" then
                        local pct = tonumber(pos.percentage)
                        if pct then b.percentage = pct / 100 end
                    end
                end
            end
        end

        if cb then cb(true, all) end
    end)
end

-- One-page-at-a-time variant for in-place search, so the first results paint
-- as soon as possible and we don't over-fetch when the user only looks at
-- page 1. cb is `(ok, books, pagination)`.
function Data.searchPage(query, api_page, per_page, cb)
    local api = Data.api()
    if not api then if cb then cb(false, "api_unavailable") end; return end
    UIManager:scheduleIn(0, function()
        local ok, books, pagination = api:searchBooks({
            query    = query,
            page     = api_page,
            per_page = per_page,
        })
        if not ok then if cb then cb(false, books) end; return end
        if cb then cb(true, books, pagination) end
    end)
end

-- ===========================================================================
-- 4. COVERS — three-tier cover resolution:
--   L0: in-memory BlitBuffer keyed by (url, w, h)  → instant re-render
--   L1: disk bytes from bookfusion.koplugin/bf_covercache → decode + return
--   L2: HTTP fetch via bf_image_loader (async, Trapper subprocess) → on
--       success, write to disk cache and fire callback to repaint.
--
-- Known limitation: bf_image_loader uses Trapper's dismissableRunInSubprocess,
-- so any user input during a sync kills the in-flight download and the URL
-- stays un-cached. Covers may need multiple refreshes to land on disk when
-- the user is actively interacting.
-- ===========================================================================

local Covers = {}

local _bb_cache = {}  -- key = url  → { bb, w, h }

-- Try L0 + L1 synchronously; never triggers network. Always pass explicit
-- w×h to renderImageData: without dims, the returned BB's memory is owned
-- by the JPEG document and paints as solid black once the document is GC'd.
-- Explicit dims force scaleBlitBuffer to allocate a fresh BB we own.
function Covers.getBB(url, api_w, api_h)
    if not url or url == "" then return nil end
    local entry = _bb_cache[url]
    if entry then return entry.bb, entry.w, entry.h end
    local ok_cc, CC = pcall(require, "bf_covercache")
    if not ok_cc or not CC then return nil end
    local data = CC.read(url)
    if not data then return nil end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return nil end

    -- Fall back to a reasonable default if the API didn't supply dims OR
    -- supplied something invalid (0, negative, or non-number).  Some books
    -- in the BookFusion catalogue really do ship with cover.width = 0 in
    -- the API response; `tonumber()` alone doesn't catch that, and passing
    -- 0 to scaleBlitBuffer produces a zero-pixel BB that paints solid black.
    local w = tonumber(api_w)
    local h = tonumber(api_h)
    if not w or w <= 0 then w = 400 end
    if not h or h <= 0 then h = 600 end

    local ok, new_bb = pcall(function()
        return RenderImage:renderImageData(data, #data, false, w, h)
    end)
    if not ok or not new_bb then return nil end
    new_bb:setAllocated(1)

    -- Use the BB's ACTUAL dimensions, not the values we asked for.  The
    -- decoders don't all honour the hint exactly (MuPDF / WebP / GifLib
    -- can return slightly different sizes), and downstream _bestFitScale
    -- needs the real dims to compute a correct scale factor.
    local actual_w = new_bb:getWidth()  or w
    local actual_h = new_bb:getHeight() or h
    if actual_w <= 0 or actual_h <= 0 then
        pcall(function() new_bb:free() end)
        return nil
    end

    _bb_cache[url] = { bb = new_bb, w = actual_w, h = actual_h }
    return new_bb, actual_w, actual_h
end

-- Kick off async fetch for each url not yet on disk. `on_done(url)` fires on
-- the main thread after each cover is cached — caller repaints the tile.
-- Returns a halt fn that cancels the pending queue.
--
-- Defers the first download by 1 s by default so rapid page flips / view
-- changes can cancel the batch before any HTTP traffic happens. Pass
-- `opts.defer = false` when the trigger is unambiguous (e.g. manual ↻ sync).
--
-- Dismissal recovery: bf_image_loader's Trapper subprocess is dismissable by
-- any UI event, so URLs may stay un-cached after a fetch. We poll the batch's
-- loading flag, diff against disk, and retry the still-missing URLs. Bounded
-- at 3 total passes to cap the "user never stops interacting" case.
function Covers.fetchMissing(urls, on_done, opts)
    local ok_cc, CC = pcall(require, "bf_covercache")
    if not ok_cc or not CC then return function() end end
    local missing = {}
    for i = 1, #urls do
        local u = urls[i]
        if u and u ~= "" and not CC.read(u) then missing[#missing + 1] = u end
    end
    if #missing == 0 then return function() end end
    local ok_il, ImageLoader = pcall(require, "bf_image_loader")
    if not ok_il or not ImageLoader then return function() end end

    local MAX_PASSES = 3
    local POLL_INTERVAL = 1.0
    local defer = not (opts and opts.defer == false)
    local cancelled = false
    local inner_halt
    local current_batch
    local passes = 0
    local poll_fn
    local start_pass  -- forward-decl for closure reference from poll_fn

    local function on_fetch(url, content)
        if content and #content > 0 then
            CC.write(url, content)
            if on_done then on_done(url) end
        end
    end

    start_pass = function(url_list)
        passes = passes + 1
        local batch, halt = ImageLoader:loadImages(url_list, on_fetch)
        current_batch = batch
        inner_halt    = halt
        UIManager:scheduleIn(POLL_INTERVAL, poll_fn)
    end

    poll_fn = function()
        if cancelled then return end
        if not current_batch or current_batch.loading then
            UIManager:scheduleIn(POLL_INTERVAL, poll_fn)
            return
        end
        if passes >= MAX_PASSES then return end
        local still_missing = {}
        for i = 1, #missing do
            if not CC.read(missing[i]) then
                still_missing[#still_missing + 1] = missing[i]
            end
        end
        if #still_missing == 0 then return end
        start_pass(still_missing)
    end

    local start_fn
    start_fn = function()
        if cancelled then return end
        start_pass(missing)
    end
    if defer then
        UIManager:scheduleIn(1, start_fn)
    else
        start_fn()
    end

    return function()
        cancelled = true
        if defer then
            pcall(function() UIManager:unschedule(start_fn) end)
        end
        pcall(function() UIManager:unschedule(poll_fn) end)
        if inner_halt then pcall(inner_halt) end
    end
end

-- Drop the BB cache (called on widget close so memory is freed).
function Covers.freeAll()
    for k, entry in pairs(_bb_cache) do
        if entry and entry.bb and type(entry.bb.free) == "function" then
            pcall(entry.bb.free, entry.bb)
        end
        _bb_cache[k] = nil
    end
end

-- ===========================================================================
-- 5. TILE
-- ---------------------------------------------------------------------------
-- BookTile: cover + title + optional progress.  One InputContainer per tile
-- so each tile owns its tap gesture.  Uses a cover thumbnail when available;
-- falls back to the BookFusion plugin's missing-image glyph placeholder.
-- ===========================================================================

local COLOR_COVER_BORDER = Blitbuffer.COLOR_BLACK
local COVER_BORDER_SIZE  = 2
-- Matches module_currently's palette so the progress bar looks identical to
-- the Home tab's Currently Reading card.
local COLOR_BAR_BG       = Blitbuffer.gray(0.15)  -- dark track
local COLOR_BAR_FG       = Blitbuffer.gray(0.75)  -- light fill

-- Bordered box with a centered "missing image" glyph (U+26F6). `title` arg
-- kept on the signature for caller compatibility but ignored — matches the
-- official BookFusion plugin's placeholder style.
local function _coverPlaceholder(title, w, h)  -- luacheck: no unused args
    -- FrameContainer's outer size = content + 2*bordersize. The inner
    -- CenterContainer must subtract that or the placeholder will be 2 px
    -- wider/taller than a real cover and misalign with neighbours.
    local bw = COVER_BORDER_SIZE
    -- Glyph size tracks placeholder height; floor of 6 keeps very small
    -- cells readable. Font:getFace applies scaleBySize internally.
    local glyph_fs = math.max(6, math.floor(10 * h / 64))
    return FrameContainer:new{
        bordersize = bw, color = COLOR_COVER_BORDER,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = h },
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * bw, h = h - 2 * bw },
            TextWidget:new{
                text = "\u{26F6}",
                face = Font:getFace("cfont", glyph_fs),
            },
        },
    }
end

-- Best-fit scale from native dims into a display box, preserving aspect.
-- If the image fills max_h within max_w → height-constrained; otherwise
-- width-constrained. Without the dual-branch check, portrait covers overflow
-- their tile_h and bleed into the row below.
local function _bestFitScale(bb_w, bb_h, max_w, max_h)
    local fit_w = math.floor(max_h * bb_w / bb_h + 0.5)
    if max_w >= fit_w then
        return max_h / bb_h   -- height is the limiting axis
    else
        return max_w / bb_w   -- width is the limiting axis
    end
end

-- Cover-fill scale (the max of h and w ratios): the BB is sized so the
-- SHORTER axis matches the box exactly, guaranteeing the longer axis
-- overflows.  Combined with ImageWidget's width/height + center_x/y_ratio
-- cropping, this yields uniform tile shapes with the centered part of the
-- cover visible — the standard "cover" behaviour in CSS object-fit terms.
local function _coverFillScale(bb_w, bb_h, max_w, max_h)
    return math.max(max_w / bb_w, max_h / bb_h)
end

-- Build the cover widget AND report its actual rendered outer size (including
-- the 1px border on each side).  The caller (BookTile) uses this width so the
-- progress bar ends up exactly under the visible cover — no letterbox gap.
--
-- Two modes, chosen by Settings.uniformCovers():
--   • uniform = true  (default)  → scale-to-fill + centre-crop.  Every tile
--     is exactly box_w × box_h; box sets / landscape covers lose their edges
--     but the grid looks consistent.
--   • uniform = false             → best-fit + letterbox.  Each cover keeps
--     its native aspect, so shapes in the grid vary.
--
-- Returns: widget, actual_w, actual_h  (scaled-image + 2*border dims)
local function _coverImage(bb, bb_w, bb_h, box_w, box_h)
    -- Inner box inside the border on both sides.
    local inner_w = box_w - 2 * COVER_BORDER_SIZE
    local inner_h = box_h - 2 * COVER_BORDER_SIZE
    local uniform = Settings.uniformCovers()
    local bw = COVER_BORDER_SIZE

    if uniform then
        -- Scale-to-fill: scale_factor grows the BB past inner_w × inner_h,
        -- then width/height + ImageWidget's default center_x/y_ratio=0.5
        -- crops the centred region.
        local scale = _coverFillScale(bb_w, bb_h, inner_w, inner_h)
        local ok, img = pcall(function()
            local w = ImageWidget:new{
                image            = bb,
                image_disposable = false,   -- owned by Covers cache
                scale_factor     = scale,
                width            = inner_w, -- paint-area — crops overflow
                height           = inner_h,
            }
            w:_render()
            return w
        end)
        if not (ok and img) then return nil, box_w, box_h end
        local frame = FrameContainer:new{
            bordersize = bw, color = COLOR_COVER_BORDER,
            padding = 0, margin = 0,
            dimen = Geom:new{ w = box_w, h = box_h },
            img,
        }
        return frame, box_w, box_h
    end

    -- Best-fit / letterbox mode — preserves native aspect ratio.
    local scale = _bestFitScale(bb_w, bb_h, inner_w, inner_h)
    local ok, img = pcall(function()
        local w = ImageWidget:new{
            image            = bb,
            image_disposable = false,  -- owned by Covers cache; do not free here
            scale_factor     = scale,  -- ≠ 1 → _render() builds a fresh BB
        }
        -- Eagerly render now so the widget is ready to paint (and holds its
        -- own fresh BB, not a reference into the source document's memory).
        w:_render()
        return w
    end)
    if not (ok and img) then return nil, box_w, box_h end
    local sz = img:getSize()
    -- Frame hugs the scaled image: no CenterContainer, no letterbox whitespace.
    -- Tile VerticalGroup(align="center") centers this frame + the progress bar
    -- within the tile column, keeping them perfectly stacked.
    local actual_w = sz.w + 2 * bw  -- border on both sides
    local actual_h = sz.h + 2 * bw
    local frame = FrameContainer:new{
        bordersize = bw, color = COLOR_COVER_BORDER,
        padding = 0, margin = 0,
        dimen = Geom:new{ w = actual_w, h = actual_h },
        img,
    }
    return frame, actual_w, actual_h
end

-- Title label constrained to N rows. TextBoxWidget has no max_lines, so we
-- size `height` to fit N lines exactly and let height_overflow_show_ellipsis
-- truncate the rest.
--
-- Font:getFace internally runs the requested size through Screen:scaleBySize
-- before handing it to FreeType, so face.size ends up double-scaled if the
-- caller pre-scaled. Deriving line_h from face.size (not the requested size)
-- keeps the N-row layout intact regardless of device scale factor.
local function _titleLabel(title, w, font_size, lines)
    lines = lines or 2
    local face   = Font:getFace("cfont", font_size)
    local line_h = math.floor((1 + 0.3) * face.size + 0.5)
    return TextBoxWidget:new{
        text                          = title or _("Untitled"),
        face                          = face,
        width                         = w,
        alignment                     = "center",
        height                        = line_h * lines + 1,
        height_overflow_show_ellipsis = true,
    }
end

-- Progress bar — same shape as the home screen's "simple" bar style
-- (desktop_modules/module_books_shared.SH.progressBar): OverlapGroup stacks
-- a full-width dark track LineWidget under a fill-width light LineWidget.
-- No inline percentage label — user wants just the bar.
local BAR_BASE_H = Screen:scaleBySize(7)

local function _progressBar(pct, w)
    local bar_h = BAR_BASE_H
    local fill  = math.max(0, math.min(1, pct or 0))
    local fw    = math.max(0, math.floor(w * fill))
    if fw <= 0 then
        return LineWidget:new{
            dimen = Geom:new{ w = w, h = bar_h },
            background = COLOR_BAR_BG,
        }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bar_h },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bar_h }, background = COLOR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bar_h }, background = COLOR_BAR_FG },
    }
end

-- Round "XX %" badge overlaid on the cover's bottom edge. Half sits inside
-- the cover and half bleeds below, so the caller must build an OverlapGroup
-- sized (cov_w × (cov_h + badge_r)) to avoid clipping the lower half.
--
-- Sizing probes TextWidget:getSize() on "100%" with the actual render face
-- so the badge tracks text size, not cover width. Cover-proportional sizing
-- explodes on the carousel's 200+ px covers.

-- Diameter + radius from text_scale, extracted so _buildLanding's reserve
-- calc can mirror it without building the full widget. Template is "100%"
-- since all percentages are ≤3 digits + "%".
local function _overlayBadgeDims(text_scale)
    local scale  = text_scale or 1.0
    local pct_fs = math.max(8, math.floor(Screen:scaleBySize(8) * scale))
    local probe  = TextWidget:new{
        text = "100%",
        face = Font:getFace("smallinfofont", pct_fs),
        bold = true,
    }
    local probe_size = probe:getSize()
    -- Tight padding — just enough breath so the text doesn't touch the
    -- circle edge.  Going below ~2 px risks the "100%" corner glyphs
    -- clipping at the rounded badge edge; 3 px sits safely above that.
    local pad        = Screen:scaleBySize(3)
    local badge_d    = math.max(
        Screen:scaleBySize(14),
        probe_size.w + 2 * pad,
        probe_size.h + 2 * pad
    )
    local badge_r = math.floor(badge_d / 2)
    return badge_r * 2, badge_r, pct_fs   -- rounded-even diameter, radius, font size
end

-- Returns: badge_widget, badge_r, badge_d — caller uses the latter two
-- to size its OverlapGroup and to reserve vertical budget in the tile.
local function _overlayBadge(pct, text_scale)
    local pct_int = math.floor((tonumber(pct) or 0) * 100)
    local badge_d, badge_r, pct_fs = _overlayBadgeDims(text_scale)
    local badge = FrameContainer:new{
        bordersize = 0,
        background = Blitbuffer.gray(0.15),
        padding    = 0,
        dimen      = Geom:new{ w = badge_d, h = badge_d },
        radius     = badge_r,
        CenterContainer:new{
            dimen = Geom:new{ w = badge_d, h = badge_d },
            TextWidget:new{
                text    = string.format(_("%d%%"), pct_int),
                face    = Font:getFace("smallinfofont", pct_fs),
                bold    = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    }
    return badge, badge_r, badge_d
end

-- "Not downloaded" badge — rounded white rectangle with a download-arrow
-- glyph. Inverse of the official plugin's "Downloaded" label: we mark
-- cloud-only books so the visual noise lives only on books that would
-- actually cost bandwidth to open. Returns badge_widget, width, height.
local function _cloudBadge()
    -- Custom SVG (icons/cloud-download.svg) rendered via ImageWidget: the
    -- glyph-based approach (☁ / ▼) can't express cloud-with-down-arrow on
    -- most cfont builds. alpha=true preserves the SVG's transparent
    -- background so the badge's white fill shows through.
    local icon_size = Screen:scaleBySize(20)
    local side      = icon_size
    local icon = ImageWidget:new{
        file         = _ICON_DOWNLOAD,
        alpha        = true,
        scale_factor = 0,             -- fit to width × height
        width        = icon_size,
        height       = icon_size,
    }
    local badge = FrameContainer:new{
        dimen      = Geom:new{ w = side, h = side },
        bordersize = Size.border.thin,
        color      = Blitbuffer.COLOR_DARK_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        radius     = Screen:scaleBySize(2),
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = side, h = side },
            icon,
        },
    }
    return badge, side, side
end

local BookTile = InputContainer:extend{}

-- opts = { book, w, h, cover_w, cover_h, show_progress, progress_style,
--          show_title, title_lines, text_scale, show_dl_indicator, on_tap }
function BookTile:init()
    local o = self.opts
    local book = o.book or {}
    local w    = o.w
    local h    = o.h
    -- cover_w is optional: callers that want cover-scale to shrink the
    -- cover horizontally (as well as vertically) pass it explicitly.  When
    -- omitted we fall back to the full tile width, preserving the old
    -- width-always-fills behaviour for any caller that hasn't migrated.
    local cov_w = o.cover_w or w
    local cov_h = o.cover_h

    -- Cover (real or placeholder).  _coverImage returns the widget PLUS its
    -- actual rendered width/height (post best-fit scaling, including the 1px
    -- border on each side).  We use that actual width for the progress bar
    -- so it sits flush under the visible cover.  Placeholder covers fill the
    -- whole box, so actual_w falls back to cov_w in that branch.
    local cover, actual_w, actual_h
    if book.cover_url and book.cover_url ~= "" then
        local bb, bb_w, bb_h = Covers.getBB(book.cover_url, book.cover_w, book.cover_h)
        if bb then cover, actual_w, actual_h = _coverImage(bb, bb_w, bb_h, cov_w, cov_h) end
    end
    if not cover then
        cover    = _coverPlaceholder(book.title, cov_w, cov_h)
        actual_w = cov_w
        actual_h = cov_h
    end

    -- Cloud-only indicator: small square in the cover's bottom-right
    -- corner, added when the caller has decided the book exists only in
    -- BookFusion's cloud (not yet downloaded locally).  Lives INSIDE the
    -- cover bounds (no bleed, no budget impact), so the OverlapGroup
    -- keeps the same (actual_w × actual_h) as the bare cover — later
    -- wraps (percentage-overlay badge) can nest on top without having
    -- to account for it.
    if o.show_dl_indicator then
        local ind, iw, ih = _cloudBadge()
        -- Bottom-right inset from the cover edges.  Bumped on both
        -- axes so the badge has breathing room from adjacent cover
        -- art instead of hugging the corner too tightly.
        local pad_x = Screen:scaleBySize(5)
        local pad_y = Screen:scaleBySize(6)
        ind.overlap_offset = {
            actual_w - iw - pad_x,
            actual_h - ih - pad_y,
        }
        cover = OverlapGroup:new{
            dimen = Geom:new{ w = actual_w, h = actual_h },
            cover,
            ind,
        }
    end

    -- Overlay-badge mode: wrap the cover widget in an OverlapGroup that
    -- includes the bottom half of the badge bleeding below the cover,
    -- Centred horizontally with half inside / half outside the cover's
    -- bottom edge. When active, the separate progress bar below is skipped
    -- (the two would be redundant).
    local use_overlay = o.show_progress and o.progress_style == "overlay"
    if use_overlay then
        local pct = tonumber(book.percentage) or 0
        local badge, badge_r, badge_d = _overlayBadge(pct, o.text_scale)
        -- Offset: centred horizontally over the cover, half inside /
        -- half below the cover's bottom edge (y = actual_h - badge_r).
        badge.overlap_offset = {
            math.floor((actual_w - badge_d) / 2),
            actual_h - badge_r,
        }
        cover = OverlapGroup:new{
            dimen = Geom:new{ w = actual_w, h = actual_h + badge_r },
            cover,
            badge,
        }
    end

    -- Font sizes.  Title = 6px base (slightly smaller so longer titles can
    -- wrap onto a second line without blowing the tile height budget).
    -- Scaled by the user's text_scale setting.  No percentage text under
    -- the bar — the bar itself is the progress indicator per user spec.
    local txt_sc   = o.text_scale or 1.0
    local title_fs = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))

    -- Layout order (per user spec, feedback pass 3):
    --     cover
    --     └─ progress bar (only when show_progress; sits FLUSH under cover)
    --     small gap
    --     title
    --
    -- The bar is visually an extension of the cover so it should butt up
    -- against the cover's bottom edge with no gap in between.
    local vg = VerticalGroup:new{ align = "center" }
    -- Zero-height, tile-wide sentinel so the VG's intrinsic width equals
    -- the tile width regardless of which children end up in it.  Without
    -- this, hiding the title makes the VG only as wide as the cover, and
    -- FrameContainer then renders that narrower VG at (0,0) of the tile
    -- — covers drift to the left instead of staying centered.  The
    -- HorizontalSpan has height=0, so it costs no vertical budget.
    vg[#vg+1] = HorizontalSpan:new{ width = w }
    vg[#vg+1] = cover
    -- Bar-style progress indicator: only drawn when progress is on AND the
    -- style isn't the overlay badge (the badge lives on the cover itself
    -- and is rendered above, so stacking a bar below it would be
    -- redundant and eat vertical budget).
    if o.show_progress and not use_overlay then
        local pct = tonumber(book.percentage) or 0
        -- Cover→bar gap: 4px at base scale (tighter than the home screen's
        -- 6px because there's no author-descender above the bar here).
        vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        -- Bar width = cover's actual rendered width (after best-fit scaling),
        -- so it lines up perfectly under the visible cover even when the book
        -- cover's aspect ratio differs from the tile box's aspect.
        vg[#vg+1] = _progressBar(pct, actual_w)
    end
    -- Title strip is opt-in per surface.  Default true so callers that
    -- haven't migrated to the show_title opt keep the old behaviour.  When
    -- titles are hidden the cover can absorb the freed tile height (the
    -- caller is responsible for not reserving title_h in tile_h).
    if o.show_title ~= false then
        vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        -- Title uses the full tile width so long titles can wrap/ellipse nicely
        -- across the tile rather than being cramped under a narrower cover.
        -- opts.title_lines lets callers pick 1 (subpage grids) or 2 (carousel);
        -- default is 2 so existing callers that don't set it keep the old behaviour.
        vg[#vg+1] = _titleLabel(book.title, w, title_fs, o.title_lines or 2)
    end

    self.dimen = Geom:new{ w = w, h = h }
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = h },
        vg,
    }

    -- Tap gesture: whole tile tappable.  Each BookTile gets its own dimen
    -- closure — OverlapGroup / HorizontalGroup updates self.dimen.x/y at
    -- paint time, so the range function resolves live.
    self.ges_events = {
        TapBookTile = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.dimen end,
            },
        },
    }
end

function BookTile:onTapBookTile()
    if self.opts and type(self.opts.on_tap) == "function" then
        self.opts.on_tap(self.opts.book)
    end
    return true
end

-- ===========================================================================
-- 6. WIDGET
-- ---------------------------------------------------------------------------
-- Fullscreen landing + subpage navigation.
-- ===========================================================================

local BookFusionTab = InputContainer:extend{
    name               = "bookfusion",
    covers_fullscreen  = true,
    is_borderless      = true,
    disable_double_tap = true,
    -- Hint to UIManager:setDirty that this widget contains cover art. Without
    -- it the initial "ui" refresh uses a bi-level pass and covers look washed
    -- out for up to ~30 s until the next full refresh.
    dithered           = true,
}

function BookFusionTab:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- View state:
    --   _view        : "landing" | "tbr" | "favorites"
    --   _cr_page     : 1-based carousel page (landing)
    --   _grid_page   : 1-based grid page (subpages)
    --   _refreshing  : single-flight guard
    --   _sync_popup  : InfoMessage shown during a manual sync (or nil)
    --   _cover_halt  : halt fn for current in-flight image-loader batch
    self._view      = self._view      or "landing"
    self._cr_page   = self._cr_page   or 1
    self._grid_page = self._grid_page or 1

    -- Title bar — rebuilt on every view change in _rebuildAndRepaint so the
    -- left icon reflects the current mode (search on landing, back arrow on
    -- subpages).  SUI's INJECT_NAMES matches our widget.name and
    -- patchUIManagerShow injects the navbar beneath it.
    self.title_bar = self:_buildTitleBar()
    -- Opt out of sui_titlebar.applyToSub so it leaves our bespoke title bar
    -- alone — otherwise it would slot the search icon into the user's
    -- sub_menu position (typically the right side) and push the sync button
    -- off-screen.
    --
    -- Side effect: sui_titlebar.reapplyAll uses this same flag as its
    -- "needs restyling on size change" criterion. Changing the title-bar
    -- size while the BookFusion tab is open will visibly break the layout
    -- until the tab is closed and reopened. Accepted in exchange for not
    -- monkey-patching sui_titlebar.
    self._titlebar_sub_patched = true

    -- Build the PERSISTENT outer tree once; subsequent rebuilds mutate the
    -- body slot inside `self._body_vg`, so sui_patches' navbar wrap (which
    -- retains a reference to `self[1]` via _navbar_inner) is never torn
    -- down.  Structure:
    --   self[1] = FrameContainer (full screen, white background)
    --     └── self._body_vg = VerticalGroup
    --          ├── [1] = self.title_bar           (fixed)
    --          └── [2] = body widget              (replaced on rebuild)
    self._body_vg    = VerticalGroup:new{ align = "left" }
    self._body_vg[1] = self.title_bar
    self._body_vg[2] = self:_buildBodyContent()
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = sw, h = sh },
        self._body_vg,
    }

    -- Block taps/holds that land in the bottom-bar area so they never reach
    -- our content (same pattern as sui_homescreen).
    local bar_y = sh - self:_navbarH()
    local function _inBar(ges) return ges and ges.pos and ges.pos.y >= bar_y end
    self._inBar = _inBar
    self.ges_events = {
        BookFusionTap = {
            GestureRange:new{ ges = "tap",   range = function() return self.dimen end },
        },
        BookFusionHold = {
            GestureRange:new{ ges = "hold",  range = function() return self.dimen end },
        },
    }
end

-- Navbar height probe — Bottombar.TOTAL_H() from sui_bottombar.  Failure-safe
-- so if the module hasn't loaded yet we conservatively assume 0.
function BookFusionTab:_navbarH()
    local BB = package.loaded["sui_bottombar"]
    if BB and BB.TOTAL_H then
        local ok, h = pcall(BB.TOTAL_H); if ok then return h end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Content builders
-- ---------------------------------------------------------------------------

-- Construct a fresh TitleBar for the current _view. Landing has a "search"
-- left icon; subpages have a back chevron. Title stays "BookFusion"; the
-- subtitle carries navigation context ("Plan to Read", "Search: <query>", …)
-- and is nil on landing so the bar's slot reserved for the subtitle collapses.
function BookFusionTab:_buildTitleBar()
    local on_landing = (self._view == "landing")
    local title = _("BookFusion")
    local subtitle, left_icon, left_cb
    if on_landing then
        subtitle  = nil
        left_icon = "appbar.search"
        left_cb   = function() self:_onLeftIcon() end
    elseif self._view == "tbr" then
        subtitle  = _("Plan to Read")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    elseif self._view == "search" then
        -- Truncate long queries so the subtitle stays single-line; the full
        -- query is preserved in self._search_query for the re-search flow.
        local q = self._search_query or ""
        if #q > 24 then q = q:sub(1, 23) .. "…" end
        subtitle  = string.format(_("Search: %s"), q)
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSearch() end
    else
        subtitle  = _("Favorites")
        left_icon = "chevron.left"
        left_cb   = function() self:_exitSubpage() end
    end
    -- Honor the user's title-bar size setting so BookFusion's icons rescale
    -- in lockstep with the FM and sub-page bars. Lazy pcall in case
    -- sui_titlebar fails to load.
    local icon_scale = 1.0
    do
        local ok, Titlebar = pcall(require, "sui_titlebar")
        if ok and Titlebar and Titlebar.getSizeScale then
            icon_scale = Titlebar.getSizeScale() or 1.0
        end
    end
    local tb = TitleBar:new{
        show_parent              = self,
        fullscreen               = true,
        title                    = title,
        -- Explicit padding matches FileManager's title bar exactly. Without
        -- it, TitleBar's auto-compute baseline-aligns title with icons and
        -- the BookFusion bar ends up shorter than the FM bar.
        title_top_padding        = Screen:scaleBySize(6),
        subtitle                 = subtitle,
        button_padding           = Screen:scaleBySize(5),
        left_icon                = left_icon,
        left_icon_size_ratio     = icon_scale,
        left_icon_tap_callback   = left_cb,
        left_icon_hold_callback  = false,
        right_icon               = "cre.render.reload",
        right_icon_size_ratio    = icon_scale,
        right_icon_tap_callback  = function() self:_onRightIcon() end,
        right_icon_hold_callback = false,
    }
    -- Strip TitleBar's asymmetric tap-zone padding so each button's dimen
    -- becomes a tight icon-size square, matching what sui_titlebar's
    -- _resizeAndStrip does to the FM bar. TitleBar:init seeds
    -- padding_top from button_padding (5 px) and padding_right /
    -- padding_left / padding_bottom from icon_size; leaving those defaults
    -- pushes our icons 5 px lower than the FM's and bloats the hitbox.
    --
    -- Buttons are then pushed 18 px inward from the screen edge via
    -- overlap_offset (matching sui_titlebar's FM placement). Net effect:
    -- the hitbox sits 18 px from the edge, not at the edge with inner pad.
    local edge_pad = Screen:scaleBySize(18)
    local sw       = Screen:getWidth()
    for _, btn in ipairs({ tb.left_button, tb.right_button }) do
        if btn then
            btn.padding_left   = 0
            btn.padding_right  = 0
            btn.padding_bottom = 0
            btn.padding_top    = 0
            if btn.update then btn:update() end
        end
    end
    if tb.left_button then
        tb.left_button.overlap_align  = nil
        tb.left_button.overlap_offset = { edge_pad, 0 }
    end
    if tb.right_button then
        local iw = tb.right_button.width
                or (tb.right_button.image and tb.right_button.image.width)
                or math.floor(Screen:scaleBySize(36) * icon_scale)
        tb.right_button.overlap_align  = nil
        tb.right_button.overlap_offset = { sw - iw - edge_pad, 0 }
    end
    return tb
end

-- Available area under the title bar, above the SUI navbar.  Safe to call
-- during init() because both TitleBar:getSize and UI.getContentHeight are
-- static computations — neither depends on the navbar wrap having happened.
function BookFusionTab:_contentDimen()
    local sw = Screen:getWidth()
    local title_h = self.title_bar and self.title_bar:getSize().h or 0
    -- UI.getContentHeight() = Screen:getHeight() - navbar - (maybe topbar),
    -- so it already accounts for the SUI chrome below us.
    local widget_h = UI.getContentHeight()
    local body_h = widget_h - title_h
    return sw, title_h, body_h
end

-- Builds just the body widget (no title bar, no outer frame) — what we swap
-- into the stable `self._body_vg[2]` slot on state change.
function BookFusionTab:_buildBodyContent()
    local sw, _title_h, body_h = self:_contentDimen()

    if not Data.isAvailable() then
        return self:_buildEmptyState(sw, body_h,
            _("BookFusion plugin is not installed."),
            _("Install it from the KOReader plugins directory to enable this tab."),
            nil)
    elseif not Data.isLinked() then
        return self:_buildEmptyState(sw, body_h,
            _("Not linked yet."),
            _("Link your BookFusion account to see your library here."),
            { label = _("Link device"), callback = function() Data.startLink() end })
    elseif self._view == "landing" then
        return self:_buildLanding(sw, body_h)
    else
        return self:_buildSubpage(sw, body_h)
    end
end

-- Empty-state panel used for "plugin not installed" / "not linked".
function BookFusionTab:_buildEmptyState(sw, content_h, title, sub, action)
    local inner_w = sw - 2 * UI.SIDE_PAD
    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = VerticalSpan:new{ width = math.floor(content_h * 0.25) }
    vg[#vg+1] = TextBoxWidget:new{
        text = title, face = Font:getFace("cfont", Screen:scaleBySize(14)),
        width = inner_w, alignment = "center", bold = true,
    }
    vg[#vg+1] = VerticalSpan:new{ width = UI.PAD }
    vg[#vg+1] = TextBoxWidget:new{
        text = sub, face = Font:getFace("cfont", Screen:scaleBySize(11)),
        width = inner_w, alignment = "center",
    }
    if action then
        vg[#vg+1] = VerticalSpan:new{ width = UI.MOD_GAP }
        vg[#vg+1] = Button:new{
            text = action.label,
            width = math.floor(inner_w * 0.6),
            callback = action.callback,
        }
    end
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = sw, h = content_h },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = content_h },
            vg,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Landing page: Currently Reading carousel + TBR / Favorites buttons.
-- ---------------------------------------------------------------------------
function BookFusionTab:_buildLanding(sw, content_h)
    local inner_w  = sw - 2 * UI.SIDE_PAD
    -- text_scale → cover title under each BookTile (content text).
    -- label_scale → section headings, nav buttons, empty-state copy
    -- (chrome text).  Kept separate because the user reasonably wants
    -- fine-grained control — e.g. big folder buttons with compact titles.
    local txt_sc      = Settings.textScaleCarousel()
    local lbl_sc      = Settings.labelScale()
    -- Per-surface visibility — each one lets the cover grow to absorb the
    -- freed vertical space (see tile_h computation below).
    local show_title  = Settings.showCarouselTitle()
    local show_progr  = Settings.showCarouselProgress()
    local show_pager  = Settings.showCarouselPager()
    local progr_style = Settings.progressStyleCarousel()
    -- Download indicator is only applied per-book inside the tile loop —
    -- the per-book check is an lfs.attributes call (cheap but not free),
    -- so hoist the global setting once and skip the call if it's off.
    local dl_ind_on   = Settings.showDownloadIndicators()
    local use_overlay = show_progr and progr_style == "overlay"
    -- Carousel uses its own cover-scale knob; cr_cols is derived from it
    -- further down (after we know carousel_inner_w and tile_gap).  Smaller
    -- scale → more covers per row; larger scale → fewer.
    local cov_sc   = Settings.coverScaleCarousel()

    -- Section label — bold + small + mid-gray.  Small enough not to compete
    -- with the covers, bold enough to read as a hierarchy signpost.
    local section_fs = math.max(6, math.floor(Screen:scaleBySize(7) * lbl_sc))
    local button_fs  = math.max(7, math.floor(Screen:scaleBySize(8) * lbl_sc))

    -- Fixed-height elements on the landing (top-down).  Used to compute
    -- carousel cover height so the page never needs scrolling.
    local section_lbl_h   = Screen:scaleBySize(10) + UI.PAD2
    local pre_section_gap = UI.PAD        -- gap between a heading and its content
    local button_h        = Screen:scaleBySize(36)
    -- tile_text_h must accommodate the actual 2-line rendered height of the
    -- title TextBoxWidget, which depends on face.size (double-scaled on hi-DPI
    -- devices via Font:getFace).  Compute it from the same face the tile will
    -- use so the budget stays accurate on every device.  When the title is
    -- hidden we reserve zero, freeing that height for the cover.
    local tile_text_h = 0
    if show_title then
        local _tile_title_fs   = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))
        local _tile_title_face = Font:getFace("cfont", _tile_title_fs)
        local _tile_title_lh   = math.floor((1 + 0.3) * _tile_title_face.size + 0.5)
        tile_text_h            = _tile_title_lh * 2 + Screen:scaleBySize(3)  -- 2 lines + rounding margin
    end
    local top_pad         = UI.PAD
    local between_sections = UI.MOD_GAP   -- gap between CR row and Folders heading
    local bot_pad         = UI.PAD

    -- Arrow width + gap from the carousel.
    local arrow_w   = Screen:scaleBySize(36)
    -- Horizontal gap between arrow and cover: match the outer gap between
    -- arrow and screen edge (UI.SIDE_PAD) so each arrow sits dead-centre in
    -- the corridor between the frame edge and the first/last cover.
    local arrow_gap = UI.SIDE_PAD
    local carousel_inner_w = inner_w - 2 * (arrow_w + arrow_gap)

    -- Tile width from cols.  cr_cols is derived from the carousel cover
    -- scale: we pick a "natural" tile width (carousel divided into 3
    -- columns — matches the old default of cr_cols=3 at scale=100%), then
    -- scale it by cov_sc to get the user's desired tile width, and fit as
    -- many of those as the available carousel width allows (minimum 1).
    --
    -- Computed early (before tile_pct_h / cover_budget) because the
    -- overlay-badge reserve depends on tile_w.
    local tile_gap        = UI.PAD2
    local min_tile_gap    = tile_gap  -- honour the minimum we picked above
    local natural_tile_w  = math.floor((carousel_inner_w - 2 * min_tile_gap) / 3)
    local target_tile_w   = math.max(1, math.floor(natural_tile_w * cov_sc))
    local cr_cols         = math.max(1,
                              math.floor((carousel_inner_w + min_tile_gap) / (target_tile_w + min_tile_gap)))
    local tile_w          = target_tile_w
    -- Distribute leftover width as the inter-cover gap.  With the cr_cols
    -- formula above, the leftover is always ≥ (cr_cols - 1) * min_tile_gap,
    -- so `tile_gap` is guaranteed ≥ min_tile_gap.  When cr_cols == 1 the
    -- LeftContainer/CenterContainer below handles positioning; tile_gap is
    -- unused.
    if cr_cols > 1 then
        local slack = carousel_inner_w - cr_cols * tile_w
        tile_gap    = math.max(min_tile_gap, math.floor(slack / (cr_cols - 1)))
    end

    -- Progress-indicator reserve:
    --   hidden  → 0 (cover takes the space).
    --   bar     → 7 px bar + 4 px cover→bar gap ≈ 11 px at base scale.
    --   overlay → bottom half of the badge bleeds below the cover
    --             (badge_r from the shared _overlayBadgeDims helper,
    --             so we stay byte-identical with what BookTile ends up
    --             rendering) plus 4 px breath so the title doesn't sit
    --             on the badge's arc.
    local tile_pct_h = 0
    if show_progr then
        if progr_style == "overlay" then
            local _, badge_r = _overlayBadgeDims(txt_sc)
            tile_pct_h = badge_r + Screen:scaleBySize(4)
        else
            tile_pct_h = Screen:scaleBySize(11)
        end
    end
    -- Carousel pager label ("1 / 2", mid-grey): small gap above to
    -- separate it from the book titles, very small gap below so it sits
    -- close to the Folders heading (the pager itself acts as the section
    -- separator — between_sections is skipped in the render path below).
    local cr_pager_fs        = math.max(6, math.floor(Screen:scaleBySize(7) * lbl_sc))
    local cr_pager_gap_above = Screen:scaleBySize(6)
    local cr_pager_gap_below = Screen:scaleBySize(2)
    local cr_pager_line_h    = 0
    local cr_pager_h         = 0
    if show_pager then
        -- Line-height formula matches TextBoxWidget's internal one so the
        -- reserve tracks what the widget actually paints.
        local _cr_pager_face = Font:getFace("cfont", cr_pager_fs)
        cr_pager_line_h = math.floor((1 + 0.3) * _cr_pager_face.size + 0.5)
        cr_pager_h      = cr_pager_gap_above + cr_pager_line_h + cr_pager_gap_below
    end

    -- Carousel sizing is natural (not stretched): cover height capped at a
    -- 1.55 aspect ratio AND at whatever the height budget can spare.
    -- Any extra vertical space flows to the bottom pad instead of inflating
    -- the covers, so Folders sits right under its heading.
    --
    -- CR→Folders separator: when the pager is shown, it IS the separator
    -- (cr_pager_h includes its own above/below gaps). When hidden, use a
    -- small fixed gap — full between_sections would look identical to
    -- leaving the pager on (text replaced by equivalent empty space).
    local cr_pager_off_gap  = Screen:scaleBySize(15)
    local cr_to_folders_gap = show_pager and cr_pager_h or cr_pager_off_gap
    local reserved = top_pad
                   + section_lbl_h + pre_section_gap + Screen:scaleBySize(6) -- CR heading (extra breathing room before covers)
                   + tile_text_h + tile_pct_h + Screen:scaleBySize(8) -- tile extras
                   + cr_to_folders_gap                                -- pager OR between_sections
                   + section_lbl_h + pre_section_gap                  -- Folders heading
                   + 3 * button_h + 2 * math.floor(UI.PAD / 2)        -- 3 nav buttons + 2 half-PAD gaps
                   + bot_pad
    local cover_budget = content_h - reserved
    -- Preserve book aspect (1.55) even when the vertical budget is tight:
    -- if cover_w × 1.55 exceeds the budget, shrink cover_w to keep the
    -- display box proportional.  Without this, uniform-cover mode would
    -- scale-to-fill and crop the top/bottom of every cover on
    -- short-height screens.
    local cover_w, cover_h
    if cover_budget < math.floor(tile_w * 1.55) then
        cover_h = cover_budget
        cover_w = math.floor(cover_h / 1.55)
    else
        cover_w = tile_w
        cover_h = math.floor(cover_w * 1.55)
    end
    -- Clamp both dimensions and recompute width from the clamped height so
    -- the aspect stays consistent. Without this, cover_budget can go ≤ 0
    -- on small screens / large text scales, leaving cover_w ≤ 0 even
    -- after the cover_h floor — which propagates into BookTile/Geom.
    local cover_min = Screen:scaleBySize(60)
    if cover_h < cover_min then
        cover_h = cover_min
        cover_w = math.max(1, math.floor(cover_h / 1.55))
    end
    local tile_h = cover_h + tile_text_h + tile_pct_h + Screen:scaleBySize(8)

    -- Current-reading books from cache.
    local cr_slot = Cache.get("currently_reading")
    local cr_books = (cr_slot and cr_slot.books) or {}

    -- Pagination for carousel.
    local total_pages = math.max(1, math.ceil(#cr_books / cr_cols))
    if self._cr_page > total_pages then self._cr_page = total_pages end
    if self._cr_page < 1 then self._cr_page = 1 end

    local start_idx = (self._cr_page - 1) * cr_cols + 1
    local end_idx   = math.min(#cr_books, start_idx + cr_cols - 1)
    local visible   = end_idx - start_idx + 1

    -- Build tiles for the current page.
    local tiles = HorizontalGroup:new{ align = "top" }
    for i = start_idx, end_idx do
        if i > start_idx then
            tiles[#tiles+1] = HorizontalSpan:new{ width = tile_gap }
        end
        local book_i = cr_books[i]
        tiles[#tiles+1] = BookTile:new{
            opts = {
                book              = book_i,
                w                 = tile_w,
                h                 = tile_h,
                cover_w           = cover_w,   -- explicit so cov_sc scales width too
                cover_h           = cover_h,
                show_progress     = show_progr,
                progress_style    = progr_style,
                show_title        = show_title,
                text_scale        = txt_sc,
                show_dl_indicator = dl_ind_on and not Data.isDownloaded(book_i),
                on_tap            = function(b)
                    Data.selectBook(b, function()
                        -- File tree changed (download / remove) —
                        -- rebuild so the cloud indicator catches up.
                        if not self._closed then self:_rebuildAndRepaint() end
                    end)
                end,
            },
        }
    end

    -- Alignment: full row centred, partial row left-aligned.
    local carousel_body
    if visible == cr_cols then
        carousel_body = CenterContainer:new{
            dimen = Geom:new{ w = carousel_inner_w, h = tile_h },
            tiles,
        }
    else
        carousel_body = LeftContainer:new{
            dimen = Geom:new{ w = carousel_inner_w, h = tile_h },
            tiles,
        }
    end

    -- Arrow buttons — native IconButton with default flash on tap.
    -- Vertical placement: we want the icon slightly BELOW the midline of
    -- (cover + progress bar), not the tile centre.  Wrapping the arrow in
    -- a CenterContainer of height = cover_h + cover→bar gap + bar_h +
    -- small nudge centres the icon within that region; the nudge puts it a
    -- few px below the true midline.  The HorizontalGroup below uses
    -- align="top" so each arrow's CenterContainer starts at the same y as
    -- the covers (y=0 of the carousel row), not vertically centred against
    -- the full tile height.
    local cover_bar_nudge = Screen:scaleBySize(8)   -- lower than pure centre
    local arrow_box_h = cover_h + Screen:scaleBySize(4) + BAR_BASE_H + cover_bar_nudge
    local function _arrow(icon, enabled, cb)
        local inner
        if enabled then
            inner = IconButton:new{
                icon        = icon,
                width       = arrow_w,
                height      = arrow_w,
                padding     = 0,
                callback    = cb,
                show_parent = self,
            }
        else
            -- Keep the column width so the carousel stays horizontally
            -- balanced when we're at the first / last page.
            inner = HorizontalSpan:new{ width = arrow_w }
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = arrow_w, h = arrow_box_h },
            inner,
        }
    end
    local left_arrow  = _arrow("chevron.left",  self._cr_page > 1,          function() self:_cycleCarousel(-1) end)
    local right_arrow = _arrow("chevron.right", self._cr_page < total_pages, function() self:_cycleCarousel( 1) end)

    -- align = "top" anchors every child at y=0 of the row, so each arrow's
    -- CenterContainer establishes its own cover-aligned vertical frame.
    local carousel_row = HorizontalGroup:new{ align = "top",
        left_arrow,
        HorizontalSpan:new{ width = arrow_gap },
        carousel_body,
        HorizontalSpan:new{ width = arrow_gap },
        right_arrow,
    }

    -- Section label — bold + small + mid-grey.  Used for both
    -- "Currently Reading" and "Folders" so they read as peers.
    local SECTION_GRAY = Blitbuffer.gray(0.45)
    local function _sectionLabel(text)
        return LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = section_lbl_h },
            TextWidget:new{
                text    = text,
                face    = Font:getFace("cfont", section_fs),
                bold    = true,
                fgcolor = SECTION_GRAY,
            },
        }
    end
    -- Borderless, left-aligned label + chevron, no left pad so the label
    -- sits flush with the page's content column.
    --
    -- Square tap feedback recipe: pass radius=0 AND no background. Button's
    -- init / flash routines only re-round corners when a background is set
    -- or radius is nil; this combination keeps the invert-flash square.
    local function _navButton(label, on_tap)
        return Button:new{
            text           = label .. " ›",
            align          = "left",
            width          = inner_w,
            height         = button_h,
            text_font_size = button_fs,
            text_font_bold = true,
            bordersize     = 0,
            radius         = 0,  -- keeps tap-feedback flash square
            padding_h      = Screen:scaleBySize(4),
            padding_v      = Screen:scaleBySize(4),
            callback       = on_tap,
        }
    end

    -- Build the page layout.
    --
    -- Structure:
    --   top_pad
    --   "Currently Reading"   (heading)
    --   pre_section_gap
    --   carousel              (covers + progress + title)
    --   between_sections
    --   "Folders"             (heading)
    --   pre_section_gap
    --   [ Plan to Read  › ]
    --   UI.PAD
    --   [ Favorites   › ]
    --   bot_pad
    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = top_pad }
    vg[#vg+1] = _sectionLabel(_("Currently Reading"))
    -- A touch more breathing room than the generic pre_section_gap so the
    -- covers don't feel crammed under the heading.  Folders still uses
    -- pre_section_gap below to keep its buttons close to its heading.
    vg[#vg+1] = VerticalSpan:new{ width = pre_section_gap + Screen:scaleBySize(6) }
    if #cr_books == 0 then
        -- First-time / after-clear-cache state.  We don't auto-sync (the tab
        -- is fully offline by spec), so nudge the user toward the refresh
        -- icon instead of showing a dead "No books" string.  A sync in
        -- progress is surfaced via the InfoMessage popup from _refreshLists,
        -- not an inline label.
        local empty_text
        if Cache.get("currently_reading") == nil then
            empty_text = _("Tap ↻ to sync your BookFusion library.")
        else
            empty_text = _("No books in this list.")
        end
        vg[#vg+1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            TextBoxWidget:new{
                text = empty_text,
                face = Font:getFace("cfont",
                    math.max(10, math.floor(Screen:scaleBySize(11) * lbl_sc))),
                width = inner_w,
            },
        }
    else
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            carousel_row,
        }
    end
    -- Carousel pager: same style as the folder pager — subdued mid-grey
    -- "X / Y" centred horizontally, sized by lbl_sc.  When shown, it
    -- acts as the section separator between Currently Reading and
    -- Folders; between_sections is skipped.  Tight layout:
    --   cr_pager_gap_above  — small breath above pager
    --   cr_pager_line_h     — the text itself
    --   cr_pager_gap_below  — very small breath below pager
    -- Total (cr_pager_h) was already reserved in `cr_to_folders_gap`.
    if show_pager then
        vg[#vg+1] = VerticalSpan:new{ width = cr_pager_gap_above }
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = cr_pager_line_h },
            TextWidget:new{
                text    = string.format("%d / %d", self._cr_page, total_pages),
                face    = Font:getFace("cfont", cr_pager_fs),
                fgcolor = Blitbuffer.gray(0.45),
            },
        }
        vg[#vg+1] = VerticalSpan:new{ width = cr_pager_gap_below }
    else
        vg[#vg+1] = VerticalSpan:new{ width = cr_pager_off_gap }
    end
    vg[#vg+1] = _sectionLabel(_("Folders"))
    vg[#vg+1] = VerticalSpan:new{ width = pre_section_gap }
    -- Half-PAD gap between folder buttons — just enough visual breathing
    -- room without making the section feel disconnected.
    local folder_gap = math.floor(UI.PAD / 2)
    vg[#vg+1] = _navButton(_("Plan to Read"),        function() self:_enterSubpage("tbr")       end)
    vg[#vg+1] = VerticalSpan:new{ width = folder_gap }
    vg[#vg+1] = _navButton(_("Favorites"),         function() self:_enterSubpage("favorites") end)
    vg[#vg+1] = VerticalSpan:new{ width = folder_gap }
    -- "Browse BookFusion" hands off to the BF plugin's own Menu widget
    -- (onSearchBooks), which lists every bookshelf + collection.  This is
    -- the escape hatch for anything outside the three cached lists above.
    vg[#vg+1] = _navButton(_("Browse BookFusion"), function() Data.openBrowser() end)
    vg[#vg+1] = VerticalSpan:new{ width = bot_pad }

    -- Apply side-padding frame and clamp to content height.
    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = UI.SIDE_PAD, padding_right = UI.SIDE_PAD,
        padding_top = 0, padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = content_h },
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Subpage: TBR / Favorites grid (covers + names, no progress).
-- ---------------------------------------------------------------------------
function BookFusionTab:_buildSubpage(sw, content_h)
    local inner_w   = sw - 2 * UI.SIDE_PAD
    -- text_scale → cover titles; label_scale → pager "1 / 3" + empty-state
    -- copy ("No books…", "Searching…").  See _buildLanding for the split.
    local txt_sc    = Settings.textScaleFolder()
    local lbl_sc    = Settings.labelScale()
    local show_title = Settings.showFolderTitle()
    -- No cover-scale knob on this surface: grid_rows × grid_cols + screen
    -- dimensions fully determine tile size.  The user can already make
    -- covers bigger/smaller by changing grid_rows or grid_cols.
    -- Grid geometry is now fully driven by settings: fixed `rows × cols`
    -- per page, cover dimensions derived so the whole grid exactly fills
    -- the available area.  Defaults are 2 rows × 4 cols = 8 covers per
    -- page; both are clamped to 1..6 by the setting readers.
    local grid_cols = Settings.gridCols()
    local rows      = Settings.gridRows()
    -- Download indicator: global toggle gates everything; the search
    -- setting is a separate check that only applies in search view.
    -- See _buildLanding for the same pattern (cached once, lfs check
    -- happens inside the per-tile loop below).
    local dl_ind_on = Settings.showDownloadIndicators()
        and (self._view ~= "search" or Settings.showDownloadIndicatorsSearch())

    -- Pager bar (prev / page / next) pinned at the bottom of the subpage.
    -- The subpage's title + back arrow live in the main TitleBar now, so
    -- there's no sub-header eating vertical space here.
    local pager_h = Screen:scaleBySize(32)

    -- Book source depends on the view:
    --   • tbr / favorites : pulled from the on-disk Cache (offline reads).
    --   • search          : in-memory self._search_results, appended to by
    --                       _fetchNextSearchPage as the user pages past what
    --                       we've buffered.  `books_total` is the authoritative
    --                       pager total — for cached lists it equals #books,
    --                       for search it comes from the API's total-count
    --                       header (self._search_total) so the pager shows
    --                       a correct "N / M" from the first render onward.
    local books, books_total
    if self._view == "search" then
        books       = self._search_results or {}
        books_total = math.max(self._search_total or 0, #books)
    elseif self._view == "tbr" then
        local slot  = Cache.get("planned_to_read"); books = (slot and slot.books) or {}
        books_total = #books
    else
        local slot  = Cache.get("favorites");       books = (slot and slot.books) or {}
        books_total = #books
    end

    -- Vertical paddings used both to size the grid area and to position
    -- the pager later on (see VG assembly below).  Declared once here so
    -- there's a single source of truth.  `pager_top_pad` is the minimum
    -- breathing room between the last row of covers and the pager label —
    -- visible mostly when titles are hidden and the grid grows to absorb
    -- the freed space.  We reserve it in grid_h so the grid can't
    -- encroach on it.
    local top_pad       = Screen:scaleBySize(12)
    local bot_pad       = Screen:scaleBySize(12)
    local pager_top_pad = Screen:scaleBySize(8)
    local grid_h  = content_h - top_pad - pager_top_pad - pager_h - bot_pad

    -- Unified horizontal padding: the gap between covers matches the gap
    -- between the outermost covers and the screen edge (the FrameContainer
    -- at the bottom of this function uses padding_left/right = UI.SIDE_PAD).
    local tile_gap = UI.SIDE_PAD
    local row_gap  = UI.PAD

    -- Subpage tiles show a 1-line title when enabled.  Reserve just one
    -- actual line of the rendered face height (same formula as
    -- _titleLabel uses) plus a few px of rounding margin.  When titles
    -- are hidden, reserve zero and drop the cover→title gap — the freed
    -- height flows into the cover.
    local title_h_reserve, cover_title_gap = 0, 0
    if show_title then
        local _sub_title_fs   = math.max(6, math.floor(Screen:scaleBySize(6) * txt_sc))
        local _sub_title_face = Font:getFace("cfont", _sub_title_fs)
        local _sub_title_lh   = math.floor((1 + 0.3) * _sub_title_face.size + 0.5)
        title_h_reserve       = _sub_title_lh + Screen:scaleBySize(3)
        cover_title_gap       = Screen:scaleBySize(4)
    end

    -- Tile dimensions derived purely from the configured rows × cols +
    -- screen geometry — no user scale knob on this surface.  Fit the
    -- cover inside tile_w × cover_h_budget while preserving the 1.5
    -- book aspect: if the vertical budget can't hold the full-width
    -- cover, shrink the cover WIDTH too instead of squashing the height.
    -- Otherwise uniform-cover mode's scale-to-fill crops the top/bottom
    -- of every cover in tight grids (many rows).
    local tile_w         = math.floor((inner_w - (grid_cols - 1) * tile_gap) / grid_cols)
    local tile_budget_h  = math.floor((grid_h - (rows - 1) * row_gap) / rows)
    local cover_h_budget = tile_budget_h - title_h_reserve - cover_title_gap
    local cover_w, cover_h
    if cover_h_budget < math.floor(tile_w * 1.5) then
        -- Height-limited: shrink width to match 1.5 aspect.
        cover_h = cover_h_budget
        cover_w = math.floor(cover_h / 1.5)
    else
        -- Width-limited: fill tile horizontally, height follows aspect.
        cover_w = tile_w
        cover_h = math.floor(cover_w * 1.5)
    end
    -- Clamp both dimensions and recompute width from the clamped height
    -- (cover_h_budget can be ≤ 0 with many rows/cols on a short screen).
    local cover_min = Screen:scaleBySize(60)
    if cover_h < cover_min then
        cover_h = cover_min
        cover_w = math.max(1, math.floor(cover_h / 1.5))
    end
    local tile_h  = cover_h + cover_title_gap + title_h_reserve
    local per_page = rows * grid_cols

    local total_pages = math.max(1, math.ceil(books_total / per_page))
    if self._grid_page > total_pages then self._grid_page = total_pages end
    if self._grid_page < 1 then self._grid_page = 1 end

    local start_idx = (self._grid_page - 1) * per_page + 1
    -- end_idx uses #books (not books_total) — the search view may declare
    -- more total pages than it has buffered right now, and we can only
    -- render books we actually have.  _cyclePage triggers a fetch before
    -- showing a page that would otherwise be empty.
    local end_idx   = math.min(#books, start_idx + per_page - 1)

    -- Build grid rows.
    local grid = VerticalGroup:new{ align = "left" }
    local i = start_idx
    local placed = 0
    while i <= end_idx do
        local row_end = math.min(end_idx, i + grid_cols - 1)
        local row = HorizontalGroup:new{ align = "top" }
        for j = i, row_end do
            if j > i then row[#row+1] = HorizontalSpan:new{ width = tile_gap } end
            local book_j = books[j]
            row[#row+1] = BookTile:new{
                opts = {
                    book              = book_j,
                    w                 = tile_w,
                    h                 = tile_h,
                    cover_w           = cover_w,
                    cover_h           = cover_h,
                    show_progress     = false,      -- subpages omit progress per spec
                    show_title        = show_title, -- folder-title visibility toggle
                    title_lines       = 1,          -- single-line titles on subpages
                    text_scale        = txt_sc,
                    show_dl_indicator = dl_ind_on and not Data.isDownloaded(book_j),
                    on_tap            = function(b)
                        Data.selectBook(b, function()
                            if not self._closed then self:_rebuildAndRepaint() end
                        end)
                    end,
                },
            }
        end
        -- Pad partial last row so left-alignment looks intentional.
        grid[#grid+1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = tile_h },
            row,
        }
        i = row_end + 1
        placed = placed + 1
        if placed < rows and i <= end_idx then
            grid[#grid+1] = VerticalSpan:new{ width = row_gap }
        end
    end
    if #grid == 0 then
        -- Empty-state copy differs by view.  During the first search fetch
        -- (no results yet AND no completed API page) we say "Searching…"
        -- so the user gets immediate feedback even if the "Searching…"
        -- InfoMessage popup fired too quickly to notice.
        local empty_text
        if self._view == "search" then
            if self._search_fetching or self._search_api_page == 0 then
                empty_text = _("Searching…")
            else
                empty_text = _("No books match your search.")
            end
        else
            empty_text = _("No books in this list.")
        end
        -- TextBoxWidget straight into the grid VG (no LeftContainer wrapper):
        -- LeftContainer would vertically center its child to tile_h, pushing
        -- "Searching…" to the middle of the first tile row.
        grid[#grid+1] = TextBoxWidget:new{
            text  = empty_text,
            face  = Font:getFace("cfont",
                math.max(10, math.floor(Screen:scaleBySize(11) * lbl_sc))),
            width = inner_w,
        }
    end

    -- Pager: subdued "X/Y" centred, arrows pinned to the edges.
    -- OverlapGroup lets each child anchor independently (left / center /
    -- right via overlap_align) inside the same footprint.  Each child is
    -- then wrapped in a CenterContainer of the same height as the pager
    -- so overlap_align (horizontal) + CenterContainer (vertical) combine
    -- into a proper 2-axis anchoring.
    local arrow_sz = Screen:scaleBySize(30)
    local function _pagerArrow(icon, enabled, cb, side)
        local inner
        if enabled then
            inner = IconButton:new{
                icon        = icon,
                width       = arrow_sz,
                height      = arrow_sz,
                padding     = 0,
                callback    = cb,
                show_parent = self,
            }
        else
            -- Keep the footprint so the text stays centred even at the edges.
            inner = HorizontalSpan:new{ width = arrow_sz }
        end
        return CenterContainer:new{
            dimen         = Geom:new{ w = arrow_sz, h = pager_h },
            overlap_align = side,
            inner,
        }
    end
    local pager_fs = math.max(6, math.floor(Screen:scaleBySize(7) * lbl_sc))
    local pager_label = TextWidget:new{
        text    = string.format("%d / %d", self._grid_page, total_pages),
        face    = Font:getFace("cfont", pager_fs),
        fgcolor = Blitbuffer.gray(0.45),   -- subtle mid-grey
    }
    local pager = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = pager_h },
        _pagerArrow("chevron.left",  self._grid_page > 1,           function() self:_cyclePage(-1) end, "left"),
        CenterContainer:new{
            dimen         = Geom:new{ w = inner_w, h = pager_h },
            overlap_align = "center",
            pager_label,
        },
        _pagerArrow("chevron.right", self._grid_page < total_pages, function() self:_cyclePage( 1) end, "right"),
    }

    -- Layout: grid at top (with top_pad clearing the title-bar icon tap
    -- zones), then a flexible VerticalSpan that absorbs whatever vertical
    -- slack is left, then the pager pinned near the content-area bottom
    -- with its own trailing pad.
    --
    -- The flex_pad must be computed from the **actual** rows we placed
    -- (variable `placed` from the build loop above), not the `rows`
    -- budget — otherwise a short last page (e.g. only 1 row of books) is
    -- measured as if it had `rows` full rows, so flex_pad underestimates
    -- the slack and the pager floats well above the bottom.  top_pad /
    -- bot_pad were defined at the top of this function.
    local grid_h_actual = placed * tile_h + math.max(0, placed - 1) * row_gap
    local used_h = top_pad + grid_h_actual + pager_h + bot_pad
    -- Minimum gap between the last row of covers and the pager = the
    -- pager_top_pad budget we reserved above.  When there's genuine slack
    -- (e.g. a short last page) flex_pad grows to push the pager down.
    local flex_pad = math.max(pager_top_pad, content_h - used_h)

    local vg = VerticalGroup:new{ align = "left" }
    vg[#vg+1] = VerticalSpan:new{ width = top_pad }
    vg[#vg+1] = grid
    vg[#vg+1] = VerticalSpan:new{ width = flex_pad }
    vg[#vg+1] = pager
    vg[#vg+1] = VerticalSpan:new{ width = bot_pad }

    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = UI.SIDE_PAD, padding_right = UI.SIDE_PAD,
        padding_top = 0, padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = content_h },
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- State transitions + repaint
-- ---------------------------------------------------------------------------

function BookFusionTab:_rebuildAndRepaint()
    -- Mutate both VG slots in place so sui_patches' navbar wrap (which holds
    -- a reference to our FrameContainer via _navbar_inner) stays intact.
    -- Rebuilding the title bar here also swaps the left icon (search ↔ back)
    -- on view transitions.
    if self._body_vg then
        local new_tb = self:_buildTitleBar()
        self.title_bar    = new_tb
        self._body_vg[1]  = new_tb
        self._body_vg[2]  = self:_buildBodyContent()
        -- VerticalGroup caches sizes and child offsets on first getSize().
        -- Without resetLayout(), in-place slot mutation leaves the cached
        -- offsets pointing at the previous children — since the title bar
        -- changes height between landing (no subtitle) and subpages (with
        -- subtitle), paint draws the new body at the old title bar's y,
        -- yielding a top overlap and a bottom gap.
        self._body_vg:resetLayout()
    end
    -- Dithering hint for e-ink refreshes — UIManager checks widget.dithered
    -- on setDirty and routes the repaint through a dithered mode. Without
    -- it the first paint after a cover lands uses a bi-level refresh that
    -- crushes photo tonality until the next full refresh ~30 s later.
    self.dithered = true
    UIManager:setDirty(self, "ui", nil, true)
end

function BookFusionTab:_cycleCarousel(delta)
    self._cr_page = self._cr_page + delta
    self:_rebuildAndRepaint()
end

function BookFusionTab:_cyclePage(delta)
    local new_page = self._grid_page + delta

    -- In the search view, tapping › past the last fully-buffered display
    -- page needs an API round-trip.  Buffer only as much as the user has
    -- navigated to — no speculative prefetch.
    if self._view == "search" and delta > 0 then
        local per_page = Settings.gridRows() * Settings.gridCols()
        local needed   = new_page * per_page
        local have     = self._search_results and #self._search_results or 0
        local server_total = self._search_total or 0
        if have < needed and (server_total == 0 or have < server_total) then
            -- Fetch another API page, then advance, repaint, and queue
            -- cover downloads for the newly-visible books.
            NetworkMgr:runWhenOnline(function()
                if self._closed or self._view ~= "search" then return end
                self:_fetchNextSearchPage(function()
                    if self._closed or self._view ~= "search" then return end
                    self._grid_page = new_page
                    self:_rebuildAndRepaint()
                    self:_prefetchVisibleCovers()
                end)
            end)
            return
        end
    end

    self._grid_page = new_page
    self:_rebuildAndRepaint()
end

function BookFusionTab:_enterSubpage(which)
    self._view = which
    self._grid_page = 1
    -- Offline by design: render from disk cache only.  Covers that haven't
    -- been downloaded yet show the typographic placeholder; tapping ↻
    -- while on this subpage is how the user opts in to fetching them.
    self:_rebuildAndRepaint()
end

function BookFusionTab:_exitSubpage()
    self._view = "landing"
    self:_rebuildAndRepaint()
end

-- ---------------------------------------------------------------------------
-- In-place search
-- ---------------------------------------------------------------------------
-- User-initiated and session-scoped (search inherently can't be offline —
-- it's the one place in the tab that ALWAYS hits the network, by design):
--   • An API call only fires when the user explicitly submits a query
--     (no auto-search on tab open, no live-as-you-type debounce).
--   • Results live in self._search_results (module-local Lua array).
--   • No Cache.put — nothing persists across the tab's lifetime; a fresh
--     query always pulls fresh data from the server.
--   • Each API call fetches a page sized to the display grid (see
--     Settings.searchFetchSize) so the buffer always ends on a whole
--     display-page boundary.
--   • total_display_pages comes from the API's total-count header on the
--     FIRST response — the pager shows a correct "N / M" immediately, no
--     "+" suffix or later renumbering.
--   • Additional API pages are fetched on-demand when the user taps › past
--     what's currently buffered.

function BookFusionTab:_showSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title   = _("Search BookFusion"),
        input   = self._search_query or "",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id   = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText() or ""
                        q = q:gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(dialog)
                        if q == "" then return end
                        self:_enterSearch(q)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookFusionTab:_enterSearch(query)
    -- Reset session state.
    self._search_query        = query
    self._search_results      = {}
    self._search_total        = 0
    self._search_api_page     = 0   -- 0 = nothing fetched yet
    self._search_api_per_page = Settings.searchFetchSize(
        Settings.gridRows() * Settings.gridCols())
    self._search_fetching     = nil
    self._grid_page           = 1

    -- Show the view immediately (empty-state "Searching…" branch) so the
    -- title bar swap is visible before network kicks in.
    self._view = "search"
    self:_rebuildAndRepaint()

    -- Kick the first API fetch (deferred so the rebuild paints first).
    NetworkMgr:runWhenOnline(function()
        if self._closed or self._view ~= "search" then return end
        self:_fetchNextSearchPage(function()
            if self._closed or self._view ~= "search" then return end
            self:_rebuildAndRepaint()
            self:_prefetchVisibleCovers()
        end)
    end)
end

function BookFusionTab:_fetchNextSearchPage(on_done)
    if self._search_fetching then return end
    if not self._search_query or self._search_query == "" then return end
    -- Stop if we've already fetched everything the server has.
    if self._search_total > 0 and #self._search_results >= self._search_total then
        if on_done then on_done() end
        return
    end
    self._search_fetching = true

    local InfoMessage = require("ui/widget/infomessage")
    local popup = InfoMessage:new{ text = _("Searching…"), timeout = 0 }
    self._search_popup = popup
    UIManager:show(popup)

    local next_api_page = self._search_api_page + 1
    Data.searchPage(self._search_query, next_api_page,
        self._search_api_per_page, function(ok, books, pagination)
        self._search_fetching = false
        if self._search_popup then
            pcall(function() UIManager:close(self._search_popup) end)
            self._search_popup = nil
        end
        if self._closed or self._view ~= "search" then return end
        if not ok or type(books) ~= "table" then
            logger.warn("simpleui-bf: search fetch failed:", tostring(books))
            UIManager:show(InfoMessage:new{
                text    = _("Couldn't search BookFusion."),
                timeout = 3,
            })
            if on_done then on_done() end
            return
        end
        -- Flatten each raw API book into the same slim shape Cache.put
        -- stores for the cached lists (nested `cover = {url, width, height}`
        -- → flat cover_url / cover_w / cover_h).  BookTile + Covers.getBB
        -- expect the flat shape; without this, every search result rendered
        -- as a placeholder because cover_url was always nil.
        for i = 1, #books do
            local b = books[i]
            if type(b) == "table" and b.id then
                local cover = b.cover
                self._search_results[#self._search_results + 1] = {
                    id            = b.id,
                    title         = b.title,
                    authors       = b.authors,
                    cover_url     = cover and cover.url    or b.cover_url,
                    cover_w       = cover and cover.width  or b.cover_w,
                    cover_h       = cover and cover.height or b.cover_h,
                    percentage    = b.percentage,
                    format        = b.format,
                    -- See Cache.put: preserved for bf_downloader's progress UI.
                    download_size = b.download_size,
                }
            end
        end
        self._search_api_page = next_api_page
        if pagination and pagination.total then
            self._search_total = pagination.total
        end
        if on_done then on_done() end
    end)
end

function BookFusionTab:_exitSearch()
    -- Cancel an in-flight popup if any.
    if self._search_popup then
        pcall(function() UIManager:close(self._search_popup) end)
        self._search_popup = nil
    end
    self._search_query        = nil
    self._search_results      = nil
    self._search_total        = 0
    self._search_api_page     = 0
    self._search_api_per_page = 0
    self._search_fetching     = nil
    self._view                = "landing"
    self:_rebuildAndRepaint()
end

function BookFusionTab:_onLeftIcon()
    -- On the landing: open the search InputDialog.  On subpages the left
    -- icon is a back chevron whose callback is wired in _buildTitleBar.
    self:_showSearchDialog()
end

function BookFusionTab:_onRightIcon()
    if not Data.isAvailable() or not Data.isLinked() then
        self:_rebuildAndRepaint()
        return
    end
    self:_refreshLists(true)
end

-- Consume taps/holds in the navbar band so they never reach content tiles.
function BookFusionTab:onBookFusionTap(_args, ges)
    if self._inBar and self._inBar(ges) then return true end
end
function BookFusionTab:onBookFusionHold(_args, ges)
    if self._inBar and self._inBar(ges) then return true end
end

-- ---------------------------------------------------------------------------
-- Refresh + cover prefetch
-- ---------------------------------------------------------------------------

function BookFusionTab:_refreshLists(force)
    if not Data.isLinked() then return end
    if self._refreshing then return end

    -- runWhenOnline prompts the user to turn on Wi-Fi if it's off.  If the
    -- user *cancels* that prompt, our callback is never invoked — so we
    -- MUST NOT commit any state (self._refreshing, self._sync_popup) before
    -- we're inside the callback.  Otherwise the popup would stay on screen
    -- and future taps on ↻ would short-circuit via the `if self._refreshing`
    -- guard above.
    NetworkMgr:runWhenOnline(function()
        if self._closed then return end

        local pending = {}
        for _i, key in ipairs(Cache.LIST_KEYS) do
            if force or Cache.isStale(key) then
                pending[#pending+1] = key
            end
        end
        if #pending == 0 then return end

        self._refreshing = true

        -- Show a persistent "Syncing…" popup for as long as the fetch loop
        -- is running.  Replaces the old inline "(refreshing…)" headline
        -- note so the header stays clean.  `timeout = 0` keeps it up until
        -- we explicitly close it on the last step.
        local InfoMessage = require("ui/widget/infomessage")
        self._sync_popup = InfoMessage:new{
            text    = _("Syncing…"),
            timeout = 0,
        }
        UIManager:show(self._sync_popup)

        local idx, failed = 0, 0
        local function finish()
            self._refreshing = false
            if failed > 0 then
                UIManager:show(InfoMessage:new{
                    text    = _("Couldn't refresh some BookFusion lists."),
                    timeout = 3,
                })
            end
            -- Prefetch covers for all three cached folders, Currently
            -- Reading first so the landing carousel warms before any
            -- drill-down. _prefetchAllCovers also owns the sync popup's
            -- lifetime from here on, closing it when the first cover is
            -- about to become visible (or immediately if everything is
            -- already cached).
            self:_prefetchAllCovers()
        end
        local function step()
            idx = idx + 1
            if idx > #pending then finish(); return end
            local key = pending[idx]
            local params = Cache.LIST_PARAMS[key] or { list = key }
            -- Enrich only Currently Reading with per-book reading position:
            -- that's the only list whose tiles render a progress bar.  TBR /
            -- Favourites would pay N extra HTTP GETs for data we'd throw
            -- away in `BookTile:init` (show_progress = false on those views).
            local fetch_opts = { with_progress = (key == "currently_reading") }
            Data.fetchListAll(params, function(ok, books)
                if ok and type(books) == "table" then
                    Cache.put(key, books)
                else
                    logger.warn("simpleui-bf: fetch failed for", key, tostring(books))
                    failed = failed + 1
                end
                if self._closed then return end
                self:_rebuildAndRepaint()
                step()
            end, fetch_opts)
        end
        step()
    end)
end

-- Kick off async downloads for the covers currently on screen.  Used by
-- the search flow (_enterSearch, search-paginate) where the only relevant
-- cover set is the in-memory search_results page.  The manual ↻ sync
-- instead calls _prefetchAllCovers so the user sees freshly-cached
-- covers across every folder on their next drill-down.
function BookFusionTab:_prefetchVisibleCovers()
    if self._cover_halt then pcall(self._cover_halt); self._cover_halt = nil end
    local books = {}
    if self._view == "landing" then
        local slot = Cache.get("currently_reading")
        local list = (slot and slot.books) or {}
        for i = 1, #list do books[#books+1] = list[i] end
    elseif self._view == "search" then
        local list = self._search_results or {}
        for i = 1, #list do books[#books+1] = list[i] end
    else
        local k = (self._view == "tbr") and "planned_to_read" or "favorites"
        local slot = Cache.get(k)
        local list = (slot and slot.books) or {}
        for i = 1, #list do books[#books+1] = list[i] end
    end
    local urls = {}
    for i = 1, #books do
        local u = books[i] and books[i].cover_url
        if u and u ~= "" then urls[#urls+1] = u end
    end
    self._cover_halt = Covers.fetchMissing(urls, function(_url)
        -- A cover landed on disk: repaint (the tile's next build picks it up
        -- via Covers.getBB which now finds it in the cache).
        if self._closed then return end
        self:_rebuildAndRepaint()
    end)
end

-- Queue cover downloads for ALL three cached folder lists so a manual
-- sync warms every folder's thumbnails regardless of which view the
-- user had open when they tapped ↻.  Order matters — bf_image_loader
-- processes the queue sequentially with a 0.2 s gap between requests,
-- so listing Currently Reading first ensures the visible carousel
-- fills before the user navigates anywhere else.
function BookFusionTab:_prefetchAllCovers()
    if self._cover_halt then pcall(self._cover_halt); self._cover_halt = nil end
    local urls = {}
    local function _pushFrom(key)
        local slot = Cache.get(key)
        local list = (slot and slot.books) or {}
        for i = 1, #list do
            local u = list[i] and list[i].cover_url
            if u and u ~= "" then urls[#urls+1] = u end
        end
    end
    _pushFrom("currently_reading")
    _pushFrom("planned_to_read")
    _pushFrom("favorites")

    -- Sync popup dismissal — captured here (rather than in _refreshLists'
    -- finish()) so we can tie the close to the first cover landing
    -- instead of a fixed delay.  popup_to_close holds the instance the
    -- call started with; if a follow-up sync spawns a new popup later,
    -- our close won't affect it because we compare identity before
    -- touching self._sync_popup.
    local popup_to_close = self._sync_popup
    local popup_closed = false
    local function close_popup()
        if popup_closed then return end
        popup_closed = true
        if popup_to_close then
            pcall(function() UIManager:close(popup_to_close) end)
            if self._sync_popup == popup_to_close then
                self._sync_popup = nil
            end
        end
    end

    -- If every cover is already cached on disk, no downloads will run
    -- and fetchMissing's callback will never fire — close the popup
    -- immediately so it doesn't hang around with nothing happening.
    local ok_cc, CC = pcall(require, "bf_covercache")
    local any_missing = false
    if ok_cc and CC then
        for i = 1, #urls do
            if not CC.read(urls[i]) then any_missing = true; break end
        end
    end
    if not any_missing then
        close_popup()
        return
    end

    -- Manual ↻ is a single unambiguous trigger — no need for the 1 s
    -- debounce that protects rapid-trigger callers (search pagination).
    self._cover_halt = Covers.fetchMissing(urls, function(_url)
        if self._closed then return end
        -- Dismiss the popup right before the rebuild that paints the
        -- first cover, so the popup "morphs" into the refreshed view
        -- rather than vanishing into empty space earlier.  No-op on
        -- subsequent cover callbacks — popup_closed gate.
        close_popup()
        self:_rebuildAndRepaint()
    end, { defer = false })

    -- Safety net: if the very first fetch is so slow (or everything
    -- gets dismissed across retries) that no cover lands in a
    -- reasonable window, close the popup anyway so it doesn't stick
    -- around indefinitely.  Large budget because we'd rather wait for
    -- a real cover than dismiss early.
    UIManager:scheduleIn(20, close_popup)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BookFusionTab:onShow()
    -- The tab is fully offline by design.  Opening it triggers ZERO network
    -- traffic: we render whatever is already in the on-disk list cache and
    -- the on-disk cover cache.  The user explicitly opts in to sync by
    -- tapping the ↻ icon in the title bar, which fires _refreshLists(true)
    -- → pulls fresh list JSON + downloads the current view's missing covers.
    --
    -- Rationale: many BookFusion users read on devices that spend most of
    -- their lives with Wi-Fi off (battery life, airplane mode).  Silent
    -- background syncs would pop the KOReader Wi-Fi prompt every time they
    -- switch to the tab — noisy and surprising.

    -- Unregister sui_patches' simpleui_menu_tap touch zone on this widget.
    -- The zone fires FileManagerMenu:onTapShowMenu for any tap in the top
    -- 1/8 of the screen BEFORE child title-bar icons' ges_events get a
    -- chance (InputContainer.onGesture walks _ordered_touch_zones before
    -- child propagation). The Library tab is unaffected because its
    -- equivalent zone lives on FileManagerMenu, not FM itself, so child
    -- propagation hits first there. Removing the zone here lets the title
    -- bar icons consume their taps; users still reach the main menu via
    -- the swipe-down gesture (simpleui_menu_swipe stays registered).
    if self.unRegisterTouchZones then
        pcall(self.unRegisterTouchZones, self, { { id = "simpleui_menu_tap" } })
    end
end

function BookFusionTab:onCloseWidget()
    self._closed = true
    if self._cover_halt then pcall(self._cover_halt); self._cover_halt = nil end
    if self._sync_popup then
        pcall(function() UIManager:close(self._sync_popup) end)
        self._sync_popup = nil
    end
    if self._search_popup then
        pcall(function() UIManager:close(self._search_popup) end)
        self._search_popup = nil
    end
    -- Drop any in-memory search results so the next tab open starts clean.
    self._search_results = nil
    self._search_query   = nil
    Covers.freeAll()
    if M._instance == self then M._instance = nil end
end

-- Back gesture closes the tab to the FM underneath.  Inside a subpage, the
-- first Back returns to landing; second Back closes.
-- Tab switches (via sui_bottombar.M.navigate) set _navbar_closing_intentionally
-- before invoking onClose and expect a full close regardless of subpage state —
-- otherwise the tab stays on the stack, covering the FM, and the user has to
-- tap the library tab twice.
function BookFusionTab:onClose()
    if not self._navbar_closing_intentionally and self._view ~= "landing" then
        self:_exitSubpage()
        return true
    end
    UIManager:close(self)
    return true
end

-- ===========================================================================
-- 7. MODULE API  (entered from sui_quickactions' bookfusion descriptor)
-- ===========================================================================

function M.show(_on_qa_tap)
    if M._instance then
        pcall(function() UIManager:close(M._instance) end)
        M._instance = nil
    end
    local w = BookFusionTab:new{}
    M._instance = w
    UIManager:show(w)
end

-- Expose so the settings-menu module can read accessors + key constants
-- without duplicating them.  Intentionally not exposing the internal
-- BookFusionTab class — settings UI doesn't need it.
M.Settings = Settings

return M
