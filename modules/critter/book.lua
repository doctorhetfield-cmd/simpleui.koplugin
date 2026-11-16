-- book.lua — Simple UI
-- The book the Critter module talks about: the one read last, when it is
-- started and not finished.

local lfs = require("libs/libkoreader-lfs")

local Book = {}

local DAY_SECS = 24 * 3600

--- Facts of a book for the phrases, { title, percent, days }: its progress in
--- whole percent and the whole days since `last_read`. nil when the book was
--- not started or is finished. `fraction` is the progress from 0 to 1.
function Book.facts(title, fraction, last_read, now)
    local percent = math.floor((fraction or 0) * 100)
    if percent < 1 or percent > 99 then return nil end
    return {
        title   = title,
        percent = percent,
        days    = math.max(0, math.floor((now - last_read) / DAY_SECS)),
    }
end

--- Facts (see Book.facts) of the book read last, nil when there is none.
function Book.current(now)
    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    local hist = ReadHistory and ReadHistory.hist
    if not hist then return nil end
    local SH = require("modules/module_books_shared")
    for _i, entry in ipairs(hist) do
        if entry.file and not SH.isHiddenEntry(entry)
                and lfs.attributes(entry.file, "mode") == "file" then
            local book = SH.getBookData(entry.file)
            if book.status == "complete" then return nil end
            return Book.facts(book.title, book.percent, entry.time, now)
        end
    end
    return nil
end

return Book
