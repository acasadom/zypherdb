#include <catch2/catch_test_macros.hpp>

#include "storage/kv_store.hpp"

#include <filesystem>

// Test de humo: valida que todo el pipeline (CMake + vcpkg + RocksDB +
// C++23 std::expected + Catch2) enlaza y funciona de extremo a extremo.
TEST_CASE("KvStore abre, escribe y lee una clave", "[storage][smoke]") {
    const auto dir = std::filesystem::temp_directory_path() / "acmedb_smoke_test_db";
    std::filesystem::remove_all(dir);

    auto store = acmedb::storage::KvStore::open(dir);
    REQUIRE(store.has_value());

    const auto put_result = store->put("saludo", "hola acmedb");
    REQUIRE(put_result.has_value());

    const auto get_result = store->get("saludo");
    REQUIRE(get_result.has_value());
    CHECK(*get_result == "hola acmedb");

    std::filesystem::remove_all(dir);
}
