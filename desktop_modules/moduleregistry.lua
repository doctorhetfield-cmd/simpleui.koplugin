-- moduleregistry.lua — Simple UI
-- Registry estático dos módulos partilhados entre páginas.
--
-- DESIGN (optimizado para dispositivos lentos)
-- ① Lista estática: sem lfs.dir(), sem I/O de descoberta.
-- ② Lazy-require: ficheiros de módulo só carregados na primeira chamada a
--    Registry.list() — nunca no boot do plugin.
-- ③ Cache: após o primeiro load, _loaded/_by_id são tabelas em RAM,
--    reutilizadas em todos os renders subsequentes.
-- ④ Zero lógica de negócio aqui: cada módulo declara os seus próprios
--    metadados, enabled_key e defaults.
--
-- CONTRATO DE CADA MÓDULO (module_*.lua)
--
--   M.id             string   id único estável, e.g. "clock", "collections"
--   M.name           string   nome legível para menus / Arrange
--   M.label          string?  texto da section label acima do módulo (nil = sem label)
--   M.enabled_key    string?  sufixo de settings: pfx .. enabled_key → bool
--   M.default_on     bool?    valor quando a chave não existe (default true)
--
--   -- Flags declarativas (opcionais — usadas pelo homescreen):
--   M.has_covers     bool?    true → activa dithering e-ink e cover poll
--                             (equivalente a pertencer a _COVER_MOD_IDS)
--   M.is_book_mod    bool?    true → suprime empty-state "No books opened yet"
--                             (equivalente a "currently"/"recent"/"coverdeck")
--
--   M.isEnabled(pfx)         → bool         (opcional; substitui enabled_key)
--   M.build(w, ctx)          → widget | nil
--   M.getHeight(ctx)         → number
--   M.getMenuItems(ctx_menu) → table | nil  (nil = sem sub-menu de settings)
--
-- Módulos instanciáveis (e.g. quick_actions_row) declaram
--   M.instanciable = true
--   M.makeInstance(id) → sub-module descriptor
-- e não têm id próprio no registry — só as instâncias têm.
-- As instâncias persistem em "simpleui_qa_row_instances" (lista de ids).
--
-- ADICIONAR UM MÓDULO BUILT-IN: append de uma linha em MODULES. Nada mais.
--
-- ADICIONAR UM MÓDULO EXTERNO (plugin de terceiros):
--   local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
--   if ok and Registry then
--       Registry.register(MyModule)           -- tabela já carregada
--       -- ou Registry.register("myplugin/module_foo")  -- path require-able
--   end
--   -- No teardown do plugin:
--   if Registry then Registry.unregister("myplugin_foo_id") end
--
-- NOTE: module_header is intentionally absent — it has been split into
-- module_clock (Clock / Clock+Date / Custom Text) and module_quote
-- (Quote of the Day). Installations that still use module_header directly
-- are unaffected; it remains loadable as a standalone file.

local logger = require("logger")
local SUISettings = require("sui_store")

local MODULES = {
    { require_mod = "desktop_modules/module_clock"         },
    { require_mod = "desktop_modules/module_quote"         },
    { require_mod = "desktop_modules/module_currently"     },
    { require_mod = "desktop_modules/module_recent"        },
    { require_mod = "desktop_modules/module_coverdeck"     },
    { require_mod = "desktop_modules/module_new_books"     },
    { require_mod = "desktop_modules/module_tbr"           },
    { require_mod = "desktop_modules/module_collections"   },
    { require_mod = "desktop_modules/module_reading_goals" },
    { require_mod = "desktop_modules/module_hardcover"     },
    { require_mod = "desktop_modules/module_reading_stats" },
    { require_mod = "desktop_modules/module_quick_actions" },
    { require_mod = "desktop_modules/module_action_list"   },
    { require_mod = "desktop_modules/module_spacer"        },
}

local _loaded        = nil
local _by_id         = nil
local _default_order = nil
-- Base descriptors for instanciable modules, keyed by base_id.
local _instanciable  = {}
-- External modules registered at runtime by third-party plugins.
-- Entries are either a module table (already loaded) or a require-path string.
-- Built-ins in MODULES always precede externals in the final list.
local _external      = {}

local Registry = {}

-- ---------------------------------------------------------------------------
-- _placedInstanceIds()
--
-- Returns a set (table keyed by id, value true) of every module id that is
-- actually placed somewhere in the current homescreen layout. This is the
-- source of truth used to prune orphaned instanciable-module entries (rows
-- that exist in "*_instances" lists but were never added to a page, or were
-- removed from a page through a path that didn't call destroyInstance).
--
-- Reads "simpleui_layout" (pages[*].modules) when present, falling back to
-- the flat "simpleui_hs_module_order" otherwise — mirroring the same
-- sources sui_homescreen.lua uses to render the layout.
-- ---------------------------------------------------------------------------
local function _placedInstanceIds()
    local placed = {}
    local layout = SUISettings:readSetting("simpleui_layout")
    if type(layout) == "table" and type(layout.pages) == "table" then
        for _, page in ipairs(layout.pages) do
            if type(page.modules) == "table" then
                for _, mod_id in ipairs(page.modules) do
                    placed[mod_id] = true
                end
            end
        end
    else
        local order = SUISettings:readSetting("simpleui_hs_module_order")
        if type(order) == "table" then
            for _, mod_id in ipairs(order) do
                placed[mod_id] = true
            end
        end
    end
    return placed
end

-- ---------------------------------------------------------------------------
-- _pruneOrphanInstances(mod, placed)
--
-- For an instanciable module descriptor `mod`, removes any id from its
-- persisted instances list (mod.instances_key, default
-- "simpleui_qa_row_instances") that is not placed in the current layout
-- (per _placedInstanceIds), and purges that instance's settings keys via
-- Registry.purgeInstanceSettings.
--
-- Runs once per _load() — i.e. once per plugin lifetime — before instances
-- are materialised, so stale ids never consume a display number or get
-- re-instantiated.
-- ---------------------------------------------------------------------------
local function _pruneOrphanInstances(mod, placed)
    local inst_key = mod.instances_key or "simpleui_qa_row_instances"
    local inst_ids = SUISettings:readSetting(inst_key) or {}
    if #inst_ids == 0 then return inst_ids end

    local kept    = {}
    local orphans = {}
    for _, iid in ipairs(inst_ids) do
        if placed[iid] then
            kept[#kept + 1] = iid
        else
            orphans[#orphans + 1] = iid
        end
    end

    if #orphans == 0 then return inst_ids end

    SUISettings:set(inst_key, kept)

    for _, iid in ipairs(orphans) do
        Registry.purgeInstanceSettings(iid, "simpleui_hs_")
        logger.dbg("simpleui: moduleregistry: pruned orphaned instance '" .. iid .. "' (key=" .. inst_key .. ")")
    end

    return kept
end

local function _load()
    if _loaded then return end
    _loaded = {}
    _by_id  = {}
    local placed = _placedInstanceIds()
    -- ── Built-ins ────────────────────────────────────────────────────────────
    for _, def in ipairs(MODULES) do
        local ok, mod = pcall(require, def.require_mod)
        if not ok or not mod then
            logger.warn("simpleui: moduleregistry: failed to load '" .. def.require_mod .. "': " .. tostring(mod))
        elseif mod then
            if mod.instanciable then
                -- Dynamic-instance module: prune orphaned instance ids, then
                -- load the (now-clean) persisted instance ids and materialise
                -- one descriptor per instance.
                local inst_ids = _pruneOrphanInstances(mod, placed)
                for _, iid in ipairs(inst_ids) do
                    local m = mod.makeInstance(iid)
                    if m and type(m.id) == "string" and not _by_id[m.id] then
                        _loaded[#_loaded + 1] = m
                        _by_id[m.id]          = m
                    end
                end
                -- Keep the base descriptor accessible for createInstance.
                _instanciable[mod.id or "quick_actions_row"] = mod
            else
                local list = mod.sub_modules or { mod }
                for _, m in ipairs(list) do
                    if type(m.id) == "string" then
                        _loaded[#_loaded + 1] = m
                        _by_id[m.id]          = m
                    end
                end
            end
        end
    end
    -- ── Externals ────────────────────────────────────────────────────────────
    for _, entry in ipairs(_external) do
        local ok, mod
        if type(entry) == "string" then
            ok, mod = pcall(require, entry)
            if not ok or not mod then
                logger.warn("simpleui: moduleregistry: failed to load external '" .. entry .. "': " .. tostring(mod))
            end
        elseif type(entry) == "table" then
            ok, mod = true, entry
        end
        if ok and mod then
            local list = mod.sub_modules or { mod }
            for _, m in ipairs(list) do
                if type(m.id) == "string" and not _by_id[m.id] then
                    _loaded[#_loaded + 1] = m
                    _by_id[m.id]          = m
                end
            end
        end
    end
end

function Registry.list()
    _load(); return _loaded
end

function Registry.get(id)
    _load(); return _by_id[id]
end

function Registry.isEnabled(mod, pfx)
    if type(mod.isEnabled) == "function" then
        return mod.isEnabled(pfx)
    end
    if mod.enabled_key then
        local v = SUISettings:readSetting(pfx .. mod.enabled_key)
        if v == nil then return mod.default_on ~= false end
        return v == true
    end
    return mod.default_on ~= false
end

function Registry.countEnabled(pfx)
    local n = 0
    for _, mod in ipairs(Registry.list()) do
        if Registry.isEnabled(mod, pfx) then n = n + 1 end
    end
    return n
end

-- Merges the saved module order for a given settings prefix with the registry
-- default, appending any modules not present in the saved list.
-- Returns the cached default directly when no custom order has been saved.
function Registry.loadOrder(pfx)
    local saved = SUISettings:readSetting(pfx .. "module_order")
    if type(saved) ~= "table" or #saved == 0 then
        return Registry.defaultOrder()
    end
    local default = Registry.defaultOrder()
    local seen = {}; local result = {}
    for _, v in ipairs(saved)   do seen[v] = true; result[#result+1] = v end
    for _, v in ipairs(default) do
        if not seen[v] then
            if v == "coverdeck" then
                local insert_at = nil
                for i, id in ipairs(result) do
                    if id == "recent" then insert_at = i + 1; break end
                    if id == "currently" then insert_at = i + 1 end
                end
                if insert_at then
                    table.insert(result, insert_at, v)
                else
                    result[#result+1] = v
                end
            else
                result[#result+1] = v
            end
        end
    end
    return result
end

function Registry.defaultOrder()
    if not _default_order then
        _default_order = {}
        for _, mod in ipairs(Registry.list()) do
            _default_order[#_default_order + 1] = mod.id
        end
    end
    return _default_order
end

function Registry.invalidate()
    _loaded        = nil
    _by_id         = nil
    _default_order = nil
    _instanciable  = {}
end

-- ---------------------------------------------------------------------------
-- Registry.createInstance(base_id) → instance_id | nil
--
-- Creates a new instance of an instanciable module, persists its id in
-- "simpleui_qa_row_instances", registers it in _loaded/_by_id, and returns
-- the new instance id (e.g. "quick_actions_row_a1b2c3").
-- Returns nil if the base module is not instanciable or not found.
-- ---------------------------------------------------------------------------
function Registry.createInstance(base_id)
    _load()
    local base = _instanciable[base_id or "quick_actions_row"]
    if not base then return nil end
    -- Generate a short unique id: base_id + 6-char hex timestamp fragment.
    local inst_id = (base_id or "quick_actions_row") .. "_" .. string.format("%06x", math.floor(os.time() * 1000) % 0xFFFFFF)
    -- Avoid collisions (unlikely but safe).
    if _by_id[inst_id] then inst_id = inst_id .. "x" end
    local m = base.makeInstance(inst_id)
    if not m or type(m.id) ~= "string" then return nil end
    _loaded[#_loaded + 1] = m
    _by_id[m.id]          = m
    _default_order        = nil  -- invalidate order cache
    -- Persist using the base module's instances_key.
    local inst_key = base.instances_key or "simpleui_qa_row_instances"
    local ids = SUISettings:readSetting(inst_key) or {}
    ids[#ids + 1] = inst_id
    SUISettings:set(inst_key, ids)
    return inst_id
end

-- ---------------------------------------------------------------------------
-- Registry.destroyInstance(inst_id)
--
-- Removes an instanciable module instance from the registry and from the
-- persisted instance list. Does NOT remove the module's own settings keys
-- (items, shape, bg, etc.) — callers that want a clean slate should call
-- Registry.purgeInstanceSettings(inst_id) first or after.
-- ---------------------------------------------------------------------------
function Registry.destroyInstance(inst_id)
    if not inst_id then return end
    _load()
    -- Remove from _loaded.
    for i = #_loaded, 1, -1 do
        if _loaded[i].id == inst_id then
            table.remove(_loaded, i)
            break
        end
    end
    _by_id[inst_id] = nil
    _default_order  = nil
    -- Determine which instances_key this instance belongs to by checking all
    -- instanciable base modules.
    local function _remove_from_key(key)
        local ids = SUISettings:readSetting(key) or {}
        local new_ids = {}
        local found = false
        for _, id in ipairs(ids) do
            if id ~= inst_id then new_ids[#new_ids + 1] = id
            else found = true end
        end
        if found then SUISettings:set(key, new_ids) end
        return found
    end
    -- Try each registered instanciable base's key; fall back to legacy key.
    local removed = false
    for _, base in pairs(_instanciable) do
        local key = base.instances_key or "simpleui_qa_row_instances"
        if _remove_from_key(key) then removed = true; break end
    end
    if not removed then
        _remove_from_key("simpleui_qa_row_instances")
    end
end

-- ---------------------------------------------------------------------------
-- Registry.purgeInstanceSettings(inst_id, pfx)
--
-- Removes all settings keys that belong to this instance: enabled, shape,
-- bg, items, labels, scale, gap, label_scale (under both pfx and pfx_qa).
-- Safe to call even if the instance no longer exists in the registry.
-- ---------------------------------------------------------------------------
function Registry.purgeInstanceSettings(inst_id, pfx)
    pfx = pfx or "simpleui_hs_"
    local qa_pfx = "simpleui_hs_qa_"
    local suffixes = { "_enabled", "_shape", "_bg", "_items", "_labels",
                       "_scale_pct", "_gap_pct", "_item_label_scale_pct" }
    for _, s in ipairs(suffixes) do
        SUISettings:set(pfx    .. inst_id .. s, nil)
        SUISettings:set(qa_pfx .. inst_id .. s, nil)
    end
    -- Also the bare keys used by build/getHeight.
    SUISettings:set(qa_pfx .. inst_id .. "_items",  nil)
    SUISettings:set(qa_pfx .. inst_id .. "_labels", nil)
end

-- ---------------------------------------------------------------------------
-- Registry.isInstanciable(base_id) → bool
-- ---------------------------------------------------------------------------
function Registry.isInstanciable(base_id)
    _load()
    return _instanciable[base_id] ~= nil
end

-- ---------------------------------------------------------------------------
-- Registry.getBase(base_id) → base module table | nil
--
-- Returns the base descriptor of an instanciable module (e.g. the table
-- with M.id, M.name, M.makeInstance). Unlike Registry.get(), this works for
-- instanciable bases which are not present in _by_id (only instances are).
-- ---------------------------------------------------------------------------
function Registry.getBase(base_id)
    _load()
    return _instanciable[base_id]
end

-- ---------------------------------------------------------------------------
-- Registry.register(mod_or_path)
--
-- Registers an external module so it appears in the homescreen, Arrange menu,
-- and loadOrder — exactly like built-in modules.
--
-- mod_or_path: a module table (with at least M.id set) OR a require-path
--              string (e.g. "myplugin/module_foo").
--
-- Safe to call multiple times with the same id — the previous entry is
-- replaced in _external and the cache is invalidated so the next render picks
-- up the new definition.
-- ---------------------------------------------------------------------------
function Registry.register(mod_or_path)
    if mod_or_path == nil then
        logger.warn("simpleui: moduleregistry: register() called with nil")
        return
    end
    -- Determine the id for dedup (only possible when a table is passed).
    local new_id
    if type(mod_or_path) == "table" then
        local list = mod_or_path.sub_modules or { mod_or_path }
        new_id = list[1] and list[1].id
    end
    -- Replace existing entry with same id (if any), otherwise append.
    local replaced = false
    if new_id then
        for i, entry in ipairs(_external) do
            local entry_id
            if type(entry) == "table" then
                local el = entry.sub_modules or { entry }
                entry_id = el[1] and el[1].id
            end
            if entry_id == new_id then
                _external[i] = mod_or_path
                replaced = true
                break
            end
        end
    end
    if not replaced then
        _external[#_external + 1] = mod_or_path
    end
    Registry.invalidate()
end

-- ---------------------------------------------------------------------------
-- Registry.unregister(id)
--
-- Removes a previously registered external module by its M.id string.
-- No-op when the id is unknown or refers to a built-in.
-- If a homescreen instance is currently displayed, call
-- plugin:_rebuildAllNavbars() or trigger a homescreen refresh after this.
-- ---------------------------------------------------------------------------
function Registry.unregister(id)
    if type(id) ~= "string" then return end
    for i = #_external, 1, -1 do
        local entry = _external[i]
        local entry_id
        if type(entry) == "table" then
            local el = entry.sub_modules or { entry }
            entry_id = el[1] and el[1].id
        end
        if entry_id == id then
            table.remove(_external, i)
            Registry.invalidate()
            return
        end
    end
end

return Registry
