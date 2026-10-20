"""Temporal values: dates, times, date-times and durations.

Query results return acmedb's own temporal types, which keep the exact value
acmedb computed (nanosecond precision, years from -999,999,999 to
999,999,999, named time zones) as its ISO 8601 text. ``to_native()`` turns
one into the closest ``datetime`` object (truncating to microseconds), and
they compare equal to the ``datetime`` objects they represent.

Query parameters accept both these types and the ``datetime`` module's:
``date`` becomes a Cypher ``Date``, a naive ``time`` / ``datetime`` a
``LocalTime`` / ``LocalDateTime``, an aware one a ``Time`` / ``DateTime``
(in its ``zoneinfo`` zone, if it has one), and a ``timedelta`` a ``Duration``.
"""

from __future__ import annotations

import datetime as _dt
import re

_TIME = re.compile(r"(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?")
_OFFSET = re.compile(r"Z|([+-])(\d{2}):(\d{2})(?::(\d{2}))?")
_DURATION = re.compile(
    r"P(?:(-?\d+)Y)?(?:(-?\d+)M)?(?:(-?\d+)D)?"
    r"(?:T(?:(-?\d+)H)?(?:(-?\d+)M)?(?:(-?)(\d+)(?:\.(\d{1,9}))?S)?)?"
)


class Temporal:
    """A temporal value, held as the ISO 8601 text acmedb wrote for it."""

    __slots__ = ("iso",)
    tag = ""

    def __init__(self, iso: str):
        self.iso = iso

    def __str__(self) -> str:
        return self.iso

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self.iso!r})"

    def __eq__(self, other) -> bool:
        if type(other) is type(self):
            return other.iso == self.iso
        if isinstance(other, (_dt.date, _dt.time, _dt.timedelta)):
            try:
                return self.to_native() == other
            except ValueError:
                return False
        return NotImplemented

    def __hash__(self) -> int:
        return hash((type(self).__name__, self.iso))

    def to_native(self):
        """The closest ``datetime``-module value (microsecond precision)."""
        raise NotImplementedError


def _date(text: str) -> _dt.date:
    year, month, day = text.split("-") if not text.startswith(("-", "+")) else text[1:].split("-")
    if text.startswith("-"):
        raise ValueError(f"{text}: years before 1 are outside the datetime module's range")
    return _dt.date(int(year), int(month), int(day))


def _time(text: str) -> tuple[_dt.time, str]:
    """The time of day at the start of `text`, and the rest of the text."""
    match = _TIME.match(text)
    hours, minutes, seconds, fraction = match.groups()
    microseconds = int((fraction or "0").ljust(9, "0")[:6])
    return _dt.time(int(hours), int(minutes), int(seconds or 0), microseconds), text[match.end():]


def _offset(text: str) -> _dt.timezone:
    match = _OFFSET.fullmatch(text)
    if match is None:
        raise ValueError(f"not an offset: {text!r}")
    if text == "Z":
        return _dt.timezone.utc
    sign, hours, minutes, seconds = match.groups()
    delta = _dt.timedelta(hours=int(hours), minutes=int(minutes), seconds=int(seconds or 0))
    return _dt.timezone(-delta if sign == "-" else delta)


class Date(Temporal):
    tag = "date"

    def to_native(self) -> _dt.date:
        return _date(self.iso)


class LocalTime(Temporal):
    tag = "localtime"

    def to_native(self) -> _dt.time:
        return _time(self.iso)[0]


class Time(Temporal):
    tag = "time"

    def to_native(self) -> _dt.time:
        time, rest = _time(self.iso)
        return time.replace(tzinfo=_offset(rest))


class LocalDateTime(Temporal):
    tag = "localdatetime"

    def to_native(self) -> _dt.datetime:
        date, time = self.iso.split("T")
        return _dt.datetime.combine(_date(date), _time(time)[0])


class DateTime(Temporal):
    tag = "datetime"

    @property
    def zone(self) -> str | None:
        """The IANA zone name (``Europe/Stockholm``), if the value has one."""
        return self.iso[self.iso.index("[") + 1 : -1] if self.iso.endswith("]") else None

    def to_native(self) -> _dt.datetime:
        text = self.iso.split("[")[0]
        date, rest = text.split("T")
        time, offset = _time(rest)
        value = _dt.datetime.combine(_date(date), time, tzinfo=_offset(offset))
        if self.zone is not None:
            from zoneinfo import ZoneInfo

            value = value.astimezone(ZoneInfo(self.zone))
        return value


class Duration(Temporal):
    """A duration: months, days and a time part, independent of each other
    (a month is not a fixed number of days)."""

    tag = "duration"

    def _parts(self) -> tuple[int, int, int, int]:
        """(months, days, seconds, nanoseconds), the time part signed as a whole."""
        match = _DURATION.fullmatch(self.iso)
        years, months, days, hours, minutes, negative, seconds, fraction = match.groups()
        total = int(hours or 0) * 3600 + int(minutes or 0) * 60
        nanoseconds = int(seconds or 0) * 10**9 + int((fraction or "0").ljust(9, "0"))
        nanoseconds = total * 10**9 + (-nanoseconds if negative else nanoseconds)
        return int(years or 0) * 12 + int(months or 0), int(days or 0), *divmod(nanoseconds, 10**9)

    @property
    def months(self) -> int:
        return self._parts()[0]

    @property
    def days(self) -> int:
        return self._parts()[1]

    @property
    def seconds(self) -> int:
        """Whole seconds of the time part, rounded down."""
        return self._parts()[2]

    @property
    def nanoseconds(self) -> int:
        """Nanoseconds of the second, 0 to 999,999,999."""
        return self._parts()[3]

    def to_native(self) -> _dt.timedelta:
        months, days, seconds, nanoseconds = self._parts()
        if months:
            raise ValueError(f"{self.iso}: a duration with months has no fixed length")
        return _dt.timedelta(days=days, seconds=seconds, microseconds=nanoseconds // 1000)


_TYPES = {cls.tag: cls for cls in (Date, LocalTime, Time, LocalDateTime, DateTime, Duration)}


def decode(tag: str, text: str) -> Temporal:
    return _TYPES[tag](text)


def tag_and_text(value) -> tuple[str, str] | None:
    """A temporal parameter as (tag, ISO 8601 text), or None if `value` is not one."""
    encoded = encode(value)
    if encoded is None:
        return None
    (tag, text), = encoded.items()
    return tag[1:], text


def encode(value) -> dict | None:
    """The tagged JSON form of a temporal parameter, or None if `value` is not one."""
    if isinstance(value, Temporal):
        return {"~" + value.tag: value.iso}
    if isinstance(value, _dt.datetime):
        if value.tzinfo is None:
            return {"~localdatetime": value.isoformat()}
        zone = getattr(value.tzinfo, "key", None)  # zoneinfo.ZoneInfo
        text = value.isoformat() + (f"[{zone}]" if zone else "")
        return {"~datetime": text}
    if isinstance(value, _dt.date):
        return {"~date": value.isoformat()}
    if isinstance(value, _dt.time):
        return {"~time" if value.tzinfo is not None else "~localtime": value.isoformat()}
    if isinstance(value, _dt.timedelta):
        return {"~duration": f"P{value.days}DT{value.seconds}.{value.microseconds:06d}S"}
    return None
