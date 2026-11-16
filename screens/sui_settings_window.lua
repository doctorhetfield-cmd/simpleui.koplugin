-- sui_settings_window.lua — SimpleUI ▸ Settings Window
--
-- Central hub for all SimpleUI SUIWindows.
-- Uses SUIWindow components directly (SUI.ListRow, SUI.PageCard, etc.) —
-- no C. sub-namespace.
--
-- Architecture:
--   LayoutService  — data layer, in infra/sui_layout (load/save layout, module names)
--   buildScreens   — render layer (one function per screen)
--   SettingsWindow — entry point (:show)
--
-- Screen map (all keys registered in SUIWindow.screens):
--   __root__               — top-level settings menu
--   home_screen_settings   — Home Screen section (layout, "Extra Custom Screens",
--                             "Wallpaper" and "Stats" (nested_menu sub-items), presets,
--                             behaviour)
--   custom_screens          — Custom Screens list (reached via Home Screen ▸
--                              "Extra Custom Screens", not linked from __root__)
--   bars_settings           — Bars section
--   library_settings        — Library section
--   style_settings          — Style section (icons, fonts and appearance)
--   critter_settings        — Tiny Critter section
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

local UIManager   = require("ui/uimanager")
local UI         = require("infra/sui_core")
local _           = require("infra/sui_i18n").translate

local SUI         = require("engines/sui_window")
local Registry    = require("modules/moduleregistry")
local Config      = require("infra/sui_config")
local BentoSheet  = require("features/dialogs/sui_bento_sheet")
local Bento       = require("infra/sui_bento")


local SettingsWindow = {}

local LayoutService = require("infra/sui_layout")

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

    -- makeCtxMenu: the standard ctx_menu passed to plugin menu generators, with
    -- the key prefixes of the screen being edited.
    local function makeCtxMenu(ctx)
        local ctx_menu  = SUI.makeCtxMenu(ctx)
        ctx_menu.pfx    = st.pfx
        ctx_menu.pfx_qa = st.pfx_qa
        return ctx_menu
    end

    -- makeMenuTable: wraps a KOReader item list as SUI.MenuTable rows.
    local function makeMenuTable(ctx, items)
        return SUI.MenuTable{
            items          = items,
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
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
                left_icon    = "home",
                subtitle     = _("Layout, wallpaper, presets and behaviour"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("home_screen_settings") end,
            },
            SUI.ListRow{
                title        = _("Bars"),
                left_icon    = "bars",
                subtitle     = _("Status, title, navigation and pagination"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("bars_settings") end,
            },
            SUI.ListRow{
                title        = _("Library"),
                left_icon    = "library",
                subtitle     = _("Book-browser settings"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("library_settings") end,
            },
            SUI.ListRow{
                title        = _("Style"),
                left_icon    = "style",
                subtitle     = _("Icons, fonts and appearance"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("style_settings") end,
            },
            SUI.ListRow{
                title        = _("Tiny Critter"),
                left_icon    = "critter",
                subtitle     = _("Your companion and what it says"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("critter_settings") end,
            },
            SUI.ListRow{
                title        = _("Quick Actions"),
                left_icon    = "quick_actions",
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
                left_icon    = "info",
                subtitle     = _("Version, author and updates"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("about_settings") end,
            },
        }
    end

    -- Stats menu screen. Opening a statistics window closes this window; the
    -- statistics window's back button reopens it on the same screen.
    local function statsMenuParams()
        return {
            title      = _("Stats"),
            items_func = function(ctx)
                local plugin = getPlugin()
                if not (plugin and plugin.makeStatsMenuItems) then return {} end
                return plugin.makeStatsMenuItems{
                    open_window = function(id)
                        ctx.close()
                        require("screens/sui_stats_launcher").open(id, {
                            on_back = function()
                                SettingsWindow:show(nil, {
                                    { id = "home_screen_settings" },
                                    { id = "nested_menu", params = statsMenuParams() },
                                })
                            end,
                        })
                    end,
                }
            end,
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
                title        = _("Stats"),
                inner_w      = iw,
                show_chevron = true,
                on_tap       = function() ctx.push("nested_menu", statsMenuParams()) end,
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
                    require("features/dialogs/sui_dialogs").prompt{
                        title     = _("Rename screen"),
                        value     = _screen.name,
                        hint      = _("Screen name"),
                        ok_text   = _("Save"),
                        on_submit = function(name)
                            CustomScreens.rename(_screen.id, name)
                            ctx.repaint()
                        end,
                    }
                end,
                on_delete = function()
                    local Dialogs = require("features/dialogs/sui_dialogs")
                    Dialogs.confirm{
                        text        = string.format(
                            _("Delete \"%s\"? This removes its layout, modules and Quick Action."),
                            _screen.name),
                        ok_text     = _("Delete"),
                        ok_callback = function()
                            CustomScreens.delete(_screen.id)
                            ctx.repaint()
                        end,
                    }
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
        if params and params.pfx then
            st.pfx         = params.pfx
            st.pfx_qa      = params.pfx_qa or (params.pfx .. "qa_")
            st.layout_key  = params.layout_key or "simpleui_layout"
            st.screen_id   = params.screen_id or "hs"
            st.screen_name = params.name
            if st.layout_loaded_key ~= st.layout_key then
                st.layout            = LayoutService.load(st.pfx, st.layout_key)
                st.layout_loaded_key = st.layout_key
                st.current_page      = nil
            end
        end

        for p_idx, page in ipairs(st.layout.pages) do
            local title  = p_idx == 1
                and _("Page 1 (Home)")
                or  string.format(_("Page %d"), p_idx)
            local _p_idx = p_idx

            local del_fn = _p_idx > 1 and function()
                local Dialogs = require("features/dialogs/sui_dialogs")
                Dialogs.confirm{
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
                }
            end or nil

            local mod_names = {}
            for _, entry in ipairs(page.modules) do
                table.insert(mod_names, LayoutService.getModuleName(LayoutService.entryId(entry)))
            end
            local subtitle = #mod_names > 0
                and table.concat(mod_names, "  ·  ")
                or  _("No modules")

            local item = {
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
            }
            -- A hidden page keeps its modules but is left out of the screen.
            Config.applyVisibilityToggle(item, {
                is_visible  = function() return not page.hidden end,
                set_visible = function(visible)
                    if not visible then
                        local others = 0
                        for _, p in ipairs(st.layout.pages) do
                            if p ~= page and not p.hidden then others = others + 1 end
                        end
                        if others == 0 then
                            UI.Notify.toast(_("At least one page must stay visible."), 2)
                            return false
                        end
                    end
                    page.hidden = not visible or nil
                end,
                on_change   = function()
                    LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                end,
                repaint     = function() ctx.repaint() end,
            })
            table.insert(items, item)
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
    -- Removes a module from its page (and destroys it, for a dynamic instance).
    local function removeModule(ctx, mod_id)
        local Dialogs  = require("features/dialogs/sui_dialogs")
        local mod_name = LayoutService.getModuleName(mod_id)
        Dialogs.confirm{
            text        = _("Delete") .. " " .. mod_name .. "?",
            ok_callback = function()
                LayoutService.remove(st.layout, st.pfx, mod_id)
                saveAndRepaint(ctx)
            end,
        }
    end

    -- Lets the user pick the page a module moves to.
    local function moveModuleToPage(ctx, mod_id)
        local picker_items = {}
        for p_idx, _p in ipairs(st.layout.pages) do
            if p_idx ~= st.current_page then
                local _p_idx = p_idx
                local title  = _p_idx == 1
                    and _("Page 1 (Home)")
                    or  string.format(_("Page %d"), _p_idx)
                table.insert(picker_items, {
                    text = title,
                    on_tap = function(picker_ctx)
                        local page = LayoutService.findPage(st.layout, mod_id)
                        if page then
                            for i, m in ipairs(page.modules) do
                                if LayoutService.entryId(m) == mod_id then
                                    table.remove(page.modules, i)
                                    break
                                end
                            end
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

    local function buildPageEdit(ctx)
        local page = st.layout.pages[st.current_page]
        if not page then return {} end
        local ids, spans = LayoutService.pageSpans(page, st.pfx)
        local mode       = LayoutService.mode(st.pfx)

        return SUI.BentoMap{
            inner_w     = ctx.inner_w,
            rows        = Bento.packFor(ids, spans, mode),
            spans       = spans,
            row_total   = mode.classic and Bento.CLASSIC_MAX or Bento.ROW,
            label_for   = LayoutService.getModuleName,
            span_label  = function(span)
                if mode.classic then return span .. "%" end
                return span == Bento.FULL and _("Full Width") or Config.bentoSpanLabel(span)
            end,
            summary_for = function(mod_id) return Registry.getSummary(mod_id, st.pfx, st.pfx_qa) end,
            can_move    = function(mod_id) return Bento.canMove(ids, spans, mod_id, mode) end,
            on_move     = function(mod_id, dir)
                LayoutService.move(st.layout, st.pfx, mod_id, dir)
                saveAndRepaint(ctx)
            end,
            open_text   = _("Incomplete row"),
            empty_text  = _("No modules"),
            on_delete   = function(mod_id) removeModule(ctx, mod_id) end,
            on_tap      = function(mod_id)
                BentoSheet.show{
                    mod_id     = mod_id,
                    pfx        = st.pfx,
                    layout     = st.layout,
                    subtitle_for = function(id) return Registry.getSummary(id, st.pfx, st.pfx_qa) end,
                    on_changed = function() ctx.repaint() end,
                    rows       = function(id)
                        return {
                            {
                                text = _("Settings"), sui_icon = "settings", chevron = true,
                                callback = function()
                                    st.current_module_id = id
                                    ctx.push("module_settings")
                                end,
                            },
                            {
                                text = _("To Page"), sui_icon = "move_page", chevron = true,
                                callback = function() moveModuleToPage(ctx, id) end,
                            },
                        }
                    end,
                }
            end,
        }
    end

    -- ── 2.5. Module Picker ───────────────────────────────────────────────────
    -- Two levels: the categories that still have something to add, then the
    -- modules of the chosen category (params.category).
    local function buildModulePicker(ctx)
        local iw         = ctx.inner_w
        local items      = {}
        local active_set = {}
        local cur        = ctx.current()
        local chosen     = cur and cur.params and cur.params.category

        for _, page in ipairs(st.layout.pages) do
            for _, m in ipairs(page.modules) do
                local id = LayoutService.entryId(m)
                if id then active_set[id] = true end
            end
        end

        -- Candidates by category: singleton modules not yet in the layout
        -- (instances are skipped) and, always, one "Add" entry per instanciable
        -- module.
        local by_cat = {}
        local function addEntry(mod_id, title, on_tap)
            local cat = Registry.getCategory(mod_id)
            by_cat[cat] = by_cat[cat] or {}
            table.insert(by_cat[cat], { title = title, on_tap = on_tap })
        end

        for _, mod in ipairs(Registry.list()) do
            if not active_set[mod.id] and not Registry.isInstance(mod.id) then
                local _mod_id = mod.id
                addEntry(_mod_id, mod.name, function()
                    table.insert(st.layout.pages[st.current_page].modules, _mod_id)
                    LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                    ctx.pop{ levels = 2 }
                end)
            end
        end

        for _i, base_id in ipairs(Registry.getInstanciableBaseIds()) do
            local base_mod = Registry.getBase(base_id)
            addEntry(base_id, (base_mod and base_mod.name) or base_id, function()
                local new_id = Registry.createInstance(base_id)
                if new_id then
                    table.insert(st.layout.pages[st.current_page].modules, new_id)
                    LayoutService.save(st.layout, st.pfx, st.layout_key, st.screen_id)
                end
                ctx.pop{ levels = 2 }
            end)
        end

        for _i, cat in ipairs(Registry.getCategories()) do
            local entries = by_cat[cat.key]
            if entries and chosen then
                if cat.key == chosen then
                    for _j, e in ipairs(entries) do
                        table.insert(items, SUI.ListRow{ title = e.title, inner_w = iw, on_tap = e.on_tap })
                    end
                end
            elseif entries then
                local _cat = cat
                table.insert(items, SUI.ListRow{
                    title        = cat.title,
                    inner_w      = iw,
                    show_chevron = true,
                    on_tap       = function()
                        ctx.push("module_picker", { category = _cat.key, title = _cat.title })
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
            layout_sheet  = function()
                BentoSheet.show{
                    mod_id     = mod.id,
                    pfx        = st.pfx,
                    layout     = st.layout,
                    on_changed = function() ctx.repaint() end,
                }
            end,
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
            in_window      = true,
        }
        return makeMenuTable(ctx, items)
    end

    -- ── 2.10. Nested Menu ────────────────────────────────────────────────────
    local function buildNestedMenu(ctx)
        local cur    = ctx.current()
        local params = cur and cur.params or {}
        local items  = params.items or {}
        if type(params.items_func) == "function" then
            items = params.items_func(ctx)
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

    local function buildCritterSettings(ctx)
        local plugin = getPlugin()
        return buildPluginMenuScreen(ctx, plugin and plugin.makeCritterMenuItems)
    end

    local function buildAboutSettings(ctx)
        local plugin   = getPlugin()
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
        critter_settings       = buildCritterSettings,
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
        critter_settings       = _("Tiny Critter"),
        about_settings         = _("About"),
        pages = function()
            return st.screen_id == "hs" and _("Layout Editor")
                or (st.screen_name or _("Layout Editor"))
        end,
        module_picker          = SUI.paramsTitle(_("Add Module")),
        item_picker            = SUI.paramsTitle(_("Add Item")),
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
        nested_menu            = SUI.paramsTitle(""),
        arrange                = SUI.paramsTitle(_("Arrange Items")),
        row_page               = SUI.paramsTitle(""),
    }
end

-- ===========================================================================
-- 4. Entry point
-- ===========================================================================

--- Opens the settings window. `nav_path` optionally lists screens ({ id, params })
--- to open on top of the root, e.g. to return to a nested menu.
--- `state` optionally seeds the editing context, for a `nav_path` that skips the
--- screens which would otherwise set it.
function SettingsWindow:show(on_close, nav_path, state)
    local st = {
        layout            = LayoutService.load(),
        layout_loaded_key = "simpleui_layout",
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
    for key, value in pairs(state or {}) do st[key] = value end

    local wrapped_on_close = function()
        if on_close then on_close() end
    end

    local screens = buildScreens(st)
    local titles  = makeScreenTitles(st)

    local win = SUI:new{
        name           = "sui_win_settings",
        icon           = "settings",
        screens        = screens,
        screen_titles  = titles,
        navpager_mode  = Config.isNavpagerEnabled(),
        on_close       = wrapped_on_close,
        nav_path       = nav_path,
        position       = "bottom",
        screen_footers = {
            custom_screens = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Create Screen"),
                    on_tap = function()
                        local ok, CustomScreens = pcall(require, "infra/sui_custom_screens")
                        if not ok or not CustomScreens then return end
                        require("features/dialogs/sui_dialogs").prompt{
                            title       = _("Create screen"),
                            hint        = _("Screen name"),
                            ok_text     = _("Create"),
                            allow_empty = true,
                            on_submit   = function(name)
                                CustomScreens.create(name ~= "" and name or nil)
                                ctx.repaint()
                            end,
                        }
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
                    if not active_set[mod.id] and not Registry.isInstance(mod.id) then
                        available = true
                        break
                    end
                end
                -- An instanciable module can always be added once more.
                if not available then
                    available = #Registry.getInstanciableBaseIds() > 0
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

--- Opens the page editor of the page that holds `mod_id` on the screen with
--- settings prefix `pfx`; going back leads through the page list.
function SettingsWindow:showPageEditor(pfx, mod_id)
    local layout_key, screen_id = LayoutService.screenFor(pfx)
    if not layout_key then return end
    local layout = LayoutService.load(pfx, layout_key)
    local _page, page_idx = LayoutService.findPage(layout, mod_id)
    if not page_idx then return end

    local name
    if screen_id ~= "hs" then
        for _i, screen in ipairs(require("infra/sui_custom_screens").list()) do
            if screen.id == screen_id then name = screen.name end
        end
    end
    local params = {
        pfx = pfx, pfx_qa = pfx .. "qa_",
        layout_key = layout_key, screen_id = screen_id, name = name,
    }
    self:show(nil, {
        { id = screen_id == "hs" and "home_screen_settings" or "custom_screens" },
        { id = "pages", params = params },
        { id = "page_edit" },
    }, {
        layout            = layout,
        layout_loaded_key = layout_key,
        current_page      = page_idx,
        pfx               = pfx,
        pfx_qa            = params.pfx_qa,
        layout_key        = layout_key,
        screen_id         = screen_id,
        screen_name       = name,
    })
end

return SettingsWindow
