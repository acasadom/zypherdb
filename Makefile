# acmedb — usual development targets. Zig is a single-binary toolchain, so the
# only real command is `zig`; these are thin conveniences.

.PHONY: build test test-py tck docs clean

build: ## Compile the static + shared libraries (into zig-out/)
	zig build

test: ## Build and run the test suite
	zig build test

test-py: build ## Run the Python binding tests (pip install -e "python[dev]")
	python -m pytest python/tests -q

tck: build ## Run the openCypher TCK, write its report, fail on regressions
	python -I tests/tck/runner.py --report tests/tck/REPORT.md --check-baseline

docs: ## Build the HTML documentation (Sphinx + MyST; pip install -r docs/requirements.txt)
	sphinx-build -b html docs docs/_build/html

clean: ## Remove Zig build artifacts and the generated docs
	rm -rf zig-out .zig-cache docs/_build
