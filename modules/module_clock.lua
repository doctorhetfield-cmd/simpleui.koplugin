-- module_clock.lua — Simple UI
-- Clock module with ordered, show/hide items (clock, date, battery).
-- Supports "digital", "word" and "analogue" clock styles.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local datetime        = require("datetime")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen          = Device.screen
local _ = require("infra/sui_i18n").translate

local UI           = require("infra/sui_core")
local UIManager    = require("ui/uimanager")
local SUIStyle     = require("features/sui_style")
local Config       = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local AAPaint      = require("infra/sui_aa_paint")
local PAD          = UI.PAD
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- ---------------------------------------------------------------------------
-- Translated date string
-- os.date("%A, %d %B") always returns English on most eReader locales.
-- We use os.date("*t") for the numeric indices and look up translated names.
-- ---------------------------------------------------------------------------

-- _WEEKDAYS and _MONTHS are intentionally NOT built at module-load time so
-- that _() is called after the user's locale has been applied. They are built
-- on the first _localDate() call and reused from that point on — the locale
-- never changes within a running KOReader session, so caching is safe.
local _weekdays = nil
local _months   = nil

local function _localDate()
    -- Pass os.time() explicitly: os.date("*t") without argument can return
    -- nil in LuaJIT on some platforms (macOS emulator) when timezone handling
    -- fails. os.date("*t", os.time()) is always safe.
    local now = os.time()
    local t   = os.date("*t", now)
    if not t or not t.day then
        -- Fallback via the datetime module's locale-aware formatter.
        return datetime.secondsToDate(now, true)
    end
    -- Build translation tables on first call only; never recreated afterwards.
    if not _weekdays then
        _weekdays = {
            _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"),
            _("Thursday"), _("Friday"), _("Saturday"),
        }
        _months = {
            _("January"), _("February"), _("March"),     _("April"),
            _("May"),     _("June"),     _("July"),       _("August"),
            _("September"), _("October"), _("November"),  _("December"),
        }
    end
    local weekday = _weekdays[t.wday] or os.date("%A", now)
    local month   = _months[t.month]  or os.date("%B", now)
    -- 中文环境用年月日格式，其他语言保持原样
    local lang = G_reader_settings and G_reader_settings:readSetting("language") or ""
    if lang:match("^zh") then
        return string.format("%d年%d月%d日 %s", t.year, t.month, t.day, weekday)
    end
    return string.format("%s, %d %s", weekday, t.day, month)
end

-- ---------------------------------------------------------------------------
-- Clock size model
-- ---------------------------------------------------------------------------
-- span = target width of the clock block (centred in the column):
--   • Full-width row (bento 100%): 35% of inner_w
--   • Bento column (< 100%):       100% of the column, capped at the full-row
--     35% span (never larger than the default full-width size)
--
-- Face size is derived from span so a full-width row yields the previous
-- default (~75 px), not span itself as a font size (which filled the screen).
-- Date / battery / word-clock / gaps are fixed ratios of that face size.
-- ---------------------------------------------------------------------------
local _CLOCK_FRAC_FULL  = 0.35
local _CLOCK_FRAC_BENTO = 1.0
local _CLOCK_FACE_FULL  = 75   -- digital face size at full-row 35% span, scale 1
local _CLOCK_SIZE_MIN   = 10

local _REF_FULL_INNER_W = UI.getInnerW() - PAD * 2
local _REF_FULL_SPAN    = _REF_FULL_INNER_W * _CLOCK_FRAC_FULL

-- Ratios relative to digital face size.
local _WORD_FS_RATIO  = 50 / 75
local _DATE_FS_RATIO  = 20 / 75
local _BATT_FS_RATIO  = 18 / 75
local _DATE_H_RATIO   = 17 / 75
local _BATT_H_RATIO   = 15 / 75

-- Gap between visible items (clock/date/battery), scaled the same way as
-- every other module's inter-element spacing (base px * module scale),
-- rather than tied to the clock face font size.
local _BASE_ITEM_GAP = Screen:scaleBySize(25)

-- Returns span (target block width) and face size (digital font / line height).
local function _clockMetrics(inner_w, pfx, raw_scale, clock_elem)
    raw_scale  = raw_scale or 1
    clock_elem = clock_elem or 1
    local scale_m = raw_scale * clock_elem
    local max_span = math.max(_CLOCK_SIZE_MIN, math.floor(_REF_FULL_SPAN * scale_m))
    local frac = (Config.getBentoWidth("clock", pfx or "") < 100)
                 and _CLOCK_FRAC_BENTO or _CLOCK_FRAC_FULL
    local span = math.max(_CLOCK_SIZE_MIN, math.floor(inner_w * frac * scale_m))
    if span > max_span then span = max_span end
    -- Map span → face: full-row span yields _CLOCK_FACE_FULL at scale 1.
    local face = math.max(_CLOCK_SIZE_MIN,
        math.floor(span / math.max(1, _REF_FULL_SPAN) * _CLOCK_FACE_FULL))
    return span, face
end

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTING_ON        = "clock_enabled"     -- pfx .. "clock_enabled"
local SETTING_DATE      = "clock_date"        -- pfx .. "clock_date"      (default ON)
local SETTING_BATTERY   = "clock_battery"     -- pfx .. "clock_battery"   (default ON)
local SETTING_ORDER     = "clock_order"       -- pfx .. "clock_order"     (array of item keys)
local SETTING_ITEM_GAP  = "clock_item_gap"    -- pfx .. "clock_item_gap"  (integer %, default 100)
-- Legacy gap keys kept for one-time migration into SETTING_ITEM_GAP.
local SETTING_DATE_GAP  = "clock_date_gap"
local SETTING_BATT_GAP  = "clock_batt_gap"
local SETTING_ALIGN     = "clock_align"       -- pfx .. "clock_align"     (default "center")
local SETTING_STYLE     = "clock_style"       -- pfx .. "clock_style"     ("digital"|"word"|"analogue")

local ALIGN_VALUES = { "left", "center", "right" }
local STYLE_VALUES = { "digital", "word", "analogue" }

-- Fixed item keys, in the default top-to-bottom order.
local DEFAULT_ORDER = { "clock", "date", "battery" }

local ITEM_VIS_KEY = {
    clock   = SETTING_ON,
    date    = SETTING_DATE,
    battery = SETTING_BATTERY,
}

-- Reads a setting and validates it against a fixed list of allowed values,
-- falling back to `default` for unset or corrupted entries.
local function _readEnum(pfx, key, values, default)
    local v = SUISettings:readSetting(pfx .. key)
    for _, allowed in ipairs(values) do if allowed == v then return v end end
    return default
end

local function getAlignment(pfx)
    return _readEnum(pfx, SETTING_ALIGN, ALIGN_VALUES, "center")
end

local function setAlignment(pfx, val)
    SUISettings:saveSetting(pfx .. SETTING_ALIGN, val)
end

local function alignLabel(align, _lc)
    if align == "left"  then return _lc("Left")  end
    if align == "right" then return _lc("Right") end
    return _lc("Center")
end

local function getClockStyle(pfx)
    return _readEnum(pfx, SETTING_STYLE, STYLE_VALUES, "digital")
end

local function setClockStyle(pfx, val)
    SUISettings:saveSetting(pfx .. SETTING_STYLE, val)
end

local ITEM_GAP_MIN  = 0
local ITEM_GAP_MAX  = 300
local ITEM_GAP_STEP = 10
local ITEM_GAP_DEF  = 100

local function _clampItemGap(n)
    return math.max(ITEM_GAP_MIN, math.min(ITEM_GAP_MAX, math.floor(n)))
end

-- Single inter-item spacing (%). Migrates from the older per-element gap
-- keys the first time it is read so existing setups keep their value.
local function getItemGapPct(pfx)
    local n = tonumber(SUISettings:readSetting(pfx .. SETTING_ITEM_GAP))
    if n then return _clampItemGap(n) end
    local legacy = tonumber(SUISettings:readSetting(pfx .. SETTING_DATE_GAP))
                or tonumber(SUISettings:readSetting(pfx .. SETTING_BATT_GAP))
    if legacy then
        local v = _clampItemGap(legacy)
        SUISettings:saveSetting(pfx .. SETTING_ITEM_GAP, v)
        return v
    end
    return ITEM_GAP_DEF
end

local function setItemGapPct(pfx, n)
    SUISettings:saveSetting(pfx .. SETTING_ITEM_GAP, _clampItemGap(n))
end

-- Reads a boolean visibility setting, defaulting to ON (unset means true;
-- only an explicit `false` turns it off).
local function _isVisible(pfx, key)
    return SUISettings:readSetting(pfx .. key) ~= false
end

local function isClockEnabled(pfx)
    return _isVisible(pfx, SETTING_ON)
end

local function isDateEnabled(pfx)
    return _isVisible(pfx, SETTING_DATE)
end

local function isBattEnabled(pfx)
    return _isVisible(pfx, SETTING_BATTERY)
end

local function isItemVisible(pfx, item_key)
    local sk = ITEM_VIS_KEY[item_key]
    return sk and _isVisible(pfx, sk) or false
end

local function setItemVisible(pfx, item_key, visible)
    local sk = ITEM_VIS_KEY[item_key]
    if not sk then return end
    SUISettings:saveSetting(pfx .. sk, visible and true or false)
end

local function itemLabel(item_key, _lc)
    if item_key == "clock"   then return _lc("Clock") end
    if item_key == "date"    then return _lc("Date") end
    if item_key == "battery" then return _lc("Battery") end
    return item_key
end

-- Manual arrangement order of the three fixed items. Unknown or missing
-- keys are appended in DEFAULT_ORDER so the list always covers every item.
local function getItemOrder(pfx)
    return Config.mergeOrder(SUISettings:readSetting(pfx .. SETTING_ORDER), DEFAULT_ORDER)
end

local function saveItemOrder(pfx, order)
    SUISettings:saveSetting(pfx .. SETTING_ORDER, order)
end

-- Visible items in the current manual order (the sequence the layout uses).
local function getVisibleItems(pfx)
    local out = {}
    for _, k in ipairs(getItemOrder(pfx)) do
        if isItemVisible(pfx, k) then out[#out + 1] = k end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Word clock — numeric time-to-words conversion
-- ---------------------------------------------------------------------------
--
-- Converts a (hour, minute) pair to two lines of spelled-out numbers.
-- Examples (12-hour mode, English defaults):
--   12:00  → "Twelve\nO'Clock"
--   12:05  → "Twelve\nOh Five"
--   12:15  → "Twelve\nFifteen"
--   12:30  → "Twelve\nThirty"
--   12:50  → "Twelve\nFifty"
--   12:21  → "Twelve\nTwenty-One"
--
-- Every word is individually wrapped in _() so translators get atomic
-- units.  The tens-units separator is also a translatable string
-- ("WORD_CLOCK_TENS_SEP") — it is "-" in English but " e " in Portuguese,
-- allowing correct "Vinte e Um" vs "Twenty-One" without any code changes.
--
-- For 24-hour mode the hour table is extended to 0–23.  Hours 13–23 use the
-- same words as 1–11 for simplicity (e.g. 14:00 → "Fourteen\nO'Clock"),
-- which matches how people actually say 24h times in most languages.
--
-- The tens-units separator in compound minute strings ("Twenty-One") is
-- itself a translatable string ("WORD_CLOCK_TENS_SEP") — "-" in English,
-- " e " in Portuguese ("Vinte e Um") — so no code changes are needed per
-- language.
-- ---------------------------------------------------------------------------

-- Translated word tables are built lazily on first use, not at module load,
-- so that _() resolves against the user's locale rather than whatever
-- locale is active before KOReader finishes initializing.
local _wc_units_cache = nil
local _wc_tens_cache  = nil
local _wc_sep_cache   = nil

local function _wcCache()
    if _wc_units_cache then return end
    _wc_units_cache = {
        [1]  = _("One"),        [2]  = _("Two"),       [3]  = _("Three"),
        [4]  = _("Four"),       [5]  = _("Five"),      [6]  = _("Six"),
        [7]  = _("Seven"),      [8]  = _("Eight"),     [9]  = _("Nine"),
        [10] = _("Ten"),        [11] = _("Eleven"),    [12] = _("Twelve"),
        [13] = _("Thirteen"),   [14] = _("Fourteen"),  [15] = _("Fifteen"),
        [16] = _("Sixteen"),    [17] = _("Seventeen"), [18] = _("Eighteen"),
        [19] = _("Nineteen"),
    }
    _wc_tens_cache = {
        [2] = _("Twenty"), [3] = _("Thirty"),
        [4] = _("Forty"),  [5] = _("Fifty"),
    }
    -- Fallback depends on the script family: CJK and Cyrillic languages
    -- write tens+units directly with no separator ("二十一", "двадцатьодин");
    -- English needs an explicit "-" (kept here so untranslated English
    -- locales still read "Twenty-One"); languages that already provide a
    -- translation (bg " и", pt " e ", cs " ", etc.) override this default.
    local sep = _("WORD_CLOCK_TENS_SEP")
    if sep == "WORD_CLOCK_TENS_SEP" then
        -- KOReader stores "English" as locale "C" (the POSIX default — see
        -- frontend/ui/language.lua's getLangMenuTable); ICU-style codes
        -- like "en_GB" / "en_US" share the "en" prefix. Treat both as
        -- English so all three read "Twenty-One" by default.
        local lang   = G_reader_settings and G_reader_settings:readSetting("language") or ""
        local prefix = lang:match("^([a-zA-Z]+)") or ""
        sep = (prefix == "en" or lang == "C") and "-" or ""
    end
    _wc_sep_cache = sep
end

-- Converts a minute value [0..59] to its word representation.
-- Returns the translated minute string, or nil for :00 (caller adds O'Clock).
local function _minToWords(min)
    if min == 0 then return nil end
    _wcCache()
    if min < 10 then
        -- "Oh Five", "Oh Nine"
        return _("Oh") .. " " .. _wc_units_cache[min]
    elseif min < 20 then
        -- "Ten" … "Nineteen" — direct lookup
        return _wc_units_cache[min]
    else
        local tens  = math.floor(min / 10)
        local units = min % 10
        if units == 0 then
            return _wc_tens_cache[tens]
        else
            return _wc_tens_cache[tens] .. _wc_sep_cache .. _wc_units_cache[units]
        end
    end
end

-- Converts hour + minute to a two-line word-clock string.
-- @param hour      number   0–23
-- @param min       number   0–59
-- @param is_12h    boolean  true = 12-hour display
-- @return          string   e.g. "Twelve\nFifty" or "Twelve\nO'Clock"
local function timeToWords(hour, min, is_12h)
    _wcCache()

    local h
    if is_12h then
        h = hour % 12
        if h == 0 then h = 12 end
    else
        -- 24h: use 0–23 but map 0 to Midnight for readability.
        h = hour
    end

    local hour_str
    if h == 0 then
        hour_str = _("Midnight")
    elseif h == 12 and not is_12h then
        -- In 24h mode, noon is special.
        hour_str = _("Noon")
    elseif _wc_units_cache[h] then
        hour_str = _wc_units_cache[h]
    else
        -- Hours 20–23 in 24h mode — compose from tens+units.
        local tens  = math.floor(h / 10)
        local units = h % 10
        if units == 0 then
            hour_str = _wc_tens_cache[tens] or tostring(h)
        else
            hour_str = (_wc_tens_cache[tens] or "") .. _wc_sep_cache .. (_wc_units_cache[units] or tostring(units))
        end
    end

    local min_str = _minToWords(min)
    if min_str then
        return hour_str .. "\n" .. min_str
    else
        return hour_str .. "\n" .. _("O'Clock")
    end
end

-- ---------------------------------------------------------------------------
-- Item slot
--
-- Wraps a widget in a row of fixed height and the widget's own width, with the
-- widget vertically centred. The fixed height keeps the module height
-- independent of font metrics (see M.getHeight).
-- `shift` (px, positive = down) offsets the widget from the centre; it is
-- applied as a spacer on the opposite side, which the centring then halves.
-- ---------------------------------------------------------------------------

local function _slot(wgt, h, shift)
    local size = wgt:getSize()
    if not wgt.dimen then wgt.dimen = size end
    local content = wgt
    if shift and shift > 0 then
        content = VerticalGroup:new{ VerticalSpan:new{ width = shift * 2 }, wgt }
    elseif shift and shift < 0 then
        content = VerticalGroup:new{ wgt, VerticalSpan:new{ width = -shift * 2 } }
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = size.w, h = h },
        content,
    }
end

-- ---------------------------------------------------------------------------
-- Word clock widget builder
--
-- Returns a VerticalGroup containing two lines (hour + minutes), aligned
-- relative to each other by `align`.
-- Using two separate widgets (rather than one multi-line TextBoxWidget) gives
-- us reliable height control on e-ink devices, where multi-line TextBoxWidget
-- getSize() sometimes reports incorrect heights before the first paint.
-- ---------------------------------------------------------------------------

local function _buildWordClockWidget(text, face, bold, align)
    -- Split the "Hour\nMinutes" string into two parts.
    local nl = text:find("\n")
    local line1 = nl and text:sub(1, nl - 1) or text
    local line2 = nl and text:sub(nl + 1)    or ""

    -- Measure a single line height once.
    local probe = TextWidget:new{ text = line1, face = face, bold = bold }
    local line_h = probe:getSize().h
    probe:free()

    local function makeLine(txt)
        return _slot(UI.makeColoredText{
            text = txt,
            face = face,
            bold = bold,
        }, line_h)
    end

    local vg = VerticalGroup:new{ align = align }
    vg[1] = makeLine(line1)
    if line2 ~= "" then
        vg[2] = VerticalSpan:new{ width = math.floor(line_h * 0.10) }
        vg[3] = makeLine(line2)
    end
    return vg
end

-- ---------------------------------------------------------------------------
-- Analogue clock face
-- ---------------------------------------------------------------------------
-- Drawn directly with the coverage-based anti-aliasing primitives in
-- infra/sui_aa_paint.lua (see that module's header for how the technique
-- works) instead of relying on any native rounded-shape drawing.
--
-- No rim: bare ticks + hands read cleanly on their own, and a ring is one
-- more shape whose stroke width would need to stay in proportion at every
-- face size for no real benefit. No centre hub — hands run a little past
-- the centre point instead. No second hand: the module only repaints on the
-- minute boundary (see M.scheduleRefresh below), so a second hand would
-- never actually move.
--
-- Always reads the time as a 12-hour face, independent of the "24-hour
-- clock" device setting the digital style honours — an analogue dial has no
-- 24-hour convention to switch to.
--
-- Composited over the target with UI.paintWithAlphaMask so it sits
-- transparently over a wallpaper, the same way UI.makeColoredText composites
-- coloured text — this drawing routine just fills the role that
-- TextWidget:paintTo plays there.

-- Draws the face into `bb` (assumed already white-filled, size diameter ×
-- diameter), in BLACK ink — UI.paintWithAlphaMask inverts and recolours it
-- afterwards.
local function _drawAnalogueFace(bb, diameter, hour, min)
    local cx, cy = diameter / 2, diameter / 2
    local r      = diameter / 2
    local x0, y0, x1, y1 = 0, 0, diameter - 1, diameter - 1

    -- Ticks: 12 marks inset from the edge, one every 30°, 0 = 12 o'clock,
    -- clockwise. The four quarter marks (12/3/6/9, i.e. i % 3 == 0) are
    -- longer and thicker.
    local tick_gap = diameter * 0.05
    for i = 0, 11 do
        local is_major = (i % 3 == 0)
        local tick_len = is_major and diameter * 0.09  or diameter * 0.045
        local tick_w   = is_major and diameter * 0.022 or diameter * 0.012
        local angle    = i * (math.pi / 6)
        local sn, co   = math.sin(angle), math.cos(angle)
        local outer    = r - tick_gap
        local inner    = outer - tick_len
        AAPaint.paintCapsule(bb, cx + inner * sn, cy - inner * co,
                                 cx + outer * sn, cy - outer * co,
                                 tick_w, x0, y0, x1, y1)
    end

    -- Hands: no centre hub, so each hand's stroke starts a little past the
    -- centre on the opposite side (tail) and runs out to its length.
    local tail = math.max(diameter * 0.04, 2)
    local function drawHand(angle, length, width)
        local sn, co = math.sin(angle), math.cos(angle)
        AAPaint.paintCapsule(bb, cx - tail * sn, cy + tail * co,
                                 cx + length * sn, cy - length * co,
                                 width, x0, y0, x1, y1)
    end
    local minute_angle = (min / 60) * (2 * math.pi)
    local hour_angle    = ((hour % 12) + min / 60) / 12 * (2 * math.pi)
    drawHand(hour_angle,   diameter * 0.28, diameter * 0.03)
    drawHand(minute_angle, diameter * 0.40, diameter * 0.022)
end

-- Builds a transparent-background widget of size diameter × diameter showing
-- the current time as an analogue face in `fg_color`. Mirrors the structure
-- of UI.makeColoredText (offscreen 8-bit buffer, painted in BLACK, composited
-- via UI.paintWithAlphaMask) — the only difference is the paint routine
-- draws clock-face primitives instead of rendering a TextWidget.
local function _buildAnalogueClockWidget(diameter, fg_color)
    if diameter < 2 then return nil end
    local t   = os.date("*t", os.time())
    local hour, min = t.hour, t.min

    local widget = WidgetContainer:new{}
    widget.dimen = Geom:new{ w = diameter, h = diameter }

    function widget:getSize()
        return self.dimen
    end

    function widget:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local d = self.dimen.w
        if d <= 0 then return end

        if not self._tmp_bb or self._tmp_bb:getWidth() ~= d or self._tmp_bb:getHeight() ~= d then
            if self._tmp_bb then self._tmp_bb:free() end
            self._tmp_bb = Blitbuffer.new(d, d, Blitbuffer.TYPE_BB8)
        end

        local custom_paint_fn = function(_widget, tmp_bb)
            _drawAnalogueFace(tmp_bb, d, hour, min)
        end

        UI.paintWithAlphaMask(widget, bb, x, y, d, d, fg_color, custom_paint_fn, self._tmp_bb)
    end

    function widget:onCloseWidget() self:free() end

    function widget:free()
        if self._tmp_bb then
            self._tmp_bb:free()
            self._tmp_bb = nil
        end
    end

    return widget
end

-- ---------------------------------------------------------------------------
-- Battery helpers
-- ---------------------------------------------------------------------------

-- Returns battery level clamped to [0,100] and charging flag.
local function _battInfo()
    local pwr = Device:getPowerDevice()
    if not pwr then return nil, false end
    local lvl, charging = nil, false
    if pwr.getCapacity then
        local ok, v = pcall(pwr.getCapacity, pwr)
        if ok and type(v) == "number" then
            lvl = v < 0 and 0 or v > 100 and 100 or v
        end
    end
    if pwr.isCharging then
        local ok, v = pcall(pwr.isCharging, pwr); if ok then charging = v end
    end
    return lvl, charging
end

-- lvl is always a number in [0,100] or nil (normalised by _battInfo).
-- Battery always uses CLR_TEXT_SUB — same subdued grey as date and author text.

-- Builds the battery display string.
-- Uses ▰/▱ (filled/empty blocks) matching module_header.lua visual style.
-- Charging replaces the first block with ⚡.
local function _battText(lvl, charging)
    if type(lvl) ~= "number" then return "N/A" end
    local bars
    if     lvl >= 90 then bars = "▰▰▰▰"
    elseif lvl >= 60 then bars = "▰▰▰▱"
    elseif lvl >= 40 then bars = "▰▰▱▱"
    elseif lvl >= 20 then bars = "▰▱▱▱"
    else                  bars = "▱▱▱▱" end
    local icon = charging and ("⚡" .. bars:sub(4)) or bars
    return string.format("%s %d%%", icon, lvl)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function _vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

-- Text elements with a user-selectable font family and size scale.
-- Size lives only in Config text styles (_text_scale_*); no parallel scale keys.
local TEXT_ELEMS = { "clock", "date", "battery" }

-- The time is bold until the user picks another variant.
Config.declareTextVariants("clock", { clock = "bold" })

-- One-shot: copy legacy *_elem_scale values into text-style scales, then delete
-- the legacy keys. Runs at most once per prefix per process.
local _LEGACY_ELEM = { clock = "clock", date = "date", battery = "batt" }
local _elem_migrated = {}

local function _migrateLegacyElemScales(pfx)
    pfx = pfx or "simpleui_hs_"
    if _elem_migrated[pfx] then return end
    _elem_migrated[pfx] = true
    for elem, legacy in pairs(_LEGACY_ELEM) do
        local text_key = pfx .. "clock_text_scale_" .. elem
        if SUISettings:get(text_key) == nil then
            local pct = Config.getElemScalePct("clock", legacy, pfx)
            if pct ~= Config.SCALE_DEF then
                Config.setTextStyleScale(pct, "clock", elem, pfx)
            end
        end
        SUISettings:del(pfx .. "clock_" .. legacy .. "_elem_scale")
    end
end

-- landscape_factor is accepted for API compatibility; size uses raw module
-- scale only. `w` is already the column width in landscape spread, so
-- applying lf again would shrink twice (same convention as GridRenderer).
-- `styles` (text style per element) is read from settings when omitted.
local function build(w, pfx, vspan_pool, landscape_factor, styles)
    local lf    = landscape_factor or 1
    _migrateLegacyElemScales(pfx)
    styles = styles or Config.readTextStyles("clock", TEXT_ELEMS, pfx)
    local scale = Config.getModuleScale("clock", pfx) * lf

    local raw_scale  = Config.getModuleScaleRaw("clock", pfx)
    local clock_elem = styles.clock.scale or 1
    local date_elem  = styles.date.scale or 1
    local batt_elem  = styles.battery.scale or 1

    local clock_span, clock_fs = _clockMetrics(w, pfx, raw_scale, clock_elem)
    local clock_w  = clock_fs
    local word_fs  = math.max(_CLOCK_SIZE_MIN, math.floor(clock_fs * _WORD_FS_RATIO))

    local date_fs  = math.max(8, math.floor(clock_fs * _DATE_FS_RATIO * date_elem))
    local batt_fs  = math.max(7, math.floor(clock_fs * _BATT_FS_RATIO * batt_elem))
    local date_h   = math.max(8, math.floor(clock_fs * _DATE_H_RATIO  * date_elem))
    local batt_h   = math.max(7, math.floor(clock_fs * _BATT_H_RATIO  * batt_elem))
    local item_gap = math.max(0, math.floor(_BASE_ITEM_GAP * scale * getItemGapPct(pfx) / 100))

    local visible     = getVisibleItems(pfx)
    local clock_style = getClockStyle(pfx)

    local sub_fg = CLR_TEXT_SUB

    local align = getAlignment(pfx)
    local vg = VerticalGroup:new{ align = align }

    local function appendClock()
        if clock_style == "word" then
            local is_12h = G_reader_settings:isTrue("twelve_hour_clock")
            local t      = os.date("*t", os.time())
            local wc_text = timeToWords(t.hour, t.min, is_12h)
            local face_word, bold_word = SUIStyle.getTextFace(styles.clock, word_fs)
            vg[#vg+1] = _buildWordClockWidget(wc_text, face_word, bold_word, align)
        elseif clock_style == "analogue" then
            local diameter = math.min(clock_span, w)
            if diameter % 2 == 1 then diameter = diameter - 1 end
            local face_widget = _buildAnalogueClockWidget(diameter, SUIStyle.COLOR.text_primary)
            if face_widget then vg[#vg+1] = face_widget end
        else
            local face_clock, bold_clock = SUIStyle.getTextFace(styles.clock, clock_fs)
            local time_text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
            vg[#vg+1] = _slot(UI.makeColoredText{
                text = time_text,
                face = face_clock,
                bold = bold_clock,
            }, clock_w, SUIStyle.inkCentreShift(face_clock, time_text, bold_clock))
        end
    end

    local function appendDate()
        local face_date, bold_date = SUIStyle.getTextFace(styles.date, date_fs)
        vg[#vg+1] = _slot(UI.makeColoredText{
            text    = _localDate(),
            face    = face_date,
            bold    = bold_date,
            fgcolor = sub_fg,
        }, date_h)
    end

    local function appendBattery()
        local lvl, charging = _battInfo()
        local face_batt, bold_batt = SUIStyle.getTextFace(styles.battery, batt_fs)
        vg[#vg+1] = _slot(UI.makeColoredText{
            text    = _battText(lvl, charging),
            face    = face_batt,
            bold    = bold_batt,
            fgcolor = sub_fg,
        }, batt_h)
    end

    local appenders = {
        clock   = appendClock,
        date    = appendDate,
        battery = appendBattery,
    }

    for _, key in ipairs(visible) do
        if #vg > 0 then vg[#vg+1] = _vspan(item_gap, vspan_pool) end
        local append = appenders[key]
        if append then append() end
    end

    if #vg == 0 then return nil end

    -- `fit_align` makes the module chrome hug the content and position it
    -- within the column (see ModuleChrome.wrap). Horizontal insets come from
    -- the chrome; equal vertical padding keeps the block optically centred.
    return FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_top    = PAD,
        padding_bottom = PAD,
        fit_align      = align,
        vg,
    }
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------

local M = {}

M.id         = "clock"
M.name       = _("Clock")
M.label      = nil
M.default_on = true
M.text_elems = TEXT_ELEMS

function M.isEnabled(pfx)
    return isClockEnabled(pfx) or isDateEnabled(pfx) or isBattEnabled(pfx)
end

function M.setEnabled(pfx, on)
    if not on then
        -- The module was removed from the layout: clear all visibility flags
        -- so a future re-add starts with clean defaults.
        SUISettings:saveSetting(pfx .. SETTING_ON,      false)
        SUISettings:saveSetting(pfx .. SETTING_DATE,    false)
        SUISettings:saveSetting(pfx .. SETTING_BATTERY, false)
    else
        -- The module is in the layout: only enable the clock itself.
        -- SETTING_DATE and SETTING_BATTERY are NOT touched — if they already exist,
        -- they respect the user's preference; if they are nil, isBattEnabled /
        -- isDateEnabled use their own defaults (ON for both).
        SUISettings:saveSetting(pfx .. SETTING_ON, true)
    end
end

M.getCountLabel = nil

-- ---------------------------------------------------------------------------
-- Surgical clock tick — rebuilds only the clock widget inside the body
-- VerticalGroup, without triggering a full homescreen rebuild.
--
-- The homescreen records _clock_body_ref, _clock_body_idx, and
-- _clock_is_wrapped during _buildContent() (see below).  The tick reads
-- those fields to do a targeted swap, then marks only the navbar container
-- dirty.  Falls back to a full _refresh() if the index was not recorded.
-- ---------------------------------------------------------------------------

local _timer         = nil   -- scheduled function reference (module-level singleton)
local _screen_widget = nil   -- weak reference to the live ScreenWidget (Homescreen or Custom Screen)

local function _tick()
    _timer = nil   -- timer has fired; clear before rescheduling

    -- Abort if the owning screen instance has changed or gone away.
    -- Uses ScreenEngine.getInstance(id), which is id-aware for any screen
    -- (built-in Homescreen or Custom Screen), rather than the legacy flat
    -- ScreenEngine._instance field, which is only ever populated for the
    -- built-in Homescreen (id == "hs") — checking against that field alone
    -- would make this guard always consider a Custom Screen's clock stale,
    -- since ScreenEngine._instance never points at a Custom Screen instance.
    local screen = _screen_widget
    if not screen then return end
    local ScreenEngine = package.loaded["engines/sui_screen_engine"]
    if not ScreenEngine or ScreenEngine.getInstance(screen._id) ~= screen then
        _screen_widget = nil
        return
    end

    -- Do not update while suspended — some platforms fire pending timers
    -- during the suspend transition before the scheduler pauses.
    -- Crucially: do NOT reschedule here. Rescheduling would create a new timer
    -- that onSuspend can no longer cancel (it already ran), causing a 60s loop
    -- that keeps firing throughout the entire suspend period.
    -- ScreenWidget:onResume calls ClockMod.scheduleRefresh() to restart the
    -- chain on wakeup — no action needed here.
    --
    -- Two complementary guards:
    -- • screen._suspended — set by ScreenWidget:onSuspend() when the Suspend
    --   event reaches the widget via broadcastEvent.
    -- • plugin._simpleui_suspended — set by SimpleUIPlugin:onSuspend(), which
    --   runs in the same broadcastEvent pass but may arrive before or after the
    --   widget handler depending on stack order. Checking both closes the race
    --   window where the UIManager has already dequeued this timer for execution
    --   in the current tick before either flag was set.
    local FM = package.loaded["apps/filemanager/filemanager"]
    local plugin = FM and FM.instance and FM.instance._simpleui_plugin
    if screen._suspended or (plugin and plugin._simpleui_suspended) or Device.screen_saver_mode then
        return
    end

    -- Do not update while a book is open — the screen is hidden anyway.
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then
        M.scheduleRefresh(screen)
        return
    end

    -- Fast path: swap only the clock widget in the body VerticalGroup.
    local body       = screen._clock_body_ref
    local idx        = screen._clock_body_idx
    local is_wrapped = screen._clock_is_wrapped
    local swapped    = false

    if body and idx and body[idx] and screen._navbar_container then
        local sw      = Screen:getWidth()
        local inner_w = screen._clock_inner_w or UI.getInnerW(sw)

        -- Pass the screen's landscape factor through explicitly so the
        -- surgical swap matches the size _updatePage would have built.
        local lf = screen._clock_landscape_factor

        local ok_ch, Chrome = pcall(require, "features/sui_module_chrome")
        local pfx = screen._clock_pfx or "simpleui_hs_"
        local chrome = ok_ch and Chrome and Chrome.resolve(pfx, "clock") or nil
        local col_w = screen._clock_col_w
        if not col_w and chrome then
            col_w = inner_w + Chrome.outerMargin(chrome) * 2
                + Chrome.innerPad(chrome) * 2 + Chrome.borderSz(chrome) * 2
        end
        col_w = col_w or inner_w

        -- Build at the same content width the page path would use.
        local build_w = (chrome and Chrome.contentWidth(col_w, chrome)) or inner_w
        local ok_w, new_widget = pcall(build, build_w, pfx, screen._vspan_pool, lf)

        if ok_w and new_widget then
            -- Re-apply module chrome so the surgical swap keeps the same
            -- fill/frame width the full page build would have wrapped.
            if chrome then
                new_widget = Chrome.wrap(new_widget, chrome, col_w, lf or 1)
            end
            local target
            if is_wrapped then
                -- The clock was wrapped in an InputContainer for hold-to-settings.
                -- Replace the inner slot [1] to keep the gesture handler alive.
                body[idx][1] = new_widget
                target = body[idx]
            else
                body[idx] = new_widget
                target = new_widget
            end
            -- Scope the e-ink refresh to the clock's own region instead of the
            -- whole screen, the same convention used for other in-place widget
            -- swaps (see ScreenWidget:_refreshBookModSlot). The dimen is read
            -- lazily via the callback, after the paint pass has positioned
            -- `target`, so it reflects the widget's real on-screen coordinates.
            UIManager:setDirty(screen, function() return "ui", target.dimen end)
            swapped = true
        end
    end

    if not swapped then
        -- Slow-path fallback — only triggered when the clock module is on the
        -- current page but build() failed (e.g. transient font-cache miss).
        -- idx == nil means clock is simply not on the current page: nothing to
        -- repaint, so skip the rebuild entirely.
        -- Use _updatePage(true) directly — same as the original _clockTick:
        -- immediate, keeps book/stats caches intact, no unnecessary DB roundtrips.
        if idx ~= nil and screen._navbar_container then
            local ok = pcall(function()
                screen:_updatePage(true)
                UIManager:setDirty(screen, "ui")
            end)
            if not ok then _screen_widget = nil; return end
        end
    end

    -- ---------------------------------------------------------------------------
    -- Topbar clock synchronisation.
    -- Both clocks schedule their next tick with 60-(os.time()%60)+1. Driving
    -- the topbar refresh from this same callback makes both chains read
    -- os.time() at the same moment, so they reschedule to the identical next
    -- minute boundary instead of drifting apart and showing different minutes.
    --
    -- `plugin` was resolved above for the suspend guard — reuse it here.
    -- ---------------------------------------------------------------------------
    if plugin and not plugin._simpleui_suspended then
        local Topbar = package.loaded["screens/sui_topbar"]
        if Topbar then
            -- Cancel the topbar's own pending timer before refreshing — without
            -- this, the topbar would fire again on its old schedule in addition
            -- to the reschedule at the end of Topbar.refresh().
            if plugin._topbar_timer then
                UIManager:unschedule(plugin._topbar_timer)
                plugin._topbar_timer = nil
            end
            pcall(Topbar.refresh, Topbar, plugin)
        end
    end

    M.scheduleRefresh(screen)
end

-- Schedule the next tick, aligned to the next minute boundary.
-- Safe to call repeatedly — cancels any pending timer first.
function M.scheduleRefresh(screen)
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _screen_widget = screen
    local secs = 60 - (os.time() % 60) + 1
    _timer = _tick
    UIManager:scheduleIn(secs, _timer)
end

-- Cancel any pending timer and release the screen reference.
-- Called from onSuspend and onCloseWidget.
function M.cancelRefresh()
    if _timer then
        UIManager:unschedule(_timer)
        _timer = nil
    end
    _screen_widget = nil
end

function M.build(w, ctx)
    -- Record swap coordinates on the owning screen widget so the tick can do
    -- a surgical replacement without rebuilding the entire page.  These fields
    -- are written here (inside build) because build() is called from within
    -- the module loop in _buildContent(), at which point the body index is
    -- not yet known to the screen. The screen sets _clock_body_idx
    -- immediately after build() returns (see sui_homescreen.lua).
    if ctx._screen_widget then
        ctx._screen_widget._clock_pfx      = ctx.pfx
        ctx._screen_widget._clock_inner_w  = w
        -- Full column width for surgical re-wrap (set by screen engine).
        ctx._screen_widget._clock_col_w    = ctx.col_w
    end
    return build(w, ctx.pfx, ctx.vspan_pool, ctx.landscape_factor,
        Config.resolveTextStyles(ctx, M.id, TEXT_ELEMS))
end

function M.getHeight(ctx)
    _migrateLegacyElemScales(ctx.pfx)
    local styles     = Config.resolveTextStyles(ctx, M.id, TEXT_ELEMS)
    local raw_scale  = Config.getModuleScaleRaw("clock", ctx.pfx)
    local clock_elem = styles.clock.scale or 1
    local date_elem  = styles.date.scale or 1
    local batt_elem  = styles.battery.scale or 1
    local w_estimate = ctx.col_w or ctx.inner_w or UI.getInnerW()
    local inner_w_estimate = w_estimate - PAD * 2

    -- Same scale basis as build(): module scale * landscape factor.
    local scale = Config.getModuleScale("clock", ctx.pfx) * (ctx.landscape_factor or 1)

    local clock_span, clock_fs = _clockMetrics(inner_w_estimate, ctx.pfx, raw_scale, clock_elem)
    local date_h   = math.max(8, math.floor(clock_fs * _DATE_H_RATIO  * date_elem))
    local batt_h   = math.max(7, math.floor(clock_fs * _BATT_H_RATIO  * batt_elem))
    local item_gap = math.max(0, math.floor(_BASE_ITEM_GAP * scale * getItemGapPct(ctx.pfx) / 100))

    local h_base  = PAD * 2
    local visible = getVisibleItems(ctx.pfx)
    local style   = getClockStyle(ctx.pfx)

    local clock_h
    if style == "analogue" then
        clock_h = math.min(clock_span, inner_w_estimate)
    elseif style == "word" then
        local word_fs = math.max(_CLOCK_SIZE_MIN, math.floor(clock_fs * _WORD_FS_RATIO))
        clock_h = math.floor(word_fs * 2.2)
    else
        clock_h = clock_fs
    end

    local heights = {
        clock   = clock_h,
        date    = date_h,
        battery = batt_h,
    }

    local h = h_base
    for i, key in ipairs(visible) do
        if i > 1 then h = h + item_gap end
        h = h + (heights[key] or 0)
    end
    return h
end


function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle(key, current)
        SUISettings:saveSetting(pfx .. key, not current)
        refresh()
    end

    -- Scale + per-element Size are grouped into a single "Size" submenu,
    -- mirroring sui_book_grid.lua's size_group pattern.
    local size_group = {}

    size_group[#size_group + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("clock", pfx) end,
        set          = function(v) Config.setModuleScale(v, "clock", pfx) end,
        refresh      = refresh,
    }
    
    local items = {
        {
            -- Arrange row: manual order (SUI ArrangeList with eye toggle;
            -- classic SortWidget for reorder plus checklist rows).
            text = _lc("Arrange"),
            keep_menu_open = true,
            callback = function()
                local order = getItemOrder(pfx)
                if #order < 2 then return end
                local sort_items = {}
                for _, key in ipairs(order) do
                    sort_items[#sort_items + 1] = {
                        text      = itemLabel(key, _lc),
                        orig_item = key,
                    }
                end
                local function on_save()
                    local new_order = {}
                    for _, item in ipairs(sort_items) do
                        new_order[#new_order + 1] = item.orig_item
                    end
                    saveItemOrder(pfx, new_order)
                    refresh()
                end
                local SortWidget = ctx_menu.SortWidget or require("ui/widget/sortwidget")
                local uim = ctx_menu.UIManager or UIManager
                uim:show(SortWidget:new{
                    title             = _lc("Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = on_save,
                })
            end,
            sui_build = ctx_menu.is_sui and function(ctx, _item)
                local SUIWindow = require("engines/sui_window")
                return SUIWindow.ListRow{
                    title        = _lc("Items"),
                    subtitle     = function()
                        local vis = getVisibleItems(pfx)
                        if #vis == 0 then return _lc("No items selected.") end
                        local names = {}
                        for _, key in ipairs(vis) do
                            names[#names + 1] = itemLabel(key, _lc)
                        end
                        return table.concat(names, "  ·  ")
                    end,
                    inner_w      = ctx.inner_w,
                    item_count   = function() return #getVisibleItems(pfx) end,
                    show_chevron = true,
                    on_tap       = function()
                        local sort_items = {}
                        for _, key in ipairs(getItemOrder(pfx)) do
                            local _key = key
                            local hidden = not isItemVisible(pfx, _key)
                            local item = {
                                text        = itemLabel(_key, _lc),
                                orig_item   = _key,
                                dim_row     = hidden or nil,
                                -- Eye glyph reflects current state: open while
                                -- visible, closed once hidden.
                                toggle_icon = hidden and "hide" or "show",
                            }
                            item.on_toggle = function()
                                local now_hidden = not isItemVisible(pfx, _key)
                                setItemVisible(pfx, _key, now_hidden)
                                local hidden2 = not isItemVisible(pfx, _key)
                                item.dim_row     = hidden2 or nil
                                item.toggle_icon = hidden2 and "hide" or "show"
                                refresh()
                                ctx.repaint()
                            end
                            sort_items[#sort_items + 1] = item
                        end
                        ctx.push("arrange", {
                            title      = _lc("Items"),
                            items      = sort_items,
                            empty_text = _lc("No items."),
                            on_change  = function(items_to_save)
                                local new_order = {}
                                for _, it in ipairs(items_to_save) do
                                    new_order[#new_order + 1] = it.orig_item
                                end
                                saveItemOrder(pfx, new_order)
                                refresh()
                            end,
                        })
                    end,
                }
            end or nil,
        },
    }

    -- Classic menu only: checklist for show/hide (SUI uses the eye toggle
    -- on the Arrange screen above).
    if not ctx_menu.is_sui then
        items[#items + 1] = {
            text           = _lc("Show Clock"),
            checked_func   = function() return isClockEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_ON, isClockEnabled(pfx)) end,
        }
        items[#items + 1] = {
            text           = _lc("Show Date"),
            checked_func   = function() return isDateEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_DATE, isDateEnabled(pfx)) end,
        }
        items[#items + 1] = {
            text           = _lc("Show Battery"),
            checked_func   = function() return isBattEnabled(pfx) end,
            keep_menu_open = true,
            callback       = function() toggle(SETTING_BATTERY, isBattEnabled(pfx)) end,
        }
    end

    local text_opts = {
        mod_id  = M.id,
        elems   = TEXT_ELEMS,
        labels  = { clock = _lc("Clock"), date = _lc("Date"), battery = _lc("Battery") },
        info    = _lc("Size of this text.\n100% is the default size."),
        pfx     = pfx,
        refresh = refresh,
        _lc     = _lc,
    }
    local appearance_extra = {}
    appearance_extra[#appearance_extra + 1] = {
        text_func  = function() return _lc("Clock Style") end,
        value_func = function()
            local style = getClockStyle(pfx)
            if style == "word" then return _lc("Word") end
            if style == "analogue" then return _lc("Analogue") end
            return _lc("Digital")
        end,
        sub_item_table = {
            {
                text         = _lc("Digital") .. "  (12:50)",
                radio        = true,
                checked_func = function() return getClockStyle(pfx) == "digital" end,
                keep_menu_open = true,
                callback     = function() setClockStyle(pfx, "digital"); refresh() end,
            },
            {
                text         = _lc("Word") .. "  (Twelve Fifty)",
                radio        = true,
                checked_func = function() return getClockStyle(pfx) == "word" end,
                keep_menu_open = true,
                callback     = function() setClockStyle(pfx, "word"); refresh() end,
            },
            {
                text         = _lc("Analogue"),
                radio        = true,
                checked_func = function() return getClockStyle(pfx) == "analogue" end,
                keep_menu_open = true,
                callback     = function() setClockStyle(pfx, "analogue"); refresh() end,
            },
        },
    }
    appearance_extra[#appearance_extra + 1] = {
        text_func  = function() return _lc("Alignment") end,
        value_func = function() return alignLabel(getAlignment(pfx), _lc) end,
        separator      = true,
        sub_item_table = {
            {
                text           = _lc("Left"),
                radio          = true,
                checked_func   = function() return getAlignment(pfx) == "left" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, "left"); refresh() end,
            },
            {
                text           = _lc("Center"),
                radio          = true,
                checked_func   = function() return getAlignment(pfx) == "center" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, "center"); refresh() end,
            },
            {
                text           = _lc("Right"),
                radio          = true,
                checked_func   = function() return getAlignment(pfx) == "right" end,
                keep_menu_open = true,
                callback       = function() setAlignment(pfx, "right"); refresh() end,
            },
        },
    }

    if #getVisibleItems(pfx) > 1 then
        appearance_extra[#appearance_extra + 1] = {
            text_func  = function() return _lc("Spacing") end,
            value_func = function() return getItemGapPct(pfx) .. "%" end,
            keep_menu_open = true,
            callback = function()
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager_ = require("ui/uimanager")
                UIManager_:show(SpinWidget:new{
                    title_text    = _lc("Spacing"),
                    info_text     = _lc("Vertical space between items.\n100% is the default spacing."),
                    value         = getItemGapPct(pfx),
                    value_min     = ITEM_GAP_MIN,
                    value_max     = ITEM_GAP_MAX,
                    value_step    = ITEM_GAP_STEP,
                    unit          = "%",
                    ok_text       = _lc("Apply"),
                    cancel_text   = _lc("Cancel"),
                    default_value = ITEM_GAP_DEF,
                    callback      = function(spin)
                        setItemGapPct(pfx, spin.value)
                        refresh()
                    end,
                })
            end,
        }
    end

    -- items[1] is the Items entry; classic show toggles follow when not SUI.
    local item_rows = items
    return Config.buildModuleMenu({
        items = item_rows,
        appearance = {
            size  = size_group,
            text  = text_opts,
            extra = appearance_extra,
        },
    }, ctx_menu)
end

return M
