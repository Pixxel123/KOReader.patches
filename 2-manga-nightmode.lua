-- 2-manga-nightmode.lua v2.1.0
--[[
Keep comic artwork un-inverted in night mode, while menus stay dark.

Night mode inverts the whole screen, which suits text and ruins artwork.
Rather than switching night mode off while a comic is open, this leaves it on
and draws comic pages already inverted, so the screen-wide inversion cancels
out. Menus, dialogs and Rakuyomi's own screens are drawn normally and so still
come out dark.

KOReader already does this for the "Invert Document" option in the reader's
bottom menu (nightmode_document), which KoptInterface.drawPage checks before
drawing. CBZ, CBR and CBT pages all go through that function, so the patch
switches the option on for comics.

The option is only switched on while the comic is open. It's left out of the
comic's saved settings, and any value already saved there (earlier versions of
this patch saved it) is removed when the comic is next closed, so removing the
patch leaves comics with the option off.

The margins around a page, the scroll-mode background and the gap between
pages are painted by ReaderView, not the document, so they'd come out dark.
For comics in night mode their colours are inverted for the length of each
paint too, so they show in the colours set for day reading.

Because night mode itself never changes, AutoWarmth, other schedules and the
manual toggle all behave as normal. Turn night mode off by hand and comic
pages draw normally, since the option only applies while night mode is on.

Cover images, the sleep screen and panel zoom use ImageWidget, which already
shows images un-inverted in night mode. The Panels+ plugin adds its own
inversion on top of that, which is skipped for comics.

Install to koreader/patches/.
]]

local KoptInterface = require("document/koptinterface")
local ReaderConfig = require("apps/reader/modules/readerconfig")
local ReaderView = require("apps/reader/modules/readerview")
local Screen = require("device").screen
local logger = require("logger")

-- The comic formats KOReader 2026.07 opens. Keep this list the same in
-- 2-manga-no-history.lua and 2-manga-no-stats.lua.
local MANGA_EXTENSIONS = { cbz = true, cbr = true, cbt = true }

local TAG = "manga-nightmode:"

local function isManga(file)
    local ext = file and file:match("%.([^.]+)$")
    return ext ~= nil and MANGA_EXTENSIONS[ext:lower()] == true
end

-- KoptInterface is a shared module table, and PdfDocument calls it as
-- self.koptinterface:drawPage(doc, ...), so wrapping it here covers every
-- open comic.
--
-- The option is set on the document and left on, not swapped in for each
-- draw. When White Threshold, Dewatermark or Auto Straighten are in use,
-- pages are cached under a key that includes every reader option. If the
-- value differed between pre-rendering and drawing, the pre-rendered next
-- page would never be found and every page turn would render from scratch.
-- It's kept out of the comic's saved settings further down.
local function forceInvert(doc)
    if isManga(doc.file) then
        doc.configurable.nightmode_document = 1
    end
end

local orig_drawPage = KoptInterface.drawPage
function KoptInterface:drawPage(doc, ...)
    forceInvert(doc)
    return orig_drawPage(self, doc, ...)
end

local orig_hintPage = KoptInterface.hintPage
function KoptInterface:hintPage(doc, ...)
    forceInvert(doc)
    return orig_hintPage(self, doc, ...)
end

-- ReaderConfig saves every reader option into the comic's settings, including
-- the one switched on above. Taking it back out after each save means the
-- comic falls back to the default (off) whenever it's opened without the
-- patch. This also clears the value earlier versions of the patch left there.
-- The last save runs after the document is closed, so the file is taken from
-- the settings rather than from self.ui.document.
local orig_onSaveSettings = ReaderConfig.onSaveSettings
function ReaderConfig:onSaveSettings(...)
    orig_onSaveSettings(self, ...)
    local doc_settings = self.ui.doc_settings
    if isManga(doc_settings:readSetting("doc_path")) then
        doc_settings:delSetting(self.options.prefix .. "_nightmode_document")
    end
end

-- Runs fn with tbl[key] inverted, then puts it back. rawget keeps an
-- inherited class value inherited, rather than copying it onto the instance.
local function withInverted(tbl, key, fn, ...)
    local own = rawget(tbl, key)
    tbl[key] = tbl[key]:invert()
    local ok, err = pcall(fn, ...)
    tbl[key] = own
    if not ok then error(err, 0) end
end

local function isMangaAtNight(view)
    return Screen.night_mode and view.document ~= nil and isManga(view.document.file)
end

-- Page mode margins.
local orig_drawPageSurround = ReaderView.drawPageSurround
function ReaderView:drawPageSurround(bb, x, y)
    if not isMangaAtNight(self) then
        return orig_drawPageSurround(self, bb, x, y)
    end
    withInverted(self, "outer_page_color", orig_drawPageSurround, self, bb, x, y)
end

-- Scroll mode background, behind and beside the pages.
local orig_drawPageBackground = ReaderView.drawPageBackground
function ReaderView:drawPageBackground(bb, x, y)
    if not isMangaAtNight(self) then
        return orig_drawPageBackground(self, bb, x, y)
    end
    withInverted(self, "page_bgcolor", orig_drawPageBackground, self, bb, x, y)
end

-- Scroll mode gap between pages. Its colour lives in the page_gap table.
local orig_drawPageGap = ReaderView.drawPageGap
function ReaderView:drawPageGap(bb, x, y)
    if not isMangaAtNight(self) then
        return orig_drawPageGap(self, bb, x, y)
    end
    withInverted(self.page_gap, "color", orig_drawPageGap, self, bb, x, y)
end

-- Panels+ panel viewer. It draws panels with ImageWidget, which already shows
-- images un-inverted in night mode, then inverts the panel once more on
-- purpose so manga panels go dark. For comics that undoes this patch, so the
-- viewer is painted without that last step, and the letterbox around the
-- panel is lightened to match the page gutters. Other paged documents keep
-- Panels+'s behaviour, since their pages are still shown inverted.
-- The replacement mirrors PanelViewer:paintTo from Panels+ 1.4.0.
local function patchPanelsPlus()
    local PanelViewer = package.loaded["src._panelviewer"]
    local OcrDebug = package.loaded["src._ocrdebug"]
    if not (PanelViewer and OcrDebug) or PanelViewer._manga_nightmode_patched then
        return
    end
    PanelViewer._manga_nightmode_patched = true

    local ImageViewer = require("ui/widget/imageviewer")
    local ReaderUI = require("apps/reader/readerui")
    local orig_paintTo = PanelViewer.paintTo

    -- Inverts the area of the image container not covered by the panel, so
    -- the letterbox shows light like the page gutters. ImageViewer centres the
    -- panel in a CenterContainer, which never records its own position, so
    -- the container's corner is worked back from where the panel was drawn.
    local function lightenLetterbox(viewer, bb)
        local image, box = viewer._image_wg, viewer.image_container
        if not (image and image.dimen and box and box.dimen) then return end
        local size = image:getSize()
        local ox = image.dimen.x - math.floor((box.dimen.w - size.w) / 2)
        local oy = image.dimen.y - math.floor((box.dimen.h - size.h) / 2)
        local ow, oh = box.dimen.w, box.dimen.h
        -- Clamp the panel to the container, in case it's panned past an edge.
        local ix = math.max(image.dimen.x, ox)
        local iy = math.max(image.dimen.y, oy)
        local iw = math.min(image.dimen.x + size.w, ox + ow) - ix
        local ih = math.min(image.dimen.y + size.h, oy + oh) - iy
        local function strip(x, y, w, h)
            if w > 0 and h > 0 then bb:invertRect(x, y, w, h) end
        end
        strip(ox, oy, ow, iy - oy)                     -- above
        strip(ox, iy + ih, ow, oy + oh - iy - ih)      -- below
        strip(ox, iy, ix - ox, ih)                     -- left
        strip(ix + iw, iy, ox + ow - ix - iw, ih)      -- right
    end

    function PanelViewer:paintTo(bb, x, y)
        local ui = ReaderUI.instance
        local doc = ui and ui.document
        if not (Screen.night_mode and doc and isManga(doc.file)) then
            return orig_paintTo(self, bb, x, y)
        end
        ImageViewer.paintTo(self, bb, x, y)
        lightenLetterbox(self, bb)
        self:paintHighlights(bb, x, y)
        OcrDebug.paint(self, bb, x, y)
    end
    logger.info(TAG, "Panels+ viewer patched")
end

-- Plugins are loaded after patches, so wait until Panels+ is created.
require("userpatch").registerPatchPluginFunc("panelsplus", patchPanelsPlus)

-- The previous version of this patch kept a restore value here. It's only
-- set if KOReader was closed with a comic open. Patches in the 2- slot run
-- after the screen is set up, so night mode is applied directly rather than
-- just saved. Called on the class, the same way AutoWarmth does.
if G_reader_settings:has("manga_nightmode_restore") then
    if G_reader_settings:isTrue("manga_nightmode_restore")
            and not G_reader_settings:isTrue("night_mode") then
        require("device/devicelistener"):onSetNightMode(true)
    end
    G_reader_settings:delSetting("manga_nightmode_restore")
    logger.info(TAG, "cleared restore value from the old patch")
end

logger.info(TAG, "loaded")
