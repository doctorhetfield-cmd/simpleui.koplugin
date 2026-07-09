-- config.lua — Simple UI
-- sui_config.lua — Simple UI
-- Central configuration, state caching, and core helpers.

local G_reader_settings = G_reader_settings
local math_max          = math.max
local math_min          = math.min
local math_floor        = math.floor
local Blitbuffer        = require("ffi/blitbuffer")
local DataStorage       = require("datastorage")
local SUISettings       = require("sui_store")
local logger            = require("logger")
local _ = require("sui_i18n").translate

local M = {}

-- ===========================================================================
-- 1. Paths & Icons
-- ===========================================================================

-- Resolve absolute plugin directory for cross-platform compatibility.
local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
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
    ko_wifi_on     = _KO .. "wifi.open.100.svg",
    ko_wifi_off    = _KO .. "wifi.open.0.svg",
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
    { id = "wifi_toggle",      label = _("Wi-Fi"),            icon = M.ICON.ko_wifi_on  },
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
local function _QA_lazy() return package.loaded["sui_quickactions"] or require("sui_quickactions") end
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
    local tb = package.loaded["sui_topbar"]
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

function M.wifiIcon()
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    local icon_on  = QA.getDefaultActionIcon("wifi_toggle") or M.ICON.ko_wifi_on
    local icon_off = QA.getDefaultActionIcon("wifi_toggle_off") or M.ICON.ko_wifi_off

    if M.wifi_optimistic ~= nil then
        return M.wifi_optimistic and icon_on or icon_off
    end
    if not deviceHasWifi() then return icon_off end
    local NetworkMgr = getNetworkMgr()
    if not NetworkMgr then return icon_off end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_state and wifi_on then return icon_on end
    return icon_off
end

local _wifi_action_live = { id = "wifi_toggle", label = "", icon = "" }

function M.getActionById(id)
    local QA = package.loaded["sui_quickactions"]
        or require("sui_quickactions")
    local entry = QA.getEntry(id)
    if entry and not entry.id then
        return { id = id, label = entry.label, icon = entry.icon }
    end
    return entry or M.ALL_ACTIONS[1]
end

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

-- Bottom Bar Size
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

function M.getThumbScalePct(mod_id, pfx)
    local v = SUISettings:get(_thumbKey(mod_id, pfx))
    local n = tonumber(v)
    if not n then return SCALE_DEF end
    return _clamp(n)
end

function M.setThumbScale(pct, mod_id, pfx)
    SUISettings:set(_thumbKey(mod_id, pfx), _clamp(pct))
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
        local ok, SUIStyle = pcall(require, "sui_style")
        local base_fs = (ok and SUIStyle and SUIStyle.FS_BODY) or 18  -- FS_BODY (18)
        _BASE_LABEL_TEXT_H = require("device").screen:scaleBySize(base_fs)
    end
    local PAD2  = require("sui_core").PAD2
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
    local Registry = require("desktop_modules/moduleregistry")
    for _, mod in ipairs(Registry.list()) do
        if mod.id then
            SUISettings:del((pfx or "simpleui_hs_") .. mod.id .. "_scale")
            SUISettings:del((pfx or "simpleui_hs_") .. mod.id .. THUMB_SCALE_KEY_SUFFIX)
            SUISettings:del(_itemLabelKey(mod.id, pfx))
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

-- Cover bitmap LRU cache. Stores pre-scaled bitmaps to prevent distortion.
local BIM_MAX_COVERS   = 30
local _bim_cover_cache = {}
local _bim_cover_count = 0
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

local function _evictOldestCover()
    local oldest_key, oldest_t = nil, math.huge
    for k, entry in pairs(_bim_cover_cache) do
        if entry.t and entry.t < oldest_t then
            oldest_t, oldest_key = entry.t, k
        end
    end
    if oldest_key then
        _bim_cover_cache[oldest_key] = nil
        _bim_cover_count = _bim_cover_count - 1
    end
end

local function _scaleBBToSlot(bb, target_w, target_h, align, stretch_limit)
    if not _RenderImage then
        local ok, ri = pcall(require, "ui/renderimage")
        if not (ok and ri) then return bb end
        _RenderImage = ri
    end
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
    if stretch_limit then
        local scale_w, scale_h = target_w / src_w, target_h / src_h
        local distort = math.abs(scale_w / scale_h - 1)
        if distort <= stretch_limit then
            local ok_sc, stretched_bb = pcall(function() return _RenderImage:scaleBlitBuffer(bb, target_w, target_h) end)
            if ok_sc and stretched_bb then return stretched_bb end
        end
    end
    local scale_factor = math_max(target_w / src_w, target_h / src_h)
    local scaled_w, scaled_h = math_floor(src_w * scale_factor + 0.5), math_floor(src_h * scale_factor + 0.5)
    local ok_sc, scaled_bb = pcall(_RenderImage.scaleBlitBuffer, _RenderImage, bb, scaled_w, scaled_h)
    if not (ok_sc and scaled_bb) then return bb end
    if scaled_w == target_w and scaled_h == target_h then return scaled_bb end
    local ok_slot, slot_bb = pcall(Blitbuffer.new, target_w, target_h, scaled_bb:getType())
    if not (ok_slot and slot_bb) then return scaled_bb end
    local src_x = align == "left" and 0 or (align == "right" and scaled_w - target_w or math_floor((scaled_w - target_w) / 2))
    local src_y = math_floor((scaled_h - target_h) / 2)
    pcall(slot_bb.blitFrom, slot_bb, scaled_bb, 0, 0, src_x, src_y, target_w, target_h)
    pcall(scaled_bb.free, scaled_bb)
    return slot_bb
end

local _NO_COVER = {}
function M.isCoverMissing(filepath) return _bim_cover_cache[filepath .. "|__nc"] == _NO_COVER end

local function _markNoCover(filepath)
    local probe = filepath .. "|__nc"
    if _bim_cover_cache[probe] then return end
    if _bim_cover_count >= BIM_MAX_COVERS then _evictOldestCover() end
    _bim_cover_cache[probe] = _NO_COVER
    _bim_cover_count = _bim_cover_count + 1
end

function M.getCoverBB(filepath, w, h, align, stretch_limit)
    if M.isCoverMissing(filepath) then return nil end
    local key = filepath .. "|" .. w .. "x" .. h .. (align and ("|" .. align) or "")
    local cached = _bim_cover_cache[key]
    if cached then cached.t = os.time(); return cached.bb end

    -- Reject non-regular-file paths (e.g. directories, ".." traversals)
    -- before hitting the native extractor, which can segfault on invalid input.
    if _lfsMode(filepath) ~= "file" then _markNoCover(filepath); return nil end

    local bim = M.getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(bim.getBookInfo, bim, filepath, true)

    local function enqueueExtract()
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

    if not ok then enqueueExtract(); M.cover_extraction_pending = true; return nil end
    if bookinfo and bookinfo.cover_fetched then
        if bookinfo.has_cover and bookinfo.cover_bb then
            M._cover_extract_pending[filepath] = nil
            local bb = _scaleBBToSlot(bookinfo.cover_bb, w, h, align, stretch_limit)
            if _bim_cover_count >= BIM_MAX_COVERS then _evictOldestCover() end
            _bim_cover_cache[key] = { bb = bb, t = os.time() }
            _bim_cover_count = _bim_cover_count + 1
            return bb
        else
            M._cover_extract_pending[filepath] = nil; _markNoCover(filepath); return nil
        end
    end
    enqueueExtract()
    if M._cover_extract_pending[filepath] then M.cover_extraction_pending = true end
    return nil
end

function M.clearCoverCache()
    if _bim_cover_count == 0 then return end
    local to_free = _bim_cover_cache
    _bim_cover_cache = {}; _bim_cover_count = 0; _RenderImage = nil
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
        if _lfsMode(fp) == "file" then
            files[#files + 1] = { filepath = fp, cover_specs = M._cover_extract_specs[fp] }
        else
            M._cover_extract_pending[fp] = nil
        end
        M._cover_extract_specs[fp] = nil
    end
    local ok = pcall(bim.extractInBackground, bim, files)
    if not ok then
        for _, fp in ipairs(queue) do M._cover_extract_pending[fp] = nil end
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
function M.getStatsDbPath() return DataStorage:getSettingsDir() .. "/statistics.sqlite3" end
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
    local ok, conn = pcall(_SQ3.open, db_path)
    if not (ok and conn) then return nil end
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
    if rc._read then
        pcall(function()
            rc:_read()
        end)
    end
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
    local UI = package.loaded["sui_core"]
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
            local HS = package.loaded["sui_homescreen"]
            if HS and HS._instance == w then
                local cur, total = HS._instance._current_page or 1, HS._instance._total_pages or 1
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

    -- Homescreen modules (default preset)
    local PFX = "simpleui_hs_"
    def(PFX .. "quote_enabled",           true)
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
    def(PFX .. "currently_show_title",         true)
    def(PFX .. "currently_show_author",        true)
    def(PFX .. "currently_show_progress",      true)
    def(PFX .. "currently_show_percent",       true)
    def(PFX .. "currently_show_book_days",     false)
    def(PFX .. "currently_show_book_time",     false)
    def(PFX .. "currently_show_book_remaining", false)
    def(PFX .. "coverdeck_show_title",          true)
    def(PFX .. "coverdeck_show_author",         false)
    def(PFX .. "coverdeck_show_progress",       true)
    def(PFX .. "coverdeck_show_percent",        false)
    def(PFX .. "coverdeck_show_book_days",      false)
    def(PFX .. "coverdeck_show_book_time",      false)
    def(PFX .. "coverdeck_show_book_remaining", false)
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
    _Device, _NetworkMgr, _has_wifi_toggle, _topbar_item_labels, _SQ3, _lfs_mod, _BookInfoManager, _topbar_cfg_menu_cache, _ReadCollection = nil, nil, nil, nil, nil, nil, nil, nil, nil
    _QA_lazy().clearQAKeyCache()
    M.clearCoverCache()
end

return M
