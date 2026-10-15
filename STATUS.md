# acmedb — Development status

_Last updated: session working with the agent. Keep this file current: it is the
entry point for a fresh session so we do not lose context._

## 1. Environment (host is macOS, Apple Silicon)

- Commands run **directly on the host** (an earlier note in the README claiming
  an "isolated VM without a Docker daemon" was **wrong** — verify before trusting
  it again).
- Docker is available. **Current engine: OrbStack** (`docker context show` ->
  `orbstack`). Docker Desktop is also installed. The active context has changed
  between engines during the project, so **always check `docker context show`
  before building**: an image/volume built on one engine is NOT visible on the
  other, though the host bind mount (`build/`) is shared.
- Toolchain lives **inside the container only** (Clang 20, CMake, Ninja, vcpkg).
  Nothing is installed on the host. **Rule: never install/modify anything on the
  host without explicit permission.**
- Internet access is fast; disk was freed up (was ~3.5 GiB, now ~96 GiB free).

### Build/run loop (important operational notes)

- The **terminal kills foreground commands after 2 minutes**. Long builds MUST be
  launched detached, writing to a log file in the repo, then polled:
  ```bash
  docker compose run --rm -d --name acmedb-<step> dev bash -lc \
    '<cmd> > build/logs/<step>.log 2>&1; echo "EXIT=$?" >> build/logs/<step>.log; touch build/logs/<step>.done'
  # then read build/logs/<step>.log
  ```
- `build/logs/` holds these logs. `build/` is gitignored.
- The first vcpkg configure compiles RocksDB from source (~1h45m). It is now
  cached in `build/debug/vcpkg_installed/` (host bind mount), so subsequent
  configures take ~2s. RocksDB is NOT recompiled unless `vcpkg.json` changes.
- If a detached container is interrupted, clean it up: `docker rm -f acmedb-<step>`.

## 2. What was found (bugs / surprises)

1. **`docker/Dockerfile` broke the image build**: `software-properties-common`
   does not exist on `debian:trixie-slim`, so `apt-get install` failed with
   exit 100. It was unused (the LLVM script adds its own repo), so it was removed.
2. **`src/storage/kv_store.cpp` did not compile** against the RocksDB that vcpkg
   installs (11.8.1): `rocksdb::DB::Open` now takes `std::unique_ptr<DB>*`, not
   the old raw `DB**`. The code assumed the raw-pointer overload. This proves the
   skeleton had **never actually been compiled** before.
3. The README's claim about an isolated VM without Docker was inaccurate for this
   environment (see section 1).
4. No git repository existed at the start.

## 3. What was done

- **Dockerfile fixed** (removed `software-properties-common`). Image builds.
- **`kv_store.cpp` fixed** for the modern `DB::Open` signature (uses
  `std::unique_ptr<rocksdb::DB>` directly).
- **Git initialized** (`main`) with an initial commit of the skeleton (`9aed84c`),
  including a `.gitignore` that excludes `build/`, `vcpkg_installed/`,
  `compile_commands.json`, `.DS_Store`, and local editor dirs (`.continue/`,
  `.vscode/`).
- **`KvStore` hardened** (uncommitted at time of writing):
  - `get` now returns `std::expected<std::optional<std::string>, KvError>` —
    a missing key is a normal result, not an error.
  - added `exists` and `del` (del is idempotent).
  - added `scan_prefix` returning a **`PrefixRange`**, which models
    `std::ranges::input_range` (compile-time `static_assert`), owns the RocksDB
    iterator via `unique_ptr` (move-only, RAII, no dangling), yields
    `std::pair<std::string_view, std::string_view>`, and composes with
    `std::views` (verified with a `transform | take` test).
  - added `count_prefix` (neighbour counts — needed later for anchor selection).
  - `KvError` extended with `DeleteFailed` and `IteratorFailed`.
- **Tests expanded** from 1 to 7, all passing: get/absent, exists, del idempotent,
  ordered prefix scan, prefix scan composed with `std::views`, count_prefix, plus
  the original smoke test.

### Design decisions worth remembering

- The project explicitly rejects class hierarchies / inheritance and the Visitor
  pattern (Stepanov-style generic programming). This is **why the prefix scan is
  modelled as a range/iterator**, not a push-style callback: a range is the
  composable abstraction a Volcano-style executor needs, and it is consistent
  with the stated philosophy.
- Errors are values (`std::expected`), not exceptions.

## 4. Verification status

- Last pipeline run: **configure OK, build OK, 7/7 ctest passed, PIPELINE_EXIT=0**.

## 5. Proposed plan from here

Ordered by leverage. Items 1–2 are the agreed next steps; adjust as needed.

1. **Commit the current `KvStore` work** (single clean commit).
2. **Define one concrete vertical use case** before writing more engine code:
   a tiny dataset (e.g. people + KNOWS edges) plus ~5 fixed queries with their
   exact expected output. This becomes the definition of "done" for the first
   openCypher slice. Without this, "supports MATCH" is undefined.
3. **Graph key encoding** on top of `KvStore::scan_prefix`: encode adjacency as
   `node-prefix | direction | edge-type | neighbour-id` so "neighbours of X" is a
   single ordered prefix scan (index-free adjacency). This is the next real
   engine brick and it exercises `scan_prefix` for real.
4. **AST as an arena** (`std::vector<Node>` + child index ranges, `NodeKind` +
   payload), no pointers/inheritance — as described in the README.
5. **Recursive-descent openCypher parser** (subset) producing the arena AST.
6. **Translation AST -> logical plan** -> **naive Volcano executor**
   (Open/Next/Close) over the encoded adjacency.
7. Later: statistics + pattern anchor selection (the highest-impact graph
   optimisation), and only then write features (CREATE/SET/DELETE) and more
   clauses.

### Open decisions to settle

- Whether to commit `.continue/prompts` and `.continue/rules` selectively
  (currently the whole `.continue/` is ignored).
- Which Docker engine to standardise on (OrbStack vs Docker Desktop) to avoid
  rebuilding images when the context flips.
- Whether the global host-safety rule should also be written to the user's global
  Claude config (the agent could not write outside the project workspace; the user
  must do it, or grant permission).
