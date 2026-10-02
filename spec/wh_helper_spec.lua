local kojson = require("spec/support/kojson")
local fake = require("spec/support/fake_helper")

describe("wh_helper", function()
    if not kojson.json then
        pending("KOReader json not available: " .. kojson.why)
        return
    end
    local helper = require("wh_helper")
    local tmp

    before_each(function() tmp = fake.tmpdir() end)
    after_each(function() os.execute("rm -rf '" .. tmp .. "'") end)

    local function last(events) return events[#events] end
    local function has(name)
        return function(events) return #events > 0 and last(events).ev == name end
    end

    it("quotes arguments for the shell", function()
        assert.equal([['it'\''s']], helper.quote("it's"))
    end)

    it("finds the helper for the processor, or says why not", function()
        os.execute("mkdir -p '" .. tmp .. "/bin' && touch '" .. tmp .. "/bin/wormhole-helper-armv7'")
        assert.equal(tmp .. "/bin/wormhole-helper-armv7", helper.binary_path(tmp, "armv7l"))
        local p, why = helper.binary_path(tmp, "aarch64")
        assert.is_nil(p)
        assert.matches("helper not found", why)
        p, why = helper.binary_path(tmp, "mips")
        assert.is_nil(p)
        assert.matches("unsupported processor: mips", why)
    end)

    it("starts the helper with the right arguments and reads its events", function()
        local bin = fake.write(tmp, { '{"ev":"code","code":"7-a-b"}', '{"ev":"done"}' })
        local h = assert(helper.start({ bin = bin, command = "send-text", text = "it's ¿bien?", tmp = tmp }))
        local events = fake.poll_until(h, has("done"))
        assert.same({ { ev = "code", code = "7-a-b" }, { ev = "done" } }, events)
        local argv = io.open(h.dir .. "/argv"):read("*l")
        assert.equal("send-text --control " .. h.dir .. " --text-file " .. h.dir .. "/text", argv)
        assert.equal("it's ¿bien?", io.open(h.dir .. "/text"):read("*a"))
        h:cleanup()
    end)

    it("passes server, receive and send-files options", function()
        local bin = fake.write(tmp, { '{"ev":"done"}' })
        local h = assert(helper.start({ bin = bin, command = "receive", code = "7-a-b", save_dir = "/x/Wormhole",
                                        rendezvous = "ws://r", relay = "t:1", tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("receive --control " .. h.dir .. " --rendezvous ws://r --relay t:1 --code 7-a-b --dir /x/Wormhole",
            io.open(h.dir .. "/argv"):read("*l"))
        h:cleanup()
        h = assert(helper.start({ bin = bin, command = "send-files", name = "Wormhole files",
                                  paths = { "/a b/c.epub", "/d" }, tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("send-files --control " .. h.dir .. " --name Wormhole files /a b/c.epub /d",
            io.open(h.dir .. "/argv"):read("*l"))
        h:cleanup()
    end)

    it("passes text and paths with shell specials unchanged", function()
        local bin = fake.write(tmp, { '{"ev":"done"}' })
        local text = "it's \"q\" $(echo no) `no` \\n\nline 2 📚"
        local h = assert(helper.start({ bin = bin, command = "send-text", text = text, tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal(text, io.open(h.dir .. "/text"):read("*a"))
        h:cleanup()
        local odd = "/b/it's $(x) ñ.epub"
        h = assert(helper.start({ bin = bin, command = "send-file", paths = { odd }, tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("send-file --control " .. h.dir .. " " .. odd, io.open(h.dir .. "/argv"):read("*l"))
        h:cleanup()
    end)

    it("passes the file name when text goes as a file", function()
        local bin = fake.write(tmp, { '{"ev":"done"}' })
        local h = assert(helper.start({ bin = bin, command = "send-text", text = "hola", file_name = "hola.txt", tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("send-text --control " .. h.dir .. " --text-file " .. h.dir .. "/text --file-name hola.txt",
            io.open(h.dir .. "/argv"):read("*l"))
        h:cleanup()
    end)

    it("passes the temp folder for zipping folders", function()
        local bin = fake.write(tmp, { '{"ev":"done"}' })
        local h = assert(helper.start({ bin = bin, command = "send-files", name = "B", paths = { "/b" },
                                        zip_tmp = "/mnt/onboard/.adds/koreader/cache/wormhole", tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("send-files --control " .. h.dir .. " --tmp /mnt/onboard/.adds/koreader/cache/wormhole --name B /b",
            io.open(h.dir .. "/argv"):read("*l"))
        h:cleanup()
    end)

    it("passes KOReader's PID to watch and starts the helper in /", function()
        local bin = fake.write(tmp, { '{"ev":"done"}' })
        local h = assert(helper.start({ bin = bin, command = "send-file", paths = { "/b.epub" }, watch_pid = 4242, tmp = tmp }))
        fake.poll_until(h, has("done"))
        assert.equal("send-file --control " .. h.dir .. " --watch-pid 4242 /b.epub", io.open(h.dir .. "/argv"):read("*l"))
        -- never keeps the storage busy (USB mass storage needs to unmount it)
        assert.equal("/", io.open(h.dir .. "/cwd"):read("*l"))
        -- the PID we keep (for Cancel) is the helper's own, not a shell's
        assert.equal(h.pid, tonumber(io.open(h.dir .. "/pid"):read("*l")))
        h:cleanup()
    end)

    it("knows its own process ID", function()
        local p = io.popen("echo $PPID") -- the shell's parent is this process
        local expected = tonumber(p:read("*l"))
        p:close()
        assert.equal(expected, helper.self_pid())
    end)

    it("makes a relative plugin path absolute (KOReader's own plugins folder is relative)", function()
        assert.equal("/mnt/onboard/.adds/koreader/plugins/wormhole.koplugin",
            helper.absolute("plugins/wormhole.koplugin", "/mnt/onboard/.adds/koreader"))
        assert.equal("/mnt/onboard/.adds/koreader/plugins/w", helper.absolute("./plugins/w", "/mnt/onboard/.adds/koreader"))
        assert.equal("/abs/w", helper.absolute("/abs/w", "/elsewhere"))
    end)

    it("delivers the answer to a waiting helper", function()
        local bin = fake.write(tmp, { '{"ev":"offer","kind":"file","name":"D.epub","bytes":5}', "wait-answer" })
        local h = assert(helper.start({ bin = bin, command = "receive", code = "1-x", save_dir = tmp, tmp = tmp }))
        fake.poll_until(h, has("offer"))
        assert.is_true(h:answer("accept"))
        local events = fake.poll_until(h, has("answered"))
        assert.equal("accept", last(events).word)
        h:cleanup()
    end)

    it("keeps half-written lines for the next poll and skips junk", function()
        local bin = fake.write(tmp, { "sleep 5" })
        local h = assert(helper.start({ bin = bin, command = "send-file", paths = { "/x" }, tmp = tmp }))
        fake.wait_started(h) -- its ">events" truncates the file: write after that
        local f = io.open(h.dir .. "/events", "ab")
        f:write('not json\n{"ev":"prog'); f:flush()
        assert.same({}, h:poll())
        f:write('ress","done":1,"total":2}\n'); f:close()
        assert.same({ { ev = "progress", done = 1, total = 2 } }, h:poll())
        h:kill(); h:cleanup()
    end)

    it("reports alive, then gone after cancel, with the stderr tail", function()
        local bin = fake.write(tmp, { "stderr first", "stderr dial tcp: refused", "sleep 5" })
        local h = assert(helper.start({ bin = bin, command = "send-file", paths = { "/x" }, tmp = tmp }))
        assert.is_true(h:alive())
        for __ = 1, 100 do -- let it write its stderr before stopping it
            if h:stderr_tail() == "dial tcp: refused" then break end
            os.execute("sleep 0.02")
        end
        h:cancel()
        for __ = 1, 100 do
            if not h:alive() then break end
            os.execute("sleep 0.02")
        end
        assert.is_false(h:alive())
        assert.equal("dial tcp: refused", h:stderr_tail())
        h:cleanup()
        assert.is_nil(io.open(h.dir .. "/events"))
    end)
end)
