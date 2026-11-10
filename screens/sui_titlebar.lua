-- sui_titlebar.lua — Simple UI
-- Title-bar customisations for the FileManager (FM) and injected fullscreen
-- widgets (Collections, History, …).
--
-- FM context:   apply(fm_self)  /  restore(fm_self)  /  reapply(fm_self)
--               Two styles: "classic" (configurable buttons and title) and
--               "tabs" (back, Library/Authors/Series/Tags tabs, menu).
-- Sub-pages:    applyToSub(w)  /  restoreSub(w)
-- Both:         reapplyAll(fm, stack)

local _ = require("infra/sui_i18n").translate
local Config = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local Backdrop = require("infra/sui_backdrop")
local SUIWallpaper = require("features/sui_wallpaper")

-- Lazy reference to the style module — avoids a circular-require at load time.
local _SUIStyle
local function SUIStyle()
    _SUIStyle = _SUIStyle or (function()
        local ok, m = pcall(require, "features/sui_style")
        return ok and m or nil
    end)()
    return _SUIStyle
end

-- Lazy reference to the shared layout constants (side margin).
local function SideM()
    return require("infra/sui_core").SIDE_M()
end

-- Lua 5.1 / LuaJIT compat: table.unpack was added in 5.2.
local _unpack = table.unpack or unpack

local Device = require("device")
local Screen = Device.screen

-- Maps browse mode → SUIStyle slot id of its icon.
local _BM_SLOT = {
    normal = "sui_browse_normal",
    author = "sui_browse_author",
    series = "sui_browse_series",
    tags   = "sui_browse_tags",
}

-- Shows the icon of `mode`'s slot on a live browse button.
local function _applyBrowseIcon(btn, mode)
    local SS = SUIStyle()
    if SS then SS.applyIconToBtn(_BM_SLOT[mode] or _BM_SLOT.normal, btn) end
end

local M = {}


local _BM_cache  -- nil = not yet tried; false = unavailable; table = module
local function _BrowseMeta()
    if _BM_cache == nil then
        local ok, m = pcall(require, "features/library/sui_library_browse")
        _BM_cache = (ok and m) or false
    end
    return _BM_cache or nil
end

-- Invalidate the cache so that reapplyAll picks up a newly-enabled BrowseMeta.
-- Called by reapply() before re-running apply().
local function _resetBMCache()
    _BM_cache = nil
end

-- ---------------------------------------------------------------------------
-- Settings keys and defaults
-- ---------------------------------------------------------------------------

local SETTING_KEY = "simpleui_tb_custom"
local FM_CFG_KEY  = "simpleui_tb_fm_cfg"
local SUB_CFG_KEY = "simpleui_tb_sub_cfg"
local SIZE_KEY    = "simpleui_tb_size_pct"
local STYLE_KEY   = "simpleui_tb_style"
local TABS_ORDER_KEY = "simpleui_tb_tabs_order"
local SEARCH_ID   = "fm_search"

M.STYLE_CLASSIC = "classic"
M.STYLE_TABS    = "tabs"

local _VIS_DEFAULTS = {
    fm_menu       = true,
    fm_back       = true,
    fm_title      = true,
    fm_search     = true,
    fm_browse     = false,
    sub_menu      = true,
    sub_close     = false,
    sub_back      = true,
}

-- Default side/order configs for FM and injected widgets.
local _FM_DEFAULTS = {
    side        = { fm_menu = "right", fm_back = "left", fm_search = "left", fm_browse = "right" },
    order_left  = { "fm_back", "fm_search" },
    order_right = { "fm_browse", "fm_menu" },
}
local _SUB_DEFAULTS = {
    side        = { sub_menu = "right", sub_close = "right", sub_back = "left" },
    order_left  = { "sub_back" },
    order_right = { "sub_menu", "sub_close" },
}

-- ---------------------------------------------------------------------------
-- Item catalogue (used by the Arrange Buttons menu)
-- ---------------------------------------------------------------------------

M.ITEMS = {
    { id = "fm_menu",       label = function() return _("Menu")              end, ctx = "fm"  },
    { id = "fm_back",       label = function() return _("Back")              end, ctx = "fm"  },
    { id = "fm_search",     label = function() return _("Search")            end, ctx = "fm"  },
    { id = "fm_browse",     label = function() return _("Browse")            end, ctx = "fm"  },
    { id = "fm_title",      label = function() return _("Title")             end, ctx = "fm",  no_side = true },
    { id = "sub_menu",      label = function() return _("Menu")              end, ctx = "sub" },
    { id = "sub_close",     label = function() return _("Close")             end, ctx = "sub" },
    { id = "sub_back",      label = function() return _("Back")              end, ctx = "sub" },
}

-- ---------------------------------------------------------------------------
-- Public settings accessors
-- ---------------------------------------------------------------------------

function M.isEnabled()   return SUISettings:nilOrTrue(SETTING_KEY) end
function M.setEnabled(v) SUISettings:saveSetting(SETTING_KEY, v)   end

local function _visKey(id) return "simpleui_tb_item_" .. id end

function M.isItemVisible(id)
    local v = SUISettings:readSetting(_visKey(id))
    if v == nil then return _VIS_DEFAULTS[id] ~= false end
    return v == true
end
function M.setItemVisible(id, v) SUISettings:saveSetting(_visKey(id), v) end

function M.getStyle()
    return SUISettings:readSetting(STYLE_KEY) == M.STYLE_TABS and M.STYLE_TABS or M.STYLE_CLASSIC
end
function M.setStyle(v)   SUISettings:saveSetting(STYLE_KEY, v) end
function M.isTabsStyle() return M.isEnabled() and M.getStyle() == M.STYLE_TABS end

-- Title-bar size in percent, shared by both styles. Sizes saved by the former
-- named-size setting are converted on first read.
local SIZE_MAX_PCT    = 150
local _LEGACY_SIZE_PCT = { compact = 75, default = 100, large = 130 }

M.SIZE_MAX_PCT = SIZE_MAX_PCT

function M.setSizePct(pct) Config.setScaleByKey(pct, SIZE_KEY, SIZE_MAX_PCT) end
function M.getSizePct()
    local legacy = _LEGACY_SIZE_PCT[SUISettings:readSetting(SIZE_KEY)]
    if legacy then M.setSizePct(legacy) end
    return Config.getScalePctByKey(SIZE_KEY, SIZE_MAX_PCT)
end
function M.getSizeScale() return M.getSizePct() / 100 end

-- ---------------------------------------------------------------------------
-- Config load/save (side assignments + button order)
-- ---------------------------------------------------------------------------

-- Merges saved config onto defaults. Any default items absent from the saved
-- order lists are appended, so newly-added buttons always appear in Arrange.
local function _loadCfg(key, defaults)
    local raw = SUISettings:readSetting(key)
    if type(raw) ~= "table" then
        local side = {}
        for k, v in pairs(defaults.side) do side[k] = v end
        return {
            side        = side,
            order_left  = { _unpack(defaults.order_left) },
            order_right = { _unpack(defaults.order_right) },
        }
    end
    local side = {}
    for k, v in pairs(defaults.side) do side[k] = v end
    if type(raw.side) == "table" then
        for k, v in pairs(raw.side) do side[k] = v end
    end
    local order_left  = (type(raw.order_left)  == "table") and raw.order_left  or defaults.order_left
    local order_right = (type(raw.order_right) == "table") and raw.order_right or defaults.order_right
    -- Append default items absent from both saved order lists.
    local in_saved = {}
    for _, id in ipairs(order_left)  do in_saved[id] = true end
    for _, id in ipairs(order_right) do in_saved[id] = true end
    for _, id in ipairs(defaults.order_right) do
        if not in_saved[id] then
            order_right[#order_right + 1] = id
            if not side[id] then side[id] = defaults.side[id] or "right" end
        end
    end
    for _, id in ipairs(defaults.order_left) do
        if not in_saved[id] then
            order_left[#order_left + 1] = id
            if not side[id] then side[id] = defaults.side[id] or "left" end
        end
    end
    return { side = side, order_left = order_left, order_right = order_right }
end

function M.getFMConfig()       return _loadCfg(FM_CFG_KEY,  _FM_DEFAULTS)  end
function M.getSubConfig()      return _loadCfg(SUB_CFG_KEY, _SUB_DEFAULTS) end
function M.saveFMConfig(cfg)   SUISettings:saveSetting(FM_CFG_KEY,  cfg) end
function M.saveSubConfig(cfg)  SUISettings:saveSetting(SUB_CFG_KEY, cfg) end

-- ---------------------------------------------------------------------------
-- Internal layout helpers
-- ---------------------------------------------------------------------------

-- Returns true if the item represents the "go up" row.
local function _isGoUpItem(item)
    return item.is_go_up or (item.text and item.text:find("\u{2B06}"))
end

-- ---------------------------------------------------------------------------
-- Path-based navigation helpers
-- ---------------------------------------------------------------------------
--
-- _normPath: resolves symlinks (Android /sdcard → /storage/emulated/0) and
-- strips trailing slashes so all comparisons are consistent.  Falls back
-- gracefully when realpath is unavailable or the path does not exist.
local function _normPath(path)
    if not path then return nil end
    local ffiUtil = require("ffi/util")
    local ok, resolved = pcall(ffiUtil.realpath, path)
    return (ok and resolved or path):gsub("/$", "")
end

-- _normHome: cached normalised home_dir.  Re-read each call — the user may
-- change home_dir in settings between navigations.
local function _normHome()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then return nil end
    return _normPath(home)
end

-- _isAtFSRoot: true when path is the effective navigation root.
-- With lock ON the root is home_dir; with lock OFF it is "/".
local function _isAtFSRoot(path)
    local p = _normPath(path)
    if not p or p == "" or p == "/" then return true end
    if G_reader_settings:isTrue("lock_home_folder") then
        local h = _normHome()
        return h ~= nil and p == h
    end
    return false
end

-- _isSubFolder: true when the back button should be shown at `path`.
--
-- Virtual BrowseMeta paths (Authors / Series / Tags):
--   root     — the entry point before choosing a dimension: hide.
--   dim_list — the list of all authors / series / tags: hide.
--              This is the virtual equivalent of the home root.
--   file_list — the books inside one author / series / tag: show.
--              This is the virtual equivalent of a subfolder.
--   (BrowseMeta not active → path treated as normal filesystem path)
--
-- Normal filesystem paths depend on lock_home_folder:
--   lock OFF: root of navigation is "/". Show everywhere except "/".
--   lock ON:  root of navigation is home_dir. Show only when strictly
--             below home_dir; hide at home_dir and outside home.
--
-- Uses realpath so Android /sdcard symlinks normalise consistently.
-- Does not handle a series group (its path is that of its parent folder):
-- callers check _seriesViewOf separately.

local function _isSubFolder(path)
    if not path then return false end
    local p = _normPath(path)
    if not p or p == "" or p == "/" then return false end

    -- Virtual path: delegate entirely to BrowseMeta's level classification.
    local BM = _BrowseMeta()
    if BM then
        local ok, level = pcall(BM.getPathLevel, path)
        if ok and level then
            -- file_list = inside a specific author/series/tag → show.
            -- root / dim_list = top of the virtual tree → hide.
            return level == "file_list"
        end
        -- getPathLevel returned nil → path is not virtual; fall through.
    end

    -- Normal filesystem path.
    if G_reader_settings:isTrue("lock_home_folder") then
        -- Locked: only show when strictly inside home_dir.
        local h = _normHome()
        if not h then return false end              -- no home set → hide
        if p == h then return false end             -- at home root → hide
        return p:sub(1, #h + 1) == h .. "/"        -- strictly below home → show
    else
        -- Unlocked: any path other than "/" has a parent to go back to.
        return true
    end
end

-- Series group listed by the file chooser in place of a folder, or nil. It
-- keeps the path of the folder it was opened from, so the path alone cannot
-- tell it apart from that folder.
local function _seriesViewOf(fc)
    local it = fc.item_table
    return it and it._sg_is_series_view and it or nil
end

-- M.isAtRoot: exported so sui_patches can use the same criterion without
-- duplicating the logic or depending on the _simpleui_has_go_up flag.
local function _isAtRoot(fc)
    if not fc then return true end
    -- A series group always has a parent, even when opened from the home root.
    if _seriesViewOf(fc) then return false end
    return not _isSubFolder(fc.path)
end
function M.isAtRoot(fc) return _isAtRoot(fc) end

-- Keep _isLockedAtHome for any callers outside this file that may require it,
-- but internally we now use _isAtFSRoot / _isSubFolder.
local function _isLockedAtHome(path)
    return _isAtFSRoot(path) and
           G_reader_settings:isTrue("lock_home_folder") and
           _normPath(path) == _normHome()
end

-- Pixel x-position for a button at slot (0-based) on a given side.
local function _buttonX(side, slot, btn_w, pad, gap, sw)
    if side == "left" then
        return pad + slot * (btn_w + gap)
    else
        return sw - btn_w - pad - slot * (btn_w + gap)
    end
end

-- Builds id -> { side, slot } map from ordered lists and a visible-ids set.
-- order_right[1] maps to the rightmost screen position (highest slot index).
local function _buildSlotMap(order_left, order_right, visible_ids)
    local slots   = {}
    local count_l = 0
    for _, id in ipairs(order_left) do
        if visible_ids[id] then
            slots[id] = { side = "left", slot = count_l }
            count_l   = count_l + 1
        end
    end
    local right_vis = {}
    for _, id in ipairs(order_right) do
        if visible_ids[id] then right_vis[#right_vis + 1] = id end
    end
    local n = #right_vis
    for i, id in ipairs(right_vis) do
        slots[id] = { side = "right", slot = n - i }
    end
    return slots
end

-- Reloads an ImageWidget after its .file field has been changed.
local function _reloadImage(img)
    pcall(img.free, img)
    pcall(img.init, img)
end

-- Text colours of content on the title bar surface, or nil when the surface
-- has no foreground (plain white or gray): then nothing is recoloured.
local function _barInk()
    local surface = SUIWallpaper.resolveBar("titlebar")
    if surface.foreground then return Backdrop.contentColors(surface) end
end

-- Native parts of a title bar drawn in ink: its title and subtitle texts (a
-- multi-line text box bakes its colour when built, so it keeps its own) and
-- its icon buttons, injected ones included.
local function _barInkParts(tb)
    local texts, icons = {}, {}
    for _, tw in ipairs({ tb.title_widget, tb.subtitle_widget }) do
        if not tw.update then texts[#texts + 1] = tw end
    end
    for _, child in ipairs(tb) do
        if child.image and child.horizontal_group then icons[#icons + 1] = child end
    end
    return texts, icons
end

-- Bar surface (tone, opacity and frame) painted behind a title bar across
-- the full page width, and the title bar content drawn in the surface's text
-- colour. Both are read at paint time so changes need no re-hook. The
-- instance-level paintTo is dropped again to return to the class method.
local function _installBarScrim(tb)
    if rawget(tb, "paintTo") then return end
    local orig = tb.paintTo
    function tb:paintTo(bb, x, y)
        local surface = SUIWallpaper.resolveBar("titlebar")
        if surface.strength > 0 or surface.border_sz > 0 then
            local h = (self.dimen and self.dimen.h) or self:getHeight()
            Backdrop.paintBar(bb, y, h, surface, "bottom")
        end
        local fg, dim = _barInk()
        if not fg then return orig(self, bb, x, y) end
        local texts, icons = _barInkParts(self)
        return require("infra/sui_core").paintInk(fg, dim, texts, icons, orig, self, bb, x, y)
    end
end

local function _removeBarScrim(tb)
    tb.paintTo = nil
end

-- Resizes btn to new_w x new_w and zeroes left/right/bottom paddings.
-- Pass keep_top_pad=true to preserve padding_top (needed for injected buttons).
local function _resizeAndStrip(btn, new_w, keep_top_pad)
    btn.width  = new_w
    btn.height = new_w
    if type(btn.icon) == "string" and btn.icon:match("^nerd:") then
        btn.icon = nil
    end
    if type(btn.file) == "string" and btn.file:match("^nerd:") then
        btn.file = nil
    end
    if btn.image then
        -- Safety guard: clear stale Nerd Font strings left by older plugin versions
        -- before they crash ImageWidget:getSize() during btn:update().
        if type(btn.image.file) == "string" and btn.image.file:match("^nerd:") then
            btn.image.file = nil
        end
        if type(btn.image.icon) == "string" and btn.image.icon:match("^nerd:") then
            btn.image.icon = nil
        end
        local box = math.floor(new_w * (btn.sui_icon_scale or 1))
        btn.image.width  = box
        btn.image.height = box
        if btn.image.face then
            btn.image.face = SUIStyle().glyphFace(box)
        else
            _reloadImage(btn.image)
        end
    end
    if btn.label_widget and type(btn.label_widget.file) == "string" and btn.label_widget.file:match("^nerd:") then
        btn.label_widget.file = nil
    end
    if btn.label_widget and type(btn.label_widget.icon) == "string" and btn.label_widget.icon:match("^nerd:") then
        btn.label_widget.icon = nil
    end
    if btn.label_widget then
        btn.label_widget.width  = new_w
        btn.label_widget.height = new_w
        if btn.label_widget.is_sui_wrapper then
            btn.label_widget.face = SUIStyle().glyphFace(new_w)
        end
    end
    btn.padding_left   = 0
    btn.padding_right  = 0
    btn.padding_bottom = 0
    if not keep_top_pad then btn.padding_top = 0 end
    btn:update()
end

-- Snapshots a button's current geometry and optional state into a plain table.
local function _snapBtn(btn, opts)
    local snap = {
        align   = btn.overlap_align,
        offset  = btn.overlap_offset,
        pad_t   = btn.padding_top,
        pad_l   = btn.padding_left,
        pad_r   = btn.padding_right,
        pad_bot = btn.padding_bottom,
        w       = btn.width,
        h       = btn.height,
    }
    if opts then
        if opts.save_icon then
            -- Save both .file and .icon fields of the ImageWidget.
            -- KOReader's ImageWidget gives precedence to .icon over .file in
            -- init(), so we must snapshot and restore both to avoid the
            -- restored button resolving to a stale icon from another widget.
            snap.icon      = btn.image and btn.image.file
            snap.image_icon = btn.image and btn.image.icon
        end
        if opts.save_callback then
            snap.callback = btn.callback
            snap.hold_cb  = btn.hold_callback
        end
        if opts.save_dimen then snap.dimen = btn.dimen end
    end
    return snap
end

-- Restores a button from a snapshot produced by _snapBtn.
local function _restoreBtn(btn, snap)
    if not snap then return end
    local _ss = SUIStyle()
    if _ss and _ss.restoreDefaultIcon then
        _ss.restoreDefaultIcon(btn, snap.image_icon, snap.icon)
    else
        if btn.image then
            btn.image.icon = snap.image_icon
            btn.image.file = snap.icon
            _reloadImage(btn.image)
        end
    end
    btn.overlap_align  = snap.align
    btn.overlap_offset = snap.offset
    btn.padding_top    = snap.pad_t
    btn.padding_left   = snap.pad_l
    btn.padding_right  = snap.pad_r
    btn.padding_bottom = snap.pad_bot
    if snap.w ~= nil then
        btn.width  = snap.w
        btn.height = snap.h
        if btn.image then
            btn.image.width  = snap.w
            btn.image.height = snap.h
            _reloadImage(btn.image)
        end
    end
    pcall(btn.update, btn)
    if snap.callback ~= nil then btn.callback      = snap.callback end
    if snap.hold_cb  ~= nil then btn.hold_callback = snap.hold_cb  end
    if snap.dimen    ~= nil then btn.dimen         = snap.dimen    end
end

-- Reads layout geometry from a TitleBar instance (called once per apply).
local function _layoutParams(tb)
    local Screen  = require("device").screen
    local scale   = M.getSizeScale()
    local base_iw = Screen:scaleBySize(36)
    pcall(function()
        local sz = (tb.right_button and tb.right_button.image and tb.right_button.image:getSize())
               or  (tb.left_button  and tb.left_button.image  and tb.left_button.image:getSize())
        if sz and sz.w and sz.w > 0 then base_iw = sz.w end
    end)
    return {
        iw  = math.floor(base_iw * scale),
        pad = SideM(),
        gap = Screen:scaleBySize(18),
        sw  = Screen:getWidth(),
    }
end

-- Icon / slot ratio of the search and menu buttons in the tabs bar. The slot
-- is only as tall as the text, so the icon is drawn larger than its slot to
-- stay prominent next to the tab labels. It applies to symbol glyphs and image
-- icons alike, which then render at the same visual size.
local TABS_ICON_SCALE = 1.37

-- Face of the tab labels, scaled by the title-bar size. `base_size` is a
-- SUIStyle font size (default FS_BODY). Also used by other tab bars so they
-- scale with the title-bar tabs.
function M.getTabsFace(base_size)
    local S = SUIStyle()
    return require("ui/font"):getFace(S.FACE_REGULAR, math.floor((base_size or S.FS_BODY) * M.getSizeScale()))
end

-- Metrics of the compact tabs-style bar, scaled by the title-bar size. The
-- icon size equals the text height and is also the menu icon size of the
-- classic style.
local function _tabsMetrics()
    local scale = M.getSizeScale()
    local face  = M.getTabsFace()
    local probe = require("ui/widget/textwidget"):new{ text = "A", face = face, padding = 0 }
    local text_h = probe:getSize().h
    probe:free()
    return {
        face      = face,
        iw        = text_h,                        -- icon size == text height
        pad_v     = math.floor(Screen:scaleBySize(7) * scale), -- above and below the text row
        margin    = SideM(),                       -- screen edge to icon
        back_gap  = Screen:scaleBySize(14),        -- back icon to the content beside it
        tap_pad_h = Screen:scaleBySize(8),         -- horizontal tap-area padding
        sw        = Screen:getWidth(),
    }
end

-- Sizes the menu button to the icon slot so it matches back, search and
-- browse. `slot_w` is the icon size; `x` is the slot's left edge; `edge` and
-- `icon_scale` (both optional) set the icon alignment and its icon / slot
-- ratio, see SUIStyle.applyIconToBtn.
local function _placeMenuButton(btn, slot_w, x, edge, icon_scale)
    btn.sui_icon_edge  = edge
    btn.sui_icon_scale = icon_scale
    _resizeAndStrip(btn, slot_w)
    btn.overlap_align  = nil
    btn.overlap_offset = { x, 0 }
end

local function _hideOffset(sw)
    return sw * 2
end

-- ---------------------------------------------------------------------------
-- D-pad focus of a title bar
-- The buttons and the tab strip are placed by offset, so the rows the host
-- menu builds from the native buttons do not match what is on screen. The
-- title bar rows of the host's focus layout are rebuilt from the controls
-- that are shown instead.
-- ---------------------------------------------------------------------------

-- Controls of `tb` that are on screen, left to right: its buttons and the
-- stops of its tab strip.
local function _titleStops(tb)
    local sw    = Screen:getWidth()
    local found = {}
    for _i, child in ipairs(tb) do
        local off = child.overlap_offset
        if not (off and off[1] >= sw) then
            local x = off and off[1] or (child.overlap_align == "right" and sw or 0)
            if child.getStops then
                for _j, stop in ipairs(child:getStops()) do
                    found[#found + 1] = { widget = stop.widget, x = x + stop.x, order = #found }
                end
            elseif child.callback then
                found[#found + 1] = { widget = child, x = x, order = #found }
            end
        end
    end
    table.sort(found, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.order < b.order
    end)
    local widgets = {}
    for i, stop in ipairs(found) do widgets[i] = stop.widget end
    return widgets
end

-- Removes the title bar rows set earlier from the host's layout and returns
-- how many there were, keeping the selection on the same list item.
local function _dropTitleRows(host)
    local state, layout = host._sui_tb_focus, host.layout
    local dropped = 0
    while layout[1] and state.rows[layout[1]] do
        table.remove(layout, 1)
        dropped = dropped + 1
    end
    state.rows = {}
    if host.selected and host.selected.y > dropped then host.selected.y = host.selected.y - dropped end
    return dropped
end

-- Puts the rows of the controls that are shown at the top of the host's
-- layout. Devices without a horizontal move get one control per row.
local function _syncTitleFocus(host)
    local state = host._sui_tb_focus
    if not (state and host.layout) then return end
    _dropTitleRows(host)
    local widgets = _titleStops(state.tb)
    local rows = {}
    if Device:hasFewKeys() then
        for i, widget in ipairs(widgets) do rows[i] = { widget } end
    elseif #widgets > 0 then
        rows[1] = widgets
    end
    for i, row in ipairs(rows) do
        table.insert(host.layout, i, row)
        state.rows[row] = true
    end
    if host.selected then host.selected.y = host.selected.y + #rows end
end

-- Takes over the title bar rows of `host`, a menu whose title bar is `tb`,
-- when the device has a D-pad.
local function _installTitleFocus(host, tb)
    if not (host and Device:hasDPad()) then return end
    host._sui_tb_focus = { tb = tb, rows = {} }
    host.mergeTitleBarIntoLayout = _syncTitleFocus
    local layout = host.layout
    if not layout then return end
    -- The layout already holds the native title bar rows: replace them.
    for _i, native in ipairs(tb:generateVerticalLayout()) do
        if layout[1] and layout[1][1] == native[1] then
            table.remove(layout, 1)
            if host.selected then host.selected.y = host.selected.y - 1 end
        end
    end
    _syncTitleFocus(host)
end

-- Gives the title bar rows back to the menu's own merge.
local function _removeTitleFocus(host)
    if not (host and host._sui_tb_focus) then return end
    if host.layout then _dropTitleRows(host) end
    host._sui_tb_focus = nil
    host.mergeTitleBarIntoLayout = nil
    if host.layout then host:mergeTitleBarIntoLayout() end
end

-- ---------------------------------------------------------------------------
-- Shared building blocks (FM styles and sub-pages)
-- ---------------------------------------------------------------------------

-- Shows the back icon: the SUIStyle override when set, the slot's default
-- symbol glyph (which follows the layout direction) otherwise.
local function _applyBackIcon(btn)
    local _ss = SUIStyle()
    if _ss then _ss.applyIconToBtn("sui_back", btn) end
end

-- Shows the menu icon: the SUIStyle override when set, the slot's default
-- symbol glyph otherwise.
local function _applyMenuIcon(btn)
    local _ss = SUIStyle()
    if _ss then _ss.applyIconToBtn("sui_menu", btn) end
end

-- Creates the injected back button, sized and styled like the other title-bar
-- buttons. `edge` ("left" | "right") is the side its icon is aligned to. Its
-- callbacks are installed by the owning state controller.
local function _newBackButton(tb, parent, iw, edge, icon_scale)
    local IconButton = require("ui/widget/iconbutton")
    -- IconButton needs a native icon name; _applyBackIcon swaps in the icon
    -- once the button exists.
    local btn = IconButton:new{
        icon        = "chevron.left",
        width       = iw,
        height      = iw,
        padding     = tb.button_padding or Screen:scaleBySize(11),
        show_parent = tb.show_parent or parent,
        callback    = function() end,
    }
    btn.sui_icon_scale = icon_scale
    btn.sui_icon_edge  = edge
    _resizeAndStrip(btn, iw)
    _applyBackIcon(btn)
    btn.overlap_align = nil
    return btn
end

-- Builds the injected search button; it opens the file search of the library.
-- `edge` and `icon_scale` (both optional) set the icon alignment and its
-- icon / slot ratio, see SUIStyle.applyIconToBtn.
local function _newSearchButton(tb, fm_self, iw, edge, icon_scale)
    local IconButton = require("ui/widget/iconbutton")
    local btn = IconButton:new{
        icon        = "appbar.search",
        width       = iw,
        height      = iw,
        padding     = tb.button_padding or Screen:scaleBySize(11),
        show_parent = tb.show_parent or fm_self,
        callback    = function()
            local fs = fm_self.filesearcher
            if fs and fs.onShowFileSearch then fs:onShowFileSearch() end
        end,
    }
    btn.sui_icon_scale = icon_scale
    btn.sui_icon_edge  = edge
    _resizeAndStrip(btn, iw)
    local S = SUIStyle()
    if S then S.applyIconToBtn("sui_search", btn) end
    btn.overlap_align = nil
    return btn
end

-- Turns the native right button into the menu button. `place(btn)` sizes and
-- positions it when shown; otherwise it is moved off-screen with its callbacks
-- disabled. setRightIcon is patched so the custom icon survives navigation.
local function _setupMenuButton(fm_self, tb, show_menu, place)
    local rb = tb.right_button
    if not rb then return end
    local UIManager = require("ui/uimanager")
    fm_self._titlebar_rb = _snapBtn(rb, { save_icon = true, save_callback = true })

    local orig_setRightIcon = tb.setRightIcon
    fm_self._titlebar_orig_setRightIcon = orig_setRightIcon
    tb.setRightIcon = function(tb_self, icon, ...)
        local result = orig_setRightIcon(tb_self, icon, ...)
        if icon == "plus" and show_menu then
            if tb_self.right_button then _applyMenuIcon(tb_self.right_button) end
            UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
        end
        return result
    end

    if show_menu then
        place(rb)
        _applyMenuIcon(rb)
    else
        rb.overlap_align  = nil
        rb.overlap_offset = { _hideOffset(Screen:getWidth()), 0 }
        rb.callback       = function() end
        rb.hold_callback  = function() end
    end
end

-- Permanently hides the native left button (snapshotted so restore() can undo);
-- an injected back button replaces it.
local function _hideNativeLeftButton(fm_self, tb)
    local lb = tb.left_button
    if not lb then return end
    fm_self._titlebar_lb = _snapBtn(lb, { save_icon = true, save_callback = true })
    lb.overlap_align  = nil
    lb.overlap_offset = { _hideOffset(Screen:getWidth()), 0 }
    lb.callback       = function() end
    lb.hold_callback  = function() end
end

-- Applies the back-button state once, right after the first layout.
local function _refreshBackState(fm_self)
    local fc      = fm_self.file_chooser
    local refresh = fm_self._simpleui_force_refresh_layout
    if not (refresh and fc) then return end
    refresh(fc, fc.page or 1)
    fm_self._simpleui_force_refresh_layout = nil
end

-- ---------------------------------------------------------------------------
-- FM back-button controller
-- ---------------------------------------------------------------------------
--
-- Drives the injected back button from file-chooser navigation. With the tabs
-- style the button only leaves folders:
--   root          : hidden
--   subfolder     : visible; tap = folder up
-- With the classic style it also pages back:
--   root + page 1 : hidden
--   root + page>1 : visible; tap = previous page, hold = first page
--   subfolder     : visible; tap = previous page past page 1, else folder up
-- `on_state(fc, view, visible)` lets each title-bar style react to the
-- evaluated state (neighbour layout, tab strip content, …). `view` describes
-- what the file chooser displays:
--   path   : path of the view
--   series : the series group on display, nil for a listing of a folder
-- State is re-evaluated on genItemTable, onFolderUp and onGotoPage.

local function _installBackController(fm_self, shown_x, on_state)
    local fc = fm_self.file_chooser
    if not fc then return end
    local UIManager = require("ui/uimanager")
    local sw        = Screen:getWidth()
    local paginates = not M.isTabsStyle()

    -- `page` is always passed explicitly to avoid stale cur_page reads.
    local function applyState(fc_self, page, path, series)
        local btn = fm_self._titlebar_up_btn
        if not btn then return end
        local is_sub     = series ~= nil or _isSubFolder(path)
        local pages_back = paginates and page > 1
        local visible    = is_sub or pages_back

        if not visible then
            btn.overlap_offset = { _hideOffset(sw), 0 }
            btn.callback       = function() end
            btn.hold_callback  = function() end
        else
            _applyBackIcon(btn)
            btn.overlap_offset = { shown_x, 0 }
            if pages_back then
                btn.callback      = function() fc_self:onGotoPage(page - 1) end
                btn.hold_callback = function() fc_self:onGotoPage(1) end
            else
                btn.callback      = function() fc_self:onFolderUp() end
                btn.hold_callback = function() end
            end
        end

        if on_state then on_state(fc_self, { path = path, series = series }, visible) end
        if fc_self._sui_tb_focus then _syncTitleFocus(fc_self) end

        local tb = fm_self.title_bar
        if tb then
            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
        end
    end

    -- Applies the state of whatever the file chooser currently displays.
    local function refreshState(fc_self, page)
        applyState(fc_self, page, fc_self.path, _seriesViewOf(fc_self))
    end

    fm_self._simpleui_force_refresh_layout = refreshState

    fm_self._titlebar_orig_fc_genItemTable = fc.genItemTable
    fc._simpleui_gen_listeners = {}

    local orig_genItemTable = fc.genItemTable
    fc.genItemTable = function(fc_self, dirs, files, path)
        local item_table = orig_genItemTable(fc_self, dirs, files, path)
        if not item_table then return item_table end

        -- Strip the go-up row from the list (the injected back button owns it).
        -- is_sub is determined by path, not by the presence of this item.
        local filtered = {}
        for _, item in ipairs(item_table) do
            if not _isGoUpItem(item) then
                filtered[#filtered + 1] = item
            end
        end

        -- Cover-collection lookups (`_dummy`) list other folders without
        -- navigating to them, so they must not touch the title-bar state.
        if fc_self._dummy then return filtered end

        -- The path argument is the destination of this call; fc_self.path may
        -- still hold the previous one on the initial load. The list built here
        -- is a folder listing: `fc_self.item_table` is the outgoing one, so a
        -- series group still on display is being replaced, not shown.
        applyState(fc_self, 1, path or fc_self.path, nil)

        -- Other registered listeners (e.g. browse icon refresh).
        for _, listener in ipairs(fc_self._simpleui_gen_listeners or {}) do
            pcall(listener, fc_self)
        end

        return filtered
    end

    -- The first FM open called genItemTable before the patch was installed:
    -- strip the go-up entry retroactively so the initial render matches.
    local it = fc.item_table
    if it then
        local cleaned, found_go_up = {}, false
        for _, item in ipairs(it) do
            if _isGoUpItem(item) then
                found_go_up = true
            else
                cleaned[#cleaned + 1] = item
            end
        end
        if found_go_up then
            for i = #it, 1, -1 do it[i] = nil end
            for i, v in ipairs(cleaned) do it[i] = v end
            UIManager:nextTick(function()
                if fc and fc.updateItems then
                    pcall(fc.updateItems, fc, 1, true)
                end
            end)
        end
    end

    -- onFolderUp re-evaluates the state after navigation. The class method is
    -- resolved at call time because sui_foldercovers may swap it at runtime.
    -- The previous instance value is saved so restore() can reinstate it.
    local FileChooser_cls = require("ui/widget/filechooser")
    fm_self._titlebar_orig_fc_onFolderUp = fc.onFolderUp  -- may be nil
    fc.onFolderUp = function(fc_self, ...)
        local BM = _BrowseMeta()
        if BM then
            -- Arrived at a leaf from elsewhere (the book dialog, or a screen):
            -- one back press from that leaf returns to where it started, not
            -- to the root of the dimension.
            local origin = fc_self._sui_leaf_origin
            if origin then
                local ok_pl, level = pcall(BM.getPathLevel, fc_self.path or "")
                if ok_pl and level == "file_list" and BM.getPathDepth(fc_self.path) == 1 then
                    fc_self._sui_leaf_origin = nil
                    if fc_self.path == origin.leaf then
                        BM.exitToNormal(fc_self, fm_self)
                        if origin.return_fn then
                            origin.return_fn()
                        else
                            fc_self:changeToPath(origin.path, origin.file)
                        end
                        refreshState(fc_self, 1)
                        return true
                    end
                end
            end
            -- At the dim_list level of a virtual tree, exit to the filesystem.
            local path = fc_self.path or ""
            if path:find("/", 1, true) then
                local ok_pl, level = pcall(BM.getPathLevel, path)
                if ok_pl and level == "dim_list" then
                    BM.exitToNormal(fc_self, fm_self)
                    refreshState(fc_self, 1)
                    return true
                end
            end
        end
        local ok, result = xpcall(FileChooser_cls.onFolderUp, debug.traceback, fc_self, ...)
        refreshState(fc_self, 1)
        if not ok then error(result, 0) end
        return result
    end

    -- onGotoPage updates the state on every CoverBrowser page turn. The
    -- re-entrancy guard keeps KOReader's internal recursive calls from
    -- overwriting the state set for the outer call.
    local orig_onGotoPage = fc.onGotoPage
    if orig_onGotoPage then
        fm_self._titlebar_orig_fc_onGotoPage = orig_onGotoPage
        fc.onGotoPage = function(fc_self, page, ...)
            if fc_self._simpleui_in_goto then
                return orig_onGotoPage(fc_self, page, ...)
            end
            fc_self._simpleui_in_goto = true
            local ok, result = xpcall(orig_onGotoPage, debug.traceback, fc_self, page, ...)
            -- Cleared before any error() so a failure never leaves it stuck.
            fc_self._simpleui_in_goto = nil
            refreshState(fc_self, page)
            if not ok then error(result, 0) end
            return result
        end
    end
end

-- ---------------------------------------------------------------------------
-- FM titlebar — classic style
-- ---------------------------------------------------------------------------

local function _applyClassic(fm_self, tb)
    local lp = _layoutParams(tb)
    local iw, pad, gap, sw = lp.iw, lp.pad, lp.gap, lp.sw

    local show_menu   = M.isItemVisible("fm_menu")
    local show_up     = M.isItemVisible("fm_back")
    local show_search = M.isItemVisible("fm_search")
    local show_browse = M.isItemVisible("fm_browse") and (function()
        local BM = _BrowseMeta()
        return BM and BM.isEnabled()
    end)()
    local show_title  = M.isItemVisible("fm_title")

    local cfg     = M.getFMConfig()
    local visible = {}
    if show_menu   then visible["fm_menu"]   = true end
    if show_up     then visible["fm_back"]   = true end
    if show_search then visible["fm_search"] = true end
    if show_browse then visible["fm_browse"] = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local UIManager = require("ui/uimanager")

    -- Menu button (native right button).
    _setupMenuButton(fm_self, tb, show_menu, function(rb)
        local s = slot_map["fm_menu"]
        if not s then return end
        _placeMenuButton(rb, iw, _buttonX(s.side, s.slot, iw, pad, gap, sw), s.side)
    end)

    -- Back button (injected; the native left button stays hidden).
    _hideNativeLeftButton(fm_self, tb)

    local s_up = show_up and slot_map["fm_back"]
    if s_up then
        local up_btn  = _newBackButton(tb, fm_self, iw, s_up.side)
        local up_x    = _buttonX(s_up.side, s_up.slot, iw, pad, gap, sw)
        up_btn.overlap_offset = { up_x, 0 }
        table.insert(tb, up_btn)
        fm_self._titlebar_up_btn = up_btn
        fm_self._simpleui_up_x   = up_x

        -- Hidden on the very first apply when already at the root.
        if _isAtRoot(fm_self.file_chooser) then
            up_btn.overlap_offset = { _hideOffset(sw), 0 }
        end

        -- Left-side neighbours of the back button, with their slot index.
        local function leftSideBtns()
            local list = {}
            for _, id in ipairs(cfg.order_left) do
                local sl = slot_map[id]
                if id ~= "fm_back" and sl and sl.side == "left" then
                    local widget
                    if id == "fm_search" then
                        widget = fm_self._titlebar_search_btn
                    elseif id == "fm_browse" then
                        widget = fm_self._titlebar_browse_btn
                    end
                    if widget then list[#list + 1] = { btn = widget, slot = sl.slot } end
                end
            end
            return list
        end

        -- While the back button is hidden, left neighbours close the gap.
        local up_slot = s_up.slot
        _installBackController(fm_self, up_x, function(_, _, visible_now)
            for _, entry in ipairs(leftSideBtns()) do
                local dslot = (not visible_now and entry.slot > up_slot)
                              and entry.slot - 1 or entry.slot
                entry.btn.overlap_offset = { _buttonX("left", dslot, iw, pad, gap, sw), 0 }
            end
        end)
    end

    -- Search button ----------------------------------------------------------
    -- Injected directly into the TitleBar OverlapGroup.
    -- All paddings (including top) are zeroed to align with the other buttons.

    local s_search = show_search and slot_map["fm_search"]
    if s_search then
        local search_btn = _newSearchButton(tb, fm_self, iw, s_search.side)
        local search_x   = _buttonX(s_search.side, s_search.slot, iw, pad, gap, sw)
        search_btn.overlap_offset = { search_x, 0 }
        table.insert(tb, search_btn)
        fm_self._titlebar_search_btn = search_btn
        fm_self._simpleui_search_x   = search_x

        if s_search.side == "left" then
            local up_slot   = slot_map["fm_back"] and slot_map["fm_back"].slot or 0
            local dslot     = s_search.slot > up_slot and s_search.slot - 1 or s_search.slot
            local compact_x = _buttonX("left", dslot, iw, pad, gap, sw)
            fm_self._simpleui_search_x_compact = compact_x
            -- Flush-left position whenever the back button does not occupy its
            -- slot: it is disabled, or hidden because the view is at the root.
            if (not show_up) or _isAtRoot(fm_self.file_chooser) then
                search_btn.overlap_offset = { compact_x, 0 }
            end
        end
    end

    -- Browse button ----------------------------------------------------------
    -- Injected like search_button. Icon reflects the current browse mode and
    -- is refreshed on every genItemTable call via the listener registry
    -- (Improvement #2) instead of a second genItemTable wrapper.

    if show_browse then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["fm_browse"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)

                -- Resolve initial icon from the current browse mode.
                -- Improvement #4: use cached _BrowseMeta().
                local BM0 = _BrowseMeta()
                local mode0 = "normal"
                if BM0 then
                    local fc0  = fm_self.file_chooser
                    mode0 = fc0 and BM0.getCurrentMode(fc0) or "normal"
                end

                local browse_btn
                browse_btn = IconButton:new{
                    icon        = "appbar.menu",
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback = function()
                        -- Improvement #4: use cached _BrowseMeta().
                        local BM = _BrowseMeta()
                        if not BM then return end
                        local ActionSheet  = require("engines/sui_action_sheet")
                        local fc_ref       = fm_self.file_chooser
                        local cur_mode     = fc_ref and BM.getCurrentMode(fc_ref) or "normal"
                        -- Navigates to mode, and refreshes the icon.
                        local function _navigate(mode)
                            BM.navigateTo(fm_self, mode)
                            _applyBrowseIcon(browse_btn, mode)
                            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
                        end
                        local function _mode(mode, label)
                            return { text = label, icon_slot = _BM_SLOT[mode], checked = cur_mode == mode,
                                     callback = function() _navigate(mode) end }
                        end
                        ActionSheet.show{
                            name       = "sui_win_browse_mode",
                            title      = _("Browse library"),
                            icon       = "library",
                            fit_width  = true,
                            auto_close = true,
                            sections   = { ActionSheet.list{
                                _mode("normal", _("Default")),
                                _mode("author", _("By author")),
                                _mode("series", _("By series")),
                                _mode("tags", _("By tags")),
                            } },
                        }
                    end,
                }

                browse_btn.sui_icon_edge = s.side
                _resizeAndStrip(browse_btn, iw)
                _applyBrowseIcon(browse_btn, mode0)
                browse_btn.overlap_align  = nil
                browse_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, browse_btn)
                fm_self._titlebar_browse_btn = browse_btn

                -- Improvement #3 — compute compact slot once, reuse for both
                -- the cached value and the immediate-at-root initial adjustment.
                if s.side == "left" then
                    local up_slot_b = slot_map["fm_back"] and slot_map["fm_back"].slot or 0
                    local dslot_b   = s.slot > up_slot_b and s.slot - 1 or s.slot
                    local compact_x_b = _buttonX("left", dslot_b, iw, pad, gap, sw)
                    fm_self._simpleui_browse_x_compact = compact_x_b
                    -- Shift to the compact (flush left) position whenever the up/back
                    -- button is not actually occupying its slot: either it is disabled
                    -- entirely (not show_up), or it is enabled but hidden because we
                    -- are already at root on first apply (show_up and _isAtRoot(...)).
                    -- Same fix as the search button above.
                    if (not show_up) or _isAtRoot(fm_self.file_chooser) then
                        browse_btn.overlap_offset = { compact_x_b, 0 }
                    end
                end


                local fc_b = fm_self.file_chooser
                if fc_b and fc_b._simpleui_gen_listeners then
                    fc_b._simpleui_gen_listeners[#fc_b._simpleui_gen_listeners + 1] = function(fc_self)
                        -- Improvement #4: use cached _BrowseMeta().
                        local BM2 = _BrowseMeta()
                        if BM2 and browse_btn then
                            local mode2 = BM2.getCurrentMode(fc_self)
                            _applyBrowseIcon(browse_btn, mode2)
                            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
                        end
                    end
                    fm_self._titlebar_browse_gen_hooked = true
                end
            end
        end
    end

    -- Title ------------------------------------------------------------------

    _refreshBackState(fm_self)
    if tb.setTitle then
        fm_self._titlebar_orig_title_set = true
        tb:setTitle(show_title and _("Library") or "")
    end
end

-- ---------------------------------------------------------------------------
-- FM titlebar — tabs style
-- ---------------------------------------------------------------------------
--
-- Back button, tab strip (tabs and search button) and menu button on a single compact row. The bar is
-- built with the metrics below (see M.runWithStyleMetrics) so its height is
-- the text row plus a vertical padding; the buttons are as tall as the text.

-- Grows an icon button's tap area to the full bar height without moving its icon.
local function _padTapArea(btn, m)
    btn.padding_left   = m.tap_pad_h
    btn.padding_right  = m.tap_pad_h
    btn.padding_top    = m.pad_v
    btn.padding_bottom = m.pad_v
    btn:update()
end

-- Browse modes the strip offers: the filesystem view plus every browse
-- dimension; only the filesystem view when browsing by metadata is disabled.
local function _availableModes()
    local BM = _BrowseMeta()
    return (BM and BM.isEnabled()) and BM.MODES or { "normal" }
end

-- Strip items in saved order: the browse tabs followed by the search button
-- by default.
function M.getTabsOrder()
    local BM       = _BrowseMeta()
    local defaults = { _unpack(BM and BM.MODES or { "normal" }) }
    defaults[#defaults + 1] = SEARCH_ID
    return Config.mergeOrder(SUISettings:readSetting(TABS_ORDER_KEY), defaults)
end

function M.setTabsOrder(order) SUISettings:saveSetting(TABS_ORDER_KEY, order) end

-- Ordered { id, label, visible } entries for the tabs and search button that
-- are available in the current configuration.
function M.getTabsEntries()
    local BM     = _BrowseMeta()
    local labels = { [SEARCH_ID] = _("Search") }
    for _i, mode in ipairs(_availableModes()) do
        labels[mode] = BM and BM.getModeLabel(mode) or _("Library")
    end
    local entries = {}
    for _i, id in ipairs(M.getTabsOrder()) do
        if labels[id] then
            entries[#entries + 1] = { id = id, label = labels[id], visible = M.isItemVisible(id) }
        end
    end
    return entries
end

-- Tab strip items of the visible entries; the search button gets a blank
-- cell of its width. Also returns whether the search button is shown.
local function _stripItems(search_w)
    local items, has_search = {}, false
    for _i, e in ipairs(M.getTabsEntries()) do
        if e.visible then
            if e.id == SEARCH_ID then
                has_search = true
                items[#items + 1] = { id = e.id, spacer_w = search_w }
            else
                items[#items + 1] = { id = e.id, label = e.label }
            end
        end
    end
    return items, has_search
end

-- True when `view` (see _installBackController) is a top-level view of the
-- library, where the tabs apply: the home folder, or the Authors/Series/Tags
-- lists. Folders below it, the books of one author/series/tag and a series
-- group are inner views.
local function _isLibraryRoot(view)
    if view.series then return false end
    local BM = _BrowseMeta()
    if BM then
        local ok, level = pcall(BM.getPathLevel, view.path)
        if ok and level then return level ~= "file_list" end
    end
    local home = _normHome()
    return home == nil or _normPath(view.path) == home
end

-- True when `view` is a folder of the filesystem. The Authors, Series and
-- Tags views, their lists and the series groups are virtual.
local function _isFilesystemView(view)
    if view.series then return false end
    local BM = _BrowseMeta()
    return not BM or BM.getPathMode(view.path) == "normal"
end

-- Name shown in place of the tabs on an inner view.
local function _innerViewLabel(view)
    if view.series then return view.series._sg_series_name or "" end
    local BM = _BrowseMeta()
    local virtual = BM and BM.getPathLabel(view.path)
    if virtual then return virtual end
    return view.path:match("([^/]+)/*$") or view.path
end

local function _applyTabs(fm_self, tb)
    local m = _tabsMetrics()
    local iw, sw = m.iw, m.sw
    local bar_h  = tb:getHeight()

    -- Menu button (native right button).
    local menu_x = sw - m.margin - iw - m.tap_pad_h
    _setupMenuButton(fm_self, tb, true, function(rb)
        _placeMenuButton(rb, iw, menu_x, "right", TABS_ICON_SCALE)
        _padTapArea(rb, m)
    end)

    -- The menu actions only apply to the filesystem views: the button is moved
    -- off-screen with its callbacks disabled elsewhere.
    local function setMenuVisible(visible)
        local rb, snap = tb.right_button, fm_self._titlebar_rb
        if not (rb and snap) then return end
        rb.overlap_offset = { visible and menu_x or _hideOffset(sw), 0 }
        if visible then
            rb.callback      = snap.callback
            rb.hold_callback = snap.hold_cb
        else
            rb.callback      = function() end
            rb.hold_callback = function() end
        end
    end

    -- Back button; shown only when there is somewhere to go back to.
    -- Same icon/slot scale as search and menu so glyphs match visually.
    _hideNativeLeftButton(fm_self, tb)
    local up_btn  = _newBackButton(tb, fm_self, iw, "left", TABS_ICON_SCALE)
    _padTapArea(up_btn, m)
    local up_x = m.margin - m.tap_pad_h
    up_btn.overlap_offset = { up_x, 0 }
    table.insert(tb, up_btn)
    fm_self._titlebar_up_btn = up_btn

    -- Search button: sits in its own cell of the tab strip and is shown only
    -- with the tabs.
    local items, has_search = _stripItems(iw)
    local search_btn
    if has_search then
        search_btn = _newSearchButton(tb, fm_self, iw, nil, TABS_ICON_SCALE)
        _padTapArea(search_btn, m)
        search_btn.overlap_offset = { _hideOffset(sw), 0 }
        table.insert(tb, search_btn)
        fm_self._titlebar_search_btn = search_btn
    end

    -- Tab strip: flush left while the back button is hidden, shifted right
    -- of it while shown. It always ends where the menu button begins.
    local strip_x_flush = m.margin
    local strip_x_back  = m.margin + iw + m.back_gap
    local strip = require("engines/sui_tab_strip").new{
        width     = menu_x - strip_x_flush,
        height    = bar_h,
        face      = m.face,
        tabs      = items,
        ink_fn    = _barInk,
        on_select = function(mode)
            local BM = _BrowseMeta()
            if BM then BM.activateMode(fm_self, mode) end
        end,
        -- Long press: switch to the tab, then show its sort options.
        on_hold = function(mode)
            local BM = _BrowseMeta()
            if not BM then return end
            if BM.getCurrentMode(fm_self.file_chooser) ~= mode then
                BM.activateMode(fm_self, mode)
            end
            require("features/library/sui_sort_sheet").show(fm_self, mode)
        end,
    }
    strip.overlap_align = nil
    strip:setSpan(strip_x_flush, menu_x - strip_x_flush)
    table.insert(tb, strip)
    fm_self._titlebar_tab_strip = strip

    -- Library root: tabs with the current mode highlighted. Inner view: its name.
    _installBackController(fm_self, up_x, function(_, view, back_visible)
        local x = back_visible and strip_x_back or strip_x_flush
        strip:setSpan(x, menu_x - x)
        setMenuVisible(_isFilesystemView(view))
        if _isLibraryRoot(view) then
            local BM = _BrowseMeta()
            strip:setActive(BM and BM.getPathMode(view.path) or "normal")
        else
            strip:setLabel(_innerViewLabel(view))
        end
        -- The search button sits in its cell; hidden with a label.
        if search_btn then
            local cell_x = strip:getCellX(SEARCH_ID)
            search_btn.overlap_offset = {
                cell_x and (x + cell_x - m.tap_pad_h) or _hideOffset(sw), 0 }
        end
    end)

    _refreshBackState(fm_self)
end

-- ---------------------------------------------------------------------------
-- FM titlebar — apply
-- ---------------------------------------------------------------------------

function M.apply(fm_self)
    if not M.isEnabled() then return end
    local tb = fm_self.title_bar
    if not tb then return end
    if fm_self._titlebar_patched then return end
    fm_self._titlebar_patched = true
    _installBarScrim(tb)

    -- The tabs layout needs the bar built with the tabs metrics; until the
    -- next layout rebuild a bar built for the classic style keeps that style.
    if M.isTabsStyle() and tb._sui_tabs_bar then
        _applyTabs(fm_self, tb)
    else
        _applyClassic(fm_self, tb)
    end
    _installTitleFocus(fm_self.file_chooser, tb)
end

-- Runs `fn(...)` (the FM layout build) so that the title bar it creates gets
-- the compact tabs metrics: no title or subtitle, and a height of one text row
-- plus a vertical padding. A pass-through for the classic style. Returns nothing.
function M.runWithStyleMetrics(fn, ...)
    if not M.isTabsStyle() then
        fn(...)
        return
    end
    local TitleBar = require("ui/widget/titlebar")
    local m        = _tabsMetrics()
    local own_new  = rawget(TitleBar, "new")
    local orig_new = TitleBar.new

    TitleBar.new = function(class, attrs, ...)
        TitleBar.new = own_new                 -- only the first bar is affected
        attrs = attrs or {}
        attrs.title             = ""
        attrs.subtitle          = nil
        attrs.title_face        = m.face
        attrs.title_top_padding = m.pad_v
        attrs.bottom_v_padding  = m.pad_v
        local bar = orig_new(class, attrs, ...)
        bar._sui_tabs_bar = true
        return bar
    end

    local ok, err = pcall(fn, ...)
    TitleBar.new = own_new
    if not ok then error(err, 0) end
end

-- ---------------------------------------------------------------------------
-- FM titlebar — restore / reapply
-- ---------------------------------------------------------------------------

function M.restore(fm_self)
    local tb = fm_self.title_bar
    if not tb then return end
    if not fm_self._titlebar_patched then return end
    _removeBarScrim(tb)
    _removeTitleFocus(fm_self.file_chooser)

    -- Restore the setRightIcon patch.
    if fm_self._titlebar_orig_setRightIcon then
        tb.setRightIcon = fm_self._titlebar_orig_setRightIcon
        fm_self._titlebar_orig_setRightIcon = nil
    end

    -- Restore left and right buttons.
    if tb.right_button then _restoreBtn(tb.right_button, fm_self._titlebar_rb) end
    fm_self._titlebar_rb = nil
    if tb.left_button  then _restoreBtn(tb.left_button,  fm_self._titlebar_lb) end
    fm_self._titlebar_lb = nil

    -- Remove the injected widgets (back, search, browse buttons and tab strip)
    -- from the TitleBar OverlapGroup.
    for _, key in ipairs({ "_titlebar_up_btn", "_titlebar_search_btn", "_titlebar_browse_btn", "_titlebar_tab_strip" }) do
        local btn = fm_self[key]
        if btn then
            -- Free the C/FFI image memory
            if btn.image then
                pcall(btn.image.free, btn.image)
            elseif btn.free then
                pcall(btn.free, btn)
            end
            
            -- Remove from the visual table (OverlapGroup)
            for i = #tb, 1, -1 do
                if tb[i] == btn then 
                    table.remove(tb, i)
                    break 
                end
            end
            fm_self[key] = nil
        end
    end
    fm_self._simpleui_browse_x_compact  = nil
    fm_self._titlebar_browse_gen_hooked = nil

    -- Restore file-chooser patches.
    local fc = fm_self.file_chooser
    if fc then
        fc._simpleui_gen_listeners = nil
        if fm_self._titlebar_orig_fc_genItemTable then
            fc.genItemTable = fm_self._titlebar_orig_fc_genItemTable
        end
        if fm_self._titlebar_orig_fc_onFolderUp ~= nil then
            fc.onFolderUp = fm_self._titlebar_orig_fc_onFolderUp
        else
            fc.onFolderUp = nil
        end
        if fm_self._titlebar_orig_fc_onGotoPage then
            fc.onGotoPage = fm_self._titlebar_orig_fc_onGotoPage
        end
    end
    fm_self._titlebar_orig_fc_genItemTable = nil
    fm_self._titlebar_orig_fc_onFolderUp   = nil
    fm_self._titlebar_orig_fc_onGotoPage   = nil

    if fm_self._titlebar_orig_title_set and tb.setTitle then
        tb:setTitle("")
        fm_self._titlebar_orig_title_set = nil
    end

    fm_self._titlebar_patched = nil
end

function M.reapply(fm_self)
    -- Improvement #4: reset BrowseMeta cache so a newly-enabled module is
    -- picked up on the next apply() rather than using a stale false value.
    _resetBMCache()
    M.restore(fm_self)
    M.apply(fm_self)
end

-- ---------------------------------------------------------------------------
-- Sub-pages widget titlebar — applyToSub / restoreSub
-- ---------------------------------------------------------------------------

-- Hide the native Menu return chevron (bottom-left "back.top"). SimpleUI owns
-- back navigation via the title-bar sub_back button (and the navbar), so the
-- footer arrow is redundant on every sub page that goes through applyToSub.
local function _suppressNativeReturnArrow(widget)
    if not widget then return end
    -- Zero the leading span so the return group takes no horizontal room.
    if widget.return_button and widget.return_button[1] then
        if not widget._titlebar_sub_orig_return_btn then
            widget._titlebar_sub_orig_return_btn = widget.return_button[1]
        end
        widget.return_button[1] = require("ui/widget/verticalspan"):new{ width = 0 }
    end
    local pra = widget.page_return_arrow
    if not pra then return end
    if widget._titlebar_sub_pra_suppressed then return end
    widget._titlebar_sub_pra_suppressed = true
    -- Save original methods (instance or class) so restoreSub can put them back.
    if widget._titlebar_sub_orig_pra_showHide == nil then
        widget._titlebar_sub_orig_pra_showHide = rawget(pra, "showHide") or false
    end
    if widget._titlebar_sub_orig_pra_show == nil then
        widget._titlebar_sub_orig_pra_show = rawget(pra, "show") or false
    end
    if widget._titlebar_sub_orig_pra_hide == nil then
        widget._titlebar_sub_orig_pra_hide = rawget(pra, "hide") or false
    end
    pcall(function()
        if pra.hide then pra:hide() end
    end)
    -- Block every path that could un-hide the arrow (Menu:updatePageInfo,
    -- applyCollBackIcon repaints, etc.).
    pra.showHide = function() end
    pra.show     = function() end
    pra.hide     = function() end
    -- Collapse its geometry so it cannot reserve layout space either.
    if pra.dimen then
        pra.dimen.w = 0
        pra.dimen.h = 0
    end
    if pra.width  then pra.width  = 0 end
    if pra.height then pra.height = 0 end
end


function M.applyToSub(widget)
    if not M.isEnabled() then return end
    local tb = widget.title_bar
    if not tb then return end
    if widget._titlebar_sub_patched then return end
    widget._titlebar_sub_patched = true
    _installBarScrim(tb)

    local lp                = _layoutParams(tb)
    local iw, pad, gap, sw  = lp.iw, lp.pad, lp.gap, lp.sw

    -- Tabs style: a bar built with the tabs metrics mirrors the library bar
    -- (back button, bold title, menu button) with fixed button positions.
    local tabs_m = M.isTabsStyle() and tb._sui_tabs_bar and _tabsMetrics() or nil
    if tabs_m then iw = tabs_m.iw end

    local show_menu      = tabs_m ~= nil or M.isItemVisible("sub_menu")
    local show_close     = tabs_m == nil and M.isItemVisible("sub_close")
    local show_back      = tabs_m ~= nil or M.isItemVisible("sub_back")

    local cfg     = M.getSubConfig()
    local visible = {}
    if show_menu  then visible["sub_menu"]  = true end
    if show_close then visible["sub_close"] = true end
    if show_back  then visible["sub_back"]  = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local menu_x = tabs_m and (sw - tabs_m.margin - iw - tabs_m.tap_pad_h)
    local back_x = tabs_m and (tabs_m.margin - tabs_m.tap_pad_h)

    -- Horizontal position of a button; nil when it has no slot.
    local function slotX(id)
        if tabs_m then return id == "sub_back" and back_x or menu_x end
        local s = slot_map[id]
        return s and _buttonX(s.side, s.slot, iw, pad, gap, sw)
    end

    -- Side of the bar a button sits on ("left" | "right"); nil without a slot.
    local function slotSide(id)
        if tabs_m then return id == "sub_back" and "left" or "right" end
        local s = slot_map[id]
        return s and s.side
    end

    local function placeBtn(id, btn)
        local x = slotX(id)
        if not x then return end
        if id == "sub_menu" then
            _placeMenuButton(btn, iw, x, slotSide(id), tabs_m and TABS_ICON_SCALE or nil)
        else
            _resizeAndStrip(btn, iw)
            btn.overlap_align  = nil
            btn.overlap_offset = { x, 0 }
        end
        if tabs_m then _padTapArea(btn, tabs_m) end
    end

   -- Left button (hamburger / sub_menu).
    if tb.left_button then
        local lb = tb.left_button
        widget._titlebar_sub_lb = _snapBtn(lb, { save_icon = true })
        if show_menu then
            placeBtn("sub_menu", lb)
            -- Apply the menu icon only when the button is currently showing
            -- the hamburger (not "check" or another select-mode icon).
            -- On a fresh applyToSub the button is always in menu state, but on
            -- a reapply triggered while select-mode is active the "check" icon
            -- set by the host must be kept.
            -- lb.icon (the IconButton field, kept in sync by setIcon) is read
            -- rather than lb.image.icon, because the icon helpers clear image.icon.
            local _is_menu_state = (lb.icon == nil or lb.icon == "appbar.menu")
            if _is_menu_state then _applyMenuIcon(lb) end

            -- Patch TitleBar:setLeftIcon so the custom menu icon survives
            -- icon changes made by the host widget (e.g. collections toggles
            -- the left button between "appbar.menu" and "check" when entering
            -- or leaving select mode). We must:
            --   • let "check" (and any non-menu icon) pass through unchanged;
            --   • re-apply the custom icon when the host restores "appbar.menu".
            -- The original icon name used by KOReader for the hamburger menu in
            -- BookList / Menu widgets is "appbar.menu".
            --
            -- _sub_lb_is_menu: tracks whether the left button is currently in
            -- hamburger-menu state (true) or in some other state like "check"
            -- (false).  Used by reapply to avoid overwriting the check icon.
            widget._titlebar_sub_lb_is_menu = true
            local orig_setLeftIcon = tb.setLeftIcon
            widget._titlebar_sub_orig_setLeftIcon = orig_setLeftIcon
            tb.setLeftIcon = function(tb_self, icon, ...)
                local result = orig_setLeftIcon(tb_self, icon, ...)
                if icon == "appbar.menu" then
                    -- Host is restoring the hamburger — re-apply the menu icon.
                    widget._titlebar_sub_lb_is_menu = true
                    if tb_self.left_button then
                        _applyMenuIcon(tb_self.left_button)
                        local UIManager = require("ui/uimanager")
                        UIManager:setDirty(tb_self.show_parent or widget, "ui", tb_self.dimen)
                    end
                else
                    -- Any other icon (e.g. "check"): record that we are NOT in
                    -- menu state so a concurrent reapply does not overwrite it.
                    widget._titlebar_sub_lb_is_menu = false
                end
                return result
            end
        else
            lb.overlap_align  = nil
            lb.overlap_offset = { _hideOffset(sw), 0 }
        end
    end

    -- Right button (close). Hidden by pushing it off-screen so it receives no taps.
    -- NOTE: do NOT zero rb.dimen — a {w=0,h=0} dimen at (0,0) leaves a phantom
    -- bounding-box at the top-left corner that the KOReader hit-test traversal
    -- visits before the injected sub_back_btn, swallowing taps on it.
    -- Using overlap_offset = {_hideOffset(sw), 0} is the same strategy used
    -- everywhere else in this file and is safe to restore via _snapBtn.
    if tb.right_button then
        local rb = tb.right_button
        widget._titlebar_sub_rb = _snapBtn(rb, { save_callback = true, save_dimen = true })
        if show_close then
            placeBtn("sub_close", rb)
        else
            rb.overlap_align  = nil
            rb.overlap_offset = { _hideOffset(sw), 0 }
            rb.callback       = function() end
            rb.hold_callback  = function() end
        end
    end

    -- Title strip (tabs style): the page title as a bold left-aligned label,
    -- flush left while the back button is hidden and right of it while shown.
    local strip, strip_x_flush, strip_x_back
    if tabs_m then
        strip_x_flush = tabs_m.margin
        strip_x_back  = tabs_m.margin + iw + tabs_m.back_gap
        strip = require("engines/sui_tab_strip").new{
            width  = menu_x - strip_x_flush,
            height = tb:getHeight(),
            face   = tabs_m.face,
            ink_fn = _barInk,
        }
        strip.overlap_align = nil
        strip:setSpan(strip_x_flush, menu_x - strip_x_flush)
        -- The host may already have set the title on the native title widget
        -- after the bar was built; take it from there and blank the native one.
        local native = tb.title_widget and tb.title_widget.text
        widget._titlebar_sub_title = (native and native ~= "") and native or widget.title or ""
        strip:setLabel(widget._titlebar_sub_title)
        table.insert(tb, strip)
        widget._titlebar_sub_strip = strip
        if tb.setTitle then pcall(tb.setTitle, tb, "", true) end

        -- The host updates the title through the title bar; route it to the strip.
        widget._titlebar_sub_orig_setTitle = rawget(tb, "setTitle") or false
        tb.setTitle = function(tb_self, text)
            widget._titlebar_sub_title = text or ""
            strip:setLabel(widget._titlebar_sub_title)
            require("ui/uimanager"):setDirty(tb_self.show_parent or widget, "ui", tb_self.dimen)
        end
    end

    -- Left button (back / pagination)
    if show_back then
        do
            if slotX("sub_back") then
                -- Same icon/slot scale as search/menu on the library tabs bar.
                local sub_back_btn = _newBackButton(tb, widget, iw, slotSide("sub_back"),
                    tabs_m and TABS_ICON_SCALE or nil)
                if tabs_m then _padTapArea(sub_back_btn, tabs_m) end
                sub_back_btn.overlap_offset = { slotX("sub_back"), 0 }
                table.insert(tb, sub_back_btn)
                widget._titlebar_sub_back_btn = sub_back_btn

                -- Applies the correct state to sub_back with unified logic across
                -- all sub-widgets (collections, history, coll_list, …). The tabs
                -- style only leaves the view; the classic style also pages back:
                --
                --   onReturn              → show; tap = onReturn (or onClose fallback)
                --   no onReturn           → hide (nothing to go back to)
                --   classic, page > 1     → show; tap = previous page, hold = page 1
                --
                -- This mirrors the native bar: page_return_arrow is enabled when
                -- #self.paths > 0 (there is somewhere to go back to).
                local paginates = tabs_m == nil
                local function _applySubBackButtonState(w_self, page)
                    local btn = w_self._titlebar_sub_back_btn
                    if not btn then return end

                    local has_return = (w_self.onReturn ~= nil)
                    local pages_back = paginates and page > 1
                    local visible    = pages_back or has_return

                    if not visible then
                        -- Nothing to go back to: hide the button.
                        btn.overlap_offset = { _hideOffset(sw), 0 }
                        btn.callback       = function() end
                        btn.hold_callback  = function() end
                    else
                        -- Show the button with the current icon (respects SUIStyle override).
                        _applyBackIcon(btn)

                        btn.overlap_offset = { slotX("sub_back"), 0 }

                        if pages_back then
                            -- Paginated: tap goes back one page, hold goes to page 1.
                            btn.callback      = function() w_self:onGotoPage(page - 1) end
                            btn.hold_callback = function() w_self:onGotoPage(1) end
                        else
                            -- A return destination (e.g. inside a collection, going
                            -- back to the collection list via onReturn).
                            btn.callback = function()
                                if w_self.onReturn then
                                    w_self:onReturn()
                                elseif w_self.onClose then
                                    w_self:onClose()
                                else
                                    require("ui/uimanager"):close(w_self)
                                end
                            end
                            btn.hold_callback = function() end
                        end
                    end
                    if strip then
                        local x = visible and strip_x_back or strip_x_flush
                        strip:setSpan(x, menu_x - x)
                        strip:setLabel(w_self._titlebar_sub_title)
                    end
                    if w_self.title_bar then
                        require("ui/uimanager"):setDirty(w_self.title_bar.show_parent or w_self, "ui", w_self.title_bar.dimen)
                    end
                end

                _applySubBackButtonState(widget, widget.page or 1)
                
                local orig_updatePageInfo = rawget(widget, "updatePageInfo")
                widget._titlebar_sub_orig_updatePageInfo = orig_updatePageInfo or false
                local inherited = widget.updatePageInfo
                widget.updatePageInfo = function(w_self, select_number)
                    if inherited then inherited(w_self, select_number) end
                    _applySubBackButtonState(w_self, w_self.page or 1)
                end

                _suppressNativeReturnArrow(widget)
            end
        end
    end
    -- Always suppress the native bottom-left return chevron on sub pages
    -- (Collections, History, coll_list, …), whether or not sub_back is shown.
    _suppressNativeReturnArrow(widget)

    _installTitleFocus(widget, tb)
end

function M.restoreSub(widget)
    local tb = widget.title_bar
    if not tb then return end
    if not widget._titlebar_sub_patched then return end
    _removeBarScrim(tb)
    _removeTitleFocus(widget)
    if tb.left_button  then _restoreBtn(tb.left_button,  widget._titlebar_sub_lb) end
    if tb.right_button then _restoreBtn(tb.right_button, widget._titlebar_sub_rb) end

    -- Restore the setLeftIcon patch.
    if widget._titlebar_sub_orig_setLeftIcon ~= nil then
        tb.setLeftIcon = widget._titlebar_sub_orig_setLeftIcon
        widget._titlebar_sub_orig_setLeftIcon = nil
    end

    if widget._titlebar_sub_orig_setTitle ~= nil then
        tb.setTitle = widget._titlebar_sub_orig_setTitle or nil
        widget._titlebar_sub_orig_setTitle = nil
    end
    if widget._titlebar_sub_strip then
        local strip = widget._titlebar_sub_strip
        for i = #tb, 1, -1 do
            if tb[i] == strip then table.remove(tb, i); break end
        end
        pcall(strip.free, strip)
        widget._titlebar_sub_strip = nil
        widget._titlebar_sub_title = nil
    end

    widget._titlebar_sub_lb      = nil
    widget._titlebar_sub_rb      = nil
    widget._titlebar_sub_patched = nil
    widget._titlebar_sub_lb_is_menu = nil

    if widget._titlebar_sub_back_btn then
        local btn = widget._titlebar_sub_back_btn
        if btn.image then pcall(btn.image.free, btn.image) end
        if tb then
            for i = #tb, 1, -1 do
                if tb[i] == btn then table.remove(tb, i); break end
            end
        end
        widget._titlebar_sub_back_btn = nil
        widget._simpleui_force_refresh_sub_back = nil
    end

    if widget._titlebar_sub_orig_updatePageInfo ~= nil then
        local orig = widget._titlebar_sub_orig_updatePageInfo
        widget.updatePageInfo = orig ~= false and orig or nil
        widget._titlebar_sub_orig_updatePageInfo = nil
    end

    if widget._titlebar_sub_orig_return_btn and widget.return_button then
        widget.return_button[1] = widget._titlebar_sub_orig_return_btn
        widget._titlebar_sub_orig_return_btn = nil
    end

    -- Restore page_return_arrow show/hide methods and re-evaluate visibility.
    local pra = widget.page_return_arrow
    if pra then
        local function restoreMethod(field, saved_key)
            local orig = widget[saved_key]
            if orig == nil then return end
            if orig ~= false then
                pra[field] = orig
            else
                pra[field] = nil
            end
            widget[saved_key] = nil
        end
        restoreMethod("showHide", "_titlebar_sub_orig_pra_showHide")
        restoreMethod("show",     "_titlebar_sub_orig_pra_show")
        restoreMethod("hide",     "_titlebar_sub_orig_pra_hide")
        widget._titlebar_sub_pra_suppressed = nil
        pcall(function()
            pra:showHide(widget.onReturn ~= nil)
            if pra.enableDisable then
                pra:enableDisable(widget.paths and #widget.paths > 0)
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- reapplyAll — re-applies to the FM and every live injected widget
-- ---------------------------------------------------------------------------

function M.reapplyAll(fm_self, window_stack)
    local logger = require("logger")
    if fm_self then
        local ok, err = pcall(M.reapply, fm_self)
        if not ok then
            logger.warn("simpleui: titlebar.reapplyAll FM failed:", tostring(err))
        end
    end
    if type(window_stack) == "table" then
        for _, entry in ipairs(window_stack) do
            local w = entry.widget
            if w and w._titlebar_sub_patched then
                local ok, err = pcall(function()
                    M.restoreSub(w)
                    M.applyToSub(w)
                end)
                if not ok then
                    logger.warn("simpleui: titlebar.reapplyAll widget failed:", tostring(err))
                end
            end
        end
    end
end

--- Refreshes the browse button icon in the live FM titlebar to reflect the
--- current mode AND the current SUIStyle override.  Called by sui_style.lua
--- after the user picks a new Browse Meta icon override.
--- @param fm   FileManager instance (may be nil — in that case does nothing)
function M.refreshBrowseIcons(fm)
    if not (fm and fm._titlebar_browse_btn) then return end
    local browse_btn = fm._titlebar_browse_btn
    if not browse_btn then return end

    local BM = _BrowseMeta()
    local mode = "normal"
    if BM and fm.file_chooser then
        mode = BM.getCurrentMode(fm.file_chooser) or "normal"
    end
    
    _applyBrowseIcon(browse_btn, mode)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and fm.title_bar then
        UIManager:setDirty(fm, "ui", fm.title_bar.dimen)
    end
end

-- Repaints the tab strip of the file manager title bar after the accent
-- colour or night mode changed, so its active indicator follows the accent.
function M.refreshAccent()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    local strip = fm and fm._titlebar_tab_strip
    if not (strip and strip:refresh()) then return end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and fm.title_bar then
        UIManager:setDirty(fm, "ui", fm.title_bar.dimen)
    end
end

return M
