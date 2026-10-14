cmake_minimum_required(VERSION 3.28)

project(acmedb
    VERSION 0.1.0
    DESCRIPTION "Motor de grafos embebido (subconjunto de openCypher) sobre RocksDB"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Build type" FORCE)
endif()

option(ACMEDB_BUILD_TESTS "Compilar los tests de acmedb" ON)

add_subdirectory(src)

if(ACMEDB_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
