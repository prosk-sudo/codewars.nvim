describe("session cache", function()
    -- Stub the cache utils to use temp directory
    local tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")

    -- Override cache path
    package.loaded["codewars.config"] = package.loaded["codewars.config"] or {
        storage = { cache = require("plenary.path"):new(tmp_dir) },
        user = {},
    }

    -- Force fresh load
    package.loaded["codewars.cache.utils"] = nil
    package.loaded["codewars.cache.session"] = nil

    local cache_utils = require("codewars.cache.utils")
    -- Override cache_file to use temp dir
    local Path = require("plenary.path")
    cache_utils.cache_file = function(name)
        return Path:new(tmp_dir, name)
    end

    local session = require("codewars.cache.session")

    after_each(function()
        -- Clean up session files
        pcall(function()
            session.clear_all()
        end)
    end)

    it("saves and retrieves session data", function()
        session.save("multiply", "python", { solutionId = "sol-1", projectId = "proj-1" })
        local data = session.get("multiply", "python")
        assert.is_not_nil(data)
        assert.are.equal("sol-1", data.solutionId)
        assert.are.equal("proj-1", data.projectId)
    end)

    it("returns nil for non-existent session", function()
        local data = session.get("nonexistent", "python")
        assert.is_nil(data)
    end)

    it("deletes specific session", function()
        session.save("multiply", "python", { solutionId = "sol-1" })
        session.delete("multiply", "python")
        local data = session.get("multiply", "python")
        assert.is_nil(data)
    end)

    it("clears all sessions", function()
        session.save("multiply", "python", { solutionId = "sol-1" })
        session.save("two-sum", "javascript", { solutionId = "sol-2" })

        local count = session.clear_all()
        assert.truthy(count >= 2)

        assert.is_nil(session.get("multiply", "python"))
        assert.is_nil(session.get("two-sum", "javascript"))
    end)

    it("respects TTL", function()
        -- Save with an old timestamp
        local data = { solutionId = "sol-1", cached_at = os.time() - (60 * 60 * 24 * 8) } -- 8 days ago
        local dir = Path:new(tmp_dir, "sessions")
        dir:mkdir({ parents = true })
        local f = dir:joinpath("old-kata_python.json")
        f:write(vim.json.encode(data), "w")

        local result = session.get("old-kata", "python")
        assert.is_nil(result) -- Should be expired
    end)
end)
