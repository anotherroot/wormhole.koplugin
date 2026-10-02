-- Screens. KOReader widgets only: no processes, no files.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local M = {}

--- The one dialog a transfer uses from start to end. Change it with update().
-- Fields: subject, code, hint, status, progress (0..1 or nil),
--         buttons = { { text = …, callback = … }, … } (one row)
local TransferDialog = InputContainer:extend{
    subject = nil, code = nil, hint = nil, status = nil, progress = nil, buttons = nil,
}
M.TransferDialog = TransferDialog

function TransferDialog:init()
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:_build()
end

function TransferDialog:_build()
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
    local inner = width - 2 * Size.padding.large
    local group = VerticalGroup:new{ align = "left" }
    local function text(t, face)
        table.insert(group, TextBoxWidget:new{ text = t, face = face, width = inner })
        table.insert(group, VerticalSpan:new{ width = Size.padding.large })
    end
    text(_("Wormhole"), Font:getFace("tfont"))
    if self.subject then text(self.subject, Font:getFace("cfont")) end
    if self.code then
        text(self.code, Font:getFace("cfont", 32))
    end
    if self.hint then text(self.hint, Font:getFace("x_smallinfofont")) end
    if self.status then text(self.status, Font:getFace("cfont")) end
    if self.progress then
        table.insert(group, ProgressWidget:new{
            width = inner, height = Screen:scaleBySize(12), percentage = self.progress,
        })
        table.insert(group, VerticalSpan:new{ width = Size.padding.large })
    end
    local buttons = {}
    for __, b in ipairs(self.buttons or {}) do
        table.insert(buttons, { text = b.text, callback = b.callback })
    end
    if #buttons > 0 then
        table.insert(group, ButtonTable:new{
            width = inner, buttons = { buttons }, zero_sep = true, show_parent = self,
        })
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.large,
        group,
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.frame }
end

--- Change some fields and redraw. Pass progress = false to remove the bar.
function TransferDialog:update(fields)
    local old = self.frame.dimen and self.frame.dimen:copy()
    for k, v in pairs(fields) do
        if v == false then self[k] = nil else self[k] = v end
    end
    self[1]:free(true)
    self:_build()
    -- "all" repaints what's under a shrinking dialog; the function runs after
    -- painting, when the new frame knows where it is.
    UIManager:setDirty("all", function()
        local new = self.frame.dimen
        return "ui", (old and new) and old:combine(new) or new or old
    end)
end

-- E-ink only redraws what is asked for: refresh our area when shown and when
-- closed (without this the closed dialog stays on the panel).
function TransferDialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function TransferDialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

-- Back key = the first button (Cancel / Close / Reject).
function TransferDialog:onClose()
    local first = self.buttons and self.buttons[1]
    if first and first.callback then first.callback() end
    return true
end

--- Ask for a code. on_code(text) gets what was typed (not cleaned).
function M.ask_code(prefill, on_code)
    local dialog
    dialog = InputDialog:new{
        title = _("Receive with Wormhole"),
        input = prefill or "",
        input_hint = "7-guitarist-revenge",
        description = _("Enter the code from the sender."),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Receive"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                on_code(text)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Ask whether to send text as text or as a .txt file. on_choice(as_file).
function M.ask_text_mode(on_choice)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function choose(as_file)
        return function()
            UIManager:close(dialog)
            on_choice(as_file)
        end
    end
    dialog = ButtonDialog:new{
        title = _("Send text"),
        title_align = "center",
        buttons = {
            { { text = _("As text"), callback = choose(false) },
              { text = _("As a file (.txt)"), callback = choose(true) } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

--- Received text, with Copy and Close.
function M.show_text(text)
    local viewer
    viewer = TextViewer:new{
        title = _("Received with Wormhole"),
        text = text,
        buttons_table = { {
            { text = _("Copy"), callback = require("wh_safe").guarded(function()
                Device.input.setClipboardText(text)
                local Notification = require("ui/widget/notification")
                Notification:notify(_("Copied to clipboard."))
            end) },
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
        } },
    }
    UIManager:show(viewer)
end

return M
