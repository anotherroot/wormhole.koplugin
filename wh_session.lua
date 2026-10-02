-- One transfer's state, driven by helper events. Draws nothing: it tells
-- the UI what changed through the `ui` callbacks it was given.
--
-- States: waiting (sender has a code / receiver connecting), offered
-- (receiver: Accept?), transferring, done, failed.
--
-- ui callbacks (all optional):
--   code(code)  offer(ev)  progress(done, total)  text(text)
--   saved(path)  done()  failed(kind, detail)  closed()
local M = {}

local Session = {}
Session.__index = Session

--- role: "send" | "receive"
function M.new(role, ui)
    return setmetatable({ role = role, ui = ui or {}, state = "waiting",
                          last_pct = -1 }, Session)
end

function Session:finished()
    return self.state == "done" or self.state == "failed"
end

function Session:_call(name, ...)
    local f = self.ui[name]
    if f then f(...) end
end

function Session:_fail(kind, detail)
    if self:finished() then return end
    self.state = "failed"
    -- Our own Cancel or Reject: just close, no message.
    if kind == "cancelled" or (kind == "rejected" and self.rejected_by_us) then
        self:_call("closed")
    else
        self:_call("failed", kind, detail)
    end
end

--- Feed a list of events from Handle:poll().
function Session:feed(events)
    for __, ev in ipairs(events) do
        if self:finished() then return end
        if ev.ev == "code" then
            self:_call("code", ev.code)
        elseif ev.ev == "offer" then
            self.state = "offered"
            self:_call("offer", ev)
        elseif ev.ev == "progress" then
            self.state = "transferring"
            local total = tonumber(ev.total) or 0
            local pct = total > 0 and math.floor((tonumber(ev.done) or 0) * 100 / total) or 0
            if pct ~= self.last_pct then -- at most 101 screen updates per transfer
                self.last_pct = pct
                self:_call("progress", tonumber(ev.done) or 0, total)
            end
        elseif ev.ev == "text" then
            self:_call("text", ev.text or "")
        elseif ev.ev == "saved" then
            self.saved_path = ev.path
            self:_call("saved", ev.path)
        elseif ev.ev == "done" then
            self.state = "done"
            self:_call("done")
        elseif ev.ev == "error" then
            self:_fail(ev.kind or "internal", ev.msg)
        end
    end
end

--- The owner pressed Reject (the helper will report "rejected").
function Session:reject()
    self.rejected_by_us = true
end

--- The owner pressed Cancel. Closes at once; later events are ignored.
function Session:cancel()
    self:_fail("cancelled")
end

--- The device is going to sleep: the transfer can't survive it.
function Session:suspended()
    self:_fail("asleep")
end

--- Call after feed() when the helper process is gone. If it never said
-- done/error, the session fails with the helper's last stderr line.
function Session:helper_exited(stderr_tail)
    if not self:finished() then
        self:_fail("internal", stderr_tail or "the helper stopped without a message")
    end
end

return M
