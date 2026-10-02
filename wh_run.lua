-- Runs one transfer: Wi-Fi, helper process, poll loop, session, dialog,
-- keeping the device awake. The only module that ties them together.
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local fmt = require("wh_format")
local files = require("wh_files")
local helper = require("wh_helper")
local lfs = require("libs/libkoreader-lfs")
local safe = require("wh_safe")
local session = require("wh_session")
local whui = require("wh_ui")
local logger = require("logger")
local time = require("ui/time")
local T = require("ffi/util").template
local _ = require("gettext")

local M = {}

local POLL_S = 0.25
local REDRAW_S = 1 -- at most one progress redraw a second (e-ink)

-- The running transfer, if any (only one at a time).
M.active = nil

local function message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local Run = {}
Run.__index = Run

--- Start a transfer.
-- opts = { plugin_dir = …, ui = ReaderUI|FileManager,
--          role = "send", what = { kind = "text"|"file"|"files", … } }
--      | { …, role = "receive", code = "7-a-b" }
--      | { …, role = "receive", new_code = true } (make the code here, show it as a QR)
function M.start(opts)
    if M.active then
        message(_("A Wormhole transfer is already running."))
        return
    end
    -- absolute: a Kobo's plugin path is relative, and the helper runs from /
    local bin, why = helper.binary_path(helper.absolute(opts.plugin_dir, lfs.currentdir()))
    if not bin then
        message(fmt.error_message("internal", opts.role, why))
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, err = pcall(function()
            local run = setmetatable({ opts = opts, bin = bin }, Run)
            run:_begin()
        end)
        if not ok then
            logger.err("Wormhole:", err)
            M.active = nil
            message(fmt.error_message("internal", opts.role, tostring(err)))
        end
    end)
end

function Run:_spec()
    local o, s = self.opts, files.settings(G_reader_settings)
    local spec = { bin = self.bin, rendezvous = s.rendezvous, relay = s.relay,
                   -- folders are zipped here, on the storage: /tmp is RAM on a Kobo
                   zip_tmp = DataStorage:getDataDir() .. "/cache/wormhole",
                   watch_pid = helper.self_pid() }
    if o.role == "receive" then
        spec.command, spec.code, spec.new_code = "receive", o.code, o.new_code
        spec.save_dir = files.save_dir(G_reader_settings, Device.home_dir)
        if not files.ensure_dir(spec.save_dir) then
            return nil, T(_("Can't create the folder %1"), spec.save_dir)
        end
    elseif o.what.kind == "text" then
        spec.command, spec.text, spec.file_name = "send-text", o.what.text, o.what.file_name
    elseif o.what.kind == "file" then
        spec.command, spec.paths = "send-file", { o.what.path }
    else
        spec.command, spec.name, spec.paths = "send-files", o.what.name, o.what.paths
    end
    return spec
end

function Run:_begin()
    local o = self.opts
    local spec, why = self:_spec()
    if not spec then message(why) return end

    self.dialog = whui.TransferDialog:new{
        subject = o.role == "send" and T(_("Sending: %1"), fmt.describe(o.what)) or _("Receiving"),
        code = o.role == "receive" and o.code or nil,
        status = (o.role == "send" or o.new_code) and _("Getting a code…") or _("Connecting…"),
        buttons = { self:_cancel_button() },
    }
    UIManager:show(self.dialog)

    local handle, err = helper.start(spec)
    if not handle then
        self:_show_failure("internal", err)
        return
    end
    self.handle = handle
    self.session = session.new(o.role, self:_callbacks())
    M.active = self
    UIManager:preventStandby()
    self.saved_pause = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    self.awake = true
    self:_tick()
end

function Run:_cancel_button()
    return { text = _("Cancel"), callback = safe.guarded(function()
        if self.session then self.session:cancel() else UIManager:close(self.dialog) end
    end) }
end

function Run:_close_button()
    return { text = _("Close"), callback = safe.guarded(function() UIManager:close(self.dialog) end) }
end

function Run:_callbacks()
    local o = self.opts
    return {
        code = function(code)
            local rendezvous = files.settings(G_reader_settings).rendezvous
            if o.role == "receive" then -- a code made here: whoever scans it sends (role=leader)
                self.dialog:update{
                    code = code,
                    qr = fmt.transfer_uri(code, rendezvous, true),
                    hint = T(_("Scan it with the Wormhole app, or on a computer:\nwormhole send --code %1 <file>"), code),
                    status = _("Waiting for the sender…"),
                }
                return
            end
            self.dialog:update{
                code = code,
                -- a phone app can scan this instead of typing the code
                qr = fmt.transfer_uri(code, rendezvous),
                hint = _("Scan it, or type it in any Wormhole app:\nwormhole receive · Warp · Wormhole"),
                status = _("Waiting for the receiver…"),
            }
        end,
        offer = function(ev)
            local what = ev.kind == "dir"
                and T(_("Folder '%1', %2 files, %3."), ev.name, ev.files or "?", fmt.size(ev.bytes))
                or T(_("%1, %2."), ev.name, fmt.size(ev.bytes))
            self.dialog:update{
                hint = false, qr = false, -- the sender found us: the QR has done its job
                status = what .. " " .. _("Accept?"),
                buttons = {
                    { text = _("Reject"), callback = safe.guarded(function()
                        self.session:reject()
                        self.handle:answer("reject")
                    end) },
                    { text = _("Accept"), callback = safe.guarded(function()
                        self.handle:answer("accept")
                        self.dialog:update{ status = _("Starting…"), buttons = { self:_cancel_button() } }
                    end) },
                },
            }
        end,
        progress = function(done, total)
            if self.last_redraw and done < total and time.to_s(time.since(self.last_redraw)) < REDRAW_S then
                return
            end
            self.last_redraw = time.now()
            self.dialog:update{
                hint = false, qr = false,
                status = T(_("%1 / %2"), fmt.size(done), fmt.size(total)),
                progress = total > 0 and done / total or 0,
                buttons = { self:_cancel_button() },
            }
        end,
        text = function(text)
            UIManager:close(self.dialog)
            whui.show_text(text)
        end,
        saved = function() end, -- read from session.saved_path in done()
        done = function()
            if o.role == "send" then
                self.dialog:update{ hint = false, qr = false, status = _("Sent ✓"), progress = false,
                                    buttons = { self:_close_button() } }
            elseif self.session.saved_path then
                self:_show_saved(self.session.saved_path)
            end
        end,
        failed = function(kind, detail)
            self:_show_failure(kind, detail)
        end,
        closed = function()
            UIManager:close(self.dialog)
        end,
    }
end

function Run:_show_saved(path)
    local is_dir = io.open(path .. "/.", "r")
    if is_dir then is_dir:close() end
    local short = path:gsub("^" .. (Device.home_dir or ""):gsub("%p", "%%%0") .. "/", "")
    local open_button = is_dir
        and { text = _("Show folder"), callback = safe.guarded(function()
                UIManager:close(self.dialog)
                M.show_folder(self.opts.ui, path)
            end) }
        or { text = _("Open"), callback = safe.guarded(function()
                UIManager:close(self.dialog)
                require("apps/filemanager/filemanagerutil").openFile(self.opts.ui, path)
            end) }
    self.dialog:update{ code = false, hint = false, qr = false, progress = false,
                        status = T(_("Saved to %1"), short),
                        buttons = { self:_close_button(), open_button } }
end

function Run:_show_failure(kind, detail)
    local o = self.opts
    local text = fmt.error_message(kind, o.new_code and "receive_new" or o.role, detail)
    if not text then UIManager:close(self.dialog) return end
    local buttons = { self:_close_button() }
    if kind == "bad_code" and o.new_code then -- codes are single-use: show a new one
        table.insert(buttons, { text = _("Try again"), callback = safe.guarded(function()
            UIManager:close(self.dialog)
            M.receive_by_qr(o.plugin_dir, o.ui)
        end) })
    elseif kind == "bad_code" and o.role == "receive" then
        local code = self.opts.code
        table.insert(buttons, { text = _("Try again"), callback = safe.guarded(function()
            UIManager:close(self.dialog)
            M.ask_and_receive(self.opts.plugin_dir, self.opts.ui, code)
        end) })
    end
    self.dialog:update{ hint = false, qr = false, progress = false, status = text, buttons = buttons }
end

--- Show a folder in the file browser (from the reader or the file browser).
function M.show_folder(ui, path)
    if ui.document then
        ui:onClose() -- like KOReader's own "go to file browser": close the book first
        ui:showFileManager(path .. "/")
    else
        ui.file_chooser:changeToPath(path)
    end
end

function Run:_tick()
    local ok, err = pcall(function()
        if not self.session:finished() then
            self.session:feed(self.handle:poll())
            if not self.session:finished() and not self.handle:alive() then
                self.session:feed(self.handle:poll()) -- lines written just before exiting
                self.session:helper_exited(self.handle:stderr_tail())
            end
        end
        if self.session:finished() then
            self:_finish()
        else
            UIManager:scheduleIn(POLL_S, function() self:_tick() end)
        end
    end)
    if not ok then
        logger.err("Wormhole:", err)
        self:_finish()
    end
end

-- The session is over: stop the helper if needed, clean up, let the device sleep.
function Run:_finish()
    if self.awake then
        self.awake = false
        UIManager:allowStandby()
        PluginShare.pause_auto_suspend = self.saved_pause
    end
    if M.active == self then M.active = nil end
    local h = self.handle
    if h:alive() then
        h:cancel()
        UIManager:scheduleIn(2, function()
            if h:alive() then h:kill() end
            h:cleanup()
        end)
    else
        h:cleanup()
    end
end

--- The device is about to sleep (Suspend event).
function M.on_suspend()
    local run = M.active
    if run then
        pcall(function()
            run.session:suspended()
            run:_finish()
        end)
    end
end

--- Ask for a code, clean it, and receive.
function M.ask_and_receive(plugin_dir, ui, prefill)
    whui.ask_code(prefill, safe.guarded(function(typed)
        local code = fmt.normalize_code(typed)
        if not code then
            message(_("That doesn't look like a Wormhole code.\nCodes look like 7-guitarist-revenge."))
            return
        end
        M.start({ plugin_dir = plugin_dir, ui = ui, role = "receive", code = code })
    end), safe.guarded(function() M.receive_by_qr(plugin_dir, ui) end))
end

--- Make a code here and show it as a QR: the sender scans it (or types it).
function M.receive_by_qr(plugin_dir, ui)
    M.start({ plugin_dir = plugin_dir, ui = ui, role = "receive", new_code = true })
end

return M
