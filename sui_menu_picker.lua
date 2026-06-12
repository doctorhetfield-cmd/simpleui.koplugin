-- sui_menu_picker.lua
-- Record and replay menu navigation paths

local Blitbuffer   = require("ffi/blitbuffer")
local Button       = require("ui/widget/button")
local InfoMessage  = require("ui/widget/infomessage")
local Size         = require("ui/size")
local TouchMenu    = require("ui/widget/touchmenu")
local UIManager    = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local VerticalGroup   = require("ui/widget/verticalgroup")
local logger       = require("logger")
local _            = require("sui_i18n").translate

local M = {}

-- ==========================================================================
-- Module-level picking state
-- ==========================================================================

local _state = {
    active          = false,
    menu            = nil,
    on_done         = nil,
    on_cancel       = nil,
    tab_index       = nil,
    nav_path        = nil,      -- stores { index = n, text = s } for each level
    view            = nil,
    action_bar      = nil,
    bars_span       = nil,
}

-- Originals saved before patching
local _orig_onMenuSelect    = nil
local _orig_backToUpperMenu = nil
local _orig_switchMenuTab   = nil
local _orig_closeMenu       = nil
local _orig_updateItems     = nil

-- ==========================================================================
-- Helpers
-- ==========================================================================

local function itemText(item)
    local t = item.text
    if type(t) == "function" then t = t() end
    if not t and item.text_func then t = item.text_func() end
    return type(t) == "string" and t or ""
end

local function snapshotMenuState(menu)
    local item_table_stack = {}
    for i, item_table in ipairs(menu.item_table_stack or {}) do
        item_table_stack[i] = item_table
    end
    return {
        cur_tab = menu.cur_tab,
        item_table = menu.item_table,
        item_table_stack = item_table_stack,
        page = menu.page,
    }
end

local function restoreMenuState(menu, state)
    if not menu or not state then return end
    menu.cur_tab = state.cur_tab
    menu.item_table = state.item_table
    menu.item_table_stack = {}
    for i, tbl in ipairs(state.item_table_stack or {}) do
        menu.item_table_stack[i] = tbl
    end
    menu.parent_id = nil
    menu.page = state.page or 1
    menu:updateItems(menu.page)
end

-- ==========================================================================
-- Patch management
-- ==========================================================================

local function _stopPicking()
    print("[sui_menu_picker] _stopPicking called")
    local menu = _state.menu
    local action_bar = _state.action_bar
    local bars_span = _state.bars_span

    _state.action_bar = nil
    _state.bars_span = nil
    _state.active = false
    _state.menu = nil
    _state.on_done = nil
    _state.on_cancel = nil
    _state.tab_index = nil
    _state.nav_path = nil
    _state.view = nil

    if menu and action_bar then
        local ig = menu.item_group
        for i = #ig, 1, -1 do
            if ig[i] == action_bar or ig[i] == bars_span then
                table.remove(ig, i)
            end
        end
        ig:resetLayout()
        menu.dimen.h = ig:getSize().h + menu.bordersize * 2 + menu.padding
        UIManager:setDirty(menu.show_parent, function()
            return "ui", menu.dimen
        end)
    end

    UIManager:setDirty("all", "flashui")

    local TouchMenu = require("ui/widget/touchmenu")
    if _orig_onMenuSelect then
        print("[sui_menu_picker] Restoring original TouchMenu methods")
        TouchMenu.onMenuSelect    = _orig_onMenuSelect
        TouchMenu.backToUpperMenu = _orig_backToUpperMenu
        TouchMenu.switchMenuTab   = _orig_switchMenuTab
        TouchMenu.closeMenu       = _orig_closeMenu
        TouchMenu.updateItems     = _orig_updateItems
        _orig_onMenuSelect    = nil
        _orig_backToUpperMenu = nil
        _orig_switchMenuTab   = nil
        _orig_closeMenu       = nil
        _orig_updateItems     = nil
    end
end

local function makeActionBar(menu)
    local buttons = {}
    
    -- Add "Finish recording" button
    table.insert(buttons, Button:new{
        text           = _("Finish recording & save as shortcut"),
        width          = menu.item_width,
        text_font_bold = true,
        bordersize     = Size.border.thin,
        background     = Blitbuffer.COLOR_LIGHT_GRAY,
        show_parent    = menu.show_parent,
        callback       = function()
            if _state.active then
                -- Build index path from current navigation state
                local index_path = {}
                for _, step in ipairs(_state.nav_path) do
                    table.insert(index_path, step.index)
                end
                local path_record = {
                    tab_index     = _state.tab_index,
                    display_label = _state.nav_path[#_state.nav_path] and _state.nav_path[#_state.nav_path].text or _("Menu Action"),
                    index_path    = index_path,
                    view          = _state.view,
                    is_leaf       = false, 
                }
                local cb = _state.on_done
                _stopPicking()
                if cb then cb(path_record) end
            end
        end,
    })
    
    -- Add cancel button
    table.insert(buttons, Button:new{
        text           = _("Cancel"),
        width          = menu.item_width,
        text_font_bold = true,
        bordersize     = Size.border.thin,
        background     = Blitbuffer.COLOR_LIGHT_GRAY,
        show_parent    = menu.show_parent,
        callback       = function()
            if _state.active then
                local cb = _state.on_cancel
                _stopPicking()
                if cb then cb() end
            end
        end,
    })
    
    -- Return VerticalGroup containing both buttons
    local vg = VerticalGroup:new{ align = "center" }
    for _, btn in ipairs(buttons) do
        table.insert(vg, btn)
        table.insert(vg, VerticalSpan:new{ width = Size.padding.small })
    end
    return vg
end

local function _installPatches()
    print("[sui_menu_picker] _installPatches called")
    local TouchMenu = require("ui/widget/touchmenu")
    
    if _orig_onMenuSelect then
        print("[sui_menu_picker] Already patched, skipping")
        return
    end

    _orig_onMenuSelect    = TouchMenu.onMenuSelect
    _orig_backToUpperMenu = TouchMenu.backToUpperMenu
    _orig_switchMenuTab   = TouchMenu.switchMenuTab
    _orig_closeMenu       = TouchMenu.closeMenu
    _orig_updateItems     = TouchMenu.updateItems
    
    print("[sui_menu_picker] Saved original methods")

    TouchMenu.updateItems = function(self, ...)
        local result = _orig_updateItems(self, ...)
        if _state.active and self == _state.menu then
            if not _state.action_bar then
                _state.action_bar = makeActionBar(self)
            end
            if not _state.bars_span then
                _state.bars_span = VerticalSpan:new{ width = Size.padding.default }
            end
            table.insert(self.item_group, _state.bars_span)
            table.insert(self.item_group, _state.action_bar)
            self.item_group:resetLayout()
            self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
            UIManager:setDirty(self.show_parent, function()
                return "ui", self.dimen
            end)
        end
        return result
    end

    TouchMenu.closeMenu = function(self, ...)
        local orig = _orig_closeMenu
        if _state.active and self == _state.menu then
            print("[sui_menu_picker] Menu closed unexpectedly, cancelling pick")
            local cb = _state.on_cancel
            _stopPicking()
            if cb then cb() end
        end
        return orig(self, ...)
    end

    -- Intercept item selection during picking
    TouchMenu.onMenuSelect = function(self, item, tap_on_checkmark)
        if not _state.active then
            return _orig_onMenuSelect(self, item, tap_on_checkmark)
        end

        print("[sui_menu_picker] onMenuSelect intercepted, active=true")
        
        local sub = (item.sub_item_table_func and item.sub_item_table_func())
                 or item.sub_item_table

        local item_index
        for i, it in ipairs(self.item_table or {}) do
            if it == item then item_index = i; break end
        end

        if sub then
            -- Record navigation step (store both index and text)
            print("[sui_menu_picker] Entering sub-menu, recording step")
            table.insert(_state.nav_path, {
                index = item_index,
                text  = itemText(item),
            })
            return _orig_onMenuSelect(self, item, tap_on_checkmark)
        end

        -- Leaf item tapped - capture it with index path
        local label = itemText(item)
        print("[sui_menu_picker] Leaf item tapped, capturing:", label)
        
        -- Build index path from nav_path
        local index_path = {}
        for _, step in ipairs(_state.nav_path) do
            table.insert(index_path, step.index)
        end
        table.insert(index_path, item_index)
        
        print("[sui_menu_picker] Index path:", table.concat(index_path, " -> "))
        
        local path_record = {
            tab_index     = _state.tab_index,
            display_label = label,
            index_path    = index_path,
            view          = _state.view,
            is_leaf       = true,  
        }
        
        print("[sui_menu_picker] Path record created, calling on_done")
        local cb = _state.on_done
        _stopPicking()
        if cb then 
            cb(path_record) 
        end
        return true
    end

    TouchMenu.backToUpperMenu = function(self, no_close)
        local orig = _orig_backToUpperMenu
        if _state.active and self == _state.menu then
            if #self.item_table_stack ~= 0 then
                if #_state.nav_path > 0 then
                    print("[sui_menu_picker] Back navigation, popping nav_path")
                    table.remove(_state.nav_path)
                end
            else
                print("[sui_menu_picker] Back to root, cancelling pick")
                local cb = _state.on_cancel
                _stopPicking()
                if cb then cb() end
            end
        end
        return orig(self, no_close)
    end

    TouchMenu.switchMenuTab = function(self, tab_num)
        local orig = _orig_switchMenuTab
        if _state.active and self == _state.menu then
            print("[sui_menu_picker] Switched to tab:", tab_num)
            _state.tab_index = tab_num
            _state.nav_path  = {}
        end
        return orig(self, tab_num)
    end
    
    print("[sui_menu_picker] Patches installed successfully")
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function M.startPicking(menu, on_done, on_cancel, view)
    print("[sui_menu_picker] startPicking called")
    
    if _state.active then 
        print("[sui_menu_picker] Already active, stopping previous pick")
        _stopPicking() 
    end

    _state.active    = true
    _state.menu      = menu
    _state.tab_index = 1
    _state.nav_path  = {}
    _state.view      = view or "reader"
    _state.on_done   = on_done
    _state.on_cancel = on_cancel

    _installPatches()

    menu.cur_tab = nil
    if menu.bar and menu.bar.switchToTab then
        menu.bar:switchToTab(1)
    end

    UIManager:show(InfoMessage:new{
        text    = _("Tap any menu item to record it as a shortcut."),
        timeout = 3,
    })
    print("[sui_menu_picker] startPicking completed")
end

function M.cancelPicking()
    print("[sui_menu_picker] cancelPicking called")
    if _state.active then
        local cb = _state.on_cancel
        _stopPicking()
        if cb then cb() end
    end
end

function M.replay(menu, path_record)
    print("[sui_menu_picker] ========== replay START ==========")
    
    print("index_path length:", #path_record.index_path)
    for i, idx in ipairs(path_record.index_path) do
        print("  level", i, ":", idx)
    end
    print("tab_index:", path_record.tab_index)
    print("view:", path_record.view)
    print("is_leaf:", path_record.is_leaf)

    if not path_record then 
        print("[sui_menu_picker] ERROR: path_record is nil")
        return false 
    end
    
    local index_path = path_record.index_path
    if not index_path or #index_path == 0 then
        print("[sui_menu_picker] ERROR: no index_path")
        print("  path_record keys:")
        for k, v in pairs(path_record) do
            print("    ", k, "=", type(v) == "table" and "table" or v)
        end
        return false
    end
    
    print("  index_path:", table.concat(index_path, " -> "))
    print("  tab_index:", path_record.tab_index)
    print("  view:", path_record.view)
    
    local saved_state = snapshotMenuState(menu)
    print("  snapshotMenuState done")
    
    -- Switch to the recorded tab
    if path_record.tab_index then
        print("[sui_menu_picker] Switching to tab:", path_record.tab_index)
        -- Ensure menu has updateItems method
        if not menu.updateItems then
            menu.updateItems = function() end
        end
        local switch = _orig_switchMenuTab or TouchMenu.switchMenuTab
        switch(menu, path_record.tab_index)
    end
    
    local current_menu = menu
    local current_item = nil
    
    -- Helper function to switch to the correct page for a given index
    local function ensurePageForIndex(target_idx)
        if not current_menu.perpage then return end
        local target_page = math.ceil(target_idx / current_menu.perpage)
        if target_page > 1 and target_page ~= current_menu.page then
            print("[sui_menu_picker] Switching to page", target_page, "for index", target_idx)
            if current_menu.onGotoPage then
                current_menu:onGotoPage(target_page)
            end
        end
    end

    for i, idx in ipairs(index_path) do
        print("[sui_menu_picker] Looking for index", idx)
        
        -- Ensure we are on the correct page before looking up the index
        ensurePageForIndex(idx)

        if not current_menu.item_table or not current_menu.item_table[idx] then
            print("[sui_menu_picker] Index", idx, "not found in current menu")
            if current_menu.item_table then
                print("[sui_menu_picker] Current menu has items 1..", #current_menu.item_table)
            end
            restoreMenuState(menu, saved_state)
            return false
        end
        
        current_item = current_menu.item_table[idx]
        print("[sui_menu_picker] Found item at index", idx, ":", itemText(current_item))
        
        -- Determine whether to enter submenu:
        -- 1. There is a next level (i < #index_path)
        -- 2. Or this is the last level but is_leaf = false (intermediate node, need to open menu)
        local should_enter_submenu = (i < #index_path) or (i == #index_path and not path_record.is_leaf)
        
        if should_enter_submenu then
            local sub = (current_item.sub_item_table_func and current_item.sub_item_table_func())
                     or current_item.sub_item_table
            if not sub or #sub == 0 then
                print("[sui_menu_picker] No submenu at index", idx)
                restoreMenuState(menu, saved_state)
                return false
            end
            table.insert(current_menu.item_table_stack, current_menu.item_table)
            current_menu.item_table = sub
            current_menu.page = 1
            current_menu:updateItems(1)  -- Refresh menu display
            print("[sui_menu_picker] Entered submenu at index", idx)
        end
    end
    
    -- Execute the leaf item callback based on is_leaf flag
    if path_record.is_leaf then
        print("[sui_menu_picker] Leaf node, executing callback and closing menu")
        local callback = (current_item.callback_func and current_item.callback_func()) or current_item.callback
        if callback then
            local ok, err = pcall(callback, current_menu)
            if not ok then
                print("[sui_menu_picker] Callback error:", err)
            end
        end
        restoreMenuState(menu, saved_state)
        menu:closeMenu()
    else
        print("[sui_menu_picker] Intermediate node, navigating only (keeping menu open)")
        -- Only navigate to the target menu, keep it open, do not execute callback
    end
    print("[sui_menu_picker] ========== replay END (success) ==========")
    return true 
end

return M