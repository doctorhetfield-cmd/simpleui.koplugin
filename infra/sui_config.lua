-- config.lua — Simple UI
-- sui_config.lua — Simple UI
-- Central configuration, state caching, and core helpers.

local G_reader_settings = G_reader_settings
local math_max          = math.max
local math_min          = math.min
local math_floor        = math.floor
local Blitbuffer        = require("ffi/blitbuffer")
local DataStorage       = require("datastorage")
local SUISettings       = require("infra/sui_store")
local SUICoverCache     = require("infra/sui_cover_cache")
local logger            = require("logger")
local _ = require("infra/sui_i18n").translate
local T = require("ffi/util").template

local M = {}

-- ===========================================================================
-- 1. Paths & Icons
-- ===========================================================================

-- Resolve absolute plugin directory for cross-platform compatibility.
local _plugin_dir = require("infra/sui_paths").getPluginDir()
local _P  = _plugin_dir .. "icons/"
local _ko_root = ""
if DataStorage and type(DataStorage.getDataDir) == "function" then
    local _d = DataStorage.getDataDir():gsub("/$", "")
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

-- Icon path registry.
M.ICON = {
    library        = _P .. "library.svg",
    collections    = _P .. "collections.svg",
    history        = _P .. "history.svg",
    recent         = _P .. "recent.svg",
    random         = _P .. "random.svg",
    continue_      = _P .. "continue.svg",       -- trailing _ avoids clash with Lua keyword
    frontlight     = _P .. "frontlight.svg",
    night          = _P .. "night.svg",
    stats          = _P .. "stats.svg",
    power          = _P .. "power.svg",
    plus_alt       = _P .. "plus_alt.svg",
    custom         = _P .. "custom.svg",
    custom_dir     = _P .. "custom",
    group          = _P .. "group.svg",
    plugin         = _P .. "plugin.svg",
    author         = _P .. "author.svg",
    series         = _P .. "series.svg",
    tags           = _P .. "tags.svg",
    nav_prev       = _KO .. "chevron.left.svg",
    nav_next       = _KO .. "chevron.right.svg",
    ko_home        = _KO .. "home.svg",
    ko_star        = _KO .. "star.empty.svg",
    ko_wifi        = _KO .. "wifi.open.100.svg",
    ko_menu        = _KO .. "appbar.menu.svg",
    ko_settings    = _KO .. "appbar.settings.svg",
    ko_search      = _KO .. "appbar.search.svg",
    ko_bookmark    = _KO .. "bookmark.svg",
}

M.CUSTOM_ICON            = M.ICON.custom
M.CUSTOM_PLUGIN_ICON     = M.ICON.plugin
M.CUSTOM_DISPATCHER_ICON = M.ICON.ko_settings
M.CUSTOM_GROUP_ICON      = M.ICON.group

-- ===========================================================================
-- 2. Core Constants & Action Registry
-- ===========================================================================

M.DEFAULT_NUM_TABS       = 5
M.MAX_TABS               = 6
M.MAX_TABS_NAVPAGER      = 4
M.MAX_LABEL_LEN          = 20
M.MAX_CUSTOM_QA          = 24
M.NAVPAGER_CENTER_TABS   = 4

M.DEFAULT_TABS = { "home", "sui_settings", "homescreen", "history", "power" }

M.NON_HOME_DEFAULTS = {}
for _i, id in ipairs(M.DEFAULT_TABS) do
    if id ~= "home" then M.NON_HOME_DEFAULTS[#M.NON_HOME_DEFAULTS + 1] = id end
end

-- Action catalogue.
M.ALL_ACTIONS = {
    { id = "home",             label = _("Library"),          icon = M.ICON.library     },
    { id = "homescreen",       label = _("Home"),             icon = M.ICON.ko_home     },
    { id = "collections",      label = _("Collections"),      icon = M.ICON.collections },
    { id = "history",          label = _("History"),          icon = M.ICON.history     },
    { id = "recent",           label = _("Recent"),           icon = M.ICON.recent      },
    { id = "continue",         label = _("Continue"),         icon = M.ICON.continue_   },
    { id = "random_document",  label = _("Random"),           icon = M.ICON.random      },
    { id = "favorites",        label = _("Favorites"),        icon = M.ICON.ko_star     },
    { id = "bookmark_browser", label = _("Bookmarks"),        icon = M.ICON.ko_bookmark },
    { id = "search_library",   label = _("Search"),           icon = M.ICON.ko_search   },
    { id = "wifi_toggle",      label = _("Wi-Fi"),            icon = M.ICON.ko_wifi     },
    { id = "frontlight",       label = _("Brightness"),       icon = M.ICON.frontlight  },
    { id = "night_mode",       label = _("Night Mode"),       icon = M.ICON.night       },
    { id = "stats_calendar",   label = _("Stats"),            icon = M.ICON.stats       },
    { id = "power",            label = _("Power"),            icon = M.ICON.power       },
    { id = "sui_settings",     label = _("Settings"),         icon = M.ICON.ko_settings },
    { id = "browse_authors",   label = _("Authors"),          icon = M.ICON.author,
      browsemeta_mode = "author" },
    { id = "browse_series",    label = _("Series"),           icon = M.ICON.series,
      browsemeta_mode = "series" },
    { id = "browse_tags",      label = _("Tags"),             icon = M.ICON.tags,
      browsemeta_mode = "tags" },
}

M.ACTION_BY_ID = {}
for _i, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- Custom Quick Actions wrappers (delegates to sui_quickactions to avoid circular require).
local function _QA_lazy() return package.loaded["features/sui_quickactions"] or require("features/sui_quickactions") end
function M.getCustomQAList()         return _QA_lazy().getCustomQAList()                                                              end
function M.saveCustomQAList(list)    return _QA_lazy().saveCustomQAList(list)                                                         end
function M.getCustomQAConfig(id)     return _QA_lazy().getCustomQAConfig(id)                                                          end
function M.saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da, is_folder) return _QA_lazy().saveCustomQAConfig(id, label, path, coll, icon, pk, pm, da, is_folder) end
function M.getQAFolderItems(id)      return _QA_lazy().getQAFolderItems(id)                                                            end
function M.saveQAFolderItems(id, items) return _QA_lazy().saveQAFolderItems(id, items)                                                 end
function M.deleteCustomQA(id)        return _QA_lazy().deleteCustomQA(id)                                                             end
function M.purgeQACollection(coll)   return _QA_lazy().purgeQACollection(coll)                                                        end
function M.renameQACollection(o, n)  return _QA_lazy().renameQACollection(o, n)                                                       end
function M.sanitizeQASlots()         return _QA_lazy().sanitizeQASlots()                                                              end
function M.nextCustomQAId()          return _QA_lazy().nextCustomQAId()                                                               end

-- ===========================================================================
-- 3. Topbar & Tab Configurations
-- ===========================================================================

M.TOPBAR_ITEMS = { "clock", "wifi", "bluetooth", "brightness", "battery", "disk", "ram", "custom_text" }

-- TOPBAR_ITEMS filtered to what this device can actually display.
function M.getAvailableTopbarItems()
    local list = {}
    local bt_ok = nil
    for _, k in ipairs(M.TOPBAR_ITEMS) do
        if k == "bluetooth" then
            if bt_ok == nil then
                local ok, Topbar = pcall(require, "screens/sui_topbar")
                bt_ok = ok and Topbar and Topbar.isBluetoothAvailable
                    and Topbar.isBluetoothAvailable() or false
            end
            if not bt_ok then
                -- skip: no Bluetooth backend on this device
            else
                list[#list + 1] = k
            end
        else
            list[#list + 1] = k
        end
    end
    return list
end

local _topbar_item_labels = nil
function M.TOPBAR_ITEM_LABEL(k)
    if not _topbar_item_labels then
        _topbar_item_labels = {
            clock       = _("Clock"),
            wifi        = _("WiFi"),
            bluetooth   = _("Bluetooth"),
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
    return SUISettings:get("simpleui_topbar_custom_text") or ""
end

function M.setTopbarCustomText(s)
    if type(s) == "string" then
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
    SUISettings:set("simpleui_topbar_custom_text", s)
end

function M.getTopbarConfig()
    local raw = SUISettings:get("simpleui_topbar_config")
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
    if #cfg.order_center == 0 then
        for k, s in pairs(cfg.side) do
            if s == "center" then cfg.order_center[#cfg.order_center + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    SUISettings:set("simpleui_topbar_config", cfg)
    M.invalidateTopbarConfigCache()
    local tb = package.loaded["screens/sui_topbar"]
    if tb and tb.invalidateConfigCache then tb.invalidateConfigCache() end
end

local _tabs_cache = nil

function M.invalidateTabsCache()
    _tabs_cache = nil
end

function M.loadTabConfig()
    if _tabs_cache then return _tabs_cache end
    local cfg = SUISettings:get("simpleui_bar_tabs")
    local result = {}
    local min_tabs = M.isNavpagerEnabled() and 1 or 2
    if type(cfg) == "table" and #cfg >= min_tabs and #cfg <= M.effectiveMaxTabs() then
        -- _QA_lazy() is defined earlier in this same file (line ~143).
        -- QA.isRegistered recognizes externally registered action ids (e.g.
        -- a Custom Screen's "open_custom_screen:<id>" QA) that
        -- M.ACTION_BY_ID never will, since M.ALL_ACTIONS only ever mirrors
        -- the built-ins.
        local ok_qa, QA = pcall(_QA_lazy)
        for i = 1, #cfg do
            local id = cfg[i]
            if M.ACTION_BY_ID[id] or id:match("^custom_qa_%d+$")
                    or (ok_qa and QA and QA.isRegistered(id)) then
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
    SUISettings:set("simpleui_bar_tabs", tabs)
end

function M.getNumTabs()
    if _tabs_cache then return #_tabs_cache end
    return #M.loadTabConfig()
end

local _navbar_mode_cache = nil

function M.getNavbarMode()
    if not _navbar_mode_cache then
        _navbar_mode_cache = SUISettings:get("simpleui_bar_mode") or "both"
    end
    return _navbar_mode_cache
end

function M.saveNavbarMode(mode)
    _navbar_mode_cache = nil
    SUISettings:set("simpleui_bar_mode", mode)
end

function M._ensureHomePresent(tabs)
    local home_pos = nil
    local used = {}
    for i, id in ipairs(tabs) do
        if id == "home" then
            if not home_pos then
                home_pos = i
                used[id] = true
            else
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

-- ===========================================================================
-- 4. Action Resolution & System State
-- ===========================================================================

M.wifi_optimistic    = nil
M.wifi_broadcast_self = nil

function M.getWifiHideWhenOff()
    return SUISettings:isTrue("simpleui_topbar_wifi_hide_when_off")
end
function M.setWifiHideWhenOff(v)
    SUISettings:set("simpleui_topbar_wifi_hide_when_off", v)
end

function M.homeLabel()
    return _("Library")
end

function M.homeIcon()
    return M.ICON.library
end

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

local _has_wifi_toggle = nil
local function deviceHasWifi()
    if _has_wifi_toggle == nil then
        local ok, v = pcall(function() return getDevice():hasWifiToggle() end)
        _has_wifi_toggle = ok and v == true
    end
    return _has_wifi_toggle
end

-- True when this device maps a key to the KOReader "Home" key name.
-- Used to show the "Home Button Opens Home Screen" option and to wire
-- ReaderUI/FileManager onHome handlers. KOReader has no Device:hasHomeKey();
-- hasKeys() alone is insufficient (registers Home even when the event_map
-- never emits it). Cache for the process lifetime — event_map is fixed.
local _has_home_key = nil
function M.deviceHasHomeKey()
    if _has_home_key ~= nil then return _has_home_key end
    _has_home_key = false
    local ok, result = pcall(function()
        local dev = getDevice()
        if not (dev and dev:hasKeys()) then return false end
        local map = dev.input and dev.input.event_map
        if type(map) ~= "table" then return false end
        for _, name in pairs(map) do
            if name == "Home" then return true end
        end
        return false
    end)
    if ok and result then _has_home_key = true end
    return _has_home_key
end

-- Returns whether Wi-Fi is currently on. Single source of truth for the
-- wifi_toggle Quick Action's is_active state (see features/sui_quickactions.lua),
-- which dims the (single) Wi-Fi icon rather than swapping to a distinct
-- "off" asset.
function M.wifiOn()
    if M.wifi_optimistic ~= nil then
        return M.wifi_optimistic == true
    end
    if not deviceHasWifi() then return false end
    local NetworkMgr = getNetworkMgr()
    if not NetworkMgr then return false end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    return ok_state and wifi_on == true
end

function M.getActionById(id)
    local QA = package.loaded["features/sui_quickactions"]
        or require("features/sui_quickactions")
    local entry = QA.getEntry(id)
    if entry and not entry.id then
        -- entry.dim carries the resolved on/off state for actions with an
        -- is_active hook (e.g. wifi_toggle, night_mode) — keep it so callers
        -- can dim the icon via UI.wrapDimmable, same as every other QA
        -- consumer (see features/sui_quickactions.lua header comment).
        return { id = id, label = entry.label, icon = entry.icon, dim = entry.dim }
    end
    return entry or M.ALL_ACTIONS[1]
end

function M.getDefaultActionLabel(id)
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    return QA.getDefaultActionLabel(id)
end
function M.getDefaultActionIcon(id)
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    return QA.getDefaultActionIcon(id)
end
function M.setDefaultActionLabel(id, label)
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    QA.setDefaultActionLabel(id, label)
end
function M.setDefaultActionIcon(id, icon)
    local QA = package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
    QA.setDefaultActionIcon(id, icon)
end

function M.sanitizeLabel(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    if #s > M.MAX_LABEL_LEN then s = s:sub(1, M.MAX_LABEL_LEN) end
    return s
end

-- Converts a "nerd:XXXX" hex string to a UTF-8 character.
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

function M.isNerdIcon(icon_value)
    return M.nerdIconChar(icon_value) ~= nil
end

-- ===========================================================================
-- 5. Scaling, Dimensions & UI Helpers
-- ===========================================================================

local SCALE_MIN, SCALE_MAX, SCALE_STEP, SCALE_DEF = 50, 200, 10, 100
local MODULE_SCALE_KEY = "simpleui_hs_module_scale"
local LABEL_SCALE_KEY  = "simpleui_hs_label_scale"
local SCALE_LINKED_KEY = "simpleui_hs_scale_linked"
local ITEM_LABEL_SCALE_SUFFIX = "_item_label_scale"

local function _clamp(n) return math_max(SCALE_MIN, math_min(SCALE_MAX, math_floor(n))) end
local function _modKey(mod_id, pfx) return (pfx or "simpleui_hs_") .. (mod_id or "") .. "_scale" end
local function _itemLabelKey(mod_id, pfx) return (pfx or "simpleui_hs_") .. (mod_id or "") .. ITEM_LABEL_SCALE_SUFFIX end

-- Navigation Bar Size
local BAR_SIZE_KEY     = "simpleui_bar_size_pct"
local BAR_SIZE_DEF     = 100
local BAR_SIZE_MIN     = 50
local BAR_SIZE_MAX     = 150

function M.getBarSizePct()
    local v = SUISettings:get(BAR_SIZE_KEY)
    local n = tonumber(v)
    if not n then return BAR_SIZE_DEF end
    return math_max(BAR_SIZE_MIN, math_min(BAR_SIZE_MAX, math_floor(n)))
end

function M.setBarSizePct(pct)
    SUISettings:set(BAR_SIZE_KEY,
        math_max(BAR_SIZE_MIN, math_min(BAR_SIZE_MAX, math_floor(pct))))
end

M.BAR_SIZE_DEF  = BAR_SIZE_DEF
M.BAR_SIZE_MIN  = BAR_SIZE_MIN
M.BAR_SIZE_MAX  = BAR_SIZE_MAX
M.BAR_SIZE_STEP = SCALE_STEP

-- Topbar Size
local TOPBAR_SIZE_KEY = "simpleui_topbar_size_pct"
local TOPBAR_SIZE_DEF = 100
local TOPBAR_SIZE_MIN = 50
local TOPBAR_SIZE_MAX = 150

function M.getTopbarSizePct()
    local v = SUISettings:get(TOPBAR_SIZE_KEY)
    local n = tonumber(v)
    if not n then return TOPBAR_SIZE_DEF end
    return math_max(TOPBAR_SIZE_MIN, math_min(TOPBAR_SIZE_MAX, math_floor(n)))
end

function M.setTopbarSizePct(pct)
    SUISettings:set(TOPBAR_SIZE_KEY,
        math_max(TOPBAR_SIZE_MIN, math_min(TOPBAR_SIZE_MAX, math_floor(pct))))
end

M.TOPBAR_SIZE_DEF  = TOPBAR_SIZE_DEF
M.TOPBAR_SIZE_MIN  = TOPBAR_SIZE_MIN
M.TOPBAR_SIZE_MAX  = TOPBAR_SIZE_MAX
M.TOPBAR_SIZE_STEP = SCALE_STEP

-- Bottom Margin
local BOT_MARGIN_KEY  = "simpleui_bar_bottom_margin_pct"
local BOT_MARGIN_DEF  = 100
local BOT_MARGIN_MIN  = 0
local BOT_MARGIN_MAX  = 300
local BOT_MARGIN_STEP = 10

function M.getBottomMarginPct()
    local v = SUISettings:get(BOT_MARGIN_KEY)
    local n = tonumber(v)
    if not n then return BOT_MARGIN_DEF end
    return math_max(BOT_MARGIN_MIN, math_min(BOT_MARGIN_MAX, math_floor(n)))
end

function M.setBottomMarginPct(pct)
    SUISettings:set(BOT_MARGIN_KEY,
        math_max(BOT_MARGIN_MIN, math_min(BOT_MARGIN_MAX, math_floor(pct))))
end

M.BOT_MARGIN_DEF  = BOT_MARGIN_DEF
M.BOT_MARGIN_MIN  = BOT_MARGIN_MIN
M.BOT_MARGIN_MAX  = BOT_MARGIN_MAX
M.BOT_MARGIN_STEP = BOT_MARGIN_STEP

-- Reading Stats Text Scale
local RS_TEXT_SCALE_KEY  = "simpleui_bar_rs_text_scale_pct"
local RS_TEXT_SCALE_DEF  = 100
local RS_TEXT_SCALE_MIN  = 50
local RS_TEXT_SCALE_MAX  = 200

function M.getRSTextScalePct()
    local v = SUISettings:get(RS_TEXT_SCALE_KEY)
    local n = tonumber(v)
    if not n then return RS_TEXT_SCALE_DEF end
    return math_max(RS_TEXT_SCALE_MIN, math_min(RS_TEXT_SCALE_MAX, math_floor(n)))
end

function M.setRSTextScalePct(pct)
    SUISettings:set(RS_TEXT_SCALE_KEY,
        math_max(RS_TEXT_SCALE_MIN, math_min(RS_TEXT_SCALE_MAX, math_floor(pct))))
end

M.RS_TEXT_SCALE_DEF  = RS_TEXT_SCALE_DEF
M.RS_TEXT_SCALE_MIN  = RS_TEXT_SCALE_MIN
M.RS_TEXT_SCALE_MAX  = RS_TEXT_SCALE_MAX
M.RS_TEXT_SCALE_STEP = SCALE_STEP

-- Navbar Icon Scale
local ICON_SCALE_KEY  = "simpleui_bar_icon_scale_pct"
local ICON_SCALE_DEF  = 100
local ICON_SCALE_MIN  = 50
local ICON_SCALE_MAX  = 200

function M.getIconScalePct()
    local v = SUISettings:get(ICON_SCALE_KEY)
    local n = tonumber(v)
    if not n then return ICON_SCALE_DEF end
    return math_max(ICON_SCALE_MIN, math_min(ICON_SCALE_MAX, math_floor(n)))
end

function M.setIconScalePct(pct)
    SUISettings:set(ICON_SCALE_KEY,
        math_max(ICON_SCALE_MIN, math_min(ICON_SCALE_MAX, math_floor(pct))))
end

M.ICON_SCALE_DEF  = ICON_SCALE_DEF
M.ICON_SCALE_MIN  = ICON_SCALE_MIN
M.ICON_SCALE_MAX  = ICON_SCALE_MAX
M.ICON_SCALE_STEP = SCALE_STEP

-- Navbar Label Scale
local NAVBAR_LABEL_SCALE_KEY  = "simpleui_bar_label_scale_pct"
local NAVBAR_LABEL_SCALE_DEF  = 100
local NAVBAR_LABEL_SCALE_MIN  = 50
local NAVBAR_LABEL_SCALE_MAX  = 200

function M.getNavbarLabelScalePct()
    local v = SUISettings:get(NAVBAR_LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return NAVBAR_LABEL_SCALE_DEF end
    return math_max(NAVBAR_LABEL_SCALE_MIN, math_min(NAVBAR_LABEL_SCALE_MAX, math_floor(n)))
end

function M.setNavbarLabelScalePct(pct)
    SUISettings:set(NAVBAR_LABEL_SCALE_KEY,
        math_max(NAVBAR_LABEL_SCALE_MIN, math_min(NAVBAR_LABEL_SCALE_MAX, math_floor(pct))))
end

M.NAVBAR_LABEL_SCALE_DEF  = NAVBAR_LABEL_SCALE_DEF
M.NAVBAR_LABEL_SCALE_MIN  = NAVBAR_LABEL_SCALE_MIN
M.NAVBAR_LABEL_SCALE_MAX  = NAVBAR_LABEL_SCALE_MAX
M.NAVBAR_LABEL_SCALE_STEP = SCALE_STEP

-- Global Font Scale (Style ▸ Text Size)
-- Multiplies SUIStyle's five FS_* typographic levels (title/subtitle/body/
-- detail/caption). Unlike the per-bar scales above, FS_* is baked into
-- module-level constants at sui_style.lua load time, so a change here only
-- takes full effect after a restart — mirrors the UI Font picker.
local FONT_SCALE_KEY  = "simpleui_style_font_scale_pct"
local FONT_SCALE_DEF  = 100
local FONT_SCALE_MIN  = 50
local FONT_SCALE_MAX  = 150

function M.getFontScalePct()
    local v = SUISettings:get(FONT_SCALE_KEY)
    local n = tonumber(v)
    if not n then return FONT_SCALE_DEF end
    return math_max(FONT_SCALE_MIN, math_min(FONT_SCALE_MAX, math_floor(n)))
end

function M.setFontScalePct(pct)
    SUISettings:set(FONT_SCALE_KEY,
        math_max(FONT_SCALE_MIN, math_min(FONT_SCALE_MAX, math_floor(pct))))
end

M.FONT_SCALE_DEF  = FONT_SCALE_DEF
M.FONT_SCALE_MIN  = FONT_SCALE_MIN
M.FONT_SCALE_MAX  = FONT_SCALE_MAX
M.FONT_SCALE_STEP = SCALE_STEP

-- Link Scale
function M.isScaleLinked()
    local v = SUISettings:get(SCALE_LINKED_KEY)
    return v == true  -- default false
end

function M.setScaleLinked(on)
    SUISettings:set(SCALE_LINKED_KEY, on)
end

-- Module Scale
function M.getModuleScale(mod_id, pfx)
    if mod_id and pfx and not M.isScaleLinked() then
        local v = SUISettings:get(_modKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clamp(n) / 100 end
    end
    local v = SUISettings:get(MODULE_SCALE_KEY)
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

-- Reads the user's saved percentage directly, ignoring ctx.landscape_factor
-- (callers of getModuleScale apply that themselves). See GridRenderer.build's
-- `cs` (engines/sui_book_grid.lua): its column width is already narrowed for
-- landscape, so applying landscape_factor to `cs` too would double-shrink it.
function M.getModuleScaleRaw(mod_id, pfx)
    if mod_id and pfx and not M.isScaleLinked() then
        local v = SUISettings:get(_modKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clamp(n) / 100 end
    end
    local v = SUISettings:get(MODULE_SCALE_KEY)
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getModuleScalePct(mod_id, pfx)
    if mod_id and pfx and not M.isScaleLinked() then
        local v = SUISettings:get(_modKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clamp(n) end
    end
    local v = SUISettings:get(MODULE_SCALE_KEY)
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setModuleScale(pct, mod_id, pfx)
    pct = _clamp(pct)
    if mod_id and pfx then
        SUISettings:set(_modKey(mod_id, pfx), pct)
    else
        SUISettings:set(MODULE_SCALE_KEY, pct)
        if M.isScaleLinked() then
            SUISettings:set(LABEL_SCALE_KEY, pct)
        end
    end
end

-- Thumbnail Scale
local THUMB_SCALE_KEY_SUFFIX = "_thumb_scale"

local function _thumbKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. (mod_id or "") .. THUMB_SCALE_KEY_SUFFIX
end

function M.getThumbScale(mod_id, pfx)
    local v = SUISettings:get(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

-- Same as getModuleScaleRaw, for the thumb scale setting.
function M.getThumbScaleRaw(mod_id, pfx)
    local v = SUISettings:get(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getThumbScalePct(mod_id, pfx)
    local v = SUISettings:get(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setThumbScale(pct, mod_id, pfx)
    SUISettings:set(_thumbKey(mod_id, pfx), _clamp(pct))
end

-- Element Scale — like Thumb Scale, but keyed by an extra `elem` name, for
-- modules with more than one independently-sizeable sub-element (e.g. the
-- clock module's clock face, date text, and battery text).
local ELEM_SCALE_KEY_SUFFIX = "_elem_scale"

local function _elemKey(mod_id, elem, pfx)
    return (pfx or "simpleui_hs_") .. (mod_id or "") .. "_" .. (elem or "") .. ELEM_SCALE_KEY_SUFFIX
end

function M.getElemScale(mod_id, elem, pfx)
    local v = SUISettings:get(_elemKey(mod_id, elem, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getElemScalePct(mod_id, elem, pfx)
    local v = SUISettings:get(_elemKey(mod_id, elem, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setElemScale(pct, mod_id, elem, pfx)
    SUISettings:set(_elemKey(mod_id, elem, pfx), _clamp(pct))
end

-- Label Scale
function M.getLabelScale()
    local v = SUISettings:get(LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getLabelScalePct()
    local v = SUISettings:get(LABEL_SCALE_KEY)
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setLabelScale(pct)
    SUISettings:set(LABEL_SCALE_KEY, _clamp(pct))
end

local _BASE_LABEL_TEXT_H = nil
function M.getScaledLabelH()
    if not _BASE_LABEL_TEXT_H then
        local ok, SUIStyle = pcall(require, "features/sui_style")
        local base_fs = (ok and SUIStyle and SUIStyle.FS_BODY) or 18  -- FS_BODY (18)
        _BASE_LABEL_TEXT_H = require("device").screen:scaleBySize(base_fs)
    end
    local PAD2  = require("infra/sui_core").PAD2
    local scale = M.getLabelScale()
    return PAD2 + math_max(8, math_floor(_BASE_LABEL_TEXT_H * scale))
end

-- Item Label Scale
function M.getItemLabelScale(mod_id, pfx)
    local v = SUISettings:get(_itemLabelKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return 1.0 end
    return _clamp(n) / 100
end

function M.getItemLabelScalePct(mod_id, pfx)
    local v = SUISettings:get(_itemLabelKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setItemLabelScale(pct, mod_id, pfx)
    SUISettings:set(_itemLabelKey(mod_id, pfx), _clamp(pct))
end

-- Reset Scales
function M.resetAllScales(pfx, pfx_qa)
    SUISettings:del(MODULE_SCALE_KEY)
    SUISettings:del(LABEL_SCALE_KEY)
    SUISettings:del(SCALE_LINKED_KEY)
    SUISettings:del(BAR_SIZE_KEY)
    SUISettings:del(TOPBAR_SIZE_KEY)
    SUISettings:del(NAVBAR_LABEL_SCALE_KEY)
    SUISettings:del("simpleui_bar_icon_scale_pct")
    SUISettings:del("simpleui_bar_rs_text_scale_pct")
    local Registry = require("modules/moduleregistry")
    for _, mod in ipairs(Registry.list()) do
        if mod.id then
            SUISettings:del((pfx or "simpleui_hs_") .. mod.id .. "_scale")
            SUISettings:del((pfx or "simpleui_hs_") .. mod.id .. THUMB_SCALE_KEY_SUFFIX)
            SUISettings:del(_itemLabelKey(mod.id, pfx))
            if mod.id == "clock" then
                SUISettings:del((pfx or "simpleui_hs_") .. "clock_clock_elem_scale")
                SUISettings:del((pfx or "simpleui_hs_") .. "clock_date_elem_scale")
                SUISettings:del((pfx or "simpleui_hs_") .. "clock_batt_elem_scale")
            end
        end
    end
    if pfx_qa then
        for slot = 1, 3 do
            SUISettings:del(pfx_qa .. slot .. "_scale")
            SUISettings:del(pfx_qa .. slot .. ITEM_LABEL_SCALE_SUFFIX)
        end
    end
end

M.SCALE_MIN  = SCALE_MIN
M.SCALE_MAX  = SCALE_MAX
M.SCALE_STEP = SCALE_STEP
M.SCALE_DEF  = SCALE_DEF
M.MODULE_SCALE_MIN  = SCALE_MIN
M.MODULE_SCALE_MAX  = SCALE_MAX
M.MODULE_SCALE_STEP = SCALE_STEP
M.MODULE_SCALE_DEF  = SCALE_DEF
M.LABEL_SCALE_MIN   = SCALE_MIN
M.LABEL_SCALE_MAX   = SCALE_MAX
M.LABEL_SCALE_STEP  = SCALE_STEP
M.LABEL_SCALE_DEF   = SCALE_DEF

-- SpinWidget Menu-Item Factory
function M.makeScaleItem(opts)
    local enabled_func = opts.enabled_func
    return {
        text_func      = opts.text_func,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        value_func     = function() return opts.get() .. "%" end,
        callback       = function()
            if enabled_func and not enabled_func() then
                local UIManager   = require("ui/uimanager")
                UI.Notify.toast(_("Disable \"Lock Scale\" first to set a per-module scale."))
                return
            end
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title,
                info_text     = opts.info,
                value         = opts.get(),
                value_min       = opts.value_min      or SCALE_MIN,
                value_max       = opts.value_max      or SCALE_MAX,
                value_step      = opts.value_step     or SCALE_STEP,
                value_hold_step = opts.value_hold_step,
                unit            = "%",
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

-- Backdrop opacity entry (0–100 %, labelled Transparent / N% / Solid),
-- shared by every surface drawn over the wallpaper. The dialog documents the
-- semantic default, which its reset button restores.
-- opts: {
--   title         — entry text and dialog title
--   get / set     — strength accessors (0–100)
--   refresh       — called with the touch menu once a value is applied
--   default_value — semantic default strength
--   info          — optional dialog description (generic one otherwise)
--   enabled_func  — optional menu enabled state
--   value_func    — optional override of the value label
--   _lc           — optional translator (defaults to the plugin translator)
-- }
function M.makeBackdropStrengthItem(opts)
    local _lc = opts._lc or _
    local function label(strength)
        return require("features/sui_wallpaper").formatBackdropStrength(strength, _lc)
    end
    return {
        text           = opts.title,
        enabled_func   = opts.enabled_func,
        keep_menu_open = true,
        value_func     = opts.value_func or function() return label(opts.get()) end,
        callback       = function(touchmenu)
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            local info = opts.info
                or _lc("0% transparent, 100% solid. Values in between add a scrim over the wallpaper.")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title,
                info_text     = info .. "\n" .. T(_lc("Default: %1"), label(opts.default_value)),
                value         = opts.get(),
                value_min     = 0,
                value_max     = 100,
                value_step    = 5,
                unit          = "%",
                ok_text       = _("Apply"),
                cancel_text   = _("Cancel"),
                default_value = opts.default_value,
                callback      = function(spin)
                    opts.set(spin.value)
                    opts.refresh(touchmenu)
                end,
            })
        end,
    }
end

-- Generic integer stepper (SpinWidget, no "%" suffix) — for small bounded
-- counts like grid rows/columns, where makeScaleItem's fixed "%" unit and
-- SCALE_MIN/MAX defaults don't apply. opts.unit defaults to "" (no suffix
-- shown after the number).
function M.makeStepperItem(opts)
    local unit = opts.unit or ""
    return {
        text_func      = opts.text_func,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        value_func     = function() return tostring(opts.get()) .. unit end,
        callback       = function()
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title,
                info_text     = opts.info,
                value         = opts.get(),
                value_min     = opts.value_min,
                value_max     = opts.value_max,
                value_step    = opts.value_step or 1,
                unit          = unit,
                ok_text       = _("Apply"),
                cancel_text   = _("Cancel"),
                default_value = opts.default_value,
                callback      = function(spin)
                    opts.set(spin.value)
                    opts.refresh()
                end,
            })
        end,
    }
end

-- Two integer steppers shown in the same dialog at once (DoubleSpinWidget) —
-- same widget/convention KOReader's own CoverBrowser plugin uses for
-- "Items per page in portrait/landscape mosaic mode" (columns + rows
-- together, one Apply). Prefer this over two separate makeStepperItem
-- entries whenever the two numbers are only meaningful as a pair.
function M.makeDoubleStepperItem(opts)
    return {
        text_func      = opts.text_func,
        value_func     = opts.value_func,
        mandatory_func = opts.mandatory_func,
        separator      = opts.separator or nil,
        -- Just like KOReader's own native item: no keep_menu_open, so you can
        -- see the result applying in the view behind.
        callback       = function()
            local DoubleSpinWidget = require("ui/widget/doublespinwidget")
            local UIManager        = require("ui/uimanager")
            local left_value, right_value = opts.left.get(), opts.right.get()
            UIManager:show(DoubleSpinWidget:new{
                title_text      = opts.title,
                width_factor    = opts.width_factor or 0.6,
                left_text       = opts.left.text,
                left_value      = left_value,
                left_min        = opts.left.value_min,
                left_max        = opts.left.value_max,
                left_default    = opts.left.default_value,
                left_precision  = "%01d",
                right_text      = opts.right.text,
                right_value     = right_value,
                right_min       = opts.right.value_min,
                right_max       = opts.right.value_max,
                right_default   = opts.right.default_value,
                right_precision = "%01d",
                keep_shown_on_apply = true,
                callback        = function(lv, rv)
                    opts.left.set(lv)
                    opts.right.set(rv)
                    opts.refresh()
                end,
            })
        end,
    }
end

-- Per-module Gaps
local GAP_MIN  = 0
local GAP_MAX  = 300
local GAP_STEP = 10
local GAP_DEF  = 100

M.GAP_MIN  = GAP_MIN
M.GAP_MAX  = GAP_MAX
M.GAP_STEP = GAP_STEP
M.GAP_DEF  = GAP_DEF

local function _gapKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. (mod_id or "") .. "_gap_pct"
end

local function _clampGap(n)
    return math_max(GAP_MIN, math_min(GAP_MAX, math_floor(n)))
end

function M.getModuleGapPx(mod_id, pfx, mod_gap_px)
    if mod_id and pfx then
        local v = SUISettings:get(_gapKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return math_floor(mod_gap_px * _clampGap(n) / 100) end
    end
    return mod_gap_px
end

function M.getModuleGapPct(mod_id, pfx)
    if mod_id and pfx then
        local v = SUISettings:get(_gapKey(mod_id, pfx))
        local n = tonumber(v)
        if n then return _clampGap(n) end
    end
    return GAP_DEF
end

function M.setModuleGap(pct, mod_id, pfx)
    if mod_id and pfx then
        SUISettings:set(_gapKey(mod_id, pfx), _clampGap(pct))
    end
end

function M.makeGapItem(opts)
    return {
        text_func      = opts.text_func,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        value_func     = function() return opts.get() .. "%" end,
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


-- Per-module column width (bento grid). Percent of the homescreen row
-- this module occupies in portrait. 100 = full width (default). Modules
-- under 100% whose widths fit side-by-side share a row automatically.
local BENTO_MIN  = 20
local BENTO_MAX  = 100
local BENTO_STEP = 5
local BENTO_DEF  = 100

local function _bentoKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. "bento_width_" .. (mod_id or "")
end

local function _clampBento(n)
    n = math_floor(tonumber(n) or BENTO_DEF)
    if n < BENTO_MIN then n = BENTO_MIN elseif n > BENTO_MAX then n = BENTO_MAX end
    -- Snap to step.
    n = math_floor((n + BENTO_STEP / 2) / BENTO_STEP) * BENTO_STEP
    if n < BENTO_MIN then n = BENTO_MIN elseif n > BENTO_MAX then n = BENTO_MAX end
    return n
end

function M.getBentoWidth(mod_id, pfx)
    if not mod_id then return BENTO_DEF end
    local v = SUISettings:get(_bentoKey(mod_id, pfx))
    if v == nil then
        -- One-shot migration from the old userpatch key (G_reader_settings).
        local legacy = _G.G_reader_settings and _G.G_reader_settings:readSetting("simpleui_bento_width_" .. mod_id)
        if legacy ~= nil then
            local n = _clampBento(legacy)
            M.setBentoWidth(n, mod_id, pfx)
            return n
        end
        return BENTO_DEF
    end
    return _clampBento(v)
end

function M.setBentoWidth(pct, mod_id, pfx)
    if mod_id and pfx then
        SUISettings:set(_bentoKey(mod_id, pfx), _clampBento(pct))
    end
end

function M.makeBentoWidthItem(opts)
    return {
        text_func      = opts.text_func or function() return _("Column Width (Bento Grid)") end,
        separator      = opts.separator or nil,
        keep_menu_open = true,
        value_func     = function() return opts.get() .. "%" end,
        callback       = function()
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager  = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text    = opts.title or _("Column Width (Bento Grid)"),
                info_text     = opts.info or _("Share of the row this module occupies.\n100% = full width. Modules under 100% share a row when their widths fit (bento grid)."),
                value         = opts.get(),
                value_min     = BENTO_MIN,
                value_max     = BENTO_MAX,
                value_step    = BENTO_STEP,
                unit          = "%",
                ok_text       = _("Apply"),
                cancel_text   = _("Cancel"),
                default_value = BENTO_DEF,
                callback      = function(spin)
                    opts.set(spin.value)
                    opts.refresh()
                end,
            })
        end,
    }
end


-- ---------------------------------------------------------------------------
-- Module Settings Chrome — Top Margin + Column Width
-- Every module's settings screen ends with these two items, regardless of
-- which window built that screen (long-press on a module vs the Settings ▸
-- Modules screen). Single source of truth for the pair, so the different
-- windows that show module settings can't drift out of sync on which items
-- are shown or how they're wired.
--
-- opts: {
--   mod       — module descriptor (id, name, no_top_margin)
--   pfx       — settings-key prefix for the screen the items belong to
--   refresh   — ctx_menu-style refresh; must already repaint the caller's
--               window (see SUIWindow.withRepaint) or the new value won't
--               show until the window is reopened
--   on_change — optional extra work to run after either value is set,
--               e.g. invalidating a live screen's module-list cache
-- }
-- ---------------------------------------------------------------------------
function M.appendModuleChromeItems(items, opts)
    local mod, pfx, refresh, on_change = opts.mod, opts.pfx, opts.refresh, opts.on_change
    local _lc = opts._lc or _

    -- Per-module Appearance: merge Frame + Background into existing submenu
    -- when the module already provides one; otherwise append a new one.
    do
        local ok, Chrome = pcall(require, "features/sui_module_chrome")
        if ok and Chrome and mod and mod.id then
            Chrome.mergeAppearanceIntoItems(items, pfx, mod.id, refresh, _lc)
        end
    end

    if not mod.no_top_margin then
        items[#items + 1] = M.makeGapItem({
            text_func = function() return _("Top Margin") end,
            title     = mod.name or mod.id,
            info      = _("Vertical space above this module.\n100% is the default spacing."),
            get       = function() return M.getModuleGapPct(mod.id, pfx) end,
            set       = function(v)
                M.setModuleGap(v, mod.id, pfx)
                if on_change then on_change() end
            end,
            refresh   = refresh,
        })
    end
    items[#items + 1] = M.makeBentoWidthItem({
        get     = function() return M.getBentoWidth(mod.id, pfx) end,
        set     = function(v)
            M.setBentoWidth(v, mod.id, pfx)
            if on_change then on_change() end
        end,
        refresh = refresh,
    })
    return items
end

-- Module Labels (Section Title) Toggle
local function _labelHideKey(mod_id)
    return "simpleui_hide_label_" .. (mod_id or "")
end

function M.isLabelHidden(mod_id)
    return SUISettings:get(_labelHideKey(mod_id)) == true
end

function M.applyLabelToggle(mod, default_label)
    if M.isLabelHidden(mod.id) then
        mod.label = nil
    else
        mod.label = default_label
    end
end

-- ===========================================================================
-- Cover Hold Mode — long-press behaviour for modules with book covers.
-- "book_dialog" (default) opens a per-book action dialog
-- (features/library/sui_book_hold_dialog.lua) when the hold lands on an
-- actual book cover; holding on empty module space still falls back to the
-- settings screen (see sui_homescreen.lua's HoldMod/HoldModRelease, which
-- only fires when the inner per-cell hold did not consume the gesture).
-- "settings" keeps the older behaviour: hold anywhere on the module opens
-- its settings screen instead.
-- ===========================================================================
local COVER_HOLD_MODE_DEFAULT = "book_dialog"

local function _coverHoldModeKey(mod_id, pfx)
    return (pfx or "simpleui_hs_") .. (mod_id or "") .. "_cover_hold_mode"
end

function M.getCoverHoldMode(mod_id, pfx)
    if not mod_id then return COVER_HOLD_MODE_DEFAULT end
    local v = SUISettings:get(_coverHoldModeKey(mod_id, pfx))
    if v == "book_dialog" or v == "settings" then return v end
    return COVER_HOLD_MODE_DEFAULT
end

function M.setCoverHoldMode(mode, mod_id, pfx)
    if mod_id then
        SUISettings:set(_coverHoldModeKey(mod_id, pfx),
            mode == "book_dialog" and "book_dialog" or "settings")
    end
end

-- Shared menu entry, meant to be inserted once per cover-bearing module's
-- getMenuItems(). opts: { mod_id, pfx, refresh, _lc, book_dialog_label }
-- book_dialog_label overrides the default "Book Menu" text — used by
-- Collections, where holding a cover opens a "set cover / module settings"
-- dialog rather than the per-book actions dialog.
function M.makeCoverHoldModeItem(opts)
    local _lc     = opts._lc or _
    local mod_id  = opts.mod_id
    local pfx     = opts.pfx
    local refresh = opts.refresh
    local settings_label = _lc("Module Settings")
    local dialog_label   = opts.book_dialog_label or _lc("Book Menu")
    return {
        text_func  = function() return _lc("Long Press") end,
        value_func = function()
            return M.getCoverHoldMode(mod_id, pfx) == "book_dialog" and dialog_label or settings_label
        end,
        mandatory_func = function()
            return M.getCoverHoldMode(mod_id, pfx) == "book_dialog" and dialog_label or settings_label
        end,
        sub_item_table_func = function()
            return {
                {
                    text           = settings_label,
                    checked_func   = function() return M.getCoverHoldMode(mod_id, pfx) == "settings" end,
                    keep_menu_open = true,
                    callback       = function()
                        M.setCoverHoldMode("settings", mod_id, pfx)
                        if refresh then refresh() end
                    end,
                },
                {
                    text           = dialog_label,
                    checked_func   = function() return M.getCoverHoldMode(mod_id, pfx) == "book_dialog" end,
                    keep_menu_open = true,
                    callback       = function()
                        M.setCoverHoldMode("book_dialog", mod_id, pfx)
                        if refresh then refresh() end
                    end,
                },
            }
        end,
    }
end

-- Generic N-way radio submenu ("Type: X →" row that opens a list of radio
-- choices), extracted from the get/set/refresh shape already used above by
-- makeCoverHoldModeItem. Any settings-menu consumer with more than an on/off
-- toggle (a style/type/color picker) can reuse this instead of hand-rolling
-- its own sub_item_table_func.
--
-- opts:
--   text          string    static row label (ignored if text_func given)
--   text_func     function? () -> string, overrides `text`
--   options       { { value = any, label = string }, ... }  (required,
--                 ordered — this order is also the menu order)
--   get           function() -> current value (required)
--   set           function(value)  (required)
--   refresh       function?  called after set()
--   enabled_func  function?  disables the whole row (e.g. "Color" greyed out
--                 while the parent "Type" is "None")
--   separator     bool?
-- Both the row's value_func and mandatory_func show the current option's
-- label, matching the convention already used for "Long Press" above and
-- for Sort/native KOReader radio rows in general.
function M.makeRadioSubmenuItem(opts)
    local get     = opts.get
    local set     = opts.set
    local refresh = opts.refresh
    local function _labelFor(v)
        for _, o in ipairs(opts.options) do
            if o.value == v then return o.label end
        end
        return ""
    end
    return {
        text_func      = opts.text_func or function() return opts.text end,
        value_func     = function() return _labelFor(get()) end,
        mandatory_func = function() return _labelFor(get()) end,
        enabled_func   = opts.enabled_func,
        separator      = opts.separator,
        sub_item_table_func = function()
            local items = {}
            for _, o in ipairs(opts.options) do
                items[#items + 1] = {
                    text           = o.label,
                    radio          = true,
                    checked_func   = function() return get() == o.value end,
                    keep_menu_open = true,
                    callback       = function()
                        set(o.value)
                        if refresh then refresh() end
                    end,
                }
            end
            return items
        end,
    }
end

function M.makeLabelToggleItem(mod_id, default_label, refresh, _lc)
    return {
        text           = _lc("Show section label"),
        checked_func   = function() return not M.isLabelHidden(mod_id) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:set(_labelHideKey(mod_id),
                not M.isLabelHidden(mod_id) and true or nil)
            refresh()
        end,
    }
end

-- ===========================================================================
-- 6. Cover Management & Caching
-- ===========================================================================

M.cover_extraction_pending = false
M._cover_extract_queue   = {}
M._cover_extract_pending = {}
M._cover_extract_specs   = {}

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

-- "No cover" probe set — remembers which filepaths are known to have no
-- extractable cover, so a repeated request for the same book doesn't hit
-- BookInfoManager again every time. This used to double up inside the old
-- exact-size cover cache (_bim_cover_cache, removed below alongside
-- M.getCoverBB — see the "Cover API" section further down for what
-- replaced it); now that table is gone this is genuinely all this table
-- ever holds, so it's bounded by ENTRY COUNT rather than the byte-budget
-- machinery that made sense when the table also held real cover bbs of
-- very different sizes. Entries here are just filepath strings — tiny and
-- roughly uniform — so a simple count cap is the right unit.
local _NO_COVER_MAX_ENTRIES = 2000
local _no_cover_probe = {}   -- filepath -> true
local _no_cover_order = {}   -- filepaths, oldest at front, MRU at back
local _RenderImage = nil
local _lfs_cover   = nil  -- lazy-loaded lfs for filepath validation

local function _lfsMode(fp)
    if not _lfs_cover then
        local ok, l = pcall(require, "libs/libkoreader-lfs")
        if not (ok and l) then return nil end
        _lfs_cover = l
    end
    return _lfs_cover.attributes(fp, "mode")
end

-- Resident byte size of a cached cover bb. stride * height is the true RAM
-- footprint of the underlying C allocation (including row padding), and it
-- scales correctly with bit depth (1 B/px grayscale e-ink vs 4 B/px RGB32)
-- without this cache needing to know the device/panel type.
local function _bbBytes(bb)
    if not bb then return 0 end
    local ok, n = pcall(function()
        local h = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride and h > 0 then return stride * h end
        local w   = (bb.getWidth and bb:getWidth()) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return w * h * math.ceil(bpp / 8)
    end)
    return (ok and n) or 0
end

-- isCoverMissing(filepath) is queried from both cover APIs below on every
-- request, so it must be a plain, correct membership test.
function M.isCoverMissing(filepath) return _no_cover_probe[filepath] == true end

local function _markNoCover(filepath)
    if _no_cover_probe[filepath] then return end
    _no_cover_probe[filepath] = true
    _no_cover_order[#_no_cover_order + 1] = filepath
    if #_no_cover_order > _NO_COVER_MAX_ENTRIES then
        local oldest = table.remove(_no_cover_order, 1)
        _no_cover_probe[oldest] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Reference-cover cache — the crop-to-fill counterpart to
-- infra/sui_cover_cache.lua's stretch-only one. Backs
-- Config.getCroppedCoverBB, used by every consumer that needs a target
-- shape OTHER than the fixed 3:2 the stretch-only cache assumes:
-- Collections' Quad style (~1:1 quadrants, a 2x2 collage where every
-- quadrant must fill its box with no letterbox gaps) and CoverDeck's
-- near/far "peek" slots (deliberately narrower-than-3:2 slivers meant to
-- look like the visible edge of a book partly hidden behind the centre
-- cover — see module_coverdeck.lua's side_w/h and far_w/h, which are NOT
-- 3:2). Both need an actual crop, not a resize, or the illusion each is
-- built on breaks: a collage with letterboxed gaps, or a "peeking" cover
-- that's visibly squashed into the sliver instead of just showing a
-- cropped slice of it. Every OTHER consumer in the plugin (including
-- CoverDeck's own centre slot, which genuinely is 3:2) went stretch-only
-- in the migration that replaced the old getCoverBB, and shares ONE
-- filepath-keyed entry via SUICoverCache instead — see that module's
-- header for why crop and stretch can't share a cache: crop is a framing
-- decision tied to a specific target shape, stretch isn't.
--
-- What this layer still caches: bookinfo.cover_bb downscaled ONCE, aspect
-- preserved, no crop, to fit within _REF_MAX_DIM on its longer side.
-- getCroppedCoverBB crops FROM this shared, modest-sized reference instead
-- of from BIM's raw cover_bb, which can be arbitrarily large (some
-- embedded cover art scans at 1500px+ on the long side) — so a book
-- visible in several crop-shaped slots only pays that decode/downscale
-- once per session, not once per slot.
-- ---------------------------------------------------------------------------
local _REF_MAX_DIM     = 480               -- long-side cap in px; plenty for any on-screen slot
local _REF_BYTE_BUDGET = 4 * 1024 * 1024   -- small: bounded per-entry size, few concurrent books need it
local _bim_ref_cache = {}   -- filepath -> { bb, bytes }
local _bim_ref_order = {}   -- filepaths, oldest at front, MRU at back
local _bim_ref_bytes = 0

local function _removeRefOrderKey(key)
    for i, k in ipairs(_bim_ref_order) do
        if k == key then table.remove(_bim_ref_order, i); return end
    end
end

local function _evictRefIfNeeded()
    while #_bim_ref_order > 1 and _bim_ref_bytes > _REF_BYTE_BUDGET do
        local key = table.remove(_bim_ref_order, 1)
        local entry = _bim_ref_cache[key]
        _bim_ref_cache[key] = nil
        if entry then
            _bim_ref_bytes = _bim_ref_bytes - (entry.bytes or 0)
            if _bim_ref_bytes < 0 then _bim_ref_bytes = 0 end
        end
    end
end

local function _ensureRenderImage()
    if not _RenderImage then
        local ok, ri = pcall(require, "ui/renderimage")
        if ok and ri then _RenderImage = ri end
    end
    return _RenderImage
end

-- Returns a bb that's safe to use as _scaleBBToSlot's source for `filepath`:
-- the raw bb itself when it's already small (no point caching a second copy
-- no bigger than the reference would be), or a cached downscaled copy
-- otherwise. Never crops -- only ever a uniform scale-to-fit within
-- _REF_MAX_DIM -- so the result stays a valid source for ANY target shape.
local function _getRefCoverBB(filepath, raw_bb)
    local cached = _bim_ref_cache[filepath]
    if cached then
        _removeRefOrderKey(filepath)
        _bim_ref_order[#_bim_ref_order + 1] = filepath
        return cached.bb
    end

    local src_w, src_h = raw_bb:getWidth(), raw_bb:getHeight()
    if src_w <= 0 or src_h <= 0 or (src_w <= _REF_MAX_DIM and src_h <= _REF_MAX_DIM) then
        return raw_bb
    end
    if not _ensureRenderImage() then return raw_bb end

    local scale = math_min(_REF_MAX_DIM / src_w, _REF_MAX_DIM / src_h)
    local ref_w = math_max(1, math_floor(src_w * scale + 0.5))
    local ref_h = math_max(1, math_floor(src_h * scale + 0.5))

    -- Never hand `raw_bb` itself to scaleBlitBuffer: it's bookinfo.cover_bb,
    -- BookInfoManager's OWN persistent cache entry for this file — shared
    -- with KOReader core and every other consumer, not something this
    -- module can risk letting scaleBlitBuffer dispose of internally (see
    -- the same guard in _scaleBBToSlot above for the full rationale). Scale
    -- a disposable copy instead.
    local ok_cp, cp_bb = pcall(Blitbuffer.new, src_w, src_h, raw_bb:getType())
    if not (ok_cp and cp_bb) then return raw_bb end
    pcall(cp_bb.blitFrom, cp_bb, raw_bb, 0, 0, 0, 0, src_w, src_h)

    local ok_sc, ref_bb = pcall(_RenderImage.scaleBlitBuffer, _RenderImage, cp_bb, ref_w, ref_h)
    if ref_bb ~= cp_bb then pcall(cp_bb.free, cp_bb) end
    if not (ok_sc and ref_bb) then return raw_bb end

    local nbytes = _bbBytes(ref_bb)
    _bim_ref_cache[filepath] = { bb = ref_bb, bytes = nbytes }
    _bim_ref_order[#_bim_ref_order + 1] = filepath
    _bim_ref_bytes = _bim_ref_bytes + nbytes
    _evictRefIfNeeded()
    return ref_bb
end

local function _scaleBBToSlot(bb, target_w, target_h, align)
    if not _ensureRenderImage() then return bb end
    local src_w, src_h = bb:getWidth(), bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return bb end
    if src_w == target_w and src_h == target_h then
        local ok_copy, copy_bb = pcall(Blitbuffer.new, target_w, target_h, bb:getType())
        if ok_copy and copy_bb then
            pcall(copy_bb.blitFrom, copy_bb, bb, 0, 0, 0, 0, target_w, target_h)
            return copy_bb
        end
        return bb
    end

    -- `bb` is very often a long-lived buffer this module owns and reuses on
    -- every future call for the same book (the reference cover cache — see
    -- _getRefCoverBB above). This function must never hand `bb` itself to
    -- RenderImage:scaleBlitBuffer(): that call's disposal behaviour for its
    -- source buffer isn't something safe to assume here, and getting it
    -- wrong once corrupts every future request for this book (loads fine
    -- the first time, "TV static"/garbage on every subsequent repaint —
    -- exactly the class of bug this guards against). So this function
    -- always scales a disposable COPY of `bb` instead of `bb` itself — cheap,
    -- since sources here are already bounded to _REF_MAX_DIM — and never
    -- frees or otherwise touches `bb`.
    -- Every OTHER buffer below (work_bb, scaled_bb, slot_bb) is created and
    -- fully owned by this function, so freeing it once it's no longer
    -- needed is always safe.
    local ok_src, work_bb = pcall(Blitbuffer.new, src_w, src_h, bb:getType())
    if not (ok_src and work_bb) then return bb end
    pcall(work_bb.blitFrom, work_bb, bb, 0, 0, 0, 0, src_w, src_h)


    -- No elastic-stretch tolerance branch here anymore: the only remaining
    -- caller (Config.getCroppedCoverBB) always wants crop-to-fill, unconditionally
    -- — the ~1:1 Quad quadrants never sit within any sane tolerance of a
    -- typical book-cover aspect anyway, so the old tolerance check never
    -- actually fired for this caller in practice.
    local scale_factor = math_max(target_w / src_w, target_h / src_h)
    -- Clamp UP to target_w/target_h: floor(...+0.5) can round 1px short of
    -- the target on either axis due to floating-point error (e.g.
    -- target_h/src_h not being the exact inverse when multiplied back out).
    -- If that happens, src_x/src_y below go negative and blitFrom() reads
    -- target_w×target_h pixels starting before the start of scaled_bb's
    -- memory — i.e. out-of-bounds reads of adjacent heap memory, which is
    -- exactly the "TV static" corruption this guards against. Only ever
    -- shows up for small/odd target sizes (e.g. module_collections.lua's
    -- Quad cover quadrants, ~55×80px) — round-number sizes used elsewhere
    -- never happened to hit this rounding edge case.
    local scaled_w = math_max(target_w, math_floor(src_w * scale_factor + 0.5))
    local scaled_h = math_max(target_h, math_floor(src_h * scale_factor + 0.5))
    local ok_sc, scaled_bb = pcall(_RenderImage.scaleBlitBuffer, _RenderImage, work_bb, scaled_w, scaled_h)
    if not (ok_sc and scaled_bb) then
        if work_bb ~= bb then pcall(work_bb.free, work_bb) end
        return bb
    end
    if scaled_bb ~= work_bb then pcall(work_bb.free, work_bb) end

    if scaled_w == target_w and scaled_h == target_h then return scaled_bb end

    local ok_slot, slot_bb = pcall(Blitbuffer.new, target_w, target_h, scaled_bb:getType())
    if not (ok_slot and slot_bb) then return scaled_bb end
    local src_x = align == "left" and 0 or (align == "right" and scaled_w - target_w or math_floor((scaled_w - target_w) / 2))
    local src_y = math_floor((scaled_h - target_h) / 2)
    -- Belt-and-braces: never let a negative offset reach blitFrom(), whatever
    -- its source (the clamp above should already prevent this).
    src_x = math_max(0, src_x)
    src_y = math_max(0, src_y)
    pcall(slot_bb.blitFrom, slot_bb, scaled_bb, 0, 0, src_x, src_y, target_w, target_h)
    pcall(scaled_bb.free, scaled_bb)
    return slot_bb
end

-- ---------------------------------------------------------------------------
-- Cover API — the ONLY cover-loading entry points in this module. Two
-- entry points, one per shape family (see infra/sui_cover_cache.lua's
-- header for why they can't share one cache):
--
--   M.getStretchedCoverBB(filepath, w, h)
--       For the fixed-3:2, no-crop consumers (Recent, TBR, New Books,
--       Library, Currently, CoverDeck's centre slot, Collections' Single
--       style). Backed by infra/sui_cover_cache.lua — one filepath-keyed
--       entry per book, held at the LARGEST (w, h) requested so far this
--       session. A hit whose bb is already >= the requested size is
--       returned AS-IS, possibly larger than asked — the caller is
--       expected to build its ImageWidget with its own width/height and no
--       scale_factor, so the downscale happens at paint time. A miss (or a
--       cached bb that's too small) decodes fresh from BookInfoManager and
--       stretches to EXACTLY (w, h) — never crops, never letterboxes.
--
--   M.getCroppedCoverBB(filepath, w, h, align)
--       For every consumer that needs a target shape OTHER than 3:2 and
--       must fill it edge-to-edge with no distortion: Collections' Quad
--       style (~1:1 quadrants, a 2x2 collage where every quadrant needs to
--       fill its box with no gaps) and CoverDeck's near/far "peek" slots
--       (deliberately narrow, non-3:2 slivers meant to look like a book
--       partly hidden behind the centre cover — see
--       module_coverdeck.lua's side_w/h and far_w/h). Reuses
--       _getRefCoverBB/_scaleBBToSlot above unchanged: crops fresh from
--       the shared, bounded, uncropped per-book reference on every call.
--       Always returns exactly (w, h).
-- ---------------------------------------------------------------------------

-- Shared enqueue-for-background-extraction helper for both cover functions
-- above.
local function _enqueueCoverExtract(filepath, w, h)
    if M._cover_extract_pending[filepath] then
        local ex = M._cover_extract_specs[filepath]
        if ex then
            if w > ex.max_cover_w then ex.max_cover_w = w end
            if h > ex.max_cover_h then ex.max_cover_h = h end
        end
        return
    end
    M._cover_extract_pending[filepath] = true
    M._cover_extract_specs[filepath]   = { max_cover_w = w, max_cover_h = h }
    if not M._cover_extract_queue then M._cover_extract_queue = {} end
    M._cover_extract_queue[#M._cover_extract_queue + 1] = filepath
end

-- True when BIM's cached thumbnail is smaller than this slot needs and the
-- original cover can yield a larger one (Cover Browser list-mode specs, etc.).
local function _coverTooSmall(bim, bookinfo, w, h)
    if not (bim and bookinfo and bookinfo.has_cover) then return false end
    if type(bim.isCachedCoverInvalid) ~= "function" then return false end
    return bim.isCachedCoverInvalid(bookinfo, {
        max_cover_w = w,
        max_cover_h = h,
    }) and true or false
end

-- Drop stretch + ref entries so a later put after re-extract can install the
-- higher-quality bb (prefer-larger alone keeps same pixel-count upscales).
local function _dropLocalCoverCaches(filepath)
    SUICoverCache:drop(filepath)
    local entry = _bim_ref_cache[filepath]
    if not entry then return end
    _removeRefOrderKey(filepath)
    _bim_ref_cache[filepath] = nil
    _bim_ref_bytes = _bim_ref_bytes - (entry.bytes or 0)
    if _bim_ref_bytes < 0 then _bim_ref_bytes = 0 end
end

-- Stretches `raw_bb` (bookinfo.cover_bb — BookInfoManager's own persistent
-- entry for this file, shared with KOReader core) to exactly
-- target_w x target_h, aspect NOT preserved. Never hands raw_bb itself to
-- scaleBlitBuffer: same ownership rule already documented on
-- _getRefCoverBB/_scaleBBToSlot above — this module can't assume how
-- scaleBlitBuffer disposes of its source, and raw_bb is not this module's
-- to give away. Always scales a disposable copy instead.
local function _stretchBBToSize(raw_bb, target_w, target_h)
    local src_w, src_h = raw_bb:getWidth(), raw_bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return raw_bb end

    local ok_cp, cp_bb = pcall(Blitbuffer.new, src_w, src_h, raw_bb:getType())
    if not (ok_cp and cp_bb) then return raw_bb end
    pcall(cp_bb.blitFrom, cp_bb, raw_bb, 0, 0, 0, 0, src_w, src_h)

    if src_w == target_w and src_h == target_h then
        return cp_bb  -- already the right size; the copy above IS the result
    end

    if not _ensureRenderImage() then pcall(cp_bb.free, cp_bb); return raw_bb end
    local ok_sc, stretched_bb = pcall(_RenderImage.scaleBlitBuffer, _RenderImage, cp_bb, target_w, target_h)
    if not (ok_sc and stretched_bb) then
        pcall(cp_bb.free, cp_bb)
        return raw_bb
    end
    if stretched_bb ~= cp_bb then pcall(cp_bb.free, cp_bb) end
    return stretched_bb
end

function M.getStretchedCoverBB(filepath, w, h)
    if M.isCoverMissing(filepath) then return nil end

    -- Reject non-regular-file paths before the extractor (can segfault).
    if _lfsMode(filepath) ~= "file" then _markNoCover(filepath); return nil end

    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(bim.getBookInfo, bim, filepath, true)

    if not ok then
        _enqueueCoverExtract(filepath, w, h)
        M.cover_extraction_pending = true
        return nil
    end
    if bookinfo and bookinfo.cover_fetched then
        if bookinfo.has_cover and bookinfo.cover_bb then
            -- List-mode / undersized BIM thumbnail: show stretched placeholder
            -- and re-extract larger. Drop local caches so the upgraded bb can
            -- replace a same-size upscale (prefer-larger is pixel-count only).
            if _coverTooSmall(bim, bookinfo, w, h) then
                local placeholder = SUICoverCache:get(filepath)
                _dropLocalCoverCaches(filepath)
                _enqueueCoverExtract(filepath, w, h)
                M.cover_extraction_pending = true
                if placeholder and placeholder:getWidth() >= w
                        and placeholder:getHeight() >= h then
                    return placeholder
                end
                return _stretchBBToSize(bookinfo.cover_bb, w, h)
            end
            M._cover_extract_pending[filepath] = nil
            local cached = SUICoverCache:get(filepath)
            if cached and cached:getWidth() >= w and cached:getHeight() >= h then
                return cached
            end
            local bb = _stretchBBToSize(bookinfo.cover_bb, w, h)
            return SUICoverCache:put(filepath, bb)
        else
            M._cover_extract_pending[filepath] = nil; _markNoCover(filepath); return nil
        end
    end
    _enqueueCoverExtract(filepath, w, h)
    if M._cover_extract_pending[filepath] then M.cover_extraction_pending = true end
    return nil
end

function M.getCroppedCoverBB(filepath, w, h, align)
    if M.isCoverMissing(filepath) then return nil end

    if _lfsMode(filepath) ~= "file" then _markNoCover(filepath); return nil end

    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(bim.getBookInfo, bim, filepath, true)

    if not ok then
        _enqueueCoverExtract(filepath, w, h)
        M.cover_extraction_pending = true
        return nil
    end
    if bookinfo and bookinfo.cover_fetched then
        if bookinfo.has_cover and bookinfo.cover_bb then
            if _coverTooSmall(bim, bookinfo, w, h) then
                _dropLocalCoverCaches(filepath)
                _enqueueCoverExtract(filepath, w, h)
                M.cover_extraction_pending = true
                -- Crop placeholder from the small source (no ref cache).
                return _scaleBBToSlot(bookinfo.cover_bb, w, h, align)
            end
            M._cover_extract_pending[filepath] = nil
            -- Shared uncropped ref; crop fresh so callers can differ on align.
            local ref_bb = _getRefCoverBB(filepath, bookinfo.cover_bb)
            return _scaleBBToSlot(ref_bb, w, h, align)
        else
            M._cover_extract_pending[filepath] = nil; _markNoCover(filepath); return nil
        end
    end
    _enqueueCoverExtract(filepath, w, h)
    if M._cover_extract_pending[filepath] then M.cover_extraction_pending = true end
    return nil
end

function M.clearCoverCache()
    -- Stretch-only cache (infra/sui_cover_cache.lua) — cheap, unconditional:
    -- clear()'s own contract is already "drop references, don't free()"
    -- (see that module), so no deferred-sweep coordination is needed here.
    SUICoverCache:clear()

    -- No-cover probes hold no bb payload (just filepath markers) — nothing
    -- to free, reset synchronously.
    _no_cover_probe = {}
    _no_cover_order = {}

    -- Reference cover cache (backs Config.getCroppedCoverBB) is the only
    -- remaining table here that holds real blitbuffers. It's never handed
    -- to any ImageWidget outside this module (see _getRefCoverBB) — it only
    -- ever serves as _scaleBBToSlot's source, and that call already
    -- copies/crops the pixels it needs before returning, so nothing outside
    -- holds a reference to these entries. Safe to free on a deferred sweep.
    if next(_bim_ref_cache) == nil then return end

    local to_free = _bim_ref_cache
    _bim_ref_cache = {}; _bim_ref_order = {}; _bim_ref_bytes = 0
    _RenderImage = nil

    local UIManager = require("ui/uimanager")
    local function freeNext()
        local k, entry = next(to_free)
        if not k then return end
        pcall(function() entry.bb:free() end); to_free[k] = nil
        if next(to_free) then UIManager:scheduleIn(0.1, freeNext) end
    end
    UIManager:scheduleIn(0.1, freeNext)
end

function M.flushCoverQueue()
    local queue = M._cover_extract_queue
    if not queue or #queue == 0 then return end
    M._cover_extract_queue = {}
    local bim = M.getBookInfoManager()
    if not bim then
        for _, fp in ipairs(queue) do M._cover_extract_pending[fp] = nil; M._cover_extract_specs[fp] = nil end
        return
    end
    local files = {}
    for _, fp in ipairs(queue) do
        local specs = M._cover_extract_specs[fp]
        M._cover_extract_specs[fp] = nil
        if _lfsMode(fp) ~= "file" then
            M._cover_extract_pending[fp] = nil
        else
            -- Skip files that already have a usable cached cover: avoids
            -- re-queuing (and wiping) complete rows when only one new file
            -- needs extraction. extractInBackground applies the same filter.
            local skip = false
            local ok_bi, bi = pcall(bim.getBookInfo, bim, fp, false)
            if ok_bi and bi and bi.cover_fetched then
                local invalid = bi.has_cover and specs
                    and type(bim.isCachedCoverInvalid) == "function"
                    and bim.isCachedCoverInvalid(bi, specs)
                if not invalid then
                    skip = true
                    M._cover_extract_pending[fp] = nil
                end
            end
            if not skip then
                files[#files + 1] = { filepath = fp, cover_specs = specs }
            end
        end
    end
    if #files == 0 then return end
    local ok = pcall(bim.extractInBackground, bim, files)
    if not ok then
        for _, entry in ipairs(files) do
            M._cover_extract_pending[entry.filepath] = nil
        end
    end
end

-- ===========================================================================
-- 7. System & Device Helpers
-- ===========================================================================

-- Topbar config cache
local _topbar_cfg_menu_cache = nil
function M.getTopbarConfigCached()
    if not _topbar_cfg_menu_cache then _topbar_cfg_menu_cache = M.getTopbarConfig() end
    return _topbar_cfg_menu_cache
end
function M.invalidateTopbarConfigCache() _topbar_cfg_menu_cache = nil end

-- Stats Database
local _SQ3, _lfs_mod, _indexes_created = nil, nil, false
-- Blocks openStatsDB while a Statistics cloud sync is running.
-- Set by ScreenEngine.prepareForStatsSync; cleared by finishStatsSync.
local _stats_sync_guard = false

function M.getStatsDbPath() return DataStorage:getSettingsDir() .. "/statistics.sqlite3" end

-- Resolves book.md5 → book.id. ORDER BY last_open DESC picks the most
-- recently active row when the same file has more than one entry.
-- Embed via string.format; do not execute as-is.
M.BOOK_ID_BY_MD5_SQL = "SELECT id FROM book WHERE md5 = '%s' ORDER BY last_open DESC LIMIT 1"

local function _ensureSqlite()
    if not _SQ3 then
        local ok, s = pcall(require, "lua-ljsqlite3/init")
        if not ok or not s then return false end
        _SQ3 = s
    end
    if not _lfs_mod then
        local ok, l = pcall(require, "libs/libkoreader-lfs")
        if not ok or not l then return false end
        _lfs_mod = l
    end
    return true
end

-- Merges the WAL into the main DB file so a plain copy/upload of
-- statistics.sqlite3 includes every committed row. Uses a private handle
-- that is not subject to _stats_sync_guard.
function M.checkpointStatsDB()
    if not _ensureSqlite() then return end
    local db_path = M.getStatsDbPath()
    if not _lfs_mod.attributes(db_path, "mode") then return end
    local ok, conn = pcall(_SQ3.open, db_path)
    if not (ok and conn) then return end
    pcall(function()
        conn:exec("PRAGMA busy_timeout = 3000;")
        conn:exec("PRAGMA wal_checkpoint(TRUNCATE);")
        conn:close()
    end)
end

function M.beginStatsSyncGuard()
    _stats_sync_guard = true
end

function M.endStatsSyncGuard()
    _stats_sync_guard = false
end

function M.isStatsSyncGuarded()
    return _stats_sync_guard
end

-- Opens statistics.sqlite3 for read queries. Returns nil when a cloud sync
-- is in progress or the DB is unavailable. Callers that keep the handle
-- open must release it before any Statistics sync
-- (ScreenEngine.prepareForStatsSync).
function M.openStatsDB()
    if _stats_sync_guard then return nil end
    if not _ensureSqlite() then return nil end
    local db_path = M.getStatsDbPath()
    if not _lfs_mod.attributes(db_path, "mode") then return nil end
    local ok, conn = pcall(_SQ3.open, db_path)
    if not (ok and conn) then return nil end
    -- Retry briefly when the Statistics plugin is mid-write.
    pcall(function() conn:exec("PRAGMA busy_timeout = 3000;") end)
    if not _indexes_created then
        local idx_ok = pcall(function()
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_book_md5 ON book(md5);")
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_pagestat_book ON page_stat(id_book);")
            conn:exec("CREATE INDEX IF NOT EXISTS idx_simpleui_pagestat_time ON page_stat(start_time);")
        end)
        if idx_ok then _indexes_created = true end
    end
    return conn
end

function M.isFatalDbError(err)
    if type(err) ~= "string" then return false end
    return err:find("ljsqlite3%[corrupt%]", 1, false) or err:find("ljsqlite3%[notadb%]", 1, false) or err:find("ljsqlite3%[ioerr%]", 1, false)
end

-- Collections
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
    -- NOTE: deliberately not calling rc:_read() here. That method is a
    -- one-shot, destructive reload (it wipes and rebuilds rc.coll /
    -- rc.coll_settings from disk) that KOReader itself only ever calls once,
    -- at module load. Calling it again from SimpleUI can discard in-memory
    -- changes the native Collections UI hasn't flushed to disk yet (e.g. a
    -- collection just created but not yet saved), causing it to vanish and
    -- crash when opened. The require()'d `rc` singleton is already kept live
    -- in-process by every mutation (addItem, addCollection, etc.), so no
    -- reload is needed here.
    local fav = rc.default_collection_name or "favorites"
    local names = {}
    local seen = {}
    local function addColls(source)
        if not source then return end
        for name in pairs(source) do
            if name ~= fav and not seen[name] then
                names[#names + 1] = name
                seen[name] = true
            end
        end
    end
    addColls(rc.coll)
    addColls(rc.coll_folders)
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end
function M.isFavoritesWidget(w)
    if not w or w.name ~= "collections" then return false end
    local rc = M.getReadCollection()
    return rc and w.path == rc.default_collection_name or false
end

-- Navpager
function M.isNavpagerEnabled() return SUISettings:isTrue("simpleui_bar_navpager_enabled") end
function M.isDotPagerEnabled() return SUISettings:nilOrTrue("simpleui_bar_dotpager_always") end
function M.effectiveMaxTabs() return M.isNavpagerEnabled() and M.MAX_TABS_NAVPAGER or M.MAX_TABS end

local function _stateFromMenu(menu)
    if not menu then return nil end
    local page, page_num = menu.page, menu.page_num
    if not (page and page_num) then return nil end
    return page > 1, page < page_num
end
function M.getNavpagerState()
    local UI = package.loaded["infra/sui_core"]
    if not UI then return false, false end
    local stack = UI.getWindowStack()
    -- Check for a SUIWindow on top of the stack first.
    -- SUIWindow._wrapper does NOT set covers_fullscreen (doing so would prevent
    -- UIManager from repainting the FM/homescreen navbar below it, breaking
    -- arrow color updates).  We detect it via the _sui_window_instance marker
    -- before entering the covers_fullscreen loop.
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w._sui_window_instance then
            local inst  = w._sui_window_instance
            local cur   = inst._current_page or 1
            local total = inst._total_pages  or 1
            return cur > 1, cur < total
        end
        -- Stop scanning once we hit a fullscreen widget below (the SUIWindow,
        -- if present, is always above it).
        if w and w.covers_fullscreen then break end
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.covers_fullscreen then
            local prev, nxt = _stateFromMenu(w)
            if prev ~= nil then return prev, nxt end
            if w.file_chooser then
                local prev2, nxt2 = _stateFromMenu(w.file_chooser)
                if prev2 ~= nil then return prev2, nxt2 end
            end
            -- Generic across any screen (built-in Homescreen or a Custom
            -- Screen) via w._id/ScreenEngine.getInstance, rather than
            -- comparing against the flat HS._instance field, which is only
            -- ever populated for the built-in Homescreen — a Custom Screen
            -- on top of the stack would otherwise always fall through to
            -- "false, false" below, permanently disabling its navpager
            -- arrows even when it has more than one page.
            local HS = package.loaded["screens/sui_homescreen"]
            if HS and w._id and HS.getInstance(w._id) == w then
                local cur, total = w._current_page or 1, w._total_pages or 1
                return cur > 1, cur < total
            end
            return false, false
        end
    end
    return false, false
end

-- ===========================================================================
-- 8. Lifecycle & Migrations
-- ===========================================================================

function M.migrateOldCustomSlots()
    if SUISettings:get("simpleui_qa_migrated_v1") then return end
    local id_map, qa_list, qa_set = {}, M.getCustomQAList(), {}
    for _, id in ipairs(qa_list) do qa_set[id] = true end
    for slot = 1, 4 do
        local old_id, cfg = "custom_" .. slot, SUISettings:get("simpleui_custom_" .. slot)
        if type(cfg) == "table" and (cfg.path or cfg.collection) then
            local new_id = M.nextCustomQAId()
            M.saveCustomQAConfig(new_id, cfg.label or (_("Custom") .. " " .. slot), cfg.path, cfg.collection)
            if not qa_set[new_id] then qa_list[#qa_list + 1] = new_id; qa_set[new_id] = true end
            id_map[old_id] = new_id
        end
    end
    M.saveCustomQAList(qa_list)
    local tabs = SUISettings:get("simpleui_bar_tabs")
    if type(tabs) == "table" then
        local new_tabs, changed = {}, false
        for _, id in ipairs(tabs) do
            if id_map[id] then new_tabs[#new_tabs + 1] = id_map[id]; changed = true
            elseif id:match("^custom_%d+$") and not id:match("^custom_qa_") then changed = true
            else new_tabs[#new_tabs + 1] = id end
        end
        if changed then SUISettings:set("simpleui_bar_tabs", new_tabs) end
    end
    for _, pfx in ipairs({"simpleui_hs_qa_"}) do
        for slot = 1, 3 do
            local key, dqa = pfx .. slot .. "_items", SUISettings:get(pfx .. slot .. "_items")
            if type(dqa) == "table" then
                local changed, new_dqa = false, {}
                for _, id in ipairs(dqa) do
                    if id_map[id] then new_dqa[#new_dqa + 1] = id_map[id]; changed = true
                    elseif not id:match("^custom_%d+$") or id:match("^custom_qa_") then new_dqa[#new_dqa + 1] = id
                    else changed = true end
                end
                if changed then SUISettings:set(key, new_dqa) end
            end
        end
    end
    SUISettings:set("simpleui_qa_migrated_v1", true)
    local legacy_enabled = SUISettings:get("simpleui_bar_enabled")
    if legacy_enabled ~= nil and SUISettings:get("simpleui_enabled") == nil then
        SUISettings:set("simpleui_enabled", legacy_enabled)
    end
end

-- First-run defaults. Idempotent: each setting is only written when absent,
-- so user customisations made after first run are never overwritten.
-- No version flags needed — the nil-check on each key is the guard.
function M.applyFirstRunDefaults()
    local function def(k, v)
        if SUISettings:get(k) == nil then SUISettings:set(k, v) end
    end
    local function gdef(k, v)
        if G_reader_settings:readSetting(k) == nil then
            G_reader_settings:saveSetting(k, v)
        end
    end

    -- Navbar
    def("simpleui_bar_enabled",  true)
    def("simpleui_topbar_enabled", true)
    def("simpleui_bar_mode",     "both")
    def("simpleui_bar_tabs",     { "home", "sui_settings", "homescreen", "history", "power" })
    if SUISettings:get("simpleui_topbar_config") == nil then
        M.saveTopbarConfig({ side = { clock = "left", battery = "right", wifi = "right" }, order_left = { "clock" }, order_right = { "wifi", "battery" } })
    end

    -- Home key → Homescreen (was PocketBook-only simpleui_pb_home_opens_hs).
    -- Migrate once when the new key is absent; leave the old key in place so
    -- older plugin versions reading the same settings file still work.
    if SUISettings:get("simpleui_home_key_opens_hs") == nil
            and SUISettings:get("simpleui_pb_home_opens_hs") ~= nil then
        SUISettings:set("simpleui_home_key_opens_hs",
            SUISettings:isTrue("simpleui_pb_home_opens_hs"))
    end
    def("simpleui_home_key_opens_hs", true)

    -- Homescreen modules (default preset)
    local PFX = "simpleui_hs_"
    def(PFX .. "quote_enabled",           false)
    def(PFX .. "currently_enabled",       true)
    def(PFX .. "recent_enabled",          true)
    def(PFX .. "clock_enabled",           false)
    def(PFX .. "clock_date",              false)
    def(PFX .. "clock_battery",           false)
    def(PFX .. "coverdeck_enabled",       false)
    def(PFX .. "new_books_enabled",       false)
    def(PFX .. "tbr_enabled",             false)
    def(PFX .. "collections_enabled",     false)
    def(PFX .. "reading_goals_enabled",   false)
    def(PFX .. "reading_stats_enabled",   false)
    def(PFX .. "action_list_enabled",     false)
    def(PFX .. "module_order",            { "quote", "currently", "recent", "clock", "coverdeck", "new_books", "tbr", "collections", "reading_goals", "reading_stats", "quick_actions_row_000001", "quick_actions_row_000002", "quick_actions_row_000003", "action_list" })

    -- NOTE on the def()/nilOrTrue() contract: every boolean setting read via
    -- SUISettings:nilOrTrue() treats an *unset* key as true. That inline
    -- fallback exists only as a defensive backstop (e.g. a key added to a
    -- module after a user's install, or a settings snapshot saved before the
    -- key existed) — it must never be the sole source of truth for a shipped
    -- default. Every nilOrTrue()-backed key must have a matching def() entry
    -- below, written once on first run, so the real default is explicit,
    -- greppable, and independent of nilOrTrue's true-leaning fallback. When
    -- adding a new show/hide toggle to any module, add its def() here too.
    def(PFX .. "currently_show_title",         true)
    def(PFX .. "currently_show_author",        true)
    def(PFX .. "currently_show_progress",      true)
    def(PFX .. "currently_show_percent",       false)
    def(PFX .. "currently_show_book_days",     true)
    def(PFX .. "currently_show_book_time",     true)
    def(PFX .. "currently_show_book_remaining", true)
    def(PFX .. "currently_show_series",         false)
    def(PFX .. "currently_show_description",   true)
    def(PFX .. "currently_bar_style",           "with_pct")
    def(PFX .. "currently_stats_style",         "compact")
    def(PFX .. "coverdeck_show_title",          true)
    def(PFX .. "coverdeck_show_author",         false)
    def(PFX .. "coverdeck_show_progress",       true)
    def(PFX .. "coverdeck_show_percent",        true)
    def(PFX .. "coverdeck_show_book_days",      false)
    def(PFX .. "coverdeck_show_book_time",      false)
    def(PFX .. "coverdeck_show_book_remaining", false)
    def(PFX .. "coverdeck_show_stats",          true)  -- was previously undefaulted; relied silently on nilOrTrue's true fallback
    def(PFX .. "recent_show_finished",          true)

    -- Updater
    def("simpleui_updater_auto_check",          true)

    -- Quick Actions Row instances (three stable ids that won't clash with
    -- runtime-generated ones, which use os.time() as suffix).
    if SUISettings:get("simpleui_qa_row_instances") == nil then
        local QA_INSTANCES = { "quick_actions_row_000001", "quick_actions_row_000002", "quick_actions_row_000003" }
        SUISettings:set("simpleui_qa_row_instances", QA_INSTANCES)
        for _, iid in ipairs(QA_INSTANCES) do
            def(PFX .. iid .. "_enabled", false)
        end
    end

    -- Reading Goals: only the annual goal shown by default.
    def("simpleui_reading_goals_show_annual",  true)
    def("simpleui_reading_goals_show_monthly", false)
    def("simpleui_reading_goals_show_daily",   false)

    -- Folder covers / browse meta
    def("simpleui_fc_enabled",          true)
    def("simpleui_fc_folder_style",     "auto")
    def("simpleui_fc_cover_mode",       "2_3")
    def("simpleui_fc_subfolder_cover",  true)
    def("simpleui_browsemeta_enabled",  true)

    -- Titlebar: search visible, browse visible left of menu
    def("simpleui_tb_item_fm_search", true)
    def("simpleui_tb_item_fm_browse", true)
    if SUISettings:get("simpleui_tb_fm_cfg") == nil then
        SUISettings:set("simpleui_tb_fm_cfg", {
            side        = { fm_menu = "right", fm_back = "left", fm_search = "left", fm_browse = "right" },
            order_left  = { "fm_back", "fm_search" },
            order_right = { "fm_browse", "fm_menu" },
        })
    end

    -- Quick Settings bar
    def("simpleui_qs_bar_enabled",          true)
    def("simpleui_qs_bar_frontlight",       false)
    def("simpleui_qs_bar_warmth",           false)
    def("simpleui_qs_bar_shape",            "round")
    def("simpleui_qs_bar_bg",              "flat")
    def("simpleui_qs_bar_settings_on_hold", true)
    def("simpleui_qs_bar_slots",            { "wifi_toggle", "bookmark_browser", "frontlight", "night_mode", "power", "sui_settings" })

    -- KOReader global: open homescreen on launch (only set once on fresh install)
    gdef("start_with", "homescreen_simpleui")

    SUISettings:flush()
end

function M.reset()
    _tabs_cache, _navbar_mode_cache, M.wifi_optimistic = nil, nil, nil
    M.cover_extraction_pending, M._cover_extract_queue, M._cover_extract_pending, M._cover_extract_specs = false, {}, {}, {}
    _Device, _NetworkMgr, _has_wifi_toggle, _has_home_key, _topbar_item_labels, _SQ3, _lfs_mod, _BookInfoManager, _topbar_cfg_menu_cache, _ReadCollection = nil, nil, nil, nil, nil, nil, nil, nil, nil
    _QA_lazy().clearQAKeyCache()
    M.clearCoverCache()
end

return M
