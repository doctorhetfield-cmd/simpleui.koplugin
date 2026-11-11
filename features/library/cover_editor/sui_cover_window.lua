-- sui_cover_window.lua — Simple UI
-- "Book cover" window: shows a book's current cover with where it comes from
-- and its size, and the actions that change it (online search, an image
-- from the device, undo of the last change, the book's own cover). A tap on
-- the cover shows it full screen. The online search is a second screen.
--
-- The decoded cover is kept for the window's life, shared by the preview and
-- the full-screen view, and freed when it is replaced or the window closes.
--
-- Public API
--   CoverWindow.show(file, opts)
--     opts.on_change  function?  called after the cover changed

local CenterContainer  = require("ui/widget/container/centercontainer")
local Device           = require("device")
local DocumentRegistry = require("document/documentregistry")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local HorizontalGroup  = require("ui/widget/horizontalgroup")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local ImageWidget      = require("ui/widget/imagewidget")
local Size             = require("ui/size")
local TextWidget       = require("ui/widget/textwidget")
local UIManager        = require("ui/uimanager")
local VerticalGroup    = require("ui/widget/verticalgroup")
local VerticalSpan     = require("ui/widget/verticalspan")
local util             = require("util")
local _                = require("infra/sui_i18n").translate
local Screen           = Device.screen

local CoverPlaceholder = require("engines/sui_cover_placeholder")
local SUIWindow        = require("engines/sui_window")
local SUIStyle         = require("features/sui_style")
local UI               = require("infra/sui_core")
local CoverSearch      = require("features/library/cover_editor/sui_cover_search")
local CoverStore       = require("features/library/cover_editor/sui_cover_store")

local CoverWindow = {}

local COVER_ASPECT = 1.5
local PREVIEW_FRACTION = 0.28  -- of the window's inner width

-- The cover fitted into a w × h box, in a thin frame, centred in a column w
-- wide and as tall as the framed image.
local function buildPreview(cover, book, w, h)
    if not cover.bb then
        return CoverPlaceholder.build(w, h, book.title, book.authors)
    end
    local border = Size.border.thin
    local scale  = math.min((w - 2 * border) / cover.width, (h - 2 * border) / cover.height)
    local img_h  = math.max(1, math.floor(cover.height * scale))
    local image = ImageWidget:new{
        image            = cover.bb,
        image_disposable = false,
        width            = math.max(1, math.floor(cover.width * scale)),
        height           = img_h,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = img_h + 2 * border },
        FrameContainer:new{
            bordersize = border,
            color      = SUIStyle.COLOR.text_primary,
            padding    = 0,
            margin     = 0,
            image,
        },
    }
end

-- One "label  value" line of the details column.
local function detailLine(label, value, face, max_w)
    local label_w = UI.makeColoredText{
        text    = label,
        face    = face,
        fgcolor = SUIStyle.COLOR.text_dim,
    }
    local gap = Size.span.horizontal_default
    return HorizontalGroup:new{
        align = "center",
        label_w,
        HorizontalSpan:new{ width = gap },
        TextWidget:new{
            text      = value,
            face      = face,
            max_width = math.max(1, max_w - label_w:getSize().w - gap),
        },
    }
end

local function sourceText(cover)
    if cover.custom_path then return _("Custom image") end
    if cover.bb then return _("Book file") end
    return _("No cover")
end

-- Preview on the left, title, author and cover details on the right. A tap
-- on the preview (or Press when it has the focus) runs `on_view`.
local function buildHeader(ctx, cover, book, on_view)
    local SZ = ctx.SZ
    local preview_w = math.floor(ctx.inner_w * PREVIEW_FRACTION)
    local preview_h = math.floor(preview_w * COVER_ASPECT)
    local gap       = SZ(Screen:scaleBySize(16))
    local text_w    = math.max(1, ctx.inner_w - preview_w - gap)

    local title_face  = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local detail_face = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))

    local info = VerticalGroup:new{ align = "left" }
    info[#info + 1] = TextWidget:new{
        text      = book.title,
        face      = title_face,
        bold      = true,
        max_width = text_w,
    }
    if book.authors and book.authors ~= "" then
        info[#info + 1] = UI.makeColoredText{
            text      = book.authors,
            face      = detail_face,
            fgcolor   = SUIStyle.COLOR.text_dim,
            max_width = text_w,
        }
    end
    info[#info + 1] = VerticalSpan:new{ width = SZ(Screen:scaleBySize(12)) }
    info[#info + 1] = detailLine(_("Source"), sourceText(cover), detail_face, text_w)
    if cover.width and cover.height then
        info[#info + 1] = detailLine(_("Dimensions"),
            string.format("%d × %d", cover.width, cover.height), detail_face, text_w)
    end
    if cover.filesize then
        info[#info + 1] = detailLine(_("File size"),
            util.getFriendlySize(cover.filesize), detail_face, text_w)
    end

    local preview = buildPreview(cover, book, preview_w, preview_h)
    if cover.bb then
        preview = SUIWindow.Input.tapable(preview, { on_tap = on_view },
            Geom:new{ w = preview_w, h = preview:getSize().h })
    end

    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = SZ(Screen:scaleBySize(12)) },
        HorizontalGroup:new{
            align = "top",
            preview,
            HorizontalSpan:new{ width = gap },
            info,
        },
        VerticalSpan:new{ width = SZ(Screen:scaleBySize(8)) },
    }
end

function CoverWindow.show(file, opts)
    opts = opts or {}
    local SH   = require("modules/module_books_shared")
    local book = SH.getBookData(file)
    local state = {}

    local function reload()
        if state.cover and state.cover.bb then state.cover.bb:free() end
        state.cover    = CoverStore.load(file)
        state.can_undo = CoverStore.canUndo(file)
    end

    local win
    -- Runs a cover change, then shows the new cover (back on the main screen
    -- when `back` is set) and refreshes the caller.
    local function change(fn, back)
        if not fn() then
            UI.Notify.toast(_("Could not change the cover."))
        end
        reload()
        if back then win:pop() else win:repaint() end
        if opts.on_change then opts.on_change() end
    end

    local function searchOnline(ctx)
        state.search = state.search or CoverSearch.new{
            file  = file,
            book  = book,
            apply = function(path)
                change(function() return CoverStore.apply(file, path) end, true)
            end,
        }
        ctx.push("search")
        if not state.search.results then state.search:run(ctx) end
    end

    local function showFullScreen()
        local ImageViewer = require("ui/widget/imageviewer")
        UIManager:show(ImageViewer:new{
            image            = state.cover.bb,
            image_disposable = false,
            with_title_bar   = false,
            fullscreen       = true,
        })
    end

    local function chooseFromDevice()
        local AssetBrowser = require("engines/sui_asset_browser")
        UIManager:show(AssetBrowser:new{
            path       = (util.splitFilePathName(file)),
            extensions = DocumentRegistry.image_ext,
            title      = _("Choose cover image"),
            onConfirm  = function(path)
                change(function() return CoverStore.apply(file, path) end)
            end,
        })
    end

    local function confirmRestore()
        require("features/dialogs/sui_dialogs").confirm{
            text        = _("Restore the book's original cover?"),
            ok_text     = _("Restore"),
            ok_callback = function()
                change(function() return CoverStore.restoreOriginal(file) end)
            end,
        }
    end

    local function buildRoot(ctx)
        local cover = state.cover
        return {
            buildHeader(ctx, cover, book, showFullScreen),
            SUIWindow.ListRow{
                inner_w   = ctx.inner_w,
                title     = _("Search online"),
                show_chevron = true,
                on_tap    = function() searchOnline(ctx) end,
            },
            SUIWindow.ListRow{
                inner_w   = ctx.inner_w,
                title     = _("Choose from device"),
                on_tap    = chooseFromDevice,
            },
            SUIWindow.ListRow{
                inner_w   = ctx.inner_w,
                title     = _("Undo last change"),
                enabled   = state.can_undo,
                on_tap    = function()
                    change(function() return CoverStore.undo(file) end)
                end,
            },
            SUIWindow.ListRow{
                inner_w   = ctx.inner_w,
                title     = _("Restore original cover"),
                enabled   = cover.custom_path ~= nil,
                on_tap    = confirmRestore,
                separator = false,
            },
        }
    end

    reload()
    win = SUIWindow:new{
        name          = "sui_win_book_cover",
        icon          = "cover",
        title         = _("Book cover"),
        screen_titles = { search = _("Search online") },
        auto_height_per_screen = true,
        navpager_mode = require("infra/sui_config").isNavpagerEnabled(),
        screens       = {
            __root__ = buildRoot,
            search   = function(ctx) return state.search:build(ctx) end,
        },
        screen_footers = {
            search = function(ctx) return state.search:footer(ctx) end,
        },
        on_close      = function()
            if state.cover and state.cover.bb then state.cover.bb:free() end
            if state.search then state.search:free() end
            state.cover, state.search = nil, nil
        end,
    }
    win:show()
    return win
end

return CoverWindow
