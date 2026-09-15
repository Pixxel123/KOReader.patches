--[[
Keep comic archives out of KOReader's history.

A document is added to the history by ReadHistory:addItem, so comics are
skipped there. addItem also decides lastfile, which ensureLastFile picks from
the top of the history list, so a skipped comic never becomes the "last book"
either.

Closing any document also calls ReadHistory:updateLastBookTime, which stamps
the top history entry with the current time without checking which file is
closing. With comics kept out, that top entry is the last real book, so the
call is skipped for comics as well. Otherwise closing a comic would mark that
book as read just now, and would error on an empty history.

Comics already logged before this patch was installed are cleared too. The
require below loads history.lua, so the list is there to be filtered.

Matches on extension, the same as 2-manga-nightmode.lua and
2-manga-no-stats.lua. Keep MANGA_EXTENSIONS the same in all three.

Install to koreader/patches/.
]]

local ReadHistory = require("readhistory")
local ReaderUI = require("apps/reader/readerui")
local logger = require("logger")

-- The comic formats KOReader 2026.07 opens.
local MANGA_EXTENSIONS = { cbz = true, cbr = true, cbt = true }
local TAG = "manga-no-history:"

local function isManga(file)
    local ext = file and file:match("%.([^.]+)$")
    return ext ~= nil and MANGA_EXTENSIONS[ext:lower()] == true
end

--------------------------------------------------------------------------
-- Skip new comics
--------------------------------------------------------------------------

local orig_addItem = ReadHistory.addItem

function ReadHistory:addItem(file, ts, no_flush)
    if isManga(file) then
        -- Returning nothing matches what addItem does for an item it rejects.
        -- The legacy history import checks this return value, so a comic found
        -- there is skipped as well.
        logger.dbg(TAG, "skipping", file)
        return
    end
    return orig_addItem(self, file, ts, no_flush)
end

local orig_updateLastBookTime = ReadHistory.updateLastBookTime

-- ReaderUI:onClose calls this while the reader still has its document, so
-- ReaderUI.instance says which file is closing.
function ReadHistory:updateLastBookTime(no_flush)
    local reader = ReaderUI.instance
    local file = reader and reader.document and reader.document.file
    if isManga(file) then return end
    return orig_updateLastBookTime(self, no_flush)
end

--------------------------------------------------------------------------
-- Clear comics logged before this patch existed
--------------------------------------------------------------------------

local removed = 0
for i = #ReadHistory.hist, 1, -1 do
    if isManga(ReadHistory.hist[i].file) then
        table.remove(ReadHistory.hist, i)
        removed = removed + 1
    end
end

if removed > 0 then
    -- _flush writes history.lua and calls ensureLastFile, so lastfile won't be
    -- left pointing at an entry that's just been removed.
    ReadHistory:_flush()
    logger.info(TAG, "removed", removed, "existing comic entries")
end

logger.info(TAG, "loaded")
