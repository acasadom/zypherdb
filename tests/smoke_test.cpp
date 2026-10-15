#include <catch2/catch_test_macros.hpp>

#include "storage/kv_store.hpp"

#include <filesystem>
#include <ranges>
#include <string>
#include <utility>
#include <vector>

namespace {

// Each test gets its own scratch directory, cleaned before and after.
struct ScratchDb {
    std::filesystem::path dir;

    explicit ScratchDb(std::string name)
        : dir(std::filesystem::temp_directory_path() / ("acmedb_test_" + name)) {
        std::filesystem::remove_all(dir);
    }
    ~ScratchDb() { std::filesystem::remove_all(dir); }

    ScratchDb(const ScratchDb&) = delete;
    ScratchDb& operator=(const ScratchDb&) = delete;
};

} // namespace

// Test de humo: valida que todo el pipeline (CMake + vcpkg + RocksDB +
// C++23 std::expected + Catch2) enlaza y funciona de extremo a extremo.
TEST_CASE("KvStore abre, escribe y lee una clave", "[storage][smoke]") {
    ScratchDb scratch{"smoke"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    const auto put_result = store->put("saludo", "hola acmedb");
    REQUIRE(put_result.has_value());

    const auto get_result = store->get("saludo");
    REQUIRE(get_result.has_value());
    REQUIRE(get_result->has_value());
    CHECK(**get_result == "hola acmedb");
}

TEST_CASE("get de una clave inexistente devuelve un optional vacio", "[storage]") {
    ScratchDb scratch{"get_missing"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    const auto result = store->get("no_existe");
    REQUIRE(result.has_value());
    CHECK_FALSE(result->has_value());
}

TEST_CASE("exists distingue presente de ausente", "[storage]") {
    ScratchDb scratch{"exists"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    REQUIRE(store->put("a", "1").has_value());

    const auto present = store->exists("a");
    REQUIRE(present.has_value());
    CHECK(*present);

    const auto absent = store->exists("b");
    REQUIRE(absent.has_value());
    CHECK_FALSE(*absent);
}

TEST_CASE("del borra una clave y es idempotente", "[storage]") {
    ScratchDb scratch{"del"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    REQUIRE(store->put("k", "v").has_value());
    REQUIRE(store->del("k").has_value());

    const auto after = store->get("k");
    REQUIRE(after.has_value());
    CHECK_FALSE(after->has_value());

    // Deleting a missing key must still succeed.
    CHECK(store->del("k").has_value());
}

TEST_CASE("scan_prefix devuelve solo las claves del prefijo, en orden", "[storage]") {
    ScratchDb scratch{"scan"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    for (const auto& kv : {std::pair{"n:a", "1"}, {"n:b", "2"}, {"n:c", "3"}, {"x:z", "9"}}) {
        REQUIRE(store->put(kv.first, kv.second).has_value());
    }

    auto range = store->scan_prefix("n:");
    REQUIRE(range.has_value());

    std::vector<std::pair<std::string, std::string>> seen;
    for (const auto& [k, v] : *range) {
        seen.emplace_back(std::string(k), std::string(v));
    }

    CHECK(range->ok());
    REQUIRE(seen.size() == 3);
    CHECK(seen[0] == std::pair{"n:a", "1"});
    CHECK(seen[1] == std::pair{"n:b", "2"});
    CHECK(seen[2] == std::pair{"n:c", "3"});
}

TEST_CASE("scan_prefix compone con las views de std::ranges", "[storage][ranges]") {
    ScratchDb scratch{"scan_ranges"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    for (int i = 0; i < 10; ++i) {
        const auto key = "n:" + std::to_string(i);
        REQUIRE(store->put(key, "v").has_value());
    }

    auto range = store->scan_prefix("n:");
    REQUIRE(range.has_value());

    // lazily take the first 3 keys through a standard view pipeline
    auto got = *range
             | std::views::transform([](auto kv) { return std::string(kv.first); })
             | std::views::take(3)
             | std::ranges::to<std::vector>();
    REQUIRE(got.size() == 3);
    CHECK(got[0] == "n:0");
    CHECK(got[1] == "n:1");
    CHECK(got[2] == "n:2");
}

TEST_CASE("count_prefix cuenta las claves de un prefijo", "[storage]") {
    ScratchDb scratch{"count"};

    auto store = acmedb::storage::KvStore::open(scratch.dir);
    REQUIRE(store.has_value());

    for (const auto& k : {"n:a", "n:b", "x:z"}) {
        REQUIRE(store->put(k, "v").has_value());
    }

    const auto count = store->count_prefix("n:");
    REQUIRE(count.has_value());
    CHECK(*count == 2);

    const auto none = store->count_prefix("q:");
    REQUIRE(none.has_value());
    CHECK(*none == 0);
}
