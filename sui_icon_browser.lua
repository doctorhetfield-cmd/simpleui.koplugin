-- sui_icon_browser.lua
-- Simple UI Icon Browser - browse filesystem for SVG/PNG icons

local BD = require("ui/bidi")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InputText = require("ui/widget/inputtext")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("sui_i18n").translate
local Screen = Device.screen
local DataStorage = require("datastorage")

local THUMB_SIZE = Screen:scaleBySize(32)
local THUMB_GAP = Screen:scaleBySize(6)

-- ---------------------------------------------------------------------------
-- Inner PathChooser subclass with thumbnail preview
-- ---------------------------------------------------------------------------
local _InnerChooser = PathChooser:extend{
    select_directory = false,
    select_file = true,
    state_w = THUMB_SIZE + THUMB_GAP,
    path = DataStorage:getDataDir() .. "/icons/",
    onConfirm = nil,
    _filter_text = "",
    _all_items = nil,
    stop_events_propagation = true,
}

function _InnerChooser:init()
    self.title = _('Choose icon')
    
    -- Only show SVG and PNG files
    self.file_filter = function(filename)
        local ext = filename:lower()
        return ext:match('%.svg$') ~= nil or ext:match('%.png$') ~= nil
    end
    
    self.state_w = THUMB_SIZE + THUMB_GAP
    self._recalculateDimen = _InnerChooser._recalculateDimen
    PathChooser.init(self)
    if not self._all_items then
        self:refreshPath()
    end
end

function _InnerChooser:_recalculateDimen(no_recalculate_dimen)
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if not self.item_dimen then return end
    
    if self._filter_bar_height and self._filter_bar_height > 0 and not no_recalculate_dimen then
        self.available_height = self.available_height - self._filter_bar_height
        self.item_dimen.h = math.floor(self.available_height / self.perpage)
    end
    
    local content_w = math.max(0, self.item_dimen.w - 2 * Size.padding.fullscreen)
    local max_state_w = math.max(1, math.floor(content_w / 4))
    local ts = THUMB_SIZE
    local tg = THUMB_GAP
    self.state_w = math.min(ts + tg, max_state_w)
    self._thumb_size = math.max(0, math.min(ts, self.state_w - tg))
end

function _InnerChooser:getCollate()
    return self.collates.strcoll, "strcoll"
end

function _InnerChooser:refreshPath()
    local _, folder_name = util.splitFilePathName(self.path)
    Screen:setWindowTitle(folder_name)
    self._all_items = self:genItemTableFromPath(self.path)
    self:_applyCurrentFilter()
end

function _InnerChooser:_applyCurrentFilter()
    local filter_text = self._filter_text or ""
    local items
    
    if filter_text == "" then
        items = self._all_items
    else
        items = {}
        local pattern = filter_text:lower()
        for _, item in ipairs(self._all_items) do
            if item.is_go_up or (item.text and item.text:lower():find(pattern, 1, true)) then
                table.insert(items, item)
            end
        end
    end
    
    local itemmatch
    if self.focused_path then
        itemmatch = {path = self.focused_path}
        self.focused_path = nil
    end
    
    local subtitle = BD.directory(filemanagerutil.abbreviate(self.path))
    self:switchItemTable(nil, items, filter_text == "" and self.path_items[self.path] or 1, itemmatch, subtitle)
end

function _InnerChooser:applyFilter(text)
    self._filter_text = text or ""
    if self._all_items then
        self:_applyCurrentFilter()
    end
end

function _InnerChooser:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)
    self.path_items[self.path] = (self.page - 1) * self.perpage + (select_number or 1)

    local eff_thumb = self._thumb_size or 0
    if eff_thumb <= 0 then return end

    local item_h = self.item_dimen and self.item_dimen.h or eff_thumb
    local center_y = math.max(0, math.floor((item_h - eff_thumb) / 2))

    for _, item_widget in ipairs(self.item_group) do
        local entry = item_widget.entry
        if not entry then goto continue end
        local filepath = entry.path or ""
        
        local ext = filepath:lower()
        if not (ext:match("%.svg$") or ext:match("%.png$")) then goto continue end

        local uc = item_widget._underline_container
        if not uc then goto continue end
        local hg = uc[1]
        if not hg then goto continue end
        local og = hg[1]
        if not og then goto continue end

        table.insert(og, 1, ImageWidget:new{
            file = filepath,
            width = eff_thumb,
            height = eff_thumb,
            alpha = true,
            overlap_offset = { 0, center_y },
        })
        og._size = nil

        ::continue::
    end
end

-- Tap to select (no confirmation dialog)
function _InnerChooser:onMenuSelect(item)
    local path = item.path or ""
    local ext = path:lower()
    
    if ext:match("%.svg$") or ext:match("%.png$") then
        local real_path = ffiUtil.realpath(path) or path
        if self.show_parent then
            self.show_parent:onClose()
        else
            UIManager:close(self)
        end
        if self.onConfirm then
            self.onConfirm(real_path)
        end
        return true
    end
    return PathChooser.onMenuSelect(self, item)
end

function _InnerChooser:onMenuHold(item)
    local path = item.path or ""
    local ext = path:lower()
    if ext:match("%.svg$") or ext:match("%.png$") then
        return true
    end
    return PathChooser.onMenuHold(self, item)
end

-- ---------------------------------------------------------------------------
-- Outer wrapper with filter bar
-- ---------------------------------------------------------------------------
local IconBrowser = WidgetContainer:extend{
    path = DataStorage:getDataDir() .. "/icons/",
    onConfirm = nil,
    is_always_active = true,
}

function IconBrowser:init()
    self.dimen = Geom:new{x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight()}

    -- Filter input
    self._filter_input = InputText:new{
        text = "",
        hint = _("Filter by name…"),
        width = self.dimen.w - 4 * Size.padding.default,
        height = nil,
        face = Font:getFace("smallinfofont"),
        padding = Size.padding.small,
        margin = 0,
        bordersize = Size.border.inputtext,
        parent = self,
        scroll = false,
        focused = false,
        edit_callback = function()
            self:_applyFilter()
        end,
    }
    
    -- Intercept Enter key
    self._filter_input.addChars = function(inp, chars)
        if chars == "\n" then
            inp:onCloseKeyboard()
            return
        end
        InputText.addChars(inp, chars)
    end
    
    self._filter_bar = FrameContainer:new{
        padding = Size.padding.default,
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        bordersize = 0,
        self._filter_input,
    }
    
    local filter_h = self._filter_bar:getSize().h

    self._chooser = _InnerChooser:new{
        show_parent = self,
        path = self.path,
        onConfirm = self.onConfirm,
        height = self.dimen.h,
        close_callback = function() self:onClose() end,
    }
    
    table.insert(self._chooser.content_group, 2, self._filter_bar)
    self._chooser._filter_bar_height = filter_h
    self._chooser:refreshPath()

    self[1] = self._chooser
end

function IconBrowser:_applyFilter()
    if not self._chooser then return end
    local text = self._filter_input and self._filter_input:getText() or ""
    self._chooser:applyFilter(text)
end

function IconBrowser:getFocusableWidgetXY()
    return nil, nil
end

function IconBrowser:onClose()
    if self._filter_input then
        self._filter_input:onCloseKeyboard()
    end
    UIManager:close(self)
end

return IconBrowser