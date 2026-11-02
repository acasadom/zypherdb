"""A query's result: its rows, and whether a forwarded write shows here yet."""

from __future__ import annotations


class Rows(list):
    """The rows of a query, as a list of lists of cells.

    `visible` is True but for a write a replica forwarded to its master
    (``forward_writes=True``): the rows came back, yet the change had not
    reached the replica when its `forward_timeout` ran out, so a read there
    may not show it yet. The master has it, and the replica shows it once
    replication catches up.
    """

    visible = True
