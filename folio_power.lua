-- folio_power.lua — Folio
-- Power / System screen (Mockup 4): battery hero, airplane & screensaver toggles,
-- OTA update row, build footer.

local CenterContainer     = require("ui/widget/container/centercontainer")
local Device              = require("device")
local FrameContainer      = require("ui/widget/container/framecontainer")
local Geom                = require("ui/geometry")
local GestureRange        = require("ui/gesturerange")
local HorizontalGroup     = require("ui/widget/horizontalgroup")
local HorizontalSpan      = require("ui/widget/horizontalspan")
local IconButton          = require("ui/widget/iconbutton")
local ImageWidget         = require("ui/widget/imagewidget")
local InputContainer      = require("ui/widget/container/inputcontainer")
local LeftContainer       = require("ui/widget/container/leftcontainer")
local OverlapGroup        = require("ui/widget/overlapgroup")
local RightContainer      = require("ui/widget/container/rightcontainer")
local TextBoxWidget       = require("ui/widget/textboxwidget")
local TextWidget          = require("ui/widget/textwidget")
local TitleBar            = require("ui/widget/titlebar")
local UIManager           = require("ui/uimanager")
local VerticalGroup       = require("ui/widget/verticalgroup")
local VerticalSpan        = require("ui/widget/verticalspan")
local DataStorage         = require("datastorage")
local Screen              = Device.screen
local _                   = require("gettext")

local Config   = require("folio_config")
local FolioTheme = require("folio_theme")
local Theme    = FolioTheme.Theme
local UI       = require("folio_core")

local M = {}

-- ---------------------------------------------------------------------------
-- Paths / version helpers
-- ---------------------------------------------------------------------------

local function koMdlightIcon(name)
    return DataStorage:getDataDir() .. "/resources/icons/mdlight/" .. name
end

local function getFolioVersion()
    local ok, meta = pcall(require, "_meta")
    if ok and meta and meta.version then return tostring(meta.version) end
    return "?"
end

local function getKoReaderVersionString()
    local ok, Version = pcall(require, "version")
    if not ok or not Version then return "?" end
    local norm, commit = Version:getNormalizedCurrentVersion()
    local short = Version:getShortVersion()
    if short and short ~= "" and short ~= "unknown" then
        return short
    end
    if norm then return tostring(norm) end
    return commit or "?"
end

local function getDeviceModelString()
    local ok, m = pcall(function()
        if Device.getDeviceModel then
            return Device:getDeviceModel()
        end
        return Device.model or (Device.info and Device:info()) or "?"
    end)
    if ok and m and m ~= "" then return tostring(m) end
    return "?"
end

-- ---------------------------------------------------------------------------
-- Battery % — KOReader uses PowerD:getCapacity(), not Device:getBatteryLevel()
-- ---------------------------------------------------------------------------

local function getBatteryPercent()
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    pcall(function() powerd:invalidateCapacityCache() end)
    local ok, cap = pcall(function() return powerd:getCapacity() end)
    if ok and cap ~= nil then return cap end
    return nil
end

-- ---------------------------------------------------------------------------
-- Wi-Fi state — airplane ON means wireless off
-- ---------------------------------------------------------------------------

local function isWifiAvailable()
    local ok, v = pcall(function() return Device:hasWifiToggle() end)
    return ok and v == true
end

local function isAirplaneOn()
    if not isWifiAvailable() then return false end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return false end
    local ok_on, on = pcall(function() return NetworkMgr:isWifiOn() end)
    return ok_on and not on
end

local function toggleWifiLikeBottombar()
    if not isWifiAvailable() then return false, "no_hw" end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return false, "no_mgr" end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok_state then wifi_on = false end
    if wifi_on then
        Config.wifi_optimistic = false
        pcall(function() NetworkMgr:turnOffWifi() end)
    else
        Config.wifi_optimistic = true
        pcall(function() NetworkMgr:turnOnWifi() end)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Screensaver type — cover art when locked
-- ---------------------------------------------------------------------------

local function isScreensaverCoverOn()
    local t = G_reader_settings:readSetting("screensaver_type")
    return t == "cover"
end

local function setScreensaverCover(on)
    if on then
        G_reader_settings:saveSetting("screensaver_type", "cover")
    else
        G_reader_settings:saveSetting("screensaver_type", "disable")
    end
    G_reader_settings:flush()
end

local function isScreensaverProgressOn()
    local msg = G_reader_settings:readSetting("screensaver_message") or ""
    return msg:find("%%P") ~= nil
end

local function setScreensaverProgress(on)
    if on then
        G_reader_settings:saveSetting("screensaver_message", "%T\n%P% read")
    else
        G_reader_settings:saveSetting("screensaver_message", "%T")
    end
    G_reader_settings:saveSetting("screensaver_show_message", true)
    G_reader_settings:flush()
end

-- ---------------------------------------------------------------------------
-- Custom toggle (48×28 scaled) — ON = PRIMARY + light knob right
-- ---------------------------------------------------------------------------

local function buildToggleVisual(on)
    local w, h = Screen:scaleBySize(48), Screen:scaleBySize(28)
    local knob = Screen:scaleBySize(20)
    local pad = Screen:scaleBySize(4)
    local track = FrameContainer:new{
        bordersize = 0,
        radius     = 0,
        background = on and Theme.PRIMARY or Theme.SURFACE_HIGH,
        width      = w,
        height     = h,
    }
    local knob_w = math.min(knob, w - pad * 2)
    local kx = on and (w - pad - knob_w) or pad
    local knob_h = math.min(knob, h - pad * 2)
    local knob_bb = FrameContainer:new{
        bordersize = 0,
        radius     = 0,
        background = on and Theme.ON_PRIMARY or Theme.TEXT,
        width      = knob_w,
        height     = knob_h,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        track,
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = kx },
                CenterContainer:new{
                    dimen = Geom:new{ w = knob_w, h = h },
                    knob_bb,
                },
            },
        },
    }
end

local function makeToggleRow(self_ref, on, callback)
    local w, h = Screen:scaleBySize(48), Screen:scaleBySize(28)
    local dim = Geom:new{ w = w, h = h }
    local C = InputContainer:new{
        dimen = dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return dim end },
            },
        },
    }
    function C:onTap()
        callback(self_ref)
        return true
    end
    C[1] = buildToggleVisual(on)
    return C
end

-- ---------------------------------------------------------------------------
-- PowerScreenWidget
-- ---------------------------------------------------------------------------

local PowerScreenWidget = InputContainer:extend{
    name              = "power",
    covers_fullscreen = true,
    _plugin           = nil,
}

function PowerScreenWidget:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    local Bottombar = require("folio_bottombar")
    local function _in_bar(ges)
        if not ges or not ges.pos then return false end
        return ges.pos.y >= Screen:getHeight() - Bottombar.TOTAL_H()
    end
    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
        BlockNavbarHold = {
            GestureRange:new{ ges = "hold", range = function() return self.dimen end },
        },
    }
    function self:onBlockNavbarTap(_a, ges) if _in_bar(ges) then return true end end
    function self:onBlockNavbarHold(_a, ges) if _in_bar(ges) then return true end end

    self.title_bar = TitleBar:new{
        show_parent = self,
        fullscreen  = true,
        title       = _("System"),
    }

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.BG,
        dimen = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }
end

function PowerScreenWidget:_buildTopRow(sw, header_h)
    local Topbar = require("folio_topbar")
    local info = Topbar.getTopbarInfo and Topbar.getTopbarInfo() or {}
    local face_word = FolioTheme.faceUI(FolioTheme.sizeLabelSm())
    local face_sys  = FolioTheme.faceContent(FolioTheme.sizeTitleMd())
    local face_icon = FolioTheme.faceUI(FolioTheme.sizeLabelSm())
    local pad       = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local side_pad  = FolioTheme.scaled(FolioTheme.Spacing.SM)

    local left_inner = HorizontalGroup:new{
        TextWidget:new{
            text    = "FOLIO",
            face    = face_word,
            fgcolor = Theme.TEXT,
        },
        HorizontalSpan:new{ width = pad },
        TextWidget:new{
            text    = _("System"),
            face    = face_sys,
            bold    = true,
            fgcolor = Theme.TEXT,
        },
    }

    local right_bits = HorizontalGroup{}
    right_bits[#right_bits + 1] = IconButton:new{
        icon     = "appbar.settings",
        width    = header_h - pad,
        height   = header_h - pad,
        padding  = 0,
        callback = function()
            local m = self._plugin and self._plugin.ui and self._plugin.ui.menu
            if m and m.onTapShowMenu then return m:onTapShowMenu() end
        end,
        show_parent = self,
    }
    if info.wifi then
        right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
        right_bits[#right_bits + 1] = TextWidget:new{
            text = "\u{ECA8}", face = face_icon, fgcolor = Theme.TEXT,
        }
    end
    if info.battery then
        right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
        right_bits[#right_bits + 1] = TextWidget:new{
            text = (info.battery_sym or "") .. info.battery .. "%",
            face = face_icon, fgcolor = Theme.TEXT,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.SURFACE_TOP,
        width = sw, height = header_h,
        OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = header_h },
            LeftContainer:new{
                dimen = Geom:new{ w = sw, h = header_h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = side_pad },
                    left_inner,
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = sw, h = header_h },
                HorizontalGroup:new{ right_bits, HorizontalSpan:new{ width = side_pad } },
            },
        },
    }
end

function PowerScreenWidget:_batteryHeroCard()
    local card_w = Screen:scaleBySize(280)
    local pct = getBatteryPercent()
    local pct_str = pct ~= nil and string.format("%d%%", pct) or "—"
    local powerd = Device:getPowerDevice()
    local sym = "?"
    if powerd then
        local cap = pct or 0
        local ok_sym, s = pcall(function()
            return powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), cap)
        end)
        if ok_sym and s then sym = s end
    end

    local icon_dim = Geom:new{ w = Screen:scaleBySize(80), h = Screen:scaleBySize(100) }
    local icon_inner = CenterContainer:new{
        dimen = icon_dim,
        TextWidget:new{
            text    = sym,
            face    = FolioTheme.faceContent(math.max(32, Screen:scaleBySize(64))),
            fgcolor = Theme.TEXT,
        },
    }

    local label_caps = TextWidget:new{
        text    = _("CURRENT CAPACITY"),
        face    = FolioTheme.faceUI(FolioTheme.sizeMicro()),
        fgcolor = Theme.TEXT_MUTED,
    }
    local pct_big = TextWidget:new{
        text    = pct_str,
        face    = FolioTheme.faceContent(FolioTheme.sizeDisplay()),
        bold    = true,
        fgcolor = Theme.TEXT,
    }

    local v = VerticalGroup:new{
        align = "center",
        icon_inner,
        VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) },
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = Screen:scaleBySize(14) },
            label_caps,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = Screen:scaleBySize(56) },
            pct_big,
        },
    }

    return FrameContainer:new{
        background = Theme.SURFACE_LOW,
        bordersize = 2,
        color      = Theme.PRIMARY,
        radius     = 0,
        padding    = FolioTheme.scaled(FolioTheme.Spacing.MD),
        width      = card_w,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w - FolioTheme.scaled(FolioTheme.Spacing.MD) * 2, h = 1 },
            v,
        },
    }
end

function PowerScreenWidget:_settingsRow(label, sub, on, on_toggle)
    local sw = Screen:getWidth()
    local margin_h = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local inner_w = sw - 2 * margin_h
    local row_h = Screen:scaleBySize(56)
    local pad_h = FolioTheme.scaled(FolioTheme.Spacing.SM)

    local face_title = FolioTheme.faceContent(FolioTheme.sizeBody())
    local face_sub   = FolioTheme.faceUI(FolioTheme.sizeMicro())

    local left = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text    = label,
            face    = face_title,
            bold    = true,
            fgcolor = Theme.TEXT,
            max_width = inner_w - Screen:scaleBySize(80),
        },
        TextWidget:new{
            text    = sub,
            face    = face_sub,
            fgcolor = Theme.TEXT_MUTED,
            max_width = inner_w - Screen:scaleBySize(80),
        },
    }

    local toggle_w = Screen:scaleBySize(48)
    local row_inner = HorizontalGroup:new{
        HorizontalSpan:new{ width = pad_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w - toggle_w - pad_h * 2, h = row_h },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w - toggle_w - pad_h * 2, h = row_h },
                left,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = toggle_w, h = row_h },
            makeToggleRow(self, on, on_toggle),
        },
        HorizontalSpan:new{ width = pad_h },
    }

    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Theme.SURFACE_LOW,
        width      = inner_w,
        height     = row_h,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = row_h },
            row_inner,
        },
    }
end

function PowerScreenWidget:_restartExitRow(sw, margin_h)
    local w = sw - 2 * margin_h
    local h = Screen:scaleBySize(48)
    local gap = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local half = math.floor((w - gap) / 2)
    local facebtn = FolioTheme.faceUI(math.max(12, Screen:scaleBySize(14)))
    local dim_r = Geom:new{ w = half, h = h }
    local dim_e = Geom:new{ w = half, h = h }

    local restart = InputContainer:new{
        dimen = dim_r,
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return dim_r end } },
        },
    }
    function restart:onTap()
        G_reader_settings:flush()
        UIManager:restartKOReader()
        return true
    end
    restart[1] = FrameContainer:new{
        bordersize = 2,
        color      = Theme.PRIMARY,
        background = Theme.SURFACE,
        radius     = 0,
        width      = half,
        height     = h,
        CenterContainer:new{
            dimen = dim_r,
            TextWidget:new{ text = _("RESTART"), face = facebtn, fgcolor = Theme.TEXT },
        },
    }

    local exit = InputContainer:new{
        dimen = dim_e,
        ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return dim_e end } },
        },
    }
    function exit:onTap()
        G_reader_settings:flush()
        UIManager:quit(0)
        return true
    end
    exit[1] = FrameContainer:new{
        bordersize = 0,
        radius     = 0,
        background = Theme.PRIMARY,
        width      = half,
        height     = h,
        CenterContainer:new{
            dimen = dim_e,
            TextWidget:new{ text = _("EXIT KOREADER"), face = facebtn, fgcolor = Theme.ON_PRIMARY },
        },
    }

    return FrameContainer:new{
        bordersize  = 0,
        padding     = 0,
        margin_left = margin_h,
        margin_right = margin_h,
        width       = sw,
        HorizontalGroup:new{
            restart,
            HorizontalSpan:new{ width = gap },
            exit,
        },
    }
end

function PowerScreenWidget:_updateSoftwareBar(sw, margin_h)
    local w = sw - 2 * margin_h
    local h = Screen:scaleBySize(72)
    local dim = Geom:new{ w = w, h = h }
    local dl_sz = Screen:scaleBySize(24)
    local pad = FolioTheme.scaled(FolioTheme.Spacing.MD)

    local dl_path = koMdlightIcon("move.down.svg")
    local dl_icon
    local ok_dl, dl_w = pcall(function()
        return ImageWidget:new{
            file   = dl_path,
            width  = dl_sz,
            height = dl_sz,
            alpha  = true,
            invert = true,
        }
    end)
    if ok_dl and dl_w then
        dl_icon = CenterContainer:new{
            dimen = Geom:new{ w = dl_sz, h = dl_sz },
            dl_w,
        }
    else
        dl_icon = CenterContainer:new{
            dimen = Geom:new{ w = dl_sz, h = dl_sz },
            TextWidget:new{
                text    = "↓",
                face    = FolioTheme.faceUI(math.max(10, Screen:scaleBySize(24))),
                fgcolor = Theme.ON_PRIMARY,
            },
        }
    end

    local left_col = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text    = _("MAINTENANCE"),
            face    = FolioTheme.faceUI(FolioTheme.sizeMicro()),
            fgcolor = Theme.ON_PRIMARY,
        },
        TextWidget:new{
            text    = _("Update Software"),
            face    = FolioTheme.faceContent(math.max(16, Screen:scaleBySize(22))),
            bold    = true,
            fgcolor = Theme.ON_PRIMARY,
        },
    }

    local C = InputContainer:new{
        dimen = dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return dim end },
            },
        },
    }
    function C:onTap()
        local ok_ota, OTAManager = pcall(require, "ui/otamanager")
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_ota and OTAManager and ok_nm and NetworkMgr then
            local connect_callback = function()
                OTAManager:fetchAndProcessUpdate()
            end
            NetworkMgr:runWhenOnline(connect_callback)
        else
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Check for updates is not available."),
                timeout = 3,
            })
        end
        return true
    end

    C[1] = FrameContainer:new{
        bordersize = 0,
        radius     = 0,
        background = Theme.PRIMARY,
        width      = w,
        height     = h,
        OverlapGroup:new{
            dimen = dim,
            LeftContainer:new{
                dimen = dim,
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = pad },
                    CenterContainer:new{
                        dimen = Geom:new{ w = w - dl_sz - pad * 3, h = h },
                        left_col,
                    },
                },
            },
            RightContainer:new{
                dimen = dim,
                HorizontalGroup:new{
                    CenterContainer:new{
                        dimen = Geom:new{ w = dl_sz + pad, h = h },
                        dl_icon,
                    },
                    HorizontalSpan:new{ width = pad },
                },
            },
        },
    }
    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        margin_left = margin_h,
        margin_right = margin_h,
        C,
    }
end

function PowerScreenWidget:_footerText()
    local folio_v = getFolioVersion()
    local ko_v = getKoReaderVersionString()
    local dev = getDeviceModelString():upper()
    local line = string.format(
        "FOLIO V%s · KOREADER V%s · %s",
        folio_v, ko_v, dev
    )
    return TextWidget:new{
        text    = line,
        face    = FolioTheme.faceUI(FolioTheme.sizeMicro()),
        fgcolor = Theme.TEXT_MUTED,
    }
end

function PowerScreenWidget:_buildMainContent()
    local content_h = self._navbar_content_h or UI.getContentHeight()
    local sw = Screen:getWidth()
    local header_h = Screen:scaleBySize(48)
    local margin_h = FolioTheme.scaled(FolioTheme.Spacing.MD)

    local body = VerticalGroup:new{ align = "center" }
    body[#body + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XL) }
    body[#body + 1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = 1 },
        self:_batteryHeroCard(),
    }
    body[#body + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }

    local vg_rows = VerticalGroup:new{ align = "center" }
    vg_rows[#vg_rows + 1] = self:_settingsRow(
        _("Airplane Mode"),
        _("DISCONNECT WIRELESS"),
        isAirplaneOn(),
        function(r)
            if not isWifiAvailable() then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Wi-Fi not available on this device."),
                    timeout = 2,
                })
                return
            end
            toggleWifiLikeBottombar()
            r:refresh()
            UIManager:setDirty(r, "ui")
        end
    )
    vg_rows[#vg_rows + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) }
    vg_rows[#vg_rows + 1] = self:_settingsRow(
        _("Screensaver"),
        _("SHOW COVER ART WHEN LOCKED"),
        isScreensaverCoverOn(),
        function(r)
            local next_on = not isScreensaverCoverOn()
            setScreensaverCover(next_on)
            r:refresh()
            UIManager:setDirty(r, "ui")
        end
    )
    vg_rows[#vg_rows + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) }
    vg_rows[#vg_rows + 1] = self:_settingsRow(
        _("Sleep screen details"),
        _("SHOW READING PROGRESS (%)"),
        isScreensaverProgressOn(),
        function(r)
            setScreensaverProgress(not isScreensaverProgressOn())
            r:refresh()
            UIManager:setDirty(r, "ui")
        end
    )
    vg_rows[#vg_rows + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) }
    vg_rows[#vg_rows + 1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = Screen:scaleBySize(52) },
        TextBoxWidget:new{
            text      = _("Custom images: add PNG/JPG to the screensaver folder under KOReader data, then choose Screen saver → Random image in KOReader."),
            face      = FolioTheme.faceUI(FolioTheme.sizeMicro()),
            fgcolor   = Theme.TEXT_MUTED,
            width     = sw - 2 * margin_h,
            alignment = "center",
            max_lines = 3,
        },
    }

    body[#body + 1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Theme.SURFACE,
        width = sw,
        vg_rows,
    }

    body[#body + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }
    body[#body + 1] = self:_restartExitRow(sw, margin_h)
    body[#body + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }
    body[#body + 1] = self:_updateSoftwareBar(sw, margin_h)
    body[#body + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XL) }
    body[#body + 1] = CenterContainer:new{
        dimen = Geom:new{ w = sw, h = Screen:scaleBySize(20) },
        self:_footerText(),
    }

    local main_col = VerticalGroup:new{
        align = "left",
        self:_buildTopRow(sw, header_h),
        body,
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Theme.BG,
        dimen = Geom:new{ w = sw, h = content_h },
        main_col,
    }
end

function PowerScreenWidget:refresh()
    if not self._navbar_container then return end
    local old = self._navbar_container[1]
    local new = self:_buildMainContent()
    if old and old.overlap_offset then new.overlap_offset = old.overlap_offset end
    self._navbar_container[1] = new
    UIManager:setDirty(self, "ui")
end

function PowerScreenWidget:onShow()
    pcall(function()
        local pd = Device:getPowerDevice()
        if pd and pd.invalidateCapacityCache then pd:invalidateCapacityCache() end
    end)
    if self._navbar_container then
        local old = self._navbar_container[1]
        local new = self:_buildMainContent()
        if old and old.overlap_offset then new.overlap_offset = old.overlap_offset end
        self._navbar_container[1] = new
    end
    UIManager:setDirty(self, "ui")
end

function PowerScreenWidget:onCloseWidget()
    self._plugin = nil
end

function M.show(plugin)
    if not plugin then return false end
    local w = PowerScreenWidget:new{ _plugin = plugin }
    UIManager:show(w)
    return true
end

return M
