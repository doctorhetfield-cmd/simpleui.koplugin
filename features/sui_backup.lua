-- sui_backup.lua — Simple UI ▸ Full Configuration Backup & Restore
--
-- Exports the complete SimpleUI configuration to a single portable ".sui"
-- file and restores it again — on this device after a re-flash, or on any
-- other device running the same (or a compatible) plugin version.
--
-- WHAT GETS BACKED UP
--   1. Settings — every key in the plugin's own store (sui_settings.lua)
--      that belongs to one of the user-selectable categories below, plus a
--      small set of "core" keys that are always included.  Internal keys
--      (migration flags, caches, debug data) are never exported.
--   2. Assets — user-supplied files from the DataStorage/simpleui/ tree:
--        sui_wallpapers/**   custom wallpaper images
--        sui_quotes/**       custom quote pools
--        sui_icons/**        custom icons + installed icon packs
--      Binary content is base64-encoded into the .sui file.
--
-- FILE FORMAT (KOReader LuaSettings file, same container as presets):
--   type            = "simpleui_backup"
--   format_version  = 1                (integer; importers accept <= their max)
--   created         = os.time()
--   plugin_version  = "2.5.0"          (informational)
--   scope           = { <category_id> = true, ... }
--   start_with_simpleui = true|false   ("Start with Homescreen" flag)
--   settings        = { [key] = value, ... }   (filtered by scope)
--   assets          = { { p = "sui_icons/foo.png", d = "<base64>" }, ... }
--
-- PATH PORTABILITY
--   Settings may reference files inside the simpleui/ data tree (wallpaper
--   path, custom quote file, …).  Absolute paths differ between devices,
--   so on export every such string is rewritten to a device-independent
--   token ("@sui_wallpapers/name.png"); on import tokens are expanded back
--   to the local device's paths.
--
-- PUBLIC API
--   Backup.FORMAT_VERSION
--   Backup.CATEGORIES                 — ordered category descriptors
--   Backup.getBackupsDir()            — DataStorage/simpleui/backups (mkdir)
--   Backup.suggestedFilename()        — "simpleui_backup_YYYYMMDD_HHMM.sui"
--   Backup.export(filepath)           — ok, err   (uses persisted scope)
--   Backup.parse(filepath)            — parsed, err
--   Backup.describe(parsed)           — summary string for preview dialogs
--   Backup.restore(parsed, cats)      — ok, err   (cats = {[id]=true} filter)
--   Backup.makeMenuItems(ctx_menu)    — About ▸ Backup & Restore menu items
--   Backup.runQuickExport()           — one-tap export for backup_export QA

local logger = require("logger")
local _      = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local UI = require("infra/sui_core")

local Backup = {}

Backup.FORMAT_VERSION = 1

-- ===========================================================================
-- § 1  Categories & key classification
-- ===========================================================================
-- Every settings key owned by the plugin starts with "simpleui_" or
-- "navbar_" (enforced repo-wide).  Classification maps each key to exactly
-- one selectable category; rules are evaluated top-down and first match
-- wins, so ordering matters:
--   * wallpaper before the generic style prefix,
--   * homescreen-scoped navbar_* keys before the generic navbar_ prefix,
--   * row-instance lists before the generic quick-actions prefixes.
-- Keys matching no rule fall through to CORE_ALWAYS (exported unconditionally)
-- unless they match EXCLUDED.

-- Keys that must never travel: migration flags, runtime caches, debug data,
-- and the backup feature's own bookkeeping.
local EXCLUDED_EXACT = {
    ["simpleui_userdata_migrated_v1"]     = true,
    ["simpleui_loaded_version"]           = true,
    ["simpleui_qa_migrated_v1"]           = true,
    ["simpleui_cqa_migrated_v1"]          = true,
    ["navbar_custom_qa_migrated_v1"]      = true,
    ["simpleui_stale_stats_v1"]           = true,
    ["simpleui_stale_books_v1"]           = true,
    ["simpleui_debug_button_bounds"]      = true,
    ["simpleui_last_backup"]              = true,
    ["simpleui_backup_scope"]             = true,
    ["simpleui_last_restore"]             = true,
}

for _i = 2, 8 do
    EXCLUDED_EXACT["simpleui_settings_migrated_v" .. _i] = true
end

-- Small always-on set that makes a restored backup actually boot into the
-- same shape (enabled state, onboarding already seen).
local CORE_ALWAYS = {
    ["simpleui_enabled"]       = true,
    ["simpleui_onboarding_done"] = true,
}

-- Selectable categories, in display order.  asset_dir names the folder under
-- DataStorage/simpleui/ whose FILES belong to the category (nil = settings
-- only).
Backup.CATEGORIES = {
    {
        id        = "appearance",
        label     = _("Appearance & Style"),
        desc      = _("Fonts, icon assignments, icon presets"),
    },
    {
        id        = "home_screen",
        label     = _("Home Screen"),
        desc      = _("Layout, modules, custom screens, presets"),
    },
    {
        id        = "bars",
        label     = _("Bars"),
        desc      = _("Navigation, status, title and quick settings bars"),
    },
    {
        id        = "library",
        label     = _("Library"),
        desc      = _("Folder covers, browse modes, series grouping"),
    },
    {
        id        = "quick_actions",
        label     = _("Quick Actions"),
        desc      = _("Custom actions, rows and dispatcher bindings"),
    },
    {
        id        = "goals",
        label     = _("Goals & Streaks"),
        desc      = _("Reading goals, streak mode and freeze bank"),
    },
    {
        id        = "wallpaper",
        label     = _("Wallpaper"),
        desc      = _("Wallpaper settings and image files"),
        asset_dir = "sui_wallpapers",
    },
    {
        id        = "quotes",
        label     = _("Custom quotes"),
        desc      = _("Quote pool files from sui_quotes/"),
        asset_dir = "sui_quotes",
    },
    {
        id        = "icons",
        label     = _("Custom icons"),
        desc      = _("Icon files and installed packs from sui_icons/"),
        asset_dir = "sui_icons",
    },
}

-- Ordered classification rules: { category_id, exact = {...}, prefixes = {...} }
local CLASSIFY_RULES = {
    { "wallpaper",
      prefixes = { "simpleui_style_wallpaper", "simpleui_wallpaper_" },
      exact    = { simpleui_style_wallpaper_enabled = true },  -- covered by prefix anyway; kept for clarity
    },
    { "goals",
      prefixes = {
          "simpleui_streak_", "simpleui_reading_goal", "simpleui_daily_reading_goal_secs",
          "simpleui_monthly_reading_goal_secs", "simpleui_tbr_sort_mode",
          "simpleui_tbr_auto_remove_finished",
      },
      exact    = { simpleui_preserve_deleted_books_in_stats = true, simpleui_deleted_books = true },
    },
    { "library",
      prefixes = { "simpleui_fc_", "simpleui_browsemeta_", "simpleui_reader_cover_" },
      exact    = { simpleui_toggle_home_library = true },
    },
    -- Homescreen-scoped keys must classify before generic bar/qa prefixes.
    -- Column width (bento grid) lives in simpleui_hs_bento_width_* / simpleui_cs_*_bento_width_*.
    { "home_screen",
      prefixes = {
          "simpleui_hs_", "simpleui_layout", "simpleui_cs_", "simpleui_custom_screens",
          "simpleui_hide_label_", "simpleui_homescreen_preset", "simpleui_coll_",
          "simpleui_collections_", "simpleui_quote_", "navbar_homescreen_",
          "simpleui_qa_row_instances", "simpleui_spacer_row_instances",
          "simpleui_coll_row_instances",
      },
    },
    { "quick_actions",
      prefixes = { "simpleui_cqa_", "simpleui_qa_custom_qa_", "simpleui_custom_qa_", "navbar_cqa_" },
      exact    = {
          simpleui_qa_list        = true,
          simpleui_cqa_list       = true,
          navbar_custom_qa_list   = true,
          simpleui_go_library     = true,
          simpleui_go_homescreen  = true,
      },
    },
    { "appearance",
      prefixes = { "simpleui_sysicon_", "simpleui_action_", "simpleui_ui_font_",
                   "simpleui_icon_preset", "simpleui_style_" },
      exact    = { simpleui_icon_active_preset = true },
    },
    { "bars",
      prefixes = {
          "simpleui_bar_", "simpleui_topbar_", "simpleui_tb_", "simpleui_qs_bar_",
          "simpleui_titlebar", "simpleui_statusbar_transparent", "simpleui_bars_transparent",
          "simpleui_statusbar_backdrop", "simpleui_navbar_backdrop", "simpleui_pagination_backdrop", "simpleui_titlebar_button_backdrop", "simpleui_module_backdrop",
          "simpleui_menu_tap", "simpleui_menu_swipe",
          "navbar_",
      },
      exact    = {
          simpleui_navbar_transparent    = true,
          simpleui_titlebar_custom       = true,
      },
    },
}

--- Classify a settings key → category id | "core" | nil (excluded/foreign).
function Backup.classifyKey(key)
    if type(key) ~= "string" then return nil end
    if EXCLUDED_EXACT[key] then return nil end
    if CORE_ALWAYS[key] then return "core" end
    -- Only ever classify keys the plugin owns (repo convention).
    if key:sub(1, 9) ~= "simpleui_" and key:sub(1, 7) ~= "navbar_" then
        return nil
    end
    for _i, rule in ipairs(CLASSIFY_RULES) do
        if rule.exact and rule.exact[key] then return rule[1] end
        if rule.prefixes then
            for _j, pfx in ipairs(rule.prefixes) do
                if key:sub(1, #pfx) == pfx then return rule[1] end
            end
        end
    end
    -- Unknown-but-owned key: carry it with the core set rather than dropping it.
    return "core"
end

-- ===========================================================================
-- § 2  Paths, filesystem helpers, base64
-- ===========================================================================

local function _lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs or nil
end

local function _dataDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    return DataStorage:getSettingsDir() .. "/simpleui"
end

--- DataStorage/simpleui/backups — where new backups are written.
function Backup.getBackupsDir()
    local base = _dataDir()
    if not base then return nil end
    local lfs = _lfs()
    if lfs then
        if lfs.attributes(base, "mode") ~= "directory" then
            pcall(lfs.mkdir, base)
        end
        local dir = base .. "/backups"
        if lfs.attributes(dir, "mode") ~= "directory" then
            pcall(lfs.mkdir, dir)
        end
        if lfs.attributes(dir, "mode") == "directory" then
            return dir
        end
        return nil
    end
    return base .. "/backups"
end

--- Map an absolute path inside the simpleui/ tree to a "@dir_rel/rel" token.
local TOKEN_DIRS = { "sui_wallpapers", "sui_quotes", "sui_icons" }

local function _tokenizePath(value)
    if type(value) ~= "string" then return value end
    local base = _dataDir()
    if not base then return value end
    for _i, sub in ipairs(TOKEN_DIRS) do
        local dir = base .. "/" .. sub
        if value:sub(1, #dir + 1) == dir .. "/" then
            return "@" .. sub .. "/" .. value:sub(#dir + 2)
        elseif value == dir then
            return "@" .. sub
        end
    end
    return value
end

--- Expand "@dir_rel/rel" tokens back to local absolute paths.
local function _detokenizePath(value)
    if type(value) ~= "string" or value:sub(1, 1) ~= "@" then return value end
    local base = _dataDir()
    if not base then return value end
    for _i, sub in ipairs(TOKEN_DIRS) do
        local marker = "@" .. sub
        if value == marker then
            return base .. "/" .. sub
        elseif value:sub(1, #marker + 1) == marker .. "/" then
            return base .. "/" .. sub .. "/" .. value:sub(#marker + 2)
        end
    end
    return value
end

-- Recursively rewrite path strings inside a settings payload.
local function _remapPaths(value, fn, depth)
    depth = depth or 0
    if depth > 12 then return value end
    local t = type(value)
    if t == "string" then
        return fn(value)
    elseif t == "table" then
        local out = {}
        for k, v in pairs(value) do
            out[k] = _remapPaths(v, fn, depth + 1)
        end
        return out
    end
    return value
end

-- Minimal base64 (RFC 4648) — keeps binary assets inspectable and avoids
-- relying on %q escaping of raw bytes across Lua builds.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function _b64_encode(data)
    local function ch(i) return B64_CHARS:sub(i + 1, i + 1) end
    local out = {}
    local len = #data
    local i = 1
    while i <= len do
        local c1, c2, c3 = data:byte(i, i + 2)
        local n = c1 * 65536 + (c2 or 0) * 256 + (c3 or 0)
        local a = math.floor(n / 262144) % 64
        local b = math.floor(n / 4096) % 64
        local c = math.floor(n / 64) % 64
        local d = n % 64
        if c3 then
            out[#out + 1] = ch(a) .. ch(b) .. ch(c) .. ch(d)
        elseif c2 then
            out[#out + 1] = ch(a) .. ch(b) .. ch(c) .. "="
        else
            out[#out + 1] = ch(a) .. ch(b) .. "=="
        end
        i = i + 3
    end
    return table.concat(out)
end

local B64_LOOKUP = {}
for _i = 1, #B64_CHARS do
    B64_LOOKUP[B64_CHARS:byte(_i)] = _i - 1
end

local function _b64_decode(data)
    -- Strip whitespace/newlines.
    data = data:gsub("[^%w%+%/=]", "")
    local out = {}
    local len = #data
    local i = 1
    while i <= len do
        local c1, c2, c3, c4 = data:byte(i, i + 3)
        local n1 = B64_LOOKUP[c1]
        if not n1 then break end
        local n2 = B64_LOOKUP[c2]
        if not n2 then break end
        local n3 = (c3 and c3 ~= 61) and B64_LOOKUP[c3] or nil
        local n4 = (c4 and c4 ~= 61) and B64_LOOKUP[c4] or nil
        local chunk
        -- n4 implies n3 in valid base64; guard anyway against malformed data.
        if n4 and n3 then
            chunk = string.char(n1 * 4 + math.floor(n2 / 16), (n2 % 16) * 16 + math.floor(n3 / 4), (n3 % 4) * 64 + n4)
        elseif n3 then
            chunk = string.char(n1 * 4 + math.floor(n2 / 16), (n2 % 16) * 16 + math.floor(n3 / 4))
        else
            chunk = string.char(n1 * 4 + math.floor(n2 / 16))
        end
        out[#out + 1] = chunk
        i = i + 4
    end
    return table.concat(out)
end

-- Sorted recursive directory listing → { rel = "...", abs = "..." }.
local function _scanAssets(abs_dir, rel_prefix, out)
    local lfs = _lfs()
    if not lfs or lfs.attributes(abs_dir, "mode") ~= "directory" then return out end
    local entries = {}
    for fname in lfs.dir(abs_dir) do
        if fname ~= "." and fname ~= ".." and fname:sub(1, 1) ~= "." then
            entries[#entries + 1] = fname
        end
    end
    table.sort(entries, function(a, b) return a:lower() < b:lower() end)
    for _i, fname in ipairs(entries) do
        local abs = abs_dir .. "/" .. fname
        local rel = rel_prefix .. fname
        local mode = lfs.attributes(abs, "mode")
        if mode == "directory" then
            _scanAssets(abs, rel .. "/", out)
        elseif mode == "file" then
            out[#out + 1] = { rel = rel, abs = abs }
        end
    end
    return out
end

local function _readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function _writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- Validate a relative asset path from a backup file: plain components only
-- (no leading "/", no "." / ".." / empty components) — prevents a crafted
-- file from writing outside the simpleui/ tree.
local function _isSafeRelPath(rel)
    if type(rel) ~= "string" or rel == "" or rel:sub(1, 1) == "/" then return false end
    local comps = {}
    for comp in rel:gmatch("[^/]+") do
        if comp == "." or comp == ".." then return false end
        comps[#comps + 1] = comp
    end
    return table.concat(comps, "/") == rel
end

local function _mkdirRecursive(lfs, path)
    local ok = lfs.attributes(path, "mode") == "directory"
    if ok then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and not _mkdirRecursive(lfs, parent) then return false end
    return pcall(lfs.mkdir, path) and lfs.attributes(path, "mode") == "directory"
end

-- ===========================================================================
-- § 3  Scope persistence
-- ===========================================================================

local SCOPE_KEY = "simpleui_backup_scope"

local function _loadScope()
    local saved = SUISettings:get(SCOPE_KEY)
    local scope = {}
    for _i, cat in ipairs(Backup.CATEGORIES) do
        -- Default: everything on.
        scope[cat.id] = (saved == nil) or (saved[cat.id] ~= false)
    end
    return scope
end

local function _saveScope(scope)
    SUISettings:set(SCOPE_KEY, scope)
end

-- ===========================================================================
-- § 4  Snapshot / export
-- ===========================================================================

function Backup.suggestedFilename()
    return "simpleui_backup_" .. os.date("%Y%m%d_%H%M") .. ".sui"
end

--- Build the full snapshot table for the given scope ({[category_id]=bool}).
--- Returns snapshot ready to be written into a .sui container.
local function _buildSnapshot(scope)
    local settings = {}
    for k, v in SUISettings:iterateKeys() do
        local cat = Backup.classifyKey(k)
        if cat and (cat == "core" or scope[cat]) then
            settings[k] = v
        end
    end
    -- Rewrite device-specific paths to portable tokens.
    settings = _remapPaths(settings, _tokenizePath)

    local assets = {}
    local base = _dataDir()
    if base then
        for _i, cat in ipairs(Backup.CATEGORIES) do
            if cat.asset_dir and scope[cat.id] then
                local files = _scanAssets(base .. "/" .. cat.asset_dir, cat.asset_dir .. "/", {})
                for _j, file in ipairs(files) do
                    local data = _readFile(file.abs)
                    if data then
                        assets[#assets + 1] = { p = file.rel, d = _b64_encode(data) }
                    else
                        logger.warn("simpleui/backup: could not read asset:", file.abs)
                    end
                end
            end
        end
        table.sort(assets, function(a, b) return a.p < b.p end)
    end

    local start_with_hs = false
    if G_reader_settings and G_reader_settings:readSetting("start_with") == "homescreen_simpleui" then
        start_with_hs = true
    end

    return {
        settings            = settings,
        assets              = assets,
        scope               = scope,
        start_with_simpleui = start_with_hs,
    }
end

--- Export using the persisted scope. Returns filepath, nil — or nil, errmsg.
function Backup.export(filepath)
    local scope = _loadScope()
    local snapshot = _buildSnapshot(scope)

    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then
        return nil, _("LuaSettings module unavailable")
    end

    local meta_ok, Meta = pcall(dofile, require("infra/sui_paths").getPluginDirNoSlash() .. "/_meta.lua")

    local f = LuaSettings:open(filepath)
    if not f or type(f.data) ~= "table" then
        return nil, _("Could not open backup file for writing")
    end
    f:saveSetting("type", "simpleui_backup")
    f:saveSetting("format_version", Backup.FORMAT_VERSION)
    f:saveSetting("created", os.time())
    f:saveSetting("plugin_version", (meta_ok and type(Meta) == "table") and Meta.version or "?")
    f:saveSetting("scope", snapshot.scope)
    f:saveSetting("start_with_simpleui", snapshot.start_with_simpleui)
    f:saveSetting("settings", snapshot.settings)
    f:saveSetting("assets", snapshot.assets)
    local flush_ok, flush_err = pcall(function() f:flush() end)
    if not flush_ok then
        return nil, flush_err and tostring(flush_err) or _("Could not write backup file")
    end

    -- Bookkeeping for the "Last backup" info row.
    local size = 0
    local lfs = _lfs()
    if lfs and lfs.attributes(filepath, "mode") == "file" then
        size = tonumber(lfs.attributes(filepath, "size")) or 0
    end
    SUISettings:set("simpleui_last_backup", {
        time   = os.time(),
        size   = size,
        path   = filepath,
        format = Backup.FORMAT_VERSION,
    })
    return filepath
end

-- ===========================================================================
-- § 5  Parse / describe
-- ===========================================================================

--- Read and validate a .sui file. Returns parsed table or nil + error msg.
function Backup.parse(filepath)
    local lfs = _lfs()
    if not lfs or lfs.attributes(filepath, "mode") ~= "file" then
        return nil, _("File not found.")
    end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then
        return nil, _("LuaSettings module unavailable")
    end

    local ok, f = pcall(LuaSettings.open, LuaSettings, filepath)
    if not ok or not f or type(f.data) ~= "table" then
        return nil, _("Not a valid backup file.")
    end
    local typ = f:readSetting("type")
    if typ ~= "simpleui_backup" then
        return nil, _("Not a valid backup file.")
    end
    local version = tonumber(f:readSetting("format_version")) or 0
    if version < 1 or version > Backup.FORMAT_VERSION then
        return nil, _("Backup was made by a newer SimpleUI version. Please update this plugin first.")
    end

    local settings = f:readSetting("settings")
    local assets = f:readSetting("assets")
    if type(settings) ~= "table" then
        return nil, _("Not a valid backup file.")
    end

    return {
        filepath            = filepath,
        format_version      = version,
        created             = tonumber(f:readSetting("created")),
        plugin_version      = f:readSetting("plugin_version"),
        scope               = type(f:readSetting("scope")) == "table" and f:readSetting("scope") or {},
        start_with_simpleui = f:readSetting("start_with_simpleui") == true,
        settings            = settings,
        assets              = type(assets) == "table" and assets or {},
    }
end

local function _fmtSize(bytes)
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return string.format("%d B", bytes)
end

Backup.formatSize = _fmtSize

--- Human-readable summary lines for the preview dialog, honouring the
--- restore filter `filter` ({[category_id]=true}, nil = everything present).
function Backup.describe(parsed, filter)
    -- Count keys per category (core counts as its own implicit line).
    local key_counts, asset_counts, asset_bytes = {}, {}, {}
    local core_keys = 0
    for k in pairs(parsed.settings) do
        local cat = Backup.classifyKey(k)
        if cat == "core" then
            core_keys = core_keys + 1
        elseif cat then
            key_counts[cat] = (key_counts[cat] or 0) + 1
        end
    end
    for _i, asset in ipairs(parsed.assets) do
        local sub = tostring(asset.p):match("^([^/]+)/")
        if sub then
            asset_counts[sub] = (asset_counts[sub] or 0) + 1
            asset_bytes[sub] = (asset_bytes[sub] or 0) + math.floor(#tostring(asset.d) * 3 / 4)
        end
    end

    local lines = {}
    if parsed.created then
        -- Built in code (not via a %Y-%m-%d msgid) so translators can never
        -- break the date format tokens.
        lines[#lines + 1] = _("Backup created") .. ": "
            .. os.date("%Y-%m-%d %H:%M", parsed.created)
            .. (parsed.plugin_version and (" · v" .. tostring(parsed.plugin_version)) or "")
    end

    local total_keys, total_files, total_bytes = 0, 0, 0
    if core_keys > 0 then
        total_keys = total_keys + core_keys
        lines[#lines + 1] = string.format(_("General — %d settings"), core_keys)
    end
    for _i, cat in ipairs(Backup.CATEGORIES) do
        local included = not filter or filter[cat.id]
        if included then
            local n_keys = key_counts[cat.id] or 0
            local n_files = cat.asset_dir and (asset_counts[cat.asset_dir] or 0) or 0
            local bytes = cat.asset_dir and (asset_bytes[cat.asset_dir] or 0) or 0
            total_keys = total_keys + n_keys
            total_files = total_files + n_files
            total_bytes = total_bytes + bytes
            if n_keys > 0 or n_files > 0 then
                local line = cat.label .. " — "
                local parts = {}
                if n_keys > 0 then parts[#parts + 1] = string.format(_("%d settings"), n_keys) end
                if n_files > 0 then
                    parts[#parts + 1] = string.format(_("%d files (%s)"), n_files, _fmtSize(bytes))
                end
                if #parts == 0 then parts[#parts + 1] = _("empty") end
                lines[#lines + 1] = line .. table.concat(parts, ", ")
            end
        end
    end
    lines[#lines + 1] = string.format(
        _("Total: %d settings, %d files (%s)"),
        total_keys, total_files, _fmtSize(total_bytes))
    return table.concat(lines, "\n"), { keys = total_keys, files = total_files, bytes = total_bytes }
end

-- ===========================================================================
-- § 6  Restore
-- ===========================================================================
-- Restore semantics: keys in the restored scope REPLACE current values, with
-- two deliberate exceptions:
--   * preset-collection keys MERGE instead of replacing (see MERGE_KEYS), so
--     importing a friend's setup adds their presets alongside your own;
--   * keys absent from the backup keep whatever they had — a backup may
--     legitimately cover only part of the config.
-- Asset files are added/overwritten; existing unrelated files stay.

--- Invalidate every in-memory cache that depends on restored settings.
local function _invalidateCaches()
    local Config = package.loaded["infra/sui_config"]
    if Config then
        if Config.invalidateTabsCache then pcall(Config.invalidateTabsCache) end
        if Config.invalidateTopbarConfigCache then pcall(Config.invalidateTopbarConfigCache) end
        if Config.invalidateNavbarModeCache then pcall(Config.invalidateNavbarModeCache) end
    end
    local QA = package.loaded["features/sui_quickactions"]
    if QA and QA.invalidateCustomQACache then pcall(QA.invalidateCustomQACache) end
    local WP = package.loaded["features/sui_wallpaper"]
    if WP and WP.invalidateCache then pcall(WP.invalidateCache) end
    local CC_ok, CC = pcall(require, "infra/sui_cover_cache")
    if CC_ok and CC and CC.clear then pcall(function() CC:clear() end) end
end

--- Map an asset's top-level folder ("sui_wallpapers", …) to its category id.
local ASSET_DIR_TO_CAT = {
    sui_wallpapers = "wallpaper",
    sui_quotes     = "quotes",
    sui_icons      = "icons",
}

-- ---------------------------------------------------------------------------
-- Preset-collection merging
-- ---------------------------------------------------------------------------
-- These keys hold named preset libraries ({ [name] = snapshot }) rather than
-- plain config values.  Replacing them wholesale would silently delete the
-- recipient's own presets when importing someone else's setup, so they MERGE:
-- identical entries de-duplicate, genuine conflicts get a " (n)" suffix
-- (same convention as single-preset import in features/sui_presets.lua).

local MERGE_KEYS = {
    ["simpleui_hs_presets"]   = true,   -- homescreen presets   (home_screen)
    ["simpleui_icon_presets"] = true,   -- icon presets         (appearance)
}

-- Deep equality for persisted preset snapshots (plain data — no cycles,
-- no functions; they round-tripped through LuaSettings serialization).
local function _deepEqual(a, b, depth)
    depth = depth or 0
    if depth > 12 then return false end
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local na, nb = 0, 0
    for k, v in pairs(a) do
        if not _deepEqual(v, b[k], depth + 1) then return false end
        na = na + 1
    end
    for _ in pairs(b) do nb = nb + 1 end
    return na == nb
end

local function _mergePresets(local_tbl, imported)
    local out = {}
    if type(local_tbl) == "table" then
        for name, snap in pairs(local_tbl) do out[name] = snap end
    end
    if type(imported) ~= "table" then return out end

    -- Sorted order keeps suffix numbering deterministic across devices.
    local names = {}
    for name in pairs(imported) do names[#names + 1] = name end
    table.sort(names)
    for _i, name in ipairs(names) do
        local snap  = imported[name]
        local final = name
        local n     = 1
        while out[final] ~= nil and not _deepEqual(out[final], snap) do
            final = string.format("%s (%d)", name, n)
            n = n + 1
        end
        out[final] = snap
    end
    return out
end

--- Apply a parsed backup. `filter` optionally restricts which of the
--- backup's own categories get applied ({[category_id]=true}; the always-on
--- "core" keys are applied regardless).  Returns true or nil + errmsg.
--- Never leaves the store half-written: all settings writes go through
--- setNoFlush/delNoFlush and flush once at the end; on any error the
--- previous values are put back and flushed.
function Backup.restore(parsed, filter)
    if type(parsed) ~= "table" or type(parsed.settings) ~= "table" then
        return nil, _("Not a valid backup file.")
    end

    -- 1. Decide what this restore touches: only keys/assets in scope, so the
    --    rollback snapshot stays minimal and untouched categories are never
    --    modified even on failure.
    local touched = {}
    for k in pairs(parsed.settings) do
        local cat = Backup.classifyKey(k)
        if cat == "core" or (cat and (not filter or filter[cat])) then
            touched[k] = true
        end
    end

    local assets = {}
    for _i, asset in ipairs(parsed.assets) do
        local sub = tostring(asset.p):match("^([^/]+)/")
        local cat = sub and ASSET_DIR_TO_CAT[sub]
        if cat and (not filter or filter[cat]) then
            assets[#assets + 1] = asset
        end
    end

    -- 2. Snapshot current values of every key we might touch (rollback safety).
    local rollback = {}
    for k, v in SUISettings:iterateKeys() do
        if touched[k] then rollback[k] = v end
    end

    local ok, err = pcall(function()
        -- 3. Settings: tokenize→local path expansion, then write.
        -- Preset-collection keys merge into the local library instead of
        -- replacing it (see MERGE_KEYS above).
        for k in pairs(touched) do
            local incoming = parsed.settings[k]
            if MERGE_KEYS[k] and type(incoming) == "table" then
                incoming = _mergePresets(SUISettings:get(k), incoming)
            end
            SUISettings:setNoFlush(k, _remapPaths(incoming, _detokenizePath))
        end

        -- 4. "Start with Homescreen" flag lives in KOReader's own settings.
        -- Only ever SET it (when the backup had it); never clear the local
        -- device's startup preference — restoring a partial backup should
        -- not change how the device boots.
        if parsed.start_with_simpleui and G_reader_settings then
            G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
        end

        -- 5. Assets: decode + write into the local simpleui/ tree.
        local base = _dataDir()
        if base then
            local lfs = _lfs()
            for _i, asset in ipairs(assets) do
                local rel = asset.p
                if _isSafeRelPath(rel) then
                    for _j, sub in ipairs(TOKEN_DIRS) do
                        if rel:sub(1, #sub + 1) == sub .. "/" then
                            local abs = base .. "/" .. rel
                            local dir = abs:match("^(.*)/[^/]+$")
                            if dir and lfs then
                                _mkdirRecursive(lfs, dir)
                            end
                            if not _writeFile(abs, _b64_decode(tostring(asset.d))) then
                                logger.warn("simpleui/backup: could not write asset:", abs)
                            end
                            break
                        end
                    end
                else
                    logger.warn("simpleui/backup: skipping unsafe asset path:", tostring(rel))
                end
            end
        end
    end)

    if not ok then
        -- Roll back every touched key to its pre-restore value.
        logger.err("simpleui/backup: restore failed, rolling back:", err)
        for k in pairs(touched) do
            SUISettings:setNoFlush(k, rollback[k])  -- nil deletes
        end
        SUISettings:flush()
        return nil, _("Restore failed. Your previous configuration was kept unchanged.")
    end
    SUISettings:flush()
    _invalidateCaches()

    -- Record the import for the "Last backup" info row (restore side).
    SUISettings:setNoFlush("simpleui_last_restore", {
        time   = os.time(),
        source = parsed.filepath,
    })
    SUISettings:flush()
    return true
end

-- ===========================================================================
-- § 7  One-tap export (backup_export quick action)
-- ===========================================================================

--- Export with the persisted scope, showing progress/result toasts.
--- Returns filepath or nil.
function Backup.runQuickExport()
    UI.Notify.toast(_("Creating backup…"), 1)
    local dir = Backup.getBackupsDir()
    if not dir then
        UI.Notify.toast(_("Could not determine backup folder."))
        return nil
    end
    local filepath = dir .. "/" .. Backup.suggestedFilename()
    local ok, result = pcall(Backup.export, filepath)
    if not ok or not result then
        UI.Notify.toast(_("Backup failed.") .. ((type(result) == "string") and ("\n" .. result) or ""), 4)
        return nil
    end
    UI.Notify.toast(_("Backup created:") .. "\n" .. result, 5)
    return result
end


-- ===========================================================================
-- § 8  Import flow + menu items (About ▸ Backup & Restore)
-- ===========================================================================
-- ---------------------------------------------------------------------------
-- Import flow
-- ---------------------------------------------------------------------------
-- The chosen backup is held in module state and the category selection is
-- done with plain checked menu rows (the same mechanism as the Export scope
-- chooser), so the flow behaves identically in the SUI Settings Window and
-- in the native KOReader menu — no custom modal widget needed.

local _pending_import = nil   -- { parsed = ..., filter = {[category_id]=true} }

--- Categories actually present in a parsed backup → {[category_id]=true}.
local function _presentCategories(parsed)
    local present = {}
    for k in pairs(parsed.settings) do
        local cat = Backup.classifyKey(k)
        if cat and cat ~= "core" then present[cat] = true end
    end
    for _i, asset in ipairs(parsed.assets) do
        local sub = tostring(asset.p):match("^([^/]+)/")
        local cat = sub and ASSET_DIR_TO_CAT[sub]
        if cat then present[cat] = true end
    end
    return present
end

--- Parse a .sui file chosen in the browser and stage it for import.
--- ctx_menu is optional; when present its refresh() rebuilds the current
--- SUIWindow nested menu so category toggles appear immediately.
local function _loadBackupFile(filepath, ctx_menu)
    local UIManager   = require("ui/uimanager")

    local parsed, err = Backup.parse(filepath)
    if not parsed then
        UI.Notify.toast(err or _("Not a valid backup file."), 4)
        return
    end

    local present = _presentCategories(parsed)
    local any = false
    for _, yes in pairs(present) do
        if yes then any = true; break end
    end
    if not any then
        UI.Notify.toast(_("This backup contains no settings or files."), 4)
        return
    end

    _pending_import = { parsed = parsed, filter = present }
    if ctx_menu and ctx_menu.refresh then
        ctx_menu.refresh()
    end
    UI.Notify.toast(_("Backup loaded. Choose what to import, then tap \"Restore Selected…\"."), 4)
end

local function _startImportFlow(ctx_menu)
    local UIManager = require("ui/uimanager")
    local dir = Backup.getBackupsDir()
    if not dir then
        UI.Notify.toast(_("Could not determine backup folder."))
        return
    end
    local AssetBrowser = require("engines/sui_asset_browser")
    UIManager:show(AssetBrowser:new{
        path            = dir,
        extensions      = { sui = true },
        show_thumbnails = false,
        title           = _("Choose backup file"),
        onConfirm       = function(path)
            _loadBackupFile(path, ctx_menu)
        end,
    })
end

--- Confirm staged import (with full summary), restore, prompt restart.
local function _confirmRestore(ctx_menu)
    local UIManager   = require("ui/uimanager")
    local ConfirmBox = ctx_menu and ctx_menu.ConfirmBox or require("ui/widget/confirmbox")

    local pend = _pending_import
    if not pend then return end

    -- Block when every category checkbox is unticked (core keys alone are
    -- never a reason to run a restore).
    local any_selected = false
    for _id, on in pairs(pend.filter) do
        if on then any_selected = true; break end
    end
    if not any_selected then
        UI.Notify.toast(_("Nothing selected to import."))
        return
    end

    local summary = Backup.describe(pend.parsed, pend.filter)
    UIManager:show(ConfirmBox:new{
        text        = summary .. "\n\n"
            .. _("Restore this backup? Existing settings for these categories will be replaced. Saved presets are merged — yours are kept."),
        ok_text     = _("Restore"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            local ok_r, rerr = Backup.restore(pend.parsed, pend.filter)
            if not ok_r then
                UI.Notify.toast(rerr or _("Restore failed."), 5)
                return
            end
            _pending_import = nil
            if ctx_menu and ctx_menu.refresh then
                ctx_menu.refresh()
            end
            UIManager:show(ConfirmBox:new{
                text        = _("Backup restored.\nRestart KOReader now to finish applying all changes?"),
                ok_text     = _("Restart now"),
                cancel_text = _("Later"),
                ok_callback = function()
                    UIManager:restartKOReader()
                end,
            })
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Menu items (About ▸ Backup & Restore)
-- ---------------------------------------------------------------------------
-- Works on both surfaces that consume plugin menu generators:
--   * SUI Settings Window (via SUI.MenuTable rows)
--   * native KOReader menu (plain sub_item_table)

local function _lastBackupText()
    local info = SUISettings:get("simpleui_last_backup")
    if type(info) ~= "table" or not info.time then
        return _("Last backup: never")
    end
    local size = info.size and info.size > 0 and (" · " .. _fmtSize(info.size)) or ""
    return string.format(_("Last backup: %s%s"), os.date("%Y-%m-%d %H:%M", info.time), size)
end

-- Checked-row builder shared by the export scope chooser and the import
-- category chooser. entries: { { label, get = fn, set = fn }, ... }
local function _makeToggleItems(entries)
    local items = {}
    for _i, e in ipairs(entries) do
        items[#items + 1] = {
            text           = e.label,
            checked_func   = e.get,
            keep_menu_open = true,
            callback       = function() e.set(not e.get()) end,
        }
    end
    return items
end

function Backup.makeMenuItems(ctx_menu)
    local UIManager   = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")

    local items = {}

    -- Info row: last backup.
    items[#items + 1] = {
        text           = _lastBackupText(),
        keep_menu_open = true,
        callback       = function() end,
    }

    -- ── Export ──────────────────────────────────────────────────────────────
    -- NOTE: the scope table is loaded once per menu build; toggles mutate it
    -- and persist immediately (same pattern as every other checked row in
    -- this plugin).
    local scope = _loadScope()
    local export_entries = {}
    for _i, cat in ipairs(Backup.CATEGORIES) do
        local cat_id = cat.id
        export_entries[#export_entries + 1] = {
            label = cat.label,
            get   = function() return scope[cat_id] == true end,
            set   = function(v) scope[cat_id] = v; _saveScope(scope) end,
        }
    end
    local export_items = _makeToggleItems(export_entries)
    export_items[#export_items + 1] = {
        text      = _("Export now…"),
        separator = true,
        callback  = function()
            local dir = Backup.getBackupsDir()
            if not dir then
                UI.Notify.toast(_("Could not determine backup folder."))
                return
            end
            local suggested = Backup.suggestedFilename()
            local dialog
            dialog = InputDialog:new{
                title      = _("Save backup as"),
                input      = suggested,
                input_hint = suggested,
                buttons    = {{
                    {
                        text     = _("Cancel"),
                        id       = "close",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text             = _("Export"),
                        is_enter_default = true,
                        callback         = function()
                            local name = dialog:getInputText()
                            name = (name or ""):match("^%s*(.-)%s*$")
                            if name == "" then name = suggested end
                            if not name:match("%.sui$") then name = name .. ".sui" end
                            UIManager:close(dialog)
                            local filepath = dir .. "/" .. name
                            UI.Notify.toast(_("Creating backup…"), 1)
                            local ok, result = pcall(Backup.export, filepath)
                            if ok and result then
                                UI.Notify.toast(_("Backup created:") .. "\n" .. result
                                        .. "\n\n" .. _("Copy this file somewhere safe (e.g. over USB)."), 8)
                            else
                                UI.Notify.toast(_("Backup failed.") .. ((type(result) == "string") and ("\n" .. result) or ""), 5)
                            end
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
        end,
    }

    items[#items + 1] = {
        text           = _("Export Full Backup…"),
        sub_item_table = export_items,
        separator      = true,
    }

    -- ── Import ──────────────────────────────────────────────────────────────
    -- Built via sub_item_table_func so a loaded backup reappears on the next
    -- menu rebuild (SUIWindow nested_menu re-calls items_func on repaint;
    -- native TouchMenu re-calls this when the submenu is entered again).
    items[#items + 1] = {
        text = _("Import Backup…"),
        sub_item_table_func = function()
            local import_items = {}

            import_items[#import_items + 1] = {
                text      = _("Choose backup file…"),
                callback  = function() _startImportFlow(ctx_menu) end,
                separator = true,
            }

            local pend = _pending_import
            if pend then
                local import_entries = {}
                for _i, cat in ipairs(Backup.CATEGORIES) do
                    local cat_id = cat.id
                    if pend.filter[cat_id] ~= nil then
                        import_entries[#import_entries + 1] = {
                            label = cat.label,
                            get   = function() return pend.filter[cat_id] == true end,
                            set   = function(v) pend.filter[cat_id] = v end,
                        }
                    end
                end
                for _i, row in ipairs(_makeToggleItems(import_entries)) do
                    import_items[#import_items + 1] = row
                end
                import_items[#import_items + 1] = {
                    text      = _("Restore Selected…"),
                    separator = true,
                    callback  = function() _confirmRestore(ctx_menu) end,
                }
            else
                -- dim (not enabled=false): SUIWindow hides enabled=false rows
                -- completely; we want a visible-but-inactive placeholder.
                import_items[#import_items + 1] = {
                    text = _("No backup loaded yet."),
                    dim  = true,
                }
            end

            return import_items
        end,
    }

    return items
end

return Backup
