-- moduleregistry.lua — Simple UI
-- Static registry of the modules shared between pages.
--
-- DESIGN (optimized for slow devices)
-- ① Static list: no lfs.dir(), no discovery I/O.
-- ② Lazy-require: module files are only loaded on the first call to
--    Registry.list() — never at plugin boot — and modules with a `lazy`
--    manifest in MODULES only once a field beyond the manifest is read
--    (in practice, once they are enabled and rendered).
-- ③ Cache: after the first load, _loaded/_by_id are tables in RAM,
--    reused across all subsequent renders.
-- ④ Zero business logic here: each module declares its own
--    metadata, enabled_key and defaults.
--
-- CONTRACT FOR EACH MODULE (module_*.lua)
--
--   M.id             string   stable unique id, e.g. "clock", "collections"
--   M.name           string   readable name for menus / Arrange
--   M.label          string?  section label text shown above the module (nil = no label)
--   M.label_right_func fun(ctx):string?  optional; text shown right-aligned on the same
--                             row as the label (e.g. a setting-dependent mode indicator),
--                             in the same style as the page indicator it takes priority
--                             over. Ignored when the module defines M.getLabel.
--   M.getLabel       fun(ctx):table?  optional; full control over the label: returns a
--                             descriptor built with SectionLabel.makeDescriptor (text may
--                             depend on the instance), or nil for no label. Without it the
--                             descriptor is derived from M.label / M.label_right_func.
--                             Visibility (the "Show section label" toggle) is applied by
--                             the descriptor, never by mutating M.label.
--   M.category       string?  group of the Add Module picker: "books", "stats",
--                             "shortcuts" or "extras" (see Registry.getCategories);
--                             unset → "other". An instance takes its base's.
--   M.enabled_key    string?  settings suffix: pfx .. enabled_key → bool
--   M.default_on     bool?    value when the key doesn't exist (default true)
--
--   -- Declarative flags (optional — used by the homescreen):
--   M.has_covers     bool?    true → enables e-ink dithering and cover poll
--                             (equivalent to belonging to _COVER_MOD_IDS)
--   M.is_book_mod    bool?    true → suppresses the "No books opened yet" empty-state
--                             (equivalent to "currently"/"recent"/"coverdeck") and lets
--                             the module repaint alone after a page turn
--   M.needs          table?   data the screen engine prepares while the module is enabled:
--                             recent = n | function(pfx) -> n   n recent books in
--                                      ctx.recent_fps (see Registry.getRecentDemand)
--                             db, stats, books, status, records, charts, year
--                                      = true | function(pfx) -> bool
--                                      the DB connection, StatsProvider's stats,
--                                      the finished-books ledger, the library
--                                      status counts, the session records, the
--                                      chart data and the year data (see
--                                      Registry.wantsData)
--   M.text_elems     string[]?  ids of the text elements with a user-selectable
--                             font family, size scale and variant (regular, bold,
--                             italic, bold italic; see Config.makeTextStyleMenu).
--                             Each style is { family, scale, variant, color }. The screen
--                             engine reads them into ctx.cfg[M.id].text; render multiplies
--                             scale into the element font size and draws the face with
--                             SUIStyle.getTextFace. Elements that are not regular by
--                             default are declared with Config.declareTextVariants.
--                             Elements that can take a palette colour are declared with
--                             Config.declareTextColors; render picks the colour with
--                             SUIStyle.textColor(style, ctx.palette, default).
--
--   M.isEnabled(pfx)         → bool         (optional; replaces enabled_key)
--   M.build(w, ctx)          → widget | nil
--   M.getHeight(ctx)         → number
--   M.fills_row_height       → bool         (optional; in a Home Screen row taller than the
--                                            module, build is called again with ctx.grow_h,
--                                            the extra height in px, to use it)
--   M.getMenuItems(ctx_menu) → table | nil  (nil = no settings sub-menu)
--
-- Instantiable modules (e.g. quick_actions_row) declare
--   M.instanciable = true
--   M.makeInstance(id) → sub-module descriptor
-- and don't have their own id in the registry — only the instances do.
-- Instance ids are "<base id>_<hex>". Each base persists its instance ids in
-- the list stored under M.instances_key (default "simpleui_qa_row_instances").
-- A base may also declare:
--   M.bare_instance = true           the base id is itself the first instance
--                                    (keys pfx .. base id .. suffix). It is
--                                    never pruned or destroyed, and
--                                    createInstance hands it out again while
--                                    it sits on no surface
--   M.menu_group = "quick_actions"   groups its instances under that entry of
--                                    the global module settings menu
--   M.setting_suffixes = { "_tabs" } suffixes of the instance's own settings
--                                    keys (pfx .. inst_id .. suffix), removed
--                                    together with the instance
-- A module (instanciable or not) may also declare:
--   M.getSummary(mod_id, pfx, pfx_qa) → string | nil
--                                    what the module shows (its selected
--                                    items), listed in the layout editor
--                                    under a full-width module
--   M.takeHoldAction(pfx) → { icon, label?, on_tap(refresh) } | nil
--                                    action for what the long-press that
--                                    opens the module settings fell on (set
--                                    by the module's own hold handler, which
--                                    lets the hold through); shown as a
--                                    button beside the layout one and
--                                    cleared by the call. on_tap gets a
--                                    function to run after every change
--   M.owns_chrome = true             the module draws its own frame and
--                                    background boxes (see
--                                    features/sui_module_chrome.lua): the
--                                    screen engine skips the module-wide
--                                    chrome and builds it at the full column
--                                    width, label insets included
-- Registry.baseId / isInstance / getInstanceIndex / getInstanceKeys resolve
-- instances generically; nothing outside the registry should match on id
-- patterns.
--
-- ADDING A BUILT-IN MODULE: append a line to MODULES (with a `lazy` manifest
-- when the module qualifies, see MODULES). Nothing else.
-- Callers that walk Registry.list() during a render read only id /
-- enabled_key / default_on (or call Registry.isEnabled) before checking that
-- a module is enabled, so disabled lazy modules stay unloaded.
--
-- ADDING AN EXTERNAL MODULE (third-party plugin):
--   local ok, Registry = pcall(require, "modules/moduleregistry")
--   if ok and Registry then
--       Registry.register(MyModule)           -- already-loaded table
--       -- or Registry.register("myplugin/module_foo")  -- require-able path
--   end
--   -- On plugin teardown:
--   if Registry then Registry.unregister("myplugin_foo_id") end
--
-- NOTE: module_header is intentionally absent — it has been split into
-- module_clock (Clock / Clock+Date / Custom Text) and module_quote
-- (Quote of the Day). Installations that still use module_header directly
-- are unaffected; it remains loadable as a standalone file.

local logger = require("logger")
local SUISettings = require("infra/sui_store")
local _ = require("infra/sui_i18n").translate

-- An entry with `lazy` is represented by a proxy descriptor that answers
-- id / enabled_key / default_on from the manifest and requires the module on
-- the first access to any other field, so modules that are off never load.
-- Only for modules without M.isEnabled, M.sub_modules or M.instanciable; the
-- manifest must match the module (checked when it loads).
-- An entry with `instanciable` is an instanciable base (M.instanciable).
local MODULES = {
    { require_mod = "modules/module_clock"         },
    { require_mod = "modules/module_quote",
      lazy = { id = "quote",         enabled_key = "quote_enabled",         default_on = false } },
    { require_mod = "modules/module_currently",
      lazy = { id = "currently",     enabled_key = "currently_enabled",     default_on = true  } },
    { require_mod = "modules/module_recent",
      lazy = { id = "recent",        enabled_key = "recent_enabled",        default_on = false } },
    { require_mod = "modules/module_new_books",
      lazy = { id = "new_books",     enabled_key = "new_books_enabled",     default_on = false } },
    -- Also the TBR data/API layer the collection hooks expect loaded.
    { require_mod = "modules/module_tbr"           },
    { require_mod = "modules/module_coverdeck",
      lazy = { id = "coverdeck",     enabled_key = "coverdeck_enabled",     default_on = false } },
    { require_mod = "modules/module_collections",
      lazy = { id = "collections",   enabled_key = "collections_enabled",   default_on = false } },
    { require_mod = "modules/module_feat_coll",      instanciable = true },
    { require_mod = "modules/module_tab_grid",       instanciable = true },
    { require_mod = "modules/module_library",
      lazy = { id = "flat_library",  enabled_key = "flat_library_enabled",  default_on = false } },
    { require_mod = "modules/module_reading_goals",
      lazy = { id = "reading_goals", enabled_key = "reading_goals_enabled", default_on = true  } },
    { require_mod = "modules/reading_stats/module_reading_stats", instanciable = true },
    { require_mod = "modules/module_heatmap",
      lazy = { id = "heatmap",       enabled_key = "heatmap_enabled",       default_on = false } },
    { require_mod = "modules/critter/module_critter",
      lazy = { id = "critter",       enabled_key = "critter_enabled",       default_on = false } },
    { require_mod = "modules/module_quick_actions",  instanciable = true },
    { require_mod = "modules/module_action_list"   },
    { require_mod = "modules/module_spacer",         instanciable = true },
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

local DEFAULT_INSTANCES_KEY = "simpleui_qa_row_instances"

local function _instancesKey(base)
    return base.instances_key or DEFAULT_INSTANCES_KEY
end

-- True when `id` is the bare instance of `base` (see M.bare_instance).
local function _isBareInstance(base, id)
    return base.bare_instance == true and id == base.id
end

-- Base descriptors of every instanciable built-in module, in MODULES order.
-- Reads the require cache only: unlike _load() it never materialises or
-- prunes instances, so it is safe to call at any time (e.g. while a backup
-- is being restored).
local _bases_cache = nil
local function _instanciableBases()
    if _bases_cache then return _bases_cache end
    local bases = {}
    for _, def in ipairs(MODULES) do
        if def.instanciable then
            local ok, mod = pcall(require, def.require_mod)
            if ok and type(mod) == "table" and mod.instanciable then
                bases[#bases + 1] = mod
            end
        end
    end
    _bases_cache = bases
    return bases
end

-- Proxy descriptor → its MODULES entry and module, for lazy modules (see
-- MODULES); MODULES entry → its proxy, kept across Registry.invalidate().
local _proxies = {}
local _proxy_of = {}

-- The real module behind a proxy, required on first use; nil when it fails.
local function _resolve(proxy)
    local p = _proxies[proxy]
    if p.mod == nil then
        local def = p.def
        local ok, mod = pcall(require, def.require_mod)
        if not ok or type(mod) ~= "table" then
            logger.warn("simpleui: moduleregistry: failed to load '" .. def.require_mod .. "': " .. tostring(mod))
            p.mod = false
        else
            p.mod = mod
            local m = def.lazy
            if mod.id ~= m.id or mod.enabled_key ~= m.enabled_key
                    or (mod.default_on ~= false) ~= m.default_on
                    or mod.isEnabled or mod.sub_modules or mod.instanciable then
                logger.warn("simpleui: moduleregistry: lazy manifest out of date for '" .. def.require_mod .. "'")
            end
        end
    end
    return p.mod or nil
end

local function _makeProxy(def)
    local m = def.lazy
    local proxy = setmetatable({ id = m.id, enabled_key = m.enabled_key, default_on = m.default_on }, {
        __index = function(t, k)
            local mod = _resolve(t)
            if mod then return mod[k] end
        end,
        __newindex = function(t, k, v)
            local mod = _resolve(t)
            if mod then mod[k] = v end
        end,
    })
    _proxies[proxy] = { def = def }
    _proxy_of[def] = proxy
    return proxy
end

-- Base descriptor an instance id belongs to, or nil for a non-instance id.
local function _baseOf(mod_id)
    if type(mod_id) ~= "string" then return nil end
    for _, base in ipairs(_instanciableBases()) do
        if mod_id:sub(1, #base.id + 1) == base.id .. "_" or _isBareInstance(base, mod_id) then
            return base
        end
    end
    return nil
end

-- "coll_row_a1b2c3" → "coll_row"; nil when `mod_id` is not an instance.
function Registry.baseId(mod_id)
    local base = _baseOf(mod_id)
    return base and base.id
end

function Registry.isInstance(mod_id)
    return _baseOf(mod_id) ~= nil
end

-- Ids of every instanciable base, in MODULES order.
function Registry.getInstanciableBaseIds()
    local ids = {}
    for _, base in ipairs(_instanciableBases()) do ids[#ids + 1] = base.id end
    return ids
end

-- Settings keys under which the instance id lists are persisted.
function Registry.getInstanceKeys()
    local keys = {}
    for _, base in ipairs(_instanciableBases()) do keys[#keys + 1] = _instancesKey(base) end
    return keys
end

-- Creation-order position of an instance and the number of instances of its
-- base: index, count. nil when `mod_id` is not a persisted instance.
function Registry.getInstanceIndex(mod_id)
    local base = _baseOf(mod_id)
    if not base then return nil end
    local ids = SUISettings:readSetting(_instancesKey(base)) or {}
    for idx, iid in ipairs(ids) do
        if iid == mod_id then return idx, #ids end
    end
    return nil
end

-- Menu group declared by the instance's base (see the header), or nil.
function Registry.getMenuGroup(mod_id)
    local base = _baseOf(mod_id)
    return base and base.menu_group
end

-- Categories of the Add Module picker, in display order. Built per call so the
-- titles follow the current language.
function Registry.getCategories()
    return {
        { key = "books",     title = _("Books")      },
        { key = "stats",     title = _("Statistics") },
        { key = "shortcuts", title = _("Shortcuts")  },
        { key = "extras",    title = _("Extras")     },
        { key = "other",     title = _("Other")      },
    }
end

-- Category key of a module, instance or instanciable base; "other" when unset
-- or unknown.
function Registry.getCategory(mod_id)
    local mod = _baseOf(mod_id) or Registry.get(mod_id) or _instanciable[mod_id]
    local cat = mod and mod.category
    for _i, c in ipairs(Registry.getCategories()) do
        if c.key == cat then return cat end
    end
    return "other"
end

-- Layout-editor summary of a module or instance, or nil when it provides none.
function Registry.getSummary(mod_id, pfx, pfx_qa)
    local mod = _baseOf(mod_id) or Registry.get(mod_id)
    if mod and mod.getSummary then
        return mod.getSummary(mod_id, pfx, pfx_qa)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- _placedInstanceIds()
--
-- Returns a set (table keyed by id, value true) of every module id that is
-- actually placed somewhere across ALL homescreen-like surfaces — the
-- built-in Homescreen plus every Custom Screen. This is the source of truth
-- used to prune orphaned instanciable-module entries (rows that exist in
-- "*_instances" lists but were never added to a page, or were removed from
-- a page through a path that didn't call destroyInstance).
--
-- Reads "simpleui_layout" (pages[*].modules) when present, falling back to
-- the flat "simpleui_hs_module_order" otherwise — mirroring the same
-- sources sui_homescreen.lua uses to render the layout — then repeats the
-- same read for every registered Custom Screen's own layout_key. A module
-- instance placed only on a Custom Screen (e.g. a Quick Actions Row) must
-- show up here or it gets silently pruned on the next _load().
-- ---------------------------------------------------------------------------
local function _collectPagesModules(layout, placed)
    if type(layout) == "table" and type(layout.pages) == "table" then
        for _, page in ipairs(layout.pages) do
            if type(page.modules) == "table" then
                for _, entry in ipairs(page.modules) do
                    local mod_id = type(entry) == "table" and entry.id or entry
                    if mod_id then placed[mod_id] = true end
                end
            end
        end
        return true
    end
    return false
end

local function _placedInstanceIds()
    local placed = {}

    local layout = SUISettings:readSetting("simpleui_layout")
    if not _collectPagesModules(layout, placed) then
        local order = SUISettings:readSetting("simpleui_hs_module_order")
        if type(order) == "table" then
            for _, mod_id in ipairs(order) do
                placed[mod_id] = true
            end
        end
    end

    -- Custom Screens: same "pages[*].modules" shape, one layout_key per
    -- screen. Lazy-required to avoid a hard load-order dependency on
    -- infra/sui_custom_screens from this low-level registry module.
    local ok_cs, CustomScreens = pcall(require, "infra/sui_custom_screens")
    if ok_cs and CustomScreens then
        for _, screen in ipairs(CustomScreens.list()) do
            local cs_layout = SUISettings:readSetting(screen.layout_key)
            _collectPagesModules(cs_layout, placed)
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
    local inst_key = _instancesKey(mod)
    local inst_ids = SUISettings:readSetting(inst_key) or {}
    if #inst_ids == 0 then return inst_ids end

    local kept    = {}
    local orphans = {}
    for _, iid in ipairs(inst_ids) do
        if placed[iid] or _isBareInstance(mod, iid) then
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

-- Lists the bare instance of `base` (first) when the stored list lacks it.
local function _ensureBareInstance(base, inst_ids)
    if not base.bare_instance then return inst_ids end
    for _, iid in ipairs(inst_ids) do
        if iid == base.id then return inst_ids end
    end
    table.insert(inst_ids, 1, base.id)
    SUISettings:set(_instancesKey(base), inst_ids)
    return inst_ids
end

local function _load()
    if _loaded then return end
    _loaded = {}
    _by_id  = {}
    local placed = _placedInstanceIds()
    -- ── Built-ins ────────────────────────────────────────────────────────────
    for _, def in ipairs(MODULES) do
        if def.lazy then
            local proxy = _proxy_of[def] or _makeProxy(def)
            _loaded[#_loaded + 1] = proxy
            _by_id[proxy.id]      = proxy
            goto continue
        end
        local ok, mod = pcall(require, def.require_mod)
        if not ok or not mod then
            logger.warn("simpleui: moduleregistry: failed to load '" .. def.require_mod .. "': " .. tostring(mod))
        elseif mod then
            if mod.instanciable then
                -- Dynamic-instance module: prune orphaned instance ids, then
                -- load the (now-clean) persisted instance ids and materialise
                -- one descriptor per instance.
                local inst_ids = _ensureBareInstance(mod, _pruneOrphanInstances(mod, placed))
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
        ::continue::
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
    -- A lazy module has no isEnabled: reading it would require the module.
    if not _proxies[mod] and type(mod.isEnabled) == "function" then
        return mod.isEnabled(pfx)
    end
    if mod.enabled_key then
        local v = SUISettings:readSetting(pfx .. mod.enabled_key)
        if v == nil then return mod.default_on ~= false end
        return v == true
    end
    return mod.default_on ~= false
end

-- Number of recent books the enabled modules need prefetched into
-- ctx.recent_fps: the largest M.needs.recent among them, 0 when none asks.
-- M.needs.recent is a count or a function(pfx) -> count.
function Registry.getRecentDemand(pfx)
    local demand = 0
    for _, mod in ipairs(Registry.list()) do
        local need = Registry.isEnabled(mod, pfx) and mod.needs and mod.needs.recent
        if need then
            if type(need) == "function" then need = need(pfx) end
            demand = math.max(demand, need)
        end
    end
    return demand
end

-- True when a module enabled under `pfx` needs the data kind `need` (see
-- M.needs): the entry is true, or a function(pfx) that returns true.
function Registry.wantsData(pfx, need)
    for _, mod in ipairs(Registry.list()) do
        local n = Registry.isEnabled(mod, pfx) and mod.needs and mod.needs[need]
        if n then
            if type(n) == "function" then n = n(pfx) end
            if n then return true end
        end
    end
    return false
end

-- Requires the lazy modules enabled under any of the prefixes in `pfxs`, so
-- the first render of their screens does not pay for loading them.
function Registry.preloadEnabled(pfxs)
    for _, mod in ipairs(Registry.list()) do
        if _proxies[mod] then
            for _i, pfx in ipairs(pfxs) do
                if Registry.isEnabled(mod, pfx) then _resolve(mod); break end
            end
        end
    end
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
    _bases_cache   = nil
    _loaded        = nil
    _by_id         = nil
    _default_order = nil
    _instanciable  = {}
end

-- ---------------------------------------------------------------------------
-- Registry.createInstance(base_id) → instance_id | nil
--
-- Creates a new instance of an instanciable module, persists its id in
-- the base's instances list, registers it in _loaded/_by_id, and returns
-- the new instance id (e.g. "quick_actions_row_a1b2c3").
-- Returns nil if the base module is not instanciable or not found. A base with
-- M.bare_instance returns its own id while that instance sits on no surface.
-- ---------------------------------------------------------------------------
function Registry.createInstance(base_id)
    _load()
    local base = _instanciable[base_id or "quick_actions_row"]
    if not base then return nil end
    if base.bare_instance and not _placedInstanceIds()[base.id] then
        return base.id
    end
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
    local inst_key = _instancesKey(base)
    local ids = SUISettings:readSetting(inst_key) or {}
    ids[#ids + 1] = inst_id
    SUISettings:set(inst_key, ids)
    return inst_id
end

-- ---------------------------------------------------------------------------
-- Registry.destroyInstance(inst_id)
--
-- Removes an instanciable module instance from the registry and from the
-- persisted instance list; a bare instance (M.bare_instance) is left alone.
-- Does NOT remove the module's own settings keys
-- (items, shape, bg, etc.) — callers that want a clean slate should call
-- Registry.purgeInstanceSettings(inst_id) first or after.
-- ---------------------------------------------------------------------------
function Registry.destroyInstance(inst_id)
    if not inst_id then return end
    local base = _baseOf(inst_id)
    if base and _isBareInstance(base, inst_id) then return end
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
        local key = _instancesKey(base)
        if _remove_from_key(key) then removed = true; break end
    end
    if not removed then
        _remove_from_key(DEFAULT_INSTANCES_KEY)
    end
end

-- ---------------------------------------------------------------------------
-- Registry.purgeInstanceSettings(inst_id, pfx)
--
-- Removes all settings keys that belong to this instance: enabled, shape,
-- bg, items, labels, scale, gap, label_scale, bento_width (under both pfx
-- and pfx_qa). Does not touch global keys (hide_label / label_outside).
-- Safe to call even if the instance no longer exists in the registry.
-- ---------------------------------------------------------------------------
function Registry.purgeInstanceSettings(inst_id, pfx)
    pfx = pfx or "simpleui_hs_"
    local qa_pfx = "simpleui_hs_qa_"
    -- NOTE: "_scale" and "_item_label_scale" are the real suffixes saved by
    -- sui_config.lua (_modKey / _itemLabelKey) — the old
    -- "_scale_pct" / "_item_label_scale_pct" entries in this list never matched
    -- any saved key (pre-existing bug, fixed here).
    local suffixes = { "_enabled", "_shape", "_bg", "_items", "_labels",
                       "_scale", "_gap_pct", "_item_label_scale",
                       -- used by Featured Collection / sui_book_grid.lua:
                       "_coll_name", "_sort_state", "_thumb_scale",
                       "_show_progress", "_show_text", "_show_overlay",
                       "_show_frame", "_tone", "_solid_bg", "_backdrop",
                       "_grid_rows", "_grid_cols" }
    local base = _baseOf(inst_id)
    if base and base.setting_suffixes then
        for _, s in ipairs(base.setting_suffixes) do suffixes[#suffixes + 1] = s end
    end
    for _, s in ipairs(suffixes) do
        SUISettings:set(pfx    .. inst_id .. s, nil)
        SUISettings:set(qa_pfx .. inst_id .. s, nil)
    end
    -- Per-element text styles (font, size, variant) of the instance.
    local Config = require("infra/sui_config")
    local elems = { "label" }
    local inst = _by_id[inst_id]
    if inst and type(inst.text_elems) == "table" and #inst.text_elems > 0 then
        elems = inst.text_elems
    elseif base and type(base.text_elems) == "table" and #base.text_elems > 0 then
        elems = base.text_elems
    end
    Config.resetTextStyles(inst_id, elems, pfx)
    Config.resetTextStyles(inst_id, elems, qa_pfx)
    -- Also the bare keys used by build/getHeight.
    SUISettings:set(qa_pfx .. inst_id .. "_items",  nil)
    SUISettings:set(qa_pfx .. inst_id .. "_labels", nil)
    -- Column width (bento grid): key is pfx .. "bento_width_" .. id (sui_config).
    SUISettings:set(pfx    .. "bento_width_" .. inst_id, nil)
    SUISettings:set(qa_pfx .. "bento_width_" .. inst_id, nil)
    -- simpleui_hide_label_* / simpleui_label_outside_* are global (no pfx),
    -- not per-screen; leave them for the module/instance lifetime elsewhere.
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
