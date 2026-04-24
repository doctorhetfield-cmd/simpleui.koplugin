-- sui_metabrowser.lua — Simple UI
-- Virtual FileChooser-based metadata browsers for Authors and Series.

local BD               = require("ui/bidi")
local Device           = require("device")
local DocumentRegistry = require("document/documentregistry")
local FileChooser      = require("ui/widget/filechooser")
local InfoMessage      = require("ui/widget/infomessage")
local UIManager        = require("ui/uimanager")
local ffiUtil          = require("ffi/util")
local filemanagerutil  = require("apps/filemanager/filemanagerutil")
local lfs              = require("libs/libkoreader-lfs")
local util             = require("util")
local _ = require("sui_i18n").translate
local T                = ffiUtil.template

local M = {}

-- We intentionally extend FileChooser so the browser participates in the same
-- coverbrowser/mosaic pipeline as the library, instead of behaving like a
-- standalone BookList.
local MetaChooser = FileChooser:extend{
    name = "simpleui_metabrowser",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    title_bar_left_icon = "chevron.left",
    return_arrow_propagation = true,
}

local function _labelFor(kind)
    return kind == "authors" and _("Authors") or _("Series")
end

local function _scanLabel(kind)
    return kind == "authors" and _("Scanning authors…") or _("Scanning series…")
end

local function _emptyLabel(kind)
    return kind == "authors" and _("No authors found.") or _("No series found.")
end

local function _trim(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if s == "" then return nil end
    return s
end

local function _resolveHomeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then
        home = Device.home_dir
    end
    if home and lfs.attributes(home, "mode") == "directory" then
        return home
    end
end

local function _splitAuthors(authors)
    if type(authors) ~= "string" or authors == "" then return {} end
    local out = {}
    for _, author in ipairs(util.splitToArray(authors, "\n")) do
        author = _trim(author)
        if author then out[#out + 1] = author end
    end
    return out
end

local function _seriesSortKey(entry)
    local idx = tonumber(entry.series_index)
    return idx or math.huge
end

local function _virtualPath(kind, group)
    -- Virtual groups are not real directories on disk; they only need a stable
    -- synthetic path so FileChooser/CoverBrowser can treat them like folders.
    return "::simpleui_meta::" .. kind .. "::" .. group.value
end

local function _groupMandatory(group)
    return tostring(#group.items) .. " \u{F016}"
end

local function _buildRootItems(kind, groups)
    -- Root view: one virtual directory per author/series value.
    local items = {}
    for _, group in ipairs(groups) do
        items[#items + 1] = {
            text = group.value .. "/",
            path = _virtualPath(kind, group),
            attr = { mode = "directory" },
            is_directory = true,
            bidi_wrap_func = BD.directory,
            mandatory = _groupMandatory(group),
            is_meta_group = true,
            meta_kind = kind,
            meta_items = group.items,
            meta_value = group.value,
        }
    end
    return items
end

local function _buildBookItems(kind, group)
    -- Group view: real file entries, so opening/holding a book reuses the same
    -- FileChooser actions as the library.
    local items = {}
    for _, entry in ipairs(group.items) do
        local mandatory
        if kind == "authors" then
            if entry.series and entry.series ~= "" then
                mandatory = entry.series
                if entry.series_index then
                    mandatory = mandatory .. " #" .. tostring(entry.series_index)
                end
            else
                mandatory = filemanagerutil.abbreviate(entry.file)
            end
        else
            mandatory = entry.authors and entry.authors:gsub("\n.*", " et al.")
                or filemanagerutil.abbreviate(entry.file)
        end
        items[#items + 1] = {
            text = entry.title,
            path = entry.file,
            attr = lfs.attributes(entry.file) or { mode = "file" },
            is_file = true,
            mandatory = mandatory,
            bidi_wrap_func = BD.filename,
            doc_props = {
                display_title = entry.title,
                authors = entry.authors,
                series = entry.series,
                series_index = entry.series_index,
            },
        }
    end
    table.sort(items, function(a, b)
        local ea = group.by_file[a.path]
        local eb = group.by_file[b.path]
        if kind == "series" then
            local ia, ib = _seriesSortKey(ea), _seriesSortKey(eb)
            if ia ~= ib then return ia < ib end
        end
        return ffiUtil.strcoll(a.text, b.text)
    end)
    return items
end

local function _collectGroups(ui, kind)
    local home = _resolveHomeDir()
    if not home then return nil, _("Home folder not available.") end

    -- The browser is metadata-driven: folder names do not matter here.
    -- We scan every supported book below home_dir and group by embedded
    -- author/series metadata.
    local grouped = {}
    util.findFiles(home, function(file)
        if not DocumentRegistry:hasProvider(file) then return end
        local props = ui.bookinfo and ui.bookinfo:getDocProps(file, nil, true) or nil
        if not props then return end

        local values
        if kind == "authors" then
            values = _splitAuthors(props.authors)
        else
            local series = _trim(props.series)
            values = series and { series } or {}
        end
        if #values == 0 then return end

        local title = _trim(props.display_title) or file:match("([^/]+)$") or file
        local entry = {
            file = file,
            path = file,
            title = title,
            authors = _trim(props.authors),
            series = _trim(props.series),
            series_index = props.series_index,
        }
        for _, value in ipairs(values) do
            local group = grouped[value]
            if not group then
                group = { value = value, items = {}, by_file = {} }
                grouped[value] = group
            end
            if not group.by_file[file] then
                group.items[#group.items + 1] = entry
                group.by_file[file] = entry
            end
        end
    end, true)

    local groups = {}
    for _, group in pairs(grouped) do
        groups[#groups + 1] = group
    end
    table.sort(groups, function(a, b) return ffiUtil.strcoll(a.value, b.value) end)
    return groups, home
end

function MetaChooser:init()
    FileChooser.init(self)
    -- Preserve the titlebar's original left-button position
    if self.title_bar and self.title_bar.left_button then
        local btn = self.title_bar.left_button
        self._meta_back_offset = btn.overlap_offset and { btn.overlap_offset[1], btn.overlap_offset[2] } or nil
    end
    self:_updateBackButton()
end

function MetaChooser:_updateBackButton()
    local tb = self.title_bar
    local btn = tb and tb.left_button
    if not btn then return end

    if self._meta_back_offset then
        btn.overlap_align = nil
        btn.overlap_offset = { self._meta_back_offset[1], self._meta_back_offset[2] }
    end

    if self._meta_group then
        -- Inside a group: go back to the root author/series list.
        btn.callback = function() self:onFolderUp() end
    else
        -- At root: keep the button visible to match the surrounding titlebar,
        -- but make it inert so it does not close the browser unexpectedly.
        btn.callback = function() end
    end
end

function MetaChooser:_showRoot()
    -- Root = virtual folders (authors or series).
    self._meta_group = nil
    self.title = T("%1 (%2)", _labelFor(self._meta_kind), #self._meta_groups)
    self.onReturn = nil
    self.paths = {}
    self:switchItemTable(self.title, _buildRootItems(self._meta_kind, self._meta_groups), 1, nil,
        BD.directory(filemanagerutil.abbreviate(self._meta_home)))
    self:_updateBackButton()
end

function MetaChooser:_showGroup(group)
    -- Group = concrete book files for one selected author/series.
    self._meta_group = group
    self.onReturn = function()
        self:_showRoot()
    end
    self.paths = { true }
    local items = _buildBookItems(self._meta_kind, group)
    self:switchItemTable(T("%1 (%2)", group.value, #items), items, 1, nil,
        group.value)
    self:_updateBackButton()
end

function MetaChooser:refreshPath()
    -- FileChooser expects refreshPath() to rebuild the current view. Since this
    -- browser is virtual, we re-render whichever level is currently active.
    if self._meta_group then
        self:_showGroup(self._meta_group)
    else
        self:_showRoot()
    end
end

function MetaChooser:onMenuSelect(item)
    if item and item.is_meta_group then
        -- Enter the virtual folder instead of changing to a real filesystem path.
        self:_showGroup(self._meta_groups_by_value[item.meta_value])
        return true
    end
    return FileChooser.onMenuSelect(self, item)
end

function MetaChooser:onMenuHold(item)
    if item and item.is_meta_group then
        return true
    end
    local fm_fc = self.ui and self.ui.file_chooser
    if fm_fc and type(fm_fc.showFileDialog) == "function" then
        fm_fc:showFileDialog(item)
        return true
    end
    return true
end

function MetaChooser:onFolderUp()
    if self._meta_group then
        self:_showRoot()
        return true
    end
    if self.close_callback then
        self.close_callback()
        return true
    end
end

function MetaChooser:onLeftButtonTap()
    return self:onFolderUp()
end

function MetaChooser:onFileSelect(item)
    -- Open the selected book through the same helper the library uses.
    filemanagerutil.openFile(self.ui, item.path, self.close_callback)
    return true
end

function MetaChooser:onFileHold(item)
    return self:onMenuHold(item)
end

function M.show(ui, kind)
    if kind ~= "authors" and kind ~= "series" then return end

    -- The scan can touch many books, so show a short transient message and do
    -- the actual collection work on the next tick to keep the UI responsive.
    local info = InfoMessage:new{
        text = _scanLabel(kind),
        timeout = 0.1,
        _navbar_closing_intentionally = true,
    }
    UIManager:show(info)
    UIManager:nextTick(function()
        local ok, groups_or_err, home = pcall(function()
            local groups, resolved_home = _collectGroups(ui, kind)
            return groups, resolved_home
        end)
        UIManager:close(info)
        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(groups_or_err), timeout = 2 })
            return
        end
        if not groups_or_err then
            UIManager:show(InfoMessage:new{ text = _("Home folder not available."), timeout = 2 })
            return
        end
        if #groups_or_err == 0 then
            UIManager:show(InfoMessage:new{ text = _emptyLabel(kind), timeout = 2 })
            return
        end

        local by_value = {}
        for _, group in ipairs(groups_or_err) do
            by_value[group.value] = group
        end

        local chooser
        chooser = MetaChooser:new{
            ui = ui,
            path = home,
            _meta_kind = kind,
            _meta_home = home,
            _meta_groups = groups_or_err,
            _meta_groups_by_value = by_value,
            close_callback = function()
                UIManager:close(chooser)
            end,
        }
        UIManager:show(chooser)
    end)
end

return M
