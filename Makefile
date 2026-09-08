GLEAM ?= gleam
REBAR3 ?= rebar3

FFI_DIR := src/eparch/ffi
EXAMPLE_MANIFESTS := $(wildcard examples/*/gleam.toml)
EXAMPLE_DIRS := $(patsubst %/gleam.toml,%,$(EXAMPLE_MANIFESTS))
EXAMPLE_TARGETS := $(addprefix example-,$(notdir $(EXAMPLE_DIRS)))

.DEFAULT_GOAL := all

.PHONY: all examples $(EXAMPLE_TARGETS) ffi-check ffi-deps-nix help

## all: Build and test every example project (default).
all: examples

## examples: Build and test every example project.
examples: $(EXAMPLE_TARGETS)

# Each target name maps to the matching directory under examples/. Keeping
# projects as independent prerequisites lets the caller choose parallelism.
$(EXAMPLE_TARGETS): example-%: examples/%/gleam.toml
	@echo "Checking example: $*"
	@cd "examples/$*" && $(GLEAM) update && $(GLEAM) build && $(GLEAM) test

## ffi-check: Run the standalone Erlang library's EUnit and Dialyzer checks.
ffi-check:
	@cd "$(FFI_DIR)" && $(REBAR3) do eunit, dialyzer

## ffi-deps-nix: Regenerate the standalone Erlang library's Nix dependency lock.
ffi-deps-nix:
	@cd "$(FFI_DIR)" && $(REBAR3) as nix nix lock

## help: Show the available targets.
help:
	@sed -n 's/^## /  /p' $(MAKEFILE_LIST)
