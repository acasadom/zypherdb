# tzdata

The IANA time zone database, compiled to TZif files, as shipped in the
[tzdata](https://pypi.org/project/tzdata/) Python package. ZypherDB embeds it
(`@import("tzdata")`, see `build.zig`) instead of reading the system's database,
so a zone's history is the same on every machine.

`tzdata.bin` and `tzdata.zig` are generated; the version and the wheel's SHA-256
are at the top of `tzdata.zig`. To update, download the newest wheel and run:

```bash
python3 -I tools/tzdata.py tzdata-<version>-py2.py3-none-any.whl vendor/tzdata
zig fmt vendor/tzdata/tzdata.zig
```

then update the version in `THIRD_PARTY_NOTICES.md` and run the tests.
