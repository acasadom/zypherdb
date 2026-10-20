"""Runs the Python examples of the documentation, so they never drift from the engine.

Every ```python block under docs/ is executed:

- the tutorial (docs/tutorial/NN-*.md) runs as one session, page after page
  in order, as a reader following it does: later blocks see the variables of
  earlier ones, across pages;
- every other page runs on its own, its blocks in one namespace.

A ```text block that directly follows a python block (only blank lines between
them) is that block's expected output: what the block prints must match it
exactly (trailing spaces aside). Mark a block that must not run with
``# docs-test: skip`` as its first line.
"""

from __future__ import annotations

import contextlib
import io
import re
from pathlib import Path

import pytest

DOCS = Path(__file__).resolve().parents[2] / "docs"

# A fenced block: its language and its body.
_FENCE = re.compile(r"^```(\w*)[^\n]*\n(.*?)^```[ \t]*$", re.MULTILINE | re.DOTALL)


def _examples(page: Path) -> list[tuple[str, str | None]]:
    """The page's python blocks, each with the output the page shows for it."""
    text = page.read_text()
    blocks = [(m.group(1), m.group(2), m.start(), m.end()) for m in _FENCE.finditer(text)]
    examples = []
    for i, (language, body, _, end) in enumerate(blocks):
        if language != "python" or body.lstrip().startswith("# docs-test: skip"):
            continue
        expected = None
        if i + 1 < len(blocks):
            next_language, next_body, next_start, _ = blocks[i + 1]
            if next_language == "text" and text[end:next_start].strip() == "":
                expected = next_body
        examples.append((body, expected))
    return examples


def _run(page: Path, namespace: dict) -> None:
    for i, (code, expected) in enumerate(_examples(page)):
        printed = io.StringIO()
        try:
            with contextlib.redirect_stdout(printed):
                exec(compile(code, f"{page.name} block {i}", "exec"), namespace)
        except Exception as error:  # report which page and block failed
            pytest.fail(f"{page.name} block {i} raised {type(error).__name__}: {error}\n--- block ---\n{code}")
        if expected is not None:
            actual = "\n".join(line.rstrip() for line in printed.getvalue().rstrip("\n").split("\n"))
            wanted = "\n".join(line.rstrip() for line in expected.rstrip("\n").split("\n"))
            assert actual == wanted, f"{page.name} block {i} printed:\n{actual}\n--- the page shows ---\n{wanted}"


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
