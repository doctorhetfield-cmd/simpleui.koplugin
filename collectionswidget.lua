-- collectionswidget.lua — Folio
-- Fullscreen collections grid (Mockup 2). Re-exports pool APIs for folio_patches.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconButton      = require("ui/widget/iconbutton")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("gettext")
local util            = require("util")

local Config          = require("folio_config")
local FolioTheme        = require("folio_theme")
local Theme           = FolioTheme.Theme
local UI              = require("folio_core")

local MC = require("desktop_modules/module_collections")

local M = {}

M.getSelected       = MC.getSelected
M.saveSelected      = MC.saveSelected
M.getCoverOverrides = MC.getCoverOverrides
M.saveCoverOverrides = MC.saveCoverOverrides

-- ---------------------------------------------------------------------------
-- Dashed border (FrameContainer has no dashed mode)
-- ---------------------------------------------------------------------------

local function paintDashedBorder(bb, x, y, w, h, color, thick, dash, gap)
    thick = thick or 2
    dash  = dash or 6
    gap   = gap or 4
    local function hline(y0)
        local xi = 0
        while xi < w do
            local seg = math.min(dash, w - xi)
            bb:paintRect(x + xi, y + y0, seg, thick, color)
            xi = xi + dash + gap
        end
    end
    local function vline(x0)
        local yi = 0
        while yi < h do
            local seg = math.min(dash, h - yi)
            bb:paintRect(x + x0, y + yi, thick, seg, color)
            yi = yi + dash + gap
        end
    end
    hline(0)
    hline(h - thick)
    vline(0)
    vline(w - thick)
end

-- FrameContainer-like tile with dashed outer border; inner content in [1].
local DashedCollectionTile = InputContainer:extend{
    background = Theme.SURFACE,
    bordersize = 0,
    radius     = 0,
    width      = nil,
    height     = nil,
    margin     = 0,
}

function DashedCollectionTile:init()
    self.dimen = Geom:new{
        w = self.width,
        h = self.height,
    }
    InputContainer.init(self)
end

function DashedCollectionTile:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    local w, h = self.dimen.w, self.dimen.h
    if self.background then
        bb:paintRect(x, y, w, h, self.background)
    end
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
    paintDashedBorder(bb, x, y, w, h, Theme.GHOST_LINE, 2, 6, 4)
end

-- ---------------------------------------------------------------------------
-- Tile tap wrapper
-- ---------------------------------------------------------------------------

local function makeTapContainer(w, h, on_tap)
    local dimen = Geom:new{ w = w, h = h }
    local C = InputContainer:new{
        dimen = dimen,
        ges_events = {
            Tap = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return dimen end,
                },
            },
        },
    }
    function C:onTap()
        if on_tap then on_tap() end
        return true
    end
    return C
end

-- ---------------------------------------------------------------------------
-- Collections grid widget
-- ---------------------------------------------------------------------------

local CollectionsGridWidget = InputContainer:extend{
    name              = "coll_list",
    covers_fullscreen = true,
    _plugin           = nil,
    _fmc              = nil,
}

function CollectionsGridWidget:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

    local Bottombar = require("folio_bottombar")
    local function _in_bar(ges)
        if not ges or not ges.pos then return false end
        local bar_y = Screen:getHeight() - Bottombar.TOTAL_H()
        return ges.pos.y >= bar_y
    end

    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.dimen end,
            },
        },
        BlockNavbarHold = {
            GestureRange:new{
                ges   = "hold",
                range = function() return self.dimen end,
            },
        },
    }
    function self:onBlockNavbarTap(_args, ges)
        if _in_bar(ges) then return true end
    end
    function self:onBlockNavbarHold(_args, ges)
        if _in_bar(ges) then return true end
    end

    -- Satisfies patchUIManagerShow + applyToInjected; not embedded in [1] (homescreen pattern).
    self.title_bar = TitleBar:new{
        show_parent             = self,
        fullscreen              = true,
        title                   = _("Collections"),
        left_icon               = "appbar.navigation.arrow.back",
        left_icon_tap_callback  = function()
            if self._plugin then
                self._plugin:_navigate("home", self, Config.loadTabConfig(), false)
            else
                UIManager:close(self)
            end
        end,
        left_icon_hold_callback = false,
    }

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self[1] = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Theme.BG,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }
end

function CollectionsGridWidget:_buildTopRow(sw, header_h)
    local Topbar = require("folio_topbar")
    local info = Topbar.getTopbarInfo and Topbar.getTopbarInfo() or {}

    local face_title = FolioTheme.faceContent(FolioTheme.sizeTitleMd())
    local face_icon  = FolioTheme.faceUI(FolioTheme.sizeLabelSm())
    local pad        = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local side_pad   = FolioTheme.scaled(FolioTheme.Spacing.SM)

    local title_w = TextWidget:new{
        text    = _("Collections"),
        face    = face_title,
        bold    = true,
        fgcolor = Theme.TEXT,
    }

    local left_inner = HorizontalGroup:new{
        IconButton:new{
            icon     = "appbar.navigation.arrow.back",
            width    = header_h - pad,
            height   = header_h - pad,
            padding  = 0,
            callback = function()
                if self._plugin then
                    self._plugin:_navigate("home", self, Config.loadTabConfig(), false)
                else
                    UIManager:close(self)
                end
            end,
            show_parent = self,
        },
        HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
        title_w,
    }

    local right_bits = HorizontalGroup:new{}
    if info.battery then
        right_bits[#right_bits + 1] = TextWidget:new{
            text    = (info.battery_sym or "") .. info.battery .. "%",
            face    = face_icon,
            fgcolor = Theme.TEXT,
        }
    end
    if info.wifi then
        if #right_bits > 0 then
            right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
        end
        right_bits[#right_bits + 1] = TextWidget:new{
            text    = "\u{ECA8}",
            face    = face_icon,
            fgcolor = Theme.TEXT,
        }
    end
    if #right_bits > 0 then
        right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
    end
    right_bits[#right_bits + 1] = IconButton:new{
        icon     = "appbar.settings",
        width    = header_h - pad,
        height   = header_h - pad,
        padding  = 0,
        callback = function()
            local m = self._plugin and self._plugin.ui and self._plugin.ui.menu
            if m and m.onTapShowMenu then
                return m:onTapShowMenu()
            end
        end,
        show_parent = self,
    }

    return FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Theme.SURFACE_TOP,
        width      = sw,
        height     = header_h,
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
                HorizontalGroup:new{
                    right_bits,
                    HorizontalSpan:new{ width = side_pad },
                },
            },
        },
    }
end

function CollectionsGridWidget:_collectionRows()
    local ReadCollection = require("readcollection")
    ReadCollection:_read()

    local fmc = self._fmc
    local screen_w = Screen:getWidth()
    local h_pad    = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local gap      = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local cols     = 3
    local inner_w  = screen_w - 2 * h_pad
    local tile_w   = (inner_w - gap * (cols - 1)) / cols
    local tile_h   = tile_w

    local items = {}
    for coll_name in pairs(ReadCollection.coll) do
        items[#items + 1] = {
            name  = coll_name,
            order = ReadCollection.coll_settings[coll_name].order,
        }
    end
    if #items > 1 then
        table.sort(items, function(a, b) return a.order < b.order end)
    end

    local face_name = FolioTheme.faceContent(FolioTheme.sizeTitleMd())
    local face_cnt  = FolioTheme.faceUI(FolioTheme.sizeLabelSm())
    local xs        = FolioTheme.scaled(FolioTheme.Spacing.XS)

    local cells = {}

    local function collectionTitle(name)
        if fmc and type(fmc.getCollectionTitle) == "function" then
            return fmc:getCollectionTitle(name)
        end
        return name
    end

    for _, it in ipairs(items) do
        local cname = it.name
        local nbooks = util.tableSize(ReadCollection.coll[cname])
        local label = string.format("%d %s", nbooks, _("BOOKS")):upper()

        local inner = CenterContainer:new{
            dimen = Geom:new{ w = tile_w - 4, h = tile_h - 4 },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text            = collectionTitle(cname),
                    face            = face_name,
                    bold            = true,
                    fgcolor         = Theme.TEXT,
                    max_width       = tile_w - 8,
                },
                VerticalSpan:new{ width = xs },
                TextWidget:new{
                    text      = label,
                    face      = face_cnt,
                    fgcolor   = Theme.TEXT_MUTED,
                    max_width = tile_w - 8,
                },
            },
        }

        local frame = FrameContainer:new{
            background   = Theme.SURFACE_LOW,
            bordersize   = 2,
            color        = Theme.PRIMARY,
            radius       = 0,
            padding      = 0,
            margin       = 0,
            width        = tile_w,
            height       = tile_h,
            inner,
        }

        local wrap = makeTapContainer(tile_w, tile_h, function()
            if fmc and type(fmc.onShowColl) == "function" then
                fmc:onShowColl(cname)
            end
        end)
        wrap[1] = frame
        cells[#cells + 1] = wrap
    end

    local plus_face = FolioTheme.faceContent(FolioTheme.sizeTitleLg())
    local new_inner = CenterContainer:new{
        dimen = Geom:new{ w = tile_w - 4, h = tile_h - 4 },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text    = "+",
                face    = plus_face,
                bold    = true,
                fgcolor = Theme.TEXT,
            },
            VerticalSpan:new{ width = xs },
            TextWidget:new{
                text      = _("NEW COLLECTION"),
                face      = face_cnt,
                fgcolor   = Theme.TEXT_MUTED,
                max_width = tile_w - 8,
            },
        },
    }

    local new_tile = DashedCollectionTile:new{
        width      = tile_w,
        height     = tile_h,
        background = Theme.SURFACE,
        [1]        = new_inner,
    }

    local self_ref = self
    local new_wrap = makeTapContainer(tile_w, tile_h, function()
        local fm = self_ref._plugin and self_ref._plugin.ui
        local fmc2 = fm and fm.collections
        if fmc2 and type(fmc2.editCollectionName) == "function" then
            fmc2:editCollectionName(function(name)
                ReadCollection:addCollection(name)
                ReadCollection:write({ [name] = true })
                self_ref:refresh()
            end)
        else
            logger.warn("folio: collectionswidget: editCollectionName unavailable")
        end
    end)
    new_wrap[1] = new_tile
    cells[#cells + 1] = new_wrap

    local rows = VerticalGroup:new{ align = "center" }
    local row_group
    for i = 1, #cells do
        local col = (i - 1) % cols
        if col == 0 then
            row_group = HorizontalGroup:new{}
            if #rows > 0 then
                rows[#rows + 1] = VerticalSpan:new{ width = gap }
            end
            rows[#rows + 1] = row_group
        end
        if col > 0 then
            row_group[#row_group + 1] = HorizontalSpan:new{ width = gap }
        end
        row_group[#row_group + 1] = cells[i]
    end

    local total = #cells
    local footer_text = string.format(_("SHOWING %d OF %d COLLECTIONS"), total, total)
    local face_ft = FolioTheme.faceUI(FolioTheme.sizeMicro())

    rows[#rows + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }
    rows[#rows + 1] = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(20) },
        TextWidget:new{
            text      = footer_text,
            face      = face_ft,
            fgcolor   = Theme.TEXT_MUTED,
            max_width = inner_w,
        },
    }

    return rows
end

function CollectionsGridWidget:refresh()
    if not self._navbar_container then return end
    local old = self._navbar_container[1]
    local new = self:_buildMainContent()
    if old and old.overlap_offset then
        new.overlap_offset = old.overlap_offset
    end
    self._navbar_container[1] = new
    UIManager:setDirty(self, "ui")
end

function CollectionsGridWidget:_buildMainContent()
    local content_h = self._navbar_content_h or UI.getContentHeight()
    local sw        = Screen:getWidth()
    local header_h  = Screen:scaleBySize(48)
    local h_pad     = FolioTheme.scaled(FolioTheme.Spacing.MD)

    local rows = self:_collectionRows()
    local scroll_h = math.max(0, content_h - header_h)

    local scroll_body = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = h_pad,
        padding_right = h_pad,
        background    = Theme.BG,
        [1]           = rows,
    }

    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = scroll_h },
        scroll_body,
    }
    self.cropping_widget = scroll

    return FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        background   = Theme.BG,
        dimen        = Geom:new{ w = sw, h = content_h },
        VerticalGroup:new{
            align = "left",
            self:_buildTopRow(sw, header_h),
            scroll,
        },
    }
end

function CollectionsGridWidget:onShow()
    if self._navbar_container then
        local old = self._navbar_container[1]
        local new = self:_buildMainContent()
        if old and old.overlap_offset then
            new.overlap_offset = old.overlap_offset
        end
        self._navbar_container[1] = new
    end
    UIManager:setDirty(self, "ui")
end

function CollectionsGridWidget:onCloseWidget()
    self._plugin = nil
    self._fmc = nil
end

-- ---------------------------------------------------------------------------
-- Public: open grid (normal list mode only — select mode stays on KOReader menu)
-- ---------------------------------------------------------------------------

function M.show(plugin, fmc_self)
    if not (plugin and fmc_self) then return false end
    local w = CollectionsGridWidget:new{
        _plugin = plugin,
        _fmc    = fmc_self,
    }
    UIManager:show(w)
    return true
end

return M
