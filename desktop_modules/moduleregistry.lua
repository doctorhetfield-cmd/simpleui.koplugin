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
--   M.isEnabled(pfx)         → bool         (opcional; substitui enabled_key)
--   M.build(w, ctx)          → widget | nil
--   M.getHeight(ctx)         → number
--   M.getMenuItems(ctx_menu) → table | nil  (nil = sem sub-menu de settings)
--
-- Módulos com múltiplos slots (e.g. quick_actions) devolvem
--   M.sub_modules = { slot1, slot2, … }
-- em vez de um único id.
--
-- ADICIONAR UM MÓDULO: append de uma linha em MODULES. Nada mais.
--
-- NOTE: module_header is intentionally absent — it has been split into
-- module_clock (Clock / Clock+Date / Custom Text) and module_quote
-- (Quote of the Day). Installations that still use module_header directly
-- are unaffected; it remains loadable as a standalone file.

local logger = require("logger")

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
    { require_mod = "desktop_modules/module_reading_stats" },
    { require_mod = "desktop_modules/module_quick_actions" },
    { require_mod = "desktop_modules/module_action_list"   },
}

local _loaded        = nil
local _by_id         = nil
local _default_order = nil

local function _load()
    if _loaded then return end
    _loaded = {}
    _by_id  = {}
    for _, def in ipairs(MODULES) do
        local ok, mod = pcall(require, def.require_mod)
        if not ok or not mod then
            logger.warn("simpleui: moduleregistry: failed to load '" .. def.require_mod .. "': " .. tostring(mod))
        elseif mod then
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

local Registry = {}

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
        local v = G_reader_settings:readSetting(pfx .. mod.enabled_key)
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
    local saved = G_reader_settings:readSetting(pfx .. "module_order")
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
end

return Registry
