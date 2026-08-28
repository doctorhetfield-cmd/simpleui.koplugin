-- modules/sui_rakuyomi.lua — Simple UI × Rakuyomi integration glue.
--
-- One entry point, M.install(plugin), called once from main.lua:init().
-- It wires four otherwise-independent pieces, each pcall-guarded so a
-- missing/renamed dependency degrades to "does nothing" rather than
-- breaking the plugin:
--
--   1. Registers modules/module_rakuyomi_row (the home-screen cover row)
--      as an external module via moduleregistry's public register() API —
--      no edit to the built-in MODULES list.
--
--   2. Registers Bar Injection descriptors so the Simple UI navbar stays
--      visible on the `vnds` plugin's library screen and on Rakuyomi's
--      LibraryView (both matched by widget name). Each descriptor also
--      supplies get_active_action so the bottom bar lights up whichever tab
--      launches that plugin. Passive: zero effect unless the plugin is
--      installed and its screen actually carries the tag. Rakuyomi's
--      LibraryView is a heavily customised MenuCustom widget the injection
--      pipeline may fail to wrap — sui_patches.lua's show wrapper now shows
--      the widget unadorned in that case rather than losing it, so the
--      worst case is "no bar on that screen", never a blank screen.
--
--   3. Wraps SH.prefetchBooks so Rakuyomi's downloaded chapter files
--      (stored under `<koreader>/rakuyomi/…/<chapter>.cbz`, which land in
--      ReadHistory like any book) never appear in Currently Reading /
--      Recent Books. Done by hiding those entries from ReadHistory.hist for
--      the duration of the prefetch call only — no edit to
--      module_books_shared.lua, and the "current slot falls through to the
--      next real book" behaviour comes for free from the unmodified
--      prefetch logic.
--
--   4. A few seconds after boot (off the first-paint path), warms up
--      Rakuyomi's HTTP backend so the row from (1) can populate without the
--      user opening Rakuyomi once per session. Rakuyomi starts that backend
--      lazily on first opening its library view; Backend.initialize()'s
--      health-check wait blocks for seconds (minutes on slow devices), so
--      this is deliberately deferred and gated on the row being enabled.
--
-- Everything Rakuyomi-side (require("Backend") / require("Platform") /
-- require("LibraryView")) is coupled to the tachibana-shin/rakuyomi fork's
-- current internal layout and may break on a future Rakuyomi update — hence
-- the shape checks before every use.

local UIManager = require("ui/uimanager")
local UI        = require("infra/sui_core")

local ROW_ID     = "rakuyomi_row"
local ROW_MODULE = "modules/module_rakuyomi_row"

local M = {}
local _installed = false

-- ---------------------------------------------------------------------------
-- 1. Home-screen row
-- ---------------------------------------------------------------------------
local function _registerRow()
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not (ok and Registry and type(Registry.register) == "function") then return end
    Registry.register(ROW_MODULE)
end

-- ---------------------------------------------------------------------------
-- 2. Bar Injection descriptors — keep the navbar on vnds / Rakuyomi screens
-- ---------------------------------------------------------------------------

-- Find the bottom-bar tab (a custom Quick Action) that launches the plugin
-- named by `needle`, so the injected screen can highlight the matching icon.
-- Returns the tab id, or nil when the user has no such launcher in the bar
-- (nothing to highlight — correct, not an error).
local function _tabIdForPlugin(needle)
    local ok, Config = pcall(require, "infra/sui_config")
    if not (ok and Config and type(Config.loadTabConfig) == "function"
                and type(Config.getCustomQAConfig) == "function") then
        return nil
    end
    local ok_t, tabs = pcall(Config.loadTabConfig)
    if not (ok_t and type(tabs) == "table") then return nil end
    needle = needle:lower()
    for _, id in ipairs(tabs) do
        if type(id) == "string" and id:match("^custom_qa_%d+$") then
            local ok_c, cfg = pcall(Config.getCustomQAConfig, id)
            if ok_c and type(cfg) == "table" then
                local hay = ((cfg.plugin_key or "") .. " " ..
                             (cfg.dispatcher_action or "")):lower()
                if hay:find(needle, 1, true) then return id end
            end
        end
    end
    return nil
end

local function _registerBarInjection()
    if not (UI and UI.BarInjection and type(UI.BarInjection.register) == "function") then return end
    -- is_pageable left unset on both: falls back to the same page_num
    -- auto-detection used for the native Collections/History cases (both
    -- screens are paginated Menu widgets).
    UI.BarInjection.register{
        id                = "vnds_library",
        widget_name       = "vnds_library",
        get_active_action = function() return _tabIdForPlugin("vnds") end,
    }
    UI.BarInjection.register{
        id                = "rakuyomi_library_view",
        widget_name       = "library_view",   -- Rakuyomi's MenuCustom:extend{ name = "library_view" }
        get_active_action = function() return _tabIdForPlugin("rakuyomi") end,
    }
end

-- ---------------------------------------------------------------------------
-- 3. Keep Rakuyomi chapters out of Currently Reading / Recent Books
-- ---------------------------------------------------------------------------
local function _isRakuyomiPath(fp)
    return type(fp) == "string" and fp:lower():find("/rakuyomi/", 1, true) ~= nil
end

local function _installHistoryFilter()
    local ok, SH = pcall(require, "modules/module_books_shared")
    if not (ok and SH and type(SH.prefetchBooks) == "function") then return end
    if SH._sui_rakuyomi_wrapped then return end   -- idempotent across hot-reload
    SH._sui_rakuyomi_wrapped = true

    local orig = SH.prefetchBooks
    SH.prefetchBooks = function(...)
        local ReadHistory = package.loaded["readhistory"] or require("readhistory")
        local hist = ReadHistory and ReadHistory.hist
        if type(hist) ~= "table" or #hist == 0 then
            return orig(...)   -- nothing to filter (also skips the reload path)
        end

        local filtered, dropped = {}, false
        for i = 1, #hist do
            local e = hist[i]
            if e and _isRakuyomiPath(e.file) then
                dropped = true
            else
                filtered[#filtered + 1] = e
            end
        end
        if not dropped then
            return orig(...)   -- no manga chapters in history — fast path
        end

        ReadHistory.hist = filtered
        local ok_call, state = pcall(orig, ...)
        ReadHistory.hist = hist   -- always restore, even on error
        if ok_call then return state end
        return orig(...)          -- prefetch errored with the swap in place; retry clean
    end
end

-- ---------------------------------------------------------------------------
-- 4. Backend warm-up
-- ---------------------------------------------------------------------------
local function _rowEnabledAnywhere()
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not (ok and Registry and type(Registry.get) == "function") then return false end
    local mod = Registry.get(ROW_ID)
    if not mod then return false end
    if Registry.isEnabled(mod, "simpleui_hs_") then return true end
    local ok_cs, CS = pcall(require, "infra/sui_custom_screens")
    if ok_cs and CS and type(CS.list) == "function" then
        local ok_l, screens = pcall(CS.list)
        if ok_l and type(screens) == "table" then
            for _, s in ipairs(screens) do
                if s and s.pfx and Registry.isEnabled(mod, s.pfx) then return true end
            end
        end
    end
    return false
end

-- Repaint every screen that could be hosting the row, once the backend is
-- confirmed serving. Mirrors the cache-invalidation pattern used elsewhere
-- (see modules/module_coverdeck.lua).
local function _refreshScreens()
    local ok_m, RowMod = pcall(require, ROW_MODULE)
    if ok_m and RowMod and type(RowMod.reset) == "function" then
        pcall(RowMod.reset)
    end
    local ok, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if not (ok and ScreenEngine and type(ScreenEngine.knownScreenIds) == "function") then return end
    for _, sid in ipairs(ScreenEngine.knownScreenIds()) do
        pcall(ScreenEngine.setCachedBooksState, sid, nil)
        pcall(ScreenEngine.setCfgCache, sid, nil)
        pcall(ScreenEngine.refreshScreen, sid, false)
    end
end

local function _warmup()
    if not _rowEnabledAnywhere() then return end

    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if not (ok_pl and PluginLoader) then return end
    local ok_inst, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "rakuyomi")
    if not (ok_inst and inst) then return end

    local ok_b, Backend = pcall(require, "Backend")
    if not (ok_b and type(Backend) == "table"
                and type(Backend.getBackend)     == "function"
                and type(Backend.getInitialized) == "function"
                and type(Backend.requestJson)    == "function") then
        return
    end

    -- Spawn the backend process now (Platform:startServer() returns
    -- immediately) so that when getBackend() runs below, Backend.running()
    -- is already true and its blocking health-check wait is skipped. If the
    -- fork names Platform differently, getBackend() still works — it just
    -- pays the blocking wait once, here, instead of on first paint.
    if not Backend.getInitialized()
            and type(Backend.running) == "function" and not Backend.running() then
        local ok_plat, Platform = pcall(require, "Platform")
        if ok_plat and type(Platform) == "table"
                and type(Platform.startServer) == "function" then
            pcall(function() Backend.server = Platform:startServer() end)
        end
    end

    -- getBackend() flips backendInitialized once initialize() succeeds; then
    -- probe /library (exactly what the row calls) to confirm the server
    -- actually answers before repainting. Retry a few times with a short
    -- gap rather than busy-waiting.
    local function step(attempt)
        pcall(Backend.getBackend)
        local served = false
        if Backend.getInitialized() then
            local ok_req, resp = pcall(Backend.requestJson, { path = "/library", timeout = 2 })
            served = ok_req and type(resp) == "table" and resp.type == "SUCCESS"
        end
        if served then
            _refreshScreens()
        elseif attempt < 8 then
            UIManager:scheduleIn(2, function() step(attempt + 1) end)
        end
    end
    step(1)
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------
function M.install(_plugin)
    if _installed then return end
    _installed = true
    pcall(_registerRow)
    pcall(_registerBarInjection)
    pcall(_installHistoryFilter)
    -- scheduleIn(5) trails the module preload (2) and update check (3) in
    -- main.lua:init(); well after the FileManager UI is painted and stable.
    UIManager:scheduleIn(5, function() pcall(_warmup) end)
end

return M
