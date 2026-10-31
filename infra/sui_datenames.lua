-- sui_datenames.lua — Simple UI
-- Localised calendar names: months and weekdays, in short and full form, and
-- the parts of the day.
--
-- Each list is built on first use, so _() runs after the user's locale is
-- applied, and is reused afterwards. Indices follow os.date("*t"): months
-- 1..12 from January, weekdays 1..7 from Sunday.
--
-- Public API:
--   DateNames.monthShort()     { "Jan", "Feb", ... }
--   DateNames.monthFull()      { "January", "February", ... }
--   DateNames.weekdayShort()   { "Sun", "Mon", ... }
--   DateNames.weekdayFull()    { "Sunday", "Monday", ... }
--   DateNames.dayParts()       { "Morning", "Afternoon", "Evening", "Night" }

local _ = require("infra/sui_i18n").translate

local DateNames = {}

-- Returns an accessor that calls `build` once and serves the cached list.
local function lazyList(build)
    local list
    return function()
        list = list or build()
        return list
    end
end

DateNames.monthShort = lazyList(function()
    return {
        _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
        _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec"),
    }
end)

-- First letter of each short month name.
DateNames.monthInitials = lazyList(function()
    local initials = {}
    for i, name in ipairs(DateNames.monthShort()) do initials[i] = require("util").splitToChars(name)[1] end
    return initials
end)

DateNames.monthFull = lazyList(function()
    return {
        _("January"), _("February"), _("March"),     _("April"),
        _("May"),     _("June"),     _("July"),      _("August"),
        _("September"), _("October"), _("November"), _("December"),
    }
end)

DateNames.weekdayShort = lazyList(function()
    return { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }
end)

DateNames.weekdayFull = lazyList(function()
    return {
        _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"),
        _("Thursday"), _("Friday"), _("Saturday"),
    }
end)

-- Same order as HD.PART_HOURS in engines/sui_heatmap_data.
DateNames.dayParts = lazyList(function()
    return { _("Morning"), _("Afternoon"), _("Evening"), _("Night") }
end)

return DateNames
