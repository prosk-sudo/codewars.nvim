PLENARY_DIR ?= /tmp/plenary.nvim
NUI_DIR ?= /tmp/nui.nvim

.PHONY: test test-file plenary nui deps

plenary:
	@if [ ! -d "$(PLENARY_DIR)/lua" ]; then \
		rm -rf "$(PLENARY_DIR)"; \
		git clone https://github.com/nvim-lua/plenary.nvim "$(PLENARY_DIR)"; \
	fi

# nui backs every split and popup. Without it the whole mounted-UI layer is
# unloadable in tests, which is how two lifecycle regressions shipped.
nui:
	@if [ ! -d "$(NUI_DIR)/lua" ]; then \
		rm -rf "$(NUI_DIR)"; \
		git clone https://github.com/MunifTanjim/nui.nvim "$(NUI_DIR)"; \
	fi

deps: plenary nui

test: deps
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua', sequential = true}"

test-file: deps
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"
