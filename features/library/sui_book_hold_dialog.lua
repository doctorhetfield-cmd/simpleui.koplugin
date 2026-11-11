-- sui_book_hold_dialog.lua — Simple UI
--
-- Action sheet for a single book, shared by every surface that lists books:
-- the home screen modules, search results and the file browser.
--
-- Actions come from the generators the file browser uses (status, reset,
-- collections, book information, ...) and from rows registered through
-- FileManager:addFileDialogButtons, so behaviour and translations match the
-- file browser's own dialog. Rows that only make sense for folders or for
-- multi-file selections are not offered.
--
-- Layout (see engines/sui_action_sheet.lua)
--   clipboard tiles → status segments → actions grid → list of further rows
-- The grid has two columns. It holds the book actions, then the registered
-- rows with several items (ignore cover / metadata) and ends with "Delete" and
-- "Rename". The clipboard tiles and that last row only appear when the sheet
-- is opened from the file browser.
--
-- Public API
--   BookHoldDialog.show(file, opts) -> window
--   BookHoldDialog.canHandle(file_chooser, item) -> boolean
--   BookHoldDialog.showFromFileChooser(file_chooser, item) -> window
--
-- opts (see also features/library/sui_hold_rows.lua)
--   title             string?    Defaults to the book title, then the file name.
--   reveal_fn         function?  Brings the caller back on top after a native
--                                screen opened by a row (Collections, Book
--                                information) closes and no refresh_fn is set.
--   open_settings_fn  function?  Adds an "Open module settings" row.
--   extra_rows        function?  (file, close) -> { row, ... }. Rows appended to
--                                the list; `close` closes the sheet.

local UIManager        = require("ui/uimanager")
local BD               = require("ui/bidi")
local BookList         = require("ui/widget/booklist")
local DocumentRegistry = require("document/documentregistry")
local filemanagerutil  = require("apps/filemanager/filemanagerutil")
local SH               = require("modules/module_books_shared")
local _                = require("infra/sui_i18n").translate

local Rows = require("features/library/sui_hold_rows")

local M = {}

local SHEET_NAME = "sui_win_book_actions"

local function bookTitle(file)
    local ok, data = pcall(SH.getBookData, file)
    if ok and data and data.title and data.title ~= "" then return data.title end
    return BD.filename(file:match("([^/]+)$") or file)
end

-- ---------------------------------------------------------------------------
-- Hand-off to native screens
-- ---------------------------------------------------------------------------

-- Tags the widget passed to the next UIManager:show() so the home screen
-- stays open underneath it. The tag is used once and dropped on the next
-- tick if nothing was shown.
local function keepHomescreenForNextShow()
    local prev_show = UIManager.show
    local restored  = false
    local function restore()
        if not restored then
            restored = true
            UIManager.show = prev_show
        end
    end
    UIManager.show = function(um_self, widget, ...)
        restore()
        if widget then widget._sui_keep_homescreen = true end
        return prev_show(um_self, widget, ...)
    end
    UIManager:nextTick(restore)
end

-- Refreshes the caller after a native screen closed, or reveals it when it
-- has no refresh.
local function refreshOrReveal(opts)
    if opts.refresh_fn then
        opts.refresh_fn()
    else
        opts.reveal_fn()
    end
end

-- Calls `on_closed` once the collections list has been dismissed. The list
-- can be replaced by another instance while open, and its close callback
-- also fires after every tap on a collection; only the reference being
-- dropped counts as a dismissal.
local function watchCollectionsList(file_manager, on_closed)
    local function hook(list)
        if not list then return end
        local previous_close = list.close_callback
        list.close_callback = function(...)
            if previous_close then previous_close(...) end
            UIManager:nextTick(function()
                local current = file_manager.collections
                    and file_manager.collections.coll_list
                if current == list then return end
                if current then
                    hook(current)
                    return
                end
                on_closed()
            end)
        end
    end
    return hook
end

local function wrapCollectionsButton(button, file_manager, opts)
    local open = button.callback
    button.callback = function(...)
        keepHomescreenForNextShow()
        open(...)
        watchCollectionsList(file_manager, function() refreshOrReveal(opts) end)(
            file_manager.collections.coll_list)
    end
end

local function wrapBookInfoButton(button, opts)
    local open = button.callback
    button.callback = function(...)
        keepHomescreenForNextShow()
        open(...)
        local ok, ui = pcall(function()
            return require("apps/reader/readerui").instance
                or require("apps/filemanager/filemanager").instance
        end)
        local page = ok and ui and ui.bookinfo and ui.bookinfo.kvp_widget
        if not page then return end
        local previous_close = page.close_callback
        page.close_callback = function(...)
            if previous_close then previous_close(...) end
            refreshOrReveal(opts)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

-- Adds the book state to the shared context: `state` is the document settings
-- once the book has been opened and the path otherwise; `book_props` are its
-- cached or stored properties.
local function newBookContext(file, opts)
    local ctx = Rows.newContext(file, opts)
    ctx.has_provider = DocumentRegistry:hasProvider(file)
    ctx.been_opened  = BookList.hasBookBeenOpened(file)
    ctx.is_book      = ctx.has_provider or ctx.been_opened
    ctx.state        = file

    if ctx.is_book then
        local fm = ctx.file_manager
        if ctx.been_opened then ctx.state = BookList.getDocSettings(file) end
        ctx.book_props = fm and fm.coverbrowser and fm.coverbrowser:getBookInfo(file)
        if ctx.been_opened and not ctx.book_props then
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            ctx.book_props = BookInfo.extendProps(ctx.state:readSetting("doc_props"), file)
            -- A cover may exist; whether it does is not known here.
            ctx.book_props.has_cover = true
        end
    end
    return ctx
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

-- Status segments. The current status is the one whose button the generator
-- disables. Choosing a status refreshes the caller and redraws the segments,
-- the sheet stays open.
local function statusSection(ctx)
    local section = { type = "segments", items = {} }

    local function load()
        local items = filemanagerutil.genStatusButtonsRow(ctx.state, function()
            ctx.refresh()
            load()
            ctx.sheet:repaint()
        end)
        for _i, item in ipairs(items) do
            item.selected = item.enabled == false
        end
        section.items = items
    end

    load()
    return section
end

local function openWithItem(ctx)
    return {
        text     = _("Open with…"),
        sui_icon = "open_with",
        enabled  = ctx.has_provider,
        callback = function()
            ctx.close()
            if ctx.file_manager then ctx.file_manager:showOpenWithDialog(ctx.path) end
        end,
    }
end

local function collectionsItem(ctx)
    local fm = ctx.file_manager
    if not (ctx.is_book and fm and fm.collections) then return nil end
    local item = fm.collections:genAddToCollectionButton(ctx.path, ctx.close, ctx.refresh)
    if ctx.opts.reveal_fn then wrapCollectionsButton(item, fm, ctx.opts) end
    return Rows.tag(item, "collections")
end

local function convertItem(ctx)
    local ok, Converter = pcall(require, "apps/filemanager/filemanagerconverter")
    if not (ok and Converter and Converter:isSupported(ctx.path)) then return nil end
    return Rows.tag(Converter:genConvertButton(ctx.path, ctx.close, ctx.refresh), "convert")
end

local function annotationItems(ctx)
    local fm = ctx.file_manager
    if not (ctx.been_opened and fm and fm.collections) then return end
    local annotations = ctx.state:readSetting("annotations")
    if not (annotations and #annotations > 0) then return end
    local files = { [ctx.path] = true }
    return Rows.tag(fm.collections:genExportHighlightsButton(files, ctx.close), "export"),
           Rows.tag(fm.collections:genBookmarkBrowserButton(files, ctx.close), "notes")
end

-- "Book cover": opens the cover window, which views and changes the cover.
local function coverItem(ctx)
    return {
        text     = _("Book cover"),
        sui_icon = "cover",
        callback = function()
            ctx.close()
            require("features/library/cover_editor/sui_cover_window").show(ctx.path, {
                on_change = ctx.refresh,
            })
        end,
    }
end

-- Rows of the book actions in the grid.
local function actionRows(ctx)
    local rows = {}
    if ctx.is_book then
        Rows.pushRow(rows,
            Rows.tag(filemanagerutil.genResetSettingsButton(ctx.state, ctx.closeAndRefresh), "reset"),
            collectionsItem(ctx))
    end
    Rows.pushRow(rows, convertItem(ctx))
    Rows.pushRow(rows, annotationItems(ctx))

    local info = Rows.tag(
        filemanagerutil.genBookInformationButton(ctx.state, ctx.book_props, ctx.close), "info")
    if ctx.opts.reveal_fn then wrapBookInfoButton(info, ctx.opts) end
    Rows.pushRow(rows, openWithItem(ctx), info)

    if ctx.has_provider then
        Rows.pushRow(rows,
            coverItem(ctx),
            Rows.tag(filemanagerutil.genBookDescriptionButton(ctx.path, ctx.book_props, ctx.close), "description"))
    end
    return rows
end

local function settingsItem(ctx)
    return {
        text     = _("Open module settings"),
        sui_icon = "settings",
        callback = function()
            ctx.close()
            ctx.opts.open_settings_fn()
        end,
    }
end

-- Rows registered through FileManager:addFileDialogButtons.
local function registeredRows(ctx)
    local rows = {}
    Rows.appendRegisteredRows(ctx, rows, true, ctx.book_props)
    return rows
end

-- Rows of the actions grid: the book actions, the registered rows that hold
-- several items, then the file's own delete and rename.
local function gridRows(ctx, registered)
    local rows = actionRows(ctx)
    for _i, row in ipairs(registered) do
        if #row > 1 then rows[#rows + 1] = row end
    end
    local manage = Rows.manageRow(ctx, true)
    if manage then Rows.appendRow(rows, manage) end
    return rows
end

-- Rows of the list below the grid: the registered single-item rows, caller
-- rows and the remaining actions. `delete` is the "Delete" item, nil when the
-- actions grid already offers it.
local function listRows(ctx, registered, delete)
    local rows = {}
    local opts = ctx.opts

    for _i, row in ipairs(registered) do
        if #row == 1 then rows[#rows + 1] = row end
    end

    if opts.extra_rows then
        local ok, extra = pcall(opts.extra_rows, ctx.path, ctx.close)
        for _i, row in ipairs(ok and extra or {}) do Rows.appendRow(rows, row) end
    end
    if ctx.file_chooser then Rows.pushRow(rows, Rows.executeScriptItem(ctx)) end

    if delete then Rows.pushRow(rows, delete) end
    if opts.open_settings_fn then Rows.pushRow(rows, settingsItem(ctx)) end
    return rows
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.show(file, opts)
    opts = opts or {}
    local ctx = newBookContext(file, opts)

    local sections = {}
    local clipboard = Rows.clipboardItems(ctx, true)
    if #clipboard > 0 then
        sections[#sections + 1] = { type = "tiles", items = clipboard }
    end
    if ctx.is_book then
        sections[#sections + 1] = statusSection(ctx)
    end
    local registered = registeredRows(ctx)
    local delete = ctx.file_manager and #clipboard == 0 and Rows.deleteItem(ctx) or nil
    local grid = gridRows(ctx, registered)
    if #grid > 0 then
        sections[#sections + 1] = { type = "rows", rows = grid }
    end
    local list = listRows(ctx, registered, delete)
    if #list > 0 then
        sections[#sections + 1] = { type = "rows", rows = list }
    end

    return Rows.show(ctx, {
        name     = SHEET_NAME,
        title    = opts.title or bookTitle(file),
        icon     = "book_open",
        sections = sections,
    })
end

--- True when a long press on `item` in the file browser opens this sheet,
--- i.e. the item is a book file.
function M.canHandle(file_chooser, item)
    if not Rows.isBrowserItem(file_chooser, item) or not item.is_file then return false end
    return DocumentRegistry:hasProvider(item.path) or BookList.hasBookBeenOpened(item.path)
end

function M.showFromFileChooser(file_chooser, item)
    return M.show(item.path, { file_chooser = file_chooser, item = item })
end

return M
