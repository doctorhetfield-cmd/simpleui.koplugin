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
--                          Every window shows the loading notice while it
--                          opens, except "finished_books". The notice is
--                          flushed to the screen before any work starts and
--                          closed once the window is shown.
--   Launcher.LOADING_NOTICE_KEY  setting that turns the loading notice on or
--                                off (on by default)

local SUISettings = require("infra/sui_store")
local UI          = require("infra/sui_core")
local _           = require("infra/sui_i18n").translate

local Launcher = {}

Launcher.LOADING_NOTICE_KEY = "simpleui_stats_loading_notice"

-- Window id -> how to open it:
--   module   module that builds and shows the window
--   show     function of that module that does it
--   notice   false for windows that open without the loading notice
local STATS_WINDOWS = {
    insights       = { module = "screens/sui_stats_windows", show = "showReadingInsightsWindow" },
    streak         = { module = "screens/sui_stats_windows", show = "showStreakManagerWindow" },
    finished_books = { module = "screens/sui_stats_windows", show = "showFinishedBooksDialog", notice = false },
    book           = { module = "screens/sui_stats_windows", show = "showBookStatsFromFile" },
    heatmap        = { module = "screens/sui_heatmap_popup", show = "show" },
}

-- Shows the loading notice when the setting allows it. Returns the notice.
local function showLoadingNotice()
    if not SUISettings:nilOrTrue(Launcher.LOADING_NOTICE_KEY) then return nil end
    return UI.Notify.sticky(_("Loading statistics…"), { timeout = 0.0 })
end

function Launcher.open(id, opts)
    local window = assert(STATS_WINDOWS[id], "unknown statistics window: " .. tostring(id))
    local notice = window.notice ~= false and showLoadingNotice() or nil
    local result = require(window.module)[window.show](opts)
    UI.Notify.close(notice)
    return result
end

return Launcher
