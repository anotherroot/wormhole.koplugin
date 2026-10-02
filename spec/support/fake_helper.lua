-- Writes a fake wormhole-helper: a /bin/sh script that plays a scenario.
-- Scenario lines:
--   a JSON event          printed to stdout as is
--   "wait-answer"         waits until <control>/answer exists, then prints
--                         {"ev":"answered","word":"<answer>"} (lets tests see it)
--   "sleep N"             sleeps N seconds
--   "stderr TEXT"         prints TEXT to stderr
--   "exit N"              exits with status N
-- The real helper's argv starts with: <command> --control DIR …
local M = {}

function M.write(dir, lines)
    local path = dir .. "/fake-helper"
    local out = { "#!/bin/sh", 'control="$3"', 'echo "$@" > "$control/argv"' }
    for __, line in ipairs(lines) do
        if line == "wait-answer" then
            out[#out + 1] = 'while [ ! -f "$control/answer" ]; do sleep 0.05; done'
            out[#out + 1] = 'printf \'{"ev":"answered","word":"%s"}\\n\' "$(cat "$control/answer")"'
        elseif line:match("^sleep ") or line:match("^exit ") then
            out[#out + 1] = line
        elseif line:match("^stderr ") then
            out[#out + 1] = "echo '" .. line:sub(8) .. "' >&2"
        else
            out[#out + 1] = "echo '" .. line .. "'"
        end
    end
    local f = assert(io.open(path, "w"))
    f:write(table.concat(out, "\n"), "\n")
    f:close()
    os.execute("chmod +x '" .. path .. "'")
    return path
end

--- A fresh temporary folder for one test.
function M.tmpdir()
    local p = io.popen("mktemp -d")
    local d = p:read("*l")
    p:close()
    return d
end

--- Poll a handle until pred(events_so_far) is true or 5 s pass.
function M.poll_until(handle, pred)
    local events = {}
    for _ = 1, 250 do
        for __, ev in ipairs(handle:poll()) do events[#events + 1] = ev end
        if pred(events) then return events end
        os.execute("sleep 0.02")
    end
    return events
end

--- Wait until the fake helper is running (it writes argv first).
function M.wait_started(handle)
    for _ = 1, 250 do
        local f = io.open(handle.dir .. "/argv")
        if f then f:close() return end
        os.execute("sleep 0.02")
    end
end

return M
