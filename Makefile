# acmedb — usual development targets. Zig is a single-binary toolchain, so the
# only real command is `zig`; these are thin conveniences.

.PHONY: build test docs clean

build: ## Compile the static + shared libraries (into zig-out/)
	zig build

test: ## Build and run the test suite
	zig build test

docs: ## Build the HTML documentation (Sphinx + MyST; pip install -r docs/requirements.txt)
	sphinx-build -b html docs docs/_build/html

clean: ## Remove Zig build artifacts and the generated docs
	rm -rf zig-out .zig-cache docs/_build
