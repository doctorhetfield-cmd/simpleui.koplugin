-- sui_paths.lua — Simple UI
--
-- Depth-independent resolution of the plugin's install directory.
--
-- Every call site used to do this inline:
--   local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+/[^/]+$")
--
-- That regex just chops the last TWO path components off the source path,
-- which only gives the real plugin root when the calling file happens to
-- live exactly one folder below it (root/<file>.lua). It silently breaks
-- for any file that lives deeper, e.g. after the library refactor moved
-- sui_foldercovers.lua from root/ to features/library/: the regex resolved
-- to ".../simpleui.koplugin/features/" instead of ".../simpleui.koplugin/",
-- so every icon lookup under "<wrong-root>/icons/..." failed and the
-- fallback (blank/invisible icon) kicked in.
--
-- Fix: anchor on the literal "<name>.koplugin/" folder that KOReader
-- requires every plugin directory to be named, so resolution is correct
-- no matter how many levels deep the calling file lives.

local M = {}

local _cached_dir

-- Returns the plugin root directory, WITH a trailing "/".
-- `level` is the debug.getinfo stack level to inspect (default 2, i.e. the
-- direct caller of this function) — only matters for the source-path lookup
-- itself, not for the resolved result, so callers can just do:
--   local _PLUGIN_DIR = require("infra/sui_paths").getPluginDir()
function M.getPluginDir(level)
    if _cached_dir then return _cached_dir end

    local info = debug.getinfo(level or 2, "S")
    local src  = info and info.source or ""
    local path = (src:sub(1, 1) == "@") and src:sub(2) or src

    -- Primary: find the "*.koplugin/" segment anywhere in the path, no
    -- matter how many subfolders come after it.
    local dir = path:match("^(.-%.koplugin/)")

    -- Fallback for unusual embeddings (e.g. a symlinked/test harness path
    -- that doesn't literally contain ".koplugin/") — keeps old behaviour
    -- rather than crashing outright.
    if not dir then
        dir = path:match("^(.+/)[^/]+/[^/]+$") or "./"
    end

    _cached_dir = dir
    return dir
end

-- Evicts every module this plugin has loaded from package.loaded, so the
-- next require reads fresh code from disk. A loaded module belongs to the
-- plugin when a matching "<name>.lua" file exists under the plugin root.
function M.unloadModules()
    local lfs = require("libs/libkoreader-lfs")
    local dir = M.getPluginDir()
    for name in pairs(package.loaded) do
        if type(name) == "string" and lfs.attributes(dir .. name .. ".lua", "mode") == "file" then
            package.loaded[name] = nil
        end
    end
end

-- Same as getPluginDir() but WITHOUT the trailing "/" (used by call sites
-- that build paths as _plugin_dir .. "/_meta.lua" etc.).
function M.getPluginDirNoSlash()
    -- level 3 = the direct caller of getPluginDirNoSlash() (frame 1 is
    -- getPluginDir itself, frame 2 is this function, frame 3 is the caller).
    local dir = M.getPluginDir(3)
    return (dir:gsub("/$", ""))
end

return M
