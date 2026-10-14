find_package(Catch2 3 CONFIG REQUIRED)
include(CTest)
include(Catch)

add_executable(acmedb_tests
    smoke_test.cpp
)

target_link_libraries(acmedb_tests
    PRIVATE
        acmedb_core
        Catch2::Catch2WithMain
)

catch_discover_tests(acmedb_tests)
