-- sui_cover_search.lua — Simple UI
-- "Search online" screen of the cover window: a form with the query
-- (editable) and the Apple Books opt-in, and a Search button. The query is a
-- title and author, searched with the book's ISBN when it has one, or an
-- ISBN, which finds only that edition. The covers
-- found open in a sheet over the window, as pages of thumbnails with their
-- source and size; a tap selects a cover and the sheet's button applies it.
--
-- The search runs behind KOReader's Wi-Fi prompt and a progress notice that
-- a tap cancels; the covers found until then are kept. Thumbnails are decoded once per search and
-- freed when replaced or when the window closes; closing the sheet keeps
-- them, so the results can be shown again without searching.
--
-- Public API
--   local search = CoverSearch.new{ file, book, apply = function(path) end }
--     apply runs when the sheet's button is tapped, with the chosen image
--   search:build(ctx)   -> widgets of the screen
--   search:footer(ctx)  -> footer widget
--   search:run(ctx)     -- runs the search, then shows the results
--   search:free()

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local Size            = require("ui/size")
local T               = require("ffi/util").template
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local I18n            = require("infra/sui_i18n")
local _               = I18n.translate
local N_              = I18n.ngettext
local Screen          = Device.screen

local ActionSheet  = require("engines/sui_action_sheet")
local PageNav      = require("engines/sui_page_nav")
local SUIWindow    = require("engines/sui_window")
local SUIStyle     = require("features/sui_style")
local SUISettings  = require("infra/sui_store")
local UI           = require("infra/sui_core")
local CoverSources = require("features/library/cover_editor/sui_cover_sources")

local CoverSearch = {}
CoverSearch.__index = CoverSearch

local APPLE_KEY = "simpleui_cover_search_apple"
local COVER_ASPECT = 1.5
local PAGE_ROWS = 2

-- Columns and cell width of a result grid `inner_w` wide.
local function gridGeometry(ctx, inner_w)
    local gap      = ctx.SZ(Screen:scaleBySize(8))
    local min_cell = ctx.SZ(Screen:scaleBySize(90))
    local cols     = math.max(2, math.min(4, math.floor((inner_w + gap) / (min_cell + gap))))
    local cell_w   = math.floor((inner_w - gap * (cols - 1)) / cols)
    return cols, cell_w, math.floor(cell_w * COVER_ASPECT), gap
end

local function captionFace(ctx)
    return Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION))
end

function CoverSearch.new(opts)
    local self = setmetatable({}, CoverSearch)
    self.apply = opts.apply
    local book = opts.book
    self.query = book.authors ~= "" and (book.title .. " " .. book.authors) or book.title
    self.isbn  = CoverSources.isbnOf(opts.file)
    self.results  = nil   -- nil until a search ran
    self.selected = nil
    self.page     = 1
    return self
end

function CoverSearch:free()
    if self.sheet then self.sheet:close() end
    for _i, c in ipairs(self.results or {}) do
        if c.thumb then c.thumb:free() end
    end
    self.results, self.selected = nil, nil
    CoverSources.clearCache()
end

function CoverSearch:run(ctx)
    -- Thumbnails fit the sheet's cells inside the selection frame, so they
    -- are drawn at their own size.
    self.sheet_w = SUIWindow.stackedWidth()
    local _cols, cell_w, cell_h = gridGeometry(ctx, SUIWindow.innerWidth(self.sheet_w))
    local frame = 2 * Size.border.thick
    local function search()
        local typed_isbn = CoverSources.parseIsbn(self.query)
        UI.Notify.progress(function(progress)
            return CoverSources.search{
                query         = typed_isbn and "" or self.query,
                isbn          = typed_isbn or self.isbn,
                include_apple = SUISettings:isTrue(APPLE_KEY),
                thumb_w       = cell_w - frame,
                thumb_h       = cell_h - frame,
                on_progress   = progress,
            }
        end, function(results, cancelled, offline)
            -- Frees the previous thumbnails; their files were already cleared.
            for _i, c in ipairs(self.results or {}) do
                if c.thumb then c.thumb:free() end
            end
            -- A search that found nothing because it was cancelled or reached
            -- no server leaves the form as it was before the first search.
            local unfinished = #results == 0 and (cancelled or offline)
            self.results, self.selected, self.page = not unfinished and results or nil, nil, 1
            ctx.repaint()
            if unfinished then
                UI.Notify.toast(cancelled and _("Search cancelled")
                    or _("Could not reach the cover services. Check your connection."))
            elseif #results > 0 then
                self:showResults()
            end
        end)
    end
    local NetworkMgr = require("infra/sui_config").getNetworkMgr()
    if NetworkMgr then
        -- Connected is enough: without internet the search reports it.
        NetworkMgr:runWhenConnected(search)
    else
        search()
    end
end

-- One result: the thumbnail framed (thick frame when selected), then the
-- source and the image size. The thumbnail is drawn at its own size; it is
-- only scaled down when the sheet's cells shrank since the search (rotation).
function CoverSearch:buildCell(ctx, index, cell_w, cell_h)
    local c = self.results[index]
    local selected = self.selected == index
    local border = selected and Size.border.thick or Size.border.thin
    local thumb_w, thumb_h = c.thumb:getWidth(), c.thumb:getHeight()
    local scale = math.min(1, (cell_w - 2 * Size.border.thick) / thumb_w,
        (cell_h - 2 * Size.border.thick) / thumb_h)
    local image = ImageWidget:new{
        image            = c.thumb,
        image_disposable = false,
        width            = math.max(1, math.floor(thumb_w * scale)),
        height           = math.max(1, math.floor(thumb_h * scale)),
    }
    local face = captionFace(ctx)
    local cell = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            FrameContainer:new{
                bordersize = border,
                color      = SUIStyle.COLOR.text_primary,
                padding    = 0,
                margin     = 0,
                image,
            },
        },
        VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
        TextWidget:new{
            text      = c.source,
            face      = face,
            bold      = selected,
            max_width = cell_w,
        },
        UI.makeColoredText{
            text      = string.format("%d × %d", c.width, c.height),
            face      = face,
            fgcolor   = SUIStyle.COLOR.text_dim,
            max_width = cell_w,
        },
    }
    return SUIWindow.Input.tapable(cell, {
        on_tap = function()
            self.selected = index
            self.sheet:update{ footer = self:sheetFooter() }
        end,
    }, Geom:new{ w = cell_w, h = cell:getSize().h })
end

-- Centred page indicator with its chevrons; they are D-pad focus stops.
function CoverSearch:buildPager(ctx, npages)
    local face  = PageNav.indicatorFace(UI.getLandscapeFactor())
    local row_h = PageNav.rowHeight(face)
    local pager, stops = PageNav.buildPager(self.page, npages, row_h,
        TextWidget:new{ text = string.format("%d/%d", self.page, npages), face = face },
        Size.padding.large,
        function(delta)
            self.page = self.page + delta
            self.sheet:repaint()
        end,
        true)
    for _i, stop in ipairs(stops) do
        local _w, focused = SUIWindow.Input.focusStop(stop.widget,
            { on_select = stop.widget.onTapPageNav })
        stop.widget._kb_focused = focused
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = ctx.inner_w, h = row_h },
        pager,
    }
end

-- Current page of the result grid: PAGE_ROWS rows (one when two do not fit
-- the sheet), every page as tall as a full one, and the pager below.
function CoverSearch:buildGrid(ctx)
    local cols, cell_w, cell_h, gap = gridGeometry(ctx, ctx.inner_w)
    local row_h = cell_h + ctx.SZ(Screen:scaleBySize(4))
        + 2 * SUIStyle.faceHeight(captionFace(ctx)) + gap
    local rows = PAGE_ROWS
    if ctx.page_h and rows * row_h > ctx.page_h then rows = 1 end
    local per_page = rows * cols
    local npages = math.ceil(#self.results / per_page)
    self.page = math.max(1, math.min(self.page, npages))

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page + 1
    local last  = math.min(first + per_page - 1, #self.results)
    for row_first = first, last, cols do
        local row = HorizontalGroup:new{ align = "top" }
        for i = row_first, math.min(row_first + cols - 1, last) do
            if i > row_first then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = self:buildCell(ctx, i, cell_w, cell_h)
        end
        grid[#grid + 1] = VerticalGroup:new{
            align = "left",
            row,
            VerticalSpan:new{ width = gap },
        }
    end
    if npages > 1 then
        local missing = rows - math.ceil((last - first + 1) / cols)
        if missing > 0 then grid[#grid + 1] = VerticalSpan:new{ width = missing * row_h } end
        grid[#grid + 1] = self:buildPager(ctx, npages)
    end
    return grid
end

function CoverSearch:sheetFooter()
    local chosen = self.selected and self.results[self.selected]
    return {
        {
            text     = _("Cancel"),
            callback = function() self.sheet:close() end,
        },
        {
            text     = _("Use this cover"),
            primary  = true,
            enabled  = chosen ~= nil,
            callback = function()
                self.sheet:close()
                self.apply(chosen.path)
            end,
        },
    }
end

-- Opens the sheet of results over the window.
function CoverSearch:showResults()
    local n = #self.results
    self.sheet = ActionSheet.show{
        name     = "sui_win_cover_results",
        width    = self.sheet_w,
        title    = T(N_("%1 cover found", "%1 covers found", n), n),
        sections = {
            { type = "widget", build = function(ctx) return self:buildGrid(ctx) end },
        },
        footer   = self:sheetFooter(),
        on_close = function() self.sheet = nil end,
    }
end

function CoverSearch:build(ctx)
    local widgets = {
        SUIWindow.ListRow{
            inner_w   = ctx.inner_w,
            title     = self.query,
            -- The book's ISBN, used unless the query is an ISBN itself.
            subtitle  = self.isbn and not CoverSources.parseIsbn(self.query)
                and T(_("ISBN %1"), self.isbn) or nil,
            right_icon = "edit",
            on_tap    = function()
                require("features/dialogs/sui_dialogs").prompt{
                    title       = _("Search covers"),
                    description = _("Title, author or ISBN"),
                    value       = self.query,
                    ok_text     = _("Search"),
                    on_submit   = function(query)
                        self.query = query
                        self:run(ctx)
                    end,
                }
            end,
        },
        SUIWindow.ListRow{
            inner_w  = ctx.inner_w,
            title    = _("Include Apple Books"),
            subtitle = _("Artwork is subject to Apple's terms of use"),
            checked  = SUISettings:isTrue(APPLE_KEY),
            on_tap   = function()
                SUISettings:set(APPLE_KEY, not SUISettings:isTrue(APPLE_KEY))
                ctx.repaint()
            end,
        },
    }
    if not self.results then return widgets end
    local n = #self.results
    widgets[#widgets + 1] = SUIWindow.ListRow{
        inner_w   = ctx.inner_w,
        title     = n == 0 and _("No covers found.")
            or T(N_("Show %1 cover", "Show %1 covers", n), n),
        enabled   = n > 0,
        on_tap    = n > 0 and function() self:showResults() end or nil,
        separator = false,
    }
    return widgets
end

function CoverSearch:footer(ctx)
    return SUIWindow.CenteredButtonFooter(ctx, {
        text   = _("Search"),
        on_tap = function() self:run(ctx) end,
    })
end

return CoverSearch
