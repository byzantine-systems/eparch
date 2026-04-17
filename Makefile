# I know you can easily shoot yourself in the foot
# with this.
MAKEFLAGS += -j$(shell nproc)

# Gets all projects inside the examples/ directory
EXAMPLES := $(wildcard examples/*/)

.PHONY: all $(EXAMPLES)

# Default target
all: $(EXAMPLES)

# The recipe for each directory
$(EXAMPLES):
	@echo "Starting build for: $@"
	@cd $@ && gleam deps update && gleam build && gleam test
	@echo "Finished build for: $@"
