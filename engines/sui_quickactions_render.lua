-- sui_quickactions_render.lua — Simple UI
-- Shared primitives and per-layout builders for rendering a quick-action
-- `entry` (features/sui_quickactions.lua's QA.getEntry) as a widget.
--
-- Two API layers:
--   1. Low-level primitives — QARenderer.buildIcon / .buildFrame /
--      .buildFramedIcon / .buildLabel — build the actual icon/frame/label
--      widgets. Used internally by layer 2, and exposed directly for callers
--      that need finer control.
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


-- Widget classes — required lazily, cached in module-local upvalues, so
-- requiring this engine at plugin load time doesn't force every widget class
-- off disk. Same pattern as screens/sui_bottombar.lua and
-- engines/sui_book_grid.lua.
local _CenterContainer, _FrameContainer, _HorizontalGroup, _HorizontalSpan
local _InputContainer, _TextWidget
local _ImageWidget, _VerticalGroup, _VerticalSpan, _OverlapGroup, _LineWidget
local _Geom, _Font, _GestureRange, _WidgetContainer
local Accent = require("infra/sui_accent")
local function CenterContainer() _CenterContainer = _CenterContainer or require("ui/widget/container/centercontainer"); return _CenterContainer end
local function FrameContainer()  _FrameContainer  = _FrameContainer  or require("ui/widget/container/framecontainer");  return _FrameContainer  end
local function HorizontalGroup() _HorizontalGroup = _HorizontalGroup or require("ui/widget/horizontalgroup");           return _HorizontalGroup end
local function HorizontalSpan()  _HorizontalSpan  = _HorizontalSpan  or require("ui/widget/horizontalspan");            return _HorizontalSpan  end
local function InputContainer()  _InputContainer  = _InputContainer  or require("ui/widget/container/inputcontainer");  return _InputContainer  end
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

local logger   = require("logger")
local Screen   = require("device").screen
local Backdrop = require("infra/sui_backdrop")
local Text     = require("infra/sui_text")

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
-- whose tap-dispatch wiring was otherwise identical. With spec.on_hold_fn a
-- long press calls spec.on_hold_fn(action_id); the hold keys of a D-pad
-- device reach it too, as FocusManager sends them as a hold gesture. With
-- spec.focusable the container is also a D-pad focus stop (see UI.makeFocusable).
local function _buildTapContainer(content, w, h, action_id, spec, default_event)
    local event_name = spec.tap_event_name or default_event
    local tappable = InputContainer():new{
        dimen       = Geom():new{ w = w, h = h },
        [1]         = content,
        _on_tap_fn  = spec.on_tap_fn,
        _on_hold_fn = spec.on_hold_fn,
        _action_id  = action_id,
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
    if spec.on_hold_fn then
        local hold_name = event_name .. "Hold"
        tappable.ges_events[hold_name] = {
            GestureRange():new{
                ges   = "hold",
                range = function() return tappable.dimen end,
            },
        }
        tappable["on" .. hold_name] = function(self)
            self._on_hold_fn(self._action_id)
            return true
        end
    end
    -- spec.focusable: the container also takes part in D-pad navigation.
    if spec.focusable then UI().makeFocusable(tappable, tappable["on" .. event_name]) end
    return tappable
end

QARenderer.buildTapContainer = _buildTapContainer

-- ===========================================================================
-- Layer 1 — shared primitives
-- ===========================================================================

-- Ink of a dimmed icon drawn in `fgcolor`: the inactive colour that still reads
-- on the same fill, light over a dark fill (light `fgcolor`) and gray otherwise.
local function _dimInk(fgcolor)
    local COLOR = SUIStyle().COLOR
    if fgcolor and fgcolor:getColor8().a >= 0x80 then return COLOR.text_dim_inverse end
    return COLOR.text_dim
end

-- Builds an icon widget for `entry` (as returned by QA.getEntry), resolving
-- nerd-font glyph → image file → single-letter fallback, in that order, and
-- always returning it already dimmed when `entry.dim` is set — the caller
-- never has to dim it itself.
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
--   opts.tint            — recolour an image icon to `fgcolor`, for icons drawn
--     on a surface whose fill is not the paper (see QARenderer.onSurfaceColor).
function QARenderer.buildIcon(entry, size, fgcolor, opts)
    opts = opts or {}
    local style = SUIStyle()
    local ui    = UI()

    local container_w   = opts.container_w or size
    local container_h   = opts.container_h or size

    -- A dimmed icon is drawn directly in the dim ink: masking an icon that is
    -- already recoloured would paint it blank.
    local ink = entry.dim and _dimInk(fgcolor) or fgcolor

    local icon_widget
    local nerd_char = Config().nerdIconChar(entry.icon)
    if nerd_char then
        local glyph = ui.makeColoredText{
            text    = nerd_char,
            face    = style.glyphFace(size),
            fgcolor = ink,
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
            original_in_nightmode = opts.tint or nil, -- the mask recolours it, night mode must not invert it
        } or nil
        local rendered = iw ~= nil and pcall(function() iw:_render() end)

        if iw and rendered then
            if opts.tint then
                iw = ui.makeAlphaMaskWidget(iw, ink, Geom():new{ w = size, h = size })
            end
            icon_widget = opts.wrap_image_in_container
                and CenterContainer():new{
                    dimen = Geom():new{ w = container_w, h = container_h },
                    iw,
                }
                or iw
            if not opts.tint then icon_widget = ui.wrapDimmable(icon_widget, entry.dim, ink) end
        else
            if iw then iw:free() end
            icon_widget = CenterContainer():new{
                dimen = Geom():new{ w = container_w, h = container_h },
                ui.makeColoredText{
                    text    = (entry.label and Text.cut(entry.label, 1):upper()) or "?",
                    face    = style.letterFace(size, opts.fallback_face),
                    fgcolor = ink,
                    padding = 0,
                },
            }
        end
    end

    return icon_widget
end

-- Surface of a frame that paints nothing.
local NO_SURFACE = { strength = 0, border_sz = 0 }

-- Builds a width×height, transparent-background widget that paints `surface`
-- (a resolved surface: fill and border, see infra/sui_backdrop.lua) behind a
-- cell's content, with corners of radius `corner_r`. Painting goes through the
-- shared backdrop painter: native rectangles plus cached anti-aliased corner
-- masks, so the cost depends on the corner radius only. With no fill the
-- wallpaper shows through.
local function _buildRoundedBackdrop(width, height, corner_r, surface)
    local widget = WidgetContainer():new{}
    widget.dimen = Geom():new{ w = width, h = height }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        if width <= 0 or height <= 0 then return end
        Backdrop.paintSurface(bb, x, y, width, height, surface, corner_r)
    end

    return _attachThemeHandlers(widget)
end

-- Colour of the content drawn on the surface of a cell or button (`spec` has
-- `shape`, `surface` and `fgcolor`, as in QARenderer.buildCell): the text colour
-- of the surface when its fill is not the paper (accent tone), else
-- `spec.fgcolor` (default: primary text). A bare shape paints no surface.
-- Second value: true when that colour belongs to the surface.
function QARenderer.onSurfaceColor(spec)
    local surface = spec.shape ~= "bare" and spec.surface or nil
    if surface and surface.foreground then return surface.foreground, true end
    return spec.fgcolor or SUIStyle().COLOR.text_primary, false
end

-- Icon size relative to the frame that holds it; shared by every framed cell.
QARenderer.ICON_FRAME_RATIO = 0.52

-- Icon size, inner padding and corner radius of a frame of `frame_sz` pixels.
function QARenderer.cellDims(frame_sz)
    local icon_sz = math.floor(frame_sz * QARenderer.ICON_FRAME_RATIO)
    return {
        icon_sz   = icon_sz,
        frame_pad = math.floor((frame_sz - icon_sz) / 2),
        corner_r  = math.floor(frame_sz / 4),
    }
end

-- Builds the border/background frame around `inner_widget` (typically the
-- result of buildIcon), resolving `opts.shape` ("bare" / "round" / anything
-- else → rounded square) and `opts.surface`, the resolved surface (tone,
-- opacity and frame) drawn behind the content; a "bare" shape draws none. The
-- surface is painted by _buildRoundedBackdrop, behind `inner_widget`'s own
-- padding container, so it stays anti-aliased regardless of shape or radius.
--
-- `size` is the frame's full outer size (icon size + padding on both sides).
--   opts.width      — outer width of a fixed_size frame wider than it is
--     tall; `size` stays its height and sets the corner radius.
--   opts.corner_r   — explicit "rounded square" corner radius. Defaults to
--     size/4 (Quick Settings bar's own default before this extraction).
--   opts.frame_pad  — inner padding between the frame's border and
--     `inner_widget`, used when the frame sizes itself from its content
--     (the default — see opts.fixed_size below).
--   opts.fixed_size — when true, `inner_widget` is re-centered inside a
--     CenterContainer sized to account for the border, instead of letting
--     the frame grow from `inner_widget` + padding. This is how the Quick
--     Settings bar sizes its buttons; visually identical to the padding-based
--     approach when the inner widget is already `size` minus padding, but
--     kept as a separate mode rather than forcing one composition style on
--     both consumers.
function QARenderer.buildFrame(inner_widget, size, opts)
    opts = opts or {}

    local shape = opts.shape or "rounded_square"
    local is_bare = (shape == "bare")
    local surface = (not is_bare and opts.surface) or NO_SURFACE

    local corner_r
    if is_bare then
        corner_r = 0
    elseif shape == "round" then
        corner_r = math.floor(size / 2)
    else
        corner_r = opts.corner_r or math.floor(size / 4)
    end

    local current_border = surface.border_sz
    local has_fill = surface.strength > 0

    local width = opts.fixed_size and opts.width or size

    local content
    if opts.fixed_size then
        content = FrameContainer():new{
            width      = width,
            height     = size,
            bordersize = 0,
            padding    = 0,
            CenterContainer():new{
                dimen = Geom():new{
                    w = width - current_border * 2,
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
    if corner_r == 0 and current_border == 0 and not has_fill then
        return content
    end

    local backdrop = _buildRoundedBackdrop(width, size, corner_r, surface)
    local overlap = OverlapGroup():new{
        dimen = Geom():new{ w = width, h = size },
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

-- Builds a color-tinted, alpha-mask painted icon from a raw icon file path.
-- This is a distinct rendering technique from buildIcon+buildFrame above —
-- it recolors the icon itself via UI.paintWithAlphaMask (or, for nerd-font
-- glyphs, paints a colored glyph directly) rather than drawing a border/
-- background around an unmodified icon. It keeps its own
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
            face    = style.glyphFace(size),
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

-- Label face of a cell or row: the caller's resolved face when given, else
-- the default UI face at spec.lbl_fs.
local function _labelFace(spec)
    return spec.lbl_face or Font():getFace(SUIStyle().FACE_REGULAR, spec.lbl_fs or SUIStyle().FS_DETAIL)
end

-- Builds a single-line label that never exceeds `opts.max_width`: longer text
-- is cut with a trailing ellipsis.
-- opts: text, face, bold, fgcolor, max_width — forwarded to TextWidget.
function QARenderer.buildLabel(opts)
    return TextWidget():new{
        text                   = opts.text,
        face                   = opts.face,
        bold                   = opts.bold,
        fgcolor                = opts.fgcolor,
        max_width              = opts.max_width,
        truncate_with_ellipsis = true,
    }
end

-- Widest label a tab cell of width `tab_w` can hold: the cell minus a small
-- margin on each side, so neighbouring labels never touch.
function QARenderer.tabLabelMaxWidth(tab_w)
    return tab_w - 2 * Screen:scaleBySize(4)
end

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
--   fixed_size, corner_r, frame_pad, shape, surface  — forwarded to
--     buildFrame (see its doc comment).
--   fgcolor                  — icon/label color (default SUIStyle.COLOR.text_primary).
--   icon_opts                — forwarded to buildIcon (see its doc comment).
--   show_label, lbl_sp, lbl_h, lbl_fs, lbl_face  — label row, shown below the
--     frame when show_label is true. lbl_face is a resolved font face; without
--     it the default UI face at lbl_fs is used. lbl_bold asks the text widget
--     to embolden the label (the face has no bold file of its own).
--   lbl_w                    — label CenterContainer width (default frame_sz).
--     Labels longer than this are truncated with an ellipsis.
--   on_tap_fn, tap_event_name  — when on_tap_fn is given, the cell is
--     wrapped in an InputContainer with its own tap GestureRange dispatching
--     to on_tap_fn(action_id). When omitted, the cell is returned untapped
--     (the Quick Settings bar dispatches taps itself against frame_widget).
--   focusable — with on_tap_fn, the tap container is also a D-pad focus
--     stop (see UI.makeFocusable).
function QARenderer.buildCell(action_id, spec)
    spec = spec or {}
    local style = SUIStyle()
    local entry = QA().getEntry(action_id)

    local frame_sz = spec.frame_sz or spec.icon_sz
    local fgcolor  = spec.fgcolor or style.COLOR.text_primary

    -- The icon sits on the surface, the label below it on the page.
    local icon_fg, on_surface = QARenderer.onSurfaceColor(spec)
    local icon_opts = spec.icon_opts
    if on_surface then
        icon_opts = setmetatable({ tint = true }, { __index = icon_opts })
    end
    local icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, icon_fg, icon_opts)
    local frame_widget = QARenderer.buildFrame(icon_widget, frame_sz, {
        shape      = spec.shape,
        surface    = spec.surface,
        corner_r   = spec.corner_r,
        frame_pad  = spec.frame_pad,
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
            QARenderer.buildLabel{
                text      = entry.label,
                face      = _labelFace(spec),
                bold      = spec.lbl_bold,
                fgcolor   = fgcolor,
                max_width = lbl_w,
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
-- tappable. The row is only as wide as its content (capped at `spec.inner_w`,
-- with longer labels truncated by an ellipsis); the caller aligns rows against
-- each other. Used by the Action List module.
--
-- spec fields:
--   inner_w, row_h            — required.
--   show_icon, icon_sz, icon_gap, icon_opts  — icon column, omitted entirely
--     when show_icon is false.
--   lbl_fs, lbl_face, lbl_bold — label text; same convention as buildCell.
--   fgcolor                   — icon/label color.
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
        text                   = entry.label,
        face                   = _labelFace(spec),
        bold                   = spec.lbl_bold,
        fgcolor                = fgcolor,
        max_width              = text_w,
        truncate_with_ellipsis = true,
        padding                = 0,
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

    return _buildTapContainer(hg, content_w, spec.row_h, action_id, spec, "TapALCell")
end

-- Width of the active indicator of a floating bar, relative to the tab width.
local FLOATING_INDICATOR_FRAC = 0.4

-- Builds one bottom-bar tab cell: icon and/or label (per spec.mode) plus an
-- active-tab indicator line pinned to the top. Used by sui_bottombar.lua.
--
-- Icons always render via buildIcon regardless of bar style: raster icons keep
-- their original colours and a missing/invalid file falls back to a
-- single-letter widget. Labels are truncated to fit the cell
-- (see tabLabelMaxWidth).
--
-- spec fields:
--   tab_w, bar_h, icon_sz, icon_txt_sp, indic_h  — required sizing.
--   lbl_face, lbl_bold — font face of the tab label and its emboldening flag;
--     same convention as buildCell.
--   mode        — "icons" / "text" / "both".
--   full_width  — true draws the active-indicator line across the cell
--     (full-width bar); a floating bar draws a short centred one, and only
--     when an accent colour is set.
--   fgcolor     — icon/label color; also the active-indicator colour when no
--     accent colour is set.
--   surface_color — colour of the bar the cell sits on; the active label and
--     glyph icon take the accent colour only when it contrasts with it.
--   inactive_indicator_color — drawn under a full-width bar's top edge when
--     the tab isn't active and the bar is opaque; nil = omitted.
function QARenderer.buildTabCell(action_id, active, spec)
    spec = spec or {}
    local style = SUIStyle()
    local entry = QA().getEntry(action_id)
    local item_fg = spec.fgcolor or style.COLOR.text_primary
    local mode = spec.mode or "both"
    local content_fg, tinted = item_fg, false
    if active and spec.surface_color and Accent.isReadableOn(spec.surface_color) then
        content_fg, tinted = Accent.color(), true
    end

    local vg = VerticalGroup():new{ align = "center" }

    if mode == "icons" or mode == "both" then
        local icon_widget = QARenderer.buildIcon(entry, spec.icon_sz, content_fg, {
            container_w = spec.tab_w,
            container_h = spec.icon_sz,
        })
        if icon_widget then vg[#vg + 1] = icon_widget end
    end

    if mode == "text" or mode == "both" then
        if mode == "both" then
            vg[#vg + 1] = VerticalSpan():new{ width = spec.icon_txt_sp or 0 }
        end
        local label = {
            text      = entry.label,
            face      = _labelFace(spec),
            bold      = spec.lbl_bold,
            fgcolor   = content_fg,
            max_width = QARenderer.tabLabelMaxWidth(spec.tab_w),
        }
        -- TextWidget draws colours as gray; a tinted label keeps its colour.
        if tinted then
            label.truncate_with_ellipsis = true
            vg[#vg + 1] = UI().makeColoredText(label)
        else
            vg[#vg + 1] = QARenderer.buildLabel(label)
        end
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

    if spec.full_width then
        if active then
            local indicator = UI().solidBar(spec.tab_w, spec.indic_h, style.accent(item_fg))
            indicator.overlap_offset = { 0, 0 }
            og[#og + 1] = indicator
        elseif spec.inactive_indicator_color then
            og[#og + 1] = LineWidget():new{
                dimen          = Geom():new{ w = spec.tab_w, h = spec.indic_h },
                background     = spec.inactive_indicator_color,
                overlap_offset = { 0, 0 },
            }
        end
    elseif active and Accent.color() then
        local w = math.floor(spec.tab_w * FLOATING_INDICATOR_FRAC)
        local indicator = UI().solidBar(w, spec.indic_h, Accent.color())
        indicator.overlap_offset = { math.floor((spec.tab_w - w) / 2), 0 }
        og[#og + 1] = indicator
    end

    return og
end

return QARenderer
