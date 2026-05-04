-- config.lua — Simple UI
-- Plugin-wide constants, action catalogue, tab/topbar configuration,
-- custom Quick Actions and settings migration.

local G_reader_settings = G_reader_settings
local logger            = require("logger")
local _ = require("sui_i18n").translate

-- ---------------------------------------------------------------------------
-- Public constants
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Icon path registry — single source of truth for every SVG used by the plugin.
--
-- Two prefixes exist:
--   _P  = "plugins/simpleui.koplugin/icons/"   (own assets)
--   _KO = "resources/icons/mdlight/"            (KOReader built-in assets)
--
-- All modules must reference M.ICON.<key> instead of bare string literals.
-- Adding or renaming an icon only requires editing this one table.
-- ---------------------------------------------------------------------------

-- Resolve the plugin's own directory at load time so icon paths are absolute.
-- On Android/Nook the working directory is not the KOReader root, so relative
-- paths like "plugins/simpleui.koplugin/icons/..." silently fail to resolve
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
    if lfs_ok and lfs_m then
        local function _is_root(dir)
            return lfs_m.attributes(dir .. "/resources/icons/mdlight", "mode") == "directory"
        end
        if _is_root(_d) then
            _ko_root = _d .. "/"
        else
            local parent = _d:match("^(.+)/[^/]+$")
            if parent and _is_root(parent) then
                _ko_root = parent .. "/"
            end
        end
    end
end
if _ko_root == "" then
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m then
        local p = (_plugin_dir:gsub("/$", ""))
        for _i = 1, 8 do
            if lfs_m.attributes(p .. "/resources/icons/mdlight", "mode") == "directory" then
                _ko_root = p .. "/"
                break
            end
            local parent = p:match("^(.+)/[^/]+$")
            if not parent or parent == p then break end
            p = parent
        end
    end
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
    author         = _P .. "author.svg",
    series         = _P .. "series.svg",

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
M.MAX_CUSTOM_QA          = 24
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
    { id = "browse_authors",   label = _("Authors"),          icon = M.ICON.author,
      browsemeta_mode = "author" },
    { id = "browse_series",    label = _("Series"),           icon = M.ICON.series,
      browsemeta_mode = "series" },
}

-- Fast lookup map keyed by action ID.
M.ACTION_BY_ID = {}
for _i, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- ---------------------------------------------------------------------------
-- Topbar configuration
-- ---------------------------------------------------------------------------

M.TOPBAR_ITEMS = { "clock", "wifi", "brightness", "battery", "disk", "ram", "custom_text" }

local _topbar_item_labels = nil

function M.TOPBAR_ITEM_LABEL(k)
    if not _topbar_item_labels then
        _topbar_item_labels = {
            clock       = _("Clock"),
            wifi        = _("WiFi"),
            brightness  = _("Brightness"),
            battery     = _("Battery"),
            disk        = _("Disk Usage"),
            ram         = _("RAM Usage"),
            custom_text = _("Custom Text"),
        }
    end
    return _topbar_item_labels[k] or k
end

-- Custom text item for the topbar.
-- Stored as a plain string; empty string = item produces no output.
local TOPBAR_CUSTOM_TEXT_MAX = 32

M.TOPBAR_CUSTOM_TEXT_MAX = TOPBAR_CUSTOM_TEXT_MAX

function M.getTopbarCustomText()
    return G_reader_settings:readSetting("navbar_topbar_custom_text") or ""
end

function M.setTopbarCustomText(s)
    if type(s) == "string" then
        -- Enforce character limit on save (UTF-8 codepoints).
        local count, i, out = 0, 1, {}
        while i <= #s do
            local byte = s:byte(i)
            local clen = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
            count = count + 1
            if count > TOPBAR_CUSTOM_TEXT_MAX then break end
            out[#out + 1] = s:sub(i, i + clen - 1)
            i = i + clen
        end
        s = table.concat(out)
    else
        s = ""
    end
    G_reader_settings:saveSetting("navbar_topbar_custom_text", s)
end

-- Returns the normalised topbar config, migrating legacy formats when needed.
function M.getTopbarConfig()
    local raw = G_reader_settings:readSetting("navbar_topbar_config")
    local cfg = { side = {}, order_left = {}, order_right = {}, order_center = {}, show = {}, order = {} }
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
        if type(raw.order_center) == "table" then
            for _i, v in ipairs(raw.order_center) do cfg.order_center[#cfg.order_center + 1] = v end
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
    -- Sync order_center from side map (items assigned to "center")
    if #cfg.order_center == 0 then
        for k, s in pairs(cfg.side) do
            if s == "center" then cfg.order_center[#cfg.order_center + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    G_reader_settings:saveSetting("navbar_topbar_config", cfg)
    M.invalidateTopbarConfigCache()
    -- Also invalidate topbar.lua's own local config cache so that
    -- buildTopbarWidget() uses the new config immediately on the next rebuild.
    local tb = package.loaded["sui_topbar"]
    if tb and tb.invalidateConfigCache then tb.invalidateConfigCache() end
end

-- ---------------------------------------------------------------------------
-- Custom Quick Actions
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Custom Quick Actions persistence
-- The authoritative implementations live in sui_quickactions to keep all QA
-- logic in one place. These thin wrappers preserve the Config.* call sites
-- in sui_menu.lua, sui_patches.lua, main.lua and migrateOldCustomSlots.
-- ---------------------------------------------------------------------------
local function _QA_lazy()
    return package.loaded["sui_quickactions"] or require("sui_quickactions")
end
function M.getCustomQAList()         return _QA_lazy().getCustomQAList()                                                              end
function M.saveCustomQAList(list)    return _QA_lazy().saveCustomQAList(list)                                                         end
function M.getCustomQAConfig(id)     return _QA_lazy().getCustomQAConfig(id)                                                          end
function M.saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da)
                                     return _QA_lazy().saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da)                    end
function M.deleteCustomQA(id)        return _QA_lazy().deleteCustomQA(id)                                                             end
function M.purgeQACollection(coll)   return _QA_lazy().purgeQACollection(coll)                                                        end
function M.renameQACollection(o, n)  return _QA_lazy().renameQACollection(o, n)                                                       end
function M.sanitizeQASlots()         return _QA_lazy().sanitizeQASlots()                                                              end
function M.nextCustomQAId()          return _QA_lazy().nextCustomQAId()                                                               end

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
    local cfg = G_reader_settings:readSetting("navbar_tabs")
    local result = {}
    local min_tabs = M.isNavpagerEnabled() and 1 or 2
    if type(cfg) == "table" and #cfg >= min_tabs and #cfg <= M.effectiveMaxTabs() then
        for i = 1, #cfg do
            local id = cfg[i]
            if M.ACTION_BY_ID[id] or id:match("^custom_qa_%d+$") then
                result[#result + 1] = id
            else
                logger.warn("simpleui: loadTabConfig: ignoring unknown tab id: " .. tostring(id))
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
    G_reader_settings:saveSetting("navbar_tabs", tabs)
end

function M.getNumTabs()
    -- Read the cache directly to avoid any table allocation (P2).
    if _tabs_cache then return #_tabs_cache end
    return #M.loadTabConfig()
end

-- Cached navbar mode — "both", "icons", or "text".
-- Invalidated by saveNavbarMode() whenever the user changes the setting.
local _navbar_mode_cache = nil

function M.getNavbarMode()
    if not _navbar_mode_cache then
        _navbar_mode_cache = G_reader_settings:readSetting("navbar_mode") or "both"
    end
    return _navbar_mode_cache
end

function M.saveNavbarMode(mode)
    _navbar_mode_cache = nil
    G_reader_settings:saveSetting("navbar_mode", mode)
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
M.wifi_optimistic    = nil
M.wifi_broadcast_self = nil

-- Hide the Wi-Fi icon when Wi-Fi is off (instead of showing the off icon).
function M.getWifiHideWhenOff()
    return G_reader_settings:isTrue("navbar_topbar_wifi_hide_when_off")
end
function M.setWifiHideWhenOff(v)
    G_reader_settings:saveSetting("navbar_topbar_wifi_hide_when_off", v)
end

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
    -- Delegate to sui_quickactions — single source of truth for label/icon
    -- resolution (applies overrides, custom QA configs, wifi state, etc.).
    -- Lazy-loaded to avoid a circular require at module load time.
    local QA = package.loaded["sui_quickactions"]
        or require("sui_quickactions")
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
-- sui_quickactions to avoid circular requires. These thin wrappers keep
-- backwards compatibility for any caller that uses Config.* directly.
function M.getDefaultActionLabel(id)
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    return QA.getDefaultActionLabel(id)
end
function M.getDefaultActionIcon(id)
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    return QA.getDefaultActionIcon(id)
end
function M.setDefaultActionLabel(id, label)
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    QA.setDefaultActionLabel(id, label)
end
function M.setDefaultActionIcon(id, icon)
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    QA.setDefaultActionIcon(id, icon)
end

function M.sanitizeLabel(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    if #s > M.MAX_LABEL_LEN then s = s:sub(1, M.MAX_LABEL_LEN) end
    return s
end

-- ---------------------------------------------------------------------------
-- Nerd Font icon helpers
--
-- Nerd Font icons are stored as the sentinel string "nerd:XXXX" where XXXX
-- is a 1–6 digit hexadecimal Unicode codepoint (e.g. "nerd:E001").
-- This keeps the icon field a plain string and requires no schema changes.
-- The symbols.ttf file shipped with KOReader is registered by the Font module
-- under the face name "symbols" and covers the full Nerd Fonts symbol range.
-- ---------------------------------------------------------------------------

-- Converts a "nerd:XXXX" sentinel to its UTF-8 encoded character.
-- Returns the UTF-8 string on success, or nil if the value is not a Nerd icon.
function M.nerdIconChar(icon_value)
    if type(icon_value) ~= "string" then return nil end
    local hex = icon_value:match("^nerd:([0-9A-Fa-f]+)$")
    if not hex then return nil end
    local cp = tonumber(hex, 16)
    if not cp or cp < 0 or cp > 0x10FFFF then return nil end
    -- Encode as UTF-8.
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40))
    else
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor((cp % 0x40000) / 0x1000),
            0x80 + math.floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40))
    end
end

-- Returns true when icon_value is a valid Nerd Font sentinel.
function M.isNerdIcon(icon_value)
    return M.nerdIconChar(icon_value) ~= nil
end

function M.migrateOldCustomSlots()
    if G_reader_settings:readSetting("navbar_custom_qa_migrated_v1") then return end
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
            logger.info("simpleui: migrated " .. old_id .. " -> " .. new_id)
        end
    end

    M.saveCustomQAList(qa_list)

    local tabs = G_reader_settings:readSetting("navbar_tabs")
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
        if changed then G_reader_settings:saveSetting("navbar_tabs", new_tabs) end
    end

    for slot = 1, 3 do
        local key = "navbar_homescreen_quick_actions_" .. slot .. "_items"
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

    G_reader_settings:saveSetting("navbar_custom_qa_migrated_v1", true)

    local legacy_enabled = G_reader_settings:readSetting("navbar_enabled")
    if legacy_enabled ~= nil and G_reader_settings:readSetting("simpleui_enabled") == nil then
        G_reader_settings:saveSetting("simpleui_enabled", legacy_enabled)
    end
end

-- ---------------------------------------------------------------------------
-- First-run defaults — written once on fresh install, never overwritten.
-- Guard key: "simpleui_defaults_v1". Idempotent: safe to call on every init.
-- ---------------------------------------------------------------------------

function M.applyFirstRunDefaults()
    if not G_reader_settings:readSetting("simpleui_defaults_v1") then
        -- Bottom bar
        G_reader_settings:saveSetting("navbar_enabled",        true)
        G_reader_settings:saveSetting("navbar_topbar_enabled", true)
        G_reader_settings:saveSetting("navbar_mode",           "both")
        G_reader_settings:saveSetting("navbar_bar_size",       "default")
        G_reader_settings:saveSetting("navbar_tabs",
            { "home", "homescreen", "history", "continue", "power" })

        -- Top bar: clock left, battery + wifi right; rest hidden
        M.saveTopbarConfig({
            side        = { clock = "left", battery = "right", wifi = "right" },
            order_left  = { "clock" },
            order_right = { "wifi", "battery" },
        })

        -- Homescreen modules: header + currently + recent on; everything else off
        local PFX = "navbar_homescreen_"
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

        G_reader_settings:saveSetting("simpleui_defaults_v1", true)
    end

    -- ---------------------------------------------------------------------------
    -- v2 migration: apply titlebar layout with search button visible on the left.
    -- Runs once on existing installs that already have simpleui_defaults_v1 set.
    -- Guard key: "simpleui_defaults_v2". Safe to call on every init.
    -- ---------------------------------------------------------------------------
    if not G_reader_settings:readSetting("simpleui_defaults_v2") then
        -- Visibility: search button on
        G_reader_settings:saveSetting("simpleui_tb_item_search_button", true)
        -- FM layout: up_button left slot-0, search_button left slot-1, menu_button right
        G_reader_settings:saveSetting("simpleui_tb_fm_cfg", {
            side        = { menu_button = "right", up_button = "left", search_button = "left" },
            order_left  = { "up_button", "search_button" },
            order_right = { "menu_button" },
        })
        G_reader_settings:saveSetting("simpleui_defaults_v2", true)
    end

    -- ---------------------------------------------------------------------------
    -- v3: Browse by Author/Series enabled by default; browse button visible,
    --     positioned on the right side, to the left of the menu button.
    -- Guard key: "simpleui_defaults_v3". Safe to call on every init.
    -- ---------------------------------------------------------------------------
    if not G_reader_settings:readSetting("simpleui_defaults_v3") then
        -- Feature on by default.
        G_reader_settings:saveSetting("simpleui_browsemeta_enabled", true)
        -- Browse button visible.
        G_reader_settings:saveSetting("simpleui_tb_item_browse_button", true)
        -- FM layout: back + search on the left, browse + menu on the right.
        -- browse_button is left of menu_button (order_right is rendered RTL: last = outermost).
        G_reader_settings:saveSetting("simpleui_tb_fm_cfg", {
            side        = { menu_button = "right", up_button = "left",
                            search_button = "left", browse_button = "right" },
            order_left  = { "up_button", "search_button" },
            order_right = { "browse_button", "menu_button" },
        })
        G_reader_settings:saveSetting("simpleui_defaults_v3", true)
    end
end

function M.reset()
    _tabs_cache                  = nil
    _navbar_mode_cache           = nil
    M.wifi_optimistic            = nil
    M.cover_extraction_pending   = false
    M._cover_extract_next_ok     = 0
    M._cover_extract_pending     = {}
    _Device                      = nil
    _NetworkMgr                  = nil
    _has_wifi_toggle             = nil
    _topbar_item_labels          = nil
    _SQ3                         = nil
    _lfs_mod                     = nil
    _BookInfoManager             = nil
    _topbar_cfg_menu_cache       = nil
    _ReadCollection              = nil
    -- Invalidate the max-extraction-size cache so it is recomputed on the
    -- next session (in case screen DPI changes, e.g. after a KOReader update).
    _max_extract_w               = nil
    _max_extract_h               = nil
    -- QA key cache is now managed in sui_quickactions.lua
    _QA_lazy().clearQAKeyCache()
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
M._cover_extract_next_ok   = 0
M._cover_extract_pending   = {}

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

local BIM_MAX_COVERS   = 12
-- _bim_cover_cache[key] = { bb = <blitbuffer>, t = <os.time()> }
local _bim_cover_cache = {}
local _bim_cover_count = 0

-- Cached require — resolved once, reused for every cover scale operation.
local _RenderImage = nil

-- ---------------------------------------------------------------------------
-- _getMaxExtractSize — returns the largest cover dimensions that any
-- homescreen module could ever request, across all user-configurable scales.
--
-- Problem: getCoverBB calls extractInBackground with cover_specs={w,h} equal
-- to the dimensions needed by the *current* module at the *current* scale.
-- If the user later increases the scale, or if a different module (e.g.
-- coverdeck) needs a larger bitmap than what CoverBrowser stored for the
-- file-browser grid, BookInfoManager considers the stored cover "lowres" and
-- re-extracts it. This creates a ping-pong: SimpleUI re-extracts at its size,
-- CoverBrowser re-extracts at its size, on every view switch.
--
-- Fix: always pass the theoretical maximum size to extractInBackground so the
-- stored bitmap is never "lowres" from any module's point of view.
-- getCoverBB still scales DOWN to the exact requested (w, h) before returning
-- to the caller — that logic is unchanged.
--
-- The largest module is coverdeck, whose centre cover uses scaleBySize(140).
-- Module scale and thumb scale are each clamped to 200% (SCALE_MAX), but in
-- practice users rarely run both at maximum simultaneously. We cap the
-- combined multiplier at 2.0× (one slider at 200%, the other at 100%) to
-- keep the stored bitmap reasonable; getCoverBB will re-extract on demand
-- if the user genuinely exceeds this — a rare edge case vs. the common one.
--
-- Computed once per session (lazy) and invalidated by M.reset().
-- ---------------------------------------------------------------------------
local _max_extract_w = nil
local _max_extract_h = nil

local function _getMaxExtractSize()
    if _max_extract_w then return _max_extract_w, _max_extract_h end
    local ok, dev = pcall(require, "device")
    if not (ok and dev and dev.screen) then
        -- Device not yet available — return a safe large default.
        -- 600×900 covers any 6" e-reader at 300 dpi with 2× scale applied.
        return 600, 900
    end
    -- coverdeck centre cover base = scaleBySize(140).
    -- Capped combined scale = module_max(200%) × 1 = 2.0.
    local max_combined = 2.0
    _max_extract_w = math.floor(dev.screen:scaleBySize(140) * max_combined)
    _max_extract_h = math.floor(_max_extract_w * 3 / 2)
    return _max_extract_w, _max_extract_h
end

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

-- stretch_limit: optional float (e.g. 0.10 = 10%).
-- When provided, the function first tries to fit the image into the slot
-- without any crop by scaling both axes independently (aspect-ratio distortion).
-- If the required distortion on either axis stays within stretch_limit, the
-- image is scaled directly to target_w × target_h — no crop, slight stretch.
-- If the distortion would exceed the limit, the function falls back to the
-- standard fill-and-crop path (math.max scale factor, centre crop).
-- When stretch_limit is nil/absent, the original fill-and-crop behaviour is
-- unchanged — all existing call sites are unaffected.
local function _scaleBBToSlot(bb, target_w, target_h, align, stretch_limit)
    if not _RenderImage then
        local ok, ri = pcall(require, "ui/renderimage")
        if not (ok and ri) then return bb end
        _RenderImage = ri
    end
    local src_w = bb:getWidth()
    local src_h = bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return bb end
    if src_w == target_w and src_h == target_h then
        -- MUST copy: bb is typically owned by BookInfoManager. Returning it
        -- directly means our LRU cache holds a reference to BIM's bitmap.
        -- When clearCoverCache() frees cached entries, it would destroy BIM's
        -- internal cover_bb — causing static/noise on the next getCoverBB call
        -- because the BIM hands back the same (now-freed) FFI memory.
        local ok_blit, Blitbuffer_mod = pcall(require, "ffi/blitbuffer")
        if ok_blit and Blitbuffer_mod then
            local ok_copy, copy_bb = pcall(function()
                local c = Blitbuffer_mod.new(target_w, target_h, bb:getType())
                c:blitFrom(bb, 0, 0, 0, 0, target_w, target_h)
                return c
            end)
            if ok_copy and copy_bb then return copy_bb end
        end
        return bb  -- fallback if copy fails (rare)
    end
    -- When a stretch_limit is requested, check whether the distortion needed
    -- to fill the slot without cropping is acceptable.
    -- distort = how much one axis must be stretched relative to the other to
    -- fill target_w × target_h exactly, expressed as a fraction (0.10 = 10%).
    -- If within the limit, scale both axes directly to target — no crop.
    -- If beyond the limit, fall through to the standard fill-and-crop path.
    if stretch_limit then
        local scale_w   = target_w / src_w
        local scale_h   = target_h / src_h
        local distort   = math.abs(scale_w / scale_h - 1)
        if distort <= stretch_limit then
            local ok_sc, stretched_bb = pcall(function()
                return _RenderImage:scaleBlitBuffer(bb, target_w, target_h)
            end)
            if ok_sc and stretched_bb then return stretched_bb end
            -- On error fall through to fill-and-crop below.
        end
    end

    -- Fill-and-crop path (default, and fallback when distortion > stretch_limit).
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
    -- Crop the oversized scaled bitmap to target_w × target_h.
    local ok_blit, Blitbuffer_mod = pcall(require, "ffi/blitbuffer")
    if not (ok_blit and Blitbuffer_mod) then return scaled_bb end
    local ok_slot, slot_bb = pcall(function()
        return Blitbuffer_mod.new(target_w, target_h, scaled_bb:getType())
    end)
    if not (ok_slot and slot_bb) then return scaled_bb end
    -- src_x/src_y: offset into the scaled bitmap where the crop starts.
    local src_x
    if align == "left" then
        src_x = 0
    elseif align == "right" then
        src_x = scaled_w - target_w
    else
        src_x = math.floor((scaled_w - target_w) / 2)
    end
    local src_y = math.floor((scaled_h - target_h) / 2)
    pcall(function()
        slot_bb:blitFrom(scaled_bb, 0, 0, src_x, src_y, target_w, target_h)
    end)
    pcall(function() scaled_bb:free() end)
    return slot_bb
end

function M.getCoverBB(filepath, w, h, align, stretch_limit)
    local key    = filepath .. "|" .. w .. "x" .. h .. (align and ("|" .. align) or "")
    local cached = _bim_cover_cache[key]
    if cached then
        -- Update LRU access time in-place — no allocation, no list shift.
        local now = os.time()
        cached.t = now
        if not cached.lowres then
            return cached.bb
        end
        if cached.chk and (now - cached.chk) < 2 then
            return cached.bb
        end
        cached.chk = now
        local bim = M.getBookInfoManager()
        if not bim then return cached.bb end
        local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, true) end)
        if not ok or not bookinfo then return cached.bb end
        if not (bookinfo.cover_fetched and bookinfo.has_cover and bookinfo.cover_bb) then
            return cached.bb
        end
        if M._cover_extract_pending then
            M._cover_extract_pending[filepath] = nil
        end
        local src_w = bookinfo.cover_bb:getWidth()
        local src_h = bookinfo.cover_bb:getHeight()
        if src_w >= w and src_h >= h then
            local bb = _scaleBBToSlot(bookinfo.cover_bb, w, h, align, stretch_limit)
            pcall(function() cached.bb:free() end)
            cached.bb     = bb
            cached.lowres = nil
            cached.src_w  = src_w
            cached.src_h  = src_h
            return bb
        end
        return cached.bb
    end

    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(function() return bim:getBookInfo(filepath, true) end)
    if not ok then return nil end

    local function scheduleExtract()
        if not M._cover_extract_pending then M._cover_extract_pending = {} end
        if M._cover_extract_pending[filepath] then return end
        local now = os.time()
        if (M._cover_extract_next_ok or 0) > now then return end
        M._cover_extract_next_ok = now + 1
        M._cover_extract_pending[filepath] = now
        -- Extract at the maximum size any homescreen module could ever need,
        -- rather than the current caller's (w, h). This prevents the ping-pong
        -- recache cycle where CoverBrowser and the homescreen repeatedly
        -- re-extract the same cover at different sizes. getCoverBB still scales
        -- the returned bitmap down to exactly (w, h) before handing it back.
        local ext_w, ext_h = _getMaxExtractSize()
        pcall(function()
            bim:extractInBackground({{
                filepath    = filepath,
                cover_specs = { max_cover_w = ext_w, max_cover_h = ext_h },
            }})
        end)
    end

    -- If extraction was already attempted, use the cached result.
    if bookinfo and bookinfo.cover_fetched then
        if bookinfo.has_cover and bookinfo.cover_bb then
            local src_w = bookinfo.cover_bb:getWidth()
            local src_h = bookinfo.cover_bb:getHeight()
            -- Compare against the max extraction size, not just the current
            -- caller's (w, h). If the stored bitmap already satisfies the
            -- current request but is smaller than the max, re-extract once so
            -- future callers (e.g. coverdeck at a larger scale) won't trigger
            -- another extraction cycle. If it already meets the max, it is
            -- stable and will never be "lowres" for any module.
            local max_w, max_h = _getMaxExtractSize()
            local lowres = (src_w < max_w or src_h < max_h)
            if lowres then scheduleExtract() end
            local bb = _scaleBBToSlot(bookinfo.cover_bb, w, h, align, stretch_limit)
            if _bim_cover_count >= BIM_MAX_COVERS then _evictOldestCover() end
            _bim_cover_cache[key] = { bb = bb, t = os.time(), lowres = lowres or nil, chk = os.time(), src_w = src_w, src_h = src_h }
            _bim_cover_count = _bim_cover_count + 1
            return bb
        else
            -- Extraction was attempted before and found no cover (or failed).
            -- Return nil immediately to avoid triggering a poll loop.
            return nil
        end
    end

    scheduleExtract()
    return nil
end

-- Releases all cover bitmaps (owned by us — scaled copies).
-- Defer the actual freeing of the bitmaps to a background timer to avoid
-- blocking the UI thread on slower e-readers when closing the Homescreen.
function M.clearCoverCache()
    if _bim_cover_count == 0 then return end
    local to_free = _bim_cover_cache
    _bim_cover_cache = {}
    _bim_cover_count = 0
    _RenderImage     = nil
    local UIManager = require("ui/uimanager")
    -- Free one cover per tick to keep the UI smooth
    local function freeNext()
        local k, entry = next(to_free)
        if not k then return end
        pcall(function() entry.bb:free() end)
        to_free[k] = nil
        if next(to_free) then
            UIManager:scheduleIn(0.1, freeNext)
        end
    end
    UIManager:scheduleIn(0.1, freeNext)
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

local _SQ3            = nil    -- cached ljsqlite3 module
local _lfs_mod        = nil    -- cached lfs module
local _indexes_created = false -- true once CREATE INDEX has run this session

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
    if not (ok and conn) then return nil end
    -- Create indexes once per process lifetime. CREATE INDEX IF NOT EXISTS still
    -- costs a schema lookup on every call, so we gate it with a module-level flag.
    -- Only set the flag when the pcall succeeds — a corrupt DB will make it fail,
    -- and we want to retry on the next successful open.
    if not _indexes_created then
        local idx_ok = pcall(function()
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_book_md5 ON book(md5);")
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_pagestat_book ON page_stat(id_book);")
            -- Covers the WHERE start_time >= ? filter in fetchTimeSeries (day_buckets CTE)
            -- and the dated CTE in fetchStreak. Without this index both queries do a full
            -- table scan of page_stat on every cold-cache render.
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_pagestat_time ON page_stat(start_time);")
        end)
        if idx_ok then _indexes_created = true end
    end
    return conn
end

-- Returns true when a ljsqlite3 error string indicates unrecoverable DB state.
-- Used by modules to signal that the shared connection should be discarded.
-- "corrupt"  -> SQLITE_CORRUPT  (11): on-disk structure invalid
-- "notadb"   -> SQLITE_NOTADB   (26): file is not a database
-- "ioerr"    -> SQLITE_IOERR    (10): I/O error reading/writing
-- "full"     -> SQLITE_FULL     (13): disk full (writes fail, reads still work)
-- We only flag errors where retrying queries on the same connection is pointless.
function M.isFatalDbError(err)
    if type(err) ~= "string" then return false end
    return err:find("ljsqlite3%[corrupt%]", 1, false)
        or err:find("ljsqlite3%[notadb%]",  1, false)
        or err:find("ljsqlite3%[ioerr%]",   1, false)
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
    return G_reader_settings:isTrue("navbar_navpager_enabled")
end

-- Returns true when dot-pager mode is active on the homescreen.
-- Dot-pager shows a row of dots (one per page) instead of the chevron bar,
-- and obeys the same pagination visibility rules as the default bar.
function M.isDotPagerEnabled()
    return G_reader_settings:nilOrTrue("navbar_dotpager_always")
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
-- Returns false, false when no pageable widget is found (e.g. ReaderUI).
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
    local UI = package.loaded["sui_core"]
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
            logger.dbg("simpleui navpager: top fullscreen widget name=",
                tostring(w.name), "has_file_chooser=", tostring(w.file_chooser ~= nil),
                "has_page=", tostring(w.page ~= nil))

            -- Case 1: widget is itself a pageable menu (BookList, History, Collections).
            local prev, nxt = _stateFromMenu(w)
            if prev ~= nil then
                logger.dbg("simpleui navpager: direct menu =>", tostring(prev), tostring(nxt))
                return prev, nxt
            end

            -- Case 2: FM — the pageable menu is file_chooser inside.
            if w.file_chooser then
                local prev2, nxt2 = _stateFromMenu(w.file_chooser)
                if prev2 ~= nil then
                    logger.dbg("simpleui navpager: file_chooser =>", tostring(prev2), tostring(nxt2))
                    return prev2, nxt2
                end
            end

            -- Case 3: Homescreen — read _current_page / _total_pages from the instance.
            local HS   = package.loaded["sui_homescreen"]
            local inst = HS and HS._instance
            if inst and inst == w then
                local cur   = inst._current_page or 1
                local total = inst._total_pages  or 1
                local prev3 = cur > 1
                local nxt3  = cur < total
                logger.dbg("simpleui navpager: homescreen =>", tostring(prev3), tostring(nxt3))
                return prev3, nxt3
            end

            -- Case 4: fullscreen but not pageable (ReaderUI, etc.).
            logger.dbg("simpleui navpager: not pageable -> false,false")
            return false, false
        end
        -- w is nil or not covers_fullscreen: overlay/dialog, keep looking down.
    end
    logger.dbg("simpleui navpager: stack exhausted -> false,false")
    return false, false
end


-- ---------------------------------------------------------------------------
-- Scale system — module-level and label scale with optional linking.
--
-- Settings layout:
--   navbar_homescreen_module_scale          global module scale (integer %)
--   navbar_homescreen_label_scale           label scale (integer %)
--   navbar_homescreen_<pfx><id>_scale       per-module scale override (integer %)
--   navbar_homescreen_scale_linked          bool; true = all scales move together
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

local MODULE_SCALE_KEY      = "navbar_homescreen_module_scale"
local LABEL_SCALE_KEY       = "navbar_homescreen_label_scale"
local SCALE_LINKED_KEY      = "navbar_homescreen_scale_linked"
local ITEM_LABEL_SCALE_SUFFIX = "_item_label_scale"

-- Clamp an integer percentage to valid range.
local function _clamp(n)
    return math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(n)))
end

-- Returns the per-module setting key for a given module id and pfx.
local function _modKey(mod_id, pfx)
    return (pfx or "navbar_homescreen_") .. (mod_id or "") .. "_scale"
end

local function _itemLabelKey(mod_id, pfx)
    return (pfx or "navbar_homescreen_") .. (mod_id or "") .. ITEM_LABEL_SCALE_SUFFIX
end

-- ---------------------------------------------------------------------------
-- Bar size (bottom bar) — numeric % stored as "navbar_bar_size_pct"
-- Legacy string key ("navbar_bar_size") is ignored; we read/write the pct key.
-- ---------------------------------------------------------------------------

local BAR_SIZE_KEY     = "navbar_bar_size_pct"
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
-- Topbar size — numeric % stored as "navbar_topbar_size_pct"
-- ---------------------------------------------------------------------------

local TOPBAR_SIZE_KEY = "navbar_topbar_size_pct"
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
-- Bottom bar bottom margin — extra space below the bar.
-- Stored as "navbar_bottom_margin_pct" (integer %, default 100).
-- 100% = default BOT_SP; 0% = no bottom margin.
-- ---------------------------------------------------------------------------

local BOT_MARGIN_KEY  = "navbar_bottom_margin_pct"
local BOT_MARGIN_DEF  = 100
local BOT_MARGIN_MIN  = 0
local BOT_MARGIN_MAX  = 300
local BOT_MARGIN_STEP = 10

function M.getBottomMarginPct()
    local v = G_reader_settings:readSetting(BOT_MARGIN_KEY)
    local n = tonumber(v)
    if not n then return BOT_MARGIN_DEF end
    return math.max(BOT_MARGIN_MIN, math.min(BOT_MARGIN_MAX, math.floor(n)))
end

function M.setBottomMarginPct(pct)
    G_reader_settings:saveSetting(BOT_MARGIN_KEY,
        math.max(BOT_MARGIN_MIN, math.min(BOT_MARGIN_MAX, math.floor(pct))))
end

M.BOT_MARGIN_DEF  = BOT_MARGIN_DEF
M.BOT_MARGIN_MIN  = BOT_MARGIN_MIN
M.BOT_MARGIN_MAX  = BOT_MARGIN_MAX
M.BOT_MARGIN_STEP = BOT_MARGIN_STEP

-- ---------------------------------------------------------------------------
-- Reading Stats text scale — multiplicative on top of module scale.
-- Stored as "navbar_rs_text_scale_pct" (integer %).
-- ---------------------------------------------------------------------------

local RS_TEXT_SCALE_KEY  = "navbar_rs_text_scale_pct"
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
-- Stored as \"navbar_icon_scale_pct\" (integer %).
-- ---------------------------------------------------------------------------

local ICON_SCALE_KEY  = "navbar_icon_scale_pct"
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
-- Stored as \"navbar_label_scale_pct\" (integer %).
-- ---------------------------------------------------------------------------

local LABEL_SCALE_KEY  = "navbar_label_scale_pct"
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
    return (pfx or "navbar_homescreen_") .. (mod_id or "") .. THUMB_SCALE_KEY_SUFFIX
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
    local PAD2  = require("sui_core").PAD2
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
            G_reader_settings:delSetting((pfx or "navbar_homescreen_") .. mod.id .. "_scale")
            G_reader_settings:delSetting((pfx or "navbar_homescreen_") .. mod.id .. THUMB_SCALE_KEY_SUFFIX)
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
    return (pfx or "navbar_homescreen_") .. (mod_id or "") .. "_gap_pct"
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
-- Per-module label (section title) visibility toggle.
-- Setting key: "simpleui_hide_label_" .. mod_id  (true = hidden, nil = shown)
-- Never stored as false — KOReader LuaSettings removes keys set to false.
-- ---------------------------------------------------------------------------

local function _labelHideKey(mod_id)
    return "simpleui_hide_label_" .. (mod_id or "")
end

-- Returns true when the section label for mod_id should be hidden.
function M.isLabelHidden(mod_id)
    return G_reader_settings:readSetting(_labelHideKey(mod_id)) == true
end

-- Call at the start of each module's build() to keep mod.label in sync.
-- default_label is the translated string e.g. _("Currently Reading").
function M.applyLabelToggle(mod, default_label)
    if M.isLabelHidden(mod.id) then
        mod.label = nil
    else
        mod.label = default_label
    end
end

-- Returns a checkbox menu item for toggling the section label visibility.
-- _lc is the menu-local gettext wrapper (ctx_menu._).
function M.makeLabelToggleItem(mod_id, default_label, refresh, _lc)
    return {
        text           = _lc("Show section label"),
        checked_func   = function() return not M.isLabelHidden(mod_id) end,
        keep_menu_open = true,
        callback       = function()
            -- Store true to hide, nil (remove key) to show — never store false.
            G_reader_settings:saveSetting(_labelHideKey(mod_id),
                not M.isLabelHidden(mod_id) and true or nil)
            refresh()
        end,
    }
end

return M
