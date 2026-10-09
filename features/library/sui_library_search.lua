-- sui_library_search.lua — Simple UI
--
-- Fast, library-wide book search by title, author, series or filename —
-- the metadata-search counterpart to KOReader's native File Search
-- (apps/filemanager/filemanagerfilesearcher), which matches filenames only
-- and re-walks the filesystem on every query.
--
-- This instead reuses the plugin's own cached library substrates, the same
-- ones the author/series/tags browse modes already rely on:
--   * engines/sui_library_scan             — cached recursive file list
--     (the candidate set)
--   * features/library/sui_metadata_source — cached bookinfo-backed rows
--     (title/authors/series), invalidated only when the library changes
-- so results return instantly even on a large library, without a per-query
-- filesystem or database walk.
--
-- The query is split on whitespace; every word must be found somewhere in
-- a book's title, author(s), series or filename. Matching is always
-- case-insensitive substring matching, every word against the combined
-- fields (AND across words) — there is no case-sensitivity toggle, unlike
-- File Search's filename matching, since a metadata lookup like this one
-- is meant to be a quick, forgiving filter rather than a precise pattern.
--
-- Public API
-- ----------
--   LibrarySearch.show()

local InputDialog    = require("ui/widget/inputdialog")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")
local T              = require("ffi/util").template

local LibraryScan    = require("engines/sui_library_scan")
local MetadataSource = require("features/library/sui_metadata_source")
local SUIWindow      = require("engines/sui_window")
local UI             = require("infra/sui_core")

local LibrarySearch = {}

local MAX_RESULTS = 400 -- keeps result collection/sorting bounded on e-readers

-- Opens a book by path. Mirrors engines/sui_screen_engine.lua's openBook():
-- normalizes a kobo virtual path (when the kobo integration is active) and
-- respects the "confirm before opening" setting. ReaderUI:showReader()
-- closes whatever is on screen (this results list included) atomically
-- before its first paint, so no explicit close is needed here.
local function _openBook(filepath)
    local function doOpen()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        local path = filepath
        local ok, PluginLoader = pcall(require, "pluginloader")
        local kobo = ok and PluginLoader and PluginLoader:getPluginInstance("kobo_plugin")
        if kobo and kobo.virtual_library then
            local vl = kobo.virtual_library
            if not next(vl.virtual_to_real) then
                pcall(function() vl:buildPathMappings() end)
            end
            if not vl:isVirtualPath(path) then
                path = vl:getVirtualPath(path) or path
            end
        end
        ReaderUI:showReader(path)
    end
    if G_reader_settings:isTrue("file_ask_to_open") then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text        = _("Open this file?") .. "\n\n" .. (filepath:match("([^/]+)$") or filepath),
            ok_text     = _("Open"),
            cancel_text = _("Cancel"),
            ok_callback = doOpen,
        })
    else
        doOpen()
    end
end

local function splitWords(query)
    local words = {}
    for w in query:gmatch("%S+") do words[#words + 1] = w:lower() end
    return words
end

-- One haystack string per candidate so each query word is checked with a
-- single find() rather than once per field.
local function buildHaystack(filename, row)
    local parts = { filename:lower() }
    if row then
        if row.title   then parts[#parts + 1] = row.title:lower()   end
        if row.authors then parts[#parts + 1] = row.authors:lower() end
        if row.series  then parts[#parts + 1] = row.series:lower()  end
    end
    return table.concat(parts, " ")
end

-- Runs the search in-process: LibraryScan and MetadataSource both hand back
-- already-cached in-memory tables (not a fresh filesystem/DB walk), so no
-- subprocess/Trapper wrapping is needed the way a live walk would require.
local function search(home_dir, query)
    local words = splitWords(query)
    if #words == 0 then return {} end

    local files = LibraryScan.getFileList(home_dir)
    local rows_by_path = {}
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if ok_bim and bim then
        local rows = MetadataSource.getMatchingFiles(bim, home_dir)
        for _, row in ipairs(rows) do rows_by_path[row[1]] = row end
    end

    local results = {}
    for _, fp in ipairs(files) do
        local filename = fp:match("([^/]+)$") or fp
        local row = rows_by_path[fp]
        local hay = buildHaystack(filename, row)
        local matched = true
        for _, w in ipairs(words) do
            if not hay:find(w, 1, true) then matched = false; break end
        end
        if matched then
            results[#results + 1] = {
                text      = (row and row.title) or filename,
                mandatory = row and row.authors or nil,
                fullpath  = fp,
            }
            if #results >= MAX_RESULTS then break end
        end
    end
    table.sort(results, function(a, b) return a.text:lower() < b.text:lower() end)
    return results
end

-- Builds one row per match: title, authors (when known) as a subtitle,
-- and a static "Open" label in place of the usual settings-row chevron —
-- a tap here opens the book directly rather than navigating to another
-- screen. Hold reproduces the shared per-book actions dialog, same as
-- elsewhere in the library.
local function buildResultRows(ctx, results)
    -- Same "Open" label for every row: computed once outside the loop so
    -- the loop index below doesn't need a name that collides with gettext's
    -- own `_` local.
    local open_label = _("Open")
    local rows = {}
    for _idx, item in ipairs(results) do
        rows[#rows + 1] = SUIWindow.ListRow{
            inner_w     = ctx.inner_w,
            title       = item.text,
            subtitle    = item.mandatory,
            right_value = open_label,
            separator   = true,
            on_tap      = function() _openBook(item.fullpath) end,
            on_hold     = function()
                local ok, BookHoldDialog = pcall(require, "features/library/sui_book_hold_dialog")
                if ok and BookHoldDialog then
                    BookHoldDialog.show(item.fullpath, {
                        refresh_fn = function() end,
                        reveal_fn  = function() ctx.repaint() end,
                    })
                end
            end,
        }
    end
    return rows
end

-- Results are shown as a SUI window list, matching the row style used
-- elsewhere for book lists (e.g. Reading History): title/subtitle on the
-- left, a static "Open" label on the right instead of a chevron, since
-- tapping a row opens the book directly rather than pushing to another
-- screen.
local function showResults(query, results)
    local win = SUIWindow:new{
        name          = "sui_win_library_search_results",
        title         = T(_("Search results: %1"), query),
        position      = "bottom",
        navpager_mode = require("infra/sui_config").isNavpagerEnabled(),
        screens       = {
            __root__ = function(ctx) return buildResultRows(ctx, results) end,
        },
    }
    win:show()
end

function LibrarySearch.show()
    local home_dir = LibraryScan.resolveHomeDir()
    if not home_dir then
        UI.Notify.toast(_("No home folder set."))
        return
    end

    local search_dialog
    local function doSearch()
        local query = search_dialog:getInputText()
        if query == "" then return end
        UIManager:close(search_dialog)
        local results = search(home_dir, query)
        if #results == 0 then
            UI.Notify.toast(T(_("No results for: %1"), query))
        else
            showResults(query, results)
        end
    end
    search_dialog = InputDialog:new{
        title = _("Search library"),
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(search_dialog) end },
                { text = _("Search"), is_enter_default = true, callback = doSearch },
            },
        },
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

return LibrarySearch
