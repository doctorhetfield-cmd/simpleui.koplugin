-- sui_homescreen.lua — SimpleUI fullscreen homescreen widget.
-- Shown when the "Homescreen" tab is tapped. Shares module registry and module
-- files with the Continue page but is fully independent: separate settings
-- prefix (simpleui_hs_), separate caches, and its own lifecycle.

local Blitbuffer       = require("ffi/blitbuffer")
local BD               = require("ui/bidi")
local BottomContainer  = require("ui/widget/container/bottomcontainer")
local Button           = require("ui/widget/button")
local CenterContainer  = require("ui/widget/container/centercontainer")
local OverlapGroup     = require("ui/widget/overlapgroup")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local GestureRange     = require("ui/gesturerange")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local InputContainer   = require("ui/widget/container/inputcontainer")
local TextWidget       = require("ui/widget/textwidget")
local TitleBar         = require("ui/widget/titlebar")
local UIManager        = require("ui/uimanager")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local logger           = require("logger")
local _                = require("sui_i18n").translate
local N_               = require("sui_i18n").ngettext
local T                = require("ffi/util").template
local Config           = require("sui_config")
local Registry         = require("desktop_modules/moduleregistry")
local SUISettings = require("sui_store")
local Event            = require("ui/event")
local Screen           = Device.screen
local UI               = require("sui_core")
local Bottombar        = require("sui_bottombar")
local ImageWidget      = require("ui/widget/imagewidget")
local lfs              = require("libs/libkoreader-lfs")

-- ---------------------------------------------------------------------------
-- Look & Feel state — wallpaper background override
--
-- All settings live under the "simpleui_style_*" namespace.
--

local _style_bg_cache     = nil   -- cached ImageWidget for the current wallpaper
local _style_bg_cache_w   = 0     -- screen width  at cache-creation time
local _style_bg_cache_h   = 0     -- screen height at cache-creation time
local _style_bg_cache_nm  = nil   -- Screen.night_mode value at cache-creation time

-- Lazy reference to ffi/pic (used only for auto-rotate dimension probe).
local _pic = nil
local function _getPic()
    if not _pic then
        local ok, m = pcall(require, "ffi/pic")
        if ok then _pic = m end
    end
    return _pic
end

-- Setting readers — centralised so _styleGetBgWidget stays readable.
local function _wpStretch()    return SUISettings:isTrue("simpleui_style_wallpaper_stretch")       end
local function _wpAutoRotate() return SUISettings:nilOrTrue("simpleui_style_wallpaper_autorotate") end
local function _wpInvertNight() return SUISettings:isTrue("simpleui_style_wallpaper_invert_night") end
local function _wpOpacity()    return SUISettings:readSetting("simpleui_style_wallpaper_opacity", 0) end

-- Pure helper: tests whether (x, y) falls inside a ratio-defined zone.
-- Defined at module level so it is created once and never re-allocated per
-- gesture event (unlike a closure defined inside _fmGestureAction).
local function _inZone(z, x, y, sw, sh)
    if not z then return false end
    return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
       and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
end

-- Reusable candidate buffer for _fmGestureAction.
-- Avoids allocating a new table on every gesture event.
-- Entries 1..n are valid after a call; the rest are nil-cleared before returning.
local _candidates = {}

-- Returns DataStorage/simpleui/sui_wallpapers/, creating it if needed.
local function _styleWallpapersDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local dir
    if ok_ds and DataStorage then
        dir = DataStorage:getSettingsDir() .. "/simpleui/sui_wallpapers"
    else
        local src = debug.getinfo(1, "S").source or ""
        dir = (src:match("^@(.+/)[^/]+$") or "./") .. "sui_wallpapers"
    end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

-- Returns the cached bg ImageWidget, or nil when unset.
-- Cache is keyed on (path, screen w/h, night-mode state) — any change to those
-- values triggers a rebuild. Setting changes (stretch, rotate, invert) always
-- call _styleFreeBgCache() before _rebuildHomescreenLayout(), so the next
-- _styleGetBgWidget() call always reflects the current options.
--
-- Stretch implementation note:
-- KOReader's ImageWidget has no native "fill ignoring aspect ratio" mode —
-- scale_factor=nil and scale_factor=0 both produce a proportional fit.
-- True stretch is achieved by decoding the source image into a Blitbuffer and
-- calling bb:scale(sw, sh), which scales X and Y independently.  The scaled
-- bitmap is kept in _style_bg_cache_bb and freed together with the widget.
local _style_bg_cache_bb = nil   -- pre-scaled Blitbuffer for stretch mode (or nil)

local function _styleGetBgWidget()
    if not SUISettings:isTrue("simpleui_style_wallpaper_enabled") then return nil end
    local path = SUISettings:readSetting("simpleui_style_wallpaper")
    if not path then return nil end

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local nm     = Screen.night_mode and true or false

    if _style_bg_cache
       and _style_bg_cache_w  == sw
       and _style_bg_cache_h  == sh
       and _style_bg_cache_nm == nm
    then
        return _style_bg_cache
    end

    -- Dimensions or night-mode state changed — rebuild.
    if _style_bg_cache    then _style_bg_cache:free()    end
    if _style_bg_cache_bb then _style_bg_cache_bb:free() end
    _style_bg_cache    = nil
    _style_bg_cache_bb = nil

    -- original_in_nightmode: true  = image is never inverted by KOReader.
    --                         false = KOReader inverts the image in night mode.
    local orig_nm = not _wpInvertNight()

    -- Auto-rotate: probe image dimensions and pick a rotation_angle so the
    -- image orientation best matches the current screen orientation.
    local rotation_angle = 0
    local img_w, img_h   = nil, nil
    local pic = _getPic()
    if pic then
        local ok_d, doc = pcall(pic.openDocument, path)
        if ok_d and doc then
            img_w, img_h = doc.width, doc.height
            doc:close()
        end
    end
    if _wpAutoRotate() and img_w and img_h and img_w > 0 and img_h > 0 then
        local img_landscape    = img_w > img_h
        local screen_landscape = sw    > sh
        if img_landscape ~= screen_landscape then
            rotation_angle = G_reader_settings:isTrue("imageviewer_rotation_landscape_invert")
                and -90 or 90
        end
    end

    local widget_opts
    if _wpStretch() and img_w and img_h and img_w > 0 and img_h > 0
       and (img_w ~= sw or img_h ~= sh)
    then
        -- True stretch: decode the raw bitmap and scale it to exact screen
        -- dimensions, distorting aspect ratio when necessary.
        -- rotation_angle is applied manually so the dimension probe above
        -- already accounts for it; we bake it into the bitmap here.
        local eff_w, eff_h = sw, sh
        if rotation_angle ~= 0 then eff_w, eff_h = sh, sw end

        local ok_ri, RenderImage = pcall(require, "ui/renderimage")
        if ok_ri and RenderImage then
            -- Decode at native resolution (no max-bounds) so we get the raw
            -- pixel data, then scale to exact eff_w×eff_h in one step.
            -- Passing width/height to renderImageFile would do a proportional
            -- fit first, producing a bitmap smaller than eff_w×eff_h, and
            -- the subsequent :scale() call would then distort unevenly.
            local ok_bb, raw_bb = pcall(RenderImage.renderImageFile, RenderImage,
                path, false, nil, nil)
            if ok_bb and raw_bb then
                local ok_sc, scaled = pcall(function() return raw_bb:scale(eff_w, eff_h) end)
                raw_bb:free()
                if ok_sc and scaled then
                    _style_bg_cache_bb = scaled
                    widget_opts = {
                        image                 = scaled,
                        width                 = sw,
                        height                = sh,
                        scale_factor          = 1,  -- bitmap is already exact sw×sh
                        file_do_cache         = false,
                        alpha                 = true,
                        original_in_nightmode = orig_nm,
                        rotation_angle        = rotation_angle,
                    }
                end
            end
        end
    end

    -- Fallback (stretch decode failed, or stretch disabled, or dimensions match):
    -- proportional fit via ImageWidget's built-in scaling.
    if not widget_opts then
        widget_opts = {
            file                  = path,
            width                 = sw,
            height                = sh,
            scale_factor          = 0,    -- proportional fit (letterbox/pillarbox)
            file_do_cache         = false,
            alpha                 = true,
            original_in_nightmode = orig_nm,
            rotation_angle        = rotation_angle,
        }
    end

    local ok, w = pcall(ImageWidget.new, ImageWidget, widget_opts)
    if ok and w then
        _style_bg_cache    = w
        _style_bg_cache_w  = sw
        _style_bg_cache_h  = sh
        _style_bg_cache_nm = nm
        return w
    end
    -- Build failed — clean up any decoded bitmap.
    if _style_bg_cache_bb then _style_bg_cache_bb:free(); _style_bg_cache_bb = nil end
    _style_bg_cache_w  = 0
    _style_bg_cache_h  = 0
    _style_bg_cache_nm = nil
    logger.warn("sui_style: cannot load wallpaper: " .. tostring(path))
    return nil
end

-- Frees the cached bg widget and any associated decode buffer.
local function _styleFreeBgCache()
    if _style_bg_cache    then _style_bg_cache:free()    end
    if _style_bg_cache_bb then _style_bg_cache_bb:free() end
    _style_bg_cache    = nil
    _style_bg_cache_bb = nil
    _style_bg_cache_w  = 0
    _style_bg_cache_h  = 0
    _style_bg_cache_nm = nil
end

-- Lazy-loaded module references — loaded once on first use.
local _SH = nil
local _SP = nil
local function _getBookShared()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok then _SH = m end
    end
    return _SH
end
local function _getStatsProvider()
    if not _SP then
        local ok, m = pcall(require, "desktop_modules/module_stats_provider")
        if ok then _SP = m end
    end
    return _SP
end

-- Layout constants sourced from sui_core (single source of truth).
local PAD                = UI.PAD
local MOD_GAP            = UI.MOD_GAP
local SIDE_PAD           = UI.SIDE_PAD
local SECTION_LABEL_SIZE = 11
-- Static color defaults — overridden at render-time by theme roles when set.
local _CLR_TEXT_MID_DEFAULT      = Blitbuffer.gray(0.45)
local _DOT_COLOR_INACTIVE_DEFAULT = Blitbuffer.gray(0.55)

-- Dynamic accessors so theme changes take effect on the next repaint without
-- requiring a full rebuild.  Both fall back to the static defaults when no
-- custom "text_secondary" role is configured.
local function _getTextMid()
    local ok, SUIStyle = pcall(require, "sui_style")
    if ok and SUIStyle then
        local c = SUIStyle.getThemeColor("text_secondary")
        if c then return c end
    end
    return _CLR_TEXT_MID_DEFAULT
end

local function _getDotInactive()
    local ok, SUIStyle = pcall(require, "sui_style")
    if ok and SUIStyle then
        local c = SUIStyle.getThemeColor("text_secondary")
        if c then return c end
    end
    return _DOT_COLOR_INACTIVE_DEFAULT
end

-- Modules that render cover thumbnails — used to set the dithering hint.
-- _COVER_MOD_IDS has been replaced by the declarative M.has_covers flag on
-- each module.  Modules that carry cover bitmaps declare has_covers = true;
-- the homescreen reads that flag instead of checking this hardcoded set.
-- This comment is kept so git history remains searchable.

-- ---------------------------------------------------------------------------
-- DotWidget — defined once at file level; buildDotFooter() creates instances.
-- ---------------------------------------------------------------------------
local _BaseWidget = require("ui/widget/widget")
local DotWidget = _BaseWidget:extend{
    current_page = 1,
    total_pages  = 1,
    dot_size     = 0,
    bar_h        = 0,
    touch_w      = 0,
}

function DotWidget:getSize()
    return Geom:new{ w = self.total_pages * self.touch_w, h = self.bar_h }
end

function DotWidget:paintTo(bb, x, y)
    local dot_r = math.floor(self.dot_size / 2)
    local cy    = y + math.floor(self.bar_h / 2)
    local tw    = self.touch_w
    for i = 1, self.total_pages do
        local cx = x + (i - 1) * tw + math.floor(tw / 2)
        if i == self.current_page then
            bb:paintCircle(cx, cy, dot_r, Blitbuffer.COLOR_BLACK)
        else
            bb:paintCircle(cx, cy, dot_r, _getDotInactive())
        end
    end
end

-- Settings prefixes — homescreen is fully namespaced, independent from continue page.
local PFX    = "simpleui_hs_"
local PFX_QA = "simpleui_hs_qa_"

-- Forward declaration needed so onCloseWidget() can reference it.
local Homescreen = { _instance = nil }

-- ---------------------------------------------------------------------------
-- Pre-computed empty-state pixel constants (computed once at load time).
-- ---------------------------------------------------------------------------
local _EMPTY_H        = Screen:scaleBySize(80)
local _EMPTY_TITLE_H  = Screen:scaleBySize(30)
local _EMPTY_TITLE_FS = Screen:scaleBySize(18)
local _EMPTY_GAP      = Screen:scaleBySize(12)
local _EMPTY_SUB_H    = Screen:scaleBySize(20)
local _EMPTY_SUB_FS   = Screen:scaleBySize(13)
local _BASE_SECTION_LABEL_SIZE = Screen:scaleBySize(SECTION_LABEL_SIZE)

-- Section label widget cache — keyed by "text|inner_w|scale_pct".
-- Invalidated on screen resize/rotation via invalidateLabelCache().
local _label_cache = {}

local function invalidateLabelCache()
    _label_cache = {}
end

local function sectionLabel(text, w)
    local scale     = Config.getLabelScale()
    local fs        = math.max(8, math.floor(_BASE_SECTION_LABEL_SIZE * scale))
    local label_h   = math.max(8, math.floor(Screen:scaleBySize(16) * scale))
    local scale_pct = math.floor(scale * 100)
    -- Resolve theme fg color so labels honour the active palette.
    -- The color pointer is included in the cache key so that a theme change
    -- after the first render produces a fresh widget instead of reusing the
    -- stale one (the cache is also invalidated on rebuildLayout, but this
    -- guards against within-session theme switches without a full rebuild).
    local ok_ss, SUIStyle = pcall(require, "sui_style")
    local _label_fg = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local color_key = _label_fg and tostring(_label_fg) or "default"
    local key = text .. "|" .. w .. "|" .. scale_pct .. "|" .. color_key
    if not _label_cache[key] then
        _label_cache[key] = FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = PAD, padding_right = PAD,
            padding_bottom = UI.LABEL_PAD_BOT,
            UI.makeColoredText{
                text    = text,
                face    = Font:getFace("smallinfofont", fs),
                bold    = true,
                fgcolor = _label_fg,   -- nil → KOReader default (black)
                width   = w - PAD * 2,
                height  = label_h,
            },
        }
    end
    return _label_cache[key]
end

local function buildEmptyState(w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = _EMPTY_TITLE_H },
                TextWidget:new{
                    text = _("No books opened yet"),
                    face = Font:getFace("smallinfofont", _EMPTY_TITLE_FS),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = _EMPTY_GAP },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = _EMPTY_SUB_H },
                UI.makeColoredText{
                    text    = _("Open a book to get started"),
                    face    = Font:getFace("smallinfofont", _EMPTY_SUB_FS),
                    fgcolor = _getTextMid(),
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Pagination helpers
-- ---------------------------------------------------------------------------

local HS_PAGE_BREAK_ID = "__page_break__"

-- Splits a flat module order list (with __page_break__ sentinels) into pages.
local function splitOrderIntoPages(order)
    local pages    = {}
    local cur_page = {}
    for _, id in ipairs(order) do
        if id == HS_PAGE_BREAK_ID then
            pages[#pages + 1] = cur_page
            cur_page = {}
        else
            cur_page[#cur_page + 1] = id
        end
    end
    pages[#pages + 1] = cur_page
    if #pages == 0 then pages[1] = {} end
    return pages
end

-- Returns true when the screen is in landscape orientation.
local function _isLandscape()
    return Screen:getWidth() > Screen:getHeight()
end

-- Computes a landscape page step (2 in landscape spread mode, 1 in portrait).
local function _pageStep(total)
    return (_isLandscape() and total > 1) and 2 or 1
end

-- Clamps raw page index to valid range and ensures it lands on an odd index
-- in landscape mode (first page of a spread).
local function _clampPage(raw, total, step)
    local p = math.max(1, math.min(raw, total))
    if step == 2 and p % 2 == 0 then p = p - 1 end
    return p
end

-- Computes the last-page raw index for the given step/total combination.
local function _lastRawPage(total, step)
    if step == 2 then
        return (total % 2 == 0) and (total - 1) or total
    end
    return total
end

-- Core page-navigation logic shared by swipe, footer, chevrons, and _goto.
-- dir: "prev" | "next" | "first" | "last" | spread_number (integer).
-- Returns the new raw page index, or cur if no change.
local function _resolvePageNav(cur, total, dir)
    local step = _pageStep(total)
    local raw
    if dir == "prev" then
        raw = cur - step
        if raw < 1 then raw = 1 end
    elseif dir == "next" then
        raw = cur + step
        if raw > total then raw = total end
    elseif dir == "first" then
        raw = 1
    elseif dir == "last" then
        raw = _lastRawPage(total, step)
    else
        -- dir is a spread number; convert to raw page index.
        raw = (step == 2) and ((dir - 1) * 2 + 1) or dir
    end
    return _clampPage(raw, total, step)
end

-- Cyclic version used by swipe gestures (wraps last→first and first→last).
local function _resolveSwipeNav(cur, total, swipe_dir)
    local step = _pageStep(total)
    local raw
    if swipe_dir == "west" then
        raw = cur + step
        if raw > total then raw = 1 end
    else -- "east"
        raw = cur - step
        if raw < 1 then raw = _lastRawPage(total, step) end
    end
    return _clampPage(raw, total, step)
end

-- ---------------------------------------------------------------------------
-- Footer helpers
-- ---------------------------------------------------------------------------

local function buildChevronFooter(goto_fn)
    local icon_size  = Bottombar.getPaginationIconSize()
    local font_size  = Bottombar.getPaginationFontSize()
    local spacer     = HorizontalSpan:new{ width = Screen:scaleBySize(32) }

    local chev_left  = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
    local chev_right = BD.mirroredUILayout() and "chevron.left"  or "chevron.right"
    local chev_first = BD.mirroredUILayout() and "chevron.last"  or "chevron.first"
    local chev_last  = BD.mirroredUILayout() and "chevron.first" or "chevron.last"

    local btn_first = Button:new{
        icon = chev_first, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn(1) end, bordersize = 0,
    }
    local btn_prev = Button:new{
        icon = chev_left, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("prev") end, bordersize = 0,
    }
    local btn_next = Button:new{
        icon = chev_right, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("next") end, bordersize = 0,
    }
    local btn_last = Button:new{
        icon = chev_last, icon_width = icon_size, icon_height = icon_size,
        callback = function() goto_fn("last") end, bordersize = 0,
    }
    local btn_text = Button:new{
        text = " ", text_font_bold = false, text_font_size = font_size,
        bordersize = 0, enabled = false,
    }

    Bottombar.patchDimmedIcon(btn_first)
    Bottombar.patchDimmedIcon(btn_prev)
    Bottombar.patchDimmedIcon(btn_next)
    Bottombar.patchDimmedIcon(btn_last)

    local page_info = HorizontalGroup:new{
        align = "center",
        btn_first, spacer, btn_prev, spacer,
        btn_text, spacer, btn_next, spacer, btn_last,
    }
    local chev_w    = Screen:getWidth()
    local chev_h    = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local chev_input = InputContainer:new{
        dimen = Geom:new{ w = chev_w, h = chev_h },
        CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = chev_h },
            page_info,
        },
    }
    -- Apply user-defined icon overrides for pagination chevrons.
    -- Since these are SimpleUI-created Buttons (not IconButtons), we use
    -- applyPaginationIcons which calls _applyNativeBtn (btn.icon + :init() path).
    pcall(function()
        local ok_ss, SS = pcall(require, "sui_style")
        if not (ok_ss and SS and SS.applyPaginationIcons) then return end
        -- Build a pseudo-widget with the four named fields that applyPaginationIcons expects.
        local pseudo = {
            page_info_first_chev = btn_first,
            page_info_left_chev  = btn_prev,
            page_info_right_chev = btn_next,
            page_info_last_chev  = btn_last,
        }
        SS.applyPaginationIcons(pseudo)
    end)
    return {
        widget    = chev_input,
        btn_first = btn_first,
        btn_prev  = btn_prev,
        btn_text  = btn_text,
        btn_next  = btn_next,
        btn_last  = btn_last,
    }
end

local function buildDotFooter(goto_fn)
    local DOT_SIZE = Screen:scaleBySize(7)
    local BAR_H    = Screen:scaleBySize(28)
    local TOUCH_W  = Screen:scaleBySize(32)

    local dot_widget = DotWidget:new{
        current_page = 1, total_pages = 1,
        dot_size = DOT_SIZE, bar_h = BAR_H, touch_w = TOUCH_W,
    }
    local dot_sz    = dot_widget:getSize()
    local bar_input = InputContainer:new{
        dimen = Geom:new{ w = dot_sz.w, h = dot_sz.h },
        dot_widget,
    }
    bar_input.ges_events = {
        TapDot = {
            GestureRange:new{
                ges   = "tap",
                range = function() return bar_input.dimen end,
            },
        },
        -- Swipe on the dot bar propagates page-turns identically to body swipes.
        SwipeDot = {
            GestureRange:new{
                ges   = "swipe",
                range = function() return bar_input.dimen end,
            },
        },
    }
    function bar_input:onTapDot(_args, ges)
        if not (ges and ges.pos) then return true end
        local total_w  = dot_widget.total_pages * TOUCH_W
        local bar_left = math.floor((Screen:getWidth() - total_w) / 2)
        local tapped   = math.floor((ges.pos.x - bar_left) / TOUCH_W) + 1
        tapped = math.max(1, math.min(tapped, dot_widget.total_pages))
        goto_fn(tapped)
        return true
    end
    function bar_input:onSwipeDot(_args, ges)
        if not ges then return true end
        local dir = ges.direction
        local cur = dot_widget.current_page
        local tot = dot_widget.total_pages
        if dir == "west" then
            goto_fn(cur < tot and cur + 1 or 1)
        elseif dir == "east" then
            goto_fn(cur > 1 and cur - 1 or tot)
        end
        return true
    end
    local centred = CenterContainer:new{
        dimen = Geom:new{ w = 0, h = BAR_H },  -- w patched in _updateFooter
        bar_input,
    }
    return {
        widget     = centred,
        dot_widget = dot_widget,
        bar_input  = bar_input,
        touch_w    = TOUCH_W,
    }
end

-- Updates the navpager bottom-bar arrows to reflect the current spread position.
local function _updateNavpagerForHS(current_page, total_pages)
    if not Config.isNavpagerEnabled() then return end
    local tgt = Homescreen._instance
    if not tgt then return end
    local has_prev = current_page > 1
    local has_next = current_page < total_pages
    if not Bottombar.updateNavpagerArrows(tgt, has_prev, has_next) then
        local tabs    = Config.loadTabConfig()
        local mode    = Config.getNavbarMode()
        local new_bar = Bottombar.buildBarWidgetWithArrows(
            "homescreen", tabs, mode, has_prev, has_next)
        Bottombar.replaceBar(tgt, new_bar, tabs)
    end
    UIManager:setDirty(tgt, "ui")
end

local function openBook(filepath, pos0, page)
    -- ReaderUI:showReader() broadcasts ShowingReader before its first paint,
    -- closing FM/Homescreen atomically — no need to close HS first.
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(filepath)
        if pos0 or page then
            UIManager:scheduleIn(0.5, function()
                local rui = package.loaded["apps/reader/readerui"]
                if not (rui and rui.instance) then return end
                if pos0 then
                    rui.instance:handleEvent(
                        require("ui/event"):new("GotoXPointer", pos0, pos0))
                elseif page then
                    rui.instance:handleEvent(
                        require("ui/event"):new("GotoPage", page))
                end
            end)
        end
    end
    if G_reader_settings:isTrue("file_ask_to_open") then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Open this file?") .. "\n\n" .. BD.filename(filepath:match("([^/]+)$")),
            ok_text = _("Open"),
            ok_callback = doOpen,
        })
    else
        doOpen()
    end
end

-- ---------------------------------------------------------------------------
-- HomescreenWidget
-- ---------------------------------------------------------------------------

local HomescreenWidget = InputContainer:extend{
    name                = "homescreen",
    covers_fullscreen   = true,
    disable_double_tap  = true,
    _on_qa_tap          = nil,
    _on_goal_tap        = nil,
}

-- Returns true when another widget (e.g. a modal dialog) sits on top of the
-- UIManager stack, so gesture handlers can fall through correctly.
local function _hasModalOnTop(hs_widget)
    local stack = UIManager._window_stack
    if not stack or #stack == 0 then return false end
    local top = stack[#stack]
    return top and top.widget ~= hs_widget
end

function HomescreenWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    local _bar_y = sh - Bottombar.TOTAL_H()
    local function _in_bar(ges)
        return ges and ges.pos and ges.pos.y >= _bar_y
    end

    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{ ges = "tap",            range = function() return self.dimen end },
        },
        BlockNavbarHold = {
            GestureRange:new{ ges = "hold",           range = function() return self.dimen end },
        },
        HSSwipe = {
            GestureRange:new{ ges = "swipe",          range = function() return self.dimen end },
        },
        HSDoubleTap = {
            GestureRange:new{ ges = "double_tap",     range = function() return self.dimen end },
        },
        HSTwoFingerTap = {
            GestureRange:new{ ges = "two_finger_tap", range = function() return self.dimen end },
        },
        HSTwoFingerSwipe = {
            GestureRange:new{ ges = "two_finger_swipe", range = function() return self.dimen end },
        },
        HSMultiswipe = {
            GestureRange:new{ ges = "multiswipe",     range = function() return self.dimen end },
        },
        HSHold = {
            GestureRange:new{ ges = "hold",           range = function() return self.dimen end },
        },
        HSSpread = {
            GestureRange:new{ ges = "spread",         range = function() return self.dimen end },
        },
        HSPinch = {
            GestureRange:new{ ges = "pinch",          range = function() return self.dimen end },
        },
        HSRotate = {
            GestureRange:new{ ges = "rotate",         range = function() return self.dimen end },
        },
    }

    -- Zone data from G_defaults is immutable during a session — read once here
    -- and reused on every gesture event to avoid per-call table allocations.
    local function _readZone(key)
        local d = G_defaults:readSetting(key)
        if not d then return nil end
        return { ratio_x = d.x, ratio_y = d.y, ratio_w = d.w, ratio_h = d.h }
    end
    local _gz_top_left   = _readZone("DTAP_ZONE_TOP_LEFT")
    local _gz_top_right  = _readZone("DTAP_ZONE_TOP_RIGHT")
    local _gz_bot_left   = _readZone("DTAP_ZONE_BOTTOM_LEFT")
    local _gz_bot_right  = _readZone("DTAP_ZONE_BOTTOM_RIGHT")
    local _gz_left_edge  = _readZone("DSWIPE_ZONE_LEFT_EDGE")
    local _gz_right_edge = _readZone("DSWIPE_ZONE_RIGHT_EDGE")
    local _gz_top_edge   = _readZone("DSWIPE_ZONE_TOP_EDGE")
    local _gz_bot_edge   = _readZone("DSWIPE_ZONE_BOTTOM_EDGE")
    local _gz_left_side  = _readZone("DDOUBLE_TAP_ZONE_PREV_CHAPTER")
    local _gz_right_side = _readZone("DDOUBLE_TAP_ZONE_NEXT_CHAPTER")

    -- Dispatches a gesture event to the FM gestures plugin (same gesture set
    -- as docless file-manager mode). sendEvent is temporarily redirected to
    -- broadcastEvent so UIManager events reach all listeners.
    local function _fmGestureAction(ges_event)
        local FileManager = require("apps/filemanager/filemanager")
        local g = FileManager.instance and FileManager.instance.gestures
        if not g then return end

        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local pos = ges_event.pos
        if not pos then return end
        local x, y = pos.x, pos.y
        local gt  = ges_event.ges
        local dir = ges_event.direction

        -- Use the module-level reusable buffer; reset it for this call.
        local n = 0

        if gt == "swipe" then
            local is_diag = dir == "northeast" or dir == "northwest"
                         or dir == "southeast" or dir == "southwest"
            if is_diag then
                local short_thresh = Screen:scaleBySize(300)
                if ges_event.distance and ges_event.distance <= short_thresh then
                    n = n + 1; _candidates[n] = "short_diagonal_swipe"
                end
            elseif _inZone(_gz_left_edge, x, y, sw, sh) then
                if     dir == "south" then n = n + 1; _candidates[n] = "one_finger_swipe_left_edge_down"
                elseif dir == "north" then n = n + 1; _candidates[n] = "one_finger_swipe_left_edge_up"
                end
            elseif _inZone(_gz_right_edge, x, y, sw, sh) then
                if     dir == "south" then n = n + 1; _candidates[n] = "one_finger_swipe_right_edge_down"
                elseif dir == "north" then n = n + 1; _candidates[n] = "one_finger_swipe_right_edge_up"
                end
            elseif _inZone(_gz_top_edge, x, y, sw, sh) then
                if     dir == "east" then n = n + 1; _candidates[n] = "one_finger_swipe_top_edge_right"
                elseif dir == "west" then n = n + 1; _candidates[n] = "one_finger_swipe_top_edge_left"
                end
            elseif _inZone(_gz_bot_edge, x, y, sw, sh) then
                if     dir == "east" then n = n + 1; _candidates[n] = "one_finger_swipe_bottom_edge_right"
                elseif dir == "west" then n = n + 1; _candidates[n] = "one_finger_swipe_bottom_edge_left"
                end
            end

        elseif gt == "tap" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_left_bottom_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "tap_right_bottom_corner"
            end

        elseif gt == "hold" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_bottom_left_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "hold_bottom_right_corner"
            end

        elseif gt == "double_tap" then
            if     _inZone(_gz_left_side,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_left_side"
            elseif _inZone(_gz_right_side, x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_right_side"
            elseif _inZone(_gz_top_left,   x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_top_left_corner"
            elseif _inZone(_gz_top_right,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_top_right_corner"
            elseif _inZone(_gz_bot_left,   x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_bottom_left_corner"
            elseif _inZone(_gz_bot_right,  x, y, sw, sh) then n = n + 1; _candidates[n] = "double_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_tap" then
            if     _inZone(_gz_top_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_top_left_corner"
            elseif _inZone(_gz_top_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_top_right_corner"
            elseif _inZone(_gz_bot_left,  x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_bottom_left_corner"
            elseif _inZone(_gz_bot_right, x, y, sw, sh) then n = n + 1; _candidates[n] = "two_finger_tap_bottom_right_corner"
            end

        elseif gt == "two_finger_swipe" then
            local map = {
                east = "two_finger_swipe_east",   west  = "two_finger_swipe_west",
                north = "two_finger_swipe_north",  south = "two_finger_swipe_south",
                northeast = "two_finger_swipe_northeast", northwest = "two_finger_swipe_northwest",
                southeast = "two_finger_swipe_southeast", southwest = "two_finger_swipe_southwest",
            }
            if map[dir] then n = n + 1; _candidates[n] = map[dir] end

        elseif gt == "multiswipe" then
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.multiswipeAction, g, ges_event.multiswipe_directions, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then logger.warn("simpleui hs gesture multiswipe:", err) end
            return true

        elseif gt == "spread" then
            n = n + 1; _candidates[n] = "spread_gesture"
        elseif gt == "pinch" then
            n = n + 1; _candidates[n] = "pinch_gesture"
        elseif gt == "rotate" then
            if     dir == "cw"  then n = n + 1; _candidates[n] = "rotate_cw"
            elseif dir == "ccw" then n = n + 1; _candidates[n] = "rotate_ccw"
            end
        end

        if n == 0 then return end

        local gestures_fm = g.gestures
        local ges_name
        for i = 1, n do
            local name = _candidates[i]
            if gestures_fm and gestures_fm[name] ~= nil then
                ges_name = name
                break
            end
        end
        -- Fall back to the first candidate; gestureAction() is a no-op when
        -- no action is configured, preserving future default-action support.
        if not ges_name then
            ges_name = _candidates[1]
        end

        -- Clear the reusable buffer so stale entries never leak into the next call.
        for i = 1, n do _candidates[i] = nil end

        if ges_name then
            local orig_sendEvent = UIManager.sendEvent
            UIManager.sendEvent = function(um, ev) return UIManager:broadcastEvent(ev) end
            local ok, err = pcall(g.gestureAction, g, ges_name, ges_event)
            UIManager.sendEvent = orig_sendEvent
            if not ok then
                logger.warn("simpleui hs gesture:", ges_name, err)
            end
            if gestures_fm and gestures_fm[ges_name] ~= nil then
                return true
            end
        end
    end

    -- Returns true when the gesture originates from a side-edge zone.
    local function _isSideEdge(ges)
        if not ges or not ges.pos then return false end
        local x  = ges.pos.x
        local sw = Screen:getWidth()
        local function _in(z)
            if not z then return false end
            return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
        end
        return _in(_gz_left_edge) or _in(_gz_right_edge)
    end

    function self:onHSSwipe(_args, ges)
        if ges then
            local dir = ges.direction
            if (dir == "west" or dir == "east") and not _isSideEdge(ges) then
                -- Delegate horizontal swipes inside the coverdeck area to the
                -- carousel widget so it can paginate without triggering an HS page turn.
                if ges.pos then
                    local cd_on_current_page = false
                    do
                        local pom = self._enabled_mods_cache and self._enabled_mods_cache.pages_of_mods
                        local cur = self._current_page or 1
                        local is_ls = _isLandscape()
                        local pages_to_check = { pom and pom[cur] }
                        if is_ls and pom and pom[cur + 1] then
                            pages_to_check[2] = pom[cur + 1]
                        end
                        for _, cur_mods in ipairs(pages_to_check) do
                            if cur_mods then
                                for _, m in ipairs(cur_mods) do
                                    if m.id == "coverdeck" then cd_on_current_page = true; break end
                                end
                            end
                            if cd_on_current_page then break end
                        end
                    end
                    local cd_wrapper = cd_on_current_page and self._wrapper_pool and self._wrapper_pool["coverdeck"]
                    if cd_wrapper and cd_wrapper.dimen
                            and ges.pos:intersectWith(cd_wrapper.dimen) then
                        local frame    = cd_wrapper[1]
                        local vg       = frame and frame[1]
                        local tappable = nil
                        if vg then
                            for _, child in ipairs(vg) do
                                if type(child.onSwipe) == "function" then
                                    tappable = child
                                    break
                                end
                            end
                        end
                        if tappable then
                            return tappable:onSwipe(nil, ges)
                        end
                    end
                end

                local cur   = self._current_page or 1
                local total = self._total_pages  or 1
                local new_page = _resolveSwipeNav(cur, total, dir)
                if new_page ~= cur or total == 1 then
                    self._current_page = new_page
                    self.page          = new_page
                    self:_refresh(true)
                end
                return true
            end
        end
        return _fmGestureAction(ges)
    end
    function self:onHSTwoFingerSwipe(_args, ges) return _fmGestureAction(ges) end
    function self:onHSDoubleTap(_args, ges)    return _fmGestureAction(ges) end
    function self:onHSTwoFingerTap(_args, ges) return _fmGestureAction(ges) end
    function self:onHSMultiswipe(_args, ges)   return _fmGestureAction(ges) end
    function self:onHSSpread(_args, ges)       return _fmGestureAction(ges) end
    function self:onHSPinch(_args, ges)        return _fmGestureAction(ges) end
    function self:onHSRotate(_args, ges)       return _fmGestureAction(ges) end

    -- Physical D-pad navigation (Kindle and similar devices).
    self.key_events = {}
    if Device:hasDPad() then
        self.key_events.HSFocusUp    = { { "Up"    } }
        self.key_events.HSFocusDown  = { { "Down"  } }
        self.key_events.HSFocusLeft  = { { "Left"  } }
        self.key_events.HSFocusRight = { { "Right" } }
        self.key_events.HSKbPress    = { { "Press" } }
    end
    if Device:hasKeys() then
        self.key_events.HSOpenMenu = { { "Menu"  } }
        self.key_events.PrevPage   = { { Device.input.group.PgBack } }
        self.key_events.NextPage   = { { Device.input.group.PgFwd } }
    end

    function self:onHSOpenMenu()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and fm.menu then fm.menu:onTapShowMenu() end
        return true
    end

    local self_ref = self

    function self:onHSFocusUp()
        local books = self._kb_book_items_fp
        if not books or #books == 0 then return end
        local frec = self._kb_first_rec_idx
        if self._kb_focus_idx == nil then
            self._kb_focus_idx = frec or 1
        elseif frec and self._kb_focus_idx >= frec then
            self._kb_focus_idx = 1
        else
            self._kb_focus_idx = frec or 1
        end
        self:_refresh(true)
        return true
    end

    function self:onHSFocusDown()
        local books = self._kb_book_items_fp
        local frec  = self._kb_first_rec_idx
        local on_recent = frec and self._kb_focus_idx and self._kb_focus_idx >= frec
        if on_recent then
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("sui_patches")
            Patches.enterNavbarKbFocus(function()
                self_ref._kb_focus_idx = frec
                self_ref:_refresh(true)
            end)
            return true
        end
        if self._kb_focus_idx == nil then
            self._kb_focus_idx = 1
        elseif frec then
            self._kb_focus_idx = frec
        else
            self._kb_focus_idx = nil
            self:_refresh(true)
            local Patches = require("sui_patches")
            Patches.enterNavbarKbFocus(function()
                self_ref._kb_focus_idx = 1
                self_ref:_refresh(true)
            end)
            return true
        end
        self:_refresh(true)
        return true
    end

    function self:onHSFocusLeft()
        local frec = self._kb_first_rec_idx
        if not frec or not self._kb_focus_idx then return end
        if self._kb_focus_idx < frec then return end
        if self._kb_focus_idx > frec then
            self._kb_focus_idx = self._kb_focus_idx - 1
            self:_refresh(true)
        end
        return true
    end

    function self:onHSFocusRight()
        local frec  = self._kb_first_rec_idx
        local books = self._kb_book_items_fp
        if not frec or not self._kb_focus_idx or not books then return end
        if self._kb_focus_idx < frec then return end
        if self._kb_focus_idx < #books then
            self._kb_focus_idx = self._kb_focus_idx + 1
            self:_refresh(true)
        end
        return true
    end

    function self:onHSKbPress()
        if self._kb_focus_idx == nil then return end
        local books = self._kb_book_items_fp
        if not books then return end
        local fp = books[self._kb_focus_idx]
        if fp then
            self._kb_focus_idx = nil
            local open_fn = self._ctx_cache and self._ctx_cache.open_fn
            if open_fn then open_fn(fp) end
        end
        return true
    end

    -- Navpager compatibility — sui_bottombar looks for these methods and the
    -- page/page_num fields on the topmost pageable widget.
    function self:onPrevPage()
        local cur   = self._current_page or 1
        local total = self._total_pages  or 1
        local new_page = _resolvePageNav(cur, total, "prev")
        if new_page ~= cur then
            self._current_page = new_page
            self.page          = new_page
            self:_refresh(true)
        end
        return true
    end

    function self:onNextPage()
        local cur   = self._current_page or 1
        local total = self._total_pages  or 1
        local new_page = _resolvePageNav(cur, total, "next")
        if new_page ~= cur then
            self._current_page = new_page
            self.page          = new_page
            self:_refresh(true)
        end
        return true
    end

    function self:onGotoPage(page)
        local total = self._total_pages or 1
        local new_page = _resolvePageNav(1, total, page)  -- page is a spread index
        self._current_page = new_page
        self.page          = new_page
        self:_refresh(true)
        return true
    end

    -- Tap forwarding: FM corner gestures have priority over the navbar guard.
    function self:onBlockNavbarTap(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _fmGestureAction(ges) then return true end
        if ges and ges.pos then
            local x, y = ges.pos.x, ges.pos.y
            local sw = Screen:getWidth()
            local sh = Screen:getHeight()
            local function _inRaw(z)
                if not z then return false end
                return x >= z.ratio_x * sw and x < (z.ratio_x + z.ratio_w) * sw
                   and y >= z.ratio_y * sh and y < (z.ratio_y + z.ratio_h) * sh
            end
            if _inRaw(_gz_bot_left) or _inRaw(_gz_bot_right) then
                return  -- let it through
            end
        end
        if _in_bar(ges) then return true end
    end
    function self:onHSHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _in_bar(ges) then return true end
        return _fmGestureAction(ges)
    end
    function self:onBlockNavbarHold(_args, ges)
        if _hasModalOnTop(self) then return false end
        if _in_bar(ges) then return true end
    end

    self.title_bar = TitleBar:new{
        show_parent             = self,
        fullscreen              = true,
        title                   = _("Homescreen"),
        left_icon               = "home",
        left_icon_tap_callback  = function() self:onClose() end,
        left_icon_hold_callback = false,
    }

    -- Per-instance state — freed in onCloseWidget.
    self._vspan_pool         = {}
    self._wrapper_pool       = {}
    self._kb_focus_idx       = nil
    self._kb_first_rec_idx   = nil
    self._kb_book_items_fp   = nil
    self._db_conn            = nil
    self._cover_poll_timer   = nil
    self._cover_mod_slots    = nil
    self._enabled_mods_cache = nil
    self._ctx_cache          = nil
    self._current_page       = self._current_page or 1
    self.page                = self._current_page
    self.page_num            = 1
    self._clock_body_ref     = nil
    self._clock_body_idx     = nil
    self._clock_is_wrapped   = nil
    self._clock_pfx          = nil
    self._clock_inner_w      = nil
    self._overflow_warn_key  = nil

    -- Minimal placeholder so patches.lua can call wrapWithNavbar safely.
    -- Real content is built in onShow() once _navbar_content_h is set.
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }

    -- Register top-of-screen tap/swipe zones to open the KOReader main menu,
    -- mirroring what FileManagerMenu:initGesListener does for the library.
    local DTAP_ZONE_MENU     = G_defaults:readSetting("DTAP_ZONE_MENU")
    local DTAP_ZONE_MENU_EXT = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    if DTAP_ZONE_MENU and DTAP_ZONE_MENU_EXT then
        local function _hsMenu()
            local FM = package.loaded["apps/filemanager/filemanager"]
            local inst = FM and FM.instance
            if inst and inst.menu then return inst.menu end
            return nil
        end

        local topbar_on  = SUISettings:nilOrTrue("simpleui_topbar_enabled")
        local zone_ratio_h
        if topbar_on then
            local ok_tb, Topbar   = pcall(require, "sui_topbar")
            local ok_ui, UI_core  = pcall(require, "sui_core")
            if ok_tb and ok_ui then
                zone_ratio_h = (Topbar.TOTAL_TOP_H() + UI_core.MOD_GAP) / sh
            else
                zone_ratio_h = DTAP_ZONE_MENU.h
            end
        else
            zone_ratio_h = DTAP_ZONE_MENU.h
        end

        self:registerTouchZones({
            {
                id          = "simpleui_hs_menu_tap",
                ges         = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _hsMenu()
                    if m then return m:onTapShowMenu(ges) end
                end,
            },
            {
                id          = "simpleui_hs_menu_swipe",
                ges         = "swipe",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = zone_ratio_h },
                handler = function(ges)
                    if _hasModalOnTop(self) then return false end
                    local m = _hsMenu()
                    if m and m:onSwipeShowMenu(ges) then return true end
                    return _fmGestureAction(ges)
                end,
            },
        })
    end

    -- Footer touch zones override BlockNavbarTap/HSSwipe for gestures landing
    -- in the combined navbar + pagination footer strip.
    local pag_footer_h   = Bottombar.getPaginationIconSize() + Screen:scaleBySize(8)
    local combined_h     = Bottombar.TOTAL_H() + pag_footer_h
    local footer_ratio_y = (sh - combined_h) / sh
    local footer_ratio_h = combined_h / sh
    local self_ref_fc    = self

    self:registerTouchZones({
        {
            id          = "simpleui_hs_footer_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { "BlockNavbarTap" },
            handler = function(ges)
                if _hasModalOnTop(self_ref_fc) then return false end
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref_fc._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                local navpager_on  = Config.isNavpagerEnabled()
                local dot_pager_on = Config.isDotPagerEnabled()
                if navpager_on or dot_pager_on then
                    local fd = self_ref_fc._footer_dot
                    if fd and fd.bar_input then
                        return fd.bar_input:handleEvent(Event:new("Gesture", ges))
                    end
                    return false
                end

                local fc = self_ref_fc._footer_chevron
                if fc then
                    local buttons = { fc.btn_first, fc.btn_prev, fc.btn_next, fc.btn_last }
                    for _, btn in ipairs(buttons) do
                        local d = btn.dimen
                        if d and ges.pos and ges.pos:intersectWith(d) then
                            if btn.enabled ~= false then btn.callback() end
                            return true
                        end
                    end
                end
                return false
            end,
        },
        {
            id          = "simpleui_hs_footer_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { "HSSwipe" },
            handler = function(ges)
                if _hasModalOnTop(self_ref_fc) then return false end
                if _fmGestureAction(ges) then return true end

                local footer_bc = self_ref_fc._footer_bc
                if not footer_bc or footer_bc.dimen.h == 0 then return false end

                local dir   = ges and ges.direction
                local cur   = self_ref_fc._current_page or 1
                local total = self_ref_fc._total_pages  or 1
                if total <= 1 then return false end
                if dir ~= "west" and dir ~= "east" then return false end

                local new_page = _resolveSwipeNav(cur, total, dir)
                if new_page ~= cur then
                    self_ref_fc._current_page = new_page
                    self_ref_fc.page          = new_page
                    self_ref_fc:_refresh(true)
                end
                return true
            end,
        },
    })

    -- Priority gesture zones for top and bottom strips — these fire before
    -- the fullscreen ges_events handlers for double-tap, two-finger, etc.
    local top_ratio_h    = (DTAP_ZONE_MENU and DTAP_ZONE_MENU.h) or 0.1
    local _gesture_types = {
        { ges = "double_tap",       id_suffix = "double_tap",        override = "HSDoubleTap"      },
        { ges = "two_finger_tap",   id_suffix = "two_finger_tap",    override = "HSTwoFingerTap"   },
        { ges = "two_finger_swipe", id_suffix = "two_finger_swipe",  override = "HSTwoFingerSwipe" },
        { ges = "multiswipe",       id_suffix = "multiswipe",        override = "HSMultiswipe"     },
        { ges = "spread",           id_suffix = "spread",            override = "HSSpread"         },
        { ges = "pinch",            id_suffix = "pinch",             override = "HSPinch"          },
        { ges = "rotate",           id_suffix = "rotate",            override = "HSRotate"         },
        { ges = "hold",             id_suffix = "hold",              override = "HSHold"           },
    }

    local priority_zones = {}
    for _, gt in ipairs(_gesture_types) do
        priority_zones[#priority_zones + 1] = {
            id          = "simpleui_hs_top_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = top_ratio_h },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
        priority_zones[#priority_zones + 1] = {
            id          = "simpleui_hs_bottom_" .. gt.id_suffix,
            ges         = gt.ges,
            screen_zone = { ratio_x = 0, ratio_y = footer_ratio_y, ratio_w = 1, ratio_h = footer_ratio_h },
            overrides = { gt.override },
            handler   = function(ges) return _hasModalOnTop(self) and false or _fmGestureAction(ges) end,
        }
    end
    self:registerTouchZones(priority_zones)
end

-- ---------------------------------------------------------------------------
-- _vspan — per-instance VerticalSpan pool; freed on close.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_vspan(px)
    local pool = self._vspan_pool
    if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
    return pool[px]
end

-- ---------------------------------------------------------------------------
-- _initLayout — builds the persistent widget tree (called once per show).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_initLayout()
    local sw        = Screen:getWidth()
    local sh        = Screen:getHeight()
    local content_h = self._navbar_content_h or sh
    local side_off  = SIDE_PAD
    local inner_w   = sw - side_off * 2

    self._layout_sw        = sw
    self._layout_content_h = content_h
    self._layout_inner_w   = inner_w

    local body = VerticalGroup:new{ align = "left" }
    self._body = body

    -- Module widgets are transparent by default (no background field set), so
    -- the device/screen background colour shows through when no wallpaper is
    -- active.  When a wallpaper is set we simply paint it behind the widget
    -- tree via a paintTo override — no conditional background juggling needed.
    local _lf_bg = _styleGetBgWidget()

    local content_widget = FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_left = side_off, padding_right = side_off,
        dimen        = Geom:new{ w = sw, h = content_h },
        body,
    }
    local outer = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = sw, h = content_h },
        content_widget,
    }

    -- _styleGetBgWidget() already creates the ImageWidget with height=sh
    -- (full screen), so when bars_transparent is active the wallpaper
    -- automatically bleeds behind the topbar and bottombar with no extra
    -- work needed here.  We just paint it at (x, y) as usual.
    if _lf_bg then
        local _orig_paintTo = content_widget.paintTo
        local _bg           = _lf_bg
        function content_widget:paintTo(bb, x, y)
            -- Always paint from y=0 so the wallpaper is anchored at the top
            -- and covers the full screen area.
            _bg:paintTo(bb, x, 0)
            -- Opacity: 0 = fully opaque (no lighten), 1-99 = fade toward white.
            -- lightenRect is a cheap in-place blitbuffer op — safe on e-ink.
            local opacity = _wpOpacity()
            if opacity and opacity > 0 then
                bb:lightenRect(x, 0, Screen:getWidth(), Screen:getHeight(), opacity / 100)
            end
            _orig_paintTo(self, bb, x, y)
        end
    end

    -- Navigation callback shared by both footer types.
    local self_ref = self
    local function _goto(page)
        local total     = self_ref._total_pages or 1
        local cur_raw   = self_ref._current_page or 1
        local target_raw = _resolvePageNav(cur_raw, total, page)
        target_raw = math.max(1, math.min(target_raw, total))
        if target_raw ~= cur_raw then
            self_ref._current_page = target_raw
            self_ref:_refresh(true)
        end
    end

    self._footer_chevron     = buildChevronFooter(_goto)
    self._footer_dot         = buildDotFooter(_goto)
    self._footer_hidden_span = VerticalSpan:new{ width = 0 }

    local footer_bc = BottomContainer:new{
        dimen = Geom:new{ w = sw, h = content_h },
        self._footer_chevron.widget,
    }
    self._footer_bc = footer_bc

    local overlap = OverlapGroup:new{
        allow_mirroring = false,
        dimen           = Geom:new{ w = sw, h = content_h },
        outer,
        footer_bc,
    }
    self._overlap = overlap
    return overlap
end

-- ---------------------------------------------------------------------------
-- _buildCtx — constructs the module build context for the current render.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_buildCtx()
    local inner_w = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)

    -- Pre-read all per-module settings once so module build() functions never
    -- call Config.get* or G_reader_settings during widget construction.
    -- The bundle is cached cross-instance and only cleared on settings change.
    local cfg = self._cfg_cache
    if not cfg then
        cfg = {
            currently = {
                scale       = Config.getModuleScale("currently", PFX),
                thumb_scale = Config.getThumbScale("currently", PFX),
                lbl_scale   = Config.getItemLabelScale("currently", PFX),
                bar_style   = SUISettings:readSetting(PFX .. "currently_bar_style") or "with_pct",
                stats_style = SUISettings:readSetting(PFX .. "currently_stats_style") or "default",
                elem_order  = SUISettings:readSetting(PFX .. "currently_elem_order"),
                show = {
                    title    = SUISettings:nilOrTrue(PFX .. "currently_show_title"),
                    author   = SUISettings:nilOrTrue(PFX .. "currently_show_author"),
                    progress = SUISettings:nilOrTrue(PFX .. "currently_show_progress"),
                    percent  = SUISettings:nilOrTrue(PFX .. "currently_show_percent"),
                    days     = SUISettings:nilOrTrue(PFX .. "currently_show_book_days"),
                    time     = SUISettings:nilOrTrue(PFX .. "currently_show_book_time"),
                    remain   = SUISettings:nilOrTrue(PFX .. "currently_show_book_remaining"),
                },
            },
            coverdeck = {
                scale         = Config.getModuleScale("coverdeck", PFX),
                thumb_scale   = Config.getThumbScale("coverdeck", PFX),
                lbl_scale     = Config.getItemLabelScale("coverdeck", PFX),
                source        = SUISettings:readSetting(PFX .. "flow_recent_source") or "recent",
                title_pos     = SUISettings:readSetting(PFX .. "coverdeck_title_pos") or "below",
                show_finished = SUISettings:readSetting(PFX .. "coverdeck_show_finished") == true,
                show = {
                    title    = SUISettings:nilOrTrue(PFX .. "flow_show_title"),
                    author   = SUISettings:nilOrTrue(PFX .. "flow_show_author"),
                    progress = SUISettings:nilOrTrue(PFX .. "flow_show_progress"),
                    percent  = SUISettings:nilOrTrue(PFX .. "flow_show_percent"),
                    days     = SUISettings:nilOrTrue(PFX .. "flow_show_book_days"),
                    time     = SUISettings:nilOrTrue(PFX .. "flow_show_book_time"),
                    remain   = SUISettings:nilOrTrue(PFX .. "flow_show_book_remaining"),
                },
                elem_order    = SUISettings:readSetting(PFX .. "coverdeck_elem_order"),
            },
        }
        self._cfg_cache = cfg
    end

    local mod_c  = Registry.get("currently")
    local mod_r  = Registry.get("recent")
    local mod_cd = Registry.get("coverdeck")
    local show_c = mod_c and Registry.isEnabled(mod_c, PFX)
    local show_r = (mod_r and Registry.isEnabled(mod_r, PFX))
                or (mod_cd and Registry.isEnabled(mod_cd, PFX))

    if not self._cached_books_state then
        local SH = _getBookShared()
        if SH then
            if show_c or show_r then
                local max_recent = 5
                local show_finished =
                    (mod_r  and Registry.isEnabled(mod_r,  PFX) and
                        SUISettings:readSetting(PFX .. "recent_show_finished") == true)
                    or
                    (mod_cd and Registry.isEnabled(mod_cd, PFX) and
                        SUISettings:readSetting(PFX .. "coverdeck_show_finished") == true)
                self._cached_books_state = SH.prefetchBooks(show_c, show_r, max_recent, show_finished)
                if Config.cover_extraction_pending then
                    self:_scheduleCoverPoll()
                end
            else
                self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
            end
        else
            logger.warn("simpleui: homescreen: cannot load module_books_shared")
            self._cached_books_state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
        end
    end

    local bs          = self._cached_books_state
    local mod_rg      = Registry.get("reading_goals")
    local mod_rs      = Registry.get("reading_stats")
    local wants_stats = (mod_rg and Registry.isEnabled(mod_rg, PFX))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))

    -- Scan external modules that declare M.needs = { db=true, stats=true, books=true }.
    -- Built-ins have their requirements encoded in the explicit checks below; this
    -- loop only fires for modules not in the MODULES list (zero cost when no
    -- external modules are registered).
    local ext_needs_db    = false
    local ext_needs_stats = false
    local ext_needs_books = false
    for _, mod in ipairs(Registry.list()) do
        if mod.needs and Registry.isEnabled(mod, PFX) then
            if mod.needs.db    then ext_needs_db    = true end
            if mod.needs.stats then ext_needs_stats = true end
            if mod.needs.books then ext_needs_books = true end
        end
    end
    if ext_needs_stats then wants_stats = true end

    -- Determine whether the coverdeck needs DB access (i.e. at least one stat
    -- beyond "percent" is visible).  "percent" comes from prefetched metadata
    -- and never requires a DB query.
    local cd_cfg = cfg and cfg.coverdeck
    local coverdeck_needs_db = mod_cd and Registry.isEnabled(mod_cd, PFX) and (
        (cd_cfg and cd_cfg.show and
            (cd_cfg.show.book_days or cd_cfg.show.book_time or cd_cfg.show.book_remaining))
        or (not (cd_cfg and cd_cfg.show) and (
            SUISettings:nilOrTrue(PFX .. "flow_show_book_days") or
            SUISettings:nilOrTrue(PFX .. "flow_show_book_time") or
            SUISettings:nilOrTrue(PFX .. "flow_show_book_remaining"))))

    -- "currently" always needs the DB when active (all its stats are DB-backed).
    -- The "recent" module (mod_r) shows no DB-backed stats, so it is excluded.
    local wants_db = show_c or coverdeck_needs_db or wants_stats or ext_needs_db

    if wants_db and not self._db_conn and not self._db_sync_guard then
        self._db_conn = Config.openStatsDB()
    end

    -- Pre-fetch numeric stats via the shared provider (at most 2 DB roundtrips).
    -- needs_books: true only when reading_goals is active, OR reading_stats is
    -- active and "total_books" is among the selected stat items.  When false,
    -- SP.get() skips the sidecar scan (up to 200 DS.open calls) entirely.
    -- External modules that declare M.needs.books = true also trigger this.
    local needs_books = ext_needs_books
    if mod_rg and Registry.isEnabled(mod_rg, PFX) then
        needs_books = true
    elseif mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX) then
        local rs_items = SUISettings:readSetting(PFX .. "reading_stats_items") or {}
        for _, id in ipairs(rs_items) do
            if id == "total_books" then needs_books = true; break end
        end
    end

    local stats_data = nil
    if wants_stats then
        local SP = _getStatsProvider()
        if SP then
            local year_str = os.date("%Y")
            stats_data = SP.get(self._db_conn, year_str, needs_books)
            if stats_data and stats_data.db_conn_fatal then
                logger.warn("simpleui: homescreen: StatsProvider reported fatal DB error — dropping connection")
                if self._db_conn then
                    pcall(function() self._db_conn:close() end)
                    self._db_conn = nil
                end
            end
        end
    end

    -- Pre-compute coverdeck book stats for the current centre cover so
    -- module_coverdeck.build() does not run DB queries on the paint path.
    -- coverdeck_needs_db already encodes the "needs DB stats" check, so we
    -- reuse it directly rather than repeating the visibility logic here.
    local coverdeck_center_stats = nil
    if coverdeck_needs_db and self._db_conn then
        local saved_center_fp = SUISettings:readSetting(PFX .. "flow_recent_fp")
        local center_fp = saved_center_fp or (bs.recent_fps and bs.recent_fps[1])
        local pe = center_fp and bs.prefetched_data and bs.prefetched_data[center_fp]
        local center_md5 = type(pe) == "table" and pe.partial_md5_checksum
        if center_md5 then
            local cd_mod = package.loaded["desktop_modules/module_coverdeck"]
            if cd_mod and cd_mod.fetchBookStatsForCtx then
                coverdeck_center_stats = {
                    fp    = center_fp,
                    stats = cd_mod.fetchBookStatsForCtx(center_md5, self._db_conn),
                }
            end
        end
    end

    -- Pre-compute Currently Reading book stats to move the DB query off the
    -- hot paint path (md5 is already in prefetched_data — no extra IO).
    local currently_book_stats = nil
    if mod_c and Registry.isEnabled(mod_c, PFX) and self._db_conn and bs.current_fp then
        local c_cfg = cfg and cfg.currently
        local needs_bstats = (c_cfg and (c_cfg.show.days or c_cfg.show.time or c_cfg.show.remain))
            or (not c_cfg and (
                SUISettings:nilOrTrue(PFX .. "currently_show_book_days") or
                SUISettings:nilOrTrue(PFX .. "currently_show_book_time") or
                SUISettings:nilOrTrue(PFX .. "currently_show_book_remaining")))
        if needs_bstats then
            local pe_c  = bs.prefetched_data and bs.prefetched_data[bs.current_fp]
            local c_md5 = type(pe_c) == "table" and pe_c.partial_md5_checksum
            if c_md5 then
                -- Fix 5: use pcall(require) instead of package.loaded so that the
                -- module is always resolved even on the very first render, before
                -- build() has had a chance to load it. require() is idempotent —
                -- subsequent calls return the cached module at zero extra cost.
                local mc_ok, mc_mod = pcall(require, "desktop_modules/module_currently")
                if mc_ok and mc_mod and mc_mod.fetchBookStatsForCtx then
                    currently_book_stats = {
                        fp    = bs.current_fp,
                        stats = mc_mod.fetchBookStatsForCtx(c_md5, self._db_conn),
                    }
                end
            end
        end
    end

    local self_ref = self
    return {
        pfx                    = PFX,
        pfx_qa                 = PFX_QA,
        close_fn               = function() self_ref:onClose() end,
        open_fn                = function(fp, pos0, page) openBook(fp, pos0, page) end,
        on_qa_tap              = function(aid) if self_ref._on_qa_tap then self_ref._on_qa_tap(aid) end end,
        on_goal_tap            = function() if self_ref._on_goal_tap then self_ref._on_goal_tap() end end,
        db_conn                = wants_db and self._db_conn or nil,
        db_conn_fatal          = false,
        stats                  = stats_data,
        coverdeck_center_stats = coverdeck_center_stats,
        currently_book_stats   = currently_book_stats,
        vspan_pool             = self._vspan_pool,
        prefetched             = bs.prefetched_data,
        current_fp             = bs.current_fp,
        recent_fps             = bs.recent_fps,
        sectionLabel           = sectionLabel,
        _hs_widget             = self,
        _show_c                = show_c,
        _show_r                = show_r,
        _has_content           = (bs.current_fp and show_c) or (#bs.recent_fps > 0 and show_r),
        cfg                    = cfg,
        has_wallpaper          = (_styleGetBgWidget() ~= nil),
    }
end

-- ---------------------------------------------------------------------------
-- _updateFooter — mutates the persistent footer in-place (zero allocation).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_updateFooter(current_page, total_pages, topbar_on)
    local footer_bc = self._footer_bc
    if not footer_bc then return end

    local sw        = self._layout_sw or Screen:getWidth()
    local content_h = self._layout_content_h or (self._navbar_content_h or Screen:getHeight())

    local navpager_on   = Config.isNavpagerEnabled()
    local dot_pager_on  = Config.isDotPagerEnabled()
    local pag_visible   = SUISettings:nilOrTrue("simpleui_bar_pagination_visible")
    local hs_pag_hidden = SUISettings:isTrue("simpleui_hs_pagination_hidden")

    local show_bar = not hs_pag_hidden
        and total_pages > 1 and (navpager_on or pag_visible or dot_pager_on)
    local use_dots = show_bar and (navpager_on or dot_pager_on)

    if not show_bar then
        footer_bc.dimen.h = 0
        footer_bc[1] = self._footer_hidden_span
        return
    end

    footer_bc.dimen.h = content_h

    if use_dots then
        local fd      = self._footer_dot
        local dw      = fd.dot_widget
        local total_w = total_pages * fd.touch_w
        dw.current_page       = current_page
        dw.total_pages        = total_pages
        fd.bar_input.dimen.w  = total_w
        fd.bar_input.dimen.h  = dw.bar_h
        fd.widget.dimen.w     = sw
        footer_bc[1]          = fd.widget
    else
        local fc = self._footer_chevron
        fc.btn_text:setText(T(_("Page %1 of %2"), current_page, total_pages))
        fc.btn_first:enableDisable(current_page > 1)
        fc.btn_prev:enableDisable(current_page > 1)
        fc.btn_next:enableDisable(current_page < total_pages)
        fc.btn_last:enableDisable(current_page < total_pages)
        footer_bc[1] = fc.widget
    end
end

-- ---------------------------------------------------------------------------
-- _getHsCtxMenu — lazy-initialised context table for module settings menus.
-- Cached after first call so the closure object is not reallocated per page turn.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_getHsCtxMenu()
    if self._hs_ctx_menu then return self._hs_ctx_menu end
    local c = setmetatable({
        pfx           = PFX,
        pfx_qa        = PFX_QA,
        refresh       = function()
            if Homescreen._instance then Homescreen._instance:_refresh(false) end
        end,
        UIManager     = UIManager,
        _             = _,
        N_            = N_,
        MAX_LABEL_LEN = Config.MAX_LABEL_LEN,
        _cover_picker = nil,
    }, {
        __index = function(t, k)
            if k == "InfoMessage" then
                local v = require("ui/widget/infomessage")
                rawset(t, k, v); return v
            elseif k == "SortWidget" then
                local v = require("ui/widget/sortwidget")
                rawset(t, k, v); return v
            end
        end,
    })
    self._hs_ctx_menu = c
    return c
end

-- ---------------------------------------------------------------------------
-- _onHoldModRelease — shared handler for module long-press settings menus.
-- Stored once on HomescreenWidget; each wrapper sets wrapper._sui_mod so this
-- single function knows which module was held (no per-module closure needed).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_onHoldModRelease(wrapper)
    if not SUISettings:nilOrTrue("simpleui_hs_settings_on_hold") then
        return true
    end
    local mod = wrapper._sui_mod
    local hs  = wrapper._sui_hs
    if not mod or not hs then return true end
    local Topbar   = require("sui_topbar")
    local topbar_h = SUISettings:nilOrTrue("simpleui_topbar_enabled")
                     and Topbar.TOTAL_TOP_H() or 0
    local _lc = _
    UI.showSettingsMenu(
        mod.name or mod.id,
        function()
            local ctx_menu = hs:_getHsCtxMenu()
            local items    = mod.getMenuItems(ctx_menu)
            local gap_item = Config.makeGapItem({
                text_func = function()
                    local pct = Config.getModuleGapPct(mod.id, PFX)
                    return string.format(_lc("Top Margin  (%d%%)"), pct)
                end,
                title   = mod.name or mod.id,
                info    = _lc("Vertical space above this module.\n100% is the default spacing."),
                get     = function() return Config.getModuleGapPct(mod.id, PFX) end,
                set     = function(v) Config.setModuleGap(v, mod.id, PFX) end,
                refresh = ctx_menu.refresh,
            })
            items[#items + 1] = gap_item
            return items
        end,
        topbar_h,
        Screen:getHeight(),
        Bottombar.TOTAL_H()
    )
    return true
end

-- ---------------------------------------------------------------------------
-- _makeModWrapper — returns a pooled InputContainer wrapping a module widget.
-- Wrappers are allocated once per mod.id per Homescreen lifetime and updated
-- in-place on subsequent page turns (zero new allocations).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_makeModWrapper(mod, widget, inner_w)
    local pool = self._wrapper_pool
    local w    = pool[mod.id]
    local h    = widget:getSize().h

    if w then
        w[1]       = widget
        w.dimen.w  = inner_w
        w.dimen.h  = h
        w._sui_mod = mod
    else
        w = InputContainer:new{
            dimen    = Geom:new{ w = inner_w, h = h },
            widget,
            _sui_mod = mod,
            _sui_hs  = self,
        }
        w.ges_events = {
            HoldMod = {
                GestureRange:new{
                    ges   = "hold",
                    range = function() return w.dimen end,
                },
            },
            HoldModRelease = {
                GestureRange:new{
                    ges   = "hold_release",
                    range = function() return w.dimen end,
                },
            },
        }
        function w:onHoldMod()
            if not SUISettings:nilOrTrue("simpleui_hs_settings_on_hold") then
                return
            end
            return true
        end
        function w:onHoldModRelease() return self._sui_hs:_onHoldModRelease(self) end
        pool[mod.id] = w
    end
    return w
end

-- ---------------------------------------------------------------------------
-- _updatePage — clears body and repopulates the current page slice.
-- Called on every page turn (keep_cache=true) and on full refreshes (false).
-- ---------------------------------------------------------------------------
function HomescreenWidget:_updatePage(keep_cache, books_only, stats_only)
    if not keep_cache then
        if stats_only then
            self._ctx_cache = nil
        else
            self._cached_books_state = nil
            if not books_only then
                self._enabled_mods_cache = nil
                self._ctx_cache          = nil
            end
        end
    end

    local ctx
    if keep_cache and self._ctx_cache then
        ctx = self._ctx_cache
    else
        ctx = self:_buildCtx()
        self._ctx_cache = ctx
    end
    local inner_w = self._layout_inner_w or (Screen:getWidth() - SIDE_PAD * 2)
    local body    = self._body
    if not body then return end

    -- Module list cache — rebuilt whenever module_order changes.
    local raw_order = Registry.loadOrder(PFX)
    if not self._enabled_mods_cache
       or self._enabled_mods_cache.raw_order ~= raw_order then
        local pages_by_id   = splitOrderIntoPages(raw_order)
        local has_book_mod  = false
        local mod_gaps      = {}
        local pages_of_mods = {}

        for _, page_ids in ipairs(pages_by_id) do
            local page_mods = {}
            for _, mod_id in ipairs(page_ids) do
                local mod = Registry.get(mod_id)
                if mod and Registry.isEnabled(mod, PFX) then
                    page_mods[#page_mods + 1] = mod
                    mod_gaps[mod_id] = Config.getModuleGapPx(mod_id, PFX, MOD_GAP)
                    if mod.is_book_mod then
                        has_book_mod = true
                    end
                end
            end
            pages_of_mods[#pages_of_mods + 1] = page_mods
        end
        if #pages_of_mods == 0 then pages_of_mods[1] = {} end

        local chosen_pages = SUISettings:readSetting(PFX .. "homescreen_num_pages")
        if chosen_pages and chosen_pages > #pages_of_mods then
            for _ = #pages_of_mods + 1, chosen_pages do
                pages_of_mods[#pages_of_mods + 1] = {}
            end
        end

        -- Safety net: ensure coverdeck appears when absent from the saved order.
        do
            local cd = Registry.get("coverdeck")
            if cd and Registry.isEnabled(cd, PFX) then
                local found = false
                for _, pg in ipairs(pages_of_mods) do
                    for _, m in ipairs(pg) do
                        if m.id == "coverdeck" then found = true; break end
                    end
                    if found then break end
                end
                if not found then
                    local insert_at = #pages_of_mods[1] + 1
                    for i, m in ipairs(pages_of_mods[1]) do
                        if m.id == "recent"    then insert_at = i + 1; break end
                        if m.id == "currently" then insert_at = i + 1 end
                    end
                    table.insert(pages_of_mods[1], insert_at, cd)
                    mod_gaps["coverdeck"] = Config.getModuleGapPx("coverdeck", PFX, MOD_GAP)
                    if cd.is_book_mod then has_book_mod = true end
                end
            end
        end

        local enabled_mods = {}
        for _, pg in ipairs(pages_of_mods) do
            for _, m in ipairs(pg) do
                enabled_mods[#enabled_mods + 1] = m
            end
        end

        self._enabled_mods_cache = {
            mods          = enabled_mods,
            mod_gaps      = mod_gaps,
            has_book_mod  = has_book_mod,
            total_pages   = #pages_of_mods,
            pages_of_mods = pages_of_mods,
            raw_order     = raw_order,
        }
    end
    local enabled_mods  = self._enabled_mods_cache.mods
    local has_book_mod  = self._enabled_mods_cache.has_book_mod
    local total_pages   = self._enabled_mods_cache.total_pages
    local mod_gaps      = self._enabled_mods_cache.mod_gaps
    local pages_of_mods = self._enabled_mods_cache.pages_of_mods

    -- Clamp current page and normalise to odd index in landscape (spread mode).
    if self._current_page > total_pages then self._current_page = total_pages end
    if self._current_page < 1           then self._current_page = 1           end
    local is_landscape = _isLandscape()
    if is_landscape and total_pages > 1 and self._current_page % 2 == 0 then
        self._current_page = self._current_page - 1
    end
    self._total_pages = total_pages
    self.page         = self._current_page
    self.page_num     = total_pages

    local empty_widget
    if (ctx._show_c or ctx._show_r) and not ctx._has_content and not has_book_mod then
        empty_widget = buildEmptyState(inner_w, _EMPTY_H)
    end

    body:clear()

    local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")

    self._header_body_idx   = nil
    self._header_inner_w    = inner_w
    self._header_body_ref   = body
    self._header_is_wrapped = false
    self._clock_body_idx    = nil
    self._clock_body_ref    = body
    self._cover_mod_slots   = {}
    self._clock_is_wrapped  = false

    -- Reset the per-filepath extraction dedup guard at the start of every
    -- render.  The guard is an intra-render dedup (prevents the same filepath
    -- being enqueued twice within one build pass); it must not persist across
    -- renders, or getCoverBB() silently skips re-enqueuing books whose covers
    -- are still missing after a previous poll cycle completed.
    if not self._cover_poll_timer then
        Config._cover_extract_pending = {}
    end

    -- Rebuild keyboard navigation book index.
    local _kb_books = {}
    self._kb_first_rec_idx = nil
    ctx.kb_currently_focused = nil
    ctx.kb_recent_focus_idx  = nil
    if ctx.current_fp then
        _kb_books[#_kb_books + 1] = ctx.current_fp
        ctx.kb_currently_focused = (self._kb_focus_idx == #_kb_books) or nil
    end
    if ctx.recent_fps and #ctx.recent_fps > 0 then
        local first_rec_idx = #_kb_books + 1
        self._kb_first_rec_idx = first_rec_idx
        for ri = 1, #ctx.recent_fps do
            _kb_books[#_kb_books + 1] = ctx.recent_fps[ri]
        end
        if self._kb_focus_idx and self._kb_focus_idx >= first_rec_idx
                and self._kb_focus_idx <= #_kb_books then
            ctx.kb_recent_focus_idx = self._kb_focus_idx - first_rec_idx + 1
        end
    end
    self._kb_book_items_fp = _kb_books

    local cur_page_mods  = pages_of_mods[self._current_page] or {}
    local first_mod      = true
    local page_has_covers = false

    if is_landscape then
        -- In landscape, temporarily override Config scale accessors by a fixed
        -- factor so all module builds and getHeight() calls use the scaled value.
        -- Originals are restored immediately after the build loop.
        local LANDSCAPE_FACTOR = 0.65
        self._clock_landscape_factor = LANDSCAPE_FACTOR
        local _orig_getModuleScale = Config.getModuleScale
        local _orig_getLabelScale  = Config.getLabelScale
        local _orig_getThumbScale  = Config.getThumbScale
        Config.getModuleScale = function(mod_id, pfx)
            return _orig_getModuleScale(mod_id, pfx) * LANDSCAPE_FACTOR
        end
        Config.getLabelScale = function()
            return _orig_getLabelScale() * LANDSCAPE_FACTOR
        end
        Config.getThumbScale = function(mod_id, pfx)
            return _orig_getThumbScale(mod_id, pfx) * LANDSCAPE_FACTOR
        end

        local COL_GAP = PAD
        local col_w   = math.floor((inner_w - COL_GAP) / 2)

        -- Spread mode: left = current page, right = next page.
        -- Solo mode (odd total, last page): split this page's modules in half.
        local right_page_mods = pages_of_mods[self._current_page + 1]
        local is_spread       = right_page_mods ~= nil

        local left_col  = {}
        local right_col = {}

        if is_spread then
            for _, mod in ipairs(cur_page_mods) do
                if mod.has_covers then page_has_covers = true end
                local ok_w, widget = pcall(mod.build, col_w, ctx)
                if not ok_w or not widget then
                    logger.warn("simpleui homescreen: build failed for "
                                .. tostring(mod.id) .. ": " .. tostring(widget))
                else
                    left_col[#left_col + 1] = { mod = mod, widget = widget }
                end
            end
            for _, mod in ipairs(right_page_mods) do
                if mod.has_covers then page_has_covers = true end
                local ok_w, widget = pcall(mod.build, col_w, ctx)
                if not ok_w or not widget then
                    logger.warn("simpleui homescreen: build failed for "
                                .. tostring(mod.id) .. ": " .. tostring(widget))
                else
                    right_col[#right_col + 1] = { mod = mod, widget = widget }
                end
            end
        else
            local col_mods = {}
            for _, mod in ipairs(cur_page_mods) do
                if mod.has_covers then page_has_covers = true end
                col_mods[#col_mods + 1] = mod
            end
            local n_col    = #col_mods
            local split_at = math.ceil(n_col / 2)
            for i, mod in ipairs(col_mods) do
                local ok_w, widget = pcall(mod.build, col_w, ctx)
                if not ok_w or not widget then
                    logger.warn("simpleui homescreen: build failed for "
                                .. tostring(mod.id) .. ": " .. tostring(widget))
                else
                    if i <= split_at then
                        left_col[#left_col + 1]  = { mod = mod, widget = widget }
                    else
                        right_col[#right_col + 1] = { mod = mod, widget = widget }
                    end
                end
            end
        end

        -- Builds a VerticalGroup from a list of {mod, widget} entries.
        local function _build_col_group(entries)
            local col_body  = VerticalGroup:new{ align = "left" }
            local col_first = true
            for _, entry in ipairs(entries) do
                local mod    = entry.mod
                local widget = entry.widget
                if col_first then
                    col_first = false
                    local gap_px = mod_gaps[mod.id] or MOD_GAP
                    local initial_pad = topbar_on and gap_px or (gap_px + MOD_GAP)
                    col_body[#col_body+1] = self:_vspan(initial_pad)
                else
                    col_body[#col_body+1] = self:_vspan(mod_gaps[mod.id] or MOD_GAP)
                end
                if mod.label then col_body[#col_body+1] = sectionLabel(mod.label, col_w) end
                local has_menu   = type(mod.getMenuItems) == "function"
                local entry_widget = has_menu
                    and self:_makeModWrapper(mod, widget, col_w)
                    or  widget
                col_body[#col_body+1] = entry_widget
                -- Record slot for per-module cover poll (only for cover modules).
                if mod.has_covers and type(mod.updateCovers) == "function" then
                    self._cover_mod_slots[mod.id] = {
                        mod    = mod,
                        widget = widget,  -- raw widget with _cover_slots attached
                    }
                end
            end
            return col_body
        end

        -- Locates the child index of the clock module within a column group
        -- by replaying the same insertion order used in _build_col_group.
        local function _locate_clock_idx(col_entries, _col_group)
            local gi        = 0
            local col_first = true
            for _, entry in ipairs(col_entries) do
                if col_first then col_first = false
                else gi = gi + 1 end
                if entry.mod.label then gi = gi + 1 end
                gi = gi + 1
                if entry.mod.id == "clock" then
                    return gi
                end
            end
            return nil
        end

        if #left_col > 0 or #right_col > 0 then
            if first_mod then first_mod = false
            else body[#body+1] = self:_vspan(MOD_GAP) end

            local left_group  = _build_col_group(left_col)
            local right_group = _build_col_group(right_col)

            local row = HorizontalGroup:new{
                align = "top",
                left_group,
                HorizontalSpan:new{ width = COL_GAP },
                right_group,
            }
            body[#body+1] = row

            local lci = _locate_clock_idx(left_col,  left_group)
            if lci then
                self._clock_body_ref   = left_group
                self._clock_body_idx   = lci
                for _, e in ipairs(left_col) do
                    if e.mod.id == "clock" then
                        self._clock_is_wrapped = type(e.mod.getMenuItems) == "function"
                        break
                    end
                end
            else
                local rci = _locate_clock_idx(right_col, right_group)
                if rci then
                    self._clock_body_ref = right_group
                    self._clock_body_idx = rci
                    for _, e in ipairs(right_col) do
                        if e.mod.id == "clock" then
                            self._clock_is_wrapped = type(e.mod.getMenuItems) == "function"
                            break
                        end
                    end
                end
            end
        end

        Config.getModuleScale = _orig_getModuleScale
        Config.getLabelScale  = _orig_getLabelScale
        Config.getThumbScale  = _orig_getThumbScale
    else
        -- Portrait single-column layout.
        self._clock_landscape_factor = nil
        for _, mod in ipairs(cur_page_mods) do
            if mod.has_covers then page_has_covers = true end
            local ok_w, widget = pcall(mod.build, inner_w, ctx)
            if not ok_w then
                logger.warn("simpleui homescreen: build failed for "
                            .. tostring(mod.id) .. ": " .. tostring(widget))
            elseif widget then
                if first_mod then
                    first_mod = false
                    local gap_px = mod_gaps[mod.id] or MOD_GAP
                    local initial_pad = topbar_on and gap_px or (gap_px + MOD_GAP)
                    body[#body+1] = self:_vspan(initial_pad)
                else
                    local gap_px = mod_gaps[mod.id] or MOD_GAP
                    body[#body+1] = self:_vspan(gap_px)
                end
                if mod.label then body[#body+1] = sectionLabel(mod.label, inner_w) end
                local has_menu = type(mod.getMenuItems) == "function"
                if mod.id == "header" then
                    self._header_body_idx   = #body + 1
                    self._header_is_wrapped = has_menu
                end
                if mod.id == "clock" then
                    self._clock_body_idx   = #body + 1
                    self._clock_body_ref   = body
                    self._clock_is_wrapped = has_menu
                end
                if has_menu then
                    body[#body+1] = self:_makeModWrapper(mod, widget, inner_w)
                else
                    body[#body+1] = widget
                end
                -- Record slot for per-module cover poll (only for cover modules).
                if mod.has_covers and type(mod.updateCovers) == "function" then
                    self._cover_mod_slots[mod.id] = {
                        mod    = mod,
                        widget = widget,
                    }
                end
            end
        end
    end

    if ctx.db_conn_fatal and self._db_conn then
        logger.warn("simpleui: homescreen: fatal DB error detected — dropping shared connection")
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end

    if empty_widget then
        if first_mod then
            local top_pad = topbar_on and MOD_GAP or (MOD_GAP * 2)
            body[#body+1] = self:_vspan(top_pad)
        end
        body[#body+1] = empty_widget
    end

    -- Dithering hint for e-ink: UIManager checks widget.dithered on setDirty
    -- to trigger a full pixel refresh cycle (avoids ghosting on cover bitmaps).
    self.dithered = page_has_covers or nil

    -- In landscape, footer and navpager reflect spread count rather than raw pages.
    local footer_page, footer_total
    if is_landscape and total_pages > 1 then
        footer_total = math.ceil(total_pages / 2)
        footer_page  = math.ceil(self._current_page / 2)
    else
        footer_total = total_pages
        footer_page  = self._current_page
    end

    self:_updateFooter(footer_page, footer_total, topbar_on)
    _updateNavpagerForHS(footer_page, footer_total)

    -- Reschedule the clock tick when the clock module is on the current page,
    -- keeping it in phase with the status-bar clock after a page turn.
    if self._clock_body_idx ~= nil then
        local ClockMod = Registry.get("clock")
        if ClockMod and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
    end

    -- Warn when module heights overflow the visible area (portrait only).
    -- Skipped when the user has disabled the warning in settings.
    if not is_landscape
       and SUISettings:nilOrTrue("simpleui_hs_overflow_warn") then
        local total_body_h = 0
        for i = 1, #body do
            local ok, sz = pcall(function() return body[i]:getSize() end)
            if ok and sz and sz.h then total_body_h = total_body_h + sz.h end
        end
        -- Use the already-computed content height when available; recalculate
        -- from sui_core when _layout_content_h has not been set yet (e.g. the
        -- very first _updatePage call before _initLayout runs), instead of
        -- falling back to Screen:getHeight() which includes the bars.
        local avail_h = self._layout_content_h or UI.getContentHeight()
        if total_body_h > avail_h then
            -- Guard against showing the warning multiple times for the same
            -- overflow within one homescreen session (e.g. after a page turn
            -- back to an already-checked page, or a stats-only refresh).
            local warn_key = tostring(self._current_page) .. ":" .. tostring(total_body_h)
            if self._overflow_warn_key ~= warn_key then
                self._overflow_warn_key = warn_key
                -- Capture current layout dimensions so the deferred callback
                -- can detect a rotation that invalidated them before it fires.
                local snap_sw      = self._layout_sw      or Screen:getWidth()
                local snap_avail_h = avail_h
                local self_ref     = self
                UIManager:scheduleIn(0.5, function()
                    -- Abort if the instance has been replaced or the screen
                    -- has been rotated since the warning was scheduled.
                    if Homescreen._instance ~= self_ref then return end
                    if (self_ref._layout_sw or Screen:getWidth()) ~= snap_sw then return end
                    if (self_ref._layout_content_h or UI.getContentHeight()) ~= snap_avail_h then return end
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text    = _("Modules exceed the visible area.\nMove some to another page or adjust the scale."),
                        timeout = 4,
                    })
                end)
            end
        else
            -- Reset the dedup key when the page no longer overflows so that a
            -- subsequent layout change that causes it to overflow again is reported.
            self._overflow_warn_key = nil
        end
    end

    -- Flush all covers enqueued during this render into a single
    -- extractInBackground call. Must run before the poll-timer check so that
    -- the subprocess is already launched when _scheduleCoverPoll fires.
    Config.flushCoverQueue()

    -- Start (or re-arm) the cover-extraction poll if any module's build()
    -- call triggered a background extraction.  This check is intentionally
    -- placed here — after all mod.build() calls — because getCoverBB sets
    -- Config.cover_extraction_pending during build(), not during prefetchBooks.
    -- The earlier check in _buildCtx (after prefetchBooks) handles the rare
    -- case where the flag was already set from a previous render cycle that
    -- did not yet finish polling; this check catches the common first-render
    -- case where covers are encountered for the first time.
    if Config.cover_extraction_pending and not self._cover_poll_timer then
        self:_scheduleCoverPoll()
    end
end

-- ---------------------------------------------------------------------------
-- _refresh — debounced rebuild. Page turns call _updatePage directly.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_refresh(keep_cache, books_only, stats_only)
    if keep_cache and self._body then
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")
        return
    end
    if stats_only then
        self._ctx_cache = nil
    else
        self._cached_books_state = nil
        if not books_only then
            self._enabled_mods_cache = nil
            self._ctx_cache          = nil
            self._cfg_cache          = nil
            Homescreen._cfg_cache    = nil
        end
    end
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    local token = {}
    self._pending_refresh_token = token
    local _books_only = books_only
    local _stats_only = stats_only
    UIManager:scheduleIn(0, function()
        if self._pending_refresh_token ~= token then return end
        if Homescreen._instance ~= self then return end
        self._refresh_scheduled = false
        if not self._navbar_container then return end
        self:_updatePage(false, _books_only, _stats_only)
        UIManager:setDirty(self, "ui")
    end)
end

function HomescreenWidget:_setCoverdeckIdx(idx)
    if self._ctx_cache then
        self._ctx_cache.coverdeck_cur_idx = idx
    end
end

-- Immediate full rebuild — bypasses debounce. Used by showSettingsMenu's
-- onCloseWidget to guarantee the HS reflects changes before the next paint.
function HomescreenWidget:_refreshImmediate(keep_cache)
    self._pending_refresh_token = {}
    self._refresh_scheduled     = false
    if not keep_cache then
        self._cached_books_state = nil
        self._enabled_mods_cache = nil
        self._ctx_cache          = nil
            self._cfg_cache          = nil
            Homescreen._cfg_cache    = nil
    end
    if not self._navbar_container then return end
    self:_updatePage(keep_cache or false)
    UIManager:setDirty(self, "ui")
end

-- ---------------------------------------------------------------------------
-- Cover extraction poll
-- ---------------------------------------------------------------------------
-- Polls every 1 second (like the History page). On each tick, for every cover
-- module that still has pending covers, calls mod.updateCovers(widget, ctx)
-- which swaps only the individual ImageWidgets that have now arrived in the
-- DB cache — no full build(), no layout recalculation, no TextWidget creation.
--
-- Each module's updateCovers() returns true when all its covers are resolved
-- (either a bitmap arrived or the file is confirmed to have no cover).
-- The slot is then removed and the poll stops once no slots remain.
--
-- Cover extraction flow within the poll:
--   1. updateCovers() calls getCoverBB() for each missing slot.
--   2. getCoverBB() returns nil for two reasons:
--        a) cover_fetched=false  → file not yet extracted; enqueues the filepath.
--        b) cover_fetched=true, has_cover=false → no cover in file; marks with
--           the NO_COVER sentinel so future calls skip the BIM query entirely.
--   3. After the slot loop, flushCoverQueue() submits newly enqueued files to
--      the BIM as a single extractInBackground call.
--   4. updateCovers() returns true when every slot either has a bitmap or is
--      confirmed missing (isCoverMissing).  The module is then dropped from
--      the poll so we never spin on files that have no cover.
-- ---------------------------------------------------------------------------
function HomescreenWidget:_scheduleCoverPoll()
    local self_ref = self
    local timer
    timer = function()
        self_ref._cover_poll_timer = nil
        if Homescreen._instance ~= self_ref then return end

        local bim              = Config.getBookInfoManager()
        local is_still_running = bim and bim:isExtractingInBackground()
        local slots            = self_ref._cover_mod_slots
        local ctx              = self_ref._ctx_cache

        if not slots or not ctx then
            Config.cover_extraction_pending = false
            self_ref:_refresh(true)
            return
        end

        local any_updated = false
        local any_pending = false

        for mod_id, slot in pairs(slots) do
            if type(slot.mod.updateCovers) == "function" then
                local ok, all_done = pcall(slot.mod.updateCovers, slot.widget, ctx)
                local dimen = slot.widget and slot.widget.dimen
                if ok then
                    if dimen then
                        self_ref.dithered = true
                        UIManager:setDirty(self_ref, function()
                            return "ui", dimen, true
                        end)
                        any_updated = true
                    end
                    if all_done then
                        slots[mod_id] = nil
                    else
                        any_pending = true
                    end
                else
                    logger.warn("simpleui cover poll: updateCovers error for " .. mod_id)
                    slots[mod_id] = nil
                end
            else
                slots[mod_id] = nil
            end
        end

        -- Submit any filepaths that getCoverBB() enqueued during the
        -- updateCovers pass above to the BIM as a single batch call.
        -- Without this, the queue is never flushed inside the poll loop.
        Config.flushCoverQueue()

        if not any_pending then
            Config.cover_extraction_pending = false
            logger.dbg("simpleui cover poll: complete")
            return
        end

        if is_still_running then
            -- BIM subprocess still running — wait for the next tick.
            logger.dbg("simpleui cover poll: BIM running, rescheduling")
            self_ref._cover_poll_timer = timer
            UIManager:scheduleIn(1, timer)
            return
        end

        -- BIM has finished but some slots still returned pending.
        -- Clear the dedup lock so getCoverBB() can re-enqueue on the next tick.
        -- This handles the race where BIM wrote the result just as we polled,
        -- meaning getBookInfo() hadn't yet refreshed its in-memory state.
        -- updateCovers() will see the updated state on the next tick and either
        -- resolve the cover or mark it NO_COVER (which makes all_done = true).
        if Config._cover_extract_pending then
            for fp in pairs(Config._cover_extract_pending) do
                Config._cover_extract_pending[fp] = nil
            end
        end

        logger.dbg("simpleui cover poll: BIM done, one final retry for missing covers")
        self_ref._cover_poll_timer = timer
        UIManager:scheduleIn(1, timer)
    end
    self._cover_poll_timer = timer
    UIManager:scheduleIn(1, timer)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function HomescreenWidget:onShow()
    if self._stats_need_refresh or Homescreen._stats_need_refresh then
        self._stats_need_refresh       = nil
        Homescreen._stats_need_refresh = nil
        local SP = package.loaded["desktop_modules/module_stats_provider"]
        if SP then SP.invalidate() end
    end
    if self._navbar_container then
        local overlap = self:_initLayout()
        local old = self._navbar_container[1]
        if old and old.overlap_offset then
            overlap.overlap_offset = old.overlap_offset
        end
        self._navbar_container[1] = overlap
        self:_updatePage(true)
        UIManager:setDirty(self, "ui")
        local ClockMod = Registry.get("clock")
        if ClockMod and Registry.isEnabled(ClockMod, PFX) and ClockMod.scheduleRefresh then
            ClockMod.scheduleRefresh(self)
        end
    end
end

function HomescreenWidget:onClose()
    UIManager:close(self)
    return true
end

-- Close our SQLite connection before the Statistics plugin's sync runs.
-- When SQLite is in WAL mode (the default on capable devices), a connection
-- held open during the sync corrupts the diff that SyncService.onSync uses
-- to detect deleted records: the WAL read-snapshot makes newly-written rows
-- invisible to the merge query, so they are incorrectly treated as "deleted
-- on this device" and stripped from the income_db before upload.  The result
-- is permanent, silent data loss on all synced devices.
--
-- Closing the connection here (synchronously, before returning false) is
-- necessary but not sufficient: ReaderStatistics:onSyncBookStats defers the
-- actual sync to UIManager:nextTick, so any repaint scheduled between this
-- handler and that tick could call _buildCtx and reopen _db_conn with a new
-- WAL snapshot that again hides the just-written rows.
--
-- _db_sync_guard prevents _buildCtx from reopening the connection during
-- that window.  tickAfterNext schedules the guard clear for two ticks after
-- this one — the sync runs in tick N+1 (nextTick) and is fully blocking, so
-- tick N+2 is guaranteed to run only after SyncService.sync has returned.
-- The guard clear also invalidates _ctx_cache so the next render fetches
-- fresh data from the updated DB.
--
-- Returning false lets the event propagate to ReaderStatistics as normal.
--
-- FIX: _db_sync_guard stuck-forever bug.
-- The original code gated the entire tick callback on
--   Homescreen._instance == self_ref
-- so if the homescreen instance was replaced between the handler and the
-- callback (e.g. a tab switch during a Kobo sync cycle), _db_sync_guard was
-- never cleared on self_ref.  Because _db_sync_guard is an INSTANCE field,
-- that check is wrong in both directions:
--   • Dead instance (onCloseWidget already ran): clearing is harmless —
--     nobody calls _buildCtx on a dead widget.
--   • Live instance no longer registered as _instance: refusing to clear
--     leaves _db_sync_guard = true permanently.  _buildCtx never opens the
--     DB again for the rest of the session, so Currently Reading and Reading
--     Goals stop updating until KOReader is restarted.
-- Fix: always clear the guard on self_ref; only gate _refresh() on the
-- instance still being the current one (refreshing a dead widget is a no-op
-- at best and a crash at worst).  A scheduleIn(10) fallback provides a
-- second safety net for the edge case where the tick callbacks are never
-- invoked (e.g. UIManager teardown during a hot plugin reload).
function HomescreenWidget:onSyncBookStats()
    if self._db_conn then
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end
    self._db_sync_guard = true
    local self_ref = self
    -- One-shot flag so the fallback timer and the tick path don't both fire.
    local cleared = false

    local function clearGuard()
        if cleared then return end
        cleared = true
        -- Always clear the guard on this instance — safe whether alive or dead.
        self_ref._db_sync_guard = false
        self_ref._ctx_cache     = nil
        -- Only repaint when this instance is still the one on screen.
        if Homescreen._instance == self_ref then
            self_ref:_refresh(false)
        end
    end

    -- Primary path: two UIManager ticks guarantee the sync has finished.
    UIManager:tickAfterNext(function()
        UIManager:nextTick(clearGuard)
    end)

    -- Safety-net: if the tick callbacks are never invoked (edge case),
    -- release the guard after 10 s so the homescreen does not stay broken
    -- for the rest of the KOReader session.
    UIManager:scheduleIn(10, clearGuard)

    return false  -- do not consume; Statistics plugin must still handle this
end

function HomescreenWidget:onSuspend()
    self._suspended = true
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
end

function HomescreenWidget:onResume()
    self._suspended = false
    local ClockMod = Registry.get("clock")
    if ClockMod and Registry.isEnabled(ClockMod, PFX) and ClockMod.scheduleRefresh then
        ClockMod.scheduleRefresh(self)
    end
end

function HomescreenWidget:onSetRotationMode(mode)
    -- Ignore rotation events originating inside an open ReaderUI.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return end

    -- HomescreenWidget is on top of the UIManager stack, so broadcastEvent
    -- delivers SetRotationMode here *before* FileManager:onSetRotationMode runs.
    -- Screen:setRotationMode() has therefore not been called yet -- Screen:getWidth()
    -- and Screen:getHeight() still return the pre-rotation dimensions, causing the
    -- original size-based guard to always match (no change detected) and silently
    -- abort the rebuild.
    --
    -- Fix: use the 'mode' argument to detect an orientation change instead.
    -- LinuxFB constants: portraits are even (0, 2), landscapes are odd (1, 3).
    -- A flip in the low bit means layout dimensions will swap -> rebuild needed.
    -- Same-family flips (e.g. 0 <-> 180 portrait inversion) leave dimensions
    -- unchanged, so they don't need a rebuild.
    local current_mode = Screen:getRotationMode()
    if mode == current_mode then return end
    local current_is_landscape = (current_mode % 2) == 1
    local new_is_landscape     = (mode      % 2) == 1
    if current_is_landscape == new_is_landscape then return end

    -- Free the wallpaper cache now, before closing. The new HomescreenWidget
    -- created by the rotation-reopen path will call _styleGetBgWidget() with
    -- the post-rotation Screen dimensions and get a freshly sized ImageWidget.
    _styleFreeBgCache()

    UI.invalidateDimCache()

    local on_qa_tap   = self._on_qa_tap
    local on_goal_tap = self._on_goal_tap

    Homescreen._cached_books_state = self._cached_books_state
    Homescreen._current_page       = self._current_page
    Homescreen._cfg_cache          = self._cfg_cache

    Homescreen._rotation_on_qa_tap   = on_qa_tap
    Homescreen._rotation_on_goal_tap = on_goal_tap
    Homescreen._rotation_pending     = true

    UIManager:close(self)
    return true
end

function HomescreenWidget:onCloseWidget()
    if self._cover_poll_timer then
        UIManager:unschedule(self._cover_poll_timer)
        self._cover_poll_timer = nil
    end
    -- Invalidate debounce token so any scheduled callback becomes a no-op.
    self._pending_refresh_token = {}
    self._refresh_scheduled     = false
    self._pending_cover_clear   = nil

    -- On tab-switch preserve book state and page for the next open;
    -- on real close discard stale data.
    if self._navbar_closing_intentionally then
        Homescreen._cached_books_state = self._cached_books_state
        Homescreen._current_page       = self._current_page
        Homescreen._cfg_cache          = self._cfg_cache
    else
        Homescreen._cached_books_state = nil
        Homescreen._current_page       = nil
        Homescreen._cfg_cache          = nil
    end

    if self._db_conn then
        pcall(function() self._db_conn:close() end)
        self._db_conn = nil
    end
    self._vspan_pool         = nil
    self._wrapper_pool       = nil
    self._cover_mod_slots    = nil
    self._cached_books_state = nil
    self._enabled_mods_cache = nil
    self._current_page       = nil
    self._total_pages        = nil
    self.page                = nil
    self.page_num            = nil
    self._header_body_ref    = nil
    self._header_body_idx    = nil
    self._header_inner_w     = nil
    self._header_is_wrapped  = nil
    self._hs_ctx_menu        = nil
    self._ctx_cache          = nil
    self._shown_once         = nil
    self._stats_need_refresh = nil
    self._body               = nil
    self._overlap            = nil
    self._footer_bc          = nil
    self._footer_chevron     = nil
    self._footer_dot         = nil
    self._footer_hidden_span = nil
    self._layout_sw          = nil
    self._layout_content_h   = nil
    self._layout_inner_w     = nil
    self._kb_book_items_fp   = nil
    self._kb_focus_idx       = nil
    self._kb_first_rec_idx   = nil

    local ClockMod = Registry.get("clock")
    if ClockMod and ClockMod.cancelRefresh then ClockMod.cancelRefresh() end
    self._clock_body_ref   = nil
    self._clock_body_idx   = nil
    self._clock_is_wrapped = nil
    self._clock_pfx        = nil
    self._clock_inner_w    = nil
    self._overflow_warn_key = nil

    -- Clear cover cache only when the FM file browser was visited since the
    -- last homescreen open (CoverBrowser replaces BIM covers with scaled
    -- thumbnails, making our cached bitmaps stale).
    if Homescreen._library_was_visited then
        Homescreen._library_was_visited = nil
        Config.clearCoverCache()
    end

    -- Free header module quotes if the header is not in quote mode.
    local ok_mh, MH = pcall(require, "desktop_modules/module_header")
    if ok_mh and MH and type(MH.freeQuotesIfUnused) == "function" then
        MH.freeQuotesIfUnused()
    end

    if Homescreen._instance == self then
        Homescreen._instance = nil
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

function Homescreen.show(on_qa_tap, on_goal_tap)
    if Homescreen._instance then
        UIManager:close(Homescreen._instance)
        Homescreen._instance = nil
    end
    local w = HomescreenWidget:new{
        _on_qa_tap          = on_qa_tap,
        _on_goal_tap        = on_goal_tap,
        _cached_books_state = Homescreen._cached_books_state,
        _current_page       = Homescreen._current_page or 1,
        _cfg_cache          = Homescreen._cfg_cache,
    }
    Homescreen._instance = w
    UIManager:show(w)
end

function Homescreen.refresh(keep_cache, books_only, stats_only)
    if Homescreen._instance then
        Homescreen._instance:_refresh(keep_cache, books_only, stats_only)
    end
end

function Homescreen.refreshImmediate(keep_cache)
    if Homescreen._instance then
        Homescreen._instance:_refreshImmediate(keep_cache)
    end
end

function Homescreen.close()
    if Homescreen._instance then
        UIManager:close(Homescreen._instance)
        Homescreen._instance = nil
    end
    Homescreen._cached_books_state = nil
    Homescreen._cfg_cache          = nil
end

-- Clears the section-label widget cache. Must be called after a screen
-- resize or rotation so labels are rebuilt at the new inner_w.
Homescreen.invalidateLabelCache = invalidateLabelCache

Homescreen.PAGE_BREAK_ID = HS_PAGE_BREAK_ID

-- ---------------------------------------------------------------------------
-- Look & Feel public API (consumed by sui_menu.lua)
-- ---------------------------------------------------------------------------

-- Rebuild the homescreen layout from scratch (calls _initLayout) so that
-- background transparency and wallpaper take effect immediately.
local function _rebuildHomescreenLayout()
    local hs_inst = Homescreen._instance
    if not hs_inst or not hs_inst._navbar_container then return end

    hs_inst._cached_books_state = nil
    hs_inst._enabled_mods_cache = nil
    hs_inst._ctx_cache          = nil
    hs_inst._cfg_cache          = nil
    Homescreen._cfg_cache       = nil

    local overlap = hs_inst:_initLayout()
    local old = hs_inst._navbar_container[1]
    if old and old.overlap_offset then
        overlap.overlap_offset = old.overlap_offset
    end
    hs_inst._navbar_container[1] = overlap
    hs_inst:_updatePage(true)
    UIManager:setDirty(hs_inst, "ui")
end

function Homescreen.styleGetWallpaper()
    return SUISettings:readSetting("simpleui_style_wallpaper")
end

function Homescreen.styleSetWallpaper(path)
    SUISettings:saveSetting("simpleui_style_wallpaper", path)
    if not path then
        SUISettings:saveSetting("simpleui_statusbar_transparent", false)
        SUISettings:saveSetting("simpleui_navbar_transparent", false)
        SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", false)
    end
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

-- ---------------------------------------------------------------------------
-- Transparent bars — split into two independent settings.
-- Migration: if the old unified "simpleui_bars_transparent" key is present
-- we copy its value to both new keys once, then delete the legacy key so
-- it doesn't interfere on subsequent launches.
-- ---------------------------------------------------------------------------
do
    local legacy = "simpleui_bars_transparent"
    if SUISettings:get(legacy) ~= nil then
        local v = SUISettings:isTrue(legacy)
        SUISettings:saveSetting("simpleui_statusbar_transparent", v)
        SUISettings:saveSetting("simpleui_navbar_transparent",    v)
        SUISettings:del(legacy)
    end
end

function Homescreen.styleStatusbarTransparent()
    if not Homescreen.styleGetWallpaperEnabled() or not Homescreen.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_statusbar_transparent")
end

function Homescreen.styleSetStatusbarTransparent(on)
    SUISettings:saveSetting("simpleui_statusbar_transparent", on and true or false)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleNavbarTransparent()
    if not Homescreen.styleGetWallpaperEnabled() or not Homescreen.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_navbar_transparent")
end

function Homescreen.styleSetNavbarTransparent(on)
    SUISettings:saveSetting("simpleui_navbar_transparent", on and true or false)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleGetWallpapersDir()
    return _styleWallpapersDir()
end

function Homescreen.styleScanWallpapers()
    local dir     = _styleWallpapersDir()
    local items   = {}
    local exts    = { jpg=true, jpeg=true, png=true, bmp=true, gif=true }
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            local ext = fname:match("%.([^%.]+)$")
            if ext and exts[ext:lower()] then
                items[#items + 1] = {
                    label = fname:match("^(.+)%.[^%.]+$") or fname,
                    path  = dir .. "/" .. fname,
                }
            end
        end
        table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Night-mode hook — free the wallpaper cache whenever night mode is toggled
-- so the next _styleGetBgWidget() call rebuilds with the correct inversion
-- state (original_in_nightmode reflects the new setting).
-- ---------------------------------------------------------------------------
local _orig_UIManager_ToggleNightMode = UIManager.ToggleNightMode
function UIManager:ToggleNightMode()
    _orig_UIManager_ToggleNightMode(self)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

local _orig_UIManager_SetNightMode = UIManager.SetNightMode
if _orig_UIManager_SetNightMode then
    function UIManager:SetNightMode(nightmode)
        _orig_UIManager_SetNightMode(self, nightmode)
        _styleFreeBgCache()
        _rebuildHomescreenLayout()
    end
end

-- ---------------------------------------------------------------------------
-- Public API — wallpaper options (consumed by sui_menu.lua)
-- ---------------------------------------------------------------------------

--- Returns the cached background ImageWidget (or nil).
--- Consumed by sui_patches.lua to paint the wallpaper into FM and fullscreen overlay surfaces.
function Homescreen.styleGetBgWidget()
    return _styleGetBgWidget()
end

--- Returns the stored wallpaper opacity (0 = fully opaque, 1-99 = fade toward white).
--- Consumed by sui_patches.lua paint helpers.
function Homescreen.styleGetWallpaperOpacityValue()
    return _wpOpacity()
end

--- fullscreen overlays (Collections, History, etc.).
function Homescreen.styleGetWallpaperShowInFM()
    if not Homescreen.styleGetWallpaperEnabled() or not Homescreen.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_wallpaper_show_in_fm")
end
function Homescreen.styleSetWallpaperShowInFM(on)
    SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", on and true or false)
end

function Homescreen.styleGetWallpaperEnabled()
    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
end
function Homescreen.styleSetWallpaperEnabled(on)
    local is_on = on ~= false and true or false
    SUISettings:saveSetting("simpleui_style_wallpaper_enabled", is_on)
    if not is_on then
        SUISettings:saveSetting("simpleui_statusbar_transparent", false)
        SUISettings:saveSetting("simpleui_navbar_transparent", false)
        SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", false)
    end
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleGetWallpaperStretch()
    return _wpStretch()
end
function Homescreen.styleSetWallpaperStretch(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_stretch", on ~= false and true or false)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleGetWallpaperAutoRotate()
    return _wpAutoRotate()
end
function Homescreen.styleSetWallpaperAutoRotate(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_autorotate", on ~= false and true or false)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleGetWallpaperInvertNight()
    return _wpInvertNight()
end
function Homescreen.styleSetWallpaperInvertNight(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_invert_night", on and true or false)
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

function Homescreen.styleGetWallpaperOpacity()
    return _wpOpacity()
end
function Homescreen.styleSetWallpaperOpacity(val)
    SUISettings:saveSetting("simpleui_style_wallpaper_opacity", math.max(0, math.min(99, val or 0)))
    -- Opacity is applied at paint-time (not baked into the ImageWidget cache),
    -- but a setDirty alone is not sufficient when called from a SpinWidget
    -- callback — the homescreen instance may not be in the foreground repaint
    -- queue at that point.  Use the same _rebuildHomescreenLayout() path as
    -- every other wallpaper setter so the change is always visible immediately.
    _rebuildHomescreenLayout()
end

--- Frees the internal wallpaper widget cache.
--- Must be called after changing the simpleui_style_* keys directly
--- in SUISettings (e.g. after applying a preset), so that the next paint
--- rebuilds the ImageWidget with the new wallpaper.
function Homescreen.styleFreeBgCache()
    _styleFreeBgCache()
end

--- Full layout rebuild — frees the wallpaper cache and rebuilds the layout
--- (dimensions, bar overlaps, positioning) before invalidating the screen.
--- Must be called after applying a preset that might change the wallpaper,
--- the transparent bars, or any other option that affects the layout.
function Homescreen.rebuildLayout()
    _styleFreeBgCache()
    _rebuildHomescreenLayout()
end

return Homescreen
