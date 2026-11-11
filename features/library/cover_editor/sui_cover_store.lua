-- sui_cover_store.lua — Simple UI
-- Reads and changes a book's cover through KOReader's own custom-cover
-- mechanism (a `cover.<ext>` file in the book's sidecar folder), so a change
-- shows everywhere covers are drawn, inside and outside Simple UI.
--
-- Every change first saves the cover it replaces in an undo slot, one per
-- book, so the last change can be undone (and the undo itself undone). The
-- slot is keyed by the book's partial MD5, so it survives the book being
-- moved or renamed; it holds either the replaced custom image or a marker
-- meaning "the book's own cover".
--
-- Public API
--   CoverStore.load(file)                -> { bb, custom_path, width, height, filesize }
--                                           bb is owned by the caller (free it);
--                                           width/height are the image's own size
--   CoverStore.apply(file, image_path)   -> ok   use an image as the book's cover
--   CoverStore.restoreOriginal(file)     -> ok   back to the book's own cover
--   CoverStore.canUndo(file)             -> bool
--   CoverStore.undo(file)                -> ok   swap the cover with the undo slot

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Event       = require("ui/event")
local UIManager   = require("ui/uimanager")
local ffiutil     = require("ffi/util")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local util        = require("util")

local CoverStore = {}

-- Undo slots kept at most; the oldest are dropped beyond this.
local MAX_UNDO_SLOTS = 50
local EMBEDDED_MARKER = "embedded"

local function undoDir()
    return DataStorage:getDataDir() .. "/cache/simpleui/cover_undo"
end

local function bookKey(file)
    return util.partialMD5(file)
end

-- Path of the undo slot of `key`, or nil. Slots are "<key>.<ext>" (one dot
-- after the key), which keeps the transient "<key>.swap.<ext>" out.
local function findSlot(key)
    local dir = undoDir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return nil end
    local prefix = key .. "."
    for name in iter, dir_obj do
        if name:sub(1, #prefix) == prefix and not name:find(".", #prefix + 1, true) then
            return dir .. "/" .. name
        end
    end
end

-- Drops the oldest slots beyond MAX_UNDO_SLOTS.
local function pruneSlots()
    local dir = undoDir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    local slots = {}
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            slots[#slots + 1] = { path = path, mtime = lfs.attributes(path, "modification") or 0 }
        end
    end
    if #slots <= MAX_UNDO_SLOTS then return end
    table.sort(slots, function(a, b) return a.mtime < b.mtime end)
    for i = 1, #slots - MAX_UNDO_SLOTS do os.remove(slots[i].path) end
end

-- Saves the book's current cover in its undo slot, replacing any earlier one.
local function saveUndo(file, key)
    local old = findSlot(key)
    if old then os.remove(old) end
    util.makePath(undoDir())
    local custom = DocSettings:findCustomCoverFile(file)
    if custom then
        local dest = undoDir() .. "/" .. key .. "." .. util.getFileNameSuffix(custom):lower()
        if ffiutil.copyFile(custom, dest) ~= nil then
            logger.warn("SimpleUI cover: could not save undo copy of", custom)
        end
    else
        local f = io.open(undoDir() .. "/" .. key .. "." .. EMBEDDED_MARKER, "w")
        if f then f:close() end
    end
    pruneSlots()
end

-- Cover columns of a book info row, cleared so the cover is extracted again.
local BOOKINFO_COVER_RESET = {
    cover_fetched   = false,
    has_cover       = false,
    cover_sizetag   = false,
    cover_w         = false,
    cover_h         = false,
    cover_bb_type   = false,
    cover_bb_stride = false,
    cover_bb_data   = false,
}

-- Tells the open document, the book info cache and every screen that the
-- cover changed. Only the cover of the book info row is cleared: its title,
-- authors and series stay known while the cover is extracted again, so lists
-- grouped or filtered by them keep the book.
local function notifyChanged(file)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local reader = ReaderUI and ReaderUI.instance
    if reader and reader.doc_settings and reader.document and reader.document.file == file then
        reader.doc_settings:getCustomCoverFile(true)
    end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if ok and BookInfoManager then
        BookInfoManager:setBookInfoProperties(file, BOOKINFO_COVER_RESET)
    end
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

local function writeCustom(file, image_path)
    local old = DocSettings:findCustomCoverFile(file)
    if old then os.remove(old) end
    return DocSettings:flushCustomCover(file, image_path) == true
end

local function removeCustom(file)
    local old = DocSettings:findCustomCoverFile(file)
    if not old then return true end
    if not os.remove(old) then return false end
    DocSettings.removeSidecarDir((util.splitFilePathName(old)))
    return true
end

-- A custom image is decoded at its own size (opening it as a document would
-- scale it to the screen); the book's own cover comes from the document.
function CoverStore.load(file)
    local custom_path = DocSettings:findCustomCoverFile(file)
    local ok, bb = pcall(function()
        if custom_path then
            return require("ui/renderimage"):renderImageFile(custom_path, false)
        end
        local BookInfo = require("apps/filemanager/filemanagerbookinfo")
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local reader   = ReaderUI and ReaderUI.instance
        local document = reader and reader.document
        if document and document.file ~= file then document = nil end
        return BookInfo:getCoverImage(document, file, true)
    end)
    if not ok then
        logger.warn("SimpleUI cover: could not load cover of", file, bb)
        bb = nil
    end
    return {
        bb          = bb,
        custom_path = custom_path,
        width       = bb and bb:getWidth(),
        height      = bb and bb:getHeight(),
        filesize    = custom_path and lfs.attributes(custom_path, "size"),
    }
end

function CoverStore.apply(file, image_path)
    local key = bookKey(file)
    if key then saveUndo(file, key) end
    local ok = writeCustom(file, image_path)
    notifyChanged(file)
    return ok
end

function CoverStore.restoreOriginal(file)
    local key = bookKey(file)
    if key then saveUndo(file, key) end
    local ok = removeCustom(file)
    notifyChanged(file)
    return ok
end

function CoverStore.canUndo(file)
    local key = bookKey(file)
    return key ~= nil and findSlot(key) ~= nil
end

function CoverStore.undo(file)
    local key = bookKey(file)
    local slot = key and findSlot(key)
    if not slot then return false end
    -- Move the slot aside so saving the current cover cannot overwrite it.
    local ext  = util.getFileNameSuffix(slot)
    local swap = undoDir() .. "/" .. key .. ".swap." .. ext
    if not os.rename(slot, swap) then return false end
    saveUndo(file, key)
    local ok
    if ext == EMBEDDED_MARKER then
        ok = removeCustom(file)
    else
        ok = writeCustom(file, swap)
    end
    os.remove(swap)
    notifyChanged(file)
    return ok
end

return CoverStore
