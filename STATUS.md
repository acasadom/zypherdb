# acmedb — Estado de desarrollo

_Última actualización: binding C manual de LMDB terminado; `KvStore` compila y
pasa sus 6 tests. Mantén este fichero al día: es el punto de entrada para una
sesión nueva, para no perder contexto._

## 1. Decisión clave: pivote de pila (C++/RocksDB → Zig/LMDB)

**Se abandona C++ + RocksDB y se pasa a Zig + LMDB.** Motivos (según el usuario):

1. Quiere algo **embebido en Python** (no en C++).
2. Quiere **rendimiento real y utilizable**.
3. **Compilaciones rápidas** en un M1 de 8 GB de RAM.
4. Quiere que **funcione sin tener que revisar todo el código** a fondo.
5. A futuro le interesa **replicación de lectura** (un proceso escribe → se replica a N → cada proceso lee su réplica).

Puntos que aclaramos y conviene recordar:

- El dolor de "compilación lenta" **no venía del código C++**, sino de **RocksDB
  compilado desde fuente vía vcpkg** (~1h45m la primera vez). Cambiar de lenguaje
  no elimina ese coste si se sigue enlazando RocksDB.
- El **lenguaje del ejecutor importa poco para el rendimiento**: lo dominan el
  storage engine (I/O) y la planificación (selección de anchor).
- **LMDB es single-writer / multi-reader por nodo**, lo que encaja exactamente con
  el modelo de réplicas deseado (cada réplica la escribe solo el "apply" de
  replicación). En lecturas LMDB es ~6x más rápido que RocksDB.
- **Caveats asumidos**: Zig sigue pre-1.0 (0.17.0, breaking changes hasta 1.0) y
  ecosistema pequeño; LMDB tiene `map_size` fijo a dimensionar y un solo escritor.

El esqueleto C++/RocksDB **se conserva en git** (commit `1a5080f`), no se pierde.

## 2. Entorno y toolchain (ya hecho)

- **Zig 0.17.0** instalado en `.zig/0.17.0/` (gitignored), enlazado a
  `~/.local/bin/zig` (que ya está en `PATH`). Verificado: `zig version` → `0.17.0`.
- Se eliminó el `zig` de Homebrew (0.11.0, estaba roto: le faltaba una dylib de z3).
- **LMDB 1.0.2** vendido en `vendor/lmdb/` (`mdb.c`, `midl.c`, `lmdb.h`, `midl.h`,
  `LICENSE`, `COPYRIGHT`), fijado a la versión `LMDB_1.0.2`.
- **Docker/vcpkg ya NO se necesitan**: Zig es una toolchain nativa de un solo
  binario (trae su propio `zig cc`). Esto elimina toda la complejidad anterior de
  Docker/vcpkg/CMake.

### Restricciones del sandbox (importante)

- El agente **no puede escribir** en `~/.local/opt` ni fuera del workspace del
  proyecto. Sí puede escribir en el proyecto, `/tmp` y `~/.local/bin`.
- Regla de la sesión anterior que se mantiene: **no instalar/modificar nada en el
  host sin permiso explícito.**

## 3. Código Zig creado (compila y pasa los tests)

Ficheros nuevos:

- `build.zig` — módulo `acmedb` + librería estática + paso `test`.
- `build.zig.zon` — manifiesto (fingerprint `0x8985f8037b44acbc`, generado por el toolchain).
- `src/root.zig` — raíz de la librería (re-exporta `storage`).
- `src/storage/kv_store.zig` — `KvStore` sobre LMDB + 6 tests.
- `src/storage/lmdb.zig` — binding C **manual** de LMDB (sin `@cImport`).

API diseñada de `KvStore` (espejo de la de C++), errores como `error union`
(análogo a `std::expected`):

- `open(allocator, path) KvError!KvStore`
- `put(key, value) KvError!void`
- `get(key) KvError!?[]u8` (clave ausente = `null`, valor devuelto es copia propiedad)
- `exists(key) KvError!bool`
- `del(key) KvError!void` (idempotente)
- `scanPrefix(prefix) KvError!PrefixIterator`
- `countPrefix(prefix) KvError!usize`

## 4. Bloqueante resuelto: binding C manual (antes `@cImport`)

**`@cImport` fue eliminado en Zig 0.17.0**, así que se sustituyó por un binding
C **manual** en `src/storage/lmdb.zig`: `extern "c" fn` + tipos `opaque {}` para
`MDB_env`/`MDB_txn`/`MDB_cursor`. Datos clave ya aplicados (ver
`vendor/lmdb/lmdb.h`):

- `MDB_val` = `extern struct { mv_size: usize, mv_data: ?*anyopaque }`.
- `MDB_dbi` = `c_uint`; `mdb_size_t` = `size_t` (usize); `mdb_mode_t` = `c_uint`.
- Constantes: `MDB_RDONLY = 0x20000`, `MDB_NOTFOUND = -30798`.
- `MDB_cursor_op`: `MDB_NEXT = 8`, `MDB_SET_RANGE = 17`.

Los 7 tests (6 de `KvStore` + `refAllDecls`) pasan: `zig build test`.

## 5. Notas de API de Zig 0.17 (para no redescubrirlas)

- `@cImport` eliminado → usar binding manual: `extern "c" fn`, tipos `opaque {}`,
  structs `extern struct` (ver `src/storage/lmdb.zig`).
- `std.fs` fue reorganizado → ahora `std.Io` (`Io.Dir`, `Io.File`). `makePath` y
  `realpathAlloc` ya no existen; ahora es `createDirPathOpen`, etc.
- `std.testing.tmpDir(.{})` devuelve `TmpDir` (NO un `error union`), crea la
  carpeta en `.zig-cache/tmp/<sub_path>` y se limpia con `.cleanup()`.
- `Allocator.dupeZ` eliminado → usar `dupeSentinel(u8, slice, 0)` (devuelve `[:0]u8`).
- `std.ArrayList(T)` ahora es la variante *unmanaged* (sin `allocator` interno):
  se inicializa con `std.ArrayList(T).empty`, y `append(gpa, item)` /
  `deinit(gpa)` reciben el allocator por parámetro. `ArrayList.init(gpa)` ya no existe.
- Build API: `b.addModule` / `b.createModule` / `b.addLibrary` / `b.addTest`;
  métodos de módulo `addCSourceFiles`, `addIncludePath`; `link_libc` se pone en
  `Module.CreateOptions`.

## 6. Plan de desarrollo (roadmap, ahora en Zig)

Ordenado por leverage:

1. ~~**Terminar el binding C manual** y pasar los 6 tests de `KvStore`.~~ ✅ hecho
2. **Definir un caso de uso vertical concreto** (dataset pequeño + ~5 queries con
   salida exacta) como definición de "done" del primer slice de openCypher.
3. **Codificación de claves de grafo** (adyacencia index-free) sobre `scanPrefix`:
   `prefijo-nodo | dirección | tipo-relación | vecino-id`.
4. **AST como arena** (`std.ArrayList` de nodos + índices de hijos, `NodeKind` +
   payload), sin punteros ni herencia.
5. **Parser recursivo-descendente** de openCypher (subset) → AST de arena.
6. **Traducción AST → plan lógico** → **ejecutor Volcano ingenuo** (Open/Next/Close).
7. **Estadísticas + selección de anchor** del patrón (la optimización de mayor impacto).
8. **Wrapper Python vía ABI C** (`export fn`), y solo después escrituras
   (CREATE/SET/DELETE) y más cláusulas.

## 7. Decisiones de diseño que conviene recordar

- **Sin jerarquías de clases ni Visitor.** Generic programming (Stepanov/STL):
  datos como tipos concretos, algoritmos como funciones libres. En Zig esto se
  traduce a `comptime` generics y tipos concretos.
- **Errores como valores** (`error union`), no excepciones.
- El `scan_prefix` como **iterador** (no callback push): es la abstracción
  componible que necesita un ejecutor Volcano.
- LMDB itera en orden lexicográfico de clave, que es justo lo que explota la
  codificación de adyacencia por prefijo.
