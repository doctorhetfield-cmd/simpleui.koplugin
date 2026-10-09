-- Compatibility checks at plugin startup.
-- Detects conflicting plugins and user patches, and verifies CoverBrowser.

local _ = require("gettext")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_dir_from_loaded(sentinel)
    local mod = package.loaded[sentinel]
    if not mod then return nil end
    local src
    if type(mod) == "table" then
        for _k, v in pairs(mod) do
            if type(v) == "function" then
                local info = debug.getinfo(v, "S")
                src = info and info.source
                break
            end
        end
    elseif type(mod) == "function" then
        local info = debug.getinfo(mod, "S")
        src = info and info.source
    end
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*)/[^/]+%.lua$")
        return dir and (dir .. "/")
    end
end

local function get_folder_key(dir)
    if not dir then return nil end
    return dir:match("^.*/([^/]+)%.koplugin/")
end

local function plugin_folder_exists(folder_key)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return false end

    local paths = { "plugins" }
    local extra_paths = G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra_paths) == "string" then extra_paths = { extra_paths } end
    if type(extra_paths) == "table" then
        for _i, path in ipairs(extra_paths) do
            paths[#paths + 1] = path
        end
    end

    for _i, path in ipairs(paths) do
        if type(path) == "string" then
            path = path:gsub("/+$", "")
            if lfs.attributes(path .. "/" .. folder_key .. ".koplugin", "mode") == "directory" then
                return true
            end
        end
    end
    return false
end

local function is_pt_detected()
    return package.loaded["ptutil"] ~= nil
end

-- Plugins that will be auto-disabled (plugins_disabled + restart).
local AUTO_DISABLE = {
    {
        sentinel = "common/zen_logger",
        label = "ZenOS",
        fallback_key = "zenos",
        folder_key = "zenos",
    },
    {
        sentinel = "burrow_util",
        label = "Burrow",
        fallback_key = "burrow",
        folder_key = "burrow",
    },
    {
        sentinel = "readermenuredesign_installer",
        label = "Reader Menu Redesign",
        fallback_key = "zzz-readermenuredesign",
        folder_key = "zzz-readermenuredesign",
    },
}

-- Extra detection for ZenOS when its logger sentinel is not yet loaded.
local function is_zenos_present()
    if package.loaded["common/zen_logger"] ~= nil then return true end
    if package.loaded["common/plugin_root"] ~= nil then return true end
    if rawget(_G, "__ZEN_UI_PLUGIN") ~= nil then return true end
    return plugin_folder_exists("zenos")
end

local AUTO_DISABLE_PATCHES = {
    "2---stretched-covers.lua",
    "2--disable-all-CB-widgets.lua",
    "2--disable-all-PT-widgets.lua",
    "2--rounded-covers.lua",
    "2--stretched-rounded-covers.lua",
    "2-navbar-vos.lua",
    "2-new-collections-star.lua",
    "2-new-progress-bar-colored.lua",
    "2-new-progress-bar.lua",
    "2-pages-badge.lua",
    "2-percent-badge.lua",
    "2-rounded-folder-covers.lua",
    "2-series-indicator.lua",
    "20-faded-finished-books.lua",
    "2-quick-settings.lua",
    "2-automatic-book-series.lua",
    "2-ui-font.lua",
    "2-custom-navbar.lua",
    "2-page-scrubber.lua",
    "2-browser-double-tap.lua",
    "2-browser-hide-underline.lua",
    "2-browser-up-folder.lua",
    "2-coverimage-eink-optimize.lua",
    "2-disable-top-menu-zones.lua",
    "2-filemanager-titlebar.lua",
    "2-menu-size.lua",
    "2-new-status-icons.lua",
    "2-screensaver-chapter.lua",
    "2-screensaver-cover.lua",
    "2-series-badge-numbered.lua",
    "2-statusbar-better-compact.lua",
    "2-statusbar-cycle-presets.lua",
}

-- Master switch for renaming the patches above to "<name>.disabled".
-- Off: user patches are left untouched. The list and the logic below are
-- kept so the behaviour can be turned back on by setting this to true.
local DISABLE_CONFLICTING_PATCHES = false

-- Renames every installed patch from AUTO_DISABLE_PATCHES that is active (or
-- has already run this session). Returns the list of renamed file names.
local function disable_conflicting_patches()
    local renamed = {}
    local ok_userpatch, userpatch = pcall(require, "userpatch")
    local execution_status = ok_userpatch and userpatch and userpatch.execution_status
    local patches_enabled = type(userpatch) ~= "table"
        or type(userpatch.arePatchesDisabled) ~= "function"
        or not userpatch.arePatchesDisabled()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local patch_dir = ok_ds and (DataStorage:getDataDir() .. "/patches") or "patches"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return renamed end

    for _i, filename in ipairs(AUTO_DISABLE_PATCHES) do
        local source = patch_dir .. "/" .. filename
        local installed = lfs.attributes(source, "mode") == "file"
        local was_run = type(execution_status) == "table" and execution_status[filename] ~= nil
        if installed and (was_run or patches_enabled)
                and os.rename(source, source .. ".disabled") then
            renamed[#renamed + 1] = filename
        end
    end
    return renamed
end

local function schedule_coverbrowser_check()
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(1.0, function()
        local ok_cm = pcall(require, "covermenu")
        if ok_cm then return end

        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local buttons = {}

        local disabled_list = {}
        if G_reader_settings then
            local dl = G_reader_settings:readSetting("plugins_disabled")
            if type(dl) == "table" then disabled_list = dl end
        end
        local plugin_available = disabled_list["coverbrowser"] ~= nil

        if plugin_available then
            table.insert(buttons, {{
                text = _("Enable"),
                callback = function()
                    UIManager:close(dialog)
                    if G_reader_settings then
                        disabled_list["coverbrowser"] = nil
                        G_reader_settings:saveSetting("plugins_disabled", disabled_list)
                        G_reader_settings:flush()
                    end
                    local Event = require("ui/event")
                    UIManager:show(require("ui/widget/confirmbox"):new{
                        text = _("Please restart KOReader for the change to take effect."),
                        ok_text = _("Restart now"),
                        ok_callback = function()
                            UIManager:broadcastEvent(Event:new("Restart"))
                        end,
                    })
                end,
            }})
        end

        table.insert(buttons, {{
            text = _("OK"),
            callback = function() UIManager:close(dialog) end,
        }})

        dialog = ButtonDialog:new{
            title = _("CoverBrowser plugin is not enabled, some features will not work correctly."),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
    end)
end

-- Returns true when startup should stop (manual block or restart required).
local function apply_compat_check()
    local logger
    do
        local ok, log = pcall(require, "logger")
        logger = ok and log or { dbg = function() end, info = function() end, warn = function() end }
    end

    if is_pt_detected() then
        logger.warn("simpleui: incompatible plugin detected (manual block)")
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Project: Title is not compatible with Simple UI.")
                    .. "\n\n" .. _("Please delete the Project: Title plugin from your plugins folder and restart KOReader."),
                show_icon = false,
            })
        end)
        return true
    end

    if not G_reader_settings then
        schedule_coverbrowser_check()
        return false
    end

    local disabled_list = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled_list) ~= "table" then disabled_list = {} end

    local needs_restart = false
    local disabled_labels = {}

    -- ZenOS: folder or known runtime markers, even if sentinel not loaded yet.
    if is_zenos_present() and disabled_list["zenos"] == nil then
        disabled_list["zenos"] = true
        disabled_labels[#disabled_labels + 1] = "ZenOS"
        needs_restart = true
    elseif disabled_list["zenos"] ~= nil and is_zenos_present()
            and package.loaded["common/zen_logger"] ~= nil then
        disabled_labels[#disabled_labels + 1] = "ZenOS"
        needs_restart = true
    end

    for _i, entry in ipairs(AUTO_DISABLE) do
        if entry.folder_key == "zenos" then
            -- handled above
        else
            local sentinel_loaded = package.loaded[entry.sentinel] ~= nil
            local folder_installed = entry.folder_key and plugin_folder_exists(entry.folder_key)
            local folder_enabled = folder_installed and disabled_list[entry.folder_key] == nil
            if sentinel_loaded or folder_enabled then
                local dir = get_dir_from_loaded(entry.sentinel)
                local folder_key = folder_enabled and entry.folder_key or get_folder_key(dir)
                if entry.expected_folder_key and folder_key and folder_key ~= entry.expected_folder_key then
                    -- skip false positive from a different plugin
                else
                    folder_key = folder_key or entry.folder_key or entry.fallback_key
                    if disabled_list[folder_key] ~= nil and sentinel_loaded then
                        disabled_labels[#disabled_labels + 1] = entry.label
                        needs_restart = true
                    elseif disabled_list[folder_key] == nil then
                        disabled_list[folder_key] = true
                        disabled_labels[#disabled_labels + 1] = entry.label
                        needs_restart = true
                    end
                end
            end
        end
    end

    if DISABLE_CONFLICTING_PATCHES then
        for _i, filename in ipairs(disable_conflicting_patches()) do
            disabled_labels[#disabled_labels + 1] = filename
            needs_restart = true
        end
    end

    if needs_restart then
        G_reader_settings:saveSetting("plugins_disabled", disabled_list)
        G_reader_settings:flush()
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
            local ConfirmBox = require("ui/widget/confirmbox")
            local Event = require("ui/event")
            UIManager:show(ConfirmBox:new{
                text = _("Incompatible items have been disabled:")
                    .. "\n" .. table.concat(disabled_labels, "\n"),
                dismissable = false,
                no_ok_button = true,
                cancel_text = _("Restart now"),
                cancel_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            })
        end)
        return true
    end

    schedule_coverbrowser_check()
    return false
end

return apply_compat_check
