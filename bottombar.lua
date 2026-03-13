-- bottombar.lua — Simple UI
-- Dimensions, visual construction, touch zones, navigation and bar-rebuild helpers
-- for the bottom tab bar.

local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local ImageWidget     = require("ui/widget/imagewidget")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Device          = require("device")
local Screen          = Device.screen
local ReaderUI        = require("apps/reader/readerui")
local logger          = require("logger")
local _               = require("gettext")

local Config      = require("config")
local DataStorage = require("datastorage")

local M = {}

-- Resolves a relative icon path to the correct absolute or relative path.
--
-- On Boox/Android two distinct roots exist:
--   - "resources/" paths  → KOReader install dir, already on the working-directory
--                           search path, so they work as plain relative paths.
--   - "plugins/"  paths   → external/user storage (/storage/emulated/0/koreader/),
--                           NOT on the working-directory path, so they need an
--                           absolute prefix from DataStorage:getDataDir().
--
-- Using lfs or package.searchpath to discover the install dir is fragile on
-- Android; the log shows both approaches fail.  The path-prefix split is the
-- reliable solution: leave "resources/" alone, absolutise "plugins/".
local _data_dir = nil
local function resolveIconPath(path)
    if not path then return path end
    if path:sub(1, 1) == "/" then return path end  -- already absolute
    if path:find("^plugins/") then
        if not _data_dir then _data_dir = DataStorage:getDataDir() end
        return _data_dir .. "/" .. path
    end
    -- "resources/" and anything else: relative path works as-is on all platforms.
    return path
end

-- ---------------------------------------------------------------------------
-- Bar colors
-- ---------------------------------------------------------------------------

M.COLOR_INACTIVE_TEXT = Blitbuffer.gray(0.55)
M.COLOR_SEPARATOR     = Blitbuffer.gray(0.7)

-- ---------------------------------------------------------------------------
-- Dimension cache — computed once per layout, cleared on screen resize
-- ---------------------------------------------------------------------------

local _dim = {}

function M.invalidateDimCache()
    _dim = {}
end

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

function M.BAR_H()       return _cached("bar_h",   function() return Screen:scaleBySize(96) end) end
function M.ICON_SZ()     return _cached("icon_sz", function() return Screen:scaleBySize(44) end) end
function M.TOP_SP()      return _cached("top_sp",  function() return Screen:scaleBySize(2)  end) end
function M.BOT_SP()      return _cached("bot_sp",  function() return Screen:scaleBySize(12)  end) end
function M.SIDE_M()      return _cached("side_m",  function() return Screen:scaleBySize(24) end) end
function M.INDIC_H()     return _cached("indic_h", function() return Screen:scaleBySize(3)  end) end
function M.ICON_TOP_SP() return _cached("it_sp",   function() return Screen:scaleBySize(10) end) end
function M.ICON_TXT_SP() return _cached("itxt_sp", function() return Screen:scaleBySize(4)  end) end
function M.LABEL_FS()    return _cached("lbl_fs",  function() return Screen:scaleBySize(9)  end) end
function M.SEP_H()       return _cached("sep_h",   function() return Screen:scaleBySize(1)  end) end

function M.TOTAL_H()
    if not G_reader_settings:nilOrTrue("navbar_enabled") then return 0 end
    return M.BAR_H() + M.TOP_SP() + M.BOT_SP()
end

-- ---------------------------------------------------------------------------
-- Pagination bar helpers
-- ---------------------------------------------------------------------------

function M.getPaginationIconSize()
    local key = G_reader_settings:readSetting("navbar_pagination_size") or "s"
    if key == "xs" then return Screen:scaleBySize(20)
    elseif key == "s" then return Screen:scaleBySize(28)
    else return Screen:scaleBySize(36) end
end

function M.getPaginationFontSize()
    local key = G_reader_settings:readSetting("navbar_pagination_size") or "s"
    if key == "xs" then return 11
    elseif key == "s" then return 14
    else return 20 end
end

function M.resizePaginationButtons(widget, icon_size)
    pcall(function()
        for __, btn in ipairs({
            widget.page_info_left_chev,
            widget.page_info_right_chev,
            widget.page_info_first_chev,
            widget.page_info_last_chev,
        }) do
            if btn then
                btn.icon_width  = icon_size
                btn.icon_height = icon_size
                btn:init()
            end
        end
        local txt = widget.page_info_text
        if txt then
            txt.text_font_size = M.getPaginationFontSize()
            txt:init()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Visual construction
-- ---------------------------------------------------------------------------

-- Distributes usable width across tabs; the last tab absorbs the rounding remainder.
function M.getTabWidths(num_tabs, usable_w)
    local base_w = math.floor(usable_w / num_tabs)
    local widths = {}
    for i = 1, num_tabs do
        widths[i] = (i == num_tabs) and (usable_w - base_w * (num_tabs - 1)) or base_w
    end
    return widths
end

-- Builds one tab cell: active indicator line, icon and/or text label.
function M.buildTabCell(action_id, active, tab_w, mode)
    local action          = Config.getActionById(action_id)
    local indicator_color = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local vg              = VerticalGroup:new{ align = "center" }

    vg[#vg + 1] = LineWidget:new{
        dimen      = Geom:new{ w = tab_w, h = M.SEP_H() },
        background = M.COLOR_SEPARATOR,
    }
    vg[#vg + 1] = LineWidget:new{
        dimen      = Geom:new{ w = tab_w, h = M.INDIC_H() },
        background = indicator_color,
    }
    vg[#vg + 1] = VerticalSpan:new{ width = M.ICON_TOP_SP() }

    if mode == "icons" or mode == "both" then
        vg[#vg + 1] = ImageWidget:new{
            file   = resolveIconPath(action.icon),
            width  = M.ICON_SZ(),
            height = M.ICON_SZ(),
            alpha  = true,
        }
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            vg[#vg + 1] = VerticalSpan:new{ width = M.ICON_TXT_SP() }
        end
        vg[#vg + 1] = TextWidget:new{
            text    = action.label,
            face    = Font:getFace("cfont", M.LABEL_FS()),
            fgcolor = active and Blitbuffer.COLOR_BLACK or M.COLOR_INACTIVE_TEXT,
        }
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = tab_w, h = M.BAR_H() },
        vg,
    }
end

-- Assembles the full bottom bar FrameContainer from all tab cells.
function M.buildBarWidget(active_action_id, tab_config, num_tabs, mode)
    num_tabs    = num_tabs or Config.getNumTabs()
    mode        = mode     or Config.getNavbarMode()
    local screen_w = Screen:getWidth()
    local side_m   = M.SIDE_M()
    local usable_w = screen_w - side_m * 2
    local widths   = M.getTabWidths(num_tabs, usable_w)
    local hg_args  = { align = "top" }

    for i = 1, num_tabs do
        local action_id = tab_config[i]
        hg_args[#hg_args + 1] = M.buildTabCell(action_id, action_id == active_action_id, widths[i], mode)
    end

    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = side_m,
        padding_right = side_m,
        margin        = 0,
        background    = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new(hg_args),
    }
end

-- Swaps the bar widget inside an already-wrapped widget, preserving overlap_offset.
function M.replaceBar(widget, new_bar, tabs)
    if not G_reader_settings:nilOrTrue("navbar_enabled") then
        if widget and tabs then widget._navbar_tabs = tabs end
        return
    end
    local container = widget._navbar_container
    if not container then return end
    local idx = widget._navbar_bar_idx
    if not idx then
        logger.err("simpleui: replaceBar called without _navbar_bar_idx — widget not initialised.")
        return
    end
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    if widget._navbar_bar_idx_topbar_on ~= nil and widget._navbar_bar_idx_topbar_on ~= topbar_on then
        logger.warn("simpleui: replaceBar — bar_idx out of sync, skipping.")
        return
    end
    local old_bar = container[idx]
    if old_bar and old_bar.overlap_offset then
        new_bar.overlap_offset = old_bar.overlap_offset
    end
    container[idx]     = new_bar
    widget._navbar_bar = new_bar
    if tabs then widget._navbar_tabs = tabs end
end

-- ---------------------------------------------------------------------------
-- TapSelect class patch  (fix for issue #4 / Project: Title interaction)
--
-- Root cause
-- ----------
-- KOReader dispatches widget-level ges_events (such as MosaicMenuItem's
-- TapSelect from Project: Title) BEFORE checking touch zones registered on
-- the parent FileManager via registerTouchZones.  When a mosaic/list item
-- occupies the same screen area as the bar, its onTapSelect fires first,
-- returns true, and the event is consumed — so the bar's registered zone
-- handler never runs.  This is why every zone-based fix fails here.
--
-- Fix
-- ---
-- Patch the onTapSelect METHOD on the class itself (via the Lua metatable)
-- so that any tap whose y coordinate falls inside the bar region is
-- intercepted and dispatched to the correct tab instead.  Patching the
-- class (not individual instances) means the fix applies to all current and
-- future instances without re-walking the tree on every redraw.
--
-- The patch is idempotent: cls._simpleui_tap_patched guards against double
-- wrapping if registerTouchZones is called multiple times.
--
-- Module-level state written by registerTouchZones, read by the patch:
-- ---------------------------------------------------------------------------
M._tap_bar_region_y = nil   -- absolute y of bar top edge (pixels)
M._tap_bar_side_m   = nil   -- left side margin (pixels)
M._tap_bar_widths   = nil   -- {w1, w2, ...} tab widths in display order
M._tap_bar_plugin   = nil   -- plugin instance for _onTabTap dispatch

-- Resolves which tab index a tap_x falls in and fires _onTabTap.
local function _dispatchBarTap(ges)
    local plugin = M._tap_bar_plugin
    local widths = M._tap_bar_widths
    local side_m = M._tap_bar_side_m
    if not (plugin and widths and side_m) then return end

    local tap_x    = ges.pos.x
    local cum      = side_m
    local num_tabs = Config.getNumTabs()
    for i = 1, num_tabs do
        local w = widths[i]
        if not w then break end
        if tap_x >= cum and tap_x < cum + w then
            local t         = Config.loadTabConfig()
            local action_id = t[i]
            if action_id then
                -- The patch fires from the library view; plugin.ui is the
                -- correct fm_self dispatch target in that context.
                plugin:_onTabTap(action_id, plugin.ui)
            end
            return
        end
        cum = cum + w
    end
    -- Tap in a margin gap — consumed silently, nothing to dispatch.
end

-- Walks the widget tree rooted at `widget` and patches the onTapSelect
-- method on every distinct class that exposes a TapSelect ges_event.
-- Recursion stops at any such widget (its children are cosmetic only).
local function _patchTapSelectClasses(widget, depth)
    if depth > 12 or type(widget) ~= "table" then return end

    if widget.ges_events
       and widget.ges_events.TapSelect
       and widget.onTapSelect
    then
        -- getmetatable(instance) returns the class table in KOReader's OOP.
        local cls = getmetatable(widget)
        if cls and cls.onTapSelect and not cls._simpleui_tap_patched then
            local orig = cls.onTapSelect
            cls.onTapSelect = function(self_w, arg, ges)
                local bar_y   = M._tap_bar_region_y
                -- In some KOReader versions the gesture arrives as `arg`
                -- rather than `ges`; handle both.
                local gesture = (ges and ges.pos and ges) or (arg and arg.pos and arg)
                if bar_y and gesture and gesture.pos.y >= bar_y then
                    _dispatchBarTap(gesture)
                    return true
                end
                return orig(self_w, arg, ges)
            end
            cls._simpleui_tap_patched = true
            logger.dbg("simpleui: patched TapSelect on class", tostring(cls))
        end
        return  -- no need to recurse into cosmetic children
    end

    for _, child in ipairs(widget) do
        _patchTapSelectClasses(child, depth + 1)
    end
end

-- ---------------------------------------------------------------------------
-- Touch zones
-- ---------------------------------------------------------------------------

function M.registerTouchZones(plugin, fm_self)
    local num_tabs  = Config.getNumTabs()
    local screen_w  = Screen:getWidth()
    local screen_h  = Screen:getHeight()
    local navbar_on = G_reader_settings:nilOrTrue("navbar_enabled")
    local bar_h     = navbar_on and M.BAR_H() or 0
    local side_m    = M.SIDE_M()
    local usable_w  = screen_w - side_m * 2
    local bar_y     = navbar_on and (screen_h - bar_h - M.BOT_SP()) or screen_h
    local widths    = M.getTabWidths(num_tabs, usable_w)

    -- Store dispatch state used by the TapSelect class patch below.
    M._tap_bar_region_y = bar_y
    M._tap_bar_side_m   = side_m
    M._tap_bar_widths   = widths
    M._tap_bar_plugin   = plugin

    -- Walk fm_self's widget tree and patch any TapSelect-bearing class
    -- (e.g. MosaicMenuItem, ListMenuItem from Project: Title).
    -- Safe no-op when Project: Title is not installed.
    _patchTapSelectClasses(fm_self, 0)

    -- Unregister stale zones from any previous registration.
    if fm_self.unregisterTouchZones then
        local old_zones = {
            { id = "navbar_bar_tap" },
        }
        -- Clean up legacy per-tab zone IDs from older installs.
        for i = 1, Config.MAX_TABS do
            old_zones[#old_zones + 1] = { id = "navbar_pos_" .. i }
        end
        for __, id in ipairs({
            "navbar_hold_start", "navbar_hold_settings",
        }) do
            old_zones[#old_zones + 1] = { id = id }
        end
        fm_self:unregisterTouchZones(old_zones)
    end

    -- Opens the settings menu anchored below the topbar.
    local function showSettingsMenu(title, item_table_fn, top_offset)
        if not item_table_fn then return end
        top_offset = top_offset or 0
        local Menu = require("ui/widget/menu")
        local menu_h = Screen:getHeight() - M.TOTAL_H() - top_offset

        local function resolveItems(items)
            local out = {}
            for __, item in ipairs(items) do
                local r = {}
                for k, v in pairs(item) do r[k] = v end
                if type(item.sub_item_table_func) == "function" then
                    r.sub_item_table      = item.sub_item_table_func()
                    r.sub_item_table_func = nil
                end
                if type(item.checked_func) == "function" then
                    local cf = item.checked_func
                    r.mandatory_func = function() return cf() and "✓" or "" end
                    r.checked_func   = nil
                end
                if type(item.enabled_func) == "function" then
                    local ef = item.enabled_func
                    r.dim          = not ef()
                    r.enabled_func = nil
                end
                out[#out + 1] = r
            end
            return out
        end

        local menu
        menu = Menu:new{
            title      = title,
            item_table = resolveItems(item_table_fn()),
            height     = menu_h,
            width      = Screen:getWidth(),
            onMenuSelect = function(self_menu, item)
                if item.sub_item_table then
                    self_menu.item_table.title = self_menu.title
                    table.insert(self_menu.item_table_stack, self_menu.item_table)
                    self_menu:switchItemTable(item.text, resolveItems(item.sub_item_table))
                elseif item.callback then
                    item.callback()
                    self_menu:updateItems()
                end
                return true
            end,
        }
        if top_offset > 0 then
            local orig_paintTo = menu.paintTo
            menu.paintTo = function(self_m, bb, x, y)
                orig_paintTo(self_m, bb, x, y + top_offset)
            end
            menu.dimen.y = top_offset
        end
        UIManager:show(menu)
    end

    local zones = {}

    -- Single full-width tap zone.  Handles the stock KOReader file list and
    -- any other view that does not use ges_events-based item widgets.
    -- For Project: Title mosaic/list views the TapSelect class patch above
    -- is the active mechanism (zone-level dispatch is bypassed there).
    zones[#zones + 1] = {
        id          = "navbar_bar_tap",
        ges         = "tap",
        screen_zone = {
            ratio_x = 0,
            ratio_y = bar_y / screen_h,
            ratio_w = 1,
            ratio_h = bar_h / screen_h,
        },
        handler = function(ges)
            if not G_reader_settings:nilOrTrue("navbar_enabled") then return false end
            _dispatchBarTap(ges)
            return true
        end,
    }

    -- Hold anywhere on the bar → open settings menu.
    local bar_screen_zone = {
        ratio_x = 0,
        ratio_y = bar_y / screen_h,
        ratio_w = 1,
        ratio_h = bar_h / screen_h,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_start",
        ges         = "hold",
        screen_zone = bar_screen_zone,
        handler     = function(_ges) return true end,
    }
    zones[#zones + 1] = {
        id          = "navbar_hold_settings",
        ges         = "hold_release",
        screen_zone = bar_screen_zone,
        handler = function(_ges)
            if not plugin._makeNavbarMenu then plugin:addToMainMenu({}) end
            local topbar_on  = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
            local top_offset = topbar_on and require("topbar").TOTAL_TOP_H() or 0
            showSettingsMenu(_("Bottom Bar"), plugin._makeNavbarMenu, top_offset)
            return true
        end,
    }

    fm_self:registerTouchZones(zones)
end

-- ---------------------------------------------------------------------------
-- Tab tap handler
-- ---------------------------------------------------------------------------

function M.onTabTap(plugin, action_id, fm_self)
    if action_id == "power" then
        plugin:_setPowerTabActive(true)
        plugin:_showPowerDialog(fm_self)
        return
    end
    if action_id == "wifi_toggle"    then M.doWifiToggle(plugin);        return end
    if action_id == "frontlight"     then M.showFrontlightDialog();      return end
    if action_id == "stats_calendar" then
        plugin:_navigate(action_id, fm_self, Config.loadTabConfig()); return
    end

    local already_active = (plugin.active_action == action_id)

    plugin.active_action = action_id
    local tabs = Config.loadTabConfig()
    if fm_self._navbar_container then
        M.replaceBar(fm_self, M.buildBarWidget(action_id, tabs), tabs)
        UIManager:setDirty(fm_self._navbar_container, "ui")
        UIManager:setDirty(fm_self, "ui")
    end
    pcall(function() plugin:_updateFMHomeIcon() end)
    plugin:_navigate(action_id, fm_self, tabs, already_active)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

local function showUnavailable(msg)
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

local function setActiveAndRefreshFM(plugin, action_id, tabs)
    plugin.active_action = action_id
    local fm = plugin.ui
    if fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
        UIManager:setDirty(fm[1], "ui")
    end
    return action_id
end

function M.navigate(plugin, action_id, fm_self, tabs, force)
    local fm = plugin.ui

    if fm_self ~= fm then
        fm_self._navbar_closing_intentionally = true
        pcall(function()
            if fm_self.onCloseAllMenus then fm_self:onCloseAllMenus()
            elseif fm_self.onClose     then fm_self:onClose() end
        end)
        fm_self._navbar_closing_intentionally = nil
    end

    local ok_d, Desktop = pcall(require, "desktop")
    local _desktop_was_visible  = ok_d and Desktop and Desktop._desktop_widget ~= nil
    local _desktop_orig_inner   = ok_d and Desktop and Desktop._orig_inner
    local _desktop_inner_idx    = ok_d and Desktop and Desktop._inner_idx or 1
    if ok_d and Desktop and Desktop._desktop_widget then
        pcall(function() Desktop:hide() end)
    end

    if fm_self ~= fm and fm._navbar_container then
        M.replaceBar(fm, M.buildBarWidget(action_id, tabs), tabs)
        UIManager:setDirty(fm._navbar_container, "ui")
        UIManager:setDirty(fm, "ui")
    end

    if action_id == "home" then
        if _desktop_was_visible and fm then
            local did_rewrap = false
            pcall(function()
                local UI2 = require("ui")
                local inner = fm._navbar_inner
                    or _desktop_orig_inner
                    or (fm._navbar_container and fm._navbar_container[_desktop_inner_idx])
                if inner and inner ~= (ok_d and Desktop and Desktop._desktop_widget) then
                    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                    local new_container, wrapped, bar, topbar, bar_idx, __, topbar_idx =
                        UI2.wrapWithNavbar(inner, "home", tabs)
                    fm._navbar_container         = new_container
                    fm._navbar_bar               = bar
                    fm._navbar_topbar            = topbar
                    fm._navbar_topbar_idx        = topbar_idx
                    fm._navbar_tabs              = tabs
                    fm._navbar_bar_idx           = bar_idx
                    fm._navbar_bar_idx_topbar_on = topbar_on
                    fm._navbar_content_h         = UI2.getContentHeight()
                    fm._navbar_topbar_h          = topbar_on and require("topbar").TOTAL_TOP_H() or 0
                    fm[1]                        = wrapped
                    plugin:_registerTouchZones(fm)
                    UIManager:setDirty(fm, "partial")
                    did_rewrap = true
                end
            end)
            if not did_rewrap and fm._navbar_container then
                local restore = _desktop_orig_inner or fm._navbar_inner
                if restore then
                    fm._navbar_container[_desktop_inner_idx] = restore
                end
                UIManager:setDirty(fm._navbar_container, "partial")
                UIManager:setDirty(fm, "partial")
            end
        end
        local home = G_reader_settings:readSetting("home_dir")
        if home and fm.file_chooser then
            fm.file_chooser:changeToPath(home)
        elseif fm.onHome then
            fm:onHome()
        end
        if (_desktop_was_visible or force) and fm.file_chooser then
            pcall(function() fm.file_chooser:refreshPath() end)
            UIManager:setDirty(fm._navbar_container, "partial")
            UIManager:setDirty(fm, "partial")
        end

    elseif action_id == "collections" then
        if fm.collections then fm.collections:onShowCollList()
        else showUnavailable(_("Collections not available.")) end

    elseif action_id == "history" then
        local ok = pcall(function() fm.history:onShowHist() end)
        if not ok then showUnavailable(_("History not available.")) end

    elseif action_id == "continue" then
        local ok, ReadHistory = pcall(require, "readhistory")
        if ok then
            ReadHistory:reload()
            local last = ReadHistory.hist and ReadHistory.hist[1]
            if last and last.file then
                setActiveAndRefreshFM(plugin, tabs[1] or "home", tabs)
                ReaderUI:showReader(last.file)
                return
            end
        end
        showUnavailable(_("No books in history."))

    elseif action_id == "favorites" then
        if fm.collections then fm.collections:onShowColl()
        else showUnavailable(_("Favorites not available.")) end

    elseif action_id == "desktop" then
        if not G_reader_settings:nilOrTrue("navbar_desktop_enabled") then return end
        if not package.loaded["desktop"]
           or type((package.loaded["desktop"] or {}).onShowDesktop) ~= "function" then
            package.loaded["desktop"] = nil
        end
        local ok_d2, Desktop2 = pcall(require, "desktop")
        if not ok_d2 or not Desktop2 or type(Desktop2.onShowDesktop) ~= "function" then
            showUnavailable(_("Desktop not available.\n") .. tostring(Desktop2))
            return
        end
        if not plugin._goalTapCallback then plugin:addToMainMenu({}) end
        if plugin._goalTapCallback then Desktop2._on_goal_tap = plugin._goalTapCallback end
        Desktop2._on_qa_tap = function(aid) plugin:_onTabTap(aid, fm) end
        Desktop2:onShowDesktop(fm, function()
            local t = Config.loadTabConfig()
            setActiveAndRefreshFM(plugin, t[1] or "home", t)
        end)

    elseif action_id == "stats_calendar" then
        local opened = false
        if fm and fm.statistics and type(fm.statistics.onShowCalendarView) == "function" then
            local ok = pcall(function() fm.statistics:onShowCalendarView() end)
            if ok then opened = true end
        end
        if not opened then
            local ok = pcall(function()
                local Event = require("ui/event")
                UIManager:sendEvent(Event:new("ShowCalendarView"))
            end)
            if ok then opened = true end
        end
        if not opened then showUnavailable(_("Statistics plugin not available.")) end
        return

    elseif action_id == "wifi_toggle" then
        M.doWifiToggle(plugin); return

    else
        if action_id:match("^custom_qa_%d+$") then
            local cfg = Config.getCustomQAConfig(action_id)
            if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
                local ok_disp, Dispatcher = pcall(require, "dispatcher")
                if ok_disp and Dispatcher then
                    local ok, err = pcall(function()
                        Dispatcher:execute({ [cfg.dispatcher_action] = true })
                    end)
                    if not ok then
                        showUnavailable(string.format(_("System action error: %s"), tostring(err)))
                    end
                else
                    showUnavailable(_("Dispatcher not available."))
                end
            elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm[cfg.plugin_key]
                if plugin_inst and type(plugin_inst[cfg.plugin_method]) == "function" then
                    local ok, err = pcall(function()
                        plugin_inst[cfg.plugin_method](plugin_inst)
                    end)
                    if not ok then
                        showUnavailable(string.format(_("Plugin error: %s"), tostring(err)))
                    end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            elseif cfg.collection and cfg.collection ~= "" then
                if fm.collections then fm.collections:onShowColl(cfg.collection) end
            elseif cfg.path and cfg.path ~= "" then
                if fm.file_chooser then fm.file_chooser:changeToPath(cfg.path) end
            else
                showUnavailable(_(
                    "No folder, collection or plugin configured.\n"
                 .. "Go to Simple UI → Settings → Quick Actions to set one."
                ))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Simple device actions
-- ---------------------------------------------------------------------------

function M.doWifiToggle(plugin)
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then
        UIManager:show(InfoMessage:new{
            text = _("WiFi not available on this device."), timeout = 2,
        })
        return
    end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then
        UIManager:show(InfoMessage:new{
            text = _("Network manager unavailable."), timeout = 2,
        })
        return
    end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
        UIManager:show(InfoMessage:new{ text = _("Wi-Fi off"), timeout = 1 })
    else
        Config.wifi_optimistic = true
        local ok_on, err = pcall(function() NetworkMgr:turnOnWifi() end)
        if not ok_on then
            logger.warn("simpleui: Wi-Fi turn-on error:", tostring(err))
            Config.wifi_optimistic = nil
        end
    end

    if plugin then
        plugin:_rebuildAllNavbars()
        local Topbar = require("topbar")
        local cfg    = require("config").getTopbarConfig()
        if (cfg.side["wifi"] or "hidden") ~= "hidden" then
            Topbar.scheduleRefresh(plugin, 0)
        end
    end

    local ok_d2, Desktop = pcall(require, "desktop")
    if ok_d2 and Desktop and Desktop._desktop_widget then
        pcall(function() Desktop:refresh() end)
    end
end

function M.refreshWifiIcon(plugin)
    Config.wifi_optimistic = nil
    local ok_d, Desktop = pcall(require, "desktop")
    if ok_d and Desktop and Desktop._desktop_widget then
        pcall(function() Desktop:refresh() end)
    end
    plugin:_rebuildAllNavbars()
    plugin:_refreshCurrentView()
end

function M.showFrontlightDialog()
    local ok_d, Dev = pcall(function() return require("device") end)
    if not ok_d or not Dev then return end
    local ok_f, has_fl = pcall(function() return Dev:hasFrontlight() end)
    if not ok_f or not has_fl then
        UIManager:show(InfoMessage:new{
            text = _("Frontlight not available on this device."), timeout = 2,
        })
        return
    end
    UIManager:show(require("ui/widget/frontlightwidget"):new{})
end

-- ---------------------------------------------------------------------------
-- Bar rebuild helpers
-- ---------------------------------------------------------------------------

function M.rebuildAllNavbars(plugin)
    local UI = require("ui")
    M.invalidateDimCache()
    local Topbar   = require("topbar")
    Topbar.invalidateDiskCache()
    local tabs     = Config.loadTabConfig()
    local num_tabs = Config.getNumTabs()
    local mode     = Config.getNavbarMode()
    local seen     = {}

    local function rebuildWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(plugin.active_action, tabs, num_tabs, mode), tabs)
        if G_reader_settings:nilOrTrue("navbar_topbar_enabled") then
            UI.replaceTopbar(w, Topbar.buildTopbarWidget())
        end
        plugin:_registerTouchZones(w)
        UIManager:setDirty(w._navbar_container, "ui")
        UIManager:setDirty(w, "ui")
    end

    rebuildWidget(plugin.ui)
    pcall(function() plugin:_updateFMHomeIcon() end)
    pcall(function()
        for __, entry in ipairs(UI.getWindowStack()) do rebuildWidget(entry.widget) end
    end)
end

function M.setPowerTabActive(plugin, active, prev_action)
    local tabs    = Config.loadTabConfig()
    local mode    = Config.getNavbarMode()
    local seen    = {}
    local show_id = active and "power"
        or (function()
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop and Desktop._desktop_widget then return "desktop" end
            return prev_action or tabs[1] or "home"
        end)()

    if not active then plugin.active_action = show_id end

    local function updateWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        M.replaceBar(w, M.buildBarWidget(show_id, tabs, nil, mode), tabs)
        UIManager:setDirty(w._navbar_container, "ui")
    end

    local UI = require("ui")
    updateWidget(plugin.ui)
    pcall(function()
        for __, entry in ipairs(UI.getWindowStack()) do updateWidget(entry.widget) end
    end)
end

function M.rewrapAllWidgets(plugin)
    local UI   = require("ui")
    local tabs = Config.loadTabConfig()
    local seen = {}

    local function rewrapWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        local inner = w._navbar_inner
        if not inner then return end
        local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
        local new_container, wrapped, bar, topbar, bar_idx, __, topbar_idx =
            UI.wrapWithNavbar(inner, plugin.active_action or tabs[1] or "home", tabs)
        w._navbar_container         = new_container
        w._navbar_bar               = bar
        w._navbar_topbar            = topbar
        w._navbar_topbar_idx        = topbar_idx
        w._navbar_tabs              = tabs
        w._navbar_bar_idx           = bar_idx
        w._navbar_bar_idx_topbar_on = topbar_on
        w._navbar_content_h         = UI.getContentHeight()
        w._navbar_topbar_h          = topbar_on and require("topbar").TOTAL_TOP_H() or 0
        w[1]                        = wrapped
        plugin:_registerTouchZones(w)
        UIManager:setDirty(w, "ui")
    end

    rewrapWidget(plugin.ui)
    pcall(function()
        for __, entry in ipairs(UI.getWindowStack()) do rewrapWidget(entry.widget) end
    end)
    M.rebuildAllNavbars(plugin)
end

function M.restoreTabInFM(plugin, tabs, prev_action)
    local fm = plugin.ui
    if not (fm and fm._navbar_container) then return end
    local should_skip = false
    local UI = require("ui")
    pcall(function()
        for __, entry in ipairs(UI.getWindowStack()) do
            if entry.widget and entry.widget._navbar_injected and entry.widget ~= fm then
                should_skip = true; return
            end
        end
    end)
    if should_skip then return end
    local t = tabs or Config.loadTabConfig()
    local Patches = require("patches")
    local restored = (fm.file_chooser and Patches._resolveTabForPath(fm.file_chooser.path, t))
                  or (t[1])
    plugin.active_action = restored
    M.replaceBar(fm, M.buildBarWidget(restored, t), t)
    UIManager:setDirty(fm._navbar_container, "ui")
end

-- ---------------------------------------------------------------------------
-- Power dialog
-- ---------------------------------------------------------------------------

function M.showPowerDialog(plugin, fm_self)
    local buttons     = {}
    local prev_action = plugin.active_action
    fm_self = fm_self or plugin.ui

    local function restoreBar()
        plugin:_setPowerTabActive(false, prev_action)
    end

    local function addBtn(text, cb)
        buttons[#buttons + 1] = {{ text = text, callback = cb }}
    end

    addBtn(_("Restart"), function()
        restoreBar(); UIManager:close(plugin._power_dialog)
        G_reader_settings:flush()
        local ok_exit, ExitCode = pcall(require, "exitcode")
        UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
    end)
    addBtn(_("Quit"), function()
        restoreBar(); UIManager:close(plugin._power_dialog)
        G_reader_settings:flush(); UIManager:quit(0)
    end)

    local ok_s, has_suspend = pcall(function() return Device:canSuspend() end)
    if ok_s and has_suspend then
        addBtn(_("Sleep"), function()
            restoreBar(); UIManager:close(plugin._power_dialog); Device:suspend()
        end)
    end
    local ok_p, has_power = pcall(function() return Device:canPowerOff() end)
    if ok_p and has_power then
        addBtn(_("Power off"), function()
            restoreBar(); UIManager:close(plugin._power_dialog); Device:powerOff()
        end)
    end
    local ok_r, has_reboot = pcall(function() return Device:canReboot() end)
    if ok_r and has_reboot then
        addBtn(_("Reboot the device"), function()
            restoreBar(); UIManager:close(plugin._power_dialog); Device:reboot()
        end)
    end
    addBtn(_("Cancel"), function()
        restoreBar(); UIManager:close(plugin._power_dialog)
    end)

    local ButtonDialog = require("ui/widget/buttondialog")
    plugin._power_dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(plugin._power_dialog)
end

return M
