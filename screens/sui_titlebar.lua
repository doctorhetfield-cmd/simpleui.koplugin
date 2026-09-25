-- sui_titlebar.lua — Simple UI
-- Title-bar customisations for the FileManager (FM) and injected fullscreen
-- widgets (Collections, History, …).
--
-- FM context:   apply(fm_self)  /  restore(fm_self)  /  reapply(fm_self)
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

-- Lua 5.1 / LuaJIT compat: table.unpack was added in 5.2.
local _unpack = table.unpack or unpack

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

local _SIZE_SCALE = { compact = 0.75, default = 1.0, large = 1.3 }

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

-- Resizes btn to new_w x new_w and zeroes left/right/bottom paddings.
-- Pass keep_top_pad=true to preserve padding_top (needed for injected buttons).
-- Rounded scrim behind title-bar icon buttons (wallpaper chrome).
-- Strength is read at paint time so opacity changes need no re-hook.
local function _installButtonScrim(btn)
    if not btn or btn._sui_tb_btn_scrim then return end
    btn._sui_tb_btn_scrim = true
    local orig = btn.paintTo
    if type(orig) ~= "function" then return end
    function btn:paintTo(bb, x, y)
        local ok, WP = pcall(require, "features/sui_wallpaper")
        if ok and WP and WP.getTitlebarButtonBackdropStrength then
            local strength = WP.getTitlebarButtonBackdropStrength()
            if strength > 0 and WP.paintBackdrop then
                local d = self.dimen
                local bw = (d and d.w) or self.width or 0
                local bh = (d and d.h) or self.height or 0
                if bw <= 0 or bh <= 0 then
                    local sz = self.getSize and self:getSize()
                    if sz then bw, bh = sz.w, sz.h end
                end
                if bw > 0 and bh > 0 then
                    local Device = require("device")
                    local radius = math.floor(Device.screen:scaleBySize(12))
                    WP.paintBackdrop(bb, x, y, bw, bh, strength, radius)
                end
            end
        end
        return orig(self, bb, x, y)
    end
end

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
    _installButtonScrim(btn)
end

-- Snapshots a button's current geometry and optional state into a plain table.
local function _snapBtn(btn, opts)
    local snap = {
        align   = btn.overlap_align,
        offset  = btn.overlap_offset,
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
        pad = Screen:scaleBySize(18),
        gap = Screen:scaleBySize(18),
        sw  = Screen:getWidth(),
    }
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
-- FM titlebar — apply
-- ---------------------------------------------------------------------------

function M.apply(fm_self)
    if not M.isEnabled() then return end
    local tb = fm_self.title_bar
    if not tb then return end
    if fm_self._titlebar_patched then return end
    fm_self._titlebar_patched = true

    local UIManager = require("ui/uimanager")
    local lp        = _layoutParams(tb)
    local iw, pad, gap, sw = lp.iw, lp.pad, lp.gap, lp.sw

    -- Read all visibility settings once.
    local show_menu   = M.isItemVisible("fm_menu")
    local show_up     = M.isItemVisible("fm_back")
    local show_search = M.isItemVisible("fm_search")
    local show_browse = M.isItemVisible("fm_browse") and (function()
        -- Improvement #4: use cached _BrowseMeta() instead of inline pcall.
        local BM = _BrowseMeta()
        return BM and BM.isEnabled()
    end)()
    local show_title  = M.isItemVisible("fm_title")

    local cfg     = M.getFMConfig()
    local visible = {}
    if show_menu   then visible["fm_menu"]   = true end
    if show_up     then visible["fm_back"]     = true end
    if show_search then visible["fm_search"] = true end
    if show_browse then visible["fm_browse"] = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    -- Resizes, strips paddings and positions a button according to its slot.
    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

    -- Right button (menu) ----------------------------------------------------

    if tb.right_button then
        local rb = tb.right_button
        fm_self._titlebar_rb = _snapBtn(rb, { save_icon = true, save_callback = true })

        -- Patch setRightIcon so our custom icon survives folder navigation.
        local _icon_enabled     = show_menu
        local orig_setRightIcon = tb.setRightIcon
        fm_self._titlebar_orig_setRightIcon = orig_setRightIcon
        tb.setRightIcon = function(tb_self, icon, ...)
            local result = orig_setRightIcon(tb_self, icon, ...)
            if icon == "plus" and _icon_enabled then
                if tb_self.right_button then
                    local _ss = SUIStyle()
                    if not (_ss and _ss.applyIconToBtn("sui_menu", tb_self.right_button)) then
                        if _ss and _ss.restoreDefaultIcon then
                            _ss.restoreDefaultIcon(tb_self.right_button, nil, Config.ICON.ko_menu)
                        elseif tb_self.right_button.image then
                            tb_self.right_button.image.file = Config.ICON.ko_menu
                            _reloadImage(tb_self.right_button.image)
                        end
                    end
                end
                UIManager:setDirty(tb_self.show_parent, "ui", tb_self.dimen)
            end
            return result
        end

        if show_menu then
            placeBtn("fm_menu", rb)
            local _ss = SUIStyle()
            if not (_ss and _ss.applyIconToBtn("sui_menu", rb)) then
                if _ss and _ss.restoreDefaultIcon then
                    _ss.restoreDefaultIcon(rb, nil, Config.ICON.ko_menu)
                elseif rb.image then
                    rb.image.file = Config.ICON.ko_menu
                    _reloadImage(rb.image)
                end
            end
        else
            rb.overlap_align  = nil
            -- Improvement #6: use defensive 2× width offset.
            rb.overlap_offset = { _hideOffset(sw), 0 }
            rb.callback       = function() end
            rb.hold_callback  = function() end
        end
    end

    -- Left button (back/up) --------------------------------------------------
    -- The native tb.left_button is permanently hidden; a fresh IconButton is
    -- injected into the TitleBar OverlapGroup, mirroring the search_button
    -- approach.  All back/up logic drives the injected widget exclusively.

    -- Always hide the native left_button (snap first so restore() can undo).
    if tb.left_button then
        local lb = tb.left_button
        fm_self._titlebar_lb = _snapBtn(lb, { save_icon = true, save_callback = true })
        lb.overlap_align  = nil
        lb.overlap_offset = { _hideOffset(sw), 0 }
        lb.callback       = function() end
        lb.hold_callback  = function() end
    end

    if show_up then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["fm_back"]
            if s then
                local btn_padding = tb.button_padding
                    or require("device").screen:scaleBySize(11)

                -- Resolve bidi chevron direction once.
                local ICON_UP = "chevron.left"
                pcall(function()
                    local BD = require("ui/bidi")
                    ICON_UP = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
                end)

                local up_btn
                up_btn = IconButton:new{
                    icon        = ICON_UP,
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback    = function() end,   -- set by _applyBackButtonState
                }
                _resizeAndStrip(up_btn, iw)

                -- Apply sui_back icon override (same logic as before).
                do
                    local _ss = SUIStyle()
                    if _ss then _ss.applyIconToBtn("sui_back", up_btn) end
                end

                up_btn.overlap_align  = nil
                up_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, up_btn)
                fm_self._titlebar_up_btn = up_btn
                fm_self._simpleui_up_x   = _buttonX(s.side, s.slot, iw, pad, gap, sw)

                -- Hide immediately if already at root on first apply.
                if _isAtRoot(fm_self.file_chooser) then
                    up_btn.overlap_offset = { _hideOffset(sw), 0 }
                    up_btn.callback       = function() end
                    up_btn.hold_callback  = function() end
                end

                local fc = fm_self.file_chooser
                if fc then
                    local function _leftSideBtns()
                        local list = {}
                        for _, id in ipairs(cfg.order_left) do
                            if id ~= "fm_back" and slot_map[id]
                               and slot_map[id].side == "left" then
                                local widget
                                if id == "fm_search" then
                                    widget = fm_self._titlebar_search_btn
                                elseif id == "fm_browse" then
                                    widget = fm_self._titlebar_browse_btn
                                end
                                if widget then
                                    list[#list + 1] = {
                                        btn  = widget,
                                        slot = slot_map[id].slot,
                                    }
                                end
                            end
                        end
                        return list
                    end

                    local up_slot = s.slot

                    -- Single authoritative function for back-button visibility and action.
                    -- root+page1: hide; root+page>1: paginate; subfolder: folder-up.
                    -- `page` is always passed explicitly to avoid stale cur_page reads.
                    -- Drives the injected up_btn, not tb.left_button.
                    local function _applyBackButtonState(fc_self, is_sub, page)
                        local btn = fm_self._titlebar_up_btn
                        if not btn then return end
                        local tb2       = fm_self.title_bar
                        local neighbors = _leftSideBtns()

                        if not is_sub and page <= 1 then
                            -- Hide back button and compact neighbors left.
                            btn.overlap_offset = { _hideOffset(sw), 0 }
                            btn.callback       = function() end
                            btn.hold_callback  = function() end
                            for _, entry in ipairs(neighbors) do
                                local dslot = entry.slot > up_slot
                                              and entry.slot - 1 or entry.slot
                                entry.btn.overlap_offset = {
                                    _buttonX("left", dslot, iw, pad, gap, sw), 0
                                }
                            end
                        else
                            -- Show: refresh icon (respects SUIStyle override).
                            -- IMPORTANT: .icon and .file must be kept mutually exclusive.
                            -- KOReader's ImageWidget:init() gives precedence to .icon over
                            -- .file, so whichever field we do NOT want must be nil-ed.
                            local _ss        = SUIStyle()
                            if not (_ss and _ss.applyIconToBtn("sui_back", btn)) then
                                if _ss and _ss.restoreDefaultIcon then
                                    _ss.restoreDefaultIcon(btn, ICON_UP, nil)
                                elseif btn.image then
                                    btn.image.file = nil
                                    btn.image.icon = ICON_UP
                                    pcall(btn.image.free, btn.image)
                                    pcall(btn.image.init, btn.image)
                                end
                            end
                            btn.overlap_offset = {
                                _buttonX("left", up_slot, iw, pad, gap, sw), 0
                            }
                            for _, entry in ipairs(neighbors) do
                                entry.btn.overlap_offset = {
                                    _buttonX("left", entry.slot, iw, pad, gap, sw), 0
                                }
                            end
                            if page > 1 then
                                -- Paginated list: tap goes back one page, hold goes to page 1.
                                btn.callback      = function()
                                    fc_self:onGotoPage(page - 1)
                                end
                                btn.hold_callback = function()
                                    fc_self:onGotoPage(1)
                                end
                            else
                                -- Subfolder page 1: tap goes to parent, hold is no-op.
                                btn.callback      = function()
                                    fc_self:onFolderUp()
                                end
                                btn.hold_callback = function() end
                            end
                        end
                        if tb2 then
                            UIManager:setDirty(
                                tb2.show_parent or fm_self, "ui", tb2.dimen
                            )
                        end
                    end

                    fm_self._simpleui_force_refresh_layout = _applyBackButtonState

                    fm_self._titlebar_orig_fc_genItemTable = fc.genItemTable
                    fc._simpleui_gen_listeners = {}

                    local orig_genItemTable = fc.genItemTable
                    fc.genItemTable = function(fc_self, dirs, files, path)
                        local item_table = orig_genItemTable(fc_self, dirs, files, path)
                        if not item_table then return item_table end

                        -- Strip the go-up row from the list (we own the back button now).
                        -- is_sub is determined by path, not by the presence of this item.
                        local filtered = {}
                        for _, item in ipairs(item_table) do
                            if not _isGoUpItem(item) then
                                filtered[#filtered + 1] = item
                            end
                        end

                        -- Path-based is_sub: use the path argument when available (it
                        -- reflects the destination of the current genItemTable call),
                        -- falling back to fc_self.path for the initial load.
                        local effective_path = path or fc_self.path
                        local is_sub = _isSubFolder(effective_path)
                        -- Series view overrides path-based result (path unchanged from parent).
                        if fc_self.item_table
                           and fc_self.item_table._sg_is_series_view then
                            is_sub = true
                        end
                        _applyBackButtonState(fc_self, is_sub, 1)

                        -- Notify all other registered listeners (e.g. browse icon refresh).
                        for _, listener in ipairs(
                            fc_self._simpleui_gen_listeners or {}
                        ) do
                            pcall(listener, fc_self)
                        end

                        return filtered
                    end

                    -- KOReader called genItemTable before our patch was installed on the
                    -- first FM open. Strip the go-up entry retroactively so the initial
                    -- render matches subsequent navigations.
                    local it = fc.item_table
                    if it then
                        local cleaned     = {}
                        local found_go_up = false
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

                    -- onFolderUp re-evaluates back-button state after navigation.
                    -- FileChooser.onFolderUp is resolved at call time (not captured as an
                    -- upvalue) because sui_foldercovers may swap the class method at runtime.
                    --
                    -- Save the previous instance value so restore() can reinstate it
                    -- exactly, rather than blindly nil-ing the slot.
                    local FileChooser_cls = require("ui/widget/filechooser")
                    fm_self._titlebar_orig_fc_onFolderUp = fc.onFolderUp  -- may be nil
                    fc.onFolderUp = function(fc_self, ...)
                        -- When the user navigated here from the book dialog ("More by X"),
                        -- a single back press should return to the real folder they came
                        -- from, scrolled to the book — not to the Authors root.
                        local BM = _BrowseMeta()
                        if BM then
                            local origin = fc_self._sui_author_dialog_origin
                            if origin and origin.path then
                                local path = fc_self.path or ""
                                local ok_pl, level = pcall(BM.getPathLevel, path)
                                if ok_pl and level == "file_list" then
                                    -- Clear origin so subsequent back presses behave normally.
                                    fc_self._sui_author_dialog_origin = nil
                                    BM.exitToNormal(fc_self, fm_self)
                                    -- Navigate to the saved real folder with the book focused
                                    -- so the list scrolls to the right page automatically.
                                    fc_self:changeToPath(origin.path, origin.file)
                                    local is_sub_after = _resolveIsSub(fc_self)
                                    _applyBackButtonState(fc_self, is_sub_after, 1)
                                    return true
                                end
                            end
                        end
                        -- At the dim_list level of a virtual browse tree, exit to normal FS.
                        if BM and BM.exitToNormal then
                            local path = fc_self.path or ""
                            if path:find("/", 1, true) then
                                local ok_pl, level =
                                    pcall(BM.getPathLevel, path)
                                if ok_pl and level == "dim_list" then
                                    BM.exitToNormal(fc_self, fm_self)
                                    local is_sub_after = _resolveIsSub(fc_self)
                                    _applyBackButtonState(fc_self, is_sub_after, 1)
                                    return true
                                end
                            end
                        end
                        -- Delegate to the current class method (resolved at call time).
                        local current = FileChooser_cls.onFolderUp
                        local ok, result = xpcall(current, debug.traceback, fc_self, ...)
                        local is_sub = _resolveIsSub(fc_self)
                        _applyBackButtonState(fc_self, is_sub, 1)
                        if not ok then error(result, 0) end
                        return result
                    end

                    -- onGotoPage updates back-button state on every CoverBrowser page turn.
                    -- Re-entrancy guard prevents KOReader's internal recursive calls from
                    -- overwriting the state set for the outer call.
                    local orig_onGotoPage = fc.onGotoPage
                    if orig_onGotoPage then
                        fm_self._titlebar_orig_fc_onGotoPage = orig_onGotoPage
                        fc.onGotoPage = function(fc_self, page, ...)
                            if fc_self._simpleui_in_goto then
                                return orig_onGotoPage(fc_self, page, ...)
                            end
                            fc_self._simpleui_in_goto = true
                            local ok, result =
                                xpcall(orig_onGotoPage, debug.traceback, fc_self, page, ...)
                            -- Clear re-entrancy guard BEFORE any error() so a failure
                            -- inside orig_onGotoPage never leaves the flag stuck at true.
                            fc_self._simpleui_in_goto = nil
                            local is_sub = _resolveIsSub(fc_self)
                            _applyBackButtonState(fc_self, is_sub, page)
                            if not ok then error(result, 0) end
                            return result
                        end
                    end
                end -- if fc
            end -- if s
        end -- if ok_ib
    end -- if show_up

    -- Search button ----------------------------------------------------------
    -- Injected directly into the TitleBar OverlapGroup.
    -- All paddings (including top) are zeroed to align with the other buttons.

    if show_search then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["fm_search"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)
                local search_btn = IconButton:new{
                    icon        = "appbar.search",
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or fm_self,
                    callback = function()
                        local fs = fm_self.filesearcher
                        if fs and fs.onShowFileSearch then fs:onShowFileSearch() end
                    end,
                }
                _resizeAndStrip(search_btn, iw)
                -- Apply sui_search icon override.
                do
                    local _ss = SUIStyle()
                    if _ss then _ss.applyIconToBtn("sui_search", search_btn) end
                end
                search_btn.overlap_align  = nil
                search_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, search_btn)
                fm_self._titlebar_search_btn = search_btn
                fm_self._simpleui_search_x   = _buttonX(s.side, s.slot, iw, pad, gap, sw)


                if s.side == "left" then
                    local up_slot2  = slot_map["fm_back"] and slot_map["fm_back"].slot or 0
                    local dslot     = s.slot > up_slot2 and s.slot - 1 or s.slot
                    local compact_x = _buttonX("left", dslot, iw, pad, gap, sw)
                    fm_self._simpleui_search_x_compact = compact_x
                    -- Shift to the compact (flush left) position whenever the up/back
                    -- button is not actually occupying its slot: either it is disabled
                    -- entirely (not show_up), or it is enabled but hidden because we
                    -- are already at root on first apply (show_up and _isAtRoot(...)).
                    -- The old "show_up and _isAtRoot(...)" condition never applied the
                    -- compact position when the up button was disabled entirely, so
                    -- search sat one slot too far right, as if the missing button were
                    -- still there.
                    if (not show_up) or _isAtRoot(fm_self.file_chooser) then
                        search_btn.overlap_offset = { compact_x, 0 }
                    end
                end
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

    if fm_self._simpleui_force_refresh_layout and fm_self.file_chooser then
        local current_is_sub = _resolveIsSub(fm_self.file_chooser)
        local current_page   = fm_self.file_chooser.page or 1
        
        
        fm_self._simpleui_force_refresh_layout(fm_self.file_chooser, current_is_sub, current_page)
        
        
        fm_self._simpleui_force_refresh_layout = nil 
    end
    if tb.setTitle then
        fm_self._titlebar_orig_title_set = true
        tb:setTitle(show_title and _("Library") or "")
    end
end

-- ---------------------------------------------------------------------------
-- FM titlebar — restore / reapply
-- ---------------------------------------------------------------------------

function M.restore(fm_self)
    local tb = fm_self.title_bar
    if not tb then return end
    if not fm_self._titlebar_patched then return end

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

    -- Remove injected up, search and browse buttons from the TitleBar OverlapGroup.
    for _, key in ipairs({ "_titlebar_up_btn", "_titlebar_search_btn", "_titlebar_browse_btn" }) do
        local btn = fm_self[key]
        if btn then
            -- Free the C/FFI image memory
            if btn.image then pcall(btn.image.free, btn.image) end
            
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

    local lp                = _layoutParams(tb)
    local iw, pad, gap, sw  = lp.iw, lp.pad, lp.gap, lp.sw
    local show_menu      = M.isItemVisible("sub_menu")
    local show_close     = M.isItemVisible("sub_close")

    local show_back      = M.isItemVisible("sub_back")

    local cfg     = M.getSubConfig()
    local visible = {}
    if show_menu  then visible["sub_menu"]  = true end
    if show_close then visible["sub_close"] = true end
    if show_back  then visible["sub_back"]  = true end
    local slot_map = _buildSlotMap(cfg.order_left, cfg.order_right, visible)

    local function placeBtn(id, btn)
        local s = slot_map[id]
        if not s then return end
        _resizeAndStrip(btn, iw)
        btn.overlap_align  = nil
        btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
    end

   -- Left button (hamburger / sub_menu).
    if tb.left_button then
        local lb = tb.left_button
        widget._titlebar_sub_lb = _snapBtn(lb)
        if show_menu then
            placeBtn("sub_menu", lb)
            -- Apply the custom menu icon only when the button is currently
            -- showing the hamburger (not "check" or another select-mode icon).
            -- On a fresh applyToSub the button is always in menu state, but on
            -- a reapply triggered while select-mode is active we must not
            -- overwrite the "check" icon that KOReader just set.
            -- We read lb.icon (the IconButton field, kept in sync by setIcon)
            -- rather than lb.image.icon, because applyIconToBtn clears image.icon.
            local _is_menu_state = (lb.icon == nil or lb.icon == "appbar.menu")
            if _is_menu_state then
                local _ss = SUIStyle()
                if _ss then
                    _ss.applyIconToBtn("sui_menu", lb)
                end
            end

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
                    -- Host is restoring the hamburger — re-apply custom icon.
                    widget._titlebar_sub_lb_is_menu = true
                    if tb_self.left_button then
                        local _ss2 = SUIStyle()
                        if not (_ss2 and _ss2.applyIconToBtn("sui_menu", tb_self.left_button)) then
                            if _ss2 and _ss2.restoreDefaultIcon then
                                _ss2.restoreDefaultIcon(tb_self.left_button, nil, Config.ICON.ko_menu)
                            elseif tb_self.left_button.image then
                                tb_self.left_button.image.file = Config.ICON.ko_menu
                                _reloadImage(tb_self.left_button.image)
                            end
                        end
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

    -- Left button (back / pagination)
    if show_back then
        local ok_ib, IconButton = pcall(require, "ui/widget/iconbutton")
        if ok_ib and IconButton then
            local s = slot_map["sub_back"]
            if s then
                local btn_padding = tb.button_padding or require("device").screen:scaleBySize(11)
                local ICON_UP = "chevron.left"
                pcall(function()
                    local BD = require("ui/bidi")
                    ICON_UP = BD.mirroredUILayout() and "chevron.right" or "chevron.left"
                end)
                local sub_back_btn = IconButton:new{
                    icon        = ICON_UP,
                    width       = iw,
                    height      = iw,
                    padding     = btn_padding,
                    show_parent = tb.show_parent or widget,
                    callback    = function() end,
                }
                _resizeAndStrip(sub_back_btn, iw)
                do
                    local _ss = SUIStyle()
                    if _ss then _ss.applyIconToBtn("sui_back", sub_back_btn) end
                end
                sub_back_btn.overlap_align  = nil
                sub_back_btn.overlap_offset = { _buttonX(s.side, s.slot, iw, pad, gap, sw), 0 }
                table.insert(tb, sub_back_btn)
                widget._titlebar_sub_back_btn = sub_back_btn

                -- Applies the correct state to sub_back with unified logic across
                -- all sub-widgets (collections, history, coll_list, …):
                --
                --   page > 1              → show; tap = previous page, hold = page 1
                --   page == 1, onReturn   → show; tap = onReturn (or onClose fallback)
                --   page == 1, no onReturn → hide (nothing to go back to)
                --
                -- This mirrors the native bar: page_return_arrow is enabled when
                -- #self.paths > 0 (there is somewhere to go back to), and the
                -- chevrons handle page navigation. sub_back unifies both functions.
                local function _applySubBackButtonState(w_self, page)
                    local btn = w_self._titlebar_sub_back_btn
                    if not btn then return end

                    local has_return = (w_self.onReturn ~= nil)
                    local visible    = (page > 1) or has_return

                    if not visible then
                        -- Nothing to go back to: hide the button.
                        btn.overlap_offset = { _hideOffset(sw), 0 }
                        btn.callback       = function() end
                        btn.hold_callback  = function() end
                    else
                        -- Show the button with the current icon (respects SUIStyle override).
                        -- .icon and .file are mutually exclusive in KOReader's ImageWidget:
                        -- init() gives precedence to .icon, so whichever we do NOT want
                        -- must be nilled explicitly.
                        local _ss = SUIStyle()
                        if not (_ss and _ss.applyIconToBtn("sui_back", btn)) then
                            if btn.image then
                                btn.image.file = nil
                                btn.image.icon = ICON_UP
                                pcall(btn.image.free, btn.image)
                                pcall(btn.image.init, btn.image)
                            end
                        end

                        local sl = slot_map["sub_back"]
                        if sl then
                            btn.overlap_offset = { _buttonX(sl.side, sl.slot, iw, pad, gap, sw), 0 }
                        end

                        if page > 1 then
                            -- Paginated: tap goes back one page, hold goes to page 1.
                            btn.callback      = function() w_self:onGotoPage(page - 1) end
                            btn.hold_callback = function() w_self:onGotoPage(1) end
                        else
                            -- Page 1 with a return destination (e.g. inside a collection,
                            -- going back to the collection list via onReturn).
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
    if tb.left_button  then _restoreBtn(tb.left_button,  widget._titlebar_sub_lb) end
    if tb.right_button then _restoreBtn(tb.right_button, widget._titlebar_sub_rb) end

    -- Restore the setLeftIcon patch.
    if widget._titlebar_sub_orig_setLeftIcon ~= nil then
        tb.setLeftIcon = widget._titlebar_sub_orig_setLeftIcon
        widget._titlebar_sub_orig_setLeftIcon = nil
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
