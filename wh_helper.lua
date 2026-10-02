-- Runs the wormhole-helper program in the background and reads its events.
-- No widgets, no UIManager: the caller polls. One handle per transfer.
local json = require("json")

local M = {}

local function quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
M.quote = quote

--- KOReader's own process ID (the helper stops when it is gone).
function M.self_pid()
    local f = io.open("/proc/self/stat", "rb")
    if not f then return nil end
    local pid = tonumber((f:read("*l") or ""):match("^(%d+)"))
    f:close()
    return pid
end

--- path made absolute against cwd ("plugins/x" on a Kobo is relative to
-- KOReader's folder, and the helper runs from /).
function M.absolute(path, cwd)
    if path:sub(1, 1) == "/" then return path end
    return cwd:gsub("/+$", "") .. "/" .. path:gsub("^%./", "")
end

local ARCH = { armv7l = "armv7", armv6l = "armv7", aarch64 = "arm64", x86_64 = "x86_64" }

--- Path of the helper for this machine, or nil + reason.
-- machine: output of `uname -m` (read once by the caller if nil).
function M.binary_path(plugin_dir, machine)
    if not machine then
        local p = io.popen("uname -m")
        machine = p and p:read("*l") or ""
        if p then p:close() end
    end
    local arch = ARCH[machine]
    if not arch then return nil, "unsupported processor: " .. tostring(machine) end
    local path = plugin_dir .. "/bin/wormhole-helper-" .. arch
    local f = io.open(path, "rb")
    if not f then return nil, "helper not found: " .. path end
    f:close()
    return path
end

--- Shell command that starts the helper in the background and prints its PID.
-- args: list of strings after the binary (already in order).
function M.command(bin, args, dir)
    local parts = { quote(bin) }
    for __, a in ipairs(args) do parts[#parts + 1] = quote(a) end
    -- cd /: the helper must never keep the storage busy (USB mass storage).
    -- ";" not "&&": "&" must apply to the helper alone, so $! is its PID.
    return string.format("cd / || exit 1; %s </dev/null >%s 2>%s & echo $!",
        table.concat(parts, " "), quote(dir .. "/events"), quote(dir .. "/stderr"))
end

local Handle = {}
Handle.__index = Handle

--- Start a transfer.
-- spec = { bin = path, command = "send-text"|"send-file"|"send-files"|"receive",
--          text = s (send-text), paths = {…} (send-file: one), name = s (send-files),
--          code = s, save_dir = s (receive), rendezvous = s?, relay = s?,
--          zip_tmp = s? (helper temp folder, on the storage), watch_pid = n? (KOReader),
--          tmp = "/tmp" (working folders) }  All paths must be absolute.
-- Returns a handle, or nil + error message.
function M.start(spec)
    local mk = io.popen("mktemp -d " .. quote((spec.tmp or "/tmp") .. "/wormhole.XXXXXX"))
    local dir = mk and mk:read("*l")
    if mk then mk:close() end
    if not dir or dir == "" then return nil, "could not create a working folder" end

    local args = { spec.command, "--control", dir }
    if spec.rendezvous and spec.rendezvous ~= "" then
        table.insert(args, "--rendezvous"); table.insert(args, spec.rendezvous)
    end
    if spec.relay and spec.relay ~= "" then
        table.insert(args, "--relay"); table.insert(args, spec.relay)
    end
    if spec.watch_pid then
        table.insert(args, "--watch-pid"); table.insert(args, tostring(spec.watch_pid))
    end
    if spec.zip_tmp and spec.zip_tmp ~= "" then
        table.insert(args, "--tmp"); table.insert(args, spec.zip_tmp)
    end
    if spec.command == "send-text" then
        local f = io.open(dir .. "/text", "wb")
        if not f then return nil, "could not write the text file" end
        f:write(spec.text); f:close()
        table.insert(args, "--text-file"); table.insert(args, dir .. "/text")
    elseif spec.command == "send-files" then
        table.insert(args, "--name"); table.insert(args, spec.name)
    elseif spec.command == "receive" then
        table.insert(args, "--code"); table.insert(args, spec.code)
        table.insert(args, "--dir"); table.insert(args, spec.save_dir)
    end
    for __, p in ipairs(spec.paths or {}) do table.insert(args, p) end

    local sh = io.popen(M.command(spec.bin, args, dir))
    local pid = sh and tonumber(sh:read("*l"))
    if sh then sh:close() end
    if not pid then
        os.execute("rm -rf " .. quote(dir))
        return nil, "could not start the helper"
    end
    return setmetatable({ pid = pid, dir = dir, offset = 0, buf = "" }, Handle)
end

--- New complete events since the last poll (a list, maybe empty).
-- Lines that aren't valid JSON are skipped.
function Handle:poll()
    local f = io.open(self.dir .. "/events", "rb")
    if not f then return {} end
    f:seek("set", self.offset)
    local chunk = f:read("*a") or ""
    f:close()
    self.offset = self.offset + #chunk
    self.buf = self.buf .. chunk
    local events = {}
    while true do
        local line, rest = self.buf:match("^([^\n]*)\n(.*)$")
        if not line then break end
        self.buf = rest
        local ok, ev = pcall(json.decode, line)
        if ok and type(ev) == "table" and ev.ev then events[#events + 1] = ev end
    end
    return events
end

--- True while the helper process exists (zombies count as gone).
function Handle:alive()
    local f = io.open("/proc/" .. self.pid .. "/stat", "rb")
    if not f then return false end
    local stat = f:read("*l") or ""
    f:close()
    return stat:match("^%d+ %b() (%a)") ~= "Z"
end

--- Answer an offer: "accept" or "reject". Atomic (write, then rename).
function Handle:answer(word)
    local tmp = self.dir .. "/answer.tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(word); f:close()
    return os.rename(tmp, self.dir .. "/answer") and true or false
end

--- Ask the helper to stop (SIGTERM). It cleans up and reports "cancelled".
function Handle:cancel()
    os.execute("kill -TERM " .. self.pid .. " 2>/dev/null")
end

--- Stop it hard (use 2 s after cancel() if it's still alive).
function Handle:kill()
    os.execute("kill -KILL " .. self.pid .. " 2>/dev/null")
end

--- Last non-empty line the helper wrote to stderr, or nil.
function Handle:stderr_tail()
    local f = io.open(self.dir .. "/stderr", "rb")
    if not f then return nil end
    local last
    for line in f:lines() do
        if line:match("%S") then last = line end
    end
    f:close()
    return last
end

--- Delete the working folder. Call once the helper is gone.
function Handle:cleanup()
    os.execute("rm -rf " .. quote(self.dir))
end

return M
