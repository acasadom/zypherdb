"""A minimal Gherkin reader for the openCypher TCK feature files.

It supports what the TCK uses: Feature, Background, Scenario, Scenario Outline
with Examples, tags, docstrings (\"\"\") and tables. Outlines are expanded into
one scenario per example row.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

_STEP_KEYWORDS = ("Given ", "When ", "Then ", "And ", "But ")


@dataclass
class Step:
    keyword: str  # Given / When / Then (And/But resolved to the previous one)
    text: str
    docstring: str | None = None
    table: list[list[str]] | None = None


@dataclass
class Scenario:
    feature_path: str  # relative to the features directory
    name: str
    tags: set[str]
    steps: list[Step]
    example: int | None = None  # 1-based example row of an outline

    @property
    def id(self) -> str:
        """A stable identifier, used by the baseline file."""
        suffix = f" #{self.example}" if self.example is not None else ""
        return f"{self.feature_path}: {self.name}{suffix}"


@dataclass
class _Outline:
    name: str
    tags: set[str]
    steps: list[Step]
    examples: list[list[str]] = field(default_factory=list)


def _split_row(line: str) -> list[str]:
    """Cells of a table row; `\\|` is an escaped pipe inside a cell."""
    inner = line.strip()[1:-1]
    cells = re.split(r"(?<!\\)\|", inner)
    return [cell.strip().replace("\\|", "|") for cell in cells]


def _substitute(text: str | None, values: dict[str, str]) -> str | None:
    if text is None:
        return None
    for name, value in values.items():
        text = text.replace(f"<{name}>", value)
    return text


def parse_feature(path: Path, features_root: Path) -> list[Scenario]:
    """Parses one .feature file into its (expanded) scenarios."""
    relative = path.relative_to(features_root).as_posix()
    lines = path.read_text(encoding="utf-8").splitlines()

    background: list[Step] = []
    scenarios: list[Scenario] = []
    current: _Outline | None = None
    current_is_background = False
    pending_tags: set[str] = set()
    in_examples = False
    last_keyword = "Given"

    def finish():
        nonlocal current
        if current is None or current_is_background:
            return
        steps = background + current.steps
        if current.examples:
            header, *rows = current.examples
            for number, row in enumerate(rows, start=1):
                values = dict(zip(header, row))
                expanded = [
                    Step(
                        s.keyword,
                        _substitute(s.text, values),
                        _substitute(s.docstring, values),
                        [[_substitute(c, values) for c in r] for r in s.table] if s.table else None,
                    )
                    for s in steps
                ]
                scenarios.append(Scenario(relative, current.name, current.tags, expanded, number))
        else:
            scenarios.append(Scenario(relative, current.name, current.tags, list(steps)))
        current = None

    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        i += 1
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("@"):
            pending_tags |= set(stripped.split())
            continue
        if stripped.startswith("Feature:"):
            continue
        if stripped.startswith("Background:"):
            finish()
            current = _Outline("Background", set(), [])
            current_is_background = True
            in_examples = False
            continue
        if stripped.startswith(("Scenario:", "Scenario Outline:")):
            if current_is_background and current is not None:
                background = current.steps
            current_is_background = False
            finish()
            current = _Outline(stripped.split(":", 1)[1].strip(), pending_tags, [])
            pending_tags = set()
            in_examples = False
            continue
        if stripped.startswith("Examples:"):
            in_examples = True
            continue
        if stripped.startswith("|"):
            row = _split_row(stripped)
            if in_examples:
                current.examples.append(row)
            else:
                step = current.steps[-1]
                step.table = (step.table or []) + [row]
            continue
        if stripped.startswith('"""'):
            indent = len(lines[i - 1]) - len(lines[i - 1].lstrip())
            body = []
            while not lines[i].strip().startswith('"""'):
                body.append(lines[i][indent:] if lines[i].strip() else "")
                i += 1
            i += 1  # closing quotes
            current.steps[-1].docstring = "\n".join(body)
            continue
        if stripped.startswith(_STEP_KEYWORDS):
            keyword, text = stripped.split(" ", 1)
            if keyword in ("And", "But"):
                keyword = last_keyword
            last_keyword = keyword
            current.steps.append(Step(keyword, text))
            continue
        raise ValueError(f"{relative}:{i}: unrecognised line: {stripped}")

    if current_is_background and current is not None:
        background = current.steps
        current = None
    finish()
    return scenarios


def load_scenarios(features_root: Path) -> list[Scenario]:
    """Every scenario of every feature file, in path order."""
    scenarios = []
    for path in sorted(features_root.rglob("*.feature")):
        scenarios.extend(parse_feature(path, features_root))
    return scenarios
