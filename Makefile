PLENARY_DIR ?= /tmp/plenary.nvim
NUI_DIR ?= /tmp/nui.nvim

.PHONY: test test-file plenary nui deps

# Probe for a FILE we actually require, never a directory. macOS deletes
# the CONTENTS of stale /tmp entries but leaves the directory tree
# standing, so a directory test passes against an empty husk and the clone
# is skipped forever - tests then hang on an unresolvable require.
plenary:
	@case "$(PLENARY_DIR)" in \
		""|/|.|./*|"$$PWD") echo "refusing to touch PLENARY_DIR=$(PLENARY_DIR)"; exit 1 ;; \
	esac
	@if [ ! -f "$(PLENARY_DIR)/lua/plenary/curl.lua" ]; then \
		rm -rf "$(PLENARY_DIR)"; \
		git clone https://github.com/nvim-lua/plenary.nvim "$(PLENARY_DIR)"; \
	fi

# nui backs every split and popup. Without it the whole mounted-UI layer is
# unloadable in tests, which is how two lifecycle regressions shipped.
nui:
	@case "$(NUI_DIR)" in \
		""|/|.|./*|"$$PWD") echo "refusing to touch NUI_DIR=$(NUI_DIR)"; exit 1 ;; \
	esac
	@if [ ! -f "$(NUI_DIR)/lua/nui/popup/init.lua" ]; then \
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
