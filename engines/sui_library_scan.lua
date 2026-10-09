-- sui_library_scan.lua — Simple UI
-- Shared, cached recursive filesystem scanner for "all books in the
-- library" style modules (module_library.lua — the "Flat Library" module).
--
-- Note: module_new_books.lua keeps its own lighter walk (collectBooks/
-- scanNewBooks) for its capped top-15/TTL-based scan — not migrated to this
-- module, since a "show everything" scan needs different invalidation
-- (below) rather than a plain TTL.
--
-- Instead of a blind TTL, this tracks the mtime of every directory visited
-- during a walk and only re-walks when one of those mtimes has actually
-- changed (or the directory disappeared) — a cheap lfs.attributes() stat
-- per directory, not a full re-walk. SAFETY_TTL is a fallback for
-- filesystems/devices where directory mtimes aren't dependable.
--
-- Public API
-- ----------
--   LibraryScan.getFileList(home_dir) -> { fp, ... }              (cached)
--   LibraryScan.getRaw(home_dir)      -> { {fp,mtime,size}, ... } (cached)
--   LibraryScan.invalidate(home_dir?) -- forces a re-walk; no arg = all
--   LibraryScan.resolveHomeDir()      -> current KOReader library home dir
--
-- getFileList/getRaw share the same underlying cache — calling one primes
-- the other. Neither mutates cache entries: callers that need to sort get a
-- shallow copy.

local lfs      = require("libs/libkoreader-lfs")
local logger   = require("logger")
local Device   = require("device")
local BimStamp = require("features/library/sui_bim_stamp")

local LibraryScan = {}

--- Resolves the current library home directory: the user-configured
--- "home_dir" setting, falling back to the device default when unset or
--- empty. Single source of truth — module_stats_provider.lua,
--- module_library.lua and module_new_books.lua all need this.
function LibraryScan.resolveHomeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then home = Device.home_dir end
    return home
end


-- Extensions KOReader can open. Single source of truth — module_new_books.lua
-- keeps its own copy today (see the note above about a future migration).
LibraryScan.BOOK_EXTS = {
    epub = true, mobi = true, azw3 = true, azw = true, kfx = true,
    pdf = true, djvu = true, fb2 = true, cbz = true, cbr = true,
    doc = true, docx = true, rtf = true, txt = true,
}

local MAX_DEPTH  = 8      -- generous but bounded — no runaway recursion on odd mounts
local MAX_FILES  = 20000  -- hard cap so a misconfigured home_dir (e.g. "/") can't OOM an e-reader
local SAFETY_TTL = 300    -- seconds; re-walk unconditionally after this even with no detected change

-- Pseudo-filesystem directories to skip, matched on basename (the
-- hidden-entry check below wouldn't catch these since they don't start with
-- a dot). Only matters if home_dir is ever a root-ish path: /proc in
-- particular can contain huge numbers of virtual entries and self-looping
-- symlinks. MAX_DEPTH bounds the damage either way, but skipping avoids
-- wasted stat calls that can never yield a book.
local SYSTEM_DIR_NAMES = {
    proc = true, sys = true, dev = true, run = true, tmp = true,
    ["lost+found"] = true,
}

-- _cache[home_dir] = { list = {{fp,mtime,size},...}, dirs = {[path]=mtime}, checked_at = os.time() }
local _cache = {}

local function joinPath(parent, child)
    if parent:sub(-1) == "/" then return parent .. child end
    return parent .. "/" .. child
end

local function supportedExt(name)
    local ext = name:match("%.([^%.]+)$")
    return ext and LibraryScan.BOOK_EXTS[ext:lower()]
end

-- Recursive walk. `dirs` records every visited directory's mtime — used
-- afterwards to decide whether a re-walk is needed at all (see
-- dirsChanged below). `state.count` is a shared budget across the whole
-- recursion (not per-directory), so MAX_FILES is a true global cap.
local function walk(dir, depth, out, dirs, state)
    if depth > MAX_DEPTH or state.count > MAX_FILES then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return end

    for entry in iter, dir_obj do
        state.count = state.count + 1
        if state.count > MAX_FILES then break end
        -- Skip "." / ".." any hidden entry (dotfiles, .git, .calibre-cache,
        -- etc.), and known pseudo-filesystem directories (see
        -- SYSTEM_DIR_NAMES above).
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "."
                and not SYSTEM_DIR_NAMES[entry] then
            local fp = joinPath(dir, entry)
            local attr = lfs.attributes(fp)
            if attr then
                if attr.mode == "directory" then
                    -- .sdr sidecars hold per-book metadata, not books, and
                    -- their mtime churns on every book close — descending
                    -- into them would falsely invalidate the cache below.
                    if entry:sub(-4) ~= ".sdr" then
                        dirs[fp] = attr.modification or 0
                        walk(fp, depth + 1, out, dirs, state)
                    end
                elseif attr.mode == "file" and supportedExt(entry) then
                    -- size kept alongside mtime so "sort by file size" has
                    -- data without a second stat per book later.
                    out[#out + 1] = { fp = fp, mtime = attr.modification or 0, size = attr.size or 0 }
                end
            end
        end
    end
end

-- True if any tracked directory's mtime no longer matches what was
-- recorded (a file/folder was added, removed or renamed inside it), or a
-- tracked directory disappeared entirely.
local function dirsChanged(dirs)
    for path, recorded in pairs(dirs) do
        local now = lfs.attributes(path, "modification")
        if not now or now ~= recorded then return true end
    end
    return false
end

local function rescan(home_dir)
    local out, dirs = {}, {}
    local root_mtime = lfs.attributes(home_dir, "modification")
    if root_mtime then dirs[home_dir] = root_mtime end
    walk(home_dir, 0, out, dirs, { count = 0 })
    local entry = { list = out, dirs = dirs, checked_at = os.time() }
    _cache[home_dir] = entry
    logger.dbg("simpleui: sui_library_scan: rescanned", home_dir, "->", #out, "books")
    return entry
end

-- getEntry(home_dir) -> cache entry, rescanning only when actually needed.
local function getEntry(home_dir)
    local entry = _cache[home_dir]
    if not entry then return rescan(home_dir) end
    local now = os.time()
    if now - entry.checked_at >= SAFETY_TTL then return rescan(home_dir) end
    if dirsChanged(entry.dirs) then return rescan(home_dir) end
    -- Nothing changed — cheap stat-only check passed. Keep serving the
    -- cached list, but bump checked_at so SAFETY_TTL counts from this
    -- confirmed-fresh point rather than the original scan time.
    entry.checked_at = now
    return entry
end

--- Raw scan results — { {fp, mtime, size}, ... }, in directory-traversal
--- order (not sorted for display). Callers needing a specific order
--- (title, date, size, ...) sort a shallow copy themselves; this never
--- mutates the cache.
function LibraryScan.getRaw(home_dir)
    if not home_dir or home_dir == "" then return {} end
    local entry = getEntry(home_dir)
    local copy = {}
    for i = 1, #entry.list do copy[i] = entry.list[i] end
    return copy
end

--- Convenience wrapper — just the filepaths, same order as getRaw().
function LibraryScan.getFileList(home_dir)
    local raw = LibraryScan.getRaw(home_dir)
    local fps = {}
    for i = 1, #raw do fps[i] = raw[i].fp end
    return fps
end

--- Forces the next call to re-walk the filesystem, regardless of the
--- mtime/TTL checks above. For callers that know the library changed
--- through a path this cache can't observe on its own (e.g. plugin
--- teardown, or a future manual "Rescan library" action). No argument
--- clears every cached home_dir.
function LibraryScan.invalidate(home_dir)
    if home_dir then
        _cache[home_dir] = nil
    else
        _cache = {}
    end
end

-- ---------------------------------------------------------------------------
-- Batch text-metadata read (title/authors) — avoids opening a DocSettings
-- sidecar per book when sorting the whole library by Title/Author (see
-- module_library.lua's cachedTitle/cachedAuthor).
--
-- Reads BookInfoManager's `bookinfo` SQLite table directly in one query
-- instead of N per-file lookups. Even a text-only SELECT there isn't free —
-- title/authors share rows with the cover BLOB, so SQLite still pages those
-- rows off disk, which can cost up to a couple of seconds on a large
-- library. To avoid paying that on every cold boot, the row map is
-- snapshotted to a small zstd file, fingerprinted by BIM's database file
-- (size + mtime): any BIM write invalidates the fingerprint and triggers a
-- fresh SQL read, which re-saves the snapshot.
--
-- A book in LibraryScan.getRaw() that isn't in this map hasn't been
-- extracted by BIM yet (or extraction failed) — callers fall back to a
-- per-file read for that one book.
-- ---------------------------------------------------------------------------

local BATCH_META_SNAPSHOT_VERSION = 1
local _batch_meta_cache = nil -- in-memory, for the lifetime of this KOReader session

local function getBookInfoMgr()
    local ok, bim = pcall(require, "bookinfomanager")
    return ok and bim or nil
end

local function bimDbFingerprint()
    local stamp = BimStamp.get()
    return stamp and string.format("v%d:%s", BATCH_META_SNAPSHOT_VERSION, stamp)
end

local function snapshotPersist()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_p, Persist = pcall(require, "persist")
    if not (ok_ds and ok_p and DataStorage and Persist) then return nil end
    local ok_new, p = pcall(Persist.new, Persist, {
        path  = DataStorage:getDataDir() .. "/cache/simpleui_library_textmeta.dat",
        codec = "zstd",
    })
    return ok_new and p or nil
end

local function loadSnapshot()
    local fingerprint = bimDbFingerprint()
    if not fingerprint then return nil end
    local p = snapshotPersist()
    if not p then return nil end
    local ok, t = pcall(p.load, p)
    if ok and type(t) == "table"
            and t.fingerprint == fingerprint
            and type(t.map) == "table" then
        return t.map
    end
    return nil
end

local function saveSnapshot(map)
    local fingerprint = bimDbFingerprint()
    if not fingerprint then return end
    local p = snapshotPersist()
    if not p then return end
    pcall(p.save, p, { fingerprint = fingerprint, map = map })
end

-- Reads BIM's bookinfo table directly (there's no bulk accessor in its
-- public API) in one SQL call. Returns (directory..filename) -> {title=,
-- authors=} for every row with in_progress=0 (successfully extracted), or
-- nil on failure — callers fall back to a per-book read. Wrapped in pcall
-- since a future BIM schema change could break this direct access.
local function loadBatchFromBim()
    local bim = getBookInfoMgr()
    if not bim or type(bim.openDbConnection) ~= "function" then return nil end
    local ok_open = pcall(function() bim:openDbConnection() end)
    if not ok_open then return nil end
    local conn = bim.db_conn
    if not conn or type(conn.exec) ~= "function" then return nil end

    local sql = "SELECT directory, filename, title, authors FROM bookinfo WHERE in_progress=0;"
    local rows
    local ok, err = pcall(function() rows = conn:exec(sql) end)
    if not ok then
        logger.warn("simpleui: sui_library_scan: batch BIM read failed:", tostring(err))
        return nil
    end
    if not rows then return {} end -- empty DB

    -- ljsqlite3:exec returns column-major arrays: rows[col_index][row_index].
    local n = (rows[1] and #rows[1]) or 0
    local map = {}
    for i = 1, n do
        -- BIM's `directory` column always stores a trailing slash, so
        -- concatenating with `filename` directly reconstructs the same
        -- fullpath format the walk above produces (joinPath).
        local fp = (rows[1][i] or "") .. (rows[2][i] or "")
        map[fp] = { title = rows[3][i], authors = rows[4][i] }
    end
    return map
end

--- Title/author for every book BookInfoManager has already extracted, in
--- one query (or a disk snapshot when BIM's database hasn't changed since
--- it was last saved). Returns (fullpath) -> {title=, authors=}. Falls
--- back to an empty table if BIM/its DB isn't reachable at all — callers
--- treat a missing entry as "not yet extracted" and read that one book
--- individually instead.
function LibraryScan.getBatchTextMeta()
    if _batch_meta_cache then return _batch_meta_cache end
    local map = loadSnapshot()
    if map then
        _batch_meta_cache = map
        return map
    end
    map = loadBatchFromBim() or {}
    _batch_meta_cache = map
    saveSnapshot(map)
    return map
end

--- Forces the next getBatchTextMeta() call to re-read from BIM (and
--- re-save the snapshot) instead of serving the in-memory cache.
function LibraryScan.invalidateTextMeta()
    _batch_meta_cache = nil
end

return LibraryScan
