"""Graph entities returned by queries: whole nodes and relationships."""

from __future__ import annotations

from dataclasses import dataclass, field

from . import temporal


@dataclass(frozen=True)
class Node:
    """A node as it was when the query ran: its id, labels and properties."""

    id: int
    labels: tuple[str, ...]
    properties: dict = field(hash=False)


@dataclass(frozen=True)
class Relationship:
    """A relationship from `source` to `target` (node ids) of type `type`.

    acmedb keeps one relationship per (source, target, type), which identifies it.
    """

    source: int
    target: int
    type: str
    properties: dict = field(hash=False)


@dataclass(frozen=True)
class Path:
    """A path: `nodes[i]` and `nodes[i + 1]` are joined by `relationships[i]`."""

    nodes: tuple[Node, ...]
    relationships: tuple[Relationship, ...]


def decode(obj: dict):
    """`json.loads` object hook: turns acmedb's tagged objects into entities."""
    if "~node" in obj:
        node = obj["~node"]
        return Node(node["id"], tuple(node["labels"]), node["properties"])
    if "~relationship" in obj:
        rel = obj["~relationship"]
        return Relationship(rel["source"], rel["target"], rel["type"], rel["properties"])
    if "~path" in obj:
        path = obj["~path"]
        return Path(tuple(path["nodes"]), tuple(path["relationships"]))
    if len(obj) == 1:
        (key, value), = obj.items()
        if key.startswith("~") and key[1:] in temporal._TYPES:
            return temporal.decode(key[1:], value)
    return obj
