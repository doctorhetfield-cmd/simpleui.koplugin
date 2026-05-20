-- sui_bookfusion_settings.lua — BookFusion tab settings menu tree
-- -----------------------------------------------------------------------------
-- Returns a menu-item table mounted under SimpleUI → Custom Tabs. Reads via
-- sui_bookfusion.Settings.* accessors; writes via SUISettings:saveSetting so
-- keys live in sui_store and participate in preset export/import. Changes
-- repaint the BookFusion tab in place when it's the active widget.

local _           = require("gettext")
local Device      = require("device")
local Screen      = Device.screen
local SpinWidget  = require("ui/widget/spinwidget")
local UIManager   = require("ui/uimanager")
local SUISettings = require("sui_store")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Lazy require: sui_menu loads this file well after sui_bookfusion has been
-- pulled in during plugin boot, so package.loaded is always populated.
local function BF()   return require("sui_bookfusion") end
local function K(id)  return BF().Settings.KEYS[id]   end
local function S()    return BF().Settings            end

-- Save a setting and, if the BookFusion tab is currently on screen, rebuild
-- it in place so the change takes effect immediately. No-op when the tab
-- isn't open — next open reads the fresh value.
local function saveAndRepaint(key, value)
    SUISettings:saveSetting(key, value)
    local bf = BF()
    local inst = bf._instance
    if inst and inst._rebuildAndRepaint then
        pcall(function() inst:_rebuildAndRepaint() end)
    end
end

-- opts = { text, key, accessor (fn → int), min, max, default, info }
local function intSpinItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d", opts.text, opts.accessor())
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = opts.accessor(),
                value_min       = opts.min,
                value_max       = opts.max,
                value_step      = 1,
                value_hold_step = 1,
                default_value   = opts.default,
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

-- Percentage spinner for 0..1 float settings displayed as integer %.
-- opts = { text, key, accessor, min_pct, max_pct, step_pct, default_pct, info }
local function pctSpinItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d%%", opts.text, math.floor(opts.accessor() * 100 + 0.5))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = math.floor(opts.accessor() * 100 + 0.5),
                value_min       = opts.min_pct,
                value_max       = opts.max_pct,
                value_step      = opts.step_pct,
                value_hold_step = opts.step_pct,
                default_value   = opts.default_pct,
                unit            = "%",
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value / 100)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

-- opts = { text, key, accessor (fn → bool) }
local function toggleItem(opts)
    return {
        text           = opts.text,
        keep_menu_open = true,
        checked_func   = function() return opts.accessor() end,
        callback       = function()
            saveAndRepaint(opts.key, not opts.accessor())
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Menu tree
-- ---------------------------------------------------------------------------

-- Title-scale spinner gated on a "show title" toggle. pctSpinItem doesn't
-- express enabled_func, so we inline the SpinWidget construction here.
local function titleScaleItem(opts)
    return {
        text_func = function()
            return string.format("%s: %d%%", opts.text,
                math.floor(opts.accessor() * 100 + 0.5))
        end,
        keep_menu_open = true,
        enabled_func   = opts.enabled_func,
        callback       = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text      = opts.text,
                info_text       = opts.info,
                value           = math.floor(opts.accessor() * 100 + 0.5),
                value_min       = 60,
                value_max       = 160,
                value_step      = 10,
                value_hold_step = 10,
                default_value   = 100,
                unit            = "%",
                ok_text         = _("Set"),
                callback        = function(spin)
                    saveAndRepaint(opts.key, spin.value / 100)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

function M.build()
    return {
        text = _("BookFusion"),
        sub_item_table = {
            -- General — cross-cutting settings.
            {
                text = _("General"),
                sub_item_table = {
                    toggleItem{
                        text     = _("Uniform covers"),
                        key      = K("UNIFORM_COVERS"),
                        accessor = function() return S().uniformCovers() end,
                    },
                    pctSpinItem{
                        text     = _("Label scale"),
                        key      = K("LABEL_SCALE"),
                        accessor = function() return S().labelScale() end,
                        min_pct = 60, max_pct = 160, step_pct = 10, default_pct = 100,
                        info = _("Scales section headings, folder buttons, page numbers, and empty-state messages.  Does not affect the title bar."),
                    },
                    -- Parent/child pair. Child's checked_func returns false
                    -- when the parent is off so the tick visibly tracks
                    -- "will this show on screen?", while the raw value is
                    -- preserved so re-enabling restores the prior choice.
                    toggleItem{
                        text     = _("Show download indicator"),
                        key      = K("DL_IND_GLOBAL"),
                        accessor = function() return S().showDownloadIndicators() end,
                    },
                    {
                        text           = _("Show download indicator in search"),
                        keep_menu_open = true,
                        enabled_func   = function() return S().showDownloadIndicators() end,
                        checked_func   = function()
                            return S().showDownloadIndicators() and S().showDownloadIndicatorsSearch()
                        end,
                        callback       = function()
                            -- Bare write (not saveAndRepaint): the toggle
                            -- only affects the search view, which is never
                            -- on screen while the settings menu is open.
                            SUISettings:saveSetting(K("DL_IND_SEARCH"), not S().showDownloadIndicatorsSearch())
                        end,
                    },
                },
            },
            -- Carousel — landing page's Currently Reading row. Column count
            -- is derived from cover scale + available width (_buildLanding).
            {
                text = _("Carousel"),
                sub_item_table = {
                    pctSpinItem{
                        text     = _("Cover scale"),
                        key      = K("COVER_SCALE_CR"),
                        accessor = function() return S().coverScaleCarousel() end,
                        min_pct = 50, max_pct = 160, step_pct = 10, default_pct = 100,
                        info = _("Smaller covers fit more per row; bigger covers show fewer."),
                    },
                    toggleItem{
                        text     = _("Show book title"),
                        key      = K("SHOW_CR_TITLE"),
                        accessor = function() return S().showCarouselTitle() end,
                    },
                    titleScaleItem{
                        text         = _("Title text scale"),
                        key          = K("TEXT_SCALE_CR"),
                        accessor     = function() return S().textScaleCarousel() end,
                        enabled_func = function() return S().showCarouselTitle() end,
                        info         = _("Scales carousel book titles."),
                    },
                    toggleItem{
                        text     = _("Show progress indicator"),
                        key      = K("SHOW_CR_PROGRESS"),
                        accessor = function() return S().showCarouselProgress() end,
                    },
                    -- Style picker — radio pair gated on the toggle above.
                    {
                        text           = _("Progress bar"),
                        radio          = true,
                        keep_menu_open = true,
                        enabled_func   = function() return S().showCarouselProgress() end,
                        checked_func   = function() return S().progressStyleCarousel() == "bar" end,
                        callback       = function()
                            saveAndRepaint(K("CR_PROGRESS_STYLE"), "bar")
                        end,
                    },
                    {
                        text           = _("Percentage overlay"),
                        radio          = true,
                        keep_menu_open = true,
                        enabled_func   = function() return S().showCarouselProgress() end,
                        checked_func   = function() return S().progressStyleCarousel() == "overlay" end,
                        callback       = function()
                            saveAndRepaint(K("CR_PROGRESS_STYLE"), "overlay")
                        end,
                    },
                    toggleItem{
                        text     = _("Show page number"),
                        key      = K("SHOW_CR_PAGER"),
                        accessor = function() return S().showCarouselPager() end,
                    },
                },
            },
            -- Folders — Plan to Read, Favorites, Search grids. Tile size is
            -- derived from rows × cols + screen geometry.
            {
                text = _("Folders"),
                sub_item_table = {
                    intSpinItem{
                        text     = _("Grid rows"),
                        key      = K("GRID_ROWS"),
                        accessor = function() return S().gridRows() end,
                        min = 1, max = 6, default = 2,
                    },
                    intSpinItem{
                        text     = _("Grid columns"),
                        key      = K("GRID_COLS"),
                        accessor = function() return S().gridCols() end,
                        min = 1, max = 7, default = 4,
                    },
                    toggleItem{
                        text     = _("Show book title"),
                        key      = K("SHOW_FOLDER_TITLE"),
                        accessor = function() return S().showFolderTitle() end,
                    },
                    titleScaleItem{
                        text         = _("Title text scale"),
                        key          = K("TEXT_SCALE_FOLDER"),
                        accessor     = function() return S().textScaleFolder() end,
                        enabled_func = function() return S().showFolderTitle() end,
                        info         = _("Scales folder / search book titles."),
                    },
                },
            },
        },
    }
end

return M
