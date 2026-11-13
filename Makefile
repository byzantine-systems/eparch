# I know you can easily shoot yourself in the foot
# with this.
MAKEFLAGS += -j$(shell nproc)

# Gets all projects inside the examples/ directory
EXAMPLES := $(wildcard examples/*/)
FFI_DIR := src/eparch/ffi

.PHONY: all ffi-check ffi-deps-nix antithesis-smoke antithesis-check $(EXAMPLES)

# Default target
all: $(EXAMPLES)

# The recipe for each directory
$(EXAMPLES):
	@echo "Starting build for: $@"
	@cd $@ && gleam deps update && gleam build && gleam test
	@echo "Finished build for: $@"

ffi-check:
	@cd $(FFI_DIR) && rebar3 do eunit, dialyzer

ffi-deps-nix:
	@cd $(FFI_DIR) && rebar3 as nix nix lock

# Run every Antithesis workload scenario locally (no SDK, no container):
# no Always verdict may fail and every Sometimes verdict must be witnessed.
antithesis-smoke:
	@gleam build --warnings-as-errors
	@cd antithesis && EPARCH_EBIN='../build/dev/erlang/*/ebin' uv run --frozen eparch-antithesis smoke

# Unit tests and type checks for the Antithesis driver project.
antithesis-check:
	@cd antithesis && uv run --frozen pytest -q && pyrefly check
