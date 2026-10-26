"""Brings vendor/tzdata/ up to the newest tzdata wheel on PyPI, if it is newer.

    python3 -I tools/tzdata_update.py

Compares PyPI's newest version of the tzdata package with the one vendor/tzdata/tzdata.zig was
generated from. If PyPI's is newer: downloads the wheel, checks it against PyPI's SHA-256,
regenerates vendor/tzdata/ with tools/tzdata.py and writes the new version into
THIRD_PARTY_NOTICES.md. Prints the new version on stdout, or nothing if there is none.
Run `zig fmt vendor/tzdata/tzdata.zig` afterwards. Used weekly by .github/workflows/tzdata.yml.
"""

import hashlib
import json
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent.parent
index = root / "vendor/tzdata/tzdata.zig"
notices = root / "THIRD_PARTY_NOTICES.md"


def version_key(version):
    return tuple(int(part) for part in re.findall(r"\d+", version))


current = re.search(r'pub const version = "([^"]+)";', index.read_text()).group(1)
with urllib.request.urlopen("https://pypi.org/pypi/tzdata/json", timeout=60) as response:
    release = json.load(response)
latest = release["info"]["version"]
if version_key(latest) <= version_key(current):
    print(f"tzdata {current} is current", file=sys.stderr)
    sys.exit(0)

wheels = [f for f in release["urls"] if f["filename"].endswith(".whl")]
if len(wheels) != 1:
    sys.exit(f"tzdata {latest}: expected one wheel, found {len(wheels)}")
wheel = wheels[0]
with urllib.request.urlopen(wheel["url"], timeout=120) as response:
    data = response.read()
if hashlib.sha256(data).hexdigest() != wheel["digests"]["sha256"]:
    sys.exit(f"tzdata {latest}: the wheel does not match PyPI's SHA-256")

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / wheel["filename"]
    path.write_bytes(data)
    subprocess.run([sys.executable, "-I", str(root / "tools/tzdata.py"), str(path), str(root / "vendor/tzdata")], check=True)

text = notices.read_text()
updated = text.replace(f"IANA time zone database {current},", f"IANA time zone database {latest},")
if updated == text:
    sys.exit(f"THIRD_PARTY_NOTICES.md does not name tzdata {current}")
notices.write_text(updated)
print(latest)
