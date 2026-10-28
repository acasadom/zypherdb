"""PEP 517 build backend for the ZypherDB Python package (in-tree, `backend-path`).

A wheel is the pure-Python package (python/zypherdb) plus the native module, which
`zig build python` compiles. The module uses the limited API, so one wheel per
platform serves every Python >= 3.10 (tag `cp310-abi3-<platform>`). Zig comes from
$ZIG, from a `zig` on PATH of the version build.zig.zon asks for, or else from the
`ziglang` PyPI package (requested through get_requires_for_build_wheel).

Config settings (`pip wheel --config-settings key=value`, `python -m build -C...`):
    optimize      Zig optimize mode (default ReleaseSafe: it keeps the pair assertions)
    zig-target    cross-compile for this Zig target ...
    platform-tag  ... and tag the wheel with this platform (both or neither)

The version comes from git, as hatch-vcs gives it: on a tag `vX.Y.Z` it is `X.Y.Z`; N
commits later, `X.Y.(Z+1).devN`; with no tag, `0.0.devN`. An sdist keeps the version it was
built with in PKG-INFO.

An editable install only puts python/ on sys.path; build the native module with
`make python` (the package then loads it from zig-out/python).
"""

from __future__ import annotations

import base64
import hashlib
import io
import os
import platform
import re
import shutil
import subprocess
import sys
import sysconfig
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib

SOURCE_ROOT = Path(__file__).resolve().parent.parent.parent
PACKAGE_DIRECTORY = SOURCE_ROOT / "python" / "zypherdb"
PYTHON_TAG = "cp310-abi3"
# What an sdist carries: enough to run `zig build python` and rebuild a wheel.
SDIST_PATHS = [
    "pyproject.toml", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md",
    "build.zig", "build.zig.zon", "src", "vendor", "include",
    "python/zypherdb", "python/native", "tools/build_backend",
]
# Zig target and wheel platform tag per (system, machine) for a native build. Linux
# targets glibc 2.17, so the wheel really is manylinux2014.
NATIVE_TARGETS = {
    ("Linux", "x86_64"): ("x86_64-linux-gnu.2.17", "manylinux_2_17_x86_64.manylinux2014_x86_64"),
    ("Linux", "aarch64"): ("aarch64-linux-gnu.2.17", "manylinux_2_17_aarch64.manylinux2014_aarch64"),
    ("Darwin", "x86_64"): ("x86_64-macos.10.13", "macosx_10_13_x86_64"),
    ("Darwin", "aarch64"): ("aarch64-macos.11.0", "macosx_11_0_arm64"),
    ("Windows", "x86_64"): ("x86_64-windows-gnu", "win_amd64"),
    ("Windows", "aarch64"): ("aarch64-windows-gnu", "win_arm64"),
}
MACHINE_NAMES = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}


# --- PEP 517 hooks -------------------------------------------------------------------


def get_requires_for_build_wheel(config_settings=None):
    return [] if _system_zig() else [f"ziglang=={_required_zig_version()}"]


def get_requires_for_build_sdist(config_settings=None):
    return []


def get_requires_for_build_editable(config_settings=None):
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    settings = config_settings or {}
    zig_target, platform_tag = _target_and_platform_tag(settings)
    windows = "windows" in zig_target
    with tempfile.TemporaryDirectory() as prefix:
        _zig_build_python(settings.get("optimize", "ReleaseSafe"), zig_target, windows, prefix)
        native_name = "_native.pyd" if windows else "_native.abi3.so"
        native_module = Path(prefix) / "python" / native_name
        package_files = [(f"zypherdb/{path.name}", path) for path in sorted(PACKAGE_DIRECTORY.glob("*.py"))]
        package_files.append((f"zypherdb/{native_name}", native_module))
        return _write_wheel(wheel_directory, [platform_tag], package_files)


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    path_file = ("zypherdb_editable.pth", str(SOURCE_ROOT / "python") + "\n")
    return _write_wheel(wheel_directory, ["any"], [], [path_file], python_tag="py3-none")


def build_sdist(sdist_directory, config_settings=None):
    project = _project()
    base_name = f"{_normalized_name(project['name'])}-{project['version']}"
    archive_path = Path(sdist_directory) / f"{base_name}.tar.gz"
    with tarfile.open(archive_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for relative in SDIST_PATHS:
            archive.add(SOURCE_ROOT / relative, f"{base_name}/{relative}", filter=_sdist_filter)
        _add_bytes_to_tar(archive, f"{base_name}/PKG-INFO", _metadata(project))
    return archive_path.name


# --- Zig -----------------------------------------------------------------------------


def _required_zig_version():
    zon = (SOURCE_ROOT / "build.zig.zon").read_text(encoding="utf-8")
    return re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1)


def _system_zig():
    """The zig to run, if one of the right version is installed (or named by $ZIG)."""
    if os.environ.get("ZIG"):
        return [os.environ["ZIG"]]
    found = shutil.which("zig")
    if found is None:
        return None
    version = subprocess.run([found, "version"], capture_output=True, text=True).stdout.strip()
    return [found] if version == _required_zig_version() else None


def _zig_command():
    command = _system_zig()
    if command is not None:
        return command
    try:
        import ziglang  # noqa: F401
    except ImportError:
        raise RuntimeError(
            f"building ZypherDB needs Zig {_required_zig_version()}: install it, set $ZIG, "
            "or install the `ziglang` package"
        ) from None
    return [sys.executable, "-m", "ziglang"]


def _target_and_platform_tag(settings):
    if "zig-target" in settings or "platform-tag" in settings:
        if "zig-target" not in settings or "platform-tag" not in settings:
            raise ValueError("config settings zig-target and platform-tag go together")
        return settings["zig-target"], settings["platform-tag"]
    system = platform.system()
    machine = MACHINE_NAMES.get(platform.machine().lower(), platform.machine().lower())
    if system == "Linux" and platform.libc_ver()[0] != "glibc":
        raise RuntimeError("only glibc Linux is supported (musl wheels are not built yet)")
    if (system, machine) not in NATIVE_TARGETS:
        raise RuntimeError(f"no wheel target for {system} {machine}")
    return NATIVE_TARGETS[(system, machine)]


def _zig_build_python(optimize, zig_target, windows, prefix):
    include = sysconfig.get_paths()["include"]
    command = _zig_command() + [
        "build", "python", f"-Doptimize={optimize}", f"-Dtarget={zig_target}", "-Dpython-strip",
        f"-Dpython-include={include}", "--prefix", prefix,
    ]
    if windows:
        command.append(f"-Dpython-libs={Path(sys.base_prefix) / 'libs'}")
    print(" ".join(command), file=sys.stderr)
    subprocess.run(command, cwd=SOURCE_ROOT, check=True)


# --- metadata ------------------------------------------------------------------------


def _project():
    with open(SOURCE_ROOT / "pyproject.toml", "rb") as pyproject:
        project = tomllib.load(pyproject)["project"]
    if "version" in project.get("dynamic", []):
        project["version"] = _version()
    return project


def _version():
    """The version of an unpacked sdist (its PKG-INFO), or else the one git describes."""
    pkg_info = SOURCE_ROOT / "PKG-INFO"
    if pkg_info.exists():
        return re.search(r"^Version: (.+)$", pkg_info.read_text(encoding="utf-8"), re.MULTILINE).group(1)
    described = _git("describe", "--tags", "--long", "--match", "v[0-9]*")
    if described is None:
        return f"0.0.dev{_git('rev-list', '--count', 'HEAD') or 0}"
    tag, distance, _ = described.rsplit("-", 2)
    version = tag[1:]
    if distance == "0":
        return version
    release = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if release is None:
        return f"{version}.post0.dev{distance}"
    major, minor, patch = release.groups()
    return f"{major}.{minor}.{int(patch) + 1}.dev{distance}"


def _git(*arguments):
    """git's output in the source tree, or None when git or the repository is missing."""
    try:
        result = subprocess.run(["git", *arguments], cwd=SOURCE_ROOT, capture_output=True, text=True)
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def _normalized_name(name):
    return re.sub(r"[-_.]+", "_", name).lower()


def _metadata(project):
    """Core metadata 2.4 (PKG-INFO / METADATA) from the [project] table."""
    lines = [
        "Metadata-Version: 2.4",
        f"Name: {project['name']}",
        f"Version: {project['version']}",
        f"Summary: {project['description']}",
        f"Requires-Python: {project['requires-python']}",
        f"License-Expression: {project['license']}",
    ]
    lines += [f"License-File: {path}" for path in project.get("license-files", [])]
    lines += [f"Author: {author['name']}" for author in project.get("authors", [])]
    if project.get("keywords"):
        lines.append(f"Keywords: {','.join(project['keywords'])}")
    lines += [f"Classifier: {classifier}" for classifier in project.get("classifiers", [])]
    lines += [f"Project-URL: {label}, {url}" for label, url in project.get("urls", {}).items()]
    lines += [f"Requires-Dist: {requirement}" for requirement in project.get("dependencies", [])]
    for extra, requirements in project.get("optional-dependencies", {}).items():
        lines.append(f"Provides-Extra: {extra}")
        lines += [f'Requires-Dist: {requirement}; extra == "{extra}"' for requirement in requirements]
    readme = project.get("readme")
    if readme:
        lines.append("Description-Content-Type: text/markdown")
        return ("\n".join(lines) + "\n\n" + (SOURCE_ROOT / readme).read_text(encoding="utf-8")).encode()
    return ("\n".join(lines) + "\n").encode()


# --- archives ------------------------------------------------------------------------


def _timestamp():
    """Reproducible archives: SOURCE_DATE_EPOCH if set, else the zip epoch."""
    return max(int(os.environ.get("SOURCE_DATE_EPOCH", "315532800")), 315532800)


def _write_wheel(wheel_directory, platform_tags, package_files, extra_files=(), python_tag=PYTHON_TAG):
    """Writes the wheel: package_files are (archive name, path), extra_files (name, text)."""
    project = _project()
    distribution = f"{_normalized_name(project['name'])}-{project['version']}"
    dist_info = f"{distribution}.dist-info"
    wheel_name = f"{distribution}-{python_tag}-{'.'.join(platform_tags)}.whl"
    tags = [f"Tag: {python_tag}-{tag}" for tag in ".".join(platform_tags).split(".")]
    purelib = "true" if python_tag == "py3-none" else "false"
    wheel_info = "\n".join(["Wheel-Version: 1.0", "Generator: zypherdb_build", f"Root-Is-Purelib: {purelib}", *tags])
    entries = [(name, path.read_bytes(), _is_executable(path)) for name, path in package_files]
    entries += [(name, text.encode(), False) for name, text in extra_files]
    entries += [
        (f"{dist_info}/licenses/{path}", (SOURCE_ROOT / path).read_bytes(), False)
        for path in project.get("license-files", [])
    ]
    entries.append((f"{dist_info}/METADATA", _metadata(project), False))
    entries.append((f"{dist_info}/WHEEL", (wheel_info + "\n").encode(), False))
    record = [f"{name},sha256={_digest(data)},{len(data)}" for name, data, _ in entries]
    record.append(f"{dist_info}/RECORD,,")
    entries.append((f"{dist_info}/RECORD", ("\n".join(record) + "\n").encode(), False))
    date_time = _zip_date_time()
    with zipfile.ZipFile(Path(wheel_directory) / wheel_name, "w", zipfile.ZIP_DEFLATED) as wheel:
        for name, data, executable in entries:
            info = zipfile.ZipInfo(name, date_time)
            info.external_attr = (0o755 if executable else 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            wheel.writestr(info, data)
    return wheel_name


def _zip_date_time():
    return time.gmtime(_timestamp())[:6]


def _digest(data):
    return base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def _is_executable(path):
    return path.suffix in (".so", ".pyd")


def _sdist_filter(member):
    if "__pycache__" in member.name or member.name.endswith((".pyc", ".DS_Store")):
        return None
    member.uid = member.gid = 0
    member.uname = member.gname = ""
    member.mtime = _timestamp()
    return member


def _add_bytes_to_tar(archive, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    info.mtime = _timestamp()
    archive.addfile(info, io.BytesIO(data))
