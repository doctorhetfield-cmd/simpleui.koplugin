-- module_currently.lua — Folio
-- Currently Reading module: cover + title + author + progress bar + percentage.

local Device  = require("device")
local Screen  = Device.screen
local _       = require("gettext")
local logger  = require("logger")

local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Config       = require("folio_config")
local FolioTheme     = require("folio_theme")
local Theme        = FolioTheme.Theme
local UI           = require("folio_core")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Shared helpers — lazy-loaded.
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("folio: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Internal spacing — base values at 100% scale; scaled at render time.
local _BASE_COVER_GAP  = Screen:scaleBySize(12)
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)
local _BASE_AUTHOR_GAP = Screen:scaleBySize(8)
local _BASE_BAR_H      = Screen:scaleBySize(12)
local _BASE_BAR_GAP    = Screen:scaleBySize(6)
local _BASE_PCT_GAP    = Screen:scaleBySize(3)
local _BASE_TITLE_FS   = Screen:scaleBySize(12)
local _BASE_AUTHOR_FS  = Screen:scaleBySize(11)
local _BASE_PCT_FS     = Screen:scaleBySize(11)
local _BASE_TL_FS      = Screen:scaleBySize(9)
local _BASE_HL_FS      = Screen:scaleBySize(10)
local _BASE_HL_GAP     = Screen:scaleBySize(8)
local MAX_HL_LINES     = 3   -- max lines per highlight before it is skipped

local TITLE_MAX_LEN = 60

local function truncateTitle(title)
    if not title then return title end
    if #title > TITLE_MAX_LEN then
        return title:sub(1, TITLE_MAX_LEN) .. "…"
    end
    return title
end

-- Second-most-recent history entry when it is a different file from the most recent.
local function getPreviousHistoryEntry()
    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return nil end
    local h = ReadHistory.hist
    if #h < 2 then return nil end
    if (h[1].file or "") == (h[2].file or "") then return nil end
    return h[2]
end

local function lastReadStripHeight(scale, lbl_scale)
    lbl_scale = lbl_scale or 1
    local gap_md = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local lh = math.max(1, math.floor(Screen:scaleBySize(54) * scale))
    local strip_pad = math.max(2, math.floor(4 * scale))
    local strip_inner_h = math.max(
        lh,
        math.ceil(FolioTheme.sizeMicro() * 1.2) + 2 + math.ceil(Screen:scaleBySize(16) * scale * lbl_scale * 1.15)
    )
    return gap_md + strip_inner_h + 2 * strip_pad
end


-- ---------------------------------------------------------------------------
-- getRecentHighlights: reads the most recent highlighted-text annotations
-- from a book's doc settings.  Returns up to `limit` entries whose displayed
-- text fits within MAX_HL_LINES lines (longer ones are skipped).
-- ---------------------------------------------------------------------------
local function getRecentHighlights(filepath, limit)
    limit = limit or 3
    local results = {}
    local DS = nil
    local ok_ds, ds_mod = pcall(require, "docsettings")
    if not ok_ds then return results end
    DS = ds_mod
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m and lfs_m.attributes(filepath, "mode") ~= "file" then return results end
    local ok2, ds = pcall(DS.open, DS, filepath)
    if not ok2 or not ds then return results end
    local annotations = ds:readSetting("annotations") or {}
    pcall(function() ds:close() end)
    -- Collect only highlighted-text entries in reverse order (most recent first).
    local hl_list = {}
    for _, ann in ipairs(annotations) do
        if ann.highlighted and ann.text and ann.text ~= "" then
            hl_list[#hl_list + 1] = ann.text
        end
    end
    -- Iterate from most recent (end of list).
    for i = #hl_list, 1, -1 do
        if #results >= limit then break end
        results[#results + 1] = hl_list[i]
    end
    return results
end


-- ---------------------------------------------------------------------------
-- Visibility helpers — each element can be toggled independently.
-- Keys stored in G_reader_settings under pfx .. "currently_show_<elem>".
-- Default: all visible (nilOrTrue).
-- ---------------------------------------------------------------------------
local function _showElem(pfx, key)
    return G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
end
local function _toggleElem(pfx, key)
    local cur = G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
    G_reader_settings:saveSetting(pfx .. "currently_show_" .. key, not cur)
end

local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently"
M.default_on  = true

function M.build(w, ctx)
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local scale       = Config.getModuleScale("currently", ctx.pfx)
    local thumb_scale = Config.getThumbScale("currently", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", ctx.pfx)

    -- Scale internal spacing proportionally.
    local cover_gap  = math.max(1, math.floor(_BASE_COVER_GAP  * scale))
    local title_gap  = math.max(1, math.floor(_BASE_TITLE_GAP  * scale))
    local author_gap = math.max(1, math.floor(_BASE_AUTHOR_GAP * scale))
    local bar_h      = math.max(8, math.floor(_BASE_BAR_H      * scale))
    local bar_gap    = math.max(1, math.floor(_BASE_BAR_GAP    * scale))
    local pct_gap    = math.max(1, math.floor(_BASE_PCT_GAP    * scale))
    local hl_fs      = math.max(7, math.floor(_BASE_HL_FS      * scale * lbl_scale))
    local hl_gap     = math.max(2, math.floor(_BASE_HL_GAP     * scale))
    local tl_fs      = math.max(7, math.floor(_BASE_TL_FS      * scale * lbl_scale))

    local title_fs   = math.max(10, math.floor(FolioTheme.sizeTitleLg() * scale * lbl_scale))
    local author_fs  = math.max(10, math.floor(FolioTheme.sizeBody() * scale * lbl_scale))
    local face_title = FolioTheme.faceContent(title_fs)
    local face_auth  = FolioTheme.faceContent(author_fs)
    local face_micro = FolioTheme.faceUI(FolioTheme.sizeMicro())
    local face_btn   = FolioTheme.faceUI(FolioTheme.sizeLabelLg())

    local pad_in     = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local gap_xs     = FolioTheme.scaled(FolioTheme.Spacing.XS)
    local gap_md     = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local btn_h      = math.max(36, FolioTheme.scaled(44) * scale)
    local bd_w       = Theme.BORDER_CARD

    local cw = math.max(1, math.floor(Screen:scaleBySize(90) * scale * thumb_scale))
    local ch = math.max(1, math.floor(Screen:scaleBySize(120) * scale * thumb_scale))

    local bd    = SH.getBookData(ctx.current_fp, ctx.prefetched and ctx.prefetched[ctx.current_fp], ctx.db_conn)
    local cover = SH.getBookCover(ctx.current_fp, cw, ch)
                  or SH.coverPlaceholder(bd.title, cw, ch)

    -- Card inner width: module content minus 2px border and padding (DESIGN.md card).
    local content_w = w - PAD * 2
    local usable_w  = content_w - 2 * bd_w - 2 * pad_in
    local tw        = usable_w - cw - cover_gap

    local pfx = ctx.pfx
    local meta = VerticalGroup:new{ align = "left" }

    if _showElem(pfx, "title") then
        meta[#meta+1] = TextBoxWidget:new{
            text       = truncateTitle(bd.title) or "?",
            face       = face_title,
            bold       = true,
            width      = tw,
            max_lines  = 2,
        }
        meta[#meta+1] = VerticalSpan:new{ width = title_gap }
    end

    if _showElem(pfx, "author") and bd.authors and bd.authors ~= "" then
        meta[#meta+1] = TextWidget:new{
            text    = bd.authors,
            face    = face_auth,
            fgcolor = CLR_TEXT_SUB,
            width   = tw,
        }
        meta[#meta+1] = VerticalSpan:new{ width = author_gap }
    end

    local show_prog = _showElem(pfx, "progress")
    local show_pct  = _showElem(pfx, "percent")
    if show_prog or show_pct then
        if show_prog then
            local pr_h = math.ceil(FolioTheme.sizeMicro() * 1.25)
            local pct_str = show_pct and string.format("%d%%", math.floor((bd.percent or 0) * 100)) or ""
            local prog_row = OverlapGroup:new{
                dimen = Geom:new{ w = tw, h = pr_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = tw, h = pr_h },
                    TextWidget:new{
                        text    = _("PROGRESS"),
                        face    = face_micro,
                        fgcolor = Theme.TEXT_MUTED,
                    },
                },
                RightContainer:new{
                    dimen = Geom:new{ w = tw, h = pr_h },
                    TextWidget:new{
                        text    = pct_str,
                        face    = face_micro,
                        fgcolor = Theme.TEXT_MUTED,
                    },
                },
            }
            meta[#meta+1] = prog_row
            meta[#meta+1] = VerticalSpan:new{ width = bar_gap }
        elseif show_pct then
            meta[#meta+1] = TextWidget:new{
                text    = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100)),
                face    = face_micro,
                bold    = true,
                fgcolor = Theme.TEXT,
                width   = tw,
            }
            meta[#meta+1] = VerticalSpan:new{ width = bar_gap }
        end
        if show_prog then
            meta[#meta+1] = SH.progressBar(tw, bd.percent, bar_h, Theme.SURFACE_HIGH, Theme.PRIMARY)
        end
    end

    local tl = SH.formatTimeLeft(bd.percent, bd.pages, bd.avg_time)
    if tl then
        meta[#meta+1] = VerticalSpan:new{ width = pct_gap }
        meta[#meta+1] = TextWidget:new{
            text    = string.format(_("%s TO GO"), tl:upper()),
            face    = FolioTheme.faceUI(tl_fs),
            fgcolor = CLR_TEXT_SUB,
            width   = tw,
        }
    end

    local highlights = getRecentHighlights(ctx.current_fp, 3)
    if #highlights > 0 then
        local CLR_HL_BG = Theme.SURFACE_LOW
        for _, hl_text in ipairs(highlights) do
            local hl_widget = TextBoxWidget:new{
                text      = hl_text,
                face      = FolioTheme.faceUI(hl_fs),
                fgcolor   = CLR_TEXT_SUB,
                width     = tw,
                max_lines = MAX_HL_LINES,
            }
            local line_count = 1
            if type(hl_widget.getLineCount) == "function" then
                line_count = hl_widget:getLineCount()
            elseif hl_widget.lines then
                line_count = #hl_widget.lines
            end
            if line_count <= MAX_HL_LINES then
                local hl_frame = FrameContainer:new{
                    bordersize  = 0,
                    background  = Theme.SURFACE,
                    padding     = math.max(2, math.floor(4 * scale)),
                    padding_top = math.max(2, math.floor(3 * scale)),
                    hl_widget,
                }
                meta[#meta+1] = VerticalSpan:new{ width = hl_gap }
                meta[#meta+1] = hl_frame
            end
        end
    end

    local row = HorizontalGroup:new{
        align = "center",
        FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        },
        meta,
    }

    local est_row = math.max(ch, math.floor(title_fs * 2.8 + author_fs + bar_h + bar_gap + 24))

    local continue_btn = CenterContainer:new{
        dimen = Geom:new{ w = usable_w, h = btn_h },
        FrameContainer:new{
            bordersize = 0,
            background = Theme.PRIMARY,
            padding    = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = usable_w, h = btn_h },
                TextWidget:new{
                    text    = _("CONTINUE READING"),
                    face    = face_btn,
                    fgcolor = Theme.ON_PRIMARY,
                },
            },
        },
    }

    local inner_w = usable_w
    local top_h = math.ceil(FolioTheme.sizeMicro() * 1.2) + gap_xs + est_row + gap_md + btn_h

    local label_row = VerticalGroup:new{ align = "left" }
    label_row[#label_row + 1] = TextWidget:new{
        text    = _("CURRENTLY READING"),
        face    = face_micro,
        fgcolor = Theme.TEXT_MUTED,
    }
    label_row[#label_row + 1] = VerticalSpan:new{ width = gap_xs }
    label_row[#label_row + 1] = row
    label_row[#label_row + 1] = VerticalSpan:new{ width = gap_md }
    label_row[#label_row + 1] = continue_btn

    local top_tap = InputContainer:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1]      = label_row,
    }
    top_tap.ges_events = {
        TapCur = {
            GestureRange:new{
                ges   = "tap",
                range = function() return top_tap.dimen end,
            },
        },
    }
    function top_tap:onTapCur()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    local prev_ent = getPreviousHistoryEntry()
    local card_children = VerticalGroup:new{ align = "left" }
    card_children[#card_children + 1] = top_tap

    local extra_prev_h = 0
    if prev_ent then
        local lw = math.max(1, math.floor(Screen:scaleBySize(40) * scale))
        local lh = math.max(1, math.floor(Screen:scaleBySize(54) * scale))
        local strip_pad = math.max(2, math.floor(4 * scale))
        local arrow_w = math.max(1, math.floor(Screen:scaleBySize(24) * scale))
        local gap_cov = math.max(1, math.floor(Screen:scaleBySize(6) * scale))
        local tw_strip = inner_w - lw - gap_cov - arrow_w - 2 * strip_pad
        if tw_strip < 40 then tw_strip = 40 end

        local bd_prev = SH.getBookData(prev_ent.file, ctx.prefetched and ctx.prefetched[prev_ent.file], ctx.db_conn)
        local cover_prev = SH.getBookCover(prev_ent.file, lw, lh)
            or SH.coverPlaceholder(bd_prev.title, lw, lh)
        local face_strip_ui = FolioTheme.faceUI(FolioTheme.sizeMicro())
        local face_strip_title = FolioTheme.faceContent(math.max(10, math.floor(Screen:scaleBySize(16) * scale * lbl_scale)))

        local strip_mid = VerticalGroup:new{ align = "left" }
        strip_mid[#strip_mid + 1] = TextWidget:new{
            text    = _("CONTINUE WITH"),
            face    = face_strip_ui,
            fgcolor = Theme.TEXT_MUTED,
            width   = tw_strip,
        }
        strip_mid[#strip_mid + 1] = VerticalSpan:new{ width = 2 }
        strip_mid[#strip_mid + 1] = TextWidget:new{
            text    = truncateTitle(bd_prev.title) or "?",
            face    = face_strip_title,
            bold    = true,
            width   = tw_strip,
        }

        local strip_inner_h = math.max(
            lh,
            math.ceil(FolioTheme.sizeMicro() * 1.2) + 2 + math.ceil(Screen:scaleBySize(16) * scale * lbl_scale * 1.15)
        )
        local strip_row = HorizontalGroup:new{
            align = "center",
            FrameContainer:new{
                bordersize    = 0, padding = 0,
                padding_right = gap_cov,
                cover_prev,
            },
            LeftContainer:new{
                dimen = Geom:new{ w = tw_strip, h = strip_inner_h },
                strip_mid,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = arrow_w, h = strip_inner_h },
                TextWidget:new{
                    text    = "→",
                    face    = face_strip_title,
                    fgcolor = Theme.TEXT_MUTED,
                },
            },
        }

        local strip_frame = FrameContainer:new{
            bordersize   = 0,
            background   = Theme.SURFACE_LOW,
            padding      = strip_pad,
            radius       = Theme.CORNER_RADIUS,
            strip_row,
        }

        local strip_h = strip_inner_h + 2 * strip_pad
        extra_prev_h = gap_md + strip_h
        local strip_tap = InputContainer:new{
            dimen    = Geom:new{ w = inner_w, h = strip_h },
            _fp      = prev_ent.file,
            _open_fn = ctx.open_fn,
            [1]      = strip_frame,
        }
        strip_tap.ges_events = {
            TapPrev = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return strip_tap.dimen end,
                },
            },
        }
        function strip_tap:onTapPrev()
            if self._open_fn then self._open_fn(self._fp) end
            return true
        end

        card_children[#card_children + 1] = VerticalSpan:new{ width = gap_md }
        card_children[#card_children + 1] = strip_tap
    end

    local card = FrameContainer:new{
        bordersize   = bd_w,
        color        = Theme.PRIMARY,
        background   = Theme.SURFACE_LOW,
        padding      = pad_in,
        radius       = Theme.CORNER_RADIUS,
        card_children,
    }

    local total_h = 2 * bd_w + 2 * pad_in + top_h + extra_prev_h

    local root = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        dimen         = Geom:new{ w = w, h = total_h },
        card,
    }

    return root
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return require("folio_config").getScaledLabelH() end
    local scale       = Config.getModuleScale("currently", _ctx and _ctx.pfx)
    local thumb_scale = Config.getThumbScale("currently", _ctx and _ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", _ctx and _ctx.pfx)
    local title_fs    = math.max(10, math.floor(FolioTheme.sizeTitleLg() * scale * lbl_scale))
    local author_fs   = math.max(10, math.floor(FolioTheme.sizeBody() * scale * lbl_scale))
    local bar_h       = math.max(8, math.floor(_BASE_BAR_H * scale))
    local bar_gap     = math.max(1, math.floor(_BASE_BAR_GAP * scale))
    local ch          = math.max(1, math.floor(Screen:scaleBySize(120) * scale * thumb_scale))
    local pad_in      = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local gap_xs      = FolioTheme.scaled(FolioTheme.Spacing.XS)
    local gap_md      = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local btn_h       = math.max(36, FolioTheme.scaled(44) * scale)
    local bd_w        = Theme.BORDER_CARD
    local est_row = math.max(ch, math.floor(title_fs * 2.8 + author_fs + bar_h + bar_gap + 24))
    local total_h = 2 * bd_w + 2 * pad_in + math.ceil(FolioTheme.sizeMicro() * 1.2) + gap_xs + est_row + gap_md + btn_h
    if getPreviousHistoryEntry() then
        total_h = total_h + lastReadStripHeight(scale, lbl_scale)
    end
    return require("folio_config").getScaledLabelH() + total_h
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("currently", pfx) end,
        set          = function(v) Config.setModuleScale(v, "currently", pfx) end,
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
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("currently", pfx) end,
        set       = function(v) Config.setThumbScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

local function _makeTextScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for all text elements (title, author, progress, time).\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("currently", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle_item(label, key)
        return {
            text_func    = function() return _lc(label) end,
            checked_func = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback     = function()
                _toggleElem(pfx, key)
                refresh()
            end,
        }
    end

    -- Scale items (no separator between them), then separator before visibility toggles.
    local thumb = _makeThumbScaleItem(ctx_menu)
    thumb.separator = true

    return {
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        toggle_item("Title",           "title"),
        toggle_item("Author",          "author"),
        toggle_item("Progress bar",    "progress"),
        toggle_item("Percentage read", "percent"),
    }
end

return M