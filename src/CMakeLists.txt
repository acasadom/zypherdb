find_package(RocksDB CONFIG REQUIRED)

add_library(acmedb_core
    storage/kv_store.cpp
)

target_include_directories(acmedb_core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(acmedb_core
    PUBLIC
        RocksDB::rocksdb
)

target_compile_features(acmedb_core PUBLIC cxx_std_23)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(acmedb_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
