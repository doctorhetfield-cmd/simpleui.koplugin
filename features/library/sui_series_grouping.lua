-- sui_series_grouping.lua — Simple UI
-- Groups consecutive series books into a virtual folder-like item when
-- browsing a REAL folder in FileManager (e.g. "Hainish Cycle" appears as
-- one entry instead of 5 loose books). Entering a group uses a lightweight
-- switchItemTable — it stays "inside" the same real folder (scroll position,
-- back-button target, and breadcrumb are all the real folder's), unlike the
-- full author/series/tags browse mode in sui_library_browse.lua which
-- navigates to an actual virtual path.
--
-- The grouping algorithm below deliberately does NOT go through
-- sui_metadata_source: it reuses the item_table FileChooser already built
-- for this directory (progress badges, non-book entries, the user's chosen
-- collate/sort function) rather than re-querying the database. Recomputing
-- that from SQL would need a second round trip and would have to
-- re-derive things SQL doesn't know about (reading progress, subfolder
-- entries) — more expensive and more code, not less.
--
-- What WAS duplicated with sui_library_browse.lua — the cover-picker
-- dialog, the create-collection dialog, and cover-override storage — now
-- goes through sui_group_actions / sui_cover_overrides instead of a local
-- copy. That's the actual reuse win here.
--
-- Books are grouped by FilterState's series key, so spelling variants of one
-- series name (case, spacing, a trailing " #n") share a single group.
--
-- Depends on sui_foldercovers for: isEnabled(), getSeriesGrouping(),
-- resolveStyle(), invalidateItemTableCache() (the FileChooser item-table
-- cache is a cross-cutting concern that lives with the strip-patch install).
--
-- Public API
-- ----------
--   SeriesGrouping.install()
--   SeriesGrouping.uninstall()
--   SeriesGrouping.isInSeriesView(fc)
--   SeriesGrouping.exitSeriesView(fc)
--   SeriesGrouping.openCoverPicker(vpath, fc, BookInfoManager)
--   SeriesGrouping.createCollection(vpath, series_name)
--   SeriesGrouping.hasGroup(vpath)  -- true if vpath is a known series-group path

local _             = require("infra/sui_i18n").translate
local FileChooser    = require("ui/widget/filechooser")
local CoverOverrides = require("features/library/sui_cover_overrides")
local GroupActions   = require("features/library/sui_group_actions")
local FolderCovers   = require("features/library/sui_foldercovers")
local FilterState    = require("features/library/sui_filter_state")
local MetadataSource = require("features/library/sui_metadata_source")

local SeriesGrouping = {}

-- _sg_current holds state while the user is inside a virtual series folder:
--   series_name:    used to re-find the group item on return to parent.
--   parent_page:    restores the scroll position in the parent list.
-- nil when in a real filesystem folder.
local _sg_current           = nil
local _sg_last_evicted_path = nil

-- vpath -> array of item_table entries (the books in that series group).
-- This IS the "group's book list" — both the cover picker and create
-- collection read from it, same as the browse-mode leaf reads from
-- sui_metadata_source.getMatchingFiles.
local _sg_items_cache = {}

function SeriesGrouping.hasGroup(vpath)
    return _sg_items_cache[vpath] ~= nil
end

-- Returns the cached item list for a series-group vpath, or nil. Used by
-- sui_foldercovers.lua's resolveStyle() to count books for "auto" style
-- (single vs quad) without this module needing to know anything about
-- cover styling.
function SeriesGrouping.getGroupItems(vpath)
    return _sg_items_cache[vpath]
end

-- ---------------------------------------------------------------------------
-- Shared actions (previously duplicated with sui_library_browse.lua)
-- ---------------------------------------------------------------------------

function SeriesGrouping.openCoverPicker(vpath, fc, BookInfoManager)
    local series_items = _sg_items_cache[vpath]
    local picker_items = {}
    for _, item in ipairs(series_items or {}) do
        if item.path then
            local bi = BookInfoManager:getBookInfo(item.path, false)
            picker_items[#picker_items + 1] = {
                path  = item.path,
                title = bi and bi.title and bi.title ~= "" and bi.title or nil,
            }
        end
    end
    GroupActions.openCoverPicker{
        title         = _("Folder cover"),
        override_key  = vpath,
        items         = picker_items,
        menu          = fc,
        empty_message = _("No books found in this series."),
    }
end

function SeriesGrouping.createCollection(vpath, series_name)
    local series_items = _sg_items_cache[vpath]
    local paths = {}
    for _, item in ipairs(series_items or {}) do
        if item.path then paths[#paths + 1] = item.path end
    end
    GroupActions.createCollection{
        suggested_name = series_name or "",
        paths          = paths,
        empty_message  = _("No books found in this series."),
    }
end

-- ---------------------------------------------------------------------------
-- Grouping — groups series books into virtual folder items in item_table
-- (in place). Books that share a series name are collapsed into one group
-- item; singletons are left as individual book entries.
-- ---------------------------------------------------------------------------

-- Series properties of a book. Folders are read in one query each and kept
-- in `folder_cache` (folder -> properties by filename | false) for the
-- duration of one item-table pass.
local function seriesPropsOf(BookInfoManager, folder_cache, item)
    if item.doc_props then return item.doc_props end
    local dir, filename = item.path:match("^(.*/)([^/]+)$")
    if not dir then return BookInfoManager:getDocProps(item.path) end
    local folder = folder_cache[dir]
    if folder == nil then
        folder = MetadataSource.getFolderSeries(BookInfoManager, dir) or false
        folder_cache[dir] = folder
    end
    if not folder then return BookInfoManager:getDocProps(item.path) end
    return folder[filename]
end

local function sgProcessItemTable(item_table, file_chooser)
    if not FolderCovers.getSeriesGrouping()   then return end
    if not file_chooser or not item_table     then return end
    if item_table._sg_is_series_view          then return end
    if file_chooser.show_current_dir_for_hold then return end

    -- Evict stale _sg_items_cache entries for the current directory.
    local current_path = file_chooser.path
    if current_path and current_path ~= _sg_last_evicted_path then
        _sg_last_evicted_path = current_path
        local prefix = current_path
        if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
        for k in pairs(_sg_items_cache) do
            if k:sub(1, #prefix) == prefix then _sg_items_cache[k] = nil end
        end
    end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then return end

    local folder_cache    = {}
    local series_map      = {}
    local processed       = {}
    local book_count      = 0
    local no_series_count = 0

    for _, item in ipairs(item_table) do
        if item.is_go_up then
            processed[#processed + 1] = item
        else
            if not item.sort_percent then item.sort_percent = item.percent_finished or 0 end
            -- Do NOT default percent_finished to 0: nil means "never opened / no sidecar data"
            -- and is the gate used by has_progress and the "New" badge. Collapsing nil→0 here
            -- would make every book look like it has been opened with 0% progress.
            if item.opened == nil then item.opened = false end

            local handled = false
            if (item.is_file or item.file) and item.path then
                book_count = book_count + 1
                local doc_props = seriesPropsOf(BookInfoManager, folder_cache, item)
                local sname, suffix_index = FilterState.parseSeries(doc_props and doc_props.series)
                if sname then
                    local skey = FilterState.seriesKey(sname)
                    item._sg_series_index = doc_props.series_index or suffix_index or 0
                    if not series_map[skey] then
                        local base_path  = item.path:match("(.*/)") or ""
                        local group_attr = {}
                        if item.attr then
                            for k, v in pairs(item.attr) do group_attr[k] = v end
                        end
                        group_attr.mode = "directory"
                        local vpath      = base_path .. sname
                        local group_item = {
                            text             = sname,
                            is_file          = false,
                            is_directory     = true,
                            is_series_group  = true,
                            path             = vpath,
                            series_items     = { item },
                            attr             = group_attr,
                            mode             = "directory",
                            sort_percent     = item.sort_percent,
                            percent_finished = item.percent_finished,
                            opened           = item.opened,
                            doc_props        = item.doc_props or {
                                series        = sname,
                                series_index  = 0,
                                display_title = sname,
                            },
                            suffix = item.suffix,
                        }
                        series_map[skey]          = group_item
                        group_item._sg_list_index = #processed + 1
                        processed[#processed + 1] = group_item
                    else
                        local si = series_map[skey].series_items
                        si[#si + 1] = item
                    end
                    handled = true
                else
                    no_series_count = no_series_count + 1
                end
            end
            if not handled then processed[#processed + 1] = item end
        end
    end

    -- If every book is in the same single series the folder is already
    -- organised — skip grouping to avoid a redundant nesting level.
    local series_count = 0
    for _ in pairs(series_map) do
        series_count = series_count + 1
        if series_count > 1 then break end
    end
    if series_count == 1 and no_series_count == 0 and book_count > 0 then return end

    -- Ungroup singleton series; sort and cache multi-book groups.
    for _, group in pairs(series_map) do
        local items = group.series_items
        if #items == 1 then
            local idx = group._sg_list_index
            if idx and processed[idx] == group then processed[idx] = items[1] end
        else
            table.sort(items, function(a, b)
                return (a._sg_series_index or 0) < (b._sg_series_index or 0)
            end)
            group.mandatory             = tostring(#items) .. " \u{F016}"
            _sg_items_cache[group.path] = items
        end
    end

    -- Re-sort the full list using FileChooser's sort function.
    local ok_collate, collate = pcall(function() return file_chooser:getCollate() end)
    local collate_obj = ok_collate and collate or nil
    local reverse     = G_reader_settings:isTrue("reverse_collate")
    local sort_func
    pcall(function() sort_func = file_chooser:getSortingFunction(collate_obj, reverse) end)
    local mixed = G_reader_settings:isTrue("collate_mixed")
        and collate_obj and collate_obj.can_collate_mixed

    local final   = {}
    local up_item = nil

    if mixed then
        local to_sort = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then up_item = item
            else to_sort[#to_sort + 1] = item end
        end
        if sort_func then pcall(table.sort, to_sort, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, item in ipairs(to_sort) do final[#final + 1] = item end
    else
        local dirs  = {}
        local files = {}
        for _, item in ipairs(processed) do
            if item.is_go_up then
                up_item = item
            elseif item.is_directory or item.is_series_group
                or (item.attr and item.attr.mode == "directory")
                or item.mode == "directory"
            then
                dirs[#dirs + 1] = item
            else
                files[#files + 1] = item
            end
        end
        if sort_func then pcall(table.sort, dirs,  sort_func) end
        if sort_func then pcall(table.sort, files, sort_func) end
        if up_item then final[#final + 1] = up_item end
        for _, d in ipairs(dirs)  do final[#final + 1] = d end
        for _, f in ipairs(files) do final[#final + 1] = f end
    end

    -- Replace item_table contents in place.
    for i = #item_table, 1, -1 do item_table[i] = nil end
    for i, v in ipairs(final)   do item_table[i] = v   end
end

-- Switch file_chooser into a virtual series folder view.
local function sgOpenGroup(file_chooser, group_item)
    if not file_chooser then return end
    local items = group_item.series_items
    _sg_current = {
        series_name = group_item.text,
        parent_page = file_chooser.page or 1,
    }
    items._sg_is_series_view = true
    items._sg_series_name    = group_item.text
    items._sg_parent_path    = file_chooser.path
    file_chooser:switchItemTable(nil, items, nil, nil, group_item.text)
    local ok_p, Patches = pcall(require, "infra/sui_patches")
    if ok_p and Patches and Patches.setFMPathBase then
        local fm = require("apps/filemanager/filemanager").instance
        Patches.setFMPathBase(group_item.text, fm)
    end
    if file_chooser.onGotoPage then
        pcall(function() file_chooser:onGotoPage(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Install / uninstall — FileChooser monkeypatches
-- ---------------------------------------------------------------------------

local _sg_orig_switchItemTable = nil
local _sg_orig_onMenuSelect    = nil
local _sg_orig_onMenuHold      = nil
local _sg_orig_onFolderUp      = nil
local _sg_orig_changeToPath    = nil
local _sg_orig_refreshPath     = nil
local _sg_orig_updateItems     = nil

function SeriesGrouping.install()
    if FileChooser._simpleui_sg_patched then return end
    FileChooser._simpleui_sg_patched = true

    _sg_orig_switchItemTable = FileChooser.switchItemTable
    _sg_orig_onMenuSelect    = FileChooser.onMenuSelect
    _sg_orig_onMenuHold      = FileChooser.onMenuHold
    _sg_orig_onFolderUp      = FileChooser.onFolderUp
    _sg_orig_changeToPath    = FileChooser.changeToPath
    _sg_orig_refreshPath     = FileChooser.refreshPath
    _sg_orig_updateItems     = FileChooser.updateItems

    -- Process the incoming item_table before KOReader calculates itemmatch.
    -- Also clears _sg_is_series_view on the outgoing table at the last safe
    -- moment — avoids a timing window where the titlebar reads a stale flag.
    FileChooser.switchItemTable = function(fc, new_title, new_item_table,
                                           itemnumber, itemmatch, new_subtitle)
        if new_item_table and not new_item_table._sg_is_series_view then
            if fc.item_table then fc.item_table._sg_is_series_view = false end
            sgProcessItemTable(new_item_table, fc)
        end
        return _sg_orig_switchItemTable(fc, new_title, new_item_table,
                                        itemnumber, itemmatch, new_subtitle)
    end

    FileChooser.onMenuSelect = function(fc, item)
        if item and item.is_series_group and FolderCovers.getSeriesGrouping() then
            sgOpenGroup(fc, item)
            return true
        end
        return _sg_orig_onMenuSelect(fc, item)
    end

    -- Long-press on a series-group shows a dialog with cover picker and
    -- "Create collection". Cover picker is hidden in quad mode.
    FileChooser.onMenuHold = function(fc, item)
        if item and item.is_series_group and FolderCovers.getSeriesGrouping() then
            if not FolderCovers.isEnabled() then return true end
            local UIManager    = require("ui/uimanager")
            local ButtonDialog = require("ui/widget/buttondialog")

            local in_list_view    = fc and fc.display_mode_type == "list"
            local cover_available = not (
                FolderCovers.resolveStyle(fc, item.path, item) == "quad" and not in_list_view
            )

            local series_name = (item.text or ""):gsub("/$", "")
            local vpath       = item.path
            local dialog
            local buttons     = {}

            if cover_available then
                buttons[#buttons + 1] = {{
                    text = _("Set folder cover"),
                    callback = function()
                        UIManager:close(dialog)
                        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
                        if ok_bim and BookInfoManager then
                            SeriesGrouping.openCoverPicker(vpath, fc, BookInfoManager)
                        end
                    end,
                }}
            end

            buttons[#buttons + 1] = {{
                text = _("Create collection"),
                callback = function()
                    UIManager:close(dialog)
                    SeriesGrouping.createCollection(vpath, series_name)
                end,
            }}

            buttons[#buttons + 1] = {{
                text     = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }}

            dialog = ButtonDialog:new{
                title       = series_name,
                title_align = "center",
                buttons     = buttons,
            }
            UIManager:show(dialog)
            return true
        end
        return _sg_orig_onMenuHold(fc, item)
    end

    FileChooser.onFolderUp = function(fc)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            if parent then
                -- Clear the series view flag IMMEDIATELY so _resolveIsSub will work correctly
                fc.item_table._sg_is_series_view = false
                fc:changeToPath(parent)
            end
            return true
        end
        return _sg_orig_onFolderUp(fc)
    end

    FileChooser.changeToPath = function(fc, path, ...)
        if fc.item_table and fc.item_table._sg_is_series_view then
            local parent = fc.item_table._sg_parent_path
            -- Redirect ".." paths to the real parent.
            if parent and path and (path:match("/%.%.") or path:match("^%.%.")) then
                path = parent
            end
            -- _sg_is_series_view is cleared in switchItemTable (not here) to
            -- avoid a timing window between changeToPath and switchItemTable.
            if path == parent then
                if _sg_current then
                    _sg_current.should_restore = true
                    local saved_page = _sg_current.parent_page
                    if saved_page and saved_page > 1 then fc.page = saved_page end
                end
            else
                _sg_current = nil
            end
        else
            _sg_current = nil
        end
        return _sg_orig_changeToPath(fc, path, ...)
    end

    -- After closing a book (refreshPath), re-enter the virtual folder if one
    -- was active. The depth counter guards against infinite recursion:
    -- sgOpenGroup → switchItemTable can trigger another refreshPath on some
    -- KOReader versions; a boolean flag would stick on error.
    local _sg_refreshPath_depth = 0
    FileChooser.refreshPath = function(fc)
        if _sg_refreshPath_depth > 0 then return _sg_orig_refreshPath(fc) end
        _sg_refreshPath_depth = _sg_refreshPath_depth + 1

        FolderCovers.invalidateItemTableCache()

        -- Flush disk-level cover caches only when the library was actually
        -- visited (files may have been added/removed).
        local HS = package.loaded["screens/sui_homescreen"]
        if HS and HS._library_was_visited then
            FolderCovers.clearCoverFinderCache()
        end

        _sg_orig_refreshPath(fc)
        if FolderCovers.getSeriesGrouping() and _sg_current then
            local sname      = _sg_current.series_name
            local saved_page = _sg_current.parent_page
            for _, item in ipairs(fc.item_table or {}) do
                if item.is_series_group and item.text == sname then
                    sgOpenGroup(fc, item)
                    if _sg_current then _sg_current.parent_page = saved_page end
                    break
                end
            end
        end

        _sg_refreshPath_depth = _sg_refreshPath_depth - 1
    end

    -- Restore focus to the series group item when returning from a virtual folder.
    FileChooser.updateItems = function(fc, ...)
        if not FolderCovers.getSeriesGrouping() then
            _sg_current = nil
            return _sg_orig_updateItems(fc, ...)
        end
        if fc.item_table and fc.item_table._sg_is_series_view then
            return _sg_orig_updateItems(fc, ...)
        end
        if _sg_current and _sg_current.should_restore
                and fc.item_table and #fc.item_table > 0 then
            local sname = _sg_current.series_name
            for idx, item in ipairs(fc.item_table) do
                if item.is_series_group and item.text == sname then
                    fc.page = math.ceil(idx / fc.perpage)
                    local select_num = ((idx - 1) % fc.perpage) + 1
                    if fc.path_items and fc.path then fc.path_items[fc.path] = idx end
                    _sg_current = nil
                    return _sg_orig_updateItems(fc, select_num)
                end
            end
            _sg_current = nil
        end
        return _sg_orig_updateItems(fc, ...)
    end
end

function SeriesGrouping.uninstall()
    if not FileChooser._simpleui_sg_patched then return end
    if _sg_orig_switchItemTable then FileChooser.switchItemTable = _sg_orig_switchItemTable; _sg_orig_switchItemTable = nil end
    if _sg_orig_onMenuSelect    then FileChooser.onMenuSelect    = _sg_orig_onMenuSelect;    _sg_orig_onMenuSelect    = nil end
    if _sg_orig_onMenuHold      then FileChooser.onMenuHold      = _sg_orig_onMenuHold;      _sg_orig_onMenuHold      = nil end
    if _sg_orig_onFolderUp      then FileChooser.onFolderUp      = _sg_orig_onFolderUp;      _sg_orig_onFolderUp      = nil end
    if _sg_orig_changeToPath    then FileChooser.changeToPath    = _sg_orig_changeToPath;    _sg_orig_changeToPath    = nil end
    if _sg_orig_refreshPath     then FileChooser.refreshPath     = _sg_orig_refreshPath;     _sg_orig_refreshPath     = nil end
    if _sg_orig_updateItems     then FileChooser.updateItems     = _sg_orig_updateItems;     _sg_orig_updateItems     = nil end
    FileChooser._simpleui_sg_patched = nil
    _sg_current           = nil
    _sg_items_cache       = {}
    _sg_last_evicted_path = nil
end

-- Public API for other modules that need to query or exit the series view.
function SeriesGrouping.isInSeriesView(fc)
    return fc and fc.item_table and fc.item_table._sg_is_series_view == true
end

-- Exits the series view and navigates to the real parent folder.
function SeriesGrouping.exitSeriesView(fc)
    if not SeriesGrouping.isInSeriesView(fc) then return end
    local parent = fc.item_table._sg_parent_path
    _sg_current = nil
    fc.item_table._sg_is_series_view = false
    if parent then fc:changeToPath(parent) end
end

return SeriesGrouping
