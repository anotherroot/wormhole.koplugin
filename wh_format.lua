-- Pure text helpers: code clean-up, sizes, highlight text, error messages.
-- No KOReader widgets; gettext is optional so the tests can load this file.
local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end

local M = {}

--- Clean a typed code: trim, lowercase, spaces/underscores → "-".
-- Returns nil unless it looks like "<number>-<word>[-<word>…]".
function M.normalize_code(s)
    if type(s) ~= "string" then return nil end
    s = s:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("[%s_]+", "-"):gsub("%-+", "-")
    if s:match("^%d+%-[%w%-]*%w$") then return s end
    return nil
end

--- 2400000 → "2.4 MB" (decimal units, like the wormhole CLI).
function M.size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1000 then return string.format("%d B", bytes) end
    local units = { "kB", "MB", "GB" }
    local v, i = bytes / 1000, 1
    while v >= 1000 and i < #units do v, i = v / 1000, i + 1 end
    return string.format(v < 10 and "%.1f %s" or "%.0f %s", v, units[i])
end

--- Text sent for a highlight: the highlighted text, then the note if any.
function M.highlight_text(item)
    local text = item.text or ""
    if item.note and item.note:match("%S") then
        return text .. "\n\n" .. item.note
    end
    return text
end

--- Last path component: "/a/b/Dune.epub" → "Dune.epub", "/a/Books/" → "Books".
function M.basename(path)
    return (path:gsub("/+$", ""):match("([^/]+)$")) or path
end

local function utf8_len(s)
    local n = 0
    for __ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n
end

--- What the wait screen calls the thing being sent.
-- what = { kind = "text", text = … } | { kind = "file", path = … }
--      | { kind = "files", name = …, paths = {…} }
function M.describe(what)
    if what.kind == "text" then
        return string.format(_("Text (%d characters)"), utf8_len(what.text))
    elseif what.kind == "file" then
        return M.basename(what.path)
    elseif #what.paths == 1 then
        return M.basename(what.paths[1])
    end
    return string.format(_("%d items"), #what.paths)
end

--- Message for an error kind, or nil when nothing should be shown.
-- role: "send" | "receive"
function M.error_message(kind, role, detail)
    if kind == "cancelled" then return nil end
    if kind == "bad_code" then
        if role == "send" then return _("The receiver typed a wrong code. Send again to get a new code.") end
        return _("That code didn't work. Check it and try again.")
    elseif kind == "rejected" then
        return _("The other side cancelled.")
    elseif kind == "network" then
        return _("Couldn't reach the Wormhole server. Check Wi-Fi.")
    elseif kind == "disk_full" then
        return _("Not enough space on this device.")
    elseif kind == "asleep" then
        return _("Transfer stopped: the device went to sleep.")
    end
    return _("Wormhole helper failed: ") .. (detail or "?")
end

return M
