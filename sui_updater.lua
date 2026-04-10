-- sui_updater.lua — Simple UI OTA Updater
-- Manual check only: verifica no GitHub Releases se há uma versão mais recente,
-- informa o utilizador e pergunta se quer descarregar e instalar.
--
-- Melhorias v2:
--   1. socketutil com timeouts corretos (evita bloqueios em redes instáveis)
--   2. ltn12.sink.file no download (stream direto para disco, sem carregar ZIP em RAM)
--   3. json.decode em vez de regex (parsing robusto da resposta da API)
--   4. Release notes mostradas antes de confirmar a atualização
--   5. Trapper:dismissableRunInSubprocess (UI não-bloqueante, cancelável)
--
-- Uso (em sui_menu.lua):
--   local Updater = require("sui_updater")
--   Updater.checkForUpdates()

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local logger      = require("logger")
local _           = require("gettext")

-- ---------------------------------------------------------------------------
-- Configuração — ajusta ao teu repositório
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "doctorhetfield-cmd"     -- ← o teu username GitHub
local GITHUB_REPO  = "simpleui.koplugin"      -- ← nome do repositório
local ASSET_NAME   = "simpleui.koplugin.zip"  -- ← nome do ficheiro no release

-- Tempo de validade do cache em segundos. 0 = desativa cache.
local CACHE_TTL    = 3600  -- 1 hora

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local M = {}

-- Diretório do plugin (resolvido a partir do caminho deste ficheiro).
local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/simpleui.koplugin"  -- fallback Kindle

local _API_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases/latest",
    GITHUB_OWNER, GITHUB_REPO
)

-- Ficheiro de cache: guarda o último resultado da API para evitar requests
-- repetidos durante a sessão (TTL definido em CACHE_TTL).
local function _cacheFile()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/simpleui_update_cache.json"
    end
    return "/tmp/simpleui_update_cache.json"
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _loadCache()
    if CACHE_TTL <= 0 then return nil end
    local path = _cacheFile()
    local fh = io.open(path, "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok_d, data = pcall(json.decode, raw)
    if not ok_d or type(data) ~= "table" then return nil end
    if (os.time() - (data.timestamp or 0)) > CACHE_TTL then return nil end
    return data.payload
end

local function _saveCache(payload)
    if CACHE_TTL <= 0 then return end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return end
    local ok_e, encoded = pcall(json.encode, { timestamp = os.time(), payload = payload })
    if not ok_e then return end
    local fh = io.open(_cacheFile(), "w")
    if fh then
        fh:write(encoded)
        fh:close()
    end
end

local function _clearCache()
    pcall(os.remove, _cacheFile())
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _currentVersion()
    local meta_path = _plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    local rok, rmeta = pcall(require, "_meta")
    return (rok and rmeta and rmeta.version) or "0.0.0"
end

-- Retorna true se a versão `a` for inferior a `b` (comparação semver simples).
local function _versionLessThan(a, b)
    local function parts(v)
        local t = {}
        for n in (v .. "."):gmatch("(%d+)%.") do t[#t + 1] = tonumber(n) end
        while #t < 3 do t[#t + 1] = 0 end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, 3 do
        if pa[i] < pb[i] then return true end
        if pa[i] > pb[i] then return false end
    end
    return false
end

-- Mostra uma mensagem temporária.
local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- HTTP com socketutil (melhoria 1 + 2)
-- ---------------------------------------------------------------------------

-- GET para memória (chamadas à API — payload pequeno).
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
        url      = url,
        method   = "GET",
        headers  = {
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

    if code == 200 then
        return table.concat(chunks)
    end
    return nil, string.format("HTTP %s", tostring(code))
end

-- GET para ficheiro — stream direto para disco sem carregar em RAM (melhoria 2).
local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then
        return nil, "Could not create file: " .. tostring(err_open)
    end

    -- Timeouts generosos para downloads de ficheiros grandes.
    if ok_su then
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local code, headers, status = socket.skip(1, http.request({
        url      = url,
        method   = "GET",
        headers  = { ["User-Agent"] = "KOReader-SimpleUI-Updater/2.0" },
        sink     = ltn12.sink.file(fh),  -- stream direto para disco
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end
    -- ltn12.sink.file fecha o fh automaticamente após o request.

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
-- JSON parsing (melhoria 3)
-- Usa json.decode nativo do KOReader. Fallback para regex se indisponível.
-- ---------------------------------------------------------------------------

local function _parseRelease(body)
    local ok_j, json = pcall(require, "json")

    if not ok_j then
        -- Fallback para regex se o módulo json não estiver disponível.
        logger.warn("simpleui updater: módulo json não disponível, usando regex fallback")
        local function jsonStr(key)
            return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
        end
        local tag = jsonStr("tag_name")
        if not tag then return nil, "could not parse tag_name" end
        local download_url = body:match(
            '"browser_download_url"%s*:%s*"([^"]*'
            .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        )
        local notes = body:match('"body"%s*:%s*"(.-)"[,}]')
        if notes then
            notes = notes:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
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

    -- Procura o asset ZIP pelo nome exato configurado em ASSET_NAME.
    local download_url = nil
    for _, asset in ipairs(data.assets or {}) do
        if type(asset.name) == "string" and asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end

    -- Sanitiza as release notes: remove markdown pesado e trunca para ecrã.
    local notes = data.body
    if notes and notes ~= "" then
        notes = notes:gsub("#+%s*", "")           -- remover headings markdown
        notes = notes:gsub("%*%*(.-)%*%*", "%1")  -- remover bold **
        notes = notes:gsub("`(.-)`", "%1")         -- remover code inline
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
    local cmd = string.format("unzip -o -q %q -d %q", zip_path, dest_dir)
    local ret = os.execute(cmd)
    if ret ~= 0 and ret ~= true then
        return nil, "unzip failed (exit " .. tostring(ret) .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Fase 2: download e instalação com Trapper (melhoria 5)
-- ---------------------------------------------------------------------------

local function _applyUpdate(download_url, new_version)
    local tmp_zip    = "/tmp/simpleui_update.zip"
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
            if stage == "download" then
                _toast(_("Download error: ") .. tostring(err))
            else
                _toast(_("Extraction error: ") .. tostring(err))
            end
            return
        end
        _clearCache()  -- invalida cache após instalação
        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("Simple UI %s successfully installed.\n\nRestart KOReader to apply the update?"),
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
        -- Fallback sem Trapper: corre na main thread.
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doDownloadAndInstall())
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Fase 1: verificação de versão com Trapper (melhoria 5)
-- ---------------------------------------------------------------------------

-- Mostra o diálogo de confirmação incluindo release notes (melhoria 4).
local function _showUpdateDialog(release, current)
    local latest       = release.version
    local download_url = release.download_url
    local notes        = release.notes

    if not _versionLessThan(current, latest) then
        logger.info("simpleui updater: já atualizado (" .. current .. ")")
        _toast(string.format(_("Simple UI is up to date (%s)."), current))
        return
    end

    logger.info("simpleui updater: nova versão disponível:", latest)

    -- Texto base com ou sem release notes (melhoria 4).
    local header = string.format(
        _("Simple UI %s is available!\nYou have %s."),
        latest, current
    )
    local footer = _("\n\nDownload and install now?")
    local notes_block = notes
        and ("\n\n" .. _("What's new:") .. "\n" .. notes)
        or  ""

    if not download_url then
        -- Sem asset ZIP — abrir GitHub.
        UIManager:show(ConfirmBox:new{
            text        = header .. notes_block
                       .. "\n\n" .. _("No automatic update file was found.\n\nOpen the releases page on GitHub?"),
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
        text        = header .. notes_block .. footer,
        ok_text     = _("Download and install"),
        cancel_text = _("Cancel"),
        ok_callback = function() _applyUpdate(download_url, latest) end,
    })
end

-- Lógica de fetch pura — corre dentro do subprocess.
local function _doFetch()
    local cached = _loadCache()
    if cached then
        logger.info("simpleui updater: usando cache")
        return cached
    end
    local body, err = _httpGet(_API_URL)
    if not body then return { error = err } end
    local release, parse_err = _parseRelease(body)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    _saveCache(release)
    return release
end

-- Ponto de entrada interno: mostra toast e corre verificação no subprocess.
function M._doCheckForUpdates(current)
    local checking_msg = _toast(_("Checking for updates…"), 15)
    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Error checking for updates."))
            return
        end
        if release.error then
            logger.err("simpleui updater: erro na verificação:", release.error)
            _toast(_("Error checking for updates: ") .. tostring(release.error))
            return
        end
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
        -- Fallback sem Trapper.
        UIManager:scheduleIn(0.3, function()
            handleCheckResult(_doFetch())
        end)
    end
end

-- Ponto de entrada público: garante rede ativa e inicia a verificação.
function M.checkForUpdates()
    local current = _currentVersion()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            M._doCheckForUpdates(current)
        end)
        return
    end
    M._doCheckForUpdates(current)
end

return M
