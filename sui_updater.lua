-- sui_updater.lua — Simple UI OTA Updater
--
-- Two modes of operation:
--   1. Silent automatic check on startup (24 h throttle via G_reader_settings).
--      If an update is available, a banner appears at the top of the About menu.
--   2. Manual check triggered by the user ("Check for Updates" menu item).
--      Always hits the network, ignores the throttle.
--
-- Technical stack:
--   • socketutil with timeouts (avoids hangs on unstable networks)
--   • ltn12.sink.file for downloads (streams directly to disk, no ZIP in RAM)
--   • Native KOReader json.decode; regex fallback if unavailable
--   • Release notes shown before confirming install
--   • Trapper:dismissableRunInSubprocess (non-blocking UI, cancellable)
--   • State persisted in G_reader_settings (survives between sessions;
--     the "update available" banner appears immediately on next startup)

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")
local _           = require("sui_i18n").translate

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "doctorhetfield-cmd"
local GITHUB_REPO  = "simpleui.koplugin"
local ASSET_NAME   = "simpleui.koplugin.zip"

local AUTO_CHECK_INTERVAL = 24 * 3600  -- segundos entre checks automáticos

-- G_reader_settings keys — prefixed with "sui_upd_" to avoid collisions.
local GS_LAST_CHECK = "sui_upd_last_check"  -- number (timestamp)
local GS_HAS_UPDATE = "sui_upd_has_update"  -- boolean
local GS_LATEST_VER = "sui_upd_latest_ver"  -- string sem "v"
local GS_DL_URL     = "sui_upd_dl_url"      -- string URL

local _API_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases/latest",
    GITHUB_OWNER, GITHUB_REPO
)

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local M = {}

-- In-memory cache for the current session.
-- Initialised lazily by _load_persisted_state().
local _state_loaded = false
local _has_update   = false
local _latest_ver   = nil  -- string sem "v", ou nil
local _dl_url       = nil  -- URL para o ZIP do asset, ou nil

-- Plugin directory — resolved once at module load time.
local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/simpleui.koplugin"

-- ---------------------------------------------------------------------------
-- Helpers: version
-- ---------------------------------------------------------------------------

local function _currentVersion()
    -- Use dofile with the absolute path to guarantee we read *this* plugin's
    -- _meta.lua, not a stale cached entry from another plugin (require caches
    -- by module name, so require("_meta") may return the wrong table).
    local ok, meta = pcall(dofile, _plugin_dir .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then return meta.version end
    local rok, rmeta = pcall(require, "_meta")
    return (rok and rmeta and rmeta.version) or "0.0.0"
end

-- Returns true if version `a` is strictly greater than `b`.
-- Supports "v1.2.3", "1.2.3", "1.2.3-beta1" (suffixes are ignored).
local function _versionGt(a, b)
    local function parts(v)
        v = (v or ""):match("^v?(.-)[-+]") or (v or ""):match("^v?(.+)$") or ""
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) or 0 end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] > pb[i] then return true end
        if pa[i] < pb[i] then return false end
    end
    return false
end

local function _isValidAssetUrl(url)
    return type(url) == "string"
        and url:find("/releases/download/", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- G_reader_settings accessor — guarded for use outside KOReader (e.g. tests)
-- ---------------------------------------------------------------------------

local function _gs()
    local ok, gs = pcall(function() return G_reader_settings end)
    return ok and gs or nil
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function _load_persisted_state()
    if _state_loaded then return end
    _state_loaded = true

    local gs = _gs()
    if not gs then return end

    _has_update = gs:readSetting(GS_HAS_UPDATE) == true
    local ver   = gs:readSetting(GS_LATEST_VER)
    _latest_ver = (type(ver) == "string" and ver ~= "") and ver or nil
    local url   = gs:readSetting(GS_DL_URL)
    _dl_url     = _isValidAssetUrl(url) and url or nil

    -- Discard stale state (e.g. update already installed).
    if _has_update and not _versionGt(_latest_ver or "", _currentVersion()) then
        _has_update = false
        _latest_ver = nil
        _dl_url     = nil
        gs:saveSetting(GS_HAS_UPDATE, false)
        gs:saveSetting(GS_LATEST_VER, "")
        gs:saveSetting(GS_DL_URL,     "")
        pcall(gs.flush, gs)
    end
end

local function _persist_state(now)
    local gs = _gs()
    if not gs then return end
    if now then gs:saveSetting(GS_LAST_CHECK, now) end
    gs:saveSetting(GS_HAS_UPDATE, _has_update)
    gs:saveSetting(GS_LATEST_VER, _latest_ver or "")
    gs:saveSetting(GS_DL_URL,     _dl_url     or "")
    pcall(gs.flush, gs)
end

local function _clear_update_state()
    _has_update = false
    _latest_ver = nil
    _dl_url     = nil
    local gs = _gs()
    if not gs then return end
    gs:saveSetting(GS_HAS_UPDATE, false)
    gs:saveSetting(GS_LATEST_VER, "")
    gs:saveSetting(GS_DL_URL,     "")
    pcall(gs.flush, gs)
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local code, headers, status = socket.skip(1, http.request({
        url     = url,
        method  = "GET",
        headers = {
            ["User-Agent"] = "KOReader-SimpleUI-Updater/2.0",
            ["Accept"]     = "application/vnd.github.v3+json",
        },
        sink     = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return table.concat(chunks) end
    return nil, string.format("HTTP %s", tostring(code))
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then return nil, "cannot create file: " .. tostring(err_open) end

    if ok_su then
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local code, headers, status = socket.skip(1, http.request({
        url     = url,
        method  = "GET",
        headers = { ["User-Agent"] = "KOReader-SimpleUI-Updater/2.0" },
        sink    = ltn12.sink.file(fh),   -- stream direto para disco
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end
    -- ltn12.sink.file closes fh automatically.

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return true end
    pcall(os.remove, dest_path)
    return nil, string.format("HTTP %s", tostring(code))
end

-- ---------------------------------------------------------------------------
-- GitHub API response parsing
-- ---------------------------------------------------------------------------

local function _parseRelease(body)
    local ok_j, json = pcall(require, "json")

    if not ok_j then
        -- Regex fallback for KOReader builds that lack the json module.
        logger.warn("simpleui updater: módulo json indisponível, usando regex fallback")
        local function jsonStr(key)
            return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
        end
        local tag = jsonStr("tag_name")
        if not tag then return nil, "could not parse tag_name" end
        local asset_pat = '"browser_download_url"%s*:%s*"([^"]*'
            .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        local download_url = body:match(asset_pat)
        local notes = body:match('"body"%s*:%s*"(.-)"%s*[,}]')
        if notes then
            notes = notes:gsub("\\n", "\n"):gsub("\\r", "")
                        :gsub('\\"', '"'):gsub("\\\\", "\\")
        end
        return {
            version      = tag:match("v?(.*)"),
            download_url = download_url,
            notes        = (notes and notes ~= "") and notes or nil,
        }
    end

    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end

    local tag = data.tag_name
    if not tag then return nil, "tag_name missing from API response" end

    local download_url
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end

    local notes = data.body
    if notes and notes ~= "" then
        notes = notes:gsub("#+%s*", "")           -- headings markdown
        notes = notes:gsub("%*%*(.-)%*%*", "%1")  -- bold **
        notes = notes:gsub("`(.-)`", "%1")         -- code inline
        notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
        if #notes > 600 then notes = notes:sub(1, 597) .. "..." end
        notes = notes:match("^%s*(.-)%s*$")        -- trim
    end

    return {
        version      = tag:match("v?(.*)"),
        download_url = download_url,
        notes        = (notes and notes ~= "") and notes or nil,
        html_url     = data.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- Unzip
-- ---------------------------------------------------------------------------

local function _unzip(zip_path, dest_dir)
    local ret = os.execute(string.format("unzip -o -q %q -d %q", zip_path, dest_dir))
    if ret ~= 0 and ret ~= true then
        return nil, "unzip failed (exit " .. tostring(ret) .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Temporary path for the update ZIP
-- ---------------------------------------------------------------------------

local function _tmpZipPath()
    -- Candidate paths in preference order.
    -- Each is probed with "wb" (binary write) — the same mode used by the
    -- actual download — so a successful probe guarantees the download will
    -- also succeed.  Using "w" (text) for the probe masked failures on some
    -- devices where text-mode open succeeded but binary-mode open did not.
    local candidates = {}

    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        local dir = DS:getSettingsDir()
        if dir then candidates[#candidates + 1] = dir .. "/simpleui_update.zip" end
    end
    candidates[#candidates + 1] = "/tmp/simpleui_update.zip"
    candidates[#candidates + 1] = _plugin_dir .. "/simpleui_update.zip"

    for _, path in ipairs(candidates) do
        local fh = io.open(path, "wb")
        if fh then fh:close(); os.remove(path); return path end
    end

    -- Last-resort fallback: return the plugin dir path even without a
    -- successful probe (the download will fail with a clear error if it
    -- really is not writable, rather than returning nil here).
    return _plugin_dir .. "/simpleui_update.zip"
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- Pure fetch — intended to run inside a subprocess
-- ---------------------------------------------------------------------------

local function _doFetch()
    local body, err = _httpGet(_API_URL)
    if not body then return { error = err } end
    local release, parse_err = _parseRelease(body)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    return release
end

-- ---------------------------------------------------------------------------
-- Download and installation
-- ---------------------------------------------------------------------------

local function _applyUpdate(download_url, new_version)
    local tmp_zip    = _tmpZipPath()
    local parent_dir = _plugin_dir:match("^(.+)/[^/]+$") or _plugin_dir

    local progress_msg = _toast(
        string.format(_("Downloading Simple UI %s…"), new_version), 120
    )

    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doDownloadAndInstall()
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then
            return { success = false, stage = "download", err = dl_err }
        end
        local uz_ok, uz_err = _unzip(tmp_zip, parent_dir)
        os.remove(tmp_zip)
        if not uz_ok then
            return { success = false, stage = "unzip", err = uz_err }
        end
        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err   = result and result.err   or "unknown error"
            logger.err("simpleui updater: falha em", stage, "-", err)
            _toast(
                stage == "download"
                    and (_("Download error: ") .. tostring(err))
                    or  (_("Extraction error: ") .. tostring(err))
            )
            return
        end
        _clear_update_state()
        UIManager:show(ConfirmBox:new{
            text        = string.format(
                _("Simple UI %s installed.\n\nRestart KOReader to apply the update?"),
                new_version
            ),
            ok_text     = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doDownloadAndInstall,
            progress_msg,
            function(res) handleInstallResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            pcall(os.remove, tmp_zip)
            _toast(_("Update cancelled."))
        end
    else
        -- Synchronous fallback (no Trapper): avoids blocking the UI via scheduleIn.
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doDownloadAndInstall())
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Confirmation dialog with release notes
-- ---------------------------------------------------------------------------

local function _showUpdateDialog(release, current)
    local latest       = release.version
    local download_url = release.download_url
    local notes        = release.notes

    if not _versionGt(latest, current) then
        logger.info("simpleui updater: já atualizado (" .. current .. ")")
        _toast(string.format(_("Simple UI is up to date (%s)."), current))
        return
    end

    logger.info("simpleui updater: nova versão disponível:", latest)

    local header     = string.format(_("Simple UI %s is available!\nYou have %s."), latest, current)
    local notes_block = notes and ("\n\n" .. _("What's new:") .. "\n" .. notes) or ""

    if not download_url then
        UIManager:show(ConfirmBox:new{
            text        = header .. notes_block
                       .. "\n\n" .. _("No download file found.\n\nOpen the releases page?"),
            ok_text     = _("Open in browser"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                local Device = require("device")
                if Device:canOpenLink() then
                    Device:openLink(string.format(
                        "https://github.com/%s/%s/releases/latest",
                        GITHUB_OWNER, GITHUB_REPO
                    ))
                end
            end,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text        = header .. notes_block .. "\n\n" .. _("Download and install now?"),
        ok_text     = _("Download and install"),
        cancel_text = _("Cancel"),
        ok_callback = function() _applyUpdate(download_url, latest) end,
    })
end

-- ---------------------------------------------------------------------------
-- Network check with result persistence
-- ---------------------------------------------------------------------------

local function _doNetworkCheck()
    local release = _doFetch()
    if release.error then
        logger.warn("simpleui updater: erro na verificação:", release.error)
        return false, release.error
    end

    local current = _currentVersion()
    _latest_ver   = release.version
    _dl_url       = _isValidAssetUrl(release.download_url) and release.download_url or nil
    _has_update   = _versionGt(_latest_ver, current)

    logger.info(string.format(
        "simpleui updater: current=%s latest=%s has_update=%s",
        current, _latest_ver or "?", tostring(_has_update)
    ))

    _persist_state(os.time())
    return true, release
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Returns true when a newer version has been detected.
--- Uses the in-memory cache (no I/O after the first call).
function M.hasUpdate()
    _load_persisted_state()
    return _has_update
end

--- Returns the latest detected version string (without "v" prefix), or nil.
function M.latestVersion()
    _load_persisted_state()
    return _latest_ver
end

--- Silent automatic check — called once on plugin startup.
---
--- • Always loads persisted state so hasUpdate() is correct immediately.
--- • Only hits the network if more than AUTO_CHECK_INTERVAL seconds have
---   elapsed since the last successful check.
--- • Never shows any UI — the result is written to G_reader_settings;
---   the banner is built by build_update_banner_item() when the menu opens.
function M.scheduleAutoCheck()
    _load_persisted_state()

    local gs   = _gs()
    local now  = os.time()
    local last = (gs and gs:readSetting(GS_LAST_CHECK)) or 0
    if type(last) ~= "number" then last = 0 end

    if (now - last) < AUTO_CHECK_INTERVAL then
        logger.dbg("simpleui updater: auto-check dentro do throttle — skip")
        return
    end

    -- Network call: runs 5 s after startup to avoid delaying the first paint.
    -- IMPORTANT: for the silent auto-check we must NEVER prompt the user to
    -- connect Wi-Fi. runWhenOnline calls beforeWifiAction when offline, which
    -- shows a dialog or turns Wi-Fi on automatically — both are unacceptable
    -- for a background check the user did not explicitly trigger.
    -- Instead: only proceed if the network is already online. If it is not,
    -- skip silently. The 24-hour throttle ensures we try again on the next
    -- startup where the device happens to be connected already.
    UIManager:scheduleIn(5, function()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        local already_online = ok_nm and NetworkMgr
            and (NetworkMgr.isOnline and NetworkMgr:isOnline()
                or (NetworkMgr.isConnected and NetworkMgr:isConnected()))
        if not already_online then
            logger.dbg("simpleui updater: auto-check skip — network not online")
            return
        end
        _doNetworkCheck()
    end)

end

--- Manual check — triggered by the "Check for Updates" menu item.
--- Always hits the network (ignores throttle) and shows UI with the result.
function M.checkForUpdates()
    local current = _currentVersion()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            M._doManualCheck(current)
        end)
        return
    end
    M._doManualCheck(current)
end

--- Internal logic for the manual check (kept separate to keep checkForUpdates
--- clean and to allow direct calls in tests).
function M._doManualCheck(current)
    local ok_tr, Trapper = pcall(require, "ui/trapper")
    local checking_msg   = _toast(_("Checking for updates…"), 15)

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Error checking for updates."))
            return
        end
        if release.error then
            logger.err("simpleui updater:", release.error)
            _toast(_("Error checking for updates: ") .. tostring(release.error))
            return
        end
        -- Persist the result so the next startup can show the banner
        -- without needing a network request.
        _latest_ver = release.version
        _dl_url     = _isValidAssetUrl(release.download_url) and release.download_url or nil
        _has_update = _versionGt(_latest_ver, current)
        _persist_state(os.time())

        _showUpdateDialog(release, current)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            _doFetch,
            checking_msg,
            function(res) handleCheckResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleCheckResult(result) end)
        elseif completed == false then
            _closeWidget(checking_msg)
            _toast(_("Update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleCheckResult(_doFetch())
        end)
    end
end

--- Returns a menu item when an update is available; nil otherwise.
--- Called when building the About menu — uses in-memory cache (zero I/O).
function M.build_update_banner_item()
    _load_persisted_state()
    if not _has_update then return nil end
    local label = _latest_ver and ("v" .. _latest_ver) or _("latest")
    return {
        text           = string.format(_("⬆ Update available: %s"), label),
        keep_menu_open = true,
        callback       = function()
            M.checkForUpdates()
        end,
    }
end

return M
