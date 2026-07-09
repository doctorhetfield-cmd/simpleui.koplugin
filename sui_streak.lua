-- sui_streak.lua — Simple UI
-- Everything about the reading "streak" that isn't a DB query lives here:
-- the shared consecutive-day walk (previously sui_streak_calc.lua) and the
-- Streak "Freeze" mechanic's persisted state + accessors (previously
-- sui_streak_freeze.lua). Merged into one module/one file since the two
-- were always used together and callers already required both under one
-- conceptual umbrella ("the streak system").
--
-- ============================================================================
-- Part 1 — current-streak calculation (formerly sui_streak_calc.lua)
-- ============================================================================
-- Single shared implementation of the "consecutive-day walk" used to derive
-- the CURRENT reading streak length.
--
-- Before this existed, the current-streak number was computed twice, by two
-- structurally different implementations that had to be kept in sync by
-- hand:
--   • module_stats_provider.lua's fetchStreak() — a recursive SQL CTE run
--     inside SQLite, walking page_stat_data directly.
--   • sui_stats_windows.lua's _riGetStreaks() — a Lua loop over dates
--     fetched from page_stat, used by the Reading Insights window.
--
-- Both now fetch only a plain list of distinct active dates from their
-- respective queries (no recursion, no CTE) and hand it to
-- M.computeCurrentDayStreak() here — one implementation, one place to fix
-- bugs, and the only place that needs to know how a "frozen" day (the
-- Freeze mechanic below) merges into the count.
--
-- M.computeCurrentDayStreak() itself has NO dependency on the Freeze state
-- below or any DB access — it is a pure function over whatever date lists
-- its callers hand it, which keeps it trivially testable and keeps the "is
-- freeze mode on, what dates are frozen" policy decisions in the callers.

local SUISettings = require("sui_store")

local M = {}

local function _parseYMD(s)
    if type(s) ~= "string" or #s < 10 then return nil end
    local y = tonumber(s:sub(1, 4))
    local mo = tonumber(s:sub(6, 7))
    local d = tonumber(s:sub(9, 10))
    if not (y and mo and d) then return nil end
    return y, mo, d
end

--- date_str ("YYYY-MM-DD") of the calendar day immediately before date_str.
--- Deliberately mirrors the existing codebase convention (no `hour` field
--- set on the os.time table) used by sui_stats_windows.lua's isConsecDay,
--- for identical behaviour at DST boundaries rather than introducing a
--- second, subtly different convention.
local function _prevDay(date_str)
    local y, mo, d = _parseYMD(date_str)
    if not y then return nil end
    return os.date("%Y-%m-%d", os.time{ year = y, month = mo, day = d } - 86400)
end

-- ---------------------------------------------------------------------------
-- M.computeCurrentDayStreak(active_dates, opts) → integer
-- ---------------------------------------------------------------------------
-- active_dates : array of "YYYY-MM-DD" strings — distinct calendar days with
--                real reading activity (duration > 0). Order does not
--                matter; this function builds its own lookup set.
-- opts (optional) :
--   frozen_dates : array of "YYYY-MM-DD" strings to merge into the activity
--                  set before walking, so a frozen day counts for
--                  continuity exactly like a real one, without the caller
--                  ever writing anything into page_stat. Pass nil/{} to
--                  compute the "real" streak with no freeze influence at
--                  all (this is what "Real streak only" mode must do).
--   today, yesterday : "YYYY-MM-DD" overrides — mainly for tests. Default
--                  to the actual current calendar day/its predecessor.
--
-- Returns the number of consecutive active days ending at today or
-- yesterday (0 if neither today nor yesterday is active — i.e. the streak
-- is broken, matching the existing "today OR yesterday must be active or
-- the streak is 0" semantics both prior implementations already used).
-- ---------------------------------------------------------------------------
function M.computeCurrentDayStreak(active_dates, opts)
    opts = opts or {}

    local set = {}
    for _, d in ipairs(active_dates or {}) do set[d] = true end
    if opts.frozen_dates then
        for _, d in ipairs(opts.frozen_dates) do set[d] = true end
    end

    local today     = opts.today     or os.date("%Y-%m-%d")
    local yesterday = opts.yesterday or _prevDay(today)

    local cur
    if set[today] then
        cur = today
    elseif yesterday and set[yesterday] then
        cur = yesterday
    else
        return 0
    end

    local streak = 0
    while cur and set[cur] do
        streak = streak + 1
        cur = _prevDay(cur)
    end
    return streak
end

-- ============================================================================
-- Part 2 — Streak "Freeze" mechanic (formerly sui_streak_freeze.lua)
-- ============================================================================
-- Persisted state + accessors for the Streak "Freeze" mechanic.
--
-- Storage: all keys live in the existing SUISettings store (sui_store.lua),
-- alongside every other SimpleUI preference — no new file, no G_reader_settings
-- keys, and nothing is ever written into KOReader's own `page_stat` table.
--
--   simpleui_streak_mode                 — "freezes" (default) | "real"
--   simpleui_streak_freezes_available    — int, freezes banked and unspent
--   simpleui_streak_frozen_dates         — array of "YYYY-MM-DD" strings
--   simpleui_streak_freeze_time_secs     — int, cumulative seconds toward
--                                           the next time-based freeze (mod 7200)
--   simpleui_streak_freeze_watermark     — int, highest streak length already
--                                           rewarded a day-based freeze
--
-- This is the single gate for "is the freeze mechanic active right now" —
-- every public function below is a no-op / returns a zero-ish value when
-- streak_mode == "real", so callers (earning hooks, computeCurrentDayStreak
-- above, the Streak Manager window) never need their own mode checks.
--
-- Mirrors the lazy-singleton style used elsewhere in the plugin (e.g.
-- sui_config.lua's M.getBookInfoManager()): this file itself is the
-- singleton (required once, Lua's module cache does the rest), and the one
-- genuinely lazy piece — seeding the watermark from the user's current
-- streak — is deferred to first read rather than done at load time.

local KEY_MODE            = "simpleui_streak_mode"
local KEY_FREEZES         = "simpleui_streak_freezes_available"
local KEY_FROZEN_DATES    = "simpleui_streak_frozen_dates"
local KEY_TIME_PROGRESS   = "simpleui_streak_freeze_time_secs"
local KEY_WATERMARK       = "simpleui_streak_freeze_watermark"
local KEY_LAST_TOTAL_SECS = "simpleui_streak_freeze_last_total_secs"

local FREEZE_TIME_THRESHOLD_SECS = 7200  -- 2 hours
local FREEZE_DAY_INTERVAL        = 5     -- +1 freeze every 5 consecutive days

-- Exposed read-only so callers (e.g. the Streak Manager window's progress
-- display) show the same numbers this module actually grants on, instead of
-- hardcoding a second copy that could drift out of sync.
M.FREEZE_TIME_THRESHOLD_SECS = FREEZE_TIME_THRESHOLD_SECS
M.FREEZE_DAY_INTERVAL        = FREEZE_DAY_INTERVAL

-- ---------------------------------------------------------------------------
-- Mode
-- ---------------------------------------------------------------------------

--- "freezes" (default) or "real".
function M.getStreakMode()
    local v = SUISettings:get(KEY_MODE)
    if v == "real" or v == "freezes" then return v end
    return "freezes"
end

function M.setStreakMode(mode)
    if mode ~= "real" and mode ~= "freezes" then return end
    SUISettings:set(KEY_MODE, mode)
end

function M.isFreezeModeEnabled()
    return M.getStreakMode() == "freezes"
end

-- ---------------------------------------------------------------------------
-- Freezes available
-- ---------------------------------------------------------------------------

--- Number of unspent freezes. Always 0 in "real" mode — but note the
--- underlying counter is NOT cleared when the mode is switched off, so
--- toggling back to "freezes" later restores whatever was banked (see
--- module docstring / Phase 5 QA checklist: mode switching must not wipe
--- freezes_available or frozen_dates).
function M.getFreezesAvailable()
    if not M.isFreezeModeEnabled() then return 0 end
    return SUISettings:get(KEY_FREEZES) or 0
end

--- Grant n additional freezes (no-op when freeze mode is off or n <= 0).
function M.addFreezes(n)
    if not M.isFreezeModeEnabled() then return end
    n = tonumber(n) or 0
    if n <= 0 then return end
    local cur = SUISettings:get(KEY_FREEZES) or 0
    SUISettings:set(KEY_FREEZES, cur + n)
end

-- ---------------------------------------------------------------------------
-- Frozen dates
-- ---------------------------------------------------------------------------

--- Spend one freeze to cover "yesterday" (the single day immediately before
--- today) — the only day a freeze can ever repair. Returns true on success,
--- false when freeze mode is off, no freezes are available, or yesterday is
--- already frozen. Never touches any day other than yesterday: freezes are
--- deliberately not a multi-day gap-repair tool.
function M.spendFreezeForYesterday()
    if not M.isFreezeModeEnabled() then return false end
    local avail = SUISettings:get(KEY_FREEZES) or 0
    if avail <= 0 then return false end

    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
    if M.isDateFrozen(yesterday) then return false end

    local dates = SUISettings:get(KEY_FROZEN_DATES) or {}
    dates[#dates + 1] = yesterday
    SUISettings:set(KEY_FROZEN_DATES, dates)
    SUISettings:set(KEY_FREEZES, avail - 1)
    return true
end

--- Is date_str ("YYYY-MM-DD") covered by a spent freeze? Always false in
--- "real" mode.
function M.isDateFrozen(date_str)
    if not M.isFreezeModeEnabled() then return false end
    if not date_str then return false end
    local dates = SUISettings:get(KEY_FROZEN_DATES) or {}
    for _, d in ipairs(dates) do
        if d == date_str then return true end
    end
    return false
end

--- All frozen dates with start_str <= d <= end_str (either bound optional),
--- sorted ascending. Empty in "real" mode. start_str/end_str are "YYYY-MM-DD"
--- strings — plain lexicographic comparison is correct for that format.
function M.getFrozenDatesInRange(start_str, end_str)
    if not M.isFreezeModeEnabled() then return {} end
    local dates = SUISettings:get(KEY_FROZEN_DATES) or {}
    local out = {}
    for _, d in ipairs(dates) do
        if (not start_str or d >= start_str) and (not end_str or d <= end_str) then
            out[#out + 1] = d
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Time-based earning (+1 freeze / 2h cumulative reading time)
-- ---------------------------------------------------------------------------

--- Current progress in seconds toward the next time-based freeze (always
--- < FREEZE_TIME_THRESHOLD_SECS between calls to addFreezeTimeProgress).
--- Always 0 in "real" mode.
function M.getFreezeTimeProgress()
    if not M.isFreezeModeEnabled() then return 0 end
    return SUISettings:get(KEY_TIME_PROGRESS) or 0
end

--- Add `secs` of reading time toward the next time-based freeze. Every time
--- the running total crosses FREEZE_TIME_THRESHOLD_SECS (7200s / 2h), grants
--- one freeze and subtracts the threshold (not a reset to 0), so a single
--- long session can grant more than one freeze at once. No-op when freeze
--- mode is off or secs <= 0. Returns the number of freezes granted (0+).
function M.addFreezeTimeProgress(secs)
    if not M.isFreezeModeEnabled() then return 0 end
    secs = tonumber(secs) or 0
    if secs <= 0 then return 0 end

    local progress = (SUISettings:get(KEY_TIME_PROGRESS) or 0) + secs
    local granted = 0
    while progress >= FREEZE_TIME_THRESHOLD_SECS do
        progress = progress - FREEZE_TIME_THRESHOLD_SECS
        granted = granted + 1
    end
    SUISettings:set(KEY_TIME_PROGRESS, progress)
    if granted > 0 then M.addFreezes(granted) end
    return granted
end

--- Phase 1's time-based earning hook, in terms of a value the stats pipeline
--- already computes: `total_secs` (all-time cumulative reading seconds, see
--- module_stats_provider.lua's SP.get()). Call this every time SP.get()
--- freshly recomputes total_secs from the DB, passing that value straight
--- through — this function derives the *delta* since the last call itself
--- (via a persisted baseline) and feeds only the delta to
--- addFreezeTimeProgress, so callers never need to track deltas themselves.
---
--- No-op when freeze mode is off. On the very first call (no baseline
--- stored yet), seeds the baseline to total_secs WITHOUT granting anything
--- for all the reading time accumulated before this feature existed — same
--- "no retroactivity" principle as the day-based watermark. Also guards
--- against total_secs appearing to go backwards (e.g. a transient DB error
--- upstream returning 0): in that case the baseline is simply reset to the
--- new value with no progress added, rather than corrupting the progress
--- counter with a spurious negative delta.
---
--- Returns the number of freezes granted (0+).
function M.advanceFreezeTimeFromTotalSecs(total_secs)
    if not M.isFreezeModeEnabled() then return 0 end
    total_secs = tonumber(total_secs) or 0

    local last = SUISettings:get(KEY_LAST_TOTAL_SECS)
    if last == nil then
        SUISettings:set(KEY_LAST_TOTAL_SECS, total_secs)
        return 0
    end

    if total_secs <= last then
        -- No new reading time (or an upstream hiccup reported a lower value
        -- than before) — just re-baseline, add nothing.
        if total_secs < last then
            SUISettings:set(KEY_LAST_TOTAL_SECS, total_secs)
        end
        return 0
    end

    local delta = total_secs - last
    SUISettings:set(KEY_LAST_TOTAL_SECS, total_secs)
    return M.addFreezeTimeProgress(delta)
end

-- ---------------------------------------------------------------------------
-- Day-based earning watermark (+1 freeze / 5 consecutive days)
-- ---------------------------------------------------------------------------

--- Highest streak length already rewarded a day-based freeze. On its very
--- first read (nil in storage — i.e. this is the first run of this code for
--- an existing or new install), lazily seeds itself to the user's *current*
--- streak length rather than 0, so existing long streaks don't retroactively
--- grant a burst of freezes for days already lived before this feature
--- existed ("no retroactivity" — freezes_available itself is unaffected and
--- simply starts at 0 via getFreezesAvailable's default).
---
--- Uses SP.getStale() (cached/disk snapshot, see module_stats_provider.lua)
--- rather than opening a DB connection here — this module has no business
--- doing its own stats DB access, and a slightly-stale seed is harmless
--- since it only affects the one-time initial watermark.
function M.getFreezeDaysWatermark()
    local v = SUISettings:get(KEY_WATERMARK)
    if v ~= nil then return v end

    local seed = 0
    local ok, SP = pcall(require, "desktop_modules/module_stats_provider")
    if ok and SP and SP.getStale then
        local ok2, stale = pcall(SP.getStale)
        if ok2 and stale and stale.streak then
            seed = tonumber(stale.streak) or 0
        end
    end
    SUISettings:set(KEY_WATERMARK, seed)
    return seed
end

function M.setFreezeDaysWatermark(n)
    n = tonumber(n) or 0
    SUISettings:set(KEY_WATERMARK, n)
end

--- Convenience for Phase 1's day-based earning hook: given the current
--- streak length, grants a freeze if it strictly exceeds the watermark AND
--- is a multiple of FREEZE_DAY_INTERVAL (5), then updates the watermark to
--- the current streak length regardless of whether a grant happened — so a
--- streak sitting at the same multiple of 5 across several days only grants
--- once, and a broken-then-rebuilt streak is evaluated correctly from
--- scratch. No-op (returns false) when freeze mode is off.
function M.maybeGrantDayFreeze(current_streak)
    if not M.isFreezeModeEnabled() then return false end
    current_streak = tonumber(current_streak) or 0
    local watermark = M.getFreezeDaysWatermark()

    local granted = false
    if current_streak > watermark
            and current_streak % FREEZE_DAY_INTERVAL == 0
            and current_streak > 0 then
        M.addFreezes(1)
        granted = true
    end
    if current_streak ~= watermark then
        M.setFreezeDaysWatermark(current_streak)
    end
    return granted
end

return M
