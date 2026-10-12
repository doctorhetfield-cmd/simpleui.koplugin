-- sui_heatmap_popup.lua — Simple UI
-- Full-screen reading heatmap: the calendar grid and the day-part grid,
-- together, for a fixed-size block of weeks that can be paged back through
-- history. Opened by tapping the homescreen heatmap card
-- (modules/module_heatmap.lua) — this file has no homescreen ties of its
-- own, so it can be opened from anywhere (e.g. a future menu entry) too.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate

local Config   = require("infra/sui_config")
local UI       = require("infra/sui_core")
local SUIStyle = require("features/sui_style")
local HD       = require("engines/sui_heatmap_data")
local HW       = require("engines/sui_heatmap_widgets")

-- Fixed block size for the full-screen view — independent of the
-- homescreen card's own "weeks shown" setting, which is sized to fit a
-- much narrower column.
local WEEKS_PER_BLOCK = 26

local M = {}

local function fmtRange(start_t, end_t)
    return os.date("%d %b", start_t) .. " – " .. os.date("%d %b %Y", end_t)
end

--- Opens the heatmap popup. Reads fresh data on open and on every period
--- change — no ties to any homescreen ctx, so it always opens its own
--- short-lived DB connection (see sui_heatmap_data.lua).
--- opts: { on_back = function }
function M.show(opts)
    opts = opts or {}
    local SUIWindow = require("engines/sui_window")

    local blocks_back = 0
    local earliest_t  = HD.getEarliestStartTime()
    local is_12h      = G_reader_settings:isTrue("twelve_hour_clock")

    local function buildRoot(ctx)
        local inner_w = ctx.inner_w
        local fs       = ctx.SZ(SUIStyle.FS_CAPTION)
        local fonts    = { small = Font:getFace(SUIStyle.FACE_REGULAR, fs) }

        -- Section-label face — same FACE_REGULAR/FS_DETAIL/bold combination
        -- the reading-stats window uses for its "CALENDAR", "DAY STREAK",
        -- etc. headers, so "Time of day" reads as the same kind of label.
        local section_face = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_DETAIL))

        local start_t, end_t   = HD.getWeekBlockRange(WEEKS_PER_BLOCK, blocks_back)
        local daily_map, fatal1 = HD.getDailyReadingData(start_t, end_t)
        local wd_hour_map, fatal2 = HD.getWeekdayHourReadingData(start_t, end_t)

        local max_blocks_back = HD.maxBlocksBack(WEEKS_PER_BLOCK, earliest_t)
        local can_go_older = blocks_back < max_blocks_back
        local can_go_newer = blocks_back > 0

        local calendar_title = TextWidget:new{
            text    = _("CALENDAR"),
            face    = section_face,
            fgcolor = SUIStyle.COLOR.text_primary,
            bold    = true,
        }

        local header = SUIWindow.PeriodHeader{
            inner_w      = inner_w,
            label        = fmtRange(start_t, end_t),
            prev_enabled = can_go_older,
            next_enabled = can_go_newer,
            compact      = true,
            on_prev      = function()
                blocks_back = blocks_back + 1
                ctx.repaint()
            end,
            on_next      = function()
                blocks_back = blocks_back - 1
                ctx.repaint()
            end,
        }

        local range_widget = HW.buildRangeHeatmap(daily_map, start_t, end_t, fonts, inner_w)

        local day_part_title = TextWidget:new{
            text    = _("TIME OF DAY"),
            face    = section_face,
            fgcolor = SUIStyle.COLOR.text_primary,
            bold    = true,
        }
        local day_part_widget = HW.buildDayPartHeatmap(wd_hour_map, fonts, inner_w, is_12h)

        -- Shared shading scale for both grids above, so the legend sits at
        -- the bottom of the page rather than between them.
        local legend = HW.buildLegend(fonts)

        return {
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            calendar_title,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            header,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            range_widget,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(22)) },
            day_part_title,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(8)) },
            day_part_widget,
            VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(16)) },
            CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = legend:getSize().h }, legend },
        }
    end

    local win = SUIWindow:new{
        name          = "sui_win_heatmap",
        on_back       = opts.on_back,
        title         = _("Reading Heatmap"),
        height        = math.floor((select(2, UI.getPortraitDims())) * 23 / 30),
        position      = "bottom",
        navpager_mode = Config.isNavpagerEnabled(),
        screens       = { __root__ = buildRoot },
    }
    win:show()
end

return M
