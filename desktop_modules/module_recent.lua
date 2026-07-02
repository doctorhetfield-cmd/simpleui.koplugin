-- module_recent.lua — Simple UI
-- Módulo: Recent Books.
-- Substitui a parte "recent" de recentbookswidget.lua.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local Size            = require("ui/size")
local _ = require("sui_i18n").translate

local logger  = require("logger")
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_recent: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

local Config       = require("sui_config")
local UI           = require("sui_core")
local SUISettings  = require("sui_store")
local SUIStyle     = require("sui_style")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local MOD_GAP      = UI.MOD_GAP
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _BASE_RB_PCT_FS = SUIStyle.FS_DETAIL  -- 15: "XX% Read" label font size

local SETTING_PROGRESS      = "recent_show_progress"  -- pfx .. this; default ON
local SETTING_TEXT          = "recent_show_text"       -- pfx .. this; default ON
local SETTING_OVERLAY       = "recent_show_overlay"    -- pfx .. this; default OFF
local SETTING_SHOW_FINISHED = "recent_show_finished"   -- pfx .. this; default OFF

local function showProgress(pfx)
    return SUISettings:readSetting(pfx .. SETTING_PROGRESS) ~= false
end
local function showText(pfx)
    return SUISettings:readSetting(pfx .. SETTING_TEXT) ~= false
end
local function showOverlay(pfx)
    return SUISettings:readSetting(pfx .. SETTING_OVERLAY) == true
end
local function showFinished(pfx)
    return SUISettings:readSetting(pfx .. SETTING_SHOW_FINISHED) == true
end


local M = {}

M.id          = "recent"
M.name        = _("Recent Books")
M.label       = _("Recent Books")
M.enabled_key = "recent_enabled"
M.default_on  = false
M.has_covers  = true   -- activates e-ink dithering and cover poll
M.is_book_mod = true   -- suppresses empty-state when active

-- Called by teardown (via _PLUGIN_MODULES flush) to drop the cached reference
-- to module_books_shared so a hot update picks up fresh code on next load.
function M.reset() _SH = nil end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Recent Books"))
    if not ctx.recent_fps or #ctx.recent_fps == 0 then return nil end

    -- Filter finished books using this module's own independent setting.
    local show_fin   = showFinished(ctx.pfx or "")
    local recent_fps = {}
    for _, fp in ipairs(ctx.recent_fps) do
        local pd      = ctx.prefetched and ctx.prefetched[fp]
        local pct     = pd and pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        if show_fin or not is_done then
            recent_fps[#recent_fps + 1] = fp
            if #recent_fps >= 5 then break end
        end
    end
    if #recent_fps == 0 then return nil end

    local SH          = getSH()
    local scale       = Config.getModuleScale("recent", ctx.pfx)
    local thumb_scale = Config.getThumbScale("recent", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("recent", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)
    local pct_fs = math.max(8, math.floor(_BASE_RB_PCT_FS * scale * lbl_scale))

    -- Theme colors
    local ok_ss, SUIStyle  = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle and SUIStyle.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle and SUIStyle.getThemeColor("text_secondary")
    local _CLR_DARK_EFF    = _theme_fg or Blitbuffer.COLOR_BLACK
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB

    local cols    = math.min(#recent_fps, 5)
    local cw      = D.RECENT_W
    local ch      = D.RECENT_H
    -- Space-between across 5 fixed slots with same lateral padding as other modules (PAD).
    local inner_w = w - PAD * 2
    local gap     = math.floor((inner_w - 5 * cw) / 4)
    -- Hoist the face lookup — same args for every cell, no need to call per iteration.
    local pct_face = Font:getFace(SUIStyle.FACE_REGULAR, pct_fs)

    local show_progress = showProgress(ctx.pfx)
    local show_text     = showText(ctx.pfx)
    local use_overlay   = showOverlay(ctx.pfx)

    -- When overlay is active, progress bar and text below covers are hidden.
    local draw_progress = show_progress and not use_overlay
    local draw_text     = show_text     and not use_overlay

    -- Badge radius (also used in getHeight).
    local badge_r = math.floor(cw * 0.28)

    -- Total tappable cell height.
    local cell_h = use_overlay and (ch + badge_r) or D.RECENT_CELL_H

    local row = HorizontalGroup:new{ align = "top" }
    local cover_slots = {}
    local rc_cell_slots = {}
    for i = 1, cols do
        local fp    = recent_fps[i]
        local bd    = SH.getBookData(fp, ctx.prefetched and ctx.prefetched[fp])
        local cover = SH.getBookCover(fp, cw, ch, nil, 0.10) or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

        -- Build cover layer: plain or with percentage badge overlaid.
        local cover_widget
        if use_overlay then
            local pct_int = math.floor((bd.percent or 0) * 100 + 0.5)
            local badge_d = badge_r * 2
            local border_sz = SUIStyle.BADGE_BORDER_SZ
            local border_color = SUIStyle.BADGE_BORDER_CLR
            local badge = FrameContainer:new{
                bordersize  = border_sz,
                color       = border_color,
                background  = Blitbuffer.gray(0.15),
                padding     = 0,
                dimen       = Geom:new{ w = badge_d, h = badge_d },
                radius      = badge_r,
                CenterContainer:new{
                    dimen = Geom:new{ w = badge_d - 2 * border_sz, h = badge_d - 2 * border_sz },
                    UI.makeColoredText{
                        text    = string.format(_("%d%%"), pct_int),
                        face    = pct_face,
                        bold    = true,
                        fgcolor = _CLR_DARK_EFF,
                    },
                },
            }
            -- Position badge centred horizontally, half inside / half outside
            -- the bottom edge of the cover (y = ch - badge_r).
            badge.overlap_offset = {
                math.floor((cw - badge_d) / 2),
                ch - badge_r,
            }
            -- The OverlapGroup must be tall enough to include the half that
            -- bleeds below the cover, otherwise the badge gets clipped.
            cover_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = ch + badge_r },
                cover,
                badge,
            }
        else
            cover_widget = cover
        end

        local cell = VerticalGroup:new{ align = "center", cover_widget }

        if draw_progress then
            cell[#cell+1] = SH.vspan(D.RB_GAP1, ctx.vspan_pool)
            cell[#cell+1] = UI.progressBar(cw, bd.percent, D.RB_BAR_H)
        end

        if draw_text then
            cell[#cell+1] = SH.vspan(draw_progress and D.RB_GAP2 or D.RB_GAP1, ctx.vspan_pool)
            cell[#cell+1] = UI.makeColoredText{
                text      = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100 + 0.5)),
                face      = pct_face,
                bold      = true,
                fgcolor   = CLR_TEXT_SUB_EFF,
                width     = cw,
                alignment = "center",
            }
        end

        local tappable = InputContainer:new{
            dimen    = Geom:new{ w = cw, h = cell_h },
            [1]      = cell,
            _fp      = fp,
            _open_fn = ctx.open_fn,
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
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        -- Record cover slot: cell[1] is cover_widget; if overlay, cover is at [1] inside it.
        if use_overlay then
            cover_slots[#cover_slots+1] = { container = cover_widget, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0.10 }
        else
            cover_slots[#cover_slots+1] = { container = cell, idx = 1, fp = fp, w = cw, h = ch, align = nil, stretch = 0.10 }
        end

        -- Record per-cell mutation slot for updateStats().
        -- Stores the VerticalGroup and the indices of the progress-bar and
        -- percent-text widgets so updateStats() can replace them without
        -- rebuilding covers or tappable containers.
        --
        -- Cell layout (indices depend on which elements are enabled):
        --   cell[1]                cover_widget  (never touched by updateStats)
        --   cell[bar_span_idx]     vspan before bar (draw_progress)
        --   cell[bar_idx]          progressBar   (draw_progress)
        --   cell[text_span_idx]    vspan before text (draw_text)
        --   cell[text_idx]         percent text  (draw_text)
        --
        -- For the overlay path (use_overlay=true), the badge inside
        -- cover_widget carries the percent: cover_widget[2] is the badge
        -- FrameContainer, and cover_widget[2][1] is the CenterContainer
        -- whose child is the TextWidget.  We track the CenterContainer
        -- directly so updateStats() can replace its [1] child.
        local bar_idx       = nil
        local text_idx      = nil
        local overlay_badge = nil   -- FrameContainer (badge) when use_overlay
        local overlay_cc    = nil   -- CenterContainer inside badge
        local cur = 1  -- cell[1] = cover_widget, already placed
        if use_overlay then
            -- Badge is cover_widget[2]; its sole child [1] is the CenterContainer.
            overlay_badge = cover_widget[2]
            overlay_cc    = overlay_badge and overlay_badge[1]
        else
            if draw_progress then
                cur = cur + 2  -- vspan + bar
                bar_idx = cur
            end
            if draw_text then
                cur = cur + 2  -- vspan + text
                text_idx = cur
            end
        end
        rc_cell_slots[i] = {
            cell          = cell,
            fp            = fp,
            bar_idx       = bar_idx,
            text_idx      = text_idx,
            overlay_badge = overlay_badge,
            overlay_cc    = overlay_cc,
            cw            = cw,
            pct_face      = pct_face,
        }

        -- Keyboard focus: overlay a black rectangular border on this book cell
        -- when it is the currently selected keyboard-navigation item.
        local cell_widget = tappable
        if ctx.kb_recent_focus_idx == i then
            local bw = Screen:scaleBySize(3)
            cell_widget = OverlapGroup:new{
                dimen = Geom:new{ w = cw, h = cell_h },
                tappable,
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = _CLR_DARK_EFF },
                LineWidget:new{ dimen = Geom:new{ w = cw, h = bw },    background = _CLR_DARK_EFF, overlap_offset = {0, cell_h - bw} },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = _CLR_DARK_EFF },
                LineWidget:new{ dimen = Geom:new{ w = bw, h = cell_h }, background = _CLR_DARK_EFF, overlap_offset = {cw - bw, 0} },
            }
        end

        -- Use HorizontalSpan for inter-cell spacing instead of a zero-border
        -- FrameContainer — avoids 4 unnecessary widget allocations per render.
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = cell_widget
    end

    local show_frame = SUISettings:isTrue(ctx.pfx .. "recent_show_frame")
    local solid_bg   = SUISettings:isTrue(ctx.pfx .. "recent_solid_bg")
    local has_box    = show_frame or solid_bg
    local border_sz  = show_frame and SUIStyle.BORDER_SZ or 0
    local radius     = has_box and math.floor(Screen:scaleBySize(12) * scale) or 0
    local border_color = Blitbuffer.gray(0.72)
    if ok_ss and SUIStyle then
        border_color = SUIStyle.getThemeColor("separator") or border_color
    end
    local bg_color = nil
    if solid_bg then
        bg_color = (ok_ss and SUIStyle and SUIStyle.getThemeColor("bg")) or Blitbuffer.COLOR_WHITE
    end

    local result = FrameContainer:new{
        bordersize = border_sz,
        radius     = radius,
        color      = border_color,
        background = bg_color,
        padding = PAD, padding_top = has_box and PAD or 0, padding_bottom = has_box and PAD or 0,
        row,
    }
    result._cover_slots   = cover_slots
    result._rc_cell_slots = rc_cell_slots
    return result
end

function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    if not SH then return true end
    local all_done = true
    for _, slot in ipairs(widget._cover_slots) do
        local new_cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if new_cover then
            slot.container[slot.idx] = new_cover
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
        end
    end
    return all_done
end

-- updateStats — in-place update of progress bars and percent text.
--
-- Called by sui_homescreen._refresh() async tick instead of a full build()
-- when the list of recent books has not changed between renders.  Covers are
-- never touched here — that is the job of updateCovers() / the cover-poll
-- loop.
--
-- Returns true  → caller can setDirty on the existing widget's dimen only.
-- Returns false → caller must fall back to a full build() rebuild.
--
-- Guard conditions that force a full rebuild:
--   • widget or _rc_cell_slots missing (first build failed / old code path)
--   • The set of recent fps visible after filtering has changed (a new book
--     appeared, a book was removed, or the show_finished setting flipped).
--     Detected by comparing fp list stored at build-time against ctx now.
--   • The draw_progress / draw_text / use_overlay flags have changed (a
--     settings change between the reader session and the return).
--
-- Everything else — percent, progress bar fill, badge number — is updated
-- by replacing the lightweight sub-widgets inside each cell's VerticalGroup
-- without touching covers, InputContainers, or HorizontalGroups.
function M.updateStats(widget, ctx)
    if not widget or not widget._rc_cell_slots then return false end
    local slots = widget._rc_cell_slots
    if #slots == 0 then return false end

    -- Recompute the same filtered fp list that build() would produce.
    if not ctx or not ctx.recent_fps then return false end
    local pfx      = ctx.pfx or ""
    local show_fin = showFinished(pfx)
    local new_fps  = {}
    for _, fp in ipairs(ctx.recent_fps) do
        local pd      = ctx.prefetched and ctx.prefetched[fp]
        local pct     = pd and pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        if show_fin or not is_done then
            new_fps[#new_fps + 1] = fp
            if #new_fps >= 5 then break end
        end
    end

    -- If the book list has changed length or order, a full rebuild is needed
    -- because the cover and tappable containers correspond to specific fps.
    if #new_fps ~= #slots then return false end
    for i = 1, #slots do
        if slots[i].fp ~= new_fps[i] then return false end
    end

    -- Check that the draw flags match what was built.  If the user toggled
    -- progress bar / text / overlay between sessions the widget structure
    -- differs and we cannot patch in-place.
    local show_progress = showProgress(pfx)
    local show_text     = showText(pfx)
    local use_overlay   = showOverlay(pfx)
    local draw_progress = show_progress and not use_overlay
    local draw_text     = show_text     and not use_overlay

    -- Validate consistency using the first slot (all cells share the same flags).
    local s0 = slots[1]
    local flags_match
    if use_overlay then
        flags_match = (s0.overlay_badge ~= nil)
    else
        flags_match = (draw_progress == (s0.bar_idx  ~= nil))
                   and (draw_text    == (s0.text_idx ~= nil))
    end
    if not flags_match then return false end

    -- Theme colours (cheap: just table lookups, no I/O).
    local ok_ss, SUIStyle_ = pcall(require, "sui_style")
    local _theme_fg        = ok_ss and SUIStyle_ and SUIStyle_.getThemeColor("fg")
    local _theme_secondary = ok_ss and SUIStyle_ and SUIStyle_.getThemeColor("text_secondary")
    local _CLR_DARK_EFF    = _theme_fg or Blitbuffer.COLOR_BLACK
    local CLR_TEXT_SUB_EFF = _theme_secondary or _theme_fg or CLR_TEXT_SUB

    -- Patch each cell in-place.
    for i, slot in ipairs(slots) do
        local fp  = slot.fp
        local pd  = ctx.prefetched and ctx.prefetched[fp]
        local pct = pd and pd.percent or 0
        local SH  = getSH()
        local bd  = SH and SH.getBookData(fp, pd) or { percent = pct }
        local pct_val = bd.percent or pct

        if use_overlay then
            -- Overlay path: replace the TextWidget inside the badge's
            -- CenterContainer (cover_widget[2][1]).
            if slot.overlay_cc then
                local pct_int = math.floor(pct_val * 100 + 0.5)
                slot.overlay_cc[1] = UI.makeColoredText{
                    text    = string.format(_("%d%%"), pct_int),
                    face    = slot.pct_face,
                    bold    = true,
                    fgcolor = _CLR_DARK_EFF,
                }
            end
        else
            local cell = slot.cell

            if draw_progress and slot.bar_idx then
                -- Replace the OverlapGroup/LineWidget returned by progressBar().
                -- D.RB_BAR_H is not stored; reuse the existing widget's height.
                local old_bar = cell[slot.bar_idx]
                local bar_h   = old_bar and old_bar.dimen and old_bar.dimen.h
                                or Screen:scaleBySize(4)
                cell[slot.bar_idx] = UI.progressBar(slot.cw, pct_val, bar_h)
            end

            if draw_text and slot.text_idx then
                -- Replace the TextWidget / makeColoredText wrapper.
                local pct_int = math.floor(pct_val * 100 + 0.5)
                cell[slot.text_idx] = UI.makeColoredText{
                    text      = string.format(_("%d%% Read"), pct_int),
                    face      = slot.pct_face,
                    bold      = true,
                    fgcolor   = CLR_TEXT_SUB_EFF,
                    width     = slot.cw,
                    alignment = "center",
                }
            end
        end
    end

    return true
end

function M.getHeight(ctx)
    local SH  = getSH()
    local pfx = ctx and ctx.pfx or ""
    local D   = SH.getDims(Config.getModuleScale("recent", pfx),
                            Config.getThumbScale("recent", pfx))
    local use_overlay = showOverlay(pfx)
    local h = D.RECENT_H
    if use_overlay then
        local badge_r = math.floor(D.RECENT_W * 0.28)
        h = h + badge_r
    else
        if showProgress(pfx) then
            h = h + D.RB_GAP1 + D.RB_BAR_H
            if showText(pfx) then h = h + D.RB_GAP2 end
        end
        if showText(pfx) then
            if not showProgress(pfx) then h = h + D.RB_GAP1 end
            h = h + D.RB_LABEL_H
        end
    end
    if SUISettings:isTrue(pfx .. "recent_show_frame") or SUISettings:isTrue(pfx .. "recent_solid_bg") then
        h = h + PAD * 2
    end
    return require("sui_config").getScaledLabelH() + h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return require("sui_config").getModuleScalePct("recent", pfx) end,
        set          = function(v) require("sui_config").setModuleScale(v, "recent", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnails only.\nText and progress bar follow the module scale.\n100% is the default size."),
        get       = function() return require("sui_config").getThumbScalePct("recent", pfx) end,
        set       = function(v) require("sui_config").setThumbScale(v, "recent", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local label_item = Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for the percentage read text.\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("recent", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "recent", pfx) end,
        refresh   = refresh,
    })
    return {
        _makeScaleItem(ctx_menu),
        label_item,
        _makeThumbScaleItem(ctx_menu),
        Config.makeLabelToggleItem("recent", _("Recent Books"), refresh, _lc),
        {
            text           = _lc("Frame"),
            checked_func   = function() return SUISettings:isTrue(pfx .. "recent_show_frame") end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. "recent_show_frame", not SUISettings:isTrue(pfx .. "recent_show_frame"))
                refresh()
            end,
        },
        {
            text           = _lc("Solid Background"),
            checked_func   = function() return SUISettings:isTrue(pfx .. "recent_solid_bg") end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. "recent_solid_bg", not SUISettings:isTrue(pfx .. "recent_solid_bg"))
                refresh()
            end,
        },
        {
            text           = _lc("Progress bar"),
            checked_func   = function() return showProgress(pfx) end,
            enabled_func   = function() return not showOverlay(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_PROGRESS, not showProgress(pfx))
                refresh()
            end,
        },
        {
            text           = _lc("Percentage text"),
            checked_func   = function() return showText(pfx) end,
            enabled_func   = function() return not showOverlay(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_TEXT, not showText(pfx))
                refresh()
            end,
        },
        {
            text           = _lc("Percentage overlay on cover"),
            checked_func   = function() return showOverlay(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_OVERLAY, not showOverlay(pfx))
                refresh()
            end,
        },
        {
            text           = _lc("Show finished books"),
            checked_func   = function() return showFinished(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_SHOW_FINISHED, not showFinished(pfx))
                refresh()
            end,
        },
    }
end

return M
