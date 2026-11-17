-- sui_toast.lua — Simple UI
-- Short notice drawn as a rounded card, centred on the screen: the text wraps
-- and the card is only as wide as its text needs, up to a share of the screen.
--
--   UIManager:show(Toast:new{
--       text    = "Message",   -- may hold line breaks
--       timeout = 3,           -- seconds until it closes itself (optional)
--       dismiss_callback = fn, -- optional; runs when a tap, a key or the
--                              -- timeout closes it, not when code closes it
--   })
--
-- A tap or any key closes the notice; the event is consumed. Closing and
-- showing refresh only the area of the card.
--
-- toast:setText(text) replaces the text of a notice on screen in place; only
-- the area of the card (old and new) is refreshed.
--
-- `timeout` stays a plain number on the widget and the widget has no buttons
-- or inputs, so a notice can be told apart from an interactive dialog.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local RoundedFrame    = require("infra/sui_backdrop").RoundedFrame
local SUIStyle        = require("features/sui_style")

local Screen = Device.screen

local COLOR = SUIStyle.COLOR

-- Metrics in base pixels, scaled when a card is built.
local METRICS = {
    pad_h  = 16,
    pad_v  = 12,
    radius = 12,
}

-- Widest card, as a fraction of the shorter screen side.
local MAX_WIDTH_RATIO = 5 / 6

local Toast = InputContainer:extend{
    text    = "",
    timeout = nil,
    dismiss_callback = nil,
}

-- Width of the widest line of `text` in `face`, in pixels.
local function widestLine(text, face)
    local widest = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local label = TextWidget:new{ text = line, face = face, padding = 0 }
        widest = math.max(widest, label:getWidth())
        label:free()
    end
    return widest
end

-- The card holding `text`.
local function buildCard(text)
    local face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local pad_h = Screen:scaleBySize(METRICS.pad_h)
    local pad_v = Screen:scaleBySize(METRICS.pad_v)

    local max_text_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * MAX_WIDTH_RATIO)
                       - 2 * (pad_h + SUIStyle.BORDER_SZ)
    local text_w = math.max(1, math.min(widestLine(text, face), max_text_w))

    return RoundedFrame:new{
        bordersize     = SUIStyle.BORDER_SZ,
        color          = COLOR.gray,
        background     = COLOR.surface,
        radius         = Screen:scaleBySize(METRICS.radius),
        padding        = 0,
        padding_left   = pad_h,
        padding_right  = pad_h,
        padding_top    = pad_v,
        padding_bottom = pad_v,
        TextBoxWidget:new{
            text      = text,
            face      = face,
            fgcolor   = COLOR.text_primary,
            width     = text_w,
            alignment = "center",
        },
    }
end

function Toast:init()
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges   = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    self.card = buildCard(self.text)
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.card,
    }
end

function Toast:onShow()
    UIManager:setDirty(self, function() return "ui", self.card.dimen end)
    if self.timeout then
        self._timeout_func = function()
            self._timeout_func = nil
            self:dismiss()
        end
        UIManager:scheduleIn(self.timeout, self._timeout_func)
    end
    return true
end

function Toast:onCloseWidget()
    if self._timeout_func then
        UIManager:unschedule(self._timeout_func)
        self._timeout_func = nil
    end
    local area = self.card.dimen
    if area then
        UIManager:setDirty(nil, function() return "ui", area end)
    end
end

function Toast:setText(text)
    local old = self.card
    local old_area = old.dimen
    self.text = text
    self.card = buildCard(text)
    self[1][1] = self.card
    old:free()
    if not old_area then return end
    local size = self.card:getSize()
    -- A card of the same size covers the old one: only the notice is redrawn.
    -- Otherwise the windows below are redrawn too, under the old card.
    local resized = size.w ~= old_area.w or size.h ~= old_area.h
    UIManager:setDirty(resized and "all" or self, function()
        return "ui", resized and old_area:combine(self.card.dimen) or self.card.dimen
    end)
end

-- Closes the notice as its reader dismissing it.
function Toast:dismiss()
    UIManager:close(self)
    if self.dismiss_callback then self.dismiss_callback() end
end

function Toast:onTapClose()
    self:dismiss()
    return true
end

Toast.onAnyKeyPressed = Toast.onTapClose

return Toast
