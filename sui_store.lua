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
        local dir = src:sub(1, 1) == "@" and src:sub(2):match("^(.*)/[^/]+$") or "."
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
-- DeletedBooks — persistent store for finished books removed from the device.
--
-- When "Preserve deleted books in statistics" is enabled (default: on) and a
-- book whose summary.status == "complete" is deleted via the KOReader file
-- manager, this module records a minimal entry so the book continues to be
-- counted in books_year / books_total on the homescreen.
--
-- Storage: a single key "simpleui_deleted_books" inside the existing
-- sui_settings.lua file.  Value is a table keyed by partial_md5_checksum:
--
--   {
--     ["<md5>"] = { title = "…", authors = "…", year = 2024 },
--     …
--   }
--
-- year is the calendar year (integer) captured at deletion time from
-- summary.modified — the same source used by countMarkedReadBoth.
--
-- Public API:
--   DeletedBooks.isEnabled()          → boolean (nil → true, i.e. on by default)
--   DeletedBooks.add(md5, title, authors, year)
--   DeletedBooks.removeByMd5(md5)
--   DeletedBooks.getAll()             → table (keyed by md5) or {}
-- ---------------------------------------------------------------------------

local STORE_KEY = "simpleui_deleted_books"

local DeletedBooks = {}

function DeletedBooks.isEnabled()
    return SUISettings:nilOrTrue("simpleui_preserve_deleted_books_in_stats")
end

-- Load the raw store table (always a copy-by-reference of the live data).
local function _load()
    return SUISettings:get(STORE_KEY) or {}
end

-- Persist the store table immediately.
local function _save(tbl)
    SUISettings:set(STORE_KEY, tbl)
end

--- Add or update an entry for a deleted finished book.
-- md5     : partial_md5_checksum string (key used by the statistics DB)
-- title   : book title string (may be nil)
-- authors : book authors string (may be nil)
-- year    : integer calendar year when the book was finished
function DeletedBooks.add(md5, title, authors, year)
    if not md5 then return end
    local tbl = _load()
    tbl[md5] = {
        title   = title   or "",
        authors = authors or "",
        year    = year    or 0,
    }
    _save(tbl)
end

--- Remove the entry whose key matches md5 (no-op when absent).
function DeletedBooks.removeByMd5(md5)
    if not md5 then return end
    local tbl = _load()
    if tbl[md5] == nil then return end   -- nothing to do
    tbl[md5] = nil
    _save(tbl)
end

--- Return the full store table (keyed by md5).  Empty table when nothing stored.
function DeletedBooks.getAll()
    return _load()
end

SUISettings.DeletedBooks = DeletedBooks

return SUISettings
