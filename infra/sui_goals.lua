-- sui_goals.lua — Simple UI
-- Single source of truth for the reading goals: storage keys, defaults,
-- value ranges, edit dialogs and the settings menu entries.
--
-- Every goal is declared once in SPECS; getters, setters, dialogs, menu rows
-- and the persisted key list are all derived from that table.
--
-- Values are stored in the unit the consumers need (books, or seconds for
-- time goals) and edited in the unit shown to the user (books, hours,
-- minutes). Goals.get() returns the stored value; Goals.getUnits() and
-- Goals.setUnits() work in the edit unit.
--
-- Public API:
--   Goals.IDS                          ordered goal ids
--   Goals.KEYS                         ordered persisted settings keys
--   Goals.label(id)                    translated goal name
--   Goals.get(id)                      stored value (books or seconds)
--   Goals.getUnits(id)                 value in the edit unit
--   Goals.setUnits(id, units)          persists, then refreshes dependents
--   Goals.showDialog(id, on_confirm)   spin dialog bound to the goal
--   Goals.makeMenuItems()              one stepper row per goal

local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local Goals = {}

local function _year() return os.date("%Y") end

-- Fields:
--   key        persisted settings key
--   default    value when never set (stored unit)
--   max        upper bound in the edit unit
--   step       dialog step in the edit unit (default 1)
--   unit_secs  seconds per edit unit; absent for plain counts
--   unit       suffix shown after the value
--   label      menu row text
--   title/info dialog texts
local SPECS = {
    annual = {
        key     = "simpleui_reading_goal",
        default = 12,   -- one book a month
        max     = 365,
        label   = function() return _("Annual Goal") end,
        title   = function() return _("Annual Reading Goal") end,
        info    = function() return string.format(_("Books to read in %s:"), _year()) end,
    },
    monthly = {
        key       = "simpleui_monthly_reading_goal_secs",
        default   = 0,
        max       = 350,
        unit_secs = 3600,
        unit      = "h",
        label     = function() return _("Monthly Goal") end,
        title     = function() return _("Monthly Reading Goal") end,
        info      = function() return _("Hours per month:") end,
    },
    daily = {
        key       = "simpleui_daily_reading_goal_secs",
        default   = 0,
        max       = 720,
        step      = 5,
        unit_secs = 60,
        unit      = " min",
        label     = function() return _("Daily Goal") end,
        title     = function() return _("Daily Reading Goal") end,
        info      = function() return _("Minutes per day:") end,
    },
}

Goals.IDS  = { "annual", "monthly", "daily" }
Goals.KEYS = {}
for _i, id in ipairs(Goals.IDS) do Goals.KEYS[#Goals.KEYS + 1] = SPECS[id].key end

local function _spec(id)
    return assert(SPECS[id], "unknown reading goal: " .. tostring(id))
end

-- Drops the cached statistics and repaints the Home Screen.
local function _notifyChanged()
    local SP = package.loaded["modules/module_stats_provider"]
    if SP then SP.invalidate() end
    local HS = package.loaded["screens/sui_homescreen"]
    if HS then HS.refresh(false) end
end

function Goals.label(id)
    return _spec(id).label()
end

function Goals.get(id)
    local spec = _spec(id)
    return tonumber(SUISettings:readSetting(spec.key)) or spec.default
end

function Goals.getUnits(id)
    return math.floor(Goals.get(id) / (_spec(id).unit_secs or 1))
end

function Goals.setUnits(id, units)
    local spec = _spec(id)
    SUISettings:saveSetting(spec.key, math.floor(units) * (spec.unit_secs or 1))
    _notifyChanged()
end

function Goals.showDialog(id, on_confirm)
    local spec       = _spec(id)
    local SpinWidget = require("ui/widget/spinwidget")
    require("ui/uimanager"):show(SpinWidget:new{
        title_text  = spec.title(),
        info_text   = spec.info(),
        value       = Goals.getUnits(id),
        value_min   = 0,
        value_max   = spec.max,
        value_step  = spec.step or 1,
        ok_text     = _("Save"),
        cancel_text = _("Cancel"),
        callback    = function(spin)
            Goals.setUnits(id, spin.value)
            if on_confirm then on_confirm() end
        end,
    })
end

--- One stepper row per goal, for the Stats settings menu.
function Goals.makeMenuItems()
    local Config = require("infra/sui_config")
    local items  = {}
    for _i, id in ipairs(Goals.IDS) do
        local spec = _spec(id)
        items[#items + 1] = Config.makeStepperItem{
            text_func   = spec.label,
            title       = spec.title(),
            info        = spec.info(),
            unit        = spec.unit,
            value_min   = 0,
            value_max   = spec.max,
            value_step  = spec.step,
            default_value = math.floor(spec.default / (spec.unit_secs or 1)),
            get         = function() return Goals.getUnits(id) end,
            set         = function(units) Goals.setUnits(id, units) end,
        }
    end
    return items
end

return Goals
