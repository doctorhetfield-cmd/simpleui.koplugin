-- folio_history.lua — Folio
-- Reading History screen (Mockup 3): month overview + milestones + load more.

local CenterContainer     = require("ui/widget/container/centercontainer")
local Device              = require("device")
local FrameContainer      = require("ui/widget/container/framecontainer")
local Geom                = require("ui/geometry")
local GestureRange        = require("ui/gesturerange")
local HorizontalGroup     = require("ui/widget/horizontalgroup")
local HorizontalSpan      = require("ui/widget/horizontalspan")
local IconButton          = require("ui/widget/iconbutton")
local InputContainer      = require("ui/widget/container/inputcontainer")
local LeftContainer       = require("ui/widget/container/leftcontainer")
local LineWidget          = require("ui/widget/linewidget")
local OverlapGroup        = require("ui/widget/overlapgroup")
local RightContainer      = require("ui/widget/container/rightcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextWidget          = require("ui/widget/textwidget")
local TitleBar            = require("ui/widget/titlebar")
local UIManager           = require("ui/uimanager")
local VerticalGroup       = require("ui/widget/verticalgroup")
local VerticalSpan        = require("ui/widget/verticalspan")
local Screen              = Device.screen
local logger              = require("logger")
local gettext             = require("gettext")

local Config   = require("folio_config")
local FolioTheme = require("folio_theme")
local Theme    = FolioTheme.Theme
local UI       = require("folio_core")

local M = {}

-- ---------------------------------------------------------------------------
-- Time / summary helpers (DocSettings summary.modified formats)
-- ---------------------------------------------------------------------------

local function parseModifiedToUnix(mod)
    if mod == nil then return nil end
    if type(mod) == "number" then return mod end
    if type(mod) == "string" then
        if #mod >= 10 then
            local y = tonumber(mod:sub(1, 4))
            local mo = tonumber(mod:sub(6, 7))
            local d = tonumber(mod:sub(9, 10))
            if y and mo and d then
                return os.time({ year = y, month = mo, day = d, hour = 12, min = 0, sec = 0 })
            end
        end
    end
    if type(mod) == "table" and mod.year then
        return os.time({
            year  = mod.year,
            month = mod.month or 1,
            day   = mod.day or 1,
            hour  = mod.hour or 12,
            min   = mod.min or 0,
            sec   = mod.sec or 0,
        })
    end
    return nil
end

local function annotationTimestamp(ann)
    local d = ann.datetime_updated or ann.datetime
    if type(d) == "number" then return d end
    if type(d) == "string" and #d >= 19 then
        local y = tonumber(d:sub(1, 4))
        local mo = tonumber(d:sub(6, 7))
        local day = tonumber(d:sub(9, 10))
        local H = tonumber(d:sub(12, 13)) or 0
        local Mi = tonumber(d:sub(15, 16)) or 0
        local S = tonumber(d:sub(18, 19)) or 0
        if y and mo and day then
            return os.time({ year = y, month = mo, day = day, hour = H, min = Mi, sec = S })
        end
    end
    return nil
end

local function maxAnnotationTime(annotations)
    local max_t = 0
    for _, ann in ipairs(annotations) do
        local t = annotationTimestamp(ann) or 0
        if t > max_t then max_t = t end
    end
    return max_t > 0 and max_t or nil
end

-- ---------------------------------------------------------------------------
-- Data: month overview + merged milestones
-- ---------------------------------------------------------------------------

local function monthRangeUnix()
    local t = os.date("*t")
    local month_start = os.time({ year = t.year, month = t.month, day = 1, hour = 0, min = 0, sec = 0 })
    local now = os.time()
    return month_start, now, t
end

local function monthOverviewFromDB(month_start, now)
    local total_secs = 0
    local conn = Config.openStatsDB()
    if not conn then return 0 end
    local ok, err = pcall(function()
        local q = string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d AND start_time <= %d
                GROUP BY id_book, page
            );]], month_start, now)
        total_secs = tonumber(conn:rowexec(q)) or 0
    end)
    if not ok then logger.warn("folio_history: month DB:", tostring(err)) end
    pcall(function() conn:close() end)
    return total_secs
end

---@return table[] milestones { ts, kind, file, title, authors, line_main, sub_line, icon }
local function gatherMilestones()
    local out = {}
    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return out end
    pcall(function() ReadHistory:reload() end)
    local hist = ReadHistory.hist or {}

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return out end

    local lfs = require("libs/libkoreader-lfs")

    -- 1) Finished books (summary.status == complete)
    for _, entry in ipairs(hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local ok_o, ds = pcall(function() return DocSettings:open(fp) end)
            if ok_o and ds then
                local summary = ds:readSetting("summary")
                local doc_props = ds:readSetting("doc_props") or {}
                pcall(function() ds:close() end)
                if type(summary) == "table" and summary.status == "complete" then
                    local ts = parseModifiedToUnix(summary.modified) or entry.time
                    local title = doc_props.title or entry.text or fp:gsub(".*/", "")
                    local authors = doc_props.authors or ""
                    local line
                    if authors ~= "" then
                        line = string.format(gettext("Finished %s by %s"), title, authors)
                    else
                        line = string.format(gettext("Finished %s"), title)
                    end
                    out[#out + 1] = {
                        ts      = ts,
                        kind    = "finished",
                        file    = fp,
                        title   = title,
                        authors = authors,
                        line_main = line,
                        title_only = title,
                        authors_only = authors,
                        sub_line = nil, -- filled when building row with format
                        icon    = "book",
                    }
                end
            end
        end
    end

    -- 2) Reading sessions (page_stat duration > 600s)
    local conn = Config.openStatsDB()
    if conn then
        local ok_sql, err = pcall(function()
            local stmt = conn:prepare([[
                SELECT page_stat.start_time, page_stat.duration, book.title, book.authors
                FROM page_stat
                JOIN book ON book.id = page_stat.id_book
                WHERE page_stat.duration > 600
                ORDER BY page_stat.start_time DESC
                LIMIT 400;
            ]])
            if stmt then
                while true do
                    local row = stmt:step()
                    if not row then break end
                    local st = tonumber(row[1])
                    local dur = tonumber(row[2])
                    local btitle = row[3] or "?"
                    local authors = row[4] or ""
                    if st and dur then
                        local end_ts = st + dur
                        out[#out + 1] = {
                            ts        = end_ts,
                            kind      = "session",
                            file      = nil,
                            title     = btitle,
                            authors   = authors,
                            line_main = string.format(gettext("Reading session — %s"), btitle),
                            start_t   = st,
                            duration  = dur,
                            sub_line  = nil,
                            icon      = "timer",
                        }
                    end
                end
                stmt:reset()
            end
        end)
        if not ok_sql then logger.warn("folio_history: page_stat:", tostring(err)) end
        pcall(function() conn:close() end)
    end

    -- 3) Highlights (annotations count > 0)
    local nscan = 0
    for _, entry in ipairs(hist) do
        if nscan >= 200 then break end
        nscan = nscan + 1
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local ok_o, ds = pcall(function() return DocSettings:open(fp) end)
            if ok_o and ds then
                local annotations = ds:readSetting("annotations") or {}
                local doc_props = ds:readSetting("doc_props") or {}
                pcall(function() ds:close() end)
                if #annotations > 0 then
                    local ts = maxAnnotationTime(annotations) or entry.time
                    local title = doc_props.title or entry.text or fp:gsub(".*/", "")
                    out[#out + 1] = {
                        ts       = ts,
                        kind     = "highlight",
                        file     = fp,
                        title    = title,
                        authors  = doc_props.authors or "",
                        line_main = string.format(gettext("Highlights in %s"), title),
                        sub_line = nil,
                        icon     = "highlight",
                    }
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.ts > b.ts end)
    return out
end

local function countBooksCompletedThisMonth()
    local month_start, now = monthRangeUnix()
    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory or not ReadHistory.hist then return 0 end
    local DocSettings = require("docsettings")
    local lfs = require("libs/libkoreader-lfs")
    local n = 0
    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local ok_o, ds = pcall(function() return DocSettings:open(fp) end)
            if ok_o and ds then
                local summary = ds:readSetting("summary")
                pcall(function() ds:close() end)
                if type(summary) == "table" and summary.status == "complete" then
                    local ts = parseModifiedToUnix(summary.modified) or entry.time
                    if ts and ts >= month_start and ts <= now then
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- UI widget
-- ---------------------------------------------------------------------------

local HistoryScreenWidget = InputContainer:extend{
    name              = "history",
    covers_fullscreen = true,
    _plugin           = nil,
    _fmhist           = nil,
    _milestone_list   = nil,
    _visible_count    = 10,
}

function HistoryScreenWidget:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self._visible_count = 10

    local Bottombar = require("folio_bottombar")
    local function _in_bar(ges)
        if not ges or not ges.pos then return false end
        return ges.pos.y >= Screen:getHeight() - Bottombar.TOTAL_H()
    end
    self.ges_events = {
        BlockNavbarTap = {
            GestureRange:new{ ges = "tap", range = function() return self.dimen end },
        },
        BlockNavbarHold = {
            GestureRange:new{ ges = "hold", range = function() return self.dimen end },
        },
    }
    function self:onBlockNavbarTap(_a, ges) if _in_bar(ges) then return true end end
    function self:onBlockNavbarHold(_a, ges) if _in_bar(ges) then return true end end

    self.title_bar = TitleBar:new{
        show_parent             = self,
        fullscreen              = true,
        title                   = gettext("Reading History"),
    }

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.BG,
        dimen = Geom:new{ w = sw, h = sh },
        VerticalSpan:new{ width = sh },
    }
end

function HistoryScreenWidget:_buildTopRow(sw, header_h)
    local Topbar = require("folio_topbar")
    local info = Topbar.getTopbarInfo and Topbar.getTopbarInfo() or {}
    local face_title = FolioTheme.faceContent(FolioTheme.sizeTitleMd())
    local face_icon  = FolioTheme.faceUI(FolioTheme.sizeLabelSm())
    local pad        = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local side_pad   = FolioTheme.scaled(FolioTheme.Spacing.SM)

    local title_w = TextWidget:new{
        text    = gettext("Reading History"),
        face    = face_title,
        bold    = true,
        fgcolor = Theme.TEXT,
    }

    local left_inner = HorizontalGroup:new{
        title_w,
    }

    local right_bits = HorizontalGroup:new{}
    right_bits[#right_bits + 1] = IconButton:new{
        icon     = "appbar.settings",
        width    = header_h - pad,
        height   = header_h - pad,
        padding  = 0,
        callback = function()
            local m = self._plugin and self._plugin.ui and self._plugin.ui.menu
            if m and m.onTapShowMenu then return m:onTapShowMenu() end
        end,
        show_parent = self,
    }
    if info.wifi then
        right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
        right_bits[#right_bits + 1] = TextWidget:new{
            text = "\u{ECA8}", face = face_icon, fgcolor = Theme.TEXT,
        }
    end
    if info.battery then
        right_bits[#right_bits + 1] = HorizontalSpan:new{ width = pad }
        right_bits[#right_bits + 1] = TextWidget:new{
            text = (info.battery_sym or "") .. info.battery .. "%",
            face = face_icon, fgcolor = Theme.TEXT,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.SURFACE_TOP,
        width = sw, height = header_h,
        OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = header_h },
            LeftContainer:new{
                dimen = Geom:new{ w = sw, h = header_h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = side_pad },
                    left_inner,
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = sw, h = header_h },
                HorizontalGroup:new{ right_bits, HorizontalSpan:new{ width = side_pad } },
            },
        },
    }
end

local function faceNum48()
    return FolioTheme.faceContent(math.max(24, Screen:scaleBySize(48)))
end

local function faceNum22()
    return FolioTheme.faceContent(math.max(12, Screen:scaleBySize(22)))
end

function HistoryScreenWidget:_monthOverviewCard(sw, margin_h)
    local month_start, now, tt = monthRangeUnix()
    local month_secs = monthOverviewFromDB(month_start, now)
    local books_n = countBooksCompletedThisMonth()

    local h_num = math.floor(month_secs / 3600)
    local m_num = math.floor((month_secs % 3600) / 60)

    local face48 = faceNum48()
    local face22 = faceNum22()
    local face_lbl = FolioTheme.faceUI(FolioTheme.sizeMicro())

    local month_names = {
        gettext("January"), gettext("February"), gettext("March"), gettext("April"), gettext("May"), gettext("June"),
        gettext("July"), gettext("August"), gettext("September"), gettext("October"), gettext("November"), gettext("December"),
    }
    local month_name = month_names[tt.month] or ""
    local header_txt = string.format("%s %d %s", month_name:upper(), tt.year, gettext("OVERVIEW"))

    local inner_w = sw - 2 * margin_h

    local left_col = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = tostring(books_n), face = face48, bold = true, fgcolor = Theme.TEXT,
        },
        VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
        TextWidget:new{
            text = gettext("BOOKS COMPLETED"), face = face_lbl, fgcolor = Theme.TEXT_MUTED,
        },
    }

    local right_col = VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            TextWidget:new{ text = tostring(h_num), face = face48, fgcolor = Theme.TEXT },
            HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
            TextWidget:new{ text = "h", face = face22, fgcolor = Theme.TEXT },
            HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
            TextWidget:new{ text = tostring(m_num), face = face48, fgcolor = Theme.TEXT },
            HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
            TextWidget:new{ text = "m", face = face22, fgcolor = Theme.TEXT },
        },
        VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.XS) },
        TextWidget:new{
            text = gettext("TOTAL TIME INVESTED"), face = face_lbl, fgcolor = Theme.TEXT_MUTED,
        },
    }

    local sep = LineWidget:new{
        dimen = Geom:new{ w = 1, h = Screen:scaleBySize(96) },
        background = Theme.GHOST_LINE,
    }

    local card_inner = HorizontalGroup:new{
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w * 0.45, h = Screen:scaleBySize(120) },
            left_col,
        },
        HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) },
        CenterContainer:new{ dimen = Geom:new{ w = 1, h = 80 }, sep },
        HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w * 0.45, h = Screen:scaleBySize(120) },
            right_col,
        },
    }

    local card = FrameContainer:new{
        background = Theme.SURFACE_LOW,
        bordersize = 2,
        color      = Theme.PRIMARY,
        radius     = 0,
        margin     = 0,
        padding    = FolioTheme.scaled(FolioTheme.Spacing.MD),
        [1]        = CenterContainer:new{
            dimen = Geom:new{ w = inner_w - FolioTheme.scaled(FolioTheme.Spacing.MD) * 2, h = Screen:scaleBySize(130) },
            card_inner,
        },
    }

    return VerticalGroup:new{
        align = "left",
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = FolioTheme.scaled(18) },
            TextWidget:new{
                text = header_txt,
                face = face_lbl,
                fgcolor = Theme.TEXT_MUTED,
            },
        },
        VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) },
        FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            margin_left = margin_h, margin_right = margin_h,
            card,
        },
    }
end

function HistoryScreenWidget:_milestoneIconButton(kind)
    local icon = "cre"
    if kind == "finished" then icon = "appbar.book" end
    if kind == "session" then icon = "appbar.timer" end
    if kind == "highlight" then icon = "appbar.highlight" end
    local sz = Screen:scaleBySize(24)
    return IconButton:new{
        icon        = icon,
        width       = sz,
        height      = sz,
        padding     = 0,
        show_parent = self,
        callback    = function() end,
    }
end

function HistoryScreenWidget:_milestoneRows(inner_w)
    local list = self._milestone_list or {}
    local nshow = math.min(self._visible_count, #list)
    local face_date = FolioTheme.faceContent(math.max(12, Screen:scaleBySize(18)))
    local face_day  = FolioTheme.faceUI(FolioTheme.sizeMicro())
    local face_body = FolioTheme.faceContent(FolioTheme.sizeBody())
    local face_sub  = FolioTheme.faceUI(FolioTheme.sizeMicro())
    local pad_v     = FolioTheme.scaled(FolioTheme.Spacing.SM)
    local min_h     = math.max(Screen:scaleBySize(64), Screen:scaleBySize(52))

    local col = VerticalGroup:new{ align = "left" }
    for i = 1, nshow do
        local ms = list[i]
        local dstr = os.date("%b %d", ms.ts)
        local daystr = os.date("%A", ms.ts):upper()
        local sub = ms.sub_line
        if not sub then
            if ms.kind == "session" and ms.start_t and ms.duration then
                local end_t = ms.start_t + ms.duration
                sub = string.format(gettext("COMPLETED AT %s"), os.date("%I:%M %p", end_t))
            else
                sub = string.format(gettext("COMPLETED AT %s"), os.date("%I:%M %p", ms.ts))
            end
        end

        local left_w = Screen:scaleBySize(80)
        local right_w = inner_w - left_w - Screen:scaleBySize(32)

        local row_inner = HorizontalGroup:new{
            VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = dstr, face = face_date, bold = true, fgcolor = Theme.TEXT },
                TextWidget:new{ text = daystr, face = face_day, fgcolor = Theme.TEXT_MUTED },
            },
            HorizontalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) },
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text = ms.line_main,
                    face = face_body,
                    fgcolor = Theme.TEXT,
                    max_width = right_w,
                },
                VerticalSpan:new{ width = 4 },
                TextWidget:new{
                    text = sub,
                    face = face_sub,
                    fgcolor = Theme.TEXT_MUTED,
                    max_width = right_w,
                },
            },
            HorizontalSpan:new{ width = 4 },
            RightContainer:new{
                dimen = Geom:new{ w = Screen:scaleBySize(28), h = min_h },
                self:_milestoneIconButton(ms.kind),
            },
        }

        local row = FrameContainer:new{
            bordersize = 0, padding = 0, padding_top = pad_v, padding_bottom = pad_v,
            background = Theme.BG,
            [1] = LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = min_h },
                row_inner,
            },
        }
        col[#col + 1] = row
        if i < nshow then
            col[#col + 1] = LineWidget:new{
                dimen = Geom:new{ w = inner_w, h = 1 },
                background = Theme.GHOST_LINE,
            }
        end
    end
    return col
end

function HistoryScreenWidget:_loadMoreBarFixed(sw, margin_h)
    local w = sw - 2 * margin_h
    local h = Screen:scaleBySize(44)
    local dim = Geom:new{ w = w, h = h }
    local self_ref = self
    local C = InputContainer:new{
        dimen = dim,
        ges_events = {
            Tap = {
                GestureRange:new{ ges = "tap", range = function() return dim end },
            },
        },
    }
    C[1] = FrameContainer:new{
        width = w, height = h,
        bordersize = 0, radius = 0, background = Theme.PRIMARY,
        CenterContainer:new{
            dimen = dim,
            TextWidget:new{
                text = gettext("LOAD MORE HISTORY"),
                face = FolioTheme.faceUI(math.max(12, Screen:scaleBySize(16))),
                fgcolor = Theme.ON_PRIMARY,
            },
        },
    }
    function C:onTap()
        self_ref._visible_count = self_ref._visible_count + 10
        self_ref:refresh()
        return true
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = FolioTheme.scaled(FolioTheme.Spacing.MD),
        [1] = C,
    }
end

function HistoryScreenWidget:_buildScrollBody(sw, content_h, header_h)
    if not self._milestone_list then
        self._milestone_list = gatherMilestones()
    end
    local margin_h = FolioTheme.scaled(FolioTheme.Spacing.MD)
    local inner_w = sw - 2 * margin_h

    local scroll = VerticalGroup:new{ align = "left" }
    scroll[#scroll + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }
    scroll[#scroll + 1] = self:_monthOverviewCard(sw, margin_h)
    scroll[#scroll + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.MD) }

    local hdr_h = Screen:scaleBySize(28)
    local hdr = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = hdr_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = hdr_h },
            TextWidget:new{
                text = gettext("Recent Milestones"),
                face = FolioTheme.faceContent(FolioTheme.sizeTitleMd()),
                bold = true,
                fgcolor = Theme.TEXT,
            },
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = hdr_h },
            TextWidget:new{
                text = gettext("SORTED BY DATE"),
                face = FolioTheme.faceUI(FolioTheme.sizeMicro()),
                fgcolor = Theme.TEXT_MUTED,
            },
        },
    }
    scroll[#scroll + 1] = FrameContainer:new{
        bordersize = 0,
        padding_left = margin_h,
        padding_right = margin_h,
        [1] = hdr,
    }
    scroll[#scroll + 1] = VerticalSpan:new{ width = FolioTheme.scaled(FolioTheme.Spacing.SM) }
    scroll[#scroll + 1] = FrameContainer:new{
        bordersize = 0,
        padding_left = margin_h,
        padding_right = margin_h,
        [1] = self:_milestoneRows(inner_w),
    }

    if #(self._milestone_list or {}) > self._visible_count then
        scroll[#scroll + 1] = self:_loadMoreBarFixed(sw, margin_h)
    end

    local scroll_h = math.max(0, content_h - header_h)
    local scroll_body = FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.BG,
        [1] = scroll,
    }
    local sc = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = scroll_h },
        scroll_body,
    }
    self.cropping_widget = sc
    return FrameContainer:new{
        bordersize = 0, padding = 0, background = Theme.BG,
        dimen = Geom:new{ w = sw, h = content_h },
        VerticalGroup:new{
            align = "left",
            self:_buildTopRow(sw, header_h),
            sc,
        },
    }
end

function HistoryScreenWidget:_buildMainContent()
    local content_h = self._navbar_content_h or UI.getContentHeight()
    local sw = Screen:getWidth()
    local header_h = Screen:scaleBySize(48)
    return self:_buildScrollBody(sw, content_h, header_h)
end

function HistoryScreenWidget:refresh()
    if not self._navbar_container then return end
    local old = self._navbar_container[1]
    local new = self:_buildMainContent()
    if old and old.overlap_offset then new.overlap_offset = old.overlap_offset end
    self._navbar_container[1] = new
    UIManager:setDirty(self, "ui")
end

function HistoryScreenWidget:onShow()
    self._milestone_list = nil
    self._visible_count = 10
    self._milestone_list = gatherMilestones()
    if self._navbar_container then
        local old = self._navbar_container[1]
        local new = self:_buildMainContent()
        if old and old.overlap_offset then new.overlap_offset = old.overlap_offset end
        self._navbar_container[1] = new
    end
    UIManager:setDirty(self, "ui")
end

function HistoryScreenWidget:onCloseWidget()
    self._plugin = nil
    self._fmhist = nil
    self._milestone_list = nil
end

function M.show(plugin, fmhist)
    if not (plugin and fmhist) then return false end
    local w = HistoryScreenWidget:new{
        _plugin = plugin,
        _fmhist = fmhist,
    }
    UIManager:show(w)
    return true
end

return M
