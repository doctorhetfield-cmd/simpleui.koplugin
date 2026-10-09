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

local Screen = require("device").screen

-- Plugin directory resolved once at load time (used for browse-mode icon paths).
local _PLUGIN_DIR = require("infra/sui_paths").getPluginDir()

-- Full paths for the four browse-mode icons (plugin-bundled defaults).
local _BROWSE_ICONS_DEFAULT = {
    normal = _PLUGIN_DIR .. "icons/default.svg",
    author = _PLUGIN_DIR .. "icons/author.svg",
    series = _PLUGIN_DIR .. "icons/series.svg",
    tags   = _PLUGIN_DIR .. "icons/tags.svg",
}

-- Maps browse mode → SUIStyle slot id for user overrides.
local _BM_SLOT = {
    normal = "sui_browse_normal",
    author = "sui_browse_author",
    series = "sui_browse_series",
    tags   = "sui_browse_tags",
}

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

local _SIZE_SCALE = { compact = 0.75, default = 1.0, large = 1.3 }

local _VIS_DEFAULTS = {
    fm_menu       = true,
    fm_home       = true, 
    fm_back       = true,
    fm_title      = true,
    fm_search     = true,
    fm_browse     = false,
    sub_menu      = true,
    sub_close     = true,
    sub_back      = true,
}

-- Default side/order configs for FM and injected widgets.
local _FM_DEFAULTS = {
    side        = { fm_menu = "right", fm_back = "left", fm_home = "left", fm_search = "left", fm_browse = "right" },
    order_left  = { "fm_back", "fm_home", "fm_search" },
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
    { id = "fm_home",       label = function() return _("Home")              end, ctx = "fm"  },
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

function M.getSizeKey()   return SUISettings:readSetting(SIZE_KEY) or "default" end
function M.setSizeKey(v)  SUISettings:saveSetting(SIZE_KEY, v) end
function M.getSizeScale() return _SIZE_SCALE[M.getSizeKey()] or 1.0 end

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
-- DOES NOT handle series-view (path unchanged from parent) — caller checks
-- fc.item_table._sg_is_series_view separately.

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

-- M.isAtRoot: exported so sui_patches can use the same criterion without
-- duplicating the logic or depending on the _simpleui_has_go_up flag.
local function _isAtRoot(fc)
    if not fc then return true end
    -- Series view always has a parent even if the path is the home root.
    if fc.item_table and fc.item_table._sg_is_series_view then return false end
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

-- Wallpaper backdrop painted behind a title bar across the full page width.
-- Strength is read at paint time so opacity changes need no re-hook. The
-- instance-level paintTo is dropped again to return to the class method.
local function _installBarScrim(tb)
    if rawget(tb, "paintTo") then return end
    local orig = tb.paintTo
    function tb:paintTo(bb, x, y)
        local ok, WP = pcall(require, "features/sui_wallpaper")
        local strength = ok and WP.getTitlebarBackdropStrength() or 0
        if strength > 0 then
            local h = (self.dimen and self.dimen.h) or self:getHeight()
            if h > 0 then WP.paintBackdrop(bb, 0, y, Screen:getWidth(), h, strength) end
        end
        return orig(self, bb, x, y)
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
        btn.image.width  = new_w
        btn.image.height = new_w
        if btn.image.is_sui_wrapper then
            local font_size = math.floor(math.min(new_w, new_w) * 0.65)
            local Font = require("ui/font")
            btn.image.face = Font:getFace(SUIStyle().FACE_ICONS, font_size)
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
            local font_size = math.floor(math.min(new_w, new_w) * 0.65)
            local Font = require("ui/font")
            btn.label_widget.face = Font:getFace(SUIStyle().FACE_ICONS, font_size)
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

-- Metrics of the compact tabs-style bar. The icon size equals the text height
-- and is also the menu icon size of the classic style.
local function _tabsMetrics()
    local S    = SUIStyle()
    local face = require("ui/font"):getFace(S.FACE_REGULAR, S.FS_BODY)
    local probe = require("ui/widget/textwidget"):new{ text = "A", face = face, padding = 0 }
    local text_h = probe:getSize().h
    probe:free()
    return {
        face      = face,
        iw        = text_h,                        -- icon size == text height
        pad_v     = Screen:scaleBySize(7),         -- above and below the text row
        margin    = SideM(),                       -- screen edge to icon
        back_gap  = Screen:scaleBySize(14),        -- back icon to the content beside it
        tap_pad_h = Screen:scaleBySize(8),         -- horizontal tap-area padding
        sw        = Screen:getWidth(),
    }
end

-- Sizes the menu button like the tabs-style menu icon and centres it inside a
-- classic slot of width `slot_w` whose left edge is `x`.
local function _placeMenuButton(btn, slot_w, x)
    local icon_w = _tabsMetrics().iw
    local inset  = math.floor((slot_w - icon_w) / 2)
    _resizeAndStrip(btn, icon_w)
    btn.padding_top = math.max(inset, 0)
    btn:update()
    btn.overlap_align  = nil
    btn.overlap_offset = { x + inset, 0 }
end

-- ---------------------------------------------------------------------------
-- _resolveIsSub: single authoritative is_sub resolver.
-- Replaces the go-up item scan with a path-based approach, handling
-- SimpleUI's virtual folder and series-view cases:
--
--   1. Series view (_sg_is_series_view): the path does NOT change when the
--      user drills into a series group — fc.path stays the parent's path.
--      We check the flag first because _isSubFolder would return false for a
--      series opened from the home root, hiding the back button incorrectly.
--
--   2. BrowseMeta virtual paths: the VROOT marker (U+E257) sits after the
--      base_dir segment, so _isSubFolder's prefix test against home_dir still
--      works correctly without special-casing.
--
--   3. Normal filesystem: _isSubFolder compares realpath-normalised strings,
--      handling Android /sdcard symlinks consistently.
--
-- ---------------------------------------------------------------------------

local function _resolveIsSub(fc_self)
    -- Series view: path is unchanged from parent, so path comparison is blind.
    -- The flag is set by sui_foldercovers when it calls switchItemTable.
    if fc_self.item_table and fc_self.item_table._sg_is_series_view then
        return true
    end
    -- Path-based test: handles normal folders, locked-home, and virtual paths.
    return _isSubFolder(fc_self.path)
end


local function _hideOffset(sw)
    return sw * 2
end

-- ---------------------------------------------------------------------------
-- Shared building blocks (FM styles and sub-pages)
-- ---------------------------------------------------------------------------

-- Default back icon as { icon = <native name> } or { file = <path> }.
-- LTR layouts use the plugin's left-aligned chevron; mirrored (RTL) layouts
-- use the native right chevron.
local function _backIcon()
    local mirrored = false
    pcall(function() mirrored = require("ui/bidi").mirroredUILayout() end)
    if mirrored then return { icon = "chevron.right" } end
    return { file = Config.ICON.back }
end

-- Shows the back icon: the SUIStyle override when set, `back_icon` (see
-- _backIcon) otherwise. .icon and .file are mutually exclusive in
-- ImageWidget:init (.icon wins), so the field that is not wanted is cleared.
local function _applyBackIcon(btn, back_icon)
    local _ss = SUIStyle()
    if _ss and _ss.applyIconToBtn("sui_back", btn) then return end
    if _ss and _ss.restoreDefaultIcon then
        _ss.restoreDefaultIcon(btn, back_icon.icon, back_icon.file)
    elseif btn.image then
        btn.image.icon = back_icon.icon
        btn.image.file = back_icon.file
        _reloadImage(btn.image)
    end
end

-- Shows the menu icon: the SUIStyle override when set, the plugin's default
-- menu icon otherwise.
local function _applyMenuIcon(btn)
    local _ss = SUIStyle()
    if _ss and _ss.applyIconToBtn("sui_menu", btn) then return end
    if _ss and _ss.restoreDefaultIcon then
        _ss.restoreDefaultIcon(btn, nil, Config.ICON.menu)
    elseif btn.image then
        btn.image.icon = nil
        btn.image.file = Config.ICON.menu
        _reloadImage(btn.image)
    end
end

-- Creates the injected back button, sized and styled like the other title-bar
-- buttons. Its callbacks are installed by the owning state controller.
local function _newBackButton(tb, parent, iw, back_icon)
    local IconButton = require("ui/widget/iconbutton")
    -- IconButton only accepts a native icon name; a file-based icon is
    -- swapped in by _applyBackIcon once the button exists.
    local btn = IconButton:new{
        icon        = back_icon.icon or "chevron.left",
        width       = iw,
        height      = iw,
        padding     = tb.button_padding or Screen:scaleBySize(11),
        show_parent = tb.show_parent or parent,
        callback    = function() end,
    }
    _resizeAndStrip(btn, iw)
    _applyBackIcon(btn, back_icon)
    btn.overlap_align = nil
    return btn
end

-- Builds the injected search button; it opens the file search of the library.
local function _newSearchButton(tb, fm_self, iw)
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
    refresh(fc, _resolveIsSub(fc), fc.page or 1)
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
-- `on_state(fc, is_sub, page, path, visible)` lets each title-bar style react
-- to the evaluated state (neighbour layout, tab strip content, …).
-- State is re-evaluated on genItemTable, onFolderUp and onGotoPage.

local function _installBackController(fm_self, back_icon, shown_x, on_state)
    local fc = fm_self.file_chooser
    if not fc then return end
    local UIManager = require("ui/uimanager")
    local sw        = Screen:getWidth()
    local paginates = not M.isTabsStyle()

    -- `page` is always passed explicitly to avoid stale cur_page reads.
    local function applyState(fc_self, is_sub, page, path)
        local btn = fm_self._titlebar_up_btn
        if not btn then return end
        local pages_back = paginates and page > 1
        local visible    = is_sub or pages_back

        if not visible then
            btn.overlap_offset = { _hideOffset(sw), 0 }
            btn.callback       = function() end
            btn.hold_callback  = function() end
        else
            _applyBackIcon(btn, back_icon)
            btn.overlap_offset = { shown_x, 0 }
            if pages_back then
                btn.callback      = function() fc_self:onGotoPage(page - 1) end
                btn.hold_callback = function() fc_self:onGotoPage(1) end
            else
                btn.callback      = function() fc_self:onFolderUp() end
                btn.hold_callback = function() end
            end
        end

        if on_state then on_state(fc_self, is_sub, page, fc_self.path, visible) end

        local tb = fm_self.title_bar
        if tb then
            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
        end
    end

    fm_self._simpleui_force_refresh_layout = applyState

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
        -- still hold the previous one on the initial load.
        local effective_path = path or fc_self.path
        local is_sub = _isSubFolder(effective_path)
        -- Series view keeps the parent's path, so the flag decides.
        if fc_self.item_table and fc_self.item_table._sg_is_series_view then
            is_sub = true
        end
        applyState(fc_self, is_sub, 1, effective_path)

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
            -- Arrived from the book dialog ("More by X"): one back press returns
            -- to the real folder, scrolled to the book, not to the Authors root.
            local origin = fc_self._sui_author_dialog_origin
            if origin and origin.path then
                local ok_pl, level = pcall(BM.getPathLevel, fc_self.path or "")
                if ok_pl and level == "file_list" then
                    fc_self._sui_author_dialog_origin = nil
                    BM.exitToNormal(fc_self, fm_self)
                    fc_self:changeToPath(origin.path, origin.file)
                    applyState(fc_self, _resolveIsSub(fc_self), 1)
                    return true
                end
            end
            -- At the dim_list level of a virtual tree, exit to the filesystem.
            local path = fc_self.path or ""
            if path:find("/", 1, true) then
                local ok_pl, level = pcall(BM.getPathLevel, path)
                if ok_pl and level == "dim_list" then
                    BM.exitToNormal(fc_self, fm_self)
                    applyState(fc_self, _resolveIsSub(fc_self), 1)
                    return true
                end
            end
        end
        local ok, result = xpcall(FileChooser_cls.onFolderUp, debug.traceback, fc_self, ...)
        applyState(fc_self, _resolveIsSub(fc_self), 1)
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
            applyState(fc_self, _resolveIsSub(fc_self), page)
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

    local show_home   = M.isItemVisible("fm_home")
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
    if show_home   then visible["fm_home"]   = true end
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
        _placeMenuButton(rb, iw, _buttonX(s.side, s.slot, iw, pad, gap, sw))
    end)

    -- Back button (injected; the native left button stays hidden).
    _hideNativeLeftButton(fm_self, tb)

    local s_up = show_up and slot_map["fm_back"]
    if s_up then
        local back_icon = _backIcon()
        local up_btn  = _newBackButton(tb, fm_self, iw, back_icon)
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
                    elseif id == "fm_home" then
                        widget = fm_self._titlebar_home_btn
                    end
                    if widget then list[#list + 1] = { btn = widget, slot = sl.slot } end
                end
            end
            return list
        end

        -- While the back button is hidden, left neighbours close the gap.
        local up_slot = s_up.slot
        _installBackController(fm_self, back_icon, up_x, function(_, _, _, _, visible_now)
            for _, entry in ipairs(leftSideBtns()) do
                local dslot = (not visible_now and entry.slot > up_slot)
                              and entry.slot - 1 or entry.slot
                entry.btn.overlap_offset = { _buttonX("left", dslot, iw, pad, gap, sw), 0 }
            end
        end)
    end

    -- Home button ------------------------------------------------------------
    if show_home then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["fm_home"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)
                local home_btn = IconButton:new{
                    icon        = "home",
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback = function()
                        local home = G_reader_settings:readSetting("home_dir")
                        if home and fm_self.file_chooser then
                            fm_self._navbar_suppress_path_change = true
                            fm_self.file_chooser:changeToPath(home)
                            fm_self._navbar_suppress_path_change = nil
                            if fm_self.updateTitleBarPath then
                                pcall(function() fm_self:updateTitleBarPath(home, true) end)
                            end
                        end
                    end,
                }
                _resizeAndStrip(home_btn, iw)
                home_btn.overlap_align  = nil
                home_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, home_btn)
                fm_self._titlebar_home_btn = home_btn
                if s.side == "left" then
                    local up_slot_h  = slot_map["fm_back"] and slot_map["fm_back"].slot or 0
                    local dslot_h    = s.slot > up_slot_h and s.slot - 1 or s.slot
                    local compact_x_h = _buttonX("left", dslot_h, iw, pad, gap, sw)
                    if (not show_up) or _isAtRoot(fm_self.file_chooser) then
                        home_btn.overlap_offset = { compact_x_h, 0 }
                    end
                end
            end
        end
    end
    
    -- Search button ----------------------------------------------------------
    -- Injected directly into the TitleBar OverlapGroup.
    -- All paddings (including top) are zeroed to align with the other buttons.

    local s_search = show_search and slot_map["fm_search"]
    if s_search then
        local search_btn = _newSearchButton(tb, fm_self, iw)
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
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local fc_ref       = fm_self.file_chooser
                        local cur_mode     = fc_ref and BM.getCurrentMode(fc_ref) or "normal"
                        local function _check(mode)
                            return cur_mode == mode and "\u{2713} " or "  "
                        end
                        -- Closes dialog, navigates to mode, and refreshes the icon.
                        local function _navigate(dlg, mode)
                            UIManager:close(dlg)
                            BM.navigateTo(fm_self, mode)
                            local _ss = SUIStyle()
                            if not (_ss and _ss.applyIconToBtn(_BM_SLOT[mode], browse_btn)) then
                                if _ss and _ss.restoreDefaultIcon then
                                    _ss.restoreDefaultIcon(browse_btn, nil, _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal)
                                elseif browse_btn.image then
                                    browse_btn.image.file = _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal
                                    _reloadImage(browse_btn.image)
                                elseif browse_btn.label_widget then
                                    browse_btn.label_widget.file = _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal
                                    _reloadImage(browse_btn.label_widget)
                                end
                            end
                            UIManager:setDirty(tb.show_parent or fm_self, "ui", tb.dimen)
                        end
                        local dlg
                        dlg = ButtonDialog:new{
                            title       = _("Browse library"),
                            title_align = "center",
                            buttons = {
                                {{ text = _check("normal") .. _("Default"),   callback = function() _navigate(dlg, "normal") end }},
                                {{ text = _check("author") .. _("By author"), callback = function() _navigate(dlg, "author") end }},
                                {{ text = _check("series") .. _("By series"), callback = function() _navigate(dlg, "series") end }},
                                {{ text = _check("tags")   .. _("By tags"),   callback = function() _navigate(dlg, "tags")   end }},
                                {{ text = _("Cancel"),                         callback = function() UIManager:close(dlg)     end }},
                            },
                        }
                        UIManager:show(dlg)
                    end,
                }

                _resizeAndStrip(browse_btn, iw)
                local _ss = SUIStyle()
                if not (_ss and _ss.applyIconToBtn(_BM_SLOT[mode0], browse_btn)) then
                    if _ss and _ss.restoreDefaultIcon then
                        _ss.restoreDefaultIcon(browse_btn, nil, _BROWSE_ICONS_DEFAULT[mode0] or _BROWSE_ICONS_DEFAULT.normal)
                    elseif browse_btn.image then
                        browse_btn.image.file = _BROWSE_ICONS_DEFAULT[mode0] or _BROWSE_ICONS_DEFAULT.normal
                        _reloadImage(browse_btn.image)
                    end
                end
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
                            local _ss2 = SUIStyle()
                            if not (_ss2 and _ss2.applyIconToBtn(_BM_SLOT[mode2], browse_btn)) then
                                if _ss2 and _ss2.restoreDefaultIcon then
                                    _ss2.restoreDefaultIcon(browse_btn, nil, _BROWSE_ICONS_DEFAULT[mode2] or _BROWSE_ICONS_DEFAULT.normal)
                                elseif browse_btn.image then
                                    browse_btn.image.file = _BROWSE_ICONS_DEFAULT[mode2] or _BROWSE_ICONS_DEFAULT.normal
                                    _reloadImage(browse_btn.image)
                                elseif browse_btn.label_widget then
                                    browse_btn.label_widget.file = _BROWSE_ICONS_DEFAULT[mode2] or _BROWSE_ICONS_DEFAULT.normal
                                    _reloadImage(browse_btn.label_widget)
                                end
                            end
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

-- True when `path` is a top-level view of the library, where the tabs apply:
-- the home folder, or the Authors/Series/Tags lists. Folders below it, the
-- books of one author/series/tag and a series group are inner views.
local function _isLibraryRoot(fc, path)
    if fc.item_table and fc.item_table._sg_is_series_view then return false end
    local BM = _BrowseMeta()
    if BM then
        local ok, level = pcall(BM.getPathLevel, path)
        if ok and level then return level ~= "file_list" end
    end
    local home = _normHome()
    return home == nil or _normPath(path) == home
end

-- True when the view is a folder of the filesystem. The Authors, Series and
-- Tags views, their lists and the series groups are virtual.
local function _isFilesystemView(fc, path)
    if fc.item_table and fc.item_table._sg_is_series_view then return false end
    local BM = _BrowseMeta()
    return not BM or BM.getPathMode(path) == "normal"
end

-- Name shown in place of the tabs on an inner view.
local function _innerViewLabel(fc, path)
    local it = fc.item_table
    if it and it._sg_is_series_view then return it._sg_series_name or "" end
    local BM = _BrowseMeta()
    local virtual = BM and BM.getPathLabel(path)
    if virtual then return virtual end
    return path:match("([^/]+)/*$") or path
end

local function _applyTabs(fm_self, tb)
    local m = _tabsMetrics()
    local iw, sw = m.iw, m.sw
    local bar_h  = tb:getHeight()

    -- Menu button (native right button).
    local menu_x = sw - m.margin - iw - m.tap_pad_h
    _setupMenuButton(fm_self, tb, true, function(rb)
        _resizeAndStrip(rb, iw)
        _padTapArea(rb, m)
        rb.overlap_align  = nil
        rb.overlap_offset = { menu_x, 0 }
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
    _hideNativeLeftButton(fm_self, tb)
    local back_icon = _backIcon()
    local up_btn  = _newBackButton(tb, fm_self, iw, back_icon)
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
        search_btn = _newSearchButton(tb, fm_self, iw)
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
        on_select = function(mode)
            if mode == "__path__" then return end
            local BM = _BrowseMeta()
            if not BM then return end

            local fc = fm_self.file_chooser
            -- 点 Library tab 时，如果当前不在书库根，强制回 home_dir
            if mode == "normal" and fc then
                local home = G_reader_settings:readSetting("home_dir")
                if home and home ~= "" and _normPath(fc.path) ~= _normPath(home) then
                    fm_self._navbar_suppress_path_change = true
                    fc:changeToPath(home)
                    fm_self._navbar_suppress_path_change = nil
                    if fm_self.updateTitleBarPath then
                        pcall(function() fm_self:updateTitleBarPath(home) end)
                    end
                    BM.setSavedMode("normal")
                    return
                end
            end

            BM.activateMode(fm_self, mode)
        end,
    }
    strip.overlap_align = nil
    strip:setSpan(strip_x_flush, menu_x - strip_x_flush)
    table.insert(tb, strip)
    fm_self._titlebar_tab_strip = strip

    -- 路径名现在是主 strip 的前置 tab：由 strip 自己渲染、下划线、间距。
    _installBackController(fm_self, back_icon, up_x, function(fc, _, _, path, back_visible)
        local x = back_visible and strip_x_back or strip_x_flush
        strip:setSpan(x, menu_x - x)

        local is_root = _isLibraryRoot(fc, path)
        if is_root then
            strip:setPathLabel(nil)
            local BM = _BrowseMeta()
            strip:setActive(BM and BM.getPathMode(path) or "normal")
        else
            -- 真实子目录：路径项显示并高亮，不落在任何 browse tab。
            strip:setPathLabel(_innerViewLabel(fc, path))
            strip:setActive("__path__")
        end

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
    for _, key in ipairs({ "_titlebar_home_btn", "_titlebar_up_btn", "_titlebar_search_btn", "_titlebar_browse_btn", "_titlebar_tab_strip"}) do
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
    local show_close     = M.isItemVisible("sub_close")
    local show_back      = tabs_m ~= nil or M.isItemVisible("sub_back")

    local cfg     = M.getSubConfig()
    local visible = {}
    if show_menu  then visible["sub_menu"]  = true end
    if show_close then visible["sub_close"] = true end
    if show_back  then visible["sub_back"]  = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    -- tabs 风格右侧：最右是 close，close 左边是 menu。
    -- 没有 close 时 menu 占最右；没有 menu 时 close 占最右。
    local close_x = tabs_m and (sw - tabs_m.margin - iw - tabs_m.tap_pad_h)
    local menu_x  = tabs_m and (close_x - ((show_close and (iw + tabs_m.back_gap)) or 0))
    local back_x  = tabs_m and (tabs_m.margin - tabs_m.tap_pad_h)

    -- Horizontal position of a button; nil when it has no slot.
    local function slotX(id)
        if tabs_m then
            if id == "sub_back"  then return back_x end
            if id == "sub_close" then return close_x end
            return menu_x   -- sub_menu 及默认
        end
        local s = slot_map[id]
        return s and _buttonX(s.side, s.slot, iw, pad, gap, sw)
    end

    local function placeBtn(id, btn)
        local x = slotX(id)
        if not x then return end
        if id == "sub_menu" and not tabs_m then
            _placeMenuButton(btn, iw, x)
            return
        end
        _resizeAndStrip(btn, iw)
        if tabs_m then _padTapArea(btn, tabs_m) end
        btn.overlap_align  = nil
        btn.overlap_offset = { x, 0 }
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
                local BACK_ICON = _backIcon()
                local sub_back_btn = _newBackButton(tb, widget, iw, BACK_ICON)
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
                        _applyBackIcon(btn, BACK_ICON)

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

                -- Suppress the native return button (HorizontalGroup containing a
                -- HorizontalSpan + page_return_arrow Button).
                -- Two layers of suppression are needed:
                --   1. Zero the leading HorizontalSpan so the group takes no space.
                --   2. Hide page_return_arrow AND override its showHide() so that
                --      Menu:updatePageInfo() — which calls showHide(self.onReturn ~= nil)
                --      on every page turn — cannot bring it back while our sub_back is live.
                if widget.return_button and widget.return_button[1] then
                    widget._titlebar_sub_orig_return_btn = widget.return_button[1]
                    widget.return_button[1] = require("ui/widget/verticalspan"):new{ width = 0 }
                end
                -- page_return_arrow sits at widget.page_return_arrow (set by Menu:init).
                local pra = widget.page_return_arrow
                if pra then
                    -- Save the original showHide method (instance or class level).
                    widget._titlebar_sub_orig_pra_showHide = rawget(pra, "showHide") or false
                    -- Immediately hide the button.
                    pcall(pra.hide, pra)
                    -- No-op showHide so Menu:updatePageInfo cannot un-hide it.
                    pra.showHide = function() end
                end
            end
        end
    end
end

function M.restoreSub(widget)
    local tb = widget.title_bar
    if not tb then return end
    if not widget._titlebar_sub_patched then return end
    _removeBarScrim(tb)
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

    -- Restore page_return_arrow showHide and let the menu re-evaluate visibility.
    local pra = widget.page_return_arrow
    if pra and widget._titlebar_sub_orig_pra_showHide ~= nil then
        local orig = widget._titlebar_sub_orig_pra_showHide
        if orig ~= false then
            pra.showHide = orig          -- restore instance-level override
        else
            pra.showHide = nil           -- remove instance override -> falls back to class
        end
        widget._titlebar_sub_orig_pra_showHide = nil
        -- Re-evaluate visibility using the menu own logic.
        pcall(function()
            pra:showHide(widget.onReturn ~= nil)
            pra:enableDisable(widget.paths and #widget.paths > 0)
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
    
    local _ss = SUIStyle()
    if not (_ss and _ss.applyIconToBtn(_BM_SLOT[mode], browse_btn)) then
        if _ss and _ss.restoreDefaultIcon then
            _ss.restoreDefaultIcon(browse_btn, nil, _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal)
        elseif browse_btn.image then
            browse_btn.image.file = _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal
            _reloadImage(browse_btn.image)
        elseif browse_btn.label_widget then
            browse_btn.label_widget.file = _BROWSE_ICONS_DEFAULT[mode] or _BROWSE_ICONS_DEFAULT.normal
            _reloadImage(browse_btn.label_widget)
        end
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and fm.title_bar then
        UIManager:setDirty(fm, "ui", fm.title_bar.dimen)
    end
end

return M
