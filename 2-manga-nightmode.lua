--[[
Hold night mode off while a comic archive is open, restore it on leaving.

Inverted rendering suits text and ruins artwork, so night mode is turned off for
the extensions in MANGA_EXTENSIONS and put back afterwards. Scheduled night mode
carries on as normal for every other file.

The complication is AutoWarmth. When it controls night mode it re-applies its
schedule when the device wakes, and again 1.5s later, by calling
DeviceListener:onSetNightMode on the class. Anything that acts only when a
document opens gets silently overridden once the device has slept. So instead
of reacting to events, this wraps onSetNightMode: while a comic is open, a
class-level request to switch night mode ON is recorded and dropped.

Requests that arrive as events reach a DeviceListener instance instead, and are
let through, so night mode can still be turned on by hand inside a comic, from
the menu or with the "Set night mode" gesture. Anything that switches night
mode without going through DeviceListener isn't held off.

Only night mode is changed. This patch never sets warmth or brightness, and
AutoWarmth still sets warmth on its schedule while night mode is held off.
Other plugins that change warmth or brightness along with night mode still do
so when this patch changes it.

What the schedule last wanted is kept in G_reader_settings, so quitting or
crashing with a comic open doesn't leave night mode stuck off.

Install to koreader/patches/.
]]

local DeviceListener = require("device/devicelistener")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- The comic formats KOReader 2026.07 opens. Keep this list the same in
-- 2-manga-no-history.lua and 2-manga-no-stats.lua.
local MANGA_EXTENSIONS = { cbz = true, cbr = true, cbt = true }

local SAVE_KEY = "manga_nightmode_restore"
local TAG = "manga-nightmode:"

-- Grace period at startup before undoing a suppression left by a previous
-- session, so the last document has a chance to reopen first.
local RECOVERY_DELAY = 3

local in_manga = false    -- a comic is the open document
local holding = false     -- night mode is being held off for that comic
local restore_to = false  -- state to return to once the comic closes

local function log(...) logger.info(TAG, ...) end

local function isManga(file)
    local ext = file and file:match("%.([^.]+)$")
    return ext ~= nil and MANGA_EXTENSIONS[ext:lower()] == true
end

local function nightModeIsOn()
    return G_reader_settings:isTrue("night_mode")
end

local function rememberWanted(on)
    restore_to = on == true
    G_reader_settings:saveSetting(SAVE_KEY, restore_to)
end

local orig_onSetNightMode = DeviceListener.onSetNightMode

-- Calls the original handler directly, so the hook below never sees our own
-- changes. Not a broadcast: by the time a closing reader reaches us it's
-- already off the window stack, and the file browser isn't up yet, so an event
-- would reach nothing. With a reader open its own DeviceListener is used,
-- which knows the document and resets crengine's call cache for an EPUB. The
-- class works without one, which is how AutoWarmth calls it.
local function applyNightMode(on)
    if nightModeIsOn() == on then return end
    local reader = ReaderUI.instance
    orig_onSetNightMode(reader and reader.devicelistener or DeviceListener, on)
end

local function startHolding()
    if holding then return end
    holding = true
    rememberWanted(nightModeIsOn())
    if restore_to then
        log("comic open, night mode off")
        applyNightMode(false)
    end
end

local function stopHolding()
    if not holding then return end
    holding = false
    G_reader_settings:delSetting(SAVE_KEY)
    if nightModeIsOn() ~= restore_to then
        log("comic closed, night mode back to", restore_to)
        applyNightMode(restore_to)
    end
end

--------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------

-- AutoWarmth calls this on the class, so self is DeviceListener itself. The
-- menu toggle sends ToggleNightMode and the "Set night mode" gesture sends a
-- SetNightMode event to a reader's or file browser's own instance, so both
-- skip the hold.
function DeviceListener:onSetNightMode(on)
    if holding and self == DeviceListener then
        rememberWanted(on)
        if on then
            logger.dbg(TAG, "held off a scheduled night mode change")
            return true
        end
    end
    return orig_onSetNightMode(self, on)
end

local orig_doShowReader = ReaderUI.doShowReader

function ReaderUI:doShowReader(file, provider, seamless)
    orig_doShowReader(self, file, provider, seamless)
    in_manga = isManga(file)
    if in_manga then
        startHolding()
    else
        stopHolding()
    end
end

local orig_onClose = ReaderUI.onClose

function ReaderUI:onClose(full_refresh)
    local ret = orig_onClose(self, full_refresh)
    in_manga = false
    -- tearing_down means another document is about to open in this one's
    -- place (switchDocument, reloadDocument, onShowingReader). Rakuyomi moves
    -- between chapters with switchDocument. Leave the hold alone and let
    -- doShowReader decide, rather than flashing night mode on between two
    -- chapters. Going Home or quitting doesn't set it, so night mode comes
    -- back before the file browser draws.
    if not self.tearing_down then
        stopHolding()
    end
    return ret
end

--------------------------------------------------------------------------
-- Recovery from a session that ended with a comic open
--------------------------------------------------------------------------

local pending = G_reader_settings:readSetting(SAVE_KEY)
if pending ~= nil then
    holding = true
    restore_to = pending
    UIManager:scheduleIn(RECOVERY_DELAY, function()
        if holding and not in_manga then
            log("restoring night mode from previous session")
            stopHolding()
        end
    end)
end

log("loaded")
