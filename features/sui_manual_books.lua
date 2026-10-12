-- sui_manual_books.lua — Simple UI
-- Dialogs and settings entry for the books the user enters by hand.
--
-- A manual book lives in the finished-books ledger (see infra/sui_store) and
-- is counted by the stats provider like any other finished book. This module
-- only collects the input and hands it to the provider.
--
-- Books are entered in one of two ways:
--   • one book with its details: title, author, start and finish stamps
--     ("YYYY-MM-DD" or "YYYY"; at least one of the two);
--   • a plain number of books for a year.
--
-- Public API:
--   ManualBooks.showBookDialog(book, on_done)    add a book (`book` nil) or edit
--                                                one (`book` is a provider entry)
--   ManualBooks.showCountDialog(year, on_done)   number of books for `year`
--   ManualBooks.showYearCountDialog(on_done)     asks the year, then the number
--   ManualBooks.showMenuDialog(refresh)          small dialog offering the two ways above
--   ManualBooks.makeMenuItem(refresh)            settings entry opening that dialog;
--                                                shows the number of tracked books

local UIManager = require("ui/uimanager")
local UI        = require("infra/sui_core")
local _         = require("infra/sui_i18n").translate
local N_        = require("infra/sui_i18n").ngettext
local Screen    = require("device").screen

local MIN_YEAR     = 1900
local MAX_COUNT    = 999
local DIALOG_MIN_W = 240   -- unscaled px; keeps side room around the button text

local ManualBooks = {}

local function _provider()
    return require("modules/module_stats_provider")
end

local function _blankToNil(text)
    text = require("util").trim(text or "")
    return text ~= "" and text or nil
end

-- Turns the form fields {title, author, started, finished} into book fields.
-- Returns nil and the message to show when the input is not acceptable.
local function _readForm(fields)
    local title    = _blankToNil(fields[1])
    local started  = _blankToNil(fields[3])
    local finished = _blankToNil(fields[4])
    local parse    = _provider().parseStamp

    if not title then
        return nil, _("Please enter a title.")
    end
    if (started and not parse(started)) or (finished and not parse(finished)) then
        return nil, _("Please enter dates as YYYY-MM-DD or YYYY.")
    end
    if not (started or finished) then
        return nil, _("Please enter a start or finish date.")
    end
    if started and finished then
        -- Compared at the precision of the shorter stamp.
        local len = math.min(#started, #finished)
        if started:sub(1, len) > finished:sub(1, len) then
            return nil, _("The start date is after the finish date.")
        end
    end
    return {
        title    = title,
        authors  = _blankToNil(fields[2]),
        started  = started,
        finished = finished,
    }
end

function ManualBooks.showBookDialog(book, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog

    local function finish(apply)
        UIManager:close(dialog)
        apply()
        if on_done then on_done() end
    end

    local buttons = {
        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
        {
            text             = _("Save"),
            is_enter_default = true,
            callback         = function()
                local values, err = _readForm(dialog:getFields())
                if not values then
                    UI.Notify.toast(err)
                    return
                end
                finish(function() _provider().saveManualBook(book and book.key, values) end)
            end,
        },
    }
    if book then
        table.insert(buttons, 1, {
            text     = _("Delete"),
            callback = function()
                UIManager:show(require("ui/widget/confirmbox"):new{
                    text        = _("Delete this book?"),
                    ok_text     = _("Delete"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        finish(function() _provider().removeManualBook(book.key) end)
                    end,
                })
            end,
        })
    end

    local date_hint = _("YYYY-MM-DD or YYYY")
    local current   = book or {}
    dialog = MultiInputDialog:new{
        title   = book and _("Edit Book") or _("Add Book"),
        fields  = {
            { description = _("Title"),    text = current.title },
            { description = _("Author"),   text = current.authors },
            { description = _("Started"),  text = current.date_started,  hint = date_hint },
            { description = _("Finished"), text = current.date_finished, hint = date_hint },
        },
        buttons = { buttons },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ManualBooks.showCountDialog(year, on_done)
    local SP = _provider()
    UIManager:show(require("ui/widget/spinwidget"):new{
        title_text  = string.format(_("Manual Yearly Count — %d"), year),
        info_text   = string.format(_("Extra books read in %d, on top of the automatic count:"), year),
        value       = SP.getManualCount(year),
        value_min   = 0,
        value_max   = MAX_COUNT,
        ok_text     = _("Save"),
        cancel_text = _("Cancel"),
        callback    = function(spin)
            SP.setManualCount(year, math.floor(spin.value))
            if on_done then on_done() end
        end,
    })
end

function ManualBooks.showYearCountDialog(on_done)
    local this_year = tonumber(os.date("%Y"))
    UIManager:show(require("ui/widget/spinwidget"):new{
        title_text  = _("Manual Yearly Count"),
        info_text   = _("Year:"),
        value       = this_year,
        value_min   = MIN_YEAR,
        value_max   = this_year,
        ok_text     = _("Next"),
        cancel_text = _("Cancel"),
        -- The year dialog opens on the current year, which is a valid choice.
        ok_always_enabled = true,
        callback    = function(spin)
            ManualBooks.showCountDialog(math.floor(spin.value), on_done)
        end,
    })
end

-- Right-side value of the settings entry: how many books are tracked by hand.
local function _countLabel()
    local count = _provider().getManualBookCount()
    return string.format(N_("%d book", "%d books", count), count)
end

-- Small untitled chooser between the two ways of entering books.
function ManualBooks.showMenuDialog(refresh)
    local dialog
    local function close_then(action)
        return function()
            UIManager:close(dialog)
            action(refresh)
        end
    end
    dialog = require("ui/widget/buttondialog"):new{
        title                 = _("Add Book"),
        title_align           = "center",
        shrink_unneeded_width = true,
        shrink_min_width      = Screen:scaleBySize(DIALOG_MIN_W),
        buttons = {
            {{ text = _("Single Book"),
               callback = close_then(function(done) ManualBooks.showBookDialog(nil, done) end) }},
            {{ text = _("Manual Yearly Count"),
               callback = close_then(ManualBooks.showYearCountDialog) }},
        },
    }
    UIManager:show(dialog)
end

function ManualBooks.makeMenuItem(refresh)
    return {
        text           = _("Manually Tracked Books"),
        value_func     = _countLabel,
        mandatory_func = _countLabel,
        keep_menu_open = true,
        callback       = function() ManualBooks.showMenuDialog(refresh) end,
    }
end

return ManualBooks
