PLENARY_DIR ?= /tmp/plenary.nvim
NUI_DIR ?= /tmp/nui.nvim

.PHONY: test test-file plenary nui deps

# The dependency directories get rm -rf'd when stale, and their paths come
# straight from the environment. Refuse the root, $HOME, the checkout, any
# ANCESTOR of the checkout (PLENARY_DIR=.. would have deleted every sibling
# project) and anything INSIDE the checkout (PLENARY_DIR=lua would have
# deleted the plugin). Resolved first, so "..", "../x", "$PWD/" and bare
# relative names cannot slip past a string comparison.
# Resolved with GNU `realpath -m` where available; BSD/macOS realpath has
# no -m (and fails on a path that does not exist yet, which is exactly the
# fresh-clone case), so fall back to resolving the parent with cd/pwd -P.
# If neither works, $$d stays empty and the guard refuses -- never the
# other way round.
define refuse_unsafe_dir
	d=$$(realpath -m -- "$(1)" 2>/dev/null \
		|| (cd "$(1)" 2>/dev/null && pwd -P) \
		|| (cd "$$(dirname -- "$(1)")" 2>/dev/null && printf '%s/%s' "$$(pwd -P)" "$$(basename -- "$(1)")") \
		|| true); \
	case "$$d" in \
		""|/|"$$HOME") echo "refusing to touch $(2)=$(1)"; exit 1 ;; \
	esac; \
	case "$$PWD/" in \
		"$$d/"*) echo "refusing to touch $(2)=$(1) (contains the checkout)"; exit 1 ;; \
	esac; \
	case "$$d/" in \
		"$$PWD/"*) echo "refusing to touch $(2)=$(1) (inside the checkout)"; exit 1 ;; \
	esac
endef

# Probe for a FILE we actually require, never a directory. macOS deletes
# the CONTENTS of stale /tmp entries but leaves the directory tree
# standing, so a directory test passes against an empty husk and the clone
# is skipped forever - tests then hang on an unresolvable require.
plenary:
	@$(call refuse_unsafe_dir,$(PLENARY_DIR),PLENARY_DIR)
	@if [ ! -f "$(PLENARY_DIR)/lua/plenary/curl.lua" ]; then \
		rm -rf "$(PLENARY_DIR)"; \
		git clone https://github.com/nvim-lua/plenary.nvim "$(PLENARY_DIR)"; \
	fi

# nui backs every split and popup. Without it the whole mounted-UI layer is
# unloadable in tests, which is how two lifecycle regressions shipped.
nui:
	@$(call refuse_unsafe_dir,$(NUI_DIR),NUI_DIR)
	@if [ ! -f "$(NUI_DIR)/lua/nui/popup/init.lua" ]; then \
		rm -rf "$(NUI_DIR)"; \
		git clone https://github.com/MunifTanjim/nui.nvim "$(NUI_DIR)"; \
	fi

deps: plenary nui

test: deps
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua', sequential = true}"

test-file: deps
	@test -f "$(FILE)" || { echo "no such spec file: FILE=$(FILE)"; exit 1; }
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedDirectory $(FILE) {minimal_init = 'test/minimal_init.lua', sequential = true}"
