"""Values for TCK result comparison.

Expected values come from TCK tables written as Cypher literals: `null`,
`true`, `42`, `1.5`, `NaN`, `'text'`, `[1, 2]`, `{a: 1}`, nodes `(:A {k: 1})`,
relationships `[:T {k: 1}]` and paths `<(:A)-[:T]->(:B)>`. Actual values come
from acmedb (Python values decoded from its JSON results).

Both are turned into one canonical, hashable form, tagged by type (in Python
`True == 1`, which must not make a boolean equal an integer):

    ("null",) ("bool", b) ("int", n) ("float", x) ("string", s)
    ("list", (...)) ("map", ((key, value), ...)) ("node", labels, map)
    ("relationship", type, map) ("path", (...))

NaN canonicalizes to ("float", "NaN") so that NaN rows compare equal.
"""

from __future__ import annotations

import math

NULL = ("null",)


def canonical_float(x: float):
    return ("float", "NaN") if math.isnan(x) else ("float", x)


def canonical_map(entries: dict) -> tuple:
    return ("map", tuple(sorted(entries.items())))


def from_python(value):
    """Canonical form of a value decoded from an acmedb result."""
    if value is None:
        return NULL
    if isinstance(value, bool):
        return ("bool", value)
    if isinstance(value, int):
        return ("int", value)
    if isinstance(value, float):
        return canonical_float(value)
    if isinstance(value, str):
        return ("string", value)
    if isinstance(value, list):
        return ("list", tuple(from_python(v) for v in value))
    if isinstance(value, dict):
        return canonical_map({k: from_python(v) for k, v in value.items()})
    from acmedb import Node, Relationship

    if isinstance(value, Node):
        properties = {k: from_python(v) for k, v in value.properties.items()}
        return ("node", tuple(sorted(value.labels)), canonical_map(properties))
    if isinstance(value, Relationship):
        properties = {k: from_python(v) for k, v in value.properties.items()}
        return ("relationship", value.type, canonical_map(properties))
    raise TypeError(f"unexpected result value {value!r}")


def to_python(value):
    """The Python value of a canonical literal (for query parameters)."""
    tag = value[0]
    if tag == "null":
        return None
    if tag in ("bool", "int", "string"):
        return value[1]
    if tag == "float":
        return float("nan") if value[1] == "NaN" else value[1]
    if tag == "list":
        return [to_python(v) for v in value[1]]
    if tag == "map":
        return {k: to_python(v) for k, v in value[1]}
    raise ValueError(f"a {tag} cannot be a parameter")


def ignoring_list_order(value):
    """The same value with every list's elements in a canonical order."""
    tag = value[0]
    if tag == "list":
        return ("list", tuple(sorted((ignoring_list_order(v) for v in value[1]), key=repr)))
    if tag == "map":
        return ("map", tuple((k, ignoring_list_order(v)) for k, v in value[1]))
    return value


class _Reader:
    """Recursive-descent reader for one TCK value literal."""

    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def fail(self, message: str):
        raise ValueError(f"{message} at {self.pos} in {self.text!r}")

    def skip_space(self):
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1

    def peek(self, token: str) -> bool:
        self.skip_space()
        return self.text.startswith(token, self.pos)

    def expect(self, token: str):
        if not self.peek(token):
            self.fail(f"expected {token!r}")
        self.pos += len(token)

    def accept(self, token: str) -> bool:
        if self.peek(token):
            self.pos += len(token)
            return True
        return False

    def name(self) -> str:
        self.skip_space()
        if self.accept("`"):
            end = self.text.index("`", self.pos)
            name, self.pos = self.text[self.pos:end], end + 1
            return name
        start = self.pos
        while self.pos < len(self.text) and (self.text[self.pos].isalnum() or self.text[self.pos] == "_"):
            self.pos += 1
        if start == self.pos:
            self.fail("expected a name")
        return self.text[start:self.pos]

    def value(self):
        self.skip_space()
        rest = self.text[self.pos:]
        for word, canonical in (("null", NULL), ("true", ("bool", True)), ("false", ("bool", False)),
                                ("NaN", ("float", "NaN"))):
            if rest.startswith(word) and not rest[len(word):len(word) + 1].isalnum():
                self.pos += len(word)
                return canonical
        if rest.startswith("'"):
            return ("string", self.string())
        if rest.startswith("["):
            return self.list_or_relationship()
        if rest.startswith("{"):
            return canonical_map(self.map_entries())
        if rest.startswith("("):
            return self.node()
        if rest.startswith("<"):
            return self.path()
        return self.number()

    def number(self):
        self.skip_space()
        start = self.pos
        while self.pos < len(self.text) and (self.text[self.pos].isalnum() or self.text[self.pos] in "+-."):
            self.pos += 1
        token = self.text[start:self.pos]
        if token in ("Inf", "Infinity", "+Inf"):
            return ("float", math.inf)
        if token in ("-Inf", "-Infinity"):
            return ("float", -math.inf)
        try:
            return ("int", int(token, 0))
        except ValueError:
            try:
                return canonical_float(float(token))
            except ValueError:
                self.fail(f"not a value: {token!r}")

    def string(self) -> str:
        self.expect("'")
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "'": "'", '"': '"', "\\": "\\", "/": "/"}
        while True:
            char = self.text[self.pos]
            self.pos += 1
            if char == "'":
                return "".join(out)
            if char == "\\":
                escaped = self.text[self.pos]
                self.pos += 1
                if escaped == "u":
                    out.append(chr(int(self.text[self.pos:self.pos + 4], 16)))
                    self.pos += 4
                else:
                    out.append(escapes.get(escaped, escaped))
            else:
                out.append(char)

    def map_entries(self) -> dict:
        self.expect("{")
        entries = {}
        if self.accept("}"):
            return entries
        while True:
            key = self.name()
            self.expect(":")
            entries[key] = self.value()
            if self.accept("}"):
                return entries
            self.expect(",")

    def list_or_relationship(self):
        self.expect("[")
        if self.peek(":"):
            return self.relationship_body()
        items = []
        if self.accept("]"):
            return ("list", ())
        while True:
            items.append(self.value())
            if self.accept("]"):
                return ("list", tuple(items))
            self.expect(",")

    def relationship_body(self):
        self.expect(":")
        rel_type = self.name()
        properties = self.map_entries() if self.peek("{") else {}
        self.expect("]")
        return ("relationship", rel_type, canonical_map(properties))

    def node(self):
        self.expect("(")
        labels = []
        while self.accept(":"):
            labels.append(self.name())
        properties = self.map_entries() if self.peek("{") else {}
        self.expect(")")
        return ("node", tuple(sorted(labels)), canonical_map(properties))

    def path(self):
        self.expect("<")
        elements = [self.node()]
        while not self.accept(">"):
            leftward = self.accept("<-")
            if not leftward:
                self.expect("-")
            self.expect("[")
            relationship = self.relationship_body()
            if self.accept("->"):
                direction = "out"
            else:
                self.expect("-")
                direction = "in" if leftward else "undirected"
            elements.append((relationship, direction))
            elements.append(self.node())
        return ("path", tuple(elements))


def parse(text: str):
    """Canonical form of one TCK value literal."""
    reader = _Reader(text)
    value = reader.value()
    reader.skip_space()
    if reader.pos != len(text):
        reader.fail("trailing text")
    return value
