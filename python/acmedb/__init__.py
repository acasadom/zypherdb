"""acmedb — Python bindings for the embedded graph database.

Usage::

    from acmedb import Database

    with Database("/tmp/movies") as db:
        db.add_node(1, "Movie")
        db.set_property(1, "title", "The Matrix")
        print(db.query("MATCH (m:Movie) RETURN m.title"))
"""

from .db import Database
from .entities import Node, Path, Relationship
from .temporal import Date, DateTime, Duration, LocalDateTime, LocalTime, Temporal, Time
from .errors import (
    AcmedbError,
    ArithmeticQueryError,
    ClosedError,
    InvalidExpressionError,
    NodeNotFoundError,
    NodeStillConnectedError,
    ParameterMissingError,
    ParseError,
    QueryError,
    StorageError,
    TypeMismatchError,
    UnknownVariableError,
)

__all__ = [
    "Database",
    "Node",
    "Path",
    "Relationship",
    "Temporal",
    "Date",
    "LocalTime",
    "Time",
    "LocalDateTime",
    "DateTime",
    "Duration",
    "AcmedbError",
    "ArithmeticQueryError",
    "QueryError",
    "ParseError",
    "UnknownVariableError",
    "TypeMismatchError",
    "InvalidExpressionError",
    "NodeStillConnectedError",
    "ParameterMissingError",
    "NodeNotFoundError",
    "ClosedError",
    "StorageError",
]
