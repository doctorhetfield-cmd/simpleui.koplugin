-- main.lua — Simple UI
-- Plugin entry point. Registers the plugin and delegates to specialised modules.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local Dispatcher      = require("dispatcher")

-- Each simpleui module captures its own local translation proxy from sui_i18n.
-- The native package.loaded["gettext"] is never wrapped or replaced, which
-- prevents state-mutation conflicts with other plugins (e.g. zlibrary).
local I18n = require("sui_i18n")
local _    = I18n.translate

local Config       = require("sui_config")
local UI           = require("sui_core")
local Bottombar    = require("sui_bottombar")
local Topbar       = require("sui_topbar")
local QSBar        = require("sui_quicksettings_bar")
local Patches      = require("sui_patches")
local SUISettings  = require("sui_store")

-- ---------------------------------------------------------------------------
-- ReaderStatistics class-table accessor
-- ---------------------------------------------------------------------------
-- KOReader loads plugins via dofile(), not require(), so the statistics plugin
-- is never registered in package.loaded under a predictable key. The path also
-- differs between platforms (Kobo: relative "plugins/…", Linux deb/Android:
-- absolute path under /usr/lib/koreader or the data dir). We try every known
-- strategy in order and cache the result so subsequent calls are free.
local _rs_module_cache  -- nil = not yet resolved, false = not available

local function _requireStatistics()
    if _rs_module_cache ~= nil then return _rs_module_cache or nil end

    -- 1. Check package.loaded for any key containing "statistics.koplugin".
    --    On Kobo the key is "plugins/statistics.koplugin/main"; on other
    --    platforms it may differ, so we scan all loaded modules.
    for key, m in pairs(package.loaded) do
        if type(key) == "string" and key:find("statistics.koplugin", 1, true) then
            _rs_module_cache = m
            return m
        end
    end

    -- 2. Scan package.path for a statistics.koplugin directory and dofile it,
    --    exactly as PluginLoader does. This works on all platforms because
    --    PluginLoader:loadPlugins() already added every plugin root to
    --    package.path before SimpleUI:init() runs.
    for path_entry in package.path:gmatch("[^;]+") do
        -- path_entry looks like "/some/dir/statistics.koplugin/?.lua"
        local plugin_root = path_entry:match("^(.*statistics%.koplugin)/")
        if plugin_root then
            local mainfile = plugin_root .. "/main.lua"
            local ok, m = pcall(dofile, mainfile)
            if ok and m then
                _rs_module_cache = m
                return m
            end
        end
    end

    -- Not available (statistics plugin disabled or not installed).
    _rs_module_cache = false
    return nil
end

local SimpleUIPlugin = WidgetContainer:new{
    name = "simpleui",

    active_action             = nil,
    _rebuild_scheduled        = false,
    _topbar_timer             = nil,
    _power_dialog             = nil,

    _orig_uimanager_show      = nil,
    _orig_uimanager_close     = nil,
    _orig_booklist_new        = nil,
    _orig_menu_new            = nil,
    _orig_menu_init           = nil,
    _orig_fmcoll_show         = nil,
    _orig_rc_remove           = nil,
    _orig_rc_rename           = nil,
    _orig_fc_init             = nil,
    _orig_fm_setup            = nil,

    _makeNavbarMenu           = nil,
    _makeTopbarMenu           = nil,
    _makeQuickActionsMenu     = nil,
    _goalTapCallback          = nil,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:init()
    local ok, err = pcall(function()
        -- Ensure the simpleui settings directory tree exists before any
        -- SUISettings call.  SUISettings is lazy — its LuaSettings store is
        -- opened on first use — but LuaSettings:open() cannot create the
        -- parent directory.  If the directory is missing (fresh install, or
        -- the dir was wiped) the open will succeed but flush() will silently
        -- fail, discarding all writes for the session.
        --
        -- We create all five user-data directories here unconditionally so
        -- that (a) SUISettings can write safely and (b) a fresh install never
        -- needs to wait until the migration block to have a usable directory
        -- structure.  All five lfs.attributes calls are cheap (single stat
        -- syscall each) and lfs.mkdir is only called when the directory is
        -- actually absent, so the common steady-state cost is negligible.
        do
            local ok_ds,  DataStorage = pcall(require, "datastorage")
            local ok_lfs, lfs_early  = pcall(require, "libs/libkoreader-lfs")
            if ok_ds and ok_lfs then
                local base = DataStorage:getSettingsDir() .. "/simpleui"
                for _, sub in ipairs({
                    "", "/sui_icons", "/sui_icons/packs", "/sui_quotes",
                    "/sui_wallpapers", "/sui_presets", "/sui_presets/sui_presets_export", "/sui_presets/sui_presets_import"
                }) do
                    local path = base .. sub
                    if lfs_early.attributes(path, "mode") ~= "directory" then
                        lfs_early.mkdir(path)
                    end
                end
            end
        end

        -- Detect hot update: compare the version now on disk with what was
        -- running last session. If they differ, warn the user to restart so
        -- that all plugin modules are loaded fresh.
        local current_version
        local src = debug.getinfo(1, "S").source or ""
        local p_root = src:match("^@?(.+)/[^/]+$")
        if p_root then
            local ok, meta = pcall(dofile, p_root .. "/_meta.lua")
            if ok and type(meta) == "table" and meta.name == "simpleui" then
                current_version = meta.version
            end
        end
        if not current_version then
            local meta_ok, meta = pcall(require, "_meta")
            if meta_ok and type(meta) == "table" and meta.name == "simpleui" then
                current_version = meta.version
            end
        end
        -- Read version from SUISettings; fall back to G_reader_settings for the
        -- first boot after the Phase-4 migration (before v2 migration has run).
        local prev_version = SUISettings:get("simpleui_loaded_version")
            or G_reader_settings:readSetting("simpleui_loaded_version")
        if current_version then
            if prev_version and prev_version ~= current_version then
                logger.info("simpleui: updated from", prev_version, "to", current_version,
                    "— restart recommended")
                UIManager:scheduleIn(1, function()
                    local InfoMessage = require("ui/widget/infomessage")
                    local _t = require("sui_i18n").translate
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _t("Simple UI was updated (%s → %s).\n\nA restart is recommended to apply all changes cleanly."),
                            prev_version, current_version
                        ),
                        timeout = 6,
                    })
                end)
            end
            SUISettings:set("simpleui_loaded_version", current_version)
        end

        -- -------------------------------------------------------------------
        -- User-data migration (runs once per install / once after upgrade).
        --
        -- v1: move user files out of the plugin folder into DataStorage so
        --     they survive plugin updates, and normalise all settings keys to
        --     the simpleui_ / navbar_ namespace.
        -- -------------------------------------------------------------------
        if not G_reader_settings:isTrue("simpleui_userdata_migrated_v1") then
            pcall(function()
                local ok_ds, DataStorage = pcall(require, "datastorage")
                local ok_lfs, lfs        = pcall(require, "libs/libkoreader-lfs")
                local ok_ffi, ffiutil    = pcall(require, "ffi/util")
                if not (ok_ds and ok_lfs and ok_ffi) then return end

                local data_dir = DataStorage:getSettingsDir() .. "/simpleui"

                -- ── 1. Migrate user files (copy, never overwrite) ─────────
                -- Directory structure is guaranteed by the startup block above.
                -- Resolve plugin root from this file's path.
                local src_info   = debug.getinfo(1, "S").source or ""
                local plugin_root = src_info:sub(1,1) == "@"
                    and src_info:sub(2):match("^(.*)/[^/]+$") or nil
                if plugin_root and plugin_root:sub(1,1) ~= "/" then
                    local ok_lfs2, lfs2 = pcall(require, "libs/libkoreader-lfs")
                    local cwd = ok_lfs2 and lfs2 and lfs2.currentdir()
                    if cwd then plugin_root = cwd .. "/" .. plugin_root end
                end

                if plugin_root then
                    -- Copy files from src/ to dst/ (never overwrite existing).
                    local function copyDirContents(src, dst)
                        if lfs.attributes(src, "mode") ~= "directory" then return end
                        for fname in lfs.dir(src) do
                            if fname ~= "." and fname ~= ".." then
                                local src_f = src .. "/" .. fname
                                local dst_f = dst .. "/" .. fname
                                if lfs.attributes(src_f, "mode") == "file"
                                    and lfs.attributes(dst_f, "mode") ~= "file" then
                                    ffiutil.copyFile(src_f, dst_f)
                                end
                            end
                        end
                    end

                    -- Removes all plain files inside dir, then the dir itself.
                    -- Skips silently if dir doesn't exist or still has subdirs.
                    local function removeDirIfEmpty(dir)
                        if lfs.attributes(dir, "mode") ~= "directory" then return end
                        for fname in lfs.dir(dir) do
                            if fname ~= "." and fname ~= ".." then
                                local p = dir .. "/" .. fname
                                if lfs.attributes(p, "mode") == "file" then
                                    os.remove(p)
                                end
                            end
                        end
                        lfs.rmdir(dir)  -- only succeeds when empty
                    end

                    -- icons/custom → DataStorage/simpleui/sui_icons/
                    -- then remove the now-redundant in-plugin directory.
                    copyDirContents(plugin_root .. "/icons/custom",
                                    data_dir    .. "/sui_icons")
                    removeDirIfEmpty(plugin_root .. "/icons/custom")

                    -- desktop_modules/custom_quotes → DataStorage/simpleui/sui_quotes/
                    -- then remove the now-redundant in-plugin directory.
                    copyDirContents(plugin_root .. "/desktop_modules/custom_quotes",
                                    data_dir    .. "/sui_quotes")
                    removeDirIfEmpty(plugin_root .. "/desktop_modules/custom_quotes")
                end

                -- ── 2. Migrate renamed settings keys ──────────────────────
                -- Each entry: { old_key, new_key }
                local key_renames = {
                    { "sui_tbr_list",             "simpleui_tbr_list"                    },
                    { "quote_deck_order",          "simpleui_quote_deck_order"            },
                    { "quote_deck_pos",            "simpleui_quote_deck_pos"              },
                    { "quote_deck_count",          "simpleui_quote_deck_count"            },
                    { "quote_hl_deck_order",       "simpleui_quote_hl_deck_order"         },
                    { "quote_hl_deck_pos",         "simpleui_quote_hl_deck_pos"           },
                    { "quote_hl_deck_count",       "simpleui_quote_hl_deck_count"         },
                    { "quote_custom_deck_order",   "simpleui_quote_custom_deck_order"     },
                    { "quote_custom_deck_pos",     "simpleui_quote_custom_deck_pos"       },
                    { "quote_custom_deck_count",   "simpleui_quote_custom_deck_count"     },
                    { "quote_custom_deck_file",    "simpleui_quote_custom_deck_file"      },
                    -- quote_source and quote_custom_file are per-instance (prefixed
                    -- with navbar_homescreen_ at runtime); migrate all known slots.
                    { "navbar_homescreen_quote_source",      "navbar_homescreen_simpleui_quote_source"      },
                    { "navbar_homescreen_quote_custom_file", "navbar_homescreen_simpleui_quote_custom_file" },
                }
                for _, pair in ipairs(key_renames) do
                    local old_key, new_key = pair[1], pair[2]
                    local val = G_reader_settings:readSetting(old_key)
                    if val ~= nil and G_reader_settings:readSetting(new_key) == nil then
                        G_reader_settings:saveSetting(new_key, val)
                    end
                    G_reader_settings:delSetting(old_key)
                end

                logger.info("simpleui: userdata migration v1 complete")
            end)
            G_reader_settings:saveSetting("simpleui_userdata_migrated_v1", true)
        end
        -- -------------------------------------------------------------------
        -- Settings migration v2: move all navbar_* and simpleui_* keys from
        -- G_reader_settings into SUISettings (the dedicated per-plugin store).
        --
        -- This runs once on first boot after the Phase-3 refactor.  It is safe
        -- to re-run if interrupted: keys that already exist in SUISettings are
        -- not overwritten; keys successfully copied are removed from
        -- G_reader_settings.
        -- -------------------------------------------------------------------
        if not SUISettings:isTrue("simpleui_settings_migrated_v2") then
            pcall(function()
                -- Enumerate every key currently stored in G_reader_settings
                -- and migrate the ones owned by SimpleUI.
                local raw = G_reader_settings.data  -- LuaSettings exposes .data
                if type(raw) ~= "table" then return end

                -- Collect owned keys first; deleting from raw while iterating
                -- it with pairs() has undefined behaviour in Lua and can cause
                -- entries to be skipped.
                local to_migrate = {}
                for k, v in pairs(raw) do
                    local owned = (type(k) == "string")
                        and (k:sub(1, 7) == "navbar_" or k:sub(1, 9) == "simpleui_")
                        -- Keep the v1 and v2 migration flags in G_reader_settings
                        -- so they survive a factory reset of sui_settings.lua.
                        and k ~= "simpleui_userdata_migrated_v1"
                    if owned then
                        to_migrate[#to_migrate + 1] = { k = k, v = v }
                    end
                end

                local migrated = 0
                for _, entry in ipairs(to_migrate) do
                    local k, v = entry.k, entry.v
                    -- Only copy if SUISettings does not already have the key
                    -- (e.g. the user already made changes after the code update).
                    if SUISettings:get(k) == nil then
                        SUISettings:set(k, v)
                    end
                    G_reader_settings:delSetting(k)
                    migrated = migrated + 1
                end

                SUISettings:flush()
                logger.info("simpleui: settings migration v2 complete —", migrated, "keys moved to SUISettings")
            end)
            SUISettings:set("simpleui_settings_migrated_v2", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------
        -- Settings migration v3: rename all navbar_* keys inside SUISettings
        -- to the canonical simpleui_* namespace.
        --
        -- Two passes:
        --   1. Fixed renames  — explicit old → new map (fast, readable).
        --   2. Dynamic prefix — bulk rename of per-slot / per-id keys that are
        --      built at runtime via string concatenation.
        --
        -- Rules:
        --   • Only copies when the destination key is absent (never overwrites).
        --   • Old key is always deleted, even when the copy is skipped.
        --   • The whole block runs inside pcall — a crash must never prevent
        --     the plugin from loading on a resource-constrained e-reader.
        --   • Guarded by simpleui_settings_migrated_v3 so it runs at most once.
        -- -------------------------------------------------------------------
        if not SUISettings:isTrue("simpleui_settings_migrated_v3") then
            pcall(function()
                -- ── 1. Fixed renames ─────────────────────────────────────────
                local fixed_renames = {
                    -- Bottom bar — general
                    { "navbar_enabled",                      "simpleui_bar_enabled"                   },
                    { "navbar_mode",                         "simpleui_bar_mode"                      },
                    { "navbar_bar_size",                     "simpleui_bar_size"                      },
                    { "navbar_bar_size_pct",                 "simpleui_bar_size_pct"                  },
                    { "navbar_hide_separator",               "simpleui_bar_hide_separator"            },
                    { "navbar_bottom_margin_pct",            "simpleui_bar_bottom_margin_pct"         },
                    { "navbar_icon_scale_pct",               "simpleui_bar_icon_scale_pct"            },
                    { "navbar_label_scale_pct",              "simpleui_bar_label_scale_pct"           },
                    { "navbar_rs_text_scale_pct",            "simpleui_bar_rs_text_scale_pct"         },
                    -- Bottom bar — pagination / pager
                    { "navbar_pagination_visible",           "simpleui_bar_pagination_visible"        },
                    { "navbar_pagination_size",              "simpleui_bar_pagination_size"           },
                    { "navbar_pagination_show_subtitle",     "simpleui_bar_pagination_show_subtitle"  },
                    { "navbar_navpager_enabled",             "simpleui_bar_navpager_enabled"          },
                    { "navbar_dotpager_always",              "simpleui_bar_dotpager_always"           },
                    -- Bottom bar — tabs & settings
                    { "navbar_tabs",                         "simpleui_bar_tabs"                      },
                    { "navbar_bottombar_settings_on_hold",   "simpleui_bar_settings_on_hold"          },
                    -- Top bar
                    { "navbar_topbar_enabled",               "simpleui_topbar_enabled"                },
                    { "navbar_topbar_config",                "simpleui_topbar_config"                 },
                    { "navbar_topbar_custom_text",           "simpleui_topbar_custom_text"            },
                    { "navbar_topbar_settings_on_hold",      "simpleui_topbar_settings_on_hold"       },
                    { "navbar_topbar_swipe_indicator",       "simpleui_topbar_swipe_indicator"        },
                    { "navbar_topbar_wifi_hide_when_off",    "simpleui_topbar_wifi_hide_when_off"     },
                    { "navbar_topbar_size_pct",              "simpleui_topbar_size_pct"               },
                    -- Homescreen bar — fixed keys
                    { "navbar_homescreen_pagination_hidden", "simpleui_hs_pagination_hidden"          },
                    { "navbar_homescreen_settings_on_hold",  "simpleui_hs_settings_on_hold"           },
                    { "navbar_homescreen_overflow_warn",     "simpleui_hs_overflow_warn"              },
                    { "navbar_hs_return_to_book_folder",     "simpleui_hs_return_to_book_folder"      },
                    { "navbar_homescreen_module_scale",      "simpleui_hs_module_scale"               },
                    { "navbar_homescreen_label_scale",       "simpleui_hs_label_scale"                },
                    { "navbar_homescreen_scale_linked",      "simpleui_hs_scale_linked"               },
                    -- Reading goal
                    { "navbar_reading_goal",                 "simpleui_reading_goal"                  },
                    { "navbar_reading_goal_physical",        "simpleui_reading_goal_physical"         },
                    { "navbar_daily_reading_goal_secs",      "simpleui_daily_reading_goal_secs"       },
                    -- Reading goals module display
                    { "navbar_reading_goals_show_annual",    "simpleui_reading_goals_show_annual"     },
                    { "navbar_reading_goals_show_daily",     "simpleui_reading_goals_show_daily"      },
                    { "navbar_reading_goals_layout",         "simpleui_reading_goals_layout"          },
                    -- Collections module
                    { "navbar_collections_list",             "simpleui_collections_list"              },
                    { "navbar_collections_covers",           "simpleui_collections_covers"            },
                    { "navbar_collections_badge_position",   "simpleui_collections_badge_position"    },
                    { "navbar_collections_badge_color",      "simpleui_collections_badge_color"       },
                    { "navbar_collections_badge_hidden",     "simpleui_collections_badge_hidden"      },
                    -- Custom quick actions — list & migration flag
                    { "navbar_custom_qa_list",               "simpleui_cqa_list"                      },
                    { "navbar_custom_qa_migrated_v1",        "simpleui_cqa_migrated_v1"               },
                }

                local migrated = 0

                for _, pair in ipairs(fixed_renames) do
                    local old_k, new_k = pair[1], pair[2]
                    local val = SUISettings:get(old_k)
                    if val ~= nil then
                        if SUISettings:get(new_k) == nil then
                            SUISettings:set(new_k, val)
                        end
                        SUISettings:del(old_k)
                        migrated = migrated + 1
                    end
                end

                -- ── 2. Dynamic-prefix renames ─────────────────────────────────
                -- Keys built at runtime via string concatenation:
                --   simpleui_hs_*        (was navbar_homescreen_*)
                --   navbar_cqa_*         →  simpleui_cqa_*
                --   navbar_action_*      →  simpleui_action_*
                --   navbar_custom_*      →  simpleui_custom_*
                --
                -- We collect all renames first, then apply — modifying a table
                -- while iterating it is undefined behaviour in Lua 5.1/5.2.
                local dynamic_prefixes = {
                    { old = "navbar_homescreen_",  new = "simpleui_hs_"     },
                    { old = "navbar_cqa_",         new = "simpleui_cqa_"    },
                    { old = "navbar_action_",      new = "simpleui_action_" },
                    { old = "navbar_custom_",      new = "simpleui_custom_" },
                }

                local pending = {}
                for k, v in SUISettings:iterateKeys() do
                    for _, pfx in ipairs(dynamic_prefixes) do
                        local plen = #pfx.old
                        if k:sub(1, plen) == pfx.old then
                            local new_k = pfx.new .. k:sub(plen + 1)
                            pending[#pending + 1] = { old_k = k, new_k = new_k, val = v }
                            break
                        end
                    end
                end

                for _, entry in ipairs(pending) do
                    if SUISettings:get(entry.new_k) == nil then
                        SUISettings:set(entry.new_k, entry.val)
                    end
                    SUISettings:del(entry.old_k)
                    migrated = migrated + 1
                end

                SUISettings:flush()
                logger.info("simpleui: settings migration v3 complete —", migrated, "navbar_* keys renamed to simpleui_*")
            end)
            SUISettings:set("simpleui_settings_migrated_v3", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------
        -- Settings migration v4: rename icon pack keys to integrated sui_ scheme.
        -- -------------------------------------------------------------------
        if not SUISettings:isTrue("simpleui_settings_migrated_v4") then
            pcall(function()
                local icon_renames = {
                    { "simpleui_sysicon_bm_normal",     "simpleui_sysicon_sui_browse_normal" },
                    { "simpleui_sysicon_bm_author",     "simpleui_sysicon_sui_browse_author" },
                    { "simpleui_sysicon_bm_series",     "simpleui_sysicon_sui_browse_series" },
                    { "simpleui_sysicon_bm_tags",       "simpleui_sysicon_sui_browse_tags" },
                    { "simpleui_sysicon_pg_chev_left",  "simpleui_sysicon_sui_pager_prev" },
                    { "simpleui_sysicon_pg_chev_right", "simpleui_sysicon_sui_pager_next" },
                    { "simpleui_sysicon_pg_chev_first", "simpleui_sysicon_sui_pager_first" },
                    { "simpleui_sysicon_pg_chev_last",  "simpleui_sysicon_sui_pager_last" },
                    { "simpleui_sysicon_coll_back",     "simpleui_sysicon_sui_coll_back" },
                }
                local migrated = 0
                for _, pair in ipairs(icon_renames) do
                    local old_k, new_k = pair[1], pair[2]
                    local val = SUISettings:get(old_k)
                    if val ~= nil then
                        if SUISettings:get(new_k) == nil then
                            SUISettings:set(new_k, val)
                        end
                        SUISettings:del(old_k)
                        migrated = migrated + 1
                    end
                end
                local icon_presets = SUISettings:get("simpleui_icon_presets")
                if type(icon_presets) == "table" then
                    local changed = false
                    for _, preset in pairs(icon_presets) do
                        if type(preset._scalar) == "table" then
                            for _, pair in ipairs(icon_renames) do
                                local old_k, new_k = pair[1], pair[2]
                                if preset._scalar[old_k] ~= nil then
                                    if preset._scalar[new_k] == nil then
                                        preset._scalar[new_k] = preset._scalar[old_k]
                                    end
                                    preset._scalar[old_k] = nil
                                    changed = true
                                end
                            end
                        end
                    end
                    if changed then SUISettings:set("simpleui_icon_presets", icon_presets) end
                end
                SUISettings:flush()
                logger.info("simpleui: settings migration v4 complete —", migrated, "icon keys renamed")
            end)
            SUISettings:set("simpleui_settings_migrated_v4", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------
        -- Settings migration v5: standardize titlebar button nomenclature
        -- -------------------------------------------------------------------
        if not SUISettings:isTrue("simpleui_settings_migrated_v5") then
            pcall(function()
                local renames = {
                    { "simpleui_tb_item_menu_button",     "simpleui_tb_item_fm_menu" },
                    { "simpleui_tb_item_up_button",       "simpleui_tb_item_fm_back" },
                    { "simpleui_tb_item_search_button",   "simpleui_tb_item_fm_search" },
                    { "simpleui_tb_item_browse_button",   "simpleui_tb_item_fm_browse" },
                    { "simpleui_tb_item_title",           "simpleui_tb_item_fm_title" },
                    { "simpleui_tb_item_inj_back",        "simpleui_tb_item_sub_menu" },
                    { "simpleui_tb_item_inj_right",       "simpleui_tb_item_sub_close" },
                    { "simpleui_tb_item_inj_menubutton",  "simpleui_tb_item_sub_menu" },
                    { "simpleui_tb_item_inj_closebutton", "simpleui_tb_item_sub_close" },
                    { "simpleui_tb_inj_cfg",              "simpleui_tb_sub_cfg" },
                }
                local migrated = 0
                for _, pair in ipairs(renames) do
                    local old_k, new_k = pair[1], pair[2]
                    local val = SUISettings:get(old_k)
                    if val ~= nil then
                        if SUISettings:get(new_k) == nil then
                            SUISettings:set(new_k, val)
                        end
                        SUISettings:del(old_k)
                        migrated = migrated + 1
                    end
                end

                local function map_cfg(cfg_key, mapping)
                    local cfg = SUISettings:get(cfg_key)
                    if type(cfg) == "table" then
                        local changed = false
                        local function map_arr(arr)
                            for i, v in ipairs(arr) do
                                if mapping[v] then arr[i] = mapping[v]; changed = true end
                            end
                        end
                        if type(cfg.side) == "table" then
                            for old_btn, new_btn in pairs(mapping) do
                                if cfg.side[old_btn] ~= nil then
                                    cfg.side[new_btn] = cfg.side[old_btn]
                                    cfg.side[old_btn] = nil
                                    changed = true
                                end
                            end
                        end
                        if type(cfg.order_left) == "table" then map_arr(cfg.order_left) end
                        if type(cfg.order_right) == "table" then map_arr(cfg.order_right) end
                        if changed then
                            SUISettings:set(cfg_key, cfg)
                            migrated = migrated + 1
                        end
                    end
                end

                local fm_map = {
                    menu_button   = "fm_menu",
                    up_button     = "fm_back",
                    search_button = "fm_search",
                    browse_button = "fm_browse",
                    title         = "fm_title"
                }
                local sub_map = {
                    inj_back         = "sub_menu",
                    inj_right        = "sub_close",
                    inj_menubutton   = "sub_menu",
                    inj_closebutton  = "sub_close"
                }
                map_cfg("simpleui_tb_fm_cfg", fm_map)
                map_cfg("simpleui_tb_sub_cfg", sub_map)

                logger.info("simpleui: settings migration v5 complete —", migrated, "titlebar keys renamed")
            end)
            SUISettings:set("simpleui_settings_migrated_v5", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------
        -- Settings migration v6: namespace clean-up and key standardisation.
        --
        -- Changes applied:
        --   1. Module enabled_key unification — bare module IDs (e.g. "currently",
        --      "recent", "coverdeck", "tbr", "new_books", "collections",
        --      "reading_goals") gain an explicit "_enabled" suffix to match the
        --      convention already used by clock, reading_stats, action_list, etc.
        --
        --   2. module_coverdeck "flow_" prefix → "coverdeck_" prefix — the old
        --      keys had no "simpleui_" namespace and risked collisions in the
        --      shared G_reader_settings / SUISettings store.
        --
        --   3. simpleui_cqa_* → simpleui_qa_* — "cqa" was undocumented jargon;
        --      "qa" matches the term used throughout the UI.  Also covers the
        --      per-slot dynamic keys simpleui_cqa_{id} → simpleui_qa_{id}.
        --
        --   4. simpleui_collections_* → simpleui_coll_* — shorter, consistent
        --      with the "fc_" brevity used by foldercovers.
        --
        --   5. simpleui_titlebar_custom → simpleui_tb_custom — aligns with the
        --      tb_ alias used by all other titlebar keys.
        --
        --   6. simpleui_tb_size → simpleui_tb_size_pct — consistent with the
        --      other size percentage keys (_bar_size_pct, _topbar_size_pct).
        --
        --   7. simpleui_bar_size (legacy enum "default"|"large") removed — this
        --      key was only written by first-run defaults v1 and was never read
        --      by any code path; the canonical value is simpleui_bar_size_pct.
        --
        -- Rules (identical to all previous migrations):
        --   • Copy only when destination key is absent (never overwrite).
        --   • Always delete the source key, even when copy is skipped.
        --   • Whole block in pcall — a crash must not prevent plugin load.
        --   • Guarded by simpleui_settings_migrated_v6.
        -- -------------------------------------------------------------------
        if not SUISettings:isTrue("simpleui_settings_migrated_v6") then
            pcall(function()
                local migrated = 0

                -- ── Helper: rename a single key ───────────────────────────
                local function _rename(old_k, new_k)
                    local val = SUISettings:get(old_k)
                    if val ~= nil then
                        if SUISettings:get(new_k) == nil then
                            SUISettings:set(new_k, val)
                        end
                        SUISettings:del(old_k)
                        migrated = migrated + 1
                    end
                end

                -- ── 1. Module enabled_key: add _enabled suffix ────────────
                -- For each preset prefix that exists in SUISettings, rename
                -- the bare module-id keys to module-id_enabled.
                -- The only guaranteed preset prefix is "simpleui_hs_" but
                -- user presets can have arbitrary prefixes — we scan all keys.
                local bare_mods = {
                    "currently", "recent", "coverdeck",
                    "tbr", "new_books", "collections", "reading_goals",
                }
                -- Collect all unique prefixes that have at least one of the
                -- bare keys so we don't have to hardcode "simpleui_hs_".
                local prefixes_seen = {}
                for k, _ in SUISettings:iterateKeys() do
                    if type(k) == "string" then
                        for _, mod_id in ipairs(bare_mods) do
                            -- key must end exactly with the bare mod_id
                            -- (no trailing chars) to avoid false matches
                            local sfx = mod_id
                            local klen, slen = #k, #sfx
                            if klen > slen and k:sub(klen - slen + 1) == sfx
                                    and k:sub(klen - slen) == "_" then
                                local pfx = k:sub(1, klen - slen)
                                prefixes_seen[pfx] = true
                            end
                        end
                    end
                end
                for pfx in pairs(prefixes_seen) do
                    for _, mod_id in ipairs(bare_mods) do
                        _rename(pfx .. mod_id, pfx .. mod_id .. "_enabled")
                    end
                end

                -- ── 2. module_coverdeck: flow_ → coverdeck_ ───────────────
                -- These keys are prefixed with a homescreen preset prefix
                -- (e.g. "simpleui_hs_") at runtime, so we scan all keys.
                local flow_suffixes = {
                    "flow_recent_source",
                    "flow_stats_order",
                    -- flow_show_{elem} keys are boolean per-element toggles;
                    -- we catch them with the dynamic scan below.
                }
                local flow_pending = {}
                for k, v in SUISettings:iterateKeys() do
                    if type(k) == "string" then
                        -- Fixed suffixes
                        for _, sfx in ipairs(flow_suffixes) do
                            if k:sub(- #sfx) == sfx then
                                local pfx = k:sub(1, #k - #sfx)
                                local new_sfx = sfx
                                    :gsub("^flow_recent_source$", "coverdeck_source")
                                    :gsub("^flow_stats_order$",   "coverdeck_stats_order")
                                flow_pending[#flow_pending + 1] = {
                                    old_k = k, new_k = pfx .. new_sfx, val = v
                                }
                                break
                            end
                        end
                        -- Dynamic: flow_show_{anything} → coverdeck_show_{anything}
                        local tail = k:match("_flow_show_(.+)$")
                        if tail then
                            local pfx = k:sub(1, #k - #("flow_show_" .. tail))
                            flow_pending[#flow_pending + 1] = {
                                old_k = k,
                                new_k = pfx .. "coverdeck_show_" .. tail,
                                val   = v,
                            }
                        end
                    end
                end
                for _, e in ipairs(flow_pending) do
                    if SUISettings:get(e.new_k) == nil then
                        SUISettings:set(e.new_k, e.val)
                    end
                    SUISettings:del(e.old_k)
                    migrated = migrated + 1
                end

                -- ── 3. simpleui_cqa_* → simpleui_qa_* ────────────────────
                -- Covers: simpleui_cqa_list, simpleui_cqa_migrated_v1,
                --         simpleui_cqa_custom_qa_{n}, simpleui_cqa_{id}
                -- The migration-v3 target was "simpleui_cqa_*"; we now move
                -- those to "simpleui_qa_*".
                local cqa_pending = {}
                for k, v in SUISettings:iterateKeys() do
                    if type(k) == "string" and k:sub(1, 13) == "simpleui_cqa_" then
                        cqa_pending[#cqa_pending + 1] = {
                            old_k = k,
                            new_k = "simpleui_qa_" .. k:sub(14),
                            val   = v,
                        }
                    end
                end
                for _, e in ipairs(cqa_pending) do
                    if SUISettings:get(e.new_k) == nil then
                        SUISettings:set(e.new_k, e.val)
                    end
                    SUISettings:del(e.old_k)
                    migrated = migrated + 1
                end
                -- Also fix the migration guard written by migrateOldCustomSlots.
                _rename("simpleui_cqa_migrated_v1", "simpleui_qa_migrated_v1")

                -- ── 4. simpleui_collections_* → simpleui_coll_* ──────────
                local coll_renames = {
                    { "simpleui_collections_list",           "simpleui_coll_list"           },
                    { "simpleui_collections_covers",         "simpleui_coll_covers"         },
                    { "simpleui_collections_badge_position", "simpleui_coll_badge_position" },
                    { "simpleui_collections_badge_color",    "simpleui_coll_badge_color"    },
                    { "simpleui_collections_badge_hidden",   "simpleui_coll_badge_hidden"   },
                }
                for _, pair in ipairs(coll_renames) do
                    _rename(pair[1], pair[2])
                end

                -- ── 5. simpleui_titlebar_custom → simpleui_tb_custom ──────
                _rename("simpleui_titlebar_custom", "simpleui_tb_custom")

                -- ── 6. simpleui_tb_size → simpleui_tb_size_pct ───────────
                _rename("simpleui_tb_size", "simpleui_tb_size_pct")

                -- ── 7. Remove legacy simpleui_bar_size enum ───────────────
                -- Never read by any code; only written by first-run defaults v1.
                -- The canonical value is simpleui_bar_size_pct.
                SUISettings:del("simpleui_bar_size")

                SUISettings:flush()
                logger.info("simpleui: settings migration v6 complete —", migrated, "keys renamed/removed")
            end)
            SUISettings:set("simpleui_settings_migrated_v6", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------

        -- Settings migration v7:
        -- 1. Restore coverdeck_show_title when written as false by the
        --    "Momentum" preset but never explicitly toggled by the user.
        --    Detects the exact Momentum signature (title=false, author=false,
        --    progress=true, percent=true, book_days=true) and resets to true.
        -- 2. Enable recent_show_finished when it has never been set, so users
        --    upgrading from 1.5.x (where the filter did not exist) don't find
        --    Recent Books / Cover Deck empty because all their books are at 100%.
        -- 3. Enable the automatic update check when it has never been set,
        --    making auto-check opt-out instead of opt-in.
        if not SUISettings:isTrue("simpleui_settings_migrated_v7") then
            pcall(function()
                local PFX       = "simpleui_hs_"
                -- 1. coverdeck_show_title
                local title     = SUISettings:get(PFX .. "coverdeck_show_title")
                local author    = SUISettings:get(PFX .. "coverdeck_show_author")
                local progress  = SUISettings:get(PFX .. "coverdeck_show_progress")
                local percent   = SUISettings:get(PFX .. "coverdeck_show_percent")
                local book_days = SUISettings:get(PFX .. "coverdeck_show_book_days")
                if title == false and author == false
                        and progress == true and percent == true
                        and book_days == true then
                    SUISettings:set(PFX .. "coverdeck_show_title", true)
                    logger.info("simpleui: migration v7 — restored coverdeck_show_title to true")
                end
                -- 2. recent_show_finished
                if SUISettings:get(PFX .. "recent_show_finished") == nil then
                    SUISettings:set(PFX .. "recent_show_finished", true)
                    logger.info("simpleui: migration v7 — enabled recent_show_finished")
                end
                -- 3. auto update check
                if SUISettings:get("simpleui_updater_auto_check") == nil then
                    SUISettings:set("simpleui_updater_auto_check", true)
                    logger.info("simpleui: migration v7 — enabled simpleui_updater_auto_check")
                end
            end)
            SUISettings:set("simpleui_settings_migrated_v7", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------

        -- Settings migration v8:
        -- Introduces the unified Cover Deck arrange list (coverdeck_main_order),
        -- replacing the old coverdeck_title_pos above/below/hidden radio and
        -- the separate "Show status bar" toggle for the progress bar.
        --   1. Legacy title_pos == "hidden" had no dedicated key of its own;
        --      fold it into coverdeck_show_title so upgrading users keep the
        --      title hidden instead of it reappearing under the new model.
        --   2. coverdeck_main_order is seeded from title_pos ("above"/"below")
        --      so existing layouts render identically the first time they're
        --      opened under the new arrange list, instead of silently
        --      reverting to the "below" default.
        if not SUISettings:isTrue("simpleui_settings_migrated_v8") then
            pcall(function()
                local PFX       = "simpleui_hs_"
                local title_pos = SUISettings:get(PFX .. "coverdeck_title_pos")
                if title_pos == "hidden" and SUISettings:get(PFX .. "coverdeck_show_title") == nil then
                    SUISettings:set(PFX .. "coverdeck_show_title", false)
                    logger.info("simpleui: migration v8 — folded coverdeck_title_pos=hidden into coverdeck_show_title=false")
                end
                if SUISettings:get(PFX .. "coverdeck_main_order") == nil then
                    local order = (title_pos == "above")
                        and { "title", "author", "covers", "progress", "stats" }
                        or  { "covers", "title", "author", "progress", "stats" }
                    SUISettings:set(PFX .. "coverdeck_main_order", order)
                    logger.info("simpleui: migration v8 — seeded coverdeck_main_order from legacy title_pos")
                end
            end)
            SUISettings:set("simpleui_settings_migrated_v8", true)
            SUISettings:flush()
        end
        -- -------------------------------------------------------------------

        Config.applyFirstRunDefaults()
        Config.migrateOldCustomSlots()
        -- Always run sanitizeQASlots: it cleans both custom QA slot references
        -- and any stale built-in IDs from navbar_tabs.  The function is cheap —
        -- it reads a handful of settings and only writes back when it finds
        -- something invalid, so the common no-op case costs only a few reads.
        Config.sanitizeQASlots()
        -- Apply the saved UI font preference early, before any widget is built.
        -- SUIStyle is lazy (module-level init runs only when the font menu opens)
        -- so this pcall is cheap on the common path where no custom font is set.
        do
            local ok_ss, SUIStyle = pcall(require, "sui_style")
            if ok_ss and SUIStyle and SUIStyle.applyUIFont then
                pcall(SUIStyle.applyUIFont)
            end
        end
        self.ui.menu:registerToMainMenu(self)

        -- Register gesture-assignable actions via Dispatcher.
        -- After this, KOReader's gesture/keyboard settings will list these
        -- actions so the user can bind any gesture to them.
        Dispatcher:init()
        Dispatcher:registerAction("simpleui_go_homescreen", {
            category = "none",
            event    = "SimpleUIGoHomescreen",
            title    = _("Simple UI: Go to Homescreen"),
            general  = true,
        })
        Dispatcher:registerAction("simpleui_go_library", {
            category = "none",
            event    = "SimpleUIGoLibrary",
            title    = _("Simple UI: Go to Library"),
            general  = true,
        })
        Dispatcher:registerAction("simpleui_toggle_home_library", {
            category = "none",
            event    = "SimpleUIToggleHomeLibrary",
            title    = _("Simple UI: Toggle Homescreen / Library"),
            general  = true,
        })
    Dispatcher:registerAction("simpleui_settings_window", {
        category = "none",
        event    = "SimpleUISettingsWindow",
        title    = _("Simple UI: Settings"),
        general  = true,
    })


        -- -------------------------------------------------------------------
        -- First-run bootstrap: ensure "Start with Homescreen" is active.
        --
        -- On a fresh install simpleui_onboarding_done is nil and start_with
        -- has never been set to "homescreen_simpleui", so isStartWithHS()
        -- would return false and the FM would open directly, bypassing the
        -- homescreen entirely — meaning the onboarding window (which is
        -- triggered inside Homescreen.show()) would never appear either.
        --
        -- Fix: write start_with HERE, before Patches.installAll, so that
        -- isStartWithHS() (lazily cached on first read in sui_patches.lua)
        -- already sees the correct value when the setupLayout patch runs and
        -- sets _hs_autoopen_pending = true.  From that point on, the normal
        -- onShow → Homescreen.show() → Onboarding.show() chain handles
        -- everything — no additional scheduling needed here.
        -- -------------------------------------------------------------------
        local _sui_first_run = not SUISettings:get("simpleui_onboarding_done")
        if _sui_first_run then
            G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
        end

        if SUISettings:nilOrTrue("simpleui_enabled") then
            Patches.installAll(self)
            
            pcall(function() QSBar.install() end)
            -- Register the TBR button in the Library hold dialog (single book).
            -- addFileDialogButtons is the official KOReader API for this.
            -- The multi-selection button is injected via patchGetPlusDialogButtons
            -- in sui_patches.lua → patchFileManagerClass.
            UIManager:scheduleIn(0, function()
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm and FM and FM.instance) then return end
                local ok_tbr, TBR = pcall(require, "desktop_modules/module_tbr")
                if not (ok_tbr and TBR) then return end

                -- Shared button factory: generates the TBR button for a given file.
                -- Used by both FM's showFileDialog (library browser) and
                -- FileSearcher's onMenuHold (search results), so both surfaces
                -- show the same "Add to To Be Read" option on long-press.
                local function _makeTBRRow(file, is_file, _book_props, close_refresh_fn)
                    if not is_file then return nil end
                    local ok_dr, DR = pcall(require, "document/documentregistry")
                    local ok_bl, BL = pcall(require, "ui/widget/booklist")
                    local is_book = (ok_dr and DR and DR:hasProvider(file))
                        or (ok_bl and BL and BL.hasBookBeenOpened(file))
                    if not is_book then return nil end
                    return { TBR.genTBRButton(file, close_refresh_fn) }
                end

                -- 1. Library browser (FileManager.showFileDialog).
                -- After toggling TBR, close the dialog and refresh the file list,
                -- matching the same behaviour as "On Hold", "Reading", etc.
                -- Note: file_dialog is a property of file_chooser, not FM.instance.
                FM.instance:addFileDialogButtons("sui_tbr", function(file, is_file, book_props)
                    local close_refresh = function()
                        local fc = FM.instance and FM.instance.file_chooser
                        local dlg = fc and fc.file_dialog
                        if dlg then UIManager:close(dlg) end
                        if fc then fc:refreshPath() end
                    end
                    return _makeTBRRow(file, is_file, book_props, close_refresh)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                --
                -- The problem: file_dialog_added_buttons row_funcs are called as
                --   row_func(file, is_file, book_props)
                -- with no reference to the dialog being built.  In the library
                -- this is fine because close_refresh captures file_chooser by
                -- closure.  In FileSearcher, self.file_dialog (the ButtonDialog)
                -- is owned by booklist_menu — the `self` inside onMenuHold — and
                -- that object is not reachable from a plain row_func closure.
                --
                -- Solution: monkey-patch FileSearcher.onMenuHold to wrap each
                -- added row_func with a closure that captures `self` (booklist_menu)
                -- and therefore can close `self.file_dialog` correctly, exactly
                -- mirroring what close_dialog_callback does natively.
                local ok_fs, FS = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs and FS and not FS._sui_onMenuHold_patched then
                    FS._sui_onMenuHold_patched = true
                    local orig_onMenuHold = FS.onMenuHold
                    FS.onMenuHold = function(menu_self, item)
                        -- Wrap every added row_func so it receives a close_cb
                        -- that closes menu_self.file_dialog — same as the native
                        -- close_dialog_callback defined inside orig_onMenuHold.
                        local manager = menu_self._manager
                        local orig_added = manager and manager.file_dialog_added_buttons
                        local wrapped
                        if orig_added then
                            wrapped = { index = orig_added.index }
                            for i, row_func in ipairs(orig_added) do
                                wrapped[i] = function(file, is_file, book_props)
                                    -- close_cb matches native close_dialog_callback:
                                    -- UIManager:close(self.file_dialog) where self
                                    -- is menu_self (the booklist_menu widget).
                                    local close_cb = function()
                                        UIManager:close(menu_self.file_dialog)
                                    end
                                    -- row_func signature: (file, is_file, book_props, close_cb)
                                    -- _makeTBRRow uses the 4th arg as its close_refresh_fn.
                                    return row_func(file, is_file, book_props, close_cb)
                                end
                            end
                            manager.file_dialog_added_buttons = wrapped
                        end
                        local result = orig_onMenuHold(menu_self, item)
                        -- Restore the original table so the next call gets
                        -- unmodified row_funcs (not double-wrapped).
                        if orig_added and manager then
                            manager.file_dialog_added_buttons = orig_added
                        end
                        return result
                    end

                    -- Register the TBR row_func on the FileSearcher class.
                    -- Note: row_func here accepts an optional 4th arg (close_cb)
                    -- injected by the patched onMenuHold above.
                    FS.file_dialog_added_buttons = FS.file_dialog_added_buttons or { index = {} }
                    if FS.file_dialog_added_buttons.index["sui_tbr"] == nil then
                        local row_func = function(file, is_file, book_props, close_cb)
                            return _makeTBRRow(file, is_file, book_props, close_cb)
                        end
                        table.insert(FS.file_dialog_added_buttons, row_func)
                        FS.file_dialog_added_buttons.index["sui_tbr"] =
                            #FS.file_dialog_added_buttons
                    end
                end
            end)

            -- Register the "More by <Author>" button in the Library hold dialog.
            -- Shown only when:
            --   • the item is a book file
            --   • Browse by Author/Series/Tags (BM) is enabled
            --   • the book has author metadata
            --   • there are ≥ 2 books by that author in the current folder tree
            -- Tapping the button closes the dialog and navigates the FM directly
            -- to the virtual author leaf, skipping the top-level Authors list.
            UIManager:scheduleIn(0, function()
                local ok_fm2, FM2 = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm2 and FM2 and FM2.instance) then return end
                local ok_bm, BM = pcall(require, "sui_browsemeta")
                if not (ok_bm and BM) then return end

                -- Shared factory: returns a button row or nil.
                -- close_cb is injected by the caller (FM dialog or FS patch).
                local function _makeAuthorRow(file, is_file, book_props, close_cb)
                    if not is_file then return nil end
                    if not BM.isEnabled() then return nil end

                    local authors_raw = book_props and book_props.authors
                    if not authors_raw or authors_raw == "" then return nil end
                    -- Multi-author: newline-delimited.  Navigate to the first
                    -- author only; a picker would be over-engineering for v1.
                    local author = authors_raw:match("^([^\n]+)") or authors_raw
                    author = author:match("^%s*(.-)%s*$") -- trim whitespace

                    local fc2 = FM2.instance and FM2.instance.file_chooser
                    local count = BM.getAuthorBookCount(fc2, author)
                    if count < 2 then return nil end

                    return {{
                        text = string.format(_("More by %s (%d)"), author, count),
                        callback = function()
                            if close_cb then close_cb() end
                            local fm2 = FM2.instance
                            if fm2 then BM.navigateToAuthorLeaf(fm2, author, file) end
                        end,
                    }}
                end

                -- 1. Library browser (FileManager.showFileDialog).
                FM2.instance:addFileDialogButtons("sui_browse_author", function(file, is_file, book_props)
                    local close_nav = function()
                        local fc2 = FM2.instance and FM2.instance.file_chooser
                        local dlg = fc2 and fc2.file_dialog
                        if dlg then UIManager:close(dlg) end
                    end
                    return _makeAuthorRow(file, is_file, book_props, close_nav)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                -- The existing TBR monkey-patch on FS.onMenuHold already wraps
                -- every row_func with a close_cb as the 4th argument, so our
                -- factory receives it without any further patching needed.
                local ok_fs2, FS2 = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs2 and FS2 then
                    FS2.file_dialog_added_buttons = FS2.file_dialog_added_buttons or { index = {} }
                    if FS2.file_dialog_added_buttons.index["sui_browse_author"] == nil then
                        local row_func = function(file, is_file, book_props, close_cb)
                            return _makeAuthorRow(file, is_file, book_props, close_cb)
                        end
                        table.insert(FS2.file_dialog_added_buttons, row_func)
                        FS2.file_dialog_added_buttons.index["sui_browse_author"] =
                            #FS2.file_dialog_added_buttons
                    end
                end
            end)

            -- Register the "Book statistics" button in the Library hold dialog.
            -- Shown only for book files; opens a standalone per-book stats window.
            UIManager:scheduleIn(0, function()
                local ok_fm3, FM3 = pcall(require, "apps/filemanager/filemanager")
                if not (ok_fm3 and FM3 and FM3.instance) then return end

                local function _makeBookStatsRow(file, is_file, _book_props, close_cb)
                    if not is_file then return nil end
                    local ok_dr, DR = pcall(require, "document/documentregistry")
                    local ok_bl, BL = pcall(require, "ui/widget/booklist")
                    local is_book = (ok_dr and DR and DR:hasProvider(file))
                        or (ok_bl and BL and BL.hasBookBeenOpened(file))
                    if not is_book then return nil end
                    return {{
                        text = _("Book statistics"),
                        callback = function()
                            if close_cb then close_cb() end
                            local ok_sw, SW = pcall(require, "sui_stats_windows")
                            if ok_sw and SW then
                                if SW.showLoadingNotice then SW.showLoadingNotice() end
                                SW.showBookStatsFromFile(file)
                            end
                        end,
                    }}
                end

                -- 1. Library browser (FileManager.showFileDialog).
                FM3.instance:addFileDialogButtons("sui_book_stats", function(file, is_file, book_props)
                    local close_cb = function()
                        local fc3 = FM3.instance and FM3.instance.file_chooser
                        local dlg = fc3 and fc3.file_dialog
                        if dlg then UIManager:close(dlg) end
                    end
                    return _makeBookStatsRow(file, is_file, book_props, close_cb)
                end)

                -- 2. Search results (FileSearcher.onMenuHold).
                -- The existing TBR monkey-patch on FS.onMenuHold already wraps
                -- every row_func with a close_cb as the 4th argument, so our
                -- factory receives it without any further patching needed.
                local ok_fs3, FS3 = pcall(require, "apps/filemanager/filemanagerfilesearcher")
                if ok_fs3 and FS3 then
                    FS3.file_dialog_added_buttons = FS3.file_dialog_added_buttons or { index = {} }
                    if FS3.file_dialog_added_buttons.index["sui_book_stats"] == nil then
                        table.insert(FS3.file_dialog_added_buttons, function(file, is_file, book_props, close_cb)
                            return _makeBookStatsRow(file, is_file, book_props, close_cb)
                        end)
                        FS3.file_dialog_added_buttons.index["sui_book_stats"] =
                            #FS3.file_dialog_added_buttons
                    end
                end
            end)

            if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
                Topbar.scheduleRefresh(self, 0)
            end
            -- Pre-load ALL desktop modules during boot idle time so the first
            -- Homescreen open has no perceptible freeze. scheduleIn(2) runs
            -- after the FileManager UI is fully painted and stable.
            -- Registry.list() triggers _load() which pcall-requires all 9
            -- module_*.lua files — they land in package.loaded and subsequent
            -- require() calls are free table lookups, not disk I/O.
            UIManager:scheduleIn(2, function()
                local ok, reg = pcall(require, "desktop_modules/moduleregistry")
                if ok and reg then pcall(reg.list) end
            end)
            -- Silent automatic update check — 24 h throttle.
            -- scheduleIn(3) ensures it runs after the first paint is stable
            -- and does not compete with the module preload above.
            UIManager:scheduleIn(3, function()
                local ok, Updater = pcall(require, "sui_updater")
                if ok and Updater then Updater.scheduleAutoCheck() end
            end)
            -- Patch ReaderStatistics:onSyncBookStats to close the SimpleUI
            -- stats connection before every sync, including syncs triggered
            -- from inside the Reader (where HomescreenWidget is not on the
            -- UIManager stack and therefore cannot handle the event itself).
            -- The HomescreenWidget:onSyncBookStats handler covers the common
            -- case; this patch is the safety net for the remaining paths
            -- (Reader menu → "Synchronize now", interval-based auto-sync).
            -- We apply it unconditionally at init time — no scheduleIn needed
            -- because PluginLoader has already initialised all plugins before
            -- SimpleUI:init() runs, so the RS class table is already in
            -- package.loaded.
            do
                local RS = _requireStatistics()
                if RS and RS.onSyncBookStats and not RS._sui_sync_patched then
                    local orig_onSyncBookStats = RS.onSyncBookStats
                    RS._sui_orig_onSyncBookStats = orig_onSyncBookStats
                    RS._sui_sync_patched         = true
                    RS.onSyncBookStats = function(self_rs, ...)
                        -- Close the HomescreenWidget DB connection synchronously,
                        -- before ReaderStatistics defers the actual sync to nextTick.
                        -- Homescreen._instance is the singleton ref used everywhere
                        -- in sui_homescreen.lua — no UIManager stack walk needed.
                        local hs = Homescreen and Homescreen._instance
                        if hs then
                            if hs._db_conn then
                                pcall(function() hs._db_conn:close() end)
                                hs._db_conn = nil
                            end
                            -- Guard prevents _buildCtx from reopening the connection
                            -- during the window between this call and the nextTick
                            -- sync.  Cleared two ticks later (after sync completes).
                            --
                            -- FIX: mirror the _db_sync_guard stuck-forever fix that was
                            -- already applied to HomescreenWidget:onSyncBookStats.
                            -- The original code gated the entire tick callback on
                            --   Homescreen._instance == hs_ref
                            -- If the homescreen instance was replaced between the guard
                            -- being set and the tick firing (e.g. a tab switch during a
                            -- Kobo sync cycle), the guard was never cleared on hs_ref and
                            -- _buildCtx would never reopen the DB for the rest of the
                            -- session.  Fix: always clear the guard on hs_ref; only gate
                            -- _refresh() on the instance still being the current one.
                            -- scheduleIn(10) is a safety-net for the edge case where tick
                            -- callbacks are never invoked (UIManager teardown, hot reload).
                            hs._db_sync_guard = true
                            local hs_ref = hs
                            local cleared = false
                            local function clearGuard()
                                if cleared then return end
                                cleared = true
                                hs_ref._db_sync_guard = false
                                hs_ref._ctx_cache     = nil
                                if Homescreen._instance == hs_ref then
                                    hs_ref:_refresh(false)
                                end
                            end
                            UIManager:tickAfterNext(function()
                                UIManager:nextTick(clearGuard)
                            end)
                            UIManager:scheduleIn(10, clearGuard)
                        end
                        return orig_onSyncBookStats(self_rs, ...)
                    end
                end
            end
        end
    end)
    if not ok then logger.err("simpleui: init failed:", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- List of all plugin-owned Lua modules that must be evicted from
-- package.loaded on teardown so that a hot plugin update (replacing files
-- without restarting KOReader) always loads fresh code.
-- ---------------------------------------------------------------------------
local _PLUGIN_MODULES = {
    "sui_i18n", "sui_config", "sui_core", "sui_bottombar", "sui_topbar",
    "sui_patches", "sui_menu", "sui_titlebar", "sui_quickactions",
    "sui_homescreen", "sui_foldercovers", "sui_browsemeta", "sui_updater",
    "sui_store", "sui_presets", "sui_style",
    "sui_settings_window",
    "sui_quicksettings_bar",
    "desktop_modules/moduleregistry",
    "desktop_modules/module_books_shared",
    "desktop_modules/module_clock",
    "desktop_modules/module_collections",
    "desktop_modules/module_currently",
    "desktop_modules/module_quick_actions",
    "desktop_modules/module_quote",
    "desktop_modules/module_reading_goals",
    "desktop_modules/module_reading_stats",
    "desktop_modules/module_stats_provider",
    "desktop_modules/module_recent",
    "desktop_modules/module_tbr",
    "desktop_modules/quotes",
}

-- ---------------------------------------------------------------------------
-- Dispatcher gesture handlers
-- ---------------------------------------------------------------------------

-- Called when the user triggers the "Go to Homescreen" gesture.
-- When inside the Reader: closes the reader and opens the Homescreen using
-- the exact same path as the native "Start with Homescreen" setting
-- (sui_patches._hs_pending_after_reader), regardless of whether that
-- setting is actually enabled.
-- When outside the Reader: equivalent to tapping the Homescreen tab.
function SimpleUIPlugin:onSimpleUIGoHomescreen()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToHomescreen(self)
        return true
    end
    local tabs = Config.loadTabConfig()
    self:_navigate("homescreen", self.ui, tabs, false)
    return true
end

-- Called when the user triggers the "Go to Library" gesture.
-- When inside the Reader: closes the reader and returns to the Library
-- (home_dir) without showing the Homescreen, as if "return to book folder"
-- were disabled — the FM file browser becomes the top widget.
-- When outside the Reader: equivalent to tapping the Library tab.
function SimpleUIPlugin:onSimpleUIGoLibrary()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToLibrary(self)
        return true
    end
    local tabs = Config.loadTabConfig()
    self:_navigate("home", self.ui, tabs, false)
    return true
end

-- Called when the user triggers the "Toggle Homescreen / Library" gesture.
-- If the Homescreen is currently open: navigates to the library (home_dir).
-- If inside the Reader: closes the reader and opens the Homescreen (same
-- path as GoHomescreen above).
-- Otherwise (library or any other view): opens the Homescreen.
function SimpleUIPlugin:onSimpleUIToggleHomeLibrary()
    local HS = package.loaded["sui_homescreen"]
    if HS and HS._instance then
        self:_navigate("home", self.ui, Config.loadTabConfig(), false)
        return true
    end
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        Patches.closeReaderToHomescreen(self)
        return true
    end
    self:_navigate("homescreen", self.ui, Config.loadTabConfig(), false)
    return true
end

function SimpleUIPlugin:onSimpleUISettingsWindow()
    local SettingsWindow = require("sui_settings_window")
    SettingsWindow:show()
    return true
end

-- onCloseWidget fires on the plugin when the FM (self.ui) closes.
-- We use this — mirroring the Bookshelf plugin pattern — to close the
-- homescreen whenever the FM shuts down for a real exit.
-- The discriminator is self.ui.tearing_down: KOReader sets it to true on the
-- FM only when the reader is about to open (filemanager.lua:onShowingReader /
-- onSetupShowReader). On a real exit the FM closes via onClose() directly,
-- without tearing_down, so we correctly close the HS and let the stack drain.
function SimpleUIPlugin:onCloseWidget()
    local HS = package.loaded["sui_homescreen"]
    local hs_inst = HS and HS._instance
    if not hs_inst then return end
    if self.ui and self.ui.tearing_down then return end
    hs_inst._navbar_closing_intentionally = true
    UIManager:close(hs_inst)
    if HS._instance == hs_inst then HS._instance = nil end
end

function SimpleUIPlugin:onTeardown()
    -- Flush the plugin settings store so any in-memory writes are persisted
    -- before the plugin is unloaded or KOReader exits.
    SUISettings:flush()
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    Patches.teardownAll(self)
    pcall(function() QSBar.uninstall() end)
    I18n.uninstall()
    -- Give modules with internal upvalue caches a chance to nil them before
    -- their package.loaded entry is cleared — ensures the GC can collect the
    -- old tables immediately rather than waiting for the upvalue to be rebound.
    local mod_recent = package.loaded["desktop_modules/module_recent"]
    if mod_recent and type(mod_recent.reset) == "function" then
        pcall(mod_recent.reset)
    end
    local mod_tbr = package.loaded["desktop_modules/module_tbr"]
    if mod_tbr and type(mod_tbr.reset) == "function" then
        pcall(mod_tbr.reset)
    end
    -- Remove the TBR button from the Library browser dialog and search results.
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons("sui_tbr") end)
    end
    -- Remove the TBR button from the FileSearcher table and restore the original onMenuHold.
    local FS = package.loaded["apps/filemanager/filemanagerfilesearcher"]
    if FS then
        -- Restore the original onMenuHold if it was replaced.
        if FS._sui_onMenuHold_patched and FS._sui_orig_onMenuHold then
            FS.onMenuHold = FS._sui_orig_onMenuHold
            FS._sui_orig_onMenuHold = nil
            FS._sui_onMenuHold_patched = nil
        elseif FS._sui_onMenuHold_patched then
            -- Patch was installed but orig was not saved separately
            -- (captured in the closure); just clear the flag and TBR entry.
            FS._sui_onMenuHold_patched = nil
        end
        if FS.file_dialog_added_buttons then
            local idx = FS.file_dialog_added_buttons.index
                and FS.file_dialog_added_buttons.index["sui_tbr"]
            if idx then
                pcall(function()
                    table.remove(FS.file_dialog_added_buttons, idx)
                    FS.file_dialog_added_buttons.index["sui_tbr"] = nil
                    for id, i in pairs(FS.file_dialog_added_buttons.index) do
                        if i > idx then
                            FS.file_dialog_added_buttons.index[id] = i - 1
                        end
                    end
                    if #FS.file_dialog_added_buttons == 0 then
                        FS.file_dialog_added_buttons = nil
                    end
                end)
            end
        end
    end
    -- Remove the "More by <Author>" button from the Library browser and FileSearcher.
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons("sui_browse_author") end)
    end
    if FS and FS.file_dialog_added_buttons then
        local idx2 = FS.file_dialog_added_buttons.index
            and FS.file_dialog_added_buttons.index["sui_browse_author"]
        if idx2 then
            pcall(function()
                table.remove(FS.file_dialog_added_buttons, idx2)
                FS.file_dialog_added_buttons.index["sui_browse_author"] = nil
                for id, i in pairs(FS.file_dialog_added_buttons.index) do
                    if i > idx2 then
                        FS.file_dialog_added_buttons.index[id] = i - 1
                    end
                end
                if #FS.file_dialog_added_buttons == 0 then
                    FS.file_dialog_added_buttons = nil
                end
            end)
        end
    end
    local mod_rg = package.loaded["desktop_modules/module_reading_goals"]
    if mod_rg and type(mod_rg.reset) == "function" then
        pcall(mod_rg.reset)
    end
    -- Remove the "Book statistics" button from the Library browser and FileSearcher.
    if FM and FM.instance and FM.instance.removeFileDialogButtons then
        pcall(function() FM.instance:removeFileDialogButtons("sui_book_stats") end)
    end
    if FS and FS.file_dialog_added_buttons then
        local idx = FS.file_dialog_added_buttons.index
            and FS.file_dialog_added_buttons.index["sui_book_stats"]
        if idx then
            pcall(function()
                table.remove(FS.file_dialog_added_buttons, idx)
                FS.file_dialog_added_buttons.index["sui_book_stats"] = nil
                for id, i in pairs(FS.file_dialog_added_buttons.index) do
                    if i > idx then
                        FS.file_dialog_added_buttons.index[id] = i - 1
                    end
                end
                if #FS.file_dialog_added_buttons == 0 then
                    FS.file_dialog_added_buttons = nil
                end
            end)
        end
    end
    local mod_bm = package.loaded["sui_browsemeta"]
    if mod_bm and type(mod_bm.reset) == "function" then
        pcall(mod_bm.reset)
    end
    -- Evict all plugin modules from the Lua module cache so that a hot update
    -- (files replaced on disk without restarting KOReader) picks up new code
    -- on the next plugin load, instead of reusing the old in-memory versions.
    _menu_installer = nil
    -- Restore the ReaderStatistics:onSyncBookStats patch.
    local RS = _requireStatistics()
    if RS and RS._sui_sync_patched then
        if RS._sui_orig_onSyncBookStats then
            RS.onSyncBookStats = RS._sui_orig_onSyncBookStats
            RS._sui_orig_onSyncBookStats = nil
        end
        RS._sui_sync_patched = nil
    end
    for _, mod in ipairs(_PLUGIN_MODULES) do
        package.loaded[mod] = nil
    end
end

-- ---------------------------------------------------------------------------
-- System events
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:onScreenResize()
    if self._simpleui_suspended then return end
    UI.invalidateDimCache()
    UIManager:scheduleIn(0.2, function()
        if self._simpleui_suspended then return end
        local RUI = package.loaded["apps/reader/readerui"]
        if RUI and RUI.instance then return end

        -- If the homescreen is open, close and reopen it so HomescreenWidget:new
        -- runs with the new screen dimensions. rewrapAllWidgets cannot resize it
        -- correctly because its layout is built entirely in init(), not via
        -- wrapWithNavbar — the same reason FM uses reinit() (= rotate()) instead
        -- of a simple rewrap.
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            local hs_inst = HS._instance
            hs_inst._navbar_closing_intentionally = true
            pcall(function() UIManager:close(hs_inst) end)
            hs_inst._navbar_closing_intentionally = nil
            if not self._goalTapCallback then self:addToMainMenu({}) end
            local tabs = Config.loadTabConfig()
            Bottombar.setActiveAndRefreshFM(self, "homescreen", tabs)
            HS.show(
                function(aid) self:_navigate(aid, self.ui, Config.loadTabConfig(), false) end,
                self._goalTapCallback
            )
            return
        end

        self:_rewrapAllWidgets()
        self:_refreshCurrentView()
    end)
end
function SimpleUIPlugin:onNetworkConnected()
    if self._simpleui_suspended then return end
    local RUI = package.loaded["apps/reader/readerui"]
    -- If this event was fired by doWifiToggle itself, wifi_optimistic is already
    -- set correctly and the bars are already rebuilt. Skip the reset so the
    -- optimistic icon is preserved (on Kindle isWifiOn() may lag behind).
    -- Still call _refreshCurrentView to rebuild homescreen QA icons.
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    if RUI and RUI.instance then
        self:_rebuildAllNavbars()
    else
        local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
        QA.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onNetworkDisconnected()
    if self._simpleui_suspended then return end
    local RUI = package.loaded["apps/reader/readerui"]
    -- Same rationale as onNetworkConnected above.
    if not Config.wifi_broadcast_self then
        Config.wifi_optimistic = nil
    end
    if RUI and RUI.instance then
        self:_rebuildAllNavbars()
    else
        local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
        QA.refreshWifiIcon(self)
    end
end

function SimpleUIPlugin:onSuspend()
    self._simpleui_suspended = true
    -- Snapshot whether the reader was open at the moment of suspend.
    -- We cannot rely on RUI.instance being intact by the time onResume fires
    -- (e.g. autosuspend can race with a reader teardown on some Kobo builds),
    -- so we capture the truth here, while the world is still settled.
    local RUI = package.loaded["apps/reader/readerui"]
    self._simpleui_reader_was_active = (RUI and RUI.instance) and true or false
    if self._topbar_timer then
        UIManager:unschedule(self._topbar_timer)
        self._topbar_timer = nil
    end
    -- Flush any settings written via SUISettings:setNoFlush() (currently:
    -- module_books_shared.lua's stale-books cache, refreshed in-memory on
    -- every prefetchBooks() success but never fsync'd on that hot path —
    -- see the WRITE COST / FLUSH COST notes there). Device suspend is
    -- infrequent and off the reader-return critical path, so this is a
    -- safe, low-cost point to make those writes durable across a full
    -- KOReader process restart.
    pcall(function() SUISettings:flush() end)
end

function SimpleUIPlugin:onResume()
    self._simpleui_suspended = false
    if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
        -- Small delay to let the wakeup transition finish before refreshing
        -- the topbar. Avoids a race with HomescreenWidget:onResume() and
        -- prevents the timer firing while the device is still mid-wakeup.
        Topbar.scheduleRefresh(self, 0.5)
    end
    -- Use the snapshot captured in onSuspend rather than checking RUI.instance
    -- live. On some Kobo builds the autosuspend timer fires close to a reader
    -- teardown, leaving RUI.instance nil even though the user was reading —
    -- causing the homescreen to open on wakeup instead of returning to the reader.
    local reader_active = self._simpleui_reader_was_active
    self._simpleui_reader_was_active = nil  -- consume; next suspend will repopulate

    -- "Return to Home Screen on Wakeup": unlike "Start with Homescreen" (which
    -- only ever fires when the reader was already closed), this setting must
    -- also override a reader that WAS open at suspend time. Handle it first,
    -- via the live RUI check (not the snapshot) so we don't try to close a
    -- reader that already tore itself down during the races described above.
    if SUISettings:nilOrTrue("simpleui_enabled")
            and SUISettings:isTrue("simpleui_hs_return_on_wakeup") then
        local RUI_live = package.loaded["apps/reader/readerui"]
        if RUI_live and RUI_live.instance then
            Patches.showHSAfterResume(self, true)
            return
        end
    end

    -- Outside the reader: restore the Homescreen.
    -- RS and RG have a built-in date-key guard (_stats_cache_day): they re-query
    -- automatically on a new calendar day and serve the in-memory cache otherwise.
    -- Explicit invalidation here would force full SQL queries on every wakeup
    -- even when nothing changed. Data changes from reading are handled by
    -- onCloseDocument, which invalidates those caches before the next render.
    if not reader_active then
        local HS = package.loaded["sui_homescreen"]
        if HS and HS._instance then
            -- Refresh the QA tap callback on the live homescreen instance.
            -- If the device suspended while the homescreen (or the touch menu
            -- floating on top of it) was open, HS._instance survives but its
            -- _on_qa_tap closure may reference a stale FileManager object.
            -- Reassigning it here ensures QA buttons work on the very first
            -- tap after wakeup, without requiring the user to navigate away
            -- and reopen the homescreen.
            local plugin_ref = self
            HS._instance._on_qa_tap = function(aid)
                plugin_ref:_navigate(aid, plugin_ref.ui, Config.loadTabConfig(), false)
            end
            -- Use keep_cache=false so that stats modules always re-fetch from
            -- the DB on wakeup.  HomescreenWidget:onResume already issued a
            -- stats-only _refresh, but this call (which fires slightly later in
            -- the same resume chain) must not override it with a keep_cache=true
            -- that reuses a potentially stale _ctx_cache.
            HS.refresh(false)
        end
        -- Re-open the Homescreen on wakeup when \"Start with Homescreen\" is set.
        if SUISettings:nilOrTrue("simpleui_enabled") then
            Patches.showHSAfterResume(self)
        end
    end
end

function SimpleUIPlugin:onCloseDocument()
    -- Consume _closing_via_gesture unconditionally before any early return,
    -- so the flag never leaks to a subsequent close if this handler bails out
    -- (e.g. while the plugin is suspended).
    local via_gesture = self._closing_via_gesture
    self._closing_via_gesture = nil

    -- Consume the reload-suppress flag once, up front (rather than deep
    -- inside the notice block below), so it is also visible to the HS
    -- visual-refresh guard near the end of this function. Set by
    -- patchReloadDocument just before ReaderUI:reloadDocument() runs —
    -- covers font size, margins, line spacing, and any other CRE setting
    -- change that triggers a background reflow + seamless reload. Those
    -- calls close and reopen ReaderUI in the same synchronous call chain;
    -- CloseDocument fires exactly the same as on a real close, so we need
    -- this flag to tell the two apart.
    local is_reload = self._suppress_closing_notice
    self._suppress_closing_notice = nil

    if self._simpleui_suspended then return end
    local HS = package.loaded["sui_homescreen"]
    if not HS then return end

    -- Show a brief "closing book" notice whenever a book is closed.
    -- onCloseDocument is the single, authoritative place for this: it fires on
    -- every close path (menu, gesture, or any direct call to ReaderUI:onClose).
    --
    -- How the three modes work:
    --   "always"       — show on every book close, regardless of how it was
    --                    triggered or where the user ends up afterwards.
    --   "gesture_only" — show only when the close was triggered by a SimpleUI
    --                    gesture (GoHomescreen, GoLibrary, ToggleHomeLibrary).
    --                    Those paths set plugin._closing_via_gesture = true
    --                    immediately before readerui:onClose(). We read and
    --                    clear that flag above. Menu-triggered closes never set
    --                    the flag — no KOReader internals patched.
    --   "never"        — never show.
    --
    -- The notice is shown while readerui.dialog is still on the widget stack
    -- (i.e. the book page is still the background). forceRePaint pushes it to
    -- the e-ink screen immediately; without it _repaint() only runs on the next
    -- event-loop tick, after closeDocument() and UIManager:close(dialog) have
    -- already run, so the notice would appear over the FM/HS far too late.
    -- timeout=0.0 schedules the InfoMessage to close itself on the next tick.
    --
    -- Migration: if simpleui_hs_closing_notice_mode is absent, fall back to the
    -- old boolean simpleui_hs_closing_notice (nil/true → "always", false → "never").
    do
        local notice_mode = SUISettings:readSetting("simpleui_hs_closing_notice_mode")
        if not notice_mode then
            notice_mode = SUISettings:nilOrTrue("simpleui_hs_closing_notice") and "always" or "never"
        end

        local suppress = is_reload

        if (notice_mode == "always" and not suppress)
                or (notice_mode == "gesture_only" and via_gesture) then
            -- UIManager:show() respects honor_silent_mode on InfoMessage, which
            -- means the notice is silently dropped when the Dispatcher has put
            -- the UIManager into silent mode to batch multiple gesture actions.
            -- We bypass silent mode here by temporarily clearing it, showing the
            -- notice and flushing it to the screen, then restoring the flag.
            -- This is safe because forceRePaint() runs synchronously and the
            -- InfoMessage is a non-blocking toast (timeout=0.0 auto-closes it);
            -- no other widget draw or event dispatch occurs between the two lines.
            local was_silent = UIManager:isInSilentMode()
            if was_silent then UIManager:setSilentMode(false) end
            UIManager:show(InfoMessage:new{
                text    = _("Closing book…"),
                timeout = 0.0,
            })
            UIManager:forceRePaint()
            if was_silent then UIManager:setSilentMode(true) end
        end
    end

    -- Fast-path: if the HS is not visible and is already flagged for rebuild,
    -- there is nothing further to do — the next Homescreen.show() will rebuild
    -- from scratch. Avoids loading the Registry and all module pcalls.
    if not HS._instance and HS._stats_need_refresh then
        if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
            Topbar.scheduleRefresh(self, 0)
        end
        return
    end

    -- Registry is already loaded (moduleregistry was pre-loaded at boot via
    -- scheduleIn(2)); use package.loaded to avoid a pcall on the hot path.
    -- Fall back to pcall only if it hasn't been loaded yet.
    local Registry = package.loaded["desktop_modules/moduleregistry"]
    if not Registry then
        local ok, reg = pcall(require, "desktop_modules/moduleregistry")
        if not ok then return end
        Registry = reg
    end

    local PFX = "simpleui_hs_"
    local needs_refresh    = false
    local currently_active = false

    -- Only call pcall(require) for modules that are actually enabled.
    -- Registry.get + Registry.isEnabled are cheap table lookups; the module
    -- is guaranteed already loaded when enabled (required by the HS on open).

    -- Determine the filepath of the book that just closed.
    -- readhistory.hist[1] is still the closing book at this point (the reader
    -- has not yet handed control back to the FM, so the history order has not
    -- been updated).
    local rh         = package.loaded["readhistory"]
    local closed_fp  = rh and rh.hist and rh.hist[1] and rh.hist[1].file

    -- Invalidate the shared stats provider when either stats module is active.
    -- One SP.invalidate() covers both reading_goals and reading_stats — they
    -- both read ctx.stats which is populated from StatsProvider.get().
    --
    -- Optimisation: SP contains two parts — DB time-series (always stale after
    -- a reading session) and books_year/books_total (sidecar scan, expensive).
    -- The sidecar-derived counts only change when the closed book's
    -- summary.status transitions to or from "complete". We detect this by
    -- comparing the cached pre-session status (from SH._cacheGet, still valid
    -- at this point) with the on-disk status (one DS.open on the closed book).
    -- If neither was "complete" and neither is now, the counts are unchanged
    -- and we can spare the full SP.invalidate() — instead we call
    -- SP.invalidateTimeSeries() which discards only the DB-derived fields,
    -- leaving books_year/books_total intact in the cache.
    local mod_rg = Registry.get("reading_goals")
    local mod_rs = Registry.get("reading_stats")
    local stats_active = (mod_rg and Registry.isEnabled(mod_rg, PFX))
        or (mod_rs and mod_rs.isEnabled and mod_rs.isEnabled(PFX))

    if not stats_active then
        for _, mod in ipairs(Registry.list()) do
            if mod.needs and mod.needs.stats and Registry.isEnabled(mod, PFX) then
                stats_active = true
                break
            end
        end
    end

    if stats_active then
        local SP = package.loaded["desktop_modules/module_stats_provider"]
        -- Fall back to pcall require: the module may not be in package.loaded yet
        -- if the homescreen was never opened this session (e.g. the user went
        -- straight from boot to the reader without visiting the homescreen).
        if not SP then
            local ok_sp, m = pcall(require, "desktop_modules/module_stats_provider")
            if ok_sp then SP = m end
        end
        if SP then
            local status_changed = true  -- default: full invalidation (safe)
            if closed_fp and SP.invalidateTimeSeries then
                local SH = package.loaded["desktop_modules/module_books_shared"]
                -- Pre-session status: read from sidecar cache (no I/O).
                -- The cache entry is still valid here — SH.invalidateSidecarCache
                -- for closed_fp runs later in this function, after this block.
                local pre_status
                if SH and SH._cacheGet then
                    local cached = SH._cacheGet(closed_fp)
                    local s = cached and cached.summary
                    pre_status = type(s) == "table" and s.status or nil
                end
                -- Post-session status: read from the in-memory doc_settings.
                -- ReaderUI:onClose() calls saveSettings() (flush) before firing
                -- CloseDocument, so doc_settings reflects the final on-disk state.
                -- doc_settings is not destroyed until UIManager:close() → onCloseWidget,
                -- which runs after this handler — so RUI.instance.doc_settings is
                -- valid here. This avoids a DS.open (file-open + WAL header read).
                local post_status
                local RUI = package.loaded["apps/reader/readerui"]
                if RUI and RUI.instance and type(RUI.instance.doc_settings) == "table" then
                    local s = RUI.instance.doc_settings:readSetting("summary")
                    post_status = type(s) == "table" and s.status or nil
                end
                -- Status changed only when a "complete" boundary was crossed.
                -- Both nil/non-complete pre and post → counts are unaffected.
                local pre_complete  = pre_status  == "complete"
                local post_complete = post_status == "complete"
                status_changed = pre_complete ~= post_complete
            end

            if status_changed then
                SP.invalidate()
            elseif SP.invalidateTimeSeries then
                -- Counts unchanged: only discard DB-derived fields (time, pages,
                -- streak). books_year/books_total survive in the cache intact.
                SP.invalidateTimeSeries()
            else
                -- SP.invalidateTimeSeries not available (older version): fall back.
                SP.invalidate()
            end
            needs_refresh = true
        end
    end

    -- Currently Reading shows the current book's cover, title, author and
    -- progress (percent_finished). All of these come from _cached_books_state.
    -- When the reader closes, percent_finished has changed for the closed book.
    -- Instead of discarding the entire _cached_books_state (which forces
    -- prefetchBooks() to re-open every sidecar), we do a surgical invalidation:
    -- only the entry for the closed book is removed from prefetched_data.
    -- prefetchBooks() will then re-open exactly one sidecar (the closed book)
    -- and reuse the mtime-validated sidecar cache for all other entries.
    -- Read the md5 of the closing book once — used by both Currently Reading
    -- and Cover Deck for surgical stats-cache invalidation.
    local closed_md5
    if closed_fp then
        local bs_pre = (HS._instance and HS._instance._cached_books_state)
                    or HS._cached_books_state
        local pe = bs_pre and bs_pre.prefetched_data
                and bs_pre.prefetched_data[closed_fp]
        closed_md5 = pe and pe.partial_md5_checksum
    end

    -- Currently Reading: invalidate book data so the next render shows fresh
    -- progress. Uses surgical invalidation to avoid re-opening every sidecar.
    local mod_cr = Registry.get("currently")
    currently_active = mod_cr and Registry.isEnabled(mod_cr, PFX) or false
    -- Also check coverdeck here so we know whether its full discard will
    -- supersede the surgical currently-reading invalidation below.
    local mod_cd = Registry.get("coverdeck")
    local coverdeck_active = mod_cd and Registry.isEnabled(mod_cd, PFX) or false
    if currently_active then
        -- Surgical invalidation: drop only the closed book's entry so
        -- prefetchBooks() re-reads exactly one sidecar, cache-hitting the rest.
        -- Skipped when coverdeck is also active — its block below will discard
        -- _cached_books_state entirely, making the partial work redundant.
        if not coverdeck_active then
            local function _partial_invalidate(bs)
                if not bs then return end
                -- Drop the entry for the closed book so prefetchBooks() re-reads it.
                if bs.prefetched_data and closed_fp then
                    bs.prefetched_data[closed_fp] = nil
                end
                -- current_fp will be re-resolved by the next prefetchBooks() call.
                -- Setting it to nil ensures Currently Reading does not paint
                -- stale progress data before the refresh completes.
                bs.current_fp = nil
            end
            if HS._instance then
                _partial_invalidate(HS._instance._cached_books_state)
                _partial_invalidate(HS._cached_books_state)
            end
        end
        -- When the homescreen is not visible (HS._instance == nil), the partially
        -- invalidated HS._cached_books_state (with current_fp=nil) would be passed
        -- to the next HomescreenWidget:new{} in Homescreen.show(). Because the
        -- state is non-nil, _buildCtx() skips prefetchBooks() entirely, leaving
        -- ctx.current_fp = nil and causing Currently Reading to disappear.
        -- Fix: discard the shared cached state so _buildCtx() is forced to call
        -- prefetchBooks() from scratch on the next Homescreen.show().
        if not HS._instance then
            HS._cached_books_state = nil
        end
        local MC = package.loaded["desktop_modules/module_currently"]
        if MC and MC.invalidateCache then MC.invalidateCache() end
        needs_refresh = true
    end

    -- Cover Deck: invalidate book list and stats cache so the carousel
    -- reflects the updated reading history immediately on return to the HS.
    -- This is independent of Currently Reading — coverdeck may be active alone.
    if coverdeck_active then
        -- Surgically evict only the closed book's stats from the cache.
        -- All other carousel entries are unaffected.
        local MCD = package.loaded["desktop_modules/module_coverdeck"]
        if MCD then
            if closed_md5 and MCD.invalidateCacheForMd5 then
                -- Fast path: only evict the one book that changed.
                MCD.invalidateCacheForMd5(closed_md5)
            elseif MCD.invalidateCache then
                -- Fallback: md5 was not in prefetched_data (book outside the
                -- top-5 window, or _cached_books_state was already nil).
                -- Full flush is safe — fetchBookStats re-populates on demand.
                MCD.invalidateCache()
            end
        end
        -- Invalidate _cached_books_state so prefetchBooks() re-reads the
        -- updated history order (closed book moves to position 1 = new centre)
        -- on the next deferred _refresh() tick. Also reset the session index
        -- so the carousel returns to fps[1] once fresh data lands.
        --
        -- Deliberately mirrors SP.invalidate() in module_stats_provider.lua:
        -- that function clears only _cache_day (the "needs recompute" flag)
        -- and explicitly does NOT touch _cache, so SP.getStale() keeps
        -- returning the previous day's numbers for one frame after a
        -- reading session ends — accepted as fine, since SP.get() overwrites
        -- everything ~50ms later anyway. Earlier versions of this code tried
        -- to eagerly fix HS._instance._ctx_cache.current_fp/recent_fps right
        -- here via SH.peekRecentBooks(), to avoid the carousel/title showing
        -- the previous book for that one frame — but that traded a few stat
        -- syscalls per close for a guarantee that wasn't actually needed:
        -- exactly like the stats case, _ctx_cache.current_fp/recent_fps
        -- being one step stale for ~50ms is harmless, since the deferred
        -- _refresh() tick (see _refresh()'s scheduleIn(0.05, ...) in
        -- sui_homescreen.lua) unconditionally re-resolves both from a real
        -- SH.prefetchBooks() call and repaints. So: touch nothing here,
        -- exactly like SP.invalidate() touches nothing in _cache.
        if HS._instance then
            HS._instance._cached_books_state = nil
            if HS._instance._ctx_cache then
                HS._instance._ctx_cache.coverdeck_cur_idx = nil
            end
        else
            -- HS not visible: discard the shared cached state so the next
            -- Homescreen.show() is forced to call prefetchBooks() from scratch.
            -- Without this, the stale _cached_books_state (non-nil) causes
            -- _buildCtx() to skip prefetchBooks(), leaving the carousel with
            -- the old history order until the user manually refreshes.
            HS._cached_books_state = nil
        end
        needs_refresh = true
    end

    if not needs_refresh then return end

    local book_mod_active = currently_active or coverdeck_active

    -- Invalidate the sidecar mtime-cache entry for the closed book only when
    -- a book module is active — prefetchBooks() will re-read it on next render.
    -- Stats-only path never calls prefetchBooks, so no sidecar work is needed.
    -- Guard: only invalidate surgically when closed_fp is known; a nil fp would
    -- flush the entire cache, discarding valid entries for all other books.
    if book_mod_active and closed_fp then
        local SH = package.loaded["desktop_modules/module_books_shared"]
        if SH and SH.invalidateSidecarCache then
            SH.invalidateSidecarCache(closed_fp)
        end
    end

    if HS._instance then
        if is_reload then
            -- The old ReaderUI is being torn down and a new one is about to
            -- be shown in its place, in the same synchronous call chain
            -- (ReaderUI:reloadDocument, triggered by a font size, margin,
            -- line spacing, or other CRE setting change). HS._instance is
            -- the hidden HomescreenWidget kept under the reader per the
            -- _live_widget/_raiseInPlace architecture — calling HS.refresh()
            -- here would UIManager:setDirty() it while it is briefly the
            -- topmost widget (old reader gone, new reader not shown yet),
            -- producing a visible flash to the homescreen and back.
            --
            -- Nothing homescreen-relevant has actually changed: the book's
            -- status/percent_finished are unaffected by a reformat, and the
            -- reading session survives the reload via PreserveCurrentSession
            -- (see readerui.lua:reloadDocument). So just flag the widget for
            -- a refresh the next time it genuinely becomes visible, instead
            -- of repainting it now.
            HS._instance._stats_need_refresh = true
        else
            -- Determine what changed and use the narrowest refresh that covers it:
            --   books_only  → book module(s) active; prefetchBooks() must re-run.
            --   stats_only  → only stats modules active; SP.get() must re-run but
            --                  no sidecar I/O is needed (_cached_books_state kept).
            -- keep_cache is always false — we never want to reuse a stale _ctx_cache.
            HS.refresh(false, book_mod_active, not book_mod_active)
        end
    else
        -- Homescreen not visible yet — flag it for rebuild on next open.
        HS._stats_need_refresh = true
    end

    -- Restart the topbar clock chain. While the reader was open, shouldRunTimer()
    -- returned false (RUI.instance present) so the chain stopped naturally.
    -- Without this, the topbar is frozen until the next hardware event (frontlight,
    -- charge) — wifi state changes that happened during reading would not be
    -- reflected for up to 60 s. scheduleRefresh guards against suspend internally
    -- via shouldRunTimer, so this is safe to call unconditionally here.
    if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
        Topbar.scheduleRefresh(self, 0)
    end
end

-- ---------------------------------------------------------------------------
-- onBookMetadataChanged — fired by KOReader when the user edits a book's
-- title, author, or other doc_props via "Book information" → "Set custom".
--
-- SimpleUI reads title/author from the sidecar's doc_props via prefetchBooks()
-- and caches the result in both the sidecar mtime-cache (_sidecar_cache in
-- module_books_shared) and the homescreen's _cached_books_state table.
--
-- Without this handler, editing metadata has no visible effect on the
-- Currently Reading (and Recent) modules: _cached_books_state is never
-- cleared, so prefetchBooks() is never re-called, and the old stale values
-- are shown even though the sidecar on disk is already correct.
--
-- Fix: when BookMetadataChanged fires, flush the sidecar cache entirely (we
-- don't know which file was edited from the event alone; prop_updated carries
-- a filepath key in some call-sites but not all, so a full flush is safest
-- and cheap — it only costs one extra DS.open on the next render), discard
-- _cached_books_state to force a full prefetchBooks() pass, and schedule a
-- homescreen refresh so the corrected metadata appears immediately.
-- ---------------------------------------------------------------------------
function SimpleUIPlugin:onBookMetadataChanged(_prop_updated)
    if self._simpleui_suspended then return end

    local HS = package.loaded["sui_homescreen"]
    if not HS then return end

    -- Flush the entire sidecar mtime-cache.  The next prefetchBooks() will
    -- re-open each sidecar and repopulate the cache from fresh disk state.
    local SH = package.loaded["desktop_modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then
        SH.invalidateSidecarCache()  -- nil → flush all
    end

    -- Discard the cached prefetch state on both the class and any live
    -- instance so _buildCtx() is forced to call prefetchBooks() from scratch.
    if HS._instance then
        HS._instance._cached_books_state = nil
    end
    HS._cached_books_state = nil

    -- Trigger a homescreen refresh (keep_cache=false, books_only=true).
    if HS._instance then
        HS.refresh(false, true)
    end
end

function SimpleUIPlugin:onFrontlightStateChanged()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onCharging()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

function SimpleUIPlugin:onNotCharging()
    if self._simpleui_suspended then return end
    if not SUISettings:nilOrTrue("simpleui_topbar_enabled") then return end
    Topbar.scheduleRefresh(self, 0)
end

-- ---------------------------------------------------------------------------
-- Topbar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_registerTouchZones(fm_self)
    Bottombar.registerTouchZones(self, fm_self)
    Topbar.registerTouchZones(self, fm_self)
end

function SimpleUIPlugin:_scheduleTopbarRefresh(delay)
    Topbar.scheduleRefresh(self, delay)
end

function SimpleUIPlugin:_refreshTopbar()
    Topbar.refresh(self)
end

-- ---------------------------------------------------------------------------
-- Bottombar delegation
-- ---------------------------------------------------------------------------

function SimpleUIPlugin:_onTabTap(action_id, fm_self)
    Bottombar.onTabTap(self, action_id, fm_self)
end

function SimpleUIPlugin:_navigate(action_id, fm_self, tabs, force)
    Bottombar.navigate(self, action_id, fm_self, tabs, force)
end

function SimpleUIPlugin:_refreshCurrentView()
    local tabs      = Config.loadTabConfig()
    local action_id = self.active_action or tabs[1] or "home"
    self:_navigate(action_id, self.ui, tabs)
end

function SimpleUIPlugin:_rebuildAllNavbars()
    Bottombar.rebuildAllNavbars(self)
end

function SimpleUIPlugin:_rewrapAllWidgets()
    Bottombar.rewrapAllWidgets(self)
end

function SimpleUIPlugin:_restoreTabInFM(tabs, prev_action)
    Bottombar.restoreTabInFM(self, tabs, prev_action)
end

function SimpleUIPlugin:_doWifiToggle()
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    QA.doWifiToggle(self)
end

function SimpleUIPlugin:_doRotateScreen()
    Bottombar.doRotateScreen()
end

function SimpleUIPlugin:_showFrontlightDialog()
    local QA = package.loaded["sui_quickactions"] or require("sui_quickactions")
    QA.showFrontlightDialog(self)
end

function SimpleUIPlugin:_scheduleRebuild()
    if self._rebuild_scheduled then return end
    self._rebuild_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._rebuild_scheduled = false
        self:_rebuildAllNavbars()
    end)
end

function SimpleUIPlugin:_updateFMHomeIcon() end

-- ---------------------------------------------------------------------------
-- Main menu entry (sui_menu is lazy-loaded on first access)
-- ---------------------------------------------------------------------------

local _menu_installer = nil

function SimpleUIPlugin:addToMainMenu(menu_items)
    local _ = require("sui_i18n").translate
    if not _menu_installer then
        local ok, result = pcall(require, "sui_menu")
        if not ok then
            logger.err("simpleui: sui_menu failed to load: " .. tostring(result))
            menu_items.simpleui = { sorting_hint = "tools", text = _("Simple UI"), sub_item_table = {} }
            return
        end
        _menu_installer = result
        -- Capture the bootstrap stub before installing so we can detect replacement.
        local bootstrap_fn = rawget(SimpleUIPlugin, "addToMainMenu")
        _menu_installer(SimpleUIPlugin)
        -- The installer replaces addToMainMenu on the class; call the real one now.
        local real_fn = rawget(SimpleUIPlugin, "addToMainMenu")
        if type(real_fn) == "function" and real_fn ~= bootstrap_fn then
            real_fn(self, menu_items)
        else
            logger.err("simpleui: sui_menu installer did not replace addToMainMenu")
            menu_items.simpleui = { sorting_hint = "tools", text = _("Simple UI"), sub_item_table = {} }
        end
        return
    end
end

return SimpleUIPlugin