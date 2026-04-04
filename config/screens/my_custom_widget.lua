local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

-- A simple native KOReader widget that will be wrapped by SimpleUI
local MyCustomWidget = InputContainer:extend{
    name = "my_custom_screen",
    covers_fullscreen = true,
    stop_events_propagation = true,
}

function MyCustomWidget:init()
    logger.dbg("SimpleUI: MyCustomWidget:init called")
    self[1] = FrameContainer:new{
        dimen = self.dimen:copy(),
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        bordersize = 0,
        CenterContainer:new{
            dimen = self.dimen:copy(),
            TextWidget:new{
                text = "Welcome to your Custom Screen!\n\nYou can build any UI here using\nnative KOReader widgets.",
                face = Font:getFace("cfont", 24),
                align = "center",
            }
        }
    }
end

function MyCustomWidget:onShow()
    -- Sync inner container dimensions when the widget is shown or re-wrapped
    if self[1] and self[1].dimen then
        local inner = self[1]
        if inner[1] and inner[1].dimen then
            inner[1].dimen = inner.dimen:copy()
        end
    end
end

function MyCustomWidget:_recalculateDimen()
    -- Ensure inner children match the newly injected height on rotation
    self:onShow()
end

function MyCustomWidget:onClose()
    logger.dbg("SimpleUI: MyCustomWidget:onClose called")
    local UIManager = require("ui/uimanager")
    UIManager:close(self)
end

return MyCustomWidget