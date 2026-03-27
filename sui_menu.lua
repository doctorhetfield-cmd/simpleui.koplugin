-- menu.lua — Simple UI
-- Builds the full settings submenu registered in the KOReader main menu
-- (Top Bar, Bottom Bar, Quick Actions, Pagination Bar).
-- Returns an installer: require("menu")(plugin) populates plugin.addToMainMenu.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _         = require("gettext")

-- Heavy UI widgets — lazy-loaded on first use so that require("menu") at boot
-- does not pull them into memory before the user ever opens the settings menu.
-- On low-memory devices these requires were the most likely point of silent
-- failure that caused the menu entry to open nothing.
local function InfoMessage()      return require("ui/widget/infomessage")      end
local function ConfirmBox()       return require("ui/widget/confirmbox")        end
local function MultiInputDialog() return require("ui/widget/multiinputdialog") end
local function PathChooser()      return require("ui/widget/pathchooser")       end
local function SortWidget()       return require("ui/widget/sortwidget")        end

local Config    = require("sui_config")
local UI        = require("sui_core")
local Bottombar = require("sui_bottombar")

-- ---------------------------------------------------------------------------
-- Installer function
-- ---------------------------------------------------------------------------

return function(SimpleUIPlugin)

SimpleUIPlugin.addToMainMenu = function(self, menu_items)
    local plugin = self

    -- Local aliases for Config functions.
    local loadTabConfig       = Config.loadTabConfig
    local saveTabConfig       = Config.saveTabConfig
    local getCustomQAList     = Config.getCustomQAList
    local saveCustomQAList    = Config.saveCustomQAList
    local getCustomQAConfig   = Config.getCustomQAConfig
    local saveCustomQAConfig  = Config.saveCustomQAConfig
    local deleteCustomQA      = Config.deleteCustomQA
    local nextCustomQAId      = Config.nextCustomQAId
    local getTopbarConfig     = Config.getTopbarConfig
    local saveTopbarConfig    = Config.saveTopbarConfig
    local _ensureHomePresent  = Config._ensureHomePresent
    local _sanitizeLabel      = Config.sanitizeLabel
    local _homeLabel          = Config.homeLabel
    local _getNonFavoritesCollections = Config.getNonFavoritesCollections
    local ALL_ACTIONS         = Config.ALL_ACTIONS
    local ACTION_BY_ID        = Config.ACTION_BY_ID
    local TOPBAR_ITEMS        = Config.TOPBAR_ITEMS
    local TOPBAR_ITEM_LABEL   = Config.TOPBAR_ITEM_LABEL
    local MAX_CUSTOM_QA       = Config.MAX_CUSTOM_QA
    local CUSTOM_ICON         = Config.CUSTOM_ICON
    local CUSTOM_PLUGIN_ICON  = Config.CUSTOM_PLUGIN_ICON
    local CUSTOM_DISPATCHER_ICON = Config.CUSTOM_DISPATCHER_ICON
    local TOTAL_H             = Bottombar.TOTAL_H
    local MAX_LABEL_LEN       = Config.MAX_LABEL_LEN

    -- Hardware capability — evaluated once per menu session, not per item render.
    -- All pool builders (tabs, position, QA) share this single check so that
    -- "Brightness" appears consistently in every pool on devices that have a
    -- frontlight, and is absent on those that don't.
    local _has_fl = nil
    local function hasFrontlight()
        if _has_fl == nil then
            local ok, v = pcall(function() return Device:hasFrontlight() end)
            _has_fl = ok and v == true
        end
        return _has_fl
    end

    -- Returns true when the given action id should be shown in menus on this device.
    -- Currently only "frontlight" is hardware-gated; all other ids are always shown.
    local function actionAvailable(id)
        if id == "frontlight" then return hasFrontlight() end
        return true
    end

    -- -----------------------------------------------------------------------
    -- Mode radio-item helper
    -- -----------------------------------------------------------------------

    local function modeItem(label, mode_value)
        return {
            text           = label,
            radio          = true,
            keep_menu_open = true,
            checked_func   = function() return Config.getNavbarMode() == mode_value end,
            callback       = function()
                Config.saveNavbarMode(mode_value)
                plugin:_scheduleRebuild()
            end,
        }
    end

    local function makeTypeMenu()
        return {
            modeItem(_("Icons") .. " + " .. _("Text"), "both"),
            modeItem(_("Icons only"),                   "icons"),
            modeItem(_("Text only"),                    "text"),
        }
    end

    -- -----------------------------------------------------------------------
    -- Tab and position menu builders
    -- -----------------------------------------------------------------------

    local function makePositionMenu(pos)
        local items        = {}
        local cached_tabs
        local cached_labels = {}

        local function getTabs()
            if not cached_tabs then cached_tabs = loadTabConfig() end
            return cached_tabs
        end

        local function getResolvedLabel(id)
            if not cached_labels[id] then
                if id:match("^custom_qa_%d+$") then
                    cached_labels[id] = getCustomQAConfig(id).label
                elseif id == "home" then
                    cached_labels[id] = _homeLabel()
                else
                    cached_labels[id] = (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
                end
            end
            return cached_labels[id]
        end

        local pool = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then pool[#pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do pool[#pool + 1] = qa_id end

        for _i, id in ipairs(pool) do
            local _id = id
            items[#items + 1] = {
                text_func    = function()
                    local lbl  = getResolvedLabel(_id)
                    local tabs = getTabs()
                    for i, tid in ipairs(tabs) do
                        if tid == _id and i ~= pos then
                            return lbl .. "  (#" .. i .. ")"
                        end
                    end
                    return lbl
                end,
                checked_func = function() return getTabs()[pos] == _id end,
                keep_menu_open = true,
                callback     = function()
                    local tabs    = loadTabConfig()
                    cached_tabs   = nil
                    cached_labels = {}
                    local old_id  = tabs[pos]
                    if old_id == _id then return end
                    tabs[pos] = _id
                    for i, tid in ipairs(tabs) do
                        if i ~= pos and tid == _id then tabs[i] = old_id; break end
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        -- Pre-compute sort keys once so text_func is not called O(N log N) times
        -- during the sort comparison (#13).
        for _i, item in ipairs(items) do
            local t = item.text_func()
            item._sort_key = (t:match("^(.-)%s+%(#") or t):lower()
        end
        table.sort(items, function(a, b) return a._sort_key < b._sort_key end)
        for _i, item in ipairs(items) do item._sort_key = nil end
        return items
    end

    local function getActionLabel(id)
        if not id then return "?" end
        if id:match("^custom_qa_%d+$") then return getCustomQAConfig(id).label end
        if id == "home" then return _homeLabel() end
        return (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
    end

    local function makeTabsMenu()
        local items = {}

        items[#items + 1] = {
            text           = _("Arrange tabs"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local tabs       = loadTabConfig()
                local sort_items = {}
                for _i, tid in ipairs(tabs) do
                    sort_items[#sort_items + 1] = { text = getActionLabel(tid), orig_item = tid }
                end
                local sort_widget = SortWidget():new{
                    title             = _("Arrange tabs"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local new_tabs = {}
                        for _i, item in ipairs(sort_items) do new_tabs[#new_tabs + 1] = item.orig_item end
                        _ensureHomePresent(new_tabs)
                        saveTabConfig(new_tabs)
                        plugin:_scheduleRebuild()
                    end,
                }
                UIManager:show(sort_widget)
            end,
        }

        local toggle_items = {}
        local action_pool  = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end

        for _i, aid in ipairs(action_pool) do
            local _aid = aid
            local _base_label = getActionLabel(_aid)
            toggle_items[#toggle_items + 1] = {
                _base        = _base_label,
                text_func    = function()
                    local limit = Config.effectiveMaxTabs()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return _base_label end
                    end
                    local rem = limit - #loadTabConfig()
                    if rem <= 0 then return _base_label .. "  (0 left)" end
                    if rem <= 2 then return _base_label .. "  (" .. rem .. " left)" end
                    return _base_label
                end,
                checked_func = function()
                    for _i, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return true end
                    end
                    return false
                end,
                radio          = false,
                keep_menu_open = true,
                callback = function()
                    local tabs       = loadTabConfig()
                    local limit      = Config.effectiveMaxTabs()
                    local min_tabs   = Config.isNavpagerEnabled() and 1 or 2
                    local active_pos = nil
                    for i, tid in ipairs(tabs) do
                        if tid == _aid then active_pos = i; break end
                    end
                    if active_pos then
                        if #tabs <= min_tabs then
                            UIManager:show(InfoMessage():new{
                                text = Config.isNavpagerEnabled()
                                    and _("Minimum 1 tab required in navpager mode.")
                                    or  _("Minimum 2 tabs required. Select another tab first."),
                                timeout = 2,
                            })
                            return
                        end
                        table.remove(tabs, active_pos)
                    else
                        if #tabs >= limit then
                            UIManager:show(InfoMessage():new{
                                text = string.format(_("Maximum %d tabs reached. Remove one first."), limit), timeout = 2,
                            })
                            return
                        end
                        tabs[#tabs + 1] = _aid
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        table.sort(toggle_items, function(a, b) return a._base:lower() < b._base:lower() end)
        for _i, item in ipairs(toggle_items) do items[#items + 1] = item end
        return items
    end

    -- -----------------------------------------------------------------------
    -- Pagination bar menu builder
    -- -----------------------------------------------------------------------

    local function makePaginationBarMenu()
        return {
            -- ── Default (was "Pagination Bar On/Off") ──────────────────────
            {
                text_func    = function()
                    local state = G_reader_settings:nilOrTrue("navbar_pagination_visible") and _("On") or _("Off")
                    return _("Default") .. " — " .. state
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_pagination_visible") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_pagination_visible")
                    G_reader_settings:saveSetting("navbar_pagination_visible", not on)
                    -- Mutual exclusion: enabling Default disables Navpager.
                    if not on then
                        G_reader_settings:saveSetting("navbar_navpager_enabled", false)
                    end
                    local state_text = on and _("hidden") or _("visible")
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Pagination bar will be %s after restart.\n\nRestart now?"), state_text),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
            -- ── Size (indented, only active when Default is on) ─────────────
            {
                text           = _("    Size"),
                enabled_func   = function() return G_reader_settings:nilOrTrue("navbar_pagination_visible") end,
                sub_item_table = (function()
                    local sizes = {
                        { label = _("Extra Small"), key = "xs" },
                        { label = _("Small"),       key = "s"  },
                        { label = _("Default"),     key = "m"  },
                    }
                    local items = {}
                    for _i, s in ipairs(sizes) do
                        local key = s.key
                        items[#items + 1] = {
                            text         = s.label,
                            checked_func = function()
                                return (G_reader_settings:readSetting("navbar_pagination_size") or "s") == key
                            end,
                            callback     = function()
                                G_reader_settings:saveSetting("navbar_pagination_size", key)
                                UIManager:show(ConfirmBox():new{
                                    text = _("Pagination bar size will change after restart.\n\nRestart now?"),
                                    ok_text = _("Restart"), cancel_text = _("Later"),
                                    ok_callback = function()
                                        G_reader_settings:flush()
                                        UIManager:restartKOReader()
                                    end,
                                })
                            end,
                        }
                    end
                    return items
                end)(),
            },
            -- ── Page number in title bar (disabled when navpager is on) ─────
            {
                text_func    = function()
                    local on = G_reader_settings:isTrue("navbar_pagination_show_subtitle")
                    return _("Page number in title bar") .. " — " .. (on and _("On") or _("Off"))
                end,
                checked_func = function()
                    return G_reader_settings:isTrue("navbar_pagination_show_subtitle")
                end,
                enabled_func = function()
                    return not Config.isNavpagerEnabled()
                end,
                help_text    = _("Shows \"Page X of Y\" in the title bar subtitle when browsing the library, history or collections.\nNavpager enables this automatically.\nNot available when Navpager is active."),
                callback     = function()
                    local on = G_reader_settings:isTrue("navbar_pagination_show_subtitle")
                    G_reader_settings:saveSetting("navbar_pagination_show_subtitle", not on)
                    plugin:_scheduleRebuild()
                end,
            },
            -- ── Navpager ────────────────────────────────────────────────────
            {
                text_func    = function()
                    local state = G_reader_settings:isTrue("navbar_navpager_enabled") and _("On") or _("Off")
                    return _("Navpager") .. " — " .. state
                end,
                checked_func = function() return G_reader_settings:isTrue("navbar_navpager_enabled") end,
                help_text    = _("Replaces the pagination bar with Prev/Next arrows at the edges of the bottom bar.\nThe arrows dim when there is no previous or next page.\nWith navpager active, as few as 1 tab and at most 4 tabs can be configured."),
                callback     = function()
                    local on = G_reader_settings:isTrue("navbar_navpager_enabled")
                    G_reader_settings:saveSetting("navbar_navpager_enabled", not on)
                    -- When enabling navpager, hide the old pagination bar
                    -- (the two features are mutually exclusive).
                    if not on then
                        G_reader_settings:saveSetting("navbar_pagination_visible", false)
                        -- Trim tabs to navpager limit if needed.
                        local tabs = Config.loadTabConfig()
                        if #tabs > Config.MAX_TABS_NAVPAGER then
                            while #tabs > Config.MAX_TABS_NAVPAGER do
                                table.remove(tabs, #tabs)
                            end
                            Config.saveTabConfig(tabs)
                        end
                    end
                    local state_text = on and _("disabled") or _("enabled")
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Navpager will be %s after restart.\n\nRestart now?"), state_text),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },

        }
    end

    -- -----------------------------------------------------------------------
    -- Topbar menu builders
    -- -----------------------------------------------------------------------

    local function makeTopbarItemsMenu()
        local items = {}
        items[#items + 1] = {
            text           = _("Swipe Indicator"),
            keep_menu_open = true,
            checked_func   = function() return G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator") end,
            callback = function()
                G_reader_settings:saveSetting("navbar_topbar_swipe_indicator",
                    not G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator"))
                plugin:_scheduleRebuild()
            end,
            separator = true,
        }

        local sorted_keys = {}
        for _i, k in ipairs(TOPBAR_ITEMS) do sorted_keys[#sorted_keys + 1] = k end
        table.sort(sorted_keys, function(a, b) return TOPBAR_ITEM_LABEL(a):lower() < TOPBAR_ITEM_LABEL(b):lower() end)

        for _i, key in ipairs(sorted_keys) do
            local k = key
            items[#items + 1] = {
                text_func    = function()
                    local side = Config.getTopbarConfigCached().side[k] or "hidden"
                    local label = TOPBAR_ITEM_LABEL(k)
                    if side == "left"   then return label .. "  ◂"
                    elseif side == "center" then return label .. "  ◆"
                    elseif side == "right"  then return label .. "  ▸"
                    else return label end
                end,
                -- Uses the cached config so opening the menu doesn't rebuild
                -- the config table once per item (#16).
                checked_func = function()
                    return (Config.getTopbarConfigCached().side[k] or "hidden") ~= "hidden"
                end,
                keep_menu_open = true,
                callback = function()
                    -- Reads fresh config for the mutation, then invalidates cache.
                    local cfg = getTopbarConfig()
                    if not cfg.order_center then cfg.order_center = {} end
                    if (cfg.side[k] or "hidden") == "hidden" then
                        -- Restore to the last known slot, checking all three lists.
                        local last_side = "right"
                        for _i, v in ipairs(cfg.order_left)   do if v == k then last_side = "left";   break end end
                        for _i, v in ipairs(cfg.order_center) do if v == k then last_side = "center"; break end end
                        cfg.side[k] = last_side
                        if last_side == "left" then
                            local found = false
                            for _i, v in ipairs(cfg.order_left) do if v == k then found = true; break end end
                            if not found then cfg.order_left[#cfg.order_left + 1] = k end
                        elseif last_side == "center" then
                            local found = false
                            for _i, v in ipairs(cfg.order_center) do if v == k then found = true; break end end
                            if not found then cfg.order_center[#cfg.order_center + 1] = k end
                        else
                            local found = false
                            for _i, v in ipairs(cfg.order_right) do if v == k then found = true; break end end
                            if not found then cfg.order_right[#cfg.order_right + 1] = k end
                        end
                    else
                        cfg.side[k] = "hidden"
                    end
                    saveTopbarConfig(cfg)   -- also calls Config.invalidateTopbarConfigCache()
                    plugin:_scheduleRebuild()
                end,
            }
        end
        if #items > 0 then items[#items].separator = true end

        items[#items + 1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            callback       = function()
                local cfg        = getTopbarConfig()
                if not cfg.order_center then cfg.order_center = {} end
                local SEP_LEFT   = "__sep_left__"
                local SEP_CENTER = "__sep_center__"
                local SEP_RIGHT  = "__sep_right__"
                local sort_items = {}
                sort_items[#sort_items + 1] = { text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true }
                for _i, key in ipairs(cfg.order_left) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Center") .. " ──", orig_item = SEP_CENTER, dim = true }
                for _i, key in ipairs(cfg.order_center) do
                    if cfg.side[key] == "center" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true }
                for _i, key in ipairs(cfg.order_right) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                UIManager:show(SortWidget():new{
                    title             = _("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local sep_left_pos, sep_center_pos, sep_right_pos
                        for j, item in ipairs(sort_items) do
                            if item.orig_item == SEP_LEFT   then sep_left_pos   = j end
                            if item.orig_item == SEP_CENTER then sep_center_pos = j end
                            if item.orig_item == SEP_RIGHT  then sep_right_pos  = j end
                        end
                        if not sep_left_pos or not sep_center_pos or not sep_right_pos
                                or sep_left_pos > sep_center_pos or sep_center_pos > sep_right_pos
                                or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                            UIManager:show(InfoMessage():new{
                                text    = _("Invalid arrangement.\nKeep the Left, Center and Right separators in order."),
                                timeout = 3,
                            })
                            return
                        end
                        local new_left, new_center, new_right = {}, {}, {}
                        local current_side = nil
                        for _i, item in ipairs(sort_items) do
                            if     item.orig_item == SEP_LEFT   then current_side = "left"
                            elseif item.orig_item == SEP_CENTER then current_side = "center"
                            elseif item.orig_item == SEP_RIGHT  then current_side = "right"
                            elseif current_side == "left"   then new_left[#new_left + 1]     = item.orig_item; cfg.side[item.orig_item] = "left"
                            elseif current_side == "center" then new_center[#new_center + 1] = item.orig_item; cfg.side[item.orig_item] = "center"
                            elseif current_side == "right"  then new_right[#new_right + 1]   = item.orig_item; cfg.side[item.orig_item] = "right"
                            end
                        end
                        -- Keep hidden items at the tail of each list so they can be restored later.
                        for _i, key in ipairs(cfg.order_left)   do if cfg.side[key] == "hidden" then new_left[#new_left + 1]     = key end end
                        for _i, key in ipairs(cfg.order_center) do if cfg.side[key] == "hidden" then new_center[#new_center + 1] = key end end
                        for _i, key in ipairs(cfg.order_right)  do if cfg.side[key] == "hidden" then new_right[#new_right + 1]   = key end end
                        cfg.order_left   = new_left
                        cfg.order_center = new_center
                        cfg.order_right  = new_right
                        saveTopbarConfig(cfg)
                        plugin:_scheduleRebuild()
                    end,
                })
            end,
        }
        return items
    end

    local function makeTopbarMenu()
        return {
            {
                text_func    = function()
                    return _("Top Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_topbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_topbar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                    G_reader_settings:saveSetting("navbar_topbar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Top Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return _("Size")
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Top Bar Size"),
                        info_text     = _("Height of the top status bar.\n100% is the default size."),
                        value         = Config.getTopbarSizePct(),
                        value_min     = Config.TOPBAR_SIZE_MIN,
                        value_max     = Config.TOPBAR_SIZE_MAX,
                        value_step    = Config.TOPBAR_SIZE_STEP,
                        unit          = "%",
                        ok_text       = _("Apply"),
                        cancel_text   = _("Cancel"),
                        default_value = Config.TOPBAR_SIZE_DEF,
                        callback      = function(spin)
                            Config.setTopbarSizePct(spin.value)
                            UI.invalidateDimCache()
                            plugin:_rewrapAllWidgets()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                        end,
                    })
                end,
            },
            { text = _("Items"), sub_item_table_func = makeTopbarItemsMenu },
        }
    end

    -- -----------------------------------------------------------------------
    -- Bottom bar menu builder
    -- -----------------------------------------------------------------------

    local function makeNavbarMenu()
        return {
            {
                text_func    = function()
                    return _("Bottom Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_enabled") end,
                keep_menu_open = true,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_enabled")
                    G_reader_settings:saveSetting("navbar_enabled", not on)
                    UIManager:show(ConfirmBox():new{
                        text = string.format(_("Bottom Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text_func = function()
                    return _("Size")
                end,
                keep_menu_open = true,
                callback = function()
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text    = _("Bottom Bar Size"),
                        info_text     = _("Height of the bottom navigation bar.\n100% is the default size."),
                        value         = Config.getBarSizePct(),
                        value_min     = Config.BAR_SIZE_MIN,
                        value_max     = Config.BAR_SIZE_MAX,
                        value_step    = Config.BAR_SIZE_STEP,
                        unit          = "%",
                        ok_text       = _("Apply"),
                        cancel_text   = _("Cancel"),
                        default_value = Config.BAR_SIZE_DEF,
                        callback      = function(spin)
                            Config.setBarSizePct(spin.value)
                            UI.invalidateDimCache()
                            plugin:_rewrapAllWidgets()
                            local ok_hs, HS = pcall(require, "sui_homescreen")
                            if ok_hs and HS then HS.refresh(true) end
                        end,
                    })
                end,
            },
            Config.makeScaleItem({
                text_func     = function()
                    local pct = Config.getBottomMarginPct()
                    return pct == Config.BOT_MARGIN_DEF
                        and _("Bottom Margin")
                        or  string.format(_("Bottom Margin — %d%%"), pct)
                end,
                title         = _("Bottom Margin"),
                info          = _("Space below the bottom navigation bar.\n100% is the default spacing."),
                get           = function() return Config.getBottomMarginPct() end,
                set           = function(pct) Config.setBottomMarginPct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rewrapAllWidgets()
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
                value_min     = Config.BOT_MARGIN_MIN,
                value_max     = Config.BOT_MARGIN_MAX,
                value_step    = Config.BOT_MARGIN_STEP,
                default_value = Config.BOT_MARGIN_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function()
                    local pct = Config.getIconScalePct()
                    return pct == Config.ICON_SCALE_DEF
                        and _("Icon Size")
                        or  string.format(_("Icon Size — %d%%"), pct)
                end,
                title         = _("Icon Size"),
                info          = _("Size of the tab icons.\n100% is the default size."),
                get           = function() return Config.getIconScalePct() end,
                set           = function(pct) Config.setIconScalePct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rebuildAllNavbars()
                end,
                value_min     = Config.ICON_SCALE_MIN,
                value_max     = Config.ICON_SCALE_MAX,
                value_step    = Config.ICON_SCALE_STEP,
                default_value = Config.ICON_SCALE_DEF,
            }),
            Config.makeScaleItem({
                text_func     = function()
                    local pct = Config.getLabelScalePct()
                    return pct == Config.LABEL_SCALE_DEF
                        and _("Label Size")
                        or  string.format(_("Label Size — %d%%"), pct)
                end,
                title         = _("Label Size"),
                info          = _("Size of the tab label text.\n100% is the default size."),
                get           = function() return Config.getLabelScalePct() end,
                set           = function(pct) Config.setLabelScalePct(pct) end,
                refresh       = function()
                    UI.invalidateDimCache()
                    plugin:_rebuildAllNavbars()
                end,
                value_min     = Config.LABEL_SCALE_MIN,
                value_max     = Config.LABEL_SCALE_MAX,
                value_step    = Config.LABEL_SCALE_STEP,
                default_value = Config.LABEL_SCALE_DEF,
            }),
            {
                text_func    = function()
                    return _("Top separator") .. " — " .. (G_reader_settings:isTrue("navbar_hide_separator") and _("Hidden") or _("Visible"))
                end,
                checked_func = function() return not G_reader_settings:isTrue("navbar_hide_separator") end,
                keep_menu_open = true,
                callback     = function()
                    local hidden = G_reader_settings:isTrue("navbar_hide_separator")
                    G_reader_settings:saveSetting("navbar_hide_separator", not hidden)
                    plugin:_rebuildAllNavbars()
                    local ok_hs, HS = pcall(require, "sui_homescreen")
                    if ok_hs and HS then HS.refresh(true) end
                end,
            },
            {
                text = _("Type"),
                sub_item_table_func = makeTypeMenu,
            },
            {
                text_func = function()
                    local n     = #loadTabConfig()
                    local limit = Config.effectiveMaxTabs()
                    local remaining = limit - n
                    if remaining <= 0 then
                        return string.format(_("Tabs  (%d/%d — at limit)"), n, limit)
                    end
                    return string.format(_("Tabs  (%d/%d — %d left)"), n, limit, remaining)
                end,
                sub_item_table_func = makeTabsMenu,
            },
        }
    end

    plugin._makeNavbarMenu = makeNavbarMenu
    plugin._makeTopbarMenu = makeTopbarMenu

    -- -----------------------------------------------------------------------
    -- Title Bar menu builder
    -- -----------------------------------------------------------------------

    -- Resolves the live FM + window stack and re-applies (or restores) all
    -- titlebar state. Called by every toggle in this submenu.
    local function _reapplyAllTitlebars()
        local Titlebar = require("sui_titlebar")
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        local stack = require("sui_core").getWindowStack()
        Titlebar.reapplyAll(fm, stack)
        if fm then UIManager:setDirty(fm[1], "ui") end
    end

    -- Builds a visibility toggle list for one context ("fm" or "inj").
    local function makeTitleBarItemsForCtx(ctx)
        local Titlebar = require("sui_titlebar")
        local items = {}
        for _i, item in ipairs(Titlebar.ITEMS) do
            if item.ctx == ctx then
                local item_id    = item.id
                local item_label = item.label
                items[#items + 1] = {
                    text_func = function()
                        local state = Titlebar.isItemVisible(item_id) and _("On") or _("Off")
                        return item_label() .. " — " .. state
                    end,
                    checked_func   = function() return Titlebar.isItemVisible(item_id) end,
                    enabled_func   = function() return Titlebar.isEnabled() end,
                    keep_menu_open = true,
                    callback       = function()
                        Titlebar.setItemVisible(item_id, not Titlebar.isItemVisible(item_id))
                        _reapplyAllTitlebars()
                    end,
                }
            end
        end
        return items
    end

    -- Builds an arrange-items menu for one context.
    -- cfg_getter / cfg_saver — functions that load/save the side config.
    -- ctx — "fm" or "inj", used to filter M.ITEMS.
    local function makeTitleBarArrangeMenu(ctx, cfg_getter, cfg_saver)
        local Titlebar   = require("sui_titlebar")
        local SEP_LEFT   = "__sep_left__"
        local SEP_RIGHT  = "__sep_right__"

        -- Build label lookup for this context.
        local labels = {}
        for _i, item in ipairs(Titlebar.ITEMS) do
            if item.ctx == ctx and not item.no_side then
                labels[item.id] = item.label
            end
        end

        local cfg        = cfg_getter()
        local sort_items = {}

        sort_items[#sort_items + 1] = {
            text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true,
        }
        for _i, id in ipairs(cfg.order_left) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end
        sort_items[#sort_items + 1] = {
            text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true,
        }
        for _i, id in ipairs(cfg.order_right) do
            if labels[id] then
                sort_items[#sort_items + 1] = { text = labels[id](), orig_item = id }
            end
        end

        UIManager:show(SortWidget():new{
            title             = _("Arrange Buttons"),
            item_table        = sort_items,
            covers_fullscreen = true,
            callback          = function()
                -- Validate: separators must be in correct relative order.
                local sep_l, sep_r
                for j, item in ipairs(sort_items) do
                    if item.orig_item == SEP_LEFT  then sep_l = j end
                    if item.orig_item == SEP_RIGHT then sep_r = j end
                end
                if not sep_l or not sep_r or sep_l > sep_r
                        or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                    UIManager:show(InfoMessage():new{
                        text    = _("Invalid arrangement.\nKeep items between the Left and Right separators."),
                        timeout = 3,
                    })
                    return
                end
                local new_left, new_right = {}, {}
                local current_side = nil
                for _i, item in ipairs(sort_items) do
                    if     item.orig_item == SEP_LEFT  then current_side = "left"
                    elseif item.orig_item == SEP_RIGHT then current_side = "right"
                    elseif current_side == "left"  then
                        new_left[#new_left + 1]    = item.orig_item
                        cfg.side[item.orig_item]   = "left"
                    elseif current_side == "right" then
                        new_right[#new_right + 1]  = item.orig_item
                        cfg.side[item.orig_item]   = "right"
                    end
                end
                -- Preserve hidden items at the end of each order list.
                for _i, id in ipairs(cfg.order_left)  do
                    if cfg.side[id] == "hidden" then new_left[#new_left + 1]   = id end
                end
                for _i, id in ipairs(cfg.order_right) do
                    if cfg.side[id] == "hidden" then new_right[#new_right + 1] = id end
                end
                cfg.order_left  = new_left
                cfg.order_right = new_right
                cfg_saver(cfg)
                _reapplyAllTitlebars()
            end,
        })
    end

    local function makeTitleBarFMMenu()
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("fm")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu("fm", Titlebar.getFMConfig, Titlebar.saveFMConfig)
            end,
        }
        return items
    end

    local function makeTitleBarInjMenu()
        local Titlebar = require("sui_titlebar")
        local items = makeTitleBarItemsForCtx("inj")
        if #items > 0 then items[#items].separator = true end
        items[#items + 1] = {
            text           = _("Arrange Buttons"),
            enabled_func   = function() return Titlebar.isEnabled() end,
            keep_menu_open = true,
            callback       = function()
                makeTitleBarArrangeMenu("inj", Titlebar.getInjConfig, Titlebar.saveInjConfig)
            end,
        }
        return items
    end

    local function makeTitleBarMenu()
        local function sizeItem(label, key)
            return {
                text         = label,
                radio        = true,
                keep_menu_open = true,
                checked_func = function() return require("sui_titlebar").getSizeKey() == key end,
                callback     = function()
                    require("sui_titlebar").setSizeKey(key)
                    _reapplyAllTitlebars()
                end,
            }
        end
        return {
            {
                text_func    = function()
                    local on = require("sui_titlebar").isEnabled()
                    return _("Custom Title Bar") .. " — " .. (on and _("On") or _("Off"))
                end,
                checked_func = function() return require("sui_titlebar").isEnabled() end,
                separator    = true,
                callback     = function()
                    local Titlebar = require("sui_titlebar")
                    local on = Titlebar.isEnabled()
                    Titlebar.setEnabled(not on)
                    G_reader_settings:flush()
                    UIManager:show(ConfirmBox():new{
                        text = string.format(
                            _("Custom Title Bar will be %s after restart.\n\nRestart now?"),
                            on and _("disabled") or _("enabled")
                        ),
                        ok_text     = _("Restart"),
                        cancel_text = _("Later"),
                        ok_callback = function()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
            },
            {
                text      = _("Button Size"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                separator = true,
                sub_item_table = {
                    sizeItem(_("Compact"), "compact"),
                    sizeItem(_("Default"), "default"),
                    sizeItem(_("Large"),   "large"),
                },
            },
            {
                text         = _("Library Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = makeTitleBarFMMenu,
            },
            {
                text         = _("Sub-pages Buttons"),
                enabled_func = function() return require("sui_titlebar").isEnabled() end,
                sub_item_table_func = makeTitleBarInjMenu,
            },
        }
    end

    plugin._makeTitleBarMenu = makeTitleBarMenu

    -- -----------------------------------------------------------------------
    -- Quick Actions
    -- -----------------------------------------------------------------------

    -- Quick Actions — delegated to sui_quickactions.lua
    local QA = require("sui_quickactions")
    local function makeQuickActionsMenu()
        return QA.makeMenuItems(plugin)
    end
    plugin._makeQuickActionsMenu = makeQuickActionsMenu

    local function refreshHomescreen()
        -- Rebuild the widget tree immediately (synchronous) with keep_cache=false
        -- so that book modules (Currently Reading, Recent Books) re-prefetch their
        -- data. Using keep_cache=true would reuse _cached_books_state which was
        -- built before those modules were enabled (with current_fp=nil, recent_fps={})
        -- causing the newly-enabled modules to render empty until the next full open.
        -- Collections and other modules have no per-instance cache so this is a
        -- no-op cost for them.
        --
        -- We also schedule a setDirty via UIManager:nextTick to guarantee a repaint
        -- AFTER the menu widget is removed from the stack. Any setDirty fired while
        -- the menu is open is painted behind it; when the menu closes the UIManager
        -- only repaints the menu frame region, not the full HS. nextTick runs after
        -- the current event's onCloseWidget teardown, so the HS is the top widget
        -- by the time the dirty is processed.
        local HS = package.loaded["sui_homescreen"]
        if not (HS and HS._instance) then return end
        local hs = HS._instance
        hs:_refreshImmediate(false)
        UIManager:nextTick(function()
            if HS._instance == hs and hs._navbar_container then
                UIManager:setDirty(hs, "ui")
            end
        end)
    end

    -- _goalTapCallback: shown when the user taps the Reading Goals widget on
    -- the Homescreen. Lets them set annual/physical goals.
    self._goalTapCallback = function()
        local goal     = G_reader_settings:readSetting("navbar_reading_goal") or 0
        local physical = G_reader_settings:readSetting("navbar_reading_goal_physical") or 0
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{ title = _("Annual Reading Goal"), buttons = {
            {{ text = goal > 0 and string.format(_("Digital: %d books in %s"), goal, os.date("%Y")) or string.format(_("Digital Goal  (%s)"), os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshHomescreen() end) end
               end }},
            {{ text = string.format(_("Physical: %d books in %s"), physical, os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualPhysicalDialog(function() refreshHomescreen() end) end
               end }},
        }}
        UIManager:show(dlg)
    end

    -- -----------------------------------------------------------------------
    -- Shared parametric helpers
    -- All menu-building functions below accept a `ctx` table:
    --   ctx.pfx       — settings key prefix, e.g. "navbar_homescreen_"
    --   ctx.pfx_qa    — QA settings prefix, e.g. "navbar_homescreen_quick_actions_"
    --   ctx.refresh   — zero-arg function to refresh the page after a change
    -- -----------------------------------------------------------------------

    local MAX_QA_ITEMS = 6  -- max actions per QA slot (used by makeQAMenu)

    local HOMESCREEN_CTX = {
        pfx     = "navbar_homescreen_",
        pfx_qa  = "navbar_homescreen_quick_actions_",
        refresh = refreshHomescreen,
    }

    local Registry = require("desktop_modules/moduleregistry")

    -- Returns number of active modules for a given ctx.
    local function countModules(ctx)
        return Registry.countEnabled(ctx.pfx)
    end

    -- getQAPool — builds the list of available actions for Quick Actions menus.
    -- Must be declared before makeQAMenu/makeModulesMenu which use it.
    local function getQAPool()
        local available = {}
        for _i, a in ipairs(ALL_ACTIONS) do
            if actionAvailable(a.id) then
                available[#available+1] = { id = a.id, label = a.id == "home" and Config.homeLabel() or a.label }
            end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do
            local _qid = qa_id
            available[#available+1] = { id = _qid, label = getCustomQAConfig(_qid).label }
        end
        return available
    end

    -- Builds the QA slot sub-menu for a given ctx and slot number.
    local function makeQAMenu(ctx, slot_n)
        local items_key  = ctx.pfx_qa .. slot_n .. "_items"
        local labels_key = ctx.pfx_qa .. slot_n .. "_labels"
        local slot_label = string.format(_("Quick Actions %d"), slot_n)
        local function getItems() return G_reader_settings:readSetting(items_key) or {} end
        local function isSelected(id)
            for _i, v in ipairs(getItems()) do if v == id then return true end end
            return false
        end
        local function toggleItem(id)
            local items = getItems(); local new_items = {}; local found = false
            for _i, v in ipairs(items) do if v == id then found = true else new_items[#new_items+1] = v end end
            if not found then
                if #items >= MAX_QA_ITEMS then
                    UIManager:show(InfoMessage():new{ text = string.format(_("Maximum %d actions per module reached. Remove one first."), MAX_QA_ITEMS), timeout = 2 })
                    return
                end
                new_items[#new_items+1] = id
            end
            G_reader_settings:saveSetting(items_key, new_items); ctx.refresh()
        end
        local items_sub = {}
        local sorted_pool = {}
        for _i, a in ipairs(getQAPool()) do sorted_pool[#sorted_pool+1] = a end
        table.sort(sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)
        items_sub[#items_sub+1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            separator      = true,
            enabled_func   = function() return #getItems() >= 2 end,
            callback       = function()
              local qa_ids = getItems()
              if #qa_ids < 2 then UIManager:show(InfoMessage():new{ text = _("Add at least 2 actions to arrange."), timeout = 2 }); return end
              local pool_labels = {}; for _i, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
              local sort_items = {}
              for _i, id in ipairs(qa_ids) do sort_items[#sort_items+1] = { text = pool_labels[id] or id, orig_item = id } end
              UIManager:show(SortWidget():new{ title = string.format(_("Arrange %s"), slot_label), covers_fullscreen = true, item_table = sort_items,
                  callback = function()
                      local new_order = {}; for _i, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                      G_reader_settings:saveSetting(items_key, new_order); ctx.refresh()
                  end })
          end,
        }
        for _i, a in ipairs(sorted_pool) do
            local aid = a.id; local _lbl = a.label
            items_sub[#items_sub+1] = {
                text_func = function()
                    if isSelected(aid) then return _lbl end
                    local rem = MAX_QA_ITEMS - #getItems()
                    if rem <= 0 then return _lbl .. "  (0 left)" end
                    if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                    return _lbl
                end,
                checked_func   = function() return isSelected(aid) end,
                keep_menu_open = true,
                callback       = function() toggleItem(aid) end,
            }
        end
        return {
            {
                text           = _("Hide Text"),
                checked_func   = function() return not G_reader_settings:nilOrTrue(labels_key) end,
                keep_menu_open = true,
                separator      = true,
                callback       = function()
                    G_reader_settings:saveSetting(labels_key, not G_reader_settings:nilOrTrue(labels_key))
                    ctx.refresh()
                end,
            },
            {
                text                = _("Items"),
                sub_item_table_func = function() return items_sub end,
            },
        }
    end

    -- Builds the full "Modules" sub-menu for a given ctx.
    -- Fully registry-driven: no module ids hardcoded here.
    local function makeModulesMenu(ctx)
        local MAX_MOD      = 3
        local NO_LIMIT_KEY = "navbar_homescreen_no_module_limit"

        local function isUnlimited()
            return G_reader_settings:readSetting(NO_LIMIT_KEY) == true
        end

        local function maxMsg()
            UIManager:show(InfoMessage():new{
                text = string.format(_("Maximum %d modules active. Disable one first."), MAX_MOD), timeout = 2 })
        end

        -- ctx_menu passed to each module's getMenuItems()
        -- InfoMessage and SortWidget are resolved lazily on first access via
        -- __index so that require("ui/widget/...") is deferred until the user
        -- actually opens a module settings menu, not when makeModulesMenu runs.
        local ctx_menu_data = {
            pfx           = ctx.pfx,
            pfx_qa        = ctx.pfx_qa,
            refresh       = ctx.refresh,
            UIManager     = UIManager,
            _             = _,
            MAX_LABEL_LEN = MAX_LABEL_LEN,
            makeQAMenu    = makeQAMenu,
            _cover_picker = nil,
        }
        local ctx_menu = setmetatable(ctx_menu_data, {
            __index = function(t, k)
                if k == "InfoMessage" then
                    local v = InfoMessage(); rawset(t, k, v); return v
                elseif k == "SortWidget" then
                    local v = SortWidget(); rawset(t, k, v); return v
                end
            end,
        })

        local function loadOrder()
            local saved   = G_reader_settings:readSetting(ctx.pfx .. "module_order")
            local default = Registry.defaultOrder()
            if type(saved) ~= "table" or #saved == 0 then return default end
            local seen = {}; local result = {}
            for _loop_, v in ipairs(saved) do seen[v] = true; result[#result+1] = v end
            for _loop_, v in ipairs(default) do if not seen[v] then result[#result+1] = v end end
            return result
        end

        -- Toggle item for one module descriptor.
        -- Persistence is fully delegated to mod.setEnabled(pfx, on).
        local function makeToggleItem(mod)
            local _mod = mod
            return {
                text_func = function()
                    local base = _mod.name
                    if isUnlimited() then return base end
                    if Registry.isEnabled(_mod, ctx.pfx) then return base end
                    local rem = MAX_MOD - countModules(ctx)
                    if rem <= 0 then return base .. "  (0 left)" end
                    if rem <= 2 then return base .. "  (" .. rem .. " left)" end
                    return base
                end,
                checked_func   = function() return Registry.isEnabled(_mod, ctx.pfx) end,
                keep_menu_open = true,
                callback = function()
                    local on = Registry.isEnabled(_mod, ctx.pfx)
                    if not on and not isUnlimited() and countModules(ctx) >= MAX_MOD then maxMsg(); return end
                    if type(_mod.setEnabled) == "function" then
                        _mod.setEnabled(ctx.pfx, not on)
                    elseif _mod.enabled_key then
                        G_reader_settings:saveSetting(ctx.pfx .. _mod.enabled_key, not on)
                    end
                    ctx.refresh()
                end,
            }
        end

        -- Module Settings sub-menu: one entry per module that has getMenuItems.
        -- Count labels are provided by mod.getCountLabel(pfx) — no per-id special cases.
        local function makeModuleSettingsMenu()
            local items    = {}
            local qa_items = {}
            for _loop_, mod in ipairs(Registry.list()) do
                if type(mod.getMenuItems) == "function" then
                    local _mod = mod
                    local text_fn = function()
                        local count_lbl = type(_mod.getCountLabel) == "function"
                            and _mod.getCountLabel(ctx.pfx)
                        return count_lbl
                            and (_mod.name .. "  " .. count_lbl)
                            or   _mod.name
                    end
                    if _mod.id:match("^quick_actions_%d+$") then
                        qa_items[#qa_items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    else
                        items[#items + 1] = {
                            text_func           = text_fn,
                            sub_item_table_func = function() return _mod.getMenuItems(ctx_menu) end,
                        }
                    end
                end
            end
            if #qa_items > 0 then
                items[#items + 1] = {
                    text                = _("Quick Actions"),
                    sub_item_table_func = function() return qa_items end,
                }
            end
            return items
        end

        -- Toggle items sorted alphabetically
        local toggles = {}
        for _loop_, mod in ipairs(Registry.list()) do
            toggles[#toggles+1] = makeToggleItem(mod)
        end
        table.sort(toggles, function(a, b)
            local ta = type(a.text_func) == "function" and a.text_func() or (a.text or "")
            local tb = type(b.text_func) == "function" and b.text_func() or (b.text or "")
            return ta:lower() < tb:lower()
        end)

        return {
            {
                text_func = function()
                    local n = countModules(ctx)
                    if isUnlimited() then
                        return string.format(_("Modules  (%d — no limit)"), n)
                    end
                    local rem = MAX_MOD - n
                    if rem <= 0 then return string.format(_("Modules  (%d/%d — at limit)"), n, MAX_MOD) end
                    return string.format(_("Modules  (%d/%d — %d left)"), n, MAX_MOD, rem)
                end,
                sub_item_table_func = function()
                    local result = {
                        {
                            text = _("Arrange Modules"), keep_menu_open = true,
                            callback = function()
                                local order      = loadOrder()
                                local sort_items = {}
                                for _loop_, key in ipairs(order) do
                                    local mod = Registry.get(key)
                                    if mod and Registry.isEnabled(mod, ctx.pfx) then
                                        sort_items[#sort_items+1] = { text = mod.name, orig_item = key }
                                    end
                                end
                                if #sort_items < 2 then
                                    UIManager:show(InfoMessage():new{
                                        text = _("Enable at least 2 modules to arrange."), timeout = 2 })
                                    return
                                end
                                UIManager:show(SortWidget():new{
                                    title = _("Arrange Modules"), item_table = sort_items,
                                    covers_fullscreen = true,
                                    callback = function()
                                        local new_active = {}; local active_set = {}
                                        for _loop_, item in ipairs(sort_items) do
                                            new_active[#new_active+1] = item.orig_item
                                            active_set[item.orig_item] = true
                                        end
                                        for _loop_, k in ipairs(loadOrder()) do
                                            if not active_set[k] then new_active[#new_active+1] = k end
                                        end
                                        G_reader_settings:saveSetting(ctx.pfx.."module_order", new_active)
                                        ctx.refresh()
                                    end,
                                })
                            end,
                        },
                        {
                            text = _("Module Settings"),
                            sub_item_table_func = makeModuleSettingsMenu,
                        },
                        {
                            text = _("No Module Limit  ⚠ not recommended"),
                            checked_func = function() return isUnlimited() end,
                            keep_menu_open = true,
                            callback = function()
                                local on = isUnlimited()
                                G_reader_settings:saveSetting(NO_LIMIT_KEY, not on)
                                if not on then
                                    UIManager:show(InfoMessage():new{
                                        text = _("Module limit disabled. Enabling too many modules may slow down the homescreen significantly and modules may be clipped at the bottom of the page."),
                                        timeout = 4,
                                    })
                                end
                                ctx.refresh()
                            end,
                        },
                        {
                            text_func = function() return _("Scale") end,
                            separator = true,
                            sub_item_table = {
                                {
                                    text_func    = function() return _("Lock Scale") end,
                                    checked_func = function() return Config.isScaleLinked() end,
                                    keep_menu_open = true,
                                    separator = true,
                                    callback = function()
                                        Config.setScaleLinked(not Config.isScaleLinked())
                                        ctx.refresh()
                                    end,
                                },
                                {
                                    text_func = function()
                                        return _("Modules")
                                    end,
                                    keep_menu_open = true,
                                    callback = function()
                                        local SpinWidget = require("ui/widget/spinwidget")
                                        UIManager:show(SpinWidget:new{
                                            title_text    = _("Module Scale"),
                                            info_text     = Config.isScaleLinked()
                                                and _("Scales all modules and labels together.\n100% is the default size.")
                                                or  _("Global scale for all modules.\nIndividual overrides in Module Settings take precedence.\n100% is the default size."),
                                            value         = Config.getModuleScalePct(),
                                            value_min     = Config.SCALE_MIN,
                                            value_max     = Config.SCALE_MAX,
                                            value_step    = Config.SCALE_STEP,
                                            unit          = "%",
                                            ok_text       = _("Apply"),
                                            cancel_text   = _("Cancel"),
                                            default_value = Config.SCALE_DEF,
                                            callback = function(spin)
                                                Config.setModuleScale(spin.value)
                                                local HS = package.loaded["sui_homescreen"]
                                                if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                                ctx.refresh()
                                            end,
                                        })
                                    end,
                                },
                                {
                                    text_func      = function() return _("Labels") end,
                                    keep_menu_open = true,
                                    callback = function()
                                        if Config.isScaleLinked() then
                                            local UIManager_  = require("ui/uimanager")
                                            local InfoMessage = require("ui/widget/infomessage")
                                            UIManager_:show(InfoMessage:new{
                                                text    = _("Disable \"Lock Scale\" first to set a custom label scale."),
                                                timeout = 3,
                                            })
                                            return
                                        end
                                        local SpinWidget = require("ui/widget/spinwidget")
                                        local UIManager_ = require("ui/uimanager")
                                        UIManager_:show(SpinWidget:new{
                                            title_text    = _("Label Scale"),
                                            info_text     = _("Scales the section label text above each module.\n100% is the default size."),
                                            value         = Config.getLabelScalePct(),
                                            value_min     = Config.SCALE_MIN,
                                            value_max     = Config.SCALE_MAX,
                                            value_step    = Config.SCALE_STEP,
                                            unit          = "%",
                                            ok_text       = _("Apply"),
                                            cancel_text   = _("Cancel"),
                                            default_value = Config.SCALE_DEF,
                                            callback = function(spin)
                                                Config.setLabelScale(spin.value)
                                                local HS = package.loaded["sui_homescreen"]
                                                if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                                ctx.refresh()
                                            end,
                                        })
                                    end,
                                },
                            },
                        },
                        {
                            text      = _("Reset to Default Scale"),
                            separator = true,
                            callback  = function()
                                local ConfirmBox = require("ui/widget/confirmbox")
                                UIManager:show(ConfirmBox:new{
                                    text    = _("Reset all scales to default (100%)? This cannot be undone."),
                                    ok_text = _("Reset"),
                                    ok_callback = function()
                                        Config.resetAllScales(ctx.pfx, ctx.pfx_qa)
                                        local HS = package.loaded["sui_homescreen"]
                                        if HS and HS.invalidateLabelCache then HS.invalidateLabelCache() end
                                        ctx.refresh()
                                    end,
                                })
                            end,
                        },
                    }
                    for _loop_, t in ipairs(toggles) do result[#result+1] = t end
                    return result
                end,
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- makeHomescreenMenu
    -- -----------------------------------------------------------------------

    local function makeHomescreenMenu()
        local ctx = HOMESCREEN_CTX
        local modules_items = makeModulesMenu(ctx)
        return {
            {
                text_func    = function()
                    local on = G_reader_settings:nilOrTrue("navbar_homescreen_enabled")
                    return _("Home Screen") .. " — " .. (on and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_homescreen_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_homescreen_enabled")
                    G_reader_settings:saveSetting("navbar_homescreen_enabled", not on)
                    plugin:_scheduleRebuild()
                end,
            },
            {
                text         = _("Start with Home Screen"),
                checked_func = function()
                    return G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("start_with", "filemanager") == "homescreen_simpleui"
                    G_reader_settings:saveSetting("start_with", on and "filemanager" or "homescreen_simpleui")
                end,
                separator = true,
            },
            table.unpack(modules_items),
        }
    end



    -- Local helper: updates the active tab in the FileManager bar.
    function setActiveAndRefreshFM(plugin_ref, action_id, tabs)
        plugin_ref.active_action = action_id
        local fm = plugin_ref.ui
        if fm and fm._navbar_container then
            Bottombar.replaceBar(fm, Bottombar.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
            UIManager:setDirty(fm[1], "ui")
        end
        return action_id
    end

    -- -----------------------------------------------------------------------
    -- Main menu entry
    -- -----------------------------------------------------------------------

    -- sorting_hint = "tools" places this entry in the Tools section of the
    -- KOReader main menu (where Statistics, Terminal, etc. live).
    -- Using a dedicated key "simpleui" avoids colliding with the section table.
    --
    -- OPT-H: All sub-menus are now built lazily via sub_item_table_func.
    -- Previously makeNavbarMenu(), makePaginationBarMenu() and makeTopbarMenu()
    -- were called eagerly at registration time, creating hundreds of closures
    -- (checked_func, callback, enabled_func, etc.) even if the user never opens
    -- the menu. With sub_item_table_func the closures are only allocated when
    -- the user actually taps the menu entry.
    menu_items.simpleui = {
        sorting_hint = "tools",
        text = _("Simple UI"),
        sub_item_table = {
            {
                text_func    = function()
                    return _("Simple UI") .. " — " .. (G_reader_settings:nilOrTrue("simpleui_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("simpleui_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("simpleui_enabled")
                    G_reader_settings:saveSetting("simpleui_enabled", not on)
                    -- When disabling SimpleUI, reset "Start with Homescreen" if active,
                    -- because "homescreen_simpleui" is not a value the base KOReader
                    -- understands — leaving it set would cause a blank screen on next boot.
                    if on and G_reader_settings:readSetting("start_with") == "homescreen_simpleui" then
                        G_reader_settings:saveSetting("start_with", "filemanager")
                    end
                    -- Flush immediately so a hard reboot / crash cannot leave the
                    -- setting unsaved, which would cause a white-screen boot loop
                    -- the next time KOReader starts with the plugin installed.
                    G_reader_settings:flush()
                    UIManager:show(ConfirmBox():new{
                        text        = string.format(_("Simple UI will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text     = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            UIManager:restartKOReader()
                        end,
                    })
                end,
                separator = true,
            },
            {
                text               = _("Settings"),
                sub_item_table_func = function()
                    return {
                        {
                            text = _("Top"),
                            sub_item_table = {
                                { text = _("Status Bar"), sub_item_table_func = makeTopbarMenu   },
                                { text = _("Title Bar"),  sub_item_table_func = makeTitleBarMenu },
                            },
                        },
                        { text = _("Home Screen"), sub_item_table_func = makeHomescreenMenu },
                        {
                            text = _("Bottom"),
                            sub_item_table = {
                                { text = _("Navigation Bar"), sub_item_table_func = makeNavbarMenu          },
                                { text = _("Pagination Bar"), sub_item_table_func = makePaginationBarMenu   },
                            },
                        },
                        {
                            text_func = function()
                                local n   = #getCustomQAList()
                                local rem = MAX_CUSTOM_QA - n
                                if n == 0 then return _("Quick Actions") end
                                if rem <= 0 then
                                    return string.format(_("Quick Actions  (%d/%d — at limit)"), n, MAX_CUSTOM_QA)
                                end
                                return string.format(_("Quick Actions  (%d/%d — %d left)"), n, MAX_CUSTOM_QA, rem)
                            end,
                            sub_item_table_func = makeQuickActionsMenu,
                        },
                        {
                            text = _("Library"),
                            sub_item_table_func = function()
                                local ok_fc, FC = pcall(require, "sui_foldercovers")
                                if not ok_fc or not FC then return {} end
                                -- Refresh the mosaic view immediately after any setting change.
                                local function _refreshFC()
                                    local FM = package.loaded["apps/filemanager/filemanager"]
                                    local fm = FM and FM.instance
                                    if fm and fm.file_chooser then
                                        fm.file_chooser:updateItems()
                                    end
                                end
                                return {
                                    {
                                        text         = _("Folder Covers"),
                                        checked_func = function() return FC.isEnabled() end,
                                        separator    = true,
                                        callback     = function()
                                            local enabling = not FC.isEnabled()
                                            FC.setEnabled(enabling)
                                            -- Install or uninstall the MosaicMenuItem patch
                                            -- at toggle time so that third-party user-patches
                                            -- (e.g. 2-browser-folder-cover.lua) that rely on
                                            -- userpatch.getUpValue(MosaicMenuItem.update, …)
                                            -- find the original function when FC is off.
                                            if enabling then
                                                pcall(FC.install)
                                            else
                                                pcall(FC.uninstall)
                                            end
                                            _refreshFC()
                                        end,
                                    },
                                    {
                                        text         = _("Overlays"),
                                        enabled_func = function() return FC.isEnabled() end,
                                        sub_item_table = {
                                            {
                                                text         = _("Number of Books in Folder"),
                                                sub_item_table = {
                                                    {
                                                        text           = _("Hidden"),
                                                        checked_func   = function() return FC.getBadgeHidden() end,
                                                        keep_menu_open = true,
                                                        separator      = true,
                                                        callback       = function()
                                                            FC.setBadgeHidden(not FC.getBadgeHidden())
                                                            FC.invalidateCache()
                                                            _refreshFC()
                                                        end,
                                                    },
                                                    {
                                                        text           = _("Top"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "top" end,
                                                        enabled_func   = function() return not FC.getBadgeHidden() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgePosition("top"); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Bottom"),
                                                        radio          = true,
                                                        checked_func   = function() return not FC.getBadgeHidden() and FC.getBadgePosition() == "bottom" end,
                                                        enabled_func   = function() return not FC.getBadgeHidden() end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setBadgePosition("bottom"); _refreshFC() end,
                                                    },
                                                },
                                            },
                                            {
                                                text           = _("Number of Pages"),
                                                checked_func   = function() return FC.getOverlayPages() end,
                                                keep_menu_open = true,
                                                callback       = function() FC.setOverlayPages(not FC.getOverlayPages()); FC.invalidateCache(); _refreshFC() end,
                                            },
                                            {
                                                text         = _("Folder Name"),
                                                sub_item_table = {
                                                    {
                                                        text           = _("Hidden"),
                                                        checked_func   = function() return FC.getLabelMode() == "hidden" end,
                                                        keep_menu_open = true,
                                                        separator      = true,
                                                        callback       = function()
                                                            FC.setLabelMode(FC.getLabelMode() == "hidden" and "overlay" or "hidden")
                                                            _refreshFC()
                                                        end,
                                                    },
                                                    {
                                                        text           = _("Transparent"),
                                                        checked_func   = function() return FC.getLabelStyle() == "alpha" end,
                                                        enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                                        keep_menu_open = true,
                                                        separator      = true,
                                                        callback       = function()
                                                            FC.setLabelStyle(FC.getLabelStyle() == "alpha" and "solid" or "alpha")
                                                            _refreshFC()
                                                        end,
                                                    },
                                                    {
                                                        text           = _("Top"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getLabelPosition() == "top" end,
                                                        enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setLabelPosition("top"); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Center"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getLabelPosition() == "center" end,
                                                        enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setLabelPosition("center"); _refreshFC() end,
                                                    },
                                                    {
                                                        text           = _("Bottom"),
                                                        radio          = true,
                                                        checked_func   = function() return FC.getLabelPosition() == "bottom" end,
                                                        enabled_func   = function() return FC.getLabelMode() ~= "hidden" end,
                                                        keep_menu_open = true,
                                                        callback       = function() FC.setLabelPosition("bottom"); _refreshFC() end,
                                                    },
                                                },
                                            },
                                        },
                                    },
                                    {
                                        text           = _("Uniformize Covers (2:3)"),
                                        checked_func   = function() return FC.getCoverMode() == "2_3" end,
                                        enabled_func   = function() return FC.isEnabled() end,
                                        keep_menu_open = true,
                                        callback       = function()
                                            FC.setCoverMode(FC.getCoverMode() == "2_3" and "default" or "2_3")
                                            _refreshFC()
                                        end,
                                    },
                                    {
                                        text           = _("Hide selection underline"),
                                        checked_func   = function() return FC.getHideUnderline() end,
                                        enabled_func   = function() return FC.isEnabled() end,
                                        keep_menu_open = true,
                                        callback       = function() FC.setHideUnderline(not FC.getHideUnderline()); _refreshFC() end,
                                    },
                                }
                            end,
                        },
                    }
                end,
            },
        },
    }
end -- addToMainMenu

end -- installer function
