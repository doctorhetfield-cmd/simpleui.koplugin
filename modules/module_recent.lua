-- module_recent.lua — Simple UI
-- "Cover row" module for Recent Books, built on top of
-- GridRenderer.makeModule (engines/sui_book_grid.lua). Not instantiable.
--
-- Split from module_book_rows.lua (which held Recent Books + New Books + TBR
-- in a single file) — see moduleregistry.lua for the require_mod.

local _ = require("infra/sui_i18n").translate

local SUISettings  = require("infra/sui_store")
local GridRenderer = require("engines/sui_book_grid")
local SH           = require("modules/module_books_shared")

local recent_module = GridRenderer.makeModule{
    id          = "recent",
    name        = _("Recent Books"),
    label       = _("Recent Books"),
    default_on  = false,
    is_book_mod = true,   -- suppresses empty-state when active
    max_items   = 5,
    -- Lets the user pick 4 or 5 visible covers (see GridRenderer.makeModule's
    -- doc comment). ctx.recent_fps is prefetched with max_recent=15 (see
    -- sui_screen_engine.lua), well above either choice, so no change
    -- needed there.
    cols_choice = true,

    getFileList = function(ctx) return ctx.recent_fps end,

    -- Filters finished books (unless "Show finished books") and optionally
    -- the Currently Reading book (default ON via recent_exclude_currently).
    filterItem = function(fp, ctx)
        local pfx = ctx.pfx or ""
        local excl = SUISettings:readSetting(pfx .. "recent_exclude_currently")
        if excl == nil then excl = true end
        if excl and ctx.current_fp and fp == ctx.current_fp then
            return false
        end
        if SUISettings:readSetting(pfx .. "recent_show_finished") == true then return true end
        return not SH.isFinished(fp, ctx.prefetched)
    end,

    progress_style = { default = "bar_text" },

    -- Off by default (unchanged look for existing users) — see
    -- GridRenderer.applyBadges' doc comment. All three available for the
    -- user to turn on, same as Flat Library/Featured Collection.
    badges = { pages = "off", series = "off", new = "off" },

    extra_settings = {
        { key = "show_finished", label = _("Show finished books"), default = false },
    },

    -- Only listed when Currently Reading is enabled on this screen.
    extra_menu_items_after = function(ctx_menu)
        local pfx = ctx_menu.pfx or ""
        local Registry = require("modules/moduleregistry")
        local currently = Registry.get("currently")
        if not (currently and Registry.isEnabled(currently, pfx)) then
            return {}
        end
        local skey = pfx .. "recent_exclude_currently"
        local refresh = ctx_menu.refresh
        local _lc = ctx_menu._
        return {
            {
                text = _lc("Hide Currently Reading book"),
                checked_func = function()
                    local v = SUISettings:readSetting(skey)
                    if v == nil then return true end
                    return v == true
                end,
                keep_menu_open = true,
                callback = function()
                    local cur = SUISettings:readSetting(skey)
                    if cur == nil then cur = true end
                    SUISettings:saveSetting(skey, not cur)
                    refresh()
                end,
            },
        }
    end,

    reset = function() GridRenderer.reset() end,
}

return recent_module
