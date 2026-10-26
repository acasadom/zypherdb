"""Runs the Python examples of the documentation, so they never drift from the engine.

Every ```python block under docs/ is executed:

- the tutorial (docs/tutorial/NN-*.md) runs as one session, page after page
  in order, as a reader following it does: later blocks see the variables of
  earlier ones, across pages;
- every other page runs on its own, its blocks in one namespace.

Every ```c block that is a whole program (it has a ``main``) is compiled with
``zig cc`` against the library in zig-out/ and run with a fresh database
directory as its argument.

Every ```bash block whose only line is ``python -m examples.…`` runs that
example from the repository root.

A ```text block that directly follows a python, c or bash block (only blank lines
between them) is that block's expected output: what the block prints must match
it exactly (trailing spaces aside). Mark a block that must not run with
``# docs-test: skip`` (``// docs-test: skip`` in C) as its first line.
"""

from __future__ import annotations

import contextlib
import io
import re
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
BUILD = ROOT / "zig-out"

# A fenced block: its language and its body.
_FENCE = re.compile(r"^```(\w*)[^\n]*\n(.*?)^```[ \t]*$", re.MULTILINE | re.DOTALL)


_SKIP = {"python": "# docs-test: skip", "c": "// docs-test: skip", "bash": "# docs-test: skip"}


def _examples(page: Path, wanted: str = "python") -> list[tuple[str, str | None]]:
    """The page's blocks in language `wanted`, each with the output the page shows for it."""
    text = page.read_text(encoding="utf-8")
    blocks = [(m.group(1), m.group(2), m.start(), m.end()) for m in _FENCE.finditer(text)]
    examples = []
    for i, (language, body, _, end) in enumerate(blocks):
        if language != wanted or body.lstrip().startswith(_SKIP[wanted]):
            continue
        expected = None
        if i + 1 < len(blocks):
            next_language, next_body, next_start, _ = blocks[i + 1]
            if next_language == "text" and text[end:next_start].strip() == "":
                expected = next_body
        examples.append((body, expected))
    return examples


def _matches(actual: str, expected: str) -> bool:
    def lines(text: str) -> str:
        return "\n".join(line.rstrip() for line in text.rstrip("\n").split("\n"))

    return lines(actual) == lines(expected)


def _run(page: Path, namespace: dict) -> None:
    for i, (code, expected) in enumerate(_examples(page)):
        printed = io.StringIO()
        try:
            with contextlib.redirect_stdout(printed):
                exec(compile(code, f"{page.name} block {i}", "exec"), namespace)
        except Exception as error:  # report which page and block failed
            pytest.fail(f"{page.name} block {i} raised {type(error).__name__}: {error}\n--- block ---\n{code}")
        if expected is not None:
            actual = printed.getvalue()
            assert _matches(actual, expected), f"{page.name} block {i} printed:\n{actual}\n--- the page shows ---\n{expected}"


def _tutorial_pages() -> list[Path]:
    return sorted((DOCS / "tutorial").glob("[0-9][0-9]-*.md"))


def _other_pages() -> list[Path]:
    tutorial = set(_tutorial_pages())
    return sorted(p for p in DOCS.rglob("*.md") if p not in tutorial and "_build" not in p.parts and _examples(p))


@pytest.fixture
def scratch(tmp_path, monkeypatch):
    """Runs the examples in a scratch directory, so the databases they make go there."""
    monkeypatch.chdir(tmp_path)
    return tmp_path


def test_tutorial(scratch):
    namespace: dict = {"__name__": "__docs__"}
    for page in _tutorial_pages():
        _run(page, namespace)


@pytest.mark.parametrize("page", _other_pages(), ids=lambda p: str(p.relative_to(DOCS)))
def test_page(page, scratch):
    _run(page, {"__name__": "__docs__"})


def _c_programs() -> list:
    programs = []
    for page in sorted(p for p in DOCS.rglob("*.md") if "_build" not in p.parts):
        for i, (code, expected) in enumerate(_examples(page, "c")):
            if re.search(r"\bint main\(", code):
                programs.append(pytest.param(page, i, code, expected, id=f"{page.relative_to(DOCS)}-{i}"))
    return programs


@pytest.mark.parametrize("page, index, code, expected", _c_programs())
def test_c_program(page, index, code, expected, scratch):
    compiler = shutil.which("zig")
    if compiler is None or not (BUILD / "include" / "zypherdb.h").exists():
        pytest.skip("needs zig and the library built with `zig build`")
    source = scratch / "program.c"
    source.write_text(code, encoding="utf-8")
    library = BUILD / "lib"
    subprocess.run(
        [compiler, "cc", f"-I{BUILD / 'include'}", str(source), f"-L{library}", "-lzypherdb",
         f"-Wl,-rpath,{library}", "-o", str(scratch / "program")],
        check=True,
    )
    database = scratch / "db"
    database.mkdir()
    # Windows has no rpath: it finds zypherdb.dll (installed in bin/) through PATH.
    environment = {**os.environ, "PATH": os.pathsep.join([str(BUILD / "bin"), os.environ.get("PATH", "")])}
    run = subprocess.run([str(scratch / "program"), str(database)], env=environment, capture_output=True, text=True, timeout=60)
    assert run.returncode == 0, f"{page.name} C block {index} exited with {run.returncode}:\n{run.stderr}"
    if expected is not None:
        assert _matches(run.stdout, expected), f"{page.name} C block {index} printed:\n{run.stdout}\n--- the page shows ---\n{expected}"


def _example_runs() -> list:
    runs = []
    for page in sorted(p for p in DOCS.rglob("*.md") if "_build" not in p.parts):
        for i, (command, expected) in enumerate(_examples(page, "bash")):
            line = command.strip()
            if "\n" not in line and line.startswith("python -m examples."):
                runs.append(pytest.param(line.split()[1:], expected, id=f"{page.relative_to(DOCS)}-{i}"))
    return runs


@pytest.mark.parametrize("arguments, expected", _example_runs())
def test_example(arguments, expected):
    environment = {**os.environ, "PYTHONPATH": os.pathsep.join([str(ROOT / "python"), str(ROOT)])}
    run = subprocess.run([sys.executable, *arguments], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=300)
    assert run.returncode == 0, f"{' '.join(arguments)} exited with {run.returncode}:\n{run.stderr}"
    if expected is not None:
        assert _matches(run.stdout, expected), f"{' '.join(arguments)} printed:\n{run.stdout}\n--- the page shows ---\n{expected}"
