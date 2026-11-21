"""Sphinx configuration for the ZypherDB documentation (Markdown via MyST)."""

project = "ZypherDB"

extensions = ["myst_parser", "sphinxcontrib.mermaid"]

# Documentation is authored in Markdown.
source_suffix = {".md": "markdown"}
root_doc = "index"

exclude_patterns = ["_build"]

html_theme = "furo"  # modern, responsive, dark-mode; install via docs/requirements.txt

# Resolve in-page links like [text](#a-heading) to heading anchors (h1..h3).
myst_heading_anchors = 3

# Pygments' Cypher lexer does not know `$parameters` or the arithmetic operators, and Sphinx
# warns on every block that has one; this one adds them.
from pygments.lexer import inherit
from pygments.lexers import CypherLexer
from pygments.token import Name, Operator


class _CypherLexer(CypherLexer):
    tokens = {"root": [(r"\$\w+", Name.Variable), inherit, (r"[-+/%^!]", Operator)]}


def setup(app):
    app.add_lexer("cypher", _CypherLexer)
