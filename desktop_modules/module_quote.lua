-- module_quote.lua — Simple UI

-- Quote of the Day module. Three source modes:

--   "quotes"     — random quote from quotes.lua (default)

--   "highlights" — random highlight from the user's books

--   "mixed"      — random pick between both sources



local Blitbuffer     = require("ffi/blitbuffer")

local Device         = require("device")

local Font           = require("ui/font")

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")

local GestureRange   = require("ui/gesturerange")

-- ConfirmBox is only needed when the user taps a highlight to open its book.
-- Lazy-loaded at that point to avoid the cost at module-load time.
-- local ConfirmBox = require("ui/widget/confirmbox")  ← moved to usage site

local InputContainer = require("ui/widget/container/inputcontainer")

local TextBoxWidget  = require("ui/widget/textboxwidget")

local VerticalGroup  = require("ui/widget/verticalgroup")

local VerticalSpan   = require("ui/widget/verticalspan")

local Screen         = Device.screen

local _              = require("gettext")

local logger         = require("logger")



local Config       = require("sui_config")

local UIManager       = require("ui/uimanager")

local UI           = require("sui_core")

local PAD          = UI.PAD

local PAD2         = UI.PAD2

local CLR_TEXT_SUB = UI.CLR_TEXT_SUB



local _CLR_TEXT_QUOTE = Blitbuffer.COLOR_BLACK



local _BASE_QUOTE_FS     = Screen:scaleBySize(11)

local _BASE_QUOTE_ATTR_FS = Screen:scaleBySize(9)

local _BASE_QUOTE_GAP    = Screen:scaleBySize(4)

local _BASE_QUOTE_ATTR_H = Screen:scaleBySize(11)

-- Base height: PAD + approx 4 lines of text + gap + attribution + PAD2

local _BASE_QUOTE_H = PAD + _BASE_QUOTE_FS * 4 + _BASE_QUOTE_GAP + _BASE_QUOTE_ATTR_H + PAD2



-- Maximum character length for a highlight to be included in the pool.

-- Highlights longer than this are skipped — they would overflow more than

-- ~3 lines at typical screen widths and font sizes.

local MAX_HL_CHARS = 250

-- Sampling limits for _buildPool.
-- Instead of scanning every book in history (which can be hundreds of files),
-- we randomly sample up to MAX_POOL_BOOKS books and collect up to
-- MAX_POOL_HIGHLIGHTS highlights total. This bounds the I/O cost to a fixed
-- budget regardless of library size, while still producing a varied pool.
local MAX_POOL_BOOKS      = 50
local MAX_POOL_HIGHLIGHTS = 100



local SETTING_SOURCE = "quote_source"



local function getSource(pfx)

    return G_reader_settings:readSetting((pfx or "") .. SETTING_SOURCE) or "quotes"

end



-- ---------------------------------------------------------------------------

-- Default quotes engine

-- ---------------------------------------------------------------------------



local _quotes_cache = nil



local function loadQuotes()

    if _quotes_cache then return _quotes_cache end

    -- Use require so KOReader resolves the path correctly via its module loader.

    -- package.loaded is cleared to force a fresh load if quotes.lua was updated.

    package.loaded["quotes"] = nil

    local ok, data = pcall(require, "desktop_modules/quotes")

    if ok and type(data) == "table" and #data > 0 then

        _quotes_cache = data

    else

        _quotes_cache = {

            { q = "A reader lives a thousand lives before he dies.",                   a = "George R.R. Martin" },

            { q = "So many books, so little time.",                                    a = "Frank Zappa" },

            { q = "I have always imagined that Paradise will be a kind of library.",   a = "Jorge Luis Borges" },

            { q = "Sleep is good, he said, and books are better.",                     a = "George R.R. Martin", b = "A Clash of Kings" },

        }

    end

    return _quotes_cache

end



-- Picks the next quote using a shuffle-deck approach: all quotes are visited

-- in a random order before any repeats. The current position and shuffled

-- order are persisted in settings so the sequence survives restarts.

local _DECK_KEY  = "quote_deck_order"

local _POS_KEY   = "quote_deck_pos"

local _COUNT_KEY = "quote_deck_count"



local function _shuffle(n)

    local t = {}

    for i = 1, n do t[i] = i end

    for i = n, 2, -1 do

        local j = math.random(i)

        t[i], t[j] = t[j], t[i]

    end

    return t

end



local function _saveDeck(deck, pos)

    G_reader_settings:saveSetting(_DECK_KEY,  table.concat(deck, ","))

    G_reader_settings:saveSetting(_POS_KEY,   pos)

    G_reader_settings:saveSetting(_COUNT_KEY, #deck)

end



local function _loadDeck(n)

    local count = G_reader_settings:readSetting(_COUNT_KEY)

    local pos   = G_reader_settings:readSetting(_POS_KEY)

    local raw   = G_reader_settings:readSetting(_DECK_KEY)

    -- Invalidate if quote count changed (user edited quotes.lua)

    if type(count) ~= "number" or count ~= n

            or type(pos) ~= "number" or pos < 1 or pos > n

            or type(raw) ~= "string" then

        return nil, nil

    end

    local deck = {}

    for v in raw:gmatch("%d+") do

        deck[#deck + 1] = tonumber(v)

    end

    if #deck ~= n then return nil, nil end

    return deck, pos

end



local function pickQuote()

    local quotes = loadQuotes()

    local n = #quotes

    if n == 0 then return nil end



    local deck, pos = _loadDeck(n)

    if not deck then

        -- First run or quote list changed: build a fresh shuffled deck.

        deck = _shuffle(n)

        pos  = 1

        logger.warn("simpleui quote: new deck n=" .. n .. " pos=" .. pos)

    else

        logger.warn("simpleui quote: loaded deck pos=" .. pos .. "/" .. n)

    end



    local idx = deck[pos]

    pos = pos + 1

    if pos > n then

        local last = idx

        deck = _shuffle(n)

        if n > 1 and deck[1] == last then

            deck[1], deck[2] = deck[2], deck[1]

        end

        pos = 1

        logger.warn("simpleui quote: reshuffled, next pos=1")

    end



    _saveDeck(deck, pos)

    logger.warn("simpleui quote: showing idx=" .. idx .. " saved pos=" .. pos)

    return quotes[idx]

end



-- ---------------------------------------------------------------------------

-- Highlights engine

--

-- Reads each sidecar as raw text. dump() uses string.format("%q") for strings,

-- so each value is on a single line and special chars are escaped (\", \n, \\).

--

-- Key ordering in dump() is alphabetical, which means in the sidecar:

--   annotations  → comes first

--   doc_props    → comes after annotations (d > a)

--   stats        → comes after doc_props

--

-- Strategy: single pass through the whole file, collecting annotation texts

-- and doc metadata simultaneously. File is read line by line so only what is

-- needed is in memory at any time. Sidecar files without annotations are small

-- and exit the inner loop early (no annotations key found).

--

-- The pool is rebuilt once per session (on invalidateCache from onResume).

-- Within a session, pickHighlight() is O(1) with no I/O.

-- ---------------------------------------------------------------------------



local _hl_pool = nil



-- Extract a string value from a dump()-serialised line.

-- ["key"] = "value",  →  value (unescaped)

-- Returns nil if the key is not on this line.

local function _extractStr(line, key)

    -- Quick plain-string check before regex (cheap early exit)

    if not line:find(key, 1, true) then return nil end

    -- Greedy match: grab everything between the outer quotes.

    -- This correctly handles escaped quotes inside the value (\" stays as \").

    local val = line:match('%["' .. key .. '"%]%s*=%s*"(.*)"')

    if not val or val == "" then return nil end

    -- Unescape %q sequences: \" → "   \n → space   \\ → \

    val = val:gsub('\\"', '"'):gsub('\\n', ' '):gsub('\\\\', '\\')

    return val

end



-- Drawer values that represent a real highlight (coloured/underlined selection).
-- "note" means the user added a text note (no selected text shown as quote).
-- Bookmarks/page reminders have no drawer field at all.
local _HIGHLIGHT_DRAWERS = {
    highlight = true,
    lighten   = true,
    underscore = true,
}

local function _buildPool()

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    if not ok_lfs then return {} end

    local ok_DS, DocSettings = pcall(require, "docsettings")

    if not ok_DS then return {} end

    local ReadHistory = package.loaded["readhistory"]

    if not ReadHistory or not ReadHistory.hist then return {} end

    local hist = ReadHistory.hist
    local n_hist = #hist

    -- Phase 1: collect all history entries that have a sidecar on disk.
    -- This only does stat() calls (microseconds each) — no file reads yet.
    local candidates = {}
    for i = 1, n_hist do
        local fp = hist[i].file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local sidecar = DocSettings:findSidecarFile(fp)
            if sidecar then
                candidates[#candidates + 1] = { fp = fp, sidecar = sidecar }
            end
        end
    end

    -- Phase 2: shuffle the candidates so we sample a random subset of books
    -- rather than always the most-recently-read ones.
    local n_cand = #candidates
    for i = n_cand, 2, -1 do
        local j = math.random(i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    -- Phase 3: read sidecars up to the book and highlight limits.
    local pool        = {}
    local books_read  = 0

    for _, cand in ipairs(candidates) do
        if books_read >= MAX_POOL_BOOKS or #pool >= MAX_POOL_HIGHLIGHTS then break end

        local f = io.open(cand.sidecar, "r")
        if f then
            books_read = books_read + 1

            -- Collect annotation texts and metadata in one pass.
            -- Each annotation block is delimited by a numeric index line ([N] = {).
            -- We buffer the text for each block and only commit it once we confirm
            -- the drawer value marks it as a real highlight (not a note or bookmark).
            -- Each entry in `annots` holds everything needed to jump to that highlight.
            -- pos0 is the EPUB xpointer (reflowable); page is the fallback for PDFs/CBZ.
            local annots       = {}
            local title        = nil
            local authors      = nil
            local pending_text = nil   -- text seen before drawer confirmed
            local pending_pos0 = nil   -- xpointer for reflowable formats
            local pending_page = nil   -- page number for fixed-layout formats
            local is_highlight = false -- true once drawer = highlight-type seen

            local function _flushBlock()
                if pending_text and is_highlight then
                    annots[#annots + 1] = {
                        text = pending_text,
                        pos0 = pending_pos0,
                        page = pending_page,
                    }
                end
                pending_text = nil
                pending_pos0 = nil
                pending_page = nil
                is_highlight = false
            end

            for line in f:lines() do
                if line:match("^%s*%[%d+%]%s*=%s*{") then
                    _flushBlock()
                elseif line:find('["text"]', 1, true) then
                    local t = _extractStr(line, "text")
                    if t and #t > 10 and #t <= MAX_HL_CHARS then
                        pending_text = t
                    else
                        pending_text = nil
                    end
                elseif line:find('["pos0"]', 1, true) then
                    pending_pos0 = _extractStr(line, "pos0")
                elseif line:find('["page"]', 1, true) and not line:find('["pagemap"]', 1, true) then
                    -- page is a number: ["page"] = 42,
                    pending_page = tonumber(line:match('%["page"%]%s*=%s*(%d+)'))
                elseif line:find('["drawer"]', 1, true) then
                    local drawer = _extractStr(line, "drawer")
                    is_highlight = drawer ~= nil and _HIGHLIGHT_DRAWERS[drawer] == true
                elseif not title and line:find('["title"]', 1, true) then
                    title = _extractStr(line, "title")
                elseif not authors and line:find('["authors"]', 1, true) then
                    authors = _extractStr(line, "authors")
                end
            end
            _flushBlock()  -- flush the final annotation block
            f:close()

            if #annots > 0 then
                local book_title   = title or cand.fp:match("([^/]+)%.[^%.]+$") or "?"
                local book_authors = authors
                local remaining    = MAX_POOL_HIGHLIGHTS - #pool
                if #annots > remaining then
                    for i = #annots, 2, -1 do
                        local j = math.random(i)
                        annots[i], annots[j] = annots[j], annots[i]
                    end
                    for i = 1, remaining do
                        local a = annots[i]
                        pool[#pool + 1] = { text = a.text, pos0 = a.pos0, page = a.page,
                                            title = book_title, authors = book_authors, filepath = cand.fp }
                    end
                else
                    for _, a in ipairs(annots) do
                        pool[#pool + 1] = { text = a.text, pos0 = a.pos0, page = a.page,
                                            title = book_title, authors = book_authors, filepath = cand.fp }
                    end
                end
            end
        end
    end

    logger.dbg("simpleui: quote: _buildPool: " .. #pool .. " highlights from "
        .. books_read .. "/" .. n_cand .. " candidate books ("
        .. n_hist .. " in history)")
    return pool

end



local function getPool()

    if not _hl_pool then

        _hl_pool = _buildPool()

        _last_hl_idx = nil

    end

    return _hl_pool

end



-- Highlights use the same shuffle-deck approach as quotes, but keyed

-- separately so the two decks are independent.

local _HL_DECK_KEY  = "quote_hl_deck_order"

local _HL_POS_KEY   = "quote_hl_deck_pos"

local _HL_COUNT_KEY = "quote_hl_deck_count"



local function _saveHlDeck(deck, pos)

    G_reader_settings:saveSetting(_HL_DECK_KEY,  table.concat(deck, ","))

    G_reader_settings:saveSetting(_HL_POS_KEY,   pos)

    G_reader_settings:saveSetting(_HL_COUNT_KEY, #deck)

end



local function _loadHlDeck(n)

    local count = G_reader_settings:readSetting(_HL_COUNT_KEY)

    local pos   = G_reader_settings:readSetting(_HL_POS_KEY)

    local raw   = G_reader_settings:readSetting(_HL_DECK_KEY)

    if type(count) ~= "number" or count ~= n

            or type(pos) ~= "number" or pos < 1 or pos > n

            or type(raw) ~= "string" then

        return nil, nil

    end

    local deck = {}

    for v in raw:gmatch("%d+") do deck[#deck + 1] = tonumber(v) end

    if #deck ~= n then return nil, nil end

    return deck, pos

end



local function pickHighlight()

    local pool = getPool()

    local n = #pool

    if n == 0 then return nil end



    local deck, pos = _loadHlDeck(n)

    if not deck then

        deck = _shuffle(n)

        pos  = 1

    end



    -- Advance through the deck, skipping any entries that exceed MAX_HL_CHARS.

    -- In practice the pool is already filtered, but guard just in case.

    local start_pos = pos

    local entry

    repeat

        entry = pool[deck[pos]]

        pos   = pos + 1

        if pos > n then

            local last = deck[n]

            deck = _shuffle(n)

            if n > 1 and deck[1] == last then deck[1], deck[2] = deck[2], deck[1] end

            pos = 1

        end

        -- Stop if we have cycled through the whole deck without finding one.

    until #entry.text <= MAX_HL_CHARS or (pos == start_pos)



    _saveHlDeck(deck, pos)

    return (#entry.text <= MAX_HL_CHARS) and entry or nil

end



-- ---------------------------------------------------------------------------

-- Widget builders

-- ---------------------------------------------------------------------------



local function buildWidget(inner_w, text_str, attr_str, face_quote, face_attr, vspan_gap)

    local vg = VerticalGroup:new{ align = "center" }

    vg[#vg+1] = TextBoxWidget:new{

        text      = text_str,

        face      = face_quote,

        fgcolor   = _CLR_TEXT_QUOTE,

        width     = inner_w,

        alignment = "center",

    }

    vg[#vg+1] = vspan_gap

    vg[#vg+1] = TextBoxWidget:new{

        text      = attr_str,

        face      = face_attr,

        fgcolor   = CLR_TEXT_SUB,

        bold      = true,

        width     = inner_w,

        alignment = "center",

    }

    return vg

end



local function buildFromQuote(inner_w, face_quote, face_attr, vspan_gap)

    local q = pickQuote()

    if not q then

        return TextBoxWidget:new{

            text    = _("No quotes found."),

            face    = face_quote,

            fgcolor = CLR_TEXT_SUB,

            width   = inner_w,

        }

    end

    local attr = "— " .. (q.a or "?")

    if q.b and q.b ~= "" then attr = attr .. ",  " .. q.b end

    return buildWidget(inner_w, "\u{201C}" .. q.q .. "\u{201D}", attr, face_quote, face_attr, vspan_gap)

end



local function buildFromHighlight(inner_w, face_quote, face_attr, vspan_gap)

    local h = pickHighlight()

    if not h then

        logger.warn("simpleui: quote: buildFromHighlight: pool empty, showing fallback")

        return buildWidget(

            inner_w,

            _("No highlights found. Open a book and highlight some passages."),

            _("Your highlights"),

            face_quote, face_attr, vspan_gap

        ), nil

    end

    logger.warn("simpleui: quote: showing highlight from '" .. tostring(h.title) .. "': " .. tostring(h.text):sub(1, 60))

    local attr = "— " .. h.title

    if h.authors and h.authors ~= "" then attr = attr .. ",  " .. h.authors end

    -- Strip leading/trailing quote marks before wrapping to avoid double quotes.
    -- Also strip leading em/en dashes (dialogue markers from books): they are
    -- typographic artefacts of the source text and the cfont used by TextBoxWidget
    -- does not have a fallback glyph for U+2014/U+2013 when they are the very
    -- first character of a text run, causing a replacement glyph to be shown.
    local text = h.text:gsub('^["\u{201C}\u{2018}%s]+', ''):gsub('["\u{201D}\u{2019}%s]+$', '')
    text = text:gsub('^[\u{2014}\u{2013}]%s*', '')
    return buildWidget(inner_w, "\u{201C}" .. text .. "\u{201D}", attr, face_quote, face_attr, vspan_gap),
           h.filepath, h.title, h.pos0, h.page

end



local function buildFromMixed(inner_w, face_quote, face_attr, vspan_gap)

    local has_highlights = #getPool() > 0

    local has_quotes     = #loadQuotes() > 0

    if has_highlights and has_quotes then

        if math.random(2) == 1 then

            return buildFromHighlight(inner_w, face_quote, face_attr, vspan_gap)

        else

            return buildFromQuote(inner_w, face_quote, face_attr, vspan_gap), nil, nil, nil, nil

        end

    elseif has_highlights then

        return buildFromHighlight(inner_w, face_quote, face_attr, vspan_gap)

    else

        return buildFromQuote(inner_w, face_quote, face_attr, vspan_gap), nil, nil, nil, nil

    end

end



-- ---------------------------------------------------------------------------

-- Module API

-- ---------------------------------------------------------------------------



local M = {}



M.id          = "quote"

M.name        = _("Quote of the Day")

M.label       = nil

M.enabled_key = "quote_enabled"

M.default_on  = false

M.getCountLabel = nil



function M.invalidateCache()

    _hl_pool = nil

    -- Clear the highlight deck so it is rebuilt from the new pool.

    G_reader_settings:delSetting(_HL_COUNT_KEY)

end



function M.build(w, ctx)

    local scale      = Config.getModuleScale("quote", ctx.pfx)

    local quote_fs   = math.max(7, math.floor(_BASE_QUOTE_FS     * scale))

    local attr_fs    = math.max(6, math.floor(_BASE_QUOTE_ATTR_FS * scale))

    local quote_gap  = math.max(1, math.floor(_BASE_QUOTE_GAP    * scale))



    local face_quote = Font:getFace("cfont", quote_fs)

    local face_attr  = Font:getFace("cfont", attr_fs)

    local vspan_gap  = VerticalSpan:new{ width = quote_gap }



    local inner_w = w - PAD * 2

    local source  = getSource(ctx and ctx.pfx)

    logger.warn("simpleui: quote: build source=" .. source)

    local content
    local hl_filepath
    local hl_title
    local hl_pos0
    local hl_page

    if source == "highlights" then

        content, hl_filepath, hl_title, hl_pos0, hl_page = buildFromHighlight(inner_w, face_quote, face_attr, vspan_gap)

    elseif source == "mixed" then

        content, hl_filepath, hl_title, hl_pos0, hl_page = buildFromMixed(inner_w, face_quote, face_attr, vspan_gap)

    else

        content = buildFromQuote(inner_w, face_quote, face_attr, vspan_gap)

    end

    -- Use a plain VerticalGroup instead of FrameContainer so the module
    -- background is fully transparent (the homescreen background shows through).
    -- Padding is replicated with VerticalSpan (top/bottom) and HorizontalSpan
    -- (left/right) since VerticalGroup has no padding property of its own.
    local pad_span  = VerticalSpan:new{ width = PAD }
    local pad2_span = VerticalSpan:new{ width = PAD2 }
    local hpad      = HorizontalSpan:new{ width = PAD }
    local inner_row = HorizontalGroup:new{ hpad, content, hpad }
    local frame = VerticalGroup:new{ align = "center", pad_span, inner_row, pad2_span }

    local open_fn = ctx and ctx.open_fn

    if hl_filepath and open_fn then
        local Geom = require("ui/geometry")
        local frame_size = frame:getSize()

        local tappable = InputContainer:new{

            dimen  = Geom:new{ x = 0, y = 0, w = frame_size.w, h = frame_size.h },

            _fp    = hl_filepath,

            _title = hl_title or hl_filepath:match("([^/]+)%.[^%.]+$") or "?",

            _pos0  = hl_pos0,

            _page  = hl_page,

            _open  = open_fn,

            [1]    = frame,

        }

        tappable.ges_events = {

            TapQuote = {

                GestureRange:new{

                    ges   = "tap",

                    range = function() return tappable.dimen end,

                },

            },

        }

        function tappable:onTapQuote()
            if not self._open then return true end
            -- When "Ask before opening file" is enabled, open_fn (openBook in
            -- sui_homescreen) already shows a ConfirmBox — skip ours to avoid
            -- two confirmation dialogs in a row.
            if G_reader_settings:isTrue("file_ask_to_open") then
                self._open(self._fp, self._pos0, self._page)
            else
                local fp    = self._fp
                local pos0  = self._pos0
                local page  = self._page
                local open  = self._open
                local BD        = require("ui/bidi")
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text        = _("Open this file?") .. "\n\n" .. BD.filename(fp:match("([^/]+)$")),
                    ok_text     = _("Open"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        open(fp, pos0, page)
                    end,
                })
            end
            return true
        end

        return tappable

    end

    return frame

end



function M.getHeight(_ctx)

    local scale      = Config.getModuleScale("quote", _ctx and _ctx.pfx)

    local quote_fs   = math.max(7, math.floor(_BASE_QUOTE_FS     * scale))

    local quote_gap  = math.max(1, math.floor(_BASE_QUOTE_GAP    * scale))

    local attr_h     = math.max(6, math.floor(_BASE_QUOTE_ATTR_H * scale))

    return PAD + quote_fs * 4 + quote_gap + attr_h + PAD2

end





local function _makeScaleItem(ctx_menu)

    local pfx = ctx_menu.pfx

    local _lc = ctx_menu._

    return Config.makeScaleItem({

        text_func    = function() return _lc("Scale") end,

        enabled_func = function() return not Config.isScaleLinked() end,

        title        = _lc("Scale"),

        info         = _lc("Scale for this module.\n100% is the default size."),

        get          = function() return Config.getModuleScalePct("quote", pfx) end,

        set          = function(v) Config.setModuleScale(v, "quote", pfx) end,

        refresh      = ctx_menu.refresh,

    })

end

function M.getMenuItems(ctx_menu)

    local pfx     = ctx_menu.pfx

    local refresh = ctx_menu.refresh

    local _lc     = ctx_menu._



    return {

        {

            text           = _lc("Source"),

            sub_item_table = {

                {

                    text           = _lc("Default Quotes"),

                    radio          = true,

                    checked_func   = function() return getSource(pfx) == "quotes" end,

                    keep_menu_open = true,

                    callback       = function()

                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "quotes")

                        refresh()

                    end,

                },

                {

                    text           = _lc("My Highlights"),

                    radio          = true,

                    checked_func   = function() return getSource(pfx) == "highlights" end,

                    keep_menu_open = true,

                    callback       = function()

                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "highlights")

                        M.invalidateCache()

                        refresh()

                    end,

                },

                {

                    text           = _lc("Quotes + My Highlights"),

                    radio          = true,

                    checked_func   = function() return getSource(pfx) == "mixed" end,

                    keep_menu_open = true,

                    callback       = function()

                        G_reader_settings:saveSetting(pfx .. SETTING_SOURCE, "mixed")

                        M.invalidateCache()

                        refresh()

                    end,

                },

            },

        },

        _makeScaleItem(ctx_menu),

    }

end



return M