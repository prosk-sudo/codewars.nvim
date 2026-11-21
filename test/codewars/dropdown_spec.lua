describe("picker.dropdown", function()
    local errors = {}
    package.loaded["codewars.logger"] = {
        info = function() end,
        warn = function() end,
        error = function(msg) table.insert(errors, msg) end,
        err = function() end,
        debug = function() end,
    }

    local captured

    local function install_telescope_stub()
        captured = { new_calls = {} }
        -- provider() auto-detects telescope through this module
        package.loaded["telescope"] = {}
        package.loaded["telescope.pickers"] = {
            new = function(topts, cfg)
                table.insert(captured.new_calls, { topts = topts, cfg = cfg })
                return {
                    find = function() captured.found = true end,
                }
            end,
        }
        package.loaded["telescope.finders"] = {
            new_table = function(args)
                return { __table = args }
            end,
        }
        package.loaded["telescope.config"] = {
            values = {
                generic_sorter = function() return "SORTER" end,
            },
        }
        package.loaded["telescope.actions"] = {
            select_default = {
                -- called as select_default:replace(fn) — first arg is self
                replace = function(_, fn) captured.select_fn = fn end,
            },
            close = function(buf) captured.closed = buf end,
        }
        package.loaded["telescope.actions.state"] = {
            get_selected_entry = function() return captured.selected end,
        }
        package.loaded["telescope.pickers.entry_display"] = {
            create = function()
                return function(segments)
                    captured.display_segments = segments
                    return "DISPLAYED"
                end
            end,
        }
        package.loaded["telescope.themes"] = {
            get_dropdown = function(o)
                captured.theme_opts = o
                return o
            end,
        }
    end

    local function clear_telescope_stub()
        for _, mod in ipairs({
            "telescope", "telescope.pickers", "telescope.finders", "telescope.config",
            "telescope.actions", "telescope.actions.state",
            "telescope.pickers.entry_display", "telescope.themes",
        }) do
            package.loaded[mod] = nil
        end
    end

    local dd = require("codewars.picker.dropdown")

    before_each(function()
        errors = {}
        install_telescope_stub()
        dd._reset()
    end)

    --- Open a dropdown and return the captured telescope config.
    local function open(opts)
        dd.open(opts)
        local call = captured.new_calls[#captured.new_calls]
        assert.is_not_nil(call)
        return call.cfg, call.topts
    end

    --- Simulate pressing <CR> on the entry at index `idx` (nil = no selection).
    local function select_entry(cfg, idx)
        cfg.attach_mappings(101)
        if idx then
            local ft = cfg.finder.__table
            captured.selected = ft.entry_maker(ft.results[idx])
        else
            captured.selected = nil
        end
        captured.select_fn()
    end

    it("passes prompt_title and default_idx through to telescope", function()
        local cfg = open({
            prompt_title = "Sort by",
            entries = { { label = "A", value = 1 }, { label = "B", value = 2 } },
            default_idx = 2,
        })
        assert.are.equal("Sort by", cfg.prompt_title)
        assert.are.equal(2, cfg.default_selection_index)
        assert.is_true(captured.found)
    end)

    it("uses explicit width/height, defaults otherwise", function()
        local _, topts = open({
            prompt_title = "t",
            entries = { { label = "A", value = 1 } },
            width = 50,
            height = 7,
        })
        assert.are.equal(50, topts.layout_config.width)
        assert.are.equal(7, topts.layout_config.height)

        local _, topts2 = open({
            prompt_title = "t",
            entries = { { label = "A", value = 1 }, { label = "B", value = 2 } },
        })
        assert.are.equal(40, topts2.layout_config.width)
        assert.are.equal(6, topts2.layout_config.height) -- #entries + 4
    end)

    it("caps default height at 25", function()
        local entries = {}
        for i = 1, 40 do
            table.insert(entries, { label = "e" .. i, value = i })
        end
        local _, topts = open({ prompt_title = "t", entries = entries })
        assert.are.equal(25, topts.layout_config.height)
    end)

    it("plain entries display their label and use label as ordinal", function()
        local cfg = open({
            prompt_title = "t",
            entries = { { label = "  Shuffle", value = 1 } },
        })
        local ft = cfg.finder.__table
        local entry = ft.entry_maker(ft.results[1])
        assert.are.equal("  Shuffle", entry.display())
        assert.are.equal("  Shuffle", entry.ordinal)
    end)

    it("icon entries render through the 2-column displayer", function()
        local cfg = open({
            prompt_title = "t",
            entries = {
                { label = "python (3)", value = 1, icon = "P", icon_hl = "codewars_lang_python" },
            },
        })
        local ft = cfg.finder.__table
        local entry = ft.entry_maker(ft.results[1])
        assert.are.equal("DISPLAYED", entry.display())
        assert.are.same({ "P", "codewars_lang_python" }, captured.display_segments[1])
        assert.are.same({ "python (3)" }, captured.display_segments[2])
    end)

    it("respects a custom ordinal", function()
        local cfg = open({
            prompt_title = "t",
            entries = { { label = "Python", value = 1, ordinal = "python Python" } },
        })
        local ft = cfg.finder.__table
        local entry = ft.entry_maker(ft.results[1])
        assert.are.equal("python Python", entry.ordinal)
    end)

    it("on_select receives the entry value and closes the dropdown", function()
        local got
        local cfg = open({
            prompt_title = "t",
            entries = {
                { label = "A", value = { lang = "python" } },
                { label = "B", value = { lang = nil } },
            },
            on_select = function(v) got = v end,
        })
        select_entry(cfg, 1)
        assert.are.same({ lang = "python" }, got)
        assert.are.equal(101, captured.closed)
    end)

    it("wrapped nil values survive selection (All-languages case)", function()
        local got, called
        local cfg = open({
            prompt_title = "t",
            entries = { { label = "All", value = { lang = nil } } },
            on_select = function(v)
                called = true
                got = v
            end,
        })
        select_entry(cfg, 1)
        assert.is_true(called)
        assert.is_nil(got.lang)
    end)

    it("<CR> with no selection is a no-op", function()
        local called = false
        local cfg = open({
            prompt_title = "t",
            entries = { { label = "A", value = 1 } },
            on_select = function() called = true end,
        })
        select_entry(cfg, nil)
        assert.is_false(called)
        assert.is_nil(captured.closed)
    end)

    -- config.user is the shared default table until apply(); swap in a fresh
    -- one per case instead of mutating it.
    local config = require("codewars.config")
    local function with_provider(provider, fn)
        local saved = config.user
        config.user = { picker = { provider = provider } }
        dd._reset()
        local ok, err = pcall(fn)
        config.user = saved
        dd._reset()
        if not ok then error(err, 0) end
    end

    it("logs an error and bails when telescope is requested but missing", function()
        clear_telescope_stub()
        with_provider("telescope", function()
            dd.open({ prompt_title = "t", entries = {} })
        end)
        assert.are.equal(1, #errors)
        assert.truthy(errors[1]:match("telescope"))
    end)

    describe("provider", function()
        it("auto-detects telescope when it is installed", function()
            with_provider(nil, function()
                assert.are.equal("telescope", dd.provider())
            end)
        end)

        it("falls back to vim.ui.select without telescope", function()
            clear_telescope_stub()
            with_provider(nil, function()
                assert.are.equal("select", dd.provider())
            end)
        end)

        it("honours an explicit provider over what is installed", function()
            with_provider("select", function()
                assert.are.equal("select", dd.provider())
            end)
            clear_telescope_stub()
            with_provider("telescope", function()
                assert.are.equal("telescope", dd.provider())
            end)
        end)
    end)

    describe("vim.ui.select backend", function()
        local real_select = vim.ui.select
        local sel

        before_each(function()
            sel = nil
            vim.ui.select = function(items, opts, on_choice)
                sel = { items = items, opts = opts, on_choice = on_choice }
            end
        end)

        after_each(function()
            vim.ui.select = real_select
        end)

        local function open_select(opts)
            with_provider("select", function() dd.open(opts) end)
            assert.is_not_nil(sel)
            return sel
        end

        it("never touches telescope", function()
            open_select({ prompt_title = "t", entries = { { label = "A", value = 1 } } })
            assert.are.equal(0, #captured.new_calls)
        end)

        it("passes the title as the prompt", function()
            local s = open_select({ prompt_title = "Sort by", entries = { { label = "A", value = 1 } } })
            assert.are.equal("Sort by", s.opts.prompt)
        end)

        it("formats entries with and without an icon", function()
            local s = open_select({
                prompt_title = "t",
                entries = {
                    { label = "Python", value = 1, icon = "P" },
                    { label = "  Shuffle", value = 2 },
                },
            })
            assert.are.equal("P Python", s.opts.format_item(s.items[1]))
            assert.are.equal("  Shuffle", s.opts.format_item(s.items[2]))
        end)

        it("on_select receives the entry value, wrapped nil included", function()
            local got, called
            local s = open_select({
                prompt_title = "t",
                entries = { { label = "All", value = { lang = nil } } },
                on_select = function(v)
                    called = true
                    got = v
                end,
            })
            s.on_choice(s.items[1], 1)
            assert.is_true(called)
            assert.is_nil(got.lang)
        end)

        it("cancel is a no-op", function()
            local called = false
            local s = open_select({
                prompt_title = "t",
                entries = { { label = "A", value = 1 } },
                on_select = function() called = true end,
            })
            s.on_choice(nil, nil)
            assert.is_false(called)
        end)
    end)
end)
