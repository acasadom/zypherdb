# acmedb

Motor de base de datos de grafos embebido, en C++, hablando un subconjunto de
openCypher, sobre RocksDB como capa de almacenamiento.

## Decisiones de arquitectura (por que esta pila)

- **C++23** como base estable (soporte completo en Clang/GCC recientes).
  C++26 ya cerro su contenido tecnico en marzo de 2026 pero aun no esta
  publicado como ISO; lo vamos adoptando funcion a funcion segun madure en el
  compilador (reflection en particular puede cambiar mucho como se genera el
  AST/plan mas adelante).
- **Clang** como compilador principal (mejor tooling: clangd, clang-tidy,
  sanitizers). GCC es tambien valido y conviene probarlo en CI para detectar
  no-portabilidades, pero el dia a dia es con Clang.
- **RocksDB** como storage engine (no SQLite): un grafo se recorre siguiendo
  adyacencias, no haciendo joins entre tablas. Codificamos nuestras propias
  claves (prefijo por nodo+direccion+tipo de relacion) y aprovechamos que
  RocksDB itera en orden para resolver "dame los vecinos de X" con un scan de
  prefijo, sin joins.
- **Sin jerarquias de clases por polimorfismo de herencia.** Nos apoyamos en
  generic programming al estilo Stepanov/STL: datos como tipos concretos sin
  comportamiento propio, algoritmos como funciones libres, concepts de C++20
  para los sitios donde de verdad hace falta un contrato generico. Nada de
  Visitor con jerarquias base-clase-de-todo. El AST se modelara como un arena
  de nodos (`std::vector` + indices, no punteros/herencia), inspirado en como
  representan su AST compiladores como el de Zig.
- **Parser propio, sin ANTLR ni libcypher-parser.** Decision explicita:
  recursivo-descendente escrito a mano sobre la gramatica publicada de
  openCypher, para no meter en el proyecto el estilo (y las dependencias) de
  un generador de parsers ajeno al paradigma que buscamos.
- **Docker** como entorno de desarrollo: todo el toolchain (Clang, CMake,
  Ninja, vcpkg) vive en la imagen; el codigo fuente se monta como volumen, asi
  que tu macOS no se ensucia con nada de esto.
- **vcpkg en modo manifiesto** para dependencias (`vcpkg.json`), fijado a un
  commit concreto de vcpkg para builds reproducibles. Se descarto Hunter (el
  ecosistema se ha movido a vcpkg/Conan) y Conan 2 se deja como opcion futura
  si algun dia hace falta una matriz de configuraciones mas compleja o
  distribuir acmedb como paquete.

## Como se construye

Todo corre dentro de Docker, nada se instala en tu maquina:

```bash
docker compose build
docker compose run --rm dev bash
```

Dentro del contenedor (en `/workspace`, que es tu carpeta del proyecto):

```bash
cmake --preset=debug
cmake --build --preset=debug
ctest --preset=debug
```

La primera vez, `cmake --preset=debug` hace que vcpkg compile RocksDB y
Catch2 desde fuente (varios minutos). Las siguientes veces es casi
instantaneo porque `vcpkg_installed/` queda en tu carpeta del proyecto
(montada como volumen) y no se vuelve a compilar mientras no cambie
`vcpkg.json`.

Nota: la maquina desde la que estoy trabajando ahora mismo no tiene Docker
accesible directamente (es una VM aislada sin el daemon de Docker), asi que
esta primera build y el test de humo los tienes que lanzar tu una vez en tu
Mac. Si algo falla, pegame la salida y lo arreglamos.

## Estado actual

Primer esqueleto: `acmedb::storage::KvStore`, un envoltorio RAII minimo sobre
RocksDB (sin jerarquias, errores como `std::expected`, no excepciones) mas un
test de humo que abre una DB, escribe una clave y la lee. Sirve para validar
que todo el pipeline (CMake + vcpkg + RocksDB + C++23 + Catch2) funciona de
extremo a extremo antes de meternos con el AST.

## Roadmap (subconjunto inicial de openCypher)

1. `MATCH` con patrones simples de nodo/relacion, `WHERE` con comparaciones y
   booleanos basicos, `RETURN` con expresiones y alias. Fuera de esta primera
   vuelta: `OPTIONAL MATCH`, `WITH` encadenado, `UNWIND`, agregaciones,
   `MERGE`/`CREATE`/`SET`/`DELETE`, comprehensions, subqueries.
2. Parser recursivo-descendente propio -> AST como arena de nodos por
   indices (`NodeKind` + payload + rango de hijos).
3. Traductor AST -> plan logico (operadores tipo Scan/Expand/Filter/Produce).
4. Codificacion de claves en RocksDB para adyacencia + primer ejecutor
   ingenuo estilo Volcano (Open/Next/Close).
5. Estadisticas basicas + seleccion de "anchor" del patron (la optimizacion
   de mayor impacto en un motor de grafos).
