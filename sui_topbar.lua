-- topbar.lua — Simple UI
-- Status bar rendered at the top of the screen: clock, Wi-Fi, battery,
-- brightness, disk usage and RAM. Supports left/right item placement.

local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget      = require("ui/widget/textwidget")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")
local _ = require("sui_i18n").translate

local Config = require("sui_config")

local M = {}

-- ---------------------------------------------------------------------------
-- Hardware capability flags — queried once per session, never change at runtime.
-- nil = not yet tested; true/false = result cached.
-- ---------------------------------------------------------------------------
local _hw_has_battery = nil
local _hw_has_wifi    = nil
local _hw_has_bt      = nil

local function hwHasBattery()
    if _hw_has_battery == nil then
        local ok, v = pcall(function() return Device:hasBattery() end)
        _hw_has_battery = ok and v == true
    end
    return _hw_has_battery
end

local function hwHasWifi()
    if _hw_has_wifi == nil then
        local ok, v = pcall(function() return Device:hasWifiToggle() end)
        _hw_has_wifi = ok and v == true
    end
    return _hw_has_wifi
end

local function hwHasBt()
    if _hw_has_bt == nil then
        local ok, v = pcall(function() return Device:hasBluetoothToggle() end)
        _hw_has_bt = ok and v == true
    end
    return _hw_has_bt
end

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

local _dim = {}

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

-- Topbar scale factor — cached inside _dim so getTopbarSizePct() (a readSetting
-- call) is only paid once per invalidation cycle, regardless of how many
-- dimension functions call _getTopbarScale(). Mirrors the same fix applied to
-- _getNavbarScale() in sui_bottombar.lua.
local function _getTopbarScale()
    return _cached("topbar_scale", function()
        return Config.getTopbarSizePct() / 100
    end)
end

-- Lazy upvalue for sui_core — resolved on first use to avoid a circular
-- require at load time, but stored so that M.SIDE_M() never pays a
-- require() lookup after the first call.
local _Core
local function _getCore()
    _Core = _Core or require("sui_core")
    return _Core
end

function M.SIDE_M()        return _getCore().SIDE_M()                                           end
function M.TOPBAR_SIDE_M() return _cached("topbar_side_m", function() return M.SIDE_M() - 3 end) end

function M.TOPBAR_H()
    return _cached("topbar_h", function()
        return math.floor(Screen:scaleBySize(18) * _getTopbarScale())
    end)
end
function M.TOPBAR_FS()
    return _cached("topbar_fs", function()
        return math.floor(Screen:scaleBySize(8) * _getTopbarScale())
    end)
end
function M.TOPBAR_CHEVRON_FS()
    return _cached("tb_chev_fs", function()
        return math.floor(Screen:scaleBySize(22) * _getTopbarScale())
    end)
end
function M.TOPBAR_PAD_TOP()
    return _cached("tb_pad_top", function()
        return math.floor(Screen:scaleBySize(20) * _getTopbarScale())
    end)
end
function M.TOPBAR_PAD_BOT()
    return _cached("tb_pad_bot", function()
        return math.floor(Screen:scaleBySize(8) * _getTopbarScale())
    end)
end
function M.TOTAL_TOP_H()
    return M.TOPBAR_H() + M.TOPBAR_PAD_TOP() + M.TOPBAR_PAD_BOT()
end

-- ---------------------------------------------------------------------------
-- Slow-data caches — declared here so invalidateDimCache can reference them
-- ---------------------------------------------------------------------------

local _topbar_cfg_cache = nil   -- topbar config (invalidated on settings change)
local _topbar_disk_text = nil
local _topbar_disk_time = 0
local _topbar_ram_mb    = nil
local _topbar_ram_time  = 0

-- Cached result of "navbar_topbar_enabled" setting.
-- This setting is read on every timer tick (shouldRunTimer) and on every
-- touch-zone registration. Caching it avoids repeated settings lookups on
-- the hot path. Invalidated by invalidateDimCache() on any settings change.
local _topbar_enabled_cache = nil

function M.invalidateDimCache()
    _dim = {}
    _topbar_enabled_cache = nil  -- settings may have changed
    _topbar_cfg_cache = nil  -- P5: settings may have changed, force re-read
    -- Also reset slow-data caches so they are refreshed on the next tick.
    _topbar_ram_mb    = nil
    _topbar_ram_time  = 0
    _topbar_disk_text = nil
    _topbar_disk_time = 0
    -- Hardware capability flags are session-stable, but reset them here so that
    -- a plugin teardown+re-enable cycle (or device state change) gets a fresh read.
    _hw_has_battery = nil
    _hw_has_wifi    = nil
    _hw_has_bt      = nil
end

-- ---------------------------------------------------------------------------
-- Topbar config cache — avoids re-parsing G_reader_settings on every minute-tick
-- ---------------------------------------------------------------------------

local function getTopbarConfigCached()
    if not _topbar_cfg_cache then
        _topbar_cfg_cache = Config.getTopbarConfig()
    end
    return _topbar_cfg_cache
end

function M.invalidateConfigCache()
    _topbar_cfg_cache = nil
end

-- ---------------------------------------------------------------------------
-- Disk-usage cache helpers
-- ---------------------------------------------------------------------------

function M.invalidateDiskCache()
    _topbar_disk_text = nil
    _topbar_disk_time = 0
end

-- ---------------------------------------------------------------------------
-- RAM-usage cache (refreshed every 5 minutes)
-- ---------------------------------------------------------------------------

function M.invalidateRamCache()
    _topbar_ram_mb   = nil
    _topbar_ram_time = 0
end

-- ---------------------------------------------------------------------------
-- System state readers
-- ---------------------------------------------------------------------------

function M.getTopbarInfo()
    local info = { time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) }

    if hwHasBattery() then
        -- getPowerDevice() and its methods are stable KOReader APIs; wrap the
        -- entire section in a single pcall rather than one per method call.
        pcall(function()
            local powerd = Device:getPowerDevice()
            if not powerd then return end
            local cap = powerd:getCapacity()
            if type(cap) ~= "number" then return end
            info.battery     = cap
            info.charging    = powerd:isCharging() == true
            local chd        = powerd:isCharged()
            info.battery_sym = powerd:getBatterySymbol(chd, info.charging, cap) or ""
            if Device:hasAuxBattery() and powerd:isAuxBatteryConnected() then
                local aux_cap = powerd:getAuxCapacity()
                if type(aux_cap) == "number" then
                    info.aux_battery     = aux_cap
                    info.aux_battery_sym = powerd:getBatterySymbol(
                        powerd:isAuxCharged(), powerd:isAuxCharging(), aux_cap) or ""
                end
            end
        end)
    end

    if hwHasWifi() then
        -- Use optimistic state set immediately on toggle (same as bottom bar).
        if Config.wifi_optimistic ~= nil then
            info.wifi = Config.wifi_optimistic == true
        else
            local nm = Config.getNetworkMgr()
            if nm then
                local ok_w, wifi_on = pcall(function() return nm:isWifiOn() end)
                info.wifi = ok_w and not not wifi_on or false
            else
                info.wifi = false
            end
        end
    else
        info.wifi = false
    end

    if hwHasBt() then
        local ok_b, bt = pcall(function() return Device:isBluetoothOn() end)
        info.bluetooth = ok_b and not not bt or false
    else
        info.bluetooth = false
    end

    -- Brightness: single pcall wrapping the two-step lookup.
    -- Mostra o valor quando ligado, ou "Off" quando desligado (igual ao patch).
    pcall(function()
        local pd = Device:getPowerDevice()
        if not pd then return end
        if pd:isFrontlightOn() then
            local br = pd:frontlightIntensity()
            if type(br) == "number" then
                info.brightness = br
            else
                local sc_br = Screen:getBrightness()
                if type(sc_br) == "number" then
                    info.brightness = sc_br > 1
                        and math.floor(sc_br / 255 * 100 + 0.5)
                        or  math.floor(sc_br * 100 + 0.5)
                end
            end
        else
            info.brightness_off = true  -- frontlight existe mas está desligado
        end
    end)

    pcall(function()
        local now = os.time()
        -- TTL of 5s: /proc/self/statm is a kernel in-memory read (~microseconds),
        -- so reading it every minute-tick is safe. 5s gives useful feedback for
        -- profiling without measurable overhead.
        if _topbar_ram_mb and (now - _topbar_ram_time) < 5 then
            info.ram = _topbar_ram_mb
        else
            local f = io.open("/proc/self/statm", "r")
            if f then
                local line = f:read("*l"); f:close()
                if line then
                    local rss = line:match("%S+%s+(%d+)")
                    if rss then
                        local mb = math.floor(tonumber(rss) * 4 / 1024)
                        _topbar_ram_mb   = mb
                        _topbar_ram_time = now
                        info.ram         = mb
                    end
                end
            end
        end
    end)

    pcall(function()
        local now = os.time()
        if _topbar_disk_text and (now - (_topbar_disk_time or 0)) < 300 then
            info.disk = _topbar_disk_text; return
        end
        local ok_util, util = pcall(require, "util")
        if not ok_util or not util or type(util.diskUsage) ~= "function" then return end
        -- Device.home_dir is set per-device: /mnt/onboard (Kobo), /mnt/us (Kindle),
        -- /mnt/public (Cervantes), /mnt/ext1 (PocketBook), /home/root (Remarkable),
        -- android.getExternalStoragePath() (Android), $HOME (SDL/desktop).
        -- Falls back to "/" if home_dir is nil (e.g. Sony PRSTUX).
        local drive = Device.home_dir or "/"
        local ok_df, usage = pcall(util.diskUsage, drive)
        if ok_df and usage and type(usage.available) == "number" and usage.available > 0 then
            local text = string.format("%.1fG", usage.available / 1024 / 1024 / 1024)
            _topbar_disk_text = text
            _topbar_disk_time = now
            info.disk         = text
        end
    end)

    return info
end

-- ---------------------------------------------------------------------------
-- Widget construction
-- ---------------------------------------------------------------------------

function M.buildTopbarWidget()
    local screen_w  = Screen:getWidth()
    local side_m    = M.TOPBAR_SIDE_M()
    local pad_top   = M.TOPBAR_PAD_TOP()
    local pad_bot   = M.TOPBAR_PAD_BOT()
    local total_h   = M.TOPBAR_H() + pad_top + pad_bot
    local face      = Font:getFace("cfont", M.TOPBAR_FS())
    local icon_face = Font:getFace("xx_smallinfofont", M.TOPBAR_FS())
    local info      = M.getTopbarInfo()
    local tb_cfg    = getTopbarConfigCached()

    local item_builders = {
        clock = function()
            return nil, info.time, false
        end,
        wifi = function()
            if info.wifi then
                return "\u{ECA8}", nil, true   -- ícone wifi ligado
            elseif hwHasWifi() then
                if Config.getWifiHideWhenOff() then
                    return nil, nil             -- esconde quando desligado
                end
                return "\u{ECA9}", nil, true   -- ícone wifi desligado
            end
            return nil, nil
        end,
        brightness = function()
            if info.brightness then
                return "\xe2\x98\x80", " " .. info.brightness, false
            elseif info.brightness_off then
                return "\xe2\x98\x80", " Off", false
            end
            return nil, nil
        end,
        battery = function()
            if not info.battery then return nil, nil end
            local label = info.battery .. "%"
            if info.aux_battery then
                label = label .. " +" .. (info.aux_battery_sym or "") .. info.aux_battery .. "%"
            end
            return (info.battery_sym or ""), label, false
        end,
        disk = function()
            if not info.disk then return nil, nil end
            return "\u{F0A0}", " " .. info.disk, true
        end,
        ram = function()
            if not info.ram then return nil, nil end
            return "\u{EA5A}", " " .. info.ram .. "M", true
        end,
        custom_text = function()
            local t = Config.getTopbarCustomText()
            if not t or t == "" then return nil, nil end
            -- max_width caps the rendered width to half the bar so it cannot
            -- collide with items on the opposite side. TextWidget will append
            -- an ellipsis automatically when the text exceeds this limit.
            local max_w = math.floor((screen_w - side_m * 2) / 2)
            return nil, t, false, max_w
        end,
    }

    local function buildSideGroup(order)
        local group = HorizontalGroup:new{}
        local first = true
        for _, key in ipairs(order) do
            if (tb_cfg.side[key] or "hidden") ~= "hidden" then
                local builder = item_builders[key]
                if builder then
                    local icon, label, is_nerd, max_w = builder()
                    if icon or (label and label ~= "") then
                        if not first then
                            group[#group + 1] = TextWidget:new{
                                text = "  ", face = face, fgcolor = Blitbuffer.COLOR_BLACK,
                            }
                        end
                        if icon then
                            group[#group + 1] = TextWidget:new{
                                text    = icon,
                                face    = is_nerd and icon_face or face,
                                fgcolor = Blitbuffer.COLOR_BLACK,
                            }
                        end
                        if label and label ~= "" then
                            group[#group + 1] = TextWidget:new{
                                text      = label,
                                face      = face,
                                fgcolor   = Blitbuffer.COLOR_BLACK,
                                max_width = max_w or nil,
                            }
                        end
                        first = false
                    end
                end
            end
        end
        return group
    end

    local inner_w = screen_w - side_m * 2

    local left_w = LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = total_h },
        buildSideGroup(tb_cfg.order_left),
    }
    local right_w = RightContainer:new{
        dimen = Geom:new{ w = inner_w, h = total_h },
        buildSideGroup(tb_cfg.order_right),
    }

    -- Build the center group (items assigned to "center" position).
    -- If there are any visible center items, show them and suppress the chevron.
    local order_center = tb_cfg.order_center or {}
    local center_has_items = false
    for _, key in ipairs(order_center) do
        if (tb_cfg.side[key] or "hidden") == "center" then
            center_has_items = true
            break
        end
    end

    local show_swipe = (not center_has_items) and G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator")
    local center_w
    if center_has_items then
        center_w = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = total_h },
            buildSideGroup(order_center),
        }
    elseif show_swipe then
        center_w = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = total_h },
            TextWidget:new{
                text    = "\xef\xb9\x80",
                face    = Font:getFace("cfont", M.TOPBAR_CHEVRON_FS()),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
    end

    local row = OverlapGroup:new{
        dimen  = Geom:new{ w = inner_w, h = total_h },
        left_w, right_w, center_w,
    }

    return FrameContainer:new{
        bordersize    = 0, padding = 0, margin = 0,
        padding_left  = side_m, padding_right = side_m,
        background    = Blitbuffer.COLOR_WHITE,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Topbar touch zones
-- ---------------------------------------------------------------------------

function M.registerTouchZones(plugin, fm_self)
    if fm_self.unregisterTouchZones then
        fm_self:unregisterTouchZones({
            { id = "navbar_topbar_hold_start"    },
            { id = "navbar_topbar_hold_settings" },
            { id = "navbar_title_hold_start"     },
            { id = "navbar_title_hold_settings"  },
        })
    end

    if _topbar_enabled_cache == nil then
        _topbar_enabled_cache = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    end
    if not _topbar_enabled_cache then return end

    local screen_h    = Screen:getHeight()
    local topbar_h    = M.TOTAL_TOP_H()
    local topbar_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = topbar_h / screen_h }

    fm_self:registerTouchZones({
        {
            id          = "navbar_topbar_hold_start",
            ges         = "hold",
            screen_zone = topbar_zone,
            handler     = function(_ges) return true end,
        },
        {
            id          = "navbar_topbar_hold_settings",
            ges         = "hold_release",
            screen_zone = topbar_zone,
            handler = function(_ges)
			if not G_reader_settings:nilOrTrue("navbar_topbar_settings_on_hold") then
				return true
			end
			 if not plugin._makeTopbarMenu then plugin:addToMainMenu({}) end
                local UI_mod    = require("sui_core")
                local Bottombar = require("sui_bottombar")
                -- Delegates to the shared implementation in ui.lua (#4).
                UI_mod.showSettingsMenu(_("Top Bar"), plugin._makeTopbarMenu,
                    M.TOTAL_TOP_H(), screen_h, Bottombar.TOTAL_H())
                return true
            end,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Refresh timer
-- ---------------------------------------------------------------------------

-- Returns true when the topbar is enabled and it is safe to refresh it.
-- Does NOT check whether the clock item is visible — that is only relevant
-- for deciding whether to *reschedule* the recurring timer after a tick.
local function shouldRefreshTopbar(plugin)
    if _topbar_enabled_cache == nil then
        _topbar_enabled_cache = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    end
    if not _topbar_enabled_cache then return false end
    -- Use package.loaded to avoid any pcall overhead; ReaderUI is only present
    -- while a book is open, and the timer is cancelled before that anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return false end
    -- Do not run while the device is suspended — the timer may fire during
    -- the suspend transition on some devices (Kobo) before the scheduler pauses.
    -- Also guard against screen_saver_mode, which is set before broadcastEvent("Suspend")
    -- fires on Kindle (framework mode) and closes the race window where the timer
    -- is already dequeued but _simpleui_suspended has not yet been set.
    if plugin and plugin._simpleui_suspended then return false end
    local Device = require("device")
    if Device.screen_saver_mode then return false end
    return true
end

-- Returns true when the recurring minute-tick timer should keep rescheduling.
-- Requires the clock item to be visible — without it there is nothing to tick.
local function shouldRunTimer(plugin)
    if not shouldRefreshTopbar(plugin) then return false end
    local cfg = getTopbarConfigCached()
    if (cfg.side["clock"] or "hidden") == "hidden" then return false end
    return true
end

function M.scheduleRefresh(plugin, delay)
    if plugin._topbar_timer then
        UIManager:unschedule(plugin._topbar_timer)
        plugin._topbar_timer = nil
    end
    if not shouldRefreshTopbar(plugin) then return end
    plugin._topbar_timer = function() M.refresh(plugin) end
    UIManager:scheduleIn(delay, plugin._topbar_timer)
end

function M.refresh(plugin)
    if not shouldRefreshTopbar(plugin) then return end
    -- shouldRefreshTopbar already checks _simpleui_suspended and screen_saver_mode,
    -- but there is a narrow race on Kobo: the UIManager may have already dequeued
    -- this timer for execution in the current event-loop tick *before* onSuspend ran
    -- and set _simpleui_suspended = true. shouldRefreshTopbar therefore passed with
    -- the flag still false. Re-check immediately after, before doing any work,
    -- so we never build a widget or call setDirty during the suspend transition.
    local Device = require("device")
    if (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then return end
    local UI    = require("sui_core")
    local stack = UI.getWindowStack()  -- read once
    -- Each widget gets its own topbar instance. Sharing a single object across
    -- multiple _navbar_containers is unsafe: replaceTopbar mutates overlap_offset
    -- in-place, so the first paint would corrupt the offset seen by subsequent
    -- containers holding the same reference.
    local new_topbar = M.buildTopbarWidget()
    -- Re-check suspended state after buildTopbarWidget() — the device may have
    -- suspended during that call. If so, discard the widget and do not setDirty
    -- or reschedule: onResume will restart the chain cleanly.
    if (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then return end
    local seen = {}
    local function refreshWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        UI.replaceTopbar(w, new_topbar)
        UIManager:setDirty(w, "ui")
    end
    refreshWidget(plugin.ui)
    for _, entry in ipairs(stack) do
        local ok, err = pcall(refreshWidget, entry.widget)
        if not ok then logger.warn("simpleui: topbar refreshWidget failed:", tostring(err)) end
    end
    -- Only keep the recurring minute-tick alive when the topbar clock is
    -- visible.  One-shot refreshes (brightness, wifi, battery events) arrive
    -- via M.scheduleRefresh(plugin, 0) from main.lua and are not affected —
    -- they bypass this rescheduling path entirely.
    if shouldRunTimer(plugin) then
        local delay = 60 - (os.time() % 60) + 1
        M.scheduleRefresh(plugin, delay)
    end
end

return M