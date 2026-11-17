-- screens/sui_homescreen.lua — built-in Homescreen identity and public API.
--
-- Rendering is generic in engines/sui_screen_engine.lua, which has no
-- opinion about "the built-in screen" — every screen (built-in or Custom)
-- supplies its own instance_cfg (id, pfx, layout_key, optional hooks) to the
-- engine's ScreenEngine._open(). This file is that supplier for the built-in
-- Homescreen (id "hs"); infra/sui_custom_screens.lua plays the same role
-- for Custom Screens.
--
-- IMPORTANT: mutates the SAME table returned by
-- require("engines/sui_screen_engine") instead of wrapping it in a new one.
-- main.lua, sui_patches.lua and several modules/*.lua read/write
-- ScreenEngine._instance, ._cached_books_state, etc. directly on this table,
-- and those fields double as the engine's flat legacy state store for
-- id == "hs" — returning a different table here would break that identity.
local UIManager = require("ui/uimanager")
local ScreenEngine = require("engines/sui_screen_engine")
local SUISettings = require("infra/sui_store")

-- The built-in Homescreen's instance_cfg. Nothing else should build one of
-- these — Custom Screens get their own from infra/sui_custom_screens.lua.
local BUILTIN_INSTANCE_CFG = {
    id         = "hs",
    pfx        = "simpleui_hs_",
    layout_key = "simpleui_layout",

    -- Only the built-in Homescreen has first-run onboarding (a Custom
    -- Screen has nothing to "onboard" into). Runs once, right after the
    -- built-in Homescreen is first shown.
    on_after_open = function()
        local logger = require("logger")
        logger.info("simpleui[diag]: on_after_open onboarding_done=", SUISettings:get("simpleui_onboarding_done"))
        if SUISettings:get("simpleui_onboarding_done") then return end
        local ok, Onboarding = pcall(require, "screens/sui_onboarding")
        logger.info("simpleui[diag]: onboarding require ok=", ok, ok and "" or tostring(Onboarding))
        if ok and Onboarding then
            Onboarding.show(function()
                ScreenEngine.rebuildLayout()
            end)
        else
            SUISettings:set("simpleui_onboarding_done", true)
        end
    end,
}

function ScreenEngine.show(on_qa_tap, on_goal_tap)
    return ScreenEngine._open(BUILTIN_INSTANCE_CFG, on_qa_tap, on_goal_tap)
end

function ScreenEngine.close()
    ScreenEngine.closeScreen("hs")
end

-- Rebuilds the open Homescreen at once, re-prefetching book data so modules
-- just enabled do not render empty, then repaints it on the next tick: a
-- setDirty while a menu or dialog is open is painted behind it, and its close
-- only repaints its own region.
function ScreenEngine.refreshNow()
    local hs = ScreenEngine._instance
    if not hs then return end
    hs:_refreshImmediate(false)
    UIManager:nextTick(function()
        if ScreenEngine._instance == hs and hs._navbar_container then
            UIManager:setDirty(hs, "ui")
        end
    end)
end

-- Rebuilds every live screen (built-in + any Custom Screen open in the
-- background), not just "hs" — every caller (sui_wallpaper, sui_style,
-- sui_onboarding, sui_menu, sui_settings_window) applies something visually
-- global to the app: wallpaper, bar transparency, style. Pass
-- `{ keep_wallpaper = true }` when the wallpaper image itself is unchanged.
function ScreenEngine.rebuildLayout(opts)
    ScreenEngine.rebuildAllLayouts(opts)
end

return ScreenEngine
