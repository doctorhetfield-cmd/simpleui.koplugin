-- sui_settings_window.lua — SimpleUI ▸ Settings Window
--
-- Central hub for all SimpleUI SUIWindows.
-- Uses SUIWindow components directly (SUI.ListRow, SUI.PageCard, etc.) —
-- no C. sub-namespace.
--
-- Architecture:
--   LayoutService  — data layer (load/save layout, module names)
--   buildScreens   — render layer (one function per screen)
--   SettingsWindow — entry point (:show)
--
-- Screen map (all keys registered in SUIWindow.screens):
--   __root__               — top-level settings menu
--   home_screen_settings   — Home Screen section (layout, "Extra Custom Screens",
--                             "Wallpaper" (nested_menu sub-item), presets, behaviour)
--   custom_screens          — Custom Screens list (reached via Home Screen ▸
--                              "Extra Custom Screens", not linked from __root__)
--   bars_settings           — Bars section
--   library_settings        — Library section
--   style_settings          — Style section (icons, fonts and appearance)
--   quick_actions_settings — Quick Actions section
--   about_settings         — About section
--   pages                  — Layout editor (page list)
--   page_edit              — Modules on a single page
--   module_picker          — Add-module picker
--   module_settings        — Per-module settings (MenuTable)
--   general_settings       — General/behaviour settings (MenuTable)
--   presets                — Presets (MenuTable)
--   nested_menu            — Generic sub-menu (params.items / params.title)
--   arrange                — Reorder screen (SUI.ArrangeList)
--
-- Title resolution uses screen_titles (declarative map) so that adding a
-- new screen requires only a single entry — no separate title function to edit.
--
-- ===========================================================================
-- UNIVERSAL NATIVE MENU INTEGRATION (SortWidget → SUI.ArrangeList)
-- ===========================================================================
-- Any menu generator that would normally show a SortWidget must check for
-- ctx_menu.show_arrange.  If present, call it instead of UIManager:show():
--
--   if ctx_menu and ctx_menu.show_arrange then
--       ctx_menu.show_arrange({
--           title     = _("Arrange Items"),
--           items     = sort_items,
--           on_change = function() end,
--           on_close  = function() end,
--       })
--   else
--       UIManager:show(SortWidget:new{ ... })
--   end
-- ===========================================================================

local Device      = require("device")
local Geom        = require("ui/geometry")
local UIManager   = require("ui/uimanager")
local UI         = require("infra/sui_core")
local _           = require("infra/sui_i18n").translate

local SUI         = require("engines/sui_window")
local SUIStyle    = require("features/sui_style")
local Registry    = require("modules/moduleregistry")
local SUISettings = require("infra/sui_store")

local SortWidget  = require("ui/widget/sortwidget")
local ButtonDialog = require("ui/widget/buttondialog")
local logger      = require("logger")

local SettingsWindow = {}

-- ===========================================================================
-- 1. Data Services
-- ===========================================================================

local LayoutService = {}

-- Normalize layout module entries to plain ids. Legacy { id, width } tables
-- (brief experimental schema) migrate width into Config bento settings and
-- collapse back to a string id so the layout stays a pure order list.
function LayoutService.entryId(entry)
    if type(entry) == "table" then return entry.id end
    return entry
end

local function _normalizeLayoutModules(layout, pfx)
    if type(layout) ~= "table" or type(layout.pages) ~= "table" then return layout end
    local Config = require("infra/sui_config")
    local changed = false
    for _, page in ipairs(layout.pages) do
        if type(page.modules) == "table" then
            local out = {}
            for _, entry in ipairs(page.modules) do
                if type(entry) == "table" and entry.id then
                    if type(entry.width) == "number" then
                        Config.setBentoWidth(entry.width, entry.id, pfx)
                    end
                    out[#out + 1] = entry.id
                    changed = true
                else
                    out[#out + 1] = entry
                end
            end
            page.modules = out
        end
    end
    if changed then
        -- Caller (load) persists via layout_key when appropriate.
    end
    return layout, changed
end


local _DEFAULT_PFX        = "simpleui_hs_"
local _DEFAULT_LAYOUT_KEY = "simpleui_layout"

function LayoutService.load(pfx, layout_key)
    pfx        = pfx or _DEFAULT_PFX
    layout_key = layout_key or _DEFAULT_LAYOUT_KEY

    local saved = SUISettings:readSetting(layout_key)
    if type(saved) == "table" and saved.pages then
        local _, changed = _normalizeLayoutModules(saved, pfx)
        if changed then SUISettings:saveSetting(layout_key, saved) end
        return saved
    end

    local order          = Registry.loadOrder(pfx)
    local pages          = {}
    local cur_page       = { id = 1, modules = {} }

    for _, mod_id in ipairs(order) do
        if mod_id == "__page_break__" then
            table.insert(pages, cur_page)
            cur_page = { id = #pages + 1, modules = {} }
        else
            local mod = Registry.get(mod_id)
            if mod and Registry.isEnabled(mod, pfx) then
                table.insert(cur_page.modules, mod_id)
            end
        end
    end

    table.insert(pages, cur_page)

    return { pages = pages }
end

function LayoutService.save(layout, pfx, layout_key, screen_id)
    pfx        = pfx or _DEFAULT_PFX
    layout_key = layout_key or _DEFAULT_LAYOUT_KEY
    screen_id  = screen_id or "hs"

    SUISettings:saveSetting(layout_key, layout)

    local flat_order = {}
    local active_set = {}

    for _, page in ipairs(layout.pages) do
        for _, entry in ipairs(page.modules) do
            local mod_id = LayoutService.entryId(entry)
            if mod_id then
                table.insert(flat_order, mod_id)
                active_set[mod_id] = true
            end
        end
    end

    for _, mod in ipairs(Registry.list()) do
        if not active_set[mod.id] then
            table.insert(flat_order, mod.id)
        end
    end

    SUISettings:saveSetting(pfx .. "module_order", flat_order)

    for _, mod in ipairs(Registry.list()) do
        local is_active = (active_set[mod.id] == true)
        if type(mod.setEnabled) == "function" then
            mod.setEnabled(pfx, is_active)
        elseif mod.enabled_key then
            SUISettings:saveSetting(pfx .. mod.enabled_key, is_active)
        end
    end

    -- Repaint whichever screen this layout belongs to, if it's currently
    -- open. The built-in Homescreen keeps going through the flat HS.refresh
    -- (unchanged codepath); any other screen_id uses the generic, id-aware
    -- refreshScreen — see engines/sui_screen_engine.lua.
    local HS = package.loaded["screens/sui_homescreen"]
    if HS then
        if screen_id == "hs" then
            if HS._instance then
                pcall(function() HS.refresh(false) end)
            end
        elseif HS.refreshScreen then
            pcall(function() HS.refreshScreen(screen_id, false) end)
        end
    end
end

function LayoutService.getModuleName(mod_id)
    local mod = Registry.get(mod_id)
    local mod_name = mod and mod.name or mod_id
    if type(mod_id) == "string" and mod_id:match("_row_") then
        -- Find position across all instanciable base keys.
        local inst_keys = {
            "simpleui_qa_row_instances",
            "simpleui_spacer_row_instances",
        }
        for _, key in ipairs(inst_keys) do
            local inst_ids = SUISettings:readSetting(key) or {}
            if #inst_ids > 1 then
                for idx, mid in ipairs(inst_ids) do
                    if mid == mod_id then
                        return mod_name .. " " .. idx
                    end
                end
            end
        end
    end
    return mod_name
end

-- ===========================================================================
-- 2. Screen Builders
-- ===========================================================================

local function buildScreens(st)

    -- saveAndRepaint: save layout then rebuild the current screen.
    local function saveAndRepaint(ctx)
        LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
        ctx.repaint()
    end

    -- Helper: returns the SimpleUI plugin instance.
    -- Checks FileManager first (normal path), then falls back to ReaderUI for
    -- when the settings window is opened from inside the reader and FM is not
    -- the active context (_simpleui_plugin is only set on FM.instance, but the
    -- plugin is always registered on ReaderUI as readerui.simpleui).
    local function getPlugin()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local plugin = FM and FM.instance and FM.instance._simpleui_plugin
        if not plugin then
            local RUI = package.loaded["apps/reader/readerui"]
            plugin = RUI and RUI.instance and RUI.instance.simpleui
        end
        if plugin and type(plugin.makeWallpaperMenuItems) ~= "function" then
            local fake = {}
            pcall(function() plugin:addToMainMenu(fake) end)
        end
        return plugin
    end

    -- makeCtxMenu: builds the standard ctx_menu passed to plugin menu generators.
    -- All screens that delegate to a plugin.makeFooMenuItems share this shape.
    local function makeCtxMenu(ctx)
        return {
            pfx          = st.pfx,
            pfx_qa       = st.pfx_qa,
            is_sui       = true,           -- signals that we are inside a SUIWindow
            refresh      = SUI.withRepaint(ctx),
            show_arrange      = function(params) ctx.push("arrange", params) end,
            show_row_page     = function(params) ctx.push("row_page", params) end,
            show_item_picker  = function(params) ctx.push("item_picker", params) end,
            UIManager    = UIManager,
            _            = _,
            N_           = require("infra/sui_i18n").ngettext,
            SortWidget   = SortWidget,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
        }
    end

    -- makeMenuTable: wraps a KOReader item list as SUI.MenuTable rows.
    local function makeMenuTable(ctx, items)
        return SUI.MenuTable{
            items          = items,
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay   or function() end,
            unlock_overlay = ctx.unlockOverlay or function() end,
            push_stack = function(id, params)
                if type(id) == "string" then
                    ctx.push(id, params)
                else
                    ctx.push("nested_menu", params)
                end
            end,
            on_close = function() end,
        }
    end

    -- buildPluginMenuScreen: generic builder for screens that delegate entirely
    -- to a plugin.makeFooMenuItems(ctx_menu) function.
    -- Eliminates the ~10-line boilerplate that was repeated for every bar/library/
    -- style/quick-actions/about screen.
    local function buildPluginMenuScreen(ctx, make_fn)
        if type(make_fn) ~= "function" then
            return { SUI.ListRow{ title = _("Settings not found."), inner_w = ctx.inner_w } }
        end
        local ctx_menu = makeCtxMenu(ctx)
        local ok, items = pcall(make_fn, ctx_menu)
        if not ok or not items then
            return { SUI.ListRow{ title = _("Settings not found."), inner_w = ctx.inner_w } }
        end
        return makeMenuTable(ctx, items)
    end

    -- ── 2.1. Root ────────────────────────────────────────────────────────────
    local function buildRoot(ctx)
        local iw = ctx.inner_w
        -- Any top-level visit resets the "currently being edited" screen
        -- context back to the built-in Homescreen. Bars/Library/Style/etc.
        -- are global settings, not per-screen — they must never inherit a
        -- pfx left over from a Custom Screen's layout editor.
        st.pfx        = "simpleui_hs_"
        st.pfx_qa     = "simpleui_hs_qa_"
        st.layout_key = "simpleui_layout"
        st.screen_id  = "hs"
        st.screen_name = nil
        return {
            SUI.ListRow{
                title        = _("Home Screen"),
                subtitle     = _("Layout, wallpaper, presets and behaviour"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("home_screen_settings") end,
            },
            SUI.ListRow{
                title        = _("Bars"),
                subtitle     = _("Status, title, navigation and pagination"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("bars_settings") end,
            },
            SUI.ListRow{
                title        = _("Library"),
                subtitle     = _("Book-browser settings"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("library_settings") end,
            },
            SUI.ListRow{
                title        = _("Style"),
                subtitle     = _("Icons, fonts and appearance"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("style_settings") end,
            },
            SUI.ListRow{
                title        = _("Quick Actions"),
                subtitle     = _("Global custom actions & icons"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function()
                    local ok, QA = pcall(require, "features/sui_quickactions")
                    if ok and QA and QA.sui_show_qa_list then
                        QA.sui_show_qa_list(getPlugin(), makeCtxMenu(ctx), ctx)
                    else
                        ctx.push("quick_actions_settings")
                    end
                end,
            },
            SUI.ListRow{
                title        = _("About"),
                subtitle     = _("Version, author and updates"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("about_settings") end,
            },
        }
    end

    -- ── 2.2. Home Screen ─────────────────────────────────────────────────────
    local function buildHomeScreenSettings(ctx)
        local iw = ctx.inner_w
        return {
            SUI.ListRow{
                title        = _("Edit Home Screen Layout"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function()
                    ctx.push("pages", {
                        pfx = "simpleui_hs_", pfx_qa = "simpleui_hs_qa_",
                        layout_key = "simpleui_layout", screen_id = "hs",
                    })
                end,
            },
            SUI.ListRow{
                title        = _("Extra Custom Screens"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("custom_screens") end,
            },
            SUI.ListRow{
                title        = _("Wallpaper"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function()
                    local plugin = getPlugin()
                    ctx.push("nested_menu", {
                        title      = _("Wallpaper"),
                        items_func = function()
                            if not (plugin and plugin.makeWallpaperMenuItems) then return {} end
                            local SUIWindow = require("engines/sui_window")
                            return plugin.makeWallpaperMenuItems(SUIWindow.makeCtxMenu(ctx))
                        end,
                    })
                end,
            },
            SUI.ListRow{
                title        = _("Presets"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("presets") end,
            },
            SUI.ListRow{
                title        = _("Behaviour"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("general_settings") end,
            },
        }
    end

    -- ── 2.2b. Custom Screens: list ───────────────────────────────────────────
    -- Rows follow the same convention as "Manage presets" (sui_presets.lua):
    -- on_edit/on_delete render rename/delete icons on the right, and tapping
    -- the row itself goes straight to the one thing left to do — edit the
    -- screen's layout (see buildPages below). This replaces the previous
    -- intermediate "custom_screen_detail" submenu (Edit Layout / Rename /
    -- Delete), which existed only because rename/delete had nowhere else to
    -- live before this icon convention was adopted here.
    local function buildCustomScreens(ctx)
        local iw = ctx.inner_w
        local ok, CustomScreens = pcall(require, "infra/sui_custom_screens")
        if not ok or not CustomScreens then
            return { SUI.ListRow{ title = _("Custom Screens unavailable."), inner_w = iw } }
        end

        local screens = CustomScreens.list()
        if #screens == 0 then
            return {
                SUI.ListRow{
                    title    = _("No custom screens yet."),
                    subtitle = _("Tap \"Create Screen\" below to add one."),
                    inner_w  = iw,
                },
            }
        end

        local items = {}
        for _idx, screen in ipairs(screens) do
            -- NOTE: the loop variable is deliberately NOT named "_" here.
            -- on_edit/on_delete below are closures that outlive this loop
            -- iteration and call _() (gettext, see the module-level
            -- `local _ = require("infra/sui_i18n").translate` at the top
            -- of this file) *after* the loop has finished. A generic-for
            -- loop variable named "_" would shadow that upvalue for the
            -- whole iteration body, so every closure created here would
            -- capture the shadowed (numeric) "_" instead of gettext,
            -- crashing with "attempt to call upvalue '_' (a number value)"
            -- the first time on_edit/on_delete actually runs.
            local _screen = screen
            table.insert(items, SUI.ListRow{
                title        = _screen.name,
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function()
                    ctx.push("pages", {
                        pfx        = _screen.pfx,
                        pfx_qa     = _screen.pfx .. "qa_",
                        layout_key = _screen.layout_key,
                        screen_id  = _screen.id,
                        name       = _screen.name,
                    })
                end,
                on_edit = function()
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title      = _("Rename screen"),
                        input      = _screen.name,
                        input_hint = _("Screen name"),
                        buttons    = {{
                            {
                                text     = _("Cancel"),
                                id       = "close",
                                callback = function() UIManager:close(dialog) end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback         = function()
                                    local name = dialog:getInputText()
                                    name = name and name:match("^%s*(.-)%s*$") or ""
                                    UIManager:close(dialog)
                                    if name ~= "" then
                                        CustomScreens.rename(_screen.id, name)
                                        ctx.repaint()
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                end,
                on_delete = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text        = string.format(
                            _("Delete \"%s\"? This removes its layout, modules and Quick Action."),
                            _screen.name),
                        ok_text     = _("Delete"),
                        ok_callback = function()
                            CustomScreens.delete(_screen.id)
                            ctx.repaint()
                        end,
                    })
                end,
            })
        end
        return items
    end

    -- ── 2.3. Layout Editor: page list ────────────────────────────────────────
    local function buildPages(ctx)
        local iw    = ctx.inner_w
        local items = {}

        -- Switch editing context if we've been pushed here for a different
        -- screen than the one st.layout currently holds (e.g. coming from
        -- a Custom Screen's row in buildCustomScreens, or back from it to
        -- the built-in Homescreen's). Both entry points now always pass
        -- these params explicitly (see buildHomeScreenSettings and
        -- buildCustomScreens), so there's no implicit-default case to guess
        -- here.
        local cur    = ctx.current()
        local params = cur and cur.params
        if params and params.pfx and params.pfx ~= st.pfx then
            st.pfx        = params.pfx
            st.pfx_qa     = params.pfx_qa or (params.pfx .. "qa_")
            st.layout_key = params.layout_key or "simpleui_layout"
            st.screen_id  = params.screen_id or "hs"
            st.screen_name = params.name
            st.layout     = LayoutService.load(st.pfx, st.layout_key)
            st.current_page = nil
        end

        for p_idx, page in ipairs(st.layout.pages) do
            local title  = p_idx == 1
                and _("Page 1 (Home)")
                or  string.format(_("Page %d"), p_idx)
            local _p_idx = p_idx

            local del_fn = _p_idx > 1 and function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text        = _("Delete") .. " " .. title .. "?",
                    ok_callback = function()
                        local actual_idx
                        for i, p in ipairs(st.layout.pages) do
                            if p == page then actual_idx = i; break end
                        end
                        if actual_idx then
                            table.remove(st.layout.pages, actual_idx)
                            saveAndRepaint(ctx)
                        end
                    end,
                })
            end or nil

            local mod_names = {}
            for _, entry in ipairs(page.modules) do
                table.insert(mod_names, LayoutService.getModuleName(LayoutService.entryId(entry)))
            end
            local subtitle = #mod_names > 0
                and table.concat(mod_names, "  ·  ")
                or  _("No modules")

            table.insert(items, {
                text         = title,
                subtitle     = subtitle,
                orig_item    = page,
                show_chevron = true,
                on_tap       = function()
                    local actual_idx
                    for i, p in ipairs(st.layout.pages) do
                        if p == page then actual_idx = i; break end
                    end
                    st.current_page = actual_idx or _p_idx
                    ctx.push("page_edit")
                end,
                on_delete    = del_fn,
            })
        end

        return SUI.ArrangeList{
            ctx        = ctx,
            inner_w    = iw,
            items      = items,
            on_repaint = function() ctx.repaint() end,
            on_change  = function(new_items)
                local new_pages = {}
                for _, it in ipairs(new_items) do table.insert(new_pages, it.orig_item) end
                st.layout.pages = new_pages
                LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
            end,
        }
    end

    -- ── 2.4. Layout Editor: modules on a page ────────────────────────────────
    local function buildPageEdit(ctx)
        local iw   = ctx.inner_w
        local items = {}
        local page = st.layout.pages[st.current_page]
        if not page then return items end

        -- Build a positional number for each _row_ instance based on creation
        -- order, using the persisted instance list as the source of truth.
        -- Moving rows in the layout does not change their number; only deletion
        -- reindexes (destroyInstance already removes from the persisted list,
        -- so the next repaint reflects the new numbers automatically).
        local row_counters = {}
        local qa_inst_ids = SUISettings:readSetting("simpleui_qa_row_instances") or {}
        for idx, mid in ipairs(qa_inst_ids) do
            row_counters[mid] = { idx = idx, kind = "qa" }
        end
        local spacer_inst_ids = SUISettings:readSetting("simpleui_spacer_row_instances") or {}
        for idx, mid in ipairs(spacer_inst_ids) do
            row_counters[mid] = { idx = idx, kind = "spacer" }
        end

        for m_idx, entry in ipairs(page.modules) do
            local mod_id       = LayoutService.entryId(entry)
            local mod_name     = LayoutService.getModuleName(mod_id)
            local mod_subtitle = nil

            if row_counters[mod_id] then
                local entry = row_counters[mod_id]
                if entry.kind == "spacer" then
                    local ok_cfg, Config2 = pcall(require, "infra/sui_config")
                    if ok_cfg and Config2 then
                        local pct = Config2.getModuleScalePct(mod_id, st.pfx)
                        mod_subtitle = pct .. "%"
                    end
                else
                    local items_key = st.pfx_qa .. mod_id .. "_items"
                    local qa_ids = SUISettings:readSetting(items_key) or {}
                    if #qa_ids > 0 then
                        local ok_qa, QA = pcall(require, "features/sui_quickactions")
                        if ok_qa and QA and QA.getEntry then
                            local names = {}
                            for _, qa_id in ipairs(qa_ids) do
                                local entry2 = QA.getEntry(qa_id)
                                table.insert(names, entry2 and entry2.label or qa_id)
                            end
                            mod_subtitle = table.concat(names, "  ·  ")
                        end
                    end
                    if not mod_subtitle or mod_subtitle == "" then mod_subtitle = _("No actions configured") end
                end
            end

            -- Featured Collection instances: shows the assigned collection as a
            -- subtitle (e.g. "test"), to distinguish instances in the page's
            -- module list without having to open each one.
            if type(mod_id) == "string" and mod_id:match("^coll_row_") then
                local coll_name = SUISettings:readSetting(st.pfx .. mod_id .. "_coll_name")
                if coll_name and coll_name ~= "" then
                    mod_subtitle = coll_name
                else
                    mod_subtitle = _("No collection selected")
                end
            end

            table.insert(items, {
                text         = mod_name,
                subtitle     = mod_subtitle,
                orig_item    = mod_id,
                show_chevron = true,
                on_tap       = function()
                    st.current_module_id = mod_id
                    ctx.push("module_settings")
                end,
                on_delete    = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text        = _("Delete") .. " " .. mod_name .. "?",
                        ok_callback = function()
                            for i, m in ipairs(page.modules) do
                                if LayoutService.entryId(m) == mod_id then
                                    table.remove(page.modules, i)
                                    break
                                end
                            end
                            -- If this is a dynamic instance, destroy it and purge its settings.
                            if mod_id:match("_row_") then
                                Registry.purgeInstanceSettings(mod_id, st.pfx)
                                Registry.destroyInstance(mod_id)
                            end
                            saveAndRepaint(ctx)
                        end,
                    })
                end,
                more_items = {
                    {
                        text = _("Move to page"),
                        icon = "move_page",
                        on_tap = function()
                            local picker_items = {}
                            for p_idx, p in ipairs(st.layout.pages) do
                                if p_idx ~= st.current_page then
                                    local _p_idx = p_idx
                                    local title  = _p_idx == 1
                                        and _("Page 1 (Home)")
                                        or  string.format(_("Page %d"), _p_idx)
                                    table.insert(picker_items, {
                                        text = title,
                                        on_tap = function(picker_ctx)
                                            local actual_idx
                                            for i, m in ipairs(page.modules) do
                                                if LayoutService.entryId(m) == mod_id then
                                                    actual_idx = i
                                                    break
                                                end
                                            end
                                            if actual_idx then
                                                table.remove(page.modules, actual_idx)
                                                table.insert(st.layout.pages[_p_idx].modules, mod_id)
                                                LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                                            end
                                            picker_ctx.pop()
                                            ctx.repaint()
                                        end
                                    })
                                end
                            end
                            if #picker_items == 0 then
                                UI.Notify.toast(_("No other pages available."), 2)
                                return
                            end
                            ctx.push("item_picker", { title = _("Move to page"), items = picker_items })
                        end
                    }
                },
            })
        end

        return SUI.ArrangeList{
            ctx        = ctx,
            inner_w    = iw,
            items      = items,
            empty_text = _("No modules"),
            on_repaint = function() ctx.repaint() end,
            on_change  = function(new_items)
                local new_mods = {}
                for _, it in ipairs(new_items) do
                    table.insert(new_mods, it.orig_item)
                end
                st.layout.pages[st.current_page].modules = new_mods
                LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
            end,
        }
    end

    -- ── 2.5. Module Picker ───────────────────────────────────────────────────
    local function buildModulePicker(ctx)
        local iw         = ctx.inner_w
        local items      = {}
        local active_set = {}

        for _, page in ipairs(st.layout.pages) do
            for _, m in ipairs(page.modules) do
                local id = LayoutService.entryId(m)
                if id then active_set[id] = true end
            end
        end

        local all_mods = Registry.list()
        logger.dbg("simpleui: buildModulePicker: Registry.list() count =", #all_mods)
        local active_count = 0
        for k, _ in pairs(active_set) do active_count = active_count + 1 end
        logger.dbg("simpleui: buildModulePicker: active_set count =", active_count)
        for k, _ in pairs(active_set) do logger.dbg("  active:", k) end
        for _, mod in ipairs(all_mods) do
            local is_inst = mod.id:match("_row_") ~= nil
            logger.dbg("  mod:", mod.id, "is_instance:", is_inst, "in_active:", active_set[mod.id] ~= nil)
        end
        logger.dbg("simpleui: isInstanciable(quick_actions_row) =", Registry.isInstanciable("quick_actions_row"))

        -- Singleton modules: show only those not yet in the layout,
        -- and skip instances of instanciable modules (they have "_row_" in their id).
        for _, mod in ipairs(Registry.list()) do
            local is_instance = mod.id:match("_row_") ~= nil
            if not active_set[mod.id] and not is_instance then
                local _mod_id = mod.id
                table.insert(items, SUI.ListRow{
                    title   = mod.name,
                    inner_w = iw,
                    on_tap  = function()
                        table.insert(st.layout.pages[st.current_page].modules, _mod_id)
                        LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                        ctx.pop()
                    end,
                })
            end
        end

        -- Instanciable modules: always show an "Add" entry regardless of
        -- how many instances already exist in the layout.
        local instanciable_bases = { "quick_actions_row", "spacer_row", "coll_row" }
        for _i, base_id in ipairs(instanciable_bases) do
            if Registry.isInstanciable(base_id) then
                local base_mod = Registry.getBase(base_id)
                local base_name = (base_mod and base_mod.name) or base_id
                table.insert(items, SUI.ListRow{
                    title    = base_name,
                    inner_w  = iw,
                    on_tap   = function()
                        local new_id = Registry.createInstance(base_id)
                        if new_id then
                            table.insert(st.layout.pages[st.current_page].modules, new_id)
                            LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                        end
                        ctx.pop()
                    end,
                })
            end
        end

        if #items == 0 then
            table.insert(items, SUI.ListRow{
                title   = _("All modules have already been added."),
                inner_w = iw,
            })
        end

        return items
    end

    -- ── 2.5b. Item Picker ────────────────────────────────────────────────────
    -- Generic picker pushed by ctx_menu.show_item_picker({ title, items }).
    -- items: { text, on_tap(ctx) }
    -- Shows a "All items already added." row when the list is empty.
    local function buildItemPicker(ctx)
        local iw     = ctx.inner_w
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        local rows   = {}

        local picker_items = type(params.items) == "table" and params.items or {}

        if #picker_items == 0 then
            rows[#rows + 1] = SUI.ListRow{
                title   = _("All items have already been added."),
                inner_w = iw,
            }
        else
            for _, it in ipairs(picker_items) do
                local _it = it
                rows[#rows + 1] = SUI.ListRow{
                    title   = _it.text,
                    inner_w = iw,
                    on_tap  = function() _it.on_tap(ctx) end,
                }
            end
        end

        return rows
    end

    -- ── 2.6. Module Settings ─────────────────────────────────────────────────
    -- Delegates entirely to SUIWindow.buildModuleSettingsScreen — the single
    -- source of truth also used by the long-press module settings window
    -- (engines/sui_screen_engine.lua), so both windows show the exact same
    -- content for the same module.
    local function buildModuleSettings(ctx)
        local mod = Registry.get(st.current_module_id)
        if not mod or not mod.getMenuItems then return {} end

        return SUI.buildModuleSettingsScreen(ctx, mod, {
            pfx           = st.pfx,
            pfx_qa        = st.pfx_qa,
            extra_refresh = function()
                LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
            end,
            on_change     = function()
                -- Invalidate the live screen's module-list cache (gap/bento fingerprint).
                local SE = package.loaded["engines/sui_screen_engine"]
                    or package.loaded["screens/sui_homescreen"]
                if SE and SE.getInstance then
                    local live = SE.getInstance(st.screen_id or "hs")
                    if live then live._enabled_mods_cache = nil end
                elseif SE and SE._instance then
                    SE._instance._enabled_mods_cache = nil
                end
            end,
        })
    end

    -- ── 2.8. General Settings ────────────────────────────────────────────────
    local function buildGeneralSettings(ctx)
        local plugin = getPlugin()
        return buildPluginMenuScreen(ctx,
            plugin and plugin.makeBehaviourMenuItems)
    end

    -- ── 2.9. Presets ─────────────────────────────────────────────────────────
    local function buildPresets(ctx)
        local ok, SUIPresets = pcall(require, "features/sui_presets")
        if not ok or not SUIPresets then
            return { SUI.ListRow{ title = _("Presets module unavailable."), inner_w = ctx.inner_w } }
        end

        local function _applyFullLayoutRefresh()
            local plugin = getPlugin()
            if plugin then plugin:_rewrapAllWidgets() end
            local Patches = package.loaded["infra/sui_patches"]
            if Patches and Patches.injectWallpaperIntoFullscreenWidget then
                local core_ok, core = pcall(require, "infra/sui_core")
                local stack = core_ok and core.getWindowStack and core.getWindowStack()
                if stack then
                    for _, entry in ipairs(stack) do
                        if entry.widget and entry.widget._navbar_injected then
                            pcall(Patches.injectWallpaperIntoFullscreenWidget, entry.widget)
                        end
                    end
                end
            end
            local FM = package.loaded["apps/filemanager/filemanager"]
            if FM and FM.instance then
                FM.instance._navbar_inner = nil
                pcall(function() FM.instance:setupLayout() end)
                UIManager:setDirty(FM.instance, "ui")
            end
        end

        local items = SUIPresets.makeMenuItems{
            on_apply       = function()
                local HS = package.loaded["screens/sui_homescreen"]
                if HS and HS.rebuildLayout then HS.rebuildLayout() end
                _applyFullLayoutRefresh()
                ctx.repaint()
            end,
            on_save        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay   or function() end,
            unlock_overlay = ctx.unlockOverlay or function() end,
        }
        return makeMenuTable(ctx, items)
    end

    -- ── 2.10. Nested Menu ────────────────────────────────────────────────────
    local function buildNestedMenu(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        local items  = params.items or {}
        if type(params.items_func) == "function" then
            items = params.items_func()
        end
        return makeMenuTable(ctx, items)
    end

    -- ── 2.11. Arrange ────────────────────────────────────────────────────────
    local function buildArrange(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        
        local items = params.items
        if not items and type(params.items_func) == "function" then
            items = params.items_func()
        end
        items = items or {}

        return SUI.ArrangeList{
            ctx        = ctx,
            items      = items,
            inner_w    = ctx.inner_w,
            empty_text = params.empty_text,
            delete_icon = params.delete_icon,
            on_repaint = function() ctx.repaint() end,
            on_delete  = params.on_delete and function(idx, item)
                table.remove(items, idx)
                if params.items and params.items ~= items then
                    table.remove(params.items, idx)
                end
                params.on_delete(item)
                if params.on_change then params.on_change(items) end
            end or nil,
            on_change  = function(new_items)
                if type(params.on_change) == "function" then params.on_change(new_items) end
            end,
        }
    end

    local function buildRowPage(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        
        local items = params.items
        if not items and type(params.items_func) == "function" then
            items = params.items_func()
        end
        items = items or {}
        
        return SUI.RowPage{
            items      = items,
            inner_w    = ctx.inner_w,
            empty_text = params.empty_text,
            on_repaint = function() ctx.repaint() end,
            on_delete  = params.on_delete and function(idx, item)
                table.remove(items, idx)
                if params.items and params.items ~= items then
                    table.remove(params.items, idx)
                end
                params.on_delete(item)
                if params.on_change then params.on_change(items) end
                ctx.repaint()
            end or nil,
            on_change  = function(new_items)
                if type(params.on_change) == "function" then params.on_change(new_items) end
                ctx.repaint()
            end,
        }
    end

    -- ── 2.12–2.16. Plugin-delegated screens ──────────────────────────────────
    local function buildBarsSettings(ctx)
        local plugin = getPlugin()
        return buildPluginMenuScreen(ctx, plugin and plugin.makeBarsMenuItems)
    end

    local function buildLibrarySettings(ctx)
        local plugin = getPlugin()
        return buildPluginMenuScreen(ctx, plugin and plugin.makeLibraryMenuItems)
    end

    local function buildStyleSettings(ctx)
        local plugin = getPlugin()
        return buildPluginMenuScreen(ctx, plugin and plugin.makeStyleMenuItems)
    end

    local function buildAboutSettings(ctx)
        local plugin   = getPlugin()
        local ctx_menu = makeCtxMenu(ctx)
        ctx_menu.ConfirmBox = require("ui/widget/confirmbox")
        return buildPluginMenuScreen(ctx, plugin and plugin.makeAboutMenuItems)
    end

    -- ── Screen map ───────────────────────────────────────────────────────────
    return {
        __root__               = buildRoot,
        home_screen_settings   = buildHomeScreenSettings,
        custom_screens         = buildCustomScreens,
        bars_settings          = buildBarsSettings,
        library_settings       = buildLibrarySettings,
        style_settings         = buildStyleSettings,
        about_settings         = buildAboutSettings,
        pages                  = buildPages,
        page_edit              = buildPageEdit,
        module_picker          = buildModulePicker,
        module_settings        = buildModuleSettings,
        item_picker            = buildItemPicker,
        general_settings       = buildGeneralSettings,
        presets                = buildPresets,
        nested_menu            = buildNestedMenu,
        arrange                = buildArrange,
        row_page               = buildRowPage,
    }
end

-- ===========================================================================
-- 3. Declarative screen titles
-- ===========================================================================
-- Adding a new screen requires only a new entry here — no separate title
-- function to modify elsewhere.

local function makeScreenTitles(st)
    return {
        __root__               = _("Simple UI Settings"),
        home_screen_settings   = _("Home Screen"),
        custom_screens         = _("Extra Custom Screens"),
        bars_settings          = _("Bars"),
        library_settings       = _("Library"),
        style_settings         = _("Style"),
        about_settings         = _("About"),
        pages = function()
            return st.screen_id == "hs" and _("Layout Editor")
                or (st.screen_name or _("Layout Editor"))
        end,
        module_picker          = _("Add Module"),
        item_picker = function(ctx)
            local cur = ctx.current()
            return cur and cur.params and cur.params.title or _("Add Item")
        end,
        general_settings       = _("Behaviour"),
        presets                = _("Home Screen Presets"),
        -- Dynamic titles (function receives ctx):
        page_edit = function(ctx)
            local idx = st.current_page or 1
            return idx == 1
                and _("Page 1 (Home)")
                or  string.format(_("Page %d"), idx)
        end,
        module_settings = function()
            local mod_id = st.current_module_id or ""
            return LayoutService.getModuleName(mod_id)
        end,
        nested_menu = function(ctx)
            local cur = ctx.current()
            return cur and cur.params and cur.params.title or ""
        end,
        arrange = function(ctx)
            local cur = ctx.current()
            return cur and cur.params and cur.params.title or _("Arrange Items")
        end,
        row_page = function(ctx)
            local cur = ctx.current()
            return cur and cur.params and cur.params.title or ""
        end,
    }
end

-- ===========================================================================
-- 4. Entry point
-- ===========================================================================

function SettingsWindow:show(on_close)
    local st = {
        layout            = LayoutService.load(),
        current_page      = nil,
        current_module_id = nil,
        -- Which screen's layout/settings st.layout currently holds. Defaults
        -- to the built-in Homescreen; buildRoot() resets to these defaults
        -- on every visit to the top-level menu (a Custom Screen's editing
        -- context never survives a trip back through root), and buildPages()
        -- switches them when entering a Custom Screen's "Edit Layout".
        pfx               = "simpleui_hs_",
        pfx_qa            = "simpleui_hs_qa_",
        layout_key        = "simpleui_layout",
        screen_id         = "hs",
    }

    local wrapped_on_close = function()
        if on_close then on_close() end
    end

    local screens = buildScreens(st)
    local titles  = makeScreenTitles(st)

    local Config = require("infra/sui_config")
    local win = SUI:new{
        name           = "sui_win_settings",
        screens        = screens,
        screen_titles  = titles,
        navpager_mode  = Config.isNavpagerEnabled(),
        on_close       = wrapped_on_close,
        position       = "bottom",
        screen_footers = {
            custom_screens = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Create Screen"),
                    on_tap = function()
                        local ok, CustomScreens = pcall(require, "infra/sui_custom_screens")
                        if not ok or not CustomScreens then return end
                        local InputDialog = require("ui/widget/inputdialog")
                        local dialog
                        dialog = InputDialog:new{
                            title      = _("Create screen"),
                            input      = "",
                            input_hint = _("Screen name"),
                            buttons    = {{
                                {
                                    text     = _("Cancel"),
                                    id       = "close",
                                    callback = function() UIManager:close(dialog) end,
                                },
                                {
                                    text             = _("Create"),
                                    is_enter_default = true,
                                    callback         = function()
                                        local name = dialog:getInputText()
                                        name = name and name:match("^%s*(.-)%s*$") or ""
                                        UIManager:close(dialog)
                                        CustomScreens.create(name ~= "" and name or nil)
                                        ctx.repaint()
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dialog)
                    end,
                })
            end,
            pages = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Add Page"),
                    on_tap = function()
                        table.insert(st.layout.pages, { id = os.time(), modules = {} })
                        if ctx.jump_to_last_page then ctx.jump_to_last_page() end
                        ctx.repaint()
                    end,
                })
            end,
            page_edit = function(ctx)
                local active_set = {}
                for _, page in ipairs(st.layout.pages) do
                    for _, m in ipairs(page.modules) do
                        local id = LayoutService.entryId(m)
                        if id then active_set[id] = true end
                    end
                end

                local all_mods = Registry.list()
                local available = false
                for _, mod in ipairs(all_mods) do
                    local is_instance = mod.id:match("_row_") ~= nil
                    if not active_set[mod.id] and not is_instance then
                        available = true
                        break
                    end
                end
                if not available then
                    local instanciable_bases = { "quick_actions_row", "spacer_row", "coll_row" }
                    for _i, base_id in ipairs(instanciable_bases) do
                        if Registry.isInstanciable(base_id) then
                            available = true
                            break
                        end
                    end
                end

                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Add Module"),
                    enabled = available,
                    on_tap = function() ctx.push("module_picker") end,
                })
            end,
            item_picker = function(ctx)
                -- No footer needed: the picker auto-pops on selection.
                -- If all items are already added the screen shows a message row.
                return nil
            end,
        },
    }

    win:show()
end

return SettingsWindow
