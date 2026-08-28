-- module_rakuyomi_row.lua — Simple UI
-- Home-screen cover row showing your Rakuyomi manga library, sorted by most
-- recently read. Same visual layout as Recent Books (module_recent.lua),
-- but built independently rather than through GridRenderer.makeModule: that
-- factory assumes every item is a real on-disk document (cover extraction,
-- title lookup and the tap handler all key off a KOReader-openable `fp`),
-- which a manga library entry is not — a manga is metadata plus a set of
-- separately-downloaded chapters, not a single file.
--
-- REQUIRES the tachibana-shin/rakuyomi fork specifically (koplugin name
-- "rakuyomi"). The original hanatsumi/rakuyomi (now archived) has no cover
-- art, no "continue reading" action and no local cover cache to read from,
-- so this row simply won't populate if that's what's installed instead —
-- every call in here is pcall-guarded and the whole module degrades to
-- "renders nothing" rather than erroring.
--
-- Reaches into two of the fork's own Lua modules (require("Backend"),
-- require("LibraryView")) because there's no public plugin API for "list my
-- library" or "resume this manga" — same require() gets whichever koplugin
-- first defined that module name, and neither name is namespaced, so a
-- sanity check (expected functions present) runs before every use. This is
-- inherently coupled to the fork's current internal layout and can break on
-- a future Rakuyomi update.
--
-- The backend server is started lazily by Rakuyomi itself (on first opening
-- its library view), NOT at KOReader startup — starting it ourselves would
-- block the UI for several seconds (or minutes on slow devices, per its own
-- startup-timeout constants) the very first time the home screen paints. So
-- this row only ever queries an already-running backend (Backend.getInitialized()
-- gate below); the module_sui_rakuyomi glue warms it up a few seconds after
-- boot so the row fills in without the user opening Rakuyomi first.

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local _ = require("infra/sui_i18n").translate

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local GridRenderer = require("engines/sui_book_grid")
local PAD    = UI.PAD
local Screen = require("device").screen

local CLR_TEXT_SUB = UI.CLR_TEXT_SUB
local ID = "rakuyomi_row"

local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "modules/module_books_shared")
        if ok and m then _SH = m end
    end
    return _SH
end

-- ---------------------------------------------------------------------------
-- Rakuyomi plugin detection / Backend access
-- ---------------------------------------------------------------------------

local function _rakuyomiInstance()
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if not (ok_pl and PluginLoader) then return nil end
    local ok_inst, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "rakuyomi")
    if not (ok_inst and inst) then return nil end
    return inst
end

-- Returns the fork's Backend module, but only once its server is already
-- running (see the file-header note on why we never start it ourselves),
-- and only after a shape check so a same-named module from some unrelated
-- koplugin can't be mistaken for it.
local function _getBackend()
    if not _rakuyomiInstance() then return nil end
    local ok, Backend = pcall(require, "Backend")
    if not (ok and type(Backend) == "table"
                and type(Backend.getMangasInLibrary) == "function"
                and type(Backend.getInitialized)     == "function"
                and type(Backend.requestJson)         == "function") then
        return nil
    end
    if not Backend.getInitialized() then return nil end
    return Backend
end

-- ---------------------------------------------------------------------------
-- Library fetch — short TTL cache so repeated home-screen repaints don't
-- each pay for an HTTP round trip to the backend.
-- ---------------------------------------------------------------------------
local _cached_mangas, _cached_mangas_time = nil, 0
local _CACHE_TTL = 60

local function _getLibraryMangas()
    local now = os.time()
    if _cached_mangas and (now - _cached_mangas_time < _CACHE_TTL) then
        return _cached_mangas
    end
    local Backend = _getBackend()
    if not Backend then return nil end
    local ok, response = pcall(Backend.requestJson, { path = "/library", timeout = 3 })
    if not (ok and type(response) == "table" and response.type == "SUCCESS"
                and type(response.body) == "table") then
        -- Transient failure (backend busy/slow) — keep serving the last good
        -- list rather than blanking the row.
        return _cached_mangas
    end
    local mangas = response.body
    table.sort(mangas, function(a, b) return (a.last_read or 0) > (b.last_read or 0) end)
    _cached_mangas  = mangas
    _cached_mangas_time = now
    return mangas
end

-- ---------------------------------------------------------------------------
-- Cover loading — Rakuyomi caches a real local image per manga (exposed as
-- a `file://` URI); this is a plain picture file, not a document, so it goes
-- through ui/renderimage directly rather than SH.getBookCover's
-- BookInfoManager/document-cover-extraction path (which expects an openable
-- book and would not know what to do with a bare jpg).
-- ---------------------------------------------------------------------------
local function _filePathFromCoverURI(uri)
    if type(uri) ~= "string" or uri:sub(1, 7) ~= "file://" then return nil end
    local path = uri:sub(8)
    path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    return path
end

-- Decode + scale-to-fill + center-crop to exactly w×h, mirroring the visual
-- treatment sui_config.lua's cover pipeline applies to book covers.
local function _decodeCoverToBB(path, w, h)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_ri and RenderImage) then return nil end
    local ok_bb, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, w, h)
    if not (ok_bb and bb) then return nil end
    local src_w, src_h = bb:getWidth(), bb:getHeight()
    if src_w <= 0 or src_h <= 0 then return bb end
    if src_w == w and src_h == h then return bb end
    local scale = math.max(w / src_w, h / src_h)
    local sw, sh = math.floor(src_w * scale + 0.5), math.floor(src_h * scale + 0.5)
    local ok_sc, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, sw, sh, true)
    if not (ok_sc and scaled) then return bb end
    if sw == w and sh == h then return scaled end
    local ok_slot, slot = pcall(Blitbuffer.new, w, h, scaled:getType())
    if not (ok_slot and slot) then return scaled end
    local sx = math.floor((sw - w) / 2)
    local sy = math.floor((sh - h) / 2)
    pcall(slot.blitFrom, slot, scaled, 0, 0, sx, sy, w, h)
    pcall(scaled.free, scaled)
    return slot
end

-- path|WxH -> BlitBuffer, or `false` to remember a decode failure without
-- retrying it every repaint. Cleared on M.reset().
local _cover_cache = {}

local function _getCoverBB(cover_uri, w, h)
    local path = _filePathFromCoverURI(cover_uri)
    if not path then return nil end
    local key = path .. "|" .. w .. "x" .. h
    local cached = _cover_cache[key]
    if cached ~= nil then return cached or nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs and lfs.attributes(path, "mode") == "file") then
        _cover_cache[key] = false
        return nil
    end
    local bb = _decodeCoverToBB(path, w, h)
    _cover_cache[key] = bb or false
    return bb
end

-- Same bordered-frame treatment SH.getBookCover gives book covers.
local function _wrapCover(bb, w, h)
    local ok_img, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image             = bb,
            image_disposable  = false,
            width             = w,
            height            = h,
            scale_factor      = 1,
        }
    end)
    if not (ok_img and img) then return nil end
    return FrameContainer:new{
        bordersize = SUIStyle.BADGE_BORDER_SZ, color = Blitbuffer.COLOR_BLACK,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

-- ---------------------------------------------------------------------------
-- Tap → "Continue Reading": delegate to the fork's own LibraryView, which
-- already implements finding the right next/last-read chapter (incl.
-- language preference, confirm dialog, "no next chapter" messaging) — the
-- exact behaviour "Continue Reading" has inside Rakuyomi's own library view.
-- Called on the bare class table (no :new{} instance): the method only
-- touches self.page / self.hide_top_close / self.current_playlist, all of
-- which are fine to leave nil here.
-- ---------------------------------------------------------------------------
local function _openManga(manga)
    if not (manga and _rakuyomiInstance()) then return end
    local ok, LibraryView = pcall(require, "LibraryView")
    if not (ok and type(LibraryView) == "table"
                and type(LibraryView._handleContinueReading) == "function") then
        return
    end
    pcall(LibraryView._handleContinueReading, LibraryView, manga)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------
local M = {}
M.id          = ID
M.name        = _("Rakuyomi Library")
M.label       = _("Rakuyomi Library")
M.enabled_key = ID .. "_enabled"
M.default_on  = false
M.has_covers  = true   -- e-ink dithering for the cover images (no updateCovers of our own — covers are decoded synchronously in build())
M.is_book_mod = true   -- suppresses the "No books opened yet" empty-state when active

function M.reset()
    _cover_cache = {}
    _cached_mangas, _cached_mangas_time = nil, 0
end

local MAX_ITEMS = 5

function M.build(w, ctx)
    local mangas = _getLibraryMangas()
    if not mangas or #mangas == 0 then return nil end

    local SH  = getSH()
    if not SH then return nil end
    local pfx = ctx.pfx

    local COLOR = SUIStyle.COLOR or {}
    local _clr_sub = COLOR.text_secondary or COLOR.text_primary or CLR_TEXT_SUB

    local scale       = Config.getModuleScale(ID, pfx)
    local thumb_scale = Config.getThumbScale(ID, pfx)
    local lbl_scale   = Config.getItemLabelScale(ID, pfx)
    local D = SH.getDims(scale, thumb_scale)

    local cols    = math.min(#mangas, MAX_ITEMS)
    local inner_w = w - PAD * 2

    local cw, ch, gap
    local cs = scale * thumb_scale
    local autofit_cw = math.max(1, math.floor((inner_w - (MAX_ITEMS - 1) * PAD) / MAX_ITEMS))
    if cs == 1.0 then
        gap = PAD
        cw  = autofit_cw
        ch  = math.max(1, math.floor(cw * (D.RECENT_H / D.RECENT_W)))
    else
        cw  = math.max(1, math.floor(autofit_cw * cs))
        ch  = math.max(1, math.floor(cw * (D.RECENT_H / D.RECENT_W)))
        gap = MAX_ITEMS > 1 and math.floor((inner_w - MAX_ITEMS * cw) / (MAX_ITEMS - 1)) or 0
    end

    local lbl_fs   = math.max(8, math.floor(SUIStyle.FS_DETAIL * scale * lbl_scale))
    local lbl_face = Font:getFace(SUIStyle.FACE_REGULAR, lbl_fs)
    local ok_h, face_height = pcall(function() return lbl_face.ftsize:getHeightAndAscender() end)
    local label_h = (ok_h and face_height and math.ceil(face_height)) or math.ceil(lbl_fs * 1.8)
    local cell_h  = ch + D.RB_GAP1 + label_h

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local manga = mangas[i]

        local inner_w_cov = math.max(1, cw - 2 * SUIStyle.BADGE_BORDER_SZ)
        local inner_h_cov = math.max(1, ch - 2 * SUIStyle.BADGE_BORDER_SZ)
        local bb    = _getCoverBB(manga.manga_cover, inner_w_cov, inner_h_cov)
        local cover = (bb and _wrapCover(bb, cw, ch))
                      or SH.coverPlaceholder(manga.title,
                            manga.source and manga.source.name, cw, ch)

        local cell = VerticalGroup:new{}
        table.insert(cell, cover)
        table.insert(cell, SH.vspan(D.RB_GAP1, ctx.vspan_pool))
        table.insert(cell, UI.makeColoredText{
            text      = manga.title or "?",
            face      = lbl_face,
            fgcolor   = _clr_sub,
            max_width = cw,
            alignment = "center",
        })

        local tappable = InputContainer:new{
            dimen  = Geom:new{ w = cw, h = cell_h },
            [1]    = cell,
            _manga = manga,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            _openManga(self._manga)
            return true
        end

        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = tappable
    end

    local show_frame = GridRenderer.showFrame(pfx, ID)
    local solid_bg    = GridRenderer.solidBg(pfx, ID)
    local has_box     = show_frame or solid_bg
    local border_sz   = show_frame and SUIStyle.BORDER_SZ or 0
    local radius      = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = COLOR.gray or Blitbuffer.gray(0.72)
    local bg_color = solid_bg and (COLOR.surface or Blitbuffer.COLOR_WHITE) or nil

    return FrameContainer:new{
        bordersize = border_sz,
        radius     = radius,
        color      = border_color,
        background = bg_color,
        padding = PAD, padding_top = has_box and PAD or 0, padding_bottom = has_box and PAD or 0,
        row,
    }
end

-- Deliberately NOT GridRenderer.getHeight(): that formula always reserves
-- progress-bar + double-gap space (so Recent/New Books/TBR stay a stable
-- height across their progress-bar/text toggles) — this module never draws
-- a progress bar at all (a manga doesn't have a single "% read"), so its
-- own build() cell is shorter (cover + one gap + one label). getHeight must
-- mirror that exact shape or the page layout reserves the wrong amount of
-- space for it.
function M.getHeight(ctx)
    local SH = getSH()
    if not SH then return 0 end
    local pfx = ctx and ctx.pfx or ""
    local scale       = Config.getModuleScale(ID, pfx)
    local thumb_scale = Config.getThumbScale(ID, pfx)
    local lbl_scale   = Config.getItemLabelScale(ID, pfx)
    local D = SH.getDims(scale, thumb_scale)

    local w = (ctx and (ctx.col_w or ctx.inner_w)) or (Screen:getWidth() - UI.SIDE_PAD * 2)
    local inner_w = w - PAD * 2
    local autofit_cw = math.max(1, math.floor((inner_w - (MAX_ITEMS - 1) * PAD) / MAX_ITEMS))
    local cs = scale * thumb_scale
    local cw = (cs == 1.0) and autofit_cw or math.max(1, math.floor(autofit_cw * cs))
    local ch = math.max(1, math.floor(cw * (D.RECENT_H / D.RECENT_W)))

    local lbl_fs   = math.max(8, math.floor(SUIStyle.FS_DETAIL * scale * lbl_scale))
    local lbl_face = Font:getFace(SUIStyle.FACE_REGULAR, lbl_fs)
    local ok_h, face_height = pcall(function() return lbl_face.ftsize:getHeightAndAscender() end)
    local label_h = (ok_h and face_height and math.ceil(face_height)) or math.ceil(lbl_fs * 1.8)

    local h = ch + D.RB_GAP1 + label_h

    local show_frame = GridRenderer.showFrame(pfx, ID)
    if show_frame or GridRenderer.solidBg(pfx, ID) then
        h = h + PAD * 2
    end
    if show_frame then
        h = h + SUIStyle.BORDER_SZ * 2
    end
    return Config.getScaledLabelH() + h
end

function M.getMenuItems(ctx_menu)
    local _lc     = ctx_menu._
    local refresh = ctx_menu.refresh
    local pfx     = ctx_menu.pfx

    return {
        Config.makeScaleItem{
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct(ID, pfx) end,
            set          = function(v) Config.setModuleScale(v, ID, pfx) end,
            refresh      = refresh,
        },
        Config.makeScaleItem{
            text_func = function() return _lc("Cover Size") end,
            separator = true,
            title     = _lc("Cover Size"),
            info      = _lc("Scale for the cover thumbnails only.\n100% is the default size."),
            get       = function() return Config.getThumbScalePct(ID, pfx) end,
            set       = function(v) Config.setThumbScale(v, ID, pfx) end,
            refresh   = refresh,
        },
        {
            text           = _lc("Frame"),
            checked_func   = function() return GridRenderer.showFrame(pfx, ID) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. ID .. "_show_frame", not GridRenderer.showFrame(pfx, ID))
                refresh()
            end,
        },
        {
            text           = _lc("Solid Background"),
            checked_func   = function() return GridRenderer.solidBg(pfx, ID) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. ID .. "_solid_bg", not GridRenderer.solidBg(pfx, ID))
                refresh()
            end,
        },
    }
end

return M
