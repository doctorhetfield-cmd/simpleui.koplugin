-- module_clock.lua — Simple UI
-- Clock module: clock always visible, with optional date and battery toggles.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("sui_i18n").translate

local UI           = require("sui_core")
local UIManager    = require("ui/uimanager")
local Config       = require("sui_config")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Translated date string
-- os.date("%A, %d %B") always returns English on most eReader locales.
-- We use os.date("*t") for the numeric indices and look up translated names.
-- ---------------------------------------------------------------------------

-- _WEEKDAYS and _MONTHS are intentionally NOT built at module-load time so
-- that _() is called after the user's locale has been applied. They are built
-- on the first _localDate() call and reused from that point on — the locale
-- never changes within a running KOReader session, so caching is safe.
local _weekdays = nil
local _months   = nil

local function _localDate()
    -- Pass os.time() explicitly: os.date("*t") without argument can return
    -- nil in LuaJIT on some platforms (macOS emulator) when timezone handling
    -- fails. os.date("*t", os.time()) is always safe.
    local now = os.time()
    local t   = os.date("*t", now)
    if not t or not t.mday then
        -- Fallback via the datetime module's locale-aware formatter.
        return datetime.secondsToDate(now, true)
    end
    -- Build translation tables on first call only; never recreated afterwards.
    if not _weekdays then
        _weekdays = {
            _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"),
            _("Thursday"), _("Friday"), _("Saturday"),
        }
        _months = {
            _("January"), _("February"), _("March"),     _("April"),
            _("May"),     _("June"),     _("July"),       _("August"),
            _("September"), _("October"), _("November"),  _("December"),
        }
    end
    local weekday = _weekdays[t.wday] or os.date("%A", now)
    local month   = _months[t.month]  or os.date("%B", now)
    return string.format("%s, %d %s", weekday, t.mday, month)
end

-- ---------------------------------------------------------------------------
-- Pixel constants — base values at 100% scale; scaled at render time.
-- ---------------------------------------------------------------------------

local _BASE_CLOCK_W       = Screen:scaleBySize(50)
local _BASE_CLOCK_FS      = Screen:scaleBySize(44)
local _BASE_DATE_H        = Screen:scaleBySize(17)
local _BASE_DATE_GAP      = Screen:scaleBySize(19)
local _BASE_DATE_FS       = Screen:scaleBySize(11)
local _BASE_BATT_FS       = Screen:scaleBySize(10)
local _BASE_BATT_H        = Screen:scaleBySize(15)
local _BASE_BATT_GAP      = Screen:scaleBySize(19)
local _BASE_BOT_PAD_EXTRA = Screen:scaleBySize(4)

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_ON        = "clock_enabled"    -- pfx .. "clock_enabled"
local SETTING_DATE      = "clock_date"       -- pfx .. "clock_date"      (default ON)
local SETTING_BATTERY   = "clock_battery"    -- pfx .. "clock_battery"   (default ON)
local SETTING_DATE_GAP  = "clock_date_gap"   -- pfx .. "clock_date_gap"  (integer %, default 100)
local SETTING_BATT_GAP  = "clock_batt_gap"   -- pfx .. "clock_batt_gap"  (integer %, default 100)

local ELEM_GAP_MIN  = 0
local ELEM_GAP_MAX  = 300
local ELEM_GAP_STEP = 10
local ELEM_GAP_DEF  = 100

local function _clampElemGap(n)
    return math.max(ELEM_GAP_MIN, math.min(ELEM_GAP_MAX, math.floor(n)))
end

local function getDateGapPct(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_DATE_GAP)
    local n = tonumber(v)
    return n and _clampElemGap(n) or ELEM_GAP_DEF
end

local function getBattGapPct(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_BATT_GAP)
    local n = tonumber(v)
    return n and _clampElemGap(n) or ELEM_GAP_DEF
end

local function isClockEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_ON)
    return v ~= false   -- default ON
end

local function isDateEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_DATE)
    return v ~= false   -- default ON
end

local function isBattEnabled(pfx)
    local v = G_reader_settings:readSetting(pfx .. SETTING_BATTERY)
    return v ~= false   -- default ON
end

-- ---------------------------------------------------------------------------
-- Battery helpers
-- ---------------------------------------------------------------------------

-- Returns battery level clamped to [0,100] and charging flag.
local function _battInfo()
    local pwr = Device:getPowerDevice()
    if not pwr then return nil, false end
    local lvl, charging = nil, false
    if pwr.getCapacity then
        local ok, v = pcall(pwr.getCapacity, pwr)
        if ok and type(v) == "number" then
            lvl = v < 0 and 0 or v > 100 and 100 or v
        end
    end
    if pwr.isCharging then
        local ok, v = pcall(pwr.isCharging, pwr); if ok then charging = v end
    end
    return lvl, charging
end

-- lvl is always a number in [0,100] or nil (normalised by _battInfo).
-- Battery always uses CLR_TEXT_SUB — same subdued grey as date and author text.

-- Builds the battery display string.
-- Uses ▰/▱ (filled/empty blocks) matching module_header.lua visual style.
-- Charging replaces the first block with ⚡.
local function _battText(lvl, charging)
    if type(lvl) ~= "number" then return "N/A" end
    local bars
    if     lvl >= 90 then bars = "▰▰▰▰"
    elseif lvl >= 60 then bars = "▰▰▰▱"
    elseif lvl >= 40 then bars = "▰▰▱▱"
    elseif lvl >= 20 then bars = "▰▱▱▱"
    else                  bars = "▱▱▱▱" end
    local icon = charging and ("⚡" .. bars:sub(4)) or bars
    return string.format("%s %d%%", icon, lvl)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function _vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

local function build(w, pfx, vspan_pool)
    local scale     = Config.getModuleScale("clock", pfx)

    -- Scale all dimensions from base values.
    local clock_w       = math.floor(_BASE_CLOCK_W       * scale)
    local clock_fs      = math.max(10, math.floor(_BASE_CLOCK_FS  * scale))
    local date_h        = math.max(8,  math.floor(_BASE_DATE_H    * scale))
    local date_gap      = math.max(0,  math.floor(_BASE_DATE_GAP  * scale * getDateGapPct(pfx) / 100))
    local batt_gap      = math.max(0,  math.floor(_BASE_BATT_GAP  * scale * getBattGapPct(pfx) / 100))
    local date_fs       = math.max(8,  math.floor(_BASE_DATE_FS   * scale))
    local batt_fs       = math.max(7,  math.floor(_BASE_BATT_FS   * scale))
    local batt_h        = math.max(7,  math.floor(_BASE_BATT_H    * scale))

    local bot_pad_extra = math.floor(_BASE_BOT_PAD_EXTRA * scale)

    local show_clock = isClockEnabled(pfx)
    local show_date  = isDateEnabled(pfx)
    local show_batt  = isBattEnabled(pfx)
    local inner_w    = w - PAD * 2

    local vg = VerticalGroup:new{ align = "center" }

    -- Clock
    if show_clock then
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = clock_w },
            TextWidget:new{
                text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
                face = Font:getFace("smallinfofont", clock_fs),
                bold = true,
            },
        }
    end

    if show_date then
        if #vg > 0 then vg[#vg+1] = _vspan(date_gap, vspan_pool) end
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = date_h },
            TextWidget:new{
                text    = _localDate(),
                face    = Font:getFace("smallinfofont", date_fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    if show_batt then
        if #vg > 0 then vg[#vg+1] = _vspan(batt_gap, vspan_pool) end
        local lvl, charging = _battInfo()
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = batt_h },
            TextWidget:new{
                text    = _battText(lvl, charging),
                face    = Font:getFace("smallinfofont", batt_fs),
                fgcolor = CLR_TEXT_SUB,
            },
        }
    end

    if #vg == 0 then return nil end

    return FrameContainer:new{
        bordersize     = 0,
        padding        = PAD,
        padding_bottom = PAD2 + bot_pad_extra,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "clock"
M.name       = _("Clock")
M.label      = nil
M.default_on = true

function M.isEnabled(pfx)
    return isClockEnabled(pfx) or isDateEnabled(pfx) or isBattEnabled(pfx)
end

function M.setEnabled(pfx, on)
    if not on then
        G_reader_settings:saveSetting(pfx .. SETTING_ON, false)
        G_reader_settings:saveSetting(pfx .. SETTING_DATE, false)
        G_reader_settings:saveSetting(pfx .. SETTING_BATTERY, false)
    else
        G_reader_settings:saveSetting(pfx .. SETTING_ON, true)
        G_reader_settings:saveSetting(pfx .. SETTING_DATE, true)
        G_reader_settings:saveSetting(pfx .. SETTING_BATTERY, true)
    end
end

M.getCountLabel = nil

-- ---------------------------------------------------------------------------
-- Surgical clock tick — rebuilds only the clock widget inside the body
-- VerticalGroup, without triggering a full homescreen rebuild.
--
-- The homescreen records _clock_body_ref, _clock_body_idx, and
-- _clock_is_wrapped during _buildContent() (see below).  The tick reads
-- those fields to do a targeted swap, then marks only the navbar container
-- dirty.  Falls back to a full _refresh() if the index was not recorded.
-- ---------------------------------------------------------------------------

local _timer     = nil   -- scheduled function reference (module-level singleton)
local _hs_widget = nil   -- weak reference to the live HomescreenWidget

local function _tick()
    _timer = nil   -- timer has fired; clear before rescheduling

    -- Abort if the homescreen instance has changed or gone away.
    local hs = _hs_widget
    if not hs then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS or HS._instance ~= hs then _hs_widget = nil; return end

    -- Do not update while suspended — some platforms fire pending timers
    -- during the suspend transition before the scheduler pauses.
    -- Crucially: do NOT reschedule here. Rescheduling would create a new timer
    -- that onSuspend can no longer cancel (it already ran), causing a 60s loop
    -- that keeps firing throughout the entire suspend period.
    -- HomescreenWidget:onResume calls ClockMod.scheduleRefresh() to restart the
    -- chain on wakeup — no action needed here.
    --
    -- Two complementary guards:
    -- • hs._suspended — set by HomescreenWidget:onSuspend() when the Suspend
    --   event reaches the widget via broadcastEvent.
    -- • plugin._simpleui_suspended — set by SimpleUIPlugin:onSuspend(), which
    --   runs in the same broadcastEvent pass but may arrive before or after the
    --   widget handler depending on stack order. Checking both closes the race
    --   window where the UIManager has already dequeued this timer for execution
    --   in the current tick before either flag was set.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local plugin = FM and FM.instance and FM.instance._simpleui_plugin
    if hs._suspended or (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then
        return
    end

    -- Do not update while a book is open — the homescreen is hidden anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        M.scheduleRefresh(hs)
        return
    end

    -- Fast path: swap only the clock widget in the body VerticalGroup.
    local body       = hs._clock_body_ref
    local idx        = hs._clock_body_idx
    local is_wrapped = hs._clock_is_wrapped
    local swapped    = false

    if body and idx and body[idx] and hs._navbar_container then
        local sw      = Screen:getWidth()
        local SIDE_PAD = require("sui_core").SIDE_M()
        local inner_w  = hs._clock_inner_w or (sw - SIDE_PAD * 2)

        -- In landscape mode the homescreen applies a scale reduction factor to
        -- all modules.  Replicate it here so the surgical swap produces a widget
        -- at the same size as the one built during _updatePage.
        local lf = hs._clock_landscape_factor
        local _orig_getModuleScale, _orig_getLabelScale, _orig_getThumbScale
        if lf then
            _orig_getModuleScale = Config.getModuleScale
            _orig_getLabelScale  = Config.getLabelScale
            _orig_getThumbScale  = Config.getThumbScale
            Config.getModuleScale = function(mod_id, pfx)
                return _orig_getModuleScale(mod_id, pfx) * lf
            end
            Config.getLabelScale = function()
                return _orig_getLabelScale() * lf
            end
            Config.getThumbScale = function(mod_id, pfx)
                return _orig_getThumbScale(mod_id, pfx) * lf
            end
        end

        local ok_w, new_widget = pcall(build, inner_w, hs._clock_pfx,
                                        hs._vspan_pool)

        if lf then
            Config.getModuleScale = _orig_getModuleScale
            Config.getLabelScale  = _orig_getLabelScale
            Config.getThumbScale  = _orig_getThumbScale
        end

        if ok_w and new_widget then
            if is_wrapped then
                -- The clock was wrapped in an InputContainer for hold-to-settings.
                -- Replace the inner slot [1] to keep the gesture handler alive.
                body[idx][1] = new_widget
            else
                body[idx] = new_widget
            end
            UIManager:setDirty(hs, "ui")
            swapped = true
        end
    end

    if not swapped then
        -- Slow-path fallback — only triggered when the clock module is on the
        -- current page but build() failed (e.g. transient font-cache miss).
        -- idx == nil means clock is simply not on the current page: nothing to
        -- repaint, so skip the rebuild entirely.
        -- Use _updatePage(true) directly — same as the original _clockTick:
        -- immediate, keeps book/stats caches intact, no unnecessary DB roundtrips.
        if idx ~= nil and hs._navbar_container then
            local ok = pcall(function()
                hs:_updatePage(true)
                UIManager:setDirty(hs, "ui")
            end)
            if not ok then _hs_widget = nil; return end
        end
    end

    -- ---------------------------------------------------------------------------
    -- Topbar clock synchronisation.
    -- Both clocks use the formula 60-(os.time()%60)+1 to schedule their next tick.
    -- If they start from different moments (e.g. topbar restarted by a frontlight
    -- event mid-minute) they phase-drift and show different minutes.
    --
    -- Fix: drive the topbar refresh from this same callback, so both clocks read
    -- os.time() at the same moment and calculate the same next-tick delay.
    -- After this call, both chains reschedule to the identical next boundary.
    --
    -- `plugin` was resolved above for the suspend guard — reuse it here.
    -- ---------------------------------------------------------------------------
    if plugin and not plugin._simpleui_suspended then
        local Topbar = package.loaded["sui_topbar"]
        if Topbar then
            -- Cancel the topbar's own pending timer before refreshing — without
            -- this, the topbar would fire again on its old schedule in addition
            -- to the reschedule at the end of Topbar.refresh().
            if plugin._topbar_timer then
                UIManager:unschedule(plugin._topbar_timer)
                plugin._topbar_timer = nil
            end
            pcall(Topbar.refresh, Topbar, plugin)
        end
    end

    M.scheduleRefresh(hs)
end

-- Schedule the next tick, aligned to the next minute boundary.
-- Safe to call repeatedly — cancels any pending timer first.
function M.scheduleRefresh(hs)
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = hs
    local secs = 60 - (os.time() % 60) + 1
    _timer = _tick
    UIManager:scheduleIn(secs, _timer)
end

-- Cancel any pending timer and release the homescreen reference.
-- Called from onSuspend and onCloseWidget.
function M.cancelRefresh()
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _hs_widget = nil
end

function M.build(w, ctx)
    -- Record swap coordinates on the homescreen widget so the tick can do a
    -- surgical replacement without rebuilding the entire page.  These fields
    -- are written here (inside build) because build() is called from within
    -- the module loop in _buildContent(), at which point the body index is
    -- not yet known to the homescreen.  The homescreen sets _clock_body_idx
    -- immediately after build() returns (see sui_homescreen.lua).
    if ctx._hs_widget then
        ctx._hs_widget._clock_pfx      = ctx.pfx
        ctx._hs_widget._clock_inner_w  = w
    end
    return build(w, ctx.pfx, ctx.vspan_pool)
end

function M.getHeight(ctx)
    local scale     = Config.getModuleScale("clock", ctx.pfx)
    local clock_w   = math.floor(_BASE_CLOCK_W   * scale)
    local date_h    = math.max(8, math.floor(_BASE_DATE_H   * scale))
    local date_gap  = math.max(0, math.floor(_BASE_DATE_GAP * scale * getDateGapPct(ctx.pfx) / 100))
    local batt_gap  = math.max(0, math.floor(_BASE_BATT_GAP * scale * getBattGapPct(ctx.pfx) / 100))
    local batt_h    = math.max(7, math.floor(_BASE_BATT_H   * scale))


    local h_base      = PAD * 2 + PAD2
    local show_clock  = isClockEnabled(ctx.pfx)
    local show_date   = isDateEnabled(ctx.pfx)
    local show_batt   = isBattEnabled(ctx.pfx)

    local h = h_base
    if show_clock then h = h + clock_w end
    if show_date  then
        h = h + date_h
        if show_clock then h = h + date_gap end
    end
    if show_batt  then
        h = h + batt_h
        if show_clock or show_date then h = h + batt_gap end
    end
    return h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("clock", pfx) end,
        set          = function(v) Config.setModuleScale(v, "clock", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end
function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle(key, current)
        G_reader_settings:saveSetting(pfx .. key, not current)
        refresh()
    end

    return {
        {
            text           = _lc("Show Clock"),
            checked_func   = function() return isClockEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_ON, isClockEnabled(pfx)) end,
        },
        {
            text           = _lc("Show Date"),
            checked_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_DATE, isDateEnabled(pfx)) end,
        },
        {
            text           = _lc("Show Battery"),
            checked_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_BATTERY, isBattEnabled(pfx)) end,
        },
        _makeScaleItem(ctx_menu),
        {
            text_func      = function()
                local pct = getDateGapPct(pfx)
                return pct == ELEM_GAP_DEF
                    and _lc("Date Spacing")
                    or  string.format("%s (%d%%)", _lc("Date Spacing"), pct)
            end,
            enabled_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                UIManager_:show(SpinWidget:new{
                    title_text    = _lc("Date Spacing"),
                    info_text     = _lc("Vertical space between the clock and the date.\n100% is the default spacing."),
                    value         = getDateGapPct(pfx),
                    value_min     = ELEM_GAP_MIN,
                    value_max     = ELEM_GAP_MAX,
                    value_step    = ELEM_GAP_STEP,
                    unit          = "%",
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = ELEM_GAP_DEF,
                    callback      = function(spin)
                        G_reader_settings:saveSetting(pfx .. SETTING_DATE_GAP, _clampElemGap(spin.value))
                        refresh()
                    end,
                })
            end,
        },
        {
            text_func      = function()
                local pct = getBattGapPct(pfx)
                return pct == ELEM_GAP_DEF
                    and _lc("Battery Spacing")
                    or  string.format("%s (%d%%)", _lc("Battery Spacing"), pct)
            end,
            enabled_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                UIManager_:show(SpinWidget:new{
                    title_text    = _lc("Battery Spacing"),
                    info_text     = _lc("Vertical space between the date (or clock) and the battery.\n100% is the default spacing."),
                    value         = getBattGapPct(pfx),
                    value_min     = ELEM_GAP_MIN,
                    value_max     = ELEM_GAP_MAX,
                    value_step    = ELEM_GAP_STEP,
                    unit          = "%",
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = ELEM_GAP_DEF,
                    callback      = function(spin)
                        G_reader_settings:saveSetting(pfx .. SETTING_BATT_GAP, _clampElemGap(spin.value))
                        refresh()
                    end,
                })
            end,
        },
    }
end

return M