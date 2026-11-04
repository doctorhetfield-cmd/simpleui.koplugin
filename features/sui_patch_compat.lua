-- sui_patch_compat.lua — Simple UI
-- Finds user patches known to clash with Simple UI and offers to disable them.
--
-- A disabled patch is renamed to <name>.disabled, the same way the native patch
-- management menu does it, so it can be enabled again from there. A patch that
-- the user keeps is remembered and not offered again. A patch that came back
-- under its own name after Simple UI disabled it was enabled on purpose, so it
-- is kept as well.
--
-- Patches run before the plugins start, so a change only takes effect after a
-- restart; the dialog ends with one.
--
-- Public API
--   PatchCompat.check() -> bool    true when the dialog is shown, i.e. startup
--                                  must stop
--   PatchCompat.detect(dir, allowed, disabled) -> found, reenabled
--   PatchCompat.apply(dir, found, selected)

local _           = require("infra/sui_i18n").translate
local SUISettings = require("infra/sui_store")

local PatchCompat = {}

local ALLOWED_KEY  = "simpleui_patch_compat_allowed"
local DISABLED_KEY = "simpleui_patch_compat_disabled"

-- A patch whose source contains this name already supports Simple UI.
local ADAPTED_MARKER = "_simpleui_native_build"

-- Patches that clash with Simple UI, grouped by the reason. Built on demand so
-- the reasons are translated when they are shown.
local function catalog()
    return {
        {
            reason = _("Replaces the navigation bar or the quick settings"),
            files  = { "2-navbar-vos.lua", "2-custom-navbar.lua", "2-quick-settings.lua" },
        },
        {
            reason = _("Replaces the title bar"),
            files  = {
                "2-filemanager-titlebar.lua", "2-filemanager-title-bar.lua", "2-custom-titlebar.lua",
                "2-filemanager-metadata-tabs.lua",
            },
        },
        {
            reason = _("Changes the size of the menus or the fonts"),
            files  = { "2-menu-size.lua", "2--ui-font.lua", "2-ui-font.lua" },
        },
        {
            reason = _("Duplicates the author and series browser"),
            files  = { "2-author-series.lua", "2-browser-up-folder.lua" },
        },
        {
            reason = _("Draws on the book covers without supporting Simple UI"),
            files  = {
                "2-pages-badge_estimate.lua", "2-finished-badge.lua", "2-reading-percentage.lua",
                "2-real-books.lua", "2-percent-badge.lua", "2-mosaicmenu-hide-bookstatusicons.lua",
            },
        },
        {
            reason = _("Replaces the folder covers"),
            files  = { "2-rounded-folder-covers.lua" },
        },
        {
            reason = _("Hides Wi-Fi dialogs, and any other dialog that mentions Wi-Fi"),
            files  = { "2-disable-wifi-notifications.lua", "2-non-blocking-wifi.lua" },
        },
        {
            reason = _("Changes how books are opened from the file browser"),
            files  = { "2-browser-double-tap.lua" },
        },
    }
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local source = f:read("*a")
    f:close()
    return source or ""
end

local function exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

-- Patches of the catalog present in `dir` and not allowed, as
-- { { file, reason }, ... }. `reenabled` lists the ones Simple UI had disabled
-- and that are active again. A patch with a .disabled copy beside it is left alone.
function PatchCompat.detect(dir, allowed, disabled)
    local found, reenabled = {}, {}
    for _i, group in ipairs(catalog()) do
        for _j, file in ipairs(group.files) do
            local source = readAll(dir .. "/" .. file)
            if source and not allowed[file]
                    and not source:find(ADAPTED_MARKER, 1, true)
                    and not exists(dir .. "/" .. file .. ".disabled") then
                if disabled[file] then
                    reenabled[#reenabled + 1] = file
                else
                    found[#found + 1] = { file = file, reason = group.reason }
                end
            end
        end
    end
    return found, reenabled
end

-- The settings directory is created later in startup, so a write made before
-- that would be lost.
local function ensureSettingsDir()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_ds and ok_lfs) then return end
    local dir = DataStorage:getSettingsDir() .. "/simpleui"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
end

local function allow(files)
    ensureSettingsDir()
    local allowed = SUISettings:get(ALLOWED_KEY) or {}
    for _i, file in ipairs(files) do allowed[file] = true end
    SUISettings:set(ALLOWED_KEY, allowed)
end

-- Disables the patches of `found` flagged in `selected`; the others are allowed.
function PatchCompat.apply(dir, found, selected)
    local disabled = SUISettings:get(DISABLED_KEY) or {}
    local kept, renamed = {}, false
    for _i, item in ipairs(found) do
        local path = dir .. "/" .. item.file
        if selected[item.file] and os.rename(path, path .. ".disabled") then
            disabled[item.file] = true
            renamed = true
        elseif not selected[item.file] then
            kept[#kept + 1] = item.file
        end
    end
    if renamed then
        ensureSettingsDir()
        SUISettings:set(DISABLED_KEY, disabled)
    end
    if #kept > 0 then allow(kept) end
end

local function restart()
    local Event = require("ui/event")
    require("ui/uimanager"):broadcastEvent(Event:new("Restart"))
end

local function message()
    return _("These patches clash with Simple UI and can cause crashes or a broken layout. The checked ones will be disabled. Uncheck a patch to keep it, at your own risk. A disabled patch can be enabled again in Patch management.")
end

-- Plain question, used when the sheet cannot be built.
local function showFallback(dir, found)
    local ConfirmBox = require("ui/widget/confirmbox")
    local names, all = {}, {}
    for _i, item in ipairs(found) do
        names[#names + 1] = item.file
        all[item.file] = true
    end
    require("ui/uimanager"):show(ConfirmBox:new{
        text        = message() .. "\n\n" .. table.concat(names, "\n"),
        dismissable = false,
        ok_text     = _("Disable and restart"),
        cancel_text = _("Keep and restart"),
        ok_callback = function()
            PatchCompat.apply(dir, found, all)
            restart()
        end,
        cancel_callback = function()
            PatchCompat.apply(dir, found, {})
            restart()
        end,
    })
end

local function showSheet(dir, found)
    local ActionSheet = require("engines/sui_action_sheet")
    local selected = {}
    for _i, item in ipairs(found) do selected[item.file] = true end

    local window
    local function sections()
        local list, rows, last_reason = {}, nil, nil
        for _i, item in ipairs(found) do
            if item.reason ~= last_reason then
                last_reason = item.reason
                rows = {}
                list[#list + 1] = { type = "note", text = item.reason }
                list[#list + 1] = { type = "rows", rows = rows }
            end
            local file = item.file
            rows[#rows + 1] = { {
                text     = file:gsub("%.lua$", ""),
                toggle   = selected[file] == true,
                callback = function()
                    selected[file] = not selected[file] or nil
                    window:update{ sections = sections() }
                end,
            } }
        end
        list[#list + 1] = { type = "segments", items = { {
            text     = _("Apply and restart"),
            primary  = true,
            callback = function()
                window:close()
                PatchCompat.apply(dir, found, selected)
                restart()
            end,
        } } }
        return list
    end

    window = ActionSheet.show{
        name        = "sui_win_patch_compat",
        title       = _("Incompatible patches"),
        message     = message(),
        dismissable = false,
        sections    = sections(),
    }
end

local function show(dir, found)
    require("ui/uimanager"):scheduleIn(0.5, function()
        if not pcall(showSheet, dir, found) then showFallback(dir, found) end
    end)
end

function PatchCompat.check()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return false end
    local ok_up, userpatch = pcall(require, "userpatch")
    if ok_up and userpatch.arePatchesDisabled and userpatch.arePatchesDisabled() then
        return false
    end

    local dir = DataStorage:getPatchesDir()
    local found, reenabled = PatchCompat.detect(dir,
        SUISettings:get(ALLOWED_KEY) or {}, SUISettings:get(DISABLED_KEY) or {})
    if #reenabled > 0 then allow(reenabled) end
    if #found == 0 then return false end

    show(dir, found)
    return true
end

return PatchCompat
