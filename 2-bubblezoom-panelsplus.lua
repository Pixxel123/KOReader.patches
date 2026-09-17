-- 2-bubblezoom-panelsplus.lua v1.0.0
--[[
Let Bubble Zoom and Panels+ share long-press on comic pages: long-press a
speech bubble to enlarge it, or anywhere else to open that panel.

Bubble Zoom handles long-press before KOReader's own long-press, which is where
Panels+ opens panels. When Bubble Zoom finds no bubble it still keeps the press
and shows "No bubble found", so Panels+ never sees it. This patch looks for the
bubble first. If there isn't one, it closes any enlarged bubble and leaves the
press alone, so it carries on to Panels+.

Bubble Zoom finds a bubble by filling the light area around the press, so faces,
clothes, sky and panel backgrounds come back as bubbles too. The patch checks
the filled area before letting Bubble Zoom enlarge it. It isn't a bubble if it:
- covers more than a quarter of the page, or reaches the edge of the page
- has too little lettering inside it (dark marks enclosed by the area)
- has a ragged outline, or isn't roughly convex

The limits were set on 13 hand-labelled pages from three series, then checked
on 15 pages from five other series. On those, about 93% of presses on bubbles
still enlarge them, and presses elsewhere that enlarge something dropped from
about half to about 2%. Balloons with very little lettering ("...", "?") and
balloons touching the page edge open the panel instead.

Long-press on an enlarged bubble (to close or translate it), taps and Bubble
Zoom's tap mode work as before. Without Panels+, a press that isn't on a bubble
goes to KOReader's own panel zoom or text selection.

Bubble Zoom needs to be switched on in its menu. Install to koreader/patches/.
]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local userpatch = require("userpatch")

-- Largest share of the page a bubble can cover (0.25 is a quarter).
local MAX_BUBBLE_AREA = 0.25
-- An area this close to the edge of the page, as a share of the page's width
-- or height, counts as reaching the edge.
local EDGE_MARGIN = 0.005
-- Smallest share of the area (with its enclosed marks filled in) that the
-- enclosed dark marks must cover. Lettering usually covers 10-25%.
local MIN_LETTERING = 0.06
-- Largest perimeter² / (4π · area). About 1.3 for a circle on the pixel grid;
-- ragged or stringy areas score far higher.
local MAX_RAGGEDNESS = 5
-- Smallest area / convex hull area.
local MIN_CONVEXITY = 0.75

-- What Bubble Zoom stores for an enlarged bubble. It clears the same fields
-- when it finds no bubble.
local OVERLAY_FIELDS = {
    "overlay_rect", "overlay_src_rect", "overlay_page", "overlay_scale_active",
    "overlay_mask", "overlay_mask_w", "overlay_mask_h", "overlay_mask_rect",
    "overlay_mask_region", "overlay_mask_region_w", "overlay_mask_region_h",
    "overlay_tap_x", "overlay_tap_y",
}

local function isInsideOverlay(bubblezoom, pos)
    local rect = bubblezoom.overlay_rect
    return rect and pos.page == bubblezoom.overlay_page
        and pos.x >= rect.x and pos.x <= rect.x + rect.w
        and pos.y >= rect.y and pos.y <= rect.y + rect.h
end

-- rect is in page coordinates at zoom 1, as detectBubbleRect returns it.
local function fitsOnPage(rect, page_size)
    if rect.w * rect.h > MAX_BUBBLE_AREA * page_size.w * page_size.h then
        return false
    end
    local margin_x = EDGE_MARGIN * page_size.w
    local margin_y = EDGE_MARGIN * page_size.h
    return rect.x > margin_x and rect.y > margin_y
        and rect.x + rect.w < page_size.w - margin_x
        and rect.y + rect.h < page_size.h - margin_y
end

-- Area of the convex hull of integer points (monotone chain).
-- The same function is in 2-bubblezoom-overlay.lua; keep the two identical.
local function hullArea(xs, ys, n)
    local order = {}
    for i = 1, n do order[i] = i end
    table.sort(order, function(a, b)
        if xs[a] ~= xs[b] then return xs[a] < xs[b] end
        return ys[a] < ys[b]
    end)
    local function cross(o, a, b)
        return (xs[a] - xs[o]) * (ys[b] - ys[o]) - (ys[a] - ys[o]) * (xs[b] - xs[o])
    end
    local hull = {}
    for _, p in ipairs(order) do
        while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
            hull[#hull] = nil
        end
        hull[#hull + 1] = p
    end
    local lower = #hull + 1
    for i = #order - 1, 1, -1 do
        local p = order[i]
        while #hull >= lower and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
            hull[#hull] = nil
        end
        hull[#hull + 1] = p
    end
    hull[#hull] = nil
    local area = 0
    for i = 1, #hull do
        local a, b = hull[i], hull[i % #hull + 1]
        area = area + xs[a] * ys[b] - xs[b] * ys[a]
    end
    return math.abs(area) / 2
end

-- Measures an area Bubble Zoom filled: region is a uint8 array of rw * rh,
-- nonzero = in the area. The area is 4-connected, so what surrounds it is
-- treated as 8-connected. Returns lettering share, raggedness and convexity.
local function measureRegion(region, rw, rh)
    local n = rw * rh
    -- 0 = unvisited, 1 = area, 2 = outside, 3 = enclosed
    local state = ffi.new("uint8_t[?]", n)
    local filled = 0
    for i = 0, n - 1 do
        if region[i] ~= 0 then
            state[i] = 1
            filled = filled + 1
        end
    end
    if filled == 0 then
        return nil
    end

    -- Everything not in the area that connects to the bounding box's border
    -- is outside; what's left is enclosed by the area.
    local queue = ffi.new("int32_t[?]", n)
    local head, tail = 0, 0
    local function markOutside(i)
        if state[i] == 0 then
            state[i] = 2
            queue[tail] = i
            tail = tail + 1
        end
    end
    for x = 0, rw - 1 do
        markOutside(x)
        markOutside((rh - 1) * rw + x)
    end
    for y = 0, rh - 1 do
        markOutside(y * rw)
        markOutside(y * rw + rw - 1)
    end
    while head < tail do
        local i = queue[head]
        head = head + 1
        local x, y = i % rw, math.floor(i / rw)
        for dy = -1, 1 do
            local ny = y + dy
            if ny >= 0 and ny < rh then
                for dx = -1, 1 do
                    local nx = x + dx
                    if nx >= 0 and nx < rw and (dx ~= 0 or dy ~= 0) then
                        markOutside(ny * rw + nx)
                    end
                end
            end
        end
    end
    local enclosed = 0
    for i = 0, n - 1 do
        if state[i] == 0 then
            state[i] = 3
            enclosed = enclosed + 1
        end
    end

    -- The solid shape is the area plus what it encloses. Its row extents give
    -- the convex hull, and its edges against anything else the perimeter.
    local solid = filled + enclosed
    local xs, ys, points = {}, {}, 0
    local perimeter = 0
    local function isSolid(i)
        local s = state[i]
        return s == 1 or s == 3
    end
    for y = 0, rh - 1 do
        local row = y * rw
        local left, right = -1, -1
        for x = 0, rw - 1 do
            if isSolid(row + x) then
                if left < 0 then left = x end
                right = x
                if x == 0 or not isSolid(row + x - 1) then perimeter = perimeter + 1 end
                if x == rw - 1 or not isSolid(row + x + 1) then perimeter = perimeter + 1 end
                if y == 0 or not isSolid(row - rw + x) then perimeter = perimeter + 1 end
                if y == rh - 1 or not isSolid(row + rw + x) then perimeter = perimeter + 1 end
            end
        end
        if left >= 0 then
            points = points + 1; xs[points], ys[points] = left, y
            points = points + 1; xs[points], ys[points] = right + 1, y
            points = points + 1; xs[points], ys[points] = left, y + 1
            points = points + 1; xs[points], ys[points] = right + 1, y + 1
        end
    end
    local hull = hullArea(xs, ys, points)
    return {
        lettering = enclosed / solid,
        raggedness = perimeter * perimeter / (4 * math.pi * solid),
        convexity = hull > 0 and solid / hull or 0,
    }
end

local function isBubbleShape(m)
    return m ~= nil and m.lettering >= MIN_LETTERING and m.raggedness <= MAX_RAGGEDNESS
        and m.convexity >= MIN_CONVEXITY
end

-- Crops Bubble Zoom's visited mask (mask-sized, nonzero = filled) to the
-- area's bounding box, looking just around the page rect scaled to the mask.
local function cropRegion(visited, mask_w, mask_h, rect, scale)
    local x0 = math.max(0, math.floor(rect.x * scale) - 2)
    local y0 = math.max(0, math.floor(rect.y * scale) - 2)
    local x1 = math.min(mask_w - 1, math.ceil((rect.x + rect.w) * scale) + 2)
    local y1 = math.min(mask_h - 1, math.ceil((rect.y + rect.h) * scale) + 2)
    local min_x, max_x, min_y, max_y = x1 + 1, -1, y1 + 1, -1
    for y = y0, y1 do
        local row = y * mask_w
        for x = x0, x1 do
            if visited[row + x] ~= 0 then
                if x < min_x then min_x = x end
                if x > max_x then max_x = x end
                if y < min_y then min_y = y end
                if y > max_y then max_y = y end
            end
        end
    end
    if max_x < 0 then
        return nil
    end
    local rw, rh = max_x - min_x + 1, max_y - min_y + 1
    local region = ffi.new("uint8_t[?]", rw * rh)
    for y = 0, rh - 1 do
        ffi.copy(region + y * rw, visited + (min_y + y) * mask_w + min_x, rw)
    end
    return region, rw, rh
end

-- KOReader wraps plugin functions whose names start with "on" in a callable
-- table, so onBubbleGesture isn't a plain function.
local function isCallable(value)
    if type(value) == "function" then
        return true
    end
    local mt = getmetatable(value)
    return mt ~= nil and mt.__call ~= nil
end

-- KOReader runs this each time a book opens, with the same plugin table.
userpatch.registerPatchPluginFunc("bubblezoom", function(BubbleZoom)
    if BubbleZoom._bubblezoom_panelsplus_patched then
        return
    end
    local orig_onBubbleGesture = BubbleZoom.onBubbleGesture
    local orig_detectBubbleRect = BubbleZoom.detectBubbleRect
    if not isCallable(orig_onBubbleGesture) or not isCallable(orig_detectBubbleRect)
        or not isCallable(BubbleZoom.isComicDocument) then
        logger.warn("2-bubblezoom-panelsplus: this Bubble Zoom version isn't supported, patch not applied")
        return
    end
    BubbleZoom._bubblezoom_panelsplus_patched = true

    -- Hands the detection this patch already ran to Bubble Zoom's own call for
    -- the same press, so a bubble isn't detected twice.
    BubbleZoom.detectBubbleRect = function(self, pageno, x, y)
        local memo = self._bubblezoom_panelsplus_detection
        if memo then
            self._bubblezoom_panelsplus_detection = nil
            if memo.page == pageno and memo.x == x and memo.y == y and memo.cache == self.sauvola_cache then
                return memo.rect, self.use_full_shape and memo.visited or nil
            end
        end
        return orig_detectBubbleRect(self, pageno, x, y)
    end

    -- True when Bubble Zoom should handle the press itself.
    local function isForBubbleZoom(self, ges)
        local pos = self.view:screenToPageTransform(ges.pos)
        if not pos or not pos.page or isInsideOverlay(self, pos) then
            return true
        end
        -- use_full_shape makes Bubble Zoom return the filled area as well.
        local use_full_shape = self.use_full_shape
        self.use_full_shape = true
        local ok, rect, visited = pcall(orig_detectBubbleRect, self, pos.page, pos.x, pos.y)
        self.use_full_shape = use_full_shape
        if not ok then
            error(rect, 0)
        end
        if not rect then
            return false
        end
        local state = self.view.state
        local page_size = self.document:getPageDimensions(pos.page, 1.0, state and state.rotation or 0)
        local cache = self.sauvola_cache
        if not page_size or not page_size.w or page_size.w <= 0 or page_size.h <= 0
            or not visited or not cache or not cache.scale then
            return true
        end
        if not fitsOnPage(rect, page_size) then
            return false
        end
        local region, rw, rh = cropRegion(visited, cache.width, cache.height, rect, cache.scale)
        if not isBubbleShape(region and measureRegion(region, rw, rh)) then
            return false
        end
        self._bubblezoom_panelsplus_detection = {
            page = pos.page, x = pos.x, y = pos.y, cache = cache, rect = rect, visited = visited,
        }
        return true
    end

    -- Bubble Zoom's long-press handler passes consume_on_miss = true, its tap
    -- handler false.
    BubbleZoom.onBubbleGesture = function(self, ges, consume_on_miss)
        if not consume_on_miss or not self.enabled or not self:isComicDocument() then
            return orig_onBubbleGesture(self, ges, consume_on_miss)
        end
        -- The callable table caught errors in Bubble Zoom's handler. If the
        -- check fails, leave the press to Bubble Zoom as if the patch weren't there.
        local ok, for_bubblezoom = pcall(isForBubbleZoom, self, ges)
        if not ok then
            logger.warn("2-bubblezoom-panelsplus: bubble check failed:", for_bubblezoom)
        end
        if not ok or for_bubblezoom then
            return orig_onBubbleGesture(self, ges, consume_on_miss)
        end

        -- Not a bubble. Bubble Zoom's hold_release handler lets the release
        -- through once hold_consumed is false.
        self._bubblezoom_panelsplus_detection = nil
        self.hold_consumed = false
        if self.overlay_rect then
            for _, field in ipairs(OVERLAY_FIELDS) do
                self[field] = nil
            end
            if self.clearTranslationOverlay then
                self:clearTranslationOverlay()
            end
            UIManager:setDirty(self.ui.dialog, "partial")
        end
        return false
    end
end)

-- Returned for offline tests of the bubble check; KOReader ignores it.
return {
    fitsOnPage = fitsOnPage,
    measureRegion = measureRegion,
    isBubbleShape = isBubbleShape,
    cropRegion = cropRegion,
}
