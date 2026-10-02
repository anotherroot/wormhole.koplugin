-- Settings and paths. `store` is G_reader_settings (or a fake in tests).
local M = {}

M.KEY = "wormhole"

--- { save_dir = …, rendezvous = …, relay = … }; missing keys mean "default".
function M.settings(store)
    return store:readSetting(M.KEY) or {}
end

--- Set one setting; nil or "" goes back to the default.
function M.set(store, key, value)
    local s = M.settings(store)
    if value == "" then value = nil end
    s[key] = value
    store:saveSetting(M.KEY, s)
end

--- How to send text: "ask" (default), "text" or "file" (a .txt file, for apps
-- that can't receive text messages, such as Warp).
function M.text_mode(store)
    local m = M.settings(store).text_mode
    if m == "text" or m == "file" then return m end
    return "ask"
end

--- Where received files go: the setting, else <device home>/Wormhole
-- (/mnt/onboard/Wormhole on a Kobo).
function M.save_dir(store, device_home)
    return M.settings(store).save_dir or ((device_home or ".") .. "/Wormhole")
end

--- Create a folder (and its parents). Returns true if it exists afterwards.
function M.ensure_dir(path)
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
    local f = io.open(path .. "/.", "r")
    if f then f:close() return true end
    return false
end

--- True for the file browser's "../" entry (its path ends in "/..").
function M.is_go_up(path)
    local p = path:gsub("/+$", "")
    return p == ".." or p:sub(-3) == "/.."
end

--- Paths ticked in the file browser's select mode, sorted.
-- selected_files: { [path] = true|nil, … } (KOReader keeps dimmed ones as true).
function M.selected_paths(selected_files)
    local out = {}
    for path, on in pairs(selected_files or {}) do
        if on then out[#out + 1] = path end
    end
    table.sort(out)
    return out
end

return M
