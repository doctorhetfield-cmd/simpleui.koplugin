-- sui_bim_stamp.lua — Simple UI
-- Cheap change detector for the book-info database.
--
-- The stamp changes whenever the database file or its write-ahead log is
-- written (new books indexed, covers extracted), so a cache derived from the
-- database can compare stamps instead of re-reading it.
--
-- Public API
-- ----------
--   BimStamp.get() -> string | nil   (nil when there is no database yet)

local lfs = require("libs/libkoreader-lfs")

local BimStamp = {}

local _db_path -- resolved once; false when the settings dir is unavailable

local function dbPath()
    if _db_path == nil then
        local ok, DataStorage = pcall(require, "datastorage")
        _db_path = ok and DataStorage
            and (DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3")
            or false
    end
    return _db_path
end

function BimStamp.get()
    local path = dbPath()
    local db   = path and lfs.attributes(path)
    if not db then return nil end
    local wal = lfs.attributes(path .. "-wal")
    return string.format("%d:%d:%d:%d", db.size, db.modification,
        wal and wal.size or 0, wal and wal.modification or 0)
end

return BimStamp
