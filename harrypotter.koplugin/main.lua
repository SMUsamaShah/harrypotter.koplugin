local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Capture = require("hp_capture")
local Render = require("hp_render")
local Script = require("hp_script")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK

local DEFAULT_ANSWER = "The magic is already in your ink."
local QUESTION_IDLE_SECONDS = 2.6
local FADE_STAGES = 12
local FADE_INTERVAL_SECONDS = 0.09
local ANSWER_INTERVAL_SECONDS = 0.018
local ANSWER_POINTS_PER_TICK = 10
local QUESTION_PEN_WIDTH = 3
local ANSWER_PEN_WIDTH = 2
local ANSWER_FONT_SIZE = 42
local ANSWER_GAP = 42

local source_path = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local HANDWRITING_FONT = source_path .. "DancingScript.ttf"

local HarryPotter = WidgetContainer:extend{
    name = "harrypotter",
    is_doc_only = true,
}

function HarryPotter:init()
    self.phase = "idle"
    self.active = false
    self.question_strokes = {}
    self.answer_strokes = nil
    self.question_bounds = nil
    self.question_region = nil
    self.answer_region = nil
    self.live_stroke = nil
    self.draw_slot = nil
    self.contacts = {}
    self.contact_count = 0
    self.passthrough = false
    self.fade_stage = 0
    self.answer_stroke_index = 1
    self.answer_point_count = 0
    self.idle_task = nil
    self.animation_task = nil
    self.animation_token = 0
    self.answer_text = DEFAULT_ANSWER

    self.ui.menu:registerToMainMenu(self)
    self:registerDispatcherActions()
    self.view:registerViewModule("harrypotter", self)
end

function HarryPotter:registerDispatcherActions()
    Dispatcher:registerAction("harrypotter_start", {
        category = "none",
        event = "HarryPotterStart",
        reader = true,
        title = _("Start Harry Potter Riddle"),
    })
    Dispatcher:registerAction("harrypotter_cancel", {
        category = "none",
        event = "HarryPotterCancel",
        reader = true,
        title = _("Cancel Harry Potter Riddle"),
    })
end

function HarryPotter:onHarryPotterStart()
    self:startWriting()
    return true
end

function HarryPotter:onHarryPotterCancel()
    self:cancel()
    return true
end

function HarryPotter:addToMainMenu(menu_items)
    menu_items.harrypotter = {
        text = _("Harry Potter Riddle"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Start local riddle"),
                callback = function()
                    self:startWriting()
                end,
            },
            {
                text = _("Cancel current riddle"),
                enabled_func = function()
                    return self.active or self.phase ~= "idle"
                end,
                callback = function()
                    self:cancel()
                end,
            },
            {
                text = _("Demo answer: The magic is already in your ink."),
                enabled_func = function()
                    return false
                end,
            },
        },
    }
end

function HarryPotter:showMessage(message)
    UIManager:show(Notification:new{
        text = message,
        timeout = 2,
    })
end

function HarryPotter:cancelTask(task_name)
    if self[task_name] then
        UIManager:unschedule(self[task_name])
        self[task_name] = nil
    end
end

function HarryPotter:cancelTasks()
    self:cancelTask("idle_task")
    self:cancelTask("animation_task")
end

function HarryPotter:nextToken()
    self.animation_token = self.animation_token + 1
    return self.animation_token
end

function HarryPotter:clearContactState()
    self.contacts = {}
    self.contact_count = 0
    self.draw_slot = nil
    self.passthrough = false
    self.live_stroke = nil
end

function HarryPotter:boundsRegion(bounds, padding)
    if not bounds then
        return nil
    end

    padding = padding or 12
    local width, height = Screen:getWidth(), Screen:getHeight()
    local x0 = math.max(0, math.floor(bounds.x0 - padding))
    local y0 = math.max(0, math.floor(bounds.y0 - padding))
    local x1 = math.min(width - 1, math.ceil(bounds.x1 + padding))
    local y1 = math.min(height - 1, math.ceil(bounds.y1 + padding))
    return Geom:new{
        x = x0,
        y = y0,
        w = math.max(1, x1 - x0 + 1),
        h = math.max(1, y1 - y0 + 1),
    }
end

function HarryPotter:unionRegions(first, second)
    if not first then
        return second
    end
    if not second then
        return first
    end

    local x0 = math.min(first.x, second.x)
    local y0 = math.min(first.y, second.y)
    local x1 = math.max(first.x + first.w, second.x + second.w)
    local y1 = math.max(first.y + first.h, second.y + second.h)
    return Geom:new{x = x0, y = y0, w = x1 - x0, h = y1 - y0}
end

function HarryPotter:repaint(refresh_type, region)
    -- Repainting the view module through UIManager first restores the page
    -- underneath the overlay, which is what makes each dissolve stage clean.
    UIManager:setDirty(self.ui, refresh_type or "fast", region)
end

function HarryPotter:includeQuestionBounds(stroke)
    self.question_bounds = Render.bounds(stroke, self.question_bounds)
    self.question_region = self:boundsRegion(self.question_bounds, 16)
end

function HarryPotter:dialogOnTop()
    if not UIManager.getTopmostVisibleWidget then
        return false
    end
    local topmost = UIManager:getTopmostVisibleWidget()
    return topmost ~= nil and topmost ~= self.ui
end

function HarryPotter:refreshLive(stroke)
    local bounds = Render.bounds(stroke)
    local region = self:boundsRegion(bounds, 10)
    if region then
        -- A direct fast refresh keeps pen latency low while the screen is being
        -- touched; the normal view repaint handles later animation frames.
        Screen:refreshFast(region.x, region.y, region.w, region.h)
    end
end

function HarryPotter:startWriting()
    if self.active then
        return
    end

    self:cancelTasks()
    self:nextToken()

    local old_region = self:unionRegions(self.question_region, self.answer_region)
    self.phase = "writing"
    self.active = true
    self.question_strokes = {}
    self.answer_strokes = nil
    self.question_bounds = nil
    self.question_region = nil
    self.answer_region = nil
    self.fade_stage = 0
    self.answer_stroke_index = 1
    self.answer_point_count = 0
    self:clearContactState()

    if old_region then
        self:repaint("ui", old_region)
    end

    if not Capture:install(function(slots)
        return self:onTouchFrame(slots)
    end) then
        self.active = false
        self.phase = "idle"
        self:showMessage(_("Harry Potter Riddle could not access touch input"))
        return
    end

    self:showMessage(_("Write one question, then lift your finger"))
end

function HarryPotter:onTouchFrame(slots)
    if not self.passthrough and self:dialogOnTop() then
        self.passthrough = true
        self.live_stroke = nil
        self:repaint("ui")
    end

    local had_passthrough = self.passthrough

    for index = 1, #slots do
        local event = slots[index]
        local slot = event.slot or 0
        local id = event.id
        if id and id >= 0 then
            if not self.contacts[slot] then
                self.contacts[slot] = true
                self.contact_count = self.contact_count + 1
                if self.contact_count > 1 then
                    self.passthrough = true
                    self.live_stroke = nil
                    self.draw_slot = nil
                    self:repaint("ui")
                end
            end

            if not self.passthrough and self.active and event.x and event.y then
                self:onContactPoint(slot, event.x, event.y)
            end
        else
            if self.contacts[slot] then
                self.contacts[slot] = nil
                self.contact_count = math.max(0, self.contact_count - 1)
            end

            if self.contact_count == 0 then
                if not self.passthrough and self.active then
                    self:endStroke()
                end
                self.passthrough = false
                self.draw_slot = nil
            end
        end
    end

    return self.passthrough or had_passthrough
end

function HarryPotter:onContactPoint(slot, x, y)
    if self.phase ~= "writing" then
        return
    end
    if self.draw_slot and self.draw_slot ~= slot then
        return
    end

    local screen_x, screen_y = Capture.toScreen(x, y)
    self.draw_slot = slot
    if not self.live_stroke then
        self.live_stroke = {
            n = 1,
            w = QUESTION_PEN_WIDTH,
            screen_x,
            screen_y,
        }
        Render.stroke(Screen.bb, self.live_stroke, BLACK)
        self:refreshLive(self.live_stroke)
        return
    end

    local previous = (self.live_stroke.n - 1) * 2 + 1
    local offset = self.live_stroke.n * 2 + 1
    self.live_stroke[offset] = screen_x
    self.live_stroke[offset + 1] = screen_y
    self.live_stroke.n = self.live_stroke.n + 1
    Render.segment(
        Screen.bb,
        self.live_stroke[previous],
        self.live_stroke[previous + 1],
        screen_x,
        screen_y,
        QUESTION_PEN_WIDTH,
        BLACK
    )
    self:refreshLive(self.live_stroke)
end

function HarryPotter:endStroke()
    if not self.live_stroke or self.live_stroke.n < 1 then
        return
    end

    local stroke = self.live_stroke
    self.live_stroke = nil
    self.question_strokes[#self.question_strokes + 1] = stroke
    self:includeQuestionBounds(stroke)
    self:scheduleQuestionCommit()
end

function HarryPotter:scheduleQuestionCommit()
    self:cancelTask("idle_task")
    local token = self.animation_token
    self.idle_task = function()
        self.idle_task = nil
        if token == self.animation_token and self.active and self.phase == "writing" and not self.live_stroke then
            self:beginFade()
        end
    end
    UIManager:scheduleIn(QUESTION_IDLE_SECONDS, self.idle_task)
end

function HarryPotter:beginFade()
    self.active = false
    Capture:remove()
    self:clearContactState()
    self.phase = "fade_question"
    self.fade_stage = 0
    self.question_region = self:boundsRegion(self.question_bounds, 22)
    self:repaint("fast", self.question_region)

    local token = self:nextToken()
    self.animation_task = function()
        self.animation_task = nil
        self:stepFade(token)
    end
    UIManager:scheduleIn(FADE_INTERVAL_SECONDS, self.animation_task)
end

function HarryPotter:stepFade(token)
    if token ~= self.animation_token or self.phase ~= "fade_question" then
        return
    end

    self.fade_stage = self.fade_stage + 1
    self:repaint("fast", self.question_region)

    if self.fade_stage >= FADE_STAGES - 1 then
        local question_region = self.question_region
        self.question_strokes = nil
        self:repaint("ui", question_region)
        self:buildAnswerPlan(token)
        return
    end

    self.animation_task = function()
        self.animation_task = nil
        self:stepFade(token)
    end
    UIManager:scheduleIn(FADE_INTERVAL_SECONDS, self.animation_task)
end

function HarryPotter:answerFace()
    local ok, face = pcall(function()
        return Font:getFace(HANDWRITING_FONT, ANSWER_FONT_SIZE)
    end)
    if ok and face then
        return face
    end

    logger.warn("Harry Potter Riddle: bundled font unavailable; using KOReader font")
    return Font:getFace("cfont", ANSWER_FONT_SIZE)
end

function HarryPotter:answerOriginY()
    local screen_height = Screen:getHeight()
    local desired = (self.question_bounds and self.question_bounds.y1 or math.floor(screen_height * 0.35)) + ANSWER_GAP
    local lower_limit = screen_height - math.floor(Screen:scaleBySize(ANSWER_FONT_SIZE * 2.2)) - 24
    return math.max(16, math.min(desired, lower_limit))
end

function HarryPotter:buildAnswerPlan(token)
    if token ~= self.animation_token then
        return
    end

    local max_width = math.max(160, Screen:getWidth() - 48)
    -- Font:getFace accepts the unscaled size and applies the device's DPI
    -- scaling internally. Script.build uses the resulting face for rendering.
    local answer_size = ANSWER_FONT_SIZE
    local ok, plan = pcall(function()
        return Script.build(
            self:answerFace(),
            self.answer_text,
            answer_size,
            max_width,
            24,
            self:answerOriginY()
        )
    end)

    if not ok or not plan then
        logger.err("Harry Potter Riddle: unable to build answer strokes", plan)
        self.phase = "done"
        self:showMessage(_("The local answer could not be drawn"))
        return
    end

    for _, stroke in ipairs(plan.strokes) do
        stroke.w = ANSWER_PEN_WIDTH
    end

    self.answer_strokes = plan.strokes
    self.answer_region = self:boundsRegion(plan.region, 18)
    self.answer_stroke_index = 1
    self.answer_point_count = 0
    self.phase = "answer"
    self:repaint("ui", self.answer_region)
    self:scheduleAnswerTick(token)
end

function HarryPotter:scheduleAnswerTick(token)
    self.animation_task = function()
        self.animation_task = nil
        self:stepAnswer(token)
    end
    UIManager:scheduleIn(ANSWER_INTERVAL_SECONDS, self.animation_task)
end

function HarryPotter:stepAnswer(token)
    if token ~= self.animation_token or self.phase ~= "answer" then
        return
    end

    local points_left = ANSWER_POINTS_PER_TICK
    while points_left > 0 and self.answer_stroke_index <= #self.answer_strokes do
        local stroke = self.answer_strokes[self.answer_stroke_index]
        local next_point = self.answer_point_count + 1
        if next_point >= stroke.n then
            self.answer_point_count = stroke.n
            self.answer_stroke_index = self.answer_stroke_index + 1
            self.answer_point_count = 0
        else
            self.answer_point_count = next_point
            points_left = points_left - 1
        end
    end

    self:repaint("fast", self.answer_region)

    if self.answer_stroke_index > #self.answer_strokes then
        self.phase = "done"
        self:repaint("ui", self.answer_region)
        return
    end

    self:scheduleAnswerTick(token)
end

function HarryPotter:cancel()
    local old_region = self:unionRegions(self.question_region, self.answer_region)
    self:cancelTasks()
    self:nextToken()
    Capture:remove()
    self.active = false
    self.phase = "idle"
    self.question_strokes = {}
    self.answer_strokes = nil
    self.question_bounds = nil
    self.question_region = nil
    self.answer_region = nil
    self:clearContactState()

    if old_region then
        self:repaint("ui", old_region)
    end
end

function HarryPotter:paintTo(bb)
    if self.phase == "idle" then
        return
    end

    if self.question_strokes and (self.phase == "writing" or self.phase == "fade_question") then
        for _, stroke in ipairs(self.question_strokes) do
            if self.phase == "fade_question" then
                Render.dissolvingStroke(bb, stroke, self.fade_stage, FADE_STAGES, BLACK)
            else
                Render.stroke(bb, stroke, BLACK)
            end
        end
    end

    if self.live_stroke and self.phase == "writing" then
        Render.stroke(bb, self.live_stroke, BLACK)
    end

    if self.answer_strokes and (self.phase == "answer" or self.phase == "done") then
        if self.phase == "done" then
            for _, stroke in ipairs(self.answer_strokes) do
                Render.stroke(bb, stroke, BLACK)
            end
        else
            for index = 1, self.answer_stroke_index - 1 do
                Render.stroke(bb, self.answer_strokes[index], BLACK)
            end
            local current = self.answer_strokes[self.answer_stroke_index]
            if current then
                Render.stroke(bb, current, BLACK, self.answer_point_count)
            end
        end
    end
end

function HarryPotter:onCloseDocument()
    self:cancel()
end

function HarryPotter:onSuspend()
    self:cancel()
end

return HarryPotter
