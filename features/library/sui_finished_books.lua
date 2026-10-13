-- sui_finished_books.lua — Simple UI
-- How finished books are presented in the library: shown as they are,
-- faded or hidden. One persisted mode drives every library view, so the
-- file browser and the home screen grids agree on what "hidden" means.
--
-- In the file browser the mode is applied by a single gate on
-- FileChooser:show_file, the check that every listing, virtual folder,
-- book count and folder cover already goes through. Fading is applied by
-- the cover renderer, which reads isFaded().
--
-- Public API
-- ----------
--   Finished.MODE                     -- { SHOW, FADE, HIDE } mode ids
--   Finished.getMode() / Finished.setMode(mode)
--   Finished.isFaded() / Finished.isHidden()
--   Finished.appendRadioItems(items, refresh)
--       -- appends one radio entry per mode to `items`
--   Finished.makeSubmenuItem(refresh)
--       -- a "Finished Books" row showing the mode and opening the entries
--   Finished.install() / Finished.uninstall()
--       -- the file browser gate

local BookList    = require("ui/widget/booklist")
local Config      = require("infra/sui_config")
local FileChooser = require("ui/widget/filechooser")
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local Finished = {}

Finished.MODE = { SHOW = "show", FADE = "fade", HIDE = "hide" }
local MODE = Finished.MODE

local MODE_KEY     = "simpleui_fc_finished_mode"
local MODE_ORDER   = { MODE.SHOW, MODE.FADE, MODE.HIDE }
local DEFAULT_MODE = MODE.FADE

-- ---------------------------------------------------------------------------
-- Mode
-- ---------------------------------------------------------------------------

function Finished.getMode()
    return Config.readChoice(MODE_KEY, MODE_ORDER, DEFAULT_MODE)
end

function Finished.setMode(mode)
    SUISettings:saveSetting(MODE_KEY, Config.resolveChoice(mode, MODE_ORDER, DEFAULT_MODE))
end

function Finished.isFaded()  return Finished.getMode() == MODE.FADE end
function Finished.isHidden() return Finished.getMode() == MODE.HIDE end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local function buildOptions()
    return {
        { value = MODE.SHOW, label = _("Show") },
        {
            value     = MODE.FADE,
            label     = _("Fade"),
            help_text = _("Fades finished book covers in the file browser. Other lists show them as usual."),
        },
        { value = MODE.HIDE, label = _("Hide") },
    }
end

local function choiceSpec(refresh)
    return {
        options = buildOptions(),
        get     = Finished.getMode,
        set     = Finished.setMode,
        refresh = refresh,
    }
end

function Finished.appendRadioItems(items, refresh)
    return Config.appendRadioItems(items, choiceSpec(refresh))
end

function Finished.makeSubmenuItem(refresh)
    local spec = choiceSpec(refresh)
    spec.text = _("Finished Books")
    return Config.makeRadioSubmenuItem(spec)
end

-- ---------------------------------------------------------------------------
-- File browser gate
-- ---------------------------------------------------------------------------

local _orig_show_file = nil

-- Leaves finished books out of the file manager's listings while the mode is
-- "hide". Like the built-in status filter, it only applies when the full
-- path of the file is known.
function Finished.install()
    if _orig_show_file then return end
    _orig_show_file = FileChooser.show_file

    FileChooser.show_file = function(fc, filename, fullpath)
        if not _orig_show_file(fc, filename, fullpath) then return false end
        if fullpath == nil or fc.name ~= "filemanager" or not Finished.isHidden() then
            return true
        end
        return BookList.getBookStatus(fullpath) ~= "complete"
    end
end

function Finished.uninstall()
    if not _orig_show_file then return end
    FileChooser.show_file = _orig_show_file
    _orig_show_file = nil
end

return Finished
