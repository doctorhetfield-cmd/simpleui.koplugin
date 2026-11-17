-- sui_cover_elements.lua — Simple UI
-- Single registry of the cover elements (badges, folder book stack, folder
-- name) and their global defaults.
--
-- Every element follows one grammar: a `show` toggle, an optional variant
-- (radio, never with a "None" entry) and its appearance (`color`, ...). The
-- defaults live under "simpleui_style_badge_<kind>_<prop>" and
-- "simpleui_style_folder_<kind>_<prop>", so they travel with presets and
-- backups through the "simpleui_style_" prefix. One `size` is shared by all
-- badges.
--
-- Public API
-- ----------
--   CE.KINDS                          -- ordered badge kinds
--   CE.isShown(kind)                  -- the `show` toggle (badges, "stack", "name")
--   CE.getVariant(kind)               -- "type" / "position" / "style" value, nil without variant
--   CE.getColor(kind)                 -- "dark" | "light" | "accent" | "secondary" (badges)
--   CE.set(kind, prop, value)         -- prop: "show" | "variant" | "color"
--   CE.getFolderType() / CE.setFolderType(v)   -- "single" | "quad" | "auto"
--   CE.getNameOption(field) / CE.setNameOption(field, v)
--   CE.getNameOptions()               -- every folder name field, normalised
--   CE.getSizePct() / CE.setSizePct(pct)
--   CE.getScale()                     -- size as a multiplier, trim included
--   CE.progressMode()                 -- "banner" | "native" | "none" (library paint modes)
--   CE.makeItems{ kind, refresh }     -- Show / variant / Color rows of one badge
--   CE.makeBadgesItems(opts)          -- the "Badges" rows: Size + one row per badge
--   CE.makeFolderCoversItems(opts)    -- the "Folder Covers" rows: Cover Type, Book Stack, Folder Name
--   CE.migrateLegacyBadges()          -- one-off move of the pre-registry badge keys
--   CE.migrateLegacyFolder()          -- one-off move of the pre-registry folder keys

local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local Config      = require("infra/sui_config")
local LabelOptions = require("features/library/sui_label_options")
local logger      = require("logger")
local _           = require("infra/sui_i18n").translate

local CE = {}

local KEY_PREFIX    = "simpleui_style_badge_"
local FOLDER_PREFIX = "simpleui_style_folder_"
local SIZE_KEY      = KEY_PREFIX .. "size"
local TYPE_KEY      = FOLDER_PREFIX .. "type"

-- Descriptor per element. `prefix` defaults to the badge prefix; `variant`
-- names the stored prop of its radio choice (`key` pins a full setting key);
-- `color` is present on elements with a colour choice; `extra(opts)` returns
-- further rows of the element's menu. Labels are built by functions so they
-- are translated when the menu opens.
local ELEMENTS = {
    pages = {
        show = true, color = "light",
        label = function() return _("Pages") end,
    },
    series = {
        show = false, color = "light",
        label = function() return _("Series Index") end,
    },
    progress = {
        show = true, color = "accent",
        label = function() return _("Progress") end,
        variant = {
            prop = "type", default = "banner",
            label = function() return _("Type") end,
            options = function()
                return {
                    { value = "banner", label = _("Banner") },
                    { value = "native", label = _("Native") },
                }
            end,
        },
    },
    new = {
        show = true, color = "accent",
        label = function() return _("New Book") end,
        variant = {
            prop = "type", default = "ribbon",
            label = function() return _("Type") end,
            options = function()
                return {
                    { value = "badge",  label = _("Badge") },
                    { value = "ribbon", label = _("Ribbon") },
                }
            end,
        },
    },
    onhold = {
        show = true, color = "accent",
        label = function() return _("On Hold (List View)") end,
    },
    count = {
        show = true, color = "accent",
        label = function() return _("Folder Count") end,
        variant = {
            prop = "position", default = "top",
            label = function() return _("Position") end,
            options = function()
                return {
                    { value = "top",    label = _("Top") },
                    { value = "bottom", label = _("Bottom") },
                }
            end,
        },
    },
}

-- Folder cover elements. The name label keeps its own colour and layout
-- fields (see LabelOptions), stored as "simpleui_style_folder_name_<field>".
ELEMENTS.stack = {
    prefix = FOLDER_PREFIX, show = true,
    label = function() return _("Book Stack") end,
    variant = {
        prop = "style", key = SUIStyle.FOLDER_STACK_STYLE_KEY, default = SUIStyle.FOLDER_STACK_DEFAULT,
        label = function() return _("Style") end,
        independent = true,
        help = function() return _("Also used by the Collections module on the Home Screen.") end,
        options = function()
            return {
                { value = SUIStyle.FOLDER_STACK_DEFAULT, label = _("Default") },
                { value = SUIStyle.FOLDER_STACK_CLASSIC, label = _("Classic") },
            }
        end,
    },
}
ELEMENTS.name = {
    prefix = FOLDER_PREFIX, show = true,
    label = function() return _("Folder Name") end,
    extra = function(opts)
        return LabelOptions.makeMenuItems{
            get          = CE.getNameOption,
            set          = CE.setNameOption,
            refresh      = opts.refresh,
            enabled_func = opts.enabled_func,
            size_title   = _("Folder Name Text Size"),
            size_info    = _("Scale for the folder name overlay text.\n100% is the default size."),
        }
    end,
}

CE.KINDS = { "pages", "series", "progress", "new", "onhold", "count" }

local FOLDER_TYPES = { "single", "quad", "auto" }

local function _key(kind, prop)
    local element = ELEMENTS[kind]
    local variant = element.variant
    if variant and variant.key and variant.prop == prop then return variant.key end
    return (element.prefix or KEY_PREFIX) .. kind .. "_" .. prop
end

local function _variantProp(kind)
    local v = ELEMENTS[kind].variant
    return v and v.prop
end

-- ---------------------------------------------------------------------------
-- Getters / setters
-- ---------------------------------------------------------------------------

function CE.isShown(kind)
    local stored = SUISettings:readSetting(_key(kind, "show"))
    if stored == nil then return ELEMENTS[kind].show end
    return stored == true
end

function CE.getColor(kind)
    return SUIStyle.badgeChoice(SUISettings:readSetting(_key(kind, "color")), ELEMENTS[kind].color)
end

-- Stored variant when it is one of the offered options, else the default.
function CE.getVariant(kind)
    local variant = ELEMENTS[kind].variant
    if not variant then return nil end
    local stored = SUISettings:readSetting(_key(kind, variant.prop))
    for _i, option in ipairs(variant.options()) do
        if option.value == stored then return stored end
    end
    return variant.default
end

-- Progress is the only badge with a native counterpart: showing it as
-- "native" or hiding it hands the corner marks back to the file browser,
-- the banner replaces them.
local function _syncCollectionMark()
    G_reader_settings:saveSetting("collection_show_mark", CE.progressMode() ~= "banner")
end

function CE.set(kind, prop, value)
    if prop == "variant" then prop = _variantProp(kind) end
    SUISettings:saveSetting(_key(kind, prop), value)
    if kind == "progress" then _syncCollectionMark() end
end

-- How the library paints progress: "banner" (pentagon), "native" (file
-- browser marks) or "none" (no marks).
function CE.progressMode()
    if not CE.isShown("progress") then return "none" end
    return CE.getVariant("progress")
end

-- Badge size, percent of the base size; 100 until set.
function CE.getSizePct() return Config.getScalePctByKey(SIZE_KEY) end
function CE.setSizePct(pct) Config.setScaleByKey(pct, SIZE_KEY) end
function CE.getScale() return CE.getSizePct() / 100 * SUIStyle.BADGE_SIZE_ADJUST end

-- Folder cover type: "single", "quad" (2×2 grid) or "auto" (single below
-- four books, quad from four).
function CE.getFolderType()
    return Config.readChoice(TYPE_KEY, FOLDER_TYPES, "single")
end
function CE.setFolderType(value) SUISettings:saveSetting(TYPE_KEY, value) end

-- Folder name fields: layout, position, color, opacity, scale_pct.
function CE.getNameOption(field)
    return LabelOptions.normalize(field, SUISettings:readSetting(_key("name", field)))
end
function CE.setNameOption(field, value)
    SUISettings:saveSetting(_key("name", field), LabelOptions.normalize(field, value))
end
function CE.getNameOptions()
    local stored = {}
    for field in pairs(LabelOptions.DEFAULTS) do
        stored[field] = SUISettings:readSetting(_key("name", field))
    end
    return LabelOptions.resolve(stored)
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

-- Show / variant / Color rows of one element (Color only on badges, plus the
-- element's own extra rows). Everything but Show is disabled while Show is
-- off, except a variant marked `independent`. `refresh` runs after every change.
function CE.makeItems(opts)
    local kind, refresh = opts.kind, opts.refresh
    local element = ELEMENTS[kind]
    local function shown() return CE.isShown(kind) end

    local items = {
        {
            text           = _("Show"),
            checked_func   = shown,
            keep_menu_open = true,
            callback       = function()
                CE.set(kind, "show", not shown())
                refresh()
            end,
        },
    }
    if element.variant then
        items[#items + 1] = Config.makeRadioSubmenuItem{
            text         = element.variant.label(),
            help_text    = element.variant.help and element.variant.help() or nil,
            enabled_func = (not element.variant.independent) and shown or nil,
            options      = element.variant.options,
            get          = function() return CE.getVariant(kind) end,
            set          = function(v) CE.set(kind, "variant", v) end,
            refresh      = refresh,
        }
    end
    if element.color then
        items[#items + 1] = Config.makeRadioSubmenuItem{
            text         = _("Color"),
            enabled_func = shown,
            options      = function() return SUIStyle.badgeColorOptions(_) end,
            get          = function() return SUIStyle.badgeChoiceShown(CE.getColor(kind)) end,
            set          = function(v) CE.set(kind, "color", v) end,
            refresh      = refresh,
        }
    end
    if element.extra then
        for _i, item in ipairs(element.extra{ refresh = refresh, enabled_func = shown }) do
            items[#items + 1] = item
        end
    end
    return items
end

-- Summary shown on the badge's row: Off, or the chosen variant, or On.
local function _summary(kind)
    if not CE.isShown(kind) then return _("Off") end
    local variant = ELEMENTS[kind].variant
    if not variant then return _("On") end
    local current = CE.getVariant(kind)
    for _i, option in ipairs(variant.options()) do
        if option.value == current then return option.label end
    end
    return _("On")
end

-- Rows of the "Badges" menu: Size, then one submenu per badge.
-- opts: { refresh = function() } — redraws the library and the home screen.
function CE.makeBadgesItems(opts)
    local refresh = opts.refresh
    local items = {
        Config.makeBadgeSizeItem{
            text_func = function() return _("Size") end,
            separator = true,
            info      = _("Scale for the badges (progress, pages, etc.).\n100% is the default size."),
            get       = CE.getSizePct,
            set       = CE.setSizePct,
            refresh   = refresh,
        },
    }
    for _i, kind in ipairs(CE.KINDS) do
        items[#items + 1] = {
            text_func           = ELEMENTS[kind].label,
            value_func          = function() return _summary(kind) end,
            sub_item_table_func = function()
                return CE.makeItems{ kind = kind, refresh = refresh }
            end,
        }
    end
    return items
end

-- Rows of the "Folder Covers" menu: Cover Type, Book Stack and Folder Name.
-- opts: { refresh_cover, refresh_stack, refresh_name = function() },
--       name_value_func = function() -> string, optional }
function CE.makeFolderCoversItems(opts)
    local function typeOptions()
        return {
            { value = "single", label = _("Single Cover") },
            { value = "quad",   label = _("4-Cover Grid (Mosaic View Only)") },
            { value = "auto",   label = _("Auto (Single ↔ 4-Cover Grid)") },
        }
    end
    local function elementRow(kind, refresh, value_func)
        return {
            text_func           = ELEMENTS[kind].label,
            value_func          = value_func or function() return _summary(kind) end,
            sub_item_table_func = function() return CE.makeItems{ kind = kind, refresh = refresh } end,
        }
    end
    return {
        Config.makeRadioSubmenuItem{
            text    = _("Cover Type"),
            options = typeOptions,
            get     = CE.getFolderType,
            set     = CE.setFolderType,
            refresh = opts.refresh_cover,
        },
        elementRow("stack", opts.refresh_stack),
        elementRow("name", opts.refresh_name, opts.name_value_func),
    }
end

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

local LEGACY = {
    pages_show     = "simpleui_fc_overlay_pages",
    series_show    = "simpleui_fc_overlay_series",
    progress_mode  = "simpleui_fc_progress_mode",
    progress_flag  = "simpleui_fc_overlay_progress",
    new_mode       = "simpleui_fc_new_mode",
    new_flag       = "simpleui_fc_overlay_new",
    count_hidden   = "simpleui_fc_badge_hidden",
    count_position = "simpleui_fc_badge_position",
    size           = "simpleui_fc_badge_scale",
    color = {
        pages    = "simpleui_fc_badge_color_pages",
        series   = "simpleui_fc_badge_color_series",
        progress = "simpleui_fc_badge_color_progress",
        new      = "simpleui_fc_badge_color_new",
        count    = "simpleui_fc_badge_color_folder",
    },
}

-- Moves the library badge settings of earlier versions to the registry keys.
-- A value already stored under a new key wins; every legacy key is removed.
-- Enums that combined visibility and variant are split into `show` + variant.
function CE.migrateLegacyBadges()
    local function read(legacy) return SUISettings:get(legacy) end
    local function put(kind, prop, value)
        local key = _key(kind, prop)
        if value ~= nil and SUISettings:get(key) == nil then SUISettings:setNoFlush(key, value) end
    end
    local moved = 0
    local function drop(legacy)
        if SUISettings:get(legacy) ~= nil then moved = moved + 1 end
        SUISettings:delNoFlush(legacy)
    end

    -- Visibility flags: pages was on unless set false, series off unless set true.
    local pages_legacy = read(LEGACY.pages_show)
    if pages_legacy ~= nil then put("pages", "show", pages_legacy ~= false) end
    drop(LEGACY.pages_show)
    local series_legacy = read(LEGACY.series_show)
    if series_legacy ~= nil then put("series", "show", series_legacy == true) end
    drop(LEGACY.series_show)

    -- Progress: "banner" / "native" / "none".
    local progress_mode = read(LEGACY.progress_mode)
    if progress_mode == "banner" or progress_mode == "native" then
        put("progress", "show", true)
        put("progress", "type", progress_mode)
    elseif progress_mode == "none" then
        put("progress", "show", false)
    end
    drop(LEGACY.progress_mode)
    drop(LEGACY.progress_flag)

    -- New book: "badge" / "ribbon" / "none"; the older boolean applies
    -- when no mode was stored.
    local new_mode = read(LEGACY.new_mode)
    if new_mode == "badge" or new_mode == "ribbon" then
        put("new", "show", true)
        put("new", "type", new_mode)
    elseif new_mode == "none" or (new_mode == nil and read(LEGACY.new_flag) == false) then
        put("new", "show", false)
    end
    drop(LEGACY.new_mode)
    drop(LEGACY.new_flag)

    -- Folder count.
    local hidden = read(LEGACY.count_hidden)
    if hidden ~= nil then put("count", "show", hidden ~= true) end
    drop(LEGACY.count_hidden)
    local position = read(LEGACY.count_position)
    if position == "top" or position == "bottom" then put("count", "position", position) end
    drop(LEGACY.count_position)

    for kind, legacy in pairs(LEGACY.color) do
        local choice = SUIStyle.badgeChoice(read(legacy))
        put(kind, "color", choice)
        drop(legacy)
    end

    local size = tonumber(read(LEGACY.size))
    if size ~= nil and SUISettings:get(SIZE_KEY) == nil then
        Config.setScaleByKey(size, SIZE_KEY)
    end
    drop(LEGACY.size)

    logger.info("simpleui: migration v12 — library badge settings moved to the cover elements registry,",
        moved, "legacy keys removed")
end

local LEGACY_FOLDER = {
    type          = "simpleui_fc_folder_style",
    hide_stack    = "simpleui_fc_hide_spine",
    stack_style   = "simpleui_style_folder_stack",
    show_name     = "simpleui_fc_show_name",
    label_mode    = "simpleui_fc_label_mode",
    label_style   = "simpleui_fc_label_style",
    label_fields  = {
        layout    = "simpleui_fc_label_layout",
        position  = "simpleui_fc_label_position",
        color     = "simpleui_fc_label_color",
        opacity   = "simpleui_fc_label_opacity",
        scale_pct = "simpleui_fc_label_scale",
    },
}

-- Moves the library folder cover settings of earlier versions to the registry
-- keys. A value already stored under a new key wins; every legacy key is
-- removed. The name's visibility flag and mode merge into one `show`, and
-- the book stack's negative `hide` becomes `show`.
function CE.migrateLegacyFolder()
    local function read(legacy) return SUISettings:get(legacy) end
    local function put(key, value)
        if value ~= nil and SUISettings:get(key) == nil then SUISettings:setNoFlush(key, value) end
    end
    local moved = 0
    local function drop(legacy)
        if SUISettings:get(legacy) ~= nil then moved = moved + 1 end
        SUISettings:delNoFlush(legacy)
    end

    put(TYPE_KEY, read(LEGACY_FOLDER.type))
    drop(LEGACY_FOLDER.type)

    local hide_stack = read(LEGACY_FOLDER.hide_stack)
    if hide_stack ~= nil then put(_key("stack", "show"), hide_stack ~= true) end
    drop(LEGACY_FOLDER.hide_stack)
    put(_key("stack", "style"), read(LEGACY_FOLDER.stack_style))
    drop(LEGACY_FOLDER.stack_style)

    -- Visible unless the flag was cleared or the mode was set to hidden.
    local show_name, label_mode = read(LEGACY_FOLDER.show_name), read(LEGACY_FOLDER.label_mode)
    if show_name ~= nil or label_mode ~= nil then
        put(_key("name", "show"), show_name ~= false and label_mode ~= "hidden")
    end
    drop(LEGACY_FOLDER.show_name)
    drop(LEGACY_FOLDER.label_mode)

    for field, legacy in pairs(LEGACY_FOLDER.label_fields) do
        put(_key("name", field), read(legacy))
        drop(legacy)
    end
    -- The former solid choice seeded the opacity until one was stored.
    if read(LEGACY_FOLDER.label_style) == "solid" then put(_key("name", "opacity"), 100) end
    drop(LEGACY_FOLDER.label_style)

    logger.info("simpleui: migration v13 — folder cover settings moved to the cover elements registry,",
        moved, "legacy keys removed")
end

return CE
