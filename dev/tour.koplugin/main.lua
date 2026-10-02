--[[--
Screen tour (development only, never installed on a device).
scripts/tour.sh links this into .dev/home/plugins, runs the laptop KOReader
headless, and this plugin drives real transfers against the `wormhole`
command, takes a screenshot of each screen, and writes PASS/FAIL lines to
$WH_TOUR_OUT/log.txt.
--]]--
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local OUT = os.getenv("WH_TOUR_OUT")
local BOOK = os.getenv("WH_BOOK")
-- time-limited, so a failed tour never leaves wormhole processes behind
local WH = "timeout 120 " .. (os.getenv("WH_CLI") or "wormhole")

local Tour = WidgetContainer:extend{ name = "tour", is_doc_only = false }

local log = OUT and io.open(OUT .. "/log.txt", "w")
local function L(...)
    log:write(table.concat({ ... }, " "), "\n")
    log:flush()
end
local function check(ok, what) L(ok and "PASS" or "FAIL", what) end
local function shot(name)
    require("device").screen:shot(OUT .. "/" .. name .. ".png")
end
local function sh(cmd) os.execute("cd '" .. OUT .. "' && " .. cmd) end
local function read(name)
    local f = io.open(OUT .. "/" .. name, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function run() return require("wh_run") end
local function fm() return require("apps/filemanager/filemanager").instance end
local function top() return UIManager._window_stack[#UIManager._window_stack].widget end
-- Press a button by its text in a ButtonDialog (rows of buttons).
local function press(dialog, text)
    for __, row in ipairs(dialog.buttons or {}) do
        for i = 1, #row do
            if row[i].text == text then row[i].callback() return true end
        end
    end
    return false
end

local function close_dialogs()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if not w.covers_fullscreen then UIManager:close(w) end
    end
end

local base = tostring(os.time() % 100000)
local plugin_dir

local steps = {}
local function step(delay, f) steps[#steps + 1] = { delay, f } end
local function play(i)
    local s = steps[i]
    if not s then return end
    UIManager:scheduleIn(s[1], function()
        local ok, err = pcall(s[2])
        if not ok then L("FAIL step", i, tostring(err)) end
        play(i + 1)
    end)
end

-- 1. File browser button is registered
step(3, function()
    require("wh_files").set(G_reader_settings, "save_dir", nil) -- default: <device home>/Wormhole
    local FileManager = require("apps/filemanager/filemanager")
    local added = FileManager.file_dialog_added_buttons
    check(added and added.index.wormhole ~= nil, "file dialog button registered")
    local row = added[added.index.wormhole]("/x/Dune.epub", true)
    check(row[1].text == "Send via wormhole", "file dialog button text")
    check(added[added.index.wormhole]("/x/Books/..", false) == nil, "no button on the ../ entry")
end)

-- 2. Send text; a second transfer meanwhile is refused
step(1, function()
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "send",
                  what = { kind = "text", text = "¿Dónde está la biblioteca?" } })
end)
step(3, function()
    shot("01-send-code")
    local code = run().active.dialog.code
    check(code and code:match("^%d+%-"), "send shows a code: " .. tostring(code))
    check(run().active.dialog.qr == require("wh_format").transfer_uri(code), "send shows a QR of the link")
    local function has_qr(w)
        if type(w) ~= "table" then return false end
        if w.image and w.text and w.text:find("^wormhole%-transfer:") then return true end
        for __, child in ipairs(w) do if has_qr(child) then return true end end
        return false
    end
    check(has_qr(run().active.dialog[1]), "the QR is drawn in the dialog")
    local pid = run().active.handle.pid
    local p = io.popen("readlink /proc/" .. pid .. "/cwd; tr '\\0' ' ' < /proc/" .. pid .. "/cmdline")
    local cwd, cmdline = p:read("*l"), p:read("*l") or ""
    p:close()
    check(cwd == "/", "helper runs in /: " .. tostring(cwd))
    check(cmdline:find("--watch-pid " .. require("wh_helper").self_pid(), 1, true), "helper watches KOReader's PID")
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "send",
                  what = { kind = "text", text = "second" } })
end)
step(1, function()
    check(top().text and top().text:match("already running"), "second transfer refused")
    UIManager:close(top())
    sh(WH .. " receive --only-text " .. run().active.dialog.code .. " > cli-text.txt 2>&1 &")
end)
step(6, function()
    shot("02-sent")
    check(top().qr == nil, "the QR is gone once sent")
    check((read("cli-text.txt") or ""):match("biblioteca"), "CLI received the text")
    check(run().active == nil, "transfer finished")
end)

-- 2b. E-ink: opening and closing the dialog must ask for a screen refresh of its
-- area (screenshots read memory, not the panel, so check the requests instead)
local function refreshes_while(f)
    local calls, orig = {}, UIManager.setDirty
    UIManager.setDirty = function(self, w, rt, ...)
        calls[#calls + 1] = { w = w, rt = rt }
        return orig(self, w, rt, ...)
    end
    local ok, err = pcall(f)
    UIManager.setDirty = orig
    assert(ok, err)
    return calls
end
local function asks_ui_refresh_of(calls, dimen)
    for __, c in ipairs(calls) do
        if type(c.rt) == "function" then
            local mode, region = c.rt()
            if mode == "ui" and region and dimen and region:contains(dimen) then return true end
        end
    end
    return false
end
step(1, function()
    local d = top() -- the "Sent" dialog
    local dimen = d.frame.dimen:copy()
    local calls = refreshes_while(function() d.buttons[1].callback() end) -- Close
    check(asks_ui_refresh_of(calls, dimen), "closing the dialog refreshes its area on the screen")
end)
step(1, function()
    local d = require("wh_ui").TransferDialog:new{ subject = "x", status = "y", buttons = { { text = "OK" } } }
    local calls = refreshes_while(function() UIManager:show(d) end)
    UIManager:setDirty(d, "ui") -- let it paint so its frame gets a position
    UIManager:scheduleIn(0.1, function() end)
    Tour.shown_calls, Tour.shown = calls, d
end)
step(1, function()
    check(asks_ui_refresh_of(Tour.shown_calls, Tour.shown.frame.dimen), "showing the dialog refreshes its area on the screen")
    UIManager:close(Tour.shown)
end)

-- 3. Receive a file: offer, accept, saved
step(1, function()
    close_dialogs()
    sh("head -c 1500000 /dev/urandom > Dune.epub")
    sh(WH .. " send --hide-progress --code 1" .. base .. "-tour-file Dune.epub > cli-send.txt 2>&1 &")
end)
step(3, function()
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "receive", code = "1" .. base .. "-tour-file" })
end)
step(5, function()
    shot("03-offer")
    check(run().active.dialog.status:match("Dune.epub, 1.5 MB. Accept?"), "offer shown")
    run().active.dialog.buttons[2].callback()
end)
step(6, function()
    shot("04-saved")
    check(read("Wormhole/Dune.epub") == read("Dune.epub"), "received file is identical")
end)

-- 3b. Receive with a code made here: Receive… → Show a QR code, the CLI sends to it
step(1, function()
    close_dialogs()
    run().ask_and_receive(plugin_dir, fm())
end)
step(2, function()
    check(press(top(), "Show a QR code"), "Receive… offers Show a QR code")
end)
step(3, function()
    shot("04b-receive-qr")
    local d = run().active and run().active.dialog
    local code = d and d.code
    check(code and code:match("^%d%d%d%d%-%l+%-%l+$"), "receive shows a code: " .. tostring(code))
    check(d and d.qr == require("wh_format").transfer_uri(code, nil, true), "receive QR is the role=leader link")
    check(d and d.hint and d.hint:find("wormhole send --code " .. tostring(code), 1, true), "receive hint shows the CLI command")
    sh(WH .. " send --hide-progress --code " .. code .. " Dune.epub > cli-send-qr.txt 2>&1 &")
end)
step(6, function()
    local d = run().active.dialog
    check(d.status:match("Dune.epub, 1.5 MB. Accept?"), "offer from the sender who used our code")
    check(d.qr == nil, "the QR is gone once the sender is there")
    d.buttons[2].callback()
end)
step(6, function()
    shot("04c-receive-qr-saved")
    check(read("Wormhole/Dune (2).epub") == read("Dune.epub"), "file sent to our code is identical")
end)

-- 4. Receive text
step(1, function()
    close_dialogs()
    sh(WH .. " send --text 'Hola desde el portátil.' --code 2" .. base .. "-tour-text > cli-send2.txt 2>&1 &")
end)
step(3, function()
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "receive", code = "2" .. base .. "-tour-text" })
end)
step(5, function()
    shot("05-text")
    check(top().text == "Hola desde el portátil.", "received text shown")
end)

-- 5. Wrong code
step(1, function()
    close_dialogs()
    sh(WH .. " send --text secret --code 3" .. base .. "-right-words > cli-send3.txt 2>&1 &")
end)
step(3, function()
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "receive", code = "3" .. base .. "-wrong-words" })
end)
step(5, function()
    shot("06-badcode")
    local d = top()
    check(d.status and d.status:match("didn't work"), "wrong code explained")
    check(d.buttons[2] and d.buttons[2].text == "Try again", "Try again offered")
end)

-- 6. Send a folder
step(1, function()
    close_dialogs()
    sh("mkdir -p Shelf/sub && echo A > Shelf/a.txt && echo B > Shelf/sub/b.txt && mkdir -p cli-recv")
    run().start({ plugin_dir = plugin_dir, ui = fm(), role = "send",
                  what = { kind = "files", name = "Shelf", paths = { OUT .. "/Shelf" } } })
end)
step(3, function()
    shot("07-send-folder")
    sh("cd cli-recv && " .. WH .. " receive --accept-file --hide-progress " .. run().active.dialog.code
        .. " > ../cli-recv.txt 2>&1 &")
end)
step(6, function()
    check(read("cli-recv/Shelf/sub/b.txt") == "B\n", "CLI received the folder")
    local zip_tmp = require("datastorage"):getDataDir() .. "/cache/wormhole"
    local d = io.open(zip_tmp .. "/.")
    if d then d:close() end
    check(d ~= nil, "folder zipped in " .. zip_tmp .. ", not /tmp")
end)

-- 6b. Select mode: "Send selected files (N)" in the Wormhole menu
step(1, function()
    close_dialogs()
    fm().selected_files = { [OUT .. "/Dune.epub"] = true, [OUT .. "/Shelf/a.txt"] = true }
    local item = fm().wormhole:menuItems()[1]
    check(item.text_func() == "Send selected files (2)", "select mode menu text: " .. tostring(item.text_func()))
    check(item.enabled_func() == true, "select mode menu enabled")
    item.callback()
end)
step(3, function()
    local what = run().active and run().active.opts.what
    check(what and what.kind == "files" and #what.paths == 2 and what.name == "Wormhole files", "selected files sent as one folder")
    run().active.dialog.buttons[1].callback()
    fm().selected_files = nil
end)
step(2, function()
    check(fm().wormhole:menuItems()[1].enabled_func() == false, "select mode menu disabled with nothing ticked")
end)

-- 7. Code box
step(1, function()
    close_dialogs()
    run().ask_and_receive(plugin_dir, fm(), "7 Guitarist revenge")
end)
step(2, function() shot("08-askcode") end)

-- 8. Reader: highlight button, existing highlight with note, current book
step(1, function()
    close_dialogs()
    require("apps/reader/readerui"):showReader(BOOK)
end)
step(8, function()
    local ReaderUI = require("apps/reader/readerui")
    local hl = ReaderUI.instance.highlight
    local fn = hl._highlight_buttons["12_h_wormhole"]
    check(fn ~= nil, "highlight button registered")
    hl.selected_text = { text = "Alice" }
    local button = fn(hl, nil)
    check(button.text == "Send via wormhole", "highlight button text")
    button.callback()
end)
step(2, function()
    shot("09a-ask-text-mode")
    check(top().title == "Send text", "asks how to send text (default)")
    check(press(top(), "As text"), "As text button")
end)
step(3, function()
    shot("09-reader-send")
    check(run().active and run().active.opts.what.text == "Alice", "selected text sent")
    run().active.dialog.buttons[1].callback() -- Cancel
end)
step(2, function()
    check(run().active == nil, "cancel finished the transfer")
    local hl = require("apps/reader/readerui").instance.highlight
    hl.selected_text = { text = "casa", note = "house" }
    hl._highlight_buttons["12_h_wormhole"](hl, 1).callback()
end)
step(2, function()
    check(press(top(), "As a file (.txt)"), "As a file button")
end)
step(3, function()
    local what = run().active and run().active.opts.what
    check(what and what.text == "casa\n\nhouse", "existing highlight sends its note")
    check(what and what.file_name == "casa house.txt", "as a file named after its words: " .. tostring(what and what.file_name))
    sh("mkdir -p cli-recv-txt && cd cli-recv-txt && " .. WH .. " receive --accept-file --hide-progress " .. run().active.dialog.code .. " > ../cli-recv-txt.log 2>&1 &")
end)
step(6, function()
    check(read("cli-recv-txt/casa house.txt") == "casa\n\nhouse", "CLI received the text as a .txt file")
    close_dialogs()
    require("wh_files").set(G_reader_settings, "text_mode", "file")
    local hl = require("apps/reader/readerui").instance.highlight
    hl.selected_text = { text = "Alice" }
    hl._highlight_buttons["12_h_wormhole"](hl, nil).callback()
end)
step(2, function()
    local what = run().active and run().active.opts.what
    check(what and what.file_name == "Alice.txt", "setting 'always as a file' skips the question")
    run().active.dialog.buttons[1].callback()
    require("wh_files").set(G_reader_settings, "text_mode", nil)
end)
step(2, function()
    local ui = require("apps/reader/readerui").instance
    ui.wormhole:menuItems()[1].callback()
end)
step(3, function()
    shot("10-send-book")
    check(run().active and run().active.opts.what.path == BOOK, "send current book")
    run().active.dialog.buttons[1].callback()
end)

-- 9. "Show folder" from the reader closes the book first
step(2, function()
    run().show_folder(require("apps/reader/readerui").instance, OUT .. "/Shelf")
end)
step(4, function()
    shot("11-show-folder")
    check(require("apps/reader/readerui").instance == nil, "Show folder closed the reader")
    local fmi = require("apps/filemanager/filemanager").instance
    check(fmi and fmi.file_chooser.path == OUT .. "/Shelf", "Show folder opened the folder: " .. tostring(fmi and fmi.file_chooser.path))
end)
step(2, function()
    L("END")
    UIManager:quit()
end)

function Tour:init()
    if Tour.started or not OUT then return end
    Tour.started = true
    plugin_dir = self.path:gsub("/dev/tour%.koplugin$", "")
    plugin_dir = os.getenv("WH_PLUGIN_DIR") or plugin_dir
    play(1)
end

return Tour
