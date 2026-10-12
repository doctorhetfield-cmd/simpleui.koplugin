-- sui_settings.lua — Simple UI
-- Dedicated settings store for all SimpleUI preferences.
--
-- Settings are persisted to:
--   DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
--
-- This file is inside the simpleui/ user-data directory that is created on
-- first run by main.lua — the same folder that holds sui_icons/, sui_quotes/,
-- etc.  Keeping plugin settings here instead of in the global G_reader_settings
-- avoids namespace pollution and makes it easy to back up or reset only the
-- SimpleUI configuration.
--
-- Public API — all methods use colon syntax (consistent with G_reader_settings):
--
--   SUISettings:get(key)              → value or nil
--   SUISettings:set(key, value)       → (saves immediately)
--   SUISettings:del(key)              → (removes key)
--   SUISettings:isTrue(key)           → boolean  (nil → false)
--   SUISettings:nilOrTrue(key)        → boolean  (nil → true)
--   SUISettings:flush()               → force-write to disk
--
-- Compatibility aliases (identical behaviour, G_reader_settings-style names):
--
--   SUISettings:readSetting(key)      → same as :get(key)
--   SUISettings:saveSetting(key, v)   → same as :set(key, v)
--   SUISettings:delSetting(key)       → same as :del(key)
--
-- The module is a singleton: requiring it multiple times always returns the
-- same table (Lua's module cache ensures this).

local logger = require("logger")

-- ---------------------------------------------------------------------------
-- Resolve the settings file path at load time.
-- ---------------------------------------------------------------------------

local _settings_path = nil

local function _getPath()
    if _settings_path then return _settings_path end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        _settings_path = DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
    else
        -- Fallback: store next to this file (should never happen in practice).
        local src = debug.getinfo(1, "S").source or "@./"
        local dir = src:sub(1, 1) == "@" and src:sub(2):match("^(.*)/[^/]+/[^/]+$") or "."
        _settings_path = dir .. "/sui_settings.lua.data"
        logger.warn("simpleui/sui_settings: DataStorage unavailable, using fallback path:", _settings_path)
    end
    return _settings_path
end

-- ---------------------------------------------------------------------------
-- Load / create the underlying LuaSettings instance.
-- ---------------------------------------------------------------------------

local _store = nil  -- LuaSettings instance, initialised lazily on first use.

local function _getStore()
    if _store then return _store end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then
        -- LuaSettings unavailable — return a minimal in-memory shim so the
        -- plugin does not crash.  Settings will not persist across restarts.
        logger.warn("simpleui/sui_settings: LuaSettings unavailable, using in-memory fallback")
        local _mem = {}
        _store = {
            data         = _mem,
            readSetting  = function(_, k)    return _mem[k] end,
            saveSetting  = function(_, k, v) _mem[k] = v end,
            delSetting   = function(_, k)    _mem[k] = nil end,
            flush        = function() end,
        }
        return _store
    end
    local path = _getPath()
    _store = LuaSettings:open(path)
    logger.dbg("simpleui/sui_settings: opened", path)
    return _store
end

-- ---------------------------------------------------------------------------
-- Public module table
-- ---------------------------------------------------------------------------

local SUISettings = {}

--- Read a value.  Returns nil when the key is absent, or default_value if provided.
function SUISettings:get(key, default_value)
    return _getStore():readSetting(key, default_value)
end

--- Write a value and persist to disk immediately.
--- Passing nil is equivalent to SUISettings:del(key).
function SUISettings:set(key, value)
    if value == nil then
        _getStore():delSetting(key)
    else
        _getStore():saveSetting(key, value)
    end
    -- LuaSettings:saveSetting() only updates in-memory data; KOReader does
    -- NOT automatically flush our file on exit (only G_reader_settings gets
    -- that treatment).  Flush here so every write is immediately durable.
    if _store then _store:flush() end
end

--- Write a value to the in-memory settings table WITHOUT flushing to disk.
--- Use this for values written frequently from hot/latency-sensitive paths
--- (e.g. a stale-data cache refreshed on every background prefetch) where an
--- immediate flush() on every write would reintroduce the exact synchronous
--- I/O cost the caller is trying to avoid.
---
--- The value stays durable in memory for the rest of this process (readable
--- immediately via :get()/:readSetting()), but is only guaranteed to survive
--- a crash/power-loss once something else calls :flush() (or :set()/:del(),
--- which always flush). Callers that need eventual durability should ensure
--- a :flush() happens on a low-frequency, non-critical-path event instead
--- (e.g. SimpleUIPlugin:onSuspend() in main.lua already does this for all
--- pending settings, including any written via this method).
function SUISettings:setNoFlush(key, value)
    if value == nil then
        _getStore():delSetting(key)
    else
        _getStore():saveSetting(key, value)
    end
    -- Deliberately no :flush() call here — see docstring above.
end

--- Delete a value from the in-memory settings table WITHOUT flushing to disk.
--- Companion to :setNoFlush() for the same latency-sensitive use case.
function SUISettings:delNoFlush(key)
    _getStore():delSetting(key)
end

--- Delete a key and persist to disk immediately.
function SUISettings:del(key)
    _getStore():delSetting(key)
    if _store then _store:flush() end
end

--- Returns true only when the stored value is the boolean true.
--- Absent keys and all other values return false.
function SUISettings:isTrue(key)
    local v = _getStore():readSetting(key)
    return v == true
end

--- Returns true when the stored value is anything other than false.
--- Absent keys (nil) return true — use this for "enabled unless explicitly disabled".
function SUISettings:nilOrTrue(key)
    local v = _getStore():readSetting(key)
    return v ~= false
end

--- Force an immediate write to disk.
function SUISettings:flush()
    if _store then
        _store:flush()
    end
end

-- ---------------------------------------------------------------------------
-- Compatibility aliases — G_reader_settings-style method names.
-- ---------------------------------------------------------------------------

function SUISettings:readSetting(key, default_value)
    return _getStore():readSetting(key, default_value)
end

function SUISettings:saveSetting(key, value)
    if value == nil then
        _getStore():delSetting(key)
    else
        _getStore():saveSetting(key, value)
    end
    if _store then _store:flush() end
end

function SUISettings:delSetting(key)
    _getStore():delSetting(key)
    if _store then _store:flush() end
end

--- Iterate over all key/value pairs currently stored in SUISettings.
--- Returns a stateless iterator compatible with generic for:
---   for k, v in SUISettings:iterateKeys() do ... end
--- NOTE: do NOT call SUISettings:set() or :del() inside the loop;
--- modifying the table while iterating has undefined behaviour in Lua.
--- Collect changes first, then apply them after the loop.
function SUISettings:iterateKeys()
    local data = _getStore().data  -- LuaSettings exposes its raw data table
    if type(data) ~= "table" then
        return function() end  -- empty iterator — store not yet initialised
    end
    return next, data, nil
end

-- ---------------------------------------------------------------------------
-- FinishedBooks — persistent ledger of every finished book.
--
-- The ledger is the source of truth for the "books read" figures: counting
-- from it needs neither the reading history nor any sidecar access, and a
-- finished book stays recorded after its file is deleted.
--
-- Storage: one key "simpleui_finished_books" inside sui_settings.lua:
--
--   {
--     initialised = true,            -- a full reconcile has run
--     books = {
--       ["<partial md5>"] = {        -- a book tracked from its sidecar
--         title, authors   strings
--         finished         completion date "YYYY-MM-DD", or just "YYYY"
--                          when only the year is known; nil when unknown
--         excluded         true when left out of the totals and goals
--         path             last known file path
--         gone             true once the file no longer exists on the device
--       },
--       ["manual:<id>"] = {          -- a book entered by hand
--         manual           true
--         title, authors   strings (authors may be empty)
--         started          start stamp, "YYYY-MM-DD" or "YYYY"; nil when unknown
--         finished         completion stamp, same formats; nil when unknown
--       },
--       ["manual:bulk:<year>"] = {   -- books entered as a plain number
--         manual           true
--         count            number of books
--         finished         "YYYY"
--       },
--     },
--   }
--
-- A manual entry has no file, so it is never reconciled and never `gone`. It
-- belongs to the year of its completion stamp, else of its start stamp.
--
-- A table stored under the legacy "simpleui_deleted_books" key is folded in
-- on first load as `gone` entries. A number stored under the legacy
-- "simpleui_reading_goal_physical" key is folded in as the bulk entry of the
-- current year.
--
-- Public API:
--   FinishedBooks.preserveGone()      → boolean (nil → true, i.e. on by default)
--   FinishedBooks.manualInAllTime()   → boolean (nil → true, i.e. on by default)
--   FinishedBooks.setManualInAllTime(enabled)
--   FinishedBooks.load()              → ledger table (live reference)
--   FinishedBooks.save(ledger)        → persists the ledger
-- ---------------------------------------------------------------------------

local LEDGER_KEY          = "simpleui_finished_books"
local LEGACY_KEY          = "simpleui_deleted_books"
local LEGACY_PHYSICAL_KEY = "simpleui_reading_goal_physical"

local FinishedBooks = {}

--- Whether finished books whose file is gone still count towards the totals.
function FinishedBooks.preserveGone()
    return SUISettings:nilOrTrue("simpleui_preserve_deleted_books_in_stats")
end

--- Whether manual books count towards the all-time total. They always count
--- towards the year they belong to.
function FinishedBooks.manualInAllTime()
    return SUISettings:nilOrTrue("simpleui_manual_books_in_all_time")
end

function FinishedBooks.setManualInAllTime(enabled)
    SUISettings:saveSetting("simpleui_manual_books_in_all_time", enabled and true or false)
end

local function _migrateLegacy(books)
    for md5, stored in pairs(SUISettings:get(LEGACY_KEY) or {}) do
        local year = tonumber(stored.year)
        books[md5] = {
            title    = stored.title or "",
            authors  = stored.authors or "",
            finished = year and year > 0 and string.format("%04d", year) or nil,
            gone     = true,
        }
    end
end

-- Folds the legacy plain count of manually tracked books into the ledger as
-- the bulk entry of the current year, then drops the legacy key.
local function _foldLegacyCount(ledger)
    local legacy = SUISettings:get(LEGACY_PHYSICAL_KEY)
    if legacy == nil then return end

    local count = math.floor(tonumber(legacy) or 0)
    if count > 0 then
        local year = os.date("%Y")
        ledger.books["manual:bulk:" .. year] = { manual = true, count = count, finished = year }
        SUISettings:set(LEDGER_KEY, ledger)
    end
    SUISettings:del(LEGACY_PHYSICAL_KEY)
end

--- Returns the ledger, creating it (and migrating legacy data) on first use.
--- The returned table is the live stored one: mutate it, then save() it.
function FinishedBooks.load()
    local ledger = SUISettings:get(LEDGER_KEY)
    if not ledger then
        ledger = { books = {} }
        _migrateLegacy(ledger.books)
        SUISettings:set(LEDGER_KEY, ledger)
        SUISettings:del(LEGACY_KEY)
    end
    _foldLegacyCount(ledger)
    return ledger
end

--- Persists a ledger obtained from load().
function FinishedBooks.save(ledger)
    SUISettings:set(LEDGER_KEY, ledger)
end

SUISettings.FinishedBooks = FinishedBooks

return SUISettings
