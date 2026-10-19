"""acmedb — Python bindings for the embedded graph database.

Usage::

    from acmedb import Database

    with Database("/tmp/movies") as db:
        db.add_node(1, "Movie")
        db.set_property(1, "title", "The Matrix")
        print(db.query("MATCH (m:Movie) RETURN m.title"))
"""

from .db import Database
from .entities import Node, Relationship
from .errors import (
    AcmedbError,
    ClosedError,
    InvalidExpressionError,
    MissingPropertyError,
    NodeNotFoundError,
    NodeStillConnectedError,
    ParseError,
    QueryError,
    StorageError,
    TypeMismatchError,
    UnknownVariableError,
)

__all__ = [
    "Database",
    "Node",
    "Relationship",
    "AcmedbError",
    "QueryError",
    "ParseError",
    "UnknownVariableError",
    "MissingPropertyError",
    "TypeMismatchError",
    "InvalidExpressionError",
    "NodeStillConnectedError",
    "NodeNotFoundError",
    "ClosedError",
    "StorageError",
]
