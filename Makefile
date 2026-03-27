PLENARY_DIR ?= /tmp/plenary.nvim

.PHONY: test test-file plenary

plenary:
	@if [ ! -d "$(PLENARY_DIR)" ]; then \
		git clone https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR); \
	fi

test: plenary
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedDirectory test/ {minimal_init = 'test/minimal_init.lua', sequential = true}"

test-file: plenary
	nvim --headless -u test/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"
