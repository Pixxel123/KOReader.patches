-- 2-bubblezoom-overlay.lua v1.0.0
--[[
Change how Bubble Zoom shows an enlarged speech bubble.

Only the bubble is enlarged: its outline, lettering and tail, with a thin white
edge so it stands out from the page behind it, instead of a rectangle cut out
of the page. If the bubble's shape can't be found cleanly (a balloon open on one
side, or a grey balloon), the rectangle is shown as before. Set SHAPED to false
to always show rectangles.

The enlarged bubble always fits on the screen. Bubble Zoom keeps it inside the
page, but the screen often shows less than the whole page (with page crop, or
zoomed to fit the width), so part of it could end up off the screen or under
the status bar. It's now shrunk if it's too big (never below the page's own
size) and moved away from the screen's edges.

The enlargement includes a little more around the bubble, so the balloon's
outline and any lettering touching it aren't cut off at the edge.

It also works with a White Threshold below 255. KOReader then cleans up each
page once at the reader's zoom and stores it under a key that doesn't include
the zoom, so Bubble Zoom's own renders got the reader's page back and it looked
for bubbles in the wrong place. Bubbles are now looked for in a normal render,
and the enlarged bubble is cut from the page the reader already shows, so it has
the same greys as the page around it.

And it keeps the enlarged bubble correct when the screen is redrawn while it's
open: Bubble Zoom scaled the bubble's position in place each time it drew it,
so a second draw showed a different part of the page.

Install to koreader/patches/.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local KoptInterface = require("document/koptinterface")
local Screen = require("device").screen
local ffi = require("ffi")
local logger = require("logger")
local userpatch = require("userpatch")

-- Enlarge only the bubble (true), or a rectangle around it (false).
local SHAPED = true
-- Space kept between the enlarged bubble and the screen's edges or the status
-- bar, in pixels on a 600 px wide screen (scaled for larger screens).
local SCREEN_MARGIN = 6
-- Least space included around the bubble, as a share of the page's width.
-- Balloon outlines are usually well under 1% of the page's width.
local MIN_PADDING = 0.012
-- Widest dark outline (with any lettering touching it) kept around the inside
-- of a shaped bubble, in page pixels.
local MAX_OUTLINE = 12
-- White edge around a shaped bubble, in pixels on a 600 px wide screen.
local HALO = 2
-- Pixels at least this light (0-255) count as the inside of a balloon.
local LIGHT = 170
-- When a bubble's inside reaches the edge of the enlarged area (balloons joined
-- to another, or cut off by Bubble Zoom's rectangle), that side is extended by
-- this share of the area's size, up to MAX_GROW times.
local GROW_BY = 0.35
local MAX_GROW = 3
-- A shape is only shown if its outline is this smooth (perimeter² / (4π · area))
-- and this close to convex (area / convex hull); leaks into the artwork aren't.
local MAX_RAGGEDNESS = 5
local MIN_CONVEXITY = 0.7
-- Extending the area is kept only if the shape gets no more ragged or less
-- convex than this: another balloon joined on keeps the shape clean, artwork doesn't.
local MAX_RAGGEDNESS_RISE = 1.0
local MAX_CONVEXITY_DROP = 0.08

local Mupdf -- loaded on first use
local function mupdf()
    if not Mupdf then
        Mupdf = require("ffi/mupdf")
    end
    return Mupdf
end

local function isCallable(value)
    if type(value) == "function" then
        return true
    end
    local mt = getmetatable(value)
    return mt ~= nil and mt.__call ~= nil
end

-- True when KOReader renders this document's pages through the cleaned-up,
-- zoom-less cache (White Threshold, Dewatermark or Auto Straighten in use).
local function isOptimized(doc)
    return doc ~= nil and doc.koptinterface ~= nil and doc.configurable ~= nil
        and doc.configurable.text_wrap ~= 1
        and doc.koptinterface:is_optimizing_page(doc)
end

-- True when KOReader draws this comic's pages inverted for night mode.
local function isInverted(doc)
    return doc ~= nil and doc.configurable ~= nil and doc.configurable.nightmode_document == 1
        and Screen.night_mode and true or false
end

-- Runs fn with KoptInterface treating doc as not optimized, so its renders
-- take the normal path, whose cache key includes the zoom. The document's
-- settings aren't touched, so the reader's own cache keys stay the same.
local function withNormalRendering(doc, fn, ...)
    local own = KoptInterface.is_optimizing_page
    KoptInterface.is_optimizing_page = function(this, d)
        if d == doc then
            return false
        end
        return own(this, d)
    end
    local ok, result = pcall(fn, ...)
    KoptInterface.is_optimizing_page = own
    if not ok then
        error(result, 0)
    end
    return result
end

-- Stands in for document:drawPage for an optimized document. rect is in page
-- coordinates at zoom, which is the reader's zoom times the enlargement, so the
-- same area at the reader's zoom is rect / enlargement. The reader's page only
-- covers what page crop kept, so only that part is drawn, in its place, and
-- the rest is left white like the page around it.
local function drawFromReaderPage(view, doc, target, x, y, rect, pageno, zoom, rotation)
    local reader_zoom = view.state.zoom
    local tile = doc.koptinterface:renderOptimizedPage(doc, pageno, nil, reader_zoom, rotation, false)
    target:paintRect(x, y, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
    if tile and tile.bb then
        local k = zoom / reader_zoom
        local left = rect.x / k - tile.excerpt.x
        local top = rect.y / k - tile.excerpt.y
        local sx0 = math.max(0, math.floor(left))
        local sy0 = math.max(0, math.floor(top))
        local sx1 = math.min(tile.bb:getWidth(), math.ceil(left + rect.w / k))
        local sy1 = math.min(tile.bb:getHeight(), math.ceil(top + rect.h / k))
        if sx1 > sx0 and sy1 > sy0 then
            local crop = Blitbuffer.new(sx1 - sx0, sy1 - sy0, tile.bb:getType())
            crop:blitFrom(tile.bb, 0, 0, sx0, sy0, sx1 - sx0, sy1 - sy0)
            local dw = math.floor((sx1 - sx0) * k + 0.5)
            local dh = math.floor((sy1 - sy0) * k + 0.5)
            local scaled = mupdf().scaleBlitBuffer(crop, dw, dh)
            crop:free()
            local ox = math.floor((sx0 - left) * k + 0.5)
            local oy = math.floor((sy0 - top) * k + 0.5)
            local bw = math.min(dw, rect.w - ox)
            local bh = math.min(dh, rect.h - oy)
            if bw > 0 and bh > 0 then
                target:blitFrom(scaled, x + ox, y + oy, 0, 0, bw, bh)
            end
            scaled:free()
        end
    end
    -- KoptInterface.drawPage inverts comic pages in the same case.
    if isInverted(doc) then
        target:invertRect(x, y, rect.w, rect.h)
    end
end

-- Where to put an enlargement on the screen. screen_rect is where Bubble Zoom
-- put it, src_w/src_h the enlarged area's size in page pixels, area the part
-- of the screen it may use. Returns the enlargement and top-left corner that
-- keep it inside area, shrinking it no further than 1x.
local function placeOnScreen(screen_rect, src_w, src_h, scale, zoom, area)
    local w, h = src_w * scale * zoom, src_h * scale * zoom
    local fit = math.min(1, area.w / w, area.h / h)
    if fit < 1 then
        scale = math.max(1, scale * fit)
        w, h = src_w * scale * zoom, src_h * scale * zoom
    end
    local x = screen_rect.x + (screen_rect.w - w) / 2
    local y = screen_rect.y + (screen_rect.h - h) / 2
    if w <= area.w then
        x = math.max(area.x, math.min(x, area.x + area.w - w))
    else
        x = area.x + (area.w - w) / 2
    end
    if h <= area.h then
        y = math.max(area.y, math.min(y, area.y + area.h - h))
    else
        y = area.y + (area.h - h) / 2
    end
    return scale, x, y
end

local function keepOnScreen(bubblezoom)
    local view = bubblezoom.view
    local rect, src, page = bubblezoom.overlay_rect, bubblezoom.overlay_src_rect, bubblezoom.overlay_page
    local scale = bubblezoom.overlay_scale_active or bubblezoom.overlay_scale
    local zoom = view and view.state and view.state.zoom
    if not (rect and src and page and scale and zoom and zoom > 0 and view.dimen) then
        return
    end
    local screen_rect = view:pageToScreenTransform(page, rect)
    if not screen_rect or screen_rect.w <= 0 or screen_rect.h <= 0 then
        return
    end
    local margin = Screen:scaleBySize(SCREEN_MARGIN)
    local bottom = view.dimen.y + view.dimen.h
    if view.footer_visible and view.footer then
        bottom = bottom - view.footer:getHeight()
    end
    local area = {
        x = view.dimen.x + margin,
        y = view.dimen.y + margin,
        w = view.dimen.w - 2 * margin,
    }
    area.h = bottom - margin - area.y
    if area.w <= 0 or area.h <= 0 then
        return
    end
    local new_scale, x, y = placeOnScreen(screen_rect, src.w, src.h, scale, zoom, area)
    bubblezoom.overlay_scale_active = new_scale
    bubblezoom.overlay_rect = Geom:new{
        x = rect.x + (x - screen_rect.x) / zoom,
        y = rect.y + (y - screen_rect.y) / zoom,
        w = src.w * new_scale,
        h = src.h * new_scale,
    }
end

-- Grows rect by at least MIN_PADDING of the page's width on every side, within the page.
local function withMinPadding(rect, padded, page_size)
    local pad = MIN_PADDING * page_size.w
    local x1 = math.max(0, math.min(padded.x, rect.x - pad))
    local y1 = math.max(0, math.min(padded.y, rect.y - pad))
    local x2 = math.min(page_size.w, math.max(padded.x + padded.w, rect.x + rect.w + pad))
    local y2 = math.min(page_size.h, math.max(padded.y + padded.h, rect.y + rect.h + pad))
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Breadth-first growth: from every pixel whose state is in `from`, grow 4-way
-- up to `steps` pixels, marking the pixels reached `to`. With dark_only, only
-- into pixels that aren't light.
local function grow(shape, light, w, h, from, to, steps, dark_only, queue, dist)
    local n = w * h
    local head, tail = 0, 0
    for i = 0, n - 1 do
        if from[shape[i]] then
            dist[i] = 0
            queue[tail] = i
            tail = tail + 1
        end
    end
    while head < tail do
        local i = queue[head]
        head = head + 1
        local d = dist[i]
        if d < steps then
            local x = i % w
            for k = 1, 4 do
                local j
                if k == 1 then
                    j = x > 0 and i - 1 or -1
                elseif k == 2 then
                    j = x < w - 1 and i + 1 or -1
                elseif k == 3 then
                    j = i - w
                else
                    j = i + w
                end
                if j >= 0 and j < n and not from[shape[j]] and shape[j] ~= to
                    and (not dark_only or light[j] == 0) then
                    shape[j] = to
                    dist[j] = d + 1
                    queue[tail] = j
                    tail = tail + 1
                end
            end
        end
    end
end

-- Area of the convex hull of integer points (monotone chain).
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

-- Builds the shaped enlargement from content (the enlarged area of the page).
-- tap_x/tap_y is the press in content pixels. Returns a buffer with alpha the
-- size of content (or nil and a reason when the shape isn't clean), and how
-- many pixels of the bubble's inside lie on each side of the content.
-- o.factor: work on content shrunk by this much (the masks are scaled back up
--   smoothly); o.inverted: content is inverted for night mode; o.outline and
--   o.halo: MAX_OUTLINE and HALO in content pixels.
local function composeShape(content, tap_x, tap_y, o)
    local W, H = content:getWidth(), content:getHeight()
    local f = math.max(1, o.factor or 1)
    local aw = math.max(1, math.floor(W / f + 0.5))
    local ah = math.max(1, math.floor(H / f + 0.5))
    local n = aw * ah

    local small = content
    if aw ~= W or ah ~= H then
        small = mupdf().scaleBlitBuffer(content, aw, ah)
    end
    local gray = Blitbuffer.new(aw, ah, Blitbuffer.TYPE_BB8)
    gray:blitFrom(small, 0, 0, 0, 0, aw, ah)
    if small ~= content then
        small:free()
    end
    local light = ffi.new("uint8_t[?]", n)
    local gp, gs = ffi.cast("uint8_t *", gray.data), tonumber(gray.stride)
    for y = 0, ah - 1 do
        local row, base = gp + y * gs, y * aw
        for x = 0, aw - 1 do
            local v = row[x]
            if o.inverted then v = 255 - v end
            if v >= LIGHT then light[base + x] = 1 end
        end
    end
    gray:free()

    -- shape: 0 = unset, 1 = inside, 2 = outside, 3 = enclosed, 4 = outline,
    -- 5 = white edge, 6 = another light area, 7 = outline candidate
    local shape = ffi.new("uint8_t[?]", n)
    local queue = ffi.new("int32_t[?]", n)
    local dist = ffi.new("uint8_t[?]", n)
    local border_len = 2 * (aw + ah) - 4

    -- Fills the light area containing start with mark; returns its size and
    -- how many of its pixels lie on each side of the enlargement.
    local function fillLight(start, mark)
        local head, tail = 0, 1
        queue[0], shape[start] = start, mark
        local sides = { left = 0, right = 0, top = 0, bottom = 0 }
        while head < tail do
            local i = queue[head]
            head = head + 1
            local x = i % aw
            local y = (i - x) / aw
            if x == 0 then sides.left = sides.left + 1 end
            if x == aw - 1 then sides.right = sides.right + 1 end
            if y == 0 then sides.top = sides.top + 1 end
            if y == ah - 1 then sides.bottom = sides.bottom + 1 end
            if x > 0 and shape[i - 1] == 0 and light[i - 1] == 1 then shape[i - 1] = mark; queue[tail] = i - 1; tail = tail + 1 end
            if x < aw - 1 and shape[i + 1] == 0 and light[i + 1] == 1 then shape[i + 1] = mark; queue[tail] = i + 1; tail = tail + 1 end
            if y > 0 and shape[i - aw] == 0 and light[i - aw] == 1 then shape[i - aw] = mark; queue[tail] = i - aw; tail = tail + 1 end
            if y < ah - 1 and shape[i + aw] == 0 and light[i + aw] == 1 then shape[i + aw] = mark; queue[tail] = i + aw; tail = tail + 1 end
        end
        return tail, sides
    end

    -- The bubble's inside is the largest light area near the press that stays
    -- inside the enlargement: the insides of letters are small, and the page
    -- around a bubble runs out of it.
    local cx = math.min(aw - 1, math.max(0, math.floor(tap_x * aw / W)))
    local cy = math.min(ah - 1, math.max(0, math.floor(tap_y * ah / H)))
    local reach = math.max(2, math.ceil(0.06 * math.max(aw, ah)))
    local best, best_size, best_sides = nil, 0, nil
    for y = math.max(0, cy - reach), math.min(ah - 1, cy + reach) do
        for x = math.max(0, cx - reach), math.min(aw - 1, cx + reach) do
            local i = y * aw + x
            if light[i] == 1 and shape[i] == 0 then
                local size, sides = fillLight(i, 6)
                local on_border = sides.left + sides.right + sides.top + sides.bottom
                if on_border <= 0.25 * border_len and size > best_size then
                    best, best_size, best_sides = i, size, sides
                end
            end
        end
    end
    if not best then
        return nil, "no light area near the press stays inside the enlargement"
    end
    if best_size < 0.08 * n then
        return nil, "the light area around the press is too small", best_sides
    end
    ffi.fill(shape, n, 0)
    fillLight(best, 1)

    -- Enclosed = not inside and not connected (8-way) to the border: lettering.
    local head, tail = 0, 0
    local function outside(i)
        if shape[i] == 0 then
            shape[i] = 2
            queue[tail] = i
            tail = tail + 1
        end
    end
    for x = 0, aw - 1 do outside(x); outside((ah - 1) * aw + x) end
    for y = 0, ah - 1 do outside(y * aw); outside(y * aw + aw - 1) end
    while head < tail do
        local i = queue[head]
        head = head + 1
        local x = i % aw
        local y = (i - x) / aw
        for dy = -1, 1 do
            local ny = y + dy
            if ny >= 0 and ny < ah then
                for dx = -1, 1 do
                    local nx = x + dx
                    if nx >= 0 and nx < aw then outside(ny * aw + nx) end
                end
            end
        end
    end
    for i = 0, n - 1 do
        if shape[i] == 0 then shape[i] = 3 end
    end

    -- The outline, and lettering touching it: dark pixels grown outwards one
    -- layer at a time. Each layer around a whole outline is about as big as the
    -- first; once a layer is less than half that, only art lines touching the
    -- outline are left, so growing stops there.
    local max_steps = math.min(255, math.max(1, math.ceil(o.outline / f)))
    -- This bubble's outline thickness: from each edge pixel of the inside,
    -- the dark pixels straight outwards. Most of the edge shows the outline
    -- itself, so artwork against part of it doesn't widen the band.
    local runs = {}
    for y = 0, ah - 1 do
        for x = 0, aw - 1 do
            local s = shape[y * aw + x]
            if s == 1 or s == 3 then
                for dir = 1, 4 do
                    local dx = dir == 1 and -1 or dir == 2 and 1 or 0
                    local dy = dir == 3 and -1 or dir == 4 and 1 or 0
                    local nx, ny = x + dx, y + dy
                    if nx >= 0 and nx < aw and ny >= 0 and ny < ah and shape[ny * aw + nx] == 2 then
                        local run = 0
                        while run < max_steps do
                            if nx < 0 or nx >= aw or ny < 0 or ny >= ah then
                                -- still dark at the edge of the enlarged area
                                run = max_steps
                                break
                            end
                            if light[ny * aw + nx] ~= 0 then
                                break
                            end
                            run = run + 1
                            nx, ny = nx + dx, ny + dy
                        end
                        runs[#runs + 1] = run
                    end
                end
            end
        end
    end
    if #runs > 0 then
        table.sort(runs)
        local typical = runs[math.ceil(0.6 * #runs)]
        if typical >= max_steps then
            -- Dark all the way out: a light balloon on a dark background, with
            -- no outline of its own to keep.
            max_steps = math.min(max_steps, 2)
        else
            max_steps = math.min(max_steps, typical + 1)
        end
    end
    head, tail = 0, 0
    for i = 0, n - 1 do
        local s = shape[i]
        if s == 1 or s == 3 then
            dist[i] = 0
            queue[tail] = i
            tail = tail + 1
        end
    end
    local layers = {}
    while head < tail do
        local i = queue[head]
        head = head + 1
        local d = dist[i]
        if d < max_steps then
            local x = i % aw
            for k = 1, 4 do
                local j
                if k == 1 then j = x > 0 and i - 1 or -1
                elseif k == 2 then j = x < aw - 1 and i + 1 or -1
                elseif k == 3 then j = i - aw
                else j = i + aw end
                if j >= 0 and j < n and shape[j] == 2 and light[j] == 0 then
                    shape[j] = 7
                    dist[j] = d + 1
                    layers[d + 1] = (layers[d + 1] or 0) + 1
                    queue[tail] = j
                    tail = tail + 1
                end
            end
        end
    end
    local keep = max_steps
    for k = 2, max_steps do
        if (layers[k] or 0) < 0.5 * (layers[1] or 0) then
            keep = k
            break
        end
    end
    for i = 0, n - 1 do
        if shape[i] == 7 then
            shape[i] = dist[i] <= keep and 4 or 2
        end
    end

    -- How clean the shape is: perimeter² / (4π · area) and area / convex hull.
    local solid = { [1] = true, [3] = true, [4] = true }
    local area, perimeter, points, xs, ys = 0, 0, 0, {}, {}
    for y = 0, ah - 1 do
        local row = y * aw
        local left, right = -1, -1
        for x = 0, aw - 1 do
            if solid[shape[row + x]] then
                area = area + 1
                if left < 0 then left = x end
                right = x
                if x == 0 or not solid[shape[row + x - 1]] then perimeter = perimeter + 1 end
                if x == aw - 1 or not solid[shape[row + x + 1]] then perimeter = perimeter + 1 end
                if y == 0 or not solid[shape[row - aw + x]] then perimeter = perimeter + 1 end
                if y == ah - 1 or not solid[shape[row + aw + x]] then perimeter = perimeter + 1 end
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
    local stats = {
        raggedness = perimeter * perimeter / (4 * math.pi * area),
        convexity = hull > 0 and area / hull or 0,
        share = area / n,
    }
    if stats.raggedness > MAX_RAGGEDNESS or stats.convexity < MIN_CONVEXITY then
        return nil, "the shape runs into the artwork", best_sides, stats
    end

    -- The white edge around everything.
    grow(shape, light, aw, ah, solid, 5, math.min(255, math.max(1, math.floor(o.halo / f + 0.5))), false, queue, dist)

    -- Masks at the working size, scaled back up smoothly.
    local body_bb = Blitbuffer.new(aw, ah, Blitbuffer.TYPE_BB8)
    local all_bb = Blitbuffer.new(aw, ah, Blitbuffer.TYPE_BB8)
    local bp, bs = ffi.cast("uint8_t *", body_bb.data), tonumber(body_bb.stride)
    local ap, as = ffi.cast("uint8_t *", all_bb.data), tonumber(all_bb.stride)
    for y = 0, ah - 1 do
        for x = 0, aw - 1 do
            local s = shape[y * aw + x]
            if solid[s] then bp[y * bs + x] = 255 end
            if s ~= 2 and s ~= 0 then ap[y * as + x] = 255 end
        end
    end
    if aw ~= W or ah ~= H then
        local b2 = mupdf().scaleBlitBuffer(body_bb, W, H)
        local a2 = mupdf().scaleBlitBuffer(all_bb, W, H)
        body_bb:free(); all_bb:free()
        body_bb, all_bb = b2, a2
        bp, bs = ffi.cast("uint8_t *", body_bb.data), tonumber(body_bb.stride)
        ap, as = ffi.cast("uint8_t *", all_bb.data), tonumber(all_bb.stride)
    end

    -- Keep colour on colour screens; otherwise grey with alpha.
    local rgb = content:getType() == Blitbuffer.TYPE_BBRGB32
    local src_bb = content
    if not rgb then
        src_bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
        src_bb:blitFrom(content, 0, 0, 0, 0, W, H)
    end
    local channels = rgb and 3 or 1
    local bpp = rgb and 4 or 2
    local cp, cs = ffi.cast("uint8_t *", src_bb.data), tonumber(src_bb.stride)
    local out = Blitbuffer.new(W, H, rgb and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8A)
    local op, ostride = ffi.cast("uint8_t *", out.data), tonumber(out.stride)
    local cbpp = rgb and 4 or 1
    local halo_grey = o.inverted and 0 or 255
    for y = 0, H - 1 do
        local brow, arow, crow, orow = bp + y * bs, ap + y * as, cp + y * cs, op + y * ostride
        for x = 0, W - 1 do
            local a = arow[x]
            if a > 0 then
                local b = brow[x]
                local o_px, c_px = bpp * x, cbpp * x
                for c = 0, channels - 1 do
                    orow[o_px + c] = math.floor((crow[c_px + c] * b + halo_grey * (255 - b)) / 255 + 0.5)
                end
                orow[o_px + bpp - 1] = a
            end
        end
    end
    if src_bb ~= content then
        src_bb:free()
    end
    body_bb:free(); all_bb:free()
    return out, nil, best_sides, stats
end

-- Draws the enlarged area into a new buffer of w x h at zoom.
local function renderEnlarged(bubblezoom, view, bb_type, w, h, zoom)
    local src = bubblezoom.overlay_src_rect
    local doc = bubblezoom.document
    local state = view.state
    local rect = Geom:new{
        x = math.floor(src.x * zoom + 0.001),
        y = math.floor(src.y * zoom + 0.001),
        w = w,
        h = h,
    }
    local content = Blitbuffer.new(w, h, bb_type)
    if isOptimized(doc) then
        drawFromReaderPage(view, doc, content, 0, 0, rect, bubblezoom.overlay_page, zoom, state.rotation or 0)
    else
        doc:drawPage(content, 0, 0, rect, bubblezoom.overlay_page, zoom, state.rotation or 0,
            state.gamma or 1.0, state.saturation or 1.0)
    end
    return content
end

local function freeShaped(overlay)
    local cached = rawget(overlay, "_bubblezoom_overlay_shape")
    if cached and cached.bb then
        cached.bb:free()
    end
    overlay._bubblezoom_overlay_shape = nil
end

-- Builds, or reuses, the shaped enlargement for the bubble being shown.
-- Returns nil when the enlargement is off the screen.
local function shapeFor(overlay, bubblezoom, bb_type)
    local view = overlay.view
    local screen_rect = view:pageToScreenTransform(bubblezoom.overlay_page, bubblezoom.overlay_rect)
    if not screen_rect then
        return nil
    end
    local rx, ry = math.floor(screen_rect.x + 0.5), math.floor(screen_rect.y + 0.5)
    local rw, rh = math.floor(screen_rect.w + 0.5), math.floor(screen_rect.h + 0.5)
    if rw <= 0 or rh <= 0 then
        return nil
    end
    local scale = bubblezoom.overlay_scale_active or bubblezoom.overlay_scale
    local zoom = view.state.zoom * scale
    local inverted = isInverted(bubblezoom.document)
    local src = bubblezoom.overlay_src_rect
    local key = table.concat({ bubblezoom.overlay_page, src.x, src.y, src.w, src.h, rw, rh, zoom, bb_type,
        tostring(inverted), bubblezoom.overlay_tap_x or "", bubblezoom.overlay_tap_y or "" }, "|")
    local cached = rawget(overlay, "_bubblezoom_overlay_shape")
    if not cached or cached.key ~= key then
        freeShaped(overlay)
        local content = renderEnlarged(bubblezoom, view, bb_type, rw, rh, zoom)
        local tap_x = ((bubblezoom.overlay_tap_x or (src.x + src.w / 2)) - src.x) * zoom
        local tap_y = ((bubblezoom.overlay_tap_y or (src.y + src.h / 2)) - src.y) * zoom
        local shaped, why, sides, stats = composeShape(content, tap_x, tap_y, {
            factor = math.max(1, math.floor(scale)),
            inverted = inverted,
            outline = MAX_OUTLINE * zoom,
            halo = Screen:scaleBySize(HALO),
        })
        content:free()
        if not shaped then
            logger.dbg("2-bubblezoom-overlay: showing a rectangle:", why)
        end
        cached = { key = key, bb = shaped, sides = sides, stats = stats }
        overlay._bubblezoom_overlay_shape = cached
    end
    cached.x, cached.y, cached.w, cached.h = rx, ry, rw, rh
    return cached
end

-- True when a shape found after extending the area is as clean as the one before.
local function isCleanGrowth(before, after)
    return before ~= nil and after ~= nil
        and after.raggedness <= before.raggedness + MAX_RAGGEDNESS_RISE
        and after.convexity >= before.convexity - MAX_CONVEXITY_DROP
end

-- The enlarged area extended on each side the bubble's inside reaches, within
-- the page; nil when there's nothing to extend.
local function grownRect(src, sides, page_size)
    if not sides then
        return nil
    end
    local x1, y1 = src.x, src.y
    local x2, y2 = src.x + src.w, src.y + src.h
    if sides.left >= 2 then x1 = math.max(0, x1 - GROW_BY * src.w) end
    if sides.right >= 2 then x2 = math.min(page_size.w, x2 + GROW_BY * src.w) end
    if sides.top >= 2 then y1 = math.max(0, y1 - GROW_BY * src.h) end
    if sides.bottom >= 2 then y2 = math.min(page_size.h, y2 + GROW_BY * src.h) end
    if x1 == src.x and y1 == src.y and x2 == src.x + src.w and y2 == src.y + src.h then
        return nil
    end
    return Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

-- Extends the enlarged area until the whole bubble is inside it (balloons
-- joined to another, or cut off by Bubble Zoom's rectangle), keeping the last
-- version whose shape was found.
local function growToWholeBubble(bubblezoom)
    local overlay = bubblezoom.overlay
    if not overlay then
        return
    end
    local bb_type = Screen.bb and Screen.bb:getType() or Blitbuffer.TYPE_BB8
    local page_size = bubblezoom.document:getPageDimensions(bubblezoom.overlay_page, 1.0,
        bubblezoom.view.state.rotation or 0)
    local cached = shapeFor(overlay, bubblezoom, bb_type)
    for _ = 1, MAX_GROW do
        if not (cached and cached.bb and page_size) then
            return
        end
        local bigger = grownRect(bubblezoom.overlay_src_rect, cached.sides, page_size)
        if not bigger then
            return
        end
        local before = {
            src = bubblezoom.overlay_src_rect, rect = bubblezoom.overlay_rect,
            scale = bubblezoom.overlay_scale_active, stats = cached.stats,
        }
        bubblezoom.overlay_src_rect = bigger
        keepOnScreen(bubblezoom)
        cached = shapeFor(overlay, bubblezoom, bb_type)
        if not (cached and cached.bb and isCleanGrowth(before.stats, cached.stats)) then
            bubblezoom.overlay_src_rect = before.src
            bubblezoom.overlay_rect = before.rect
            bubblezoom.overlay_scale_active = before.scale
            shapeFor(overlay, bubblezoom, bb_type)
            return
        end
    end
end

-- KOReader runs this each time a book opens, with the same plugin table.
userpatch.registerPatchPluginFunc("bubblezoom", function(BubbleZoom)
    if BubbleZoom._bubblezoom_overlay_patched then
        return
    end
    if not isCallable(BubbleZoom.getSauvolaCache) or not isCallable(BubbleZoom.onReaderReady)
        or not isCallable(BubbleZoom.showOverlayRect) or not isCallable(BubbleZoom.padRect) then
        logger.warn("2-bubblezoom-overlay: this Bubble Zoom version isn't supported, patch not applied")
        return
    end
    BubbleZoom._bubblezoom_overlay_patched = true

    -- The page image bubbles are looked for in.
    local orig_getSauvolaCache = BubbleZoom.getSauvolaCache
    BubbleZoom.getSauvolaCache = function(self, pageno, rotation, gamma)
        if not isOptimized(self.document) then
            return orig_getSauvolaCache(self, pageno, rotation, gamma)
        end
        return withNormalRendering(self.document, orig_getSauvolaCache, self, pageno, rotation, gamma)
    end

    -- Room around the bubble for its outline.
    local orig_padRect = BubbleZoom.padRect
    BubbleZoom.padRect = function(self, rect, page_size)
        local padded = orig_padRect(self, rect, page_size)
        if not page_size or not page_size.w then
            return padded
        end
        return withMinPadding(rect, padded, page_size)
    end

    -- Where the enlarged bubble goes.
    local orig_showOverlayRect = BubbleZoom.showOverlayRect
    BubbleZoom.showOverlayRect = function(self, pageno, rect, tap_x, tap_y, visited_mask)
        local handled = orig_showOverlayRect(self, pageno, rect, tap_x, tap_y, visited_mask)
        if handled and self.overlay_rect then
            local ok, err = pcall(function()
                if SHAPED and self.overlay_mask_region then
                    -- Bubble Zoom's own "full shape" skips the padding; the shaped
                    -- enlargement here doesn't use its mask.
                    local page_size = self.document:getPageDimensions(pageno, 1.0, self.view.state.rotation or 0)
                    self.overlay_src_rect = withMinPadding(rect, rect, page_size)
                    self.overlay_mask, self.overlay_mask_rect = nil, nil
                    self.overlay_mask_region, self.overlay_mask_region_w, self.overlay_mask_region_h = nil, nil, nil
                end
                keepOnScreen(self)
                if SHAPED then
                    growToWholeBubble(self)
                end
            end)
            if not ok then
                logger.warn("2-bubblezoom-overlay: couldn't place the enlarged bubble:", err)
            end
        end
        return handled
    end

    -- The enlarged bubble is drawn by a widget Bubble Zoom creates when the
    -- book is ready, so its draw function is wrapped on that widget.
    local orig_onReaderReady = BubbleZoom.onReaderReady
    BubbleZoom.onReaderReady = function(self, ...)
        local result = orig_onReaderReady(self, ...)
        local overlay = self.overlay
        if overlay and not rawget(overlay, "_bubblezoom_overlay_paintTo") then
            local orig_paintTo = overlay.paintTo
            local bubblezoom = self
            overlay._bubblezoom_overlay_paintTo = true

            local function paintRectangle(this, bb, x, y)
                local src = bubblezoom.overlay_src_rect
                local sx, sy, sw, sh = src.x, src.y, src.w, src.h
                local doc = bubblezoom.document
                local ok, err
                if isOptimized(doc) then
                    local had_own = rawget(doc, "drawPage")
                    doc.drawPage = function(d, target, tx, ty, rect, pageno, zoom, rotation)
                        drawFromReaderPage(this.view, d, target, tx, ty, rect, pageno, zoom, rotation)
                    end
                    ok, err = pcall(orig_paintTo, this, bb, x, y)
                    doc.drawPage = had_own
                else
                    ok, err = pcall(orig_paintTo, this, bb, x, y)
                end
                -- Undo Bubble Zoom's in-place scaling of the bubble's position.
                src.x, src.y, src.w, src.h = sx, sy, sw, sh
                if not ok then
                    error(err, 0)
                end
            end

            overlay.paintTo = function(this, bb, x, y)
                if not (bubblezoom.overlay_src_rect and bubblezoom.overlay_rect and bubblezoom.overlay_page) then
                    freeShaped(this)
                    return orig_paintTo(this, bb, x, y)
                end
                if SHAPED then
                    local ok, cached = pcall(shapeFor, this, bubblezoom, bb:getType())
                    if not ok then
                        logger.warn("2-bubblezoom-overlay: couldn't draw the bubble's shape:", cached)
                        freeShaped(this)
                    elseif not cached then
                        return -- off the screen, as Bubble Zoom does
                    elseif cached.bb then
                        bb:alphablitFrom(cached.bb, cached.x, cached.y, 0, 0, cached.w, cached.h)
                        return
                    end
                end
                return paintRectangle(this, bb, x, y)
            end
        end
        return result
    end
end)

-- Returned for offline tests; KOReader ignores it.
return {
    placeOnScreen = placeOnScreen,
    withMinPadding = withMinPadding,
    composeShape = composeShape,
    grownRect = grownRect,
    isCleanGrowth = isCleanGrowth,
}
