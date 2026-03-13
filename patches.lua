-- patches.lua — Simple UI
-- All monkey-patches applied to KOReader on plugin load:
--   FileManager.setupLayout  (navbar injection + desktop auto-open)
--   FileChooser.init         (corrected height)
--   FileManagerMenu          (Start with Desktop option)
--   BookList.new             (corrected height)
--   Menu.new + FMColl        (collections with corrected height)
--   SortWidget.new + PathChooser.new (fullscreen widgets)
--   UIManager.show           (universal navbar injection)
--   UIManager.close          (tab restore + desktop on close)
--   Menu.init                (hide pagination bar)

local UIManager  = require("ui/uimanager")
local Screen     = require("device").screen
local logger     = require("logger")
local _          = require("gettext")

local Config    = require("config")
local UI        = require("ui")
local Bottombar = require("bottombar")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared helpers used across multiple patches
-- ---------------------------------------------------------------------------

local function setActiveAndRefreshFM(plugin, action_id, tabs)
    plugin.active_action = action_id
    local fm = plugin.ui
    if fm and fm._navbar_container then
        Bottombar.replaceBar(fm, Bottombar.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
        UIManager:setDirty(fm[1], "ui")
    end
    return action_id
end

-- ---------------------------------------------------------------------------
-- _patchFileManagerClass
-- ---------------------------------------------------------------------------

function M.patchFileManagerClass(plugin)
    local FileManager      = require("apps/filemanager/filemanager")
    local orig_setupLayout = FileManager.setupLayout
    plugin._orig_fm_setup  = orig_setupLayout

    FileManager.setupLayout = function(fm_self)
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        fm_self._navbar_height = Bottombar.TOTAL_H() + (topbar_on and require("topbar").TOTAL_TOP_H() or 0)

        -- Patch FileChooser.init once to correct its height.
        local FileChooser = require("ui/widget/filechooser")
        if not FileChooser._navbar_patched then
            local orig_fc_init   = FileChooser.init
            plugin._orig_fc_init = orig_fc_init
            FileChooser._navbar_patched = true
            FileChooser.init = function(fc_self)
                -- Correct the height when it is either unset (stock KOReader) or
                -- explicitly set to the full screen height (Project: Title passes
                -- height = Screen:getHeight() in covermenu.lua, bypassing the nil check).
                if fc_self.height == nil or fc_self.height >= Screen:getHeight() then
                    fc_self.height = UI.getContentHeight()
                    fc_self.y      = UI.getContentTop()
                end
                orig_fc_init(fc_self)
            end
        end

        orig_setupLayout(fm_self)

        -- Replace the right title bar button icon.
        local PLUS_ALT_ICON = "plugins/simpleui.koplugin/icons/plus_alt.svg"
        local tb = fm_self.title_bar
        if tb and tb.right_button then
            local function setPlusAltIcon(btn)
                if btn.image then
                    btn.image.file = PLUS_ALT_ICON
                    btn.image:free(); btn.image:init()
                end
            end
            setPlusAltIcon(tb.right_button)
            local orig_setRightIcon = tb.setRightIcon
            tb.setRightIcon = function(tb_self, icon, ...)
                local result = orig_setRightIcon(tb_self, icon, ...)
                if icon == "plus" then
                    setPlusAltIcon(tb_self.right_button)
                    UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
                end
                return result
            end
        end

        if tb and tb.left_button and tb.right_button then
            local rb = tb.right_button
            if rb.image then
                rb.image.file = "resources/icons/mdlight/appbar.menu.svg"
                rb.image:free(); rb.image:init()
            end
            rb.overlap_align  = nil
            rb.overlap_offset = { Screen:scaleBySize(18), 0 }
            rb.padding_left   = 0
            rb:update()
            tb.left_button.overlap_align  = nil
            tb.left_button.overlap_offset = { Screen:getWidth() + 100, 0 }
            tb.left_button.callback       = function() end
            tb.left_button.hold_callback  = function() end
        end
        if tb and tb.setTitle then tb:setTitle(_("Library")) end

        -- Store the inner widget reference for re-wrapping.
        local inner_widget
        if fm_self._navbar_inner then
            inner_widget = fm_self._navbar_inner
        else
            inner_widget          = fm_self[1]
            fm_self._navbar_inner = inner_widget
        end

        local tabs = Config.loadTabConfig()

        -- When the FileManager is rebuilt after closing the reader, the Desktop
        -- widget has been destroyed by the teardown. Reset the session flag so
        -- the auto-open logic below can re-inject the Desktop correctly.
        local _desktop_was_visible = false
        do
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop then
                if not Desktop._desktop_widget then
                    -- FM teardown wiped the desktop widget → re-open from scratch
                    Config.desktop_session_opened = false
                elseif Desktop._fm == fm_self then
                    -- reinit() on the same FM while Desktop is visible (e.g. SDL
                    -- resize/rotate event): we must re-inject after wrapWithNavbar
                    -- replaces fm_self[1] with a fresh wrapped widget.
                    _desktop_was_visible = true
                else
                    -- Desktop._fm is a different (destroyed) FM — happens when the
                    -- reader closes and KOReader builds a brand-new FileManager while
                    -- the old one is gone. Force re-open from scratch.
                    Config.desktop_session_opened = false
                    Desktop._desktop_widget = nil
                    Desktop._fm = nil
                end
            end
        end

        -- Pre-activate the Desktop tab so the initial bar renders correctly.
        local _will_autoopen_desktop = (
            not Config.desktop_session_opened
            and G_reader_settings:readSetting("start_with", "filemanager") == "desktop_simpleui"
            and G_reader_settings:nilOrTrue("navbar_desktop_enabled")
            and Config.tabInTabs("desktop", tabs)
        )
        if _will_autoopen_desktop or _desktop_was_visible then plugin.active_action = "desktop" end

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on2, topbar_idx =
            UI.wrapWithNavbar(inner_widget, plugin.active_action, tabs)
        fm_self._navbar_bar               = bar
        fm_self._navbar_topbar            = topbar
        fm_self._navbar_topbar_idx        = topbar_idx
        fm_self._navbar_tabs              = tabs
        fm_self._navbar_container         = navbar_container
        fm_self._navbar_bar_idx           = bar_idx
        fm_self._navbar_bar_idx_topbar_on = topbar_on2
        fm_self._navbar_content_h         = UI.getContentHeight()
        fm_self._navbar_topbar_h          = topbar_on2 and require("topbar").TOTAL_TOP_H() or 0
        fm_self[1]                        = wrapped

        -- Auto-open Desktop: inject the widget synchronously now (so the first
        -- paint already shows the Desktop), then register touch zones in onShow
        -- once the FM is on the UIManager stack.
        if _will_autoopen_desktop or _desktop_was_visible then
            Config.desktop_session_opened = true
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop then
                local close_fn = function()
                    local fm = fm_self
                    pcall(function()
                        Desktop:hide()
                        plugin.active_action = plugin._navbar_default_action or "home"
                        Bottombar.replaceBar(fm, Bottombar.buildBarWidget(plugin.active_action, tabs), tabs)
                        UIManager:setDirty(fm._navbar_container, "ui")
                    end)
                end
                if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                if plugin._goalTapCallback then Desktop._on_goal_tap = plugin._goalTapCallback end
                Desktop._on_qa_tap = function(action_id) plugin:_onTabTap(action_id, fm_self) end
                -- _injectWidget is safe before UIManager:show — no touch zones yet.
                local ok_inj, injected = pcall(function() return Desktop:_injectWidget(fm_self, close_fn) end)
                logger.dbg("simpleui setupLayout: _injectWidget ok=" .. tostring(ok_inj) .. " result=" .. tostring(injected))
                if _desktop_was_visible then
                    -- reinit(): FM is already on the UIManager stack, so we can
                    -- register touch zones immediately rather than waiting for onShow.
                    -- Guard: setupLayout is called multiple times during FM boot;
                    -- only register zones on the FIRST call to avoid stacking duplicates.
                    if not fm_self._desktop_zones_registered then
                        fm_self._desktop_zones_registered = true
                        logger.dbg("simpleui setupLayout: reinit with desktop visible -> _registerZones now")
                        if ok_inj and injected then
                            pcall(function() Desktop:_registerZones(fm_self) end)
                        end
                    end
                    fm_self._desktop_needs_zones = nil
                else
                    -- _registerZones needs the FM on the UIManager stack; done in onShow below.
                    fm_self._desktop_needs_zones = (ok_inj and injected) and Desktop or nil
                end
            end
        end

        pcall(function() plugin:_updateFMHomeIcon() end)

        -- onShow: complete Desktop setup (touch zones) if needed, then fix the bar.
        local orig_onShow = fm_self.onShow
        fm_self.onShow = function(this)
            if orig_onShow then orig_onShow(this) end
            Bottombar.resizePaginationButtons(this.file_chooser or this, Bottombar.getPaginationIconSize())
            UIManager:setDirty(this[1], "ui")

            local ok_d, Desktop = pcall(require, "desktop")

            -- Complete Desktop setup: register touch zones now that FM is on the stack.
            if this._desktop_needs_zones then
                logger.dbg("simpleui onShow: _desktop_needs_zones → _registerZones")
                logger.dbg("simpleui onShow: navbar_container[1] is desktop_widget=", tostring(this._navbar_container and this._navbar_container[1] == Desktop._desktop_widget))
                local D = this._desktop_needs_zones
                this._desktop_needs_zones = nil
                pcall(function() D:_registerZones(this) end)
                logger.dbg("simpleui onShow: after _registerZones, navbar_container[1] is desktop_widget=", tostring(this._navbar_container and this._navbar_container[1] == Desktop._desktop_widget))
                -- Bar is already set to "desktop" from setupLayout — nothing to replace.
                return
            end

            -- Re-register Desktop touch zones on FM reshow (e.g. returning from reader).
            -- Skip if already registered via setupLayout (flag set there) to avoid
            -- stacking duplicate zones on every onShow.
            if ok_d and Desktop and Desktop._registered_zones and this.registerTouchZones
            and not this._desktop_zones_registered then
                this._desktop_zones_registered = true
                if this.unregisterTouchZones then
                    this:unregisterTouchZones(Desktop._registered_zones)
                end
                this:registerTouchZones(Desktop._registered_zones)
            end

            -- Set correct active tab:
            -- If Desktop is visible → leave bar as-is (already shows "desktop" active).
            -- Otherwise → activate "home".
            local desktop_visible = ok_d and Desktop and Desktop._desktop_widget
            logger.dbg("simpleui onShow: desktop_visible=" .. tostring(desktop_visible ~= nil) .. " session_opened=" .. tostring(Config.desktop_session_opened))
            if desktop_visible and Config.desktop_session_opened then return end
            if this._navbar_container then
                local t = Config.loadTabConfig()
                plugin.active_action = "home"
                Bottombar.replaceBar(this, Bottombar.buildBarWidget("home", t), t)
                UIManager:setDirty(this._navbar_container, "ui")
            end
        end

        plugin:_registerTouchZones(fm_self)

        fm_self.onPathChanged = function(this, new_path)
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop and Desktop._desktop_widget then return end
            local t          = Config.loadTabConfig()
            local new_active = M._resolveTabForPath(new_path, t)
            plugin.active_action = new_active
            if this._navbar_container then
                Bottombar.replaceBar(this, Bottombar.buildBarWidget(new_active, t), t)
                UIManager:setDirty(this._navbar_container, "ui")
            end
            pcall(function() plugin:_updateFMHomeIcon() end)
        end
    end
end

-- Resolves the active tab from the current filesystem path.
function M._resolveTabForPath(path, tabs)
    if not path then return nil end
    path = path:gsub("/$", "")
    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then home_dir = home_dir:gsub("/$", "") end
    for __, tab_id in ipairs(tabs) do
        if tab_id == "home" then
            if home_dir and path == home_dir then return "home" end
        elseif tab_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(tab_id)
            if cfg.path then
                local cfg_path = cfg.path:gsub("/$", "")
                if path == cfg_path then return tab_id end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- _patchStartWithMenu
-- ---------------------------------------------------------------------------

function M.patchStartWithMenu()
    local ok_fmm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not (ok_fmm and FileManagerMenu) then return end
    local orig_fn = FileManagerMenu.getStartWithMenuTable
    if not orig_fn then return end
    FileManagerMenu.getStartWithMenuTable = function(fmm_self)
        local result = orig_fn(fmm_self)
        if not G_reader_settings:nilOrTrue("navbar_desktop_enabled") then return result end
        local sub = result.sub_item_table
        if type(sub) ~= "table" then return result end
        table.insert(sub, #sub, {
            text         = _("Desktop"),
            checked_func = function()
                return G_reader_settings:readSetting("start_with", "filemanager") == "desktop_simpleui"
            end,
            callback = function()
                G_reader_settings:saveSetting("start_with", "desktop_simpleui")
            end,
            radio = true,
        })
        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with", "filemanager") == "desktop_simpleui" then
                return _("Start with") .. ": " .. _("Desktop")
            end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- ---------------------------------------------------------------------------
-- _patchBookList
-- ---------------------------------------------------------------------------

function M.patchBookList(plugin)
    local BookList    = require("ui/widget/booklist")
    local orig_bl_new = BookList.new
    plugin._orig_booklist_new = orig_bl_new
    BookList.new = function(class, attrs, ...)
        attrs = attrs or {}
        if not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
        end
        return orig_bl_new(class, attrs, ...)
    end
end

-- ---------------------------------------------------------------------------
-- _patchCollections
-- ---------------------------------------------------------------------------

function M.patchCollections(plugin)
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not (ok and FMColl) then return end
    local Menu          = require("ui/widget/menu")
    local orig_menu_new = Menu.new
    plugin._orig_menu_new    = orig_menu_new
    plugin._orig_fmcoll_show = FMColl.onShowCollList
    local patch_depth = 0

    local orig_onShowCollList = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc_self, ...)
        patch_depth = patch_depth + 1
        local ok2, result = pcall(orig_onShowCollList, fmc_self, ...)
        patch_depth = patch_depth - 1
        if not ok2 then error(result) end
        return result
    end

    Menu.new = function(class, attrs, ...)
        attrs = attrs or {}
        if patch_depth > 0
                and attrs.covers_fullscreen and attrs.is_borderless
                and attrs.is_popout == false
                and not attrs.height and not attrs._navbar_height_reduced then
            attrs.height                 = UI.getContentHeight()
            attrs.y                      = UI.getContentTop()
            attrs._navbar_height_reduced = true
            attrs.name                   = attrs.name or "coll_list"
        end
        return orig_menu_new(class, attrs, ...)
    end

    -- Patch ReadCollection to keep the SimpleUI collections pool in sync when
    -- a collection is renamed or deleted from within KOReader.
    local ok_rc, RC = pcall(require, "readcollection")
    if ok_rc and RC then
        -- Removes a collection name from the SimpleUI selected list and
        -- cover-override table, then refreshes the Desktop if visible.
        local function _removeFromPool(name)
            local ok_cw, CW = pcall(require, "collectionswidget")
            if not (ok_cw and CW) then return end
            local selected = CW.getSelected()
            local changed  = false
            for i = #selected, 1, -1 do
                if selected[i] == name then
                    table.remove(selected, i)
                    changed = true
                end
            end
            if changed then CW.saveSelected(selected) end
            local overrides = CW.getCoverOverrides()
            if overrides[name] then
                overrides[name] = nil
                CW.saveCoverOverrides(overrides)
            end
        end

        -- Renames a collection entry in the SimpleUI selected list and
        -- cover-override table, then refreshes the Desktop if visible.
        local function _renameInPool(old_name, new_name)
            local ok_cw, CW = pcall(require, "collectionswidget")
            if not (ok_cw and CW) then return end
            local selected = CW.getSelected()
            local changed  = false
            for i, name in ipairs(selected) do
                if name == old_name then
                    selected[i] = new_name
                    changed = true
                end
            end
            if changed then CW.saveSelected(selected) end
            local overrides = CW.getCoverOverrides()
            if overrides[old_name] then
                overrides[new_name] = overrides[old_name]
                overrides[old_name] = nil
                CW.saveCoverOverrides(overrides)
            end
        end

        -- Schedules a Desktop refresh if it is currently visible.
        local function _refreshDesktop()
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop and Desktop._desktop_widget and Desktop._fm then
                Desktop:refresh()
            end
        end

        -- Patch removeCollection (called when the user deletes a collection).
        if type(RC.removeCollection) == "function" then
            local orig_remove = RC.removeCollection
            plugin._orig_rc_remove = orig_remove
            RC.removeCollection = function(rc_self, coll_name, ...)
                local result = orig_remove(rc_self, coll_name, ...)
                pcall(function()
                    _removeFromPool(coll_name)
                    _refreshDesktop()
                end)
                return result
            end
        end

        -- Patch renameCollection (called when the user renames a collection).
        if type(RC.renameCollection) == "function" then
            local orig_rename = RC.renameCollection
            plugin._orig_rc_rename = orig_rename
            RC.renameCollection = function(rc_self, old_name, new_name, ...)
                local result = orig_rename(rc_self, old_name, new_name, ...)
                pcall(function()
                    _renameInPool(old_name, new_name)
                    _refreshDesktop()
                end)
                return result
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- _patchFullscreenWidgets
-- ---------------------------------------------------------------------------

function M.patchFullscreenWidgets(plugin)
    local ok_sw, SortWidget  = pcall(require, "ui/widget/sortwidget")
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")

    if ok_sw and SortWidget then
        local ok_tb, TitleBar = pcall(require, "ui/widget/titlebar")
        local orig_sw_new     = SortWidget.new
        plugin._orig_sortwidget_new = orig_sw_new
        SortWidget.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            local orig_tb_new
            if ok_tb and TitleBar and attrs.covers_fullscreen then
                orig_tb_new = TitleBar.new
                TitleBar.new = function(tb_class, tb_attrs, ...)
                    tb_attrs = tb_attrs or {}
                    tb_attrs.title_h_padding = Screen:scaleBySize(24)
                    return orig_tb_new(tb_class, tb_attrs, ...)
                end
            end
            local sw = orig_sw_new(class, attrs, ...)
            if orig_tb_new then TitleBar.new = orig_tb_new end
            if not attrs.covers_fullscreen then return sw end
            pcall(function()
                local vfooter = sw[1] and sw[1][1] and sw[1][1][2] and sw[1][1][2][1]
                if vfooter and vfooter[3] and vfooter[3].dimen then
                    vfooter[3].dimen.h = 0
                end
            end)
            pcall(function()
                local orig_populate = sw._populateItems
                if type(orig_populate) == "function" then
                    sw._populateItems = function(self_sw, ...)
                        local result = orig_populate(self_sw, ...)
                        UIManager:setDirty(nil, "ui")
                        return result
                    end
                end
            end)
            return sw
        end
    end

    if ok_pc and PathChooser then
        local orig_pc_new = PathChooser.new
        plugin._orig_pathchooser_new = orig_pc_new
        PathChooser.new = function(class, attrs, ...)
            attrs = attrs or {}
            if attrs.covers_fullscreen and not attrs._navbar_height_reduced then
                attrs.height                 = UI.getContentHeight()
                attrs.y                      = UI.getContentTop()
                attrs._navbar_height_reduced = true
            end
            return orig_pc_new(class, attrs, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- _patchUIManagerShow
-- ---------------------------------------------------------------------------

function M.patchUIManagerShow(plugin)
    local orig_show = UIManager.show
    plugin._orig_uimanager_show = orig_show
    local _show_depth = 0

    local INJECT_NAMES = { collections = true, history = true, coll_list = true }

    UIManager.show = function(um_self, widget, ...)
        _show_depth = _show_depth + 1

        -- Desktop: only activate the tab, do not inject a navbar.
        if _show_depth == 1 and widget and widget.name == "desktop" then
            local tabs = Config.loadTabConfig()
            if Config.tabInTabs("desktop", tabs) then
                setActiveAndRefreshFM(plugin, "desktop", tabs)
            end
            local result = orig_show(um_self, widget, ...)
            _show_depth  = _show_depth - 1
            return result
        end

        local should_inject = _show_depth == 1
            and widget
            and not widget._navbar_injected
            and not widget._navbar_skip_inject
            and widget ~= plugin.ui
            and widget.covers_fullscreen
            and widget.title_bar ~= nil
            and (widget._navbar_height_reduced or (widget.name and INJECT_NAMES[widget.name]))

        if not should_inject then
            local result = orig_show(um_self, widget, ...)
            _show_depth  = _show_depth - 1
            return result
        end

        widget._navbar_injected = true

        if not widget._navbar_height_reduced then
            local content_h   = UI.getContentHeight()
            local content_top = UI.getContentTop()
            if widget.dimen then
                widget.dimen.h = content_h
                widget.dimen.y = content_top
            end
            pcall(function()
                if widget[1] and widget[1].dimen then
                    widget[1].dimen.h = content_h
                    widget[1].dimen.y = content_top
                end
            end)
            widget._navbar_height_reduced = true
        end

        -- Adjust title bar buttons for injected widgets.
        pcall(function()
            local tb = widget.title_bar
            if not tb then return end
            if tb.left_button then
                tb.left_button.overlap_align  = nil
                tb.left_button.overlap_offset = { Screen:scaleBySize(13), 0 }
            end
        end)
        pcall(function()
            local rb = widget.title_bar and widget.title_bar.right_button
            if rb then
                rb.dimen         = require("ui/geometry"):new{ w = 0, h = 0 }
                rb.callback      = function() end
                rb.hold_callback = function() end
            end
        end)

        local tabs          = Config.loadTabConfig()
        local action_before = plugin.active_action
        local tabs_set      = {}
        for __, id in ipairs(tabs) do tabs_set[id] = true end

        local effective_action = nil

        if widget.name == "collections" and Config.isFavoritesWidget(widget) and tabs_set["favorites"] then
            effective_action = setActiveAndRefreshFM(plugin, "favorites", tabs)
            pcall(function()
                local orig_onReturn = widget.onReturn
                if not orig_onReturn then return end
                widget.onReturn = function(w_self, ...)
                    plugin:_restoreTabInFM(w_self._navbar_tabs, action_before)
                    return orig_onReturn(w_self, ...)
                end
            end)
        elseif widget.name == "history" and tabs_set["history"] then
            effective_action = setActiveAndRefreshFM(plugin, "history", tabs)
        elseif widget.name == "desktop" and tabs_set["desktop"] then
            effective_action = setActiveAndRefreshFM(plugin, "desktop", tabs)
        elseif widget.name == "coll_list"
               or (widget.name == "collections" and not Config.isFavoritesWidget(widget)) then
            if tabs_set["collections"] then
                effective_action = setActiveAndRefreshFM(plugin, "collections", tabs)
            end
        end

        local display_action = effective_action or action_before
        if not widget._navbar_inner then widget._navbar_inner = widget[1] end

        local navbar_container, wrapped, bar, topbar, bar_idx, topbar_on, topbar_idx =
            UI.wrapWithNavbar(widget._navbar_inner, display_action, tabs)
        widget._navbar_container          = navbar_container
        widget._navbar_bar                = bar
        widget._navbar_topbar             = topbar
        widget._navbar_topbar_idx         = topbar_idx
        widget._navbar_tabs               = tabs
        widget._navbar_bar_idx            = bar_idx
        widget._navbar_bar_idx_topbar_on  = topbar_on
        widget._navbar_prev_action        = action_before
        widget[1]                         = wrapped
        plugin:_registerTouchZones(widget)

        pcall(function()
            local rb = widget.return_button
            if rb and rb[1] then rb[1].width = UI.SIDE_M() end
        end)

        Bottombar.resizePaginationButtons(widget, Bottombar.getPaginationIconSize())

        if widget.name == "desktop" and widget.onShow then
            pcall(function() widget:onShow() end)
        end

        orig_show(um_self, widget, ...)
        _show_depth = _show_depth - 1
        UIManager:setDirty(widget[1], "ui")
    end
end

-- ---------------------------------------------------------------------------
-- _patchUIManagerClose
-- ---------------------------------------------------------------------------

function M.patchUIManagerClose(plugin)
    local orig_close = UIManager.close
    plugin._orig_uimanager_close = orig_close

    UIManager.close = function(um_self, widget, ...)
        if widget and widget._navbar_injected
                and not widget._navbar_closing_intentionally then
            local start_with = G_reader_settings:readSetting("start_with", "filemanager")
            if start_with ~= "desktop_simpleui" then
                -- coll_list is opened on top of the collections widget, so
                -- restoreTabInFM's should_skip would fire (another _navbar_injected
                -- widget is still on the stack). Force a direct restore to home instead.
                if widget.name == "coll_list" then
                    local fm = plugin.ui
                    if fm and fm._navbar_container then
                        local t = Config.loadTabConfig()
                        -- Prefer the prev_action saved on the collections widget
                        -- sitting beneath coll_list in the stack (that reflects
                        -- what was active before the user entered collections).
                        local restored = nil
                        pcall(function()
                            for __, entry in ipairs(UI.getWindowStack()) do
                                local w = entry.widget
                                if w and w ~= widget and w._navbar_injected
                                        and (w.name == "collections" or w.name == "coll_list") then
                                    restored = w._navbar_prev_action
                                    break
                                end
                            end
                        end)
                        -- fallback: resolve from current FM path
                        if not restored then
                            restored = (fm.file_chooser
                                        and M._resolveTabForPath(fm.file_chooser.path, t))
                                    or t[1] or "home"
                        end
                        plugin.active_action = restored
                        Bottombar.replaceBar(fm, Bottombar.buildBarWidget(restored, t), t)
                        UIManager:setDirty(fm._navbar_container, "ui")
                    end
                else
                    plugin:_restoreTabInFM(widget._navbar_tabs, widget._navbar_prev_action)
                end
            end
        end

        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        local closing_reader = ok_rui and ReaderUI and widget and widget == ReaderUI.instance

        local result = orig_close(um_self, widget, ...)

        if closing_reader then
            plugin:_scheduleTopbarRefresh(0)
            Config.desktop_session_opened = false
        end

        local start_with = G_reader_settings:readSetting("start_with", "filemanager")
        if start_with == "desktop_simpleui"
                and widget
                and widget.covers_fullscreen
                and widget ~= plugin.ui
                and widget.name ~= "coll_list"   -- coll_list closes onto collections, not the FM
                and not widget._navbar_closing_intentionally then
            local fm = plugin.ui
            local other_open = false
            pcall(function()
                for __, entry in ipairs(UI.getWindowStack()) do
                    local w = entry.widget
                    if w and w ~= fm and w ~= widget and w.covers_fullscreen then
                        other_open = true; return
                    end
                end
            end)
            if not other_open and fm and fm._navbar_container then
                local ok_d, Desktop = pcall(require, "desktop")
                if ok_d and Desktop and not Desktop._desktop_widget then
                    UIManager:scheduleIn(0, function()
                        local tabs = Config.loadTabConfig()
                        setActiveAndRefreshFM(plugin, "desktop", tabs)
                        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
                        if plugin._goalTapCallback then Desktop._on_goal_tap = plugin._goalTapCallback end
                        Desktop._on_qa_tap = function(action_id) plugin:_onTabTap(action_id, fm) end
                        Desktop:onShowDesktop(fm, function()
                            local t = Config.loadTabConfig()
                            setActiveAndRefreshFM(plugin, t[1] or "home", t)
                        end)
                    end)
                end
            end
        end

        return result
    end
end

-- ---------------------------------------------------------------------------
-- _patchMenuInitForPagination
-- ---------------------------------------------------------------------------

function M.patchMenuInitForPagination(plugin)
    local Menu = require("ui/widget/menu")
    local TARGET_NAMES = {
        filemanager = true, history = true, collections = true, coll_list = true,
    }
    local orig_menu_init = Menu.init
    plugin._orig_menu_init = orig_menu_init

    Menu.init = function(menu_self, ...)
        orig_menu_init(menu_self, ...)
        if G_reader_settings:nilOrTrue("navbar_pagination_visible") then return end
        if not TARGET_NAMES[menu_self.name]
           and not (menu_self.covers_fullscreen
                    and menu_self.is_borderless
                    and menu_self.title_bar_fm_style) then
            return
        end
        local content = menu_self[1] and menu_self[1][1]
        if content then
            for i = #content, 1, -1 do
                if content[i] ~= menu_self.content_group then
                    table.remove(content, i)
                end
            end
        end
        menu_self._recalculateDimen = function(self_inner, no_recalculate_dimen)
            local saved_arrow = self_inner.page_return_arrow
            local saved_text  = self_inner.page_info_text
            local saved_info  = self_inner.page_info
            self_inner.page_return_arrow = nil
            self_inner.page_info_text    = nil
            self_inner.page_info         = nil
            local instance_fn = self_inner._recalculateDimen
            self_inner._recalculateDimen = nil
            local ok, err = pcall(function()
                self_inner:_recalculateDimen(no_recalculate_dimen)
            end)
            self_inner._recalculateDimen = instance_fn
            self_inner.page_return_arrow = saved_arrow
            self_inner.page_info_text    = saved_text
            self_inner.page_info         = saved_info
            if not ok then error(err, 2) end
        end
        menu_self:_recalculateDimen()
    end
end

-- ---------------------------------------------------------------------------
-- installAll / teardownAll
-- ---------------------------------------------------------------------------

function M.installAll(plugin)
    M.patchFileManagerClass(plugin)
    M.patchStartWithMenu()
    M.patchBookList(plugin)
    M.patchCollections(plugin)
    M.patchFullscreenWidgets(plugin)
    M.patchUIManagerShow(plugin)
    M.patchUIManagerClose(plugin)
    M.patchMenuInitForPagination(plugin)
end

function M.teardownAll(plugin)
    if plugin._orig_uimanager_show then
        UIManager.show  = plugin._orig_uimanager_show
        plugin._orig_uimanager_show = nil
    end
    if plugin._orig_uimanager_close then
        UIManager.close = plugin._orig_uimanager_close
        plugin._orig_uimanager_close = nil
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and plugin._orig_booklist_new then
        BookList.new = plugin._orig_booklist_new; plugin._orig_booklist_new = nil
    end
    local ok_m, Menu = pcall(require, "ui/widget/menu")
    if ok_m and Menu then
        if plugin._orig_menu_new  then Menu.new  = plugin._orig_menu_new;  plugin._orig_menu_new  = nil end
        if plugin._orig_menu_init then Menu.init = plugin._orig_menu_init; plugin._orig_menu_init = nil end
    end
    local ok_fc, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if ok_fc and FMColl and plugin._orig_fmcoll_show then
        FMColl.onShowCollList = plugin._orig_fmcoll_show; plugin._orig_fmcoll_show = nil
    end
    local ok_rc, RC = pcall(require, "readcollection")
    if ok_rc and RC then
        if plugin._orig_rc_remove then RC.removeCollection = plugin._orig_rc_remove; plugin._orig_rc_remove = nil end
        if plugin._orig_rc_rename then RC.renameCollection = plugin._orig_rc_rename; plugin._orig_rc_rename = nil end
    end
    local ok_fch, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fch and FileChooser and plugin._orig_fc_init then
        FileChooser.init            = plugin._orig_fc_init
        FileChooser._navbar_patched = nil
        plugin._orig_fc_init        = nil
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and plugin._orig_fm_setup then
        FileManager.setupLayout = plugin._orig_fm_setup; plugin._orig_fm_setup = nil
    end
end

return M
