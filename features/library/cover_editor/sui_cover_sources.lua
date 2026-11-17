-- sui_cover_sources.lua — Simple UI
-- Online cover search: asks Open Library, Google Books and, when enabled,
-- Apple Books for covers of a book, downloads each one, and returns the
-- portrait images found, largest first.
--
-- Each source is queried by ISBN (the exact edition) when the book has one,
-- then by free text. A source that fails, is rate limited or finds nothing is
-- skipped. Downloads are decoded one at a time: the full image only lives
-- long enough to read its size and scale it to a thumbnail, and the file is
-- kept in a cache folder (cleared on every search) for when it is applied.
--
-- Public API
--   CoverSources.isbnOf(file)   -> ISBN string | nil
--   CoverSources.parseIsbn(s)   -> ISBN string | nil (checked)
--   CoverSources.search(opts)   -> { candidate, ... }, cancelled, offline
--     offline: no request reached a server (no network or no internet)
--     opts.query          string    free-text query (title and author)
--     opts.isbn           string?
--     opts.include_apple  bool
--     opts.thumb_w/h      number    thumbnail bounds
--     opts.on_progress    function(text) -> false to cancel
--   candidate = { path, width, height, filesize, source, thumb }
--     thumb is a Blitbuffer owned by the caller
--   CoverSources.clearCache()

local DataStorage = require("datastorage")
local T           = require("ffi/util").template
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local util        = require("util")
local _           = require("infra/sui_i18n").translate

local CoverNet = require("features/library/cover_editor/sui_cover_net")

local CoverSources = {}

local MAX_PER_SOURCE = 4

local function cacheDir()
    return DataStorage:getDataDir() .. "/cache/simpleui/cover_search"
end

function CoverSources.clearCache()
    local dir = cacheDir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
    end
end

local function encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ---------------------------------------------------------------------------
-- ISBN
-- ---------------------------------------------------------------------------

-- The ISBN written in `s` (10 or 13 characters, spaces and hyphens allowed),
-- as its bare characters, when its check digit is right; else nil.
function CoverSources.parseIsbn(s)
    local isbn = s:gsub("[%s%-]", ""):upper()
    local sum = 0
    if isbn:match("^97[89]%d%d%d%d%d%d%d%d%d%d$") then
        for i = 1, 13 do
            sum = sum + tonumber(isbn:sub(i, i)) * (i % 2 == 1 and 1 or 3)
        end
        return sum % 10 == 0 and isbn or nil
    end
    if isbn:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then
        for i = 1, 10 do
            local c = isbn:sub(i, i)
            sum = sum + (c == "X" and 10 or tonumber(c)) * (11 - i)
        end
        return sum % 11 == 0 and isbn or nil
    end
end

-- First ISBN in a document's identifiers: a labelled one, else any bare
-- 13-digit ISBN.
local function isbnFromIdentifiers(identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end
    for value in identifiers:lower():gmatch("isbn[^%dx]*([%dx][%dx%s%-]+)") do
        local isbn = CoverSources.parseIsbn(value)
        if isbn then return isbn end
    end
    for value in identifiers:gmatch("97[89][%d%-]+") do
        local isbn = CoverSources.parseIsbn(value)
        if isbn then return isbn end
    end
end

-- Identifiers stored when the book was opened, else read from the file's
-- metadata (without rendering it).
function CoverSources.isbnOf(file)
    local BookList = require("ui/widget/booklist")
    local identifiers
    if BookList.hasBookBeenOpened(file) then
        local props = BookList.getDocSettings(file):readSetting("doc_props")
        identifiers = props and props.identifiers
    end
    if not identifiers then
        local DocumentRegistry = require("document/documentregistry")
        local ok, props = pcall(function()
            local doc = DocumentRegistry:openDocument(file)
            if not doc then return nil end
            local loaded = not doc.loadDocument or doc:loadDocument(false)
            local result = loaded and doc:getProps() or nil
            doc:close()
            return result
        end)
        identifiers = ok and props and props.identifiers
    end
    return isbnFromIdentifiers(identifiers)
end

-- ---------------------------------------------------------------------------
-- Sources: each returns the cover URLs it found, best match first
-- ---------------------------------------------------------------------------

local function openLibrary(query, isbn)
    local urls = {}
    if isbn then
        -- default=false answers 404 instead of a blank image when there is none.
        urls[#urls + 1] = "https://covers.openlibrary.org/b/isbn/" .. isbn .. "-L.jpg?default=false"
    end
    if query ~= "" then
        local data = CoverNet.getJson("https://openlibrary.org/search.json?q=" .. encode(query)
            .. "&limit=8&fields=cover_i")
        for _i, doc in ipairs(data and type(data.docs) == "table" and data.docs or {}) do
            if #urls >= MAX_PER_SOURCE then break end
            if tonumber(doc.cover_i) then
                urls[#urls + 1] = "https://covers.openlibrary.org/b/id/" .. doc.cover_i .. "-L.jpg"
            end
        end
    end
    return urls
end

-- Largest image a Google Books imageLinks table offers. The thumbnail link
-- serves a larger rendition when its zoom cap and page-curl effect are
-- dropped and a width is requested.
local function googleImage(links)
    if type(links) ~= "table" then return nil end
    local url = links.extraLarge or links.large or links.medium
    if url then
        return (url:gsub("^http:", "https:"):gsub("&edge=curl", ""))
    end
    url = links.small or links.thumbnail or links.smallThumbnail
    if type(url) ~= "string" then return nil end
    url = url:gsub("^http:", "https:"):gsub("&edge=curl", ""):gsub("&zoom=%d", "")
    return url .. "&fife=w1200"
end

local function googleBooks(query, isbn)
    local queries = {}
    if isbn then queries[#queries + 1] = "isbn:" .. isbn end
    if query ~= "" then queries[#queries + 1] = query end
    local urls = {}
    for _i, q in ipairs(queries) do
        local data = CoverNet.getJson("https://www.googleapis.com/books/v1/volumes?q="
            .. encode(q) .. "&maxResults=8")
        for _j, item in ipairs(data and type(data.items) == "table" and data.items or {}) do
            if #urls >= MAX_PER_SOURCE then return urls end
            local url = googleImage(item.volumeInfo and item.volumeInfo.imageLinks)
            if url then urls[#urls + 1] = url end
        end
    end
    return urls
end

-- The artwork link's size segment is rewritten to a large box; the server
-- answers with the largest size it has, up to that box.
local function appleBooks(query, isbn)
    local terms = {}
    if isbn then terms[#terms + 1] = isbn end
    if query ~= "" then terms[#terms + 1] = query end
    local urls = {}
    for _i, term in ipairs(terms) do
        local data = CoverNet.getJson("https://itunes.apple.com/search?media=ebook&limit=8&term="
            .. encode(term))
        for _j, result in ipairs(data and type(data.results) == "table" and data.results or {}) do
            if #urls >= MAX_PER_SOURCE then return urls end
            local art = result.artworkUrl100
            if type(art) == "string" then
                urls[#urls + 1] = (art:gsub("/%d+x%d+bb%.", "/1200x1200bb."))
            end
        end
    end
    return urls
end

local SOURCES = {
    { id = "openlibrary", name = "Open Library", fetch = openLibrary },
    { id = "google",      name = "Google Books", fetch = googleBooks },
    { id = "apple",       name = "Apple Books",  fetch = appleBooks, opt_in = true },
}

-- ---------------------------------------------------------------------------
-- Downloads
-- ---------------------------------------------------------------------------

-- File extension of image data, from its signature.
local function imageExt(data)
    if data:sub(1, 3) == "\xFF\xD8\xFF" then return "jpg" end
    if data:sub(1, 8) == "\x89PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 3) == "GIF" then return "gif" end
end

-- Downloads and decodes one cover; nil when it is not a usable portrait image.
local function fetchCandidate(url, seq, opts, seen)
    local data = CoverNet.get(url)
    local ext = data and imageExt(data)
    if not ext then return nil end
    local hash = require("ffi/sha2").md5(data)
    if seen[hash] then return nil end
    seen[hash] = true

    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not (ok and bb) then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    -- Covers are portrait (or square); wider images are banners or wrong hits.
    if w > h then
        bb:free()
        return nil
    end
    local scale = math.min(opts.thumb_w / w, opts.thumb_h / h, 1)
    local thumb = RenderImage:scaleBlitBuffer(bb,
        math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)))

    local path = cacheDir() .. "/" .. seq .. "." .. ext
    local f = io.open(path, "wb")
    if not (f and f:write(data)) then
        if f then f:close() end
        thumb:free()
        logger.warn("SimpleUI cover search: could not write", path)
        return nil
    end
    f:close()
    return { path = path, width = w, height = h, filesize = #data, thumb = thumb }
end

function CoverSources.search(opts)
    local query = util.trim(opts.query or "")
    local progress = opts.on_progress or function() return true end
    CoverSources.clearCache()
    util.makePath(cacheDir())
    CoverNet.resetAnswered()

    local pending = {}
    for _i, source in ipairs(SOURCES) do
        if not source.opt_in or (source.id == "apple" and opts.include_apple) then
            if progress(T(_("Searching %1"), source.name)) == false then return {}, true end
            local ok, urls = pcall(source.fetch, query, opts.isbn)
            if ok then
                for _j, url in ipairs(urls) do
                    pending[#pending + 1] = { url = url, source = source.name }
                end
            else
                logger.warn("SimpleUI cover search:", source.id, urls)
            end
        end
    end

    local results, seen, seen_url = {}, {}, {}
    local cancelled = false
    for i, item in ipairs(pending) do
        if progress(T(_("Downloading covers %1/%2"), i, #pending)) == false then
            cancelled = true
            break
        end
        if not seen_url[item.url] then
            seen_url[item.url] = true
            local ok, candidate = pcall(fetchCandidate, item.url, i, opts, seen)
            if ok and candidate then
                candidate.source = item.source
                results[#results + 1] = candidate
            elseif not ok then
                logger.warn("SimpleUI cover search:", item.url, candidate)
            end
        end
    end
    table.sort(results, function(a, b) return a.width * a.height > b.width * b.height end)
    return results, cancelled, CoverNet.answered() == 0
end

return CoverSources
