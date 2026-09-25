-- sui_quickactions_render.lua — Simple UI
-- Shared primitives and per-layout builders for rendering a quick-action
-- `entry` (features/sui_quickactions.lua's QA.getEntry) as a widget.
--
-- Two API layers:
--   1. Low-level primitives — QARenderer.buildIcon / .buildFrame /
--      .buildFramedIcon — build the actual icon/frame widgets. Used
--      internally by layer 2, and exposed directly for callers that need
--      finer control.
--   2. Declarative per-layout builders — QARenderer.buildCell /
--      .buildListRow / .buildTabCell — one per "shape" a quick action can be
--      rendered as. Each resolves QA.getEntry(action_id) internally, so
--      consumers no longer need to call it just to build a widget.
--
-- Consumers:
--   modules/module_quick_actions.lua   — QARenderer.buildCell (icon grid row)
--   screens/sui_quicksettings_bar.lua  — QARenderer.buildCell (icon grid row)
--   modules/module_action_list.lua     — QARenderer.buildListRow (icon + label row)
--   screens/sui_bottombar.lua          — QARenderer.buildTabCell (tab bar cell)
--
-- Not a registry module (no top-level id/build) — a pure library.

local Blitbuffer = require("ffi/blitbuffer")
local AAPaint    = require("infra/sui_aa_paint")

-- Widget classes — required lazily, cached in module-local upvalues, so
-- requiring this engine at plugin load time doesn't force every widget class
-- off disk. Same pattern as screens/sui_bottombar.lua and
-- engines/sui_book_grid.lua.
local _CenterContainer, _FrameContainer, _HorizontalGroup, _HorizontalSpan
local _InputContainer, _LeftContainer, _RightContainer, _TextWidget
local _ImageWidget, _VerticalGroup, _VerticalSpan, _OverlapGroup, _LineWidget
local _Geom, _Font, _GestureRange, _WidgetContainer
local function CenterContainer() _CenterContainer = _CenterContainer or require("ui/widget/container/centercontainer"); return _CenterContainer end
local function FrameContainer()  _FrameContainer  = _FrameContainer  or require("ui/widget/container/framecontainer");  return _FrameContainer  end
local function HorizontalGroup() _HorizontalGroup = _HorizontalGroup or require("ui/widget/horizontalgroup");           return _HorizontalGroup end
local function HorizontalSpan()  _HorizontalSpan  = _HorizontalSpan  or require("ui/widget/horizontalspan");            return _HorizontalSpan  end
local function InputContainer()  _InputContainer  = _InputContainer  or require("ui/widget/container/inputcontainer");  return _InputContainer  end
local function LeftContainer()   _LeftContainer   = _LeftContainer   or require("ui/widget/container/leftcontainer");   return _LeftContainer   end
local function RightContainer()  _RightContainer  = _RightContainer  or require("ui/widget/container/rightcontainer");  return _RightContainer  end
local function TextWidget()      _TextWidget      = _TextWidget      or require("ui/widget/textwidget");                return _TextWidget      end
local function ImageWidget()     _ImageWidget     = _ImageWidget     or require("ui/widget/imagewidget");               return _ImageWidget     end
local function VerticalGroup()   _VerticalGroup   = _VerticalGroup   or require("ui/widget/verticalgroup");             return _VerticalGroup   end
local function VerticalSpan()    _VerticalSpan    = _VerticalSpan    or require("ui/widget/verticalspan");              return _VerticalSpan    end
local function OverlapGroup()    _OverlapGroup    = _OverlapGroup    or require("ui/widget/overlapgroup");              return _OverlapGroup    end
local function LineWidget()      _LineWidget      = _LineWidget      or require("ui/widget/linewidget");                return _LineWidget      end
local function Geom()            _Geom            = _Geom            or require("ui/geometry");                         return _Geom            end
local function Font()            _Font            = _Font            or require("ui/font");                             return _Font            end
local function GestureRange()    _GestureRange    = _GestureRange    or require("ui/gesturerange");                     return _GestureRange    end
local function WidgetContainer() _WidgetContainer = _WidgetContainer or require("ui/widget/container/widgetcontainer"); return _WidgetContainer end

local logger = require("logger")

-- Marks `widget` dirty whenever KOReader's theme or night-mode state changes,
-- so its next paint reflects updated colors. Needed by any widget in this
-- file that paints through a cached/recolored technique rather than
-- delegating theme-awareness to a child widget.
local function _attachThemeHandlers(widget)
    function widget:onToggleNightMode() require("ui/uimanager"):setDirty(self) end
    function widget:onSetNightMode()    require("ui/uimanager"):setDirty(self) end
    function widget:onApplyTheme()      require("ui/uimanager"):setDirty(self) end
    return widget
end

-- Feature/infra modules — lazy + cached, same pattern as sui_bottombar.lua's
-- _QA()/_UI() accessors, to avoid forcing them off disk at require time and
-- to sidestep circular-require ordering issues at plugin load.
local _QA, _Config, _UI, _SUIStyle
local function QA()
    _QA = _QA or (package.loaded["features/sui_quickactions"] or require("features/sui_quickactions"))
    return _QA
end
local function Config()
    _Config = _Config or (package.loaded["infra/sui_config"] or require("infra/sui_config"))
    return _Config
end
local function UI()
    _UI = _UI or (package.loaded["infra/sui_core"] or require("infra/sui_core"))
    return _UI
end
local function SUIStyle()
    _SUIStyle = _SUIStyle or (package.loaded["features/sui_style"] or require("features/sui_style"))
    return _SUIStyle
end

local QARenderer = {}

-- Wraps `content` in an InputContainer of size w×h that dispatches taps to
-- spec.on_tap_fn(action_id) via a dedicated gesture event — spec.tap_event_name
-- when given, else `default_event`. Shared by buildCell and buildListRow,
-- whose tap-dispatch wiring was otherwise identical.
local function _buildTapContainer(content, w, h, action_id, spec, default_event)
    local event_name = spec.tap_event_name or default_event
    local tappable = InputContainer():new{
        dimen      = Geom():new{ w = w, h = h },
        [1]        = content,
        _on_tap_fn = spec.on_tap_fn,
        _action_id = action_id,
    }
    tappable.ges_events = {
        [event_name] = {
            GestureRange():new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    tappable["on" .. event_name] = function(self)
        if self._on_tap_fn then self._on_tap_fn(self._action_id) end
        return true
    end
    return tappable
end

-- ===========================================================================
-- Layer 1 — shared primitives
-- ===========================================================================

-- Builds an icon widget for `entry` (as returned by QA.getEntry), resolving
-- nerd-font glyph → image file → single-letter fallback, in that order, and
-- always returning it already wrapped in UI.wrapDimmable(., entry.dim) — the
-- caller never has to remember to dim it itself (see header history: a
-- forgotten wrapDimmable call in one of the four consumers left wifi/night
-- mode icons undimmed while the other three were fine).
--
-- This behavior is now the single, unified path for all four consumers.
-- Before this extraction the four call sites disagreed on several points;
-- rather than carry those disagreements forward as opt-in variations, this
-- primitive picks the safest/most consistent behavior at each point and
-- applies it everywhere:
--   * Icon file paths are always run through SUIStyle.safeIconPath before
--     being handed to ImageWidget (previously only the Quick Settings bar
--     and bottom bar did this; the other two relied solely on ImageWidget's
--     own pcall'd render failing on a bad path).
--   * A missing or unrenderable image always falls back to a single-letter
--     TextWidget rather than silently disappearing (previously the bottom
--     bar omitted the icon entirely on failure, leaving a blank gap).
--   * Both the nerd-font glyph and the fallback letter are painted via
--     UI.makeColoredText rather than a raw TextWidget, for consistent
--     behavior under night mode / color themes (previously only
--     module_action_list's nerd-glyph path did this; everything else, and
--     module_action_list's own fallback-letter path, used a plain
--     TextWidget — an inconsistency even within that one file).
--   * The nerd-glyph size is a single scale factor (0.65) instead of the
--     three different values (0.6 / 0.75 / 0.85) previously used across the
--     four consumers, chosen as a middle ground close to the majority that
--     avoids the clipping risk of the largest of the three.
--
-- `size` is the icon's own pixel size (nerd glyph font size and fallback
-- letter font size are derived from it). `opts` still covers the remaining,
-- genuinely structural differences between consumers:
--   opts.container_w / opts.container_h  — size of the CenterContainer the
--     nerd glyph / fallback letter is centered in (defaults to `size`).
--     Some consumers center a narrower icon inside a wider cell (e.g. the
--     bottom bar centers icon_sz inside the full tab_w).
--   opts.fallback_face   — face for the fallback letter (default "cfont").
--   opts.wrap_image_in_container — wrap a successfully rendered ImageWidget
--     in a CenterContainer(container_w, container_h) instead of returning it
--     bare (module_action_list does this so a narrow icon still gets a
--     full-row-height hitbox; the others return the ImageWidget directly).
function QARenderer.buildIcon(entry, size, fgcolor, opts)
    opts = opts or {}
    local style = SUIStyle()
    local ui    = UI()

    local container_w   = opts.container_w or size
    local container_h   = opts.container_h or size
    local nerd_scale     = 0.65
    local fallback_scale = 0.55
    local icons_face     = style.FACE_ICONS or "symbols"
    local fallback_face  = opts.fallback_face or "cfont"

    local icon_widget
    local nerd_char = Config().nerdIconChar(entry.icon)
    if nerd_char then
        local glyph = ui.makeColoredText{
            text    = nerd_char,
            face    = Font():getFace(icons_face, math.floor(size * nerd_scale)),
            fgcolor = fgcolor,
            padding = 0,
        }
        icon_widget = CenterContainer():new{
            dimen = Geom():new{ w = container_w, h = container_h },
            glyph,
        }
    else
        local icon_file = style.safeIconPath(entry.icon, nil)

        local iw = icon_file and ImageWidget():new{
            file    = icon_file,
            width   = size,
            height  = size,
            is_icon = true,
            alpha   = true,
        } or nil
        local rendered = iw ~= nil and pcall(function() iw:_render() end)

        if iw and rendered then
            icon_widget = opts.wrap_image_in_container
                and CenterContainer():new{
                    dimen = Geom():new{ w = container_w, h = container_h },
                    iw,
                }
                or iw
        else
            if iw then iw:free() end
            icon_widget = CenterContainer():new{
                dimen = Geom():new{ w = container_w, h = container_h },
                ui.makeColoredText{
                    text    = (entry.label and entry.label:sub(1, 1):upper()) or "?",
                    face    = Font():getFace(fallback_face, math.floor(size * fallback_scale)),
                    fgcolor = fgcolor,
                    padding = 0,
                },
            }
        end
    end

    if not icon_widget then return nil end
    return ui.wrapDimmable(icon_widget, entry.dim)
end

-- Builds a size×size, transparent-background widget that paints the
-- rounded-rect fill (`bg_color`, when given) and/or border stroke
-- (`border_color`, `border_sz` thick, when > 0) that sits behind a cell's
-- content. Uses the coverage-based anti-aliasing primitives in
-- infra/sui_aa_paint.lua — the same technique module_clock.lua's analogue
-- face uses — instead of native rounded-rect drawing, which is aliased at
-- the radii this UI uses. Composited via UI.paintWithAlphaMask, once per
-- color, so it sits transparently over whatever is beneath (a wallpaper,
-- when bg_color is nil and only the border is drawn).
-- strength: 0 skip fill, 1–99 scrim via shared backdrop painter, 100 solid AA fill.
local function _buildRoundedBackdrop(size, corner_r, border_sz, bg_color, border_color, strength)
    strength = require("features/sui_wallpaper").clampBackdropStrength(strength) or 100
    local widget = WidgetContainer():new{}
    widget.dimen = Geom():new{ w = size, h = size }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        if size <= 0 then return end

        if bg_color and strength > 0 and strength < 100 then
            local ok, WP = pcall(require, "features/sui_wallpaper")
            if ok and WP and WP.paintBackdrop then
                WP.paintBackdrop(bb, x, y, size, size, strength, corner_r, bg_color)
            end
        end

        if not self._tmp_bb or self._tmp_bb:getWidth() ~= size then
            if self._tmp_bb then self._tmp_bb:free() end
            self._tmp_bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        end

        local ui = UI()
        if bg_color and strength >= 100 then
            ui.paintWithAlphaMask(self, bb, x, y, size, size, bg_color, function(_w, tmp_bb)
                AAPaint.paintRoundedRectFill(tmp_bb, 0, 0, size, size, corner_r, 0, 0, size - 1, size - 1)
            end, self._tmp_bb)
        end
        if border_sz > 0 then
            local half = border_sz / 2
            ui.paintWithAlphaMask(self, bb, x, y, size, size, border_color, function(_w, tmp_bb)
                AAPaint.paintRoundedRectStroke(tmp_bb, half, half, size - border_sz, size - border_sz,
                    math.max(0, corner_r - half), border_sz, 0, 0, size - 1, size - 1)
            end, self._tmp_bb)
        end
    end

    function widget:onCloseWidget() self:free() end

    function widget:free()
        if self._tmp_bb then
            self._tmp_bb:free()
            self._tmp_bb = nil
        end
    end

    return _attachThemeHandlers(widget)
end

-- Builds the border/background frame around `inner_widget` (typically the
-- result of buildIcon), resolving `opts.shape` ("bare" / "round" / anything
-- else → rounded square) and `opts.bg` ("flat" / "solid" / "transparent" /
-- anything else → no fill), the same way module_quick_actions.lua's
-- buildQAWidget and sui_quicksettings_bar.lua's makeButton both did before
-- this extraction. The border/background itself is painted by
-- _buildRoundedBackdrop, behind `inner_widget`'s own padding container, so
-- both stay anti-aliased regardless of shape or radius.
--
-- `size` is the frame's full outer size (icon size + padding on both sides).
--   opts.corner_r   — explicit "rounded square" corner radius. Defaults to
--     size/4 (Quick Settings bar's own default before this extraction).
--   opts.frame_pad  — inner padding between the frame's border and
--     `inner_widget`, used when the frame sizes itself from its content
--     (the default — see opts.fixed_size below).
--   opts.border_sz  — border thickness when a border is drawn. Defaults to
--     SUIStyle.BORDER_SZ.
--   opts.fixed_size — when true, `inner_widget` is re-centered inside a
--     CenterContainer sized to account for the border, instead of letting
--     the frame grow from `inner_widget` + padding. This is how the Quick
--     Settings bar sizes its buttons; visually identical to the padding-based
--     approach when the inner widget is already `size` minus padding, but
--     kept as a separate mode rather than forcing one composition style on
--     both consumers.
function QARenderer.buildFrame(inner_widget, size, opts)
    opts = opts or {}
    local style = SUIStyle()

    local shape = opts.shape or "rounded_square"
    local bg    = opts.bg or "solid"
    local is_bare = (shape == "bare")

    -- Fill opacity: explicit opts.strength, else transparent → 0, solid/flat → 100.
    local strength = require("features/sui_wallpaper").clampBackdropStrength(opts.strength)
    if strength == nil then
        strength = (bg == "transparent") and 0 or 100
    end

    local corner_r
    if is_bare then
        corner_r = 0
    elseif shape == "round" then
        corner_r = math.floor(size / 2)
    else
        corner_r = opts.corner_r or math.floor(size / 4)
    end

    local border_sz = opts.border_sz or style.BORDER_SZ
    -- Border for solid/transparent styles (not flat, not bare).
    local current_border = (not is_bare and bg ~= "flat") and border_sz or 0

    local bg_color = nil
    if not is_bare and strength > 0 then
        if bg == "flat" then
            bg_color = style.COLOR.surface_flat
        else
            bg_color = style.COLOR.surface
        end
    end

    local content
    if opts.fixed_size then
        content = FrameContainer():new{
            width      = size,
            height     = size,
            bordersize = 0,
            padding    = 0,
            CenterContainer():new{
                dimen = Geom():new{
                    w = size - current_border * 2,
                    h = size - current_border * 2,
                },
                inner_widget,
            },
        }
    else
        content = FrameContainer():new{
            bordersize = 0,
            padding    = is_bare and 0 or (opts.frame_pad or 0),
            inner_widget,
        }
    end

    -- Nothing to paint behind the content: skip the backdrop and its
    -- offscreen buffer entirely.
    if corner_r == 0 and current_border == 0 and not bg_color then
        return content
    end

    local backdrop = _buildRoundedBackdrop(size, corner_r, current_border, bg_color, style.COLOR.gray, strength)
    local overlap = OverlapGroup():new{
        dimen = Geom():new{ w = size, h = size },
        backdrop,
        content,
    }

    -- OverlapGroup computes self.dimen once in init() (x/y hardcoded to 0)
    -- and never updates it in paintTo() — unlike every other container used
    -- in this file, whose .dimen reflects the widget's actual screen
    -- position after each paint. A caller that reads the returned widget's
    -- .dimen post-layout (rather than only ever wrapping it in its own tap
    -- container) would see a box permanently stuck at the top-left corner.
    -- A borderless, paddingless FrameContainer is a transparent, size-
    -- preserving wrapper whose paintTo() does keep .dimen in sync, so this
    -- makes the returned widget's .dimen reliable for any consumer.
    return FrameContainer():new{
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        overlap,
    }
end

-- Builds a "framed" (color-tinted, alpha-mask painted) icon from a raw icon
-- file path, migrated as-is from sui_bottombar.lua's former _makeColoredIcon.
-- This is a distinct rendering technique from buildIcon+buildFrame above —
-- it recolors the icon itself via UI.paintWithAlphaMask (or, for nerd-font
-- glyphs, paints a colored glyph directly) rather than drawing a border/
-- background around an unmodified icon — used only by the bottom bar's
-- "framed" bar style (see buildTabCell). It keeps its own
-- onToggleNightMode/onSetNightMode/onApplyTheme handlers and
-- `original_in_nightmode = true` so the recolored icon is exempt from
-- KOReader's native night-mode inversion, which would otherwise fight with
-- the alpha-mask recoloring.
function QARenderer.buildFramedIcon(file, size, fgcolor)
    local style = SUIStyle()

    if Config().isNerdIcon(file) then
        local nerd_char = Config().nerdIconChar(file)
        local widget = WidgetContainer():new{}
        widget.dimen = Geom():new{ w = size, h = size }
        widget._fg   = fgcolor
        local tw = TextWidget():new{
            text    = nerd_char,
            face    = Font():getFace(style.FACE_ICONS or "symbols", math.floor(size * 0.75)),
            fgcolor = fgcolor,
            padding = 0,
        }
        widget._inner = tw
        function widget:getSize() return self.dimen end
        function widget:paintTo(bb, x, y)
            self.dimen.x, self.dimen.y = x, y
            local w, h = self.dimen.w, self.dimen.h
            if w <= 0 or h <= 0 then return end
            self._inner.fgcolor = self._fg or style.COLOR.text_primary
            local t_sz = self._inner:getSize()
            local ox = x + math.floor((size - t_sz.w) / 2)
            local oy = y + math.floor((size - t_sz.h) / 2)
            self._inner:paintTo(bb, ox, oy)
        end
        function widget:free()
            if self._inner then self._inner:free(); self._inner = nil end
        end
        return _attachThemeHandlers(widget)
    end

    local safe_file = style.safeIconPath(file, nil)
    if not safe_file then
        logger.warn("simpleui/quickactions_render: buildFramedIcon skipped, invalid file: " .. tostring(file))
        local placeholder = WidgetContainer():new{}
        placeholder.dimen = Geom():new{ w = size, h = size }
        function placeholder:getSize() return self.dimen end
        function placeholder:paintTo() end
        return placeholder
    end

    local inner = ImageWidget():new{
        file    = safe_file,
        width   = size,
        height  = size,
        is_icon = true,
        alpha   = true,
        original_in_nightmode = true, -- prevents native night-mode inversion of the ImageWidget
    }
    return UI().makeAlphaMaskWidget(inner, fgcolor, Geom():new{ w = size, h = size })
end

-- ===========================================================================
-- Layer 2 — declarative per-layout builders
-- ===========================================================================

-- Builds one "cell": an icon inside a buildFrame, with an optional label
-- underneath, optionally tappable. Used by the Quick Actions Row module and
-- the Quick Settings bar, whose cells differ in sizing, whether a label is
-- shown, and how the tap zone is dispatched (see spec.on_tap_fn below).
--
-- Returns two values: `cell_widget` (the full column — icon frame + optional
-- label, wrapped in an InputContainer when spec.on_tap_fn is given) and
-- `frame_widget` (just the icon's FrameContainer, for callers — like the
-- Quick Settings bar — that hit-test taps externally against a widget list
-- instead of using a per-cell gesture range).
--
-- spec fields:
--   icon_sz, frame_sz        — required. frame_sz is the full button size.
--   fixed_size, corner_r, frame_pad, border_sz, shape, bg  — forwarded to
--     buildFrame (see its doc comment).
--   fgcolor                  — icon/label color (default SUIStyle.COLOR.text_primary).
--   icon_opts                — forwarded to buildIcon (see its doc comment).
--   show_label, lbl_sp, lbl_h, lbl_fs, lbl_face  — label row, shown below the
--     frame when show_label is true.
--   lbl_w                    — label CenterContainer width (default frame_sz).
--   lbl_width                — sets TextWidget.width directly (wrapping, no
--     truncation) — used by the Quick Settings bar.
--   lbl_max_width, lbl_truncate — sets TextWidget.max_width +
--     truncate_with_ellipsis — used by the Quick Actions Row. Mutually
--     exclusive with lbl_width; the two consumers use different label-
--     overflow strategies and this preserves both exactly.
--   on_tap_fn, tap_event_name  — when on_tap_fn is given, the cell is
--     wrapped in an InputContainer with its own tap GestureRange dispatching
--     to on_tap_fn(action_id). When omitted, the cell is returned untapped
--     (the Quick Settings bar dispatches taps itself against frame_widget).
function QARenderer.buildCell(action_id, spec)
    spec = spec or {}
    local style = SUIStyle()
    local entry = QA().getEntry(action_id)

    local frame_sz = spec.frame_sz or spec.icon_sz
    local fgcolor  = spec.fgcolor or style.COLOR.text_primary

    local icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, fgcolor, spec.icon_opts)
    local frame_widget = QARenderer.buildFrame(icon_widget, frame_sz, {
        shape      = spec.shape,
        bg         = spec.bg,
        strength   = spec.strength,
        corner_r   = spec.corner_r,
        frame_pad  = spec.frame_pad,
        border_sz  = spec.border_sz,
        fixed_size = spec.fixed_size,
    })

    local col = VerticalGroup():new{ align = "center" }
    col[#col + 1] = frame_widget
    local col_h = frame_sz

    if spec.show_label then
        col[#col + 1] = VerticalSpan():new{ width = spec.lbl_sp or 0 }
        local lbl_w = spec.lbl_w or frame_sz
        col[#col + 1] = CenterContainer():new{
            dimen = Geom():new{ w = lbl_w, h = spec.lbl_h or 0 },
            TextWidget():new{
                text                   = entry.label,
                face                   = Font():getFace(spec.lbl_face or style.FACE_REGULAR, spec.lbl_fs or 15),
                fgcolor                = fgcolor,
                width                  = spec.lbl_width,
                max_width              = spec.lbl_max_width,
                truncate_with_ellipsis = spec.lbl_truncate,
            },
        }
        col_h = col_h + (spec.lbl_sp or 0) + (spec.lbl_h or 0)
    end

    local cell_widget = col
    if spec.on_tap_fn then
        cell_widget = _buildTapContainer(col, frame_sz, col_h, action_id, spec, "TapQACell")
    end

    return cell_widget, frame_widget
end

-- Builds one list row: icon (optional) on the left, label on the right,
-- tappable, aligned within `spec.inner_w`. Used by the Action List module.
--
-- spec fields:
--   inner_w, row_h            — required.
--   show_icon, icon_sz, icon_gap, icon_opts  — icon column, omitted entirely
--     when show_icon is false.
--   lbl_fs, lbl_face          — label text.
--   fgcolor                   — icon/label color.
--   align                     — "left" / "right" / anything else → centered.
--   on_tap_fn, tap_event_name — tap dispatch, same convention as buildCell.
function QARenderer.buildListRow(action_id, spec)
    spec = spec or {}
    local style = SUIStyle()
    local ui    = UI()
    local entry = QA().getEntry(action_id)
    local fgcolor = spec.fgcolor or style.COLOR.text_primary

    local icon_widget
    local text_w = spec.inner_w
    if spec.show_icon then
        icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, fgcolor, spec.icon_opts)
        text_w = spec.inner_w - spec.icon_sz - spec.icon_gap
    end

    local label_tw = ui.makeColoredText{
        text    = entry.label,
        face    = Font():getFace(spec.lbl_face or style.FACE_REGULAR, spec.lbl_fs),
        fgcolor = fgcolor,
        width   = text_w,
        padding = 0,
    }

    local content_w = spec.show_icon
        and (spec.icon_sz + spec.icon_gap + label_tw:getSize().w)
        or  label_tw:getSize().w
    content_w = math.min(content_w, spec.inner_w)

    local hg = HorizontalGroup():new{ align = "center" }
    if spec.show_icon then
        hg[#hg + 1] = icon_widget
        hg[#hg + 1] = HorizontalSpan():new{ width = spec.icon_gap }
    end
    hg[#hg + 1] = CenterContainer():new{
        dimen = Geom():new{ w = label_tw:getSize().w, h = spec.row_h },
        label_tw,
    }

    local tappable = _buildTapContainer(hg, content_w, spec.row_h, action_id, spec, "TapALCell")

    if spec.align == "left" then
        return LeftContainer():new{
            dimen = Geom():new{ w = spec.inner_w, h = spec.row_h },
            tappable,
        }
    elseif spec.align == "right" then
        return RightContainer():new{
            dimen = Geom():new{ w = spec.inner_w, h = spec.row_h },
            tappable,
        }
    end
    return CenterContainer():new{
        dimen = Geom():new{ w = spec.inner_w, h = spec.row_h },
        tappable,
    }
end

-- Builds one bottom-bar tab cell: icon and/or label (per spec.mode) plus an
-- active-tab indicator line pinned to the top. Used by sui_bottombar.lua.
--
-- Nerd-font glyphs always render via buildIcon regardless of bar style (the
-- "framed" bar style only affects raster-image icons, via buildFramedIcon —
-- see the header comment on buildFramedIcon for why that's a separate
-- mechanism and not folded into buildFrame). A missing/invalid file always
-- falls back to a single-letter widget via buildIcon, the same guarantee
-- every other QARenderer builder gives — the bottom bar previously omitted
-- the icon entirely on failure; that gap is now filled consistently.
--
-- spec fields:
--   tab_w, bar_h, icon_sz, label_fs, icon_txt_sp, indic_h  — required sizing.
--   mode        — "icons" / "text" / "both".
--   bar_style   — "default" (draws the active-indicator line) / "framed"
--     (raster icons render via buildFramedIcon) / anything else (no indicator).
--   fgcolor     — icon/label color (also used as the active-indicator color).
--   inactive_indicator_color — drawn under the bar in "default" style when
--     the tab isn't active and the navbar isn't transparent; nil = omitted.
function QARenderer.buildTabCell(action_id, active, spec)
    spec = spec or {}
    local style = SUIStyle()
    local ui    = UI()
    local entry = QA().getEntry(action_id)
    local item_fg = spec.fgcolor or style.COLOR.text_primary
    local mode = spec.mode or "both"

    local vg = VerticalGroup():new{ align = "center" }

    if mode == "icons" or mode == "both" then
        local icon_widget
        local nerd_char = Config().nerdIconChar(entry.icon)
        if not nerd_char and spec.bar_style == "framed" then
            local safe_file = style.safeIconPath(entry.icon, nil)
            if safe_file then
                icon_widget = ui.wrapDimmable(
                    QARenderer.buildFramedIcon(safe_file, spec.icon_sz, item_fg), entry.dim)
            else
                -- Invalid file even under the framed bar style still gets the
                -- same letter-fallback guarantee as every other render path.
                icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, item_fg, {
                    container_w = spec.tab_w,
                    container_h = spec.icon_sz,
                })
            end
        else
            icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, item_fg, {
                container_w = spec.tab_w,
                container_h = spec.icon_sz,
            })
        end
        if icon_widget then vg[#vg + 1] = icon_widget end
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            vg[#vg + 1] = VerticalSpan():new{ width = spec.icon_txt_sp or 0 }
        end
        vg[#vg + 1] = TextWidget():new{
            text    = entry.label,
            face    = Font():getFace(style.FACE_REGULAR, spec.label_fs),
            fgcolor = item_fg,
            bold    = active or false,
        }
    end

    local content = CenterContainer():new{
        dimen = Geom():new{ w = spec.tab_w, h = spec.bar_h },
        vg,
    }

    -- The active indicator is pinned to the very top of the cell via
    -- OverlapGroup, independent of the vertical centering of the content.
    local og = OverlapGroup():new{
        allow_mirroring = false,
        dimen           = Geom():new{ w = spec.tab_w, h = spec.bar_h },
        content,
    }

    if spec.bar_style == "default" then
        if active then
            og[#og + 1] = LineWidget():new{
                dimen          = Geom():new{ w = spec.tab_w, h = spec.indic_h },
                background     = item_fg, -- active underline tracks fg
                overlap_offset = { 0, 0 },
            }
        elseif spec.inactive_indicator_color then
            og[#og + 1] = LineWidget():new{
                dimen          = Geom():new{ w = spec.tab_w, h = spec.indic_h },
                background     = spec.inactive_indicator_color,
                overlap_offset = { 0, 0 },
            }
        end
    end

    return og
end

return QARenderer
