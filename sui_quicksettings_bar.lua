-- sui_quicksettings_bar.lua — Simple UI
-- Injects a Quick Settings panel tab into the KOReader touch menu,
-- identical in concept to the 2-quick-settings.lua userpatch but implemented
-- as a proper SimpleUI module.
--
-- PUBLIC API
--   QSBar.install(plugin)    — called from main.lua:onInit  (once per session)
--   QSBar.uninstall()        — called from main.lua:onTeardown
--   QSBar.makeMenuItems(ctx_menu) → KOReader item table for Bars → Quick Settings Bar
--
-- HOW IT WORKS
--   1. install() monkey-patches TouchMenu:updateItems and
--      TouchMenu:onTapCloseAllMenus so that when the panel tab is active the
--      normal item list is replaced by a row of action-button widgets.
--   2. A panel tab entry  { icon="...", remember=false, panel=<fn> }  is
--      inserted into tab_item_table by patching FileManagerMenu:setUpdateItemTable.
--   3. Action buttons are built from the user-configured slots stored under
--      "simpleui_qs_bar_slots".  Execution delegates to QA.execute().
--
-- SETTINGS KEY
--   "simpleui_qs_bar_slots"  → ordered array of action-id strings
--   "simpleui_qs_bar_enabled" → bool (default true)

local Device     = require("device")
local Screen     = Device.screen
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local UIManager  = require("ui/uimanager")
local logger     = require("logger")

local Blitbuffer        = require("ffi/blitbuffer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local FrameContainer    = require("ui/widget/container/framecontainer")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local ImageWidget       = require("ui/widget/imagewidget")
local LineWidget        = require("ui/widget/linewidget")
local TextWidget        = require("ui/widget/textwidget")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local InputContainer    = require("ui/widget/container/inputcontainer")
local GestureRange      = require("ui/gesturerange")

local SUISettings = require("sui_store")
local _           = require("sui_i18n").translate
local N_          = require("sui_i18n").ngettext

-- Lazy references
local function _QA()
    return package.loaded["sui_quickactions"] or require("sui_quickactions")
end
local function _Config()
    return package.loaded["sui_config"] or require("sui_config")
end

local QSBar = {}
local _showQSBarSettingsWindow

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local SLOTS_KEY      = "simpleui_qs_bar_slots"
local ENABLED_KEY    = "simpleui_qs_bar_enabled"
local SHAPE_KEY      = "simpleui_qs_bar_shape"
local BG_KEY         = "simpleui_qs_bar_bg"
local FRONTLIGHT_KEY = "simpleui_qs_bar_frontlight"
local WARMTH_KEY     = "simpleui_qs_bar_warmth"
local LABELS_KEY     = "simpleui_qs_bar_labels"
local LABEL_SCALE_KEY= "simpleui_qs_bar_label_scale_pct"
local MAX_SLOTS      = 24

local function getSlots()
    local raw = SUISettings:readSetting(SLOTS_KEY)
    return type(raw) == "table" and raw or {}
end

local function saveSlots(slots)
    SUISettings:saveSetting(SLOTS_KEY, slots)
end

local function isEnabled()
    return SUISettings:nilOrTrue(ENABLED_KEY)
end

local function getShape()
    return SUISettings:readSetting(SHAPE_KEY) or "rounded_square"
end

local function getBg()
    return SUISettings:readSetting(BG_KEY) or "solid"
end

local function showLabels()
    return SUISettings:nilOrTrue(LABELS_KEY)
end

local function getLabelScalePct()
    local n = tonumber(SUISettings:readSetting(LABEL_SCALE_KEY))
    if not n then return 100 end
    return math.max(50, math.min(200, math.floor(n)))
end

local function showFrontlight()
    return SUISettings:nilOrTrue(FRONTLIGHT_KEY)
end

local function showWarmth()
    return SUISettings:nilOrTrue(WARMTH_KEY)
end

-- ---------------------------------------------------------------------------
-- Label helper
-- ---------------------------------------------------------------------------

local function labelFor(id)
    local ok, entry = pcall(function() return _QA().getEntry(id) end)
    if ok and entry then return entry.label end
    return id
end

-- ---------------------------------------------------------------------------
-- Panel widget builder
-- Returns a VerticalGroup that fills the menu body, plus a refs table used
-- by the gesture handler to dispatch taps.
-- touch_menu is the live TouchMenu instance (for width / show_parent).
-- ---------------------------------------------------------------------------

local function buildPanel(touch_menu)
    local original_slots = getSlots()

    -- Detect current view: "reader" (inside a book) or "fb" (file browser)
    local current_view = nil
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and not RUI.instance.tearing_down then
        current_view = "reader"
    else
        current_view = "fb"
    end

    -- Determine which context an action belongs to
    -- Returns: "fb", "reader", or "common" (both)
    local function getActionCategory(action_id)
        local cfg = SUISettings:get("simpleui_qa_" .. action_id) or {}

        -- Folder or collection: file browser only
        if cfg.path or cfg.collection then
            return "fb"
        end

        -- Plugin action: works everywhere
        if cfg.plugin_key then
            return "common"
        end

        -- Action with explicit menu_path.view setting
        if cfg.menu_path and type(cfg.menu_path) == "table" then
            return cfg.menu_path.view
        end

        -- Dispatcher action: inspect its category
        if cfg.dispatcher_action then
            local Dispatcher = require("dispatcher")
            local settingsList
            local fn_idx = 1
            while true do
                local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
                if not name then break end
                if name == "settingsList" then settingsList = val end
                fn_idx = fn_idx + 1
            end
            local def = settingsList and settingsList[cfg.dispatcher_action]
            if def then
                if def.filemanager then return "fb" end
                if def.reader or def.rolling or def.paging then return "reader" end
            end
            return "common"
        end

        -- Built-in file browser actions
        local fb_actions = {
            "home", "collections", "history", "favorites",
            "browse_authors", "browse_series", "browse_tags"
        }
        for _, id in ipairs(fb_actions) do
            if action_id == id then return "fb" end
        end

        -- Default: available in both contexts
        return "common"
    end

    -- Filter slots: only show actions valid in current view
    local slots = {}
    for _, action_id in ipairs(original_slots) do
        local category = getActionCategory(action_id)
        if category == "common" or category == current_view then
            table.insert(slots, action_id)
        end
    end

    local n = #slots
    local panel_w  = touch_menu.item_width
    local padding  = Screen:scaleBySize(28)
    local inner_w  = panel_w - padding * 2

    -- refs: { widget, callback } entries for action buttons +
    --       fl_progress / fl_state / setBrightness for the frontlight bar.
    local refs = { buttons = {} }

    -- ── Action-button row ────────────────────────────────────────────────────
    local btn_size  = Screen:scaleBySize(60)
    local icon_size = math.floor(btn_size * 0.52)
    local ok_style, SUIStyle = pcall(require, "sui_style")
    local lbl_fs    = math.max(6, math.floor((ok_style and SUIStyle.FS_DETAIL or 15) * (getLabelScalePct() / 100)))
    local lbl_face  = Font:getFace(ok_style and SUIStyle.FACE_REGULAR or "cfont", lbl_fs)
    local border_sz = ok_style and SUIStyle.BORDER_SZ or 1

    local function makeButton(action_id)
        local QA    = _QA()
        local entry = QA.getEntry(action_id)
        local label = entry.label or action_id

        local icon_widget
        local Config = _Config()
        local is_nerd = Config.isNerdIcon(entry.icon)
        local ok_style, SUIStyle = pcall(require, "sui_style")
        
        if is_nerd then
            local nerd_char = Config.nerdIconChar(entry.icon)
            icon_widget = TextWidget:new{
                text    = nerd_char,
                face    = Font:getFace(ok_style and SUIStyle.FACE_ICONS or "symbols", math.floor(icon_size * 0.75)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                padding = 0,
            }
        else
            local icon_path = ok_style and SUIStyle and entry.icon
                and SUIStyle.safeIconPath and SUIStyle.safeIconPath(entry.icon, nil)
            if icon_path then
                local iw = ImageWidget:new{
                    file    = icon_path,
                    width   = icon_size,
                    height  = icon_size,
                    is_icon = true,
                    alpha   = true,
                }
                local ok_render = pcall(function() iw:_render() end)
                if ok_render then
                    icon_widget = iw
                else
                    iw:free()
                end
            end
            if not icon_widget then
                icon_widget = TextWidget:new{
                    text    = (label:sub(1, 1)):upper(),
                    face    = Font:getFace("cfont", math.floor(icon_size * 0.55)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                }
            end
        end

        local shape = getShape()
        local bg    = getBg()
        local is_bare = (shape == "bare")
        local corner_r = is_bare and 0 or ((shape == "round") and math.floor(btn_size / 2) or math.floor(btn_size / 4))
        local current_border = (not is_bare and (bg == "solid" or bg == "transparent")) and border_sz or 0

        local bg_color = nil
        if not is_bare then
            if bg == "flat" then bg_color = Blitbuffer.gray(0.08)
            elseif bg == "solid" then bg_color = Blitbuffer.COLOR_WHITE end
        end

        local btn_frame = FrameContainer:new{
            width      = btn_size,
            height     = btn_size,
            radius     = corner_r,
            bordersize = current_border,
            color      = current_border > 0 and Blitbuffer.gray(0.75) or nil,
            background = bg_color,
            padding    = 0,
            CenterContainer:new{
                dimen = Geom:new{
                    w = btn_size - current_border * 2,
                    h = btn_size - current_border * 2,
                },
                icon_widget,
            },
        }

        local vg = VerticalGroup:new{
            align = "center",
            btn_frame,
        }

        if showLabels() then
            local lbl_w = btn_size + Screen:scaleBySize(6)
            table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(2) })
            table.insert(vg, CenterContainer:new{
                dimen = Geom:new{ w = lbl_w, h = lbl_face.size },
                TextWidget:new{
                    text    = label,
                    face    = lbl_face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = lbl_w,
                },
            })
        end

        return vg, btn_frame
    end

local n = #slots
-- Calculate max buttons per row based on available width
local fixed_gap = Screen:scaleBySize(8)
local max_per_row = math.floor((inner_w + fixed_gap) / (btn_size + fixed_gap))
if max_per_row < 1 then max_per_row = 1 end

-- Split into multiple rows
local rows = {}
for i = 1, n, max_per_row do
    local row_slots = {}
    for j = i, math.min(i + max_per_row - 1, n) do
        table.insert(row_slots, slots[j])
    end
    table.insert(rows, row_slots)
end

-- Build all rows vertically
local rows_vg = VerticalGroup:new{ align = "center" }
local row_gap = Screen:scaleBySize(8)

if n > 0 then
    for ri, row_slots in ipairs(rows) do
        local row_n = #row_slots
        local gap = (row_n > 1)
            and math.max(0, math.floor((inner_w - row_n * btn_size) / (row_n - 1)))
            or 0
        
        local hg = HorizontalGroup:new{ align = "center" }
        for i, action_id in ipairs(row_slots) do
            local vg, btn_frame = makeButton(action_id)
            local _aid = action_id
            table.insert(refs.buttons, {
                widget   = btn_frame,
                callback = function()
                    local QA = _QA()
                    local is_in_place = QA.isInPlace(_aid)
                    local stay_open = is_in_place

                    if _aid:match("^custom_qa_%d+$") or _aid == "sui_win_settings" then
                        stay_open = false
                    end

                    local FM  = package.loaded["apps/filemanager/filemanager"]
                    local fm  = FM and FM.instance
                    local plugin = fm and fm._simpleui_plugin
                    
                    if not plugin then
                        local ctx = { fm = fm }
                        if not stay_open then
                            UIManager:scheduleIn(0, function()
                                local ok, err = pcall(QA.execute, _aid, ctx)
                                if not ok then logger.warn("simpleui QSBar: execute error", _aid, tostring(err)) end
                            end)
                        else
                            local ok, err = pcall(QA.execute, _aid, ctx)
                            if not ok then logger.warn("simpleui QSBar: execute error", _aid, tostring(err)) end
                            touch_menu:updateItems()
                        end
                        return stay_open
                    end
                    
                    local RUI = package.loaded["apps/reader/readerui"]
                    local in_reader = RUI and RUI.instance
                    -- Inside the reader, FM.instance may be nil, so fall back to
                    -- the plugin instance registered on ReaderUI.
                    local plugin_resolved = plugin
                        or (in_reader and in_reader.simpleui)

                    if stay_open then
                        local ctx = { plugin = plugin_resolved, fm = fm }
                        local ok, err = pcall(QA.execute, _aid, ctx)
                        if not ok then
                            logger.warn("simpleui QSBar: execute error", _aid, tostring(err))
                        end
                        touch_menu:updateItems()
                        return stay_open
                    end

                    UIManager:scheduleIn(0, function()
                        local FM_live = package.loaded["apps/filemanager/filemanager"]
                        local fm_live = FM_live and FM_live.instance
                        local plugin_live = fm_live and fm_live._simpleui_plugin or plugin

                        if in_reader and not is_in_place then
                            if _aid == "homescreen" then
                                require("sui_patches").closeReaderToHomescreen(plugin_live)
                            else
                                local readerui = RUI.instance
                                local file = readerui.document and readerui.document.file
                                plugin_live._closing_via_gesture = true
                                readerui._navbar_closing_intentionally = true
                                readerui:onClose()
                                readerui:showFileManager(file)
                                UIManager:scheduleIn(0, function()
                                    local FM_new = package.loaded["apps/filemanager/filemanager"]
                                    local fm_new = FM_new and FM_new.instance
                                    local plugin_new = fm_new and fm_new._simpleui_plugin or plugin_live
                                    plugin_new:_navigate(_aid, fm_new, _Config().loadTabConfig(), false)
                                end)
                            end
                        else
                            if is_in_place then
                                local ctx = { plugin = plugin_live, fm = fm_live }
                                local ok, err = pcall(QA.execute, _aid, ctx)
                                if not ok then logger.warn("simpleui QSBar: execute error", _aid, tostring(err)) end
                            else
                                local fm_self = fm_live
                                local UI = package.loaded["sui_core"]
                                if UI then
                                    local stack = UI.getWindowStack()
                                    for i = #stack, 1, -1 do
                                        local w = stack[i].widget
                                        if w and w._navbar_injected and w.name ~= "homescreen" then
                                            fm_self = w
                                            break
                                        end
                                    end
                                end
                                plugin_live:_navigate(_aid, fm_self, _Config().loadTabConfig(), false)
                            end
                        end
                    end)
                    return stay_open
                end,
            })
            table.insert(hg, vg)
            if i < row_n then
                table.insert(hg, HorizontalSpan:new{ width = gap })
            end
        end
        
        table.insert(rows_vg, hg)
        if ri < #rows then
            table.insert(rows_vg, VerticalSpan:new{ width = row_gap })
        end
    end
else
    -- No actions configured, show a hint message
    table.insert(rows_vg, TextWidget:new{
        text    = _("No actions configured.\nGo to Bars → Quick Settings Bar."),
        face    = Font:getFace("cfont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
end

local btn_row = rows_vg

    -- ── Slider helpers ───────────────────────────────────────────────────────
    local Button         = require("ui/widget/button")
    local ProgressWidget = require("ui/widget/progresswidget")
    local medium_face    = Font:getFace("ffont")
    local small_btn_w    = Screen:scaleBySize(40)
    local max_btn_w      = Screen:scaleBySize(50)
    local slider_gap     = Screen:scaleBySize(4)
    local slider_w       = inner_w - 2 * small_btn_w - max_btn_w - 3 * slider_gap
    local section_gap    = VerticalSpan:new{ width = Screen:scaleBySize(6) }

    -- ── Frontlight slider ────────────────────────────────────────────────────
    local fl_group = VerticalGroup:new{ align = "center" }

    if showFrontlight() and Device:hasFrontlight() then
        local powerd = Device:getPowerDevice()
        local fl = {
            min = powerd.fl_min,
            max = powerd.fl_max,
            cur = powerd:frontlightIntensity(),
        }
        local fl_steps  = fl.max - fl.min + 1
        local fl_stride = math.ceil(fl_steps * (1 / 25))

        -- Intermediate ticks for the progress bar
        local fl_ticks     = {}
        local fl_num_ticks = math.ceil(fl_steps / fl_stride)
        if (fl_num_ticks - 1) * fl_stride < fl.max - fl.min then
            fl_num_ticks = fl_num_ticks + 1
        end
        fl_num_ticks = math.min(fl_num_ticks, fl_steps)
        for i = 1, fl_num_ticks - 2 do
            table.insert(fl_ticks, i * fl_stride)
        end

        local fl_label = TextWidget:new{
            text      = _("Frontlight") .. ": " .. tostring(fl.cur),
            face      = medium_face,
            max_width = inner_w,
        }

        -- Create a dummy button first to measure the height for the progress bar.
        local _dummy     = Button:new{ text = "−", width = small_btn_w,
                                       show_parent = touch_menu.show_parent,
                                       callback = function() end }
        local btn_height = _dummy:getSize().h

        local fl_progress = ProgressWidget:new{
            width      = slider_w,
            height     = btn_height,
            percentage = fl.cur / fl.max,
            ticks      = fl_ticks,
            tick_width = Screen:scaleBySize(0.5),
            last       = fl.max,
        }

        local function updateFLWidgets()
            fl_progress:setPercentage(fl.cur / fl.max)
            fl_label:setText(_("Frontlight") .. ": " .. tostring(fl.cur))
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        local function setBrightness(intensity)
            if intensity ~= fl.min and intensity == fl.cur then return end
            intensity = math.max(fl.min, math.min(fl.max, intensity))
            powerd:setIntensity(intensity)
            fl.cur = powerd:frontlightIntensity()
            updateFLWidgets()
        end

        local fl_minus = Button:new{
            text        = "−",
            width       = small_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setBrightness(fl.cur - 1) end,
        }
        local fl_plus = Button:new{
            text        = "＋",
            width       = small_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setBrightness(fl.cur + 1) end,
        }
        local fl_max_btn = Button:new{
            text        = _("Max"),
            width       = max_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setBrightness(fl.max) end,
        }

        local fl_row = HorizontalGroup:new{
            align = "center",
            fl_minus,
            HorizontalSpan:new{ width = slider_gap },
            fl_progress,
            HorizontalSpan:new{ width = slider_gap },
            fl_plus,
            HorizontalSpan:new{ width = slider_gap },
            fl_max_btn,
        }

        -- Store on refs so the gesture handler can hit-test the progress bar.
        refs.fl_progress   = fl_progress
        refs.fl_state      = fl
        refs.setBrightness = setBrightness

        table.insert(fl_group, fl_label)
        table.insert(fl_group, section_gap)
        table.insert(fl_group, fl_row)
    end

    -- ── Warmth slider ────────────────────────────────────────────────────────
    local warmth_group = VerticalGroup:new{ align = "center" }

    if showWarmth() and Device:hasNaturalLight() then
        local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
        local Math   = require("optmath")
        local powerd = Device:getPowerDevice()

        local nl = {
            min = powerd.fl_warmth_min,
            max = powerd.fl_warmth_max,
            cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
        }
        local nl_steps      = nl.max - nl.min + 1
        local nl_stride     = math.ceil(nl_steps * (1 / 25))
        local nl_num_btns   = math.ceil(nl_steps / nl_stride)
        if (nl_num_btns - 1) * nl_stride < nl.max - nl.min then
            nl_num_btns = nl_num_btns + 1
        end
        nl_num_btns = math.min(nl_num_btns, nl_steps)

        local warmth_slider_w = inner_w - 2 * small_btn_w - max_btn_w - 3 * slider_gap

        -- Measure button height (reuse dummy or create one).
        local _dummy2     = Button:new{ text = "−", width = small_btn_w,
                                        show_parent = touch_menu.show_parent,
                                        callback = function() end }
        local btn_height2 = _dummy2:getSize().h

        local nl_label = TextWidget:new{
            text      = _("Warmth") .. ": " .. tostring(nl.cur),
            face      = medium_face,
            max_width = inner_w,
        }

        local nl_progress = ButtonProgressWidget:new{
            width            = warmth_slider_w,
            height           = btn_height2,
            font_size        = 20,
            padding          = 0,
            thin_grey_style  = false,
            num_buttons      = nl_num_btns - 1,
            position         = math.floor(nl.cur / nl_stride),
            default_position = math.floor(nl.cur / nl_stride),
            show_parent      = touch_menu.show_parent,
            enabled          = true,
            callback         = function(i)
                local new_native = Math.round(i * nl_stride)
                new_native = math.min(new_native, nl.max)
                powerd:setWarmth(powerd:fromNativeWarmth(new_native))
                nl.cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
                nl_label:setText(_("Warmth") .. ": " .. tostring(nl.cur))
                UIManager:setDirty(touch_menu.show_parent, "ui")
            end,
        }

        local function setWarmth(warmth)
            if warmth == nl.cur then return end
            warmth = math.max(nl.min, math.min(nl.max, warmth))
            powerd:setWarmth(powerd:fromNativeWarmth(warmth))
            nl.cur = powerd:toNativeWarmth(powerd:frontlightWarmth())
            nl_progress:setPosition(math.floor(nl.cur / nl_stride), nl_progress.default_position)
            nl_label:setText(_("Warmth") .. ": " .. tostring(nl.cur))
            UIManager:setDirty(touch_menu.show_parent, "ui")
        end

        local nl_minus = Button:new{
            text        = "−",
            width       = small_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setWarmth(nl.cur - 1) end,
        }
        local nl_plus = Button:new{
            text        = "＋",
            width       = small_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setWarmth(nl.cur + 1) end,
        }
        local nl_max_btn = Button:new{
            text        = _("Max"),
            width       = max_btn_w,
            show_parent = touch_menu.show_parent,
            callback    = function() setWarmth(nl.max) end,
        }

        local nl_row = HorizontalGroup:new{
            align = "center",
            nl_minus,
            HorizontalSpan:new{ width = slider_gap },
            nl_progress,
            HorizontalSpan:new{ width = slider_gap },
            nl_plus,
            HorizontalSpan:new{ width = slider_gap },
            nl_max_btn,
        }

        table.insert(warmth_group, VerticalSpan:new{ width = Screen:scaleBySize(12) })
        table.insert(warmth_group, nl_label)
        table.insert(warmth_group, section_gap)
        table.insert(warmth_group, nl_row)
    end

    -- ── Assemble panel ───────────────────────────────────────────────────────
    local panel = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Screen:scaleBySize(20) },
        CenterContainer:new{
            dimen = Geom:new{ w = panel_w, h = btn_row:getSize().h },
            btn_row,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(16) },
    }

    if #fl_group > 0 then
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_w, h = fl_group:getSize().h },
            fl_group,
        })
    end

    if #warmth_group > 0 then
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_w, h = warmth_group:getSize().h },
            warmth_group,
        })
    end

    table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(14) })

    local panel_h = panel:getSize().h
    local ic = InputContainer:new{
        dimen = Geom:new{ w = panel_w, h = panel_h },
        [1]   = panel,
    }

    ic.ges_events = {
        HoldPanel = {
            GestureRange:new{ ges = "hold", range = function() return ic.dimen end },
        },
    }
    function ic:onHoldPanel()
        if not SUISettings:nilOrTrue("simpleui_qs_bar_settings_on_hold") then
            return false
        end
        if _showQSBarSettingsWindow then
            _showQSBarSettingsWindow(touch_menu)
        end
        return true
    end

    return ic, refs
end

-- ---------------------------------------------------------------------------
-- Gesture handler — dispatch taps/swipes that land on a button circle
-- ---------------------------------------------------------------------------

local function handleGesture(touch_menu, ges)
    local refs = touch_menu._sui_qs_refs
    if not refs then return false end

    -- Hit-test frontlight progress bar (ProgressWidget doesn't self-handle taps).
    if refs.fl_progress and refs.fl_progress.dimen
            and ges.pos:intersectWith(refs.fl_progress.dimen) then
        local perc = refs.fl_progress:getPercentageFromPosition(ges.pos)
        if perc and refs.setBrightness then
            local fl = refs.fl_state
            local Math = require("optmath")
            refs.setBrightness(Math.round(perc * fl.max))
            return true, true
        end
    end

    -- Hit-test action buttons.
    for _, ref in ipairs(refs.buttons or refs) do
        if ref.widget.dimen and ges.pos:intersectWith(ref.widget.dimen) then
            local stay_open = ref.callback()
            return true, stay_open == true
        end
    end

    return false, false
end

-- ---------------------------------------------------------------------------
-- TouchMenu monkey-patch (install / uninstall)
-- ---------------------------------------------------------------------------
-- We keep the originals on the class itself under _sui_qs_orig_* so we can
-- restore them cleanly on uninstall without needing a module-level upvalue.

local function patchTouchMenu()
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok or not TouchMenu then return end
    if TouchMenu._sui_qs_patched then return end
    TouchMenu._sui_qs_patched = true

    local FocusManager = require("ui/widget/focusmanager")
    local datetime     = require("datetime")
    local BD           = require("ui/bidi")

    -- ── updateItems ─────────────────────────────────────────────────────────
    local orig_updateItems = TouchMenu.updateItems
    TouchMenu._sui_qs_orig_updateItems = orig_updateItems

    function TouchMenu:updateItems(target_page, target_item_id)
        -- Not our panel tab — delegate normally.
        if not (self.item_table and self.item_table._sui_qs_panel) then
            self._sui_qs_refs = nil
            return orig_updateItems(self, target_page, target_item_id)
        end

        -- Panel mode: replace the item list with our widget.
        self.item_group:clear()
        self.layout = {}
        table.insert(self.item_group, self.bar)
        table.insert(self.layout, self.bar.icon_widgets)

        -- Build panel (sets self._sui_qs_refs)
        local panel, refs = buildPanel(self)
        self._sui_qs_refs = refs
        table.insert(self.item_group, panel)

        -- Footer (no pagination)
        table.insert(self.item_group, self.footer_top_margin)
        table.insert(self.item_group, self.footer)
        self.page_info_text:setText("")
        self.page_info_left_chev:showHide(false)
        self.page_info_right_chev:showHide(false)

        -- Disable long-press on pagination buttons to prevent crashes
        if self.page_info_left_chev then
            self.page_info_left_chev.hold_callback = nil
        end
        if self.page_info_right_chev then
            self.page_info_right_chev.hold_callback = nil
        end

        -- Update clock/battery in footer
        local time_txt = datetime.secondsToHour(
            os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
        local powerd = Device:getPowerDevice()
        if Device:hasBattery() then
            local lvl  = powerd:getCapacity()
            local sym  = powerd:getBatterySymbol(
                powerd:isCharged(), powerd:isCharging(), lvl)
            time_txt = BD.wrap(time_txt)
                .. " " .. BD.wrap("⌁")
                .. BD.wrap(sym)
                .. BD.wrap(lvl .. "%")
        end
        self.time_info:setText(time_txt)

        -- Recalculate geometry
        local old_dimen = self.dimen:copy()
        self.dimen.w = self.width
        self.dimen.h = self.item_group:getSize().h
            + self.bordersize * 2 + self.padding
        self:moveFocusTo(self.cur_tab, 1, FocusManager.NOT_FOCUS)

        local keep_bg = old_dimen and self.dimen.h >= old_dimen.h
        UIManager:setDirty(
            (self.is_fresh or keep_bg) and self.show_parent or "all",
            function()
                local refresh_dimen = old_dimen
                    and old_dimen:combine(self.dimen) or self.dimen
                local refresh_type = "ui"
                if self.is_fresh then
                    refresh_type = "flashui"
                    self.is_fresh = false
                end
                return refresh_type, refresh_dimen
            end)
    end

    -- ── onTapCloseAllMenus ───────────────────────────────────────────────────
    local orig_onTap = TouchMenu.onTapCloseAllMenus
    TouchMenu._sui_qs_orig_onTap = orig_onTap

    function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
        if self._sui_qs_refs
                and self.item_table
                and self.item_table._sui_qs_panel then
            local handled, stay_open = handleGesture(self, ges_ev)
            if handled then
                if stay_open then return true end
                self:onClose()
                return true
            end
        end
        return orig_onTap(self, arg, ges_ev)
    end

    -- ── onSwipe ──────────────────────────────────────────────────────────────
    local orig_onSwipe = TouchMenu.onSwipe
    TouchMenu._sui_qs_orig_onSwipe = orig_onSwipe

    function TouchMenu:onSwipe(arg, ges_ev)
        if self._sui_qs_refs
                and self.item_table
                and self.item_table._sui_qs_panel then
            local handled, stay_open = handleGesture(self, ges_ev)
            if handled then
                if stay_open then return true end
                self:onClose()
                return true
            end
        end
        if orig_onSwipe then
            return orig_onSwipe(self, arg, ges_ev)
        end
    end
end

local function unpatchTouchMenu()
    local TM = package.loaded["ui/widget/touchmenu"]
    if not TM or not TM._sui_qs_patched then return end
    if TM._sui_qs_orig_updateItems then
        TM.updateItems           = TM._sui_qs_orig_updateItems
        TM._sui_qs_orig_updateItems = nil
    end
    if TM._sui_qs_orig_onTap then
        TM.onTapCloseAllMenus    = TM._sui_qs_orig_onTap
        TM._sui_qs_orig_onTap    = nil
    end
    if TM._sui_qs_orig_onSwipe then
        TM.onSwipe               = TM._sui_qs_orig_onSwipe
        TM._sui_qs_orig_onSwipe  = nil
    end
    TM._sui_qs_patched = nil
end

-- ---------------------------------------------------------------------------
-- Tab injection into FileManagerMenu:setUpdateItemTable
-- ---------------------------------------------------------------------------
-- The panel tab entry has _sui_qs_panel=true on the item_table so that
-- the patched updateItems knows to switch to panel mode.

local _panel_tab = {
    icon     = "simpleui_settings",
    remember = false,
    -- _sui_qs_panel flag consumed by the patched updateItems
    _sui_qs_panel = true,
}

local function injectPanelTab(m_self)
    if not isEnabled() then return end
    if type(m_self.tab_item_table) ~= "table" then return end

    -- Avoid double-inject (called on every menu open)
    for _, tab in ipairs(m_self.tab_item_table) do
        if tab._sui_qs_panel then return end
    end

    -- Find the KOReader quicksettings tab position to insert right before it
    -- (mirrors the convention used in the patch).
    local insert_pos = 1
    for i, tab in ipairs(m_self.tab_item_table) do
        for _, field in ipairs({ "id", "name", "icon" }) do
            local v = tab[field]
            if type(v) == "string" then
                local norm = v:lower():gsub("[%s_%-]+", "")
                if norm == "quicksettings" then
                    insert_pos = i  -- insert BEFORE the native QS tab
                    break
                end
            end
        end
    end

    table.insert(m_self.tab_item_table, insert_pos, _panel_tab)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- QSBar.install(plugin)
-- Called once from SimpleUIPlugin:onInit (via the existing do-block in main.lua).
function QSBar.install()
    if not isEnabled() then return end

    -- 0. Icon registration: make "simpleui_settings" resolve to settings.svg
    --    independently.  Three layers:
    --
    --    Layer 1 — copy SVG to DataStorage/icons/ so ICONS_DIRS disk lookup
    --              works even when runtime upvalue injection fails.
    --    Layer 2 — inject into IconWidget's ICONS_PATH and ICONS_DIRS upvalue
    --              caches (single scan, same approach as Zen UI / main.lua).
    --    Layer 3 — patch IconWidget.init directly for hardened builds where
    --              debug.getupvalue is unavailable.
    do
        -- Resolve plugin_root to an absolute path.
        -- On some devices debug.getinfo returns a relative source path
        -- (e.g. "plugins/simpleui.koplugin/sui_quicksettings_bar.lua").
        local src = debug.getinfo(1, "S").source or ""
        local plugin_root = (src:sub(1, 1) == "@")
            and src:sub(2):match("^(.*)/[^/]+$") or nil
        if plugin_root and plugin_root:sub(1, 1) ~= "/" then
            local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
            local cwd = ok_lfs2 and lfs2 and lfs2.currentdir()
            if cwd then plugin_root = cwd .. "/" .. plugin_root end
        end

        if plugin_root then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs then
                local icon_src = plugin_root .. "/icons/settings.svg"
                if lfs.attributes(icon_src, "mode") == "file" then

                    -- Layer 1: copy to DataStorage/icons/simpleui_settings.svg
                    pcall(function()
                        local DataStorage = require("datastorage")
                        local ffiutil     = require("ffi/util")
                        local user_dir    = DataStorage:getDataDir() .. "/icons"
                        if lfs.attributes(user_dir, "mode") ~= "directory" then
                            lfs.mkdir(user_dir)
                        end
                        local dst = user_dir .. "/simpleui_settings.svg"
                        if lfs.attributes(dst, "mode") ~= "file" then
                            ffiutil.copyFile(icon_src, dst)
                        end
                    end)

                    -- Layer 2: inject into IconWidget's runtime upvalue caches.
                    local injected = false
                    pcall(function()
                        local iw      = require("ui/widget/iconwidget")
                        -- Prefer the unwrapped init so the scan finds ICONS_PATH/ICONS_DIRS
                        -- even when sui_patches' alpha patch has already replaced iw.init.
                        local iw_init = iw._simpleui_orig_init_for_scan or rawget(iw, "init")
                        if type(iw_init) ~= "function" then return end
                        local icons_path, icons_dirs
                        for i = 1, 64 do
                            local uname, uval = debug.getupvalue(iw_init, i)
                            if uname == nil then break end
                            if uname == "ICONS_PATH" and type(uval) == "table" then
                                icons_path = uval
                            elseif uname == "ICONS_DIRS" and type(uval) == "table" then
                                icons_dirs = uval
                            end
                            if icons_path and icons_dirs then break end
                        end
                        if icons_path then
                            if not icons_path["simpleui_settings"] then
                                icons_path["simpleui_settings"] = icon_src
                            end
                            injected = true
                        end
                        if icons_dirs then
                            local icons_subdir = plugin_root .. "/icons"
                            local already = false
                            for _, d in ipairs(icons_dirs) do
                                if d == icons_subdir then already = true; break end
                            end
                            if not already then
                                table.insert(icons_dirs, 1, icons_subdir)
                            end
                            injected = true
                        end
                    end)

                    -- Layer 3: patch IconWidget.init for hardened builds.
                    if not injected then
                        pcall(function()
                            local iw = require("ui/widget/iconwidget")
                            local orig_init = iw.init
                            iw.init = function(self_iw, ...)
                                if self_iw.icon == "simpleui_settings"
                                        and not self_iw.file
                                        and not self_iw.image then
                                    self_iw.file = icon_src
                                    return
                                end
                                if type(orig_init) == "function" then
                                    orig_init(self_iw, ...)
                                end
                            end
                            logger.info("simpleui/qsbar: icon registered via IconWidget.init patch (fallback)")
                        end)
                    end

                end
            end
        end
    end

    -- 1. Patch TouchMenu methods.
    patchTouchMenu()

    -- Reset FileManagerMenu tab index to 1 when closing
    -- This ensures Quick Settings panel is active when menu reopens
    local function patchFileManagerMenuClose()
        local ok, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
        if not ok or not FileManagerMenu then return end
        if FileManagerMenu._sui_qs_fm_patched then return end
        FileManagerMenu._sui_qs_fm_patched = true

        local orig_onCloseFileManagerMenu = FileManagerMenu.onCloseFileManagerMenu
        FileManagerMenu.onCloseFileManagerMenu = function(self)
            if self.menu_container and self.menu_container[1] then
                self.menu_container[1].last_index = 1
            end
            return orig_onCloseFileManagerMenu(self)
        end
    end

    patchFileManagerMenuClose()

    -- Reset ReaderMenu tab index to 1 when closing
    -- This ensures Quick Settings panel is active when menu reopens
    local function patchReaderMenuClose()
        local ok, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
        if not ok or not ReaderMenu then return end
        if ReaderMenu._sui_qs_reader_patched then return end
        ReaderMenu._sui_qs_reader_patched = true

        local orig_onCloseReaderMenu = ReaderMenu.onCloseReaderMenu
        ReaderMenu.onCloseReaderMenu = function(self)
            if self.menu_container and self.menu_container[1] then
                self.menu_container[1].last_index = 1
                self.last_tab_index = 1
            end
            return orig_onCloseReaderMenu(self)
        end
    end

    patchReaderMenuClose()

    -- 2. Patch FileManagerMenu:setUpdateItemTable to inject the panel tab.
    local ok_fm, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok_fm or not FMMenu then return end
    if FMMenu._sui_qs_tab_patched then return end
    FMMenu._sui_qs_tab_patched = true

    local orig_sut = FMMenu.setUpdateItemTable
    FMMenu.setUpdateItemTable = function(m_self)
        orig_sut(m_self)
        injectPanelTab(m_self)
    end

    -- 3. Patch ReaderMenu:onShowMenu to inject the panel tab inside the reader.
    --
    --    We cannot mirror step 2 and patch setUpdateItemTable, because
    --    ReaderMenu caches tab_item_table after the first call and the nil-guard
    --    in onShowMenu prevents setUpdateItemTable from ever being called again.
    --    Patching onShowMenu guarantees injectPanelTab runs on every menu open,
    --    even with the cached tab_item_table — identical to what setUpdateItemTable
    --    achieves for FileManagerMenu (which rebuilds tab_item_table each time).
    local ok_rm, RMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm and RMenu and not RMenu._sui_qs_tab_patched then
        RMenu._sui_qs_tab_patched = true

        local orig_show_menu = RMenu.onShowMenu
        RMenu.onShowMenu = function(m_self, ...)
            -- tab_item_table is built (or already cached) at this point;
            -- inject our panel tab before the TouchMenu is created.
            if m_self.tab_item_table then
                -- Move "File manager" tab to the end of the list
                -- This gives priority to reader-specific tabs
                local tabs = m_self.tab_item_table
                for i, tab in ipairs(tabs) do
                    if tab.id == "filemanager" or (tab.text and tab.text == _("File manager")) then
                        if i < #tabs then
                            table.remove(tabs, i)
                            table.insert(tabs, tab)
                        end
                        break
                    end
                end 
                injectPanelTab(m_self)
            end
            return orig_show_menu(m_self, ...)
        end
    end
end

-- QSBar.uninstall()
-- Called from SimpleUIPlugin:onTeardown.
function QSBar.uninstall()
    unpatchTouchMenu()

    local FMMenu = package.loaded["apps/filemanager/filemanagermenu"]
    if FMMenu and FMMenu._sui_qs_tab_patched then
        FMMenu._sui_qs_tab_patched = nil
    end

    local RMenu = package.loaded["apps/reader/modules/readermenu"]
    if RMenu and RMenu._sui_qs_tab_patched then
        RMenu._sui_qs_tab_patched = nil
    end
end

_showQSBarSettingsWindow = function(touch_menu)
    local SUIWindow = require("sui_window")
    
    local function buildRoot(ctx)
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = QSBar.makeMenuItems(ctx_menu),
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
            push_stack     = function(id, params)
                if type(id) == "string" then ctx.push(id, params) else ctx.push("nested_menu", params) end
            end,
            on_close       = function() end,
        }
    end

    local function titleFn(ctx)
        local cur = ctx.current()
        local id  = cur and cur.id or "__root__"
        if id == "nested_menu" then return cur.params.title or "" end
        if id == "arrange"     then return cur.params.title or _("Arrange Items") end
        if id == "item_picker" then return cur.params and cur.params.title or _("Add Item") end
        return _("Quick Settings Bar")
    end

    local win = SUIWindow:new{
        name           = "sui_win_context",
        title          = titleFn,
        screens        = SUIWindow.makeSettingsScreens(buildRoot),
        navpager_mode  = _Config().isNavpagerEnabled(),
        position       = "bottom",
        has_settings_btn = true,
    }
    UIManager:close(touch_menu)
    win:show()
end

-- QSBar.makeMenuItems(ctx_menu) → KOReader item table
-- Returned by makeBarsMenuItems in sui_menu.lua.
function QSBar.makeMenuItems(ctx_menu)
    local function refresh()
        if ctx_menu and type(ctx_menu.refresh) == "function" then
            ctx_menu.refresh()
        end
        
        local function _forceRebuild(menu)
            if menu then 
                menu.is_fresh = true
                if menu.item_table and menu.item_table._sui_qs_panel then
                    pcall(function() menu:updateItems() end)
                end
            end
        end
        
        local FM = package.loaded["apps/filemanager/filemanager"]
        if FM and FM.instance then _forceRebuild(FM.instance.menu) end
        
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then _forceRebuild(RUI.instance.menu) end
    end

    local items = {}

    local QA   = _QA()
    local pool = {}
    for _, id in ipairs(QA.allIds()) do pool[#pool + 1] = { id = id, label = QA.getEntry(id).label } end
    for _, qa_id in ipairs(QA.getCustomQAList()) do pool[#pool + 1] = { id = qa_id, label = QA.getEntry(qa_id).label } end
    table.sort(pool, function(a, b) return a.label:lower() < b.label:lower() end)

    local items_sub = {}
    items_sub[#items_sub + 1] = {
        text           = _("Arrange Items"),
        keep_menu_open = true,
        separator      = true,
        enabled_func   = function() return #getSlots() >= 2 end,
        callback       = function()
            local slots = getSlots()
            if #slots < 2 then
                local InfoMessage = require("ui/widget/infomessage")
                local UIM = (ctx_menu and ctx_menu.UIManager) or UIManager
                UIM:show(InfoMessage:new{ text = _("Add at least 2 actions to arrange."), timeout = 3 })
                return
            end
            local sort_items = {}
            for _, sid in ipairs(slots) do
                sort_items[#sort_items + 1] = { text = labelFor(sid), orig_item = sid }
            end
            local function on_save()
                local new_slots = {}
                for _, it in ipairs(sort_items) do new_slots[#new_slots + 1] = it.orig_item end
                saveSlots(new_slots)
                refresh()
            end
            local SortWidget = require("ui/widget/sortwidget")
            local UIM = (ctx_menu and ctx_menu.UIManager) or UIManager
            UIM:show(SortWidget:new{
                title             = _("Arrange Quick Settings"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = on_save,
            })
        end,
    }

    for _, entry in ipairs(pool) do
        local _id    = entry.id
        local _label = entry.label
        items_sub[#items_sub + 1] = {
            text_func    = function()
                local slots = getSlots()
                for i, sid in ipairs(slots) do
                    if sid == _id then return string.format("%s  (%d/%d)", _label, i, MAX_SLOTS) end
                end
                return _label
            end,
            checked_func = function()
                for _, sid in ipairs(getSlots()) do if sid == _id then return true end end
                return false
            end,
            keep_menu_open = true,
            callback = function()
                local slots = getSlots()
                local pos
                for i, sid in ipairs(slots) do if sid == _id then pos = i; break end end
                if pos then
                    table.remove(slots, pos)
                else
                    if #slots >= MAX_SLOTS then
                        local InfoMessage = require("ui/widget/infomessage")
                        local UIM = (ctx_menu and ctx_menu.UIManager) or UIManager
                        UIM:show(InfoMessage:new{
                            text = string.format(N_("Maximum of %d slot reached. Remove one first.", "Maximum of %d slots reached. Remove one first.", MAX_SLOTS), MAX_SLOTS),
                            timeout = 3,
                        })
                        return
                    end
                    slots[#slots + 1] = _id
                end
                saveSlots(slots)
                refresh()
            end,
        }
    end

    items[#items + 1] = {
        text           = _("Enable Quick Settings Bar"),
        checked_func   = isEnabled,
        keep_menu_open = true,
        separator      = true,
        callback       = function()
            local on = isEnabled()
            SUISettings:saveSetting(ENABLED_KEY, not on)
            local ConfirmBox = require("ui/widget/confirmbox")
            local UIM = (ctx_menu and ctx_menu.UIManager) or UIManager
            UIM:show(ConfirmBox:new{
                text = string.format(
                    _("The Quick Settings Bar will be %s after restart.\n\nRestart now?"),
                    on and _("disabled") or _("enabled")
                ),
                ok_text = _("Restart"), cancel_text = _("Later"),
                ok_callback = function()
                    SUISettings:flush()
                    UIM:restartKOReader()
                end,
            })
        end,
    }

    items[#items + 1] = {
        text                = _("Quick Actions"),
        sub_item_table_func = function() return items_sub end,
        sui_build = ctx_menu and ctx_menu.is_sui and function(ctx, _item)
            local SUIWindow = require("sui_window")
            return SUIWindow.ListRow{
                title        = _("Quick Actions"),
                        subtitle     = function()
                            local slots = getSlots()
                            if #slots == 0 then return _("No actions active yet.") end
                            local names = {}
                            for _, sid in ipairs(slots) do
                                names[#names + 1] = labelFor(sid)
                            end
                            return table.concat(names, "  ·  ")
                        end,
                inner_w      = ctx.inner_w,
                item_count   = function() return #getSlots() end,
                max_items    = MAX_SLOTS,
                show_chevron = true,
                on_tap       = function()
                    local slots = getSlots()
                    local sort_items = {}
                    for _, sid in ipairs(slots) do
                        sort_items[#sort_items + 1] = { text = labelFor(sid), orig_item = sid }
                    end
                    ctx.push("arrange", {
                        title = _("Quick Actions"),
                        items = sort_items,
                        empty_text = _("No actions active yet."),
                        item_count = function() return #getSlots() end,
                        max_items  = MAX_SLOTS,
                        on_delete = function(item) end,
                        on_change = function(items_to_save)
                            local new_slots = {}
                            for _, it in ipairs(items_to_save) do new_slots[#new_slots + 1] = it.orig_item end
                            saveSlots(new_slots)
                            refresh()
                        end,
                        footer_text = _("Add Action"),
                        footer_action = function(ctx2)
                            local picker_items = {}
                            for _, entry in ipairs(pool) do
                                local is_sel = false
                                for _, sid in ipairs(getSlots()) do if sid == entry.id then is_sel = true; break end end
                                if not is_sel then
                                    picker_items[#picker_items + 1] = {
                                        text = entry.label,
                                        on_tap = function(picker_ctx)
                                            local cur = getSlots()
                                            if #cur >= MAX_SLOTS then
                                                local InfoMessage = require("ui/widget/infomessage")
                                                local UIM = ctx_menu and ctx_menu.UIManager or require("ui/uimanager")
                                                UIM:show(InfoMessage:new{ text = _("Maximum slots reached."), timeout = 2 })
                                                return
                                            end
                                            cur[#cur + 1] = entry.id
                                            saveSlots(cur)
                                            table.insert(sort_items, { text = entry.label, orig_item = entry.id })
                                            refresh()
                                            picker_ctx.pop()
                                            ctx2.repaint()
                                        end
                                    }
                                end
                            end
                            ctx2.push("item_picker", { title = _("Add Action"), items = picker_items })
                        end
                    })
                end
            }
        end or nil,
    }
    
    items[#items + 1] = {
        text           = _("Frontlight Slider"),
        checked_func   = showFrontlight,
        keep_menu_open = true,
        enabled_func   = function() return Device:hasFrontlight() end,
        callback       = function()
            SUISettings:saveSetting(FRONTLIGHT_KEY, not showFrontlight())
            refresh()
        end,
    }

    items[#items + 1] = {
        text           = _("Warmth Slider"),
        checked_func   = showWarmth,
        keep_menu_open = true,
        enabled_func   = function() return Device:hasNaturalLight() end,
        callback       = function()
            SUISettings:saveSetting(WARMTH_KEY, not showWarmth())
            refresh()
        end,
    }

    items[#items + 1] = {
        text = _("Label"),
        sub_item_table = {
            _Config().makeScaleItem({
                text_func    = function() return _("Size") end,
                title        = _("Size"),
                info         = _("Scale for the label text.\n100% is the default size."),
                get          = function() return getLabelScalePct() end,
                set          = function(v) SUISettings:saveSetting(LABEL_SCALE_KEY, v) end,
                refresh      = refresh,
            }),
            {
                text           = _("Hide Label"),
                checked_func   = function() return not showLabels() end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(LABELS_KEY, not showLabels())
                    refresh()
                end,
            },
        }
    }

    items[#items + 1] = {
        text = _("Button Type"),
        sub_item_table = {
            {
                text           = _("Round"),
                radio          = true,
                checked_func   = function() return getShape() == "round" end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(SHAPE_KEY, "round")
                    refresh()
                end,
            },
            {
                text           = _("Rounded Square"),
                radio          = true,
                checked_func   = function() return getShape() == "square_round" end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(SHAPE_KEY, "square_round")
                    refresh()
                end,
            },
                {
                    text           = _("Bare"),
                    radio          = true,
                    checked_func   = function() return getShape() == "bare" end,
                    keep_menu_open = true,
                    callback       = function()
                        SUISettings:saveSetting(SHAPE_KEY, "bare")
                        refresh()
                    end,
                },
        },
    }

    items[#items + 1] = {
        text = _("Button Background"),
            enabled_func = function() return getShape() ~= "bare" end,
        sub_item_table = {
            {
                text           = _("Transparent"),
                radio          = true,
                checked_func   = function() return getBg() == "transparent" end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(BG_KEY, "transparent")
                    refresh()
                end,
            },
            {
                text           = _("Solid"),
                radio          = true,
                checked_func   = function() return getBg() == "solid" end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(BG_KEY, "solid")
                    refresh()
                end,
            },
            {
                text           = _("Flat"),
                radio          = true,
                checked_func   = function() return getBg() == "flat" end,
                keep_menu_open = true,
                callback       = function()
                    SUISettings:saveSetting(BG_KEY, "flat")
                    refresh()
                end,
            },
        },
    }

    items[#items + 1] = {
        text           = _("Settings on Long Tap"),
        help_text      = _("When enabled, long-pressing the Quick Settings Bar opens its settings menu.\nDisable this to prevent the settings menu from appearing on long tap."),
        checked_func   = function()
            return SUISettings:nilOrTrue("simpleui_qs_bar_settings_on_hold")
        end,
        keep_menu_open = true,
        callback       = function()
            local on = SUISettings:nilOrTrue("simpleui_qs_bar_settings_on_hold")
            SUISettings:saveSetting("simpleui_qs_bar_settings_on_hold", not on)
            refresh()
        end,
    }

    return items
end

return QSBar
