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
