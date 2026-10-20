"""Loads the native engine (`acmedb._native`, built from python/native/) and
registers with it the Python classes results are built with."""

from __future__ import annotations

import datetime
import importlib.machinery
import importlib.util
import zoneinfo
from pathlib import Path

from . import entities, errors, temporal


def _load():
    try:
        from . import _native  # an installed package ships it next to this file

        return _native
    except ImportError:
        pass
    # A source checkout: `zig build python -Dpython-include=...` puts it in zig-out/python.
    repository = Path(__file__).resolve().parent.parent.parent
    for candidate in (repository / "zig-out" / "python" / "_native.abi3.so", Path.cwd() / "zig-out" / "python" / "_native.abi3.so"):
        if candidate.is_file():
            loader = importlib.machinery.ExtensionFileLoader("acmedb._native", str(candidate))
            spec = importlib.util.spec_from_file_location("acmedb._native", candidate, loader=loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            return module
    raise ImportError(
        "acmedb's native engine is missing: build it with "
        "`zig build python -Dpython-include=$(python3 -c \"import sysconfig; print(sysconfig.get_paths()['include'])\")`"
    )


native = _load()
native.configure(
    {
        "node": entities.Node,
        "relationship": entities.Relationship,
        "path": entities.Path,
        "date": datetime.date,
        "time": datetime.time,
        "datetime": datetime.datetime,
        "timedelta": datetime.timedelta,
        "timezone": datetime.timezone,
        "zone_info": zoneinfo.ZoneInfo,
        "duration": temporal.Duration,
        "query_error": errors.error_from_code,
        "storage_error": errors.StorageError,
        "node_not_found_error": errors.NodeNotFoundError,
    }
)
