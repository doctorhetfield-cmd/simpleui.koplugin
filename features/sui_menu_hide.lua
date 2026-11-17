-- sui_menu_hide.lua — Simple UI
--
-- Hides chosen tabs, submenus and items of the File Manager and Reader menus.
--
-- Entries are matched by the `.id` KOReader's MenuSorter stamps onto every
-- sorted entry. Hidden ids are kept per target ("fm" / "reader") in
-- SUISettings; a step registered in the shared menu hooks
-- (infra/sui_menu_hooks.lua) prunes the live tab table whenever it is built
-- or opened. Before pruning, the full tree (ids and labels) is saved to a
-- file per target so the editor can list the menu of a context that is not
-- open right now.
--
-- The Quick Settings tab and every ancestor of it are never removed, and a
-- prune never leaves the menu without tabs.

local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate
local N_          = require("infra/sui_i18n").ngettext
local MenuHooks   = require("infra/sui_menu_hooks")

local M = {}

M.PROTECTED = { _sui_qs_panel = true }

local SETTING_PREFIX = "simpleui_menu_hidden_"

-- ---------------------------------------------------------------------------
-- Pure tree functions
-- ---------------------------------------------------------------------------

-- A node's children: its submenu table, or the node itself for a tab (whose
-- entries live in its array part).
local function childrenOf(node)
    return node.sub_item_table or node
end

-- True when the node is protected or contains a protected entry.
local function holdsProtected(node)
    if node.id and M.PROTECTED[node.id] then return true end
    for _i, child in ipairs(childrenOf(node)) do
        if type(child) == "table" and holdsProtected(child) then return true end
    end
    return false
end

local function isRemovable(node, hidden)
    return node.id ~= nil and hidden[node.id] == true and not holdsProtected(node)
end

-- Removes list[i] and notes in `log` where it came from.
local function removeAt(list, i, log)
    local node = table.remove(list, i)
    if log then log[#log + 1] = { list = list, node = node, after = list[i] } end
end

local function pruneList(list, hidden, log)
    for i = #list, 1, -1 do
        local node = list[i]
        if type(node) == "table" then
            if isRemovable(node, hidden) then
                removeAt(list, i, log)
            else
                pruneList(childrenOf(node), hidden, log)
            end
        end
    end
end

--- Puts back, in reverse order, the entries a prune noted in `log`.
function M.restore(log)
    for i = #log, 1, -1 do
        local entry = log[i]
        local pos = #entry.list + 1
        for j, node in ipairs(entry.list) do
            if node == entry.after then pos = j; break end
        end
        table.insert(entry.list, pos, entry.node)
        log[i] = nil
    end
end

--- Removes the entries whose id is in `hidden` from the tab table, in place.
--- Protected entries stay, and so do all tabs if none would be left. When
--- `log` is given, every removal is noted in it for M.restore.
function M.prune(tabs, hidden, log)
    if not next(hidden) then return end
    local remaining = 0
    for _i, tab in ipairs(tabs) do
        if not isRemovable(tab, hidden) then remaining = remaining + 1 end
    end
    for i = #tabs, 1, -1 do
        local tab = tabs[i]
        if remaining > 0 and isRemovable(tab, hidden) then
            removeAt(tabs, i, log)
        else
            pruneList(childrenOf(tab), hidden, log)
        end
    end
end

-- Label of an entry and whether it came from a `text_func` (its value changes
-- with the state of the menu).
local function entryText(node)
    if type(node.text) == "string" then return node.text, false end
    if type(node.text_func) == "function" then
        local ok, text = pcall(node.text_func)
        if ok and type(text) == "string" then return text, true end
    end
end

--- Returns the menu as plain data: an array of { id, text, dynamic?, children? }.
--- Entries without an id are skipped; dynamic submenus are not expanded.
function M.extractTree(tabs, tabLabel)
    local function walk(list, is_tabs)
        local out = {}
        for _i, node in ipairs(list) do
            if type(node) == "table" and type(node.id) == "string" then
                local text, dynamic = is_tabs and tabLabel and tabLabel(node.id)
                if not text then text, dynamic = entryText(node) end
                local entry = { id = node.id, text = text or node.id, dynamic = dynamic or nil }
                local children = walk(childrenOf(node), false)
                if #children > 0 then entry.children = children end
                out[#out + 1] = entry
            end
        end
        return out
    end
    return walk(tabs, true)
end

-- ---------------------------------------------------------------------------
-- Hidden ids
-- ---------------------------------------------------------------------------

local function settingKey(target) return SETTING_PREFIX .. target end

--- Set of hidden ids ({ [id] = true }) of a target; never nil.
function M.getHidden(target)
    local stored = SUISettings:get(settingKey(target))
    return type(stored) == "table" and stored or {}
end

-- The menu object of the running File Manager / Reader of a target, if any.
local function liveMenu(target)
    local class_path = target == MenuHooks.TARGET.FM
        and "apps/filemanager/filemanager" or "apps/reader/readerui"
    local class = package.loaded[class_path]
    return class and class.instance and class.instance.menu
end

-- Re-applies the hidden set to the menu table of a running context, so the
-- table is already current before the menu is next opened or looked up.
local function applyLive(target)
    local menu = liveMenu(target)
    if menu and menu.tab_item_table ~= nil then MenuHooks.refresh(menu, target) end
end

-- Stores the hidden set of a target and applies it to the running menu.
local function writeHidden(target, set)
    if next(set) then
        SUISettings:set(settingKey(target), set)
    else
        SUISettings:del(settingKey(target))
    end
    applyLive(target)
end

--- Hides or shows one id of a target.
function M.setHidden(target, id, hidden)
    local set = {}
    for k in pairs(M.getHidden(target)) do set[k] = true end
    set[id] = hidden and true or nil
    writeHidden(target, set)
end

--- Hidden set for the reader that mirrors the File Manager: every id present in
--- both trees takes its File Manager state; ids only in the reader keep theirs.
function M.mirrorHidden(fm_tree, reader_tree, fm_hidden, reader_hidden)
    local fm_ids = {}
    local function collect(nodes)
        for _i, node in ipairs(nodes) do
            fm_ids[node.id] = true
            if node.children then collect(node.children) end
        end
    end
    collect(fm_tree)
    local set = {}
    for k in pairs(reader_hidden) do set[k] = true end
    local function apply(nodes)
        for _i, node in ipairs(nodes) do
            if fm_ids[node.id] then set[node.id] = fm_hidden[node.id] == true or nil end
            if node.children then apply(node.children) end
        end
    end
    apply(reader_tree)
    return set
end

--- Shows every hidden entry again, in both menus.
function M.clearAll()
    for _i, target in pairs(MenuHooks.TARGET) do
        SUISettings:del(settingKey(target))
        applyLive(target)
    end
end

-- ---------------------------------------------------------------------------
-- Menu tree snapshot
-- ---------------------------------------------------------------------------

local SAVE_DELAY = 2 -- seconds between a menu build and the snapshot write

local _trees   = {} -- target -> tree captured in this session
local _written = {} -- target -> signature of the tree last written to / read from disk
local _pending = {} -- target -> tree waiting to be written

local function treePath(target)
    return require("datastorage"):getSettingsDir() .. "/simpleui/menu_tree_" .. target .. ".lua"
end

local function readTreeFile(target)
    local ok, tree = pcall(function()
        return require("luasettings"):open(treePath(target)):readSetting("tree")
    end)
    return ok and type(tree) == "table" and tree or nil
end

-- Identifies a tree by its ids and stable labels; labels that come from a
-- `text_func` are left out, as their value changes without the menu changing.
local function signature(tree)
    local out = {}
    local function walk(nodes)
        for _i, entry in ipairs(nodes) do
            out[#out + 1] = entry.id
            if not entry.dynamic then out[#out + 1] = entry.text end
            if entry.children then
                out[#out + 1] = "{"
                walk(entry.children)
                out[#out + 1] = "}"
            end
        end
    end
    walk(tree)
    return table.concat(out, "\0")
end

local function flushTree(target)
    local tree = _pending[target]
    _pending[target] = nil
    if not tree then return end
    if _written[target] == nil then
        local stored = readTreeFile(target)
        _written[target] = stored and signature(stored) or false
    end
    local sig = signature(tree)
    if sig == _written[target] then return end
    local ok, err = pcall(function()
        local file = require("luasettings"):open(treePath(target))
        file:saveSetting("tree", tree)
        file:flush()
    end)
    if ok then
        _written[target] = sig
    else
        require("logger").warn("simpleui/menu_hide: could not save menu tree:", err)
    end
end

-- Queues the snapshot for writing shortly after the menu has been built.
local function saveTree(target, tree)
    local queued = _pending[target] ~= nil
    _pending[target] = tree
    if not queued then require("ui/uimanager"):scheduleIn(SAVE_DELAY, flushTree, target) end
end

--- Label of a native tab, from the slot that describes its icon.
function M.tabLabel(id)
    local ok, SUIStyle = pcall(require, "features/sui_style")
    if not ok then return nil end
    for _i, slot in ipairs(SUIStyle.SLOTS) do
        if slot.tab_id == id and slot.label then return slot.label() end
    end
end

-- Builds the menu table of a running File Manager / Reader that has not been
-- opened yet, so its entries can be listed. The menu hook step captures the
-- tree as the table is built. Does nothing once a table exists, which also
-- keeps an open menu untouched.
local function buildLiveMenus()
    for _i, target in pairs(MenuHooks.TARGET) do
        local menu = liveMenu(target)
        if menu and menu.tab_item_table == nil and menu.setUpdateItemTable then
            local ok, err = pcall(menu.setUpdateItemTable, menu)
            if not ok then
                require("logger").warn("simpleui/menu_hide: could not build the menu:", err)
            end
        end
    end
end

--- Menu tree of a target: the one captured in this session, else the saved copy.
function M.loadTree(target)
    if not _trees[target] then _trees[target] = readTreeFile(target) end
    return _trees[target]
end

-- ---------------------------------------------------------------------------
-- Menu hook step
-- ---------------------------------------------------------------------------

local SEEN = "_sui_menu_hide_seen"
local LOG  = "_sui_menu_hide_log"

local function prepare(menu, target)
    local tabs = menu.tab_item_table
    if type(tabs) ~= "table" then return end
    -- The table is cached between openings; capture it once per build, before
    -- anything is removed.
    if not tabs[SEEN] then
        local tree = M.extractTree(tabs, M.tabLabel)
        _trees[target] = tree
        saveTree(target, tree)
        tabs[SEEN] = true
        tabs[LOG] = {}
    end
    -- The table is cached and KOReader cannot rebuild it, so the previous
    -- prune is undone before pruning with the current hidden set.
    M.restore(tabs[LOG])
    M.prune(tabs, M.getHidden(target), tabs[LOG])
end

--- A top-level tab that the current prune took out of `tabs`, by id; nil if
--- the tab is shown or does not exist. Lets other features keep using a tab
--- the user has hidden from the menu.
function M.findHiddenTab(tabs, id)
    for _i, entry in ipairs(tabs[LOG] or {}) do
        if entry.list == tabs and entry.node.id == id then return entry.node end
    end
end

-- The tab the menu opens on is remembered by position. When the tab layout
-- changes (a tab hidden or shown), that position is moved to the same tab.
local LAYOUT = "_sui_menu_hide_layout"

local function savedTabIndex(menu, target)
    if target == MenuHooks.TARGET.FM then
        return G_reader_settings:readSetting("filemanagermenu_tab_index")
    end
    return menu.last_tab_index
end

local function saveTabIndex(menu, target, index)
    if target == MenuHooks.TARGET.FM then
        G_reader_settings:saveSetting("filemanagermenu_tab_index", index)
    else
        menu.last_tab_index = index
    end
end

local function keepLastTab(menu, target)
    local tabs = menu.tab_item_table
    if type(tabs) ~= "table" then return end
    local after = {}
    for i, tab in ipairs(tabs) do after[i] = tab.id or false end
    local before = tabs[LAYOUT]
    tabs[LAYOUT] = after
    local index = savedTabIndex(menu, target)
    local id = before and index and before[index]
    if not id then return end
    local new_index = 1
    for i, tab_id in ipairs(after) do
        if tab_id == id then new_index = i; break end
    end
    if new_index ~= index then saveTabIndex(menu, target, new_index) end
end

function M.install()
    MenuHooks.register{
        id      = "menu_hide",
        order   = MenuHooks.ORDER.MENU_HIDE,
        prepare = prepare,
    }
    MenuHooks.register{
        id      = "menu_hide_last_tab",
        order   = MenuHooks.ORDER.TAB_LAYOUT,
        prepare = keepLastTab,
    }
end

-- ---------------------------------------------------------------------------
-- Editor (Style > Hide Menu Items)
-- ---------------------------------------------------------------------------

local function showProtectedNotice()
    require("infra/sui_core").Notify.toast(_("This item can't be hidden"))
end

-- Checkbox row that shows or hides `node`. A protected node is always shown.
local function makeToggleRow(target, node, text, protected)
    return {
        text           = text,
        keep_menu_open = true,
        checked_func   = function()
            return protected or not M.getHidden(target)[node.id]
        end,
        callback       = function()
            if protected then return showProtectedNotice() end
            M.setHidden(target, node.id, not M.getHidden(target)[node.id])
        end,
    }
end

local function treeHoldsProtected(node)
    if M.PROTECTED[node.id] then return true end
    for _i, child in ipairs(node.children or {}) do
        if treeHoldsProtected(child) then return true end
    end
    return false
end

-- Number of hidden entries in `nodes`; the entries inside a hidden submenu are
-- not counted on top of it, and ids that are not in the menu are ignored.
local function countHidden(nodes, hidden)
    local n = 0
    for _i, node in ipairs(nodes) do
        if hidden[node.id] == true and not treeHoldsProtected(node) then
            n = n + 1
        elseif node.children then
            n = n + countHidden(node.children, hidden)
        end
    end
    return n
end

local function hiddenLabel(n)
    if n == 0 then return "" end
    return string.format(N_("%d hidden", "%d hidden", n), n)
end

-- Greys out `row` and makes it inert while `locked()` is true. The settings
-- window drops rows with `enabled_func` false, so it gets `dim` instead.
local function applyLock(row, locked, is_sui)
    if is_sui then
        row.dim = locked() or nil
    else
        row.enabled_func = function() return not locked() end
    end
    return row
end

-- Rows for `nodes`; `locked()` tells whether an ancestor submenu is hidden.
local function makeTreeRows(target, nodes, locked, is_sui)
    local rows = {}
    for _i, node in ipairs(nodes) do
        local protected = treeHoldsProtected(node)
        if node.children then
            local show = applyLock(makeToggleRow(target, node, _("Show this menu"), protected), locked, is_sui)
            show.separator = true
            local function children_locked()
                return locked() or M.getHidden(target)[node.id] == true
            end
            local function state()
                local hidden = M.getHidden(target)
                if hidden[node.id] == true and not protected then return _("Hidden") end
                return hiddenLabel(countHidden(node.children, hidden))
            end
            rows[#rows + 1] = applyLock({
                text                = node.text,
                value_func          = state,
                mandatory_func      = state,
                sub_item_table_func = function()
                    local sub = { show }
                    for _j, row in ipairs(makeTreeRows(target, node.children, children_locked, is_sui)) do
                        sub[#sub + 1] = row
                    end
                    return sub
                end,
            }, locked, is_sui)
        else
            rows[#rows + 1] = applyLock(makeToggleRow(target, node, node.text, protected), locked, is_sui)
        end
    end
    return rows
end

local function notLocked() return false end

local function makeContextRow(target, label, missing, is_sui)
    local function hiddenCount()
        local hidden = M.getHidden(target)
        local tree = M.loadTree(target)
        local n = 0
        if tree then
            n = countHidden(tree, hidden)
        else
            for _id in pairs(hidden) do n = n + 1 end
        end
        return hiddenLabel(n)
    end
    return {
        text           = label,
        value_func     = hiddenCount,
        mandatory_func = hiddenCount,
        sub_item_table_func = function()
            local tree = M.loadTree(target)
            if not tree then
                return { { text = missing, callback = function() end } }
            end
            return makeTreeRows(target, tree, notLocked, is_sui)
        end,
    }
end

-- Settings-window row for the note: a grey rounded card with the warning
-- glyph centred in its own column, a thin rule, then the text in a small
-- regular face, wrapped over as many lines as it needs. The text composites
-- over the card instead of painting its own white background.
local function makeNoteWidget(ctx, text)
    local SUIStyle        = require("features/sui_style")
    local UI              = require("infra/sui_core")
    local Screen          = require("device").screen
    local Geom            = require("ui/geometry")
    local Size            = require("ui/size")
    local RoundedFrame    = require("infra/sui_backdrop").RoundedFrame
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LineWidget      = require("ui/widget/linewidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local SZ              = ctx.SZ
    local function dp(n) return SZ(Screen:scaleBySize(n)) end

    local h_pad, v_pad, margin = dp(8), dp(12), dp(12)
    local icon_col, gap, rule_w = dp(56), dp(14), Size.line.thin

    local icon = UI.makeColoredText{
        text    = SUIStyle.ICON.warning,
        face    = SUIStyle.glyphFace(dp(22)),
        fgcolor = SUIStyle.COLOR.text_primary,
        padding = 0,
    }
    local body = UI.makeAlphaTextBox{
        text    = text,
        face    = require("ui/font"):getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL)),
        fgcolor = SUIStyle.COLOR.text_primary,
        width   = math.max(1, ctx.inner_w - 2 * h_pad - icon_col - rule_w - gap),
    }
    local text_h = body:getSize().h

    local row = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = icon_col, h = text_h }, icon },
        LineWidget:new{
            dimen      = Geom:new{ w = rule_w, h = text_h },
            background = SUIStyle.accent(SUIStyle.COLOR.gray_strong),
        },
        HorizontalSpan:new{ width = gap },
        body,
    }
    local card = RoundedFrame:new{
        radius     = dp(12),
        bordersize = 0,
        background = SUIStyle.COLOR.surface_flat,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = ctx.inner_w, h = text_h + 2 * v_pad },
            row,
        },
    }
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = margin },
        card,
        VerticalSpan:new{ width = margin },
    }
end

--- Menu items of Style > Hide Menu Items. `ctx_menu` is the caller's menu
--- context; inside the settings window it has `is_sui` set.
function M.makeMenuItems(ctx_menu)
    local is_sui = ctx_menu and ctx_menu.is_sui or false
    buildLiveMenus()
    local missing_fm    = _("Open the File Manager once to list its menu")
    local missing_reader = _("Open a book once to list the Reader menu")
    local fm_row = makeContextRow(MenuHooks.TARGET.FM, _("File Manager"), missing_fm, is_sui)
    local reader_row = makeContextRow(MenuHooks.TARGET.READER, _("Reader"), missing_reader, is_sui)
    reader_row.separator = true
    local note = _("Make sure you can still open Simple UI settings, e.g. with a quick action.")
    -- Asks to confirm `action`; the counts shown on the rows are stale once it runs.
    local function confirmThen(touch_menu, text, action)
        require("features/dialogs/sui_dialogs").confirm{
            text        = text,
            ok_callback = function()
                action()
                if is_sui then
                    if ctx_menu.refresh then ctx_menu.refresh() end
                elseif touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems()
                end
            end,
        }
    end
    return {
        fm_row,
        reader_row,
        {
            text     = _("Apply File Manager Layout to Reader"),
            callback = function(touch_menu)
                local fm_tree     = M.loadTree(MenuHooks.TARGET.FM)
                local reader_tree = M.loadTree(MenuHooks.TARGET.READER)
                if not fm_tree or not reader_tree then
                    require("infra/sui_core").Notify.toast(fm_tree and missing_reader or missing_fm)
                    return
                end
                confirmThen(touch_menu,
                    _("Hide and show the Reader menu items shared with the File Manager as they are in the File Manager?"),
                    function()
                        local set = M.mirrorHidden(fm_tree, reader_tree,
                            M.getHidden(MenuHooks.TARGET.FM), M.getHidden(MenuHooks.TARGET.READER))
                        writeHidden(MenuHooks.TARGET.READER, set)
                    end)
            end,
        },
        {
            text     = _("Show All Items"),
            callback = function(touch_menu)
                confirmThen(touch_menu, _("Show all hidden menu items again?"), M.clearAll)
            end,
            separator = true,
        },
        {
            text           = note,
            keep_menu_open = true,
            callback       = function() end,
            sui_build      = is_sui and function(ctx) return makeNoteWidget(ctx, note) end or nil,
        },
    }
end

return M
