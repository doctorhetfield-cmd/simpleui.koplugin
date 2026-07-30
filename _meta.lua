local _ = require("sui_i18n").translate

-- `name` must stay "simpleui": main.lua, sui_menu.lua and sui_updater.lua all
-- hard-filter on meta.name == "simpleui" before trusting this table. Renaming
-- it breaks hot-update detection, blanks the About page, and pins
-- _currentVersion() at "0.0.0" so the update banner can never be dismissed.
-- The fork cannot be installed alongside upstream Simple UI anyway - both
-- claim the same sui_* module names in package.loaded - so a distinct plugin
-- id would buy nothing.
--
-- Fork releases take a fourth version component. Do not use a "-bf1" style
-- suffix: sui_updater's version parser stops at the first "-", so "2.1.1-bf1"
-- compares equal to "2.1.1" and the update is never offered.
return {
    name        = "simpleui",
    fullname    = _("Simple UI | BookFusion"),
    description = _([[A simple UI for KOReader]]),
    version     = "2.1.1.1",
    author      = "Doctor Hetfield",
}
