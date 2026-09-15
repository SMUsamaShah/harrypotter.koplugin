-- Small screen-space renderer for question and answer strokes.

local floor = math.floor
local max = math.max
local min = math.min

local Render = {}

local function hash(x, y, index)
    -- Keep this deterministic across sessions and avoid bit operations so the
    -- effect works on older LuaJIT builds as well.
    local value = x * 1103515245 + y * 12345 + (index or 0) * 2654435761
    return math.abs(value) % 2147483647
end

function Render.segment(bb, x0, y0, x1, y1, width, color)
    width = max(1, floor(width or 2))

    local dx = x1 - x0
    local dy = y1 - y0
    local steps = max(math.abs(dx), math.abs(dy))

    if steps == 0 then
        bb:paintRect(floor(x0 - width / 2), floor(y0 - width / 2), width, width, color)
        return
    end

    for i = 0, steps do
        local t = i / steps
        local x = floor(x0 + dx * t - width / 2)
        local y = floor(y0 + dy * t - width / 2)
        bb:paintRect(x, y, width, width, color)
    end
end

function Render.stroke(bb, stroke, color, point_count)
    if not stroke or not stroke.n or stroke.n < 1 then
        return
    end

    local count = min(point_count or stroke.n, stroke.n)
    local width = stroke.w or 2

    if count == 1 then
        Render.segment(bb, stroke[1], stroke[2], stroke[1], stroke[2], width, color)
        return
    end

    for i = 2, count do
        local previous = (i - 2) * 2 + 1
        local current = (i - 1) * 2 + 1
        Render.segment(
            bb,
            stroke[previous],
            stroke[previous + 1],
            stroke[current],
            stroke[current + 1],
            width,
            color
        )
    end
end

function Render.dissolvingStroke(bb, stroke, stage, stages, color)
    if not stroke or not stroke.n or stroke.n < 1 then
        return
    end

    if stage <= 0 then
        Render.stroke(bb, stroke, color)
        return
    end

    if stage >= stages - 1 then
        return
    end

    local width = stroke.w or 2
    for i = 2, stroke.n do
        local previous = (i - 2) * 2 + 1
        local current = (i - 1) * 2 + 1
        local x0, y0 = stroke[previous], stroke[previous + 1]
        local x1, y1 = stroke[current], stroke[current + 1]

        -- Each segment disappears at a stable pseudo-random stage. Redrawing
        -- the page under the overlay makes the gaps look like a true dissolve.
        if hash(floor(x1), floor(y1), i) % stages > stage then
            Render.segment(bb, x0, y0, x1, y1, width, color)
        end
    end
end

function Render.bounds(stroke, bounds)
    if not stroke or not stroke.n then
        return bounds
    end

    bounds = bounds or { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    for i = 1, stroke.n do
        local offset = (i - 1) * 2 + 1
        local x, y = stroke[offset], stroke[offset + 1]
        bounds.x0 = min(bounds.x0, x)
        bounds.y0 = min(bounds.y0, y)
        bounds.x1 = max(bounds.x1, x)
        bounds.y1 = max(bounds.y1, y)
    end

    return bounds
end

return Render
