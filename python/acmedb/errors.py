"""Typed exceptions, mapped from acmedb's stable error codes."""


class AcmedbError(Exception):
    """Base class for every acmedb error."""


class StorageError(AcmedbError):
    """A storage-layer failure (I/O, the storage engine)."""


class ClosedError(AcmedbError):
    """The `Database` was used after `close()`."""


class NodeNotFoundError(AcmedbError):
    """A mutator referenced a node id that does not exist."""


class QueryError(AcmedbError):
    """A query failed to run. Carries the error code and message."""

    def __init__(self, code: int, message: str):
        self.code = code
        self.message = message
        super().__init__(f"{message} (code {code})")


class ParseError(QueryError):
    """The query text did not parse."""


class UnknownVariableError(QueryError):
    """The query referenced a variable that is not bound."""


class TypeMismatchError(QueryError):
    """An operator or function got a value of the wrong type."""


class InvalidExpressionError(QueryError):
    """An expression is ill-formed (e.g. a WITH projection without an alias)."""


class NodeStillConnectedError(QueryError):
    """A DELETE targeted a node that still has relationships (use DETACH DELETE)."""


class ParameterMissingError(QueryError):
    """The query uses a `$name` parameter that was not given."""


class ArithmeticQueryError(QueryError, ArithmeticError):
    """Integer overflow or division by zero (also an ArithmeticError)."""


# Error code -> exception class (see src/diagnostics.zig ErrorCode).
_CODE_TO_ERROR = {
    1: ParseError,
    2: UnknownVariableError,
    4: TypeMismatchError,
    5: InvalidExpressionError,
    6: NodeStillConnectedError,
    8: ParameterMissingError,
    9: ArithmeticQueryError,
}


def error_from_code(code: int, message: str) -> AcmedbError:
    cls = _CODE_TO_ERROR.get(code, QueryError)
    if cls is QueryError and code == 7:
        return StorageError(f"{message} (code 7)")
    return cls(code, message)
