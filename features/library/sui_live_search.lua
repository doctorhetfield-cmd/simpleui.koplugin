-- sui_live_search.lua — Simple UI
-- Search bar pinned at the top of the library that filters the current
-- listing as you type, by title, author, series or filename.
--
-- The bar is a plain InputText inserted into the file chooser's own
-- content group, under the title bar, and the item area is shortened by
-- its height. It filters whatever the file chooser is showing: a real
-- folder, a series group, or an author/series/tags browse level. Clearing
-- it puts the unfiltered listing back as it was, with its sort order and
-- the active filters unchanged, because the listing is never rebuilt:
-- every keystroke filters the item table the file chooser already got.
--
-- A book is kept when its file name, title, authors or series match; a
-- folder when its name matches or a book anywhere below it does, so the
-- search is useful from the top of the library too. Books come from the
-- cached LibraryScan file list and sui_metadata_source rows, the same ones
-- the library search reads, so the bar adds no index of its own.
--
-- With "Typo-tolerant search" on (the default), matching also ignores
-- accents and punctuation (bronte finds Brontë) and forgives small typos:
-- one edit in a word of 4-7 letters, two in a word of 8 or more, measured
-- against the start of each word so it works while the word is still being
-- typed. Every query word must match, in any order. Plain matches keep
-- their place at the top, then accent/punctuation-only ones, then close
-- matches by number of edits. Turned off, matching is the plain one above.
--
-- A single hook on FileChooser.switchItemTable keeps the last unfiltered
-- table of each file chooser and filters it while a query is set. Moving
-- to another folder or view clears the query.
--
-- Public API
-- ----------
--   LiveSearch.isEnabled() / LiveSearch.setEnabled(bool)
--   LiveSearch.isFuzzy()   / LiveSearch.setFuzzy(bool)  -- typo tolerance
--   LiveSearch.install(owner)    -- the bar appears on the next listing
--   LiveSearch.uninstall(owner)  -- removes the bar and the hook

local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InputText       = require("ui/widget/inputtext")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local util            = require("util")

local SUISettings     = require("infra/sui_store")
local UI              = require("infra/sui_core")
local LibraryScan     = require("engines/sui_library_scan")
local MetadataSource  = require("features/library/sui_metadata_source")
local _               = require("infra/sui_i18n").translate

local Screen = Device.screen

local LiveSearch = {}

local ENABLED_KEY = "simpleui_live_search"
local FUZZY_KEY   = "simpleui_live_search_fuzzy"
local HOOK_STATE  = "_simpleui_live_search_hooks"
-- Short enough to feel immediate, long enough to skip a repaint per key
-- while typing fast on e-ink.
local DEBOUNCE_S  = 0.15

function LiveSearch.isEnabled() return SUISettings:isTrue(ENABLED_KEY) end
function LiveSearch.setEnabled(v) SUISettings:saveSetting(ENABLED_KEY, v and true or false) end
-- Typo tolerance is on unless turned off.
function LiveSearch.isFuzzy() return SUISettings:nilOrTrue(FUZZY_KEY) end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

local function queryWords(query)
    local words = {}
    for w in query:gmatch("%S+") do words[#words + 1] = util.stringLower(w) end
    return words
end

-- True when `new` only extends `old`, so the previous matches can be
-- narrowed instead of filtering the whole listing again.
local function isRefinement(old, new)
    if not old or old == "" or old:find("%s$") then return false end
    return #new > #old and new:sub(1, #old) == old
end

local function lower(s) return s and util.stringLower(s) or "" end

-- File names are matched without their extension, or "pub" would match
-- every EPUB in the library.
local function fileName(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""))
end

-- One lower-cased string per book, so each query word costs one find().
-- Both caches have weak keys: the scan entries and the metadata rows belong
-- to LibraryScan and MetadataSource, which replace them when they rescan.
local _file_keys = setmetatable({}, { __mode = "k" })
local _row_keys  = setmetatable({}, { __mode = "k" })

local function bookKey(entry, row)
    if row then
        local key = _row_keys[row]
        if not key then
            key = table.concat({ lower(fileName(row[2])), lower(row.title), lower(row.authors), lower(row.series) }, "\n")
            _row_keys[row] = key
        end
        return key
    end
    local key = _file_keys[entry]
    if not key then
        key = lower(fileName(entry.fp))
        _file_keys[entry] = key
    end
    return key
end

-- Every book under the home folder with its search key: the same file list
-- and metadata rows the library search reads.
local function libraryBooks()
    local home_dir = LibraryScan.resolveHomeDir()
    if not home_dir then return {}, {} end
    local rows_by_path = {}
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if ok_bim and bim then
        for _, row in ipairs(MetadataSource.getMatchingFiles(bim, home_dir)) do
            rows_by_path[row[1]] = row
        end
    end
    local books, known = {}, {}
    for i, entry in ipairs(LibraryScan.getRaw(home_dir)) do
        books[i] = { entry.fp, bookKey(entry, rows_by_path[entry.fp]) }
        known[entry.fp] = true
    end
    return books, known
end

local function matchesAll(key, words)
    for _, w in ipairs(words) do
        if not key:find(w, 1, true) then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Typo-tolerant matching
-- ---------------------------------------------------------------------------

-- Accented Latin letters (both cases) -> plain ASCII, keyed by UTF-8 sequence.
local FOLD = {}
do
    local groups = {
        a = "àáâãäåāăąǎÀÁÂÃÄÅĀĂĄǍ", c = "çćĉċčÇĆĈĊČ", d = "ďđðĎĐÐ",
        e = "èéêëēĕėęěÈÉÊËĒĔĖĘĚ", g = "ĝğġģĜĞĠĢ", h = "ĥħĤĦ",
        i = "ìíîïĩīĭįıǐÌÍÎÏĨĪĬĮİǏ", j = "ĵĴ", k = "ķĶ", l = "ĺļľŀłĹĻĽĿŁ",
        n = "ñńņňŉÑŃŅŇ", o = "òóôõöøōŏőǒÒÓÔÕÖØŌŎŐǑ", r = "ŕŗřŔŖŘ",
        s = "śŝşšŚŜŞŠ", t = "ţťŧŢŤŦ", u = "ùúûüũūŭůűųǔÙÚÛÜŨŪŬŮŰŲǓ",
        w = "ŵŴ", y = "ýÿŷÝŸŶ", z = "źżžŹŻŽ",
        ss = "ß", ae = "æÆ", oe = "œŒ", th = "þÞ",
    }
    for plain, chars in pairs(groups) do
        for ch in chars:gmatch("[\192-\247][\128-\191]*") do FOLD[ch] = plain end
    end
end

-- Lower-case, fold accents, drop apostrophes and turn other punctuation
-- into spaces. Letters of other scripts are kept as they are.
local function normalize(s)
    s = lower(s)
    if s:find("[\128-\255]") then
        s = s:gsub("[\195-\201][\128-\191]", FOLD)
        s = s:gsub("\226\128[\152\153]", "")                -- ‘ ’
        s = s:gsub("\226\128[\147\148\156\157\166]", " ")  -- – — “ ” …
        s = s:gsub("\194[\160-\191]", " ")                   -- no-break space, « » ¿ ¡ ·
        s = s:lower()                                        -- folded capitals
    end
    if s:find("[%c%p]") then
        s = s:gsub("'", ""):gsub("[%c%p]", " ")
    end
    return s
end

-- Edits forgiven in a query word of `n` letters.
local function typoBudget(n)
    if n >= 8 then return 2 elseif n >= 4 then return 1 end
    return 0
end

-- Smallest Damerau-Levenshtein (optimal string alignment) distance between
-- `q` and any prefix of `t`, or nil when it is above `cap`. Columns walk `t`
-- one letter at a time; it gives up as soon as a whole column is over `cap`.
local byte = string.byte
local _row2, _row1, _row0 = {}, {}, {}
local function prefixDistance(q, t, cap)
    local n, m = #q, #t
    if m < n - cap then return nil end
    local prev2, prev, cur = _row2, _row1, _row0
    for i = 0, n do prev[i] = i end
    local best = prev[n]
    local tj1 -- t's previous letter
    for j = 1, m do
        local tj = byte(t, j)
        cur[0] = j
        local colmin = j
        local qi1
        for i = 1, n do
            local qi = byte(q, i)
            local v = prev[i - 1] + ((qi == tj) and 0 or 1)
            local del = prev[i] + 1
            if del < v then v = del end
            local ins = cur[i - 1] + 1
            if ins < v then v = ins end
            if i > 1 and j > 1 and qi == tj1 and qi1 == tj then
                local tr = prev2[i - 2] + 1
                if tr < v then v = tr end
            end
            cur[i] = v
            if v < colmin then colmin = v end
            qi1 = qi
        end
        if cur[n] < best then best = cur[n] end
        if best == 0 or colmin > cap then break end
        prev2, prev, cur = prev, cur, prev2
        tj1 = tj
    end
    if best <= cap then return best end
end

-- Normalised text and its words, once per search key. Keys are strings, so
-- this cache is a plain table, emptied when it gets large.
local _norm, _norm_n = {}, 0
local function normalized(key)
    local e = _norm[key]
    if not e then
        if _norm_n >= 20000 then _norm, _norm_n = {}, 0 end
        local norm = normalize(key)
        local tokens = {}
        for w in norm:gmatch("%S+") do tokens[#tokens + 1] = w end
        e = { norm, tokens }
        _norm[key], _norm_n = e, _norm_n + 1
    end
    return e
end

-- _dist[query word][book word] = distance or false, so each keystroke only
-- measures words it has not met before.
local _dist, _dist_n = {}, 0
local function wordCost(word, budget, tokens)
    local cache = _dist[word]
    if not cache then
        if _dist_n >= 64 then _dist, _dist_n = {}, 0 end
        cache = {}
        _dist[word], _dist_n = cache, _dist_n + 1
    end
    local best
    for k = 1, #tokens do
        local t = tokens[k]
        local d = cache[t]
        if d == nil then
            d = prefixDistance(word, t, budget) or false
            cache[t] = d
        end
        if d and (not best or d < best) then
            best = d
            if d == 0 then break end
        end
    end
    return best
end

-- Returns how a search key matches the query, lower is better, or nil:
-- 0 every word found as typed (the plain search), 1 found once accents and
-- punctuation are ignored, 1 + n with n edits forgiven. Without `fuzzy`
-- only 0 or nil, exactly the plain search.
local function makeMatcher(words, query, fuzzy)
    if not fuzzy then
        return function(key) if matchesAll(key, words) then return 0 end end
    end
    local fwords = {}
    for w in normalize(query):gmatch("%S+") do fwords[#fwords + 1] = w end
    return function(key)
        if matchesAll(key, words) then return 0 end
        if #fwords == 0 then return nil end
        local e = normalized(key)
        local norm, tokens = e[1], e[2]
        local total = 0
        for j = 1, #fwords do
            local w = fwords[j]
            if not norm:find(w, 1, true) then
                local budget = typoBudget(#w)
                if budget == 0 then return nil end
                local d = wordCost(w, budget, tokens)
                if not d then return nil end
                total = total + d
            end
        end
        return 1 + total
    end
end

-- ---------------------------------------------------------------------------
-- Bar
-- ---------------------------------------------------------------------------

local SearchBar = InputContainer:extend{
    fc     = nil, -- the file chooser the bar belongs to
    width  = nil,
    query  = "",
}

function SearchBar:init()
    local side = UI.SIDE_M()
    local clear = IconButton:new{
        icon        = "close",
        width       = Screen:scaleBySize(32),
        height      = Screen:scaleBySize(32),
        padding     = Size.padding.small,
        callback    = function() self:clear() end,
        show_parent = self.fc.show_parent,
    }
    local face = Font:getFace("smallinfofont")
    -- `width` is the text area only; InputText wraps it in a frame with its
    -- own margin, border and padding on both sides, so leave room for those.
    local frame_w = 2 * (InputText.margin + InputText.bordersize + InputText.padding)
    local input_w = self.width - 2 * side - clear:getSize().w
                  - Size.padding.default - frame_w
    self.input = InputText:new{
        text          = "",
        hint          = _("Search title, author, series"),
        width         = input_w,
        face          = face,
        focused       = false,
        scroll        = false,
        parent        = self,
        edit_callback = function(edited)
            if edited then self:schedule() end
        end,
        enter_callback = function() self:closeKeyboard() end,
    }
    self[1] = FrameContainer:new{
        padding        = 0,
        padding_left   = side,
        padding_right  = side,
        padding_bottom = Size.padding.small,
        bordersize     = 0,
        HorizontalGroup:new{
            align = "center",
            self.input,
            HorizontalSpan:new{ width = Size.padding.default },
            clear,
        },
    }
    self.dimen = Geom:new{ w = self.width, h = self[1]:getSize().h }
    -- While the keyboard is up it is the top window and swallows nothing it
    -- does not cover; the bar gets those taps as an active widget of the
    -- file manager (see attach) and uses them to put the keyboard away.
    self.ges_events = {
        TapOutsideKeyboard = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } },
    }
end

function SearchBar:getSize() return self.dimen end

-- The bar never takes D-pad focus; InputText asks its parent for these.
function SearchBar:getFocusableWidgetXY() return nil, nil end
function SearchBar:moveFocusTo() end

function SearchBar:keyboardVisible()
    return self.input:isKeyboardVisible()
end

function SearchBar:closeKeyboard()
    if self:keyboardVisible() then self.input:onCloseKeyboard() end
    self.input:unfocus()
end

function SearchBar:onTapOutsideKeyboard(_arg, ges)
    if not self:keyboardVisible() then return false end
    local kb = self.input.keyboard
    if kb and kb.dimen and ges.pos:intersectWith(kb.dimen) then return false end
    self:closeKeyboard()
    return true
end

function SearchBar:onCloseWidget()
    self:cancelScheduled()
    self:closeKeyboard()
end

function SearchBar:cancelScheduled()
    if self._apply then
        UIManager:unschedule(self._apply)
        self._apply = nil
    end
end

function SearchBar:schedule()
    self:cancelScheduled()
    self._apply = function()
        self._apply = nil
        self:apply(self.input:getText())
    end
    UIManager:scheduleIn(DEBOUNCE_S, self._apply)
end

function SearchBar:clear()
    self:cancelScheduled()
    if self.input:getText() ~= "" then self.input:setText("") end
    self:apply("")
end

-- Called for every table the file chooser is given. Keeps the unfiltered
-- table and returns the one to show. A different folder or view drops the
-- query; the same one (a refresh) keeps it.
function SearchBar:take(items)
    local view = tostring(self.fc.path) .. "\0" .. tostring(items._sg_is_series_view and items._sg_series_name or "")
    if view ~= self.view and self.query ~= "" then
        self:cancelScheduled()
        self.query = ""
        self.input:setText("")
    end
    self.view, self.full = view, items
    self.keys, self.last, self.library, self.known = nil, nil, nil, nil
    return self:filtered()
end

-- The books matching the query (path -> rank, see makeMatcher) and the
-- folders holding at least one of them (path -> best rank below), so a
-- folder stays listed when a book somewhere inside it matches.
function SearchBar:matchingBooks(match, refine)
    local source = refine and self.last and self.last.rows
    if not source then
        if not self.library then self.library, self.known = libraryBooks() end
        source = self.library
    end
    local rows, by_path, dirs = {}, {}, {}
    for _, book in ipairs(source) do
        local rank = match(book[2])
        if rank then
            rows[#rows + 1] = book
            by_path[book[1]] = rank
            local dir = book[1]:match("^(.*)/[^/]*$")
            while dir and dir ~= "" and not (dirs[dir] and dirs[dir] <= rank) do
                dirs[dir] = rank
                dir = dir:match("^(.*)/[^/]*$")
            end
        end
    end
    return rows, by_path, dirs
end

function SearchBar:filtered()
    local words = queryWords(self.query)
    if #words == 0 then
        self.last = nil
        return self.full
    end
    local fuzzy = LiveSearch.isFuzzy()
    local match = makeMatcher(words, self.query, fuzzy)
    -- A longer word may forgive more typos, so typo-tolerant results are
    -- not a subset of the previous ones: filter the whole listing again.
    local refine = not fuzzy and isRefinement(self.last and self.last.query, self.query)
    local rows, books, dirs = self:matchingBooks(match, refine)
    self.keys = self.keys or {}
    local out = {}
    -- Keep the table's own fields (series view flags and the like).
    for k, v in pairs(self.full) do
        if type(k) ~= "number" then out[k] = v end
    end
    local keys = self.keys
    local known = self.known
    local function keeps(item)
        if item.is_file and item.path and known[item.path] then
            return books[item.path]
        end
        if not item.is_file and item.path then
            local rank = dirs[(item.path:gsub("/$", ""))]
            if rank then return rank end
        end
        -- Folders by name, and books outside the home folder or not
        -- scanned yet by their file name.
        local key = keys[item]
        if not key then
            key = lower(item.is_file and item.path and fileName(item.path) or item.text)
            keys[item] = key
        end
        return match(key)
    end
    -- Typo-tolerant results are ranked: one bucket per rank, each in the
    -- listing's own order. Plain results all have rank 0.
    local buckets, max_rank = { [0] = out }, 0
    local function add(item, rank)
        local bucket = buckets[rank]
        if not bucket then
            bucket = {}
            buckets[rank] = bucket
            if rank > max_rank then max_rank = rank end
        end
        bucket[#bucket + 1] = item
    end
    for _, item in ipairs(refine and self.last.items or self.full) do
        if item.series_items then
            -- A series group shows its matching books; the series grouping
            -- groups them again when there are enough of them.
            for _, book in ipairs(item.series_items) do
                local rank = keeps(book)
                if rank then add(book, rank) end
            end
        elseif item.is_go_up then
            out[#out + 1] = item
        else
            local rank = keeps(item)
            if rank then add(item, rank) end
        end
    end
    for rank = 1, max_rank do
        local bucket = buckets[rank]
        if bucket then
            for _, item in ipairs(bucket) do out[#out + 1] = item end
        end
    end
    self.last = { query = self.query, rows = rows, items = out }
    return out
end

function SearchBar:apply(text)
    text = text or ""
    if text == self.query or not self.full then return end
    if self.query == "" then
        -- Where the list was before the search, to return there on clear.
        self.return_item = ((self.fc.page or 1) - 1) * (self.fc.perpage or 1) + 1
    end
    self.query = text
    local itemnumber = text == "" and self.return_item or nil
    local state = rawget(require("ui/widget/filechooser"), HOOK_STATE)
    local switch = state and state.call_orig
    if switch then
        -- Below our own hook: the table is already the one to show.
        switch(self.fc, nil, self:filtered(), itemnumber)
    end
end

-- Filters again with the current query, after a matching setting changed.
function SearchBar:refilter()
    if self.query == "" or not self.full then return end
    self.last = nil
    local state = rawget(require("ui/widget/filechooser"), HOOK_STATE)
    local switch = state and state.call_orig
    if switch then switch(self.fc, nil, self:filtered()) end
end

-- ---------------------------------------------------------------------------
-- Attaching the bar to a file chooser
-- ---------------------------------------------------------------------------

local function wantsBar(fc)
    return fc.name == "filemanager" and fc.content_group ~= nil and fc.inner_dimen ~= nil
        and LiveSearch.isEnabled()
end

local function addActive(fm, bar)
    if not fm then return end
    fm.active_widgets = fm.active_widgets or {}
    table.insert(fm.active_widgets, bar)
end

local function removeActive(fm, bar)
    local list = fm and fm.active_widgets
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == bar then table.remove(list, i) end
    end
end

local function attach(fc)
    local bar = SearchBar:new{ fc = fc, width = fc.inner_dimen.w }
    -- Right under the title bar, which is the first child of the group.
    table.insert(fc.content_group, 2, bar)
    fc.content_group:resetLayout()
    fc.inner_dimen.h = fc.inner_dimen.h - bar.dimen.h
    fc._sui_live_search = bar
    addActive(fc.ui, bar)
    return bar
end

local function detach(fc)
    local bar = rawget(fc, "_sui_live_search")
    if not bar then return end
    bar:cancelScheduled()
    bar:closeKeyboard()
    removeActive(fc.ui, bar)
    for i, child in ipairs(fc.content_group) do
        if child == bar then table.remove(fc.content_group, i); break end
    end
    fc.content_group:resetLayout()
    fc.inner_dimen.h = fc.inner_dimen.h + bar.dimen.h
    fc._sui_live_search = nil
    return bar
end

-- ---------------------------------------------------------------------------
-- Hook
-- ---------------------------------------------------------------------------

function LiveSearch.install(owner)
    local FileChooser = require("ui/widget/filechooser")
    local Patches = require("infra/sui_patches")
    local state = Patches._acquireHooks(FileChooser, HOOK_STATE, owner)
    if not state then return end
    -- Resolved through the class chain: FileChooser inherits it from Menu
    -- unless another patch already wrapped it.
    local orig = FileChooser.switchItemTable
    state.call_orig = orig
    Patches._addHook(state, FileChooser, "switchItemTable",
        function(fc, new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
            if new_item_table then
                local bar = rawget(fc, "_sui_live_search")
                if not bar and wantsBar(fc) then bar = attach(fc) end
                if bar then new_item_table = bar:take(new_item_table) end
            end
            return orig(fc, new_title, new_item_table, itemnumber, itemmatch, new_subtitle)
        end)
end

local function liveFileChooser()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    return fm and fm.file_chooser
end

function LiveSearch.setFuzzy(v)
    SUISettings:saveSetting(FUZZY_KEY, v and true or false)
    local fc = liveFileChooser()
    local bar = fc and rawget(fc, "_sui_live_search")
    if bar then bar:refilter() end
end

-- Removes the bar from the file manager on screen, putting its unfiltered
-- listing back, then releases the hook once no owner is left.
function LiveSearch.uninstall(owner)
    local FileChooser = package.loaded["ui/widget/filechooser"]
    if not FileChooser then return end
    local state = rawget(FileChooser, HOOK_STATE)
    local fc = liveFileChooser()
    local first = fc and ((fc.page or 1) - 1) * (fc.perpage or 1) + 1
    local bar = fc and detach(fc)
    if bar and bar.full and state then
        -- The whole list, at the same place (or where the search started).
        pcall(state.call_orig, fc, nil, bar.full, bar.query ~= "" and bar.return_item or first)
    end
    require("infra/sui_patches")._releaseHooks(FileChooser, HOOK_STATE, owner)
end

return LiveSearch
