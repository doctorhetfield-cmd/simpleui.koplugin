-- sui_quicksettings_bar.lua — Simple UI
-- Injects a Quick Settings panel tab into the KOReader touch menu.
--
-- PUBLIC API
--   QSBar.install()          — called from main.lua:onInit  (once per session)
--   QSBar.uninstall()        — called from main.lua:onTeardown
--   QSBar.makeMenuItems(ctx_menu) → KOReader item table for Bars → Quick Settings Bar
--
-- HOW IT WORKS
--   1. install() monkey-patches TouchMenu:updateItems and
--      TouchMenu:onTapCloseAllMenus so that when the panel tab is active the
--      normal item list is replaced by a row of action-button widgets.
--   2. A panel tab entry  { icon="...", remember=false, _sui_qs_panel=true }
--      is inserted as the first tab of the reader and file-browser menus by a
--      step registered in the shared menu hooks (infra/sui_menu_hooks.lua).
--      The same step can open those menus directly on the panel.
--   3. Action buttons are built from the user-configured slots stored under
--      "simpleui_qs_bar_slots".  Execution delegates to QA.execute().
--   4. The panel has two layouts. Classic (always used in the file browser)
--      spreads the buttons over the width, above the optional sliders. Book
--      (reader only) shows the open book's cover beside its title, author,
--      statistics and progress bar — each optional and in a configurable
--      order — with a row of label-less icon buttons and an Exit button
--      (icon and text) underneath the text. The title, author and progress bar
--      span the width of the action slots, which follows the button size. The
--      statistics line spans the text column, up to the end of the Exit Book
--      button. The optional sliders sit below, from the cover's left edge to
--      the Exit Book button's right edge.
--   5. The sliders span the width of the button row: they start where the
--      first button starts and end where the last button ends.
--
-- SETTINGS KEYS
--   "simpleui_qs_bar_slots"  → ordered array of action-id strings
--   "simpleui_qs_bar_enabled" → bool (default true)
--   "simpleui_qs_bar_open_reader" / "simpleui_qs_bar_open_fm"
--                            → bool (default true): open that menu on the panel
--   "simpleui_qs_bar_reader_layout" → "classic" | "book" (default "book")
--   "simpleui_qs_bar_slider_style"  → "classic" | "minimal" (default "minimal"): look
--                            of the frontlight and warmth sliders
--   "simpleui_qs_bar_book_sliders"  → bool (default false): show the sliders in the
--                            Book layout too
--   "simpleui_qs_bar_settings_on_hold" → bool (default true): long tap opens the settings
--   "simpleui_qs_bar_book_order"    → ordered array of Book layout item ids
--   "simpleui_qs_bar_book_show_<id>" → bool (default true): item is shown
--   "simpleui_qs_bar_stats_order"    → ordered array of statistics ids
--   "simpleui_qs_bar_stats_show_<id>" → bool: statistic is shown (see STAT_HIDDEN_BY_DEFAULT)

local Device     = require("device")
local Screen     = Device.screen
local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local UIManager  = require("ui/uimanager")
local UI         = require("infra/sui_core")
local Math       = require("optmath")
local logger     = require("logger")

local CenterContainer   = require("ui/widget/container/centercontainer")
local FrameContainer    = require("ui/widget/container/framecontainer")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local LeftContainer     = require("ui/widget/container/leftcontainer")
local TextBoxWidget     = require("ui/widget/textboxwidget")
local TextWidget        = require("ui/widget/textwidget")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local InputContainer    = require("ui/widget/container/inputcontainer")
local GestureRange      = require("ui/gesturerange")
local Event             = require("ui/event")

local BookStats   = require("infra/sui_book_stats")
local SUISettings = require("infra/sui_store")
local Backdrop    = require("infra/sui_backdrop")
local SUIStyle    = require("features/sui_style")
local MenuHooks   = require("infra/sui_menu_hooks")
local _           = require("infra/sui_i18n").translate
local N_          = require("infra/sui_i18n").ngettext

-- Lazy references
local function _QA()
    return package.loaded["features/sui_quickactions"] or require("features/sui_quickactions")
end
local function _Config()
    return package.loaded["infra/sui_config"] or require("infra/sui_config")
end
local function _QARenderer()
    return package.loaded["engines/sui_quickactions_render"] or require("engines/sui_quickactions_render")
end
local function _SUISlider()
    return package.loaded["engines/sui_slider"] or require("engines/sui_slider")
end
local function _SH()
    return package.loaded["modules/module_books_shared"] or require("modules/module_books_shared")
end
local function _CritterRow()
    return package.loaded["modules/critter/panel_row"] or require("modules/critter/panel_row")
end

local QSBar = {}
local _showQSBarSettingsWindow

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local SLOTS_KEY      = "simpleui_qs_bar_slots"
local ENABLED_KEY    = "simpleui_qs_bar_enabled"
local SHAPE_KEY      = "simpleui_qs_bar_shape"
local LOOK_KEY       = "simpleui_qs_bar_bg"        -- single-choice look of earlier versions
local SURFACE_KEY    = "simpleui_qs_bar"
local FRONTLIGHT_KEY = "simpleui_qs_bar_frontlight"
local WARMTH_KEY     = "simpleui_qs_bar_warmth"
local SLIDER_STYLE_KEY = "simpleui_qs_bar_slider_style"
local SLIDER_STYLE = { CLASSIC = "classic", MINIMAL = "minimal" }
local SLIDER_STYLE_IDS = { SLIDER_STYLE.CLASSIC, SLIDER_STYLE.MINIMAL }
local BOOK_SLIDERS_KEY = "simpleui_qs_bar_book_sliders"
local LABELS_KEY     = "simpleui_qs_bar_labels"
local LABEL_SCALE_KEY= "simpleui_qs_bar_label_scale_pct"
local READER_LAYOUT_KEY = "simpleui_qs_bar_reader_layout"
local SETTINGS_ON_HOLD_KEY = "simpleui_qs_bar_settings_on_hold"
local LAYOUT = { CLASSIC = "classic", BOOK = "book" }
local LAYOUT_IDS = { LAYOUT.CLASSIC, LAYOUT.BOOK }
local BOOK_ORDER_KEY  = "simpleui_qs_bar_book_order"
local BOOK_SHOW_KEY   = "simpleui_qs_bar_book_show_"   -- .. item id
-- Items of the Book layout's text column, in default order.
local BOOK_ITEMS = { "title", "author", "stats", "progress" }
local STAT_ORDER_KEY  = "simpleui_qs_bar_stats_order"
local STAT_SHOW_KEY   = "simpleui_qs_bar_stats_show_"   -- .. statistic id
-- Statistics joined into the Book layout's statistics line, in default order.
local STAT_ITEMS = BookStats.STAT_IDS
-- Statistics that stay hidden until the user shows them.
local STAT_HIDDEN_BY_DEFAULT = { book_days = true, book_time = true }
-- Setting key of the icon shown on the Exit Book button (see SUIStyle.SLOTS).
local EXIT_ICON_SLOT = "sui_qs_exit"
-- Per-menu switch: open the menu on the panel instead of the last used tab.
local OPEN_ON_PANEL_KEYS = {
    [MenuHooks.TARGET.READER] = "simpleui_qs_bar_open_reader",
    [MenuHooks.TARGET.FM]     = "simpleui_qs_bar_open_fm",
}

local function opensOnPanel(target)
    return SUISettings:nilOrTrue(OPEN_ON_PANEL_KEYS[target])
end
local MAX_SLOTS      = 6

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

local BUTTON_SURFACE = Backdrop.surface("quick_settings", SURFACE_KEY)

-- Surface of the buttons; the look stored by earlier versions is converted on
-- first use (see Backdrop.migrateLook).
local function buttonSurface()
    Backdrop.migrateLook(BUTTON_SURFACE, LOOK_KEY)
    return BUTTON_SURFACE
end

local function showLabels()
    return SUISettings:nilOrTrue(LABELS_KEY)
end

local function getLabelScalePct()
    local n = tonumber(SUISettings:readSetting(LABEL_SCALE_KEY))
    if not n then return 100 end
    return math.max(50, math.min(200, math.floor(n)))
end

local function getSliderStyle()
    return _Config().readChoice(SLIDER_STYLE_KEY, SLIDER_STYLE_IDS, SLIDER_STYLE.MINIMAL)
end

local function showBookSliders()
    return SUISettings:isTrue(BOOK_SLIDERS_KEY)
end

local function getReaderLayout()
    return _Config().readChoice(READER_LAYOUT_KEY, LAYOUT_IDS, LAYOUT.BOOK)
end

local function isBookItemVisible(id)
    return SUISettings:nilOrTrue(BOOK_SHOW_KEY .. id)
end

local function setBookItemVisible(id, visible)
    SUISettings:saveSetting(BOOK_SHOW_KEY .. id, visible)
end

local function getBookItemOrder()
    return _Config().mergeOrder(SUISettings:readSetting(BOOK_ORDER_KEY), BOOK_ITEMS)
end

local function isStatVisible(id)
    local saved = SUISettings:readSetting(STAT_SHOW_KEY .. id)
    if saved == nil then return not STAT_HIDDEN_BY_DEFAULT[id] end
    return saved
end

local function setStatVisible(id, visible)
    SUISettings:saveSetting(STAT_SHOW_KEY .. id, visible)
end

local function getStatOrder()
    return _Config().mergeOrder(SUISettings:readSetting(STAT_ORDER_KEY), STAT_ITEMS)
end

local function bookItemLabel(id)
    if id == "title"  then return _("Title") end
    if id == "author" then return _("Author") end
    if id == "stats"  then return _("Statistics") end
    return _("Progress bar")
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
-- Action execution
-- ---------------------------------------------------------------------------

local function safeExecute(action_id, ctx)
    local ok, err = pcall(_QA().execute, action_id, ctx)
    if not ok then logger.warn("simpleui QSBar: execute error", action_id, tostring(err)) end
end

-- Live FileManager and ReaderUI instances plus the plugin registered on
-- them. FileManager.instance may be nil inside the reader; the plugin is then
-- registered on ReaderUI as readerui.simpleui.
local function liveInstances()
    local FM     = package.loaded["apps/filemanager/filemanager"]
    local RUI    = package.loaded["apps/reader/readerui"]
    local fm     = FM and FM.instance
    local reader = RUI and RUI.instance
    return fm, reader, (fm and fm._simpleui_plugin) or (reader and reader.simpleui)
end

-- Closes the open reader and replays `action_id` on the file browser it
-- leaves behind.
local function runFromReader(plugin, action_id)
    local Patches = require("infra/sui_patches")
    if action_id == "homescreen" then
        Patches.closeReaderToHomescreen(plugin, false)
    elseif action_id == "home" then
        Patches.closeReaderToLibrary(plugin)
    else
        Patches.closeReaderToLibrary(plugin)
        UIManager:scheduleIn(0.05, function()
            local fm_new = liveInstances()
            if not fm_new then return end
            local plugin_new = fm_new._simpleui_plugin or plugin
            plugin_new:_navigate(action_id, fm_new, _Config().loadTabConfig(), false)
        end)
    end
end

-- Runs `action_id` for a tap on the panel. Returns true when the menu stays
-- open (in-place actions) and false when the tap closes it.
local function runAction(touch_menu, action_id)
    local is_in_place = _QA().isInPlace(action_id)
    local stay_open   = is_in_place
        and not action_id:match("^custom_qa_%d+$")
        and action_id ~= "sui_win_settings"

    local fm, _reader, plugin = liveInstances()

    if stay_open then
        safeExecute(action_id, { plugin = plugin, fm = fm })
        touch_menu:updateItems()
        return true
    end

    UIManager:scheduleIn(0, function()
        local fm_live, reader, plugin_live = liveInstances()
        plugin_live = plugin_live or plugin
        if not plugin_live then
            safeExecute(action_id, { fm = fm })
            return
        end

        if reader then
            -- In-place actions run against the current UI (ReaderUI when no
            -- FileManager is live) and never navigate.
            if is_in_place then
                safeExecute(action_id, { plugin = plugin_live, fm = fm_live or reader })
            else
                runFromReader(plugin_live, action_id)
            end
            return
        end

        local fm_self = fm_live
        local stack = UI.getWindowStack()
        for i = #stack, 1, -1 do
            local w = stack[i].widget
            if w and w._navbar_injected and w.name ~= "homescreen" then
                fm_self = w
                break
            end
        end
        plugin_live:_navigate(action_id, fm_self, _Config().loadTabConfig(), false)
    end)
    return false
end

-- ---------------------------------------------------------------------------
-- Shared panel pieces
-- ---------------------------------------------------------------------------

-- Index of the first tab of `menu` whose `key` field equals `value`, or nil.
local function tabIndexBy(menu, key, value)
    for i, tab in ipairs(menu.tab_item_table) do
        if tab[key] == value then return i end
    end
end

local CLASSIC_BTN_DP = 60   -- classic layout button size

-- Face of the panel's text at `size`, in the font chosen for the bar's labels.
-- Returns the face and whether the text widget has to embolden it.
local function panelFace(size, bold)
    return SUIStyle.getTextFace(_Config().getChromeLabelStyle("quick_settings"), size, bold)
end

-- Font size of the panel's text: the style's `base` size with the label size
-- setting applied.
local function scaledFontSize(base)
    return math.max(6, math.floor(base * (getLabelScalePct() / 100)))
end

-- Font size of the button labels.
local function labelFontSize()
    return scaledFontSize(SUIStyle.FS_DETAIL)
end

-- Font size of the slider texts, one step above the button labels.
local function sliderFontSize()
    return scaledFontSize(SUIStyle.FS_BODY)
end

-- Cell spec of a button of `btn_size` pixels, built from the configured shape
-- and surface. With `label_w`, the button shows its label, following the
-- label settings, truncated to that many pixels.
local function buttonSpec(btn_size, label_w)
    local spec = {
        icon_sz    = _QARenderer().cellDims(btn_size).icon_sz,
        frame_sz   = btn_size,
        fixed_size = true,
        shape      = getShape(),
        surface    = Backdrop.resolve(buttonSurface(), Backdrop.STRENGTH_MAX),
        fgcolor    = SUIStyle.COLOR.text_primary,
        show_label = label_w ~= nil,
    }
    if label_w then
        local lbl_fs = labelFontSize()
        local lbl_face, lbl_bold = panelFace(lbl_fs)
        spec.lbl_sp   = Screen:scaleBySize(2)
        spec.lbl_h    = lbl_face.size
        spec.lbl_fs   = lbl_fs
        spec.lbl_face = lbl_face
        spec.lbl_bold = lbl_bold
        spec.lbl_w    = label_w
    end
    return spec
end

-- Returns makeButton(action_id) → (group, frame) for the action buttons of
-- `btn_size` pixels (see buttonSpec).
local function buttonFactory(btn_size, label_w)
    local spec = buttonSpec(btn_size, label_w)
    return function(action_id)
        return _QARenderer().buildCell(action_id, spec)
    end
end

-- Tap targets of a panel: `buttons` are { widget, callback } entries hit-tested
-- against the gesture, `taps` the handlers of the slider bars that rely on the
-- panel to route their taps, `focus_rows` the rows of step controls that join
-- the menu's focus layout.
local function newRefs()
    return { buttons = {}, taps = {}, focus_rows = {} }
end

-- Builds one button per configured slot, in slot order, and registers each
-- tap target in refs.buttons. Returns the button groups and the focus row
-- the buttons form in the menu's focus layout (see refs.focus_rows).
local function buildActionWidgets(touch_menu, refs, makeButton)
    local widgets, focus_row = {}, {}
    for _i, action_id in ipairs(getSlots()) do
        local group, frame = makeButton(action_id)
        table.insert(refs.buttons, {
            widget   = frame,
            callback = function() return runAction(touch_menu, action_id) end,
        })
        widgets[#widgets + 1] = group
        focus_row[#focus_row + 1] = UI.makeFocusable(frame)
    end
    if #focus_row > 0 then table.insert(refs.focus_rows, focus_row) end
    return widgets, focus_row
end

-- Row spreading the button `cells` over `width`: the first button starts at the
-- left end and the last one ends at the right end. A cell wider than its
-- `btn_size` button, because of its label, overhangs the ends.
local function spreadRow(cells, btn_size, width)
    local row      = HorizontalGroup:new{ align = "center" }
    local gaps     = #cells - 1
    local overhang = cells[1]:getSize().w - btn_size
    local free     = width - #cells * btn_size
    local step     = gaps > 0 and math.floor(free / gaps) or 0
    local extra    = gaps > 0 and free - step * gaps or 0 -- one more pixel in the first gaps
    for i, cell in ipairs(cells) do
        if i > 1 then
            local gap = step + (i - 1 <= extra and 1 or 0) - overhang
            table.insert(row, HorizontalSpan:new{ width = math.max(0, gap) })
        end
        table.insert(row, cell)
    end
    return row
end

-- Wraps `panel` in the container the touch menu paints: sized to the panel,
-- opening the bar settings on long tap.
local function wrapPanel(touch_menu, panel, panel_w)
    local ic = InputContainer:new{
        dimen = Geom:new{ w = panel_w, h = panel:getSize().h },
        [1]   = panel,
    }

    ic.ges_events = {
        HoldPanel = {
            GestureRange:new{ ges = "hold", range = function() return ic.dimen end },
        },
    }
    function ic:onHoldPanel()
        if not SUISettings:nilOrTrue(SETTINGS_ON_HOLD_KEY) then
            return false
        end
        if _showQSBarSettingsWindow then
            _showQSBarSettingsWindow(touch_menu)
        end
        return true
    end

    return ic
end

-- ---------------------------------------------------------------------------
-- Sliders
-- A slider adjusts one channel of the light: the frontlight or its warmth. A
-- channel describes its range, how to read and write its value, and the bar
-- it uses in the Classic style. In the Minimal style every channel uses the
-- shared slider instead, with plain text controls. A bar is built by a
-- function returning
--   { widget, show(value), tap(ges)? }
-- where `show` moves the bar to a value and `tap` (optional) handles a tap
-- the bar does not handle itself.
-- ---------------------------------------------------------------------------

-- Segments a bar shows for `channel` (at most 25) and the value distance
-- between two of them.
local function barSegments(channel)
    local steps  = channel.max - channel.min + 1
    local stride = math.ceil(steps / 25)
    local count  = math.ceil(steps / stride)
    if (count - 1) * stride < channel.max - channel.min then
        count = count + 1
    end
    return math.min(count, steps), stride
end

-- Bar builders. `ctx` carries `commit(value, shown, dragging)`, which applies
-- a value picked on the bar (`shown`: the bar already displays it), `release()`
-- for the end of a drag, and the `show_parent` of the menu.

-- Progress bar with tick marks; taps on it are routed by the panel.
local function progressBar(channel, width, height, value, ctx)
    local ProgressWidget = require("ui/widget/progresswidget")
    local count, stride = barSegments(channel)
    local ticks = {}
    for i = 1, count - 2 do ticks[i] = i * stride end
    local widget = ProgressWidget:new{
        width      = width,
        height     = height,
        percentage = value / channel.max,
        ticks      = ticks,
        tick_width = Screen:scaleBySize(0.5),
        last       = channel.max,
    }
    return {
        widget = widget,
        show   = function(v) widget:setPercentage(v / channel.max) end,
        tap    = function(ges)
            if not (widget.dimen and ges.pos:intersectWith(widget.dimen)) then return false end
            local fraction = widget:getPercentageFromPosition(ges.pos)
            if not fraction then return false end
            ctx.commit(Math.round(fraction * channel.max))
            return true
        end,
    }
end

-- Row of step buttons; it handles its own taps.
local function stepBar(channel, width, height, value, ctx)
    local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
    local count, stride = barSegments(channel)
    local position = math.floor(value / stride)
    local widget = ButtonProgressWidget:new{
        width            = width,
        height           = height,
        font_size        = SUIStyle.FS_SUBTITLE,
        padding          = 0,
        thin_grey_style  = false,
        num_buttons      = count - 1,
        position         = position,
        default_position = position,
        show_parent      = ctx.show_parent,
        enabled          = true,
        callback         = function(i)
            ctx.commit(math.min(Math.round(i * stride), channel.max), true)
        end,
    }
    return {
        widget = widget,
        show   = function(v) widget:setPosition(math.floor(v / stride), widget.default_position) end,
    }
end

-- Slider with a knob that carries the value; it handles its own taps and
-- drags.
local function sliderBar(channel, width, height, value, ctx)
    local face, bold = panelFace(sliderFontSize())
    local widget = _SUISlider():new{
        width      = width,
        height     = height,
        min        = channel.min,
        max        = channel.max,
        value      = value,
        face       = face,
        bold       = bold,
        on_change  = function(v, dragging) ctx.commit(v, true, dragging) end,
        on_release = ctx.release,
    }
    return {
        widget = widget,
        show   = function(v) widget:setValue(v) end,
    }
end

local function frontlightChannel()
    local powerd = Device:getPowerDevice()
    return {
        label = _("Frontlight"),
        min   = powerd.fl_min,
        max   = powerd.fl_max,
        bar   = progressBar,
        read  = function() return powerd:frontlightIntensity() end,
        write = function(v) powerd:setIntensity(v) end,
    }
end

local function warmthChannel()
    local powerd = Device:getPowerDevice()
    return {
        label = _("Warmth"),
        min   = powerd.fl_warmth_min,
        max   = powerd.fl_warmth_max,
        bar   = stepBar,
        read  = function() return powerd:toNativeWarmth(powerd:frontlightWarmth()) end,
        write = function(v) powerd:setWarmth(powerd:fromNativeWarmth(v)) end,
    }
end

-- Step controls of a slider row, by style. A builder takes the `show_parent`
-- of the menu and the `actions` of the three controls (minus, plus, top) and
-- returns them with the `gap` kept between the bar and its neighbours, the
-- `top_gap` before the top control, the `height` of the row and, when the
-- style draws its own bar, the `bar` builder. A style without a top control
-- leaves it out; one whose bar shows the value sets `value_on_bar`.
local CONTROLS = {
    -- Framed buttons.
    [SLIDER_STYLE.CLASSIC] = function(show_parent, actions)
        local Button  = require("ui/widget/button")
        local small_w = Screen:scaleBySize(40)
        local function button(text, width, callback)
            return Button:new{
                text        = text,
                width       = width,
                show_parent = show_parent,
                callback    = callback,
            }
        end
        local minus = button("−", small_w, actions.minus)
        return {
            minus   = minus,
            plus    = button("＋", small_w, actions.plus),
            top     = button(_("Max"), Screen:scaleBySize(50), actions.top),
            gap     = Screen:scaleBySize(4),
            top_gap = Screen:scaleBySize(4),
            height  = minus:getSize().h,
        }
    end,
    -- Drawn symbols around a bar whose knob carries the value.
    [SLIDER_STYLE.MINIMAL] = function(_show_parent, actions)
        local controls = _SUISlider().stepControls(actions)
        controls.bar = sliderBar
        return controls
    end,
}

-- A left-aligned caption, a bold name followed by its value in regular weight
-- (or the name alone when the bar shows the value), above a row made of a "−"
-- control, the bar, a "+" control and, in most styles, a "Max" control, `width`
-- wide.
-- Registers the bar's own tap handler, if any, and the row of its step controls
-- in `refs`.
local function buildSlider(touch_menu, width, refs, channel)
    local show_parent = touch_menu.show_parent
    local current     = channel.read()

    local caption, bar -- assigned below, used by apply

    -- Applies `value` to the light and to the widgets. `shown`: the bar already
    -- displays the value. `dragging`: the value comes from a drag, so the
    -- caption repaints on its own instead of the whole menu.
    local function apply(value, shown, dragging)
        value = math.max(channel.min, math.min(channel.max, value))
        if value ~= channel.min and value == current then return end
        channel.write(value)
        current = channel.read()
        if not shown then bar.show(current) end
        caption:setValue(tostring(current))
        if dragging then
            caption:refresh("fast")
        else
            UIManager:setDirty(show_parent, "ui")
        end
    end

    local controls = CONTROLS[getSliderStyle()](show_parent, {
        minus = function() apply(current - 1) end,
        plus  = function() apply(current + 1) end,
        top   = function() apply(channel.max) end,
    })

    local font_size = sliderFontSize()
    local name_face, name_bold   = panelFace(font_size, true)
    local value_face, value_bold = panelFace(font_size)
    caption = _SUISlider().Caption:new{
        name        = channel.label,
        value       = tostring(current),
        width       = width,
        gap         = Screen:scaleBySize(6),
        name_face   = name_face,
        name_bold   = name_bold,
        value_face  = not controls.value_on_bar and value_face or nil,
        value_bold  = value_bold,
    }

    bar = (controls.bar or channel.bar)(channel, _SUISlider().barWidth(width, controls), controls.height, current, {
        commit      = apply,
        release     = function() caption:refresh() end,
        show_parent = show_parent,
    })
    if bar.tap then table.insert(refs.taps, bar.tap) end

    table.insert(refs.focus_rows, { controls.minus, controls.plus, controls.top })
    local row = _SUISlider().row(controls, bar.widget)
    return VerticalGroup:new{
        align = "left",
        caption,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        row,
    }
end

local SLIDER_GAP_DP = 12 -- between the frontlight and the warmth slider

-- The frontlight and warmth sliders, `width` wide, one above the other; nil
-- when none of them is shown.
local function buildSliders(touch_menu, refs, width)
    local group = VerticalGroup:new{ align = "center" }
    local function add(channel)
        if #group > 0 then
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(SLIDER_GAP_DP) })
        end
        table.insert(group, buildSlider(touch_menu, width, refs, channel))
    end
    if showFrontlight() and Device:hasFrontlight() then add(frontlightChannel()) end
    if showWarmth() and Device:hasNaturalLight() then add(warmthChannel()) end
    return #group > 0 and group or nil
end

-- ---------------------------------------------------------------------------
-- Classic panel
-- Action buttons spread across the panel width, followed by the optional
-- frontlight and warmth sliders. Returns the panel widget plus a refs table
-- used by the gesture handler to dispatch taps.
-- touch_menu is the live TouchMenu instance (for width / show_parent).
-- ---------------------------------------------------------------------------

-- Widest label a classic button can hold: the distance between the centres of
-- neighbouring buttons, less a margin, so labels never touch. The labels of
-- the end buttons overhang the row, so the width is capped to keep them inside
-- the panel padding. Never narrower than the button.
local function classicLabelWidth(btn_size, count, inner_w, padding)
    local QARenderer = _QARenderer()
    local pitch      = count > 1 and (inner_w - btn_size) / (count - 1) or inner_w
    local width      = math.min(QARenderer.tabLabelMaxWidth(pitch),
                                QARenderer.tabLabelMaxWidth(btn_size + 2 * padding))
    return math.max(btn_size, math.floor(width))
end

local function buildClassicPanel(touch_menu)
    local panel_w  = touch_menu.item_width
    local padding  = Screen:scaleBySize(28)
    local inner_w  = panel_w - padding * 2
    local refs     = newRefs()

    -- ── Action-button row ────────────────────────────────────────────────────
    local btn_size = Screen:scaleBySize(CLASSIC_BTN_DP)
    local label_w  = showLabels() and classicLabelWidth(btn_size, #getSlots(), inner_w, padding) or nil
    local widgets  = buildActionWidgets(touch_menu, refs, buttonFactory(btn_size, label_w))
    local btn_row
    if #widgets > 0 then
        btn_row = spreadRow(widgets, btn_size, inner_w)
    else
        btn_row = HorizontalGroup:new{
            align = "center",
            TextWidget:new{
                text    = _("No actions configured.\nGo to Bars → Quick Settings Bar."),
                face    = Font:getFace("cfont"),
                fgcolor = SUIStyle.COLOR.text_primary,
            },
        }
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

    local critter = _CritterRow().build(touch_menu, refs, inner_w)
    if critter then
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_w, h = critter:getSize().h },
            critter,
        })
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end

    local sliders = buildSliders(touch_menu, refs, inner_w)
    if sliders then
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(panel, CenterContainer:new{
            dimen = Geom:new{ w = panel_w, h = sliders:getSize().h },
            sliders,
        })
    end

    table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(14) })

    return wrapPanel(touch_menu, panel, panel_w), refs
end

-- ---------------------------------------------------------------------------
-- Book layout (reader only)
-- The open book's cover on the left; on the right its configured items (title,
-- author, statistics, progress bar), above a row with the action buttons and
-- the Exit button. The action buttons never show labels in this layout.
-- The button size sets the width of the title, author and progress bar (the
-- width of the action slots) and the height of the row, so the panel follows it.
-- Geometry is relative to the panel width and the text is sized from the
-- cover, so the two stay balanced on any screen.
-- ---------------------------------------------------------------------------

local BOOK_PAD_PCT       = 0.02    -- outer padding of the panel
local BOOK_COVER_W_PCT   = 0.207   -- cover width
local BOOK_GAP_PCT       = 0.042   -- cover ↔ text gap
local BOOK_TITLE_FS_PCT  = 0.11    -- title font size, relative to the cover height
local BOOK_BODY_FS_PCT   = 0.085   -- author and progress font size, relative to the cover height
local BOOK_TEXT_GAP_PCT  = 0.03    -- between title, author and progress line, relative to the cover height
local BOOK_BLOCK_GAP_PCT = 0.09    -- around the progress bar and above the action row, relative to the cover height
local BOOK_BTN_PCT       = 0.072   -- button size
local BOOK_BTN_GAP_PCT   = 0.014   -- between the action buttons
local BOOK_TITLE_LINES   = 2
local BOOK_EXIT_GAP_PCT  = 0.25    -- Exit icon ↔ text gap, relative to the button size
local BOOK_EXIT_PAD_PCT  = 0.25    -- Exit horizontal padding, relative to the button size
local BOOK_EXIT_TAIL_PCT = 0.12    -- Exit extra space after the text, relative to the button size

-- Pixel metrics of the Book layout for a panel `panel_w` wide.
local function bookMetrics(panel_w)
    local dims    = _SH().getDims(1.0, 1.0)
    local pad     = math.floor(panel_w * BOOK_PAD_PCT)
    local gap     = math.floor(panel_w * BOOK_GAP_PCT)
    local inner_w = panel_w - pad * 2
    local cover_w = math.floor(panel_w * BOOK_COVER_W_PCT)
    local cover_h = math.floor(cover_w * dims.COVER_H / dims.COVER_W)
    local text_w  = inner_w - cover_w - gap
    local btn     = math.floor(panel_w * BOOK_BTN_PCT)
    local btn_gap = math.floor(panel_w * BOOK_BTN_GAP_PCT)
    -- Width of the action slots, side by side.
    local slots_w = MAX_SLOTS * btn + (MAX_SLOTS - 1) * btn_gap
    return {
        pad        = pad,
        gap        = gap,
        inner_w    = inner_w,
        cover_w    = cover_w,
        cover_h    = cover_h,
        text_w     = text_w,
        text_gap   = math.floor(cover_h * BOOK_TEXT_GAP_PCT),
        block_gap  = math.floor(cover_h * BOOK_BLOCK_GAP_PCT),
        title_face = SUIStyle.pxFace(SUIStyle.FACE_BOLD, cover_h * BOOK_TITLE_FS_PCT),
        body_face  = SUIStyle.pxFace(SUIStyle.FACE_REGULAR, cover_h * BOOK_BODY_FS_PCT),
        info_w     = slots_w,
        stats_w    = text_w,
        bar_w      = slots_w,
        bar_h      = SUIStyle.PROGRESS_BAR_H,
        btn_size   = btn,
        btn_gap    = btn_gap,
        exit_gap   = math.floor(btn * BOOK_EXIT_GAP_PCT),
        exit_pad   = math.floor(btn * BOOK_EXIT_PAD_PCT),
        exit_tail  = math.floor(btn * BOOK_EXIT_TAIL_PCT),
    }
end

-- Reading time for `pages` as the statistics plugin formats it; nil when the
-- plugin is off or has no average yet. getTimeForPages only exists since
-- KOReader v2025.10: older versions get the same computation from avg_time.
local function timeForPages(stats, pages)
    if not stats then return nil end
    if stats.getTimeForPages then return stats:getTimeForPages(pages) end
    local avg = stats.avg_time
    if not (stats.settings and stats.settings.is_enabled) or not avg or avg ~= avg then
        return nil
    end
    local duration_format = G_reader_settings:readSetting("duration_format", "classic")
    return require("datetime").secondsToClockDuration(duration_format, pages * avg, true)
end

-- Reading progress of the open document: the current page and page count
-- (following the page map when the book has one), the progress as a 0–1
-- fraction, and two functions evaluated on demand: `time_left()`, the
-- estimated time left (nil when reading statistics cannot estimate it), and
-- `book()`, the book's totals from the statistics database (nil when
-- unavailable), read once.
local function readingProgress(ui)
    local doc    = ui.document
    local pageno = ui:getCurrentPage()
    local page, pages
    if doc:hasHiddenFlows() then
        page  = doc:getPageNumberInFlow(pageno)
        pages = doc:getTotalPagesInFlow(doc:getPageFlow(pageno))
    else
        page, pages = pageno, doc:getPageCount()
    end
    local fraction = page / pages

    local pagemap = ui.pagemap
    if pagemap and pagemap:wantsPageLabels() then
        page  = pagemap:getCurrentPageLabel(true)
        pages = pagemap:getLastPageLabel(true)
    end

    local book, book_read
    return {
        page      = page,
        pages     = pages,
        fraction  = fraction,
        time_left = function()
            return timeForPages(ui.statistics, doc:getTotalPagesLeft(pageno))
        end,
        book      = function()
            if not book_read then
                book_read = true
                local md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
                book = BookStats.fetch(md5, nil, nil, true)
            end
            return book
        end,
    }
end

-- Text of each statistic for a `readingProgress` state; nil when there is
-- nothing to show for it.
local STAT_TEXT = {
    page = function(progress)
        return BookStats.text.page(progress.page, progress.pages)
    end,
    percent = function(progress)
        return BookStats.text.percent(progress.fraction)
    end,
    book_days = function(progress)
        return BookStats.textFor("book_days", progress.book())
    end,
    book_time = function(progress)
        return BookStats.textFor("book_time", progress.book())
    end,
    book_remaining = function(progress)
        local time_left = progress.time_left()
        return time_left and BookStats.text.left(time_left) or nil
    end,
}

-- The visible statistics in the configured order, joined into one line; nil
-- when none has anything to show.
local function statsLine(progress)
    local line = BookStats.line(getStatOrder(), isStatVisible, function(id)
        return STAT_TEXT[id](progress)
    end)
    return line ~= "" and line or nil
end

-- Wraps `widget` in a tap target registered in refs.buttons.
local function tapArea(refs, widget, callback)
    local area = FrameContainer:new{
        bordersize = 0,
        margin     = 0,
        padding    = 0,
        widget,
    }
    table.insert(refs.buttons, { widget = area, callback = callback })
    return area
end

-- Widget builders of the Book layout's text column, by item id. Each returns
-- the widget of the item, or nil when the book has nothing to show for it.
-- `progress()` returns the reading progress of the book (see readingProgress).
local BOOK_ITEM_BUILDERS = {
    title = function(ui, m)
        return TextBoxWidget:new{
            text                          = ui.doc_props.display_title or "",
            face                          = m.title_face,
            width                         = m.info_w,
            height                        = math.floor(1.3 * m.title_face.size + 0.5) * BOOK_TITLE_LINES,
            height_adjust                 = true,
            height_overflow_show_ellipsis = true,
        }
    end,
    author = function(ui, m)
        local authors = ui.doc_props.authors
        authors = authors and authors:gsub("%s*\r?\n%s*", ", ")
        if authors and authors ~= "" then
            return TextWidget:new{ text = authors, face = m.body_face, max_width = m.info_w }
        end
    end,
    stats = function(_ui, m, progress)
        local line = statsLine(progress())
        if line then
            return TextWidget:new{ text = line, face = m.body_face, max_width = m.stats_w }
        end
    end,
    progress = function(_ui, m, progress)
        return UI.progressBar(m.bar_w, progress().fraction, m.bar_h, SUIStyle.accent())
    end,
}

-- The visible items of the text column in the configured order; nil when
-- none is visible. The reading progress is only worked out when an item
-- needs it.
local function buildBookInfo(ui, m)
    local state
    local function progress()
        state = state or readingProgress(ui)
        return state
    end

    local info = VerticalGroup:new{ align = "left" }
    local previous
    for _i, id in ipairs(getBookItemOrder()) do
        local widget = isBookItemVisible(id) and BOOK_ITEM_BUILDERS[id](ui, m, progress)
        if widget then
            if previous then
                local around_bar = id == "progress" or previous == "progress"
                table.insert(info, VerticalSpan:new{
                    width = around_bar and m.block_gap or m.text_gap,
                })
            end
            table.insert(info, widget)
            previous = id
        end
    end
    return previous and info or nil
end

-- Exit button: the icon of the action buttons followed by the text, in a frame
-- of their shape. The extra space after the text balances the icon's inner
-- margin. It activates the reader menu's native "file browser" tab,
-- the single path that honours the configured book-close destination, also
-- when the user has hidden that tab from the menu. nil when the menu has no
-- such tab.
local function buildBookExitButton(touch_menu, refs, m)
    local tab_index = tabIndexBy(touch_menu, "id", "filemanager")
    local hidden_tab = not tab_index
        and require("features/sui_menu_hide").findHiddenTab(touch_menu.tab_item_table, "filemanager")
    if not tab_index and not hidden_tab then return nil end

    local spec  = buttonSpec(m.btn_size)
    local label = _("Exit")
    local fg, on_surface = _QARenderer().onSurfaceColor(spec)
    local content = HorizontalGroup:new{
        align = "center",
        _QARenderer().buildIcon({
            icon  = SUIStyle.resolveIcon(EXIT_ICON_SLOT),
            label = label,
        }, spec.icon_sz, fg, { tint = on_surface }),
        HorizontalSpan:new{ width = m.exit_gap },
        UI.makeColoredText{ text = label, face = m.body_face, fgcolor = on_surface and fg or nil },
        HorizontalSpan:new{ width = m.exit_tail },
    }
    local frame = _QARenderer().buildFrame(content, m.btn_size, {
        width      = content:getSize().w + m.exit_pad * 2,
        fixed_size = true,
        shape      = spec.shape,
        surface    = spec.surface,
    })
    table.insert(refs.buttons, {
        widget   = frame,
        callback = function()
            if tab_index then
                touch_menu:switchMenuTab(tab_index)
            else
                if touch_menu.touch_menu_callback then touch_menu.touch_menu_callback() end
                hidden_tab.callback()
            end
            return true -- the tab callback already closed the menu
        end,
    })
    return frame
end

-- Action buttons on the left of the text column, with the Exit button at its
-- right end. nil when the row would be empty.
local function buildBookActionRow(touch_menu, refs, m)
    local buttons = HorizontalGroup:new{ align = "top" }
    local groups, focus_row = buildActionWidgets(touch_menu, refs, buttonFactory(m.btn_size))
    for i, group in ipairs(groups) do
        if i > 1 then table.insert(buttons, HorizontalSpan:new{ width = m.btn_gap }) end
        table.insert(buttons, group)
    end
    local exit = buildBookExitButton(touch_menu, refs, m)
    if #buttons == 0 and not exit then return nil end
    if exit then
        -- Exit joins the buttons' focus row, creating it when there are no buttons.
        if #focus_row == 0 then table.insert(refs.focus_rows, focus_row) end
        focus_row[#focus_row + 1] = UI.makeFocusable(exit)
    end

    local row = HorizontalGroup:new{ align = "center", buttons }
    if exit then
        table.insert(row, HorizontalSpan:new{
            width = math.max(0, m.text_w - buttons:getSize().w - exit:getSize().w),
        })
        table.insert(row, exit)
    end
    return row
end

local function buildBookPanel(touch_menu, ui)
    local panel_w = touch_menu.item_width
    local m       = bookMetrics(panel_w)
    local refs    = newRefs()
    local SH      = _SH()
    local props   = ui.doc_props

    local function showBookStatus()
        UIManager:scheduleIn(0, function() ui:handleEvent(Event:new("ShowBookStatus")) end)
    end

    local cover = SH.getBookCover(ui.document.file, m.cover_w, m.cover_h)
                  or SH.coverPlaceholder(props.display_title or "", props.authors, m.cover_w, m.cover_h)
    local column = VerticalGroup:new{ align = "left" }
    local info = buildBookInfo(ui, m)
    if info then
        table.insert(column, tapArea(refs, info, showBookStatus))
    end
    local actions = buildBookActionRow(touch_menu, refs, m)
    if actions then
        if info then table.insert(column, VerticalSpan:new{ width = m.block_gap }) end
        table.insert(column, actions)
    end

    local body = HorizontalGroup:new{
        align = "center",
        tapArea(refs, cover, showBookStatus),
        HorizontalSpan:new{ width = m.gap },
        column,
    }
    local content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = m.pad },
        LeftContainer:new{ dimen = Geom:new{ w = m.inner_w, h = body:getSize().h }, body },
    }
    local critter = _CritterRow().build(touch_menu, refs, m.inner_w)
    if critter then
        table.insert(content, VerticalSpan:new{ width = m.block_gap })
        table.insert(content, LeftContainer:new{
            dimen = Geom:new{ w = m.inner_w, h = critter:getSize().h },
            critter,
        })
    end
    local sliders = showBookSliders() and buildSliders(touch_menu, refs, m.inner_w)
    if sliders then
        table.insert(content, VerticalSpan:new{ width = m.block_gap })
        table.insert(content, LeftContainer:new{
            dimen = Geom:new{ w = m.inner_w, h = sliders:getSize().h },
            sliders,
        })
    end
    table.insert(content, VerticalSpan:new{ width = m.pad })
    local panel = CenterContainer:new{
        dimen = Geom:new{ w = panel_w, h = content:getSize().h },
        content,
    }
    return wrapPanel(touch_menu, panel, panel_w), refs
end

-- ---------------------------------------------------------------------------
-- Layout resolution and panel builder
-- ---------------------------------------------------------------------------

-- Layout of the panel in `menu`, plus the reader UI for the Book layout.
-- Book applies only to the reader menu of an open document with that layout
-- selected; every other menu uses the classic layout.
local function resolveLayout(menu)
    if getReaderLayout() == LAYOUT.BOOK then
        local RUI = package.loaded["apps/reader/readerui"]
        local ui  = RUI and RUI.instance
        if ui and ui.document and ui.doc_props
                and ui.menu and ui.menu.tab_item_table == menu.tab_item_table then
            return LAYOUT.BOOK, ui
        end
    end
    return LAYOUT.CLASSIC
end

-- Returns the panel widget plus the refs table used by the gesture handler.
local function buildPanel(touch_menu)
    local layout, ui = resolveLayout(touch_menu)
    if layout == LAYOUT.BOOK then
        return buildBookPanel(touch_menu, ui)
    end
    return buildClassicPanel(touch_menu)
end

-- ---------------------------------------------------------------------------
-- Gesture handler — dispatch taps/swipes that land on a button circle
-- ---------------------------------------------------------------------------

local function handleGesture(touch_menu, ges)
    local refs = touch_menu._sui_qs_refs
    if not refs then return false end

    -- Slider bars that rely on the panel for their taps.
    for _i, tap in ipairs(refs.taps) do
        if tap(ges) then return true, true end
    end

    -- Hit-test action buttons.
    for _i, ref in ipairs(refs.buttons) do
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
            _CritterRow().release(self)
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
        for _i, row in ipairs(refs.focus_rows) do
            table.insert(self.layout, row)
        end

        -- Native page handlers expect numeric pagination state. This panel is
        -- a single fixed page, so keep page-key and swipe events safe.
        self.page = 1
        self.page_num = 1

        table.insert(self.item_group, panel)

        -- Footer (no pagination)
        table.insert(self.item_group, self.footer_top_margin)
        table.insert(self.item_group, self.footer)
        self.page_info_text:setText("")
        self.page_info_left_chev:showHide(false)
        self.page_info_right_chev:showHide(false)

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
-- Panel tab (shared by the reader and file-browser menus)
-- ---------------------------------------------------------------------------
-- The panel tab entry has _sui_qs_panel=true on the item_table so that
-- the patched updateItems knows to switch to panel mode.

local _panel_tab = {
    id       = "_sui_qs_panel",  -- lets sui_style.lua's icon-slot system (Style ▸ Icons ▸ Tab Bar) reference this tab
    icon     = "simpleui_settings",
    remember = false,
    -- _sui_qs_panel flag consumed by the patched updateItems
    _sui_qs_panel = true,
}

--- Applies the user's stored icon override (Style ▸ Icons ▸ Tab Bar ▸
--- "SimpleUI Quick Settings") to the shared panel-tab descriptor, or falls
--- back to the default "simpleui_settings" icon. `_panel_tab` is the exact
--- same table object inserted by reference into both FileManagerMenu's and
--- ReaderMenu's tab_item_table, so mutating its `.icon` field here updates
--- the tab everywhere it appears, independent of injection/patch ordering.
function QSBar.refreshPanelTabIcon()
    local ok_ss, SUIStyle = pcall(require, "features/sui_style")
    local override_path = ok_ss and SUIStyle and SUIStyle.getIcon("sui_tab_qs_panel")
    local name = nil
    if override_path and ok_ss and SUIStyle.registerTabIconName then
        name = SUIStyle.registerTabIconName("sui_tab_qs_panel", override_path)
    end
    _panel_tab.icon = name or "simpleui_settings"
end

--- Index of the panel tab in `menu.tab_item_table`, or nil when absent.
local function panelTabIndex(menu)
    return tabIndexBy(menu, "_sui_qs_panel", true)
end

--- Inserts the panel as the first tab. TouchMenu only auto-activates a tab
--- with `remember = false` at index 1, so the panel must stay first to be
--- usable as the opening tab.
local function injectPanelTab(menu)
    if not isEnabled() or type(menu.tab_item_table) ~= "table" then return end
    if panelTabIndex(menu) then return end
    table.insert(menu.tab_item_table, 1, _panel_tab)
end

--- Opens the menu on the panel when the user enabled that for `target`.
local function resolveOpeningTab(menu, target, tab_index)
    if not (isEnabled() and opensOnPanel(target)) then
        return tab_index
    end
    return panelTabIndex(menu) or tab_index
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- QSBar.install(plugin)
-- Called once from SimpleUIPlugin:onInit (via the existing do-block in main.lua).
function QSBar.install()
    if not isEnabled() then return end

    -- Apply any stored icon override for the panel tab up front, so it's
    -- already correct the first time the tab is injected.
    pcall(QSBar.refreshPanelTabIcon)

    -- 0. Make the panel tab's "simpleui_settings" icon resolve by name.
    do
        local Registry  = require("infra/sui_icon_registry")
        local icons_dir = require("infra/sui_paths").getPluginDirNoSlash() .. "/icons"
        Registry.addDir(icons_dir)
        Registry.register("simpleui_settings", icons_dir .. "/settings.svg")
    end

    -- 1. Patch TouchMenu methods.
    patchTouchMenu()

    -- 2. Register the panel tab step for the reader and file-browser menus.
    MenuHooks.register{
        id      = "quick_settings_panel",
        order   = MenuHooks.ORDER.PANEL_TAB,
        prepare = injectPanelTab,
        resolve = resolveOpeningTab,
    }
end

-- QSBar.uninstall()
-- Called from SimpleUIPlugin:onTeardown.
function QSBar.uninstall()
    unpatchTouchMenu()
end

_showQSBarSettingsWindow = function(touch_menu)
    local SUIWindow = require("engines/sui_window")
    
    local function buildRoot(ctx)
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = QSBar.makeMenuItems(ctx_menu),
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            push_stack     = function(id, params)
                if type(id) == "string" then ctx.push(id, params) else ctx.push("nested_menu", params) end
            end,
            on_close       = function() end,
        }
    end

    local win = SUIWindow:new{
        name           = "sui_win_context",
        title          = SUIWindow.makeSettingsTitle(_("Quick Settings Bar")),
        screens        = SUIWindow.makeSettingsScreens(buildRoot),
        navpager_mode  = _Config().isNavpagerEnabled(),
        position       = "bottom",
        has_settings_btn = true,
    }
    -- Use the menu's own close path (same one onTapCloseAllMenus/onSwipe use
    -- above), not a raw UIManager:close(). touch_menu is the shared system
    -- TouchMenu (FileManagerMenu/ReaderMenu's own menu, not something this
    -- file owns), which self-reschedules its footer clock/battery refresh
    -- timer for as long as it believes it's open. That timer is only
    -- cancelled inside the menu's own onClose()/onCloseWidget(); a raw
    -- UIManager:close() skips it, so it keeps firing against the
    -- already-torn-down widget and can re-dirty it well after this function
    -- returns, repainting a widget tree whose icons were already freed by
    -- the CloseWidget cascade.
    touch_menu:onClose()
    win:show()
end

-- Rebuilds the panel of the open file browser and reader menus.
local function rebuildOpenMenus()
    local function rebuild(menu)
        if not menu then return end
        menu.is_fresh = true
        if menu.item_table and menu.item_table._sui_qs_panel then
            pcall(function() menu:updateItems() end)
        end
    end

    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance then rebuild(FM.instance.menu) end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then rebuild(RUI.instance.menu) end
end

-- Every action that can be placed on the bar, sorted by label.
local function actionPool()
    local QA, pool = _QA(), {}
    for _i, id in ipairs(QA.allIds()) do
        pool[#pool + 1] = { id = id, label = QA.getEntry(id).label }
    end
    for _i, id in ipairs(QA.getCustomQAList()) do
        pool[#pool + 1] = { id = id, label = QA.getEntry(id).label }
    end
    table.sort(pool, function(a, b) return a.label:lower() < b.label:lower() end)
    return pool
end

-- Master row: enables or disables the whole bar, after a restart.
local function makeEnableItem(ctx_menu)
    return {
        text           = _("Enable Quick Settings Bar"),
        checked_func   = isEnabled,
        keep_menu_open = true,
        separator      = true,
        callback       = function()
            local on  = isEnabled()
            SUISettings:saveSetting(ENABLED_KEY, not on)
            require("features/dialogs/sui_dialogs").askRestart{
                text = string.format(
                    _("The Quick Settings Bar will be %s after restart.\n\nRestart now?"),
                    on and _("disabled") or _("enabled")
                ),
            }
        end,
    }
end

-- "Quick Actions" row: the action slots of the bar, picked from every action.
local function makeQuickActionsItem(ctx_menu)
    return require("features/sui_arrange").makeListItem{
        ctx_menu = ctx_menu,
        title    = _("Quick Actions"),
        labels   = {
            action  = _("Arrange Quick Settings"),
            empty   = _("No actions active yet."),
            too_few = _("Add at least 2 actions to arrange."),
            add     = _("Add Action"),
            full    = function(max)
                return string.format(N_("Maximum of %d slot reached. Remove one first.",
                    "Maximum of %d slots reached. Remove one first.", max), max)
            end,
        },
        max    = MAX_SLOTS,
        pool   = actionPool,
        label  = labelFor,
        getIds = getSlots,
        setIds = function(ids)
            saveSlots(ids)
            rebuildOpenMenus()
        end,
    }
end

-- QSBar.makeMenuItems(ctx_menu) → KOReader item table
-- Returned by makeBarsMenuItems in sui_menu.lua.
function QSBar.makeMenuItems(ctx_menu)
    local Config = _Config()

    local function refresh()
        if ctx_menu and type(ctx_menu.refresh) == "function" then
            ctx_menu.refresh()
        end
        rebuildOpenMenus()
    end

    local function toggleRow(text, is_on, set_on, extra)
        local row = {
            text           = text,
            checked_func   = is_on,
            keep_menu_open = true,
            callback       = function()
                set_on(not is_on())
                refresh()
            end,
        }
        for k, v in pairs(extra or {}) do row[k] = v end
        return row
    end

    local function saveToggle(key)
        return function(on) SUISettings:saveSetting(key, on) end
    end

    -- Items: the actions of the bar, and the text items of the Book layout.
    local is_book_layout = function() return getReaderLayout() == LAYOUT.BOOK end
    local stats_list = Config.makeOrderedItems{
        ids          = STAT_ITEMS,
        order_key    = STAT_ORDER_KEY,
        label        = BookStats.statLabel,
        is_visible   = isStatVisible,
        set_visible  = setStatVisible,
        refresh      = refresh,
        ctx          = ctx_menu,
        title        = _("Statistics"),
        text         = _("Arrange Statistics"),
        empty_text   = _("No statistics selected."),
        enabled_func = is_book_layout,
    }
    local book_list = Config.makeOrderedItems{
        ids          = BOOK_ITEMS,
        order_key    = BOOK_ORDER_KEY,
        label        = bookItemLabel,
        is_visible   = isBookItemVisible,
        set_visible  = setBookItemVisible,
        refresh      = refresh,
        ctx          = ctx_menu,
        title        = _("Book Details"),
        text         = _("Arrange Book Details"),
        enabled_func = is_book_layout,
        nested       = { stats = stats_list },
    }

    -- The SUI menu reaches the statistics from the Book Details screen.
    local item_rows = { makeQuickActionsItem(ctx_menu) }
    local lists = { book_list }
    if not (ctx_menu and ctx_menu.is_sui) then lists[#lists + 1] = stats_list end
    for _i, list in ipairs(lists) do
        for _j, row in ipairs(list.rows()) do
            item_rows[#item_rows + 1] = row
        end
    end

    -- Content: reader layout and the sliders.
    local content_rows = {
        Config.makeRadioSubmenuItem{
            text      = _("Reader Layout"),
            help_text = _("Layout of the Quick Settings panel in the reader. The file browser always uses the classic layout."),
            options   = {
                { value = LAYOUT.CLASSIC, label = _("Classic") },
                { value = LAYOUT.BOOK,    label = _("Book") },
            },
            get     = getReaderLayout,
            set     = function(v) SUISettings:saveSetting(READER_LAYOUT_KEY, v) end,
            refresh = refresh,
        },
        Config.makeRadioSubmenuItem{
            text         = _("Slider Style"),
            help_text    = _("Look of the frontlight and warmth sliders."),
            enabled_func = function() return Device:hasFrontlight() end,
            options      = {
                { value = SLIDER_STYLE.CLASSIC, label = _("Classic") },
                { value = SLIDER_STYLE.MINIMAL, label = _("Minimal") },
            },
            get          = getSliderStyle,
            set          = function(v) SUISettings:saveSetting(SLIDER_STYLE_KEY, v) end,
            refresh      = refresh,
        },
        toggleRow(_("Frontlight Slider"), showFrontlight, saveToggle(FRONTLIGHT_KEY),
            { enabled_func = function() return Device:hasFrontlight() end }),
        toggleRow(_("Warmth Slider"), showWarmth, saveToggle(WARMTH_KEY),
            { enabled_func = function() return Device:hasNaturalLight() end }),
        toggleRow(_("Sliders in Book Layout"), showBookSliders, saveToggle(BOOK_SLIDERS_KEY), {
            help_text    = _("Show the frontlight and warmth sliders below the book details in the Book layout."),
            enabled_func = function() return is_book_layout() and Device:hasFrontlight() end,
        }),
        {
            text                = _("Tiny Critter"),
            sub_item_table_func = function() return _CritterRow().getMenuItems(refresh, ctx_menu) end,
        },
    }

    -- Appearance: labels and buttons.
    local appearance_rows = {
        {
            text = _("Label"),
            sub_item_table = {
                Config.makeScaleItem({
                    text_func = function() return _("Size") end,
                    title     = _("Size"),
                    info      = _("Scale for the label text.\n100% is the default size."),
                    get       = getLabelScalePct,
                    set       = function(v) SUISettings:saveSetting(LABEL_SCALE_KEY, v) end,
                    refresh   = refresh,
                }),
                Config.makeChromeLabelFontItem({
                    bar     = "quick_settings",
                    title   = _("Font"),
                    refresh = refresh,
                    _lc     = _,
                }),
                toggleRow(_("Hide Label"), function() return not showLabels() end,
                    function(hidden) SUISettings:saveSetting(LABELS_KEY, not hidden) end),
            },
        },
        Config.makeRadioSubmenuItem{
            text    = _("Button Type"),
            options = {
                { value = "round",        label = _("Round") },
                { value = "square_round", label = _("Rounded Square") },
                { value = "bare",         label = _("Bare") },
            },
            get     = getShape,
            set     = function(v) SUISettings:saveSetting(SHAPE_KEY, v) end,
            refresh = refresh,
        },
        Config.makeSurfaceMenu{
            surface       = buttonSurface(),
            enabled_func  = function() return getShape() ~= "bare" end,
            with_strength = false,
            refresh       = refresh,
            _lc          = _,
        },
    }

    -- Behaviour: long tap and opening tab.
    local open_on_panel_rows = {}
    for _i, row in ipairs({
        { target = MenuHooks.TARGET.READER, text = _("Reader") },
        { target = MenuHooks.TARGET.FM,     text = _("File Browser") },
    }) do
        open_on_panel_rows[#open_on_panel_rows + 1] = toggleRow(row.text,
            function() return opensOnPanel(row.target) end,
            saveToggle(OPEN_ON_PANEL_KEYS[row.target]))
    end
    local behaviour_rows = {
        toggleRow(_("Settings on Long Tap"),
            function() return SUISettings:nilOrTrue(SETTINGS_ON_HOLD_KEY) end,
            saveToggle(SETTINGS_ON_HOLD_KEY),
            { help_text = _("When enabled, long-pressing the Quick Settings Bar opens its settings menu.\nDisable this to prevent the settings menu from appearing on long tap.") }),
        {
            text           = _("Open Menu on Quick Settings"),
            help_text      = _("Choose the menus that open directly on the Quick Settings tab instead of the last used tab."),
            sub_item_table = open_on_panel_rows,
        },
    }

    return Config.buildModuleMenu({
        master     = { makeEnableItem(ctx_menu) },
        items      = item_rows,
        content    = content_rows,
        appearance = { extra = appearance_rows },
        behaviour  = behaviour_rows,
    }, ctx_menu)
end

return QSBar
