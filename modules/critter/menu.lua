-- menu.lua — Simple UI
-- Settings > Tiny Critter: the settings of the critter that are the same on
-- every screen (see settings.lua).

local T           = require("ffi/util").template
local util        = require("util")
local Config      = require("infra/sui_config")
local Arrange     = require("features/sui_arrange")
local i18n        = require("infra/sui_i18n")
local _           = i18n.translate
local N_          = i18n.ngettext
local Assets      = require("modules/critter/assets")
local Phrases     = require("modules/critter/phrases")
local Settings    = require("modules/critter/settings")

local M = {}

local MAX_NAME_CHARS = 20

local _CRITTER_NAMES = {
    argos   = function() return _("Argos") end,
    chonk   = function() return _("Chonk") end,
    frankie = function() return _("Frankie") end,
    hazel   = function() return _("Hazel") end,
    sholmes = function() return _("Sholmes") end,
    suey    = function() return _("Suey") end,
    tulu    = function() return _("Tulu") end,
    vlad    = function() return _("Vlad") end,
}

local function critterName(entry)
    if not entry then return "" end
    local name = _CRITTER_NAMES[entry.id]
    if name then return name() end
    return entry.name
end

local _DECOR_NAMES = {
    book_stack    = function() return _("Book stack") end,
    bookcase      = function() return _("Bookcase") end,
    candle_shelf  = function() return _("Candle shelf") end,
    cat_pot       = function() return _("Cat pot") end,
    coffee        = function() return _("Coffee") end,
    corkboard     = function() return _("Corkboard") end,
    hanging_plant = function() return _("Hanging plant") end,
    lamp          = function() return _("Lamp") end,
    picture       = function() return _("Picture") end,
    pillow        = function() return _("Pillow") end,
    plant         = function() return _("Plant") end,
    plant_shelf   = function() return _("Plant shelf") end,
    window        = function() return _("Window") end,
}

local function decorName(entry)
    if not entry then return "" end
    local name = _DECOR_NAMES[entry.id]
    if name then return name() end
    return entry.name
end

local function makeCritterItem(refresh)
    local function get()
        local entry = Assets.get(Settings.pick())
        return entry and entry.id
    end
    return {
        text_func  = function() return _("Critter") end,
        value_func = function()
            local entry = Assets.get(Settings.pick())
            return entry and critterName(entry) or ""
        end,
        sub_item_table_func = function()
            Assets.relist()
            Assets.ensureUserDir()
            local options = {}
            for _i, entry in ipairs(Assets.list()) do
                options[#options + 1] = { value = entry.id, label = critterName(entry) }
            end
            local rows = Config.appendRadioItems({}, {
                options = options,
                get     = get,
                set     = Settings.setPick,
                refresh = refresh,
            })
            rows[#rows + 1] = {
                text    = T(_("Add your own critters in %1"), Assets.userDir()),
                enabled = false,
            }
            return rows
        end,
    }
end

-- Menu row that asks for the name the critter uses for the user; an empty text
-- clears it.
local function makeNameItem(refresh)
    return {
        text_func      = function() return _("Your name") end,
        keep_menu_open = true,
        value_func     = function() return Settings.userName() or _("Not set") end,
        callback       = function()
            require("features/dialogs/sui_dialogs").prompt{
                title       = _("Your name"),
                description = _("The critter may use it in what it says."),
                value       = Settings.userName() or "",
                hint        = _("Name"),
                allow_empty = true,
                validate    = function(text)
                    if #util.splitToChars(text) > MAX_NAME_CHARS then
                        return T(_("Use at most %1 characters."), tostring(MAX_NAME_CHARS))
                    end
                end,
                on_submit   = function(text)
                    Settings.setUserName(text)
                    refresh()
                end,
            }
        end,
    }
end

-- Arrange row for the decorations of both sides, in one list: those of the left
-- side, then those of the right, each as they stand on the screen. The arrange
-- screen needs a menu context, which the native menu does not have.
local function makeDecorItem(ctx_menu, refresh)
    local arrange_ctx = setmetatable({ _ = _, refresh = refresh }, { __index = ctx_menu })
    local title = _("Decorations")
    return Arrange.makeSectionedItem{
        ctx_menu = arrange_ctx,
        title    = title,
        labels   = {
            action  = string.format(_("Arrange %s"), title),
            empty   = _("No decorations selected."),
            too_few = _("Add at least 2 decorations to arrange."),
            full    = function(max)
                return string.format(N_("The maximum of %d decoration per side has been reached. Remove one first.",
                    "The maximum of %d decorations per side has been reached. Remove one first.", max), max)
            end,
        },
        sections = {
            { id = "left",  label = _("Left") },
            { id = "right", label = _("Right") },
        },
        max    = Settings.DECOR_PER_SIDE,
        pool   = function()
            local pool = {}
            for _i, entry in ipairs(Assets.decorList()) do
                pool[#pool + 1] = { id = entry.id, label = decorName(entry) }
            end
            return pool
        end,
        getIds = Settings.decorIds,
        setIds = Settings.setDecorIds,
    }
end

local function makeStyleItem(refresh)
    return Config.makeRadioSubmenuItem{
        text    = _("Bubble style"),
        options = {
            { value = "pixel",  label = _("Pixel") },
            { value = "smooth", label = _("Smooth") },
        },
        get     = Settings.bubbleStyle,
        set     = Settings.setBubbleStyle,
        refresh = refresh,
    }
end

local function makeSourceItem(refresh)
    return Config.makeRadioSubmenuItem{
        text    = _("Phrases"),
        options = {
            { value = "builtin", label = _("Included") },
            { value = "both",    label = _("Included and mine") },
            { value = "custom",  label = _("Mine only") },
        },
        get     = Settings.source,
        set     = Settings.setSource,
        refresh = refresh,
    }
end

local function makeCategoriesItem(refresh)
    return {
        text_func = function() return _("Topics") end,
        sub_item_table_func = function()
            local rows = {}
            for _i, cat in ipairs(Phrases.CATEGORIES) do
                rows[#rows + 1] = {
                    text           = cat.label(),
                    checked_func   = function() return Settings.categoryOn(cat.id) end,
                    keep_menu_open = true,
                    callback       = function()
                        Settings.setCategory(cat.id, not Settings.categoryOn(cat.id))
                        refresh()
                    end,
                }
            end
            return rows
        end,
    }
end

local function makeReactionsItem(refresh)
    return {
        text           = _("React to events"),
        checked_func   = Settings.reactionsOn,
        keep_menu_open = true,
        callback       = function()
            Settings.setReactions(not Settings.reactionsOn())
            refresh()
        end,
    }
end

-- Items of the menu. `rebuild`, when given, redraws the Home Screen; `ctx_menu`,
-- when there is one, also redraws the window the menu is shown in.
function M.getItems(ctx_menu, rebuild)
    local function refresh()
        if rebuild then rebuild() end
        if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
    end
    -- Picks up the decorations the user added since the last time.
    Assets.relist()
    Assets.ensureUserDir()
    return {
        makeCritterItem(refresh),
        makeDecorItem(ctx_menu, refresh),
        {
            text    = T(_("Add your own decorations in %1"), Assets.userDecorDir()),
            enabled = false,
        },
        makeStyleItem(refresh),
        makeNameItem(refresh),
        makeSourceItem(refresh),
        makeCategoriesItem(refresh),
        makeReactionsItem(refresh),
    }
end

-- Entry that opens the menu above from the menu of a module or a panel.
function M.makeSettingsItem(ctx_menu)
    return {
        text                = _("Tiny Critter Settings"),
        sub_item_table_func = function() return M.getItems(ctx_menu) end,
    }
end

return M
