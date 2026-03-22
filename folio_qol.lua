-- folio_qol.lua — QoL: one-handed tap zones + first-launch reader status bar defaults
-- Tap zones follow KOReader's page_turns_* settings (see frontend/ui/elements/page_turns.lua).

local Device = require("device")
local util = require("util")

local M = {}

local KEY_MODE = "folio_one_handed_mode"
local KEY_BACKUP = "folio_one_handed_tap_backup"
local KEY_STATUSBAR   = "folio_statusbar_set"
local KEY_SCREENSAVER = "folio_screensaver_set"

local _orig_getTapZones

function M.getOneHandedMode()
    return G_reader_settings:readSetting(KEY_MODE) or "off"
end

local function backupTapZonesIfNeeded()
    if G_reader_settings:readSetting(KEY_BACKUP) then return end
    G_reader_settings:saveSetting(KEY_BACKUP, {
        page_turns_tap_zones = G_reader_settings:readSetting("page_turns_tap_zones") or "default",
        forward = G_reader_settings:readSetting("page_turns_tap_zone_forward_size_ratio"),
        backward = G_reader_settings:readSetting("page_turns_tap_zone_backward_size_ratio"),
    })
end

local function restoreTapZonesFromBackup()
    local b = G_reader_settings:readSetting(KEY_BACKUP)
    if b then
        G_reader_settings:saveSetting("page_turns_tap_zones", b.page_turns_tap_zones or "default")
        if b.forward ~= nil then
            G_reader_settings:saveSetting("page_turns_tap_zone_forward_size_ratio", b.forward)
        else
            G_reader_settings:delSetting("page_turns_tap_zone_forward_size_ratio")
        end
        if b.backward ~= nil then
            G_reader_settings:saveSetting("page_turns_tap_zone_backward_size_ratio", b.backward)
        else
            G_reader_settings:delSetting("page_turns_tap_zone_backward_size_ratio")
        end
        G_reader_settings:delSetting(KEY_BACKUP)
    else
        G_reader_settings:saveSetting("page_turns_tap_zones", "default")
        G_reader_settings:delSetting("page_turns_tap_zone_forward_size_ratio")
        G_reader_settings:delSetting("page_turns_tap_zone_backward_size_ratio")
    end
end

--- @param mode "off"|"right"|"left"
function M.applyOneHandedMode(mode)
    if mode == "off" then
        G_reader_settings:saveSetting(KEY_MODE, "off")
        restoreTapZonesFromBackup()
    else
        local prev = M.getOneHandedMode()
        if prev == "off" then
            backupTapZonesIfNeeded()
        end
        G_reader_settings:saveSetting(KEY_MODE, mode)
        G_reader_settings:saveSetting("page_turns_tap_zones", "left_right")
        G_reader_settings:saveSetting("page_turns_tap_zone_forward_size_ratio", 0.8)
        G_reader_settings:saveSetting("page_turns_tap_zone_backward_size_ratio", 0.2)
    end
    G_reader_settings:flush()
    M.refreshReaderTouchZones()
end

function M.refreshReaderTouchZones()
    local R = package.loaded["apps/reader/readerui"]
    if R and R.instance and R.instance.view then
        R.instance.view:setupTouchZones()
    end
end

function M.onReaderReady()
    M.refreshReaderTouchZones()
end

function M.patchReaderViewGetTapZones()
    local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if not ok or not ReaderView or ReaderView._folio_onehanded_patched then return end
    ReaderView._folio_onehanded_patched = true
    _orig_getTapZones = ReaderView.getTapZones
    ReaderView.getTapZones = function(self)
        local forward_zone, backward_zone = _orig_getTapZones(self)
        if G_reader_settings:readSetting(KEY_MODE) == "left" then
            forward_zone.ratio_x = 1 - forward_zone.ratio_x - forward_zone.ratio_w
            backward_zone.ratio_x = 1 - backward_zone.ratio_x - backward_zone.ratio_w
        end
        return forward_zone, backward_zone
    end
end

function M.unpatchReaderViewGetTapZones()
    local ReaderView = package.loaded["apps/reader/modules/readerview"]
    if ReaderView and _orig_getTapZones then
        ReaderView.getTapZones = _orig_getTapZones
        ReaderView._folio_onehanded_patched = nil
        _orig_getTapZones = nil
    end
end

function M.applySmartStatusBarFirstLaunch()
    if G_reader_settings:readSetting(KEY_STATUSBAR) then return end
    -- Do not replace a footer the user (or KOReader) already persisted.
    if G_reader_settings:readSetting("footer") ~= nil then
        G_reader_settings:saveSetting(KEY_STATUSBAR, true)
        G_reader_settings:flush()
        return
    end
    local ok_rf, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
    if not ok_rf or not ReaderFooter or not ReaderFooter.default_settings then return end
    local footer = util.tableDeepCopy(ReaderFooter.default_settings)
    footer.page_progress = false
    footer.pages_left_book = false
    footer.pages_left = false
    footer.percentage = false
    footer.book_time_to_read = false
    footer.bookmark_count = false
    footer.book_title = false
    footer.book_author = false
    footer.book_chapter = false
    footer.all_at_once = true
    footer.auto_refresh_time = true
    footer.chapter_progress = true
    footer.chapter_time_to_read = true
    footer.time = true
    footer.battery = Device:hasBattery() and true or false
    G_reader_settings:saveSetting("footer", footer)
    -- With all_at_once, text uses genAllFooterText; a non-off mode keeps the footer visible.
    G_reader_settings:saveSetting("reader_footer_mode", 1)
    G_reader_settings:saveSetting(KEY_STATUSBAR, true)
    G_reader_settings:flush()
end

--- First Folio launch: default sleep screen to current-book cover + title/% message.
--- Custom images: KOReader → Settings → Screen saver — use "Random image" and add PNG/JPG
--- under the koreader data directory screensaver folder (see KOReader wiki).
function M.applyScreensaverDefaultsFirstLaunch()
    if G_reader_settings:readSetting(KEY_SCREENSAVER) then return end
    G_reader_settings:saveSetting("screensaver_type", "cover")
    G_reader_settings:saveSetting("screensaver_show_message", true)
    G_reader_settings:saveSetting("screensaver_message", "%T\n%P% read")
    G_reader_settings:saveSetting(KEY_SCREENSAVER, true)
    G_reader_settings:flush()
end

return M
