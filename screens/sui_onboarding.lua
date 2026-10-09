-- sui_onboarding.lua — Simple UI
-- Onboarding window shown on first run.

local Device          = require("device")
local Geom            = require("ui/geometry")
local UIManager       = require("ui/uimanager")
local _               = require("infra/sui_i18n").translate
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local ImageWidget     = require("ui/widget/imagewidget")

local SUI         = require("engines/sui_window")
local SUIStyle    = require("features/sui_style")
local SUISettings = require("infra/sui_store")
local SUIPresets  = require("features/sui_presets")

-- Landscape-aware scaling for this file's screens comes from ctx.SZ(n),
-- handed to every screen builder by SUIWindow itself (single source of
-- truth, see sui_window.lua) — no local wrapper needed here anymore.
local Screen      = Device.screen

local Onboarding = {}

-- Returns true when the user has not yet configured a library home folder.
local function needsHomeFolderSetup()
    local home = G_reader_settings:readSetting("home_dir")
    return not home or home == ""
end

-- Primary storage root for path suggestions. Prefer the device home dir
-- reported by KOReader; fall back to known mount points per platform.
local function detectBaseStorage()
    if Device.home_dir and Device.home_dir ~= "" then
        return Device.home_dir
    end
    local base = "/"
    pcall(function()
        local Dev = require("device")
        if     Dev.isKobo       and Dev:isKobo()       then base = "/mnt/onboard"
        elseif Dev.isKindle     and Dev:isKindle()     then base = "/mnt/base-us"
        elseif Dev.isPocketBook and Dev:isPocketBook() then base = "/mnt/ext1"
        elseif Dev.isAndroid    and Dev:isAndroid()    then base = "/sdcard"
        end
    end)
    return base
end

-- Creates path and any missing parents. Returns true when path is a directory.
local function ensureDirectory(lfs, path)
    if not path or path == "" then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        if not ensureDirectory(lfs, parent) then return false end
    end
    pcall(lfs.mkdir, path)
    return lfs.attributes(path, "mode") == "directory"
end

-- Persists the chosen home folder, locks navigation to it, and invalidates
-- any cached library scan.
local function applyHomeDir(path)
    if not path or path == "" then return end
    G_reader_settings:saveSetting("home_dir", path)
    G_reader_settings:saveSetting("lock_home_folder", true)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
    local ok, LibraryScan = pcall(require, "engines/sui_library_scan")
    if ok and LibraryScan and LibraryScan.invalidate then
        LibraryScan.invalidate()
    end
end

-- Navigates the file manager to the current home folder when it differs.
local function navigateFileManagerToHome()
    local ok_scan, LibraryScan = pcall(require, "engines/sui_library_scan")
    local home = (ok_scan and LibraryScan and LibraryScan.resolveHomeDir and LibraryScan.resolveHomeDir())
        or G_reader_settings:readSetting("home_dir")
    if not home or home == "" then return end
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    if fm and fm.file_chooser and home ~= fm.file_chooser.path then
        fm.file_chooser:changeToPath(home)
    end
end

function Onboarding.show(on_finish)
    require("logger").info("simpleui[diag]: Onboarding.show called")
    local st = {
        selected_preset = SUISettings:get("simpleui_hs_active_preset") or "builtin_reading_nook"
    }

    local show_home = needsHomeFolderSetup()
    local base_storage = show_home and detectBaseStorage() or "/"
    local books_dir    = base_storage:gsub("/$", "") .. "/Books"

    local win

    -- ---------------------------------------------------------------------------
    -- Screen 1: Welcome header + subtitle only
    -- ---------------------------------------------------------------------------
    local function buildWelcomeHeader(ctx)
        local iw = ctx.inner_w
        local rows = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })
        table.insert(rows, FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = ctx.SZ(Screen:scaleBySize(20)), padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text    = _("Choose your initial layout"),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE)),
                    bold    = true,
                    fgcolor = SUIStyle.COLOR.text_primary,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                TextBoxWidget:new{
                    text      = _("Start with a ready-made layout. You can change everything later."),
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                    width     = iw - ctx.SZ(Screen:scaleBySize(40)),
                    alignment = "left",
                    fgcolor   = SUIStyle.COLOR.text_secondary,
                },
            },
        })

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen 2: Preset list
    -- ---------------------------------------------------------------------------
    local function buildPresetList(ctx)
        local iw = ctx.inner_w
        local rows = {}
        local builtins = SUIPresets.getBuiltinPresets and SUIPresets.getBuiltinPresets() or {}

        local preset_rows_args = { align = "left" }
        rows[#rows + 1] = VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(14)) }
        for i, bp in ipairs(builtins) do
            rows[#rows + 1] = SUI.ListRow{
                title     = bp.name,
                subtitle  = bp.desc,
                inner_w   = iw - ctx.SZ(Screen:scaleBySize(40)),
                radio     = true,
                checked   = (st.selected_preset == bp.id),
                separator = (i < #builtins),
                on_tap    = function()
                    st.selected_preset = bp.id
                    if SUIPresets.applyBuiltin then SUIPresets.applyBuiltin(st.selected_preset) end
                    SUISettings:set("simpleui_hs_active_preset", st.selected_preset)
                    local ok, HS = pcall(require, "screens/sui_homescreen")
                    if ok and HS and HS.rebuildLayout then HS.rebuildLayout() end
                    ctx.repaint()
                end,
            }
        end

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen: Home folder setup (only when home_dir is not yet configured)
    -- Single screen: title, subtitle, and radio choices.
    -- ---------------------------------------------------------------------------
    local function buildHomeFolder(ctx)
        local iw = ctx.inner_w
        local rows = {}
        local choices = {
            {
                id       = "books",
                title    = _("Create a \"Books\" folder"),
                subtitle = _("A folder named \"Books\" will be created and set as the library home."),
            },
            {
                id       = "choose",
                title    = _("Choose a different folder"),
                subtitle = _("Pick any existing folder to use as the library home."),
            },
        }

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })
        table.insert(rows, FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = ctx.SZ(Screen:scaleBySize(20)), padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text    = _("Set the Home Folder"),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE)),
                    bold    = true,
                    fgcolor = SUIStyle.COLOR.text_primary,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                TextBoxWidget:new{
                    text      = _("Choose the folder where you will place all your books. Simple UI uses it to show your books in the Library."),
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                    width     = iw - ctx.SZ(Screen:scaleBySize(40)),
                    alignment = "left",
                    fgcolor   = SUIStyle.COLOR.text_secondary,
                },
            },
        })

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(26)) })

        local choice_rows = { align = "left" }
        for i, c in ipairs(choices) do
            table.insert(choice_rows, SUI.ListRow{
                title     = c.title,
                subtitle  = c.subtitle,
                inner_w   = iw - ctx.SZ(Screen:scaleBySize(40)),
                radio     = true,
                checked   = (st.home_choice == c.id),
                separator = (i < #choices),
                on_tap    = function()
                    st.home_choice = c.id
                    ctx.repaint()
                end,
            })
        end
        table.insert(rows, FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = ctx.SZ(Screen:scaleBySize(20)),
            padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new(choice_rows),
        })

        return rows
    end

    -- Applies the selected home-folder option, then advances to the next screen.
    local function applyHomeChoiceAndContinue(ctx)
        local choice = st.home_choice
        if choice == "books" then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and ensureDirectory(lfs, books_dir) then
                applyHomeDir(books_dir)
            end
        elseif choice == "choose" then
            UIManager:scheduleIn(0.3, function()
                local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
                if not ok_pc then return end
                UIManager:show(PathChooser:new{
                    select_directory = true,
                    path             = base_storage,
                    onConfirm        = function(chosen_path)
                        if chosen_path and chosen_path ~= "" then
                            applyHomeDir(chosen_path)
                        end
                    end,
                })
            end)
        end
        ctx.push("tips_header")
    end

    -- ---------------------------------------------------------------------------
    -- Screen 3: Tips header + subtitle only
    -- ---------------------------------------------------------------------------
    local function buildTipsHeader(ctx)
        local iw = ctx.inner_w
        local rows = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(30)) })
        table.insert(rows, FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = ctx.SZ(Screen:scaleBySize(20)), padding_right = ctx.SZ(Screen:scaleBySize(20)),
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text    = _("Make it yours"),
                    face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_TITLE)),
                    bold    = true,
                    fgcolor = SUIStyle.COLOR.text_primary,
                },
                VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                TextBoxWidget:new{
                    text      = _("Simple UI is designed to be simple and flexible. Here are a few tips to get the most out of it."),
                    face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                    width     = iw - ctx.SZ(Screen:scaleBySize(40)),
                    alignment = "left",
                    fgcolor   = SUIStyle.COLOR.text_secondary,
                },
            },
        })

        return rows
    end

    -- ---------------------------------------------------------------------------
    -- Screen 4: Tips list — subtitle uses TextBoxWidget for full wrap (no truncation)
    -- Visual style mirrors ListRow: FS_BODY bold title, FS_CAPTION subtitle,
    -- with a LineWidget separator between items (not after the last one).
    -- ---------------------------------------------------------------------------
    local function buildTipsList(ctx)
        local iw      = ctx.inner_w
        local text_w  = iw - ctx.SZ(Screen:scaleBySize(40))
        local vpad    = ctx.SZ(Screen:scaleBySize(16))
        local rows    = {}

        table.insert(rows, VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(14)) })

        local tips = {
            {
                title = _("Long press to customize"),
                desc  = _("Press and hold any element on the screen (like modules or bars) to quickly customize its settings."),
            },
            {
                title = _("Customize even more"),
                desc  = _("Go to Settings > Home Screen to edit your layout whenever you want."),
            },
            {
                title = _("Set your reading goal"),
                desc  = _("If you selected the Momentum Preset, long press the Reading Goal module to choose and set your reading goals."),
            },
            {
                title = _("Custom wallpapers and icons"),
                desc  = _("Place your files in koreader/settings/simpleui/sui_wallpapers or sui_icons."),
            },
        }

        local Size      = require("ui/size")
        local fg        = SUIStyle.COLOR.text_primary
        local fg_sub    = SUIStyle.COLOR.text_secondary
        local sep_color = SUIStyle.COLOR.gray_soft

        local tip_vg = VerticalGroup:new{ align = "left" }

        for i, tip in ipairs(tips) do
            -- Tip content: bold title + wrapping subtitle
            local tip_content = FrameContainer:new{
                bordersize     = 0, padding = 0,
                padding_top    = vpad,
                padding_bottom = vpad,
                VerticalGroup:new{
                    align = "left",
                    TextWidget:new{
                        text    = tip.title,
                        face    = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_BODY)),
                        bold    = true,
                        fgcolor = fg,
                    },
                    VerticalSpan:new{ width = ctx.SZ(Screen:scaleBySize(4)) },
                    TextBoxWidget:new{
                        text      = tip.desc,
                        face      = Font:getFace(SUIStyle.FACE_REGULAR, ctx.SZ(SUIStyle.FS_CAPTION)),
                        width     = text_w,
                        alignment = "left",
                        fgcolor   = fg_sub,
                    },
                },
            }
            table.insert(tip_vg, tip_content)

            -- Separator between items, not after the last one
            if i < #tips then
                table.insert(tip_vg, LineWidget:new{
                    dimen      = Geom:new{ w = text_w, h = Size.line.thin },
                    background = sep_color,
                })
            end
        end

        table.insert(rows, FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_left  = ctx.SZ(Screen:scaleBySize(20)),
            padding_right = ctx.SZ(Screen:scaleBySize(20)),
            tip_vg,
        })

        return rows
    end

    -- Home folder is a single screen. Navigation skips it when home_dir
    -- is already configured.
    win = SUI:new{
        name          = "sui_win_onboarding",
        height        = math.floor(Screen:getHeight() * 0.75),
        screen_titles = {
            __root__    = _("Welcome to Simple UI"),
            presets     = _("Welcome to Simple UI"),
            home_folder = _("Set the Home Folder"),
            tips_header = _("Quick Tips"),
            tips        = _("Quick Tips"),
        },
        screens = {
            __root__    = buildWelcomeHeader,
            presets     = buildPresetList,
            home_folder = buildHomeFolder,
            tips_header = buildTipsHeader,
            tips        = buildTipsList,
        },
        position = "bottom",
        on_close = function()
            SUISettings:set("simpleui_onboarding_done", true)
            navigateFileManagerToHome()
            if on_finish then on_finish() end
        end,
        screen_footers = {
            __root__ = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() ctx.push("presets") end,
                })
            end,
            presets = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function()
                        if show_home then
                            ctx.push("home_folder")
                        else
                            ctx.push("tips_header")
                        end
                    end,
                })
            end,
            home_folder = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() applyHomeChoiceAndContinue(ctx) end,
                })
            end,
            tips_header = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Continue"),
                    on_tap = function() ctx.push("tips") end,
                })
            end,
            tips = function(ctx)
                return SUI.CenteredButtonFooter(ctx, {
                    text   = _("Start using Simple UI"),
                    on_tap = function()
                        if SUIPresets.applyBuiltin then SUIPresets.applyBuiltin(st.selected_preset) end
                        SUISettings:set("simpleui_hs_active_preset", st.selected_preset)
                        if win.close then win:close() else UIManager:close(win) end
                    end,
                })
            end,
        },
    }
    win:show()
end

return Onboarding
