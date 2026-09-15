-- Capture one-finger frames while the plugin is in writing mode.
-- This follows KOReader's gesture-detector hook used by Finger Ink, but
-- leaves multi-touch frames alone so normal reader gestures still work.

local Device = require("device")

local Capture = {
    installed = false,
    detector = nil,
    original_feed_event = nil,
}

function Capture:install(handler)
    if self.installed then
        return true
    end

    local detector = Device.input and Device.input.gesture_detector
    if not detector or not detector.feedEvent then
        return false
    end

    self.detector = detector
    self.original_feed_event = detector.feedEvent

    detector.feedEvent = function(detector_self, slots)
        local consume = handler(slots)
        local events = self.original_feed_event(detector_self, slots)

        if not consume then
            return events
        end

        -- The gesture detector has already seen the frame. Returning an empty
        -- event list prevents ReaderUI from acting on the one-finger stroke.
        for i = #events, 1, -1 do
            events[i] = nil
        end
        return events
    end

    self.installed = true
    return true
end

function Capture:remove()
    if not self.installed then
        return
    end

    if self.detector and self.original_feed_event then
        self.detector.feedEvent = self.original_feed_event
    end

    self.installed = false
    self.detector = nil
    self.original_feed_event = nil
end

function Capture.toScreen(x, y)
    local screen = Device.screen
    local mode = screen:getRotationMode()

    if mode == screen.DEVICE_ROTATED_UPRIGHT then
        return x, y
    elseif mode == screen.DEVICE_ROTATED_CLOCKWISE then
        return screen:getWidth() - y, x
    elseif mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return screen:getWidth() - x, screen:getHeight() - y
    elseif mode == screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        return y, screen:getHeight() - x
    end

    return x, y
end

return Capture
