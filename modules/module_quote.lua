-- module_quote.lua — Simple UI

-- Quote of the Day module. Five source modes:

--   "quotes"       — random quote from quotes.lua (default)

--   "highlights"   — random highlight from the user's books

--   "mixed"        — random pick between quotes.lua and highlights

--   "custom"       — random quote from a user-supplied .lua file in the plugin's modules/custom_quotes/ folder

--   "custom_mixed" — random pick between the selected custom file and highlights



local Blitbuffer     = require("ffi/blitbuffer")

local util = require("util")

local Device         = require("device")


local CenterContainer = require("ui/widget/container/centercontainer")

local GestureRange   = require("ui/gesturerange")

-- ConfirmBox is only needed when the user taps a highlight to open its book.
-- Lazy-loaded at that point to avoid the cost at module-load time.
-- local ConfirmBox = require("ui/widget/confirmbox")  ← moved to usage site

local InputContainer   = require("ui/widget/container/inputcontainer")

local RenderText       = require("ui/rendertext")

local TextBoxWidget    = require("ui/widget/textboxwidget")

local VerticalGroup  = require("ui/widget/verticalgroup")

local VerticalSpan   = require("ui/widget/verticalspan")

local Screen         = Device.screen

local _ = require("infra/sui_i18n").translate

local logger         = require("logger")



local Config       = require("infra/sui_config")

local UIManager       = require("ui/uimanager")

local UI           = require("infra/sui_core")
local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")

local PAD          = UI.PAD

local PAD2         = UI.PAD2

local CLR_TEXT_SUB = UI.CLR_TEXT_SUB






local _BASE_QUOTE_FS      = SUIStyle.FS_BODY    -- 18: quote body text

local _BASE_QUOTE_ATTR_FS = SUIStyle.FS_DETAIL  -- 15: attribution / author text

local _BASE_QUOTE_GAP    = Screen:scaleBySize(4)

local _BASE_QUOTE_ATTR_H = Screen:scaleBySize(20)

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



local SETTING_SOURCE      = "simpleui_quote_source"
local SETTING_CUSTOM_FILE = "simpleui_quote_custom_file"
local SETTING_ALIGN       = "simpleui_quote_align"
local SETTING_FIXED_H     = "simpleui_quote_fixed_height"

local _FIXED_LINES = 3  -- number of quote-body lines when fixed height is active

-- ---------------------------------------------------------------------------
-- Alignment setting helpers  (mirrors module_action_list)
-- ---------------------------------------------------------------------------
local _ALIGN_VALUES = { "left", "center", "right" }

local function getAlignment(pfx)
    local v = SUISettings:readSetting((pfx or "") .. SETTING_ALIGN)
    for _, a in ipairs(_ALIGN_VALUES) do if a == v then return v end end
    return "center"  -- default
end

local function setAlignment(pfx, val)
    SUISettings:saveSetting((pfx or "") .. SETTING_ALIGN, val)
end

local function alignLabel(align)
    if align == "left"  then return _("Left")  end
    if align == "right" then return _("Right") end
    return _("Center")
end

-- ---------------------------------------------------------------------------
-- Fixed-height setting helpers
-- ---------------------------------------------------------------------------
local function isFixedHeight(pfx)
    return SUISettings:nilOrTrue((pfx or "") .. SETTING_FIXED_H)
end

local function setFixedHeight(pfx, val)
    SUISettings:saveSetting((pfx or "") .. SETTING_FIXED_H, val and true or false)
end


local lfs = require("libs/libkoreader-lfs")



local function getSource(pfx)

    return SUISettings:readSetting((pfx or "") .. SETTING_SOURCE) or "quotes"

end

local function getCustomFile(pfx)
    return SUISettings:readSetting((pfx or "") .. SETTING_CUSTOM_FILE) or ""
end

-- Returns the absolute path to the sui_quotes directory.
-- Since version X.X this lives outside the plugin folder
-- (DataStorage/simpleui/sui_quotes/) so it survives plugin updates.
local _CUSTOM_DIR
local function customDir()
    if not _CUSTOM_DIR then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage then
            _CUSTOM_DIR = DataStorage:getSettingsDir() .. "/simpleui/sui_quotes"
        else
            -- Fallback: old in-plugin location.
            local info = debug.getinfo(1, "S")
            local src  = info and info.source and info.source:match("^@(.+)$")
            if src then
                _CUSTOM_DIR = src:match("(.+)/[^/]+$") .. "/sui_quotes"
            else
                _CUSTOM_DIR = "modules/custom_quotes"
            end
        end
    end
    return _CUSTOM_DIR
end

-- Scans sui_quotes/ for .lua files; returns a sorted list of filenames.
local function listCustomQuoteFiles()
    local dir   = customDir()
    local files = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return files end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and name:match("%.lua$") then
            files[#files + 1] = name
        end
    end
    table.sort(files)
    return files
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

    local ok, data = pcall(require, "modules/quotes")

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



-- ---------------------------------------------------------------------------

-- Custom quotes engine

-- ---------------------------------------------------------------------------

-- Forward declaration: _shuffle is defined further below (after the default
-- quotes engine section) but is also needed by pickCustomQuote here.
-- Declaring it upfront makes the dependency explicit and avoids a nil-call
-- crash at runtime when the "custom" source mode is active.
local _shuffle

local _custom_quotes_cache      = nil
local _custom_quotes_cache_file = nil

local function loadCustomQuotes(filename)
    if _custom_quotes_cache and _custom_quotes_cache_file == filename then
        return _custom_quotes_cache
    end
    _custom_quotes_cache = nil; _custom_quotes_cache_file = nil
    if not filename or filename == "" then return nil end
    local path = customDir() .. "/" .. filename
    if lfs.attributes(path, "mode") ~= "file" then
        logger.warn("simpleui: quote: custom file not found: " .. tostring(path))
        return nil
    end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" and #data > 0 then
        _custom_quotes_cache = data; _custom_quotes_cache_file = filename
        logger.info("simpleui: quote: loaded " .. #data .. " custom quotes from " .. filename)
        return _custom_quotes_cache
    end
    logger.warn("simpleui: quote: failed to load " .. tostring(path) .. ": " .. tostring(data))
    return nil
end

local _CUSTOM_DECK_KEY  = "simpleui_quote_custom_deck_order"
local _CUSTOM_POS_KEY   = "simpleui_quote_custom_deck_pos"
local _CUSTOM_COUNT_KEY = "simpleui_quote_custom_deck_count"
local _CUSTOM_FILE_KEY  = "simpleui_quote_custom_deck_file"

local function pickCustomQuote(pfx)
    local filename = getCustomFile(pfx)
    local quotes   = loadCustomQuotes(filename)
    if not quotes or #quotes == 0 then return nil end
    local n = #quotes

    local sf = SUISettings:readSetting(_CUSTOM_FILE_KEY)
    local sc = SUISettings:readSetting(_CUSTOM_COUNT_KEY)
    local sp = SUISettings:readSetting(_CUSTOM_POS_KEY)
    local sr = SUISettings:readSetting(_CUSTOM_DECK_KEY)

    local deck, pos
    if sf == filename and type(sc) == "number" and sc == n
            and type(sp) == "number" and sp >= 1 and sp <= n
            and type(sr) == "string" then
        deck = {}
        for v in sr:gmatch("%d+") do deck[#deck + 1] = tonumber(v) end
        if #deck == n then pos = sp else deck, pos = nil, nil end
    end

    if not deck then deck = _shuffle(n); pos = 1 end

    local idx = deck[pos]
    pos = pos + 1
    if pos > n then
        local last = idx
        deck = _shuffle(n)
        if n > 1 and deck[1] == last then deck[1], deck[2] = deck[2], deck[1] end
        pos = 1
    end

    SUISettings:saveSetting(_CUSTOM_FILE_KEY,  filename)
    SUISettings:saveSetting(_CUSTOM_DECK_KEY,  table.concat(deck, ","))
    SUISettings:saveSetting(_CUSTOM_POS_KEY,   pos)
    SUISettings:saveSetting(_CUSTOM_COUNT_KEY, n)
    return quotes[idx]
end



-- Picks the next quote using a shuffle-deck approach: all quotes are visited

-- in a random order before any repeats. The current position and shuffled

-- order are persisted in settings so the sequence survives restarts.

local _DECK_KEY  = "simpleui_quote_deck_order"

local _POS_KEY   = "simpleui_quote_deck_pos"

local _COUNT_KEY = "simpleui_quote_deck_count"



_shuffle = function(n)

    local t = {}

    for i = 1, n do t[i] = i end

    for i = n, 2, -1 do

        local j = math.random(i)

        t[i], t[j] = t[j], t[i]

    end

    return t

end



local function _saveDeck(deck, pos)

    SUISettings:saveSetting(_DECK_KEY,  table.concat(deck, ","))

    SUISettings:saveSetting(_POS_KEY,   pos)

    SUISettings:saveSetting(_COUNT_KEY, #deck)

end



local function _loadDeck(n)

    local count = SUISettings:readSetting(_COUNT_KEY)

    local pos   = SUISettings:readSetting(_POS_KEY)

    local raw   = SUISettings:readSetting(_DECK_KEY)

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

-- Builds a pool of the user's own highlighted passages, sourced from every

-- book in ReadHistory that has a sidecar (.sdr) on disk. Sidecars are read

-- through the DocSettings settings API, so annotation data (escaping,

-- multi-line text, legacy vs. modern schema) is always parsed the same way

-- the reader itself parses it rather than by a hand-rolled text scan.

--

-- Two-stage sampling keeps the cost bounded regardless of library size:

--   1. candidate books are shuffled and visited in random order, capped at

--      MAX_POOL_BOOKS, so the pool draws from a varied subset rather than

--      always the most-recently-read books;

--   2. within a book, if its own highlights alone would exceed the

--      remaining budget they are subsampled too, so one heavily-annotated

--      book cannot crowd out every other book in the pool.

--

-- The pool is rebuilt once per session (on invalidateCache from onResume).

-- Within a session, pickHighlight() is O(1) with no I/O.

-- ---------------------------------------------------------------------------



local _hl_pool = nil



-- Minimum length for a highlight's text to be worth surfacing as a quote.

local MIN_HL_CHARS = 10



-- Reads one book's highlights via the DocSettings settings API and appends

-- up to `remaining` of them to `pool`, in randomised order if the book has

-- more than that on its own. Returns (opened, added):

--   opened — true if the sidecar was successfully read (for book-count stats)

--   added  — number of entries appended to pool

local function _collectFromSidecar(fp, DocSettings, pool, remaining)

    local ok_ds, ds = pcall(DocSettings.open, DocSettings, fp)

    if not (ok_ds and ds) then return false, 0 end

    if remaining <= 0 then return true, 0 end



    local title, authors

    local ok_p, props = pcall(ds.readSetting, ds, "doc_props")

    if ok_p and type(props) == "table" then

        if type(props.title) == "string" and props.title ~= "" then

            title = props.title

        end

        if type(props.authors) == "string" and props.authors ~= "" then

            authors = props.authors:match("^[^\n]+") or props.authors

        end

    end

    title = title or fp:match("([^/]+)%.[^%.]+$") or "?"



    -- Collect candidates first so a book with many highlights can be

    -- subsampled fairly, mirroring the book-selection phase below.

    local annots = {}

    local function add(text, page, pos0)

        if type(text) ~= "string" then return end

        if #text > MIN_HL_CHARS and #text <= MAX_HL_CHARS then

            annots[#annots + 1] = { text = text, page = page, pos0 = pos0 }

        end

    end



    -- Modern sidecar: annotations array. A populated drawer value marks a

    -- real coloured/underlined/struck-through/inverted selection; entries

    -- without one are bookmarks or page reminders and carry no meaningful

    -- quote text, so they are skipped.

    local ok_a, ann = pcall(ds.readSetting, ds, "annotations")

    if ok_a and type(ann) == "table" and #ann > 0 then

        for _, a in ipairs(ann) do

            if type(a) == "table" and a.drawer then

                add(a.text, a.page, a.pos0)

            end

        end

    else

        -- Pre-annotations sidecar: a "highlight" table keyed by page number,

        -- each holding an array of selections made on that page.

        local ok_h, hl = pcall(ds.readSetting, ds, "highlight")

        if ok_h and type(hl) == "table" then

            for page, list in pairs(hl) do

                if type(list) == "table" then

                    for _, h in ipairs(list) do

                        if type(h) == "table" then

                            add(h.text, tonumber(page) or page, h.pos0)

                        end

                    end

                end

            end

        end

    end



    if #annots == 0 then return true, 0 end



    if #annots > remaining then

        for i = #annots, 2, -1 do

            local j = math.random(i)

            annots[i], annots[j] = annots[j], annots[i]

        end

    end



    local n_add = math.min(#annots, remaining)

    for i = 1, n_add do

        local a = annots[i]

        pool[#pool + 1] = { text = a.text, pos0 = a.pos0, page = a.page,

                             title = title, authors = authors, filepath = fp }

    end

    return true, n_add

end



local function _buildPool()

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    if not ok_lfs then return {} end

    local ok_DS, DocSettings = pcall(require, "docsettings")

    if not ok_DS then return {} end

    -- Force-load readhistory instead of a passive package.loaded lookup.
    -- Module build order on the homescreen is layout-dependent, so this
    -- module cannot assume some other module has already required it.
    local ok_RH, ReadHistory = pcall(require, "readhistory")

    if not ok_RH or not ReadHistory or not ReadHistory.hist then return {} end

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
                candidates[#candidates + 1] = { fp = fp }
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

        local remaining = MAX_POOL_HIGHLIGHTS - #pool
        local opened = _collectFromSidecar(cand.fp, DocSettings, pool, remaining)
        if opened then books_read = books_read + 1 end
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

local _HL_DECK_KEY  = "simpleui_quote_hl_deck_order"

local _HL_POS_KEY   = "simpleui_quote_hl_deck_pos"

local _HL_COUNT_KEY = "simpleui_quote_hl_deck_count"



local function _saveHlDeck(deck, pos)

    SUISettings:saveSetting(_HL_DECK_KEY,  table.concat(deck, ","))

    SUISettings:saveSetting(_HL_POS_KEY,   pos)

    SUISettings:saveSetting(_HL_COUNT_KEY, #deck)

end



local function _loadHlDeck(n)

    local count = SUISettings:readSetting(_HL_COUNT_KEY)

    local pos   = SUISettings:readSetting(_HL_POS_KEY)

    local raw   = SUISettings:readSetting(_HL_DECK_KEY)

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



-- ---------------------------------------------------------------------------
-- Line-break control
-- ---------------------------------------------------------------------------

local NBSP = "\u{00A0}"  -- no-break space
local WJ   = "\u{2060}"  -- word joiner: forbids a line break on either side

-- Largest share of the box width the last two words may take for them to be
-- kept together on one line.
local _WIDOW_MAX_FRAC = 0.5

local function textWidth(face, text)
    return RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true).x
end

-- Glues each inner hyphen of `token` to the text after it, so the compound
-- cannot be split across lines at its hyphen.
local function bindHyphens(token)
    return (token:gsub("()%-()", function(i, j)
        local before, after = token:sub(i - 1, i - 1), token:sub(j, j)
        if before == "" or after == "" or before == "-" or after == "-" then
            return nil
        end
        return "-" .. WJ
    end))
end

-- Applies bindHyphens to every hyphenated word of `text` that fits `max_w`;
-- a wider word is left alone to avoid a forced mid-word cut.
local function bindCompounds(text, face, max_w)
    return (text:gsub("%S+", function(token)
        if token:find("-", 1, true) and textWidth(face, token) <= max_w then
            return bindHyphens(token)
        end
    end))
end

-- Prepares `text` for a box `max_w` wide:
--   * the last two words are kept together, so the final line is never a
--     single word;
--   * hyphenated compounds wrap as one unit instead of splitting at the hyphen.
local function controlLineBreaks(text, face, max_w)
    local function bind(part)
        -- The word joiner is only understood by the xtext layout engine.
        return TextBoxWidget.use_xtext and bindCompounds(part, face, max_w) or part
    end

    local head, w1, w2, tail = text:match("^(.-)(%S+)[ \t]+(%S+)(%s*)$")
    if head and textWidth(face, w1 .. " " .. w2) <= max_w * _WIDOW_MAX_FRAC then
        return bind(head) .. bind(w1) .. NBSP .. bind(w2) .. tail
    end
    return bind(text)
end

local function buildWidget(inner_w, text_str, attr_str, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)
    
    -- 防乱码：先修掉非法 UTF-8，再做测宽 / 换行控制
    text_str = util.fixUtf8(text_str or "", "")
    attr_str = attr_str and util.fixUtf8(attr_str, "") or attr_str

 local function makeTBW(text, face, fgcolor, bold)
        local args = {
            text      = controlLineBreaks(text, face, inner_w),
            face      = face,
            bold      = bold,
            width     = inner_w,
            alignment = alignment or "center",
            fgcolor   = fgcolor,
        }

        if has_wallpaper then
                local ok_tbx, tbx = pcall(UI.makeAlphaTextBox, args)
                if ok_tbx then
                    return tbx
                else
                    logger.warn("simpleui: module_quote: makeAlphaTextBox failed, falling back: " .. tostring(tbx))
                    return TextBoxWidget:new(args)
                end
            else
                return TextBoxWidget:new(args)
            end
    end

    local vg = VerticalGroup:new{ align = "center" }
    vg[#vg+1] = makeTBW(text_str, fonts.quote_face, clr_quote or SUIStyle.COLOR.text_primary, fonts.quote_bold)
    if attr_str and attr_str ~= "" then
        vg[#vg+1] = vspan_gap
        vg[#vg+1] = makeTBW(attr_str, fonts.attr_face, clr_attr or CLR_TEXT_SUB, fonts.attr_bold)
    end
    return vg

end



local function buildFromCustomQuote(inner_w, fonts, vspan_gap, pfx, has_wallpaper, clr_quote, clr_attr, alignment)

    local q = pickCustomQuote(pfx)

    if not q then

        return TextBoxWidget:new{

            text    = _("No custom quotes found. Add a .lua file to the plugin's sui_quotes/ folder and select it in Settings."),

            face    = fonts.quote_face,

            bold    = fonts.quote_bold,

            fgcolor = clr_attr or CLR_TEXT_SUB,

            bgcolor = nil,

            width   = inner_w,

            alpha   = true,

        }

    end

    local attr = q.a and ("— " .. q.a) or ""

    if q.b and q.b ~= "" then attr = attr .. (attr ~= "" and ",  " or "") .. q.b end

    return buildWidget(inner_w, "“" .. q.q .. "”", attr, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

end



local function buildFromQuote(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

    local q = pickQuote()

    if not q then

        return TextBoxWidget:new{

            text    = _("No quotes found."),

            face    = fonts.quote_face,

            bold    = fonts.quote_bold,

            fgcolor = clr_attr or CLR_TEXT_SUB,

            bgcolor = nil,

            width   = inner_w,

            alpha   = true,

        }

    end

    local attr = q.a and ("— " .. q.a) or ""

    if q.b and q.b ~= "" then attr = attr .. (attr ~= "" and ",  " or "") .. q.b end

    return buildWidget(inner_w, "\u{201C}" .. q.q .. "\u{201D}", attr, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

end



local function buildFromHighlight(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

    local h = pickHighlight()

    if not h then

        logger.warn("simpleui: quote: buildFromHighlight: pool empty, showing fallback")

        return buildWidget(

            inner_w,

            _("No highlights found. Open a book and highlight some passages."),

            _("Your highlights"),

            fonts, vspan_gap, has_wallpaper

        ), nil

    end

    logger.warn("simpleui: quote: showing highlight from '" .. tostring(h.title) .. "': " .. tostring(h.text):sub(1, 60))

    local attr = "— " .. h.title

    if h.authors and h.authors ~= "" then attr = attr .. ",  " .. h.authors end

    -- Strip leading/trailing quote marks before wrapping to avoid double quotes.
    -- The class covers: ASCII " and ', curly double (U+201C/201D), curly single /
    -- apostrophe (U+2018/2019), guillemets (U+00AB/00BB, U+2039/203A), and
    -- low-9 quotes (U+201E/201A) — all common in e-book source text.
    -- Whitespace is stripped at the same time to avoid "\u{201C} text \u{201D}" becoming "\u{201C}  text \u{201D}".
    -- Also strip leading em/en dashes (dialogue markers from books): they are
    -- typographic artefacts of the source text and the cfont used by TextBoxWidget
    -- does not have a fallback glyph for U+2014/U+2013 when they are the very
    -- first character of a text run, causing a replacement glyph to be shown.
    local LEADING_QUOTES  = '^["\'\u{201C}\u{2018}\u{201E}\u{201A}\u{00AB}\u{2039}%s]+'
    local TRAILING_QUOTES = '["\'\u{201D}\u{2019}\u{201E}\u{201A}\u{00BB}\u{203A}%s]+$'
    local text = h.text:gsub(LEADING_QUOTES, ''):gsub(TRAILING_QUOTES, '')
    text = text:gsub('^[\u{2014}\u{2013}]%s*', '')
    return buildWidget(inner_w, "\u{201C}" .. text .. "\u{201D}", attr, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment),
           h.filepath, h.title, h.pos0, h.page

end



local function buildFromMixed(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

    local has_highlights = #getPool() > 0

    local has_quotes     = #loadQuotes() > 0

    if has_highlights and has_quotes then

        if math.random(2) == 1 then

            return buildFromHighlight(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

        else

            return buildFromQuote(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment), nil, nil, nil, nil

        end

    elseif has_highlights then

        return buildFromHighlight(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

    else

        return buildFromQuote(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment), nil, nil, nil, nil

    end

end



-- Same as buildFromMixed, but pairs the user's highlights with the selected
-- custom quotes file instead of the built-in quotes.lua pool.
local function buildFromCustomMixed(inner_w, fonts, vspan_gap, pfx, has_wallpaper, clr_quote, clr_attr, alignment)

    local has_highlights = #getPool() > 0

    local custom_quotes  = loadCustomQuotes(getCustomFile(pfx))
    local has_custom     = custom_quotes ~= nil and #custom_quotes > 0

    if has_highlights and has_custom then

        if math.random(2) == 1 then

            return buildFromHighlight(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

        else

            return buildFromCustomQuote(inner_w, fonts, vspan_gap, pfx, has_wallpaper, clr_quote, clr_attr, alignment), nil, nil, nil, nil

        end

    elseif has_highlights then

        return buildFromHighlight(inner_w, fonts, vspan_gap, has_wallpaper, clr_quote, clr_attr, alignment)

    else

        return buildFromCustomQuote(inner_w, fonts, vspan_gap, pfx, has_wallpaper, clr_quote, clr_attr, alignment), nil, nil, nil, nil

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

-- Text elements with a user-selectable font family and size.
M.text_elems  = { "quote", "author" }

-- The attribution is bold until the user picks another variant.
Config.declareTextVariants(M.id, { author = "bold" })

M.getCountLabel = nil



function M.invalidateCache()

    _hl_pool = nil

    -- Clear the highlight deck so it is rebuilt from the new pool.

    SUISettings:delSetting(_HL_COUNT_KEY)

    -- Clear the custom quotes cache so re-selection picks up any file changes.
    _custom_quotes_cache = nil; _custom_quotes_cache_file = nil

end



-- Font sizes of the quote and author text: module scale × per-element text scale.
local function fontSizes(scale, styles)
    return math.max(7, math.floor(_BASE_QUOTE_FS     * scale * styles.quote.scale)),
           math.max(6, math.floor(_BASE_QUOTE_ATTR_FS * scale * styles.author.scale))
end

function M.build(w, ctx)

    local scale      = Config.getModuleScale("quote", ctx.pfx) * (ctx.landscape_factor or 1)

    local styles     = Config.resolveTextStyles(ctx, M.id, M.text_elems)
    local quote_fs, attr_fs = fontSizes(scale, styles)

    local quote_gap  = math.max(1, math.floor(_BASE_QUOTE_GAP    * scale))



    -- Faces of the quote text and its attribution, with the emboldening flag
    -- each still needs.
    local fonts = {}
    fonts.quote_face, fonts.quote_bold = SUIStyle.getTextFace(styles.quote,  quote_fs)
    fonts.attr_face,  fonts.attr_bold  = SUIStyle.getTextFace(styles.author, attr_fs)

    local vspan_gap  = VerticalSpan:new{ width = quote_gap }

    local _clr_quote       = SUIStyle.COLOR.text_primary
    local _clr_attr        = CLR_TEXT_SUB

    local source    = getSource(ctx and ctx.pfx)
    local alignment = getAlignment(ctx and ctx.pfx)

    local has_wallpaper = ctx and ctx.has_wallpaper

    local content
    local hl_filepath
    local hl_title
    local hl_pos0
    local hl_page

    if source == "highlights" then

        content, hl_filepath, hl_title, hl_pos0, hl_page = buildFromHighlight(w, fonts, vspan_gap, has_wallpaper, _clr_quote, _clr_attr, alignment)

    elseif source == "mixed" then

        content, hl_filepath, hl_title, hl_pos0, hl_page = buildFromMixed(w, fonts, vspan_gap, has_wallpaper, _clr_quote, _clr_attr, alignment)

    elseif source == "custom" then

        content = buildFromCustomQuote(w, fonts, vspan_gap, ctx and ctx.pfx, has_wallpaper, _clr_quote, _clr_attr, alignment)

    elseif source == "custom_mixed" then

        content, hl_filepath, hl_title, hl_pos0, hl_page = buildFromCustomMixed(w, fonts, vspan_gap, ctx and ctx.pfx, has_wallpaper, _clr_quote, _clr_attr, alignment)

    else

        content = buildFromQuote(w, fonts, vspan_gap, has_wallpaper, _clr_quote, _clr_attr, alignment)

    end

    -- Use a plain VerticalGroup instead of FrameContainer so the module
    -- background is fully transparent (the homescreen background shows through).
    -- Vertical padding is replicated with VerticalSpan. Horizontal insets come
    -- from the module chrome, and each text box aligns its own lines.
    local pad_span  = VerticalSpan:new{ width = PAD }
    local pad2_span = VerticalSpan:new{ width = PAD2 }
    local frame = VerticalGroup:new{ align = "center", pad_span, content, pad2_span }

    -- When fixed height is active, pin the frame to exactly getHeight() so the
    -- homescreen layout is stable regardless of how many lines the quote wraps to.
    local fixed = isFixedHeight(ctx and ctx.pfx)
    if fixed then
        local Geom2 = require("ui/geometry")
        frame = CenterContainer:new{
            dimen = Geom2:new{ w = w, h = M.getHeight(ctx) },
            frame,
        }
    end

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

    local lf         = (_ctx and _ctx.landscape_factor) or (UI.isLandscape() and UI.getLandscapeFactor() or 1)
    local scale      = Config.getModuleScale("quote", _ctx and _ctx.pfx) * lf

    local styles     = Config.resolveTextStyles(_ctx, M.id, M.text_elems)
    local quote_fs, attr_fs = fontSizes(scale, styles)
    local quote_lh   = SUIStyle.lineReserve(styles.quote, quote_fs, quote_fs)

    local quote_gap  = math.max(1, math.floor(_BASE_QUOTE_GAP    * scale))

    local attr_h     = SUIStyle.lineReserve(styles.author, attr_fs,
        math.max(6, math.floor(_BASE_QUOTE_ATTR_H * scale * styles.author.scale)))

    local fixed = isFixedHeight(_ctx and _ctx.pfx)
    local lines = fixed and _FIXED_LINES or 4  -- 4 is the dynamic estimate

    return PAD + quote_lh * lines + quote_gap + attr_h + PAD2

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



    local rows = {

        {

            text           = _lc("Source"),

            sub_item_table = {

                {

                    text           = _lc("Default Quotes"),

                    radio          = true,

                    checked_func   = function() return getSource(pfx) == "quotes" end,

                    keep_menu_open = true,

                    callback       = function()

                        SUISettings:saveSetting(pfx .. SETTING_SOURCE, "quotes")

                        refresh()

                    end,

                },

                {

                    text           = _lc("My Highlights"),

                    radio          = true,

                    checked_func   = function() return getSource(pfx) == "highlights" end,

                    keep_menu_open = true,

                    callback       = function()

                        SUISettings:saveSetting(pfx .. SETTING_SOURCE, "highlights")

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

                        SUISettings:saveSetting(pfx .. SETTING_SOURCE, "mixed")

                        M.invalidateCache()

                        refresh()

                    end,

                },

                {

                    text         = _lc("Custom File"),

                    radio        = true,

                    checked_func = function() return getSource(pfx) == "custom" end,

                    -- Scan the filesystem only when the user opens this sub-menu.
                    sub_item_table_func = function()
                        local files    = listCustomQuoteFiles()
                        local subitems = {}

                        if #files == 0 then
                            subitems[#subitems + 1] = {
                                text    = _lc("No .lua files found in sui_quotes/"),
                                enabled = false,
                            }
                        else
                            for _, fname in ipairs(files) do
                                local _fname = fname
                                subitems[#subitems + 1] = {
                                    text           = _fname,
                                    radio          = true,
                                    checked_func   = function()
                                        return getSource(pfx) == "custom"
                                               and getCustomFile(pfx) == _fname
                                    end,
                                    keep_menu_open = true,
                                    callback       = function()
                                        SUISettings:saveSetting(pfx .. SETTING_SOURCE,      "custom")
                                        SUISettings:saveSetting(pfx .. SETTING_CUSTOM_FILE, _fname)
                                        M.invalidateCache()
                                        refresh()
                                    end,
                                }
                            end
                        end

                        subitems[#subitems + 1] = {
                            text    = _lc("Place .lua files in the plugin's sui_quotes/ folder"),
                            enabled = false,
                        }

                        return subitems
                    end,

                },

                {

                    text         = _lc("Custom File + My Highlights"),

                    radio        = true,

                    checked_func = function() return getSource(pfx) == "custom_mixed" end,

                    -- Scan the filesystem only when the user opens this sub-menu.
                    sub_item_table_func = function()
                        local files    = listCustomQuoteFiles()
                        local subitems = {}

                        if #files == 0 then
                            subitems[#subitems + 1] = {
                                text    = _lc("No .lua files found in sui_quotes/"),
                                enabled = false,
                            }
                        else
                            for _, fname in ipairs(files) do
                                local _fname = fname
                                subitems[#subitems + 1] = {
                                    text           = _fname,
                                    radio          = true,
                                    checked_func   = function()
                                        return getSource(pfx) == "custom_mixed"
                                               and getCustomFile(pfx) == _fname
                                    end,
                                    keep_menu_open = true,
                                    callback       = function()
                                        SUISettings:saveSetting(pfx .. SETTING_SOURCE,      "custom_mixed")
                                        SUISettings:saveSetting(pfx .. SETTING_CUSTOM_FILE, _fname)
                                        M.invalidateCache()
                                        refresh()
                                    end,
                                }
                            end
                        end

                        subitems[#subitems + 1] = {
                            text    = _lc("Place .lua files in the plugin's sui_quotes/ folder"),
                            enabled = false,
                        }

                        return subitems
                    end,

                },

            },

        },

        _makeScaleItem(ctx_menu),

        {
            text_func  = function() return _lc("Alignment") end,
            value_func = function() return alignLabel(getAlignment(pfx)) end,
            sub_item_table = {
                {
                    text           = _lc("Left"),
                    checked_func   = function() return getAlignment(pfx) == "left" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "left");   refresh() end,
                },
                {
                    text           = _lc("Center"),
                    checked_func   = function() return getAlignment(pfx) == "center" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "center"); refresh() end,
                },
                {
                    text           = _lc("Right"),
                    checked_func   = function() return getAlignment(pfx) == "right" end,
                    keep_menu_open = true,
                    callback       = function() setAlignment(pfx, "right");  refresh() end,
                },
            },
        },

        Config.makeTextSection({
            mod_id  = M.id,
            elems   = M.text_elems,
            labels  = { quote = _lc("Quote"), author = _lc("Author") },
            info    = _lc("Size of this text.\n100% is the default size."),
            pfx     = pfx,
            refresh = refresh,
            _lc     = _lc,
        }),
        {
            text         = _lc("Fixed Height"),
            checked_func = function() return isFixedHeight(pfx) end,
            callback     = function()
                setFixedHeight(pfx, not isFixedHeight(pfx))
                refresh()
            end,
        },

    }

    local content_rows, size_rows, appearance_extra = {}, {}, {}
    local text_opts = {
        mod_id  = M.id,
        elems   = M.text_elems,
        labels  = { quote = _lc("Quote"), author = _lc("Author") },
        info    = _lc("Size of this text.\n100% is the default size."),
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }
    for _, row in ipairs(rows) do
        local label = row.text
        if type(label) ~= "string" and row.text_func then
            local ok, v = pcall(row.text_func)
            if ok then label = v end
        end
        label = label or ""
        if label == _lc("Scale") then
            size_rows[#size_rows + 1] = row
        elseif label == _lc("Text") or label == _lc("Fonts") then
            -- text_opts
        elseif label == _lc("Alignment") or label == _lc("Fixed Height") then
            appearance_extra[#appearance_extra + 1] = row
        else
            content_rows[#content_rows + 1] = row
        end
    end
    return Config.buildModuleMenu({
        content = content_rows,
        appearance = {
            size  = #size_rows > 0 and size_rows or nil,
            text  = text_opts,
            extra = #appearance_extra > 0 and appearance_extra or nil,
        },
    }, ctx_menu)
end

return M
