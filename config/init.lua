-- SimpleUI User Configuration
-- Rename this file to init.lua to apply your customizations.
--
-- This file allows you to define custom tabs and actions that appear in the
-- SimpleUI bottom navigation bar.

return {
    -- Override the tabs displayed in the bottom bar.
    -- These are the IDs of the actions you want to appear, in order.
    -- Built-in options include: "home", "history", "collections", "favorites"
    -- You can also include IDs from your `custom_actions` below.
    tabs = { "home", "collections", "custom_opds", "my_custom_screen" },

    -- Define your own custom buttons and screens here
    custom_actions = {
        -- Example 1: A Quick Action (Action Only)
        -- This example simply runs a KOReader dispatcher action without changing the screen layout.
        {
            id = "custom_opds",
            label = "Catalog",
            -- You can provide an absolute path to a custom SVG icon, or a path relative to the plugin directory
            icon = "config/icons/app.svg",
            is_action_only = true,   -- Set to true if this button only triggers an action instead of opening a SimpleUI view
            is_in_place = false,     -- Set to false so SimpleUI closes the homescreen/menus before executing the action
            action = function(plugin, fm_self)
                local Dispatcher = require("dispatcher")
                
                -- Dispatch KOReader's official OPDS Catalog natively
                Dispatcher:execute({ opds_show_catalog = true })
            end
        },
        
        -- Example 2: A Custom Fullscreen Screen
        -- This example shows how to launch a completely custom widget wrapped with SimpleUI navbars.
        {
            id = "my_custom_screen",
            label = "Custom",
            icon = "config/icons/settings.svg",
            is_fullscreen_view = true, -- Set to true to automatically inject top/bottom navbars into your widget
            action = function(plugin, fm_self)
                local UIManager = require("ui/uimanager")
                local Screen = require("device").screen
                
                -- Load your custom widget module (This file must exist!)
                local MyCustomWidget = require("config/screens/my_custom_widget")
                
                local my_widget = MyCustomWidget:new{
                    dimen = require("ui/geometry"):new{
                        w = Screen:getWidth(), 
                        h = Screen:getHeight()
                    }
                }
                
                -- Note: Your widget must have its 'name' property set to match this action 'id' (e.g., "my_custom_screen")
                -- for SimpleUI to recognize it and attach the navigation bars!
                my_widget.name = "my_custom_screen"
                UIManager:show(my_widget)
            end
        }
    }
}
