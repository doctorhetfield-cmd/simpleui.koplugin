-- features/sui_wallpaper.lua — SimpleUI wallpaper feature module.
--
-- Owns all state and logic for the "Wallpaper" settings sub-page: the cached
-- background ImageWidget (plus its associated pre-scaled Blitbuffer used for
-- stretch mode), every simpleui_style_wallpaper_* / simpleui_wallpaper_*
-- setting getter/setter, the on-disk wallpaper directory scan, the
-- backdrop strength settings for bars, title bar buttons, pagination and
-- modules (they only ever have a visible effect while a wallpaper is
-- active, so they live here next to the settings that gate them, as part of
-- the same sub-page), the shared backdrop / frame painters, and the
-- night-mode hook that invalidates the cache when night mode is toggled.
--
-- All settings live under the "simpleui_style_wallpaper_*" namespace (plus
-- the standalone "simpleui_wallpaper_show_in_fm" key) — unchanged from
-- before this module existed, since these are user-persisted keys.
--
-- Consumers:
--   * engines/sui_screen_engine.lua — paints the wallpaper behind the
--     Homescreen / Custom Screens body, and derives ctx.has_wallpaper for
--     content modules from styleGetBgWidget().
--   * infra/sui_patches.lua — paints the same wallpaper behind FM,
--     Collections, History and other fullscreen overlays when
--     "Show in FM" is enabled.
--   * modules/module_collections.lua, modules/module_currently.lua,
--     modules/module_quote.lua, engines/sui_book_grid.lua — these never
--     talk to this module directly; they just read ctx.has_wallpaper,
--     which the homescreen engine computes from this module.
--   * features/library/sui_foldercovers.lua — checks styleGetWallpaperShowInFM
--     / styleGetBgWidget directly to decide whether to mask its title strip.
--   * screens/sui_menu.lua — builds the "Wallpaper" TouchMenu / MenuTable
--     entries, consumed both from the native KOReader menu and from the
--     SUIWindow-based Settings window (screens/sui_settings_window.lua).
--   * bars, title bar, pagination, module chrome and quick-action / card
--     renderers — read their strength and paint through paintBackdrop /
--     paintFrame.
--
-- Any wallpaper-image setter here that affects what is on screen frees the
-- cached ImageWidget/Blitbuffer and asks the homescreen engine to rebuild
-- its layout via screens/sui_homescreen's ScreenEngine.rebuildLayout() —
-- using a lazy require() inside the function body (never at file scope), the
-- same pattern already used by features/sui_style.lua for the same purpose.
-- This is required because engines/sui_screen_engine.lua requires this
-- module directly; requiring it back at file scope would create a
-- load-order cycle. Backdrop strength setters only store their value: the
-- image is unaffected, so the caller refreshes once with the wallpaper cache
-- kept (ScreenEngine.rebuildLayout({ keep_wallpaper = true })).

local Device      = require("device")
local logger       = require("logger")
local _            = require("infra/sui_i18n").translate
local AA           = require("infra/sui_aa_paint")
local SUISettings  = require("infra/sui_store")
local ImageWidget  = require("ui/widget/imagewidget")
local UIManager    = require("ui/uimanager")
local lfs          = require("libs/libkoreader-lfs")
local Screen       = Device.screen

local M = {}

-- ---------------------------------------------------------------------------
-- Cache state
-- ---------------------------------------------------------------------------
local _style_bg_cache     = nil   -- cached ImageWidget for the current wallpaper
local _style_bg_cache_w   = 0     -- screen width  at cache-creation time
local _style_bg_cache_h   = 0     -- screen height at cache-creation time
local _style_bg_cache_nm  = nil   -- Screen.night_mode value at cache-creation time

-- Stretch implementation note:
-- KOReader's ImageWidget has no native "fill ignoring aspect ratio" mode —
-- scale_factor=nil and scale_factor=0 both produce a proportional fit.
-- True stretch is achieved by decoding the source image into a Blitbuffer and
-- calling bb:scale(sw, sh), which scales X and Y independently.  The scaled
-- bitmap is kept in _style_bg_cache_bb and freed together with the widget.
local _style_bg_cache_bb = nil   -- pre-scaled Blitbuffer for stretch mode (or nil)

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
local function _wpStretch()     return SUISettings:isTrue("simpleui_style_wallpaper_stretch")        end
local function _wpAutoRotate()  return SUISettings:nilOrTrue("simpleui_style_wallpaper_autorotate")  end
local function _wpInvertNight() return SUISettings:isTrue("simpleui_style_wallpaper_invert_night")   end
local function _wpOpacity()     return SUISettings:readSetting("simpleui_style_wallpaper_opacity", 0) end

-- Returns DataStorage/simpleui/sui_wallpapers/, creating it if needed.
local function _styleWallpapersDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local dir
    if ok_ds and DataStorage then
        dir = DataStorage:getSettingsDir() .. "/simpleui/sui_wallpapers"
    else
        local src = debug.getinfo(1, "S").source or ""
        dir = (src:match("^@(.+/)[^/]+/[^/]+$") or "./") .. "sui_wallpapers"
    end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

-- Returns the cached bg ImageWidget, or nil when unset.
-- Cache is keyed on (path, screen w/h, night-mode state) — any change to those
-- values triggers a rebuild. Setting changes (stretch, rotate, invert) always
-- call _styleFreeBgCache() before asking the engine to rebuild its layout, so
-- the next _styleGetBgWidget() call always reflects the current options.
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
    local raw_bb         = nil
    local pic = _getPic()
    if pic then
        local ok_d, doc = pcall(pic.openDocument, path)
        if ok_d and doc then
            img_w, img_h = doc.width, doc.height
            doc:close()
        end
    end
    if not img_w or not img_h then
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if ok_ri and RenderImage then
        local ok_bb, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
        if ok_bb and bb then
            img_w = bb:getWidth()
            img_h = bb:getHeight()
            raw_bb = bb
            end
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
            local ok_bb = true
            if not raw_bb then
                -- Decode at native resolution (no max-bounds) so we get the raw
                -- pixel data, then scale to exact eff_w×eff_h in one step.
                -- Passing width/height to renderImageFile would do a proportional
                -- fit first, producing a bitmap smaller than eff_w×eff_h, and
                -- the subsequent :scale() call would then distort unevenly.
                ok_bb, raw_bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, nil, nil)
            end
            if ok_bb and raw_bb then
                local ok_sc, scaled = pcall(function() return raw_bb:scale(eff_w, eff_h) end)
                raw_bb:free()
                raw_bb = nil
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

    if raw_bb then
        pcall(function() raw_bb:free() end)
        raw_bb = nil
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
        -- Keep a screen-sized blitbuffer for partial erasers. Stretch mode
        -- already stores one; fit mode rasterizes the widget once here.
        if not _style_bg_cache_bb then
            local ok_bb, canvas = pcall(function()
                local Blitbuffer = require("ffi/blitbuffer")
                local c = Blitbuffer.new(sw, sh)
                c:fill(Blitbuffer.COLOR_WHITE)
                w:paintTo(c, 0, 0)
                return c
            end)
            if ok_bb and canvas then
                _style_bg_cache_bb = canvas
            end
        end
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

-- Lazily asks the homescreen engine to free the cache (redundant but
-- harmless — see ScreenEngine.rebuildLayout()) and rebuild its layout so a
-- wallpaper setting change is visible immediately. Lazy-required so this
-- module never creates a load-order cycle with the engine, which requires
-- this module directly — same pattern as features/sui_style.lua.
local function _notifyLayoutChanged()
    local ok, HS = pcall(require, "screens/sui_homescreen")
    if ok and HS and HS.rebuildLayout then
        HS.rebuildLayout()
    end
end

-- ---------------------------------------------------------------------------
-- Public API — wallpaper options (consumed by sui_menu.lua and friends)
-- ---------------------------------------------------------------------------

function M.styleGetWallpaper()
    return SUISettings:readSetting("simpleui_style_wallpaper")
end

-- Settings that only make sense while a wallpaper is active.
local function _resetWallpaperDependents()
    SUISettings:saveSetting("simpleui_statusbar_transparent", false)
    SUISettings:saveSetting("simpleui_navbar_transparent", false)
    SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", false)
end

function M.styleSetWallpaper(path)
    SUISettings:saveSetting("simpleui_style_wallpaper", path)
    if not path then _resetWallpaperDependents() end
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpapersDir()
    return _styleWallpapersDir()
end

-- Raster formats accepted for wallpapers. Exported (not local) so callers
-- offering a file browser over the wallpapers directory — e.g. the
-- "Browse…" entry in screens/sui_menu.lua's Select Wallpaper submenu — stay
-- in sync with this list instead of duplicating it.
M.SUPPORTED_WALLPAPER_EXTS = { jpg=true, jpeg=true, png=true, bmp=true, gif=true, webp=true }

function M.styleScanWallpapers()
    local dir     = _styleWallpapersDir()
    local items   = {}
    local exts    = M.SUPPORTED_WALLPAPER_EXTS
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            -- lfs.dir() always yields "." and ".." — skip them explicitly so
            -- they are never matched against the extension table (a bare "."
            -- has no extension, but guard unconditionally for clarity).
            if fname ~= "." and fname ~= ".." then
                local ext = fname:match("%.([^%.]+)$")
                if ext and exts[ext:lower()] then
                    items[#items + 1] = {
                        label = fname:match("^(.+)%.[^%.]+$") or fname,
                        path  = dir .. "/" .. fname,
                    }
                end
            end
        end
        table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    return items
end

--- Returns the cached background ImageWidget (or nil).
--- Consumed by sui_patches.lua to paint the wallpaper into FM and fullscreen overlay surfaces.
function M.styleGetBgWidget()
    return _styleGetBgWidget()
end

--- Returns the stored wallpaper opacity (0 = fully opaque, 1-99 = fade toward white).
--- Consumed by sui_patches.lua paint helpers.
function M.styleGetWallpaperOpacityValue()
    return _wpOpacity()
end

--- Consumed by sui_patches.lua to decide whether to paint the wallpaper into
--- fullscreen overlays (Collections, History, etc.) and the FM.
function M.styleGetWallpaperShowInFM()
    if not M.styleGetWallpaperEnabled() or not M.styleGetWallpaper() then return false end
    return SUISettings:isTrue("simpleui_wallpaper_show_in_fm")
end
function M.styleSetWallpaperShowInFM(on)
    SUISettings:saveSetting("simpleui_wallpaper_show_in_fm", on and true or false)
end

function M.styleGetWallpaperEnabled()
    return SUISettings:isTrue("simpleui_style_wallpaper_enabled")
end
function M.styleSetWallpaperEnabled(on)
    local is_on = on ~= false and true or false
    SUISettings:saveSetting("simpleui_style_wallpaper_enabled", is_on)
    if not is_on then _resetWallpaperDependents() end
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperStretch()
    return _wpStretch()
end
function M.styleSetWallpaperStretch(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_stretch", on ~= false and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperAutoRotate()
    return _wpAutoRotate()
end
function M.styleSetWallpaperAutoRotate(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_autorotate", on ~= false and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperInvertNight()
    return _wpInvertNight()
end
function M.styleSetWallpaperInvertNight(on)
    SUISettings:saveSetting("simpleui_style_wallpaper_invert_night", on and true or false)
    _styleFreeBgCache()
    _notifyLayoutChanged()
end

function M.styleGetWallpaperOpacity()
    return _wpOpacity()
end
function M.styleSetWallpaperOpacity(val)
    -- Opacity is applied at paint-time (not baked into the ImageWidget
    -- cache); the caller refreshes the layout with the cache kept.
    SUISettings:saveSetting("simpleui_style_wallpaper_opacity", math.max(0, math.min(99, val or 0)))
end

--- Frees the internal wallpaper widget cache.
--- Must be called after changing the simpleui_style_* keys directly
--- in SUISettings (e.g. after applying a preset), so that the next paint
--- rebuilds the ImageWidget with the new wallpaper.
--- Consumed by engines/sui_screen_engine.lua (rotation handling,
--- ScreenEngine.rebuildLayout()).
function M.freeCache()
    _styleFreeBgCache()
end

-- ---------------------------------------------------------------------------
-- Transparent bars — these only ever apply while a wallpaper is active (a
-- transparent bar with no wallpaper behind it would just show the plain
-- background), so they live here rather than in the homescreen engine, next
-- to the settings that gate them. They are part of the same "Wallpaper"
-- settings sub-page as every other option above.
--
-- Split into two independent settings (status bar / navigation bar).
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

-- ---------------------------------------------------------------------------
-- Backdrop strength (0–100) for bars, chrome and modules:
--   0    = fully transparent (wallpaper shows through)
--   1–99 = scrim (semi-opaque surface blend)
--   100  = solid surface
--
-- Every setting has a single semantic default (BACKDROP_DEFAULT). Setters
-- only store the value; the caller refreshes the UI once afterwards.
-- Legacy booleans migrate once on first read:
--   status / navigation bar transparent true  → 0
--   status / navigation bar transparent false → default
--   module solid_bg true                      → 100
-- ---------------------------------------------------------------------------
local _BACKDROP_MIN, _BACKDROP_MAX = 0, 100

-- Bars keep the solid look of a plain UI; cards and buttons start solid;
-- every other surface starts transparent over the wallpaper.
M.BACKDROP_DEFAULT = {
    statusbar       = 100,
    navbar          = 100,
    pagination      = 0,
    titlebar_button = 0,
    module          = 0,
    card            = 100,
    button          = 100,
}

local KEY_STATUSBAR       = "simpleui_statusbar_backdrop"
local KEY_NAVBAR          = "simpleui_navbar_backdrop"
local KEY_PAGINATION      = "simpleui_pagination_backdrop"
local KEY_TITLEBAR_BUTTON = "simpleui_titlebar_button_backdrop"
local KEY_MODULE          = "simpleui_module_backdrop"

-- Rounds and clamps n to 0–100; nil when n is not a number.
local function _clampBackdrop(n)
    n = tonumber(n)
    if not n then return nil end
    return math.max(_BACKDROP_MIN, math.min(_BACKDROP_MAX, math.floor(n + 0.5)))
end
M.clampBackdropStrength = _clampBackdrop

-- Reads a strength setting; `default` applies when it is unset or invalid.
function M.readBackdropStrength(key, default)
    return _clampBackdrop(SUISettings:readSetting(key)) or default
end

-- Stores a strength setting and returns the stored value. Invalid input is
-- ignored and returns nil.
function M.saveBackdropStrength(key, n)
    local v = _clampBackdrop(n)
    if v then SUISettings:saveSetting(key, v) end
    return v
end

-- Human-readable strength label for menus: Transparent / N% / Solid.
-- `tr` overrides the translator for callers that carry their own.
function M.formatBackdropStrength(s, tr)
    tr = tr or _
    s = tonumber(s) or 0
    if s <= 0 then return tr("Transparent") end
    if s >= 100 then return tr("Solid") end
    return tostring(s) .. "%"
end

-- True while a wallpaper is enabled and selected. Surfaces that only exist
-- over a wallpaper fall back to their native look otherwise.
function M.isWallpaperActive()
    return M.styleGetWallpaperEnabled() and M.styleGetWallpaper() ~= nil
end

local function _migrateBarStrength(bool_key, strength_key, default)
    local stored = M.readBackdropStrength(strength_key)
    if stored then return stored end
    local strength = SUISettings:isTrue(bool_key) and _BACKDROP_MIN or default
    SUISettings:saveSetting(strength_key, strength)
    return strength
end

-- Stores a bar strength and keeps the legacy boolean in sync for any
-- external reader.
local function _saveBarStrength(strength_key, bool_key, n)
    local v = M.saveBackdropStrength(strength_key, n)
    if v then SUISettings:saveSetting(bool_key, v <= _BACKDROP_MIN) end
end

function M.getStatusbarBackdropStrength()
    if not M.isWallpaperActive() then return _BACKDROP_MAX end
    return _migrateBarStrength("simpleui_statusbar_transparent", KEY_STATUSBAR,
        M.BACKDROP_DEFAULT.statusbar)
end

function M.setStatusbarBackdropStrength(n)
    _saveBarStrength(KEY_STATUSBAR, "simpleui_statusbar_transparent", n)
end

function M.getNavbarBackdropStrength()
    if not M.isWallpaperActive() then return _BACKDROP_MAX end
    return _migrateBarStrength("simpleui_navbar_transparent", KEY_NAVBAR,
        M.BACKDROP_DEFAULT.navbar)
end

function M.setNavbarBackdropStrength(n)
    _saveBarStrength(KEY_NAVBAR, "simpleui_navbar_transparent", n)
end

function M.getPaginationBackdropStrength()
    if not M.isWallpaperActive() then return _BACKDROP_MAX end
    return M.readBackdropStrength(KEY_PAGINATION, M.BACKDROP_DEFAULT.pagination)
end

function M.setPaginationBackdropStrength(n)
    M.saveBackdropStrength(KEY_PAGINATION, n)
end

-- Without a wallpaper there is no button chrome to paint.
function M.getTitlebarButtonBackdropStrength()
    if not M.isWallpaperActive() then return _BACKDROP_MIN end
    return M.readBackdropStrength(KEY_TITLEBAR_BUTTON, M.BACKDROP_DEFAULT.titlebar_button)
end

function M.setTitlebarButtonBackdropStrength(n)
    M.saveBackdropStrength(KEY_TITLEBAR_BUTTON, n)
end

-- Module backdrop strength.
-- With (pfx, id): per-module override, migrating legacy solid_bg once.
-- With no args: global default.
function M.getModuleBackdropStrength(pfx, id)
    if type(pfx) ~= "string" or not id then
        return M.readBackdropStrength(KEY_MODULE, M.BACKDROP_DEFAULT.module)
    end
    local key = pfx .. id .. "_backdrop"
    local solid_key = pfx .. id .. "_solid_bg"
    local n = M.readBackdropStrength(key)
    -- A stored 0 next to an explicit solid_bg=false is a stale migration
    -- result (meaning "not solid", not "force transparent"): drop it.
    if n == 0 and SUISettings:get(solid_key) ~= nil and not SUISettings:isTrue(solid_key) then
        SUISettings:del(key)
        n = nil
    end
    if n then return n end
    -- Only solid_bg=true is a positive legacy signal; false means inherit.
    if SUISettings:isTrue(solid_key) then
        SUISettings:saveSetting(key, _BACKDROP_MAX)
        return _BACKDROP_MAX
    end
    return M.getModuleBackdropStrength()
end

function M.setModuleBackdropStrength(n, pfx, id)
    local key = (type(pfx) == "string" and id) and (pfx .. id .. "_backdrop") or KEY_MODULE
    M.saveBackdropStrength(key, n)
end

-- Tile a rounded rect into non-overlapping horizontal spans so each pixel is
-- written once (blending corners separately would double-tint them).
local _SQUARE_SPAN = { {} }
local function _roundedSpans(x, y, w, h, r)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then
        local sp = _SQUARE_SPAN[1]
        sp.x, sp.y, sp.w, sp.h = x, y, w, h
        return _SQUARE_SPAN
    end
    local spans = {}
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        local sw = w - inset * 2
        if sw > 0 then
            spans[#spans + 1] = { x = x + inset, y = y + i,         w = sw, h = 1 }
            spans[#spans + 1] = { x = x + inset, y = y + h - 1 - i, w = sw, h = 1 }
        end
    end
    local mid_h = h - r * 2
    if mid_h > 0 then
        spans[#spans + 1] = { x = x, y = y + r, w = w, h = mid_h }
    end
    return spans
end

local function _surfaceColor()
    return require("features/sui_style").COLOR.surface
end

-- Runs fn with the buffer's inverse flag cleared on Android, where night
-- mode may set it: the logical colour is then written exactly once and
-- frame inversion turns it into its night-mode counterpart. Returns pcall's
-- results.
function M.withInverseGuard(bb, fn)
    local suppress = Device:isAndroid() and bb.getInverse and bb:getInverse() == 1
    if suppress then bb:setInverse(0) end
    local ok, result = pcall(fn)
    if suppress then bb:setInverse(1) end
    return ok, result
end

-- Paint a backdrop into bb.
-- strength: 0 no-op, 1–99 scrim (wallpaper shows through), 100 solid surface.
-- radius: optional corner radius, drawn with anti-aliased corners.
-- Optional `color` overrides the default surface fill (e.g. surface_flat for
-- flat cards/buttons).
--
-- No day/night colour branch: always paint the light-mode surface colour
-- (white by default). Frame inversion turns it black in night mode while
-- preserving the same alpha — same approach as chrome scrims elsewhere.
function M.paintBackdrop(bb, x, y, w, h, strength, radius, color)
    strength = _clampBackdrop(strength) or 0
    if strength <= 0 or w <= 0 or h <= 0 then return end
    local alpha = math.floor(255 * strength / 100 + 0.5)
    local c = color or _surfaceColor()
    radius = math.max(0, math.floor(tonumber(radius) or 0))

    local ok, drawn = M.withInverseGuard(bb, function()
        return AA.fillRoundedRect(bb, x, y, w, h, radius, c, alpha)
    end)
    if ok and drawn then return end

    -- Corners without anti-aliasing.
    M.withInverseGuard(bb, function()
        for _, sp in ipairs(_roundedSpans(x, y, w, h, radius)) do
            AA.fillRect(bb, sp.x, sp.y, sp.w, sp.h, c, alpha)
        end
    end)
end

-- Paint an opaque rounded border of `thickness` inside (x, y, w, h), with
-- anti-aliased corners where the radius allows it.
function M.paintFrame(bb, x, y, w, h, thickness, radius, color)
    thickness = math.max(1, math.floor(tonumber(thickness) or 1))
    radius = math.max(0, math.floor(tonumber(radius) or 0))

    local ok, drawn = M.withInverseGuard(bb, function()
        return AA.strokeRoundedRect(bb, x, y, w, h, radius, thickness, color)
    end)
    if ok and drawn then return end

    if type(bb.paintBorderRGB32) == "function" then
        M.withInverseGuard(bb, function()
            bb:paintBorderRGB32(x, y, w, h, thickness, color, radius, true)
        end)
    end
end

-- Clear a dirty rect before a partial redraw: restore wallpaper pixels when
-- a wallpaper is active, otherwise paint the solid surface colour.
function M.paintEraser(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    -- Ensure the screen-sized cache exists (fit mode builds it on first get).
    if not _style_bg_cache_bb then
        _styleGetBgWidget()
    end
    local src = _style_bg_cache_bb
    if src then
        local sw = src:getWidth()
        local sh = src:getHeight()
        if x < 0 then w = w + x; x = 0 end
        if y < 0 then h = h + y; y = 0 end
        if x >= sw or y >= sh then return end
        if x + w > sw then w = sw - x end
        if y + h > sh then h = sh - y end
        if w <= 0 or h <= 0 then return end
        local ok = pcall(function()
            bb:blitFrom(src, x, y, x, y, w, h)
            local opacity = _wpOpacity()
            if opacity and opacity > 0 then
                bb:lightenRect(x, y, w, h, opacity / 100)
            end
        end)
        if ok then return end
    end
    local SUIStyle = require("features/sui_style")
    bb:paintRect(x, y, w, h, SUIStyle.COLOR.surface)
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
    _notifyLayoutChanged()
end

local _orig_UIManager_SetNightMode = UIManager.SetNightMode
if _orig_UIManager_SetNightMode then
    function UIManager:SetNightMode(nightmode)
        _orig_UIManager_SetNightMode(self, nightmode)
        _styleFreeBgCache()
        _notifyLayoutChanged()
    end
end

return M
