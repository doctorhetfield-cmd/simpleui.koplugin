-- module_new_books.lua — Simple UI
-- "Cover row" module for New Books — recently added to the library
-- (by file date), built on top of GridRenderer.makeModule
-- (engines/sui_book_grid.lua). Not instantiable.
--
-- Split from module_book_rows.lua (which held Recent Books + New Books + TBR
-- in a single file) — see moduleregistry.lua for the require_mod.

local lfs    = require("libs/libkoreader-lfs")
local _ = require("infra/sui_i18n").translate

local GridRenderer = require("engines/sui_book_grid")
local LibraryScan  = require("engines/sui_library_scan")
local SH           = require("modules/module_books_shared")

local _BOOK_EXTS = {
    epub = true, mobi = true, azw3 = true, azw = true, kfx = true,
    pdf = true, djvu = true, fb2 = true, cbz = true, cbr = true,
    doc = true, docx = true, rtf = true, txt = true,
}

--- Recursively scan `dir` for book files, collecting path + mtime.
local function collectBooks(dir, files, depth, state)
    if depth > 5 or state.count > 5000 then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for f in iter, dir_obj do
        state.count = state.count + 1
        if state.count > 5000 then break end
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "file" then
                    local ext = f:match("%.([^%.]+)$")
                    if ext and _BOOK_EXTS[ext:lower()] then
                        files[#files + 1] = { path = path, mtime = attr.modification }
                    end
                elseif attr.mode == "directory" then
                    collectBooks(path, files, depth + 1, state)
                end
            end
        end
    end
end

--- Return up to `limit` file paths from home_dir, newest first by mtime.
local function scanNewBooks(limit)
    limit = limit or 5
    local home = LibraryScan.resolveHomeDir()
    if not home then return {} end

    local files = {}
    collectBooks(home, files, 1, { count = 0 })
    table.sort(files, function(a, b) return a.mtime > b.mtime end)

    local result = {}
    for i = 1, math.min(limit, #files) do
        result[i] = files[i].path
    end
    return result
end

-- Scan cache (heavy I/O — walks home_dir recursively), 5min TTL.
local _cached_new_fps      = nil
local _cached_new_fps_time = 0

--- Fetches 15 candidates (to compensate for the ones the filter will exclude), with a
--- 5-minute cache between disk scans.
local function getNewBooksCandidates()
    local now = os.time()
    if _cached_new_fps and (now - _cached_new_fps_time < 300) then
        return _cached_new_fps
    end
    local fps = scanNewBooks(15)
    _cached_new_fps      = fps
    _cached_new_fps_time = now
    return fps
end

local new_books_module = GridRenderer.makeModule{
    id          = "new_books",
    name        = _("New Books"),
    label       = _("New Books"),
    default_on  = false,  -- opt-in; users enable via Arrange Modules
    max_items   = 5,
    -- Lets the user pick 4 or 5 visible covers (see GridRenderer.makeModule's
    -- doc comment). getNewBooksCandidates() already fetches 15 candidates,
    -- well above either choice, so no change needed there.
    cols_choice = true,

    getFileList = function(_ctx) return getNewBooksCandidates() end,

    -- Excludes finished books. Unlike module_recent.lua, does NOT exclude the
    -- currently open book: "New Books" tracks recency of acquisition, not
    -- reading progress, so a freshly added book you've already started
    -- stays listed here until it's finished.
    filterItem = function(fp, ctx)
        return not SH.isFinished(fp, ctx.prefetched)
    end,

    -- Same defaults as Recent Books/Library/TBR: progress bar + "% Read"
    -- label by default, but user-editable via the "Progress Style" picker
    -- (see engines/sui_book_grid.lua's getMenuItems). Previously locked here
    -- with no equivalent reason in any other book-grid module — labelForItem
    -- below ("New"/"X% Read") only depends on draw_text being active
    -- (text/bar_text styles), same mechanism Recent already relies on.
    progress_style = { default = "bar_text" },

    -- All three off by default. "New" is user-editable (not locked) even
    -- though every cover in this module is already a new book — the badge
    -- would be redundant against labelForItem's own "New" text above, but
    -- some users like the extra visual marker on the cover itself, so it's
    -- left as a choice rather than forced off.
    badges = { pages = "off", series = "off", new = "off" },

    labelForItem = function(bd)
        if (bd.percent or 0) < 0.01 then return _("New") end
        return string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5))
    end,

    reset = function()
        GridRenderer.reset()
        _cached_new_fps      = nil
        _cached_new_fps_time = 0
    end,
}

-- Preserved as a public API (not called internally by this file,
-- but other modules/future versions may want to force a rescan).
function new_books_module.invalidateCache()
    _cached_new_fps      = nil
    _cached_new_fps_time = 0
end

return new_books_module
