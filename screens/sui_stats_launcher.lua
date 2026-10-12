-- sui_stats_launcher.lua — Simple UI
-- Single entry point for every statistics window. Callers name a window by id
-- and never deal with module loading or the loading notice themselves.
--
-- The window modules are required on first use only, so a caller that merely
-- references the launcher does not pay for them.
--
-- Public API:
--   Launcher.open(id, opts)  id: "insights" | "streak" | "finished_books"
--                                | "book" | "heatmap"
--                            opts is forwarded to the window. Common field:
--                              on_back  function — adds a back button that
--                                       closes the window and calls it
--                            Window-specific fields: "book" takes filepath,
--                            "finished_books" initial_year, "insights"
--                            on_close.

local Launcher = {}

-- Window id -> StatsWindows function that builds and shows it.
local STATS_WINDOWS = {
    insights       = "showReadingInsightsWindow",
    streak         = "showStreakManagerWindow",
    finished_books = "showFinishedBooksDialog",
    book           = "showBookStatsFromFile",
}

function Launcher.open(id, opts)
    if id == "heatmap" then
        return require("screens/sui_heatmap_popup").show(opts)
    end
    local show_name = assert(STATS_WINDOWS[id], "unknown statistics window: " .. tostring(id))
    local StatsWindows = require("screens/sui_stats_windows")
    StatsWindows.showLoadingNotice()
    return StatsWindows[show_name](opts)
end

return Launcher
