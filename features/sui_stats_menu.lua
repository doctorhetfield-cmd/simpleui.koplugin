-- sui_stats_menu.lua — Simple UI
-- Settings entries for everything statistics-related that is global, i.e. not
-- tied to a single module instance: the statistics windows, streak mode,
-- reading goals and the statistics data options.
--
-- The menu is built once and consumed by every settings UI through
-- plugin.makeStatsMenuItems. Streak mode and the stats refresh are exposed as
-- single definitions (makeStreakModeItem, updateNow) so module menus can offer
-- shortcuts to them without redefining them.
--
-- Public API:
--   StatsMenu.makeMenuItems(opts)       opts.refresh: repaints the Home Screen
--                                       opts.open_window(id): opens a statistics
--                                       window; defaults to the launcher
--   StatsMenu.makeStreakModeItem(refresh)
--   StatsMenu.updateNow(refresh)

local Config       = require("infra/sui_config")
local Goals        = require("infra/sui_goals")
local Launcher     = require("screens/sui_stats_launcher")
local ManualBooks  = require("features/sui_manual_books")
local StreakFreeze = require("infra/sui_streak")
local SUISettings  = require("infra/sui_store")
local UI           = require("infra/sui_core")
local _            = require("infra/sui_i18n").translate

local StatsMenu = {}

-- Modules whose caches hold data derived from the book files.
local CACHE_MODULES = {
    "modules/module_currently",
    "modules/module_coverdeck",
}

local function _defaultOpenWindow(id)
    require("screens/sui_stats_launcher").open(id)
end

--- Rescans the finished books and drops every cache derived from them.
function StatsMenu.updateNow(refresh)
    local SP = package.loaded["modules/module_stats_provider"]
    if SP and SP.rescanBooks then SP.rescanBooks() end

    local SH = package.loaded["modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then SH.invalidateSidecarCache() end

    for _i, name in ipairs(CACHE_MODULES) do
        local mod = package.loaded[name]
        if mod and mod.invalidateCache then mod.invalidateCache() end
    end

    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if ScreenEngine and ScreenEngine.invalidateAllCfgAndRefresh then
        ScreenEngine.invalidateAllCfgAndRefresh(true)
    end
    if refresh then refresh() end
    UI.Notify.toast(_("Stats updated successfully."), 2)
end

function StatsMenu.makeStreakModeItem(refresh)
    return Config.makeRadioSubmenuItem{
        text    = _("Streak Mode"),
        options = {
            { value = "freezes", label = _("Freezes") },
            { value = "real",    label = _("Real streak only") },
        },
        get     = StreakFreeze.getStreakMode,
        set     = StreakFreeze.setStreakMode,
        refresh = refresh,
    }
end

-- Toggle bound to a boolean setting that defaults to on.
local function _nilOrTrueToggle(text, help_text, key, on_change)
    return {
        text           = text,
        help_text      = help_text,
        checked_func   = function() return SUISettings:nilOrTrue(key) end,
        keep_menu_open = true,
        callback       = function()
            SUISettings:saveSetting(key, not SUISettings:nilOrTrue(key))
            if on_change then on_change() end
        end,
    }
end

local function _preserveDeletedItem(refresh)
    return _nilOrTrueToggle(
        _("Preserve Deleted Books in Statistics"),
        _("When a finished book is deleted from the device (file or folder), keep it counted in the Books Read statistics on the Home Screen.\n\nBooks changed back to Reading or Abandoned are automatically removed from this list."),
        "simpleui_preserve_deleted_books_in_stats",
        function()
            local SP = package.loaded["modules/module_stats_provider"]
            if SP and SP.invalidateBooks then pcall(SP.invalidateBooks) end
            if refresh then refresh() end
        end)
end

local function _manualInAllTimeItem(refresh)
    local FinishedBooks = SUISettings.FinishedBooks
    return {
        text           = _("Include Manual Books in All Time Total"),
        help_text      = _("Count manually tracked books in the all-time total of books finished. They always count towards the year they belong to."),
        checked_func   = FinishedBooks.manualInAllTime,
        keep_menu_open = true,
        callback       = function()
            FinishedBooks.setManualInAllTime(not FinishedBooks.manualInAllTime())
            local SP = package.loaded["modules/module_stats_provider"]
            if SP and SP.invalidateBooks then pcall(SP.invalidateBooks) end
            if refresh then refresh() end
        end,
    }
end

local function _loadingNoticeItem()
    return _nilOrTrueToggle(
        _("Statistics Loading Notice"),
        _("Show a brief \"Loading statistics…\" notice when opening a statistics window, preventing accidental double-taps while e-ink refreshes."),
        Launcher.LOADING_NOTICE_KEY)
end

function StatsMenu.makeMenuItems(opts)
    opts = opts or {}
    local refresh     = opts.refresh
    local open_window = opts.open_window or _defaultOpenWindow
    local manual_in_all_time = _manualInAllTimeItem(refresh)
    manual_in_all_time.separator = true
    local function windowItem(text, id, separator)
        return { text = text, separator = separator, callback = function() open_window(id) end }
    end
    return {
        windowItem(_("Reading Insights"), "insights"),
        windowItem(_("Finished Books"),   "finished_books"),
        windowItem(_("Streak"),           "streak"),
        windowItem(_("Reading Heatmap"),  "heatmap", true),
        StatsMenu.makeStreakModeItem(refresh),
        {
            text           = _("Reading Goals"),
            sub_item_table_func = function() return Goals.makeMenuItems() end,
        },
        ManualBooks.makeMenuItem(refresh),
        manual_in_all_time,
        _preserveDeletedItem(refresh),
        _loadingNoticeItem(),
        {
            text           = _("Update Stats Now"),
            keep_menu_open = true,
            callback       = function() StatsMenu.updateNow(refresh) end,
        },
    }
end

return StatsMenu
