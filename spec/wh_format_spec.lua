local fmt = require("wh_format")

describe("wh_format.normalize_code", function()
    it("accepts codes and cleans what people type on e-ink keyboards", function()
        assert.equal("7-guitarist-revenge", fmt.normalize_code("7-guitarist-revenge"))
        assert.equal("7-guitarist-revenge", fmt.normalize_code("  7 Guitarist  Revenge "))
        assert.equal("12-a-b-c", fmt.normalize_code("12_a--b c"))
    end)

    it("rejects things that aren't codes", function()
        for __, bad in ipairs({ "", "   ", "guitarist-revenge", "7", "7-", "7-a-", "-7-a", nil }) do
            assert.is_nil(fmt.normalize_code(bad), tostring(bad))
        end
    end)
end)

describe("wh_format.size", function()
    it("uses decimal units", function()
        assert.equal("512 B", fmt.size(512))
        assert.equal("2.4 MB", fmt.size(2400000))
        assert.equal("30 MB", fmt.size(30000000))
        assert.equal("1.5 GB", fmt.size(1500000000))
        assert.equal("0 B", fmt.size(nil))
    end)
end)

describe("wh_format.highlight_text", function()
    it("adds the note after a blank line", function()
        assert.equal("casa\n\nhouse", fmt.highlight_text({ text = "casa", note = "house" }))
        assert.equal("casa", fmt.highlight_text({ text = "casa", note = "  " }))
        assert.equal("casa", fmt.highlight_text({ text = "casa" }))
    end)
end)

describe("wh_format.describe", function()
    it("names what is sent", function()
        assert.equal("Text (5 characters)", fmt.describe({ kind = "text", text = "¿Qué?" }))
        assert.equal("Dune.epub", fmt.describe({ kind = "file", path = "/b/Dune.epub" }))
        assert.equal("Books", fmt.describe({ kind = "files", name = "Books", paths = { "/b/Books/" } }))
        assert.equal("3 items", fmt.describe({ kind = "files", name = "Wormhole files", paths = { "/a", "/b", "/c" } }))
    end)
end)

describe("wh_format.error_message", function()
    it("says nothing for our own cancel", function()
        assert.is_nil(fmt.error_message("cancelled", "send"))
    end)

    it("explains a wrong code from both sides", function()
        assert.matches("code didn't work", fmt.error_message("bad_code", "receive"))
        assert.matches("receiver typed a wrong code", fmt.error_message("bad_code", "send"))
        -- receiving with a code made here: the sender typed it wrong (or a rare clash)
        assert.matches("sender used a different code", fmt.error_message("bad_code", "receive_new"))
    end)

    it("shows the detail for helper failures", function()
        assert.equal("Wormhole helper failed: panic: boom", fmt.error_message("internal", "send", "panic: boom"))
    end)
end)

describe("wh_format.text_filename", function()
    it("names a text file after its first words", function()
        assert.equal("¿Dónde está la biblioteca Tengo prisa.txt",
            fmt.text_filename("¿Dónde está la biblioteca? Tengo prisa, mucha prisa."))
    end)

    it("drops characters other devices refuse in names", function()
        assert.equal("a b c.txt", fmt.text_filename('a: b/ c*\n'))
    end)

    it("keeps names short, cutting between words", function()
        local name = fmt.text_filename(string.rep("palabra ", 30))
        assert.is_true(#name <= 64, name)
        assert.matches("^palabra palabra .-palabra%.txt$", name)
    end)

    it("falls back to text.txt", function()
        assert.equal("text.txt", fmt.text_filename("  ?!  "))
    end)
end)

describe("wh_format.describe text as a file", function()
    it("names the file", function()
        assert.equal("Hola.txt", fmt.describe({ kind = "text", text = "Hola", file_name = "Hola.txt" }))
    end)
end)

describe("wh_format.transfer_uri", function()
    it("is the standard wormhole-transfer link for the default server", function()
        assert.equal("wormhole-transfer:7-guitarist-revenge", fmt.transfer_uri("7-guitarist-revenge"))
        assert.equal("wormhole-transfer:7-guitarist-revenge", fmt.transfer_uri("7-guitarist-revenge", ""))
    end)

    it("adds an own server, percent-encoded", function()
        assert.equal("wormhole-transfer:7-a-b?rendezvous=ws%3A%2F%2Fmy.host%3A4000%2Fv1",
            fmt.transfer_uri("7-a-b", "ws://my.host:4000/v1"))
    end)

    it("asks the scanner to send (role=leader) when this device receives", function()
        assert.equal("wormhole-transfer:7-a-b?role=leader", fmt.transfer_uri("7-a-b", nil, true))
        assert.equal("wormhole-transfer:7-a-b?rendezvous=ws%3A%2F%2Fh%2Fv1&role=leader",
            fmt.transfer_uri("7-a-b", "ws://h/v1", true))
    end)

    it("percent-encodes anything unusual in the code", function()
        assert.equal("wormhole-transfer:7-a%20b%3F", fmt.transfer_uri("7-a b?"))
    end)
end)
