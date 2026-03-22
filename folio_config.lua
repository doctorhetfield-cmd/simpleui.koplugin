-- config.lua — Folio
-- Plugin-wide constants, action catalogue, tab/topbar configuration,
-- custom Quick Actions and settings migration.
--
-- Settings keys use the `folio_` prefix (e.g. `folio_navbar_topbar_config`,
-- `folio_navbar_homescreen_*`, `folio_enabled`). Legacy keys are migrated via
-- `migrateLegacySettingsKeysToFolioPrefix()`; QoL `simpleui_*` / `sui_*` keys are migrated inline in main.lua.

local G_reader_settings = G_reader_settings
local logger            = require("logger")
local _                 = require("gettext")

-- ---------------------------------------------------------------------------
-- Public constants
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Icon path registry — single source of truth for every SVG used by the plugin.
--
-- Two prefixes exist:
--   _P  = "plugins/folio.koplugin/icons/"   (own assets)
--   _KO = "resources/icons/mdlight/"            (KOReader built-in assets)
--
-- All modules must reference M.ICON.<key> instead of bare string literals.
-- Adding or renaming an icon only requires editing this one table.
-- ---------------------------------------------------------------------------

-- Resolve the plugin's own directory at load time so icon paths are absolute.
-- On Android/Nook the working directory is not the KOReader root, so relative
-- paths like "plugins/folio.koplugin/icons/..." silently fail to resolve
-- while KOReader's own assets (resources/icons/mdlight/...) work because the
-- engine has hardcoded fallbacks for its own resource tree.
-- Using an absolute path derived from this file's location is portable across
-- all platforms (Android, Kobo, Kindle, desktop emulator).
local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
local _P  = _plugin_dir .. "icons/"
-- Resolve KOReader root for Android compatibility (relative paths fail on Android).
-- DataStorage.getDataDir() returns the absolute KOReader data/install root.
local _ko_root = ""
local _ok_ds, _ds = pcall(require, "datastorage")
if _ok_ds and _ds and type(_ds.getDataDir) == "function" then
    -- getDataDir() returns e.g. /sdcard/koreader — strip trailing slash safety.
    local _d = _ds.getDataDir():gsub("/$", "")
    -- Walk up from data dir to find the KOReader install root (contains "resources").
    -- On most platforms data dir IS the install root; on Android it may differ.
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m and lfs_m.attributes(_d .. "/resources/icons/mdlight", "mode") == "directory" then
        _ko_root = _d .. "/"
    end
end
if _ko_root == "" then
    -- Fallback: derive from plugin file location (works on Kobo/Kindle/desktop).
    -- Plugin lives at <root>/plugins/folio.koplugin/folio_config.lua
    -- so root is two directories up.
    _ko_root = _plugin_dir:match("^(.*/)plugins/[^/]+/$") or ""
end
local _KO = _ko_root .. "resources/icons/mdlight/"

M.ICON = {
    -- Plugin icons
    library        = _P .. "library.svg",
    collections    = _P .. "collections.svg",
    history        = _P .. "history.svg",
    continue_      = _P .. "continue.svg",       -- trailing _ avoids clash with Lua keyword
    frontlight     = _P .. "frontlight.svg",
    stats          = _P .. "stats.svg",
    power          = _P .. "power.svg",
    plus_alt       = _P .. "plus_alt.svg",
    custom         = _P .. "custom.svg",
    custom_dir     = _P .. "custom",             -- directory, no trailing slash
    plugin         = _P .. "plugin.svg",

    -- Navpager arrow icons (KOReader built-ins)
    nav_prev       = _KO .. "chevron.left.svg",
    nav_next       = _KO .. "chevron.right.svg",

    -- KOReader built-in icons
    ko_home        = _KO .. "home.svg",
    ko_star        = _KO .. "star.empty.svg",
    ko_wifi_on     = _KO .. "wifi.open.100.svg",
    ko_wifi_off    = _KO .. "wifi.open.0.svg",
    ko_menu        = _KO .. "appbar.menu.svg",
    ko_settings    = _KO .. "appbar.settings.svg",
    ko_search      = _KO .. "appbar.search.svg",
    ko_bookmark    = _KO .. "bookmark.svg",
}

-- Legacy flat constants — kept for any external code that may reference them.
-- They resolve through the table above so there is still a single definition.
M.CUSTOM_ICON            = M.ICON.custom
M.CUSTOM_PLUGIN_ICON     = M.ICON.plugin
M.CUSTOM_DISPATCHER_ICON = M.ICON.ko_settings
M.DEFAULT_NUM_TABS       = 4
M.MAX_TABS               = 6        -- standard mode limit
M.MAX_TABS_NAVPAGER      = 4        -- navpager mode limit
M.MAX_LABEL_LEN          = 20
M.MAX_CUSTOM_QA          = 10
-- When the navpager is enabled the bar always shows exactly this many centre tabs.
M.NAVPAGER_CENTER_TABS   = 4

M.DEFAULT_TABS = { "home", "collections", "history", "continue", "favorites" }

-- Fallback tab IDs used when a duplicate 'home' is detected.
M.NON_HOME_DEFAULTS = {}
for _i, id in ipairs(M.DEFAULT_TABS) do
    if id ~= "home" then M.NON_HOME_DEFAULTS[#M.NON_HOME_DEFAULTS + 1] = id end
end

-- ---------------------------------------------------------------------------
-- Predefined action catalogue
-- ---------------------------------------------------------------------------

M.ALL_ACTIONS = {
    { id = "home",             label = _("Library"),          icon = M.ICON.library     },
    { id = "homescreen",       label = _("Home"),             icon = M.ICON.ko_home     },
    { id = "collections",      label = _("Collections"),      icon = M.ICON.collections },
    { id = "history",          label = _("History"),          icon = M.ICON.history     },
    { id = "continue",         label = _("Continue"),         icon = M.ICON.continue_   },
    { id = "favorites",        label = _("Favorites"),        icon = M.ICON.ko_star     },
    { id = "bookmark_browser", label = _("Bookmarks"),        icon = M.ICON.ko_bookmark },
    { id = "wifi_toggle",      label = _("Wi-Fi"),            icon = M.ICON.ko_wifi_on  },
    { id = "frontlight",       label = _("Brightness"),       icon = M.ICON.frontlight  },
    { id = "stats_calendar",   label = _("Stats"),            icon = M.ICON.stats       },
    { id = "power",            label = _("Power"),            icon = M.ICON.power       },
}

-- Fast lookup map keyed by action ID.
M.ACTION_BY_ID = {}
for _i, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- ---------------------------------------------------------------------------
-- Topbar configuration
-- ---------------------------------------------------------------------------

M.TOPBAR_ITEMS = { "clock", "wifi", "brightness", "battery", "disk", "ram" }

local _topbar_item_labels = nil

function M.TOPBAR_ITEM_LABEL(k)
    if not _topbar_item_labels then
        _topbar_item_labels = {
            clock      = _("Clock"),
            wifi       = _("WiFi"),
            brightness = _("Brightness"),
            battery    = _("Battery"),
            disk       = _("Disk Usage"),
            ram        = _("RAM Usage"),
        }
    end
    return _topbar_item_labels[k] or k
end

-- Returns the normalised topbar config, migrating legacy formats when needed.
function M.getTopbarConfig()
    local raw = G_reader_settings:readSetting("folio_navbar_topbar_config")
    local cfg = { side = {}, order_left = {}, order_right = {}, show = {}, order = {} }
    if type(raw) == "table" then
        if type(raw.side) == "table" then
            for k, v in pairs(raw.side) do cfg.side[k] = v end
        end
        if type(raw.order_left) == "table" then
            for _i, v in ipairs(raw.order_left) do cfg.order_left[#cfg.order_left + 1] = v end
        end
        if type(raw.order_right) == "table" then
            for _i, v in ipairs(raw.order_right) do cfg.order_right[#cfg.order_right + 1] = v end
        end
        if not next(cfg.side) and type(raw.show) == "table" then
            for k, v in pairs(raw.show) do
                cfg.side[k] = v and "right" or "hidden"
            end
            if type(raw.order) == "table" then
                for _i, v in ipairs(raw.order) do
                    if v ~= "clock" and cfg.side[v] == "right" then
                        cfg.order_right[#cfg.order_right + 1] = v
                    end
                end
            end
        end
    end
    if not next(cfg.side) then
        cfg.side        = { clock = "left", battery = "right", wifi = "right" }
        cfg.order_left  = { "clock" }
        cfg.order_right = { "wifi", "battery" }
    end
    if #cfg.order_left == 0 then
        for k, s in pairs(cfg.side) do
            if s == "left" and k ~= "clock" then cfg.order_left[#cfg.order_left + 1] = k end
        end
        if cfg.side["clock"] == "left" then
            table.insert(cfg.order_left, 1, "clock")
        end
    end
    if #cfg.order_right == 0 then
        for k, s in pairs(cfg.side) do
            if s == "right" then cfg.order_right[#cfg.order_right + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    G_reader_settings:saveSetting("folio_navbar_topbar_config", cfg)
    M.invalidateTopbarConfigCache()
    -- Also invalidate topbar.lua's own local config cache so that
    -- buildTopbarWidget() uses the new config immediately on the next rebuild.
    local tb = package.loaded["folio_topbar"]
    if tb and tb.invalidateConfigCache then tb.invalidateConfigCache() end
end

-- ---------------------------------------------------------------------------
-- Custom Quick Actions
-- ---------------------------------------------------------------------------

-- Key cache: avoids rebuilding "folio_navbar_cqa_<id>" strings on every call.
-- These keys are stable within a session (IDs never change after creation).
local _qa_key_cache = {}
local function getQASettingsKey(qa_id)
    local k = _qa_key_cache[qa_id]
    if not k then
        k = "folio_navbar_cqa_" .. qa_id
        _qa_key_cache[qa_id] = k
    end
    return k
end

function M.getCustomQAList()
    return G_reader_settings:readSetting("folio_navbar_custom_qa_list") or {}
end

function M.saveCustomQAList(list)
    G_reader_settings:saveSetting("folio_navbar_custom_qa_list", list)
end

function M.getCustomQAConfig(qa_id)
    local cfg = G_reader_settings:readSetting(getQASettingsKey(qa_id)) or {}
    return {
        label             = cfg.label or qa_id,
        path              = cfg.path,
        collection        = cfg.collection,
        plugin_key        = cfg.plugin_key,
        plugin_method     = cfg.plugin_method,
        dispatcher_action = cfg.dispatcher_action,
        icon              = cfg.icon,
    }
end

function M.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action)
    G_reader_settings:saveSetting(getQASettingsKey(qa_id), {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        icon              = icon,
    })
end

function M.deleteCustomQA(qa_id)
    G_reader_settings:delSetting(getQASettingsKey(qa_id))
    _qa_key_cache[qa_id] = nil  -- remove from key cache
    local list = M.getCustomQAList()
    local new_list = {}
    for _i, id in ipairs(list) do
        if id ~= qa_id then new_list[#new_list + 1] = id end
    end
    M.saveCustomQAList(new_list)
    -- Invalidate the module-level QA validity cache so the next render does
    -- not show a deleted action.
    local mqa = package.loaded["desktop_modules/module_quick_actions"]
    if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    local tabs = G_reader_settings:readSetting("folio_navbar_tabs")
    if type(tabs) == "table" then
        local new_tabs = {}
        for _i, id in ipairs(tabs) do
            if id ~= qa_id then new_tabs[#new_tabs + 1] = id end
        end
        G_reader_settings:saveSetting("folio_navbar_tabs", new_tabs)
    end
    -- Remove from all page QA slots
    for _i, pfx in ipairs({ "folio_navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key = pfx .. slot .. "_items"
            local dqa = G_reader_settings:readSetting(key)
            if type(dqa) == "table" then
                local new_dqa = {}
                for _i, id in ipairs(dqa) do
                    if id ~= qa_id then new_dqa[#new_dqa + 1] = id end
                end
                G_reader_settings:saveSetting(key, new_dqa)
            end
        end
    end
end

-- Removes all custom QA entries that reference a deleted collection name.
-- Called by patches.lua when removeCollection fires.
function M.purgeQACollection(coll_name)
    local list    = M.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = M.getCustomQAConfig(qa_id)
        if cfg.collection == coll_name then
            -- Wipe the collection field so the QA becomes unconfigured
            -- (keeps the entry visible so the user knows to reconfigure).
            M.saveCustomQAConfig(qa_id, cfg.label, cfg.path, nil,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Updates collection references in all custom QAs after a rename.
function M.renameQACollection(old_name, new_name)
    local list    = M.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = M.getCustomQAConfig(qa_id)
        if cfg.collection == old_name then
            M.saveCustomQAConfig(qa_id, cfg.label, cfg.path, new_name,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Removes orphaned custom QA ids from all QA slots.
-- An id is orphaned when it is referenced in a slot but not in the master list.
-- Safe to call at startup and after any QA deletion.
function M.sanitizeQASlots()
    local list = M.getCustomQAList()
    local valid = {}
    for _i, id in ipairs(list) do valid[id] = true end
    local changed = false
    for _, pfx in ipairs({ "folio_navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key  = pfx .. slot .. "_items"
            local items = G_reader_settings:readSetting(key)
            if type(items) == "table" then
                local clean = {}
                for _i, id in ipairs(items) do
                    -- Keep built-in action ids and valid custom QA ids
                    if not id:match("^custom_qa_%d+$") or valid[id] then
                        clean[#clean+1] = id
                    else
                        changed = true
                    end
                end
                if changed then G_reader_settings:saveSetting(key, clean) end
            end
        end
    end
    if changed then
        local mqa = package.loaded["desktop_modules/module_quick_actions"]
        if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    end
    return changed
end

function M.nextCustomQAId()
    local list  = M.getCustomQAList()
    local max_n = 0
    for _i, id in ipairs(list) do
        local n = tonumber(id:match("^custom_qa_(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local n = max_n + 1
    while G_reader_settings:readSetting("folio_navbar_cqa_custom_qa_" .. n) do n = n + 1 end
    return "custom_qa_" .. n
end

-- ---------------------------------------------------------------------------
-- Tab configuration
-- ---------------------------------------------------------------------------

-- In-memory cache to avoid repeated settings reads.
local _tabs_cache = nil

function M.invalidateTabsCache()
    _tabs_cache = nil
end

function M.loadTabConfig()
    if _tabs_cache then return _tabs_cache end
    local cfg = G_reader_settings:readSetting("folio_navbar_tabs")
    local result = {}
    local min_tabs = M.isNavpagerEnabled() and 1 or 2
    if type(cfg) == "table" and #cfg >= min_tabs and #cfg <= M.effectiveMaxTabs() then
        for i = 1, #cfg do
            local id = cfg[i]
            if M.ACTION_BY_ID[id] or id:match("^custom_qa_%d+$") then
                result[#result + 1] = id
            else
                logger.warn("folio: loadTabConfig: ignoring unknown tab id: " .. tostring(id))
            end
        end
    else
        for i = 1, M.DEFAULT_NUM_TABS do
            result[i] = M.DEFAULT_TABS[i] or M.ALL_ACTIONS[2].id
        end
    end
    M._ensureHomePresent(result)
    _tabs_cache = result
    return _tabs_cache
end

function M.saveTabConfig(tabs)
    _tabs_cache = nil
    G_reader_settings:saveSetting("folio_navbar_tabs", tabs)
end

function M.getNumTabs()
    -- Read the cache directly to avoid any table allocation (P2).
    if _tabs_cache then return #_tabs_cache end
    return #M.loadTabConfig()
end

-- Cached navbar mode — "both", "icons", or "text".
-- Invalidated by saveNavbarMode() whenever the user changes the setting.
local _folio_navbar_mode_cache = nil

function M.getNavbarMode()
    if not _folio_navbar_mode_cache then
        _folio_navbar_mode_cache = G_reader_settings:readSetting("folio_navbar_mode") or "both"
    end
    return _folio_navbar_mode_cache
end

function M.saveNavbarMode(mode)
    _folio_navbar_mode_cache = nil
    G_reader_settings:saveSetting("folio_navbar_mode", mode)
end

function M._ensureHomePresent(tabs)
    -- Single-pass: find the first 'home' position and collect used ids,
    -- then fix any duplicate 'home' entries in the same iteration.
    local home_pos = nil
    local used = {}
    for i, id in ipairs(tabs) do
        if id == "home" then
            if not home_pos then
                home_pos = i
                used[id] = true
            else
                -- Duplicate 'home' — replace with the first unused default.
                for _, fid in ipairs(M.NON_HOME_DEFAULTS) do
                    if not used[fid] then
                        tabs[i] = fid
                        used[fid] = true
                        break
                    end
                end
            end
        else
            used[id] = true
        end
    end
    return tabs
end

function M.tabInTabs(tab_id, tabs)
    for _i, tid in ipairs(tabs) do
        if tid == tab_id then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Action resolution — returns live label/icon for dynamic actions
-- ---------------------------------------------------------------------------

-- Optimistic Wi-Fi state, updated immediately on toggle.
M.wifi_optimistic = nil

function M.homeLabel()
    return _("Library")
end

function M.homeIcon()
    return M.ICON.library
end

-- Module-level cache for the two heavy requires used every bar rebuild.
local _Device     = nil
local _NetworkMgr = nil
local function getDevice()
    if not _Device then _Device = require("device") end
    return _Device
end
local function getNetworkMgr()
    if not _NetworkMgr then
        local ok, nm = pcall(require, "ui/network/manager")
        if ok and nm then _NetworkMgr = nm end
    end
    return _NetworkMgr
end
M.getNetworkMgr = getNetworkMgr

-- Hardware capability — does not change during a session.
-- nil = not yet tested, false = no wifi toggle, true = has wifi toggle.
local _has_wifi_toggle = nil
local function deviceHasWifi()
    if _has_wifi_toggle == nil then
        local ok, v = pcall(function() return getDevice():hasWifiToggle() end)
        _has_wifi_toggle = ok and v == true
    end
    return _has_wifi_toggle
end

function M.wifiIcon()
    if M.wifi_optimistic ~= nil then
        return M.wifi_optimistic and M.ICON.ko_wifi_on or M.ICON.ko_wifi_off
    end
    if not deviceHasWifi() then return M.ICON.ko_wifi_off end
    local NetworkMgr = getNetworkMgr()
    if not NetworkMgr then return M.ICON.ko_wifi_off end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_state and wifi_on then return M.ICON.ko_wifi_on end
    return M.ICON.ko_wifi_off
end

-- Mutable sentinel reused on every bar rebuild for wifi_toggle.
-- Avoids allocating a new table each time the icon state is queried.
local _wifi_action_live = { id = "wifi_toggle", label = "", icon = "" }

function M.getActionById(id)
    -- Delegate to folio_quickactions — single source of truth for label/icon
    -- resolution (applies overrides, custom QA configs, wifi state, etc.).
    -- Lazy-loaded to avoid a circular require at module load time.
    local QA = package.loaded["folio_quickactions"]
        or require("folio_quickactions")
    local entry = QA.getEntry(id)
    -- getActionById must return a table with id field for callers that read .id
    if entry and not entry.id then
        return { id = id, label = entry.label, icon = entry.icon }
    end
    return entry or M.ALL_ACTIONS[1]
end

-- ---------------------------------------------------------------------------
-- Settings migration
-- ---------------------------------------------------------------------------

-- Convenience delegates — the authoritative implementations live in
-- folio_quickactions to avoid circular requires. These thin wrappers keep
-- backwards compatibility for any caller that uses Config.* directly.
function M.getDefaultActionLabel(id)
    local QA = package.loaded["folio_quickactions"] or require("folio_quickactions")
    return QA.getDefaultActionLabel(id)
end
function M.getDefaultActionIcon(id)
    local QA = package.loaded["folio_quickactions"] or require("folio_quickactions")
    return QA.getDefaultActionIcon(id)
end
function M.setDefaultActionLabel(id, label)
    local QA = package.loaded["folio_quickactions"] or require("folio_quickactions")
    QA.setDefaultActionLabel(id, label)
end
function M.setDefaultActionIcon(id, icon)
    local QA = package.loaded["folio_quickactions"] or require("folio_quickactions")
    QA.setDefaultActionIcon(id, icon)
end

function M.sanitizeLabel(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    if #s > M.MAX_LABEL_LEN then s = s:sub(1, M.MAX_LABEL_LEN) end
    return s
end

function M.migrateOldCustomSlots()
    if G_reader_settings:readSetting("folio_navbar_custom_qa_migrated_v1") then return end
    local id_map  = {}
    local qa_list = M.getCustomQAList()
    local qa_set  = {}
    for _i, id in ipairs(qa_list) do qa_set[id] = true end

    for slot = 1, 4 do
        local old_id = "custom_" .. slot
        local cfg    = G_reader_settings:readSetting("navbar_custom_" .. slot)
        if type(cfg) == "table" and (cfg.path or cfg.collection) then
            local new_id = M.nextCustomQAId()
            M.saveCustomQAConfig(new_id, cfg.label or (_("Custom") .. " " .. slot), cfg.path, cfg.collection)
            if not qa_set[new_id] then
                qa_list[#qa_list + 1] = new_id
                qa_set[new_id]        = true
            end
            id_map[old_id] = new_id
            logger.info("folio: migrated " .. old_id .. " -> " .. new_id)
        end
    end

    M.saveCustomQAList(qa_list)

    local tabs = G_reader_settings:readSetting("folio_navbar_tabs")
    if type(tabs) == "table" then
        -- Build a new table instead of mutating while iterating (B6).
        local new_tabs, changed = {}, false
        for _i, id in ipairs(tabs) do
            if id_map[id] then
                new_tabs[#new_tabs + 1] = id_map[id]; changed = true
            elseif id:match("^custom_%d+$") and not id:match("^custom_qa_") then
                changed = true  -- discard stale legacy ID
            else
                new_tabs[#new_tabs + 1] = id
            end
        end
        if changed then G_reader_settings:saveSetting("folio_navbar_tabs", new_tabs) end
    end

    for slot = 1, 3 do
        local key = "folio_navbar_homescreen_quick_actions_" .. slot .. "_items"
        local dqa = G_reader_settings:readSetting(key)
        if type(dqa) == "table" then
            local changed = false
            local new_dqa = {}
            for _i, id in ipairs(dqa) do
                if id_map[id] then
                    new_dqa[#new_dqa + 1] = id_map[id]; changed = true
                elseif not id:match("^custom_%d+$") or id:match("^custom_qa_") then
                    new_dqa[#new_dqa + 1] = id
                else
                    changed = true
                end
            end
            if changed then G_reader_settings:saveSetting(key, new_dqa) end
        end
    end

    G_reader_settings:saveSetting("folio_navbar_custom_qa_migrated_v1", true)

    local legacy_enabled = G_reader_settings:readSetting("navbar_enabled")
    if legacy_enabled ~= nil and G_reader_settings:readSetting("folio_enabled") == nil then
        G_reader_settings:saveSetting("folio_enabled", legacy_enabled)
    end
end

-- ---------------------------------------------------------------------------
-- First-run defaults — written once on fresh install, never overwritten.
-- Guard key: "folio_defaults_v1". Idempotent: safe to call on every init.
-- ---------------------------------------------------------------------------

function M.applyFirstRunDefaults()
    if not G_reader_settings:readSetting("folio_defaults_v1") then
        -- Bottom bar
        G_reader_settings:saveSetting("folio_navbar_enabled",        true)
        G_reader_settings:saveSetting("folio_navbar_topbar_enabled", true)
        G_reader_settings:saveSetting("folio_navbar_mode",           "both")
        G_reader_settings:saveSetting("folio_navbar_bar_size",       "default")
        G_reader_settings:saveSetting("folio_navbar_tabs",
            { "home", "homescreen", "history", "continue", "power" })

        -- Top bar: clock left, battery + wifi right; rest hidden
        M.saveTopbarConfig({
            side        = { clock = "left", battery = "right", wifi = "right" },
            order_left  = { "clock" },
            order_right = { "wifi", "battery" },
        })

        -- Homescreen modules: header + currently + recent on; everything else off
        local PFX = "folio_navbar_homescreen_"
        G_reader_settings:saveSetting(PFX .. "header_enabled",  true)
        G_reader_settings:saveSetting(PFX .. "header",          "clock_date")
        G_reader_settings:saveSetting(PFX .. "currently",       true)
        G_reader_settings:saveSetting(PFX .. "recent",          true)
        G_reader_settings:saveSetting(PFX .. "collections",     false)
        G_reader_settings:saveSetting(PFX .. "reading_goals",   false)
        G_reader_settings:saveSetting(PFX .. "reading_stats_enabled",          false)
        G_reader_settings:saveSetting(PFX .. "quick_actions_1_enabled",        true)
        G_reader_settings:saveSetting(PFX .. "quick_actions_1_items",          { "bookmark_browser" })
        G_reader_settings:saveSetting(PFX .. "quick_actions_2_enabled",        false)
        G_reader_settings:saveSetting(PFX .. "quick_actions_3_enabled",        false)

        -- General
        G_reader_settings:saveSetting("start_with", "filemanager")

        G_reader_settings:saveSetting("folio_defaults_v1", true)
    end

    -- ---------------------------------------------------------------------------
    -- v2 migration: apply titlebar layout with search button visible on the left.
    -- Runs once on existing installs that already have folio_defaults_v1 set.
    -- Guard key: "folio_defaults_v2". Safe to call on every init.
    -- ---------------------------------------------------------------------------
    if not G_reader_settings:readSetting("folio_defaults_v2") then
        -- Visibility: search button on
        G_reader_settings:saveSetting("folio_tb_item_search_button", true)
        -- FM layout: up_button left slot-0, search_button left slot-1, menu_button right
        G_reader_settings:saveSetting("folio_tb_fm_cfg", {
            side        = { menu_button = "right", up_button = "left", search_button = "left" },
            order_left  = { "up_button", "search_button" },
            order_right = { "menu_button" },
        })
        G_reader_settings:saveSetting("folio_defaults_v2", true)
    end
end

function M.reset()
    _tabs_cache                  = nil
    _folio_navbar_mode_cache           = nil
    M.wifi_optimistic            = nil
    M.cover_extraction_pending   = false
    _Device                      = nil
    _NetworkMgr                  = nil
    _has_wifi_toggle             = nil
    _topbar_item_labels          = nil
    _SQ3                         = nil
    _lfs_mod                     = nil
    _BookInfoManager             = nil
    _topbar_cfg_menu_cache       = nil
    _ReadCollection              = nil
    -- Clear QA key cache so re-enable starts clean
    for k in pairs(_qa_key_cache) do _qa_key_cache[k] = nil end
    -- Release all cached cover bitmaps (OPT-D)
    M.clearCoverCache()
    -- _bim_cover_count and _RenderImage are reset inside clearCoverCache()
end

-- ---------------------------------------------------------------------------
-- BookInfoManager — centralised cover cache shared by the Homescreen and
-- collectionswidget.lua, avoiding duplicate discovery logic (fix #17).
-- ---------------------------------------------------------------------------

-- Shared cover-extraction pending flag.
-- Previously each module kept its own flag, causing up to 2 parallel poll
-- timers (60 × 0.5 s each). One centralised flag prevents duplicates.
M.cover_extraction_pending = false

local _BookInfoManager = nil

function M.getBookInfoManager()
    if _BookInfoManager then return _BookInfoManager end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cover bitmap LRU cache — OPT-D
--
-- getCoverBB always returns a bitmap already scaled to exactly w×h pixels.
-- Previously the raw native bitmap was cached and ImageWidget was asked to
-- scale it on every paint (scale_factor=0). Because each book cover has
-- different native proportions, the scale_factor differed per book and
-- KOReader produced negative initial_offsets (crop), causing distortion.
--
-- Fix: scale once at cache-fill time, store the correctly-sized bitmap,
-- pass it to ImageWidget with scale_factor=1 (no further scaling).
-- The cached bitmaps are now owned by us, so we free them on eviction.
--
-- LRU implementation: each cache entry stores the bitmap and its last-access
-- time. Eviction scans the (small, max 8) table for the oldest entry.
-- This avoids the O(n) table.remove mid-array shift of the previous
-- order-list approach, with zero extra allocation per cache hit.
-- ---------------------------------------------------------------------------

local BIM_MAX_COVERS   = 8
-- _bim_cover_cache[key] = { bb = <blitbuffer>, t = <os.time()> }
local _bim_cover_cache = {}
local _bim_cover_count = 0

-- Cached require — resolved once, reused for every cover scale operation.
local _RenderImage = nil

local function _evictOldestCover()
    local oldest_key = nil
    local oldest_t   = math.huge
    for k, entry in pairs(_bim_cover_cache) do
        if entry.t < oldest_t then
            oldest_t   = entry.t
            oldest_key = k
        end
    end
    if oldest_key then
        -- Do NOT call bb:free() here — bitmap may still be referenced by a
        -- live ImageWidget. clearCoverCache() handles explicit freeing.
        _bim_cover_cache[oldest_key] = nil
        _bim_cover_count = _bim_cover_count - 1
    end
end

local function _scaleBBToSlot(bb, target_w, target_h)
    if not _RenderImage then
        local ok, ri = pcall(require, "ui/renderimage")
        if not (ok and ri) then return bb end
        _RenderImage = ri
    end
    local src_w = bb:getWidth()
    local src_h = bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return bb end
    if src_w == target_w and src_h == target_h then return bb end
    -- Use math.max so the image fills the slot completely (cover crop),
    -- rather than math.min which would letterbox/pillarbox with white bars.
    local scale_factor = math.max(target_w / src_w, target_h / src_h)
    local scaled_w = math.floor(src_w * scale_factor + 0.5)
    local scaled_h = math.floor(src_h * scale_factor + 0.5)
    local ok_sc, scaled_bb = pcall(function()
        return _RenderImage:scaleBlitBuffer(bb, scaled_w, scaled_h)
    end)
    if not (ok_sc and scaled_bb) then return bb end
    if scaled_w == target_w and scaled_h == target_h then return scaled_bb end
    -- Crop the oversized scaled bitmap to target_w × target_h from the centre.
    local ok_blit, Blitbuffer_mod = pcall(require, "ffi/blitbuffer")
    if not (ok_blit and Blitbuffer_mod) then return scaled_bb end
    local ok_slot, slot_bb = pcall(function()
        return Blitbuffer_mod.new(target_w, target_h, scaled_bb:getType())
    end)
    if not (ok_slot and slot_bb) then return scaled_bb end
    -- src_x/src_y: offset into the scaled bitmap where the crop starts.
    local src_x = math.floor((scaled_w - target_w) / 2)
    local src_y = math.floor((scaled_h - target_h) / 2)
    pcall(function()
        slot_bb:blitFrom(scaled_bb, 0, 0, src_x, src_y, target_w, target_h)
    end)
    pcall(function() scaled_bb:free() end)
    return slot_bb
end

function M.getCoverBB(filepath, w, h)
    local key    = filepath .. "|" .. w .. "x" .. h
    local cached = _bim_cover_cache[key]
    if cached then
        -- Update LRU access time in-place — no allocation, no list shift.
        cached.t = os.time()
        return cached.bb
    end

    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, true) end)
    if not ok then return nil end

    -- CORREÇÃO: Verificar se a tentativa de extração já foi feita
    if bookinfo and bookinfo.cover_fetched then
        if bookinfo.has_cover and bookinfo.cover_bb then
            local bb = _scaleBBToSlot(bookinfo.cover_bb, w, h)
            if _bim_cover_count >= BIM_MAX_COVERS then _evictOldestCover() end
            _bim_cover_cache[key] = { bb = bb, t = os.time() }
            _bim_cover_count = _bim_cover_count + 1
            return bb
        else
            -- Já tentámos extrair antes e sabemos que não tem capa (ou falhou).
            -- Devolve nil imediatamente para não desencadear um poll loop.
            return nil
        end
    end

    if not M.cover_extraction_pending then
        M.cover_extraction_pending = true
        pcall(function()
            bim:extractInBackground({{
                filepath    = filepath,
                cover_specs = { max_cover_w = w, max_cover_h = h },
            }})
        end)
    end
    return nil
end

-- Releases all cover bitmaps (owned by us — scaled copies).
function M.clearCoverCache()
    for _, entry in pairs(_bim_cover_cache) do
        pcall(function() entry.bb:free() end)
    end
    _bim_cover_cache = {}
    _bim_cover_count = 0
    _RenderImage     = nil
end

-- ---------------------------------------------------------------------------
-- Topbar config cache — shared between topbar.lua and menu.lua so that
-- checked_func callbacks don't rebuild the config table on every render (#16).
-- Invalidated automatically by saveTopbarConfig().
-- ---------------------------------------------------------------------------

local _topbar_cfg_menu_cache = nil

function M.getTopbarConfigCached()
    if not _topbar_cfg_menu_cache then
        _topbar_cfg_menu_cache = M.getTopbarConfig()
    end
    return _topbar_cfg_menu_cache
end

function M.invalidateTopbarConfigCache()
    _topbar_cfg_menu_cache = nil
end
-- ---------------------------------------------------------------------------

local _SQ3     = nil  -- cached ljsqlite3 module
local _lfs_mod = nil  -- cached lfs module

function M.getStatsDbPath()
    return require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
end

-- Opens a new SQLite connection to the statistics DB.
-- Returns the connection on success, or nil on any failure.
function M.openStatsDB()
    if not _SQ3 then
        local ok, s = pcall(require, "lua-ljsqlite3/init")
        if not ok or not s then return nil end
        _SQ3 = s
    end
    if not _lfs_mod then
        local ok, l = pcall(require, "libs/libkoreader-lfs")
        if not ok or not l then return nil end
        _lfs_mod = l
    end
    local db_path = M.getStatsDbPath()
    if not _lfs_mod.attributes(db_path, "mode") then return nil end
    local ok, conn = pcall(function() return _SQ3.open(db_path) end)
    return ok and conn or nil
end

-- ---------------------------------------------------------------------------
-- Collection helpers
-- ---------------------------------------------------------------------------

local _ReadCollection
function M.getReadCollection()
    if not _ReadCollection then
        local ok, rc = pcall(require, "readcollection")
        if ok then _ReadCollection = rc end
    end
    return _ReadCollection
end

function M.getNonFavoritesCollections()
    local rc = M.getReadCollection()
    if not rc then return {} end
    if rc._read then pcall(function() rc:_read() end) end
    local coll = rc.coll
    if not coll then return {} end
    local fav   = rc.default_collection_name or "favorites"
    local names = {}
    for name in pairs(coll) do
        if name ~= fav then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function M.isFavoritesWidget(w)
    if not w or w.name ~= "collections" then return false end
    local rc = M.getReadCollection()
    if not rc then return false end
    return w.path == rc.default_collection_name
end

-- ---------------------------------------------------------------------------
-- Navpager helpers
-- ---------------------------------------------------------------------------

-- Returns true when the navpager mode is active.
-- Reads settings directly (no cache) — called rarely (build time, menu toggle).
function M.isNavpagerEnabled()
    return G_reader_settings:isTrue("folio_navbar_navpager_enabled")
end


-- Returns the effective tab limit for the current mode.
function M.effectiveMaxTabs()
    return M.isNavpagerEnabled() and M.MAX_TABS_NAVPAGER or M.MAX_TABS
end

-- Returns has_prev, has_next by reading the enabled state of the KOReader
-- pagination chevrons from the topmost active pageable widget.
-- This mirrors exactly what KOReader's own pagination bar shows — no
-- reimplementation needed.
--
-- Priority order (top-down on the UIManager stack):
--   1. A Menu/BookList directly on the stack (History, Collections BookList,
--      any fullscreen menu)
--   2. The FM's file_chooser (always a Menu/BookList)
--
-- Returns false, false when no pageable widget is found or when the widget
-- is the homescreen (which has no pagination).
-- Read prev/next state from a menu using page/page_num directly,
-- exactly as KOReader's own pagination bar does in Menu:updatePageInfo().
local function _stateFromMenu(menu)
    if not menu then return nil end
    local page     = menu.page
    local page_num = menu.page_num
    if not (page and page_num) then return nil end
    return page > 1, page < page_num
end

function M.getNavpagerState()
    local UI = package.loaded["folio_core"]
    if not UI then return false, false end
    local stack = UI.getWindowStack()
    local logger = require("logger")

    -- Walk from the top of the stack down, looking for the first
    -- covers_fullscreen widget — that is what the user is seeing.
    -- Non-fullscreen overlays (dialogs, notifications) are transparent:
    -- skip them and keep looking.
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.covers_fullscreen then
            -- Found the topmost fullscreen widget.
            logger.dbg("folio navpager: top fullscreen widget name=",
                tostring(w.name), "has_file_chooser=", tostring(w.file_chooser ~= nil),
                "has_page=", tostring(w.page ~= nil))

            -- Case 1: widget is itself a pageable menu (BookList, History, Collections).
            local prev, nxt = _stateFromMenu(w)
            if prev ~= nil then
                logger.dbg("folio navpager: direct menu =>", tostring(prev), tostring(nxt))
                return prev, nxt
            end

            -- Case 2: FM — the pageable menu is file_chooser inside.
            if w.file_chooser then
                local prev2, nxt2 = _stateFromMenu(w.file_chooser)
                if prev2 ~= nil then
                    logger.dbg("folio navpager: file_chooser =>", tostring(prev2), tostring(nxt2))
                    return prev2, nxt2
                end
            end

            -- Case 3: fullscreen but not pageable (homescreen, ReaderUI, etc.).
            logger.dbg("folio navpager: not pageable -> false,false")
            return false, false
        end
        -- w is nil or not covers_fullscreen: overlay/dialog, keep looking down.
    end
    logger.dbg("folio navpager: stack exhausted -> false,false")
    return false, false
end


-- ---------------------------------------------------------------------------
-- Scale system — module-level and label scale with optional linking.
--
-- Settings layout:
--   folio_navbar_homescreen_module_scale          global module scale (integer %)
--   folio_navbar_homescreen_label_scale           label scale (integer %)
--   folio_navbar_homescreen_<pfx><id>_scale       per-module scale override (integer %)
--   folio_navbar_homescreen_scale_linked          bool; true = all scales move together
--
-- API for modules:
--   Config.getModuleScale(mod_id, pfx)      → float multiplier for build()/getHeight()
--   Config.getModuleScalePct(mod_id, pfx)   → integer % for SpinWidget value
--   Config.setModuleScale(pct, mod_id, pfx) → save individual or global scale
--   Config.getLabelScale()                  → float multiplier for sectionLabel()
--   Config.getLabelScalePct()               → integer %
--   Config.setLabelScale(pct)               → save label scale
--   Config.isScaleLinked()                  → bool
--   Config.setScaleLinked(on)               → save link state
--   Config.getScaledLabelH()                → scaled LABEL_H for getHeight()
-- ---------------------------------------------------------------------------

local SCALE_MIN  = 50
local SCALE_MAX  = 200
local SCALE_STEP = 10
local SCALE_DEF  = 100

local MODULE_SCALE_KEY      = "folio_navbar_homescreen_module_scale"
local LABEL_SCALE_KEY       = "folio_navbar_homescreen_label_scale"
local SCALE_LINKED_KEY      = "folio_navbar_homescreen_scale_linked"
local ITEM_LABEL_SCALE_SUFFIX = "_item_label_scale"

-- Clamp an integer percentage to valid range.
local function _clamp(n)
    return math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(n)))
end

-- Returns the per-module setting key for a given module id and pfx.
local function _modKey(mod_id, pfx)
    return (pfx or "folio_navbar_homescreen_") .. (mod_id or "") .. "_scale"
end

local function _itemLabelKey(mod_id, pfx)
    return (pfx or "folio_navbar_homescreen_") .. (mod_id or "") .. ITEM_LABEL_SCALE_SUFFIX
end

-- ---------------------------------------------------------------------------
-- Bar size (bottom bar) — numeric % stored as "folio_navbar_bar_size_pct"
-- Legacy string key ("folio_navbar_bar_size") is ignored; we read/write the pct key.
-- ---------------------------------------------------------------------------

local BAR_SIZE_KEY     = "folio_navbar_bar_size_pct"
local BAR_SIZE_DEF     = 100
local BAR_SIZE_MIN     = 50
local BAR_SIZE_MAX     = 150

function M.getBarSizePct()
    local v = G_reader_settings:readSetting(BAR_SIZE_KEY)
    local n = tonumber(v)
    if not n then return BAR_SIZE_DEF end
    return math.max(BAR_SIZE_MIN, math.min(BAR_SIZE_MAX, math.floor(n)))
end

function M.setBarSizePct(pct)
    G_reader_settings:saveSetting(BAR_SIZE_KEY,
        math.max(BAR_SIZE_MIN, math.min(BAR_SIZE_MAX, math.floor(pct))))
end

M.BAR_SIZE_DEF  = BAR_SIZE_DEF
M.BAR_SIZE_MIN  = BAR_SIZE_MIN
M.BAR_SIZE_MAX  = BAR_SIZE_MAX
M.BAR_SIZE_STEP = SCALE_STEP

-- ---------------------------------------------------------------------------
-- Topbar size — numeric % stored as "folio_navbar_topbar_size_pct"
-- ---------------------------------------------------------------------------

local TOPBAR_SIZE_KEY = "folio_navbar_topbar_size_pct"
local TOPBAR_SIZE_DEF = 100
local TOPBAR_SIZE_MIN = 50
local TOPBAR_SIZE_MAX = 150

function M.getTopbarSizePct()
    local v = G_reader_settings:readSetting(TOPBAR_SIZE_KEY)
    local n = tonumber(v)
    if not n then return TOPBAR_SIZE_DEF end
    return math.max(TOPBAR_SIZE_MIN, math.min(TOPBAR_SIZE_MAX, math.floor(n)))
end

function M.setTopbarSizePct(pct)
    G_reader_settings:saveSetting(TOPBAR_SIZE_KEY,
        math.max(TOPBAR_SIZE_MIN, math.min(TOPBAR_SIZE_MAX, math.floor(pct))))
end

M.TOPBAR_SIZE_DEF  = TOPBAR_SIZE_DEF
M.TOPBAR_SIZE_MIN  = TOPBAR_SIZE_MIN
M.TOPBAR_SIZE_MAX  = TOPBAR_SIZE_MAX
M.TOPBAR_SIZE_STEP = SCALE_STEP

-- ---------------------------------------------------------------------------
-- Reading Stats text scale — multiplicative on top of module scale.
-- Stored as "folio_navbar_rs_text_scale_pct" (integer %).
-- ---------------------------------------------------------------------------

local RS_TEXT_SCALE_KEY  = "folio_navbar_rs_text_scale_pct"
local RS_TEXT_SCALE_DEF  = 100
local RS_TEXT_SCALE_MIN  = 50
local RS_TEXT_SCALE_MAX  = 200

function M.getRSTextScalePct()
    local v = G_reader_settings:readSetting(RS_TEXT_SCALE_KEY)
    local n = tonumber(v)
    if not n then return RS_TEXT_SCALE_DEF end
    return math.max(RS_TEXT_SCALE_MIN, math.min(RS_TEXT_SCALE_MAX, math.floor(n)))
end

function M.setRSTextScalePct(pct)
    G_reader_settings:saveSetting(RS_TEXT_SCALE_KEY,
        math.max(RS_TEXT_SCALE_MIN, math.min(RS_TEXT_SCALE_MAX, math.floor(pct))))
end

M.RS_TEXT_SCALE_DEF  = RS_TEXT_SCALE_DEF
M.RS_TEXT_SCALE_MIN  = RS_TEXT_SCALE_MIN
M.RS_TEXT_SCALE_MAX  = RS_TEXT_SCALE_MAX
M.RS_TEXT_SCALE_STEP = SCALE_STEP

-- ---------------------------------------------------------------------------
-- Navbar icon scale — multiplicative on top of bar scale.
-- Stored as \"folio_navbar_icon_scale_pct\" (integer %).
-- ---------------------------------------------------------------------------

local ICON_SCALE_KEY  = "folio_navbar_icon_scale_pct"
local ICON_SCALE_DEF  = 100
local ICON_SCALE_MIN  = 50
local ICON_SCALE_MAX  = 200

function M.getIconScalePct()
    local v = G_reader_settings:readSetting(ICON_SCALE_KEY)
    local n = tonumber(v)
    if not n then return ICON_SCALE_DEF end
    return math.max(ICON_SCALE_MIN, math.min(ICON_SCALE_MAX, math.floor(n)))
end

function M.setIconScalePct(pct)
    G_reader_settings:saveSetting(ICON_SCALE_KEY,
        math.max(ICON_SCALE_MIN, math.min(ICON_SCALE_MAX, math.floor(pct))))
end

M.ICON_SCALE_DEF  = ICON_SCALE_DEF
M.ICON_SCALE_MIN  = ICON_SCALE_MIN
M.ICON_SCALE_MAX  = ICON_SCALE_MAX
M.ICON_SCALE_STEP = SCALE_STEP

-- ---------------------------------------------------------------------------
-- Navbar label scale — multiplicative on top of bar scale.
-- Stored as \"folio_navbar_label_scale_pct\" (integer %).
-- ---------------------------------------------------------------------------

local LABEL_SCALE_KEY  = "folio_navbar_label_scale_pct"
local LABEL_SCALE_DEF  = 100
local LABEL_SCALE_MIN  = 50
local LABEL_SCALE_MAX  = 200

function M.getLabelScalePct()
    local v = G_reader_settings:readSetting(LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return LABEL_SCALE_DEF end
    return math.max(LABEL_SCALE_MIN, math.min(LABEL_SCALE_MAX, math.floor(n)))
end

function M.setLabelScalePct(pct)
    G_reader_settings:saveSetting(LABEL_SCALE_KEY,
        math.max(LABEL_SCALE_MIN, math.min(LABEL_SCALE_MAX, math.floor(pct))))
end

M.LABEL_SCALE_DEF  = LABEL_SCALE_DEF
M.LABEL_SCALE_MIN  = LABEL_SCALE_MIN
M.LABEL_SCALE_MAX  = LABEL_SCALE_MAX
M.LABEL_SCALE_STEP = SCALE_STEP

-- ---------------------------------------------------------------------------
-- Link flag
-- ---------------------------------------------------------------------------

function M.isScaleLinked()
    local v = G_reader_settings:readSetting(SCALE_LINKED_KEY)
    return v ~= false  -- default true
end

function M.setScaleLinked(on)
    G_reader_settings:saveSetting(SCALE_LINKED_KEY, on)
end

-- ---------------------------------------------------------------------------
-- Module scale
-- ---------------------------------------------------------------------------

-- Returns float multiplier.
-- If mod_id + pfx given and link is OFF, reads the per-module override first.
function M.getModuleScale(mod_id, pfx)
    if mod_id and pfx and not M.isScaleLinked() then
        local v = G_reader_settings:readSetting(_modKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clamp(n) / 100 end
    end
    local v = G_reader_settings:readSetting(MODULE_SCALE_KEY)
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

-- Returns integer %.
function M.getModuleScalePct(mod_id, pfx)
    if mod_id and pfx and not M.isScaleLinked() then
        local v = G_reader_settings:readSetting(_modKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clamp(n) end
    end
    local v = G_reader_settings:readSetting(MODULE_SCALE_KEY)
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

-- Save scale.
-- If mod_id + pfx given → individual; otherwise global.
-- When saving the global and link is ON, also syncs the label scale.
function M.setModuleScale(pct, mod_id, pfx)
    pct = _clamp(pct)
    if mod_id and pfx then
        G_reader_settings:saveSetting(_modKey(mod_id, pfx), pct)
    else
        G_reader_settings:saveSetting(MODULE_SCALE_KEY, pct)
        if M.isScaleLinked() then
            G_reader_settings:saveSetting(LABEL_SCALE_KEY, pct)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Thumbnail scale (independent of module scale)
-- Controls cover/thumbnail dimensions only; text and gaps follow module scale.
-- Setting key: <pfx><mod_id>_thumb_scale
-- ---------------------------------------------------------------------------

local THUMB_SCALE_KEY_SUFFIX = "_thumb_scale"

local function _thumbKey(mod_id, pfx)
    return (pfx or "folio_navbar_homescreen_") .. (mod_id or "") .. THUMB_SCALE_KEY_SUFFIX
end

function M.getThumbScale(mod_id, pfx)
    local v = G_reader_settings:readSetting(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getThumbScalePct(mod_id, pfx)
    local v = G_reader_settings:readSetting(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setThumbScale(pct, mod_id, pfx)
    G_reader_settings:saveSetting(_thumbKey(mod_id, pfx), _clamp(pct))
end

-- ---------------------------------------------------------------------------
-- Label scale
-- ---------------------------------------------------------------------------

function M.getLabelScale()
    local v = G_reader_settings:readSetting(LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getLabelScalePct()
    local v = G_reader_settings:readSetting(LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setLabelScale(pct)
    G_reader_settings:saveSetting(LABEL_SCALE_KEY, _clamp(pct))
end

-- Returns the scaled LABEL_H value for module getHeight() calls.
local _BASE_LABEL_TEXT_H = nil
function M.getScaledLabelH()
    if not _BASE_LABEL_TEXT_H then
        _BASE_LABEL_TEXT_H = require("device").screen:scaleBySize(16)
    end
    local PAD2  = require("folio_core").PAD2
    local scale = M.getLabelScale()
    return PAD2 + math.max(8, math.floor(_BASE_LABEL_TEXT_H * scale))
end

-- ---------------------------------------------------------------------------
-- Item label scale (text inside module cards: collection name, book title, etc.)
-- Per-module setting: <pfx><mod_id>_item_label_scale
-- ---------------------------------------------------------------------------

function M.getItemLabelScale(mod_id, pfx)
    local v = G_reader_settings:readSetting(_itemLabelKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getItemLabelScalePct(mod_id, pfx)
    local v = G_reader_settings:readSetting(_itemLabelKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setItemLabelScale(pct, mod_id, pfx)
    G_reader_settings:saveSetting(_itemLabelKey(mod_id, pfx), _clamp(pct))
end

-- ---------------------------------------------------------------------------
-- Reset all scales to default (100%)
-- Clears global module scale, label scale, all per-module overrides,
-- all thumb scales, all item label scales, and bar/topbar sizes.
-- ---------------------------------------------------------------------------

function M.resetAllScales(pfx, pfx_qa)
    -- Global scales
    G_reader_settings:delSetting(MODULE_SCALE_KEY)
    G_reader_settings:delSetting(LABEL_SCALE_KEY)
    G_reader_settings:delSetting(SCALE_LINKED_KEY)
    G_reader_settings:delSetting(BAR_SIZE_KEY)
    G_reader_settings:delSetting(TOPBAR_SIZE_KEY)
    -- Per-module overrides
    local Registry = require("desktop_modules/moduleregistry")
    for _, mod in ipairs(Registry.list()) do
        if mod.id then
            G_reader_settings:delSetting((pfx or "folio_navbar_homescreen_") .. mod.id .. "_scale")
            G_reader_settings:delSetting((pfx or "folio_navbar_homescreen_") .. mod.id .. THUMB_SCALE_KEY_SUFFIX)
            G_reader_settings:delSetting(_itemLabelKey(mod.id, pfx))
        end
    end
    -- Quick actions per-slot overrides
    if pfx_qa then
        for slot = 1, 3 do
            G_reader_settings:delSetting(pfx_qa .. slot .. "_scale")
            G_reader_settings:delSetting(pfx_qa .. slot .. ITEM_LABEL_SCALE_SUFFIX)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Exported constants
-- ---------------------------------------------------------------------------

M.SCALE_MIN  = SCALE_MIN
M.SCALE_MAX  = SCALE_MAX
M.SCALE_STEP = SCALE_STEP
M.SCALE_DEF  = SCALE_DEF
-- Keep legacy aliases so any existing external code keeps working.
M.MODULE_SCALE_MIN  = SCALE_MIN
M.MODULE_SCALE_MAX  = SCALE_MAX
M.MODULE_SCALE_STEP = SCALE_STEP
M.MODULE_SCALE_DEF  = SCALE_DEF
M.LABEL_SCALE_MIN   = SCALE_MIN
M.LABEL_SCALE_MAX   = SCALE_MAX
M.LABEL_SCALE_STEP  = SCALE_STEP
M.LABEL_SCALE_DEF   = SCALE_DEF

-- ---------------------------------------------------------------------------
-- makeScaleItem — centralised SpinWidget menu-item factory.
--
-- Generates a complete menu item that opens a SpinWidget, keeping the parent
-- menu open (keep_menu_open = true) so the menu stays visible while the
-- spinner floats on top.
--
-- Required fields in opts:
--   text_func   function()→string   label shown in the menu row
--   title       string              SpinWidget title bar
--   info        string              SpinWidget description
--   get         function()→number   returns current pct value
--   set         function(pct)       saves new pct value
--   refresh     function()          redraws after apply
--
-- Optional fields:
--   separator    boolean            grey bar after this item
--   enabled_func function()→bool    greys out when false
--   value_min    number             override SCALE_MIN
--   value_max    number             override SCALE_MAX
--   value_step   number             override SCALE_STEP
--   default_value number            override SCALE_DEF
-- ---------------------------------------------------------------------------
function M.makeScaleItem(opts)
    -- When an enabled_func is provided the item is guarded: if the condition
    -- is false the callback shows an explanatory message instead of the spinner.
    -- We intentionally do NOT set enabled_func on the returned item — the KOReader
    -- Menu widget blocks taps on dim items before our onMenuSelect runs, so the
    -- warning would never be shown. The guard inside the callback handles it.
    local enabled_func = opts.enabled_func
    return {
        text_func      = opts.text_func,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        callback       = function()
            if enabled_func and not enabled_func() then
                local UIManager   = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text    = _("Disable \"Lock Scale\" first to set a per-module scale."),
                    timeout = 3,
                })
                return
            end
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title,
                info_text     = opts.info,
                value         = opts.get(),
                value_min     = opts.value_min   or SCALE_MIN,
                value_max     = opts.value_max   or SCALE_MAX,
                value_step    = opts.value_step  or SCALE_STEP,
                unit          = "%",
                ok_text       = _("Apply"),
                cancel_text   = _("Cancel"),
                default_value = opts.default_value or SCALE_DEF,
                callback      = function(spin)
                    opts.set(spin.value)
                    opts.refresh()
                end,
            })
        end,
    }
end


-- ---------------------------------------------------------------------------
-- Per-module gap — vertical space above each module.
-- Setting key: <pfx><mod_id>_gap_pct  (integer %, default 100)
-- 100% = MOD_GAP; 0% = no gap.
-- ---------------------------------------------------------------------------

local GAP_MIN  = 0
local GAP_MAX  = 300
local GAP_STEP = 10
local GAP_DEF  = 100

M.GAP_MIN  = GAP_MIN
M.GAP_MAX  = GAP_MAX
M.GAP_STEP = GAP_STEP
M.GAP_DEF  = GAP_DEF

local function _gapKey(mod_id, pfx)
    return (pfx or "folio_navbar_homescreen_") .. (mod_id or "") .. "_gap_pct"
end

local function _clampGap(n)
    return math.max(GAP_MIN, math.min(GAP_MAX, math.floor(n)))
end

-- Returns gap in pixels. Falls back to mod_gap_px when no setting is saved.
function M.getModuleGapPx(mod_id, pfx, mod_gap_px)
    if mod_id and pfx then
        local v = G_reader_settings:readSetting(_gapKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return math.floor(mod_gap_px * _clampGap(n) / 100) end
    end
    return mod_gap_px
end

-- Returns integer % for SpinWidget.
function M.getModuleGapPct(mod_id, pfx)
    if mod_id and pfx then
        local v = G_reader_settings:readSetting(_gapKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clampGap(n) end
    end
    return GAP_DEF
end

-- Saves gap %.
function M.setModuleGap(pct, mod_id, pfx)
    if mod_id and pfx then
        G_reader_settings:saveSetting(_gapKey(mod_id, pfx), _clampGap(pct))
    end
end

-- Menu-item factory for the gap SpinWidget, matching makeScaleItem's pattern.
function M.makeGapItem(opts)
    return {
        text_func      = opts.text_func,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        callback       = function()
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title,
                info_text     = opts.info,
                value         = opts.get(),
                value_min     = GAP_MIN,
                value_max     = GAP_MAX,
                value_step    = GAP_STEP,
                unit          = "%",
                ok_text       = _("Apply"),
                cancel_text   = _("Cancel"),
                default_value = GAP_DEF,
                callback      = function(spin)
                    opts.set(spin.value)
                    opts.refresh()
                end,
            })
        end,
    }
end

-- ---------------------------------------------------------------------------
-- One-time migration: legacy `navbar_*` → `folio_navbar_*`, and `sui_navbar_*` → `folio_navbar_*`.
-- Safe to run every boot: only copies when the new key is unset.
-- ---------------------------------------------------------------------------

function M.migrateLegacySettingsKeysToFolioPrefix()
    if G_reader_settings:isTrue("folio_plugin_settings_migrated_v1") then return end
    local map = {
        { "navbar_topbar_config",                "folio_navbar_topbar_config" },
        { "navbar_custom_qa_list",               "folio_navbar_custom_qa_list" },
        { "navbar_tabs",                         "folio_navbar_tabs" },
        { "navbar_mode",                         "folio_navbar_mode" },
        { "navbar_enabled",                      "folio_navbar_enabled" },
        { "navbar_topbar_enabled",               "folio_navbar_topbar_enabled" },
        { "navbar_bar_size",                     "folio_navbar_bar_size" },
        { "navbar_bar_size_pct",                 "folio_navbar_bar_size_pct" },
        { "navbar_topbar_size_pct",              "folio_navbar_topbar_size_pct" },
        { "navbar_pagination_visible",           "folio_navbar_pagination_visible" },
        { "navbar_navpager_enabled",             "folio_navbar_navpager_enabled" },
        { "navbar_pagination_size",              "folio_navbar_pagination_size" },
        { "navbar_pagination_show_subtitle",     "folio_navbar_pagination_show_subtitle" },
        { "navbar_topbar_swipe_indicator",       "folio_navbar_topbar_swipe_indicator" },
        { "navbar_hide_separator",               "folio_navbar_hide_separator" },
        { "navbar_homescreen_enabled",           "folio_navbar_homescreen_enabled" },
        { "navbar_reading_goal",                 "folio_navbar_reading_goal" },
        { "navbar_reading_goal_physical",         "folio_navbar_reading_goal_physical" },
        { "navbar_daily_reading_goal_secs",      "folio_navbar_daily_reading_goal_secs" },
        { "navbar_custom_qa_migrated_v1",        "folio_navbar_custom_qa_migrated_v1" },
        { "navbar_reading_goals_show_annual",    "folio_navbar_reading_goals_show_annual" },
        { "navbar_reading_goals_show_daily",     "folio_navbar_reading_goals_show_daily" },
        { "navbar_reading_goals_layout",         "folio_navbar_reading_goals_layout" },
        { "navbar_rs_text_scale_pct",            "folio_navbar_rs_text_scale_pct" },
        { "navbar_icon_scale_pct",               "folio_navbar_icon_scale_pct" },
        { "navbar_label_scale_pct",              "folio_navbar_label_scale_pct" },
        { "navbar_collections_list",             "folio_navbar_collections_list" },
        { "navbar_collections_covers",           "folio_navbar_collections_covers" },
        { "navbar_collections_badge_position",   "folio_navbar_collections_badge_position" },
        { "navbar_homescreen_no_module_limit",    "folio_navbar_homescreen_no_module_limit" },
        { "simpleui_enabled",                     "folio_enabled" },
        { "simpleui_defaults_v1",                 "folio_defaults_v1" },
        { "simpleui_defaults_v2",                 "folio_defaults_v2" },
        { "simpleui_tb_item_search_button",       "folio_tb_item_search_button" },
        { "simpleui_tb_fm_cfg",                   "folio_tb_fm_cfg" },
        { "simpleui_loaded_version",              "folio_loaded_version" },
        { "simpleui_fc_enabled",                  "folio_fc_enabled" },
        { "simpleui_fc_show_name",                "folio_fc_show_name" },
        { "simpleui_fc_hide_underline",           "folio_fc_hide_underline" },
        { "simpleui_fc_label_style",              "folio_fc_label_style" },
        { "simpleui_fc_label_position",           "folio_fc_label_position" },
        { "simpleui_fc_badge_position",           "folio_fc_badge_position" },
        { "simpleui_fc_covers",                   "folio_fc_covers" },
        { "simpleui_titlebar_custom",             "folio_titlebar_custom" },
        { "simpleui_tb_inj_cfg",                  "folio_tb_inj_cfg" },
        { "simpleui_tb_size",                     "folio_tb_size" },
    }
    for _, e in ipairs(map) do
        local old_k, new_k = e[1], e[2]
        local v = G_reader_settings:readSetting(old_k)
        if v ~= nil and G_reader_settings:readSetting(new_k) == nil then
            G_reader_settings:saveSetting(new_k, v)
            G_reader_settings:delSetting(old_k)
        end
    end
    -- Phase 10 installs used `sui_navbar_*` before the Folio rename; copy into `folio_navbar_*`.
    for _, e in ipairs(map) do
        local old_k, new_k = e[1], e[2]
        local rest = old_k:match("^navbar_(.*)$")
        if rest then
            local sui_old = "sui_navbar_" .. rest
            local v = G_reader_settings:readSetting(sui_old)
            if v ~= nil and G_reader_settings:readSetting(new_k) == nil then
                G_reader_settings:saveSetting(new_k, v)
                G_reader_settings:delSetting(sui_old)
            end
        end
    end
    -- Top-level `sui_*` keys (not navbar-prefixed in map)
    local sui_top = {
        { "sui_enabled", "folio_enabled" },
        { "sui_loaded_version", "folio_loaded_version" },
        { "sui_plugin_settings_migrated_v1", "folio_plugin_settings_migrated_v1" },
        { "sui_defaults_v1", "folio_defaults_v1" },
        { "sui_defaults_v2", "folio_defaults_v2" },
        { "sui_tb_item_search_button", "folio_tb_item_search_button" },
        { "sui_tb_fm_cfg", "folio_tb_fm_cfg" },
        { "sui_fc_enabled", "folio_fc_enabled" },
        { "sui_fc_show_name", "folio_fc_show_name" },
        { "sui_fc_hide_underline", "folio_fc_hide_underline" },
        { "sui_fc_label_style", "folio_fc_label_style" },
        { "sui_fc_label_position", "folio_fc_label_position" },
        { "sui_fc_badge_position", "folio_fc_badge_position" },
        { "sui_fc_covers", "folio_fc_covers" },
        { "sui_titlebar_custom", "folio_titlebar_custom" },
        { "sui_tb_inj_cfg", "folio_tb_inj_cfg" },
        { "sui_tb_size", "folio_tb_size" },
    }
    for _, e in ipairs(sui_top) do
        local old_k, new_k = e[1], e[2]
        local v = G_reader_settings:readSetting(old_k)
        if v ~= nil and G_reader_settings:readSetting(new_k) == nil then
            G_reader_settings:saveSetting(new_k, v)
            G_reader_settings:delSetting(old_k)
        end
    end
    local list = G_reader_settings:readSetting("folio_navbar_custom_qa_list")
        or G_reader_settings:readSetting("navbar_custom_qa_list") or {}
    if type(list) == "table" then
        for _, qa_id in ipairs(list) do
            if type(qa_id) == "string" then
                local old_k = "navbar_cqa_" .. qa_id
                local new_k = "folio_navbar_cqa_" .. qa_id
                local v = G_reader_settings:readSetting(old_k)
                if v ~= nil and G_reader_settings:readSetting(new_k) == nil then
                    G_reader_settings:saveSetting(new_k, v)
                    G_reader_settings:delSetting(old_k)
                end
            end
        end
    end
    for _, id in ipairs({ "home", "homescreen", "collections", "history", "continue", "favorites",
            "bookmark_browser", "wifi_toggle", "frontlight", "stats_calendar", "power" }) do
        for _, suf in ipairs({ "label", "icon" }) do
            local old_k = "navbar_action_" .. id .. "_" .. suf
            local new_k = "folio_navbar_action_" .. id .. "_" .. suf
            local v = G_reader_settings:readSetting(old_k)
            if v ~= nil and G_reader_settings:readSetting(new_k) == nil then
                G_reader_settings:saveSetting(new_k, v)
                G_reader_settings:delSetting(old_k)
            end
        end
    end
    G_reader_settings:saveSetting("folio_plugin_settings_migrated_v1", true)
end

return M
