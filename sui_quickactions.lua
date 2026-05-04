-- sui_quickactions.lua — Simple UI
-- Single source of truth for Quick Actions:
--   • Storage: custom QA CRUD, default-action label/icon overrides
--   • Resolution: getEntry(id) — used by both bottombar and module_quick_actions
--   • Menus: icon picker, rename dialog, create/edit/delete flows
--
-- Both sui_bottombar (buildTabCell) and module_quick_actions (buildQAWidget)
-- call QA.getEntry(id) so every label/icon change propagates everywhere
-- automatically.  sui_menu.lua calls QA.makeMenuItems(plugin) to obtain
-- the Create / Change Icons / Rename sub-menu items.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _ = require("sui_i18n").translate
local N_ = require("sui_i18n").ngettext

local Config    = require("sui_config")

local QA = {}

-- ---------------------------------------------------------------------------
-- Icon directory (same as before — single definition now)
-- ---------------------------------------------------------------------------

-- Resolve icons/custom directory using an absolute path derived from this
-- file's location so it works on Android (relative paths fail there).
local _qa_plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
QA.ICONS_DIR = _qa_plugin_dir .. "icons/custom"

-- ---------------------------------------------------------------------------
-- Custom Quick Actions persistence
-- CRUD for custom QA entries: list management, per-entry config, key cache,
-- collection purge/rename, slot sanitization, id generation.
-- ---------------------------------------------------------------------------
-- Key cache: avoids rebuilding "navbar_cqa_<id>" strings on every call.
-- These keys are stable within a session (IDs never change after creation).
local _qa_key_cache = {}
local function getQASettingsKey(qa_id)
    local k = _qa_key_cache[qa_id]
    if not k then
        k = "navbar_cqa_" .. qa_id
        _qa_key_cache[qa_id] = k
    end
    return k
end

function QA.getCustomQAList()
    return G_reader_settings:readSetting("navbar_custom_qa_list") or {}
end

function QA.saveCustomQAList(list)
    G_reader_settings:saveSetting("navbar_custom_qa_list", list)
end

function QA.getCustomQAConfig(qa_id)
    local cfg = G_reader_settings:readSetting(getQASettingsKey(qa_id)) or {}
    return {
        label             = cfg.label or qa_id,
        path              = cfg.path,
        collection        = cfg.collection,
        plugin_key        = cfg.plugin_key,
        plugin_method     = cfg.plugin_method,
        dispatcher_action = cfg.dispatcher_action,
        icon              = cfg.icon,
    }
end

function QA.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action)
    G_reader_settings:saveSetting(getQASettingsKey(qa_id), {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        icon              = icon,
    })
end

function QA.deleteCustomQA(qa_id)
    G_reader_settings:delSetting(getQASettingsKey(qa_id))
    _qa_key_cache[qa_id] = nil  -- remove from key cache
    local list = QA.getCustomQAList()
    local new_list = {}
    for _i, id in ipairs(list) do
        if id ~= qa_id then new_list[#new_list + 1] = id end
    end
    QA.saveCustomQAList(new_list)
    -- Invalidate the module-level QA validity cache so the next render does
    -- not show a deleted action.
    local mqa = package.loaded["desktop_modules/module_quick_actions"]
    if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        local new_tabs = {}
        for _i, id in ipairs(tabs) do
            if id ~= qa_id then new_tabs[#new_tabs + 1] = id end
        end
        G_reader_settings:saveSetting("navbar_tabs", new_tabs)
    end
    -- Remove from all page QA slots
    for _i, pfx in ipairs({ "navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key = pfx .. slot .. "_items"
            local dqa = G_reader_settings:readSetting(key)
            if type(dqa) == "table" then
                local new_dqa = {}
                for _i, id in ipairs(dqa) do
                    if id ~= qa_id then new_dqa[#new_dqa + 1] = id end
                end
                G_reader_settings:saveSetting(key, new_dqa)
            end
        end
    end
end

-- Removes all custom QA entries that reference a deleted collection name.
-- Called by patches.lua when removeCollection fires.
function QA.purgeQACollection(coll_name)
    local list    = QA.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = QA.getCustomQAConfig(qa_id)
        if cfg.collection == coll_name then
            -- Wipe the collection field so the QA becomes unconfigured
            -- (keeps the entry visible so the user knows to reconfigure).
            QA.saveCustomQAConfig(qa_id, cfg.label, cfg.path, nil,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Updates collection references in all custom QAs after a rename.
function QA.renameQACollection(old_name, new_name)
    local list    = QA.getCustomQAList()
    local changed = false
    for _i, qa_id in ipairs(list) do
        local cfg = QA.getCustomQAConfig(qa_id)
        if cfg.collection == old_name then
            QA.saveCustomQAConfig(qa_id, cfg.label, cfg.path, new_name,
                cfg.icon, cfg.plugin_key, cfg.plugin_method, cfg.dispatcher_action)
            changed = true
        end
    end
    return changed
end

-- Removes orphaned custom QA ids from all QA slots.
-- An id is orphaned when it is referenced in a slot but not in the master list.
-- Safe to call at startup and after any QA deletion.
function QA.sanitizeQASlots()
    local Config = require("sui_config")

    -- 0. Clean the master list itself: remove any ID whose config record is
    --    missing or empty (orphaned entry with no label/path/etc.).
    --    This is the root cause of "invalid items that can't be removed".
    local list = QA.getCustomQAList()
    local clean_list = {}
    local list_changed = false
    for _i, id in ipairs(list) do
        if id:match("^custom_qa_%d+$") then
            local cfg = G_reader_settings:readSetting(getQASettingsKey(id))
            if type(cfg) == "table" and next(cfg) then
                clean_list[#clean_list + 1] = id
            else
                list_changed = true  -- orphan: no config record
            end
        else
            list_changed = true  -- malformed ID
        end
    end
    if list_changed then
        QA.saveCustomQAList(clean_list)
        list = clean_list
    end

    local valid_custom = {}
    for _i, id in ipairs(list) do valid_custom[id] = true end
    local changed = list_changed

    -- 1. Clean navbar_homescreen_quick_actions_N_items (HS quick-action slots).
    for _, pfx in ipairs({ "navbar_homescreen_quick_actions_" }) do
        for slot = 1, 3 do
            local key  = pfx .. slot .. "_items"
            local items = G_reader_settings:readSetting(key)
            if type(items) == "table" then
                local clean = {}
                local slot_changed = false
                for _i, id in ipairs(items) do
                    if not id:match("^custom_qa_%d+$") or valid_custom[id] then
                        clean[#clean+1] = id
                    else
                        slot_changed = true
                        changed = true
                    end
                end
                if slot_changed then G_reader_settings:saveSetting(key, clean) end
            end
        end
    end

    -- 2. Clean navbar_tabs — remove IDs that are neither a known built-in nor
    --    a live custom QA.  loadTabConfig already silently skips unknowns but
    --    never writes them back, so stale IDs persist across restarts.
    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        local clean_tabs = {}
        local tabs_changed = false
        for _i, id in ipairs(tabs) do
            if Config.ACTION_BY_ID[id]
                    or (id:match("^custom_qa_%d+$") and valid_custom[id]) then
                clean_tabs[#clean_tabs + 1] = id
            else
                tabs_changed = true
                changed = true
            end
        end
        if tabs_changed then
            G_reader_settings:saveSetting("navbar_tabs", clean_tabs)
            Config.invalidateTabsCache()
        end
    end

    if changed then
        local mqa = package.loaded["desktop_modules/module_quick_actions"]
        if mqa and mqa.invalidateCustomQACache then mqa.invalidateCustomQACache() end
    end
    return changed
end

function QA.nextCustomQAId()
    local list  = QA.getCustomQAList()
    local max_n = 0
    for _i, id in ipairs(list) do
        local n = tonumber(id:match("^custom_qa_(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local n = max_n + 1
    while G_reader_settings:readSetting("navbar_cqa_custom_qa_" .. n) do n = n + 1 end
    return "custom_qa_" .. n
end

function QA.clearQAKeyCache()
    for k in pairs(_qa_key_cache) do _qa_key_cache[k] = nil end
end

-- ---------------------------------------------------------------------------
-- Default-action label / icon overrides
-- Setting keys: navbar_action_<id>_label  /  navbar_action_<id>_icon
-- These are the authoritative get/set functions; sui_config.lua delegates
-- to here for any external callers that still use Config.get/setDefaultAction*.
-- ---------------------------------------------------------------------------

local function _defaultLabelKey(id) return "navbar_action_" .. id .. "_label" end
local function _defaultIconKey(id)  return "navbar_action_" .. id .. "_icon"  end

function QA.getDefaultActionLabel(id)
    return G_reader_settings:readSetting(_defaultLabelKey(id))
end

function QA.getDefaultActionIcon(id)
    return G_reader_settings:readSetting(_defaultIconKey(id))
end

function QA.setDefaultActionLabel(id, label)
    if label and label ~= "" then
        G_reader_settings:saveSetting(_defaultLabelKey(id), label)
    else
        G_reader_settings:delSetting(_defaultLabelKey(id))
    end
end

function QA.setDefaultActionIcon(id, icon)
    if icon then
        G_reader_settings:saveSetting(_defaultIconKey(id), icon)
    else
        G_reader_settings:delSetting(_defaultIconKey(id))
    end
end

-- ---------------------------------------------------------------------------
-- getEntry(id) — canonical resolver used by ALL rendering code
--
-- Returns { icon = path, label = string } for any action id.
-- Applies label/icon overrides for default actions.
-- For custom QAs: reads from settings directly (same key as sui_config).
-- Never returns nil.
-- ---------------------------------------------------------------------------

-- Module-level sentinel reused for wifi_toggle to avoid per-call allocation.
local _wifi_entry = { icon = "", label = "" }

function QA.getEntry(id)
    -- Custom QA
    if id and id:match("^custom_qa_%d+$") then
        local cfg = G_reader_settings:readSetting("navbar_cqa_" .. id) or {}
        local default_icon
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = Config.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = Config.CUSTOM_PLUGIN_ICON
        else
            default_icon = Config.CUSTOM_ICON
        end
        return {
            icon  = cfg.icon or default_icon,
            label = cfg.label or id,
        }
    end

    -- Default action: look up catalogue
    local a = Config.ACTION_BY_ID[id]
    if not a then
        logger.warn("simpleui: QA.getEntry: unknown id " .. tostring(id))
        return { icon = Config.ICON.library, label = tostring(id) }
    end

    -- wifi_toggle: icon is dynamic (on/off state)
    if id == "wifi_toggle" then
        _wifi_entry.icon  = QA.getDefaultActionIcon(id) or Config.wifiIcon()
        _wifi_entry.label = QA.getDefaultActionLabel(id) or a.label
        return _wifi_entry
    end

    -- All other defaults: apply overrides if present
    local lbl_ov  = QA.getDefaultActionLabel(id)
    local icon_ov = QA.getDefaultActionIcon(id)
    if not lbl_ov and not icon_ov then
        return a  -- fast path: catalogue entry, no allocation
    end
    return {
        icon  = icon_ov  or a.icon,
        label = lbl_ov   or a.label,
    }
end

-- ---------------------------------------------------------------------------
-- Custom QA validity cache
-- Shared between module_quick_actions slots so it is built at most once per
-- render cycle. Invalidate after any create/delete.
-- ---------------------------------------------------------------------------

local _cqa_valid_cache = nil

function QA.getCustomQAValid()
    if not _cqa_valid_cache then
        local list = Config.getCustomQAList()
        local s = {}
        for _, id in ipairs(list) do s[id] = true end
        _cqa_valid_cache = s
    end
    return _cqa_valid_cache
end

function QA.invalidateCustomQACache()
    _cqa_valid_cache = nil
end

-- ---------------------------------------------------------------------------
-- Icon picker
-- ---------------------------------------------------------------------------

local function _loadCustomIconList()
    local icons = {}
    local attr  = lfs.attributes(QA.ICONS_DIR)
    if not attr or attr.mode ~= "directory" then return icons end
    for fname in lfs.dir(QA.ICONS_DIR) do
        if fname:match("%.[Ss][Vv][Gg]$") or fname:match("%.[Pp][Nn][Gg]$") then
            local path  = QA.ICONS_DIR .. "/" .. fname
            local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
            icons[#icons + 1] = { path = path, label = label }
        end
    end
    table.sort(icons, function(a, b) return a.label:lower() < b.label:lower() end)
    return icons
end

-- Shows a preview dialog for a validated Nerd Font icon.
-- on_confirm(sentinel) applies the icon; on_back() reopens the input dialog.
local function _showNerdIconPreview(sentinel, on_confirm, on_back)
    local ConfirmBox = require("ui/widget/confirmbox")
    local nerd_char  = Config.nerdIconChar(sentinel)
    local hex        = sentinel:match("nerd:(.+)")

    -- ConfirmBox is a proper FocusManager subclass: Left/Right/Press/Back all
    -- work out of the box and it correctly resets the device text-input state
    -- that InputDialog left behind (which was preventing key events from reaching
    -- our previous custom FocusManager overlay).
    UIManager:show(ConfirmBox:new{
        text        = ("U+%s  %s"):format(hex, nerd_char) .. "\n\n" ..
                      _("Use this Nerd Font icon?"),
        ok_text     = _("Confirm"),
        cancel_text = _("Cancel"),
        ok_callback = function() on_confirm(sentinel) end,
        cancel_callback = function() if on_back then on_back() end end,
    })
end

-- Opens an InputDialog for entering a Nerd Font hex codepoint.
-- on_select is called with "nerd:XXXX" on success, or nothing on cancel.
local function _showNerdIconInput(current_icon, on_select, on_cancel)
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")

    -- Pre-fill with the current hex code if the icon is already a Nerd Font.
    local current_hex = ""
    if current_icon then
        current_hex = current_icon:match("^nerd:([0-9A-Fa-f]+)$") or ""
    end

    local dlg
    local function _openInputDlg()
        dlg = InputDialog:new{
            title       = _("Nerd Font Icon"),
            input       = current_hex:upper(),
            input_hint  = _("hex code, e.g. E001"),
            description = _("Enter the Unicode codepoint (hex) of a Nerd Fonts symbol.\nYou can look up codes with wakamaifondue.com using the file:\n  /koreader/fonts/nerdfonts/symbols.ttf\nLeave blank and press OK to remove a Nerd Font icon."),
            buttons = {{
                {
                    text     = _("Cancel"),
                    callback = function()
                        UIManager:close(dlg)
                        if on_cancel then on_cancel() end
                    end,
                },
                {
                    text             = _("OK"),
                    is_enter_default = true,
                    callback         = function()
                        local raw = dlg:getInputText()
                        -- Empty input â clear the nerd icon (caller gets nil).
                        if raw:match("^%s*$") then
                            UIManager:close(dlg)
                            on_select(nil)
                            return
                        end
                        local hex = raw:match("^%s*([0-9A-Fa-f]+)%s*$")
                        if hex and #hex >= 1 and #hex <= 6 then
                            -- Validate that Config can convert it (range check).
                            local sentinel = "nerd:" .. hex:upper()
                            if Config.nerdIconChar(sentinel) then
                                -- Close dlg first, then show preview on top.
                                -- Cancel in preview reopens the InputDialog via nextTick
                                -- so the tap that closed the preview is fully consumed
                                -- before the new dialog appears (otherwise the same tap
                                -- event lands on the freshly-opened dialog and closes it).
                                UIManager:close(dlg)
                                _showNerdIconPreview(sentinel,
                                    on_select,
                                    function() UIManager:nextTick(_openInputDlg) end)
                            else
                                UIManager:show(InfoMessage:new{
                                    text    = _("Codepoint out of valid Unicode range (0–10FFFF)."),
                                    timeout = 3,
                                })
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text    = _("Invalid input. Please enter 1–6 hexadecimal digits (0–9, A–F)."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
    end
    _openInputDlg()
end

-- on_select(path_or_nil) is called with the chosen icon path, or nil for "reset".
-- _picker_handle: table where the open dialog will be stored (e.g. plugin table).
-- picker_key: key on that table (e.g. "_qa_icon_picker").
function QA.showIconPicker(current_icon, on_select, default_label, _picker_handle, picker_key)
    _picker_handle = _picker_handle or QA
    picker_key     = picker_key     or "_icon_picker"

    local ButtonDialog = require("ui/widget/buttondialog")
    local icons   = _loadCustomIconList()
    local buttons = {}

    -- "Default" row — marked when no custom icon is active.
    local is_nerd    = Config.isNerdIcon(current_icon)
    local is_svg     = current_icon and not is_nerd
    local default_marker = (not current_icon) and "  ✓" or ""
    buttons[#buttons + 1] = {{
        text     = (default_label or _("Default")) .. default_marker,
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            on_select(nil)
        end,
    }}

    -- "Nerd Font…" row — opens the hex input dialog.
    local nerd_char   = Config.nerdIconChar(current_icon)
    local nerd_marker = is_nerd and ("  " .. nerd_char .. "  ✓") or ""
    buttons[#buttons + 1] = {{
        text     = _("Nerd Font symbol…") .. nerd_marker,
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            _showNerdIconInput(current_icon, function(new_icon)
                on_select(new_icon)
            end, function()
                QA.showIconPicker(current_icon, on_select, default_label, _picker_handle, picker_key)
            end)
        end,
    }}

    if #icons == 0 then
        buttons[#buttons + 1] = {{
            text    = _("No icons found in:") .. "\n" .. QA.ICONS_DIR,
            enabled = false,
        }}
    else
        for _i, icon in ipairs(icons) do
            local p = icon
            buttons[#buttons + 1] = {{
                text     = p.label .. ((is_svg and current_icon == p.path) and "  ✓" or ""),
                callback = function()
                    UIManager:close(_picker_handle[picker_key])
                    on_select(p.path)
                end,
            }}
        end
    end
    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(_picker_handle[picker_key]) end,
    }}
    _picker_handle[picker_key] = ButtonDialog:new{ buttons = buttons }
    UIManager:show(_picker_handle[picker_key])
end

-- ---------------------------------------------------------------------------
-- Plugin scanner helpers (used by showQuickActionDialog)
-- ---------------------------------------------------------------------------

local function _scanFMPlugins()
    local fm = package.loaded["apps/filemanager/filemanager"]
    fm = fm and fm.instance
    if not fm then return {} end
    local known = {
        { key = "history",          method = "onShowHist",                      title = _("History")           },
        { key = "bookinfo",         method = "onShowBookInfo",                  title = _("Book Info")         },
        { key = "collections",      method = "onShowColl",                      title = _("Favorites")         },
        { key = "collections",      method = "onShowCollList",                  title = _("Collections")       },
        { key = "filesearcher",     method = "onShowFileSearch",                title = _("File Search")       },
        { key = "folder_shortcuts", method = "onShowFolderShortcutsDialog",     title = _("Folder Shortcuts")  },
        { key = "dictionary",       method = "onShowDictionaryLookup",          title = _("Dictionary Lookup") },
        { key = "wikipedia",        method = "onShowWikipediaLookup",           title = _("Wikipedia Lookup")  },
    }
    local results = {}
    for _, entry in ipairs(known) do
        local mod = fm[entry.key]
        if mod and type(mod[entry.method]) == "function" then
            results[#results + 1] = { fm_key = entry.key, fm_method = entry.method, title = entry.title }
        end
    end
    local native_keys = {
        screenshot=true, menu=true, history=true, bookinfo=true, collections=true,
        filesearcher=true, folder_shortcuts=true, languagesupport=true,
        dictionary=true, wikipedia=true, devicestatus=true, devicelistener=true,
        networklistener=true,
    }
    local our_name  = "simpleui"
    local seen_keys = {}
    local fm_val_to_key = {}
    for k, v in pairs(fm) do
        if type(k) == "string" and type(v) == "table" then fm_val_to_key[v] = k end
    end
    for i = 1, #fm do
        local val = fm[i]
        if type(val) ~= "table" or type(val.name) ~= "string" then goto cont end
        local fm_key = fm_val_to_key[val]
        if not fm_key or native_keys[fm_key] or seen_keys[fm_key] or fm_key == our_name then goto cont end
        if type(val.addToMainMenu) ~= "function" then goto cont end
        seen_keys[fm_key] = true
        local method = nil
        for _, pfx in ipairs({"onShow","show","open","launch","onOpen"}) do
            if type(val[pfx]) == "function" then method = pfx; break end
        end
        if not method then
            local cap = "on" .. fm_key:sub(1,1):upper() .. fm_key:sub(2)
            if type(val[cap]) == "function" then method = cap end
        end
        -- Fallback: extract the callback from addToMainMenu and wrap it as a
        -- synthetic method (_sui_launch). This covers plugins that only expose
        -- their entry point as an inline callback in addToMainMenu (e.g.
        -- solitaire, audiobookshelf, killersudoku, rakuyomi).
        if not method then
            local probe = {}
            local ok = pcall(function() val:addToMainMenu(probe) end)
            if ok then
                local entry = probe[fm_key] or probe[val.name]
                if entry and type(entry.callback) == "function" then
                    local cb = entry.callback
                    val._sui_launch = function(_self) cb() end
                    method = "_sui_launch"
                end
            end
        end
        if method then
            local raw     = (val.name or fm_key):gsub("^filemanager", "")
            local display = raw:sub(1,1):upper() .. raw:sub(2)
            -- Prefer the menu text provided by addToMainMenu when available,
            -- as it is already localised and more descriptive than the key.
            local probe2 = {}
            local ok2 = pcall(function() val:addToMainMenu(probe2) end)
            if ok2 then
                local entry2 = probe2[fm_key] or probe2[val.name]
                if entry2 and type(entry2.text) == "string" and entry2.text ~= "" then
                    display = entry2.text
                end
            end
            results[#results + 1] = { fm_key = fm_key, fm_method = method, title = display }
        end
        ::cont::
    end
    table.sort(results, function(a, b) return a.title < b.title end)
    return results
end

local function _scanDispatcherActions()
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)
    local settingsList, dispatcher_menu_order
    pcall(function()
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList"          then settingsList          = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
    end)
    if type(settingsList) ~= "table" then return {} end
    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local t = {}
            for k in pairs(settingsList) do t[#t+1] = k end
            table.sort(t)
            return t
        end)()
    local results = {}
    for _i, action_id in ipairs(order) do
        local def = settingsList[action_id]
        if type(def) == "table" and def.title and def.category == "none"
                and (def.condition == nil or def.condition == true) then
            results[#results + 1] = { id = action_id, title = tostring(def.title) }
        end
    end
    table.sort(results, function(a, b) return a.title < b.title end)
    return results
end

-- ---------------------------------------------------------------------------
-- Create / Edit dialog
-- plugin: the SimpleUI plugin instance (for _rebuildAllNavbars)
-- qa_id:  existing id to edit, or nil to create new
-- on_done: optional zero-arg callback after save
-- ---------------------------------------------------------------------------

function QA.showQuickActionDialog(plugin, qa_id, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local InfoMessage      = require("ui/widget/infomessage")
    local ButtonDialog     = require("ui/widget/buttondialog")

    local getNonFavColl    = Config.getNonFavoritesCollections
    local collections      = getNonFavColl and getNonFavColl() or {}
    table.sort(collections, function(a, b) return a:lower() < b:lower() end)

    local cfg         = qa_id and Config.getCustomQAConfig(qa_id) or {}
    local start_path  = cfg.path or G_reader_settings:readSetting("home_dir") or "/"
    local chosen_icon = cfg.icon
    local dlg_title   = qa_id and _("Edit Quick Action") or _("New Quick Action")
    local TOTAL_H     = require("sui_bottombar").TOTAL_H

    local function iconButtonLabel(default_lbl)
        if not chosen_icon then return default_lbl or _("Icon: Default") end
        local nerd_char = Config.nerdIconChar(chosen_icon)
        if nerd_char then
            -- Show the rendered glyph plus the hex code as confirmation.
            local hex = chosen_icon:match("nerd:(.+)")
            return _("Icon") .. ": " .. nerd_char .. " (" .. hex .. ")"
        end
        local fname = chosen_icon:match("([^/]+)$") or chosen_icon
        local stem  = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
        return _("Icon") .. ": " .. stem
    end

    local function commitQA(final_label, path, coll, default_icon, fm_key, fm_method, dispatcher_action)
        local final_id = qa_id or Config.nextCustomQAId()
        if not qa_id then
            local list = Config.getCustomQAList()
            list[#list + 1] = final_id
            Config.saveCustomQAList(list)
        end
        Config.saveCustomQAConfig(final_id, final_label, path, coll,
            chosen_icon or default_icon, fm_key, fm_method, dispatcher_action)
        QA.invalidateCustomQACache()
        plugin:_rebuildAllNavbars()
        if on_done then on_done() end
    end

    local active_dialog = nil

    local function _buildSaveDialog(spec)
        if active_dialog then UIManager:close(active_dialog); active_dialog = nil end

        local function openIconPicker()
            if active_dialog then UIManager:close(active_dialog); active_dialog = nil end
            QA.showIconPicker(chosen_icon, function(new_icon)
                chosen_icon = new_icon
                _buildSaveDialog(spec)
            end, spec.icon_default_label, plugin, "_qa_icon_picker")
        end

        local fields = {}
        for _i, f in ipairs(spec.fields) do
            fields[#fields + 1] = { description = f.description, text = f.text or "", hint = f.hint }
        end

        active_dialog = MultiInputDialog:new{
            title  = dlg_title,
            fields = fields,
            buttons = {
                { { text = iconButtonLabel(spec.icon_default_label),
                    callback = function() openIconPicker() end } },
                { { text = _("Cancel"),
                    callback = function() UIManager:close(active_dialog); active_dialog = nil end },
                  { text = _("Save"), is_enter_default = true,
                    callback = function()
                        local inputs = active_dialog:getFields()
                        if spec.validate then
                            local err = spec.validate(inputs)
                            if err then
                                UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                                return
                            end
                        end
                        UIManager:close(active_dialog); active_dialog = nil
                        spec.on_save(inputs)
                    end } },
            },
        }
        UIManager:show(active_dialog)
        pcall(function() active_dialog:onShowKeyboard() end)
    end

    local sanitize = Config.sanitizeLabel


    local function openFolderPicker()
        local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
        if not ok_pc or not PathChooser then
            UIManager:show(InfoMessage:new{ text = _("Path chooser not available."), timeout = 3 })
            return
        end
        local pc = PathChooser:new{
            select_directory = true,
            select_file      = false,
            show_files       = false,
            path             = start_path,
            onConfirm        = function(chosen_path)
                -- Strip trailing slash for consistency with the rest of the plugin.
                chosen_path = chosen_path:gsub("/$", "")
                local default_label = chosen_path:match("([^/]+)$") or chosen_path
                -- Defer until the PathChooser has fully closed and all pending
                -- input events (tap/hold_release) have been consumed, otherwise
                -- the dialog opens and is immediately closed by the lingering event.
                UIManager:scheduleIn(0.3, function()
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or default_label, hint = _("e.g. Comics…") } },
                        icon_default_label = _("Default (Folder)"),
                        on_save = function(inputs)
                            commitQA(sanitize(inputs[1]) or default_label, chosen_path, nil, Config.CUSTOM_ICON)
                        end,
                    })
                end)
            end,
        }
        UIManager:show(pc)
    end

    local function openCollectionPicker()
        local buttons = {}
        for _i, coll_name in ipairs(collections) do
            local name = coll_name
            buttons[#buttons + 1] = {{ text = name, callback = function()
                UIManager:close(plugin._qa_coll_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or name, hint = _("e.g. Sci-Fi…") } },
                    icon_default_label = _("Default (Folder)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or name, nil, name, Config.CUSTOM_ICON)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_coll_picker) end }}
        plugin._qa_coll_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_coll_picker)
    end

    local function openPluginPicker()
        local plugin_actions = _scanFMPlugins()
        if #plugin_actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 })
            return
        end
        local buttons = {}
        table.sort(plugin_actions, function(a, b) return a.title:lower() < b.title:lower() end)
        for _i, a in ipairs(plugin_actions) do
            local _a = a
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager:close(plugin._qa_plugin_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Rakuyomi…") } },
                    icon_default_label = _("Default (Plugin)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or _a.title,
                            nil, nil, Config.CUSTOM_PLUGIN_ICON, _a.fm_key, _a.fm_method, nil)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_plugin_picker) end }}
        plugin._qa_plugin_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_plugin_picker)
    end

    local function openDispatcherPicker()
        local actions = _scanDispatcherActions()
        if #actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            return
        end
        local buttons = {}
        table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
        for _i, a in ipairs(actions) do
            local _a = a
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager:close(plugin._qa_dispatcher_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Sleep, Refresh…") } },
                    icon_default_label = _("Default (System)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or _a.title,
                            nil, nil, Config.CUSTOM_DISPATCHER_ICON, nil, nil, _a.id)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_dispatcher_picker) end }}
        plugin._qa_dispatcher_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_dispatcher_picker)
    end

    local choice_dialog
    choice_dialog = ButtonDialog:new{ buttons = {
        {{ text = _("Folder"),
           callback = function() UIManager:close(choice_dialog); openFolderPicker() end }},
        {{ text = _("Collection"), enabled = #collections > 0,
           callback = function() UIManager:close(choice_dialog); openCollectionPicker() end }},
        {{ text = _("Plugin"),
           callback = function() UIManager:close(choice_dialog); openPluginPicker() end }},
        {{ text = _("System Actions"),
           callback = function() UIManager:close(choice_dialog); openDispatcherPicker() end }},
        {{ text = _("Cancel"),
           callback = function() UIManager:close(choice_dialog) end }},
    }}
    UIManager:show(choice_dialog)
end

-- ---------------------------------------------------------------------------
-- makeMenuItems(plugin) — returns the items table for the Quick Actions menu
-- Called from sui_menu.lua; replaces the old makeQuickActionsMenu closure.
-- ---------------------------------------------------------------------------

function QA.makeMenuItems(plugin)
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InputDialog = require("ui/widget/inputdialog")

    local MAX_CUSTOM_QA = Config.MAX_CUSTOM_QA

    -- All overridable actions (default built-ins + custom QAs), sorted by label.
    local function allActions()
        local pool = {}
        for _, a in ipairs(Config.ALL_ACTIONS) do
            pool[#pool + 1] = { id = a.id, is_default = true }
        end
        for _i, qa_id in ipairs(Config.getCustomQAList()) do
            pool[#pool + 1] = { id = qa_id, is_default = false }
        end
        table.sort(pool, function(a, b)
            return QA.getEntry(a.id).label:lower() < QA.getEntry(b.id).label:lower()
        end)
        return pool
    end

    -- ── Change Icons ─────────────────────────────────────────────────────────

    local function makeChangeIconsMenu()
        local items = {}
        for _i, entry in ipairs(allActions()) do
            local _id         = entry.id
            local _is_default = entry.is_default
            items[#items + 1] = {
                text_func = function()
                    local lbl        = QA.getEntry(_id).label
                    local has_custom = _is_default
                        and QA.getDefaultActionIcon(_id) ~= nil
                        or (not _is_default and (function()
                                local c = Config.getCustomQAConfig(_id)
                                return c.icon ~= nil
                                    and c.icon ~= Config.CUSTOM_ICON
                                    and c.icon ~= Config.CUSTOM_PLUGIN_ICON
                                    and c.icon ~= Config.CUSTOM_DISPATCHER_ICON
                            end)())
                    return lbl .. (has_custom and "  ✎" or "")
                end,
                callback = function()
                    local current_icon
                    if _is_default then
                        current_icon = QA.getDefaultActionIcon(_id)
                    else
                        current_icon = Config.getCustomQAConfig(_id).icon
                    end
                    local default_label = QA.getEntry(_id).label .. " (" .. _("default") .. ")"
                    QA.showIconPicker(current_icon, function(new_icon)
                        if _is_default then
                            QA.setDefaultActionIcon(_id, new_icon)
                        else
                            local c = Config.getCustomQAConfig(_id)
                            local type_default
                            if c.dispatcher_action and c.dispatcher_action ~= "" then
                                type_default = Config.CUSTOM_DISPATCHER_ICON
                            elseif c.plugin_key and c.plugin_key ~= "" then
                                type_default = Config.CUSTOM_PLUGIN_ICON
                            else
                                type_default = Config.CUSTOM_ICON
                            end
                            Config.saveCustomQAConfig(_id, c.label, c.path, c.collection,
                                new_icon or type_default,
                                c.plugin_key, c.plugin_method, c.dispatcher_action)
                        end
                        QA.invalidateCustomQACache()
                        plugin:_rebuildAllNavbars()
                        local ok, HS = pcall(require, "sui_homescreen")
                        if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                    end, default_label, plugin, "_qa_icon_picker")
                end,
            }
        end
        return items
    end

    -- ── Rename ───────────────────────────────────────────────────────────────

    local function makeRenameMenu()
        local items = {}
        for _i, entry in ipairs(allActions()) do
            local _id         = entry.id
            local _is_default = entry.is_default
            items[#items + 1] = {
                text_func = function()
                    local lbl        = QA.getEntry(_id).label
                    local has_custom = _is_default and QA.getDefaultActionLabel(_id) ~= nil
                    return lbl .. (has_custom and "  ✎" or "")
                end,
                callback = function()
                    local current_label = QA.getEntry(_id).label
                    local dlg
                    dlg = InputDialog:new{
                        title      = _("Rename"),
                        input      = current_label,
                        input_hint = _("New name…"),
                        buttons = {{
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(dlg) end,
                            },
                            {
                                text         = _("Reset"),
                                enabled_func = function()
                                    return _is_default and QA.getDefaultActionLabel(_id) ~= nil
                                end,
                                callback = function()
                                    UIManager:close(dlg)
                                    QA.setDefaultActionLabel(_id, nil)
                                    plugin:_rebuildAllNavbars()
                                end,
                            },
                            {
                                text             = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local new_name = Config.sanitizeLabel(dlg:getInputText())
                                    UIManager:close(dlg)
                                    if not new_name then return end
                                    if _is_default then
                                        QA.setDefaultActionLabel(_id, new_name)
                                    else
                                        local c = Config.getCustomQAConfig(_id)
                                        Config.saveCustomQAConfig(_id, new_name,
                                            c.path, c.collection, c.icon,
                                            c.plugin_key, c.plugin_method, c.dispatcher_action)
                                        Config.invalidateTabsCache()
                                    end
                                    QA.invalidateCustomQACache()
                                    plugin:_rebuildAllNavbars()
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    pcall(function() dlg:onShowKeyboard() end)
                end,
            }
        end
        return items
    end

    -- ── Top-level menu ───────────────────────────────────────────────────────

    local items = {}

    items[#items + 1] = {
        text               = _("Change Icons"),
        sub_item_table_func = makeChangeIconsMenu,
    }
    items[#items + 1] = {
        text               = _("Rename"),
        sub_item_table_func = makeRenameMenu,
        separator          = true,
    }
    items[#items + 1] = {
        text         = _("Create Quick Action"),
        enabled_func = function() return #Config.getCustomQAList() < MAX_CUSTOM_QA end,
        callback     = function(_menu_self, suppress_refresh)
            if #Config.getCustomQAList() >= MAX_CUSTOM_QA then
                UIManager:show(InfoMessage:new{
                    text    = string.format(N_("The maximum of %d quick action has been reached. Delete one first.",
                              "The maximum of %d quick actions has been reached. Delete one first.", MAX_CUSTOM_QA), MAX_CUSTOM_QA),
                    timeout = 2,
                })
                return
            end
            if suppress_refresh then suppress_refresh() end
            QA.showQuickActionDialog(plugin, nil, function()
                local ok, HS = pcall(require, "sui_homescreen")
                if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
            end)
        end,
    }

    local qa_list = Config.getCustomQAList()
    if #qa_list == 0 then return items end
    items[#items].separator = true

    -- Pre-read + sort custom QAs by label.
    local sorted_qa = {}
    for _i, qa_id in ipairs(qa_list) do
        local cfg = Config.getCustomQAConfig(qa_id)
        sorted_qa[#sorted_qa + 1] = { id = qa_id, label = cfg.label or qa_id }
    end
    table.sort(sorted_qa, function(a, b) return a.label:lower() < b.label:lower() end)

    for _i, entry in ipairs(sorted_qa) do
        local _id = entry.id
        items[#items + 1] = {
            text_func = function()
                local c = Config.getCustomQAConfig(_id)
                local desc
                if c.dispatcher_action and c.dispatcher_action ~= "" then
                    desc = "⊕ " .. c.dispatcher_action
                elseif c.plugin_key and c.plugin_key ~= "" then
                    desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                elseif c.collection and c.collection ~= "" then
                    desc = "⊞ " .. c.collection
                else
                    desc = c.path or _("not configured")
                    if #desc > 34 then desc = "…" .. desc:sub(-31) end
                end
                return c.label .. "  |  " .. desc
            end,
            sub_item_table_func = function()
                local sub = {}
                sub[#sub + 1] = {
                    text_func = function()
                        local c = Config.getCustomQAConfig(_id)
                        local desc
                        if c.plugin_key and c.plugin_key ~= "" then
                            desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                        elseif c.collection and c.collection ~= "" then
                            desc = "⊞ " .. c.collection
                        else
                            desc = c.path or _("not configured")
                            if #desc > 38 then desc = "…" .. desc:sub(-35) end
                        end
                        return c.label .. "  |  " .. desc
                    end,
                    enabled = false,
                }
                sub[#sub + 1] = {
                    text     = _("Edit"),
                    callback = function(_menu_self, suppress_refresh)
                        if suppress_refresh then suppress_refresh() end
                        QA.showQuickActionDialog(plugin, _id, function()
                            local ok, HS = pcall(require, "sui_homescreen")
                            if ok and HS and HS._instance then HS._instance:_refreshImmediate(false) end
                        end)
                    end,
                }
                sub[#sub + 1] = {
                    text     = _("Delete"),
                    callback = function()
                        local c = Config.getCustomQAConfig(_id)
                        UIManager:show(ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                Config.deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                QA.invalidateCustomQACache()
                                plugin:_rebuildAllNavbars()
                            end,
                        })
                    end,
                }
                return sub
            end,
        }
    end

    return items
end

-- ---------------------------------------------------------------------------
-- executeCustomQA(action_id, fm, show_unavailable_fn)
--
-- Single source of truth for running a custom QA action.
-- Called by sui_bottombar from both _executeInPlace and navigate so that
-- execution logic lives here rather than being duplicated across two call sites.
--
--   action_id           — e.g. "custom_qa_1"
--   fm                  — the live FileManager (or ReaderUI) instance
--   show_unavailable_fn — optional function(msg) for surfacing errors;
--                         defaults to an InfoMessage toast
-- ---------------------------------------------------------------------------
function QA.executeCustomQA(action_id, fm, show_unavailable_fn)
    local function _unavail(msg)
        if show_unavailable_fn then
            show_unavailable_fn(msg)
        else
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
        end
    end

    local cfg = G_reader_settings:readSetting("navbar_cqa_" .. action_id) or {}

    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
        local ok_disp, Dispatcher = pcall(require, "dispatcher")
        if ok_disp and Dispatcher then
            local ok, err = pcall(function()
                Dispatcher:execute({ [cfg.dispatcher_action] = true })
            end)
            if not ok then
                logger.warn("simpleui: dispatcher_action failed:", cfg.dispatcher_action, tostring(err))
                _unavail(string.format(_("System action error: %s"), tostring(err)))
            end
        else
            _unavail(_("Dispatcher not available."))
        end

    elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
        -- Always resolve the live FileManager instance so that a stale `fm`
        -- reference (e.g. captured before a FM recreate) does not cause false
        -- "Plugin not available" errors on the second and subsequent calls
        -- while the homescreen is open (_executeInPlace path).
        local live_fm = package.loaded["apps/filemanager/filemanager"]
        live_fm = live_fm and live_fm.instance
        local effective_fm = (live_fm and live_fm[cfg.plugin_key]) and live_fm or fm
        local plugin_inst = effective_fm and effective_fm[cfg.plugin_key]

        local method = cfg.plugin_method
        if plugin_inst and not plugin_inst[method] and method == "_sui_launch" then
            -- Re-probe for synthetic _sui_launch if missing from the current instance.
            -- This happens after a restart or FM recreate for plugins that only
            -- expose their entry point via addToMainMenu (e.g. solitaire).
            local probe = {}
            local ok = pcall(function() plugin_inst:addToMainMenu(probe) end)
            if ok then
                local entry = probe[cfg.plugin_key] or probe[plugin_inst.name]
                if entry and type(entry.callback) == "function" then
                    local cb = entry.callback
                    plugin_inst._sui_launch = function(_self) cb() end
                end
            end
        end

        if plugin_inst and type(plugin_inst[method]) == "function" then
            local ok, err = pcall(function() plugin_inst[method](plugin_inst) end)
            if not ok then _unavail(string.format(_("Plugin error: %s"), tostring(err))) end
        else
            _unavail(string.format(_("Plugin not available: %s"), cfg.plugin_key))
        end

    elseif cfg.collection and cfg.collection ~= "" then
        if fm and fm.collections then
            local ok, err = pcall(function() fm.collections:onShowColl(cfg.collection) end)
            if not ok then _unavail(string.format(_("Collection not available: %s"), cfg.collection)) end
        end

    elseif cfg.path and cfg.path ~= "" then
        if fm and fm.file_chooser then fm.file_chooser:changeToPath(cfg.path) end

    else
        _unavail(_("No folder, collection or plugin configured.\nGo to Simple UI \xe2\x86\x92 Settings \xe2\x86\x92 Quick Actions to set one."))
    end
end

-- ---------------------------------------------------------------------------
-- isInPlaceCustomQA(action_id)
--
-- Returns true when the custom QA executes without opening a new fullscreen
-- view (dispatcher_action or plugin_method).  Used by sui_bottombar's
-- _isInPlaceAction so the homescreen is not closed for in-place actions.
-- ---------------------------------------------------------------------------
function QA.isInPlaceCustomQA(action_id)
    local cfg = G_reader_settings:readSetting("navbar_cqa_" .. action_id) or {}
    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then return true end
    if cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then return true end
    return false
end

return QA
