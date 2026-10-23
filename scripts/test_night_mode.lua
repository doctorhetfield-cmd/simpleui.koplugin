-- Run from a disposable copy of a KOReader installation with this plugin in plugins/simpleui.koplugin:
-- SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./luajit plugins/simpleui.koplugin/scripts/test_night_mode.lua
io.stdout:setvbuf("line")
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("test-night-settings.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = "plugins/simpleui.koplugin/?.lua;" .. package.path
local QA = require("features/sui_quickactions")
local Config = require("infra/sui_config")
local Renderer = require("engines/sui_quickactions_render")
local Style = require("features/sui_style")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local WC = require("ui/widget/container/widgetcontainer")
local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
local Screen = Device.screen
assert(not Screen.night_mode, "test requires fresh day-mode settings")

local moon = QA.getEntry("night_mode").icon
Screen.night_mode = true
local sun = QA.getEntry("night_mode").icon
Screen.night_mode = false
assert(moon ~= sun, "FEATURE_GAP: light and night modes resolve the same asset")
assert(moon == Config.ICON.night and sun:match("/day.svg$"), "toggle target icons reversed")
local default_pixels = {}
for _, path in ipairs({moon, sun}) do
    local file = assert(io.open(path, "rb"))
    file:close()
    local iw = require("ui/widget/imagewidget"):new{file=path, width=48, height=48, is_icon=true}
    iw:_render()
    assert(iw._bb, "default icon did not render: " .. path)
    default_pixels[#default_pixels+1] = ffi.string(iw._bb.data, iw._bb.stride * iw._bb.h)
    iw:free()
end
assert(default_pixels[1] ~= default_pixels[2], "default icons render identically")

local function tap(id) QA.execute(id) end
-- The two cell configurations represent the Home Screen and Quick Settings;
-- the other builders are shared with Action List and the navigation bar.
local builders = {
    function()
        return Renderer.buildCell("night_mode", {
            icon_sz=48, frame_sz=64, shape="bare", on_tap_fn=tap,
        })
    end,
    function()
        return Renderer.buildCell("night_mode", {
            icon_sz=40, frame_sz=56, shape="round",
        })
    end,
    function()
        return Renderer.buildListRow("night_mode", {
            inner_w=200, row_h=64, show_icon=true, icon_sz=48,
            icon_gap=8, lbl_fs=16, on_tap_fn=tap,
            icon_opts={wrap_image_in_container=true},
        })
    end,
    function()
        return Renderer.buildTabCell("night_mode", false, {
            tab_w=100, bar_h=64, icon_sz=48, mode="icons",
            bar_style="bare", indic_h=0,
        })
    end,
}
local function pixels(widget)
    local bb = BB.new(240, 100, BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    widget:paintTo(bb, 0, 0)
    local result = ffi.string(bb.data, bb.stride * bb.h)
    bb:free()
    return result
end
local function assertCurrent(widgets)
    for i, widget in ipairs(widgets) do
        local expected = builders[i]()
        assert(pixels(widget) == pixels(expected), "LIVE_ICON_STALE: layout " .. i .. " differs from current mode")
        assert(pixels(widget) == pixels(widget), "repeated paint changed layout " .. i)
        expected:free()
    end
end
local function exercise(override)
    QA.setDefaultActionIcon("night_mode", override)
    local widgets = {}
    for i, build in ipairs(builders) do widgets[i] = build() end
    -- Deliver events to icons before the real device listener changes state.
    local root = WC:new{}
    for _, widget in ipairs(widgets) do root[#root+1] = widget end
    root[#root+1] = require("device/devicelistener"):new{}
    UIManager:show(root)
    local static = Renderer.buildIcon(QA.getEntry("frontlight"), 48, Style.COLOR.text_primary, nil, "frontlight")
    local static_pixels = pixels(static)
    local function check()
        assertCurrent(widgets)
        assert(pixels(static) == static_pixels, "unrelated action icon changed")
    end
    local day_pixels = pixels(widgets[1])
    check()
    for cycle=1,3 do
        widgets[1]:onTapQACell()
        assert(Screen.night_mode, "Night Mode action did not enable mode")
        assert(QA.getEntry("night_mode").icon == (override or sun), "night icon override lost")
        assert(QA.getEntry("night_mode").dim == false, "enabled icon dimmed")
        check()
        UIManager:broadcastEvent(Event:new("SetNightMode", true))
        check()
        widgets[1]:onTapQACell()
        assert(not Screen.night_mode, "Night Mode action did not disable mode")
        assert(QA.getEntry("night_mode").dim == true, "disabled icon not dimmed")
        check()
        assert(pixels(widgets[1]) == day_pixels, "return-to-day pixels changed")
        UIManager:broadcastEvent(Event:new("SetNightMode", true))
        assert(Screen.night_mode, "SetNightMode did not enable mode")
        check()
        UIManager:broadcastEvent(Event:new("SetNightMode", false))
        assert(not Screen.night_mode, "SetNightMode did not disable mode")
        assert(QA.getEntry("night_mode").icon == (override or moon), "day icon override lost")
        check()
    end
    UIManager:close(root)
    root:free()
    static:free()
end
exercise(nil)
exercise(Config.ICON.frontlight)
local png = BB.new(48, 48, BB.TYPE_BB8)
png:fill(BB.COLOR_WHITE)
png:paintRect(12, 12, 24, 24, BB.COLOR_BLACK)
png:writePNG("test-night-icon.png")
png:free()
exercise("test-night-icon.png")
exercise("nerd:f186")
QA.setDefaultActionIcon("night_mode", nil)
local lfs = require("libs/libkoreader-lfs")
lfs.mkdir("test-night-pack")
local f = assert(io.open(Config.ICON.frontlight, "rb"))
local svg = f:read("*a"); f:close()
f = assert(io.open("test-night-pack/sui_action_night_mode.svg", "wb"))
f:write(svg); f:close()
local result = assert(Style.applyPack("test-night-pack"))
assert(result.applied == 1 and result.errors == 0, "icon pack not applied")
exercise("test-night-pack/sui_action_night_mode.svg")
QA.setDefaultActionIcon("night_mode", nil)
os.remove("test-night-icon.png")
os.remove("test-night-pack/sui_action_night_mode.svg")
lfs.rmdir("test-night-pack")
print("PASS: dynamic defaults, native image rendering, live layouts, repeated action/SetNightMode events, SVG/PNG/Nerd Font and icon-pack overrides")
