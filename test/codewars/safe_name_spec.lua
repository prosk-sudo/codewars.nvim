local safe_name = require("codewars.safe_name")

describe("safe_name.is_slug", function()
    it("accepts ASCII letters, digits, '_' and '-'", function()
        for _, slug in ipairs({ "valid-braces", "Snake_case-9", "a", "7", "_", "-", string.rep("a", 24) }) do
            assert.is_true(safe_name.is_slug(slug), slug)
        end
    end)

    it("rejects a separator, a dot, or anything that could climb out of a directory", function()
        for _, slug in ipairs({ "../evil", "a/b", "..", ".", "a\\b", "a.b", "/a", "a/", "~", "a:b", "C:\\x" }) do
            assert.is_false(safe_name.is_slug(slug), slug)
        end
    end)

    it("rejects the empty string, whitespace, control characters and non-ASCII letters", function()
        for _, slug in ipairs({ "", " ", "a b", "a\n", "\na", "a\0b", "a\tb", "caf\195\169", "\226\128\174a" }) do
            assert.is_false(safe_name.is_slug(slug), vim.inspect(slug))
        end
    end)

    it("rejects what is not a string", function()
        for _, value in ipairs({ 1, true, {} }) do
            assert.is_false(safe_name.is_slug(value))
        end
        assert.is_false(safe_name.is_slug(nil))
    end)
end)

describe("safe_name.is_file_name", function()
    it("accepts <slug>.<extension>", function()
        for _, name in ipairs({ "valid-braces.py", "5264d2b162488dc400000001.js", "a_b-c.cpp", "x.7z" }) do
            assert.is_true(safe_name.is_file_name(name), name)
        end
    end)

    it("rejects a separator, '..', a missing or extra extension and an empty part", function()
        local bad = {
            "../x.py", "a/b.py", "/etc/x.py", "..\\x.py", "a\\b.py", "x..py", "x.y.py", ".py", "x.",
            "x", "", "x.py/", "x.py\n", "x .py", "x.p y", ".hidden.py",
        }
        for _, name in ipairs(bad) do
            assert.is_false(safe_name.is_file_name(name), vim.inspect(name))
        end
    end)

    it("rejects what is not a string", function()
        assert.is_false(safe_name.is_file_name(nil))
        assert.is_false(safe_name.is_file_name(1))
        assert.is_false(safe_name.is_file_name({}))
    end)
end)
