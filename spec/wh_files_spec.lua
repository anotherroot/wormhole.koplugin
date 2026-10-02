local files = require("wh_files")
local fake = require("spec/support/fake_helper")

-- Stands in for G_reader_settings.
local function store()
    local data = {}
    return {
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value end,
        data = data,
    }
end

describe("wh_files", function()
    it("saves into <device home>/Wormhole by default", function()
        assert.equal("/mnt/onboard/Wormhole", files.save_dir(store(), "/mnt/onboard"))
    end)

    it("uses the save_dir setting, and '' goes back to the default", function()
        local s = store()
        files.set(s, "save_dir", "/mnt/onboard/Books/In")
        assert.equal("/mnt/onboard/Books/In", files.save_dir(s, "/mnt/onboard"))
        files.set(s, "save_dir", "")
        assert.equal("/mnt/onboard/Wormhole", files.save_dir(s, "/mnt/onboard"))
    end)

    it("keeps the other settings when one changes", function()
        local s = store()
        files.set(s, "rendezvous", "ws://r")
        files.set(s, "relay", "t:1")
        assert.same({ rendezvous = "ws://r", relay = "t:1" }, files.settings(s))
    end)

    it("creates a missing folder, quotes included", function()
        local tmp = fake.tmpdir()
        local dir = tmp .. "/it's/new"
        assert.is_true(files.ensure_dir(dir))
        assert.is_true(files.ensure_dir(dir)) -- already there
        os.execute("rm -rf '" .. tmp .. "'")
    end)

    it("recognises the file browser's go-up entry (never send the parent folder)", function()
        assert.is_true(files.is_go_up("/mnt/onboard/Books/.."))
        assert.is_true(files.is_go_up("/mnt/onboard/Books/../"))
        assert.is_true(files.is_go_up(".."))
        assert.is_false(files.is_go_up("/mnt/onboard/Books"))
        assert.is_false(files.is_go_up("/mnt/onboard/..hidden"))
        assert.is_false(files.is_go_up("/mnt/onboard/a..b.epub"))
    end)

    it("lists the ticked files of select mode, sorted", function()
        assert.same({ "/a", "/b" }, files.selected_paths({ ["/b"] = true, ["/a"] = true, ["/c"] = nil }))
        assert.same({}, files.selected_paths(nil))
    end)
end)
