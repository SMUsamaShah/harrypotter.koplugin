-- Turn rendered font pixels into ordered line strokes.
--
-- The pipeline is intentionally close to Riddle's script.rs:
-- render -> threshold -> Zhang-Suen thinning -> skeleton tracing.

local Blitbuffer = require("ffi/blitbuffer")
local RenderText = require("ui/rendertext")

local floor = math.floor
local max = math.max
local min = math.min

local Script = {}

local function pixel_is_ink(bb, x, y)
    -- BB8 getPixel returns a Color8 cdata whose grayscale value is .a.
    return bb:getPixel(x, y).a < 200
end

local function rasterize_line(face, text, size, max_width)
    local rendered_size = (face and face.size) or size
    local buffer_width = max(256, floor(max_width or 900))
    local buffer_height = max(80, floor(rendered_size * 1.8) + 24)
    local baseline = floor(rendered_size * 1.25)
    local bb = Blitbuffer.new(buffer_width, buffer_height, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local rendered_width = RenderText:renderUtf8Text(
        bb,
        8,
        baseline,
        face,
        text,
        true,
        false,
        Blitbuffer.COLOR_BLACK,
        buffer_width - 16
    )

    local scan_width = min(buffer_width, max(1, floor(rendered_width or buffer_width - 16) + 16))
    local min_x, min_y = buffer_width, buffer_height
    local max_x, max_y = -1, -1

    for y = 0, buffer_height - 1 do
        for x = 0, scan_width - 1 do
            if pixel_is_ink(bb, x, y) then
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
            end
        end
    end

    if max_x < 0 then
        bb:free()
        return { width = 1, height = 1, pixels = { false } }
    end

    local width = max_x - min_x + 1
    local height = max_y - min_y + 1
    local pixels = {}
    for y = min_y, max_y do
        for x = min_x, max_x do
            pixels[(y - min_y) * width + (x - min_x) + 1] = pixel_is_ink(bb, x, y)
        end
    end

    bb:free()
    return { width = width, height = height, pixels = pixels }
end

local function at(pixels, width, height, x, y)
    if x < 0 or y < 0 or x >= width or y >= height then
        return false
    end
    return pixels[y * width + x + 1] == true
end

local function neighbor_values(pixels, width, height, x, y)
    return {
        at(pixels, width, height, x, y - 1),
        at(pixels, width, height, x + 1, y - 1),
        at(pixels, width, height, x + 1, y),
        at(pixels, width, height, x + 1, y + 1),
        at(pixels, width, height, x, y + 1),
        at(pixels, width, height, x - 1, y + 1),
        at(pixels, width, height, x - 1, y),
        at(pixels, width, height, x - 1, y - 1),
    }
end

local function transitions(neighbors)
    local count = 0
    for i = 1, 8 do
        if not neighbors[i] and neighbors[(i % 8) + 1] then
            count = count + 1
        end
    end
    return count
end

local function thin(raster)
    local pixels = raster.pixels
    local width, height = raster.width, raster.height
    local changed = true
    local passes = 0

    -- A cap protects an e-reader from a malformed font or an unexpectedly
    -- large answer while still allowing ordinary glyphs to converge.
    while changed and passes < 24 do
        changed = false
        passes = passes + 1

        for phase = 0, 1 do
            local remove = {}
            for y = 1, height - 2 do
                for x = 1, width - 2 do
                    if at(pixels, width, height, x, y) then
                        local n = neighbor_values(pixels, width, height, x, y)
                        local count = 0
                        for i = 1, 8 do
                            if n[i] then
                                count = count + 1
                            end
                        end

                        local a = transitions(n)
                        local p2, p4, p6, p8 = n[1], n[3], n[5], n[7]
                        local corner_rule
                        if phase == 0 then
                            corner_rule = (not (p2 and p4 and p6)) and (not (p4 and p6 and p8))
                        else
                            corner_rule = (not (p2 and p4 and p8)) and (not (p2 and p6 and p8))
                        end

                        if count >= 2 and count <= 6 and a == 1 and corner_rule then
                            remove[#remove + 1] = y * width + x + 1
                        end
                    end
                end
            end

            for _, index in ipairs(remove) do
                pixels[index] = false
            end
            if #remove > 0 then
                changed = true
            end
        end
    end

    return raster
end

local function make_stroke(points)
    if #points < 2 then
        return nil
    end

    local stroke = { n = 0, w = 2, min_x = math.huge }
    for _, point in ipairs(points) do
        stroke.n = stroke.n + 1
        local offset = (stroke.n - 1) * 2 + 1
        stroke[offset] = point[1]
        stroke[offset + 1] = point[2]
        stroke.min_x = min(stroke.min_x, point[1])
    end
    return stroke
end

local function trace(raster)
    local pixels = raster.pixels
    local width, height = raster.width, raster.height
    local visited = {}
    local result = {}

    local function visit_index(x, y)
        return y * width + x + 1
    end

    local function has_unvisited_neighbor(x, y)
        for dy = -1, 1 do
            for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and at(pixels, width, height, x + dx, y + dy) then
                    local index = visit_index(x + dx, y + dy)
                    if not visited[index] then
                        return true
                    end
                end
            end
        end
        return false
    end

    local function first_unvisited_neighbor(x, y)
        for dy = -1, 1 do
            for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and at(pixels, width, height, x + dx, y + dy) then
                    local index = visit_index(x + dx, y + dy)
                    if not visited[index] then
                        return x + dx, y + dy
                    end
                end
            end
        end
    end

    local function start_is_endpoint(x, y)
        local count = 0
        for dy = -1, 1 do
            for dx = -1, 1 do
                if (dx ~= 0 or dy ~= 0) and at(pixels, width, height, x + dx, y + dy) then
                    count = count + 1
                end
            end
        end
        return count == 1
    end

    local function trace_from(x, y)
        local points = {}
        local current_x, current_y = x, y

        while current_x and current_y do
            local current_index = visit_index(current_x, current_y)
            if visited[current_index] or not at(pixels, width, height, current_x, current_y) then
                break
            end

            visited[current_index] = true
            points[#points + 1] = { current_x, current_y }

            if not has_unvisited_neighbor(current_x, current_y) then
                break
            end
            current_x, current_y = first_unvisited_neighbor(current_x, current_y)
        end

        local stroke = make_stroke(points)
        if stroke then
            result[#result + 1] = stroke
        end
    end

    -- Endpoints make the replay direction more handwriting-like.
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local index = visit_index(x, y)
            if at(pixels, width, height, x, y) and not visited[index] and start_is_endpoint(x, y) then
                trace_from(x, y)
            end
        end
    end

    -- Closed loops and any pixels left over after endpoint tracing.
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local index = visit_index(x, y)
            if at(pixels, width, height, x, y) and not visited[index] then
                trace_from(x, y)
            end
        end
    end

    table.sort(result, function(left, right)
        return left.min_x < right.min_x
    end)
    return result
end

local function split_words(text)
    local words = {}
    for word in text:gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

local function wrap(text, face, max_width)
    local lines = {}
    local current = ""
    for _, word in ipairs(split_words(text)) do
        local candidate = current == "" and word or (current .. " " .. word)
        local size = RenderText:sizeUtf8Text(0, nil, face, candidate, true, false)
        if current ~= "" and size.x > max_width then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then
        lines[#lines + 1] = current
    end
    return lines
end

function Script.build(face, text, size, max_width, origin_x, origin_y)
    local lines = wrap(text, face, max_width)
    local strokes = {}
    local line_height = floor(size * 1.35)
    local top = origin_y
    local region = {
        x0 = origin_x,
        y0 = origin_y,
        x1 = origin_x + max_width,
        y1 = origin_y + max(1, #lines) * line_height,
    }

    for line_index, line in ipairs(lines) do
        local raster = rasterize_line(face, line, size, max_width)
        thin(raster)
        local line_strokes = trace(raster)
        local line_x = origin_x + floor((max_width - raster.width) / 2)
        local line_y = origin_y + (line_index - 1) * line_height

        for _, stroke in ipairs(line_strokes) do
            local translated = { n = stroke.n, w = 2, min_x = stroke.min_x + line_x }
            for i = 1, stroke.n do
                local offset = (i - 1) * 2 + 1
                translated[offset] = stroke[offset] + line_x
                translated[offset + 1] = stroke[offset + 1] + line_y
            end
            strokes[#strokes + 1] = translated
        end

        region.y1 = max(region.y1, line_y + raster.height)
        top = max(top, line_y + raster.height)
    end

    return {
        strokes = strokes,
        region = region,
        height = top - origin_y,
    }
end

return Script
