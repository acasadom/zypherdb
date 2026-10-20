"""Graph entities returned by queries: whole nodes, relationships and paths.

They are immutable values: equal when their fields are, hashable by their
identity (a node's id and labels, a relationship's endpoints and type). The
native engine builds them without running `__init__` (which costs more than
the rest of building a node), so `__init__` is only for code that makes one
by hand.
"""

from __future__ import annotations

_set = object.__setattr__


class _Entity:
    __slots__ = ()
    _fields: tuple[str, ...] = ()
    _identity: tuple[str, ...] = ()

    def __init__(self, *values):
        if len(values) != len(self._fields):
            raise TypeError(f"{type(self).__name__} takes {len(self._fields)} arguments ({len(values)} given)")
        for name, value in zip(self._fields, values):
            _set(self, name, value)

    def __setattr__(self, name, value):
        raise AttributeError(f"{type(self).__name__} is immutable")

    def __delattr__(self, name):
        raise AttributeError(f"{type(self).__name__} is immutable")

    def _values(self) -> tuple:
        return tuple(getattr(self, name) for name in self._fields)

    def __eq__(self, other):
        if type(other) is not type(self):
            return NotImplemented
        return self._values() == other._values()

    def __hash__(self):
        return hash((type(self).__name__, *(getattr(self, name) for name in self._identity)))

    def __repr__(self):
        fields = ", ".join(f"{name}={getattr(self, name)!r}" for name in self._fields)
        return f"{type(self).__name__}({fields})"


class Node(_Entity):
    """A node as it was when the query ran: its id, labels and properties."""

    __slots__ = ("id", "labels", "properties")
    _fields = __slots__
    _identity = ("id", "labels")
    id: int
    labels: tuple[str, ...]
    properties: dict


class Relationship(_Entity):
    """A relationship from `source` to `target` (node ids) of type `type`.

    acmedb keeps one relationship per (source, target, type), which identifies it.
    """

    __slots__ = ("source", "target", "type", "properties")
    _fields = __slots__
    _identity = ("source", "target", "type")
    source: int
    target: int
    type: str
    properties: dict


class Path(_Entity):
    """A path: `nodes[i]` and `nodes[i + 1]` are joined by `relationships[i]`."""

    __slots__ = ("nodes", "relationships")
    _fields = __slots__
    _identity = __slots__
    nodes: tuple[Node, ...]
    relationships: tuple[Relationship, ...]
