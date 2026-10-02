--[[--
Wormhole: send and receive text, books and files with Magic Wormhole.

@module koplugin.Wormhole
--]]--
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")

local Wormhole = WidgetContainer:extend{
    name = "wormhole",
    is_doc_only = false,
}

-- Crash guards (wh_safe): guarded for actions, quietly for text_func / enabled_func.
local safe = require("wh_safe")
local guarded, quietly = safe.guarded, safe.quietly

local function run() return require("wh_run") end
local function fmt() return require("wh_format") end

function Wormhole:init()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addHighlightButton()
    end
    if not self.ui.document then
        self:addFileDialogButton()
    end
end

function Wormhole:send(what)
    local function go()
        run().start({ plugin_dir = self.path, ui = self.ui, role = "send", what = what })
    end
    if what.kind ~= "text" then return go() end
    -- Text as text, or as a .txt file (apps on magic-wormhole.rs, e.g. Warp,
    -- can't receive text messages). The setting decides, or we ask.
    local function as(as_file)
        if as_file then what.file_name = fmt().text_filename(what.text) end
        go()
    end
    local mode = require("wh_files").text_mode(G_reader_settings)
    if mode == "ask" then
        require("wh_ui").ask_text_mode(guarded(as))
    else
        as(mode == "file")
    end
end

function Wormhole:addHighlightButton()
    -- Sorts after "12_generate_qr_code" and before "12_search" (always last).
    self.ui.highlight:addToHighlightDialog("12_h_wormhole", function(this, index)
        return {
            text = _("Send via wormhole"),
            callback = guarded(function()
                local item = this.selected_text or {}
                local text
                if index then -- an existing highlight: send its note too
                    text = fmt().highlight_text(item)
                else
                    text = util.cleanupSelectedText(item.text or "")
                end
                this:onClose()
                self:send({ kind = "text", text = text })
            end),
        }
    end)
end

function Wormhole:addFileDialogButton()
    -- Registered on the FileManager class, so every file browser gets it once.
    -- quietly: KOReader builds the dialog with this; nil = no button (the "../" entry).
    FileManager.addFileDialogButtons(FileManager, "wormhole", quietly(function(file, is_file)
        if require("wh_files").is_go_up(file) then return nil end
        return {
            {
                text = _("Send via wormhole"),
                callback = guarded(function()
                    local fm = FileManager.instance
                    if fm and fm.file_chooser and fm.file_chooser.file_dialog then
                        UIManager:close(fm.file_chooser.file_dialog)
                    end
                    local plugin = fm and fm.wormhole or self
                    if is_file then
                        plugin:send({ kind = "file", path = file })
                    else
                        local path = file:gsub("/+$", "")
                        plugin:send({ kind = "files", name = fmt().basename(path), paths = { path } })
                    end
                end),
            },
        }
    end))
end

function Wormhole:addToMainMenu(menu_items)
    menu_items.wormhole = {
        text = _("Wormhole"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

function Wormhole:menuItems()
    local files = require("wh_files")
    local items = {}
    if self.ui.document then
        table.insert(items, {
            text = _("Send current book"),
            callback = guarded(function()
                self:send({ kind = "file", path = self.ui.document.file })
            end),
        })
    else
        table.insert(items, {
            text_func = quietly(function()
                local n = #files.selected_paths(self.ui.selected_files)
                return n > 0 and _("Send selected files") .. " (" .. n .. ")" or _("Send selected files")
            end, _("Send selected files")),
            enabled_func = quietly(function()
                return #files.selected_paths(self.ui.selected_files) > 0
            end, false),
            help_text = _("Select files in the file browser's select mode first."),
            callback = guarded(function()
                local paths = files.selected_paths(self.ui.selected_files)
                self:send({ kind = "files", name = _("Wormhole files"), paths = paths })
            end),
        })
    end
    table.insert(items, {
        text = _("Receive…"),
        callback = guarded(function() run().ask_and_receive(self.path, self.ui) end),
        separator = true,
    })
    table.insert(items, self:settingsMenu())
    return items
end

function Wormhole:settingsMenu()
    local files = require("wh_files")
    local function text_mode_item(text, mode)
        return {
            text = text,
            radio = true,
            checked_func = quietly(function() return files.text_mode(G_reader_settings) == mode end, false),
            callback = guarded(function()
                files.set(G_reader_settings, "text_mode", mode ~= "ask" and mode or nil)
            end),
        }
    end
    local Device = require("device")
    local function input(title, key, hint)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = title,
            input = files.settings(G_reader_settings)[key] or "",
            input_hint = hint,
            description = _("Leave empty to use the default."),
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    files.set(G_reader_settings, key, dialog:getInputText())
                    UIManager:close(dialog)
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    return {
        text = _("Settings"),
        sub_item_table = {
            {
                text = _("When sending text"),
                sub_item_table = {
                    text_mode_item(_("Ask each time"), "ask"),
                    text_mode_item(_("Always as text"), "text"),
                    text_mode_item(_("Always as a file (.txt)"), "file"),
                },
                help_text = _("Apps built on magic-wormhole.rs, such as Warp, can't receive text, only files."),
            },
            {
                text_func = quietly(function()
                    return _("Save received files in: ") .. files.save_dir(G_reader_settings, Device.home_dir)
                end, _("Save received files in…")),
                keep_menu_open = true,
                callback = guarded(function(touchmenu)
                    local current = files.save_dir(G_reader_settings, Device.home_dir)
                    files.ensure_dir(current)
                    require("apps/filemanager/filemanagerutil").showChooseDialog(
                        _("Save received files in:"),
                        function(path)
                            files.set(G_reader_settings, "save_dir", path)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                        current, (Device.home_dir or ".") .. "/Wormhole")
                end),
            },
            {
                text = _("Server (rendezvous URL)"),
                keep_menu_open = true,
                callback = guarded(function()
                    input(_("Rendezvous server"), "rendezvous", "ws://relay.magic-wormhole.io:4000/v1")
                end),
            },
            {
                text = _("Transit relay"),
                keep_menu_open = true,
                callback = guarded(function()
                    input(_("Transit relay"), "relay", "transit.magic-wormhole.io:4001")
                end),
            },
        },
    }
end

function Wormhole:onSuspend()
    pcall(function() run().on_suspend() end)
end

return Wormhole
