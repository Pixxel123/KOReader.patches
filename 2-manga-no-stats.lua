--[[
Keep comic archives out of the reading statistics.

The statistics plugin already has this behaviour for picture documents:
onReaderReady only calls initData when the document isn't a PIC, which leaves
is_doc false, so no time is recorded and no book row is created. Comic archives
are handled by MuPDF rather than the picture provider, so they miss out.

This applies the same rule to the extensions in MANGA_EXTENSIONS. Nothing else
in the plugin needs changing: isEnabled() tests is_doc and the insert path tests
id_curr_book, and both stay unset when initData is skipped.

Plugins are loaded with dofile and never reach package.loaded, so the instance
is caught as ReaderUI registers it, which happens once per document opened.

Statistics already recorded against comics stay in statistics.sqlite3. Delete
those separately.

Matches on extension, the same as 2-manga-nightmode.lua and
2-manga-no-history.lua. Keep MANGA_EXTENSIONS the same in all three.

Install to koreader/patches/.
]]

local ReaderUI = require("apps/reader/readerui")
local logger = require("logger")

-- The comic formats KOReader 2026.07 opens.
local MANGA_EXTENSIONS = { cbz = true, cbr = true, cbt = true }
local TAG = "manga-no-stats:"

local function isManga(file)
    local ext = file and file:match("%.([^.]+)$")
    return ext ~= nil and MANGA_EXTENSIONS[ext:lower()] == true
end

-- Shadows initData on this instance only, so there's no risk of wrapping the
-- class twice as documents come and go.
local function skipStatsForComics(stats)
    local orig_initData = stats.initData

    stats.initData = function(self, ...)
        local file = self.document and self.document.file
        if isManga(file) then
            logger.dbg(TAG, "not tracking", file)
            return
        end
        return orig_initData(self, ...)
    end
end

local orig_registerModule = ReaderUI.registerModule

function ReaderUI:registerModule(name, ui_module, always_active)
    if name == "statistics" and ui_module and ui_module.initData then
        skipStatsForComics(ui_module)
    end
    return orig_registerModule(self, name, ui_module, always_active)
end

logger.info(TAG, "loaded")
