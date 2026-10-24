"""acmedb — Python bindings for the embedded graph database.

Usage::

    from acmedb import Database

    with Database("/tmp/movies") as db:
        db.add_node(1, "Movie")
        db.set_property(1, "title", "The Matrix")
        print(db.query("MATCH (m:Movie) RETURN m.title"))
"""

from .db import Database, PreparedQuery
from .entities import Node, Path, Relationship
from .temporal import Duration
from .errors import (
    AcmedbError,
    ArithmeticQueryError,
    ClosedError,
    InvalidExpressionError,
    NodeNotFoundError,
    NodeStillConnectedError,
    ConstraintViolationError,
    ExternalResourceError,
    ParameterMissingError,
    ParseError,
    QueryError,
    StorageError,
    TypeMismatchError,
    UnknownVariableError,
)

__all__ = [
    "Database",
    "PreparedQuery",
    "Node",
    "Path",
    "Relationship",
    "Duration",
    "AcmedbError",
    "ArithmeticQueryError",
    "QueryError",
    "ParseError",
    "UnknownVariableError",
    "TypeMismatchError",
    "InvalidExpressionError",
    "NodeStillConnectedError",
    "ConstraintViolationError",
    "ExternalResourceError",
    "ParameterMissingError",
    "NodeNotFoundError",
    "ClosedError",
    "StorageError",
]
