test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests/solomon/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

.PHONY: test
