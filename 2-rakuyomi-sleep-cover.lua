--[[
Sleep screen: show the manga's cover instead of page 1 of the chapter.

KOReader's "cover" sleep screen shows the first page of a CBZ, so a Rakuyomi
chapter gets its page 1 rather than the series art.

Chapter files are named base64url(sha256(source_id .. manga_id .. chapter_id))
so the filename cannot be mapped back to a manga. The route used here is:

    chapter.cbz -> <Series> from ComicInfo.xml
                -> manga_informations row (source_id, manga_id)
                -> base64url(sha256(source_id .. manga_id))
                -> cover file named after that hash

Sources hand out small thumbnails (280x400 is common), so covers are fetched
from MangaDex in the background when a chapter is opened, and Rakuyomi's
low-res poster is used whenever that can't be done.

Where possible the cover shown is the one for the volume the chapter is in.
Most sources don't record the volume in the chapter file (ComicInfo.xml says
Volume 0), so it's looked up from the chapter number through MangaDex's
aggregate endpoint. That only holds when the numbering agrees, so a chapter
number is used only when it's a whole integer: sources that split a chapter
into parts write 1.3 or 0.05, which would match the wrong volume or none.
Those keep the series cover.

The next volume's cover is saved too, so chapters Rakuyomi downloads ahead
have their cover when they're read offline. That's one volume ahead only:
later volumes show the series cover until they're opened with wifi on.

Cover lookup order, first hit wins:
    .posters-hires/<hash>.v<volume>.jpg   volume cover for this chapter
    .posters-hires/<hash>.jpg / .png      series cover
    .posters/<hash>.jpg                   Rakuyomi's own low-res poster

Anything larger than the panel is downscaled once into .posters-hires/.fit.

Getting the cover onto the sleep screen: stock Screensaver:setup runs its own
checks first (books excluded from the sleep screen, finished or on-hold books,
the file browser setting), then asks BookInfo:getCoverImage for the cover.
While setup runs for type "cover", that call is answered with the manga cover
when a Rakuyomi chapter is open or is lastfile. The rest stays stock, so the
sleep screen frees the image when it closes, and when a manga cover is found
the last real book isn't opened just to have its cover thrown away. Other sleep
screen types, including "Show custom image or cover", are left alone.

Stock only asks for a cover when lastfile exists. With 2-manga-no-history.lua
that's the last real book, so if none has been opened yet the sleep screen
shows a random image instead.

MangaDex's API is run by a non-profit on limited hardware, so their stated
requirements are honoured here: a genuine identifying User-Agent, requests
paced under the 5 req/s per-IP allowance, one fetch at a time (a lock
directory in .posters-hires), and a hard stop with a persisted cooldown on 429
or 403 rather than retrying into an IP ban. Covers are cached on disk and
never re-fetched. A lookup that doesn't get what it needs (no match, no cover
for that volume, a chapter not in a volume yet, a failed connection) is tried
at most three times, at least a day apart, and then left alone for 30 days.
Tries are kept in .posters-hires/.fetch-tries, and deleting it resets them.
Per their Acceptable Use Policy, MangaDex is the source of this cover art.

Needs sleep screen type "Show book cover on sleep screen". Any failure falls
back to stock behaviour. Install to koreader/patches/.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local DataStorage = require("datastorage")
local Device = require("device")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local Screen = Device.screen
local Screensaver = require("ui/screensaver")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local RAKUYOMI_DIR = DataStorage:getDataDir() .. "/rakuyomi"
local DB_PATH      = RAKUYOMI_DIR .. "/database.db"
local DOWNLOADS    = RAKUYOMI_DIR .. "/downloads"

-- Rakuyomi's cover cache. It rewrites this, so don't put anything here.
local POSTER_DIR = DOWNLOADS .. "/.posters"
-- Fetched covers and the chapter/volume maps. Safe to add your own files to.
local HIRES_DIR  = DOWNLOADS .. "/.posters-hires"
-- Panel-sized copies, generated on demand. Safe to delete.
local FIT_DIR    = HIRES_DIR .. "/.fit"

-- E-ink shows 16 grey levels, so JPEG artefacts invisible at 80 stay invisible;
-- going higher just costs bytes and decode time.
local JPEG_QUALITY = 80
local TAG = "rakuyomi-sleep-cover:"

-- Seconds after a chapter opens before fetching, so opening stays responsive.
local FETCH_DELAY = 8

-- MangaDex guarantees 5 requests/second per IP. Stay well under it: going over
-- earns a 429, and continuing to send while throttled earns an IP ban.
local MIN_REQUEST_INTERVAL = 0.3
-- How long to stay away after a 429 or 403 that doesn't say when to return.
local DEFAULT_COOLDOWN = 3600

-- Held by the process doing a fetch. A directory, because mkdir either creates
-- it or fails, so two processes can't both take it.
local LOCK_DIR = HIRES_DIR .. "/.fetch-lock"
-- socketutil's timeouts cap a whole fetch at about 3.5 minutes, so a lock older
-- than this was left by a process that was killed before it could remove it.
local LOCK_STALE_AFTER = 600

-- A fetch that doesn't get what it needs (no match, no cover for that volume,
-- a dead connection) would otherwise run again on every open and use battery
-- for nothing. The same lookup is tried at most MAX_TRIES times, RETRY_AFTER
-- apart.
local MAX_TRIES = 3
local RETRY_AFTER = 24 * 3600
-- Once the last try is this old it starts over, in case MangaDex has added
-- the cover since. Older entries are dropped from the file.
local FORGET_AFTER = 30 * 24 * 3600

-- chapter path -> { series = , chapter = }, or false once looked up and absent
local info_cache = {}
-- hash -> { mtime = , map = { [chapter] = volume } }, from the .volmap files
local volmap_cache = {}

local byte = string.byte

local function log(...) logger.info(TAG, ...) end
local function warn(...) logger.warn(TAG, ...) end

local function isFile(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

--------------------------------------------------------------------------
-- File naming. Everything that touches a cover path goes through here.
--------------------------------------------------------------------------

-- Same hash the Rust backend uses to name poster files. sha2 is a 5,600-line
-- pure-Lua module, so it's loaded on first use rather than at startup.
local function coverHash(source_id, manga_id)
    local sha2 = require("ffi/sha2")
    local digest = sha2.hex_to_bin(sha2.sha256(source_id .. manga_id))
    return (sha2.bin_to_base64(digest)
        :gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- Series cover when volume is nil, that volume's cover otherwise. Returns the
-- path without extension; covers may be .jpg or .png.
local function coverBase(hash, volume)
    if volume then
        return HIRES_DIR .. "/" .. hash .. ".v" .. volume
    end
    return HIRES_DIR .. "/" .. hash
end

local function volmapPath(hash)
    return HIRES_DIR .. "/" .. hash .. ".volmap"
end

local function stockPath(hash)
    return POSTER_DIR .. "/" .. hash .. ".jpg"
end

-- Written by the child when MangaDex throttles or blocks us, holding the unix
-- time to stay away until. Read by the parent before it bothers forking.
local function cooldownPath()
    return HIRES_DIR .. "/.mangadex-cooldown"
end

local function cooldownRemaining()
    local f = io.open(cooldownPath(), "r")
    if not f then return 0 end
    local until_time = tonumber(f:read("*l") or "")
    f:close()
    return until_time and math.max(0, until_time - os.time()) or 0
end

-- "count last_time key" lines, one for each thing a fetch was started for.
-- Only the parent reads and writes it.
local function triesPath()
    return HIRES_DIR .. "/.fetch-tries"
end

-- True while another fetch holds the lock. Clears a stale one.
local function fetchLocked()
    local taken_at = lfs.attributes(LOCK_DIR, "modification")
    if not taken_at then return false end
    if os.time() - taken_at < LOCK_STALE_AFTER then return true end
    lfs.rmdir(LOCK_DIR)
    return false
end

local function existingImage(base)
    for _, ext in ipairs({ ".jpg", ".png" }) do
        if isFile(base .. ext) then return base .. ext end
    end
    return nil
end

--------------------------------------------------------------------------
-- Chapter file -> series and chapter number
--------------------------------------------------------------------------

local XML_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function unescapeXml(s)
    s = s:gsub("&#(%d+);", function(n)
        local code = tonumber(n)
        return (code and code < 256) and string.char(code) or ""
    end)
    return (s:gsub("&(%a+);", function(e)
        return XML_ENTITIES[e] or ("&" .. e .. ";")
    end))
end

-- Only whole chapter numbers are usable. A source that splits a chapter into
-- parts writes 1.1, 1.2, 0.05 and so on, which won't line up with MangaDex's
-- numbering, and a wrong volume cover is worse than the series one.
local function wholeChapter(number)
    local num = tonumber(number)
    if not num or num < 0 or num ~= math.floor(num) then return nil end
    return string.format("%d", num)
end

-- Rakuyomi writes ComicInfo.xml as the first zip entry with no compression, so
-- the tags are readable in the first few KB without unzipping anything.
local function infoFromCbz(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(8192)
    f:close()
    if not head then return nil end

    local series = head:match("<Series>(.-)</Series>")
    if not series or series == "" then return nil end

    return {
        series = unescapeXml(series),
        chapter = wholeChapter(head:match("<Number>(.-)</Number>")),
    }
end

local function infoFor(chapter_path)
    local cached = info_cache[chapter_path]
    if cached ~= nil then return cached or nil end

    local info = infoFromCbz(chapter_path)
    info_cache[chapter_path] = info or false
    if not info then
        logger.dbg(TAG, "no <Series> in", chapter_path)
    end
    return info
end

--------------------------------------------------------------------------
-- Series -> database rows -> cover on disk
--------------------------------------------------------------------------

-- Every row filed under this title. A series can appear more than once when
-- it's available from several sources.
local function rowsForSeries(series)
    local conn = SQ3.open(DB_PATH, "ro")
    if not conn then return {} end

    local ok, rows = pcall(function()
        local stmt = conn:prepare([[
            SELECT source_id, manga_id, COALESCE(cover_url, '')
            FROM manga_informations WHERE title = ?]])
        local res = stmt:reset():bind(series):resultset()
        stmt:close()

        local out = {}
        if res and res[1] then
            for i = 1, #res[1] do
                out[#out + 1] = {
                    hash = coverHash(res[1][i], res[2][i]),
                    cover_url = res[3][i],
                }
            end
        end
        return out
    end)

    pcall(function() conn:close() end)
    if not ok then
        warn("db lookup failed:", rows)
        return {}
    end
    return rows
end

-- The volume after this one, out of the volumes that have chapters in the map.
-- Compared as numbers, because MangaDex volumes skip (1, 2, 4) and have
-- decimals (1, 1.5, 2), so adding 1 would miss them.
local function nextVolume(map, volume)
    local current = tonumber(volume)
    if not current then return nil end

    local best, best_num
    for _, v in pairs(map) do
        local num = tonumber(v)
        -- The same number can be written two ways ("2", "2.0"), and pairs goes
        -- in a different order over the map file than over the JSON. Taking
        -- the smaller string keeps the fetch and the check before it agreeing.
        if num and num > current and (not best_num or num < best_num
                or (num == best_num and v < best)) then
            best, best_num = v, num
        end
    end
    return best
end

-- Reads the "chapter volume" lines the fetch wrote, so the sleep path can
-- resolve a volume with no network. Cached by file timestamp, so a map
-- rewritten by a background fetch is picked up automatically.
local function volmapFor(hash)
    local path = volmapPath(hash)
    local mtime = lfs.attributes(path, "modification") or 0
    local cached = volmap_cache[hash]

    if not cached or cached.mtime ~= mtime then
        local map = {}
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local ch, volume = line:match("^(%S+)%s+(%S+)$")
                if ch then map[ch] = volume end
            end
            f:close()
        end
        cached = { mtime = mtime, map = map }
        volmap_cache[hash] = cached
    end
    return cached.map
end

local function volumeFor(hash, chapter)
    if not chapter then return nil end
    return volmapFor(hash)[chapter]
end

-- This chapter's own volume cover and nothing else. The sleep path tries it
-- before falling back to the series cover.
local function volumeCover(hash, chapter)
    local volume = volumeFor(hash, chapter)
    return volume and existingImage(coverBase(hash, volume)) or nil
end

-- This chapter's volume cover, and the next volume's when the map has one.
-- The fetch runs until both are on disk, so chapters downloaded ahead have
-- their cover offline.
local function volumeCoversOnDisk(hash, chapter)
    if not volumeCover(hash, chapter) then return false end
    local map = volmapFor(hash)
    local next_volume = nextVolume(map, map[chapter])
    return not next_volume or existingImage(coverBase(hash, next_volume)) ~= nil
end

local function seriesCover(hash)
    return existingImage(coverBase(hash))
end

-- Best cover across every source, hi-res before low-res. Checking all rows
-- for hi-res first matters: otherwise a stock poster on the first row would
-- beat a fetched cover on the second.
local function coverForInfo(info)
    local rows = rowsForSeries(info.series)
    for _, row in ipairs(rows) do
        local path = volumeCover(row.hash, info.chapter) or seriesCover(row.hash)
        if path then return path end
    end
    for _, row in ipairs(rows) do
        if isFile(stockPath(row.hash)) then return stockPath(row.hash) end
    end
    return nil
end

--------------------------------------------------------------------------
-- Downscaling oversized covers
--------------------------------------------------------------------------

-- Dimensions from a JPEG SOF marker, without decoding the image.
local function jpegDims(head)
    local i, n = 3, #head
    while i < n - 8 do
        if byte(head, i) ~= 0xFF then
            i = i + 1
        else
            local marker = byte(head, i + 1)
            -- standalone markers carry no length field
            if marker == 0xD8 or marker == 0xD9 or marker == 0x01
                    or (marker >= 0xD0 and marker <= 0xD7) then
                i = i + 2
            else
                -- SOF0..SOF15, excluding the DHT/JPG/DAC markers in that range
                if marker >= 0xC0 and marker <= 0xCF
                        and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    return byte(head, i + 7) * 256 + byte(head, i + 8),
                           byte(head, i + 5) * 256 + byte(head, i + 6)
                end
                i = i + 2 + (byte(head, i + 2) * 256 + byte(head, i + 3))
            end
        end
    end
end

-- Dimensions from a PNG IHDR chunk, which is always at a fixed offset.
local function pngDims(head)
    if head:sub(2, 4) ~= "PNG" then return end
    local function u32(o)
        return byte(head, o) * 16777216 + byte(head, o + 1) * 65536
             + byte(head, o + 2) * 256 + byte(head, o + 3)
    end
    return u32(17), u32(21)
end

local function imageDims(path)
    local f = io.open(path, "rb")
    if not f then return end
    local head = f:read(131072)
    f:close()
    if not head or #head < 24 then return end

    if byte(head, 1) == 0xFF and byte(head, 2) == 0xD8 then
        return jpegDims(head)
    end
    return pngDims(head)
end

-- Size that fits inside max_w x max_h keeping the aspect ratio, or nil if it
-- already fits. Never enlarges.
local function fitDims(w, h, max_w, max_h)
    local scale = math.min(max_w / w, max_h / h)
    if scale >= 1 then return nil end
    return math.floor(w * scale + 0.5), math.floor(h * scale + 0.5)
end

-- On a grayscale panel the colour is thrown away at display time, so don't
-- store it: a single-channel JPEG is roughly half the size and decodes faster.
-- BlitBuffer:writeToFile always writes a JPEG as RGB, but the encoder under it
-- takes a subsampling mode, and TurboJPEG's TJSAMP_GRAY turns RGB input into a
-- one-component JPEG. Falls back to the normal path if anything in that
-- lower-level route fails, so a colour device or an older base is unaffected.
local function writeCover(bb, dest)
    if not Device:hasColorScreen() then
        local ok = pcall(function()
            local ffi = require("ffi")
            local Jpeg = require("ffi/jpeg")
            require("ffi/turbojpeg_h")
            local dump, channels = bb:getBufferData()
            local encoded, err = Jpeg.encodeToFile(dest,
                ffi.cast("uint8_t*", dump.data), dump.w, dump.h, channels,
                JPEG_QUALITY, dump.stride, ffi.C.TJSAMP_GRAY)
            if dump ~= bb then dump:free() end
            assert(encoded, err)
        end)
        if ok then return true end
    end
    return bb:writeToFile(dest, "jpg", JPEG_QUALITY)
end

-- Web covers run to 3000px and up, and KOReader decodes the whole file on every
-- wake. Scale once, keep the result, and leave the original alone so it can be
-- redone if it's replaced.
local function fittedCover(path)
    local stem = (path:match("([^/]+)$"):gsub("%.%w+$", ""))
    local dest = FIT_DIR .. "/" .. stem .. ".jpg"

    -- Steady state is two stats and nothing else.
    local dest_time = lfs.attributes(dest, "modification")
    local src_time = lfs.attributes(path, "modification")
    if dest_time and src_time and dest_time >= src_time then
        return dest
    end

    local w, h = imageDims(path)
    if not w or w == 0 or h == 0 then return path end

    local fit_w, fit_h = fitDims(w, h, Screen:getWidth(), Screen:getHeight())
    if not fit_w then return path end

    lfs.mkdir(FIT_DIR)
    local bb = RenderImage:renderImageFile(path, false, fit_w, fit_h)
    if not bb then
        warn("could not decode", path)
        return path
    end

    local ok = writeCover(bb, dest)
    pcall(function() bb:free() end)

    if ok and isFile(dest) then
        log("fitted", w .. "x" .. h, "to", fit_w .. "x" .. fit_h)
        return dest
    end
    return path
end

--------------------------------------------------------------------------
-- Interpreting MangaDex responses. Pure functions on decoded JSON.
--------------------------------------------------------------------------

local function normalise(s)
    return (s:lower():gsub("[^%w]+", ""))
end

-- Rakuyomi's stored URL gives away the manga id outright when the source is
-- MangaDex, skipping the search and its guesswork.
local function mangaIdFromUrl(url)
    return url and url:match("uploads%.mangadex%.org/covers/([^/]+)/")
end

-- Does any title or alternate title on a search result match this one? Without
-- this a search for "Mobile Suit Gundam Thunderbolt" cheerfully returns
-- "Gundam Wing x Code Geass", and a wrong cover is worse than a small one.
local function entryMatchesTitle(entry, title)
    local want = normalise(title)
    local attrs = entry.attributes or {}
    for _, name in pairs(attrs.title or {}) do
        if normalise(name) == want then return true end
    end
    for _, alt in ipairs(attrs.altTitles or {}) do
        for _, name in pairs(alt) do
            if normalise(name) == want then return true end
        end
    end
    return false
end

-- chapter number -> volume, from an /aggregate response. "none" holds chapters
-- with no volume assigned and is skipped.
local function volmapFromAggregate(res)
    local map = {}
    for volume, entry in pairs(res.volumes or {}) do
        if volume ~= "none" and type(entry) == "table" then
            for ch in pairs(entry.chapters or {}) do
                map[ch] = volume
            end
        end
    end
    return map
end

-- volume -> cover filename from a /cover response, plus the filename to use as
-- the series cover: volume 1's if it has one, else the first listed.
local function coversFromList(res)
    local by_volume, first = {}, nil
    for _, entry in ipairs(res.data or {}) do
        local attrs = entry.attributes or {}
        if attrs.fileName then
            first = first or attrs.fileName
            if type(attrs.volume) == "string" and attrs.volume ~= "" then
                by_volume[attrs.volume] = attrs.fileName
            end
        end
    end
    return by_volume, by_volume["1"] or first
end

--------------------------------------------------------------------------
-- Fetching covers
--------------------------------------------------------------------------

-- Everything in here runs in a forked child, so a slow or dead connection can't
-- touch the UI. The child inherits the parent's memory, so the helpers above
-- and the paths are all available.
local function fetchInChild(series, chapter, cover_url, hash)
    local JSON = require("json")
    local http = require("socket.http")
    local socket = require("socket")
    -- Requiring socketutil is what makes the timeouts bite: it monkey-patches
    -- socket.tcp so they apply to HTTPS too, and sets a descriptive UserAgent.
    local socketutil = require("socketutil")
    local util = require("util")

    local API = "https://api.mangadex.org"
    local UPLOADS = "https://uploads.mangadex.org/covers/"

    -- MangaDex requires a User-Agent that isn't spoofed. KOReader's already
    -- names itself and its version; add what's actually making the request.
    local USER_AGENT = socketutil.USER_AGENT .. " rakuyomi-sleep-cover"

    local last_request = 0
    local throttled = false

    -- Persist how long to stay away, so a restart doesn't wipe the backoff.
    -- X-RateLimit-Retry-After is a unix timestamp when MangaDex sends it.
    local function startCooldown(headers)
        local retry_after = tonumber(headers and headers["x-ratelimit-retry-after"])
        local until_time = retry_after or (os.time() + DEFAULT_COOLDOWN)
        local f = io.open(cooldownPath(), "w")
        if f then
            f:write(tostring(until_time), "\n")
            f:close()
        end
        warn("throttled by MangaDex, backing off until", os.date("%c", until_time))
    end

    local function get(url, block, total)
        if throttled then return nil end

        -- Space requests out rather than firing them back to back.
        local since = socket.gettime() - last_request
        if since < MIN_REQUEST_INTERVAL then
            socket.sleep(MIN_REQUEST_INTERVAL - since)
        end
        last_request = socket.gettime()

        socketutil:set_timeout(block, total)
        local sink = {}
        -- table_sink, not ltn12.sink.table: only this one honours total_timeout
        -- once data has started arriving.
        local code, headers = socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = { ["user-agent"] = USER_AGENT },
            sink = socketutil.table_sink(sink),
        })
        socketutil:reset_timeout()

        -- 429 is the rate limit, 403 is the ban that follows ignoring it.
        -- Either way stop completely: sending more is what escalates it.
        if code == 429 or code == 403 then
            throttled = true
            startCooldown(headers)
            return nil
        end
        if code ~= 200 then return nil end
        return table.concat(sink)
    end

    local function getJson(url)
        local body = get(url, socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT)
        if not body then return nil end
        local ok, res = pcall(JSON.decode, body)
        return ok and res or nil
    end

    -- Downloads an image to base + the right extension. Refuses anything that
    -- isn't JPEG or PNG so an error page can't end up as a cover.
    local function saveImage(url, base)
        local data = get(url, socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT)
        if not data or #data < 10240 then return false end

        local ext
        if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then ext = ".jpg"
        elseif data:sub(2, 4) == "PNG" then ext = ".png"
        else return false end

        local dest = base .. ext
        local f = io.open(dest .. ".part", "wb")
        if not f then return false end
        f:write(data)
        f:close()
        os.rename(dest .. ".part", dest)
        log("saved", dest)
        return true
    end

    local function searchMangaId(title)
        local res = getJson(API .. "/manga?limit=5&title=" .. util.urlEncode(title))
        for _, entry in ipairs(res and res.data or {}) do
            if entryMatchesTitle(entry, title) then return entry.id end
        end
        return nil
    end

    local function writeVolmap(map)
        local f = io.open(volmapPath(hash), "w")
        if not f then return end
        for ch, volume in pairs(map) do
            f:write(ch, " ", volume, "\n")
        end
        f:close()
    end

    -- 1. Which manga is this on MangaDex?
    local manga_id = mangaIdFromUrl(cover_url) or searchMangaId(series)
    if not manga_id then
        log("no confident MangaDex match for", series)
        return
    end

    -- 2. What covers does it have?
    local covers = getJson(API .. "/cover?limit=100&manga[]=" .. manga_id)
    if not covers then return end
    local by_volume, series_cover = coversFromList(covers)

    -- 3. Series cover first, so there's always something better than the poster.
    if series_cover and not seriesCover(hash) then
        saveImage(UPLOADS .. manga_id .. "/" .. series_cover, coverBase(hash))
    end

    -- 4. Which volume is this chapter in? Only if the number is trustworthy.
    if not chapter then return end
    local aggregate = getJson(API .. "/manga/" .. manga_id .. "/aggregate")
    if not aggregate then return end
    local map = volmapFromAggregate(aggregate)
    writeVolmap(map)

    -- 5. That volume's cover, then the next volume's, so chapters Rakuyomi
    -- downloads ahead have their cover when read offline. Either may already
    -- be on disk, since the fetch also runs when only the next one is missing.
    local function saveVolumeCover(volume)
        local filename = volume and by_volume[volume]
        if filename and not existingImage(coverBase(hash, volume)) then
            saveImage(UPLOADS .. manga_id .. "/" .. filename,
                coverBase(hash, volume))
        end
    end
    local volume = map[chapter]
    saveVolumeCover(volume)
    saveVolumeCover(nextVolume(map, volume))
end

-- Of several sources, prefer one whose URL already names the MangaDex id.
local function bestRow(rows)
    for _, row in ipairs(rows) do
        if mangaIdFromUrl(row.cover_url) then return row end
    end
    return rows[1]
end

-- key -> { count = , last = }, from the tries file.
local function readTries()
    local tries = {}
    local f = io.open(triesPath(), "r")
    if not f then return tries end
    for line in f:lines() do
        local count, last, key = line:match("^(%d+) (%d+) (.+)$")
        if key then
            tries[key] = { count = tonumber(count), last = tonumber(last) }
        end
    end
    f:close()
    return tries
end

-- Drops entries that haven't been tried for FORGET_AFTER, so the file stays
-- small. Returns false if it couldn't be written.
local function writeTries(tries, now)
    local path = triesPath()
    local f = io.open(path .. ".part", "w")
    if not f then return false end
    for key, try in pairs(tries) do
        if now - try.last < FORGET_AFTER then
            f:write(string.format("%d %d %s\n", try.count, try.last, key))
        end
    end
    f:close()
    if os.rename(path .. ".part", path) then return true end
    os.remove(path .. ".part")
    return false
end

-- Tries are counted against what a fetch is after, not the chapter, or every
-- chapter opened would get its own tries. That's a volume's covers when the
-- map places the chapter, the map when it has no line for this chapter, and
-- otherwise the MangaDex match and the series cover.
local function tryKey(hash, chapter)
    local volume = volumeFor(hash, chapter)
    if volume then return hash .. "#v" .. volume end
    if chapter and isFile(volmapPath(hash)) then return hash .. "#unmapped" end
    return hash .. "#series"
end

-- Records a try and returns true, or returns false when the key has used up
-- its tries or was last tried too recently.
local function takeTry(key)
    local now = os.time()
    local tries = readTries()
    local try = tries[key]
    if try and now - try.last >= FORGET_AFTER then try = nil end
    if try and (try.count >= MAX_TRIES or now - try.last < RETRY_AFTER) then
        return false
    end

    lfs.mkdir(HIRES_DIR)
    tries[key] = { count = (try and try.count or 0) + 1, last = now }
    -- If it can't be recorded it can't be limited, so don't fetch.
    return writeTries(tries, now)
end

local function fetchCover(info)
    local NetworkMgr = require("ui/network/manager")
    -- Never bring wifi up on its own: if it's off, the low-res poster is fine.
    if not NetworkMgr:isConnected() then return end

    -- One fetch at a time, however fast chapters are opened. A locked chapter
    -- isn't marked as tried below, so it gets another go next time it opens.
    if fetchLocked() then return end

    local wait = cooldownRemaining()
    if wait > 0 then
        logger.dbg(TAG, "in MangaDex cooldown for another", wait, "seconds")
        return
    end

    local rows = rowsForSeries(info.series)
    if #rows == 0 then return end
    local row = bestRow(rows)

    -- Nothing to do if what this chapter would show is already on disk, along
    -- with the next volume's cover for chapters Rakuyomi downloaded ahead.
    for _, r in ipairs(rows) do
        if info.chapter then
            if volumeCoversOnDisk(r.hash, info.chapter) then return end
        else
            if seriesCover(r.hash) then return end
        end
    end

    -- Counted before forking, so a child that gets killed still uses a try.
    local key = tryKey(row.hash, info.chapter)
    if not takeTry(key) then
        logger.dbg(TAG, "not trying", key, "again yet")
        return
    end

    log("fetching cover for", info.series, "chapter", info.chapter or "?")

    -- Double fork: the fetching process is handed to init, which reaps it, so
    -- there's nothing to wait for here. It also means the pid returned can't
    -- tell us whether the fetch is still running, hence the lock directory.
    ffiutil.runInSubProcess(function()
        if not lfs.mkdir(LOCK_DIR) then return end
        local ok, err = pcall(fetchInChild, info.series, info.chapter,
            row.cover_url, row.hash)
        lfs.rmdir(LOCK_DIR)
        if not ok then warn("fetch failed:", err) end
    end, false, true)
end

--------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------

local function isRakuyomiChapter(path)
    if not path or not path:match("%.cbz$") then return false end
    if path:find("/rakuyomi/", 1, true) then return true end
    -- chapters copied to tmpfs land elsewhere but keep the 43-char hash name
    local stem = path:match("([^/]+)%.cbz$")
    return stem ~= nil and #stem == 43 and stem:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local orig_doShowReader = ReaderUI.doShowReader

function ReaderUI:doShowReader(file, provider, seamless)
    orig_doShowReader(self, file, provider, seamless)
    if not isRakuyomiChapter(file) then return end

    -- Wifi is usually still up just after Rakuyomi downloaded the chapter.
    UIManager:scheduleIn(FETCH_DELAY, function()
        local info = infoFor(file)
        if info then pcall(fetchCover, info) end
    end)
end

-- The manga cover for a chapter, decoded, or nil to let stock pick.
local function sleepCoverImage(chapter_path)
    local info = infoFor(chapter_path)
    if not info then return nil end
    local path = coverForInfo(info)
    if not path then
        log("no cover on file for", info.series)
        return nil
    end
    return RenderImage:renderImageFile(fittedCover(path), false)
end

-- True only while Screensaver:setup runs for sleep screen type "cover".
local sleep_cover_wanted = false

local orig_getCoverImage = BookInfo.getCoverImage

-- Stock setup only gets here once the book has passed its sleep screen checks.
-- The image returned goes into self.image, and the sleep screen frees it when
-- it closes.
function BookInfo:getCoverImage(document, file, force_orig)
    if sleep_cover_wanted then
        -- The open chapter comes first: with 2-manga-no-history.lua, lastfile
        -- (passed as file) is the last real book, not the chapter. Sleeping
        -- from the file browser leaves document nil, so lastfile is used.
        local current = document and document.file or file
        if isRakuyomiChapter(current) and isFile(current) then
            local ok, image = pcall(sleepCoverImage, current)
            if not ok then
                warn("resolve failed:", image)
            elseif image then
                return image
            end
        end
    end
    return orig_getCoverImage(self, document, file, force_orig)
end

local orig_setup = Screensaver.setup

function Screensaver:setup(event, event_message)
    -- Work out the type the way stock setup does: poweroff and reboot can have
    -- their own. Stock turns "Show custom image or cover" (document_cover)
    -- into "cover" too, so this has to be read before it runs.
    local prefix = event and (event .. "_") or ""
    local mode = G_reader_settings:readSetting(prefix .. "screensaver_type")
        or G_reader_settings:readSetting("screensaver_type")

    sleep_cover_wanted = mode == "cover"
    local ok, err = pcall(orig_setup, self, event, event_message)
    sleep_cover_wanted = false
    if not ok then error(err, 0) end
end

log("loaded")
