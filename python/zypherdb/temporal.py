"""Temporal values: Cypher's dates, times and durations as Python values.

Query results return the `datetime` module's types (built by the native
engine field by field): `date`, `time` (naive, or with a fixed-offset
`timezone`), `datetime` (naive, in its `zoneinfo.ZoneInfo` zone, or at a
fixed offset) and `timedelta`. They stop at microseconds and at years 1 to
9999, so nanoseconds are truncated and a year outside that range raises
`ValueError`; a database opened with ``temporals="iso"`` returns the exact
ISO 8601 text instead.

A duration with months has no `timedelta` (a month is not a fixed number of
days): it comes back as a :class:`Duration`. Both work as query parameters,
like the other `datetime` types.
"""

from __future__ import annotations

import datetime as _dt


class Duration:
    """A duration of months, days and a time part, independent of each other:
    a month is not a fixed number of days, nor a day a fixed number of hours
    across a daylight saving change. ``seconds`` is rounded down, so
    ``nanoseconds`` is always 0 to 999,999,999."""

    __slots__ = ("months", "days", "seconds", "nanoseconds")

    def __init__(self, months: int = 0, days: int = 0, seconds: int = 0, nanoseconds: int = 0):
        extra, nanoseconds = divmod(nanoseconds, 10**9)
        for name, value in (("months", months), ("days", days), ("seconds", seconds + extra), ("nanoseconds", nanoseconds)):
            object.__setattr__(self, name, value)

    def __setattr__(self, name, value):
        raise AttributeError("Duration is immutable")

    def _parts(self) -> tuple[int, int, int, int]:
        return self.months, self.days, self.seconds, self.nanoseconds

    def __eq__(self, other):
        if isinstance(other, _dt.timedelta):
            return self.months == 0 and self.to_timedelta() == other and self.nanoseconds % 1000 == 0
        if not isinstance(other, Duration):
            return NotImplemented
        return self._parts() == other._parts()

    def __hash__(self):
        return hash(self._parts())

    def __repr__(self):
        return f"Duration(months={self.months}, days={self.days}, seconds={self.seconds}, nanoseconds={self.nanoseconds})"

    def __str__(self):
        """ISO 8601, as Cypher writes it: ``P1Y2M3DT4H5M6.5S``."""
        from ._engine import native

        return native.duration_text(*self._parts())

    def to_timedelta(self) -> _dt.timedelta:
        """The duration as a `timedelta` (microseconds), if it has no months."""
        if self.months:
            raise ValueError(f"{self}: a duration with months has no fixed length")
        return _dt.timedelta(days=self.days, seconds=self.seconds, microseconds=self.nanoseconds // 1000)
