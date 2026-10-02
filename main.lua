--[[--
Wormhole: send and receive text, books and files with Magic Wormhole.

@module koplugin.Wormhole
--]]--
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Wormhole = WidgetContainer:extend{
    name = "wormhole",
    is_doc_only = false,
}

-- Run f safely: an error becomes a message, never a crash.
local function guarded(f)
    return function(...)
        local ok, err = pcall(f, ...)
        if not ok then
            logger.err("Wormhole:", err)
            UIManager:show(InfoMessage:new{ text = _("Wormhole error: ") .. tostring(err) })
        end
    end
end

-- For text_func / enabled_func: on error return the fallback, never crash the menu.
local function quietly(f, fallback)
    return function(...)
        local ok, value = pcall(f, ...)
        if ok then return value end
        logger.err("Wormhole:", value)
        return fallback
    end
end

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
    run().start({ plugin_dir = self.path, ui = self.ui, role = "send", what = what })
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
    FileManager.addFileDialogButtons(FileManager, "wormhole", function(file, is_file)
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
    end)
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
