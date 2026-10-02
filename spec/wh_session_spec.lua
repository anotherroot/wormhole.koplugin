local session = require("wh_session")

-- A ui table that records every call as { name, args… }.
local function recorder()
    local calls = {}
    local ui = setmetatable({}, { __index = function(_, name)
        return function(...) calls[#calls + 1] = { name, ... } end
    end })
    return ui, calls
end

local function names(calls)
    local out = {}
    for i, c in ipairs(calls) do out[i] = c[1] end
    return out
end

describe("wh_session", function()
    it("send: code, progress, done", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:feed({ { ev = "code", code = "7-a-b" } })
        assert.equal("waiting", s.state)
        s:feed({ { ev = "progress", done = 50, total = 100 }, { ev = "done" } })
        assert.same({ { "code", "7-a-b" }, { "progress", 50, 100 }, { "done" } }, calls)
        assert.equal("done", s.state)
    end)

    it("calls progress only when the whole percent changes", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:feed({ { ev = "progress", done = 1, total = 1000 }, { ev = "progress", done = 9, total = 1000 },
                 { ev = "progress", done = 10, total = 1000 }, { ev = "progress", done = 1000, total = 1000 } })
        assert.same({ { "progress", 1, 1000 }, { "progress", 10, 1000 }, { "progress", 1000, 1000 } }, calls)
    end)

    it("receive file: offer, saved, done", function()
        local ui, calls = recorder()
        local s = session.new("receive", ui)
        local offer = { ev = "offer", kind = "file", name = "Dune.epub", bytes = 5 }
        s:feed({ offer })
        assert.equal("offered", s.state)
        s:feed({ { ev = "saved", path = "/W/Dune.epub" }, { ev = "done" } })
        assert.same({ "offer", "saved", "done" }, names(calls))
        assert.equal(offer, calls[1][2])
        assert.equal("/W/Dune.epub", s.saved_path)
    end)

    it("receive text", function()
        local ui, calls = recorder()
        session.new("receive", ui):feed({ { ev = "text", text = "hola" }, { ev = "done" } })
        assert.same({ { "text", "hola" }, { "done" } }, calls)
    end)

    for __, kind in ipairs({ "bad_code", "rejected", "network", "disk_full", "internal" }) do
        it("error " .. kind .. " fails with the kind and message", function()
            local ui, calls = recorder()
            local s = session.new("receive", ui)
            s:feed({ { ev = "error", kind = kind, msg = "detail" }, { ev = "done" } })
            assert.same({ { "failed", kind, "detail" } }, calls)
            assert.equal("failed", s.state)
        end)
    end

    it("our own Reject closes quietly", function()
        local ui, calls = recorder()
        local s = session.new("receive", ui)
        s:feed({ { ev = "offer", kind = "file", name = "x", bytes = 1 } })
        s:reject()
        s:feed({ { ev = "error", kind = "rejected", msg = "you rejected the transfer" } })
        assert.same({ "offer", "closed" }, names(calls))
    end)

    it("Cancel closes at once and ignores what comes after", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:cancel()
        s:feed({ { ev = "error", kind = "cancelled" }, { ev = "done" } })
        s:helper_exited("whatever")
        assert.same({ { "closed" } }, calls)
    end)

    it("sleep fails with 'asleep'", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:suspended()
        assert.same({ { "failed", "asleep" } }, calls)
    end)

    it("a helper that dies silently fails with its last stderr line", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:feed({ { ev = "code", code = "1-a" } })
        s:helper_exited("panic: boom")
        assert.same({ "failed", "internal", "panic: boom" }, calls[2])
        s:helper_exited(nil)
        assert.equal(2, #calls)
    end)

    it("a helper that exits after done is fine", function()
        local ui, calls = recorder()
        local s = session.new("send", ui)
        s:feed({ { ev = "done" } })
        s:helper_exited(nil)
        assert.same({ { "done" } }, calls)
    end)
end)
