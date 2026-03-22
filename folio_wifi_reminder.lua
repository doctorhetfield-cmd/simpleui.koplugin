-- folio_wifi_reminder.lua — After Wi-Fi is left on, optional reminder strip (Folio QoL).

local Device         = require("device")
local Screen         = Device.screen
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")

local Config  = require("folio_config")
local FolioTheme = require("folio_theme")
local Theme   = FolioTheme.Theme
local SP      = FolioTheme.SP

local M = {}

local _idle_timer_fn = nil
local _auto_dismiss_fn = nil
local _banner = nil

local function cancelIdleTimer()
    if _idle_timer_fn then
        UIManager:unschedule(_idle_timer_fn)
        _idle_timer_fn = nil
    end
end

local function cancelAutoDismiss()
    if _auto_dismiss_fn then
        UIManager:unschedule(_auto_dismiss_fn)
        _auto_dismiss_fn = nil
    end
end

function M.cancelAll()
    cancelIdleTimer()
    cancelAutoDismiss()
    if _banner then
        UIManager:close(_banner)
        _banner = nil
    end
end

local function disconnectWifi()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return end
    Config.wifi_optimistic = false
    pcall(function() NetworkMgr:turnOffWifi() end)
end

local function showBanner(plugin)
    if _banner then return end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return end
    local ok_w, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_w or not wifi_on then return end

    local sw = Screen:getWidth()
    local bh = SP.XL

    local inner = FrameContainer:new{
        bordersize   = 0,
        background   = Theme.SURFACE_TOP,
        width        = sw,
        height       = bh,
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = bh },
            TextWidget:new{
                text    = _("WiFi still on · Tap to disconnect"),
                face    = FolioTheme.faceUI(FolioTheme.sizeBody()),
                fgcolor = Theme.TEXT,
                width   = sw - SP.SM,
            },
        },
    }

    local banner = InputContainer:new{
        dimen = Geom:new{ w = sw, h = bh },
        [1]   = inner,
        _plugin = plugin,
    }
    banner.ges_events = {
        TapBanner = {
            GestureRange:new{
                ges   = "tap",
                range = function() return banner.dimen end,
            },
        },
    }
    function banner:onTapBanner()
        cancelAutoDismiss()
        disconnectWifi()
        UIManager:close(self)
        _banner = nil
        local p = self._plugin
        if p and p._rebuildAllNavbars then
            p:_rebuildAllNavbars()
            local Topbar = require("folio_topbar")
            local cfg = Config.getTopbarConfig()
            if (cfg.side["wifi"] or "hidden") ~= "hidden" then
                Topbar.scheduleRefresh(p, 0)
            end
        end
        return true
    end

    _banner = banner
    UIManager:show(banner)

    _auto_dismiss_fn = function()
        _auto_dismiss_fn = nil
        if _banner then
            UIManager:close(_banner)
            _banner = nil
        end
    end
    UIManager:scheduleIn(10, _auto_dismiss_fn)
end

--- Schedule a reminder if Wi-Fi is still on after `delay_s` seconds of idle
--- (no further schedule calls). Call again after Wi-Fi on or network activity to reset idle.
function M.scheduleIdleReminder(plugin, delay_s)
    cancelIdleTimer()
    delay_s = delay_s or 60
    _idle_timer_fn = function()
        _idle_timer_fn = nil
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if not ok_nm or not NetworkMgr then return end
        local ok_w, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
        if not ok_w or not wifi_on then return end
        showBanner(plugin)
    end
    UIManager:scheduleIn(delay_s, _idle_timer_fn)
end

return M
