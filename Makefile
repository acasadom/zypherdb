# ZypherDB — usual development targets. Zig is a single-binary toolchain, so the
# only real command is `zig`; these are thin conveniences.

.PHONY: build python test test-py tck docs clean

PYTHON ?= python3
PYTHON_INCLUDE = $(shell $(PYTHON) -c "import sysconfig; print(sysconfig.get_paths()['include'])")
# python3.lib, which a Windows build links (ignored elsewhere)
PYTHON_LIBS = $(shell $(PYTHON) -c "import os, sys; print(os.path.join(sys.base_prefix, 'libs'))")

build: ## Compile the static + shared libraries (into zig-out/)
	zig build

python: ## Compile the Python extension module (into zig-out/python/)
	zig build python -Dpython-include="$(PYTHON_INCLUDE)" -Dpython-libs="$(PYTHON_LIBS)"

test: ## Build and run the test suite
	zig build test

test-py: build python ## Run the Python and documentation tests (pip install -e ".[dev]")
	$(PYTHON) -m pytest python/tests -q

tck: python ## Run the openCypher TCK, write its report, fail on regressions
	$(PYTHON) -I tests/tck/runner.py --report tests/tck/REPORT.md --check-baseline

docs: ## Build the HTML documentation (Sphinx + MyST; pip install -r docs/requirements.txt)
	sphinx-build -b html docs docs/_build/html

clean: ## Remove Zig build artifacts and the generated docs
	rm -rf zig-out .zig-cache docs/_build
