-- sui_native_sheets.lua — Simple UI
-- Shows the button dialogs of the desktop (file manager, collections, history,
-- folder and path pickers) as action sheets
-- (engines/sui_action_sheet.lua), so they share the look of the book and
-- folder sheets.
--
-- A dialog is converted when it is about to be shown (see the intercept
-- steps in infra/sui_window_hooks.lua). Its callers are not aware of it:
-- closing the dialog closes the sheet, and dismissing the sheet runs the
-- dialog's `tap_close_callback`.
--
-- Which dialogs are converted
--   * only plain button dialogs, with text buttons;
--   * only while the file manager is the active environment, never over a
--     book or over a Simple UI window;
--   * never a dialog anchored to a widget, a non-dismissable one, one with
--     added widgets, one with addressable buttons (`id`), or one flagged
--     `sui_native = true`.
-- Everything else is shown as usual.
--
-- What the sheet keeps of the dialog: its buttons, title, `sui_icon`,
-- `tap_close_callback` and any `onShow` / `onCloseWidget` set on the dialog
-- itself. What it replaces by the common look: `width`, `width_factor`,
-- `title_align`, `rows_per_page`, `colorful` and the font and alignment of
-- single buttons.
--
-- Hierarchy
--   * Rows of three or more buttons, pairs of choices (see Choices) and
--     confirmation pairs (a Cancel button beside an action without icon) are
--     drawn as segments; each selected or checked button is inverted.
--   * Other rows are drawn as icon cells: rows of two actions form a grid,
--     rows of one action a list, and consecutive rows of three or more actions
--     are reflowed in pairs into a grid. A button's own `sui_icon` is kept,
--     others get the icon their text maps to. A group of cells shows icons
--     only when at least half of its actions have one.
--   * A native separator row starts a new section.
--   * The first line of the title is the sheet title; further lines are the
--     sheet message. A dialog may set `sui_icon` to give the sheet a header
--     icon.
--
-- Choices
--   A button spec with a `checked_func` is a choice: its selection state is
--   known. A dialog that does not describe its own state can be given one
--   with NativeSheets.withChoices, which annotates the buttons of the dialog
--   shown while a function runs.
--   A choice may be drawn under another label. Choices that share a group,
--   wherever their buttons stand in the dialog, form one block of segments
--   ordered by rank and split into balanced rows.
--   A choice may also keep the sheet open: tapping it applies the choice,
--   then the code that showed the dialog runs again and the sheet takes the
--   content of the dialog it shows, so the state of every button (selection,
--   label, enabled) is read again. The dialog's own request to close is
--   ignored meanwhile. Tapping the selected choice does nothing, unless the
--   choice is a toggle: then it is applied again, as it clears the choice.
--
-- Public API
--   NativeSheets.withChoices(resolve, fn, ...)      runs fn and returns its
--                                                   results; the dialog it shows
--                                                   has its buttons annotated
--                                                   by `resolve(label)`, which
--                                                   returns the choice of a
--                                                   button, or nil (see Choice)
--
--   Choice  { checked, keep_open, toggle, text, group, rank }
--     checked    function() -> boolean   selection state
--     keep_open  boolean                 applying it leaves the sheet open
--     toggle     boolean                 tapping it while selected clears it
--     text       string                  label drawn instead of the button's
--     group      string                  block of segments the choice joins
--     rank       number                  position within its group
--   NativeSheets.canReplace(over_windows) -> boolean  whether native widgets may be
--                                                   drawn as sheets right now
--   NativeSheets.interceptShow(widget) -> boolean   show step (consumes the call)
--   NativeSheets.interceptClose(widget) -> boolean  close step (consumes the call)

local ButtonDialog = require("ui/widget/buttondialog")
local gettext      = require("gettext")
local logger       = require("logger")

local _unpack = table.unpack or unpack

local ActionSheet = require("engines/sui_action_sheet")
local DialogIcons = require("features/dialogs/sui_dialog_icons")
local SUIWindow   = require("engines/sui_window")

local NativeSheets = {}

local SHEET_NAME = "sui_win_native_dialog"
local CHECK_MARK = "\u{2713}"

-- Most segments in one row of a group.
local SEGMENTS_PER_ROW = 3

-- Native dialog → proxy { widget, window, choices, holding }. Present while the
-- sheet standing in for the dialog is open; `widget` is the dialog the sheet
-- currently stands for.
local proxies = setmetatable({}, { __mode = "k" })

-- { resolve, replay } set by withChoices while the function it wraps runs:
-- the resolver of the choices and a function that runs that function again.
local active_choices

-- Proxy whose dialog is being built again (see reshow).
local rebuilding

-- ---------------------------------------------------------------------------
-- Eligibility
-- ---------------------------------------------------------------------------

-- True while the file manager is the active environment: it exists and no
-- book is open.
local function isDesktop()
    local reader = package.loaded["apps/reader/readerui"]
    if reader and reader.instance then return false end
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    return file_manager ~= nil and file_manager.instance ~= nil
end

local function isSimpleUIWindowOpen()
    return #SUIWindow._open_instances > 0
end

-- True when `buttons` holds text buttons only, at least one, none addressable.
local function hasPlainButtons(buttons)
    local count = 0
    for _i, row in ipairs(buttons) do
        if type(row) ~= "table" then return false end
        for _j, spec in ipairs(row) do
            if spec.icon or (spec.id and spec.id ~= "close") then return false end
            if spec.text or spec.text_func then count = count + 1 end
        end
    end
    return count > 0
end

--- True when a native widget may be drawn as a sheet now: the file manager is
--- the active environment (no book open) and no Simple UI window is open, unless
--- `over_windows` allows the sheet to open above one.
function NativeSheets.canReplace(over_windows)
    return isDesktop() and (over_windows or not isSimpleUIWindowOpen())
end

local function isEligible(widget)
    return type(widget.buttons) == "table"
        and not widget.anchor
        and widget.dismissable ~= false
        and not widget._added_widgets
        and not widget.sui_native
        and NativeSheets.canReplace()
        and hasPlainButtons(widget.buttons)
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

-- Splits a leading or trailing check mark off a label. Returns the label and
-- whether a mark was found.
local function parseLabel(text)
    local label   = text:match("^%s*(.-)%s*$")
    local checked = false
    if label:sub(1, #CHECK_MARK) == CHECK_MARK then
        label, checked = label:sub(#CHECK_MARK + 1):match("^%s*(.-)$"), true
    elseif label:sub(-#CHECK_MARK) == CHECK_MARK then
        label, checked = label:sub(1, -#CHECK_MARK - 1):match("^(.-)%s*$"), true
    end
    return label, checked
end

-- Sheet item of a native button spec; nil for a hidden button or one without
-- text.
local function toItem(spec)
    if spec.hidden then return nil end
    local text = spec.text_func and spec.text_func() or spec.text
    if type(text) ~= "string" then return nil end

    local label, checked = parseLabel(text)
    if spec.checked_func and spec.checked_func() then checked = true end

    local enabled = spec.enabled ~= false
    if spec.enabled_func then enabled = spec.enabled_func() and true or false end

    -- A selected choice is drawn selected, not dimmed.
    local choice = spec.checked_func ~= nil
    if choice then enabled = enabled or checked end

    return {
        text          = label,
        sui_icon      = spec.sui_icon or DialogIcons.forText(label),
        enabled       = enabled,
        checked       = checked,
        choice        = choice,
        checked_func  = spec.checked_func,
        keep_open     = spec.sui_keep_open == true,
        clearable     = spec.sui_toggle == true,
        group         = spec.sui_group,
        rank          = spec.sui_rank or 0,
        callback      = spec.callback,
        hold_callback = spec.hold_callback,
    }
end

local function toItems(row)
    local items = {}
    for _i, spec in ipairs(row) do
        items[#items + 1] = toItem(spec)
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function hasIcon(items)
    for _i, item in ipairs(items) do
        if item.sui_icon then return true end
    end
    return false
end

local function hasCancel(items)
    local cancel = gettext("Cancel")
    for _i, item in ipairs(items) do
        if item.text == cancel then return true end
    end
    return false
end

-- True when every item is a choice.
local function allChoices(items)
    for _i, item in ipairs(items) do
        if not item.choice then return false end
    end
    return true
end

-- True for a Cancel button beside one action without icon.
local function isConfirmPair(items)
    return #items == 2 and not allChoices(items) and not hasIcon(items) and hasCancel(items)
end

-- Rows drawn as one row of buttons: three or more buttons, a pair of choices,
-- or a confirmation pair.
local function isSegmentRow(items)
    return #items >= 3 or (#items == 2 and (allChoices(items) or isConfirmPair(items)))
end

local function segmentsSection(items)
    local cancel = isConfirmPair(items) and gettext("Cancel")
    for _i, item in ipairs(items) do
        item.selected = item.checked
        item.primary  = cancel and item.text ~= cancel or nil
    end
    return { type = "segments", items = items }
end

-- Splits `items` into the fewest rows of at most SEGMENTS_PER_ROW, as even as
-- possible.
local function segmentRows(items)
    local row_count = math.ceil(#items / SEGMENTS_PER_ROW)
    local row_size  = math.ceil(#items / row_count)
    local rows = {}
    for first = 1, #items, row_size do
        rows[#rows + 1] = { _unpack(items, first, math.min(first + row_size - 1, #items)) }
    end
    return rows
end

-- Drops the icons of a group of rows unless at least half of its items have
-- one, so an icon never stands alone.
local function pruneIcons(rows)
    local total, iconed = 0, 0
    for _i, items in ipairs(rows) do
        for _j, item in ipairs(items) do
            total = total + 1
            if item.sui_icon then iconed = iconed + 1 end
        end
    end
    if iconed * 2 >= total then return end
    for _i, items in ipairs(rows) do
        for _j, item in ipairs(items) do item.sui_icon = nil end
    end
end

-- Rows of three or more actions: too narrow as cells, so their items are laid
-- out two per row.
local function isWideActionRow(items)
    return #items >= 3 and hasIcon(items)
end

-- Replaces each gathered group in `sections` by its segment rows, ordered by
-- rank.
local function expandGroups(sections)
    local expanded = {}
    for _i, section in ipairs(sections) do
        if section.type == "group" then
            table.sort(section.items, function(a, b) return a.rank < b.rank end)
            for _j, items in ipairs(segmentRows(section.items)) do
                expanded[#expanded + 1] = segmentsSection(items)
            end
        else
            expanded[#expanded + 1] = section
        end
    end
    return expanded
end

local function buildSections(buttons)
    local sections = {}
    local cells, wide
    local groups = {}

    -- Moves the items of consecutive wide rows into `cells`, two per row.
    local function flushWide()
        if not wide then return end
        cells = cells or {}
        for i = 1, #wide, 2 do
            cells[#cells + 1] = { wide[i], wide[i + 1] }
        end
        wide = nil
    end

    local function flush()
        flushWide()
        if not cells then return end
        pruneIcons(cells)
        sections[#sections + 1] = { type = "rows", rows = cells }
        cells = nil
    end

    for _i, row in ipairs(buttons) do
        local items = toItems(row)
        local group = items[1] and items[1].group
        if group then
            -- A group takes the place of its first row.
            local gathered = groups[group]
            if not gathered then
                flush()
                gathered = { type = "group", items = {} }
                groups[group] = gathered
                sections[#sections + 1] = gathered
            end
            for _j, item in ipairs(items) do gathered.items[#gathered.items + 1] = item end
        elseif #items == 0 then
            flush()
        elseif isWideActionRow(items) then
            wide = wide or {}
            for _j, item in ipairs(items) do wide[#wide + 1] = item end
        elseif isSegmentRow(items) then
            flush()
            sections[#sections + 1] = segmentsSection(items)
        else
            flushWide()
            cells = cells or {}
            cells[#cells + 1] = items
        end
    end
    flush()
    return expandGroups(sections)
end

-- First line of a dialog title as the sheet title, the rest as its message.
local function splitTitle(title)
    if type(title) ~= "string" then return nil, nil end
    local first, rest = title:match("^([^\n]*)\n+(.*)$")
    if not first then return title ~= "" and title or nil, nil end
    rest = rest:match("^%s*(.-)%s*$")
    return first ~= "" and first or nil, rest ~= "" and rest or nil
end

-- ---------------------------------------------------------------------------
-- Choices
-- ---------------------------------------------------------------------------

-- Applies `choice` to the button spec `copy`.
local function applyChoice(copy, choice)
    copy.checked_func  = choice.checked
    copy.sui_keep_open = choice.keep_open
    copy.sui_toggle    = choice.toggle
    copy.sui_group     = choice.group
    copy.sui_rank      = choice.rank
    if choice.text then
        copy.text, copy.text_func = choice.text, nil
    end
end

-- Copy of `buttons` in which each button carries the choice that `resolve`
-- returns for its label. The dialog's own button specs are left untouched.
local function annotate(buttons, resolve)
    local result = {}
    for i, row in ipairs(buttons) do
        result[i] = {}
        for j, spec in ipairs(row) do
            local copy = {}
            for key, value in pairs(spec) do copy[key] = value end
            local text = spec.text_func and spec.text_func() or spec.text
            if type(text) == "string" then
                local choice = resolve((parseLabel(text)))
                if choice then applyChoice(copy, choice) end
            end
            result[i][j] = copy
        end
    end
    return result
end

-- Calls fn(item) for every item of `sections`.
local function eachItem(sections, fn)
    for _i, section in ipairs(sections) do
        for _j, items in ipairs(section.rows or { section.items }) do
            for _k, item in ipairs(items) do fn(item) end
        end
    end
end

-- Runs the code that showed the dialog again, so the sheet adopts the dialog
-- it shows now (see interceptShow). A failure leaves the sheet as it is.
local function reshow(proxy)
    rebuilding = proxy
    local ok, err = pcall(proxy.choices.replay)
    rebuilding = nil
    if not ok then
        logger.warn("simpleui/native_sheets: sheet not refreshed:", tostring(err))
    end
end

-- Makes the choices that keep the sheet open apply their callback and then
-- show the dialog again. While the callback runs, the dialog's own request to
-- close is ignored (see interceptClose).
local function holdOpen(proxy, sections)
    eachItem(sections, function(item)
        local run = item.callback
        if not (item.keep_open and run) then return end
        item.callback = function(...)
            if item.checked and not item.clearable then return end
            proxy.holding = true
            local ok, err = pcall(run, ...)
            proxy.holding = false
            if not ok then error(err, 0) end
            reshow(proxy)
        end
    end)
end

-- Restores the choices of the enclosing call, then returns the results of the
-- protected call.
local function endChoices(previous, ok, ...)
    active_choices = previous
    if not ok then error((...), 0) end
    return ...
end

--- Runs `fn(...)` and returns its results. The dialog it shows as a sheet has
--- its buttons annotated by `resolve(label)`, which returns the choice of the
--- button with that label, or nil for a button without selection state.
function NativeSheets.withChoices(resolve, fn, ...)
    local previous = active_choices
    local args = { n = select("#", ...), ... }
    active_choices = {
        resolve = resolve,
        replay  = function() return fn(_unpack(args, 1, args.n)) end,
    }
    return endChoices(previous, pcall(fn, ...))
end

-- ---------------------------------------------------------------------------
-- Showing and closing
-- ---------------------------------------------------------------------------

-- Hooks a caller set on the dialog itself (not the ones of the class), which
-- UIManager would have run had the dialog been shown: `onShow` once the
-- sheet is up and `onCloseWidget` when it closes (after `tap_close_callback`
-- when it was dismissed, as ButtonDialog does).
local function runShowHook(widget)
    local on_show = rawget(widget, "onShow")
    if on_show then on_show(widget) end
end

local function runCloseHook(widget)
    local on_close = rawget(widget, "onCloseWidget")
    if on_close then on_close(widget) end
end

-- Title, message, icon and sections of the sheet that stands in for `widget`.
local function sheetContent(proxy, widget)
    local choices = proxy.choices
    local buttons = choices and annotate(widget.buttons, choices.resolve) or widget.buttons
    local title, message = splitTitle(widget.title)
    local sections = buildSections(buttons)
    holdOpen(proxy, sections)
    return { title = title, message = message, icon = widget.sui_icon, sections = sections }
end

local function present(widget)
    local proxy = { widget = widget, choices = active_choices }
    proxies[widget] = proxy

    local ok, err = pcall(function()
        local content = sheetContent(proxy, widget)
        content.name = SHEET_NAME
        -- Dismissed by the user (tap outside, Back key). A close requested
        -- through the dialog has already released the proxy.
        content.on_dismiss = function()
            local current = proxy.widget
            if proxies[current] ~= proxy then return end
            proxies[current] = nil
            if current.tap_close_callback then current.tap_close_callback() end
        end
        content.on_close = function()
            proxies[proxy.widget] = nil
            runCloseHook(proxy.widget)
        end
        proxy.window = ActionSheet.show(content)
    end)
    if not ok then
        proxies[widget] = nil
        error(err, 0)
    end
    runShowHook(widget)
end

-- Makes the sheet of `proxy` stand in for `widget`, the dialog that replaces
-- the one it stood for, and redraws it with the content of the new dialog.
local function adopt(proxy, widget)
    if not hasPlainButtons(widget.buttons) then return end
    proxies[proxy.widget] = nil
    proxy.widget = widget
    proxies[widget] = proxy
    proxy.window:update(sheetContent(proxy, widget))
end

--- Show step: replaces an eligible button dialog with a sheet. Returns true
--- when the dialog was consumed. While a sheet is being refreshed (see
--- reshow), the dialog shown is the one its sheet adopts.
function NativeSheets.interceptShow(widget)
    if widget == nil or getmetatable(widget) ~= ButtonDialog then return false end
    if rebuilding then
        adopt(rebuilding, widget)
        return true
    end
    if not isEligible(widget) then return false end

    local ok, err = pcall(present, widget)
    if ok then return true end
    logger.warn("simpleui/native_sheets: sheet failed, showing the dialog:", tostring(err))
    return false
end

--- Close step: closing a dialog that a sheet stands in for closes the sheet,
--- except while one of its choices is being applied.
function NativeSheets.interceptClose(widget)
    local proxy = proxies[widget]
    if not proxy then return false end
    if proxy.holding then return true end
    proxies[widget] = nil
    if proxy.window then proxy.window:close() end
    return true
end

return NativeSheets
