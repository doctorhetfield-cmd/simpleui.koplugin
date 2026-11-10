-- sui_group_actions.lua — Simple UI
-- Shared "cover picker" and "create collection" dialogs for anything that
-- is conceptually a group of books the user can enter: a plain folder, an
-- in-folder series group, or a virtual author/series/tag leaf.
--
-- Previously each of those three had its own near-identical copy of this
-- UI (sui_foldercovers._openFolderCoverPicker / _openSeriesGroupCoverPicker,
-- sui_browsemeta._openVirtualCoverPicker, etc). Callers now just supply the
-- list of books and an override key; the dialog logic lives here once.
--
-- Public API
-- ----------
--   GroupActions.openCoverPicker(args)
--     args.title          -- dialog title, defaults to "Folder cover"
--     args.override_key   -- string key used with sui_cover_overrides
--     args.items          -- { {path=fullpath, title=display_title}, ... }
--     args.menu           -- the FileChooser/menu widget to invalidate after a change
--     args.on_change      -- optional; called after the cover is set or cleared
--     args.empty_message  -- shown instead of the picker when items is empty
--     args.parent         -- optional flow sheet to show the picker on, as a page; the
--                            sheet closes once a cover is chosen, or when there is
--                            nothing to choose from
--
--   GroupActions.createCollection(args)
--     Asks whether the collection stays connected to its source or keeps only
--     the current books, then asks for its name.
--     args.suggested_name       -- pre-filled name (may be "")
--     args.connect_folder       -- source folder (KOReader connected-folder model)
--     args.connect_subfolders   -- include subfolders of the folder
--     args.connect_scan_on_show -- rescan when opening the collection (default true)
--     args.connect_rule         -- source metadata rule instead (see sui_rule_collections)
--     args.parent               -- optional flow sheet to show the pages on; the sheet
--                                  closes once the collection is created

local _ = require("infra/sui_i18n").translate
local N_ = require("infra/sui_i18n").ngettext
local UI = require("infra/sui_core")
local CoverOverrides = require("features/library/sui_cover_overrides")

local GroupActions = {}

function GroupActions.openCoverPicker(args)
    local books = args.items or {}
    if #books == 0 then
        if args.parent then args.parent:close() end
        UI.Notify.toast(args.empty_message or _("No books found."), 2)
        return
    end

    local override_key = args.override_key
    local cur_override = CoverOverrides.get(override_key)

    local function applyOverride(book_path)
        if book_path then
            CoverOverrides.set(override_key, book_path)
        else
            CoverOverrides.clear(override_key)
        end
        CoverOverrides.invalidateGridItem(args.menu, override_key)
        if args.on_change then args.on_change() end
    end

    local items = {{
        text     = _("Auto (first book)"),
        checked  = not cur_override,
        callback = function() applyOverride(nil) end,
    }}
    for _i, item in ipairs(books) do
        local fp    = item.path
        local title = (item.title and item.title ~= "") and item.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        items[#items + 1] = {
            text     = title,
            checked  = cur_override == fp,
            callback = function() applyOverride(fp) end,
        }
    end

    require("engines/sui_action_sheet").pick{
        name         = "sui_win_cover_picker",
        title        = args.title or _("Folder cover"),
        icon         = "cover",
        items        = items,
        parent       = args.parent,
        close_parent = true,
    }
end

-- Creates collection `name` from the folder or rule of `args`, connected or
-- holding only the books found now.
local function fillCollection(RC, name, args, connected)
    RC:addCollection(name)
    local settings = RC.coll_settings[name]
    local count = 0
    if args.connect_folder then
        local folders = {
            [args.connect_folder] = {
                subfolders   = args.connect_subfolders and true or false,
                scan_on_show = args.connect_scan_on_show ~= false,
            },
        }
        local n
        if connected then
            settings.folders = folders
            n = RC:updateCollectionFromFolder(name)
        else
            n = RC:updateCollectionFromFolder(name, folders)
        end
        if type(n) == "number" then count = n end
    elseif args.connect_rule then
        local RuleCollections = require("features/library/sui_rule_collections")
        settings[RuleCollections.KEY] = args.connect_rule
        count = RuleCollections.sync(RC, name)
        if not connected then settings[RuleCollections.KEY] = nil end
    end
    RC:write({ [name] = true })
    return count
end

function GroupActions.createCollection(args)
    local T = require("ffi/util").template
    local ActionSheet = require("engines/sui_action_sheet")
    local RC = require("readcollection")
    local sheet

    local function askName(connected)
        require("features/dialogs/sui_dialogs").prompt{
            title        = _("New collection name"),
            value        = args.suggested_name or "",
            ok_text      = _("Create"),
            parent       = sheet,
            close_parent = true,
            validate     = function(name)
                if RC.coll[name] then
                    return T(_("Collection already exists: %1"), name)
                end
            end,
            on_submit    = function(name)
                local count = fillCollection(RC, name, args, connected)
                UI.Notify.toast(T(N_("Collection \"%1\" created with %2 book.",
                    "Collection \"%1\" created with %2 books.", count), name, count))
            end,
        }
    end

    local page = {
        title    = _("Create collection"),
        icon     = "collections",
        message  = _("A connected collection adds and removes books as they change in the folder. A fixed collection keeps only the books found now."),
        sections = { ActionSheet.list{
            {
                text      = _("Connected"),
                keep_open = true,
                chevron   = true,
                callback  = function() askName(true) end,
            },
            {
                text      = _("Fixed"),
                keep_open = true,
                chevron   = true,
                callback  = function() askName(false) end,
            },
        } },
    }
    if args.parent then
        sheet = args.parent
        sheet:showPage(page)
    else
        page.name = "sui_win_create_collection"
        page.flow = true
        sheet = ActionSheet.show(page)
    end
end

return GroupActions
